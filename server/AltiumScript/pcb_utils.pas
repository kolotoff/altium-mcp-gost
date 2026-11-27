const
    // Mechanical 1 to 1024: Altium numbers mechanical layers past 32
    MAX_MECH_LAYERS = 1024;
    // DelphiScript marshals zero as nil in TList. Keep coordinates biased.
    KEEPOUT_COORD_BIAS = 100000000;
    KEEPOUT_DEGREES_TO_RADIANS = 0.017453292519943295;

// Nil-safe access to the current PCB board. When no PCB document has ever
// been opened this session, PCBServer itself is nil and calling
// GetCurrentPCBBoard on it throws an access violation that leaves the
// script paused in the debugger - silently blocking every later script run.
// All board lookups must go through this helper.
function GetBoardSafe(Dummy: Integer): IPCB_Board;
begin
    Result := nil;
    if (PCBServer <> nil) then
        Result := PCBServer.GetCurrentPCBBoard;
end;

// Nil-safe access to the current PCB library (same hazard as GetBoardSafe)
function GetPcbLibSafe(Dummy: Integer): IPCB_Library;
begin
    Result := nil;
    if (PCBServer <> nil) then
        Result := PCBServer.GetCurrentPCBLibrary;
end;

// Create many footprints in a single script run from a spec file (plain
// text, pipe-delimited; coords in mils, layers as names, shapes/hole types
// as raw enum ints - symmetric with get_footprint_primitives):
//   FPLIB|<path to .PcbLib>              (optional first line - focus/open)
//   FOOTPRINT|<name>|<description>
//   EDITFOOTPRINT|<name>                 add MODEL3D records to an existing
//                                        footprint (never creates one)
//   PAD|name|x|y|rot|layer|plated|hole_size|hole_type|hole_width|hole_rot|top_x|top_y|top_shape[|corner_pct[|mode|mid_x|mid_y|mid_shape|bot_x|bot_y|bot_shape[|paste_mode|paste_exp|mask_mode|mask_exp]]]
//       (mask modes are TMaskExpansionMode ints: 0 no mask, 1 rule, 2 manual;
//        every pad created is locked)
//   MODEL3D|<STEP file>|<layer>|<rot_x>|<rot_y>|<rot_z>|<z_offset>[|<x>|<y>[|<embed 1/0>]]
//   TRACK|x1|y1|x2|y2|width|layer
//   ARC|cx|cy|radius|start_angle|end_angle|width|layer
//   FILL|x1|y1|x2|y2|rotation|layer
//   TEXT|x|y|size|width|rotation|layer|mirror|ttf|text
function CreateFootprintsBatch(SpecFilePath: String): String;
var
    PcbLib      : IPCB_Library;
    LibComp     : IPCB_LibComponent;
    ServerDoc   : IServerDocument;
    Lines       : TStringList;
    FailedArray : TStringList;
    ResultProps : TStringList;
    Pad         : IPCB_Pad;
    Track       : IPCB_Track;
    Arc         : IPCB_Arc;
    Fill        : IPCB_Fill;
    Text        : IPCB_Text;
    Region      : IPCB_Region;
    Contour     : IPCB_Contour;
    Via         : IPCB_Via;
    Body        : IPCB_ComponentBody;
    Model       : IPCB_Model;
    Line, Kind  : String;
    LibPath     : String;
    FieldValue  : String;
    CurMode     : String;
    ModelPath   : String;
    CreatedCount: Integer;
    EditedCount : Integer;
    ModelCount  : Integer;
    PrimErrors  : Integer;
    OX, OY      : Integer;
    i, V        : Integer;
    Matched     : Boolean;
    Shown       : Boolean;
    Problems    : TStringList;


begin
    if not FileExists(SpecFilePath) then
    begin
        Result := 'ERROR: Spec file not found: ' + SpecFilePath;
        Exit;
    end;

    Lines := TStringList.Create;
    FailedArray := TStringList.Create;
    ResultProps := TStringList.Create;
    Problems := TStringList.Create;
    LibComp := nil;
    PcbLib := nil;
    CurMode := '';
    Shown := False;
    OX := 0;
    OY := 0;
    CreatedCount := 0;
    EditedCount := 0;
    ModelCount := 0;
    PrimErrors := 0;

    try
        Lines.LoadFromFile(SpecFilePath);

        // One undo step for the whole batch; this is also what marks the
        // library as modified (the user saves it)
        PCBServer.PreProcess;

        for i := 0 to Lines.Count - 1 do
        begin
            ReportProgress;
            Line := Lines[i];
            Kind := UpperCase(Trim(GetFieldFromPipeString(Line, 0)));

            try
                if (Kind = 'FPLIB') then
                begin
                    // Stop unless that library is now the focused one -
                    // never work on whatever else is focused
                    LibPath := Trim(GetFieldFromPipeString(Line, 1));
                    if FileExists(LibPath) then
                        ServerDoc := OpenLibraryDocument('PcbLib', LibPath);
                    PcbLib := GetPcbLibSafe(0);
                    Matched := False;
                    if (PcbLib <> nil) then
                        Matched := (NormalizedPath(PcbLib.Board.FileName) = NormalizedPath(LibPath));
                    if not Matched then
                    begin
                        PCBServer.PostProcess;
                        Result := 'ERROR: Could not open and focus ' + LibPath + ' - nothing was created';
                        Exit;
                    end;
                end
                else if (Kind = 'FOOTPRINT') or (Kind = 'EDITFOOTPRINT') then
                begin
                    PcbLib := GetPcbLibSafe(0);
                    // Focus can drift between chunks - retry via the opened
                    // document before giving up
                    if (PcbLib = nil) and (ServerDoc <> nil) then
                    begin
                        Client.ShowDocument(ServerDoc);
                        Sleep(1000);
                        PcbLib := GetPcbLibSafe(0);
                    end;
                    if (PcbLib = nil) then
                    begin
                        PCBServer.PostProcess;
                        Result := 'ERROR: No PCB library document is active';
                        Exit;
                    end;
                    CurMode := Kind;
                    OX := 0;
                    OY := 0;
                    Shown := False;
                    if (Kind = 'EDITFOOTPRINT') then
                    begin
                        LibComp := FindLibFootprint(PcbLib, Trim(GetFieldFromPipeString(Line, 1)));
                        if (LibComp = nil) then
                        begin
                            FailedArray.Add('"' + JSONEscapeString(Trim(GetFieldFromPipeString(Line, 1))) + '"');
                            Problems.Add('"' + JSONEscapeString(Trim(GetFieldFromPipeString(Line, 1)) +
                                ': not in the library (EDITFOOTPRINT never creates a footprint)') + '"');
                        end
                        else
                        begin
                            EditedCount := EditedCount + 1;
                            // The library board holds the footprint shown in
                            // the editor, in library coordinates (offset by the
                            // library origin), and writes it back to the
                            // footprint when another one is shown
                            if (PcbLib.CurrentComponent <> nil) then
                                if (PcbLib.CurrentComponent.I_ObjectAddress = LibComp.I_ObjectAddress) then
                                begin
                                    Shown := True;
                                    OX := PcbLib.Board.XOrigin;
                                    OY := PcbLib.Board.YOrigin;
                                end;
                        end;
                    end
                    else
                    begin
                        LibComp := PCBServer.CreatePCBLibComp;
                        LibComp.Name := Trim(GetFieldFromPipeString(Line, 1));
                        LibComp.Description := GetFieldFromPipeString(Line, 2);
                        PcbLib.RegisterComponent(LibComp);
                        PCBServer.SendMessageToRobots(PcbLib.Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, LibComp.I_ObjectAddress);
                        CreatedCount := CreatedCount + 1;
                    end;
                end
                else if (LibComp <> nil) and (Kind = 'MODEL3D') then
                begin
                    ModelPath := Trim(GetFieldFromPipeString(Line, 1));
                    if not FileExists(ModelPath) then
                        Problems.Add('"' + JSONEscapeString(LibComp.Name + ': 3D model file not found: ' + ModelPath) + '"')
                    else
                    begin
                        Body := PCBServer.PCBObjectFactory(eComponentBodyObject, eNoDimension, eCreate_Default);
                        Model := Body.ModelFactory_FromFilename(ModelPath, False);
                        if (Model = nil) then
                            Problems.Add('"' + JSONEscapeString(LibComp.Name + ': could not load 3D model ' + ModelPath) + '"')
                        else
                        begin
                            // Embedded unless the embed field is 0
                            if (Trim(GetFieldFromPipeString(Line, 9)) = '0') then
                                Model.Embed := False;
                            Model.SetState(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 3))),
                                           SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 4))),
                                           SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 5))),
                                           MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 6)))));
                            Body.Model := Model;
                            Body.SetState_FromModel;
                            Body.Layer := String2Layer(Trim(GetFieldFromPipeString(Line, 2)));
                            Body.MoveByXY(OX + MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 7)))),
                                          OY + MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 8)))));
                            // Added to the footprint itself, a body for the
                            // shown footprint is lost when another is shown
                            if Shown then
                            begin
                                PcbLib.Board.AddPCBObject(Body);
                                PCBServer.SendMessageToRobots(PcbLib.Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Body.I_ObjectAddress);
                            end
                            else
                            begin
                                LibComp.AddPCBObject(Body);
                                PCBServer.SendMessageToRobots(LibComp.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Body.I_ObjectAddress);
                            end;
                            ModelCount := ModelCount + 1;
                        end;
                    end;
                end
                else if (LibComp <> nil) and (CurMode = 'EDITFOOTPRINT') and (Kind <> '') then
                    Problems.Add('"' + JSONEscapeString('line ' + IntToStr(i + 1) + ': ' + Kind +
                        ' is ignored - only MODEL3D can be added to an existing footprint') + '"')
                else if (LibComp <> nil) and (Kind = 'PAD') then
                begin
                    Pad := PCBServer.PCBObjectFactory(ePadObject, eNoDimension, eCreate_Default);
                    // Pad name is NOT trimmed - round-trip fidelity preserves
                    // whitespace and even control characters found in source data
                    Pad.Name := GetFieldFromPipeString(Line, 1);
                    // Mode first so per-stack sizes land correctly
                    FieldValue := Trim(GetFieldFromPipeString(Line, 15));
                    if (FieldValue <> '') then
                        Pad.Mode := StrToInt(FieldValue)
                    else
                        Pad.Mode := ePadMode_Simple;
                    Pad.x := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 2))));
                    Pad.y := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 3))));
                    Pad.Layer := String2Layer(Trim(GetFieldFromPipeString(Line, 5)));
                    Pad.Plated := (Trim(GetFieldFromPipeString(Line, 6)) = '1');
                    Pad.HoleSize := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 7))));
                    Pad.HoleType := StrToInt(Trim(GetFieldFromPipeString(Line, 8)));
                    Pad.HoleWidth := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 9))));
                    Pad.HoleRotation := SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 10)));
                    Pad.TopXSize := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 11))));
                    Pad.TopYSize := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 12))));
                    Pad.TopShape := StrToInt(Trim(GetFieldFromPipeString(Line, 13)));
                    FieldValue := Trim(GetFieldFromPipeString(Line, 14));
                    if (FieldValue <> '') then
                        Pad.StackCRPctOnLayer[eTopLayer] := StrToInt(FieldValue);
                    if (Pad.Mode <> ePadMode_Simple) then
                    begin
                        Pad.MidXSize := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 16))));
                        Pad.MidYSize := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 17))));
                        Pad.MidShape := StrToInt(Trim(GetFieldFromPipeString(Line, 18)));
                        Pad.BotXSize := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 19))));
                        Pad.BotYSize := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 20))));
                        Pad.BotShape := StrToInt(Trim(GetFieldFromPipeString(Line, 21)));
                    end;
                    // Paste and solder mask expansion; omitted keeps the
                    // default (rule)
                    FieldValue := SetPadMaskExpansion(Pad, Trim(GetFieldFromPipeString(Line, 22)), Trim(GetFieldFromPipeString(Line, 23)),
                                                      Trim(GetFieldFromPipeString(Line, 24)), Trim(GetFieldFromPipeString(Line, 25)));
                    if (FieldValue <> '') then
                        Problems.Add('"' + JSONEscapeString(LibComp.Name + ' pad ' + Pad.Name + ': ' + FieldValue) + '"');
                    // Rotation last: it rotates the pad about its location
                    Pad.Rotation := SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 4)));
                    // Every pad the tool creates is locked
                    Pad.Moveable := False;
                    LibComp.AddPCBObject(Pad);
                    PCBServer.SendMessageToRobots(LibComp.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Pad.I_ObjectAddress);
                end
                else if (LibComp <> nil) and (Kind = 'TRACK') then
                begin
                    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
                    Track.x1 := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 1))));
                    Track.y1 := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 2))));
                    Track.x2 := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 3))));
                    Track.y2 := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 4))));
                    Track.Width := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 5))));
                    Track.Layer := String2Layer(Trim(GetFieldFromPipeString(Line, 6)));
                    LibComp.AddPCBObject(Track);
                    PCBServer.SendMessageToRobots(LibComp.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Track.I_ObjectAddress);
                end
                else if (LibComp <> nil) and (Kind = 'ARC') then
                begin
                    Arc := PCBServer.PCBObjectFactory(eArcObject, eNoDimension, eCreate_Default);
                    Arc.XCenter := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 1))));
                    Arc.YCenter := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 2))));
                    Arc.Radius := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 3))));
                    Arc.StartAngle := SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 4)));
                    Arc.EndAngle := SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 5)));
                    Arc.LineWidth := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 6))));
                    Arc.Layer := String2Layer(Trim(GetFieldFromPipeString(Line, 7)));
                    LibComp.AddPCBObject(Arc);
                    PCBServer.SendMessageToRobots(LibComp.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Arc.I_ObjectAddress);
                end
                else if (LibComp <> nil) and (Kind = 'FILL') then
                begin
                    Fill := PCBServer.PCBObjectFactory(eFillObject, eNoDimension, eCreate_Default);
                    Fill.x1Location := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 1))));
                    Fill.y1Location := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 2))));
                    Fill.x2Location := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 3))));
                    Fill.y2Location := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 4))));
                    Fill.Rotation := SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 5)));
                    Fill.Layer := String2Layer(Trim(GetFieldFromPipeString(Line, 6)));
                    LibComp.AddPCBObject(Fill);
                    PCBServer.SendMessageToRobots(LibComp.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Fill.I_ObjectAddress);
                end
                else if (LibComp <> nil) and (Kind = 'VIA') then
                begin
                    Via := PCBServer.PCBObjectFactory(eViaObject, eNoDimension, eCreate_Default);
                    Via.x := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 1))));
                    Via.y := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 2))));
                    Via.Size := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 3))));
                    Via.HoleSize := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 4))));
                    Via.LowLayer := String2Layer(Trim(GetFieldFromPipeString(Line, 5)));
                    Via.HighLayer := String2Layer(Trim(GetFieldFromPipeString(Line, 6)));
                    LibComp.AddPCBObject(Via);
                    PCBServer.SendMessageToRobots(LibComp.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Via.I_ObjectAddress);
                end
                else if (LibComp <> nil) and (Kind = 'REGION') then
                begin
                    Region := PCBServer.PCBObjectFactory(eRegionObject, eNoDimension, eCreate_Default);
                    Contour := PCBServer.PCBContourFactory;
                    V := 3;
                    while (Trim(GetFieldFromPipeString(Line, V)) <> '') do
                    begin
                        Contour.AddPoint(MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, V)))),
                                         MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, V + 1)))));
                        V := V + 2;
                    end;
                    Region.SetOutlineContour(Contour);
                    Region.Layer := String2Layer(Trim(GetFieldFromPipeString(Line, 1)));
                    Region.Kind := StrToInt(Trim(GetFieldFromPipeString(Line, 2)));
                    LibComp.AddPCBObject(Region);
                    PCBServer.SendMessageToRobots(LibComp.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Region.I_ObjectAddress);
                end
                else if (LibComp <> nil) and (Kind = 'TEXT') then
                begin
                    Text := PCBServer.PCBObjectFactory(eTextObject, eNoDimension, eCreate_Default);
                    Text.XLocation := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 1))));
                    Text.YLocation := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 2))));
                    Text.Size := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 3))));
                    Text.Width := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 4))));
                    Text.Layer := String2Layer(Trim(GetFieldFromPipeString(Line, 6)));
                    Text.MirrorFlag := (Trim(GetFieldFromPipeString(Line, 7)) = '1');
                    Text.UseTTFonts := (Trim(GetFieldFromPipeString(Line, 8)) = '1');
                    // <NL> placeholder carries embedded newlines through the
                    // line-based spec file
                    Text.Text := StringReplace(GetFieldFromPipeString(Line, 9), '<NL>', #13#10, REPLACEALL);
                    Text.Rotation := SafeStrToFloat(Trim(GetFieldFromPipeString(Line, 5)));
                    LibComp.AddPCBObject(Text);
                    PCBServer.SendMessageToRobots(LibComp.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Text.I_ObjectAddress);
                end;
            except
                PrimErrors := PrimErrors + 1;
                if (Kind = 'FOOTPRINT') then
                    FailedArray.Add('"' + JSONEscapeString(Trim(GetFieldFromPipeString(Line, 1))) + '"');
            end;
        end;

        PCBServer.PostProcess;
        if (LibComp <> nil) and (PcbLib <> nil) then
        begin
            PcbLib.CurrentComponent := LibComp;
            PcbLib.Board.ViewManager_FullUpdate;
        end;
        if (CreatedCount + EditedCount > 0) and (PcbLib <> nil) then
            MarkDocumentModified(PcbLib.Board.FileName);

        AddJSONInteger(ResultProps, 'created', CreatedCount);
        AddJSONInteger(ResultProps, 'edited', EditedCount);
        AddJSONInteger(ResultProps, 'models_added', ModelCount);
        AddJSONInteger(ResultProps, 'primitive_errors', PrimErrors);
        if (FailedArray.Count > 0) then
            ResultProps.Add(BuildJSONArray(FailedArray, 'failed'))
        else
            ResultProps.Add('"failed": []');
        if (Problems.Count > 0) then
            ResultProps.Add(BuildJSONArray(Problems, 'problems'))
        else
            ResultProps.Add('"problems": []');

        Result := BuildJSONObject(ResultProps);
    finally
        Lines.Free;
        FailedArray.Free;
        ResultProps.Free;
        Problems.Free;
    end;
end;

// Get the graphic/copper primitives of footprints in a PCB library.
// FootprintName = '' -> inventory (per-footprint primitive counts);
// '*' -> full dump of every footprint; name -> dump that footprint.
// Coordinates in mils, layers as names, shapes/hole types as raw enum ints
// (pass-through symmetric with create_footprints_batch).
function GetFootprintPrimitives(ROOT_DIR: String; LibraryPath: String; FootprintName: String): String;
var
    PcbLib      : IPCB_Library;
    LibComp     : IPCB_LibComponent;
    GrpIter     : IPCB_GroupIterator;
    Prim        : IPCB_Primitive;
    ServerDoc   : IServerDocument;
    ResultProps : TStringList;
    FPArray     : TStringList;
    FPProps     : TStringList;
    PrimsArray  : TStringList;
    PrimProps   : TStringList;
    PointsArray : TStringList;
    PProps      : TStringList;
    Counts      : TStringList;
    OutputLines : TStringList;
    TypeName    : String;
    i, C, V     : Integer;
    Found       : Boolean;
    BodiesArray : TStringList;
    BodyProps   : TStringList;
    Model       : IPCB_Model;
    OX, OY      : Integer;
begin
    Result := '';

    if (LibraryPath <> '') then
    begin
        if not FileExists(LibraryPath) then
        begin
            Result := 'ERROR: Library file not found: ' + LibraryPath;
            Exit;
        end;
        // Never re-open an open document (reload discards unsaved changes)
        ServerDoc := OpenLibraryDocument('PcbLib', LibraryPath);
        if ServerDoc = Nil then
        begin
            Result := 'ERROR: Failed to open library: ' + LibraryPath;
            Exit;
        end;
    end;

    PcbLib := GetPcbLibSafe(0);
    if (PcbLib = nil) then
    begin
        Result := 'ERROR: No PCB library is open (provide library_path or open a .PcbLib)';
        Exit;
    end;

    ResultProps := TStringList.Create;
    FPArray := TStringList.Create;
    Found := False;

    try
        AddJSONProperty(ResultProps, 'library_name', ExtractFileName(PcbLib.Board.FileName));
        AddJSONProperty(ResultProps, 'library_path', PcbLib.Board.FileName);

        for C := 0 to PcbLib.ComponentCount - 1 do
        begin
            LibComp := PcbLib.GetComponent(C);

            if (FootprintName = '') then
            begin
                // Inventory mode
                Counts := TStringList.Create;
                FPProps := TStringList.Create;
                try
                    GrpIter := LibComp.GroupIterator_Create;
                    Prim := GrpIter.FirstPCBObject;
                    while (Prim <> nil) do
                    begin
                        case Prim.ObjectId of
                            ePadObject:           TypeName := 'pads';
                            eTrackObject:         TypeName := 'tracks';
                            eArcObject:           TypeName := 'arcs';
                            eFillObject:          TypeName := 'fills';
                            eTextObject:          TypeName := 'texts';
                            eRegionObject:        TypeName := 'regions';
                            eViaObject:           TypeName := 'vias';
                            eComponentBodyObject: TypeName := 'component_bodies';
                        else
                            TypeName := 'other';
                        end;
                        i := Counts.IndexOfName(TypeName);
                        if (i < 0) then
                            Counts.Add(TypeName + '=1')
                        else
                            Counts[i] := TypeName + '=' + IntToStr(StrToInt(Counts.ValueFromIndex[i]) + 1);
                        Prim := GrpIter.NextPCBObject;
                    end;
                    LibComp.GroupIterator_Destroy(GrpIter);

                    AddJSONProperty(FPProps, 'name', LibComp.Name);
                    AddJSONProperty(FPProps, 'description', LibComp.Description);
                    for i := 0 to Counts.Count - 1 do
                        AddJSONInteger(FPProps, Counts.Names[i], StrToInt(Counts.ValueFromIndex[i]));
                    FPArray.Add(BuildJSONObject(FPProps, 1));
                finally
                    Counts.Free;
                    FPProps.Free;
                end;
            end
            else if (FootprintName = '*') or (UpperCase(LibComp.Name) = UpperCase(FootprintName)) then
            begin
                // Dump mode
                Found := True;
                FPProps := TStringList.Create;
                PrimsArray := TStringList.Create;
                BodiesArray := TStringList.Create;
                try
                    AddJSONProperty(FPProps, 'footprint_name', LibComp.Name);
                    AddJSONProperty(FPProps, 'description', LibComp.Description);

                    // The footprint shown in the editor is held in library
                    // coordinates, offset by the library origin; report every
                    // footprint relative to its own origin
                    OX := 0;
                    OY := 0;
                    if (PcbLib.CurrentComponent <> nil) then
                        if (PcbLib.CurrentComponent.I_ObjectAddress = LibComp.I_ObjectAddress) then
                        begin
                            OX := PcbLib.Board.XOrigin;
                            OY := PcbLib.Board.YOrigin;
                        end;

                    GrpIter := LibComp.GroupIterator_Create;
                    Prim := GrpIter.FirstPCBObject;
                    while (Prim <> nil) do
                    begin
                        PrimProps := TStringList.Create;
                        try
                          // Armor: an unreadable primitive degrades to a
                          // reported entry instead of crashing the script
                          try
                            case Prim.ObjectId of
                                ePadObject:
                                begin
                                    AddJSONProperty(PrimProps, 'type', 'pad');
                                    AddJSONProperty(PrimProps, 'name', Prim.Name);
                                    AddJSONNumber(PrimProps, 'x', CoordToMils(Prim.x - OX));
                                    AddJSONNumber(PrimProps, 'y', CoordToMils(Prim.y - OY));
                                    AddJSONNumber(PrimProps, 'rotation', Prim.Rotation);
                                    AddJSONProperty(PrimProps, 'layer', Layer2String(Prim.Layer));
                                    AddJSONBoolean(PrimProps, 'plated', Prim.Plated);
                                    AddJSONInteger(PrimProps, 'mode', Prim.Mode);
                                    AddJSONNumber(PrimProps, 'top_x_size', CoordToMils(Prim.TopXSize));
                                    AddJSONNumber(PrimProps, 'top_y_size', CoordToMils(Prim.TopYSize));
                                    AddJSONInteger(PrimProps, 'top_shape', Prim.TopShape);
                                    AddJSONNumber(PrimProps, 'hole_size', CoordToMils(Prim.HoleSize));
                                    AddJSONInteger(PrimProps, 'hole_type', Prim.HoleType);
                                    AddJSONNumber(PrimProps, 'hole_width', CoordToMils(Prim.HoleWidth));
                                    AddJSONNumber(PrimProps, 'hole_rotation', Prim.HoleRotation);
                                    if (Prim.Mode <> ePadMode_Simple) then
                                    begin
                                        AddJSONNumber(PrimProps, 'mid_x_size', CoordToMils(Prim.MidXSize));
                                        AddJSONNumber(PrimProps, 'mid_y_size', CoordToMils(Prim.MidYSize));
                                        AddJSONInteger(PrimProps, 'mid_shape', Prim.MidShape);
                                        AddJSONNumber(PrimProps, 'bot_x_size', CoordToMils(Prim.BotXSize));
                                        AddJSONNumber(PrimProps, 'bot_y_size', CoordToMils(Prim.BotYSize));
                                        AddJSONInteger(PrimProps, 'bot_shape', Prim.BotShape);
                                    end;
                                    if (Prim.TopShape = eRoundedRectangular) then
                                        AddJSONInteger(PrimProps, 'corner_pct', Prim.StackCRPctOnLayer[eTopLayer]);
                                    AddJSONInteger(PrimProps, 'paste_mode', Prim.PasteMaskExpansionMode);
                                    AddJSONNumber(PrimProps, 'paste_expansion', CoordToMils(Prim.PasteMaskExpansion));
                                    AddJSONInteger(PrimProps, 'mask_mode', Prim.SolderMaskExpansionMode);
                                    AddJSONNumber(PrimProps, 'mask_expansion', CoordToMils(Prim.SolderMaskExpansion));
                                    AddJSONBoolean(PrimProps, 'locked', not Prim.Moveable);
                                end;
                                eTrackObject:
                                begin
                                    AddJSONProperty(PrimProps, 'type', 'track');
                                    AddJSONNumber(PrimProps, 'x1', CoordToMils(Prim.x1 - OX));
                                    AddJSONNumber(PrimProps, 'y1', CoordToMils(Prim.y1 - OY));
                                    AddJSONNumber(PrimProps, 'x2', CoordToMils(Prim.x2 - OX));
                                    AddJSONNumber(PrimProps, 'y2', CoordToMils(Prim.y2 - OY));
                                    AddJSONNumber(PrimProps, 'width', CoordToMils(Prim.Width));
                                    AddJSONProperty(PrimProps, 'layer', Layer2String(Prim.Layer));
                                end;
                                eArcObject:
                                begin
                                    AddJSONProperty(PrimProps, 'type', 'arc');
                                    AddJSONNumber(PrimProps, 'cx', CoordToMils(Prim.XCenter - OX));
                                    AddJSONNumber(PrimProps, 'cy', CoordToMils(Prim.YCenter - OY));
                                    AddJSONNumber(PrimProps, 'radius', CoordToMils(Prim.Radius));
                                    AddJSONNumber(PrimProps, 'start_angle', Prim.StartAngle);
                                    AddJSONNumber(PrimProps, 'end_angle', Prim.EndAngle);
                                    AddJSONNumber(PrimProps, 'width', CoordToMils(Prim.LineWidth));
                                    AddJSONProperty(PrimProps, 'layer', Layer2String(Prim.Layer));
                                end;
                                eFillObject:
                                begin
                                    AddJSONProperty(PrimProps, 'type', 'fill');
                                    AddJSONNumber(PrimProps, 'x1', CoordToMils(Prim.x1Location - OX));
                                    AddJSONNumber(PrimProps, 'y1', CoordToMils(Prim.y1Location - OY));
                                    AddJSONNumber(PrimProps, 'x2', CoordToMils(Prim.x2Location - OX));
                                    AddJSONNumber(PrimProps, 'y2', CoordToMils(Prim.y2Location - OY));
                                    AddJSONNumber(PrimProps, 'rotation', Prim.Rotation);
                                    AddJSONProperty(PrimProps, 'layer', Layer2String(Prim.Layer));
                                end;
                                eTextObject:
                                begin
                                    AddJSONProperty(PrimProps, 'type', 'text');
                                    AddJSONProperty(PrimProps, 'text', Prim.Text);
                                    AddJSONNumber(PrimProps, 'x', CoordToMils(Prim.XLocation - OX));
                                    AddJSONNumber(PrimProps, 'y', CoordToMils(Prim.YLocation - OY));
                                    AddJSONNumber(PrimProps, 'size', CoordToMils(Prim.Size));
                                    AddJSONNumber(PrimProps, 'width', CoordToMils(Prim.Width));
                                    AddJSONNumber(PrimProps, 'rotation', Prim.Rotation);
                                    AddJSONProperty(PrimProps, 'layer', Layer2String(Prim.Layer));
                                    AddJSONBoolean(PrimProps, 'mirror', Prim.MirrorFlag);
                                    AddJSONBoolean(PrimProps, 'ttf', Prim.UseTTFonts);
                                end;
                                eRegionObject:
                                begin
                                    AddJSONProperty(PrimProps, 'type', 'region');
                                    AddJSONProperty(PrimProps, 'layer', Layer2String(Prim.Layer));
                                    AddJSONInteger(PrimProps, 'kind', Prim.Kind);
                                    PointsArray := TStringList.Create;
                                    try
                                        for V := 1 to Prim.MainContour.Count do
                                        begin
                                            PProps := TStringList.Create;
                                            try
                                                AddJSONNumber(PProps, 'x', CoordToMils(Prim.MainContour.x[V] - OX));
                                                AddJSONNumber(PProps, 'y', CoordToMils(Prim.MainContour.y[V] - OY));
                                                PointsArray.Add(BuildJSONObject(PProps, 3));
                                            finally
                                                PProps.Free;
                                            end;
                                        end;
                                        PrimProps.Add(BuildJSONArray(PointsArray, 'vertices', 2));
                                    finally
                                        PointsArray.Free;
                                    end;
                                    AddJSONInteger(PrimProps, 'hole_count', Prim.HoleCount);
                                end;
                                eViaObject:
                                begin
                                    AddJSONProperty(PrimProps, 'type', 'via');
                                    AddJSONNumber(PrimProps, 'x', CoordToMils(Prim.x - OX));
                                    AddJSONNumber(PrimProps, 'y', CoordToMils(Prim.y - OY));
                                    AddJSONNumber(PrimProps, 'size', CoordToMils(Prim.Size));
                                    AddJSONNumber(PrimProps, 'hole_size', CoordToMils(Prim.HoleSize));
                                    AddJSONProperty(PrimProps, 'low_layer', Layer2String(Prim.LowLayer));
                                    AddJSONProperty(PrimProps, 'high_layer', Layer2String(Prim.HighLayer));
                                end;
                                eComponentBodyObject:
                                begin
                                    // 3D bodies are models, not 2D primitives:
                                    // reported apart, so the graphics
                                    // round-trip is unchanged. The model's
                                    // rotations and Z offset are added by the
                                    // server from the saved file:
                                    // Model.GetState returns them through out
                                    // parameters, which DelphiScript never
                                    // receives.
                                    AddJSONProperty(PrimProps, 'type', '');
                                    BodyProps := TStringList.Create;
                                    try
                                        Model := Prim.Model;
                                        if (Model <> nil) then
                                        begin
                                            AddJSONProperty(BodyProps, 'model_file', Model.FileName);
                                            AddJSONBoolean(BodyProps, 'model_embedded', Model.Embed);
                                            AddJSONNumber(BodyProps, 'model_x', CoordToMils(Model.Origin.X - OX));
                                            AddJSONNumber(BodyProps, 'model_y', CoordToMils(Model.Origin.Y - OY));
                                        end
                                        else
                                            AddJSONProperty(BodyProps, 'model_file', '');
                                        AddJSONNumber(BodyProps, 'standoff_height', CoordToMils(Prim.StandoffHeight));
                                        AddJSONNumber(BodyProps, 'overall_height', CoordToMils(Prim.OverallHeight));
                                        AddJSONProperty(BodyProps, 'layer', Layer2String(Prim.Layer));
                                        BodiesArray.Add(BuildJSONObject(BodyProps, 2));
                                    finally
                                        BodyProps.Free;
                                    end;
                                end;
                            else
                            begin
                                AddJSONProperty(PrimProps, 'type', 'unknown');
                                AddJSONInteger(PrimProps, 'object_id', Prim.ObjectId);
                            end;
                            end;

                            if (PrimProps.Count > 0) then
                                if (Pos('"type": ""', PrimProps[0]) = 0) then
                                    PrimsArray.Add(BuildJSONObject(PrimProps, 1));
                          except
                            PrimProps.Clear;
                            AddJSONProperty(PrimProps, 'type', 'unreadable');
                            PrimsArray.Add(BuildJSONObject(PrimProps, 1));
                          end;
                        finally
                            PrimProps.Free;
                        end;

                        Prim := GrpIter.NextPCBObject;
                    end;
                    LibComp.GroupIterator_Destroy(GrpIter);

                    FPProps.Add(BuildJSONArray(PrimsArray, 'primitives', 1));
                    if (BodiesArray.Count > 0) then
                        FPProps.Add(BuildJSONArray(BodiesArray, 'bodies_3d', 1))
                    else
                        FPProps.Add('"bodies_3d": []');

                    if (FootprintName = '*') then
                        FPArray.Add(BuildJSONObject(FPProps, 1))
                    else
                        for i := 0 to FPProps.Count - 1 do
                            ResultProps.Add(FPProps[i]);
                finally
                    FPProps.Free;
                    PrimsArray.Free;
                    BodiesArray.Free;
                end;
            end;
        end;

        if (FootprintName = '') or (FootprintName = '*') then
        begin
            AddJSONInteger(ResultProps, 'footprint_count', FPArray.Count);
            ResultProps.Add(BuildJSONArray(FPArray, 'footprints', 1));
        end
        else if not Found then
        begin
            Result := 'ERROR: Footprint not found in library: ' + FootprintName;
            Exit;
        end;

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := WriteJSONToFile(OutputLines, ROOT_DIR + '\temp_footprint_primitives.json');
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
        FPArray.Free;
    end;
end;


// Function to get all unique net names from the current PCB document
function GetAllNets(ROOT_DIR: String): String;
var
    Board       : IPCB_Board;
    Net         : IPCB_Net;
    Iterator    : IPCB_BoardIterator;
    NetsArray   : TStringList; 
    OutputLines : TStringList;
begin
    // Initialize empty array result in case no board is found
    Result := '[]';
    
    // Retrieve the current board
    Board := GetBoardSafe(0);
    if Board = nil then Exit;

    // Create array for storing unique nets
    NetsArray := TStringList.Create;
    // Set Duplicates property to prevent duplicate net names
    NetsArray.Duplicates := dupIgnore;
    NetsArray.Sorted := True;
    
    try
        // Create the iterator that will look for Net objects only
        Iterator := Board.BoardIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(eNetObject));
        Iterator.AddFilter_LayerSet(AllLayers);
        Iterator.AddFilter_Method(eProcessAll);

        // Search for Net objects and get their Net Name values
        Net := Iterator.FirstPCBObject;
        while (Net <> nil) do
        begin
            // Add each net name to the list, duplicates will be ignored
            NetsArray.Add('"' + JSONEscapeString(Net.Name) + '"');
            Net := Iterator.NextPCBObject;
        end;
        Board.BoardIterator_Destroy(Iterator);
        
        // Build the final JSON array
        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONArray(NetsArray);
            Result := WriteJSONToFile(OutputLines, ROOT_DIR+'\temp_nets_data.json');
        finally
            OutputLines.Free;
        end;
    finally
        NetsArray.Free;
    end;
end;

// Function to create a net class and add nets to it
function CreateNetClass(ClassName: String; NetNames: TStringList): String;
var
    Board       : IPCB_Board;
    ClassExists : Boolean;
    NetClass    : IPCB_ObjectClass;
    ClassIterator : IPCB_BoardIterator;
    i           : Integer;
    ResultProps : TStringList;
    AddedCount  : Integer;
    BoardNets   : TStringList;
    Members     : TStringList;
    NotFound    : TStringList;
    Net         : IPCB_Net;
    NetIterator : IPCB_BoardIterator;
    NetIndex    : Integer;
    OutputLines : TStringList;
begin
    // Initialize result
    ResultProps := TStringList.Create;
    BoardNets := TStringList.Create;
    Members := TStringList.Create;
    NotFound := TStringList.Create;
    AddedCount := 0;
    ClassExists := False;
    
    try
        // Retrieve the current board
        Board := GetBoardSafe(0);
        if (Board = nil) then
        begin
            AddJSONBoolean(ResultProps, 'success', False);
            AddJSONProperty(ResultProps, 'error', 'No PCB document is currently active');
            
            OutputLines := TStringList.Create;
            try
                OutputLines.Text := BuildJSONObject(ResultProps);
                Result := OutputLines.Text;
            finally
                OutputLines.Free;
            end;
            Exit;
        end;
        
        // Search for existing class with the same name
        ClassIterator := Board.BoardIterator_Create;
        ClassIterator.SetState_FilterAll;
        ClassIterator.AddFilter_ObjectSet(MkSet(eClassObject));
        
        NetClass := ClassIterator.FirstPCBObject;
        while (NetClass <> nil) do
        begin
            if (NetClass.MemberKind = eClassMemberKind_Net) and (NetClass.Name = ClassName) then
            begin
                ClassExists := True;
                Break;
            end;
            NetClass := ClassIterator.NextPCBObject;
        end;
        
        // If class doesn't exist, create it
        if not ClassExists then
        begin
            PCBServer.PreProcess;
            NetClass := PCBServer.PCBClassFactoryByClassMember(eClassMemberKind_Net);
            NetClass.SuperClass := False;
            NetClass.Name := ClassName;
            Board.AddPCBObject(NetClass);
            PCBServer.PostProcess;
        end;
        
        // AddMemberByName returns nothing and takes any name, and IsMember
        // takes a net object: compare names. A net already in the class is
        // skipped (AddMemberByName would list it twice), and so is a name
        // the board has no net for.
        NetIterator := Board.BoardIterator_Create;
        NetIterator.AddFilter_ObjectSet(MkSet(eNetObject));
        NetIterator.AddFilter_LayerSet(AllLayers);
        NetIterator.AddFilter_Method(eProcessAll);
        Net := NetIterator.FirstPCBObject;
        while (Net <> nil) do
        begin
            BoardNets.Add(Net.Name);
            Net := NetIterator.NextPCBObject;
        end;
        Board.BoardIterator_Destroy(NetIterator);

        i := 0;
        while (NetClass.MemberName[i] <> '') do
        begin
            Members.Add(NetClass.MemberName[i]);
            i := i + 1;
        end;

        // Add nets to the class
        PCBServer.PreProcess;
        for i := 0 to NetNames.Count - 1 do
        begin
            NetIndex := BoardNets.IndexOf(NetNames[i]);
            if (NetIndex < 0) then
                NotFound.Add('"' + JSONEscapeString(NetNames[i]) + '"')
            else if (Members.IndexOf(BoardNets[NetIndex]) < 0) then
            begin
                NetClass.AddMemberByName(BoardNets[NetIndex]);
                Members.Add(BoardNets[NetIndex]);
                AddedCount := AddedCount + 1;
            end;
        end;
        PCBServer.PostProcess;
        
        // Clean up iterator
        Board.BoardIterator_Destroy(ClassIterator);
        
        // Build result JSON
        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'class_name', ClassName);
        AddJSONBoolean(ResultProps, 'class_created', not ClassExists);
        AddJSONInteger(ResultProps, 'nets_added', AddedCount);
        if (NotFound.Count > 0) then
            ResultProps.Add(BuildJSONArray(NotFound, 'nets_not_found'))
        else
            ResultProps.Add('"nets_not_found": []');
        
        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
        BoardNets.Free;
        Members.Free;
        NotFound.Free;
    end;
end;

// Function to get detailed layer stackup information
function GetPCBLayerStackup(ROOT_DIR): String;
var
    Board           : IPCB_Board;
    LayerIterator   : IPCB_LayerObjectIterator;
    LayerObject     : IPCB_LayerObject;
    StackupArray    : TStringList;
    LayerProps      : TStringList;
    OutputLines     : TStringList;
    TotalThickness  : Double;
    LayerCount      : Integer;
begin
    Result := '';

    // Retrieve the current board
    Board := GetBoardSafe(0);
    if (Board = nil) then
    begin
        Result := '{"error": "No PCB document is currently active"}';
        Exit;
    end;

    // Create arrays for stackup data
    StackupArray := TStringList.Create;
    TotalThickness := 0;
    LayerCount := 0;
    
    try
        // Get the electrical layer iterator
        LayerIterator := Board.ElectricalLayerIterator;
        
        // Process each electrical layer
        while LayerIterator.Next do
        begin
            LayerObject := LayerIterator.LayerObject;
            
            // Create layer properties
            LayerProps := TStringList.Create;
            try
                // Basic layer information
                AddJSONProperty(LayerProps, 'layer_name', LayerObject.Name);
                AddJSONProperty(LayerProps, 'layer_id', Layer2String(LayerObject.LayerID));
                AddJSONProperty(LayerProps, 'material_type', 'Copper');
                AddJSONNumber(LayerProps, 'copper_thickness_mils', LayerObject.CopperThickness / 10000);
                AddJSONNumber(LayerProps, 'copper_thickness_um', LayerObject.CopperThickness * 0.00254);
                
                // Add copper thickness to total
                TotalThickness := TotalThickness + (LayerObject.CopperThickness / 10000);
                
                // Dielectric information (if present)
                if LayerObject.Dielectric.DielectricType <> eNoDielectric then
                begin
                    case LayerObject.Dielectric.DielectricType of
                        eCore: AddJSONProperty(LayerProps, 'dielectric_type', 'Core');
                        ePrePreg: AddJSONProperty(LayerProps, 'dielectric_type', 'PrePreg');
                        eSurfaceMaterial: AddJSONProperty(LayerProps, 'dielectric_type', 'Surface Material');
                    else
                        AddJSONProperty(LayerProps, 'dielectric_type', 'Unknown');
                    end;
                    
                    AddJSONProperty(LayerProps, 'dielectric_material', LayerObject.Dielectric.DielectricMaterial);
                    AddJSONNumber(LayerProps, 'dielectric_height_mils', LayerObject.Dielectric.DielectricHeight / 10000);
                    AddJSONNumber(LayerProps, 'dielectric_height_um', LayerObject.Dielectric.DielectricHeight * 0.00254);
                    AddJSONNumber(LayerProps, 'dielectric_constant', LayerObject.Dielectric.DielectricConstant);
                    
                    // Add dielectric thickness to total
                    TotalThickness := TotalThickness + (LayerObject.Dielectric.DielectricHeight / 10000);
                end
                else
                begin
                    AddJSONProperty(LayerProps, 'dielectric_type', 'No Dielectric');
                    AddJSONProperty(LayerProps, 'dielectric_material', '');
                    AddJSONNumber(LayerProps, 'dielectric_height_mils', 0);
                    AddJSONNumber(LayerProps, 'dielectric_height_um', 0);
                    AddJSONNumber(LayerProps, 'dielectric_constant', 0);
                end;
                
                // Add layer order
                AddJSONInteger(LayerProps, 'layer_order', LayerCount + 1);
                
                // Add to stackup array
                StackupArray.Add(BuildJSONObject(LayerProps, 1));
                LayerCount := LayerCount + 1;
            finally
                LayerProps.Free;
            end;
        end;
        
        // Create final stackup object with summary
        LayerProps := TStringList.Create;
        try
            AddJSONInteger(LayerProps, 'total_layers', LayerCount);
            AddJSONNumber(LayerProps, 'total_thickness_mils', TotalThickness);
            AddJSONNumber(LayerProps, 'total_thickness_mm', TotalThickness * 0.0254);
            AddJSONProperty(LayerProps, 'board_name', ExtractFileName(Board.FileName));
            
            // Add the layers array
            LayerProps.Add(BuildJSONArray(StackupArray, 'layers'));
            
            // Build the final JSON
            OutputLines := TStringList.Create;
            try
                OutputLines.Text := BuildJSONObject(LayerProps);
                Result := WriteJSONToFile(OutputLines, ROOT_DIR+'\temp_stackup_data.json');
            finally
                OutputLines.Free;
            end;
        finally
            LayerProps.Free;
        end;
    finally
        StackupArray.Free;
    end;
end;

// Function to get all layer information from the PCB
function GetPCBLayers(ROOT_DIR: String): String;
var
    Board           : IPCB_Board;
    TheLayerStack   : IPCB_LayerStack_V7;
    LayerObj        : IPCB_LayerObject;
    MechLayer       : IPCB_MechanicalLayer;
    AllLayersArray  : TStringList;
    CopperArray     : TStringList;
    MechArray       : TStringList;
    OtherArray      : TStringList;
    LayerProps      : TStringList;
    i               : Integer;
    OutputLines     : TStringList;
begin
    Result := '';

    // Retrieve the current board
    Board := GetBoardSafe(0);
    if (Board = nil) then
    begin
        Result := '[]';
        Exit;
    end;
    
    // Get the layer stack
    TheLayerStack := Board.LayerStack_V7;
    if (TheLayerStack = nil) then
    begin
        Result := '[]';
        Exit;
    end;

    // Create arrays for different layer categories
    AllLayersArray := TStringList.Create;
    CopperArray := TStringList.Create;
    MechArray := TStringList.Create;
    OtherArray := TStringList.Create;
    
    try
        // Process copper (electrical) layers
        LayerObj := TheLayerStack.FirstLayer;
        while (LayerObj <> nil) do
        begin
            // Create layer properties
            LayerProps := TStringList.Create;
            try
                // Add properties
                AddJSONProperty(LayerProps, 'name', LayerObj.Name);
                AddJSONProperty(LayerProps, 'layer_id', IntToStr(LayerObj.V6_LayerID));
                AddJSONProperty(LayerProps, 'layer_type', 'copper');

                if LayerSet.SignalLayers.Contains(LayerObj.V6_LayerID) then
                    AddJSONProperty(LayerProps, 'is_signal', 'true', False)
                else
                    AddJSONProperty(LayerProps, 'is_signal', 'false', False);

                if not LayerSet.SignalLayers.Contains(LayerObj.V6_LayerID) then
                    AddJSONProperty(LayerProps, 'is_plane', 'true', False)
                else
                    AddJSONProperty(LayerProps, 'is_plane', 'false', False);

                AddJSONBoolean(LayerProps, 'is_displayed', LayerObj.IsDisplayed[Board]);
                AddJSONBoolean(LayerProps, 'is_enabled', True);
                AddJSONProperty(LayerProps, 'color', ColorToString(Board.LayerColor[LayerObj.LayerID]));
                
                // Add to copper array
                CopperArray.Add(BuildJSONObject(LayerProps, 1));
            finally
                LayerProps.Free;
            end;
            
            LayerObj := TheLayerStack.NextLayer(LayerObj);
        end;
        
        // Process mechanical layers. Keyed by the layer number: V6 ids only
        // reach Mechanical 16, and every layer above reads 72 (#32)
        for i := 1 to MAX_MECH_LAYERS do
        begin
            MechLayer := TheLayerStack.LayerObject_V7[ILayer.MechanicalLayer(i)];

            if (MechLayer <> nil) and MechLayer.MechanicalLayerEnabled then
            begin
                // Create layer properties
                LayerProps := TStringList.Create;
                try
                    // Add properties
                    AddJSONProperty(LayerProps, 'name', MechLayer.Name);
                    AddJSONProperty(LayerProps, 'layer_id', IntToStr(ILayer.MechanicalLayer(i)));
                    AddJSONProperty(LayerProps, 'layer_type', 'mechanical');
                    AddJSONProperty(LayerProps, 'mechanical_number', IntToStr(i));
                    AddJSONBoolean(LayerProps, 'is_displayed', MechLayer.IsDisplayed[Board]);
                    AddJSONBoolean(LayerProps, 'is_enabled', MechLayer.MechanicalLayerEnabled);
                    AddJSONBoolean(LayerProps, 'link_to_sheet', MechLayer.LinkToSheet);
                    AddJSONBoolean(LayerProps, 'is_paired', Board.MechanicalPairs.LayerUsed(ILayer.MechanicalLayer(i)));
                    AddJSONProperty(LayerProps, 'color', ColorToString(PCBServer.SystemOptions.LayerColors[ILayer.MechanicalLayer(i)]));
                    
                    // If layer is paired, add the pair information
                    if Board.MechanicalPairs.LayerUsed(ILayer.MechanicalLayer(i)) then
                    begin
                        // Could add pair info here if Altium API provides it
                    end;
                    
                    // Add to mechanical array
                    MechArray.Add(BuildJSONObject(LayerProps, 1));
                finally
                    LayerProps.Free;
                end;
            end;
        end;
        
        // Process other special layers
        // Top Overlay
        LayerProps := TStringList.Create;
        try
            AddJSONProperty(LayerProps, 'name', 'Top Overlay');
            AddJSONProperty(LayerProps, 'layer_id', IntToStr(String2Layer('Top Overlay')));
            AddJSONProperty(LayerProps, 'layer_type', 'special');
            AddJSONProperty(LayerProps, 'special_type', 'overlay');
            AddJSONBoolean(LayerProps, 'is_displayed', Board.LayerIsDisplayed[String2Layer('Top Overlay')]);
            AddJSONProperty(LayerProps, 'color', ColorToString(Board.LayerColor[String2Layer('Top Overlay')]));
            OtherArray.Add(BuildJSONObject(LayerProps, 1));
        finally
            LayerProps.Free;
        end;
        
        // Bottom Overlay
        LayerProps := TStringList.Create;
        try
            AddJSONProperty(LayerProps, 'name', 'Bottom Overlay');
            AddJSONProperty(LayerProps, 'layer_id', IntToStr(String2Layer('Bottom Overlay')));
            AddJSONProperty(LayerProps, 'layer_type', 'special');
            AddJSONProperty(LayerProps, 'special_type', 'overlay');
            AddJSONBoolean(LayerProps, 'is_displayed', Board.LayerIsDisplayed[String2Layer('Bottom Overlay')]);
            AddJSONProperty(LayerProps, 'color', ColorToString(Board.LayerColor[String2Layer('Bottom Overlay')]));
            OtherArray.Add(BuildJSONObject(LayerProps, 1));
        finally
            LayerProps.Free;
        end;
        
        // Top Solder Mask
        LayerProps := TStringList.Create;
        try
            AddJSONProperty(LayerProps, 'name', 'Top Solder Mask');
            AddJSONProperty(LayerProps, 'layer_id', IntToStr(String2Layer('Top Solder Mask')));
            AddJSONProperty(LayerProps, 'layer_type', 'special');
            AddJSONProperty(LayerProps, 'special_type', 'solder_mask');
            AddJSONBoolean(LayerProps, 'is_displayed', Board.LayerIsDisplayed[String2Layer('Top Solder Mask')]);
            AddJSONProperty(LayerProps, 'color', ColorToString(Board.LayerColor[String2Layer('Top Solder Mask')]));
            OtherArray.Add(BuildJSONObject(LayerProps, 1));
        finally
            LayerProps.Free;
        end;
        
        // Bottom Solder Mask
        LayerProps := TStringList.Create;
        try
            AddJSONProperty(LayerProps, 'name', 'Bottom Solder Mask');
            AddJSONProperty(LayerProps, 'layer_id', IntToStr(String2Layer('Bottom Solder Mask')));
            AddJSONProperty(LayerProps, 'layer_type', 'special');
            AddJSONProperty(LayerProps, 'special_type', 'solder_mask');
            AddJSONBoolean(LayerProps, 'is_displayed', Board.LayerIsDisplayed[String2Layer('Bottom Solder Mask')]);
            AddJSONProperty(LayerProps, 'color', ColorToString(Board.LayerColor[String2Layer('Bottom Solder Mask')]));
            OtherArray.Add(BuildJSONObject(LayerProps, 1));
        finally
            LayerProps.Free;
        end;
        
        // Top Paste
        LayerProps := TStringList.Create;
        try
            AddJSONProperty(LayerProps, 'name', 'Top Paste');
            AddJSONProperty(LayerProps, 'layer_id', IntToStr(String2Layer('Top Paste')));
            AddJSONProperty(LayerProps, 'layer_type', 'special');
            AddJSONProperty(LayerProps, 'special_type', 'paste');
            AddJSONBoolean(LayerProps, 'is_displayed', Board.LayerIsDisplayed[String2Layer('Top Paste')]);
            AddJSONProperty(LayerProps, 'color', ColorToString(Board.LayerColor[String2Layer('Top Paste')]));
            OtherArray.Add(BuildJSONObject(LayerProps, 1));
        finally
            LayerProps.Free;
        end;
        
        // Bottom Paste
        LayerProps := TStringList.Create;
        try
            AddJSONProperty(LayerProps, 'name', 'Bottom Paste');
            AddJSONProperty(LayerProps, 'layer_id', IntToStr(String2Layer('Bottom Paste')));
            AddJSONProperty(LayerProps, 'layer_type', 'special');
            AddJSONProperty(LayerProps, 'special_type', 'paste');
            AddJSONBoolean(LayerProps, 'is_displayed', Board.LayerIsDisplayed[String2Layer('Bottom Paste')]);
            AddJSONProperty(LayerProps, 'color', ColorToString(Board.LayerColor[String2Layer('Bottom Paste')]));
            OtherArray.Add(BuildJSONObject(LayerProps, 1));
        finally
            LayerProps.Free;
        end;
        
        // Drill Guide
        LayerProps := TStringList.Create;
        try
            AddJSONProperty(LayerProps, 'name', 'Drill Guide');
            AddJSONProperty(LayerProps, 'layer_id', IntToStr(String2Layer('Drill Guide')));
            AddJSONProperty(LayerProps, 'layer_type', 'special');
            AddJSONProperty(LayerProps, 'special_type', 'drill');
            AddJSONBoolean(LayerProps, 'is_displayed', Board.LayerIsDisplayed[String2Layer('Drill Guide')]);
            AddJSONProperty(LayerProps, 'color', ColorToString(Board.LayerColor[String2Layer('Drill Guide')]));
            OtherArray.Add(BuildJSONObject(LayerProps, 1));
        finally
            LayerProps.Free;
        end;
        
        // Drill Drawing
        LayerProps := TStringList.Create;
        try
            AddJSONProperty(LayerProps, 'name', 'Drill Drawing');
            AddJSONProperty(LayerProps, 'layer_id', IntToStr(String2Layer('Drill Drawing')));
            AddJSONProperty(LayerProps, 'layer_type', 'special');
            AddJSONProperty(LayerProps, 'special_type', 'drill');
            AddJSONBoolean(LayerProps, 'is_displayed', Board.LayerIsDisplayed[String2Layer('Drill Drawing')]);
            AddJSONProperty(LayerProps, 'color', ColorToString(Board.LayerColor[String2Layer('Drill Drawing')]));
            OtherArray.Add(BuildJSONObject(LayerProps, 1));
        finally
            LayerProps.Free;
        end;
        
        // Multi Layer
        LayerProps := TStringList.Create;
        try
            AddJSONProperty(LayerProps, 'name', 'Multi Layer');
            AddJSONProperty(LayerProps, 'layer_id', IntToStr(String2Layer('Multi Layer')));
            AddJSONProperty(LayerProps, 'layer_type', 'special');
            AddJSONProperty(LayerProps, 'special_type', 'multi');
            AddJSONBoolean(LayerProps, 'is_displayed', Board.LayerIsDisplayed[String2Layer('Multi Layer')]);
            AddJSONProperty(LayerProps, 'color', ColorToString(Board.LayerColor[String2Layer('Multi Layer')]));
            OtherArray.Add(BuildJSONObject(LayerProps, 1));
        finally
            LayerProps.Free;
        end;
        
        // Keep Out Layer
        LayerProps := TStringList.Create;
        try
            AddJSONProperty(LayerProps, 'name', 'Keep Out Layer');
            AddJSONProperty(LayerProps, 'layer_id', IntToStr(String2Layer('Keep Out Layer')));
            AddJSONProperty(LayerProps, 'layer_type', 'special');
            AddJSONProperty(LayerProps, 'special_type', 'keepout');
            AddJSONBoolean(LayerProps, 'is_displayed', Board.LayerIsDisplayed[String2Layer('Keep Out Layer')]);
            AddJSONProperty(LayerProps, 'color', ColorToString(Board.LayerColor[String2Layer('Keep Out Layer')]));
            OtherArray.Add(BuildJSONObject(LayerProps, 1));
        finally
            LayerProps.Free;
        end;
        
        // Add additional info for the complete layer response
        LayerProps := TStringList.Create;
        try
            // Add summary information
            AddJSONInteger(LayerProps, 'copper_layers_count', TheLayerStack.LayersInStackCount);
            AddJSONInteger(LayerProps, 'signal_layers_count', TheLayerStack.SignalLayerCount);
            AddJSONInteger(LayerProps, 'internal_planes_count', TheLayerStack.LayersInStackCount - TheLayerStack.SignalLayerCount);
            
            // The enabled mechanical layers listed above. (Counting with the
            // loop's own variable reported 33 whatever the board had.)
            AddJSONInteger(LayerProps, 'mechanical_layers_count', MechArray.Count);
            
            // Add the layer arrays
            LayerProps.Add(BuildJSONArray(CopperArray, 'copper_layers'));
            LayerProps.Add(BuildJSONArray(MechArray, 'mechanical_layers'));
            LayerProps.Add(BuildJSONArray(OtherArray, 'special_layers'));
            
            // Build the final JSON
            OutputLines := TStringList.Create;
            try
                OutputLines.Text := BuildJSONObject(LayerProps);
                Result := WriteJSONToFile(OutputLines, ROOT_DIR+'\temp_layers_data.json');
            finally
                OutputLines.Free;
            end;
        finally
            LayerProps.Free;
        end;
    finally
        AllLayersArray.Free;
        CopperArray.Free;
        MechArray.Free;
        OtherArray.Free;
    end;
end;

// Function to set layer visibility (only specified layers visible)
// Function to set layer visibility with two modes:
// - visible=true: Show only specified layers, hide all others
// - visible=false: Hide specified layers, leave others unchanged
function SetPCBLayerVisibility(LayerNamesList: TStringList; Visible: Boolean; Exclusive: Boolean): String;
var
    Board          : IPCB_Board;
    TheLayerStack  : IPCB_LayerStack_V7;
    LayerObj       : IPCB_LayerObject;
    MechLayer      : IPCB_MechanicalLayer;
    ResultProps    : TStringList;
    OutputLines    : TStringList;
    i, j           : Integer;
    LayerName      : String;
    LayerID        : TLayer;
    FoundCount     : Integer;
    NotFoundList   : TStringList;
    FoundLayers    : TStringList;
    MechFound      : Boolean;
begin
    // Retrieve the current board
    Board := GetBoardSafe(0);
    if (Board = nil) then
    begin
        Result := '{"success": false, "error": "No PCB document is currently active"}';
        Exit;
    end;
    
    // Get the layer stack
    TheLayerStack := Board.LayerStack_V7;
    if (TheLayerStack = nil) then
    begin
        Result := '{"success": false, "error": "Failed to retrieve layer stack"}';
        Exit;
    end;
    
    // Create lists for tracking results
    ResultProps := TStringList.Create;
    NotFoundList := TStringList.Create;
    FoundLayers := TStringList.Create;
    FoundCount := 0;
    
    try
        // First phase: identify all specified layers
        for i := 0 to LayerNamesList.Count - 1 do
        begin
            LayerName := LayerNamesList[i];
            
            // Try to find the layer by name
            // First check special layers (since they have specific names)
            if (LayerName = 'Top Overlay') or 
               (LayerName = 'Bottom Overlay') or
               (LayerName = 'Top Solder Mask') or
               (LayerName = 'Bottom Solder Mask') or
               (LayerName = 'Top Paste') or
               (LayerName = 'Bottom Paste') or
               (LayerName = 'Drill Guide') or
               (LayerName = 'Drill Drawing') or
               (LayerName = 'Multi Layer') or
               (LayerName = 'Keep Out Layer') then
            begin
                // Get layer ID from name
                LayerID := String2Layer(LayerName);
                if (LayerID <> eNoLayer) then
                begin
                    FoundLayers.Add(IntToStr(LayerID));
                    FoundCount := FoundCount + 1;
                end
                else
                    NotFoundList.Add('"' + JSONEscapeString(LayerName) + '"');
                
                continue;
            end;
            
            // Check copper layers
            LayerObj := TheLayerStack.FirstLayer;
            j := 1;
            
            while (LayerObj <> nil) do
            begin
                if (LayerObj.Name = LayerName) then
                begin
                    FoundLayers.Add(IntToStr(LayerObj.V6_LayerID));
                    FoundCount := FoundCount + 1;
                    break;
                end;
                
                Inc(j);
                LayerObj := TheLayerStack.NextLayer(LayerObj);
            end;
            
            // If we found the layer in copper layers, continue to next layer name
            if (LayerObj <> nil) then
                continue;
            
            // Check mechanical layers (they can have custom names). Keyed by
            // layer number, as their V6 ids repeat above Mechanical 16
            MechFound := False;
            for j := 1 to MAX_MECH_LAYERS do
            begin
                MechLayer := TheLayerStack.LayerObject_V7[ILayer.MechanicalLayer(j)];
                
                if (MechLayer <> nil) and MechLayer.MechanicalLayerEnabled and (MechLayer.Name = LayerName) then
                begin
                    FoundLayers.Add(IntToStr(ILayer.MechanicalLayer(j)));
                    FoundCount := FoundCount + 1;
                    MechFound := True;
                    break;
                end;
            end;
            
            // If we've checked all layer types and didn't find a match, add to not found list
            if not MechFound then
                NotFoundList.Add('"' + JSONEscapeString(LayerName) + '"');
        end;
        
        // Second phase: set visibility for all layers based on mode
        if Visible and Exclusive then
        begin
            // Show only the specified layers, hide all others
            
            // For copper layers
            LayerObj := TheLayerStack.FirstLayer;
            while (LayerObj <> nil) do
            begin
                // Check if this layer is in our found list
                if (FoundLayers.IndexOf(IntToStr(LayerObj.V6_LayerID)) >= 0) then
                    LayerObj.IsDisplayed[Board] := True
                else
                    LayerObj.IsDisplayed[Board] := False;
                
                LayerObj := TheLayerStack.NextLayer(LayerObj);
            end;
            
            // For mechanical layers
            for j := 1 to MAX_MECH_LAYERS do
            begin
                MechLayer := TheLayerStack.LayerObject_V7[ILayer.MechanicalLayer(j)];
                
                if (MechLayer <> nil) and MechLayer.MechanicalLayerEnabled then
                begin
                    if (FoundLayers.IndexOf(IntToStr(ILayer.MechanicalLayer(j))) >= 0) then
                        MechLayer.IsDisplayed[Board] := True
                    else
                        MechLayer.IsDisplayed[Board] := False;
                end;
            end;
            
            // For special layers
            for j := 1 to 10 do
            begin
                case j of
                    1: LayerID := String2Layer('Top Overlay');
                    2: LayerID := String2Layer('Bottom Overlay');
                    3: LayerID := String2Layer('Top Solder Mask');
                    4: LayerID := String2Layer('Bottom Solder Mask');
                    5: LayerID := String2Layer('Top Paste');
                    6: LayerID := String2Layer('Bottom Paste');
                    7: LayerID := String2Layer('Drill Guide');
                    8: LayerID := String2Layer('Drill Drawing');
                    9: LayerID := String2Layer('Multi Layer');
                    10: LayerID := String2Layer('Keep Out Layer');
                end;
                
                if (FoundLayers.IndexOf(IntToStr(LayerID)) >= 0) then
                    Board.LayerIsDisplayed[LayerID] := True
                else
                    Board.LayerIsDisplayed[LayerID] := False;
            end;
        end
        else
        begin
            // Show or hide only the specified layers, leave others unchanged
            
            // For copper layers
            LayerObj := TheLayerStack.FirstLayer;
            while (LayerObj <> nil) do
            begin
                // Check if this layer is in our found list
                if (FoundLayers.IndexOf(IntToStr(LayerObj.V6_LayerID)) >= 0) then
                    LayerObj.IsDisplayed[Board] := Visible;
                
                LayerObj := TheLayerStack.NextLayer(LayerObj);
            end;
            
            // For mechanical layers
            for j := 1 to MAX_MECH_LAYERS do
            begin
                MechLayer := TheLayerStack.LayerObject_V7[ILayer.MechanicalLayer(j)];
                
                if (MechLayer <> nil) and MechLayer.MechanicalLayerEnabled then
                begin
                    if (FoundLayers.IndexOf(IntToStr(ILayer.MechanicalLayer(j))) >= 0) then
                        MechLayer.IsDisplayed[Board] := Visible;
                end;
            end;
            
            // For special layers
            for j := 1 to 10 do
            begin
                case j of
                    1: LayerID := String2Layer('Top Overlay');
                    2: LayerID := String2Layer('Bottom Overlay');
                    3: LayerID := String2Layer('Top Solder Mask');
                    4: LayerID := String2Layer('Bottom Solder Mask');
                    5: LayerID := String2Layer('Top Paste');
                    6: LayerID := String2Layer('Bottom Paste');
                    7: LayerID := String2Layer('Drill Guide');
                    8: LayerID := String2Layer('Drill Drawing');
                    9: LayerID := String2Layer('Multi Layer');
                    10: LayerID := String2Layer('Keep Out Layer');
                end;
                
                if (FoundLayers.IndexOf(IntToStr(LayerID)) >= 0) then
                    Board.LayerIsDisplayed[LayerID] := Visible;
            end;
        end;
        
        // Update the display
        Board.ViewManager_FullUpdate;
        Board.ViewManager_UpdateLayerTabs;
        
        // Create result JSON
        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONInteger(ResultProps, 'updated_count', FoundCount);
        
        // Add missing layers array
        if (NotFoundList.Count > 0) then
            ResultProps.Add(BuildJSONArray(NotFoundList, 'not_found_layers'))
        else
            ResultProps.Add('"not_found_layers": []');
        
        // Build final JSON
        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
        NotFoundList.Free;
        FoundLayers.Free;
    end;
end;

// A value of create_pcb_rule's "key=value" list, or Default when absent
function RuleValue(Values: TStringList; Key: String; Default: Integer): Integer;
var
    i : Integer;
begin
    Result := Default;
    i := Values.IndexOfName(Key);
    if i >= 0 then Result := StrToInt(Values.ValueFromIndex[i]);
end;

function RuleHasValue(Values: TStringList; Key: String): Boolean;
begin
    Result := Values.IndexOfName(Key) >= 0;
end;

// How many rules of Kind are on Board besides Rule
function OtherRulesOfKind(Board: IPCB_Board; Rule: IPCB_Rule): Integer;
var
    Iterator : IPCB_BoardIterator;
    Other    : IPCB_Rule;
begin
    Result := 0;
    Iterator := Board.BoardIterator_Create;
    Iterator.AddFilter_ObjectSet(MkSet(eRuleObject));
    Iterator.AddFilter_LayerSet(AllLayers);
    Iterator.AddFilter_Method(eProcessAll);
    Other := Iterator.FirstPCBObject;
    while Other <> nil do
    begin
        if (Other.RuleKind = Rule.RuleKind) and (UpperCase(Other.Name) <> UpperCase(Rule.Name)) then
            Result := Result + 1;
        Other := Iterator.NextPCBObject;
    end;
    Board.BoardIterator_Destroy(Iterator);
end;

// The rule named Name on Board, or nil
function FindRuleByName(Board: IPCB_Board; Name: String): IPCB_Rule;
var
    Iterator : IPCB_BoardIterator;
    Rule     : IPCB_Rule;
begin
    Result := nil;
    Iterator := Board.BoardIterator_Create;
    Iterator.AddFilter_ObjectSet(MkSet(eRuleObject));
    Iterator.AddFilter_LayerSet(AllLayers);
    Iterator.AddFilter_Method(eProcessAll);
    Rule := Iterator.FirstPCBObject;
    while (Rule <> nil) and (Result = nil) do
    begin
        if UpperCase(Rule.Name) = UpperCase(Name) then Result := Rule;
        Rule := Iterator.NextPCBObject;
    end;
    Board.BoardIterator_Destroy(Iterator);
end;

// Add a design rule to the focused board. Values holds "key=value" lines in
// internal units (counts for entries, a word for connect_style), already
// checked by the server for this kind. Constraint properties are only
// reachable through a variable of the rule's own interface, hence one
// variable per kind. Every value is read back into the result: Descriptor
// shows what Altium actually stored.
function CreatePCBRule(Kind: String; Name: String; Scope1: String; Scope2: String; Comment: String;
                       Values: TStringList; Replace: Boolean): String;
var
    Board    : IPCB_Board;
    Existing : IPCB_Rule;
    Rule     : IPCB_Rule;
    Clear    : IPCB_ClearanceConstraint;
    Width    : IPCB_MaxMinWidthConstraint;
    Hole     : IPCB_MaxMinHoleSizeConstraint;
    Via      : IPCB_RoutingViaStyleRule;
    SMask    : IPCB_SolderMaskExpansionRule;
    PMask    : IPCB_PasteMaskExpansionRule;
    Connect  : IPCB_PolygonConnectStyleRule;
    L        : Integer;
    Style    : String;
    Props    : TStringList;
begin
    Board := GetBoardSafe(0);
    if Board = nil then
    begin
        Result := 'ERROR: No PCB document is focused';
        Exit;
    end;
    Existing := FindRuleByName(Board, Name);
    if (Existing <> nil) and (not Replace) then
    begin
        Result := 'ERROR: A rule named ' + Name + ' already exists (' + Existing.Descriptor +
                  '). Pass replace=true to replace it, or choose another name';
        Exit;
    end;

    Rule := nil;
    if Kind = 'clearance' then
    begin
        Clear := PCBServer.PCBRuleFactory(eRule_Clearance);
        Clear.Gap := RuleValue(Values, 'gap', 0);
        Rule := Clear;
    end
    else if Kind = 'width' then
    begin
        Width := PCBServer.PCBRuleFactory(eRule_MaxMinWidth);
        // Width is per layer; set it on every signal layer
        for L := eTopLayer to eBottomLayer do
        begin
            Width.MinWidth(L) := RuleValue(Values, 'min', 0);
            Width.MaxWidth(L) := RuleValue(Values, 'max', 0);
            Width.FavoredWidth(L) := RuleValue(Values, 'preferred', 0);
        end;
        Rule := Width;
    end
    else if Kind = 'hole_size' then
    begin
        Hole := PCBServer.PCBRuleFactory(eRule_MaxMinHoleSize);
        Hole.MinLimit := RuleValue(Values, 'min', 0);
        Hole.MaxLimit := RuleValue(Values, 'max', 0);
        Rule := Hole;
    end
    else if Kind = 'routing_via' then
    begin
        Via := PCBServer.PCBRuleFactory(eRule_RoutingViaStyle);
        Via.MinWidth := RuleValue(Values, 'min_diameter', 0);
        Via.MaxWidth := RuleValue(Values, 'max_diameter', 0);
        Via.PreferedWidth := RuleValue(Values, 'preferred_diameter', 0);
        Via.MinHoleWidth := RuleValue(Values, 'min_hole', 0);
        Via.MaxHoleWidth := RuleValue(Values, 'max_hole', 0);
        Via.PreferedHoleWidth := RuleValue(Values, 'preferred_hole', 0);
        Rule := Via;
    end
    else if Kind = 'solder_mask_expansion' then
    begin
        SMask := PCBServer.PCBRuleFactory(eRule_SolderMaskExpansion);
        SMask.Expansion := RuleValue(Values, 'expansion', 0);
        Rule := SMask;
    end
    else if Kind = 'paste_mask_expansion' then
    begin
        PMask := PCBServer.PCBRuleFactory(eRule_PasteMaskExpansion);
        PMask.Expansion := RuleValue(Values, 'expansion', 0);
        Rule := PMask;
    end
    else if Kind = 'polygon_connect' then
    begin
        Connect := PCBServer.PCBRuleFactory(eRule_PolygonConnectStyle);
        Style := Values.Values['connect_style'];
        if Style = 'direct' then
            Connect.ConnectStyle := eDirectConnectToPlane
        else if Style = 'none' then
            Connect.ConnectStyle := eNoConnect
        else
            Connect.ConnectStyle := eReliefConnectToPlane;
        if RuleHasValue(Values, 'conductor_width') then
            Connect.ReliefConductorWidth := RuleValue(Values, 'conductor_width', 0);
        if RuleHasValue(Values, 'air_gap') then
            Connect.ReliefAirGap := RuleValue(Values, 'air_gap', 0);
        if RuleHasValue(Values, 'entries') then
            Connect.ReliefEntries := RuleValue(Values, 'entries', 4);
        Rule := Connect;
    end;
    if Rule = nil then
    begin
        Result := 'ERROR: Unknown rule kind: ' + Kind;
        Exit;
    end;

    Rule.Name := Name;
    Rule.Scope1Expression := Scope1;
    Rule.Scope2Expression := Scope2;
    if Comment <> '' then Rule.Comment := Comment;

    // PostProcess must run whatever happens, or Altium's undo stays broken
    PCBServer.PreProcess;
    try
        if Existing <> nil then
        begin
            Board.RemovePCBObject(Existing);
            PCBServer.SendMessageToRobots(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Existing.I_ObjectAddress);
        end;
        Board.AddPCBObject(Rule);
        PCBServer.SendMessageToRobots(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Rule.I_ObjectAddress);
    finally
        PCBServer.PostProcess;
    end;

    Props := TStringList.Create;
    try
        AddJSONBoolean(Props, 'success', True);
        AddJSONProperty(Props, 'name', Rule.Name);
        AddJSONProperty(Props, 'descriptor', Rule.Descriptor);
        AddJSONProperty(Props, 'scope1', Rule.Scope1Expression);
        AddJSONProperty(Props, 'scope2', Rule.Scope2Expression);
        // A rule added by script always becomes priority 1 of its kind, and
        // Priority cannot be set from a script
        AddJSONInteger(Props, 'priority', Rule.Priority);
        AddJSONInteger(Props, 'other_rules_of_kind', OtherRulesOfKind(Board, Rule));
        AddJSONBoolean(Props, 'enabled', Rule.Enabled);
        AddJSONBoolean(Props, 'replaced', Existing <> nil);
        AddJSONProperty(Props, 'board', Board.FileName);
        Result := BuildJSONObject(Props);
    finally
        Props.Free;
    end;
end;


function SetPCBLayerNamesById(LayerNameSpecs: TStringList): String;
var
    Board         : IPCB_Board;
    TheLayerStack : IPCB_LayerStack_V7;
    LayerObj      : IPCB_LayerObject;
    MechLayer     : IPCB_MechanicalLayer;
    ResultProps   : TStringList;
    OutputLines   : TStringList;
    NotFoundList  : TStringList;
    Spec          : String;
    SepPos        : Integer;
    LayerId       : Integer;
    NewName       : String;
    i, j          : Integer;
    UpdatedCount  : Integer;
    Found         : Boolean;
begin
    ResultProps := TStringList.Create;
    NotFoundList := TStringList.Create;
    UpdatedCount := 0;

    try
        Board := GetBoardSafe(0);
        if (Board = nil) then
        begin
            AddJSONBoolean(ResultProps, 'success', False);
            AddJSONProperty(ResultProps, 'error', 'No PCB document is currently active');
        end
        else
        begin
            TheLayerStack := Board.LayerStack_V7;
            if (TheLayerStack = nil) then
            begin
                AddJSONBoolean(ResultProps, 'success', False);
                AddJSONProperty(ResultProps, 'error', 'No layer stack is available');
            end
            else
            begin
                PCBServer.PreProcess;

                for i := 0 to LayerNameSpecs.Count - 1 do
                begin
                    Spec := LayerNameSpecs[i];
                    SepPos := Pos('|', Spec);
                    if SepPos <= 0 then
                    begin
                        NotFoundList.Add('"' + JSONEscapeString(Spec) + '"');
                        Continue;
                    end;

                    LayerId := StrToIntDef(Copy(Spec, 1, SepPos - 1), -1);
                    NewName := Copy(Spec, SepPos + 1, Length(Spec));
                    Found := False;

                    LayerObj := TheLayerStack.FirstLayer;
                    while (LayerObj <> nil) do
                    begin
                        if LayerObj.V6_LayerID = LayerId then
                        begin
                            Found := True;
                            if LayerObj.Name <> NewName then
                            begin
                                LayerObj.Name := NewName;
                                UpdatedCount := UpdatedCount + 1;
                            end;
                            Break;
                        end;

                        LayerObj := TheLayerStack.NextLayer(LayerObj);
                    end;

                    if not Found then
                    begin
                        for j := 1 to 32 do
                        begin
                            MechLayer := TheLayerStack.LayerObject_V7[ILayer.MechanicalLayer(j)];
                            if MechLayer.MechanicalLayerEnabled and (MechLayer.V6_LayerID = LayerId) then
                            begin
                                Found := True;
                                if MechLayer.Name <> NewName then
                                begin
                                    MechLayer.Name := NewName;
                                    UpdatedCount := UpdatedCount + 1;
                                end;
                                Break;
                            end;
                        end;
                    end;

                    if not Found then
                        NotFoundList.Add('"' + JSONEscapeString(IntToStr(LayerId)) + '"');
                end;

                PCBServer.PostProcess;
                Board.ViewManager_FullUpdate;
                Board.ViewManager_UpdateLayerTabs;

                AddJSONBoolean(ResultProps, 'success', True);
                AddJSONInteger(ResultProps, 'updated_count', UpdatedCount);
                if (NotFoundList.Count > 0) then
                    ResultProps.Add(BuildJSONArray(NotFoundList, 'not_found_layer_ids'))
                else
                    ResultProps.Add('"not_found_layer_ids": []');
                AddJSONProperty(ResultProps, 'message', 'Updated ' + IntToStr(UpdatedCount) + ' PCB layer names.');
            end;
        end;

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        NotFoundList.Free;
        ResultProps.Free;
    end;
end;

function ClearPCBRouteToolPathLayer(): String;
var
    Board       : IPCB_Board;
    ResultProps : TStringList;
    OutputLines : TStringList;
begin
    ResultProps := TStringList.Create;

    try
        Board := GetBoardSafe(0);
        if (Board = nil) then
        begin
            AddJSONBoolean(ResultProps, 'success', False);
            AddJSONProperty(ResultProps, 'error', 'No PCB document is currently active');
        end
        else
        begin
            PCBServer.PreProcess;
            Board.RouteToolPathLayer := eNoLayer;
            PCBServer.PostProcess;
            Board.ViewManager_FullUpdate;
            Board.ViewManager_UpdateLayerTabs;

            AddJSONBoolean(ResultProps, 'success', True);
            AddJSONProperty(ResultProps, 'message', 'Cleared PCB route tool path layer override.');
        end;

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
    end;
end;

// Function to get all PCB rules
function GetPCBRules(ROOT_DIR: String): String;
Var
    Board         : IPCB_Board;
    Rule          : IPCB_Rule;
    BoardIterator : IPCB_BoardIterator;
    RulesArray    : TStringList;
    RuleProps     : TStringList;
    OutputLines   : TStringList;
begin
    // Retrieve the current board
    Board := GetBoardSafe(0);
    if (Board = Nil) then
    begin
        Result := '[]';
        Exit;
    end;

    // Create array for rules
    RulesArray := TStringList.Create;
    
    try
        // Retrieve the iterator
        BoardIterator := Board.BoardIterator_Create;
        BoardIterator.AddFilter_ObjectSet(MkSet(eRuleObject));
        BoardIterator.AddFilter_LayerSet(AllLayers);
        BoardIterator.AddFilter_Method(eProcessAll);

        // Process each rule
        Rule := BoardIterator.FirstPCBObject;
        while (Rule <> Nil) do
        begin
            // Create rule properties
            RuleProps := TStringList.Create;
            try
                // Add rule descriptor
                AddJSONProperty(RuleProps, 'name', Rule.Name);
                AddJSONBoolean(RuleProps, 'enabled', Rule.Enabled);
                AddJSONInteger(RuleProps, 'priority', Rule.Priority);
                AddJSONProperty(RuleProps, 'descriptor', Rule.Descriptor);
                AddJSONProperty(RuleProps, 'rule_kind', Rule.GetState_ShortDescriptorString);
                AddJSONProperty(RuleProps, 'filter1', Rule.Scope1Expression);
                AddJSONProperty(RuleProps, 'filter2', Rule.Scope2Expression);

                // Add to rules array
                RulesArray.Add(BuildJSONObject(RuleProps, 1));
            finally
                RuleProps.Free;
            end;
            
            // Move to next rule
            Rule := BoardIterator.NextPCBObject;
        end;

        // Clean up the iterator
        Board.BoardIterator_Destroy(BoardIterator);
        
        // Build the final JSON array
        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONArray(RulesArray);
            Result := WriteJSONToFile(OutputLines, ROOT_DIR+'\temp_rules_data.json');
        finally
            OutputLines.Free;
        end;
    finally
        RulesArray.Free;
    end;
end;

// One primitive of a violation: what it is, its net, and where
function ViolationPrimitiveJSON(Board: IPCB_Board; Prim: IPCB_Primitive): String;
var
    Props : TStringList;
    Rect  : TCoordRect;
    Detail, NetName : String;
begin
    Props := TStringList.Create;
    try
        Detail := '';
        NetName := '';
        try Detail := Prim.Detail; except end;
        try if Prim.Net <> nil then NetName := Prim.Net.Name; except end;
        AddJSONProperty(Props, 'object', Detail);
        AddJSONProperty(Props, 'net', NetName);
        try AddJSONProperty(Props, 'layer', Layer2String(Prim.Layer)); except end;
        try
            Rect := Prim.BoundingRectangle;
            AddJSONNumber(Props, 'x_mils', CoordToMils((Rect.Left + Rect.Right) div 2 - Board.XOrigin));
            AddJSONNumber(Props, 'y_mils', CoordToMils((Rect.Bottom + Rect.Top) div 2 - Board.YOrigin));
        except
        end;
        Result := BuildJSONObject(Props, 2);
    finally
        Props.Free;
    end;
end;

// Run the design rule check on the focused board and list the violations it
// leaves on the board. PCB:DesignRuleCheck opens the modal Design Rule
// Checker dialog and returns once it closes; run_drc presses its Run button
// from outside Altium. Coordinates are mils relative to the board origin.
function RunDRC(MaxViolations: Integer): String;
var
    Board     : IPCB_Board;
    Iterator  : IPCB_BoardIterator;
    Violation : IPCB_Violation;
    Rect      : TCoordRect;
    Items, Props, ResultProps : TStringList;
    Count     : Integer;
    RuleName  : String;
begin
    Board := GetBoardSafe(0);
    if Board = nil then
    begin
        Result := 'ERROR: No PCB document is focused';
        Exit;
    end;

    ResetParameters;
    RunProcess('PCB:DesignRuleCheck');

    Items := TStringList.Create;
    ResultProps := TStringList.Create;
    try
        Count := 0;
        Iterator := Board.BoardIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(eViolationObject));
        Iterator.AddFilter_LayerSet(AllLayers);
        Iterator.AddFilter_Method(eProcessAll);
        Violation := Iterator.FirstPCBObject;
        while Violation <> nil do
        begin
            Count := Count + 1;
            if Count <= MaxViolations then
            begin
                Props := TStringList.Create;
                try
                    RuleName := '';
                    try if Violation.Rule <> nil then RuleName := Violation.Rule.Name; except end;
                    AddJSONProperty(Props, 'rule', RuleName);
                    // Description and the violation's own layer are empty;
                    // Descriptor says what is wrong and by how much
                    try AddJSONProperty(Props, 'description', Violation.Descriptor); except end;
                    try
                        Rect := Violation.BoundingRectangle;
                        AddJSONNumber(Props, 'x_mils', CoordToMils((Rect.Left + Rect.Right) div 2 - Board.XOrigin));
                        AddJSONNumber(Props, 'y_mils', CoordToMils((Rect.Bottom + Rect.Top) div 2 - Board.YOrigin));
                    except
                    end;
                    try
                        if Violation.Primitive1 <> nil then
                            Props.Add('"primitive1": ' + ViolationPrimitiveJSON(Board, Violation.Primitive1));
                    except
                    end;
                    try
                        if Violation.Primitive2 <> nil then
                            Props.Add('"primitive2": ' + ViolationPrimitiveJSON(Board, Violation.Primitive2));
                    except
                    end;
                    Items.Add(BuildJSONObject(Props, 1));
                finally
                    Props.Free;
                end;
            end;
            Violation := Iterator.NextPCBObject;
        end;
        Board.BoardIterator_Destroy(Iterator);

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'board', Board.FileName);
        AddJSONInteger(ResultProps, 'violation_count', Count);
        ResultProps.Add(BuildJSONArray(Items, 'violations'));
        Result := BuildJSONObject(ResultProps);
    finally
        Items.Free;
        ResultProps.Free;
    end;
end;

// Function to get all component data from the PCB
function GetAllComponentData(ROOT_DIR: String, SelectedOnly: Boolean = False): String;
var
    Board       : IPCB_Board;
    Iterator    : IPCB_BoardIterator;
    Component   : IPCB_Component;
    ComponentsArray : TStringList;
    ComponentProps : TStringList;
    Rect        : TCoordRect;
    xorigin, yorigin : Integer;
    i           : Integer;
    ComponentCount : Integer;
    OutputLines : TStringList;
begin
    // Retrieve the current board
    Board := GetBoardSafe(0);
    if (Board = nil) then
    begin
        Result := '[]';
        Exit;
    end;
    
    // Get board origin coordinates
    xorigin := Board.XOrigin;
    yorigin := Board.YOrigin;

    // Create array for components
    ComponentsArray := TStringList.Create;
    
    try
        // Create an iterator to find all components
        Iterator := Board.BoardIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(eComponentObject));
        Iterator.AddFilter_IPCB_LayerSet(LayerSet.AllLayers);
        Iterator.AddFilter_Method(eProcessAll);

        // Process each component
        Component := Iterator.FirstPCBObject;
        while (Component <> Nil) do
        begin
            // Process either all components or only selected ones
            if ((not SelectedOnly) or (SelectedOnly and Component.Selected)) then
            begin
                // Create component properties
                ComponentProps := TStringList.Create;
                try
                    // Get bounds
                    Rect := Component.BoundingRectangleNoNameComment;
                    
                    // Add properties
                    AddJSONProperty(ComponentProps, 'designator', Component.Name.Text);
                    AddJSONProperty(ComponentProps, 'name', Component.Identifier);
                    AddJSONProperty(ComponentProps, 'description', Component.SourceDescription);
                    AddJSONProperty(ComponentProps, 'footprint', Component.Pattern);
                    AddJSONProperty(ComponentProps, 'layer', Layer2String(Component.Layer));
                    AddJSONNumber(ComponentProps, 'x', CoordToMils(Component.x - xorigin));
                    AddJSONNumber(ComponentProps, 'y', CoordToMils(Component.y - yorigin));
                    AddJSONNumber(ComponentProps, 'width', CoordToMils(Rect.Right - Rect.Left));
                    AddJSONNumber(ComponentProps, 'height', CoordToMils(Rect.Top - Rect.Bottom));
                    AddJSONNumber(ComponentProps, 'rotation', Component.Rotation);

                    // Add to components array
                    ComponentsArray.Add(BuildJSONObject(ComponentProps, 1));
                finally
                    ComponentProps.Free;
                end;
            end;
            
            // Move to next component
            Component := Iterator.NextPCBObject;
        end;

        // Clean up the iterator
        Board.BoardIterator_Destroy(Iterator);
        
        // Build the final JSON array
        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONArray(ComponentsArray);
            Result := WriteJSONToFile(OutputLines, ROOT_DIR+'\temp_component_data.json');
        finally
            OutputLines.Free;
        end;
    finally
        ComponentsArray.Free;
    end;
end;

// Example refactored function using the new JSON utilities
function GetSelectedComponentsCoordinates(ROOT_DIR: String): String;
var
    Board       : IPCB_Board;
    Component   : IPCB_Component;
    Rect        : TCoordRect;
    xorigin, yorigin : Integer;
    ComponentsArray : TStringList;
    ComponentProps : TStringList;
    OutputLines : TStringList;
    i : Integer;
begin
    Result := '';

    // Retrieve the current board
    Board := GetBoardSafe(0);
    if Board = nil then Exit;

    // Get board origin coordinates
    xorigin := Board.XOrigin;
    yorigin := Board.YOrigin;

    // Create output and components array
    OutputLines := TStringList.Create;
    ComponentsArray := TStringList.Create;
    
    try
        // Process each selected component
        for i := 0 to Board.SelectecObjectCount - 1 do
        begin
            // Only process selected components
            if Board.SelectecObject[i].ObjectId = eComponentObject then
            begin
                // Cast to component type
                Component := Board.SelectecObject[i];
                
                // Get component bounds
                Rect := Component.BoundingRectangleNoNameComment;
                
                // Create component properties
                ComponentProps := TStringList.Create;
                try
                    // Add component properties
                    AddJSONProperty(ComponentProps, 'designator', Component.Name.Text);
                    AddJSONProperty(ComponentProps, 'layer', Layer2String(Component.Layer));
                    AddJSONProperty(ComponentProps, 'footprint', Component.Pattern);
                    AddJSONNumber(ComponentProps, 'x', CoordToMils(Component.x - xorigin));
                    AddJSONNumber(ComponentProps, 'y', CoordToMils(Component.y - yorigin));
                    AddJSONNumber(ComponentProps, 'width', CoordToMils(Rect.Right - Rect.Left));
                    AddJSONNumber(ComponentProps, 'height', CoordToMils(Rect.Top - Rect.Bottom));
                    AddJSONNumber(ComponentProps, 'rotation', Component.Rotation);
                    
                    // Add component JSON to array
                    ComponentsArray.Add(BuildJSONObject(ComponentProps, 1));
                finally
                    ComponentProps.Free;
                end;
            end;
        end;
        
        // If components found, build array
        if ComponentsArray.Count > 0 then
            Result := BuildJSONArray(ComponentsArray)
        else
            Result := '[]';
            
        // For consistency with existing code, write to file and read back
        OutputLines.Text := Result;
        Result := WriteJSONToFile(OutputLines, ROOT_DIR+'\temp_selected_components.json');
    finally
        ComponentsArray.Free;
        OutputLines.Free;
    end;
end;

// Function to get pin data for specified components
function GetComponentPinsFromList(ROOT_DIR: String; DesignatorsList: TStringList): String;
var
    Board           : IPCB_Board;
    Component       : IPCB_Component;
    ComponentsArray : TStringList;
    CompProps       : TStringList;
    PinsArray       : TStringList;
    GrpIter         : IPCB_GroupIterator;
    Pad             : IPCB_Pad;
    NetName         : String;
    xorigin, yorigin : Integer;
    PinProps        : TStringList;
    PinCount, PinsProcessed : Integer;
    Designator      : String;
    i               : Integer;
    OutputLines     : TStringList;
    CompX, CompY    : Double;
    CompRad         : Double;
    AbsDX, AbsDY    : Double;
    RelDX, RelDY    : Double;
begin
    // Retrieve the current board
    Board := GetBoardSafe(0);
    if (Board = nil) then
    begin
        Result := '[]';
        Exit;
    end;
    
    // Get board origin coordinates
    xorigin := Board.XOrigin;
    yorigin := Board.YOrigin;

    // Create array for components
    ComponentsArray := TStringList.Create;
    
    try
        // Process each designator
        for i := 0 to DesignatorsList.Count - 1 do
        begin
            Designator := Trim(DesignatorsList[i]);
            
            // Use direct function to get component by designator
            Component := Board.GetPcbComponentByRefDes(Designator);
            
            if (Component <> Nil) then
            begin
                // Create component properties
                CompProps := TStringList.Create;
                PinsArray := TStringList.Create;
                
                try
                    // Add designator to component
                    AddJSONProperty(CompProps, 'designator', Component.Name.Text);

                    // Component placement info so pin data is self-contained
                    CompX := CoordToMils(Component.x - xorigin);
                    CompY := CoordToMils(Component.y - yorigin);
                    CompRad := Component.Rotation * Pi / 180;
                    AddJSONNumber(CompProps, 'x', CompX);
                    AddJSONNumber(CompProps, 'y', CompY);
                    AddJSONNumber(CompProps, 'rotation', Component.Rotation);
                    AddJSONProperty(CompProps, 'layer', Layer2String(Component.Layer));

                    // Create pad iterator
                    GrpIter := Component.GroupIterator_Create;
                    GrpIter.SetState_FilterAll;
                    GrpIter.AddFilter_ObjectSet(MkSet(ePadObject));
                    
                    // Count pins
                    PinCount := 0;
                    Pad := GrpIter.FirstPCBObject;
                    while (Pad <> Nil) do
                    begin
                        if Pad.InComponent then
                            PinCount := PinCount + 1;
                        Pad := GrpIter.NextPCBObject;
                    end;
                    
                    // Reset iterator
                    Component.GroupIterator_Destroy(GrpIter);
                    GrpIter := Component.GroupIterator_Create;
                    GrpIter.SetState_FilterAll;
                    GrpIter.AddFilter_ObjectSet(MkSet(ePadObject));
                    
                    // Process each pad
                    PinsProcessed := 0;
                    Pad := GrpIter.FirstPCBObject;
                    while (Pad <> Nil) do
                    begin
                        if Pad.InComponent then
                        begin
                            // Get net name if connected
                            if (Pad.Net <> Nil) then
                                NetName := Pad.Net.Name
                            else
                                NetName := '';
                                
                            // Create pin properties
                            PinProps := TStringList.Create;
                            try
                                AddJSONProperty(PinProps, 'name', Pad.Name);
                                AddJSONProperty(PinProps, 'net', NetName);
                                AddJSONNumber(PinProps, 'x', CoordToMils(Pad.x - xorigin));
                                AddJSONNumber(PinProps, 'y', CoordToMils(Pad.y - yorigin));

                                // Pad offset from the component origin in the
                                // footprint's rotation-0 frame: un-rotate the
                                // current offset, and un-mirror X for parts on
                                // the bottom side. Predicted pad position after
                                // placement = origin + (mirror-x if bottom,
                                // then rotate CCW by rotation) applied to dx/dy.
                                AbsDX := CoordToMils(Pad.x - xorigin) - CompX;
                                AbsDY := CoordToMils(Pad.y - yorigin) - CompY;
                                RelDX := AbsDX * Cos(CompRad) + AbsDY * Sin(CompRad);
                                RelDY := -AbsDX * Sin(CompRad) + AbsDY * Cos(CompRad);
                                if (Component.Layer = eBottomLayer) then
                                begin
                                    RelDX := -(AbsDX * Cos(CompRad) - AbsDY * Sin(CompRad));
                                    RelDY := AbsDX * Sin(CompRad) + AbsDY * Cos(CompRad);
                                end;
                                // Round away trig noise (0.0001 mil resolution)
                                RelDX := Round(RelDX * 10000) / 10000;
                                RelDY := Round(RelDY * 10000) / 10000;
                                AddJSONNumber(PinProps, 'dx', RelDX);
                                AddJSONNumber(PinProps, 'dy', RelDY);

                                AddJSONNumber(PinProps, 'rotation', Pad.Rotation);
                                AddJSONProperty(PinProps, 'layer', Layer2String(Pad.Layer));
                                AddJSONNumber(PinProps, 'width', CoordToMils(Pad.XSizeOnLayer[Pad.Layer]));
                                AddJSONNumber(PinProps, 'height', CoordToMils(Pad.YSizeOnLayer[Pad.Layer]));
                                AddJSONNumber(PinProps, 'hole_size', CoordToMils(Pad.HoleSize));
                                AddJSONProperty(PinProps, 'shape', ShapeToString(Pad.ShapeOnLayer[Pad.Layer]));
                                
                                // Add to pins array
                                PinsArray.Add(BuildJSONObject(PinProps, 3));
                                
                                // Increment counter
                                PinsProcessed := PinsProcessed + 1;
                            finally
                                PinProps.Free;
                            end;
                        end;
                        
                        Pad := GrpIter.NextPCBObject;
                    end;
                    
                    // Clean up iterator
                    Component.GroupIterator_Destroy(GrpIter);
                    
                    // Add pins array to component
                    CompProps.Add(BuildJSONArray(PinsArray, 'pins', 1));
                    
                    // Add to components array
                    ComponentsArray.Add(BuildJSONObject(CompProps, 1));
                finally
                    CompProps.Free;
                    PinsArray.Free;
                end;
            end
            else
            begin
                // Component not found, add empty component
                CompProps := TStringList.Create;
                try
                    AddJSONProperty(CompProps, 'designator', Designator);
                    CompProps.Add('"pins": []');
                    
                    // Add to components array
                    ComponentsArray.Add(BuildJSONObject(CompProps, 1));
                finally
                    CompProps.Free;
                end;
            end;
        end;
        
        // Build the final JSON array
        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONArray(ComponentsArray);
            Result := WriteJSONToFile(OutputLines, ROOT_DIR+'\temp_pins_data.json');
        finally
            OutputLines.Free;
        end;
    finally
        ComponentsArray.Free;
    end;
end;

// Set absolute position of a single component
function SetComponentPosition(Designator: String; NewX, NewY: Float; Rotation: Float): String;
var
    Board: IPCB_Board;
    Component: IPCB_Component;
    ResultProps: TStringList;
    xorigin, yorigin: TCoord;
begin
    Board := GetBoardSafe(0);
    if (Board = nil) then
    begin
        Result := '{"success": false, "error": "No PCB document is currently active"}';
        Exit;
    end;
    
    Component := Board.GetPcbComponentByRefDes(Designator);
    if (Component = nil) then
    begin
        Result := '{"success": false, "error": "Component not found: ' + Designator + '"}';
        Exit;
    end;
    
    // Get board origin
    xorigin := Board.XOrigin;
    yorigin := Board.YOrigin;
    
    ResultProps := TStringList.Create;
    try
        PCBServer.PreProcess;
        PCBServer.SendMessageToRobots(Component.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
        
        // Set absolute position using MoveToXY
        // Add origin back since input coordinates are relative to origin
        Component.MoveToXY(MilsToCoord(NewX) + xorigin, MilsToCoord(NewY) + yorigin);
        
        // Set rotation if specified (use -1 to keep current)
        if (Rotation >= 0) then
            Component.Rotation := Rotation;
        
        PCBServer.SendMessageToRobots(Component.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
        PCBServer.PostProcess;
        
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);
        
        AddJSONProperty(ResultProps, 'designator', Designator);
        // AddJSONNumber: FloatToStr writes the locale's decimal separator,
        // and a decimal comma made the reply invalid JSON (#31)
        AddJSONNumber(ResultProps, 'new_x', NewX);
        AddJSONNumber(ResultProps, 'new_y', NewY);
        AddJSONNumber(ResultProps, 'rotation', Component.Rotation);
        
        Result := '{"success": true, "result": ' + BuildJSONObject(ResultProps) + '}';
    finally
        ResultProps.Free;
    end;
end;

function StringListContainsText(Items: TStringList; Value: String): Boolean;
var
    i: Integer;
begin
    Result := False;

    for i := 0 to Items.Count - 1 do
    begin
        if UpperCase(Trim(Items[i])) = UpperCase(Trim(Value)) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function SetPadCopperShape(Pad: IPCB_Pad; Board: IPCB_Board; NewShape: TShape): Boolean;
var
    LayerStack: IPCB_LayerStack;
    LayerObject: IPCB_LayerObject;
begin
    Result := False;

    if Pad = Nil then
        Exit;

    if Pad.Mode = ePadMode_ExternalStack then
    begin
        if Board = Nil then
            Exit;

        LayerStack := Board.LayerStack;
        if LayerStack = Nil then
            Exit;

        LayerObject := LayerStack.FirstLayer;
        while LayerObject <> Nil do
        begin
            if Pad.StackShapeOnLayer[LayerObject.LayerID] <> NewShape then
            begin
                Pad.StackShapeOnLayer[LayerObject.LayerID] := NewShape;
                Result := True;
            end;

            LayerObject := LayerStack.NextLayer(LayerObject);
        end;
    end
    else if Pad.Mode = ePadMode_LocalStack then
    begin
        if Pad.TopShape <> NewShape then
        begin
            Pad.TopShape := NewShape;
            Result := True;
        end;

        if Pad.MidShape <> NewShape then
        begin
            Pad.MidShape := NewShape;
            Result := True;
        end;

        if Pad.BotShape <> NewShape then
        begin
            Pad.BotShape := NewShape;
            Result := True;
        end;
    end
    else
    begin
        if Pad.TopShape <> NewShape then
        begin
            Pad.TopShape := NewShape;
            Result := True;
        end;
    end;
end;

function TryParsePositiveInteger(Text: String; var Value: Integer): Boolean;
var
    i: Integer;
begin
    Result := False;
    Value := 0;
    Text := Trim(Text);

    if Text = '' then
        Exit;

    for i := 1 to Length(Text) do
    begin
        if (Text[i] < '0') or (Text[i] > '9') then
            Exit;
    end;

    Value := StrToInt(Text);
    Result := True;
end;

function ParseMechanicalLayerMove(MoveText: String; var SourceNumber: Integer; var DestinationNumber: Integer): Boolean;
var
    SeparatorPos: Integer;
    SourceText: String;
    DestinationText: String;
begin
    Result := False;
    SourceNumber := 0;
    DestinationNumber := 0;
    MoveText := Trim(MoveText);

    SeparatorPos := Pos('|', MoveText);
    if SeparatorPos <= 1 then
        Exit;

    SourceText := Copy(MoveText, 1, SeparatorPos - 1);
    DestinationText := Copy(MoveText, SeparatorPos + 1, Length(MoveText) - SeparatorPos);

    if not TryParsePositiveInteger(SourceText, SourceNumber) then
        Exit;

    if not TryParsePositiveInteger(DestinationText, DestinationNumber) then
        Exit;

    Result := (SourceNumber >= 1) and (SourceNumber <= 32) and
              (DestinationNumber >= 1) and (DestinationNumber <= 32);
end;

function Parse3DBodyProjectionCommand(MoveText: String; var DestinationNumber: Integer; var LineWidthMM: Double): Boolean;
var
    FirstSeparatorPos: Integer;
    SecondSeparatorPos: Integer;
    CommandName: String;
    RemainderText: String;
    DestinationText: String;
    LineWidthText: String;
begin
    Result := False;
    DestinationNumber := 0;
    LineWidthMM := 0;
    MoveText := Trim(MoveText);

    FirstSeparatorPos := Pos('|', MoveText);
    if FirstSeparatorPos <= 1 then
        Exit;

    CommandName := UpperCase(Trim(Copy(MoveText, 1, FirstSeparatorPos - 1)));
    if CommandName <> '3D_BODY_PROJECTION' then
        Exit;

    RemainderText := Copy(MoveText, FirstSeparatorPos + 1, Length(MoveText) - FirstSeparatorPos);
    SecondSeparatorPos := Pos('|', RemainderText);
    if SecondSeparatorPos <= 1 then
        Exit;

    DestinationText := Copy(RemainderText, 1, SecondSeparatorPos - 1);
    LineWidthText := Copy(RemainderText, SecondSeparatorPos + 1, Length(RemainderText) - SecondSeparatorPos);

    if not TryParsePositiveInteger(DestinationText, DestinationNumber) then
        Exit;

    if (DestinationNumber < 1) or (DestinationNumber > 32) then
        Exit;

    LineWidthMM := SafeStrToFloat(LineWidthText);
    Result := LineWidthMM > 0;
end;

function Find3DBodyProjectionCommand(LayerMoves: TStringList; var DestinationNumber: Integer; var LineWidthMM: Double): Boolean;
var
    i: Integer;
begin
    Result := False;
    DestinationNumber := 0;
    LineWidthMM := 0;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if Parse3DBodyProjectionCommand(LayerMoves[i], DestinationNumber, LineWidthMM) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function Find3DBodyStepSilhouetteCommand(LayerMoves: TStringList; var DestinationNumber: Integer; var LineWidthMM: Double; var RemoveExisting: Boolean): Boolean;
var
    i: Integer;
    MoveText: String;
    FirstSeparatorPos: Integer;
    SecondSeparatorPos: Integer;
    CommandName: String;
    RemainderText: String;
    DestinationText: String;
    LineWidthText: String;
begin
    Result := False;
    DestinationNumber := 0;
    LineWidthMM := 0;
    RemoveExisting := True;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        MoveText := Trim(LayerMoves[i]);
        FirstSeparatorPos := Pos('|', MoveText);
        if FirstSeparatorPos <= 1 then
            Continue;

        CommandName := UpperCase(Trim(Copy(MoveText, 1, FirstSeparatorPos - 1)));
        if (CommandName <> '3D_BODY_STEP_SILHOUETTE') and
           (CommandName <> '3D_BODY_SILHOUETTE') and
           (CommandName <> '3D_BODY_SILHOUETTE_APPEND') then
            Continue;

        RemoveExisting := CommandName <> '3D_BODY_SILHOUETTE_APPEND';

        RemainderText := Copy(MoveText, FirstSeparatorPos + 1, Length(MoveText) - FirstSeparatorPos);
        SecondSeparatorPos := Pos('|', RemainderText);
        if SecondSeparatorPos <= 1 then
            Continue;

        DestinationText := Copy(RemainderText, 1, SecondSeparatorPos - 1);
        LineWidthText := Copy(RemainderText, SecondSeparatorPos + 1, Length(RemainderText) - SecondSeparatorPos);

        if not TryParsePositiveInteger(DestinationText, DestinationNumber) then
            Continue;

        if (DestinationNumber < 1) or (DestinationNumber > 32) then
            Continue;

        LineWidthMM := SafeStrToFloat(LineWidthText);
        if LineWidthMM > 0 then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function Find3DBodyDumpCommand(LayerMoves: TStringList): Boolean;
var
    i: Integer;
begin
    Result := False;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if UpperCase(Trim(LayerMoves[i])) = '3D_BODY_DUMP' then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function Parse3DBodyTrackCountCommand(MoveText: String; var DestinationNumber: Integer; var LineWidthMM: Double): Boolean;
var
    FirstSeparatorPos: Integer;
    SecondSeparatorPos: Integer;
    CommandName: String;
    RemainderText: String;
    DestinationText: String;
    LineWidthText: String;
begin
    Result := False;
    DestinationNumber := 0;
    LineWidthMM := 0;
    MoveText := Trim(MoveText);

    FirstSeparatorPos := Pos('|', MoveText);
    if FirstSeparatorPos <= 1 then
        Exit;

    CommandName := UpperCase(Trim(Copy(MoveText, 1, FirstSeparatorPos - 1)));
    if CommandName <> '3D_BODY_TRACK_COUNT' then
        Exit;

    RemainderText := Copy(MoveText, FirstSeparatorPos + 1, Length(MoveText) - FirstSeparatorPos);
    SecondSeparatorPos := Pos('|', RemainderText);
    if SecondSeparatorPos <= 1 then
        Exit;

    DestinationText := Copy(RemainderText, 1, SecondSeparatorPos - 1);
    LineWidthText := Copy(RemainderText, SecondSeparatorPos + 1, Length(RemainderText) - SecondSeparatorPos);

    if not TryParsePositiveInteger(DestinationText, DestinationNumber) then
        Exit;

    if (DestinationNumber < 1) or (DestinationNumber > 32) then
        Exit;

    LineWidthMM := SafeStrToFloat(LineWidthText);
    Result := LineWidthMM > 0;
end;

function Find3DBodyTrackCountCommand(LayerMoves: TStringList; var DestinationNumber: Integer; var LineWidthMM: Double): Boolean;
var
    i: Integer;
begin
    Result := False;
    DestinationNumber := 0;
    LineWidthMM := 0;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if Parse3DBodyTrackCountCommand(LayerMoves[i], DestinationNumber, LineWidthMM) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function FindPCBUndoCommand(LayerMoves: TStringList): Boolean;
var
    i: Integer;
begin
    Result := False;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if UpperCase(Trim(LayerMoves[i])) = 'PCB_UNDO' then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function FindPCBCancelCommand(LayerMoves: TStringList): Boolean;
var
    i: Integer;
begin
    Result := False;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if UpperCase(Trim(LayerMoves[i])) = 'PCB_CANCEL' then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function FindPCBPostProcessCommand(LayerMoves: TStringList): Boolean;
var
    i: Integer;
begin
    Result := False;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if UpperCase(Trim(LayerMoves[i])) = 'PCB_POSTPROCESS' then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function FindSaveDocumentCommand(LayerMoves: TStringList): Boolean;
var
    i: Integer;
    MoveText: String;
begin
    Result := False;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        MoveText := UpperCase(Trim(LayerMoves[i]));
        if (MoveText = 'SAVE_DOCUMENT_CONFIRMED') or
           (MoveText = 'SAVE_DOCUMENT|CONFIRMED') then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function Parse3DBodyTrackSelectCommand(MoveText: String; var DestinationNumber: Integer; var LineWidthMM: Double): Boolean;
var
    FirstSeparatorPos: Integer;
    SecondSeparatorPos: Integer;
    CommandName: String;
    RemainderText: String;
    DestinationText: String;
    LineWidthText: String;
begin
    Result := False;
    DestinationNumber := 0;
    LineWidthMM := 0;
    MoveText := Trim(MoveText);

    FirstSeparatorPos := Pos('|', MoveText);
    if FirstSeparatorPos <= 1 then
        Exit;

    CommandName := UpperCase(Trim(Copy(MoveText, 1, FirstSeparatorPos - 1)));
    if CommandName <> '3D_BODY_TRACK_SELECT' then
        Exit;

    RemainderText := Copy(MoveText, FirstSeparatorPos + 1, Length(MoveText) - FirstSeparatorPos);
    SecondSeparatorPos := Pos('|', RemainderText);
    if SecondSeparatorPos <= 1 then
        Exit;

    DestinationText := Copy(RemainderText, 1, SecondSeparatorPos - 1);
    LineWidthText := Copy(RemainderText, SecondSeparatorPos + 1, Length(RemainderText) - SecondSeparatorPos);

    if not TryParsePositiveInteger(DestinationText, DestinationNumber) then
        Exit;

    if (DestinationNumber < 1) or (DestinationNumber > 32) then
        Exit;

    LineWidthMM := SafeStrToFloat(LineWidthText);
    Result := LineWidthMM > 0;
end;

function Find3DBodyTrackSelectCommand(LayerMoves: TStringList; var DestinationNumber: Integer; var LineWidthMM: Double): Boolean;
var
    i: Integer;
begin
    Result := False;
    DestinationNumber := 0;
    LineWidthMM := 0;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if Parse3DBodyTrackSelectCommand(LayerMoves[i], DestinationNumber, LineWidthMM) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function Parse3DBodySelectedDumpCommand(MoveText: String; var DestinationNumber: Integer; var LineWidthMM: Double): Boolean;
var
    FirstSeparatorPos: Integer;
    SecondSeparatorPos: Integer;
    CommandName: String;
    RemainderText: String;
    DestinationText: String;
    LineWidthText: String;
begin
    Result := False;
    DestinationNumber := 0;
    LineWidthMM := 0;
    MoveText := Trim(MoveText);

    FirstSeparatorPos := Pos('|', MoveText);
    if FirstSeparatorPos <= 1 then
        Exit;

    CommandName := UpperCase(Trim(Copy(MoveText, 1, FirstSeparatorPos - 1)));
    if CommandName <> '3D_BODY_SELECTED_DUMP' then
        Exit;

    RemainderText := Copy(MoveText, FirstSeparatorPos + 1, Length(MoveText) - FirstSeparatorPos);
    SecondSeparatorPos := Pos('|', RemainderText);
    if SecondSeparatorPos <= 1 then
        Exit;

    DestinationText := Copy(RemainderText, 1, SecondSeparatorPos - 1);
    LineWidthText := Copy(RemainderText, SecondSeparatorPos + 1, Length(RemainderText) - SecondSeparatorPos);

    if not TryParsePositiveInteger(DestinationText, DestinationNumber) then
        Exit;

    if (DestinationNumber < 1) or (DestinationNumber > 32) then
        Exit;

    LineWidthMM := SafeStrToFloat(LineWidthText);
    Result := LineWidthMM > 0;
end;

function Find3DBodySelectedDumpCommand(LayerMoves: TStringList; var DestinationNumber: Integer; var LineWidthMM: Double): Boolean;
var
    i: Integer;
begin
    Result := False;
    DestinationNumber := 0;
    LineWidthMM := 0;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if Parse3DBodySelectedDumpCommand(LayerMoves[i], DestinationNumber, LineWidthMM) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function Parse3DBodyTextCommand(MoveText: String; var DestinationNumber: Integer; var ReferenceFootprintName: String): Boolean;
var
    FirstSeparatorPos: Integer;
    SecondSeparatorPos: Integer;
    CommandName: String;
    RemainderText: String;
    DestinationText: String;
begin
    Result := False;
    DestinationNumber := 0;
    ReferenceFootprintName := '';
    MoveText := Trim(MoveText);

    FirstSeparatorPos := Pos('|', MoveText);
    if FirstSeparatorPos <= 1 then
        Exit;

    CommandName := UpperCase(Trim(Copy(MoveText, 1, FirstSeparatorPos - 1)));
    if CommandName <> '3D_BODY_TEXT' then
        Exit;

    RemainderText := Copy(MoveText, FirstSeparatorPos + 1, Length(MoveText) - FirstSeparatorPos);
    SecondSeparatorPos := Pos('|', RemainderText);
    if SecondSeparatorPos > 1 then
    begin
        DestinationText := Copy(RemainderText, 1, SecondSeparatorPos - 1);
        ReferenceFootprintName := Trim(Copy(RemainderText, SecondSeparatorPos + 1, Length(RemainderText) - SecondSeparatorPos));
    end
    else
    begin
        DestinationText := RemainderText;
        ReferenceFootprintName := '';
    end;

    if not TryParsePositiveInteger(DestinationText, DestinationNumber) then
        Exit;

    if (DestinationNumber < 1) or (DestinationNumber > 32) then
        Exit;

    Result := True;
end;

function Find3DBodyTextCommand(LayerMoves: TStringList; var DestinationNumber: Integer; var ReferenceFootprintName: String): Boolean;
var
    i: Integer;
begin
    Result := False;
    DestinationNumber := 0;
    ReferenceFootprintName := '';

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if Parse3DBodyTextCommand(LayerMoves[i], DestinationNumber, ReferenceFootprintName) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function Parse3DBodyTextDumpCommand(MoveText: String; var DestinationNumber: Integer; var FootprintName: String): Boolean;
var
    FirstSeparatorPos: Integer;
    SecondSeparatorPos: Integer;
    CommandName: String;
    RemainderText: String;
    DestinationText: String;
begin
    Result := False;
    DestinationNumber := 0;
    FootprintName := '';
    MoveText := Trim(MoveText);

    FirstSeparatorPos := Pos('|', MoveText);
    if FirstSeparatorPos <= 1 then
        Exit;

    CommandName := UpperCase(Trim(Copy(MoveText, 1, FirstSeparatorPos - 1)));
    if CommandName <> '3D_BODY_TEXT_DUMP' then
        Exit;

    RemainderText := Copy(MoveText, FirstSeparatorPos + 1, Length(MoveText) - FirstSeparatorPos);
    SecondSeparatorPos := Pos('|', RemainderText);
    if SecondSeparatorPos <= 1 then
        Exit;

    DestinationText := Copy(RemainderText, 1, SecondSeparatorPos - 1);
    FootprintName := Trim(Copy(RemainderText, SecondSeparatorPos + 1, Length(RemainderText) - SecondSeparatorPos));
    if FootprintName = '' then
        Exit;

    if not TryParsePositiveInteger(DestinationText, DestinationNumber) then
        Exit;

    if (DestinationNumber < 1) or (DestinationNumber > 32) then
        Exit;

    Result := True;
end;

function Find3DBodyTextDumpCommand(LayerMoves: TStringList; var DestinationNumber: Integer; var FootprintName: String): Boolean;
var
    i: Integer;
begin
    Result := False;
    DestinationNumber := 0;
    FootprintName := '';

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if Parse3DBodyTextDumpCommand(LayerMoves[i], DestinationNumber, FootprintName) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function Parse3DBodyEditorCleanCommand(MoveText: String; var DestinationNumber: Integer; var LineWidthMM: Double): Boolean;
var
    FirstSeparatorPos: Integer;
    SecondSeparatorPos: Integer;
    CommandName: String;
    RemainderText: String;
    DestinationText: String;
    LineWidthText: String;
begin
    Result := False;
    DestinationNumber := 0;
    LineWidthMM := 0;
    MoveText := Trim(MoveText);

    FirstSeparatorPos := Pos('|', MoveText);
    if FirstSeparatorPos <= 1 then
        Exit;

    CommandName := UpperCase(Trim(Copy(MoveText, 1, FirstSeparatorPos - 1)));
    if CommandName <> '3D_BODY_EDITOR_CLEAN' then
        Exit;

    RemainderText := Copy(MoveText, FirstSeparatorPos + 1, Length(MoveText) - FirstSeparatorPos);
    SecondSeparatorPos := Pos('|', RemainderText);
    if SecondSeparatorPos <= 1 then
        Exit;

    DestinationText := Copy(RemainderText, 1, SecondSeparatorPos - 1);
    LineWidthText := Copy(RemainderText, SecondSeparatorPos + 1, Length(RemainderText) - SecondSeparatorPos);

    if not TryParsePositiveInteger(DestinationText, DestinationNumber) then
        Exit;

    if (DestinationNumber < 1) or (DestinationNumber > 32) then
        Exit;

    LineWidthMM := SafeStrToFloat(LineWidthText);
    Result := LineWidthMM > 0;
end;

function Find3DBodyEditorCleanCommand(LayerMoves: TStringList; var DestinationNumber: Integer; var LineWidthMM: Double): Boolean;
var
    i: Integer;
begin
    Result := False;
    DestinationNumber := 0;
    LineWidthMM := 0;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if Parse3DBodyEditorCleanCommand(LayerMoves[i], DestinationNumber, LineWidthMM) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function Parse3DBodyEditorDeleteCommand(MoveText: String; var FootprintName: String): Boolean;
var
    Fields: TStringList;
begin
    Result := False;
    FootprintName := '*';

    Fields := TStringList.Create;
    try
        Fields.Delimiter := '|';
        Fields.StrictDelimiter := True;
        Fields.DelimitedText := Trim(MoveText);

        if Fields.Count < 1 then
            Exit;
        if UpperCase(Trim(Fields[0])) <> '3D_BODY_EDITOR_DELETE' then
            Exit;

        if (Fields.Count >= 2) and (Trim(Fields[1]) <> '') then
            FootprintName := Trim(Fields[1]);

        Result := True;
    finally
        Fields.Free;
    end;
end;

function Find3DBodyEditorDeleteCommand(LayerMoves: TStringList; var FootprintName: String): Boolean;
var
    i: Integer;
begin
    Result := False;
    FootprintName := '*';

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if Parse3DBodyEditorDeleteCommand(LayerMoves[i], FootprintName) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function Parse3DBodyImportCommand(MoveText: String; var FootprintName, StepPath: String; var LocalXMM, LocalYMM, RotX, RotY, RotZ, ModelZMM, StandoffMM, OverallHeightMM: Double): Boolean;
var
    CommandName: String;
    Fields     : TStringList;
    Remainder  : String;
    Separator  : Integer;
begin
    Result := False;
    FootprintName := '';
    StepPath := '';
    LocalXMM := 0;
    LocalYMM := 0;
    RotX := 0;
    RotY := 0;
    RotZ := 0;
    ModelZMM := 0;
    StandoffMM := 0;
    OverallHeightMM := 0;

    MoveText := Trim(MoveText);
    Separator := Pos('|', MoveText);
    if Separator <= 1 then
        Exit;

    CommandName := UpperCase(Trim(Copy(MoveText, 1, Separator - 1)));
    if CommandName <> '3D_BODY_IMPORT' then
        Exit;

    Remainder := Copy(MoveText, Separator + 1, Length(MoveText) - Separator);
    Fields := TStringList.Create;
    try
        Fields.Delimiter := '|';
        Fields.StrictDelimiter := True;
        Fields.DelimitedText := Remainder;

        if Fields.Count < 9 then
            Exit;

        FootprintName := Trim(Fields[0]);
        StepPath := Trim(Fields[1]);
        if (FootprintName = '') or (StepPath = '') then
            Exit;

        LocalXMM := SafeStrToFloat(Trim(Fields[2]));
        LocalYMM := SafeStrToFloat(Trim(Fields[3]));
        RotX := SafeStrToFloat(Trim(Fields[4]));
        RotY := SafeStrToFloat(Trim(Fields[5]));
        RotZ := SafeStrToFloat(Trim(Fields[6]));
        if Fields.Count >= 10 then
        begin
            ModelZMM := SafeStrToFloat(Trim(Fields[7]));
            StandoffMM := SafeStrToFloat(Trim(Fields[8]));
            OverallHeightMM := SafeStrToFloat(Trim(Fields[9]));
        end
        else
        begin
            StandoffMM := SafeStrToFloat(Trim(Fields[7]));
            OverallHeightMM := SafeStrToFloat(Trim(Fields[8]));
        end;

        Result := True;
    finally
        Fields.Free;
    end;
end;

function Find3DBodyImportCommand(LayerMoves: TStringList; var FootprintName, StepPath: String; var LocalXMM, LocalYMM, RotX, RotY, RotZ, ModelZMM, StandoffMM, OverallHeightMM: Double): Boolean;
var
    i: Integer;
begin
    Result := False;
    FootprintName := '';
    StepPath := '';
    ModelZMM := 0;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if Parse3DBodyImportCommand(LayerMoves[i], FootprintName, StepPath, LocalXMM, LocalYMM, RotX, RotY, RotZ, ModelZMM, StandoffMM, OverallHeightMM) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function Parse3DBodySetHeightsCommand(MoveText: String; var FootprintName: String; var StandoffMM, OverallHeightMM: Double): Boolean;
var
    CommandName: String;
    Fields     : TStringList;
    Remainder  : String;
    Separator  : Integer;
begin
    Result := False;
    FootprintName := '';
    StandoffMM := 0;
    OverallHeightMM := 0;

    MoveText := Trim(MoveText);
    Separator := Pos('|', MoveText);
    if Separator <= 1 then
        Exit;

    CommandName := UpperCase(Trim(Copy(MoveText, 1, Separator - 1)));
    if CommandName <> '3D_BODY_SET_HEIGHTS' then
        Exit;

    Remainder := Copy(MoveText, Separator + 1, Length(MoveText) - Separator);
    Fields := TStringList.Create;
    try
        Fields.Delimiter := '|';
        Fields.StrictDelimiter := True;
        Fields.DelimitedText := Remainder;

        if Fields.Count < 3 then
            Exit;

        FootprintName := Trim(Fields[0]);
        if FootprintName = '' then
            Exit;

        StandoffMM := SafeStrToFloat(Trim(Fields[1]));
        OverallHeightMM := SafeStrToFloat(Trim(Fields[2]));

        Result := OverallHeightMM >= StandoffMM;
    finally
        Fields.Free;
    end;
end;

function Find3DBodySetHeightsCommand(LayerMoves: TStringList; var FootprintName: String; var StandoffMM, OverallHeightMM: Double): Boolean;
var
    i: Integer;
begin
    Result := False;
    FootprintName := '';
    StandoffMM := 0;
    OverallHeightMM := 0;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if Parse3DBodySetHeightsCommand(LayerMoves[i], FootprintName, StandoffMM, OverallHeightMM) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function Parse3DBodySetIdentifierCommand(MoveText: String; var FootprintName, IdentifierText: String): Boolean;
var
    CommandName: String;
    Fields     : TStringList;
    Remainder  : String;
    Separator  : Integer;
begin
    Result := False;
    FootprintName := '';
    IdentifierText := '';

    MoveText := Trim(MoveText);
    Separator := Pos('|', MoveText);
    if Separator <= 1 then
        Exit;

    CommandName := UpperCase(Trim(Copy(MoveText, 1, Separator - 1)));
    if CommandName <> '3D_BODY_SET_IDENTIFIER' then
        Exit;

    Remainder := Copy(MoveText, Separator + 1, Length(MoveText) - Separator);
    Fields := TStringList.Create;
    try
        Fields.Delimiter := '|';
        Fields.StrictDelimiter := True;
        Fields.DelimitedText := Remainder;

        if Fields.Count < 2 then
            Exit;

        FootprintName := Trim(Fields[0]);
        IdentifierText := Trim(Fields[1]);
        Result := (FootprintName <> '') and (IdentifierText <> '');
    finally
        Fields.Free;
    end;
end;

function Find3DBodySetIdentifierCommand(LayerMoves: TStringList; var FootprintName, IdentifierText: String): Boolean;
var
    i: Integer;
begin
    Result := False;
    FootprintName := '';
    IdentifierText := '';

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if Parse3DBodySetIdentifierCommand(LayerMoves[i], FootprintName, IdentifierText) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function Parse3DBodyFixOriginOffsetCommand(MoveText: String; var FootprintName: String): Boolean;
var
    CommandName: String;
    Separator  : Integer;
begin
    Result := False;
    FootprintName := '';

    MoveText := Trim(MoveText);
    Separator := Pos('|', MoveText);
    if Separator <= 1 then
        Exit;

    CommandName := UpperCase(Trim(Copy(MoveText, 1, Separator - 1)));
    if CommandName <> '3D_BODY_FIX_ORIGIN_OFFSET' then
        Exit;

    FootprintName := Trim(Copy(MoveText, Separator + 1, Length(MoveText) - Separator));
    if FootprintName = '' then
        FootprintName := '*';

    Result := True;
end;

function Find3DBodyFixOriginOffsetCommand(LayerMoves: TStringList; var FootprintName: String): Boolean;
var
    i: Integer;
begin
    Result := False;
    FootprintName := '';

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if Parse3DBodyFixOriginOffsetCommand(LayerMoves[i], FootprintName) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function Parse3DBodyParamsDumpCommand(MoveText: String; var FootprintName: String): Boolean;
var
    CommandName: String;
    Separator  : Integer;
begin
    Result := False;
    FootprintName := '';

    MoveText := Trim(MoveText);
    Separator := Pos('|', MoveText);
    if Separator <= 1 then
        Exit;

    CommandName := UpperCase(Trim(Copy(MoveText, 1, Separator - 1)));
    if CommandName <> '3D_BODY_PARAMS_DUMP' then
        Exit;

    FootprintName := Trim(Copy(MoveText, Separator + 1, Length(MoveText) - Separator));
    Result := FootprintName <> '';
end;

function Find3DBodyParamsDumpCommand(LayerMoves: TStringList; var FootprintName: String): Boolean;
var
    i: Integer;
begin
    Result := False;
    FootprintName := '';

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if Parse3DBodyParamsDumpCommand(LayerMoves[i], FootprintName) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function Parse3DBodySetColorCommand(MoveText: String; var RedValue, GreenValue, BlueValue: Integer): Boolean;
var
    CommandName: String;
    Separator  : Integer;
    Remainder  : String;
    Fields     : TStringList;
begin
    Result := False;
    RedValue := 0;
    GreenValue := 0;
    BlueValue := 0;

    MoveText := Trim(MoveText);
    Separator := Pos('|', MoveText);
    if Separator <= 1 then
        Exit;

    CommandName := UpperCase(Trim(Copy(MoveText, 1, Separator - 1)));
    if CommandName <> '3D_BODY_SET_COLOR' then
        Exit;

    Remainder := Copy(MoveText, Separator + 1, Length(MoveText) - Separator);
    Fields := TStringList.Create;
    try
        Fields.Delimiter := '|';
        Fields.StrictDelimiter := True;
        Fields.DelimitedText := Remainder;

        if Fields.Count < 3 then
            Exit;

        RedValue := StrToIntDef(Trim(Fields[0]), -1);
        GreenValue := StrToIntDef(Trim(Fields[1]), -1);
        BlueValue := StrToIntDef(Trim(Fields[2]), -1);

        Result := (RedValue >= 0) and (RedValue <= 255) and
                  (GreenValue >= 0) and (GreenValue <= 255) and
                  (BlueValue >= 0) and (BlueValue <= 255);
    finally
        Fields.Free;
    end;
end;

function Find3DBodySetColorCommand(LayerMoves: TStringList; var RedValue, GreenValue, BlueValue: Integer): Boolean;
var
    i: Integer;
begin
    Result := False;
    RedValue := 0;
    GreenValue := 0;
    BlueValue := 0;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if Parse3DBodySetColorCommand(LayerMoves[i], RedValue, GreenValue, BlueValue) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function SetPCBLibrary3DBodyColor(ExcludeFootprints: TStringList; RedValue, GreenValue, BlueValue: Integer): String;
var
    PcbLib              : IPCB_Library;
    Board               : IPCB_Board;
    FootprintIterator   : IPCB_LibraryIterator;
    Footprint           : IPCB_LibComponent;
    ActiveFootprint     : IPCB_LibComponent;
    BodyIterator        : IPCB_GroupIterator;
    Primitive           : IPCB_Primitive;
    Body                : IPCB_ComponentBody;
    ResultProps         : TStringList;
    ModifiedFootprints  : TStringList;
    SkippedFootprints   : TStringList;
    OutputLines         : TStringList;
    FootprintName       : String;
    FootprintsSeen      : Integer;
    FootprintsProcessed : Integer;
    FootprintsModified  : Integer;
    BodiesSeen          : Integer;
    BodiesUpdated       : Integer;
    FootprintBodiesUpdated : Integer;
    PackedColor         : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    Board := PcbLib.Board;
    ResultProps := TStringList.Create;
    ModifiedFootprints := TStringList.Create;
    SkippedFootprints := TStringList.Create;
    OutputLines := TStringList.Create;
    FootprintsSeen := 0;
    FootprintsProcessed := 0;
    FootprintsModified := 0;
    BodiesSeen := 0;
    BodiesUpdated := 0;
    PackedColor := RedValue + (GreenValue * 256) + (BlueValue * 65536);

    try
        PCBServer.PreProcess;
        try
            FootprintIterator := PcbLib.LibraryIterator_Create;
            if FootprintIterator = Nil then
            begin
                Result := '{"success": false, "error": "Failed to create PCB library footprint iterator."}';
                Exit;
            end;

            try
                FootprintIterator.SetState_FilterAll;
                Footprint := FootprintIterator.FirstPCBObject;
                while Footprint <> Nil do
                begin
                    FootprintsSeen := FootprintsSeen + 1;
                    FootprintName := Footprint.Name;

                    if StringListContainsText(ExcludeFootprints, FootprintName) then
                    begin
                        SkippedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                    end
                    else
                    begin
                        FootprintsProcessed := FootprintsProcessed + 1;
                        PcbLib.CurrentComponent := Footprint;
                        ActiveFootprint := PcbLib.CurrentComponent;
                        FootprintBodiesUpdated := 0;

                        BodyIterator := Nil;
                        if ActiveFootprint <> Nil then
                            BodyIterator := ActiveFootprint.GroupIterator_Create;

                        if BodyIterator <> Nil then
                        begin
                            try
                                BodyIterator.AddFilter_ObjectSet(MkSet(eComponentBodyObject));
                                BodyIterator.AddFilter_LayerSet(AllLayers);

                                Primitive := BodyIterator.FirstPCBObject;
                                while Primitive <> Nil do
                                begin
                                    BodiesSeen := BodiesSeen + 1;
                                    Body := Primitive;
                                    PCBServer.SendMessageToRobots(Primitive.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
                                    try
                                        Body.BodyColor3D := PackedColor;
                                        Body.OverrideColor := True;
                                        Primitive.GraphicallyInvalidate;
                                        BodiesUpdated := BodiesUpdated + 1;
                                        FootprintBodiesUpdated := FootprintBodiesUpdated + 1;
                                    finally
                                        PCBServer.SendMessageToRobots(Primitive.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
                                    end;

                                    Primitive := BodyIterator.NextPCBObject;
                                end;
                            finally
                                ActiveFootprint.GroupIterator_Destroy(BodyIterator);
                            end;
                        end;

                        if FootprintBodiesUpdated > 0 then
                        begin
                            FootprintsModified := FootprintsModified + 1;
                            ModifiedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                        end;
                    end;

                    Footprint := FootprintIterator.NextPCBObject;
                end;
            finally
                PcbLib.LibraryIterator_Destroy(FootprintIterator);
            end;
        finally
            PCBServer.PostProcess;
        end;

        if Board <> Nil then
            Board.ViewManager_FullUpdate;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONInteger(ResultProps, 'red', RedValue);
        AddJSONInteger(ResultProps, 'green', GreenValue);
        AddJSONInteger(ResultProps, 'blue', BlueValue);
        AddJSONInteger(ResultProps, 'body_color_3d', PackedColor);
        AddJSONInteger(ResultProps, 'footprints_seen', FootprintsSeen);
        AddJSONInteger(ResultProps, 'footprints_processed', FootprintsProcessed);
        AddJSONInteger(ResultProps, 'footprints_modified', FootprintsModified);
        AddJSONInteger(ResultProps, 'bodies_seen', BodiesSeen);
        AddJSONInteger(ResultProps, 'bodies_updated', BodiesUpdated);
        ResultProps.Add(BuildJSONArray(SkippedFootprints, 'skipped_footprints'));
        ResultProps.Add(BuildJSONArray(ModifiedFootprints, 'modified_footprints'));

        OutputLines.Text := BuildJSONObject(ResultProps);
        Result := OutputLines.Text;
    finally
        OutputLines.Free;
        SkippedFootprints.Free;
        ModifiedFootprints.Free;
        ResultProps.Free;
    end;
end;

function Parse3DBodySetPlacementCommand(MoveText: String; var FootprintName: String; var LocalXMM, LocalYMM, RotX, RotY, RotZ, ModelZMM, StandoffMM, OverallHeightMM: Double): Boolean;
var
    CommandName: String;
    Separator  : Integer;
    Remainder  : String;
    Fields     : TStringList;
begin
    Result := False;
    FootprintName := '';
    LocalXMM := 0;
    LocalYMM := 0;
    RotX := 0;
    RotY := 0;
    RotZ := 0;
    ModelZMM := 0;
    StandoffMM := 0;
    OverallHeightMM := 0;

    MoveText := Trim(MoveText);
    Separator := Pos('|', MoveText);
    if Separator <= 1 then
        Exit;

    CommandName := UpperCase(Trim(Copy(MoveText, 1, Separator - 1)));
    if CommandName <> '3D_BODY_SET_PLACEMENT' then
        Exit;

    Remainder := Copy(MoveText, Separator + 1, Length(MoveText) - Separator);
    Fields := TStringList.Create;
    try
        Fields.Delimiter := '|';
        Fields.StrictDelimiter := True;
        Fields.DelimitedText := Remainder;

        if Fields.Count < 9 then
            Exit;

        FootprintName := Trim(Fields[0]);
        if FootprintName = '' then
            Exit;

        LocalXMM := SafeStrToFloat(Trim(Fields[1]));
        LocalYMM := SafeStrToFloat(Trim(Fields[2]));
        RotX := SafeStrToFloat(Trim(Fields[3]));
        RotY := SafeStrToFloat(Trim(Fields[4]));
        RotZ := SafeStrToFloat(Trim(Fields[5]));
        ModelZMM := SafeStrToFloat(Trim(Fields[6]));
        StandoffMM := SafeStrToFloat(Trim(Fields[7]));
        OverallHeightMM := SafeStrToFloat(Trim(Fields[8]));

        Result := OverallHeightMM >= StandoffMM;
    finally
        Fields.Free;
    end;
end;

function Find3DBodySetPlacementCommand(LayerMoves: TStringList; var FootprintName: String; var LocalXMM, LocalYMM, RotX, RotY, RotZ, ModelZMM, StandoffMM, OverallHeightMM: Double): Boolean;
var
    i: Integer;
begin
    Result := False;
    FootprintName := '';
    LocalXMM := 0;
    LocalYMM := 0;
    RotX := 0;
    RotY := 0;
    RotZ := 0;
    ModelZMM := 0;
    StandoffMM := 0;
    OverallHeightMM := 0;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if Parse3DBodySetPlacementCommand(
            LayerMoves[i],
            FootprintName,
            LocalXMM,
            LocalYMM,
            RotX,
            RotY,
            RotZ,
            ModelZMM,
            StandoffMM,
            OverallHeightMM
        ) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function FindMechanicalLayerMove(CurrentLayer: TLayer; LayerMoves: TStringList; var SourceNumber: Integer; var DestinationNumber: Integer): Boolean;
var
    i: Integer;
    ParsedSource: Integer;
    ParsedDestination: Integer;
begin
    Result := False;
    SourceNumber := 0;
    DestinationNumber := 0;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if ParseMechanicalLayerMove(LayerMoves[i], ParsedSource, ParsedDestination) then
        begin
            if CurrentLayer = ILayer.MechanicalLayer(ParsedSource) then
            begin
                SourceNumber := ParsedSource;
                DestinationNumber := ParsedDestination;
                Result := True;
                Exit;
            end;
        end;
    end;
end;

function DumpPCBLibrary3DBodies(ExcludeFootprints: TStringList): String;
var
    PcbLib              : IPCB_Library;
    Board               : IPCB_Board;
    FootprintIterator   : IPCB_LibraryIterator;
    Footprint           : IPCB_LibComponent;
    ActiveFootprint     : IPCB_LibComponent;
    BodyIterator        : IPCB_GroupIterator;
    Primitive           : IPCB_Primitive;
    Body                : IPCB_ComponentBody;
    Model               : IPCB_Model;
    Rect                : TCoordRect;
    ResultProps         : TStringList;
    BodyArray           : TStringList;
    BodyProps           : TStringList;
    OutputLines         : TStringList;
    FootprintName       : String;
    FootprintsSeen      : Integer;
    FootprintsProcessed : Integer;
    BodiesSeen          : Integer;
    LeftMM, BottomMM, RightMM, TopMM : Double;
    RawLeftMM, RawBottomMM, RawRightMM, RawTopMM : Double;
    ModelRotX, ModelRotY, ModelRotZ : Double;
    ModelZ              : TCoord;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    ResultProps := TStringList.Create;
    BodyArray := TStringList.Create;
    Board := PcbLib.Board;
    FootprintsSeen := 0;
    FootprintsProcessed := 0;
    BodiesSeen := 0;

    try
        FootprintIterator := PcbLib.LibraryIterator_Create;
        if FootprintIterator = Nil then
        begin
            Result := '{"success": false, "error": "Failed to create PCB library footprint iterator."}';
            Exit;
        end;

        FootprintIterator.SetState_FilterAll;

        try
            Footprint := FootprintIterator.FirstPCBObject;
            while Footprint <> Nil do
            begin
                FootprintsSeen := FootprintsSeen + 1;
                FootprintName := Footprint.Name;

                if not StringListContainsText(ExcludeFootprints, FootprintName) then
                begin
                    FootprintsProcessed := FootprintsProcessed + 1;

                    PcbLib.CurrentComponent := Footprint;
                    ActiveFootprint := PcbLib.CurrentComponent;
                    if Board <> Nil then
                        Board.ViewManager_FullUpdate;

                    BodyIterator := Nil;
                    if ActiveFootprint <> Nil then
                        BodyIterator := ActiveFootprint.GroupIterator_Create;
                    if BodyIterator <> Nil then
                    begin
                        try
                            BodyIterator.AddFilter_ObjectSet(MkSet(eComponentBodyObject));
                            BodyIterator.AddFilter_LayerSet(AllLayers);

                            Primitive := BodyIterator.FirstPCBObject;
                            while Primitive <> Nil do
                            begin
                                BodiesSeen := BodiesSeen + 1;
                                Body := Primitive;
                                Model := Body.GetModel;
                                Rect := Primitive.BoundingRectangle;
                                LeftMM := CoordToMMs(Rect.Left);
                                BottomMM := CoordToMMs(Rect.Bottom);
                                RightMM := CoordToMMs(Rect.Right);
                                TopMM := CoordToMMs(Rect.Top);
                                RawLeftMM := LeftMM;
                                RawBottomMM := BottomMM;
                                RawRightMM := RightMM;
                                RawTopMM := TopMM;

                                if (Board <> Nil) and
                                   ((Abs(LeftMM) > 100) or (Abs(BottomMM) > 100) or
                                    (Abs(RightMM) > 100) or (Abs(TopMM) > 100)) then
                                begin
                                    LeftMM := CoordToMMs(Rect.Left - Board.XOrigin);
                                    BottomMM := CoordToMMs(Rect.Bottom - Board.YOrigin);
                                    RightMM := CoordToMMs(Rect.Right - Board.XOrigin);
                                    TopMM := CoordToMMs(Rect.Top - Board.YOrigin);
                                end;

                                BodyProps := TStringList.Create;
                                try
                                    AddJSONProperty(BodyProps, 'footprint', FootprintName);
                                    AddJSONProperty(BodyProps, 'object_id', Primitive.ObjectIDString);
                                    AddJSONProperty(BodyProps, 'identifier', Primitive.Identifier);
                                    AddJSONProperty(BodyProps, 'descriptor', Primitive.Descriptor);
                                    AddJSONProperty(BodyProps, 'layer', Layer2String(Primitive.Layer));
                                    AddJSONBoolean(BodyProps, 'in_board', Body.GetState_InBoard);
                                    AddJSONNumber(BodyProps, 'snap_point_x_mm', CoordToMMs(Body.GetState_SnapPointX));
                                    AddJSONNumber(BodyProps, 'snap_point_y_mm', CoordToMMs(Body.GetState_SnapPointY));
                                    AddJSONNumber(BodyProps, 'body_x_mm', CoordToMMs(Body.X));
                                    AddJSONNumber(BodyProps, 'body_y_mm', CoordToMMs(Body.Y));
                                    if Board <> Nil then
                                    begin
                                        AddJSONNumber(BodyProps, 'board_x_origin_mm', CoordToMMs(Board.XOrigin));
                                        AddJSONNumber(BodyProps, 'board_y_origin_mm', CoordToMMs(Board.YOrigin));
                                    end;
                                    AddJSONNumber(BodyProps, 'raw_left_mm', RawLeftMM);
                                    AddJSONNumber(BodyProps, 'raw_bottom_mm', RawBottomMM);
                                    AddJSONNumber(BodyProps, 'raw_right_mm', RawRightMM);
                                    AddJSONNumber(BodyProps, 'raw_top_mm', RawTopMM);
                                    AddJSONNumber(BodyProps, 'left_mm', LeftMM);
                                    AddJSONNumber(BodyProps, 'bottom_mm', BottomMM);
                                    AddJSONNumber(BodyProps, 'right_mm', RightMM);
                                    AddJSONNumber(BodyProps, 'top_mm', TopMM);
                                    AddJSONNumber(BodyProps, 'standoff_height_mm', CoordToMMs(Body.StandoffHeight));
                                    AddJSONNumber(BodyProps, 'overall_height_mm', CoordToMMs(Body.OverallHeight));
                                    AddJSONInteger(BodyProps, 'body_projection', Body.BodyProjection);
                                    if Model <> Nil then
                                    begin
                                        ModelRotX := 0;
                                        ModelRotY := 0;
                                        ModelRotZ := 0;
                                        ModelZ := 0;
                                        Model.GetState(ModelRotX, ModelRotY, ModelRotZ, ModelZ);
                                        AddJSONNumber(BodyProps, 'model_rotation_x_deg', ModelRotX);
                                        AddJSONNumber(BodyProps, 'model_rotation_y_deg', ModelRotY);
                                        AddJSONNumber(BodyProps, 'model_rotation_z_deg', ModelRotZ);
                                        AddJSONNumber(BodyProps, 'model_z_mm', CoordToMMs(ModelZ));
                                    end;
                                    BodyArray.Add(BuildJSONObject(BodyProps, 1));
                                finally
                                    BodyProps.Free;
                                end;

                                Primitive := BodyIterator.NextPCBObject;
                            end;
                        finally
                            ActiveFootprint.GroupIterator_Destroy(BodyIterator);
                        end;
                    end;
                end;

                Footprint := FootprintIterator.NextPCBObject;
            end;
        finally
            PcbLib.LibraryIterator_Destroy(FootprintIterator);
        end;

        AddJSONBoolean(ResultProps, 'success', True);
        if Board <> Nil then
            AddJSONProperty(ResultProps, 'library_path', Board.FileName);
        AddJSONInteger(ResultProps, 'footprints_seen', FootprintsSeen);
        AddJSONInteger(ResultProps, 'footprints_processed', FootprintsProcessed);
        AddJSONInteger(ResultProps, 'component_bodies_seen', BodiesSeen);
        ResultProps.Add(BuildJSONArray(BodyArray, 'bodies'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
        BodyArray.Free;
    end;
end;

procedure EnsureMechanicalLayerEnabled(Board: IPCB_Board; LayerNumber: Integer);
var
    LayerStack: IPCB_LayerStack_V7;
    MechLayer: IPCB_MechanicalLayer;
begin
    if Board = Nil then
        Exit;

    LayerStack := Board.LayerStack_V7;
    if LayerStack = Nil then
        Exit;

    MechLayer := LayerStack.LayerObject_V7[ILayer.MechanicalLayer(LayerNumber)];
    if MechLayer <> Nil then
        MechLayer.MechanicalLayerEnabled := True;
end;

function AddProjectionTrack(Footprint: IPCB_LibComponent; DestinationLayer: TLayer; X1, Y1, X2, Y2: TCoord; LineWidth: TCoord): Boolean;
var
    Track: IPCB_Track;
begin
    Result := False;

    if Footprint = Nil then
        Exit;

    if (X1 = X2) and (Y1 = Y2) then
        Exit;

    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    if Track = Nil then
        Exit;

    Track.Layer := DestinationLayer;
    Track.x1 := X1;
    Track.y1 := Y1;
    Track.x2 := X2;
    Track.y2 := Y2;
    Track.Width := LineWidth;

    Footprint.AddPCBObject(Track);
    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);
    Result := True;
end;

function AddProjectionBoardTrack(Board: IPCB_Board; DestinationLayer: TLayer; X1, Y1, X2, Y2: TCoord; LineWidth: TCoord): Boolean;
var
    Track: IPCB_Track;
begin
    Result := False;

    if Board = Nil then
        Exit;

    if (X1 = X2) and (Y1 = Y2) then
        Exit;

    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    if Track = Nil then
        Exit;

    Track.Layer := DestinationLayer;
    Track.x1 := X1;
    Track.y1 := Y1;
    Track.x2 := X2;
    Track.y2 := Y2;
    Track.Width := LineWidth;

    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
    Board.AddPCBObject(Track);
    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
    Result := True;
end;

function AddProjectionBoardArc(Board: IPCB_Board; DestinationLayer: TLayer; XCenter, YCenter, Radius: TCoord; StartAngle, EndAngle: Double; LineWidth: TCoord): Boolean;
var
    Arc: IPCB_Arc;
begin
    Result := False;

    if Board = Nil then
        Exit;

    if Radius <= 0 then
        Exit;

    Arc := PCBServer.PCBObjectFactory(eArcObject, eNoDimension, eCreate_Default);
    if Arc = Nil then
        Exit;

    Arc.Layer := DestinationLayer;
    Arc.XCenter := XCenter;
    Arc.YCenter := YCenter;
    Arc.Radius := Radius;
    Arc.StartAngle := StartAngle;
    Arc.EndAngle := EndAngle;
    Arc.LineWidth := LineWidth;

    PCBServer.SendMessageToRobots(Arc.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
    Board.AddPCBObject(Arc);
    PCBServer.SendMessageToRobots(Arc.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
    Result := True;
end;

function AddProjectionRectangle(Footprint: IPCB_LibComponent; DestinationLayer: TLayer; Rect: TCoordRect; LineWidth: TCoord): Integer;
begin
    Result := 0;

    if (Rect.Left = Rect.Right) or (Rect.Top = Rect.Bottom) then
        Exit;

    if AddProjectionTrack(Footprint, DestinationLayer, Rect.Left, Rect.Bottom, Rect.Right, Rect.Bottom, LineWidth) then
        Result := Result + 1;

    if AddProjectionTrack(Footprint, DestinationLayer, Rect.Right, Rect.Bottom, Rect.Right, Rect.Top, LineWidth) then
        Result := Result + 1;

    if AddProjectionTrack(Footprint, DestinationLayer, Rect.Right, Rect.Top, Rect.Left, Rect.Top, LineWidth) then
        Result := Result + 1;

    if AddProjectionTrack(Footprint, DestinationLayer, Rect.Left, Rect.Top, Rect.Left, Rect.Bottom, LineWidth) then
        Result := Result + 1;
end;

function ParseSilhouetteSegment(SegmentLine: String; var FootprintName: String; var X1MM, Y1MM, X2MM, Y2MM: Double): Boolean;
var
    FieldText: String;
    SeparatorPos: Integer;
begin
    Result := False;
    FootprintName := '';
    SegmentLine := Trim(SegmentLine);

    SeparatorPos := Pos('|', SegmentLine);
    if SeparatorPos <= 1 then
        Exit;
    FootprintName := Trim(Copy(SegmentLine, 1, SeparatorPos - 1));
    Delete(SegmentLine, 1, SeparatorPos);

    SeparatorPos := Pos('|', SegmentLine);
    if SeparatorPos <= 1 then
        Exit;
    FieldText := Trim(Copy(SegmentLine, 1, SeparatorPos - 1));
    X1MM := SafeStrToFloat(FieldText);
    Delete(SegmentLine, 1, SeparatorPos);

    SeparatorPos := Pos('|', SegmentLine);
    if SeparatorPos <= 1 then
        Exit;
    FieldText := Trim(Copy(SegmentLine, 1, SeparatorPos - 1));
    Y1MM := SafeStrToFloat(FieldText);
    Delete(SegmentLine, 1, SeparatorPos);

    SeparatorPos := Pos('|', SegmentLine);
    if SeparatorPos <= 1 then
        Exit;
    FieldText := Trim(Copy(SegmentLine, 1, SeparatorPos - 1));
    X2MM := SafeStrToFloat(FieldText);
    Delete(SegmentLine, 1, SeparatorPos);

    Y2MM := SafeStrToFloat(Trim(SegmentLine));
    Result := FootprintName <> '';
end;

function PopSilhouetteField(var Text: String; var FieldValue: String): Boolean;
var
    SeparatorPos: Integer;
begin
    Result := False;
    Text := Trim(Text);
    if Text = '' then
        Exit;

    SeparatorPos := Pos('|', Text);
    if SeparatorPos > 0 then
    begin
        FieldValue := Trim(Copy(Text, 1, SeparatorPos - 1));
        Delete(Text, 1, SeparatorPos);
    end
    else
    begin
        FieldValue := Trim(Text);
        Text := '';
    end;
    Result := True;
end;

function ParseSilhouettePrimitive(PrimitiveLine: String; var FootprintName: String; var PrimitiveKind: String; var X1MM, Y1MM, X2MM, Y2MM, CenterXMM, CenterYMM, RadiusMM, StartAngle, EndAngle: Double): Boolean;
var
    FieldText: String;
begin
    Result := False;
    FootprintName := '';
    PrimitiveKind := '';
    X1MM := 0;
    Y1MM := 0;
    X2MM := 0;
    Y2MM := 0;
    CenterXMM := 0;
    CenterYMM := 0;
    RadiusMM := 0;
    StartAngle := 0;
    EndAngle := 0;

    if not PopSilhouetteField(PrimitiveLine, FootprintName) then
        Exit;
    if FootprintName = '' then
        Exit;

    if not PopSilhouetteField(PrimitiveLine, FieldText) then
        Exit;

    PrimitiveKind := UpperCase(FieldText);
    if (PrimitiveKind <> 'LINE') and (PrimitiveKind <> 'ARC') then
    begin
        PrimitiveKind := 'LINE';
        X1MM := SafeStrToFloat(FieldText);
    end
    else
    begin
        if not PopSilhouetteField(PrimitiveLine, FieldText) then
            Exit;
        X1MM := SafeStrToFloat(FieldText);
    end;

    if PrimitiveKind = 'LINE' then
    begin
        if not PopSilhouetteField(PrimitiveLine, FieldText) then
            Exit;
        Y1MM := SafeStrToFloat(FieldText);
        if not PopSilhouetteField(PrimitiveLine, FieldText) then
            Exit;
        X2MM := SafeStrToFloat(FieldText);
        if not PopSilhouetteField(PrimitiveLine, FieldText) then
            Exit;
        Y2MM := SafeStrToFloat(FieldText);
        Result := True;
    end
    else if PrimitiveKind = 'ARC' then
    begin
        CenterXMM := X1MM;
        if not PopSilhouetteField(PrimitiveLine, FieldText) then
            Exit;
        CenterYMM := SafeStrToFloat(FieldText);
        if not PopSilhouetteField(PrimitiveLine, FieldText) then
            Exit;
        RadiusMM := SafeStrToFloat(FieldText);
        if not PopSilhouetteField(PrimitiveLine, FieldText) then
            Exit;
        StartAngle := SafeStrToFloat(FieldText);
        if not PopSilhouetteField(PrimitiveLine, FieldText) then
            Exit;
        EndAngle := SafeStrToFloat(FieldText);
        Result := RadiusMM > 0;
    end;
end;

function RemoveProjectionTracks(Footprint: IPCB_LibComponent; DestinationLayer: TLayer; LineWidth: TCoord): Integer;
var
    PrimitiveIterator: IPCB_GroupIterator;
    Primitive: IPCB_Primitive;
    Track: IPCB_Track;
    Arc: IPCB_Arc;
    TracksToRemove: TObjectList;
begin
    Result := 0;

    if Footprint = Nil then
        Exit;

    TracksToRemove := TObjectList.Create;
    TracksToRemove.OwnsObjects := False;
    PrimitiveIterator := Footprint.GroupIterator_Create;
    if PrimitiveIterator = Nil then
    begin
        TracksToRemove.Free;
        Exit;
    end;

    try
        PrimitiveIterator.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject));
        PrimitiveIterator.AddFilter_LayerSet(MkSet(DestinationLayer));

        Primitive := PrimitiveIterator.FirstPCBObject;
        while Primitive <> Nil do
        begin
            if Primitive.ObjectId = eTrackObject then
            begin
                Track := Primitive;
                if Track.Width = LineWidth then
                    TracksToRemove.Add(Primitive);
            end
            else if Primitive.ObjectId = eArcObject then
            begin
                Arc := Primitive;
                if Arc.LineWidth = LineWidth then
                    TracksToRemove.Add(Primitive);
            end;

            Primitive := PrimitiveIterator.NextPCBObject;
        end;
    finally
        Footprint.GroupIterator_Destroy(PrimitiveIterator);
    end;

    try
        while TracksToRemove.Count > 0 do
        begin
            Primitive := TracksToRemove[0];
            TracksToRemove.Delete(0);
            if Primitive <> Nil then
            begin
                Footprint.RemovePCBObject(Primitive);
                Primitive := Nil;
                Result := Result + 1;
            end;
        end;

        if Result > 0 then
            PCBServer.SendMessageToRobots(Footprint.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);
    finally
        TracksToRemove.Free;
    end;
end;

function CountPCBLibraryProjectionTracks(ExcludeFootprints: TStringList; DestinationLayerNumber: Integer; LineWidthMM: Double): String;
var
    PcbLib              : IPCB_Library;
    FootprintIterator   : IPCB_LibraryIterator;
    Footprint           : IPCB_LibComponent;
    PrimitiveIterator   : IPCB_GroupIterator;
    Primitive           : IPCB_Primitive;
    Track               : IPCB_Track;
    Arc                 : IPCB_Arc;
    DestinationLayer    : TLayer;
    LineWidth           : TCoord;
    ResultProps         : TStringList;
    CountArray          : TStringList;
    CountProps          : TStringList;
    OutputLines         : TStringList;
    FootprintName       : String;
    FootprintsSeen      : Integer;
    FootprintsProcessed : Integer;
    FootprintTrackCount : Integer;
    FootprintArcCount   : Integer;
    TotalTrackCount     : Integer;
    TotalArcCount       : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    if (DestinationLayerNumber < 1) or (DestinationLayerNumber > 32) then
    begin
        Result := '{"success": false, "error": "Mechanical layer number must be between 1 and 32."}';
        Exit;
    end;

    if LineWidthMM <= 0 then
    begin
        Result := '{"success": false, "error": "Line width must be greater than zero."}';
        Exit;
    end;

    DestinationLayer := ILayer.MechanicalLayer(DestinationLayerNumber);
    LineWidth := MMsToCoord(LineWidthMM);
    ResultProps := TStringList.Create;
    CountArray := TStringList.Create;
    FootprintsSeen := 0;
    FootprintsProcessed := 0;
    TotalTrackCount := 0;
    TotalArcCount := 0;

    try
        FootprintIterator := PcbLib.LibraryIterator_Create;
        if FootprintIterator = Nil then
        begin
            Result := '{"success": false, "error": "Failed to create PCB library footprint iterator."}';
            Exit;
        end;

        FootprintIterator.SetState_FilterAll;
        try
            Footprint := FootprintIterator.FirstPCBObject;
            while Footprint <> Nil do
            begin
                FootprintsSeen := FootprintsSeen + 1;
                FootprintName := Footprint.Name;

                if not StringListContainsText(ExcludeFootprints, FootprintName) then
                begin
                    FootprintsProcessed := FootprintsProcessed + 1;
                    FootprintTrackCount := 0;
                    FootprintArcCount := 0;

                    PrimitiveIterator := Footprint.GroupIterator_Create;
                    if PrimitiveIterator <> Nil then
                    begin
                        try
                            PrimitiveIterator.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject));
                            PrimitiveIterator.AddFilter_LayerSet(MkSet(DestinationLayer));

                            Primitive := PrimitiveIterator.FirstPCBObject;
                            while Primitive <> Nil do
                            begin
                                if Primitive.ObjectId = eTrackObject then
                                begin
                                    Track := Primitive;
                                    if Track.Width = LineWidth then
                                        FootprintTrackCount := FootprintTrackCount + 1;
                                end
                                else if Primitive.ObjectId = eArcObject then
                                begin
                                    Arc := Primitive;
                                    if Arc.LineWidth = LineWidth then
                                        FootprintArcCount := FootprintArcCount + 1;
                                end;
                                Primitive := PrimitiveIterator.NextPCBObject;
                            end;
                        finally
                            Footprint.GroupIterator_Destroy(PrimitiveIterator);
                        end;
                    end;

                    TotalTrackCount := TotalTrackCount + FootprintTrackCount;
                    TotalArcCount := TotalArcCount + FootprintArcCount;
                    CountProps := TStringList.Create;
                    try
                        AddJSONProperty(CountProps, 'footprint', FootprintName);
                        AddJSONInteger(CountProps, 'tracks', FootprintTrackCount);
                        AddJSONInteger(CountProps, 'arcs', FootprintArcCount);
                        AddJSONInteger(CountProps, 'primitives', FootprintTrackCount + FootprintArcCount);
                        CountArray.Add(BuildJSONObject(CountProps, 1));
                    finally
                        CountProps.Free;
                    end;
                end;

                Footprint := FootprintIterator.NextPCBObject;
            end;
        finally
            PcbLib.LibraryIterator_Destroy(FootprintIterator);
        end;

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONInteger(ResultProps, 'mechanical_layer', DestinationLayerNumber);
        AddJSONNumber(ResultProps, 'line_width_mm', LineWidthMM);
        AddJSONInteger(ResultProps, 'footprints_seen', FootprintsSeen);
        AddJSONInteger(ResultProps, 'footprints_processed', FootprintsProcessed);
        AddJSONInteger(ResultProps, 'total_tracks', TotalTrackCount);
        AddJSONInteger(ResultProps, 'total_arcs', TotalArcCount);
        AddJSONInteger(ResultProps, 'total_primitives', TotalTrackCount + TotalArcCount);
        ResultProps.Add(BuildJSONArray(CountArray, 'footprint_counts'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
        CountArray.Free;
    end;
end;

function RunPCBUndoCommand: String;
var
    ResultProps : TStringList;
    OutputLines : TStringList;
begin
    RunProcess('PCB:Undo');

    ResultProps := TStringList.Create;
    try
        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'process', 'PCB:Undo');

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
    end;
end;

function RunPCBCancelCommand: String;
var
    ResultProps : TStringList;
    OutputLines : TStringList;
begin
    ResetParameters;
    RunProcess('PCB:Cancel');
    Client.SendMessage('PCB:Cancel', '', 255, Client.CurrentView);
    Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);
    Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

    ResultProps := TStringList.Create;
    try
        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'process', 'PCB:Cancel');

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
    end;
end;

function RunPCBPostProcessCommand: String;
var
    ResultProps : TStringList;
    OutputLines : TStringList;
begin
    if PCBServer = Nil then
    begin
        Result := 'ERROR: PCB server is not active.';
        Exit;
    end;
    PCBServer.PostProcess;
    ResetParameters;
    RunProcess('PCB:Cancel');
    Client.SendMessage('PCB:Cancel', '', 255, Client.CurrentView);
    Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);
    Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

    ResultProps := TStringList.Create;
    try
        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'process', 'PCBServer.PostProcess');

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
    end;
end;

function RunSaveDocumentCommand: String;
var
    PcbLib      : IPCB_Library;
    Board       : IPCB_Board;
    View        : IServerDocumentView;
    Doc         : IServerDocument;
    ResultProps : TStringList;
    OutputLines : TStringList;
begin
    PcbLib := GetPcbLibSafe(0);
    Board := Nil;
    if PcbLib <> Nil then
        Board := PcbLib.Board
    else
        Board := GetBoardSafe(0);

    View := Client.GetCurrentView;
    Doc := Nil;
    if View <> Nil then
        Doc := View.OwnerDocument;
    if (Board = Nil) or (Doc = Nil) then
    begin
        Result := 'ERROR: Focus the PCB library or board before using the PCB save recovery command.';
        Exit;
    end;
    if NormalizedPath(Doc.FileName) <> NormalizedPath(Board.FileName) then
    begin
        Result := 'ERROR: The focused document does not match the PCB library or board.';
        Exit;
    end;

    ResetParameters;
    AddStringParameter('ObjectKind', 'Document');
    AddStringParameter('SaveMode', 'Standard');
    RunProcess('WorkspaceManager:SaveObject');
    Client.SendMessage('WorkspaceManager:SaveObject', 'ObjectKind=Document|SaveMode=Standard', 255, Client.CurrentView);

    ResultProps := TStringList.Create;
    try
        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'process', 'WorkspaceManager:SaveObject');
        AddJSONProperty(ResultProps, 'board_file_name', Board.FileName);

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
    end;
end;

function SelectProjectionTracks(Footprint: IPCB_LibComponent; DestinationLayer: TLayer; LineWidth: TCoord): Integer;
var
    PrimitiveIterator: IPCB_GroupIterator;
    Primitive: IPCB_Primitive;
    Track: IPCB_Track;
    Arc: IPCB_Arc;
begin
    Result := 0;

    if Footprint = Nil then
        Exit;

    PrimitiveIterator := Footprint.GroupIterator_Create;
    if PrimitiveIterator = Nil then
        Exit;

    try
        PrimitiveIterator.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject));
        PrimitiveIterator.AddFilter_LayerSet(MkSet(DestinationLayer));

        Primitive := PrimitiveIterator.FirstPCBObject;
        while Primitive <> Nil do
        begin
            if Primitive.ObjectId = eTrackObject then
            begin
                Track := Primitive;
                if Track.Width = LineWidth then
                begin
                    Primitive.Selected := True;
                    Result := Result + 1;
                end;
            end
            else if Primitive.ObjectId = eArcObject then
            begin
                Arc := Primitive;
                if Arc.LineWidth = LineWidth then
                begin
                    Primitive.Selected := True;
                    Result := Result + 1;
                end;
            end;
            Primitive := PrimitiveIterator.NextPCBObject;
        end;
    finally
        Footprint.GroupIterator_Destroy(PrimitiveIterator);
    end;
end;

function Select3DBodiesForEditorDelete(Footprint: IPCB_LibComponent): Integer;
var
    PrimitiveIterator: IPCB_GroupIterator;
    Primitive: IPCB_Primitive;
begin
    Result := 0;

    if Footprint = Nil then
        Exit;

    PrimitiveIterator := Footprint.GroupIterator_Create;
    if PrimitiveIterator = Nil then
        Exit;

    try
        PrimitiveIterator.AddFilter_ObjectSet(MkSet(eComponentBodyObject));
        PrimitiveIterator.AddFilter_LayerSet(AllLayers);

        Primitive := PrimitiveIterator.FirstPCBObject;
        while Primitive <> Nil do
        begin
            Primitive.Selected := True;
            Result := Result + 1;
            Primitive := PrimitiveIterator.NextPCBObject;
        end;
    finally
        Footprint.GroupIterator_Destroy(PrimitiveIterator);
    end;
end;

function SelectPadsByPrefixAndLayerPrimitives(Footprint: IPCB_LibComponent; OverlayLayer: TLayer; PadNamePrefix: String): Integer;
var
    PrimitiveIterator: IPCB_GroupIterator;
    Primitive: IPCB_Primitive;
    Pad: IPCB_Pad;
    PrefixText: String;
begin
    Result := 0;

    if Footprint = Nil then
        Exit;

    PrefixText := UpperCase(Trim(PadNamePrefix));

    PrimitiveIterator := Footprint.GroupIterator_Create;
    if PrimitiveIterator = Nil then
        Exit;

    try
        PrimitiveIterator.AddFilter_ObjectSet(MkSet(ePadObject, eTrackObject, eArcObject));

        Primitive := PrimitiveIterator.FirstPCBObject;
        while Primitive <> Nil do
        begin
            if Primitive.ObjectId = ePadObject then
            begin
                Pad := Primitive;
                if (PrefixText <> '') and (Copy(UpperCase(Pad.Name), 1, Length(PrefixText)) = PrefixText) then
                begin
                    Primitive.Selected := True;
                    Result := Result + 1;
                end;
            end
            else if Primitive.Layer = OverlayLayer then
            begin
                Primitive.Selected := True;
                Result := Result + 1;
            end;

            Primitive := PrimitiveIterator.NextPCBObject;
        end;
    finally
        Footprint.GroupIterator_Destroy(PrimitiveIterator);
    end;
end;

function SelectProjectionTracksAndMeasure(Footprint: IPCB_LibComponent; DestinationLayer: TLayer; LineWidth: TCoord; var Left, Bottom, Right, Top: TCoord): Integer;
var
    PrimitiveIterator: IPCB_GroupIterator;
    Primitive: IPCB_Primitive;
    Track: IPCB_Track;
    Arc: IPCB_Arc;
    MinX, MaxX: TCoord;
    MinY, MaxY: TCoord;
begin
    Result := 0;
    Left := 0;
    Bottom := 0;
    Right := 0;
    Top := 0;

    if Footprint = Nil then
        Exit;

    PrimitiveIterator := Footprint.GroupIterator_Create;
    if PrimitiveIterator = Nil then
        Exit;

    try
        PrimitiveIterator.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject));
        PrimitiveIterator.AddFilter_LayerSet(MkSet(DestinationLayer));

        Primitive := PrimitiveIterator.FirstPCBObject;
        while Primitive <> Nil do
        begin
            if Primitive.ObjectId = eTrackObject then
            begin
                Track := Primitive;
                if Track.Width = LineWidth then
                begin
                    Primitive.Selected := True;

                    if Track.x1 < Track.x2 then
                    begin
                        MinX := Track.x1;
                        MaxX := Track.x2;
                    end
                    else
                    begin
                        MinX := Track.x2;
                        MaxX := Track.x1;
                    end;

                    if Track.y1 < Track.y2 then
                    begin
                        MinY := Track.y1;
                        MaxY := Track.y2;
                    end
                    else
                    begin
                        MinY := Track.y2;
                        MaxY := Track.y1;
                    end;

                    if Result = 0 then
                    begin
                        Left := MinX;
                        Right := MaxX;
                        Bottom := MinY;
                        Top := MaxY;
                    end
                    else
                    begin
                        if MinX < Left then
                            Left := MinX;
                        if MaxX > Right then
                            Right := MaxX;
                        if MinY < Bottom then
                            Bottom := MinY;
                        if MaxY > Top then
                            Top := MaxY;
                    end;

                    Result := Result + 1;
                end;
            end
            else if Primitive.ObjectId = eArcObject then
            begin
                Arc := Primitive;
                if Arc.LineWidth = LineWidth then
                begin
                    Primitive.Selected := True;

                    MinX := Arc.XCenter - Arc.Radius;
                    MaxX := Arc.XCenter + Arc.Radius;
                    MinY := Arc.YCenter - Arc.Radius;
                    MaxY := Arc.YCenter + Arc.Radius;

                    if Result = 0 then
                    begin
                        Left := MinX;
                        Right := MaxX;
                        Bottom := MinY;
                        Top := MaxY;
                    end
                    else
                    begin
                        if MinX < Left then
                            Left := MinX;
                        if MaxX > Right then
                            Right := MaxX;
                        if MinY < Bottom then
                            Bottom := MinY;
                        if MaxY > Top then
                            Top := MaxY;
                    end;

                Result := Result + 1;
                end;
            end;
            Primitive := PrimitiveIterator.NextPCBObject;
        end;
    finally
        Footprint.GroupIterator_Destroy(PrimitiveIterator);
    end;
end;

function MeasureProjectionTracks(Footprint: IPCB_LibComponent; DestinationLayer: TLayer; LineWidth: TCoord; var Left, Bottom, Right, Top: TCoord): Integer;
var
    PrimitiveIterator: IPCB_GroupIterator;
    Primitive: IPCB_Primitive;
    Track: IPCB_Track;
    Arc: IPCB_Arc;
    MinX, MaxX: TCoord;
    MinY, MaxY: TCoord;
begin
    Result := 0;
    Left := 0;
    Bottom := 0;
    Right := 0;
    Top := 0;

    if Footprint = Nil then
        Exit;

    PrimitiveIterator := Footprint.GroupIterator_Create;
    if PrimitiveIterator = Nil then
        Exit;

    try
        PrimitiveIterator.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject));
        PrimitiveIterator.AddFilter_LayerSet(MkSet(DestinationLayer));

        Primitive := PrimitiveIterator.FirstPCBObject;
        while Primitive <> Nil do
        begin
            if Primitive.ObjectId = eTrackObject then
            begin
                Track := Primitive;
                if Track.Width = LineWidth then
                begin
                    if Track.x1 < Track.x2 then
                    begin
                        MinX := Track.x1;
                        MaxX := Track.x2;
                    end
                    else
                    begin
                        MinX := Track.x2;
                        MaxX := Track.x1;
                    end;

                    if Track.y1 < Track.y2 then
                    begin
                        MinY := Track.y1;
                        MaxY := Track.y2;
                    end
                    else
                    begin
                        MinY := Track.y2;
                        MaxY := Track.y1;
                    end;

                    if Result = 0 then
                    begin
                        Left := MinX;
                        Right := MaxX;
                        Bottom := MinY;
                        Top := MaxY;
                    end
                    else
                    begin
                        if MinX < Left then
                            Left := MinX;
                        if MaxX > Right then
                            Right := MaxX;
                        if MinY < Bottom then
                            Bottom := MinY;
                        if MaxY > Top then
                            Top := MaxY;
                    end;

                    Result := Result + 1;
                end;
            end
            else if Primitive.ObjectId = eArcObject then
            begin
                Arc := Primitive;
                if Arc.LineWidth = LineWidth then
                begin
                    MinX := Arc.XCenter - Arc.Radius;
                    MaxX := Arc.XCenter + Arc.Radius;
                    MinY := Arc.YCenter - Arc.Radius;
                    MaxY := Arc.YCenter + Arc.Radius;

                    if Result = 0 then
                    begin
                        Left := MinX;
                        Right := MaxX;
                        Bottom := MinY;
                        Top := MaxY;
                    end
                    else
                    begin
                        if MinX < Left then
                            Left := MinX;
                        if MaxX > Right then
                            Right := MaxX;
                        if MinY < Bottom then
                            Bottom := MinY;
                        if MaxY > Top then
                            Top := MaxY;
                    end;

                    Result := Result + 1;
                end;
            end;
            Primitive := PrimitiveIterator.NextPCBObject;
        end;
    finally
        Footprint.GroupIterator_Destroy(PrimitiveIterator);
    end;
end;

function PCBLibLocalX(Board: IPCB_Board; X: TCoord): TCoord;
begin
    Result := X;
    if Board <> Nil then
    begin
        if Abs(CoordToMMs(X)) > 100 then
            Result := X - Board.XOrigin;
    end;
end;

function PCBLibLocalY(Board: IPCB_Board; Y: TCoord): TCoord;
begin
    Result := Y;
    if Board <> Nil then
    begin
        if Abs(CoordToMMs(Y)) > 100 then
            Result := Y - Board.YOrigin;
    end;
end;

function DumpSelectedProjectionPrimitives(ExcludeFootprints: TStringList; DestinationLayerNumber: Integer; LineWidthMM: Double): String;
var
    PcbLib              : IPCB_Library;
    Board               : IPCB_Board;
    Footprint           : IPCB_LibComponent;
    PrimitiveIterator   : IPCB_GroupIterator;
    Primitive           : IPCB_Primitive;
    Track               : IPCB_Track;
    Arc                 : IPCB_Arc;
    DestinationLayer    : TLayer;
    LineWidth           : TCoord;
    ResultProps         : TStringList;
    PrimitiveArray      : TStringList;
    PrimitiveProps      : TStringList;
    OutputLines         : TStringList;
    FootprintName       : String;
    SelectedTracks      : Integer;
    SelectedArcs        : Integer;
    X1MM, Y1MM          : Double;
    X2MM, Y2MM          : Double;
    DXMM, DYMM          : Double;
    RadiusMM            : Double;
    SweepDeg            : Double;
    ArcLengthMM         : Double;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    if (DestinationLayerNumber < 1) or (DestinationLayerNumber > 32) then
    begin
        Result := '{"success": false, "error": "Mechanical layer number must be between 1 and 32."}';
        Exit;
    end;

    if LineWidthMM <= 0 then
    begin
        Result := '{"success": false, "error": "Line width must be greater than zero."}';
        Exit;
    end;

    Footprint := PcbLib.CurrentComponent;
    if Footprint = Nil then
    begin
        Result := '{"success": false, "error": "No current footprint is active in the PCB library."}';
        Exit;
    end;

    FootprintName := Footprint.Name;
    if StringListContainsText(ExcludeFootprints, FootprintName) then
    begin
        Result := '{"success": false, "error": "The current footprint is excluded."}';
        Exit;
    end;

    Board := PcbLib.Board;
    DestinationLayer := ILayer.MechanicalLayer(DestinationLayerNumber);
    LineWidth := MMsToCoord(LineWidthMM);
    ResultProps := TStringList.Create;
    PrimitiveArray := TStringList.Create;
    SelectedTracks := 0;
    SelectedArcs := 0;

    try
        PrimitiveIterator := Footprint.GroupIterator_Create;
        if PrimitiveIterator = Nil then
        begin
            Result := '{"success": false, "error": "Failed to create selected primitive iterator."}';
            Exit;
        end;

        try
            PrimitiveIterator.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject));
            PrimitiveIterator.AddFilter_LayerSet(MkSet(DestinationLayer));

            Primitive := PrimitiveIterator.FirstPCBObject;
            while Primitive <> Nil do
            begin
                if (Primitive.ObjectId = eTrackObject) and Primitive.Selected then
                begin
                    Track := Primitive;
                    if Track.Width = LineWidth then
                    begin
                        SelectedTracks := SelectedTracks + 1;
                        X1MM := CoordToMMs(PCBLibLocalX(Board, Track.x1));
                        Y1MM := CoordToMMs(PCBLibLocalY(Board, Track.y1));
                        X2MM := CoordToMMs(PCBLibLocalX(Board, Track.x2));
                        Y2MM := CoordToMMs(PCBLibLocalY(Board, Track.y2));
                        DXMM := X2MM - X1MM;
                        DYMM := Y2MM - Y1MM;

                        PrimitiveProps := TStringList.Create;
                        try
                            AddJSONProperty(PrimitiveProps, 'kind', 'LINE');
                            AddJSONInteger(PrimitiveProps, 'index', SelectedTracks + SelectedArcs);
                            AddJSONNumber(PrimitiveProps, 'x1_mm', X1MM);
                            AddJSONNumber(PrimitiveProps, 'y1_mm', Y1MM);
                            AddJSONNumber(PrimitiveProps, 'x2_mm', X2MM);
                            AddJSONNumber(PrimitiveProps, 'y2_mm', Y2MM);
                            AddJSONNumber(PrimitiveProps, 'length_mm', Sqrt((DXMM * DXMM) + (DYMM * DYMM)));
                            AddJSONNumber(PrimitiveProps, 'line_width_mm', CoordToMMs(Track.Width));
                            PrimitiveArray.Add(BuildJSONObject(PrimitiveProps, 1));
                        finally
                            PrimitiveProps.Free;
                        end;
                    end;
                end
                else if (Primitive.ObjectId = eArcObject) and Primitive.Selected then
                begin
                    Arc := Primitive;
                    if Arc.LineWidth = LineWidth then
                    begin
                        SelectedArcs := SelectedArcs + 1;
                        RadiusMM := CoordToMMs(Arc.Radius);
                        SweepDeg := Arc.EndAngle - Arc.StartAngle;
                        while SweepDeg < 0 do
                            SweepDeg := SweepDeg + 360.0;
                        while SweepDeg > 360.0 do
                            SweepDeg := SweepDeg - 360.0;
                        ArcLengthMM := RadiusMM * SweepDeg * 3.141592653589793 / 180.0;

                        PrimitiveProps := TStringList.Create;
                        try
                            AddJSONProperty(PrimitiveProps, 'kind', 'ARC');
                            AddJSONInteger(PrimitiveProps, 'index', SelectedTracks + SelectedArcs);
                            AddJSONNumber(PrimitiveProps, 'center_x_mm', CoordToMMs(PCBLibLocalX(Board, Arc.XCenter)));
                            AddJSONNumber(PrimitiveProps, 'center_y_mm', CoordToMMs(PCBLibLocalY(Board, Arc.YCenter)));
                            AddJSONNumber(PrimitiveProps, 'radius_mm', RadiusMM);
                            AddJSONNumber(PrimitiveProps, 'start_angle_deg', Arc.StartAngle);
                            AddJSONNumber(PrimitiveProps, 'end_angle_deg', Arc.EndAngle);
                            AddJSONNumber(PrimitiveProps, 'sweep_deg', SweepDeg);
                            AddJSONNumber(PrimitiveProps, 'arc_length_mm', ArcLengthMM);
                            AddJSONNumber(PrimitiveProps, 'line_width_mm', CoordToMMs(Arc.LineWidth));
                            PrimitiveArray.Add(BuildJSONObject(PrimitiveProps, 1));
                        finally
                            PrimitiveProps.Free;
                        end;
                    end;
                end;
                Primitive := PrimitiveIterator.NextPCBObject;
            end;
        finally
            Footprint.GroupIterator_Destroy(PrimitiveIterator);
        end;

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'footprint', FootprintName);
        AddJSONInteger(ResultProps, 'mechanical_layer', DestinationLayerNumber);
        AddJSONNumber(ResultProps, 'line_width_mm', LineWidthMM);
        AddJSONInteger(ResultProps, 'selected_tracks', SelectedTracks);
        AddJSONInteger(ResultProps, 'selected_arcs', SelectedArcs);
        AddJSONInteger(ResultProps, 'selected_primitives_count', SelectedTracks + SelectedArcs);
        ResultProps.Add(BuildJSONArray(PrimitiveArray, 'selected_primitives'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
        PrimitiveArray.Free;
    end;
end;

function IsProjectionText(TextValue: String): Boolean;
begin
    TextValue := UpperCase(Trim(TextValue));
    Result := (TextValue = '.DESIGNATOR') or (TextValue = '.COMMENT');
end;

function ProjectionTextHeight: TCoord;
begin
    Result := MMsToCoord(1.5);
end;

function ProjectionTextStrokeWidth: TCoord;
begin
    Result := MMsToCoord(0.1);
end;

function ProjectionTextAverageCharWidthMM: Double;
begin
    Result := CoordToMMs(ProjectionTextHeight) * 0.45;
end;

function ProjectionTextWidth(TextValue: String): TCoord;
begin
    Result := MMsToCoord(Length(TextValue) * ProjectionTextAverageCharWidthMM);
end;

function ProjectionTextKeepout: TCoord;
begin
    Result := MMsToCoord(0.05);
end;

function ProjectionTextGap: TCoord;
begin
    Result := MMsToCoord(0.2);
end;

function ProjectionCommentGap: TCoord;
begin
    Result := MMsToCoord(0.2);
end;

function ProjectionTrueTypeVisibleHeight: TCoord;
begin
    Result := MMsToCoord(CoordToMMs(ProjectionTextHeight) * 0.675);
end;

function ProjectionDesignatorAnchorOverlapHeight: TCoord;
begin
    Result := MMsToCoord(CoordToMMs(ProjectionTextHeight) * 0.6);
end;

function CoordMin(A, B: TCoord): TCoord;
begin
    if A < B then
        Result := A
    else
        Result := B;
end;

function CoordMax(A, B: TCoord): TCoord;
begin
    if A > B then
        Result := A
    else
        Result := B;
end;

function PointInsideRect(X, Y, Left, Bottom, Right, Top: TCoord): Boolean;
begin
    Result := (X >= Left) and (X <= Right) and (Y >= Bottom) and (Y <= Top);
end;

function SegmentDirection(AX, AY, BX, BY, CX, CY: TCoord): Double;
begin
    Result := ((CX - AX) * 1.0 * (BY - AY)) - ((BX - AX) * 1.0 * (CY - AY));
end;

function PointOnSegment(AX, AY, BX, BY, CX, CY: TCoord): Boolean;
begin
    Result := (Abs(SegmentDirection(AX, AY, BX, BY, CX, CY)) < 1.0) and
              (CX >= CoordMin(AX, BX)) and (CX <= CoordMax(AX, BX)) and
              (CY >= CoordMin(AY, BY)) and (CY <= CoordMax(AY, BY));
end;

function SegmentsIntersect(A1X, A1Y, A2X, A2Y, B1X, B1Y, B2X, B2Y: TCoord): Boolean;
var
    D1, D2, D3, D4: Double;
begin
    D1 := SegmentDirection(B1X, B1Y, B2X, B2Y, A1X, A1Y);
    D2 := SegmentDirection(B1X, B1Y, B2X, B2Y, A2X, A2Y);
    D3 := SegmentDirection(A1X, A1Y, A2X, A2Y, B1X, B1Y);
    D4 := SegmentDirection(A1X, A1Y, A2X, A2Y, B2X, B2Y);

    Result := False;
    if (((D1 > 0) and (D2 < 0)) or ((D1 < 0) and (D2 > 0))) and
       (((D3 > 0) and (D4 < 0)) or ((D3 < 0) and (D4 > 0))) then
    begin
        Result := True;
        Exit;
    end;

    if (Abs(D1) < 1.0) and PointOnSegment(B1X, B1Y, B2X, B2Y, A1X, A1Y) then
        Result := True
    else if (Abs(D2) < 1.0) and PointOnSegment(B1X, B1Y, B2X, B2Y, A2X, A2Y) then
        Result := True
    else if (Abs(D3) < 1.0) and PointOnSegment(A1X, A1Y, A2X, A2Y, B1X, B1Y) then
        Result := True
    else if (Abs(D4) < 1.0) and PointOnSegment(A1X, A1Y, A2X, A2Y, B2X, B2Y) then
        Result := True;
end;

function SegmentIntersectsRect(X1, Y1, X2, Y2, Left, Bottom, Right, Top: TCoord): Boolean;
begin
    Result := False;

    if CoordMax(X1, X2) < Left then
        Exit;
    if CoordMin(X1, X2) > Right then
        Exit;
    if CoordMax(Y1, Y2) < Bottom then
        Exit;
    if CoordMin(Y1, Y2) > Top then
        Exit;

    if PointInsideRect(X1, Y1, Left, Bottom, Right, Top) or
       PointInsideRect(X2, Y2, Left, Bottom, Right, Top) then
    begin
        Result := True;
        Exit;
    end;

    Result := SegmentsIntersect(X1, Y1, X2, Y2, Left, Bottom, Right, Bottom) or
              SegmentsIntersect(X1, Y1, X2, Y2, Right, Bottom, Right, Top) or
              SegmentsIntersect(X1, Y1, X2, Y2, Right, Top, Left, Top) or
              SegmentsIntersect(X1, Y1, X2, Y2, Left, Top, Left, Bottom);
end;

function ProjectionTracksIntersectRect(Board: IPCB_Board; Footprint: IPCB_LibComponent; DestinationLayer: TLayer; LineWidth: TCoord; Left, Bottom, Right, Top: TCoord): Boolean;
var
    PrimitiveIterator: IPCB_GroupIterator;
    Primitive: IPCB_Primitive;
    Track: IPCB_Track;
    Arc: IPCB_Arc;
    X1, Y1, X2, Y2: TCoord;
    MinX, MaxX: TCoord;
    MinY, MaxY: TCoord;
    Keepout: TCoord;
begin
    Result := False;

    if Footprint = Nil then
        Exit;

    Keepout := ProjectionTextKeepout;
    Left := Left - Keepout;
    Bottom := Bottom - Keepout;
    Right := Right + Keepout;
    Top := Top + Keepout;

    PrimitiveIterator := Footprint.GroupIterator_Create;
    if PrimitiveIterator = Nil then
        Exit;

    try
        PrimitiveIterator.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject));
        PrimitiveIterator.AddFilter_LayerSet(MkSet(DestinationLayer));

        Primitive := PrimitiveIterator.FirstPCBObject;
        while Primitive <> Nil do
        begin
            if Primitive.ObjectId = eTrackObject then
            begin
                Track := Primitive;
                if Track.Width = LineWidth then
                begin
                    X1 := PCBLibLocalX(Board, Track.x1);
                    Y1 := PCBLibLocalY(Board, Track.y1);
                    X2 := PCBLibLocalX(Board, Track.x2);
                    Y2 := PCBLibLocalY(Board, Track.y2);
                    if SegmentIntersectsRect(X1, Y1, X2, Y2, Left, Bottom, Right, Top) then
                    begin
                        Result := True;
                        Exit;
                    end;
                end;
            end
            else if Primitive.ObjectId = eArcObject then
            begin
                Arc := Primitive;
                if Arc.LineWidth = LineWidth then
                begin
                    MinX := PCBLibLocalX(Board, Arc.XCenter - Arc.Radius);
                    MaxX := PCBLibLocalX(Board, Arc.XCenter + Arc.Radius);
                    MinY := PCBLibLocalY(Board, Arc.YCenter - Arc.Radius);
                    MaxY := PCBLibLocalY(Board, Arc.YCenter + Arc.Radius);
                    if not ((MaxX < Left) or (MinX > Right) or (MaxY < Bottom) or (MinY > Top)) then
                    begin
                        Result := True;
                        Exit;
                    end;
                end;
            end;
            Primitive := PrimitiveIterator.NextPCBObject;
        end;
    finally
        Footprint.GroupIterator_Destroy(PrimitiveIterator);
    end;
end;

function ProjectionDesignatorAnchorWidth: TCoord;
begin
    Result := ProjectionTextWidth('.De');
end;

function ProjectionDesignatorAnchorIsClear(Board: IPCB_Board; Footprint: IPCB_LibComponent; DestinationLayer: TLayer; LineWidth: TCoord; CenterX, CenterY, TextHeight: TCoord): Boolean;
var
    Left, Bottom, Right, Top: TCoord;
    AnchorWidth: TCoord;
    TextY: TCoord;
begin
    AnchorWidth := ProjectionDesignatorAnchorWidth;
    Left := CenterX - (AnchorWidth div 2);
    Right := CenterX + (AnchorWidth div 2);
    TextY := CenterY - (TextHeight div 2);
    Bottom := TextY;
    Top := TextY + ProjectionTrueTypeVisibleHeight;
    Result := not ProjectionTracksIntersectRect(Board, Footprint, DestinationLayer, LineWidth, Left, Bottom, Right, Top);
end;

function TryChooseProjectionDesignatorCenter(Board: IPCB_Board; Footprint: IPCB_LibComponent; DestinationLayer: TLayer; LineWidth: TCoord; CenterX, CenterY, Bottom, Top, TextHeight: TCoord; var DesignatorY: TCoord): Boolean;
var
    Offset: TCoord;
    Step: TCoord;
    MaxOffset: TCoord;
    CandidateCenterY: TCoord;
    MinCenterY: TCoord;
    MaxCenterY: TCoord;
begin
    Result := False;
    DesignatorY := CenterY - (TextHeight div 2);

    MinCenterY := Bottom + (TextHeight div 2);
    MaxCenterY := Top - (TextHeight div 2);
    if MaxCenterY < MinCenterY then
        Exit;

    Step := MMsToCoord(0.025);
    MaxOffset := CoordMax(Abs(CenterY - MinCenterY), Abs(MaxCenterY - CenterY));
    Offset := 0;
    while Offset <= MaxOffset do
    begin
        CandidateCenterY := CenterY - Offset;
        if (CandidateCenterY >= MinCenterY) and (CandidateCenterY <= MaxCenterY) then
        begin
            if ProjectionDesignatorAnchorIsClear(Board, Footprint, DestinationLayer, LineWidth, CenterX, CandidateCenterY, TextHeight) then
            begin
                DesignatorY := CandidateCenterY - (TextHeight div 2);
                Result := True;
                Exit;
            end;
        end;

        if Offset > 0 then
        begin
            CandidateCenterY := CenterY + Offset;
            if (CandidateCenterY >= MinCenterY) and (CandidateCenterY <= MaxCenterY) then
            begin
                if ProjectionDesignatorAnchorIsClear(Board, Footprint, DestinationLayer, LineWidth, CenterX, CandidateCenterY, TextHeight) then
                begin
                    DesignatorY := CandidateCenterY - (TextHeight div 2);
                    Result := True;
                    Exit;
                end;
            end;
        end;

        Offset := Offset + Step;
    end;
end;

procedure ChooseProjectionTextLocations(Board: IPCB_Board; Footprint: IPCB_LibComponent; DestinationLayer: TLayer; LineWidth: TCoord; var DesignatorX, DesignatorY, CommentX, CommentY: TCoord; var DesignatorAtCenter: Boolean);
var
    Left, Bottom, Right, Top: TCoord;
    CenterX, CenterY: TCoord;
    DesignatorHeight: TCoord;
    DesignatorAnchorWidth: TCoord;
    CommentWidth: TCoord;
    Gap: TCoord;
    CommentGap: TCoord;
begin
    DesignatorHeight := ProjectionTextHeight;
    DesignatorAnchorWidth := ProjectionDesignatorAnchorWidth;
    CommentWidth := ProjectionTextWidth('.Comment');
    Gap := ProjectionTextGap;
    CommentGap := ProjectionCommentGap;
    DesignatorAtCenter := False;

    if MeasureProjectionTracks(Footprint, DestinationLayer, LineWidth, Left, Bottom, Right, Top) <= 0 then
    begin
        CenterX := 0;
        CenterY := 0;
        DesignatorX := CenterX - (DesignatorAnchorWidth div 2);
        DesignatorY := CenterY - (DesignatorHeight div 2);
        CommentX := CenterX - (CommentWidth div 2);
        CommentY := CenterY - DesignatorHeight - CommentGap - ProjectionTrueTypeVisibleHeight;
        Exit;
    end;

    Left := PCBLibLocalX(Board, Left);
    Right := PCBLibLocalX(Board, Right);
    Bottom := PCBLibLocalY(Board, Bottom);
    Top := PCBLibLocalY(Board, Top);
    CenterX := (Left + Right) div 2;
    CenterY := (Bottom + Top) div 2;

    if TryChooseProjectionDesignatorCenter(Board, Footprint, DestinationLayer, LineWidth, CenterX, CenterY, Bottom, Top, DesignatorHeight, DesignatorY) then
    begin
        DesignatorX := CenterX - (DesignatorAnchorWidth div 2);
        DesignatorAtCenter := True;
    end
    else
    begin
        DesignatorX := CenterX - (DesignatorAnchorWidth div 2);
        DesignatorY := Top + Gap;
    end;

    CommentX := CenterX - (CommentWidth div 2);
    CommentY := Bottom - CommentGap - ProjectionTrueTypeVisibleHeight;
end;

function SelectProjectionTexts(Footprint: IPCB_LibComponent; DestinationLayer: TLayer): Integer;
var
    PrimitiveIterator: IPCB_GroupIterator;
    Primitive: IPCB_Primitive;
    TextPrimitive: IPCB_Text;
begin
    Result := 0;

    if Footprint = Nil then
        Exit;

    PrimitiveIterator := Footprint.GroupIterator_Create;
    if PrimitiveIterator = Nil then
        Exit;

    try
        PrimitiveIterator.AddFilter_ObjectSet(MkSet(eTextObject));
        PrimitiveIterator.AddFilter_LayerSet(MkSet(DestinationLayer));

        Primitive := PrimitiveIterator.FirstPCBObject;
        while Primitive <> Nil do
        begin
            TextPrimitive := Primitive;
            if IsProjectionText(TextPrimitive.Text) then
            begin
                Primitive.Selected := True;
                Result := Result + 1;
            end;
            Primitive := PrimitiveIterator.NextPCBObject;
        end;
    finally
        Footprint.GroupIterator_Destroy(PrimitiveIterator);
    end;
end;

function FindReferenceProjectionText(PcbLib: IPCB_Library; Board: IPCB_Board; ReferenceFootprintName: String; TextValue: String; var TemplateText: IPCB_Text; var LocalX, LocalY: TCoord): Boolean;
var
    FootprintIterator: IPCB_LibraryIterator;
    ReferenceFootprint: IPCB_LibComponent;
    ActiveFootprint: IPCB_LibComponent;
    PrimitiveIterator: IPCB_GroupIterator;
    Primitive: IPCB_Primitive;
    TextPrimitive: IPCB_Text;
begin
    Result := False;
    TemplateText := Nil;
    LocalX := 0;
    LocalY := 0;

    ReferenceFootprint := Nil;
    FootprintIterator := PcbLib.LibraryIterator_Create;
    if FootprintIterator = Nil then
        Exit;
    try
        FootprintIterator.SetState_FilterAll;
        ReferenceFootprint := FootprintIterator.FirstPCBObject;
        while ReferenceFootprint <> Nil do
        begin
            if UpperCase(ReferenceFootprint.Name) = UpperCase(ReferenceFootprintName) then
                Break;
            ReferenceFootprint := FootprintIterator.NextPCBObject;
        end;
    finally
        PcbLib.LibraryIterator_Destroy(FootprintIterator);
    end;

    if ReferenceFootprint = Nil then
        Exit;

    PcbLib.CurrentComponent := ReferenceFootprint;
    ActiveFootprint := PcbLib.CurrentComponent;
    if Board <> Nil then
        Board.ViewManager_FullUpdate;

    if ActiveFootprint = Nil then
        Exit;

    PrimitiveIterator := ActiveFootprint.GroupIterator_Create;
    if PrimitiveIterator = Nil then
        Exit;

    try
        PrimitiveIterator.AddFilter_ObjectSet(MkSet(eTextObject));
        PrimitiveIterator.AddFilter_LayerSet(AllLayers);

        Primitive := PrimitiveIterator.FirstPCBObject;
        while Primitive <> Nil do
        begin
            TextPrimitive := Primitive;
            if UpperCase(Trim(TextPrimitive.Text)) = UpperCase(TextValue) then
            begin
                TemplateText := TextPrimitive.Replicate;
                LocalX := PCBLibLocalX(Board, TextPrimitive.XLocation);
                LocalY := PCBLibLocalY(Board, TextPrimitive.YLocation);
                Result := TemplateText <> Nil;
                Exit;
            end;
            Primitive := PrimitiveIterator.NextPCBObject;
        end;
    finally
        ActiveFootprint.GroupIterator_Destroy(PrimitiveIterator);
    end;
end;

function AddProjectionTextFromTemplate(Board: IPCB_Board; TemplateText: IPCB_Text; DestinationLayer: TLayer; TextValue: String; LocalX, LocalY: TCoord): Boolean;
var
    NewText: IPCB_Text;
begin
    Result := False;

    if (Board = Nil) or (TemplateText = Nil) then
        Exit;

    NewText := TemplateText.Replicate;
    if NewText = Nil then
        Exit;

    NewText.Layer := DestinationLayer;
    NewText.Text := TextValue;
    NewText.XLocation := Board.XOrigin + LocalX;
    NewText.YLocation := Board.YOrigin + LocalY;
    NewText.Selected := False;

    PCBServer.SendMessageToRobots(NewText.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
    Board.AddPCBObject(NewText);
    PCBServer.SendMessageToRobots(NewText.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
    Result := True;
end;

function AddProjectionTextBuiltIn(Board: IPCB_Board; DestinationLayer: TLayer; TextValue: String; LocalX, LocalY: TCoord): Boolean;
var
    NewText: IPCB_Text;
begin
    Result := False;

    if Board = Nil then
        Exit;

    NewText := PCBServer.PCBObjectFactory(eTextObject, eNoDimension, eCreate_Default);
    if NewText = Nil then
        Exit;

    NewText.Layer := DestinationLayer;
    NewText.Text := TextValue;
    NewText.XLocation := Board.XOrigin + LocalX;
    NewText.YLocation := Board.YOrigin + LocalY;
    NewText.Size := ProjectionTextHeight;
    NewText.Width := ProjectionTextStrokeWidth;
    NewText.UseTTFonts := True;
    NewText.FontName := 'ARIAL';
    NewText.Bold := False;
    NewText.Italic := False;
    NewText.Rotation := 0;
    NewText.Selected := False;

    PCBServer.SendMessageToRobots(NewText.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
    Board.AddPCBObject(NewText);
    PCBServer.SendMessageToRobots(NewText.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
    Result := True;
end;

function FindLibFootprint(PcbLib: IPCB_Library; FootprintName: String): IPCB_LibComponent;
var
    FootprintIterator : IPCB_LibraryIterator;
    Footprint         : IPCB_LibComponent;
begin
    Result := Nil;

    if PcbLib = Nil then
        Exit;

    FootprintIterator := PcbLib.LibraryIterator_Create;
    if FootprintIterator = Nil then
        Exit;

    try
        FootprintIterator.SetState_FilterAll;
        Footprint := FootprintIterator.FirstPCBObject;
        while Footprint <> Nil do
        begin
            if UpperCase(Footprint.Name) = UpperCase(FootprintName) then
            begin
                Result := Footprint;
                Exit;
            end;
            Footprint := FootprintIterator.NextPCBObject;
        end;
    finally
        PcbLib.LibraryIterator_Destroy(FootprintIterator);
    end;
end;

function ParseFootprintPrimitiveDumpCommand(MoveText: String; var FootprintName: String): Boolean;
var
    CommandName : String;
    SeparatorPos: Integer;
begin
    Result := False;
    FootprintName := '';

    SeparatorPos := Pos('|', MoveText);
    if SeparatorPos > 0 then
    begin
        CommandName := UpperCase(Trim(Copy(MoveText, 1, SeparatorPos - 1)));
        FootprintName := Trim(Copy(MoveText, SeparatorPos + 1, Length(MoveText) - SeparatorPos));
    end
    else
        CommandName := UpperCase(Trim(MoveText));

    if CommandName <> 'FOOTPRINT_PRIMITIVE_DUMP' then
        Exit;

    Result := FootprintName <> '';
end;

function FindFootprintPrimitiveDumpCommand(LayerMoves: TStringList; var FootprintName: String): Boolean;
var
    i: Integer;
begin
    Result := False;
    FootprintName := '';

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if ParseFootprintPrimitiveDumpCommand(LayerMoves[i], FootprintName) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function ParsePCBLibraryDescriptionDumpCommand(MoveText: String; var FootprintName: String): Boolean;
var
    CommandName : String;
    SeparatorPos: Integer;
begin
    Result := False;
    FootprintName := '*';

    SeparatorPos := Pos('|', MoveText);
    if SeparatorPos > 0 then
    begin
        CommandName := UpperCase(Trim(Copy(MoveText, 1, SeparatorPos - 1)));
        FootprintName := Trim(Copy(MoveText, SeparatorPos + 1, Length(MoveText) - SeparatorPos));
    end
    else
        CommandName := UpperCase(Trim(MoveText));

    if CommandName <> 'PCB_LIB_DESCRIPTION_DUMP' then
        Exit;

    if FootprintName = '' then
        FootprintName := '*';

    Result := True;
end;

function FindPCBLibraryDescriptionDumpCommand(LayerMoves: TStringList; var FootprintName: String): Boolean;
var
    i: Integer;
begin
    Result := False;
    FootprintName := '*';

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if ParsePCBLibraryDescriptionDumpCommand(LayerMoves[i], FootprintName) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function ParsePCBLibraryOpenCommand(MoveText: String; var LibraryPath: String): Boolean;
var
    CommandName : String;
    SeparatorPos: Integer;
begin
    Result := False;
    LibraryPath := '';

    MoveText := Trim(MoveText);
    SeparatorPos := Pos('|', MoveText);
    if SeparatorPos <= 1 then
        Exit;

    CommandName := UpperCase(Trim(Copy(MoveText, 1, SeparatorPos - 1)));
    if CommandName <> 'PCB_LIB_OPEN' then
        Exit;

    LibraryPath := Trim(Copy(MoveText, SeparatorPos + 1, Length(MoveText) - SeparatorPos));
    Result := LibraryPath <> '';
end;

function FindPCBLibraryOpenCommand(LayerMoves: TStringList; var LibraryPath: String): Boolean;
var
    i: Integer;
begin
    Result := False;
    LibraryPath := '';

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if ParsePCBLibraryOpenCommand(LayerMoves[i], LibraryPath) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function ParseSchLibrarySetFootprintLibraryCommand(MoveText: String; var LibraryName, LibraryPath: String): Boolean;
var
    Fields     : TStringList;
begin
    Result := False;
    LibraryName := '';
    LibraryPath := '';

    Fields := TStringList.Create;
    try
        Fields.Delimiter := '|';
        Fields.StrictDelimiter := True;
        Fields.DelimitedText := Trim(MoveText);

        if Fields.Count < 2 then
            Exit;
        if UpperCase(Trim(Fields[0])) <> 'SCH_LIB_SET_FOOTPRINT_LIBRARY' then
            Exit;

        LibraryName := Trim(Fields[1]);
        if Fields.Count >= 3 then
            LibraryPath := Trim(Fields[2]);

        Result := LibraryName <> '';
    finally
        Fields.Free;
    end;
end;

function FindSchLibrarySetFootprintLibraryCommand(LayerMoves: TStringList; var LibraryName, LibraryPath: String): Boolean;
var
    i: Integer;
begin
    Result := False;
    LibraryName := '';
    LibraryPath := '';

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if ParseSchLibrarySetFootprintLibraryCommand(LayerMoves[i], LibraryName, LibraryPath) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function SetSchLibraryFootprintLibraryName(LibraryName, LibraryPath: String): String;
var
    CurrentLib             : ISch_Lib;
    ComponentIterator      : ISch_Iterator;
    ImplementationIterator : ISch_Iterator;
    SchComponent           : ISch_Component;
    SchImplementation      : ISch_Implementation;
    ResultProps            : TStringList;
    ModifiedArray          : TStringList;
    ComponentProps         : TStringList;
    OutputLines            : TStringList;
    ComponentsSeen         : Integer;
    ComponentsWithModels   : Integer;
    ImplementationsSeen    : Integer;
    ImplementationsModified: Integer;
    ComponentModified      : Boolean;
    ServerDoc              : IServerDocument;
begin
    ResultProps := TStringList.Create;
    ModifiedArray := TStringList.Create;
    OutputLines := TStringList.Create;
    ComponentsSeen := 0;
    ComponentsWithModels := 0;
    ImplementationsSeen := 0;
    ImplementationsModified := 0;

    try
        if (Trim(LibraryPath) <> '') then
        begin
            if not FileExists(LibraryPath) then
            begin
                AddJSONBoolean(ResultProps, 'success', False);
                AddJSONProperty(ResultProps, 'error', 'Schematic library file not found: ' + LibraryPath);
                OutputLines.Text := BuildJSONObject(ResultProps);
                Result := OutputLines.Text;
                Exit;
            end;

            ServerDoc := OpenLibraryDocument('SchLib', LibraryPath);
            if ServerDoc = Nil then
            begin
                AddJSONBoolean(ResultProps, 'success', False);
                AddJSONProperty(ResultProps, 'error', 'Failed to open schematic library: ' + LibraryPath);
                OutputLines.Text := BuildJSONObject(ResultProps);
                Result := OutputLines.Text;
                Exit;
            end;
        end;

        CurrentLib := Nil;
        if SchServer <> Nil then
            CurrentLib := SchServer.GetCurrentSchDocument;
        if (CurrentLib = Nil) or (CurrentLib.ObjectID <> eSchLib) then
        begin
            AddJSONBoolean(ResultProps, 'success', False);
            AddJSONProperty(ResultProps, 'error', 'Please open or focus a schematic library document.');
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
            Exit;
        end;

        if (LibraryPath <> '') and (NormalizedPath(CurrentLib.DocumentName) <> NormalizedPath(LibraryPath)) then
        begin
            Result := 'ERROR: The requested schematic library could not be focused.';
            Exit;
        end;

        if (Trim(LibraryName) = '') then
        begin
            AddJSONBoolean(ResultProps, 'success', False);
            AddJSONProperty(ResultProps, 'error', 'Footprint library name is empty.');
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
            Exit;
        end;

        ComponentIterator := CurrentLib.SchLibIterator_Create;
        try
            ComponentIterator.AddFilter_ObjectSet(MkSet(eSchComponent));
            SchComponent := ComponentIterator.FirstSchObject;
            while (SchComponent <> Nil) do
            begin
                ComponentsSeen := ComponentsSeen + 1;
                ComponentModified := False;

                ImplementationIterator := SchComponent.SchIterator_Create;
                try
                    ImplementationIterator.AddFilter_ObjectSet(MkSet(eImplementation));
                    SchImplementation := ImplementationIterator.FirstSchObject;
                    while (SchImplementation <> Nil) do
                    begin
                        ImplementationsSeen := ImplementationsSeen + 1;
                        if UpperCase(SchImplementation.ModelType) = 'PCBLIB' then
                        begin
                            if ImplementationsModified = 0 then
                                MarkDocumentModified(CurrentLib.DocumentName);
                            SchImplementation.ClearAllDatafileLinks;
                            SchImplementation.AddDataFileLink(SchImplementation.ModelName, LibraryName, 'PCBLIB');
                            ImplementationsModified := ImplementationsModified + 1;
                            ComponentModified := True;
                        end;
                        SchImplementation := ImplementationIterator.NextSchObject;
                    end;
                finally
                    SchComponent.SchIterator_Destroy(ImplementationIterator);
                end;

                if ComponentModified then
                begin
                    ComponentsWithModels := ComponentsWithModels + 1;
                    ComponentProps := TStringList.Create;
                    try
                        AddJSONProperty(ComponentProps, 'name', SchComponent.LibReference);
                        AddJSONProperty(ComponentProps, 'footprint_library', LibraryName);
                        ModifiedArray.Add(BuildJSONObject(ComponentProps, 1));
                    finally
                        ComponentProps.Free;
                    end;
                end;

                SchComponent := ComponentIterator.NextSchObject;
            end;
        finally
            CurrentLib.SchIterator_Destroy(ComponentIterator);
        end;

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'library_name', ExtractFileName(CurrentLib.DocumentName));
        AddJSONProperty(ResultProps, 'footprint_library', LibraryName);
        AddJSONInteger(ResultProps, 'components_seen', ComponentsSeen);
        AddJSONInteger(ResultProps, 'components_with_pcblib_models', ComponentsWithModels);
        AddJSONInteger(ResultProps, 'implementations_seen', ImplementationsSeen);
        AddJSONInteger(ResultProps, 'implementations_modified', ImplementationsModified);
        ResultProps.Add(BuildJSONArray(ModifiedArray, 'modified_components'));

        OutputLines.Text := BuildJSONObject(ResultProps);
        Result := OutputLines.Text;
    finally
        OutputLines.Free;
        ModifiedArray.Free;
        ResultProps.Free;
    end;
end;

function OpenPCBLibraryByPath(LibraryPath: String): String;
var
    PcbLib            : IPCB_Library;
    Board             : IPCB_Board;
    ServerDoc         : IServerDocument;
    FootprintIterator : IPCB_LibraryIterator;
    Footprint         : IPCB_LibComponent;
    ResultProps       : TStringList;
    OutputLines       : TStringList;
    FootprintCount    : Integer;
    WasAlreadyOpen    : Boolean;
begin
    ResultProps := TStringList.Create;
    OutputLines := TStringList.Create;
    FootprintCount := 0;
    WasAlreadyOpen := False;

    try
        if Trim(LibraryPath) = '' then
        begin
            AddJSONBoolean(ResultProps, 'success', False);
            AddJSONProperty(ResultProps, 'error', 'PcbLib path is empty.');
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
            Exit;
        end;

        if not FileExists(LibraryPath) then
        begin
            AddJSONBoolean(ResultProps, 'success', False);
            AddJSONProperty(ResultProps, 'error', 'PcbLib file not found: ' + LibraryPath);
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
            Exit;
        end;

        WasAlreadyOpen := FindOpenDocument(LibraryPath) <> Nil;
        ServerDoc := OpenLibraryDocument('PcbLib', LibraryPath);
        if ServerDoc = Nil then
        begin
            AddJSONBoolean(ResultProps, 'success', False);
            AddJSONProperty(ResultProps, 'error', 'Failed to open PcbLib: ' + LibraryPath);
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
            Exit;
        end;

        PcbLib := GetPcbLibSafe(0);
        if PcbLib = Nil then
        begin
            AddJSONBoolean(ResultProps, 'success', False);
            AddJSONProperty(ResultProps, 'error', 'Opened document is not the active PCB library: ' + LibraryPath);
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
            Exit;
        end;

        Board := PcbLib.Board;
        if (Board = Nil) or (NormalizedPath(Board.FileName) <> NormalizedPath(LibraryPath)) then
        begin
            Result := 'ERROR: The requested PCB library could not be focused.';
            Exit;
        end;
        FootprintIterator := PcbLib.LibraryIterator_Create;
        if FootprintIterator <> Nil then
        begin
            try
                FootprintIterator.SetState_FilterAll;
                Footprint := FootprintIterator.FirstPCBObject;
                while Footprint <> Nil do
                begin
                    FootprintCount := FootprintCount + 1;
                    Footprint := FootprintIterator.NextPCBObject;
                end;
            finally
                PcbLib.LibraryIterator_Destroy(FootprintIterator);
            end;
        end;

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'requested_path', LibraryPath);
        if Board <> Nil then
            AddJSONProperty(ResultProps, 'library_path', Board.FileName);
        AddJSONBoolean(ResultProps, 'was_already_open', WasAlreadyOpen);
        AddJSONInteger(ResultProps, 'footprint_count', FootprintCount);

        OutputLines.Text := BuildJSONObject(ResultProps);
        Result := OutputLines.Text;
    finally
        OutputLines.Free;
        ResultProps.Free;
    end;
end;

function MMKey(Value: TCoord): String;
begin
    Result := StringReplace(FormatFloat('0.######', CoordToMMs(Value)), ',', '.', REPLACEALL);
end;

procedure IncrementCount(Counts: TStringList; Key: String);
var
    CurrentValue: Integer;
begin
    Key := Trim(Key);
    if Key = '' then
        Key := '(blank)';

    CurrentValue := StrToIntDef(Counts.Values[Key], 0) + 1;
    Counts.Values[Key] := IntToStr(CurrentValue);
end;

procedure AddUniqueJSONString(Items: TStringList; Value: String);
var
    JSONValue: String;
begin
    JSONValue := '"' + JSONEscapeString(Value) + '"';
    if Items.IndexOf(JSONValue) < 0 then
        Items.Add(JSONValue);
end;

function BuildCountJSONArray(Counts: TStringList; ArrayName, KeyName: String): String;
var
    Items : TStringList;
    Props : TStringList;
    Line  : String;
    Key   : String;
    Value : String;
    EqPos : Integer;
    i     : Integer;
begin
    Items := TStringList.Create;
    try
        for i := 0 to Counts.Count - 1 do
        begin
            Line := Counts[i];
            EqPos := Pos('=', Line);
            if EqPos > 0 then
            begin
                Key := Copy(Line, 1, EqPos - 1);
                Value := Copy(Line, EqPos + 1, Length(Line) - EqPos);
            end
            else
            begin
                Key := Line;
                Value := '0';
            end;

            Props := TStringList.Create;
            try
                AddJSONProperty(Props, KeyName, Key);
                AddJSONInteger(Props, 'count', StrToIntDef(Value, 0));
                Items.Add(BuildJSONObject(Props, 1));
            finally
                Props.Free;
            end;
        end;

        Result := BuildJSONArray(Items, ArrayName);
    finally
        Items.Free;
    end;
end;

procedure AddPCBLibraryFootprintStats(PcbLib: IPCB_Library; Board: IPCB_Board; Footprint: IPCB_LibComponent; StatsArray: TStringList);
var
    PrimitiveIterator : IPCB_GroupIterator;
    Primitive         : IPCB_Primitive;
    Pad               : IPCB_Pad;
    Track             : IPCB_Track;
    Arc               : IPCB_Arc;
    TextPrimitive     : IPCB_Text;
    Body              : IPCB_ComponentBody;
    Props             : TStringList;
    PadLayerCounts    : TStringList;
    PadShapeCounts    : TStringList;
    PadSizeCounts     : TStringList;
    TrackLayerCounts  : TStringList;
    TrackWidthCounts  : TStringList;
    ArcLayerCounts    : TStringList;
    ArcWidthCounts    : TStringList;
    BodyLayerCounts   : TStringList;
    BodyHeightCounts  : TStringList;
    TextValues        : TStringList;
    PadCount          : Integer;
    TrackCount        : Integer;
    ArcCount          : Integer;
    TextCount         : Integer;
    BodyCount         : Integer;
begin
    if (PcbLib = Nil) or (Footprint = Nil) then
        Exit;

    PcbLib.CurrentComponent := Footprint;
    Footprint := PcbLib.CurrentComponent;

    Props := TStringList.Create;
    PadLayerCounts := TStringList.Create;
    PadShapeCounts := TStringList.Create;
    PadSizeCounts := TStringList.Create;
    TrackLayerCounts := TStringList.Create;
    TrackWidthCounts := TStringList.Create;
    ArcLayerCounts := TStringList.Create;
    ArcWidthCounts := TStringList.Create;
    BodyLayerCounts := TStringList.Create;
    BodyHeightCounts := TStringList.Create;
    TextValues := TStringList.Create;
    PadCount := 0;
    TrackCount := 0;
    ArcCount := 0;
    TextCount := 0;
    BodyCount := 0;

    try
        PrimitiveIterator := Footprint.GroupIterator_Create;
        if PrimitiveIterator <> Nil then
        begin
            try
                PrimitiveIterator.SetState_FilterAll;
                Primitive := PrimitiveIterator.FirstPCBObject;
                while Primitive <> Nil do
                begin
                    if Primitive.ObjectId = ePadObject then
                    begin
                        Pad := Primitive;
                        PadCount := PadCount + 1;
                        IncrementCount(PadLayerCounts, Layer2String(Pad.Layer));
                        IncrementCount(PadShapeCounts, IntToStr(Pad.TopShape));
                        IncrementCount(PadSizeCounts, MMKey(Pad.TopXSize) + 'x' + MMKey(Pad.TopYSize));
                    end
                    else if Primitive.ObjectId = eTrackObject then
                    begin
                        Track := Primitive;
                        TrackCount := TrackCount + 1;
                        IncrementCount(TrackLayerCounts, Layer2String(Track.Layer));
                        IncrementCount(TrackWidthCounts, MMKey(Track.Width));
                    end
                    else if Primitive.ObjectId = eArcObject then
                    begin
                        Arc := Primitive;
                        ArcCount := ArcCount + 1;
                        IncrementCount(ArcLayerCounts, Layer2String(Arc.Layer));
                        IncrementCount(ArcWidthCounts, MMKey(Arc.LineWidth));
                    end
                    else if Primitive.ObjectId = eTextObject then
                    begin
                        TextPrimitive := Primitive;
                        TextCount := TextCount + 1;
                        AddUniqueJSONString(TextValues, TextPrimitive.Text + ' @ ' + Layer2String(TextPrimitive.Layer));
                    end
                    else if Primitive.ObjectId = eComponentBodyObject then
                    begin
                        Body := Primitive;
                        BodyCount := BodyCount + 1;
                        IncrementCount(BodyLayerCounts, Layer2String(Primitive.Layer));
                        IncrementCount(
                            BodyHeightCounts,
                            'standoff ' + MMKey(Body.StandoffHeight) + ' overall ' + MMKey(Body.OverallHeight)
                        );
                    end;

                    Primitive := PrimitiveIterator.NextPCBObject;
                end;
            finally
                Footprint.GroupIterator_Destroy(PrimitiveIterator);
            end;
        end;

        AddJSONProperty(Props, 'footprint', Footprint.Name);
        AddJSONProperty(Props, 'description', Footprint.GetState_Description);
        AddJSONInteger(Props, 'pad_count', PadCount);
        AddJSONInteger(Props, 'track_count', TrackCount);
        AddJSONInteger(Props, 'arc_count', ArcCount);
        AddJSONInteger(Props, 'text_count', TextCount);
        AddJSONInteger(Props, 'body_count', BodyCount);
        Props.Add(BuildCountJSONArray(PadLayerCounts, 'pad_layers', 'layer'));
        Props.Add(BuildCountJSONArray(PadShapeCounts, 'pad_shapes', 'shape'));
        Props.Add(BuildCountJSONArray(PadSizeCounts, 'pad_sizes_mm', 'size'));
        Props.Add(BuildCountJSONArray(TrackLayerCounts, 'track_layers', 'layer'));
        Props.Add(BuildCountJSONArray(TrackWidthCounts, 'track_widths_mm', 'width'));
        Props.Add(BuildCountJSONArray(ArcLayerCounts, 'arc_layers', 'layer'));
        Props.Add(BuildCountJSONArray(ArcWidthCounts, 'arc_widths_mm', 'width'));
        Props.Add(BuildCountJSONArray(BodyLayerCounts, 'body_layers', 'layer'));
        Props.Add(BuildCountJSONArray(BodyHeightCounts, 'body_heights_mm', 'height'));
        Props.Add(BuildJSONArray(TextValues, 'texts'));

        StatsArray.Add(BuildJSONObject(Props, 1));
    finally
        TextValues.Free;
        BodyHeightCounts.Free;
        BodyLayerCounts.Free;
        ArcWidthCounts.Free;
        ArcLayerCounts.Free;
        TrackWidthCounts.Free;
        TrackLayerCounts.Free;
        PadSizeCounts.Free;
        PadShapeCounts.Free;
        PadLayerCounts.Free;
        Props.Free;
    end;
end;

function ParsePCBLibraryStatsDumpCommand(MoveText: String; var FootprintName: String): Boolean;
var
    CommandName : String;
    SeparatorPos: Integer;
begin
    Result := False;
    FootprintName := '*';

    SeparatorPos := Pos('|', MoveText);
    if SeparatorPos > 0 then
    begin
        CommandName := UpperCase(Trim(Copy(MoveText, 1, SeparatorPos - 1)));
        FootprintName := Trim(Copy(MoveText, SeparatorPos + 1, Length(MoveText) - SeparatorPos));
    end
    else
        CommandName := UpperCase(Trim(MoveText));

    if CommandName <> 'PCB_LIB_STATS_DUMP' then
        Exit;

    if FootprintName = '' then
        FootprintName := '*';

    Result := True;
end;

function FindPCBLibraryStatsDumpCommand(LayerMoves: TStringList; var FootprintName: String): Boolean;
var
    i: Integer;
begin
    Result := False;
    FootprintName := '*';

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if ParsePCBLibraryStatsDumpCommand(LayerMoves[i], FootprintName) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function DumpPCBLibraryFootprintStats(FootprintName: String): String;
var
    PcbLib            : IPCB_Library;
    Board             : IPCB_Board;
    FootprintIterator : IPCB_LibraryIterator;
    Footprint         : IPCB_LibComponent;
    ResultProps       : TStringList;
    StatsArray        : TStringList;
    OutputLines       : TStringList;
    MatchAll          : Boolean;
    Count             : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    Board := PcbLib.Board;
    ResultProps := TStringList.Create;
    StatsArray := TStringList.Create;
    OutputLines := TStringList.Create;
    Count := 0;
    MatchAll := (Trim(FootprintName) = '') or (Trim(FootprintName) = '*');

    try
        if MatchAll then
        begin
            FootprintIterator := PcbLib.LibraryIterator_Create;
            if FootprintIterator = Nil then
            begin
                Result := '{"success": false, "error": "Failed to create PCB library iterator."}';
                Exit;
            end;

            try
                FootprintIterator.SetState_FilterAll;
                Footprint := FootprintIterator.FirstPCBObject;
                while Footprint <> Nil do
                begin
                    AddPCBLibraryFootprintStats(PcbLib, Board, Footprint, StatsArray);
                    Count := Count + 1;
                    Footprint := FootprintIterator.NextPCBObject;
                end;
            finally
                PcbLib.LibraryIterator_Destroy(FootprintIterator);
            end;
        end
        else
        begin
            Footprint := FindLibFootprint(PcbLib, FootprintName);
            if Footprint = Nil then
            begin
                Result := '{"success": false, "error": "Footprint not found."}';
                Exit;
            end;

            AddPCBLibraryFootprintStats(PcbLib, Board, Footprint, StatsArray);
            Count := 1;
        end;

        AddJSONBoolean(ResultProps, 'success', True);
        if Board <> Nil then
            AddJSONProperty(ResultProps, 'library_path', Board.FileName);
        AddJSONProperty(ResultProps, 'footprint_filter', FootprintName);
        AddJSONInteger(ResultProps, 'footprints_processed', Count);
        ResultProps.Add(BuildJSONArray(StatsArray, 'footprints'));

        OutputLines.Text := BuildJSONObject(ResultProps);
        Result := OutputLines.Text;
    finally
        OutputLines.Free;
        StatsArray.Free;
        ResultProps.Free;
    end;
end;

function ParsePCBLibrarySetDescriptionCommand(MoveText: String; var FootprintName, DescriptionText: String): Boolean;
var
    CommandName: String;
    Remainder  : String;
    Separator  : Integer;
    DescriptionSeparator: Integer;
begin
    Result := False;
    FootprintName := '';
    DescriptionText := '';

    MoveText := Trim(MoveText);
    Separator := Pos('|', MoveText);
    if Separator <= 1 then
        Exit;

    CommandName := UpperCase(Trim(Copy(MoveText, 1, Separator - 1)));
    if CommandName <> 'PCB_LIB_SET_DESCRIPTION' then
        Exit;

    Remainder := Copy(MoveText, Separator + 1, Length(MoveText) - Separator);
    DescriptionSeparator := Pos('|', Remainder);
    if DescriptionSeparator <= 1 then
        Exit;

    FootprintName := Trim(Copy(Remainder, 1, DescriptionSeparator - 1));
    DescriptionText := Trim(Copy(Remainder, DescriptionSeparator + 1, Length(Remainder) - DescriptionSeparator));
    Result := (FootprintName <> '') and (DescriptionText <> '');
end;

function FindPCBLibrarySetDescriptionCommands(LayerMoves: TStringList; FootprintNames, DescriptionTexts: TStringList): Boolean;
var
    i              : Integer;
    FootprintName  : String;
    DescriptionText: String;
begin
    Result := False;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if ParsePCBLibrarySetDescriptionCommand(LayerMoves[i], FootprintName, DescriptionText) then
        begin
            FootprintNames.Add(FootprintName);
            DescriptionTexts.Add(DescriptionText);
            Result := True;
        end;
    end;
end;

function ParsePCBLibraryBatchCreateCommand(MoveText: String; var DataFileName: String; var SkipExisting: Boolean): Boolean;
var
    Fields: TStringList;
begin
    Result := False;
    DataFileName := ROOT_DIR + 'pcblib_batch_footprints.txt';
    SkipExisting := True;

    Fields := TStringList.Create;
    try
        Fields.Delimiter := '|';
        Fields.StrictDelimiter := True;
        Fields.DelimitedText := Trim(MoveText);

        if Fields.Count < 1 then
            Exit;
        if UpperCase(Trim(Fields[0])) <> 'PCB_LIB_BATCH_CREATE' then
            Exit;

        if (Fields.Count >= 2) and (Trim(Fields[1]) <> '') then
            DataFileName := Trim(Fields[1]);
        if Fields.Count >= 3 then
            SkipExisting := UpperCase(Trim(Fields[2])) <> 'FALSE';

        Result := True;
    finally
        Fields.Free;
    end;
end;

function FindPCBLibraryBatchCreateCommand(LayerMoves: TStringList; var DataFileName: String; var SkipExisting: Boolean): Boolean;
var
    i: Integer;
begin
    Result := False;
    DataFileName := ROOT_DIR + 'pcblib_batch_footprints.txt';
    SkipExisting := True;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if ParsePCBLibraryBatchCreateCommand(LayerMoves[i], DataFileName, SkipExisting) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function ParsePCBLibraryCleanPadsOverlayCommand(MoveText: String; var TargetNameContains, PadNamePrefix, OverlayLayerName: String): Boolean;
var
    Fields: TStringList;
begin
    Result := False;
    TargetNameContains := '';
    PadNamePrefix := 'MP';
    OverlayLayerName := 'Top Overlay';

    Fields := TStringList.Create;
    try
        Fields.Delimiter := '|';
        Fields.StrictDelimiter := True;
        Fields.DelimitedText := Trim(MoveText);

        if Fields.Count < 1 then
            Exit;
        if UpperCase(Trim(Fields[0])) <> 'PCB_LIB_CLEAN_PADS_OVERLAY' then
            Exit;

        if Fields.Count >= 2 then
            TargetNameContains := Trim(Fields[1]);
        if (Fields.Count >= 3) and (Trim(Fields[2]) <> '') then
            PadNamePrefix := Trim(Fields[2]);
        if (Fields.Count >= 4) and (Trim(Fields[3]) <> '') then
            OverlayLayerName := Trim(Fields[3]);

        Result := True;
    finally
        Fields.Free;
    end;
end;

function FindPCBLibraryCleanPadsOverlayCommand(LayerMoves: TStringList; var TargetNameContains, PadNamePrefix, OverlayLayerName: String): Boolean;
var
    i: Integer;
begin
    Result := False;
    TargetNameContains := '';
    PadNamePrefix := 'MP';
    OverlayLayerName := 'Top Overlay';

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if ParsePCBLibraryCleanPadsOverlayCommand(LayerMoves[i], TargetNameContains, PadNamePrefix, OverlayLayerName) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function FindPCBLibraryJoinSelectedPadsCustomCommand(LayerMoves: TStringList; var JoinAction: String): Boolean;
var
    i: Integer;
    MoveText: String;
begin
    Result := False;
    JoinAction := '';

    for i := 0 to LayerMoves.Count - 1 do
    begin
        MoveText := UpperCase(Trim(LayerMoves[i]));
        if MoveText = 'PCB_LIB_JOIN_SELECTED_PADS_CUSTOM' then
        begin
            JoinAction := 'FULL';
            Result := True;
            Exit;
        end
        else if MoveText = 'PCB_LIB_JOIN_SELECTED_PADS_CUSTOM_PREPARE' then
        begin
            JoinAction := 'PREPARE';
            Result := True;
            Exit;
        end
        else if MoveText = 'PCB_LIB_JOIN_SELECTED_PADS_CUSTOM_CONVERT' then
        begin
            JoinAction := 'CONVERT';
            Result := True;
            Exit;
        end
        else if MoveText = 'PCB_LIB_JOIN_SELECTED_PADS_CUSTOM_CLEANUP' then
        begin
            JoinAction := 'CLEANUP';
            Result := True;
            Exit;
        end
        else if MoveText = 'PCB_LIB_JOIN_SELECTED_PADS_CUSTOM_REBUILD_SOURCE' then
        begin
            JoinAction := 'REBUILD_SOURCE';
            Result := True;
            Exit;
        end;
    end;
end;

function Parse3DBodyBatchImportCommand(MoveText: String; var DataFileName: String; var SkipExisting: Boolean): Boolean;
var
    Fields: TStringList;
begin
    Result := False;
    DataFileName := ROOT_DIR + 'pcblib_3d_body_import.txt';
    SkipExisting := True;

    Fields := TStringList.Create;
    try
        Fields.Delimiter := '|';
        Fields.StrictDelimiter := True;
        Fields.DelimitedText := Trim(MoveText);

        if Fields.Count < 1 then
            Exit;
        if UpperCase(Trim(Fields[0])) <> '3D_BODY_BATCH_IMPORT' then
            Exit;

        if (Fields.Count >= 2) and (Trim(Fields[1]) <> '') then
            DataFileName := Trim(Fields[1]);
        if Fields.Count >= 3 then
            SkipExisting := UpperCase(Trim(Fields[2])) <> 'FALSE';

        Result := True;
    finally
        Fields.Free;
    end;
end;

function Find3DBodyBatchImportCommand(LayerMoves: TStringList; var DataFileName: String; var SkipExisting: Boolean): Boolean;
var
    i: Integer;
begin
    Result := False;
    DataFileName := ROOT_DIR + 'pcblib_3d_body_import.txt';
    SkipExisting := True;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if Parse3DBodyBatchImportCommand(LayerMoves[i], DataFileName, SkipExisting) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function Parse3DBodyBatchSetPlacementCommand(MoveText: String; var DataFileName: String): Boolean;
var
    Fields: TStringList;
begin
    Result := False;
    DataFileName := ROOT_DIR + 'pcblib_3d_body_placements.txt';

    Fields := TStringList.Create;
    try
        Fields.Delimiter := '|';
        Fields.StrictDelimiter := True;
        Fields.DelimitedText := Trim(MoveText);

        if Fields.Count < 1 then
            Exit;
        if UpperCase(Trim(Fields[0])) <> '3D_BODY_BATCH_SET_PLACEMENT' then
            Exit;

        if (Fields.Count >= 2) and (Trim(Fields[1]) <> '') then
            DataFileName := Trim(Fields[1]);

        Result := True;
    finally
        Fields.Free;
    end;
end;

function Find3DBodyBatchSetPlacementCommand(LayerMoves: TStringList; var DataFileName: String): Boolean;
var
    i: Integer;
begin
    Result := False;
    DataFileName := ROOT_DIR + 'pcblib_3d_body_placements.txt';

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if Parse3DBodyBatchSetPlacementCommand(LayerMoves[i], DataFileName) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function Parse3DBodyBatchSetIdentifierCommand(MoveText: String; var DataFileName: String): Boolean;
var
    Fields: TStringList;
begin
    Result := False;
    DataFileName := ROOT_DIR + 'pcblib_3d_body_identifiers.txt';

    Fields := TStringList.Create;
    try
        Fields.Delimiter := '|';
        Fields.StrictDelimiter := True;
        Fields.DelimitedText := Trim(MoveText);

        if Fields.Count < 1 then
            Exit;
        if UpperCase(Trim(Fields[0])) <> '3D_BODY_BATCH_SET_IDENTIFIER' then
            Exit;

        if (Fields.Count >= 2) and (Trim(Fields[1]) <> '') then
            DataFileName := Trim(Fields[1]);

        Result := True;
    finally
        Fields.Free;
    end;
end;

function Find3DBodyBatchSetIdentifierCommand(LayerMoves: TStringList; var DataFileName: String): Boolean;
var
    i: Integer;
begin
    Result := False;
    DataFileName := ROOT_DIR + 'pcblib_3d_body_identifiers.txt';

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if Parse3DBodyBatchSetIdentifierCommand(LayerMoves[i], DataFileName) then
        begin
            Result := True;
            Exit;
        end;
    end;
end;

function DumpPCBLibraryFootprintDescriptions(FootprintName: String): String;
var
    PcbLib          : IPCB_Library;
    FootprintIterator: IPCB_LibraryIterator;
    Footprint       : IPCB_LibComponent;
    ResultProps     : TStringList;
    DescriptionsArray: TStringList;
    Props           : TStringList;
    OutputLines     : TStringList;
    MatchAll        : Boolean;
    Count           : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    ResultProps := TStringList.Create;
    DescriptionsArray := TStringList.Create;
    OutputLines := TStringList.Create;
    Count := 0;
    MatchAll := (Trim(FootprintName) = '') or (Trim(FootprintName) = '*');

    try
        if MatchAll then
        begin
            FootprintIterator := PcbLib.LibraryIterator_Create;
            if FootprintIterator = Nil then
            begin
                Result := '{"success": false, "error": "Failed to create PCB library iterator."}';
                Exit;
            end;

            try
                FootprintIterator.SetState_FilterAll;
                Footprint := FootprintIterator.FirstPCBObject;
                while Footprint <> Nil do
                begin
                    Props := TStringList.Create;
                    try
                        AddJSONProperty(Props, 'footprint', Footprint.Name);
                        AddJSONProperty(Props, 'description', Footprint.GetState_Description);
                        DescriptionsArray.Add(BuildJSONObject(Props, 1));
                    finally
                        Props.Free;
                    end;
                    Count := Count + 1;
                    Footprint := FootprintIterator.NextPCBObject;
                end;
            finally
                PcbLib.LibraryIterator_Destroy(FootprintIterator);
            end;
        end
        else
        begin
            Footprint := FindLibFootprint(PcbLib, FootprintName);
            if Footprint = Nil then
            begin
                Result := '{"success": false, "error": "Footprint not found."}';
                Exit;
            end;

            Props := TStringList.Create;
            try
                AddJSONProperty(Props, 'footprint', Footprint.Name);
                AddJSONProperty(Props, 'description', Footprint.GetState_Description);
                DescriptionsArray.Add(BuildJSONObject(Props, 1));
            finally
                Props.Free;
            end;
            Count := 1;
        end;

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'footprint_filter', FootprintName);
        AddJSONInteger(ResultProps, 'footprints_processed', Count);
        ResultProps.Add(BuildJSONArray(DescriptionsArray, 'descriptions'));

        OutputLines.Text := BuildJSONObject(ResultProps);
        Result := OutputLines.Text;
    finally
        OutputLines.Free;
        DescriptionsArray.Free;
        ResultProps.Free;
    end;
end;

function SetPCBLibraryFootprintDescriptions(FootprintNames, DescriptionTexts: TStringList): String;
var
    PcbLib          : IPCB_Library;
    Board           : IPCB_Board;
    Footprint       : IPCB_LibComponent;
    ResultProps     : TStringList;
    ResultsArray    : TStringList;
    Props           : TStringList;
    OutputLines     : TStringList;
    i               : Integer;
    ModifiedCount   : Integer;
    UnchangedCount  : Integer;
    MissingCount    : Integer;
    OldDescription  : String;
    NewDescription  : String;
begin
    if FootprintNames.Count <> DescriptionTexts.Count then
    begin
        Result := '{"success": false, "error": "Description command name/value count mismatch."}';
        Exit;
    end;

    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    Board := PcbLib.Board;
    ResultProps := TStringList.Create;
    ResultsArray := TStringList.Create;
    OutputLines := TStringList.Create;
    ModifiedCount := 0;
    UnchangedCount := 0;
    MissingCount := 0;

    try
        for i := 0 to FootprintNames.Count - 1 do
        begin
            Footprint := FindLibFootprint(PcbLib, FootprintNames[i]);
            Props := TStringList.Create;
            try
                AddJSONProperty(Props, 'footprint', FootprintNames[i]);
                if Footprint = Nil then
                begin
                    AddJSONBoolean(Props, 'success', False);
                    AddJSONProperty(Props, 'error', 'Footprint not found.');
                    MissingCount := MissingCount + 1;
                end
                else
                begin
                    PcbLib.CurrentComponent := Footprint;
                    Footprint := PcbLib.CurrentComponent;
                    OldDescription := Footprint.GetState_Description;
                    NewDescription := DescriptionTexts[i];

                    AddJSONBoolean(Props, 'success', True);
                    AddJSONProperty(Props, 'old_description', OldDescription);
                    AddJSONProperty(Props, 'new_description', NewDescription);

                    if OldDescription <> NewDescription then
                    begin
                        Footprint.SetState_Description(NewDescription);
                        AddJSONBoolean(Props, 'modified', True);
                        ModifiedCount := ModifiedCount + 1;
                    end
                    else
                    begin
                        AddJSONBoolean(Props, 'modified', False);
                        UnchangedCount := UnchangedCount + 1;
                    end;
                end;

                ResultsArray.Add(BuildJSONObject(Props, 1));
            finally
                Props.Free;
            end;
        end;

        if Board <> Nil then
            Board.ViewManager_FullUpdate;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        AddJSONBoolean(ResultProps, 'success', MissingCount = 0);
        AddJSONInteger(ResultProps, 'commands_seen', FootprintNames.Count);
        AddJSONInteger(ResultProps, 'footprints_modified', ModifiedCount);
        AddJSONInteger(ResultProps, 'footprints_unchanged', UnchangedCount);
        AddJSONInteger(ResultProps, 'footprints_missing', MissingCount);
        ResultProps.Add(BuildJSONArray(ResultsArray, 'results'));

        OutputLines.Text := BuildJSONObject(ResultProps);
        Result := OutputLines.Text;
    finally
        OutputLines.Free;
        ResultsArray.Free;
        ResultProps.Free;
    end;
end;

function CountPCBLibraryFootprintPrimitives(Footprint: IPCB_LibComponent): Integer;
var
    PrimitiveIterator: IPCB_GroupIterator;
    Primitive        : IPCB_Primitive;
begin
    Result := 0;
    if Footprint = Nil then
        Exit;

    PrimitiveIterator := Footprint.GroupIterator_Create;
    if PrimitiveIterator = Nil then
        Exit;

    try
        PrimitiveIterator.SetState_FilterAll;
        Primitive := PrimitiveIterator.FirstPCBObject;
        while Primitive <> Nil do
        begin
            Result := Result + 1;
            Primitive := PrimitiveIterator.NextPCBObject;
        end;
    finally
        Footprint.GroupIterator_Destroy(PrimitiveIterator);
    end;
end;

function CreatePCBLibraryBatchFootprints(DataFileName: String; SkipExisting: Boolean): String;
var
    PcbLib          : IPCB_Library;
    Board           : IPCB_Board;
    LibComp         : IPCB_Component;
    Footprint       : IPCB_LibComponent;
    ExistingFootprint: IPCB_LibComponent;
    Lines           : TStringList;
    Fields          : TStringList;
    ResultProps     : TStringList;
    CreatedFootprints: TStringList;
    SkippedFootprints: TStringList;
    PopulatedFootprints: TStringList;
    ErrorArray      : TStringList;
    OutputLines     : TStringList;
    LineText        : String;
    CommandName     : String;
    CurrentName     : String;
    CurrentDescription: String;
    LayerName       : String;
    ShapeStr        : String;
    PadShape        : TShape;
    CurrentSkipped  : Boolean;
    CurrentExisting : Boolean;
    i               : Integer;
    FootprintsSeen  : Integer;
    FootprintsCreated: Integer;
    FootprintsSkipped: Integer;
    FootprintsPopulated: Integer;
    ExistingPrimitiveCount: Integer;
    PrimitiveCount  : Integer;
    Pad             : IPCB_Pad;
    Track           : IPCB_Track;
    Arc             : IPCB_Arc;
    TextPrimitive   : IPCB_Text;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    if not FileExists(DataFileName) then
    begin
        Result := '{"success": false, "error": "Batch footprint file not found."}';
        Exit;
    end;

    Board := PcbLib.Board;
    Lines := TStringList.Create;
    Fields := TStringList.Create;
    ResultProps := TStringList.Create;
    CreatedFootprints := TStringList.Create;
    SkippedFootprints := TStringList.Create;
    PopulatedFootprints := TStringList.Create;
    ErrorArray := TStringList.Create;
    OutputLines := TStringList.Create;
    CurrentName := '';
    CurrentDescription := '';
    CurrentSkipped := False;
    CurrentExisting := False;
    LibComp := Nil;
    Footprint := Nil;
    FootprintsSeen := 0;
    FootprintsCreated := 0;
    FootprintsSkipped := 0;
    FootprintsPopulated := 0;
    PrimitiveCount := 0;

    try
        Fields.Delimiter := '|';
        Fields.StrictDelimiter := True;
        Lines.LoadFromFile(DataFileName);

        PCBServer.PreProcess;
        try
            for i := 0 to Lines.Count - 1 do
            begin
            LineText := Trim(Lines[i]);
            if LineText = '' then
                continue;
            if Copy(LineText, 1, 1) = '#' then
                continue;

            Fields.Clear;
            Fields.DelimitedText := LineText;
            if Fields.Count = 0 then
                continue;

            CommandName := UpperCase(Trim(Fields[0]));

            if CommandName = 'FOOTPRINT' then
            begin
                if Fields.Count < 3 then
                begin
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': FOOTPRINT requires name and description.') + '"');
                    continue;
                end;

                CurrentName := Trim(Fields[1]);
                CurrentDescription := Trim(Fields[2]);
                CurrentSkipped := False;
                CurrentExisting := False;
                LibComp := Nil;
                Footprint := Nil;
                FootprintsSeen := FootprintsSeen + 1;

                ExistingFootprint := FindLibFootprint(PcbLib, CurrentName);
                if ExistingFootprint <> Nil then
                begin
                    ExistingPrimitiveCount := CountPCBLibraryFootprintPrimitives(ExistingFootprint);
                    if SkipExisting and (ExistingPrimitiveCount > 0) then
                    begin
                        CurrentSkipped := True;
                        FootprintsSkipped := FootprintsSkipped + 1;
                        SkippedFootprints.Add('"' + JSONEscapeString(CurrentName) + '"');
                    end
                    else
                    begin
                        CurrentExisting := True;
                        PcbLib.CurrentComponent := ExistingFootprint;
                        Footprint := PcbLib.CurrentComponent;
                        if Footprint <> Nil then
                            Footprint.SetState_Description(CurrentDescription);
                    end;
                end;

                if (ExistingFootprint = Nil) then
                begin
                    LibComp := PCBServer.CreatePCBLibComp;
                    if LibComp = Nil then
                    begin
                        ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': failed to create footprint: ' + CurrentName) + '"');
                        CurrentSkipped := True;
                        continue;
                    end;

                    LibComp.Name := CurrentName;
                    PcbLib.RegisterComponent(LibComp);
                    PcbLib.CurrentComponent := LibComp;
                    Footprint := PcbLib.CurrentComponent;
                    if Footprint <> Nil then
                        Footprint.SetState_Description(CurrentDescription);
                end;
            end
            else if CommandName = 'END' then
            begin
                if (not CurrentSkipped) and (Footprint <> Nil) then
                begin
                    if CurrentExisting then
                    begin
                        PopulatedFootprints.Add('"' + JSONEscapeString(CurrentName) + '"');
                        FootprintsPopulated := FootprintsPopulated + 1;
                    end
                    else
                    begin
                        CreatedFootprints.Add('"' + JSONEscapeString(CurrentName) + '"');
                        FootprintsCreated := FootprintsCreated + 1;
                    end;
                end;

                CurrentName := '';
                CurrentDescription := '';
                CurrentSkipped := False;
                CurrentExisting := False;
                LibComp := Nil;
                Footprint := Nil;
            end
            else if (CurrentSkipped) or (Footprint = Nil) then
                continue
            else if CommandName = 'PAD' then
            begin
                if Fields.Count < 7 then
                begin
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': PAD requires name, x, y, width, height, shape.') + '"');
                    continue;
                end;
                if Board = Nil then
                begin
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': active PcbLib board is nil.') + '"');
                    continue;
                end;

                ShapeStr := UpperCase(Trim(Fields[6]));
                if ShapeStr = 'ROUND' then
                    PadShape := eRounded
                else if (ShapeStr = 'OVAL') or (ShapeStr = 'ROUNDRECT') then
                    PadShape := eRoundedRectangular
                else
                    PadShape := eRectangular;

                Pad := PCBServer.PCBObjectFactory(ePadObject, eNoDimension, eCreate_Default);
                if Pad <> Nil then
                begin
                    Pad.Name := Trim(Fields[1]);
                    Pad.Mode := ePadMode_Simple;
                    Pad.HoleSize := 0;
                    Pad.X := Board.XOrigin + MMsToCoord(SafeStrToFloat(Fields[2]));
                    Pad.Y := Board.YOrigin + MMsToCoord(SafeStrToFloat(Fields[3]));
                    Pad.Layer := eTopLayer;
                    Pad.TopXSize := MMsToCoord(SafeStrToFloat(Fields[4]));
                    Pad.TopYSize := MMsToCoord(SafeStrToFloat(Fields[5]));
                    Pad.TopShape := PadShape;
                    PCBServer.SendMessageToRobots(Pad.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
                    Board.AddPCBObject(Pad);
                    PCBServer.SendMessageToRobots(Pad.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
                    PrimitiveCount := PrimitiveCount + 1;
                end;
            end
            else if CommandName = 'TRACK' then
            begin
                if Fields.Count < 7 then
                begin
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': TRACK requires layer, x1, y1, x2, y2, width.') + '"');
                    continue;
                end;
                if Board = Nil then
                begin
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': active PcbLib board is nil.') + '"');
                    continue;
                end;

                LayerName := Trim(Fields[1]);
                Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
                if Track <> Nil then
                begin
                    Track.Layer := String2Layer(LayerName);
                    Track.X1 := Board.XOrigin + MMsToCoord(SafeStrToFloat(Fields[2]));
                    Track.Y1 := Board.YOrigin + MMsToCoord(SafeStrToFloat(Fields[3]));
                    Track.X2 := Board.XOrigin + MMsToCoord(SafeStrToFloat(Fields[4]));
                    Track.Y2 := Board.YOrigin + MMsToCoord(SafeStrToFloat(Fields[5]));
                    Track.Width := MMsToCoord(SafeStrToFloat(Fields[6]));
                    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
                    Board.AddPCBObject(Track);
                    PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
                    PrimitiveCount := PrimitiveCount + 1;
                end;
            end
            else if CommandName = 'ARC' then
            begin
                if Fields.Count < 8 then
                begin
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': ARC requires layer, center x, center y, radius, start angle, end angle, width.') + '"');
                    continue;
                end;
                if Board = Nil then
                begin
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': active PcbLib board is nil.') + '"');
                    continue;
                end;

                LayerName := Trim(Fields[1]);
                Arc := PCBServer.PCBObjectFactory(eArcObject, eNoDimension, eCreate_Default);
                if Arc <> Nil then
                begin
                    Arc.Layer := String2Layer(LayerName);
                    Arc.XCenter := Board.XOrigin + MMsToCoord(SafeStrToFloat(Fields[2]));
                    Arc.YCenter := Board.YOrigin + MMsToCoord(SafeStrToFloat(Fields[3]));
                    Arc.Radius := MMsToCoord(SafeStrToFloat(Fields[4]));
                    Arc.StartAngle := SafeStrToFloat(Fields[5]);
                    Arc.EndAngle := SafeStrToFloat(Fields[6]);
                    Arc.LineWidth := MMsToCoord(SafeStrToFloat(Fields[7]));
                    PCBServer.SendMessageToRobots(Arc.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
                    Board.AddPCBObject(Arc);
                    PCBServer.SendMessageToRobots(Arc.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
                    PrimitiveCount := PrimitiveCount + 1;
                end;
            end
            else if CommandName = 'TEXT' then
            begin
                if Fields.Count < 8 then
                begin
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': TEXT requires layer, text, x, y, size, width, rotation.') + '"');
                    continue;
                end;
                if Board = Nil then
                begin
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': active PcbLib board is nil.') + '"');
                    continue;
                end;

                LayerName := Trim(Fields[1]);
                TextPrimitive := PCBServer.PCBObjectFactory(eTextObject, eNoDimension, eCreate_Default);
                if TextPrimitive <> Nil then
                begin
                    TextPrimitive.Layer := String2Layer(LayerName);
                    TextPrimitive.Text := Fields[2];
                    TextPrimitive.XLocation := Board.XOrigin + MMsToCoord(SafeStrToFloat(Fields[3]));
                    TextPrimitive.YLocation := Board.YOrigin + MMsToCoord(SafeStrToFloat(Fields[4]));
                    TextPrimitive.Size := MMsToCoord(SafeStrToFloat(Fields[5]));
                    TextPrimitive.Width := MMsToCoord(SafeStrToFloat(Fields[6]));
                    TextPrimitive.Rotation := SafeStrToFloat(Fields[7]);
                    TextPrimitive.UseTTFonts := True;
                    TextPrimitive.FontName := 'ARIAL';
                    PCBServer.SendMessageToRobots(TextPrimitive.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
                    Board.AddPCBObject(TextPrimitive);
                    PCBServer.SendMessageToRobots(TextPrimitive.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
                    PrimitiveCount := PrimitiveCount + 1;
                end;
            end;
            end;
        finally
            PCBServer.PostProcess;
        end;

        AddJSONBoolean(ResultProps, 'success', ErrorArray.Count = 0);
        AddJSONProperty(ResultProps, 'data_file', DataFileName);
        AddJSONBoolean(ResultProps, 'skip_existing', SkipExisting);
        AddJSONInteger(ResultProps, 'footprints_seen', FootprintsSeen);
        AddJSONInteger(ResultProps, 'footprints_created', FootprintsCreated);
        AddJSONInteger(ResultProps, 'footprints_skipped', FootprintsSkipped);
        AddJSONInteger(ResultProps, 'footprints_populated', FootprintsPopulated);
        AddJSONInteger(ResultProps, 'primitives_created', PrimitiveCount);
        ResultProps.Add(BuildJSONArray(CreatedFootprints, 'created_footprints'));
        ResultProps.Add(BuildJSONArray(SkippedFootprints, 'skipped_footprints'));
        ResultProps.Add(BuildJSONArray(PopulatedFootprints, 'populated_footprints'));
        ResultProps.Add(BuildJSONArray(ErrorArray, 'errors'));

        OutputLines.Text := BuildJSONObject(ResultProps);
        Result := OutputLines.Text;
    finally
        OutputLines.Free;
        ErrorArray.Free;
        PopulatedFootprints.Free;
        SkippedFootprints.Free;
        CreatedFootprints.Free;
        ResultProps.Free;
        Fields.Free;
        Lines.Free;
    end;
end;

function ApplyGenericStepModelPlacement(Model: IPCB_Model; RotX, RotY, RotZ, ModelZMM: Double; var ErrorText: String): Boolean;
begin
    if Model = Nil then
    begin
        Result := False;
        ErrorText := 'STEP model is nil.';
        Exit;
    end;

    ErrorText := '';
    Model.SetState(RotX, RotY, RotZ, MMsToCoord(ModelZMM));
    Result := True;
end;

function StepIdentifierFromPath(StepPath: String): String;
var
    FileName : String;
    DotIndex : Integer;
    i        : Integer;
begin
    FileName := ExtractFileName(Trim(StepPath));
    DotIndex := 0;

    for i := Length(FileName) downto 1 do
    begin
        if Copy(FileName, i, 1) = '.' then
        begin
            DotIndex := i;
            Break;
        end;
    end;

    if DotIndex > 1 then
        Result := Copy(FileName, 1, DotIndex - 1)
    else
        Result := FileName;
end;

function AddStepBodyToActiveComponentWithPlacement(PcbLib: IPCB_Library; Footprint: IPCB_LibComponent; StepPath: String; LocalXMM, LocalYMM, RotX, RotY, RotZ, ModelZMM, StandoffMM, OverallHeightMM: Double; var ErrorText: String): Boolean;
var
    Board   : IPCB_Board;
    StepBody: IPCB_ComponentBody;
    Model   : IPCB_Model;
    ModelError : String;
    IdentifierText : String;
    TargetCenterX : TCoord;
    TargetCenterY : TCoord;
begin
    Result := False;
    ErrorText := '';

    if (PcbLib = Nil) or (Footprint = Nil) then
    begin
        ErrorText := 'PcbLib or footprint is nil.';
        Exit;
    end;

    if not FileExists(StepPath) then
    begin
        ErrorText := 'STEP file not found: ' + StepPath;
        Exit;
    end;

    PcbLib.CurrentComponent := Footprint;
    Board := PcbLib.Board;
    if Board = Nil then
    begin
        ErrorText := 'PcbLib board is nil.';
        Exit;
    end;

    StepBody := PCBServer.PCBObjectFactory(eComponentBodyObject, eNoDimension, eCreate_Default);
    if StepBody = Nil then
    begin
        ErrorText := 'Failed to create component body.';
        Exit;
    end;

    StepBody.Layer := ILayer.MechanicalLayer(1);
    Model := StepBody.ModelFactory_FromFilename(StepPath, False);
    if Model = Nil then
    begin
        ErrorText := 'Failed to load STEP model: ' + StepPath;
        Exit;
    end;

    if not ApplyGenericStepModelPlacement(Model, RotX, RotY, RotZ, ModelZMM, ModelError) then
    begin
        ErrorText := ModelError;
        Exit;
    end;

    StepBody.SetModel(Model);
    StepBody.SetState_FromModel;
    Model := StepBody.GetModel;
    if Model <> Nil then
    begin
        if not ApplyGenericStepModelPlacement(Model, RotX, RotY, RotZ, ModelZMM, ModelError) then
        begin
            ErrorText := ModelError;
            Exit;
        end;
        StepBody.SetModel(Model);
    end;
    StepBody.Layer := ILayer.MechanicalLayer(1);
    TargetCenterX := Board.XOrigin + MMsToCoord(LocalXMM);
    TargetCenterY := Board.YOrigin + MMsToCoord(LocalYMM);
    StepBody.SetState_SnapPointX(TargetCenterX);
    StepBody.SetState_SnapPointY(TargetCenterY);
    StepBody.StandoffHeight := MMsToCoord(StandoffMM);
    if OverallHeightMM > 0 then
        StepBody.OverallHeight := MMsToCoord(OverallHeightMM);
    IdentifierText := StepIdentifierFromPath(StepPath);
    if IdentifierText <> '' then
        StepBody.SetState_Identifier(IdentifierText);

    PCBServer.SendMessageToRobots(StepBody.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
    Board.AddPCBObject(StepBody);
    StepBody.GraphicallyInvalidate;
    PCBServer.SendMessageToRobots(StepBody.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
    Result := True;
end;

function Count3DBodiesForFootprint(Footprint: IPCB_LibComponent): Integer;
var
    BodyIterator : IPCB_GroupIterator;
    Primitive    : IPCB_Primitive;
begin
    Result := 0;
    if Footprint = Nil then
        Exit;

    BodyIterator := Footprint.GroupIterator_Create;
    if BodyIterator = Nil then
        Exit;

    try
        BodyIterator.AddFilter_ObjectSet(MkSet(eComponentBodyObject));
        BodyIterator.AddFilter_LayerSet(AllLayers);
        Primitive := BodyIterator.FirstPCBObject;
        while Primitive <> Nil do
        begin
            Result := Result + 1;
            Primitive := BodyIterator.NextPCBObject;
        end;
    finally
        Footprint.GroupIterator_Destroy(BodyIterator);
    end;
end;

function Import3DBodyWithPlacement(FootprintName, StepPath: String; LocalXMM, LocalYMM, RotX, RotY, RotZ, ModelZMM, StandoffMM, OverallHeightMM: Double): String;
var
    PcbLib          : IPCB_Library;
    Board           : IPCB_Board;
    Footprint       : IPCB_LibComponent;
    ExistingBodies  : Integer;
    BodyError       : String;
    ResultProps     : TStringList;
    OutputLines     : TStringList;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    Footprint := FindLibFootprint(PcbLib, FootprintName);
    if Footprint = Nil then
    begin
        Result := '{"success": false, "error": "Footprint not found."}';
        Exit;
    end;

    if not FileExists(StepPath) then
    begin
        Result := '{"success": false, "error": "STEP file not found."}';
        Exit;
    end;

    Board := PcbLib.Board;
    EnsureMechanicalLayerEnabled(Board, 1);
    ResultProps := TStringList.Create;

    try
        Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);
        PcbLib.CurrentComponent := Footprint;
        Footprint := PcbLib.CurrentComponent;
        if Board <> Nil then
            Board.ViewManager_FullUpdate;

        ExistingBodies := Count3DBodiesForFootprint(Footprint);
        if ExistingBodies > 0 then
        begin
            AddJSONBoolean(ResultProps, 'success', False);
            AddJSONBoolean(ResultProps, 'mutated', False);
            AddJSONProperty(ResultProps, 'footprint', FootprintName);
            AddJSONProperty(ResultProps, 'step_file', StepPath);
            AddJSONInteger(ResultProps, 'existing_bodies', ExistingBodies);
            AddJSONProperty(ResultProps, 'error', 'Footprint already has a 3D body. Remove it manually or import into an empty footprint.');
        end
        else
        begin

            PCBServer.PreProcess;
            try
                if not AddStepBodyToActiveComponentWithPlacement(PcbLib, Footprint, StepPath, LocalXMM, LocalYMM, RotX, RotY, RotZ, ModelZMM, StandoffMM, OverallHeightMM, BodyError) then
                begin
                    AddJSONBoolean(ResultProps, 'success', False);
                    AddJSONProperty(ResultProps, 'error', BodyError);
                end
                else
                begin
                    AddJSONBoolean(ResultProps, 'success', True);
                    AddJSONBoolean(ResultProps, 'mutated', True);
                    AddJSONProperty(ResultProps, 'footprint', FootprintName);
                    AddJSONProperty(ResultProps, 'step_file', StepPath);
                    AddJSONProperty(ResultProps, 'identifier', StepIdentifierFromPath(StepPath));
                    AddJSONNumber(ResultProps, 'local_x_mm', LocalXMM);
                    AddJSONNumber(ResultProps, 'local_y_mm', LocalYMM);
                    AddJSONNumber(ResultProps, 'model_rot_x_deg', RotX);
                    AddJSONNumber(ResultProps, 'model_rot_y_deg', RotY);
                    AddJSONNumber(ResultProps, 'model_rot_z_deg', RotZ);
                    AddJSONNumber(ResultProps, 'model_z_mm', ModelZMM);
                    AddJSONNumber(ResultProps, 'standoff_height_mm', StandoffMM);
                    AddJSONNumber(ResultProps, 'overall_height_mm', OverallHeightMM);
                end;
            finally
                PCBServer.PostProcess;
            end;
        end;

        Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);
        if Board <> Nil then
            Board.ViewManager_FullUpdate;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
    end;
end;

function Import3DBodiesFromBatchFile(DataFileName: String; SkipExisting: Boolean): String;
var
    PcbLib              : IPCB_Library;
    Board               : IPCB_Board;
    Lines               : TStringList;
    Fields              : TStringList;
    ResultProps         : TStringList;
    ImportedBodies      : TStringList;
    SkippedBodies       : TStringList;
    ErrorArray          : TStringList;
    OutputLines         : TStringList;
    LineText            : String;
    CommandName         : String;
    FootprintName       : String;
    StepPath            : String;
    Footprint           : IPCB_LibComponent;
    BodyError           : String;
    LocalXMM            : Double;
    LocalYMM            : Double;
    RotX                : Double;
    RotY                : Double;
    RotZ                : Double;
    ModelZMM            : Double;
    StandoffMM          : Double;
    OverallHeightMM     : Double;
    ExistingBodies      : Integer;
    i                   : Integer;
    RecordsSeen         : Integer;
    BodiesImported      : Integer;
    BodiesSkipped       : Integer;
    FootprintsMissing   : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    if not FileExists(DataFileName) then
    begin
        Result := '{"success": false, "error": "3D body batch import file not found."}';
        Exit;
    end;

    Board := PcbLib.Board;
    if Board = Nil then
    begin
        Result := '{"success": false, "error": "PcbLib board is nil."}';
        Exit;
    end;

    EnsureMechanicalLayerEnabled(Board, 1);

    Lines := TStringList.Create;
    Fields := TStringList.Create;
    ResultProps := TStringList.Create;
    ImportedBodies := TStringList.Create;
    SkippedBodies := TStringList.Create;
    ErrorArray := TStringList.Create;
    OutputLines := TStringList.Create;
    RecordsSeen := 0;
    BodiesImported := 0;
    BodiesSkipped := 0;
    FootprintsMissing := 0;

    try
        Fields.Delimiter := '|';
        Fields.StrictDelimiter := True;
        Lines.LoadFromFile(DataFileName);

        Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);

        PCBServer.PreProcess;
        try
            for i := 0 to Lines.Count - 1 do
            begin
                LineText := Trim(Lines[i]);
                if LineText = '' then
                    continue;
                if Copy(LineText, 1, 1) = '#' then
                    continue;

                Fields.Clear;
                Fields.DelimitedText := LineText;
                if Fields.Count = 0 then
                    continue;

                CommandName := UpperCase(Trim(Fields[0]));
                if CommandName <> 'BODY' then
                begin
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': expected BODY record.') + '"');
                    continue;
                end;

                if Fields.Count < 11 then
                begin
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': BODY requires footprint, STEP path, local X/Y, rotations, model Z, standoff, and overall height.') + '"');
                    continue;
                end;

                RecordsSeen := RecordsSeen + 1;
                FootprintName := Trim(Fields[1]);
                StepPath := Trim(Fields[2]);
                LocalXMM := SafeStrToFloat(Trim(Fields[3]));
                LocalYMM := SafeStrToFloat(Trim(Fields[4]));
                RotX := SafeStrToFloat(Trim(Fields[5]));
                RotY := SafeStrToFloat(Trim(Fields[6]));
                RotZ := SafeStrToFloat(Trim(Fields[7]));
                ModelZMM := SafeStrToFloat(Trim(Fields[8]));
                StandoffMM := SafeStrToFloat(Trim(Fields[9]));
                OverallHeightMM := SafeStrToFloat(Trim(Fields[10]));

                Footprint := FindLibFootprint(PcbLib, FootprintName);
                if Footprint = Nil then
                begin
                    FootprintsMissing := FootprintsMissing + 1;
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': footprint not found: ' + FootprintName) + '"');
                    continue;
                end;

                if not FileExists(StepPath) then
                begin
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': STEP file not found: ' + StepPath) + '"');
                    continue;
                end;

                PcbLib.CurrentComponent := Footprint;
                Footprint := PcbLib.CurrentComponent;
                ExistingBodies := Count3DBodiesForFootprint(Footprint);
                if ExistingBodies > 0 then
                begin
                    if SkipExisting then
                    begin
                        BodiesSkipped := BodiesSkipped + 1;
                        SkippedBodies.Add('"' + JSONEscapeString(FootprintName) + '"');
                    end
                    else
                    begin
                        ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': footprint already has a 3D body: ' + FootprintName) + '"');
                    end;
                    continue;
                end;

                if not AddStepBodyToActiveComponentWithPlacement(PcbLib, Footprint, StepPath, LocalXMM, LocalYMM, RotX, RotY, RotZ, ModelZMM, StandoffMM, OverallHeightMM, BodyError) then
                begin
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': ' + BodyError) + '"');
                    continue;
                end;

                BodiesImported := BodiesImported + 1;
                ImportedBodies.Add('"' + JSONEscapeString(FootprintName) + '"');
            end;
        finally
            PCBServer.PostProcess;
        end;

        Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);
        Board.ViewManager_FullUpdate;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        AddJSONBoolean(ResultProps, 'success', ErrorArray.Count = 0);
        AddJSONProperty(ResultProps, 'data_file', DataFileName);
        AddJSONBoolean(ResultProps, 'skip_existing', SkipExisting);
        AddJSONInteger(ResultProps, 'records_seen', RecordsSeen);
        AddJSONInteger(ResultProps, 'bodies_imported', BodiesImported);
        AddJSONInteger(ResultProps, 'bodies_skipped', BodiesSkipped);
        AddJSONInteger(ResultProps, 'footprints_missing', FootprintsMissing);
        ResultProps.Add(BuildJSONArray(ImportedBodies, 'imported_footprints'));
        ResultProps.Add(BuildJSONArray(SkippedBodies, 'skipped_footprints'));
        ResultProps.Add(BuildJSONArray(ErrorArray, 'errors'));

        OutputLines.Text := BuildJSONObject(ResultProps);
        Result := OutputLines.Text;
    finally
        OutputLines.Free;
        ErrorArray.Free;
        SkippedBodies.Free;
        ImportedBodies.Free;
        ResultProps.Free;
        Fields.Free;
        Lines.Free;
    end;
end;

function Set3DBodyHeightsForFootprint(PcbLib: IPCB_Library; Footprint: IPCB_LibComponent; StandoffMM, OverallHeightMM: Double): Integer;
var
    BodyIterator : IPCB_GroupIterator;
    Primitive    : IPCB_Primitive;
    Body         : IPCB_ComponentBody;
begin
    Result := 0;
    if (PcbLib = Nil) or (Footprint = Nil) then
        Exit;

    PcbLib.CurrentComponent := Footprint;
    Footprint := PcbLib.CurrentComponent;
    if Footprint = Nil then
        Exit;

    BodyIterator := Footprint.GroupIterator_Create;
    if BodyIterator = Nil then
        Exit;

    try
        BodyIterator.AddFilter_ObjectSet(MkSet(eComponentBodyObject));
        BodyIterator.AddFilter_LayerSet(AllLayers);

        Primitive := BodyIterator.FirstPCBObject;
        while Primitive <> Nil do
        begin
            Body := Primitive;
            PCBServer.SendMessageToRobots(Body.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
            Body.StandoffHeight := MMsToCoord(StandoffMM);
            Body.OverallHeight := MMsToCoord(OverallHeightMM);
            PCBServer.SendMessageToRobots(Body.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
            Result := Result + 1;
            Primitive := BodyIterator.NextPCBObject;
        end;
    finally
        Footprint.GroupIterator_Destroy(BodyIterator);
    end;
end;

function SetPCBLibrary3DBodyHeights(FootprintName: String; StandoffMM, OverallHeightMM: Double): String;
var
    PcbLib              : IPCB_Library;
    Board               : IPCB_Board;
    FootprintIterator   : IPCB_LibraryIterator;
    Footprint           : IPCB_LibComponent;
    TargetFootprint     : IPCB_LibComponent;
    FootprintsProcessed : Integer;
    BodiesModified      : Integer;
    ResultProps         : TStringList;
    OutputLines         : TStringList;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    ResultProps := TStringList.Create;
    OutputLines := TStringList.Create;
    Board := PcbLib.Board;
    FootprintsProcessed := 0;
    BodiesModified := 0;

    try
        PCBServer.PreProcess;
        try
            if FootprintName = '*' then
            begin
                FootprintIterator := PcbLib.LibraryIterator_Create;
                if FootprintIterator <> Nil then
                begin
                    try
                        FootprintIterator.SetState_FilterAll;
                        Footprint := FootprintIterator.FirstPCBObject;
                        while Footprint <> Nil do
                        begin
                            FootprintsProcessed := FootprintsProcessed + 1;
                            BodiesModified := BodiesModified + Set3DBodyHeightsForFootprint(PcbLib, Footprint, StandoffMM, OverallHeightMM);
                            Footprint := FootprintIterator.NextPCBObject;
                        end;
                    finally
                        PcbLib.LibraryIterator_Destroy(FootprintIterator);
                    end;
                end;
            end
            else
            begin
                TargetFootprint := FindLibFootprint(PcbLib, FootprintName);
                if TargetFootprint <> Nil then
                begin
                    FootprintsProcessed := 1;
                    BodiesModified := Set3DBodyHeightsForFootprint(PcbLib, TargetFootprint, StandoffMM, OverallHeightMM);
                end;
            end;
        finally
            PCBServer.PostProcess;
        end;

        AddJSONBoolean(ResultProps, 'success', BodiesModified > 0);
        AddJSONProperty(ResultProps, 'footprint', FootprintName);
        AddJSONInteger(ResultProps, 'footprints_processed', FootprintsProcessed);
        AddJSONInteger(ResultProps, 'bodies_modified', BodiesModified);
        AddJSONNumber(ResultProps, 'standoff_height_mm', StandoffMM);
        AddJSONNumber(ResultProps, 'overall_height_mm', OverallHeightMM);
        if BodiesModified = 0 then
            AddJSONProperty(ResultProps, 'error', 'No matching 3D bodies were found.');

        if Board <> Nil then
            Board.ViewManager_FullUpdate;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        OutputLines.Text := BuildJSONObject(ResultProps);
        Result := OutputLines.Text;
    finally
        OutputLines.Free;
        ResultProps.Free;
    end;
end;

function Set3DBodyIdentifierForFootprint(PcbLib: IPCB_Library; Footprint: IPCB_LibComponent; IdentifierText: String; FootprintResults: TStringList): Integer;
var
    BodyIterator : IPCB_GroupIterator;
    Primitive    : IPCB_Primitive;
    Body         : IPCB_ComponentBody;
    Props        : TStringList;
    FootprintName: String;
    BodiesSeen   : Integer;
    BodiesUpdated: Integer;
    OldIdentifier: String;
begin
    Result := 0;
    if (PcbLib = Nil) or (Footprint = Nil) or (Trim(IdentifierText) = '') then
        Exit;

    FootprintName := Footprint.Name;
    PcbLib.CurrentComponent := Footprint;
    Footprint := PcbLib.CurrentComponent;
    if Footprint = Nil then
        Exit;

    BodiesSeen := 0;
    BodiesUpdated := 0;
    BodyIterator := Footprint.GroupIterator_Create;
    if BodyIterator = Nil then
        Exit;

    try
        BodyIterator.AddFilter_ObjectSet(MkSet(eComponentBodyObject));
        BodyIterator.AddFilter_LayerSet(AllLayers);

        Primitive := BodyIterator.FirstPCBObject;
        while Primitive <> Nil do
        begin
            BodiesSeen := BodiesSeen + 1;
            Body := Primitive;
            OldIdentifier := Primitive.Identifier;
            if OldIdentifier <> IdentifierText then
            begin
                PCBServer.SendMessageToRobots(Body.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
                try
                    Body.SetState_Identifier(IdentifierText);
                    Primitive.GraphicallyInvalidate;
                finally
                    PCBServer.SendMessageToRobots(Body.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
                end;
                BodiesUpdated := BodiesUpdated + 1;
            end;

            Primitive := BodyIterator.NextPCBObject;
        end;
    finally
        Footprint.GroupIterator_Destroy(BodyIterator);
    end;

    if FootprintResults <> Nil then
    begin
        Props := TStringList.Create;
        try
            AddJSONProperty(Props, 'footprint', FootprintName);
            AddJSONProperty(Props, 'identifier', IdentifierText);
            AddJSONInteger(Props, 'bodies_seen', BodiesSeen);
            AddJSONInteger(Props, 'bodies_updated', BodiesUpdated);
            FootprintResults.Add(BuildJSONObject(Props, 1));
        finally
            Props.Free;
        end;
    end;

    Result := BodiesUpdated;
end;

function SetPCBLibrary3DBodyIdentifier(FootprintName, IdentifierText: String): String;
var
    PcbLib          : IPCB_Library;
    Board           : IPCB_Board;
    TargetFootprint : IPCB_LibComponent;
    ResultProps     : TStringList;
    FootprintResults: TStringList;
    OutputLines     : TStringList;
    BodiesModified  : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    TargetFootprint := FindLibFootprint(PcbLib, FootprintName);
    if TargetFootprint = Nil then
    begin
        Result := '{"success": false, "error": "Footprint not found."}';
        Exit;
    end;

    ResultProps := TStringList.Create;
    FootprintResults := TStringList.Create;
    OutputLines := TStringList.Create;
    Board := PcbLib.Board;
    BodiesModified := 0;

    try
        PCBServer.PreProcess;
        try
            BodiesModified := Set3DBodyIdentifierForFootprint(PcbLib, TargetFootprint, IdentifierText, FootprintResults);
        finally
            PCBServer.PostProcess;
        end;

        if Board <> Nil then
            Board.ViewManager_FullUpdate;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'footprint', FootprintName);
        AddJSONProperty(ResultProps, 'identifier', IdentifierText);
        AddJSONInteger(ResultProps, 'bodies_modified', BodiesModified);
        ResultProps.Add(BuildJSONArray(FootprintResults, 'footprint_results'));
        if BodiesModified = 0 then
            AddJSONProperty(ResultProps, 'message', 'No matching 3D bodies needed an Identifier update.');

        OutputLines.Text := BuildJSONObject(ResultProps);
        Result := OutputLines.Text;
    finally
        OutputLines.Free;
        FootprintResults.Free;
        ResultProps.Free;
    end;
end;

function Set3DBodyPlacementForFootprint(PcbLib: IPCB_Library; Board: IPCB_Board; Footprint: IPCB_LibComponent; LocalXMM, LocalYMM, RotX, RotY, RotZ, ModelZMM, StandoffMM, OverallHeightMM: Double; FootprintResults: TStringList): Integer;
var
    BodyIterator : IPCB_GroupIterator;
    Primitive    : IPCB_Primitive;
    Body         : IPCB_ComponentBody;
    Model        : IPCB_Model;
    Props        : TStringList;
    FootprintName: String;
    BodiesSeen   : Integer;
    BodiesUpdated: Integer;
    OldRotX      : Double;
    OldRotY      : Double;
    OldRotZ      : Double;
    OldModelZ    : TCoord;
    TargetCenterX : TCoord;
    TargetCenterY : TCoord;
begin
    Result := 0;
    if (PcbLib = Nil) or (Board = Nil) or (Footprint = Nil) then
        Exit;

    FootprintName := Footprint.Name;
    PcbLib.CurrentComponent := Footprint;
    Footprint := PcbLib.CurrentComponent;
    if Footprint = Nil then
        Exit;

    BodiesSeen := 0;
    BodiesUpdated := 0;

    BodyIterator := Footprint.GroupIterator_Create;
    if BodyIterator = Nil then
        Exit;

    try
        BodyIterator.AddFilter_ObjectSet(MkSet(eComponentBodyObject));
        BodyIterator.AddFilter_LayerSet(AllLayers);

        Primitive := BodyIterator.FirstPCBObject;
        while Primitive <> Nil do
        begin
            BodiesSeen := BodiesSeen + 1;
            Body := Primitive;
            Model := Body.GetModel;

            if Model <> Nil then
            begin
                PCBServer.SendMessageToRobots(Primitive.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
                try
                    OldRotX := 0;
                    OldRotY := 0;
                    OldRotZ := 0;
                    OldModelZ := 0;
                    Model.GetState(OldRotX, OldRotY, OldRotZ, OldModelZ);
                    Model.SetState(RotX, RotY, RotZ, MMsToCoord(ModelZMM));
                    Body.SetModel(Model);
                    Body.SetState_FromModel;
                    Model := Body.GetModel;
                    if Model <> Nil then
                    begin
                        Model.SetState(RotX, RotY, RotZ, MMsToCoord(ModelZMM));
                        Body.SetModel(Model);
                    end;
                    TargetCenterX := Board.XOrigin + MMsToCoord(LocalXMM);
                    TargetCenterY := Board.YOrigin + MMsToCoord(LocalYMM);
                    Body.SetState_SnapPointX(TargetCenterX);
                    Body.SetState_SnapPointY(TargetCenterY);
                    Body.StandoffHeight := MMsToCoord(StandoffMM);
                    Body.OverallHeight := MMsToCoord(OverallHeightMM);
                    Primitive.GraphicallyInvalidate;
                    BodiesUpdated := BodiesUpdated + 1;
                finally
                    PCBServer.SendMessageToRobots(Primitive.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
                end;
            end;

            Primitive := BodyIterator.NextPCBObject;
        end;
    finally
        Footprint.GroupIterator_Destroy(BodyIterator);
    end;

    if FootprintResults <> Nil then
    begin
        Props := TStringList.Create;
        try
            AddJSONProperty(Props, 'footprint', FootprintName);
            AddJSONInteger(Props, 'bodies_seen', BodiesSeen);
            AddJSONInteger(Props, 'bodies_updated', BodiesUpdated);
            AddJSONNumber(Props, 'local_x_mm', LocalXMM);
            AddJSONNumber(Props, 'local_y_mm', LocalYMM);
            AddJSONNumber(Props, 'rotation_x_deg', RotX);
            AddJSONNumber(Props, 'rotation_y_deg', RotY);
            AddJSONNumber(Props, 'rotation_z_deg', RotZ);
            AddJSONNumber(Props, 'model_z_mm', ModelZMM);
            AddJSONNumber(Props, 'standoff_height_mm', StandoffMM);
            AddJSONNumber(Props, 'overall_height_mm', OverallHeightMM);
            FootprintResults.Add(BuildJSONObject(Props, 1));
        finally
            Props.Free;
        end;
    end;

    Result := BodiesUpdated;
end;

function SetPCBLibrary3DBodyPlacement(FootprintName: String; LocalXMM, LocalYMM, RotX, RotY, RotZ, ModelZMM, StandoffMM, OverallHeightMM: Double): String;
var
    PcbLib              : IPCB_Library;
    Board               : IPCB_Board;
    FootprintIterator   : IPCB_LibraryIterator;
    Footprint           : IPCB_LibComponent;
    ResultProps         : TStringList;
    FootprintResults    : TStringList;
    OutputLines         : TStringList;
    TargetFootprint     : IPCB_LibComponent;
    FootprintsProcessed : Integer;
    BodiesUpdated       : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    Board := PcbLib.Board;
    if Board = Nil then
    begin
        Result := '{"success": false, "error": "No PcbLib board is available."}';
        Exit;
    end;

    ResultProps := TStringList.Create;
    FootprintResults := TStringList.Create;
    OutputLines := TStringList.Create;
    FootprintsProcessed := 0;
    BodiesUpdated := 0;

    try
        PCBServer.PreProcess;
        try
            if FootprintName = '*' then
            begin
                FootprintIterator := PcbLib.LibraryIterator_Create;
                if FootprintIterator <> Nil then
                begin
                    try
                        FootprintIterator.SetState_FilterAll;
                        Footprint := FootprintIterator.FirstPCBObject;
                        while Footprint <> Nil do
                        begin
                            FootprintsProcessed := FootprintsProcessed + 1;
                            BodiesUpdated := BodiesUpdated + Set3DBodyPlacementForFootprint(
                                PcbLib,
                                Board,
                                Footprint,
                                LocalXMM,
                                LocalYMM,
                                RotX,
                                RotY,
                                RotZ,
                                ModelZMM,
                                StandoffMM,
                                OverallHeightMM,
                                FootprintResults
                            );
                            Footprint := FootprintIterator.NextPCBObject;
                        end;
                    finally
                        PcbLib.LibraryIterator_Destroy(FootprintIterator);
                    end;
                end;
            end
            else
            begin
                TargetFootprint := FindLibFootprint(PcbLib, FootprintName);
                if TargetFootprint <> Nil then
                begin
                    FootprintsProcessed := 1;
                    BodiesUpdated := Set3DBodyPlacementForFootprint(
                        PcbLib,
                        Board,
                        TargetFootprint,
                        LocalXMM,
                        LocalYMM,
                        RotX,
                        RotY,
                        RotZ,
                        ModelZMM,
                        StandoffMM,
                        OverallHeightMM,
                        FootprintResults
                    );
                end;
            end;
        finally
            PCBServer.PostProcess;
        end;

        AddJSONBoolean(ResultProps, 'success', BodiesUpdated > 0);
        AddJSONProperty(ResultProps, 'footprint', FootprintName);
        AddJSONInteger(ResultProps, 'footprints_processed', FootprintsProcessed);
        AddJSONInteger(ResultProps, 'bodies_updated', BodiesUpdated);
        AddJSONNumber(ResultProps, 'local_x_mm', LocalXMM);
        AddJSONNumber(ResultProps, 'local_y_mm', LocalYMM);
        AddJSONNumber(ResultProps, 'rotation_x_deg', RotX);
        AddJSONNumber(ResultProps, 'rotation_y_deg', RotY);
        AddJSONNumber(ResultProps, 'rotation_z_deg', RotZ);
        AddJSONNumber(ResultProps, 'model_z_mm', ModelZMM);
        AddJSONNumber(ResultProps, 'standoff_height_mm', StandoffMM);
        AddJSONNumber(ResultProps, 'overall_height_mm', OverallHeightMM);
        ResultProps.Add(BuildJSONArray(FootprintResults, 'footprint_results'));
        if BodiesUpdated = 0 then
            AddJSONProperty(ResultProps, 'error', 'No matching 3D bodies with Generic model state were found.');

        Board.ViewManager_FullUpdate;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        OutputLines.Text := BuildJSONObject(ResultProps);
        Result := OutputLines.Text;
    finally
        OutputLines.Free;
        FootprintResults.Free;
        ResultProps.Free;
    end;
end;

function SetPCBLibrary3DBodyPlacementsFromBatchFile(DataFileName: String): String;
var
    PcbLib              : IPCB_Library;
    Board               : IPCB_Board;
    Lines               : TStringList;
    Fields              : TStringList;
    ResultProps         : TStringList;
    FootprintResults    : TStringList;
    UpdatedFootprints   : TStringList;
    ErrorArray          : TStringList;
    OutputLines         : TStringList;
    LineText            : String;
    CommandName         : String;
    FootprintName       : String;
    Footprint           : IPCB_LibComponent;
    LocalXMM            : Double;
    LocalYMM            : Double;
    RotX                : Double;
    RotY                : Double;
    RotZ                : Double;
    ModelZMM            : Double;
    StandoffMM          : Double;
    OverallHeightMM     : Double;
    UpdatedCount        : Integer;
    RecordsSeen         : Integer;
    BodiesUpdated       : Integer;
    FootprintsMissing   : Integer;
    i                   : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    if not FileExists(DataFileName) then
    begin
        Result := '{"success": false, "error": "3D body placement batch file not found."}';
        Exit;
    end;

    Board := PcbLib.Board;
    if Board = Nil then
    begin
        Result := '{"success": false, "error": "PcbLib board is nil."}';
        Exit;
    end;

    Lines := TStringList.Create;
    Fields := TStringList.Create;
    ResultProps := TStringList.Create;
    FootprintResults := TStringList.Create;
    UpdatedFootprints := TStringList.Create;
    ErrorArray := TStringList.Create;
    OutputLines := TStringList.Create;
    RecordsSeen := 0;
    BodiesUpdated := 0;
    FootprintsMissing := 0;

    try
        Fields.Delimiter := '|';
        Fields.StrictDelimiter := True;
        Lines.LoadFromFile(DataFileName);

        PCBServer.PreProcess;
        try
            for i := 0 to Lines.Count - 1 do
            begin
                LineText := Trim(Lines[i]);
                if LineText = '' then
                    continue;
                if Copy(LineText, 1, 1) = '#' then
                    continue;

                Fields.Clear;
                Fields.DelimitedText := LineText;
                if Fields.Count = 0 then
                    continue;

                CommandName := UpperCase(Trim(Fields[0]));
                if CommandName <> 'PLACE' then
                begin
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': expected PLACE record.') + '"');
                    continue;
                end;

                if Fields.Count < 10 then
                begin
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': PLACE requires footprint, local X/Y, rotations, model Z, standoff, and overall height.') + '"');
                    continue;
                end;

                RecordsSeen := RecordsSeen + 1;
                FootprintName := Trim(Fields[1]);
                LocalXMM := SafeStrToFloat(Trim(Fields[2]));
                LocalYMM := SafeStrToFloat(Trim(Fields[3]));
                RotX := SafeStrToFloat(Trim(Fields[4]));
                RotY := SafeStrToFloat(Trim(Fields[5]));
                RotZ := SafeStrToFloat(Trim(Fields[6]));
                ModelZMM := SafeStrToFloat(Trim(Fields[7]));
                StandoffMM := SafeStrToFloat(Trim(Fields[8]));
                OverallHeightMM := SafeStrToFloat(Trim(Fields[9]));

                Footprint := FindLibFootprint(PcbLib, FootprintName);
                if Footprint = Nil then
                begin
                    FootprintsMissing := FootprintsMissing + 1;
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': footprint not found: ' + FootprintName) + '"');
                    continue;
                end;

                UpdatedCount := Set3DBodyPlacementForFootprint(
                    PcbLib,
                    Board,
                    Footprint,
                    LocalXMM,
                    LocalYMM,
                    RotX,
                    RotY,
                    RotZ,
                    ModelZMM,
                    StandoffMM,
                    OverallHeightMM,
                    FootprintResults
                );
                BodiesUpdated := BodiesUpdated + UpdatedCount;
                if UpdatedCount > 0 then
                    UpdatedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"')
                else
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': no matching 3D body with Generic model state: ' + FootprintName) + '"');
            end;
        finally
            PCBServer.PostProcess;
        end;

        Board.ViewManager_FullUpdate;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        AddJSONBoolean(ResultProps, 'success', ErrorArray.Count = 0);
        AddJSONProperty(ResultProps, 'data_file', DataFileName);
        AddJSONInteger(ResultProps, 'records_seen', RecordsSeen);
        AddJSONInteger(ResultProps, 'bodies_updated', BodiesUpdated);
        AddJSONInteger(ResultProps, 'footprints_missing', FootprintsMissing);
        ResultProps.Add(BuildJSONArray(UpdatedFootprints, 'updated_footprints'));
        ResultProps.Add(BuildJSONArray(FootprintResults, 'footprint_results'));
        ResultProps.Add(BuildJSONArray(ErrorArray, 'errors'));

        OutputLines.Text := BuildJSONObject(ResultProps);
        Result := OutputLines.Text;
    finally
        OutputLines.Free;
        ErrorArray.Free;
        UpdatedFootprints.Free;
        FootprintResults.Free;
        ResultProps.Free;
        Fields.Free;
        Lines.Free;
    end;
end;

function SetPCBLibrary3DBodyIdentifiersFromBatchFile(DataFileName: String): String;
var
    PcbLib              : IPCB_Library;
    Board               : IPCB_Board;
    Lines               : TStringList;
    Fields              : TStringList;
    ResultProps         : TStringList;
    FootprintResults    : TStringList;
    UpdatedFootprints   : TStringList;
    ErrorArray          : TStringList;
    OutputLines         : TStringList;
    LineText            : String;
    CommandName         : String;
    FootprintName       : String;
    IdentifierText      : String;
    Footprint           : IPCB_LibComponent;
    UpdatedCount        : Integer;
    RecordsSeen         : Integer;
    BodiesUpdated       : Integer;
    FootprintsMissing   : Integer;
    i                   : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    if not FileExists(DataFileName) then
    begin
        Result := '{"success": false, "error": "3D body Identifier batch file not found."}';
        Exit;
    end;

    Board := PcbLib.Board;
    if Board = Nil then
    begin
        Result := '{"success": false, "error": "PcbLib board is nil."}';
        Exit;
    end;

    Lines := TStringList.Create;
    Fields := TStringList.Create;
    ResultProps := TStringList.Create;
    FootprintResults := TStringList.Create;
    UpdatedFootprints := TStringList.Create;
    ErrorArray := TStringList.Create;
    OutputLines := TStringList.Create;
    RecordsSeen := 0;
    BodiesUpdated := 0;
    FootprintsMissing := 0;

    try
        Fields.Delimiter := '|';
        Fields.StrictDelimiter := True;
        Lines.LoadFromFile(DataFileName);

        PCBServer.PreProcess;
        try
            for i := 0 to Lines.Count - 1 do
            begin
                LineText := Trim(Lines[i]);
                if LineText = '' then
                    continue;
                if Copy(LineText, 1, 1) = '#' then
                    continue;

                Fields.Clear;
                Fields.DelimitedText := LineText;
                if Fields.Count = 0 then
                    continue;

                CommandName := UpperCase(Trim(Fields[0]));
                if CommandName <> 'IDENTIFIER' then
                begin
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': expected IDENTIFIER record.') + '"');
                    continue;
                end;

                if Fields.Count < 3 then
                begin
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': IDENTIFIER requires footprint and identifier text.') + '"');
                    continue;
                end;

                RecordsSeen := RecordsSeen + 1;
                FootprintName := Trim(Fields[1]);
                IdentifierText := Trim(Fields[2]);
                if (FootprintName = '') or (IdentifierText = '') then
                begin
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': empty footprint or identifier.') + '"');
                    continue;
                end;

                Footprint := FindLibFootprint(PcbLib, FootprintName);
                if Footprint = Nil then
                begin
                    FootprintsMissing := FootprintsMissing + 1;
                    ErrorArray.Add('"' + JSONEscapeString('Line ' + IntToStr(i + 1) + ': footprint not found: ' + FootprintName) + '"');
                    continue;
                end;

                UpdatedCount := Set3DBodyIdentifierForFootprint(PcbLib, Footprint, IdentifierText, FootprintResults);
                BodiesUpdated := BodiesUpdated + UpdatedCount;
                if UpdatedCount > 0 then
                    UpdatedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
            end;
        finally
            PCBServer.PostProcess;
        end;

        Board.ViewManager_FullUpdate;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        AddJSONBoolean(ResultProps, 'success', ErrorArray.Count = 0);
        AddJSONProperty(ResultProps, 'data_file', DataFileName);
        AddJSONInteger(ResultProps, 'records_seen', RecordsSeen);
        AddJSONInteger(ResultProps, 'bodies_updated', BodiesUpdated);
        AddJSONInteger(ResultProps, 'footprints_modified', UpdatedFootprints.Count);
        AddJSONInteger(ResultProps, 'footprints_missing', FootprintsMissing);
        ResultProps.Add(BuildJSONArray(UpdatedFootprints, 'updated_footprints'));
        ResultProps.Add(BuildJSONArray(FootprintResults, 'footprint_results'));
        ResultProps.Add(BuildJSONArray(ErrorArray, 'errors'));

        OutputLines.Text := BuildJSONObject(ResultProps);
        Result := OutputLines.Text;
    finally
        OutputLines.Free;
        ErrorArray.Free;
        UpdatedFootprints.Free;
        FootprintResults.Free;
        ResultProps.Free;
        Fields.Free;
        Lines.Free;
    end;
end;

function Fix3DBodyOriginOffsetForFootprint(PcbLib: IPCB_Library; Board: IPCB_Board; Footprint: IPCB_LibComponent; Threshold: TCoord; FootprintResults: TStringList; var BodiesSkipped: Integer): Integer;
var
    BodyIterator   : IPCB_GroupIterator;
    Primitive      : IPCB_Primitive;
    Rect           : TCoordRect;
    Props          : TStringList;
    FootprintName  : String;
    BodiesSeen     : Integer;
    BodiesMoved    : Integer;
    BodiesSkippedHere : Integer;
    ShouldMove     : Boolean;
begin
    Result := 0;
    if (PcbLib = Nil) or (Board = Nil) or (Footprint = Nil) then
        Exit;

    FootprintName := Footprint.Name;
    PcbLib.CurrentComponent := Footprint;
    Footprint := PcbLib.CurrentComponent;
    if Footprint = Nil then
        Exit;

    BodiesSeen := 0;
    BodiesMoved := 0;
    BodiesSkippedHere := 0;

    BodyIterator := Footprint.GroupIterator_Create;
    if BodyIterator = Nil then
        Exit;

    try
        BodyIterator.AddFilter_ObjectSet(MkSet(eComponentBodyObject));
        BodyIterator.AddFilter_LayerSet(AllLayers);

        Primitive := BodyIterator.FirstPCBObject;
        while Primitive <> Nil do
        begin
            BodiesSeen := BodiesSeen + 1;
            Rect := Primitive.BoundingRectangle;

            ShouldMove := (Abs(Rect.Left) < Threshold) and
                          (Abs(Rect.Right) < Threshold) and
                          (Abs(Rect.Bottom) < Threshold) and
                          (Abs(Rect.Top) < Threshold);

            if ShouldMove then
            begin
                PCBServer.SendMessageToRobots(Primitive.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
                Primitive.MoveByXY(Board.XOrigin, Board.YOrigin);
                PCBServer.SendMessageToRobots(Primitive.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
                BodiesMoved := BodiesMoved + 1;
            end
            else
                BodiesSkippedHere := BodiesSkippedHere + 1;

            Primitive := BodyIterator.NextPCBObject;
        end;
    finally
        Footprint.GroupIterator_Destroy(BodyIterator);
    end;

    if BodiesSeen > 0 then
    begin
        Props := TStringList.Create;
        try
            AddJSONProperty(Props, 'footprint', FootprintName);
            AddJSONInteger(Props, 'bodies_seen', BodiesSeen);
            AddJSONInteger(Props, 'bodies_moved', BodiesMoved);
            AddJSONInteger(Props, 'bodies_skipped', BodiesSkippedHere);
            FootprintResults.Add(BuildJSONObject(Props, 1));
        finally
            Props.Free;
        end;
    end;

    BodiesSkipped := BodiesSkipped + BodiesSkippedHere;
    Result := BodiesMoved;
end;

function FixPCBLibrary3DBodyOriginOffset(FootprintName: String): String;
var
    PcbLib              : IPCB_Library;
    Board               : IPCB_Board;
    FootprintIterator   : IPCB_LibraryIterator;
    Footprint           : IPCB_LibComponent;
    TargetFootprint     : IPCB_LibComponent;
    ResultProps         : TStringList;
    FootprintResults    : TStringList;
    OutputLines         : TStringList;
    Threshold           : TCoord;
    FootprintsProcessed : Integer;
    BodiesMoved         : Integer;
    BodiesSkipped       : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    Board := PcbLib.Board;
    if Board = Nil then
    begin
        Result := '{"success": false, "error": "PcbLib board is nil."}';
        Exit;
    end;

    ResultProps := TStringList.Create;
    FootprintResults := TStringList.Create;
    OutputLines := TStringList.Create;
    Threshold := MMsToCoord(100);
    FootprintsProcessed := 0;
    BodiesMoved := 0;
    BodiesSkipped := 0;

    try
        PCBServer.PreProcess;
        try
            if FootprintName = '*' then
            begin
                FootprintIterator := PcbLib.LibraryIterator_Create;
                if FootprintIterator <> Nil then
                begin
                    try
                        FootprintIterator.SetState_FilterAll;
                        Footprint := FootprintIterator.FirstPCBObject;
                        while Footprint <> Nil do
                        begin
                            FootprintsProcessed := FootprintsProcessed + 1;
                            BodiesMoved := BodiesMoved + Fix3DBodyOriginOffsetForFootprint(PcbLib, Board, Footprint, Threshold, FootprintResults, BodiesSkipped);
                            Footprint := FootprintIterator.NextPCBObject;
                        end;
                    finally
                        PcbLib.LibraryIterator_Destroy(FootprintIterator);
                    end;
                end;
            end
            else
            begin
                TargetFootprint := FindLibFootprint(PcbLib, FootprintName);
                if TargetFootprint <> Nil then
                begin
                    FootprintsProcessed := 1;
                    BodiesMoved := Fix3DBodyOriginOffsetForFootprint(PcbLib, Board, TargetFootprint, Threshold, FootprintResults, BodiesSkipped);
                end;
            end;
        finally
            PCBServer.PostProcess;
        end;

        AddJSONBoolean(ResultProps, 'success', (BodiesMoved > 0) or (BodiesSkipped > 0));
        AddJSONBoolean(ResultProps, 'mutated', BodiesMoved > 0);
        AddJSONProperty(ResultProps, 'footprint', FootprintName);
        AddJSONInteger(ResultProps, 'footprints_processed', FootprintsProcessed);
        AddJSONInteger(ResultProps, 'bodies_moved', BodiesMoved);
        AddJSONInteger(ResultProps, 'bodies_skipped', BodiesSkipped);
        AddJSONNumber(ResultProps, 'x_offset_mm', CoordToMMs(Board.XOrigin));
        AddJSONNumber(ResultProps, 'y_offset_mm', CoordToMMs(Board.YOrigin));
        AddJSONNumber(ResultProps, 'local_origin_threshold_mm', CoordToMMs(Threshold));
        ResultProps.Add(BuildJSONArray(FootprintResults, 'footprint_results'));
        if BodiesMoved = 0 then
            AddJSONProperty(ResultProps, 'message', 'No 3D bodies looked like unshifted local-origin bodies. Already shifted bodies were left untouched.');

        Board.ViewManager_FullUpdate;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        OutputLines.Text := BuildJSONObject(ResultProps);
        Result := OutputLines.Text;
    finally
        OutputLines.Free;
        FootprintResults.Free;
        ResultProps.Free;
    end;
end;

function Dump3DBodyParametersForFootprint(FootprintName: String): String;
var
    PcbLib          : IPCB_Library;
    Board           : IPCB_Board;
    Footprint       : IPCB_LibComponent;
    BodyIterator    : IPCB_GroupIterator;
    Primitive       : IPCB_Primitive;
    Body            : IPCB_ComponentBody;
    ResultProps     : TStringList;
    BodyArray       : TStringList;
    BodyProps       : TStringList;
    OutputLines     : TStringList;
    ParamText       : TPCBString;
    ParamSpace      : Integer;
    BodyIndex       : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    Footprint := FindLibFootprint(PcbLib, FootprintName);
    if Footprint = Nil then
    begin
        Result := '{"success": false, "error": "Footprint not found."}';
        Exit;
    end;

    Board := PcbLib.Board;
    PcbLib.CurrentComponent := Footprint;
    Footprint := PcbLib.CurrentComponent;
    if Board <> Nil then
        Board.ViewManager_FullUpdate;

    ResultProps := TStringList.Create;
    BodyArray := TStringList.Create;
    OutputLines := TStringList.Create;
    BodyIndex := 0;

    try
        BodyIterator := Footprint.GroupIterator_Create;
        if BodyIterator <> Nil then
        begin
            try
                BodyIterator.AddFilter_ObjectSet(MkSet(eComponentBodyObject));
                BodyIterator.AddFilter_LayerSet(AllLayers);

                Primitive := BodyIterator.FirstPCBObject;
                while Primitive <> Nil do
                begin
                    BodyIndex := BodyIndex + 1;
                    Body := Primitive;
                    BodyProps := TStringList.Create;
                    try
                        AddJSONInteger(BodyProps, 'index', BodyIndex);
                        AddJSONProperty(BodyProps, 'object_id', Primitive.ObjectIDString);
                        AddJSONProperty(BodyProps, 'identifier', Primitive.Identifier);
                        AddJSONProperty(BodyProps, 'descriptor', Primitive.Descriptor);
                        AddJSONProperty(BodyProps, 'detail', Primitive.Detail);
                        ParamSpace := Primitive.RequiredParamterSpace;
                        AddJSONInteger(BodyProps, 'required_parameter_space', ParamSpace);
                        if ParamSpace > 0 then
                        begin
                            ParamText := StringOfChar(' ', ParamSpace + 1);
                            Primitive.Export_ToParameters(ParamText);
                            AddJSONProperty(BodyProps, 'parameters', ParamText);
                        end
                        else
                            AddJSONProperty(BodyProps, 'parameters', '');

                        BodyArray.Add(BuildJSONObject(BodyProps, 1));
                    finally
                        BodyProps.Free;
                    end;

                    Primitive := BodyIterator.NextPCBObject;
                end;
            finally
                Footprint.GroupIterator_Destroy(BodyIterator);
            end;
        end;

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'footprint', FootprintName);
        AddJSONInteger(ResultProps, 'body_count', BodyIndex);
        ResultProps.Add(BuildJSONArray(BodyArray, 'bodies'));

        OutputLines.Text := BuildJSONObject(ResultProps);
        Result := OutputLines.Text;
    finally
        OutputLines.Free;
        BodyArray.Free;
        ResultProps.Free;
    end;
end;

function DumpPCBLibraryFootprintPrimitives(FootprintName: String): String;
var
    PcbLib            : IPCB_Library;
    Board             : IPCB_Board;
    Footprint         : IPCB_LibComponent;
    PrimitiveIterator : IPCB_GroupIterator;
    Primitive         : IPCB_Primitive;
    Pad               : IPCB_Pad;
    Track             : IPCB_Track;
    Arc               : IPCB_Arc;
    TextPrimitive     : IPCB_Text;
    Body              : IPCB_ComponentBody;
    Rect              : TCoordRect;
    ResultProps       : TStringList;
    PadsArray         : TStringList;
    TracksArray       : TStringList;
    ArcsArray         : TStringList;
    TextsArray        : TStringList;
    BodiesArray       : TStringList;
    Props             : TStringList;
    OutputLines       : TStringList;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    Board := PcbLib.Board;
    Footprint := FindLibFootprint(PcbLib, FootprintName);
    if Footprint = Nil then
    begin
        Result := '{"success": false, "error": "Footprint not found."}';
        Exit;
    end;

    PcbLib.CurrentComponent := Footprint;
    Footprint := PcbLib.CurrentComponent;
    if Board <> Nil then
        Board.ViewManager_FullUpdate;

    ResultProps := TStringList.Create;
    PadsArray := TStringList.Create;
    TracksArray := TStringList.Create;
    ArcsArray := TStringList.Create;
    TextsArray := TStringList.Create;
    BodiesArray := TStringList.Create;

    try
        PrimitiveIterator := Footprint.GroupIterator_Create;
        if PrimitiveIterator = Nil then
        begin
            Result := '{"success": false, "error": "Failed to create PCB library primitive iterator."}';
            Exit;
        end;

        try
            PrimitiveIterator.SetState_FilterAll;
            Primitive := PrimitiveIterator.FirstPCBObject;
            while Primitive <> Nil do
            begin
                if Primitive.ObjectId = ePadObject then
                begin
                    Pad := Primitive;
                    Props := TStringList.Create;
                    try
                        AddJSONProperty(Props, 'name', Pad.Name);
                        AddJSONProperty(Props, 'layer', Layer2String(Pad.Layer));
                        AddJSONNumber(Props, 'x_mm', CoordToMMs(PCBLibLocalX(Board, Pad.X)));
                        AddJSONNumber(Props, 'y_mm', CoordToMMs(PCBLibLocalY(Board, Pad.Y)));
                        AddJSONNumber(Props, 'top_x_size_mm', CoordToMMs(Pad.TopXSize));
                        AddJSONNumber(Props, 'top_y_size_mm', CoordToMMs(Pad.TopYSize));
                        AddJSONInteger(Props, 'top_shape', Pad.TopShape);
                        PadsArray.Add(BuildJSONObject(Props, 1));
                    finally
                        Props.Free;
                    end;
                end
                else if Primitive.ObjectId = eTrackObject then
                begin
                    Track := Primitive;
                    Props := TStringList.Create;
                    try
                        AddJSONProperty(Props, 'layer', Layer2String(Track.Layer));
                        AddJSONNumber(Props, 'x1_mm', CoordToMMs(PCBLibLocalX(Board, Track.X1)));
                        AddJSONNumber(Props, 'y1_mm', CoordToMMs(PCBLibLocalY(Board, Track.Y1)));
                        AddJSONNumber(Props, 'x2_mm', CoordToMMs(PCBLibLocalX(Board, Track.X2)));
                        AddJSONNumber(Props, 'y2_mm', CoordToMMs(PCBLibLocalY(Board, Track.Y2)));
                        AddJSONNumber(Props, 'width_mm', CoordToMMs(Track.Width));
                        TracksArray.Add(BuildJSONObject(Props, 1));
                    finally
                        Props.Free;
                    end;
                end
                else if Primitive.ObjectId = eArcObject then
                begin
                    Arc := Primitive;
                    Props := TStringList.Create;
                    try
                        AddJSONProperty(Props, 'layer', Layer2String(Arc.Layer));
                        AddJSONNumber(Props, 'center_x_mm', CoordToMMs(PCBLibLocalX(Board, Arc.XCenter)));
                        AddJSONNumber(Props, 'center_y_mm', CoordToMMs(PCBLibLocalY(Board, Arc.YCenter)));
                        AddJSONNumber(Props, 'radius_mm', CoordToMMs(Arc.Radius));
                        AddJSONNumber(Props, 'start_angle_deg', Arc.StartAngle);
                        AddJSONNumber(Props, 'end_angle_deg', Arc.EndAngle);
                        AddJSONNumber(Props, 'line_width_mm', CoordToMMs(Arc.LineWidth));
                        ArcsArray.Add(BuildJSONObject(Props, 1));
                    finally
                        Props.Free;
                    end;
                end
                else if Primitive.ObjectId = eTextObject then
                begin
                    TextPrimitive := Primitive;
                    Props := TStringList.Create;
                    try
                        AddJSONProperty(Props, 'text', TextPrimitive.Text);
                        AddJSONProperty(Props, 'layer', Layer2String(TextPrimitive.Layer));
                        AddJSONNumber(Props, 'x_mm', CoordToMMs(PCBLibLocalX(Board, TextPrimitive.XLocation)));
                        AddJSONNumber(Props, 'y_mm', CoordToMMs(PCBLibLocalY(Board, TextPrimitive.YLocation)));
                        AddJSONNumber(Props, 'size_mm', CoordToMMs(TextPrimitive.Size));
                        AddJSONNumber(Props, 'width_mm', CoordToMMs(TextPrimitive.Width));
                        AddJSONNumber(Props, 'rotation_deg', TextPrimitive.Rotation);
                        TextsArray.Add(BuildJSONObject(Props, 1));
                    finally
                        Props.Free;
                    end;
                end
                else if Primitive.ObjectId = eComponentBodyObject then
                begin
                    Body := Primitive;
                    Rect := Primitive.BoundingRectangle;
                    Props := TStringList.Create;
                    try
                        AddJSONProperty(Props, 'layer', Layer2String(Primitive.Layer));
                        AddJSONNumber(Props, 'left_mm', CoordToMMs(PCBLibLocalX(Board, Rect.Left)));
                        AddJSONNumber(Props, 'bottom_mm', CoordToMMs(PCBLibLocalY(Board, Rect.Bottom)));
                        AddJSONNumber(Props, 'right_mm', CoordToMMs(PCBLibLocalX(Board, Rect.Right)));
                        AddJSONNumber(Props, 'top_mm', CoordToMMs(PCBLibLocalY(Board, Rect.Top)));
                        AddJSONNumber(Props, 'standoff_height_mm', CoordToMMs(Body.StandoffHeight));
                        AddJSONNumber(Props, 'overall_height_mm', CoordToMMs(Body.OverallHeight));
                        AddJSONInteger(Props, 'body_projection', Body.BodyProjection);
                        BodiesArray.Add(BuildJSONObject(Props, 1));
                    finally
                        Props.Free;
                    end;
                end;

                Primitive := PrimitiveIterator.NextPCBObject;
            end;
        finally
            Footprint.GroupIterator_Destroy(PrimitiveIterator);
        end;

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'footprint', FootprintName);
        ResultProps.Add(BuildJSONArray(PadsArray, 'pads'));
        ResultProps.Add(BuildJSONArray(TracksArray, 'tracks'));
        ResultProps.Add(BuildJSONArray(ArcsArray, 'arcs'));
        ResultProps.Add(BuildJSONArray(TextsArray, 'texts'));
        ResultProps.Add(BuildJSONArray(BodiesArray, 'bodies'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
        PadsArray.Free;
        TracksArray.Free;
        ArcsArray.Free;
        TextsArray.Free;
        BodiesArray.Free;
    end;
end;

function DumpPCBLibraryProjectionTextPlacement(DestinationLayerNumber: Integer; FootprintName: String): String;
var
    PcbLib              : IPCB_Library;
    Board               : IPCB_Board;
    Footprint           : IPCB_LibComponent;
    DestinationLayer    : TLayer;
    ProjectionLineWidth : TCoord;
    TracksCount         : Integer;
    Left, Bottom, Right, Top: TCoord;
    LocalLeft, LocalBottom, LocalRight, LocalTop: TCoord;
    CenterX, CenterY    : TCoord;
    DesignatorLocalX    : TCoord;
    DesignatorLocalY    : TCoord;
    CommentLocalX       : TCoord;
    CommentLocalY       : TCoord;
    DesignatorAtCenter  : Boolean;
    PrimitiveIterator   : IPCB_GroupIterator;
    Primitive           : IPCB_Primitive;
    TextPrimitive       : IPCB_Text;
    TextLocalX          : TCoord;
    TextLocalY          : TCoord;
    ResultProps         : TStringList;
    TextArray           : TStringList;
    TextProps           : TStringList;
    GeneratedProps      : TStringList;
    OutputLines         : TStringList;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    if (DestinationLayerNumber < 1) or (DestinationLayerNumber > 32) then
    begin
        Result := '{"success": false, "error": "Mechanical layer number must be between 1 and 32."}';
        Exit;
    end;

    Board := PcbLib.Board;
    DestinationLayer := ILayer.MechanicalLayer(DestinationLayerNumber);
    ProjectionLineWidth := MMsToCoord(0.1);
    Footprint := FindLibFootprint(PcbLib, FootprintName);
    if Footprint = Nil then
    begin
        Result := '{"success": false, "error": "Footprint not found."}';
        Exit;
    end;

    PcbLib.CurrentComponent := Footprint;
    Footprint := PcbLib.CurrentComponent;

    ResultProps := TStringList.Create;
    TextArray := TStringList.Create;
    GeneratedProps := TStringList.Create;
    try
        TracksCount := MeasureProjectionTracks(Footprint, DestinationLayer, ProjectionLineWidth, Left, Bottom, Right, Top);
        LocalLeft := PCBLibLocalX(Board, Left);
        LocalRight := PCBLibLocalX(Board, Right);
        LocalBottom := PCBLibLocalY(Board, Bottom);
        LocalTop := PCBLibLocalY(Board, Top);
        CenterX := (LocalLeft + LocalRight) div 2;
        CenterY := (LocalBottom + LocalTop) div 2;

        ChooseProjectionTextLocations(
            Board,
            Footprint,
            DestinationLayer,
            ProjectionLineWidth,
            DesignatorLocalX,
            DesignatorLocalY,
            CommentLocalX,
            CommentLocalY,
            DesignatorAtCenter
        );

        PrimitiveIterator := Footprint.GroupIterator_Create;
        if PrimitiveIterator <> Nil then
        begin
            try
                PrimitiveIterator.AddFilter_ObjectSet(MkSet(eTextObject));
                PrimitiveIterator.AddFilter_LayerSet(MkSet(DestinationLayer));

                Primitive := PrimitiveIterator.FirstPCBObject;
                while Primitive <> Nil do
                begin
                    TextPrimitive := Primitive;
                    if IsProjectionText(TextPrimitive.Text) then
                    begin
                        TextLocalX := PCBLibLocalX(Board, TextPrimitive.XLocation);
                        TextLocalY := PCBLibLocalY(Board, TextPrimitive.YLocation);
                        TextProps := TStringList.Create;
                        try
                            AddJSONProperty(TextProps, 'text', TextPrimitive.Text);
                            AddJSONNumber(TextProps, 'x_mm', CoordToMMs(TextLocalX));
                            AddJSONNumber(TextProps, 'y_mm', CoordToMMs(TextLocalY));
                            AddJSONNumber(TextProps, 'x_from_center_mm', CoordToMMs(TextLocalX - CenterX));
                            AddJSONNumber(TextProps, 'y_from_bottom_mm', CoordToMMs(TextLocalY - LocalBottom));
                            AddJSONNumber(TextProps, 'y_from_top_mm', CoordToMMs(TextLocalY - LocalTop));
                            TextArray.Add(BuildJSONObject(TextProps, 1));
                        finally
                            TextProps.Free;
                        end;
                    end;
                    Primitive := PrimitiveIterator.NextPCBObject;
                end;
            finally
                Footprint.GroupIterator_Destroy(PrimitiveIterator);
            end;
        end;

        AddJSONNumber(GeneratedProps, 'designator_x_mm', CoordToMMs(DesignatorLocalX));
        AddJSONNumber(GeneratedProps, 'designator_y_mm', CoordToMMs(DesignatorLocalY));
        AddJSONNumber(GeneratedProps, 'comment_x_mm', CoordToMMs(CommentLocalX));
        AddJSONNumber(GeneratedProps, 'comment_y_mm', CoordToMMs(CommentLocalY));
        AddJSONBoolean(GeneratedProps, 'designator_at_center', DesignatorAtCenter);

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'footprint', FootprintName);
        AddJSONInteger(ResultProps, 'mechanical_layer', DestinationLayerNumber);
        AddJSONNumber(ResultProps, 'projection_line_width_mm', CoordToMMs(ProjectionLineWidth));
        AddJSONInteger(ResultProps, 'projection_track_count', TracksCount);
        AddJSONNumber(ResultProps, 'projection_left_mm', CoordToMMs(LocalLeft));
        AddJSONNumber(ResultProps, 'projection_bottom_mm', CoordToMMs(LocalBottom));
        AddJSONNumber(ResultProps, 'projection_right_mm', CoordToMMs(LocalRight));
        AddJSONNumber(ResultProps, 'projection_top_mm', CoordToMMs(LocalTop));
        AddJSONNumber(ResultProps, 'projection_center_x_mm', CoordToMMs(CenterX));
        AddJSONNumber(ResultProps, 'projection_center_y_mm', CoordToMMs(CenterY));
        ResultProps.Add(JSONPairStr('generated_positions', BuildJSONObject(GeneratedProps, 1), False));
        ResultProps.Add(BuildJSONArray(TextArray, 'current_texts'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
        TextArray.Free;
        GeneratedProps.Free;
    end;
end;

function CleanPCBLibraryProjectionTracksWithEditor(ExcludeFootprints: TStringList; DestinationLayerNumber: Integer; LineWidthMM: Double): String;
var
    PcbLib              : IPCB_Library;
    Board               : IPCB_Board;
    FootprintIterator   : IPCB_LibraryIterator;
    Footprint           : IPCB_LibComponent;
    DestinationLayer    : TLayer;
    LineWidth           : TCoord;
    FootprintNames      : TStringList;
    ResultProps         : TStringList;
    ModifiedFootprints  : TStringList;
    SkippedFootprints   : TStringList;
    OutputLines         : TStringList;
    FootprintName       : String;
    FootprintsSeen      : Integer;
    FootprintsProcessed : Integer;
    FootprintsModified  : Integer;
    TracksSelected      : Integer;
    FootprintTracksSelected : Integer;
    i                   : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    if (DestinationLayerNumber < 1) or (DestinationLayerNumber > 32) then
    begin
        Result := '{"success": false, "error": "Mechanical layer number must be between 1 and 32."}';
        Exit;
    end;

    if LineWidthMM <= 0 then
    begin
        Result := '{"success": false, "error": "Line width must be greater than zero."}';
        Exit;
    end;

    Board := PcbLib.Board;
    DestinationLayer := ILayer.MechanicalLayer(DestinationLayerNumber);
    LineWidth := MMsToCoord(LineWidthMM);
    FootprintNames := TStringList.Create;
    ResultProps := TStringList.Create;
    ModifiedFootprints := TStringList.Create;
    SkippedFootprints := TStringList.Create;
    FootprintsSeen := 0;
    FootprintsProcessed := 0;
    FootprintsModified := 0;
    TracksSelected := 0;

    try
        FootprintIterator := PcbLib.LibraryIterator_Create;
        if FootprintIterator = Nil then
        begin
            Result := '{"success": false, "error": "Failed to create PCB library footprint iterator."}';
            Exit;
        end;

        FootprintIterator.SetState_FilterAll;
        try
            Footprint := FootprintIterator.FirstPCBObject;
            while Footprint <> Nil do
            begin
                FootprintsSeen := FootprintsSeen + 1;
                FootprintName := Footprint.Name;

                if StringListContainsText(ExcludeFootprints, FootprintName) then
                begin
                    SkippedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                end
                else
                begin
                    FootprintsProcessed := FootprintsProcessed + 1;
                    FootprintNames.Add(FootprintName);
                end;

                Footprint := FootprintIterator.NextPCBObject;
            end;
        finally
            PcbLib.LibraryIterator_Destroy(FootprintIterator);
        end;

        for i := 0 to FootprintNames.Count - 1 do
        begin
            FootprintName := FootprintNames[i];
            Footprint := FindLibFootprint(PcbLib, FootprintName);
            if Footprint <> Nil then
            begin
                Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);
                PcbLib.CurrentComponent := Footprint;
                Footprint := PcbLib.CurrentComponent;
                if Board <> Nil then
                    Board.ViewManager_FullUpdate;

                if Footprint <> Nil then
                begin
                    FootprintTracksSelected := SelectProjectionTracks(Footprint, DestinationLayer, LineWidth);
                    if FootprintTracksSelected > 0 then
                    begin
                        TracksSelected := TracksSelected + FootprintTracksSelected;
                        Client.SendMessage('PCB:DeleteObjects', 'Object=FOCUSED', 255, Client.CurrentView);
                        FootprintsModified := FootprintsModified + 1;
                        ModifiedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                    end;
                end;
            end;
        end;

        Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);
        if Board <> Nil then
            Board.ViewManager_FullUpdate;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'cleanup_source', 'PCB editor DeleteObjects process');
        AddJSONInteger(ResultProps, 'mechanical_layer', DestinationLayerNumber);
        AddJSONNumber(ResultProps, 'line_width_mm', LineWidthMM);
        AddJSONInteger(ResultProps, 'footprints_seen', FootprintsSeen);
        AddJSONInteger(ResultProps, 'footprints_processed', FootprintsProcessed);
        AddJSONInteger(ResultProps, 'footprints_modified', FootprintsModified);
        AddJSONInteger(ResultProps, 'tracks_selected_for_delete', TracksSelected);
        ResultProps.Add(BuildJSONArray(SkippedFootprints, 'skipped_footprints'));
        ResultProps.Add(BuildJSONArray(ModifiedFootprints, 'modified_footprints'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        FootprintNames.Free;
        ResultProps.Free;
        ModifiedFootprints.Free;
        SkippedFootprints.Free;
    end;
end;

function DeletePCBLibrary3DBodiesWithEditor(ExcludeFootprints: TStringList; TargetFootprintName: String): String;
var
    PcbLib              : IPCB_Library;
    Board               : IPCB_Board;
    FootprintIterator   : IPCB_LibraryIterator;
    Footprint           : IPCB_LibComponent;
    FootprintNames      : TStringList;
    ResultProps         : TStringList;
    ModifiedFootprints  : TStringList;
    SkippedFootprints   : TStringList;
    OutputLines         : TStringList;
    FootprintName       : String;
    TargetName          : String;
    MatchAll            : Boolean;
    FootprintsSeen      : Integer;
    FootprintsProcessed : Integer;
    FootprintsModified  : Integer;
    BodiesSelected      : Integer;
    FootprintBodiesSelected : Integer;
    i                   : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    Board := PcbLib.Board;
    TargetName := Trim(TargetFootprintName);
    MatchAll := (TargetName = '') or (TargetName = '*');
    FootprintNames := TStringList.Create;
    ResultProps := TStringList.Create;
    ModifiedFootprints := TStringList.Create;
    SkippedFootprints := TStringList.Create;
    FootprintsSeen := 0;
    FootprintsProcessed := 0;
    FootprintsModified := 0;
    BodiesSelected := 0;

    try
        FootprintIterator := PcbLib.LibraryIterator_Create;
        if FootprintIterator = Nil then
        begin
            Result := '{"success": false, "error": "Failed to create PCB library footprint iterator."}';
            Exit;
        end;

        FootprintIterator.SetState_FilterAll;
        try
            Footprint := FootprintIterator.FirstPCBObject;
            while Footprint <> Nil do
            begin
                FootprintsSeen := FootprintsSeen + 1;
                FootprintName := Footprint.Name;

                if StringListContainsText(ExcludeFootprints, FootprintName) then
                begin
                    SkippedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                end
                else if MatchAll or (UpperCase(FootprintName) = UpperCase(TargetName)) then
                begin
                    FootprintsProcessed := FootprintsProcessed + 1;
                    FootprintNames.Add(FootprintName);
                end
                else
                    SkippedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');

                Footprint := FootprintIterator.NextPCBObject;
            end;
        finally
            PcbLib.LibraryIterator_Destroy(FootprintIterator);
        end;

        for i := 0 to FootprintNames.Count - 1 do
        begin
            FootprintName := FootprintNames[i];
            Footprint := FindLibFootprint(PcbLib, FootprintName);
            if Footprint <> Nil then
            begin
                Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);
                PcbLib.CurrentComponent := Footprint;
                Footprint := PcbLib.CurrentComponent;
                if Board <> Nil then
                    Board.ViewManager_FullUpdate;

                if Footprint <> Nil then
                begin
                    FootprintBodiesSelected := Select3DBodiesForEditorDelete(Footprint);
                    if FootprintBodiesSelected > 0 then
                    begin
                        BodiesSelected := BodiesSelected + FootprintBodiesSelected;
                        Client.SendMessage('PCB:DeleteObjects', 'Object=FOCUSED', 255, Client.CurrentView);
                        FootprintsModified := FootprintsModified + 1;
                        ModifiedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                    end;
                end;
            end;
        end;

        Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);
        if Board <> Nil then
            Board.ViewManager_FullUpdate;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'cleanup_source', 'PCB editor DeleteObjects process');
        AddJSONProperty(ResultProps, 'target_footprint', TargetFootprintName);
        AddJSONInteger(ResultProps, 'footprints_seen', FootprintsSeen);
        AddJSONInteger(ResultProps, 'footprints_processed', FootprintsProcessed);
        AddJSONInteger(ResultProps, 'footprints_modified', FootprintsModified);
        AddJSONInteger(ResultProps, 'bodies_selected_for_delete', BodiesSelected);
        ResultProps.Add(BuildJSONArray(SkippedFootprints, 'skipped_footprints'));
        ResultProps.Add(BuildJSONArray(ModifiedFootprints, 'modified_footprints'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        FootprintNames.Free;
        ResultProps.Free;
        ModifiedFootprints.Free;
        SkippedFootprints.Free;
    end;
end;

function CleanPCBLibraryPadsAndOverlayWithEditor(ExcludeFootprints: TStringList; TargetNameContains, PadNamePrefix, OverlayLayerName: String): String;
var
    PcbLib              : IPCB_Library;
    Board               : IPCB_Board;
    FootprintIterator   : IPCB_LibraryIterator;
    Footprint           : IPCB_LibComponent;
    OverlayLayer        : TLayer;
    ResultProps         : TStringList;
    ModifiedFootprints  : TStringList;
    SkippedFootprints   : TStringList;
    FootprintNames      : TStringList;
    OutputLines         : TStringList;
    FootprintName       : String;
    MatchText           : String;
    FootprintsSeen      : Integer;
    FootprintsProcessed : Integer;
    FootprintsModified  : Integer;
    PrimitivesSelected  : Integer;
    FootprintPrimitivesSelected : Integer;
    i                   : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    Board := PcbLib.Board;
    OverlayLayer := String2Layer(OverlayLayerName);
    MatchText := UpperCase(Trim(TargetNameContains));

    FootprintNames := TStringList.Create;
    ResultProps := TStringList.Create;
    ModifiedFootprints := TStringList.Create;
    SkippedFootprints := TStringList.Create;
    FootprintsSeen := 0;
    FootprintsProcessed := 0;
    FootprintsModified := 0;
    PrimitivesSelected := 0;

    try
        FootprintIterator := PcbLib.LibraryIterator_Create;
        if FootprintIterator = Nil then
        begin
            Result := '{"success": false, "error": "Failed to create PCB library footprint iterator."}';
            Exit;
        end;

        FootprintIterator.SetState_FilterAll;
        try
            Footprint := FootprintIterator.FirstPCBObject;
            while Footprint <> Nil do
            begin
                FootprintsSeen := FootprintsSeen + 1;
                FootprintName := Footprint.Name;

                if StringListContainsText(ExcludeFootprints, FootprintName) then
                begin
                    SkippedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                end
                else if (MatchText = '') or (Pos(MatchText, UpperCase(FootprintName)) > 0) then
                begin
                    FootprintsProcessed := FootprintsProcessed + 1;
                    FootprintNames.Add(FootprintName);
                end;

                Footprint := FootprintIterator.NextPCBObject;
            end;
        finally
            PcbLib.LibraryIterator_Destroy(FootprintIterator);
        end;

        for i := 0 to FootprintNames.Count - 1 do
        begin
            FootprintName := FootprintNames[i];
            Footprint := FindLibFootprint(PcbLib, FootprintName);
            if Footprint <> Nil then
            begin
                Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);
                PcbLib.CurrentComponent := Footprint;
                Footprint := PcbLib.CurrentComponent;
                if Board <> Nil then
                    Board.ViewManager_FullUpdate;

                if Footprint <> Nil then
                begin
                    FootprintPrimitivesSelected := SelectPadsByPrefixAndLayerPrimitives(Footprint, OverlayLayer, PadNamePrefix);
                    if FootprintPrimitivesSelected > 0 then
                    begin
                        PrimitivesSelected := PrimitivesSelected + FootprintPrimitivesSelected;
                        Client.SendMessage('PCB:DeleteObjects', 'Object=FOCUSED', 255, Client.CurrentView);
                        FootprintsModified := FootprintsModified + 1;
                        ModifiedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                    end;
                end;
            end;
        end;

        Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);
        if Board <> Nil then
            Board.ViewManager_FullUpdate;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'cleanup_source', 'PCB editor DeleteObjects process');
        AddJSONProperty(ResultProps, 'target_name_contains', TargetNameContains);
        AddJSONProperty(ResultProps, 'pad_name_prefix', PadNamePrefix);
        AddJSONProperty(ResultProps, 'overlay_layer', OverlayLayerName);
        AddJSONInteger(ResultProps, 'footprints_seen', FootprintsSeen);
        AddJSONInteger(ResultProps, 'footprints_processed', FootprintsProcessed);
        AddJSONInteger(ResultProps, 'footprints_modified', FootprintsModified);
        AddJSONInteger(ResultProps, 'primitives_selected_for_delete', PrimitivesSelected);
        ResultProps.Add(BuildJSONArray(SkippedFootprints, 'skipped_footprints'));
        ResultProps.Add(BuildJSONArray(ModifiedFootprints, 'modified_footprints'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        FootprintNames.Free;
        ResultProps.Free;
        ModifiedFootprints.Free;
        SkippedFootprints.Free;
    end;
end;

function SelectPCBLibraryProjectionTracksForEditor(ExcludeFootprints: TStringList; DestinationLayerNumber: Integer; LineWidthMM: Double): String;
var
    PcbLib              : IPCB_Library;
    Board               : IPCB_Board;
    FootprintIterator   : IPCB_LibraryIterator;
    Footprint           : IPCB_LibComponent;
    DestinationLayer    : TLayer;
    LineWidth           : TCoord;
    FootprintNames      : TStringList;
    ResultProps         : TStringList;
    SelectedArray       : TStringList;
    SkippedFootprints   : TStringList;
    SelectionProps      : TStringList;
    OutputLines         : TStringList;
    FootprintName       : String;
    FootprintsSeen      : Integer;
    FootprintsProcessed : Integer;
    FootprintsSelected  : Integer;
    TracksSelected      : Integer;
    FootprintTracksSelected : Integer;
    Left, Bottom, Right, Top : TCoord;
    i                   : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    if (DestinationLayerNumber < 1) or (DestinationLayerNumber > 32) then
    begin
        Result := '{"success": false, "error": "Mechanical layer number must be between 1 and 32."}';
        Exit;
    end;

    if LineWidthMM <= 0 then
    begin
        Result := '{"success": false, "error": "Line width must be greater than zero."}';
        Exit;
    end;

    Board := PcbLib.Board;
    DestinationLayer := ILayer.MechanicalLayer(DestinationLayerNumber);
    LineWidth := MMsToCoord(LineWidthMM);
    FootprintNames := TStringList.Create;
    ResultProps := TStringList.Create;
    SelectedArray := TStringList.Create;
    SkippedFootprints := TStringList.Create;
    FootprintsSeen := 0;
    FootprintsProcessed := 0;
    FootprintsSelected := 0;
    TracksSelected := 0;

    try
        EnsureMechanicalLayerEnabled(Board, DestinationLayerNumber);

        FootprintIterator := PcbLib.LibraryIterator_Create;
        if FootprintIterator = Nil then
        begin
            Result := '{"success": false, "error": "Failed to create PCB library footprint iterator."}';
            Exit;
        end;

        FootprintIterator.SetState_FilterAll;
        try
            Footprint := FootprintIterator.FirstPCBObject;
            while Footprint <> Nil do
            begin
                FootprintsSeen := FootprintsSeen + 1;
                FootprintName := Footprint.Name;

                if StringListContainsText(ExcludeFootprints, FootprintName) then
                begin
                    SkippedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                end
                else
                begin
                    FootprintsProcessed := FootprintsProcessed + 1;
                    FootprintNames.Add(FootprintName);
                end;

                Footprint := FootprintIterator.NextPCBObject;
            end;
        finally
            PcbLib.LibraryIterator_Destroy(FootprintIterator);
        end;

        Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);

        for i := 0 to FootprintNames.Count - 1 do
        begin
            FootprintName := FootprintNames[i];
            Footprint := FindLibFootprint(PcbLib, FootprintName);
            if Footprint <> Nil then
            begin
                PcbLib.CurrentComponent := Footprint;
                Footprint := PcbLib.CurrentComponent;
                if Board <> Nil then
                    Board.ViewManager_FullUpdate;

                if Footprint <> Nil then
                begin
                    FootprintTracksSelected := SelectProjectionTracksAndMeasure(Footprint, DestinationLayer, LineWidth, Left, Bottom, Right, Top);
                    if FootprintTracksSelected > 0 then
                    begin
                        TracksSelected := TracksSelected + FootprintTracksSelected;
                        FootprintsSelected := FootprintsSelected + 1;

                        SelectionProps := TStringList.Create;
                        try
                        AddJSONProperty(SelectionProps, 'footprint', FootprintName);
                        AddJSONInteger(SelectionProps, 'tracks_selected', FootprintTracksSelected);
                        AddJSONNumber(SelectionProps, 'left_mm', CoordToMMs(Left - Board.XOrigin));
                        AddJSONNumber(SelectionProps, 'bottom_mm', CoordToMMs(Bottom - Board.YOrigin));
                        AddJSONNumber(SelectionProps, 'right_mm', CoordToMMs(Right - Board.XOrigin));
                        AddJSONNumber(SelectionProps, 'top_mm', CoordToMMs(Top - Board.YOrigin));
                        AddJSONNumber(SelectionProps, 'absolute_left_mm', CoordToMMs(Left));
                        AddJSONNumber(SelectionProps, 'absolute_bottom_mm', CoordToMMs(Bottom));
                        AddJSONNumber(SelectionProps, 'absolute_right_mm', CoordToMMs(Right));
                        AddJSONNumber(SelectionProps, 'absolute_top_mm', CoordToMMs(Top));
                            SelectedArray.Add(BuildJSONObject(SelectionProps, 1));
                        finally
                            SelectionProps.Free;
                        end;
                    end;
                end;
            end;
        end;

        if Board <> Nil then
            Board.ViewManager_FullUpdate;
        Client.SendMessage('PCB:Zoom', 'Action=Selected', 255, Client.CurrentView);
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'selection_source', 'projection tracks');
        AddJSONInteger(ResultProps, 'mechanical_layer', DestinationLayerNumber);
        AddJSONNumber(ResultProps, 'line_width_mm', LineWidthMM);
        AddJSONInteger(ResultProps, 'footprints_seen', FootprintsSeen);
        AddJSONInteger(ResultProps, 'footprints_processed', FootprintsProcessed);
        AddJSONInteger(ResultProps, 'footprints_selected', FootprintsSelected);
        AddJSONInteger(ResultProps, 'tracks_selected', TracksSelected);
        ResultProps.Add(BuildJSONArray(SkippedFootprints, 'skipped_footprints'));
        ResultProps.Add(BuildJSONArray(SelectedArray, 'selected_footprints'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        FootprintNames.Free;
        ResultProps.Free;
        SelectedArray.Free;
        SkippedFootprints.Free;
    end;
end;

function AddPCBLibraryProjectionTexts(ExcludeFootprints: TStringList; DestinationLayerNumber: Integer; ReferenceFootprintName: String): String;
var
    PcbLib              : IPCB_Library;
    Board               : IPCB_Board;
    FootprintIterator   : IPCB_LibraryIterator;
    Footprint           : IPCB_LibComponent;
    DestinationLayer    : TLayer;
    FootprintNames      : TStringList;
    ResultProps         : TStringList;
    ModifiedFootprints  : TStringList;
    SkippedFootprints   : TStringList;
    OutputLines         : TStringList;
    FootprintName       : String;
    DesignatorLocalX    : TCoord;
    DesignatorLocalY    : TCoord;
    CommentLocalX       : TCoord;
    CommentLocalY       : TCoord;
    ProjectionLineWidth : TCoord;
    DesignatorAtCenter  : Boolean;
    DesignatorsCentered : Integer;
    FootprintsSeen      : Integer;
    FootprintsProcessed : Integer;
    FootprintsModified  : Integer;
    TextsDeleted        : Integer;
    TextsCreated        : Integer;
    FootprintTextsDeleted : Integer;
    FootprintTextsCreated : Integer;
    i                   : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    if (DestinationLayerNumber < 1) or (DestinationLayerNumber > 32) then
    begin
        Result := '{"success": false, "error": "Mechanical layer number must be between 1 and 32."}';
        Exit;
    end;

    Board := PcbLib.Board;
    DestinationLayer := ILayer.MechanicalLayer(DestinationLayerNumber);
    ProjectionLineWidth := MMsToCoord(0.1);

    FootprintNames := TStringList.Create;
    ResultProps := TStringList.Create;
    ModifiedFootprints := TStringList.Create;
    SkippedFootprints := TStringList.Create;
    FootprintsSeen := 0;
    FootprintsProcessed := 0;
    FootprintsModified := 0;
    TextsDeleted := 0;
    TextsCreated := 0;
    DesignatorsCentered := 0;

    try
        EnsureMechanicalLayerEnabled(Board, DestinationLayerNumber);

        FootprintIterator := PcbLib.LibraryIterator_Create;
        if FootprintIterator = Nil then
        begin
            Result := '{"success": false, "error": "Failed to create PCB library footprint iterator."}';
            Exit;
        end;

        FootprintIterator.SetState_FilterAll;
        try
            Footprint := FootprintIterator.FirstPCBObject;
            while Footprint <> Nil do
            begin
                FootprintsSeen := FootprintsSeen + 1;
                FootprintName := Footprint.Name;

                if (ReferenceFootprintName <> '') and (UpperCase(FootprintName) <> UpperCase(ReferenceFootprintName)) then
                begin
                    SkippedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                end
                else if StringListContainsText(ExcludeFootprints, FootprintName) then
                begin
                    SkippedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                end
                else
                begin
                    FootprintsProcessed := FootprintsProcessed + 1;
                    FootprintNames.Add(FootprintName);
                end;

                Footprint := FootprintIterator.NextPCBObject;
            end;
        finally
            PcbLib.LibraryIterator_Destroy(FootprintIterator);
        end;

        for i := 0 to FootprintNames.Count - 1 do
        begin
            FootprintName := FootprintNames[i];
            Footprint := FindLibFootprint(PcbLib, FootprintName);
            if Footprint <> Nil then
            begin
                PcbLib.CurrentComponent := Footprint;
                Footprint := PcbLib.CurrentComponent;
                if Board <> Nil then
                    Board.ViewManager_FullUpdate;

                if Footprint <> Nil then
                begin
                    Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);
                    FootprintTextsDeleted := SelectProjectionTexts(Footprint, DestinationLayer);
                    if FootprintTextsDeleted > 0 then
                    begin
                        Client.SendMessage('PCB:DeleteObjects', 'Object=FOCUSED', 255, Client.CurrentView);
                        TextsDeleted := TextsDeleted + FootprintTextsDeleted;
                    end;

                    ChooseProjectionTextLocations(
                        Board,
                        Footprint,
                        DestinationLayer,
                        ProjectionLineWidth,
                        DesignatorLocalX,
                        DesignatorLocalY,
                        CommentLocalX,
                        CommentLocalY,
                        DesignatorAtCenter
                    );

                    FootprintTextsCreated := 0;
                    PCBServer.PreProcess;
                    try
                        if AddProjectionTextBuiltIn(Board, DestinationLayer, '.Designator', DesignatorLocalX, DesignatorLocalY) then
                            FootprintTextsCreated := FootprintTextsCreated + 1;
                        if AddProjectionTextBuiltIn(Board, DestinationLayer, '.Comment', CommentLocalX, CommentLocalY) then
                            FootprintTextsCreated := FootprintTextsCreated + 1;
                    finally
                        PCBServer.PostProcess;
                    end;

                    if FootprintTextsCreated > 0 then
                    begin
                        TextsCreated := TextsCreated + FootprintTextsCreated;
                        FootprintsModified := FootprintsModified + 1;
                        ModifiedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                        if DesignatorAtCenter then
                            DesignatorsCentered := DesignatorsCentered + 1;
                    end;

                    if Board <> Nil then
                        Board.ViewManager_FullUpdate;
                end;
            end;
        end;

        Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);
        if Board <> Nil then
            Board.ViewManager_FullUpdate;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'text_style_source', 'built-in');
        AddJSONNumber(ResultProps, 'text_height_mm', CoordToMMs(ProjectionTextHeight));
        AddJSONNumber(ResultProps, 'text_stroke_width_mm', CoordToMMs(ProjectionTextStrokeWidth));
        AddJSONNumber(ResultProps, 'comment_gap_mm', CoordToMMs(ProjectionCommentGap));
        AddJSONNumber(ResultProps, 'projection_line_width_mm', CoordToMMs(ProjectionLineWidth));
        AddJSONInteger(ResultProps, 'mechanical_layer', DestinationLayerNumber);
        AddJSONProperty(ResultProps, 'target_footprint', ReferenceFootprintName);
        AddJSONInteger(ResultProps, 'footprints_seen', FootprintsSeen);
        AddJSONInteger(ResultProps, 'footprints_processed', FootprintsProcessed);
        AddJSONInteger(ResultProps, 'footprints_modified', FootprintsModified);
        AddJSONInteger(ResultProps, 'texts_deleted', TextsDeleted);
        AddJSONInteger(ResultProps, 'texts_created', TextsCreated);
        AddJSONInteger(ResultProps, 'designators_centered', DesignatorsCentered);
        ResultProps.Add(BuildJSONArray(SkippedFootprints, 'skipped_footprints'));
        ResultProps.Add(BuildJSONArray(ModifiedFootprints, 'modified_footprints'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        FootprintNames.Free;
        ResultProps.Free;
        ModifiedFootprints.Free;
        SkippedFootprints.Free;
    end;
end;

function ProjectPCBLibraryStepSilhouettes(ExcludeFootprints: TStringList; DestinationLayerNumber: Integer; LineWidthMM: Double; RemoveExisting: Boolean): String;
var
    PcbLib              : IPCB_Library;
    Board               : IPCB_Board;
    FootprintIterator   : IPCB_LibraryIterator;
    Footprint           : IPCB_LibComponent;
    DestinationLayer    : TLayer;
    LineWidth           : TCoord;
    SegmentLines        : TStringList;
    ResultProps         : TStringList;
    ModifiedFootprints  : TStringList;
    SkippedFootprints   : TStringList;
    FootprintNames      : TStringList;
    OutputLines         : TStringList;
    DataFileName        : String;
    FootprintName       : String;
    SegmentFootprint    : String;
    FootprintsSeen      : Integer;
    FootprintsProcessed : Integer;
    FootprintsModified  : Integer;
    SegmentsLoaded      : Integer;
    SegmentsMatched     : Integer;
    TracksCreated       : Integer;
    ArcsCreated         : Integer;
    TracksRemoved       : Integer;
    FootprintPrimitivesCreated : Integer;
    PrimitiveKind      : String;
    X1MM, Y1MM, X2MM, Y2MM : Double;
    CenterXMM, CenterYMM, RadiusMM : Double;
    StartAngle, EndAngle : Double;
    i                   : Integer;
    SegmentIndex        : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    if (DestinationLayerNumber < 1) or (DestinationLayerNumber > 32) then
    begin
        Result := '{"success": false, "error": "Mechanical layer number must be between 1 and 32."}';
        Exit;
    end;

    if LineWidthMM <= 0 then
    begin
        Result := '{"success": false, "error": "Line width must be greater than zero."}';
        Exit;
    end;

    DataFileName := ROOT_DIR + '3d_body_silhouette.txt';
    if not FileExists(DataFileName) then
    begin
        Result := '{"success": false, "error": "Silhouette segment file not found: C:\\Users\\Public\\altium_mcp\\3d_body_silhouette.txt"}';
        Exit;
    end;

    Board := PcbLib.Board;
    DestinationLayer := ILayer.MechanicalLayer(DestinationLayerNumber);
    LineWidth := MMsToCoord(LineWidthMM);

    SegmentLines := TStringList.Create;
    ResultProps := TStringList.Create;
    ModifiedFootprints := TStringList.Create;
    SkippedFootprints := TStringList.Create;
    FootprintNames := TStringList.Create;
    FootprintsSeen := 0;
    FootprintsProcessed := 0;
    FootprintsModified := 0;
    SegmentsMatched := 0;
    TracksCreated := 0;
    ArcsCreated := 0;
    TracksRemoved := 0;

    try
        SegmentLines.LoadFromFile(DataFileName);
        SegmentsLoaded := SegmentLines.Count;
        EnsureMechanicalLayerEnabled(Board, DestinationLayerNumber);

        FootprintIterator := PcbLib.LibraryIterator_Create;
        if FootprintIterator = Nil then
        begin
            Result := '{"success": false, "error": "Failed to create PCB library footprint iterator."}';
            Exit;
        end;

        FootprintIterator.SetState_FilterAll;

        try
            Footprint := FootprintIterator.FirstPCBObject;
            while Footprint <> Nil do
            begin
                FootprintsSeen := FootprintsSeen + 1;
                FootprintName := Footprint.Name;

                if StringListContainsText(ExcludeFootprints, FootprintName) then
                begin
                    SkippedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                end
                else
                begin
                    FootprintsProcessed := FootprintsProcessed + 1;
                    FootprintNames.Add(FootprintName);
                end;

                Footprint := FootprintIterator.NextPCBObject;
            end;
        finally
            PcbLib.LibraryIterator_Destroy(FootprintIterator);
        end;

        for i := 0 to FootprintNames.Count - 1 do
        begin
            FootprintName := FootprintNames[i];
            Footprint := FindLibFootprint(PcbLib, FootprintName);
            if Footprint <> Nil then
            begin
                PcbLib.CurrentComponent := Footprint;
                Footprint := PcbLib.CurrentComponent;
                if Board <> Nil then
                    Board.ViewManager_FullUpdate;

                if Footprint <> Nil then
                begin
                    FootprintPrimitivesCreated := 0;

                    PCBServer.PreProcess;
                    try
                        if RemoveExisting then
                            TracksRemoved := TracksRemoved + RemoveProjectionTracks(Footprint, DestinationLayer, LineWidth);

                        for SegmentIndex := 0 to SegmentLines.Count - 1 do
                        begin
                            if ParseSilhouettePrimitive(SegmentLines[SegmentIndex], SegmentFootprint, PrimitiveKind, X1MM, Y1MM, X2MM, Y2MM, CenterXMM, CenterYMM, RadiusMM, StartAngle, EndAngle) then
                            begin
                                if UpperCase(SegmentFootprint) = UpperCase(FootprintName) then
                                begin
                                    if PrimitiveKind = 'ARC' then
                                    begin
                                        if AddProjectionBoardArc(
                                            Board,
                                            DestinationLayer,
                                            Board.XOrigin + MMsToCoord(CenterXMM),
                                            Board.YOrigin + MMsToCoord(CenterYMM),
                                            MMsToCoord(RadiusMM),
                                            StartAngle,
                                            EndAngle,
                                            LineWidth
                                        ) then
                                        begin
                                            FootprintPrimitivesCreated := FootprintPrimitivesCreated + 1;
                                            ArcsCreated := ArcsCreated + 1;
                                            SegmentsMatched := SegmentsMatched + 1;
                                        end;
                                    end
                                    else
                                    begin
                                        if AddProjectionBoardTrack(
                                            Board,
                                            DestinationLayer,
                                            Board.XOrigin + MMsToCoord(X1MM),
                                            Board.YOrigin + MMsToCoord(Y1MM),
                                            Board.XOrigin + MMsToCoord(X2MM),
                                            Board.YOrigin + MMsToCoord(Y2MM),
                                            LineWidth
                                        ) then
                                        begin
                                            FootprintPrimitivesCreated := FootprintPrimitivesCreated + 1;
                                            TracksCreated := TracksCreated + 1;
                                            SegmentsMatched := SegmentsMatched + 1;
                                        end;
                                    end;
                                end;
                            end;
                        end;
                    finally
                        PCBServer.PostProcess;
                    end;

                    if FootprintPrimitivesCreated > 0 then
                    begin
                        FootprintsModified := FootprintsModified + 1;
                        ModifiedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                    end;

                    if Board <> Nil then
                        Board.ViewManager_FullUpdate;
                end;
            end;
        end;

        if Board <> Nil then
            Board.ViewManager_FullUpdate;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'projection_source', 'STEP edge projection');
        AddJSONProperty(ResultProps, 'silhouette_file', DataFileName);
        AddJSONBoolean(ResultProps, 'remove_existing', RemoveExisting);
        AddJSONInteger(ResultProps, 'mechanical_layer', DestinationLayerNumber);
        AddJSONNumber(ResultProps, 'line_width_mm', LineWidthMM);
        AddJSONInteger(ResultProps, 'segments_loaded', SegmentsLoaded);
        AddJSONInteger(ResultProps, 'segments_matched', SegmentsMatched);
        AddJSONInteger(ResultProps, 'footprints_seen', FootprintsSeen);
        AddJSONInteger(ResultProps, 'footprints_processed', FootprintsProcessed);
        AddJSONInteger(ResultProps, 'footprints_modified', FootprintsModified);
        AddJSONInteger(ResultProps, 'tracks_removed', TracksRemoved);
        AddJSONInteger(ResultProps, 'tracks_created', TracksCreated);
        AddJSONInteger(ResultProps, 'arcs_created', ArcsCreated);
        AddJSONInteger(ResultProps, 'primitives_created', TracksCreated + ArcsCreated);
        ResultProps.Add(BuildJSONArray(SkippedFootprints, 'skipped_footprints'));
        ResultProps.Add(BuildJSONArray(ModifiedFootprints, 'modified_footprints'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        SegmentLines.Free;
        ResultProps.Free;
        ModifiedFootprints.Free;
        SkippedFootprints.Free;
        FootprintNames.Free;
    end;
end;

function ProjectPCBLibrary3DBodyOutlines(ExcludeFootprints: TStringList; DestinationLayerNumber: Integer; LineWidthMM: Double): String;
var
    PcbLib              : IPCB_Library;
    Board               : IPCB_Board;
    FootprintIterator   : IPCB_LibraryIterator;
    Footprint           : IPCB_LibComponent;
    BodyIterator        : IPCB_GroupIterator;
    Primitive           : IPCB_Primitive;
    BodyRect            : TCoordRect;
    DestinationLayer    : TLayer;
    LineWidth           : TCoord;
    ResultProps         : TStringList;
    ModifiedFootprints  : TStringList;
    SkippedFootprints   : TStringList;
    OutputLines         : TStringList;
    FootprintName       : String;
    FootprintsSeen      : Integer;
    FootprintsProcessed : Integer;
    FootprintsModified  : Integer;
    FootprintsWithBodies : Integer;
    BodiesSeen          : Integer;
    TracksCreated       : Integer;
    FootprintBodiesSeen : Integer;
    FootprintTracksCreated : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    if (DestinationLayerNumber < 1) or (DestinationLayerNumber > 32) then
    begin
        Result := '{"success": false, "error": "Mechanical layer number must be between 1 and 32."}';
        Exit;
    end;

    if LineWidthMM <= 0 then
    begin
        Result := '{"success": false, "error": "Line width must be greater than zero."}';
        Exit;
    end;

    Board := PcbLib.Board;
    DestinationLayer := ILayer.MechanicalLayer(DestinationLayerNumber);
    LineWidth := MMsToCoord(LineWidthMM);

    ResultProps := TStringList.Create;
    ModifiedFootprints := TStringList.Create;
    SkippedFootprints := TStringList.Create;
    FootprintsSeen := 0;
    FootprintsProcessed := 0;
    FootprintsModified := 0;
    FootprintsWithBodies := 0;
    BodiesSeen := 0;
    TracksCreated := 0;

    try
        EnsureMechanicalLayerEnabled(Board, DestinationLayerNumber);

        FootprintIterator := PcbLib.LibraryIterator_Create;
        if FootprintIterator = Nil then
        begin
            Result := '{"success": false, "error": "Failed to create PCB library footprint iterator."}';
            Exit;
        end;

        FootprintIterator.SetState_FilterAll;

        PCBServer.PreProcess;
        try
            Footprint := FootprintIterator.FirstPCBObject;
            while Footprint <> Nil do
            begin
                FootprintsSeen := FootprintsSeen + 1;
                FootprintName := Footprint.Name;

                if StringListContainsText(ExcludeFootprints, FootprintName) then
                begin
                    SkippedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                end
                else
                begin
                    FootprintsProcessed := FootprintsProcessed + 1;
                    FootprintBodiesSeen := 0;
                    FootprintTracksCreated := 0;

                    BodyIterator := Footprint.GroupIterator_Create;
                    if BodyIterator <> Nil then
                    begin
                        try
                            BodyIterator.AddFilter_ObjectSet(MkSet(eComponentBodyObject));
                            BodyIterator.AddFilter_LayerSet(AllLayers);

                            Primitive := BodyIterator.FirstPCBObject;
                            while Primitive <> Nil do
                            begin
                                BodiesSeen := BodiesSeen + 1;
                                FootprintBodiesSeen := FootprintBodiesSeen + 1;

                                BodyRect := Primitive.BoundingRectangle;
                                FootprintTracksCreated := FootprintTracksCreated + AddProjectionRectangle(Footprint, DestinationLayer, BodyRect, LineWidth);

                                Primitive := BodyIterator.NextPCBObject;
                            end;
                        finally
                            Footprint.GroupIterator_Destroy(BodyIterator);
                        end;
                    end;

                    if FootprintBodiesSeen > 0 then
                        FootprintsWithBodies := FootprintsWithBodies + 1;

                    if FootprintTracksCreated > 0 then
                    begin
                        TracksCreated := TracksCreated + FootprintTracksCreated;
                        FootprintsModified := FootprintsModified + 1;
                        ModifiedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                    end;
                end;

                Footprint := FootprintIterator.NextPCBObject;
            end;
        finally
            PCBServer.PostProcess;
            PcbLib.LibraryIterator_Destroy(FootprintIterator);
        end;

        if Board <> Nil then
            Board.ViewManager_FullUpdate;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'projection_source', '3D body bounding rectangle');
        AddJSONInteger(ResultProps, 'mechanical_layer', DestinationLayerNumber);
        AddJSONNumber(ResultProps, 'line_width_mm', LineWidthMM);
        AddJSONInteger(ResultProps, 'footprints_seen', FootprintsSeen);
        AddJSONInteger(ResultProps, 'footprints_processed', FootprintsProcessed);
        AddJSONInteger(ResultProps, 'footprints_with_3d_bodies', FootprintsWithBodies);
        AddJSONInteger(ResultProps, 'footprints_modified', FootprintsModified);
        AddJSONInteger(ResultProps, 'component_bodies_seen', BodiesSeen);
        AddJSONInteger(ResultProps, 'tracks_created', TracksCreated);
        ResultProps.Add(BuildJSONArray(SkippedFootprints, 'skipped_footprints'));
        ResultProps.Add(BuildJSONArray(ModifiedFootprints, 'modified_footprints'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
        ModifiedFootprints.Free;
        SkippedFootprints.Free;
    end;
end;

function SetPCBLibraryPadShapes(ExcludeFootprints: TStringList; NewShape: TShape): String;
var
    PcbLib              : IPCB_Library;
    Board               : IPCB_Board;
    FootprintIterator   : IPCB_LibraryIterator;
    Footprint           : IPCB_LibComponent;
    PadIterator         : IPCB_GroupIterator;
    Pad                 : IPCB_Pad;
    ResultProps         : TStringList;
    ModifiedFootprints  : TStringList;
    SkippedFootprints   : TStringList;
    OutputLines         : TStringList;
    FootprintName       : String;
    FootprintsSeen      : Integer;
    FootprintsProcessed : Integer;
    FootprintsModified  : Integer;
    PadsSeen            : Integer;
    PadsModified        : Integer;
    FootprintPadsModified : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    Board := PcbLib.Board;
    ResultProps := TStringList.Create;
    ModifiedFootprints := TStringList.Create;
    SkippedFootprints := TStringList.Create;
    FootprintsSeen := 0;
    FootprintsProcessed := 0;
    FootprintsModified := 0;
    PadsSeen := 0;
    PadsModified := 0;

    try
        FootprintIterator := PcbLib.LibraryIterator_Create;
        if FootprintIterator = Nil then
        begin
            Result := '{"success": false, "error": "Failed to create PCB library footprint iterator."}';
            Exit;
        end;

        FootprintIterator.SetState_FilterAll;

        PCBServer.PreProcess;
        try
            Footprint := FootprintIterator.FirstPCBObject;
            while Footprint <> Nil do
            begin
                FootprintsSeen := FootprintsSeen + 1;
                FootprintName := Footprint.Name;

                if StringListContainsText(ExcludeFootprints, FootprintName) then
                begin
                    SkippedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                end
                else
                begin
                    FootprintsProcessed := FootprintsProcessed + 1;
                    FootprintPadsModified := 0;

                    PadIterator := Footprint.GroupIterator_Create;
                    if PadIterator <> Nil then
                    begin
                        try
                            PadIterator.AddFilter_ObjectSet(MkSet(ePadObject));

                            Pad := PadIterator.FirstPCBObject;
                            while Pad <> Nil do
                            begin
                                PadsSeen := PadsSeen + 1;

                                PCBServer.SendMessageToRobots(Pad.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
                                if SetPadCopperShape(Pad, Board, NewShape) then
                                begin
                                    PadsModified := PadsModified + 1;
                                    FootprintPadsModified := FootprintPadsModified + 1;
                                end;
                                PCBServer.SendMessageToRobots(Pad.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);

                                Pad := PadIterator.NextPCBObject;
                            end;
                        finally
                            Footprint.GroupIterator_Destroy(PadIterator);
                        end;
                    end;

                    if FootprintPadsModified > 0 then
                    begin
                        FootprintsModified := FootprintsModified + 1;
                        ModifiedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                    end;
                end;

                Footprint := FootprintIterator.NextPCBObject;
            end;
        finally
            PCBServer.PostProcess;
            PcbLib.LibraryIterator_Destroy(FootprintIterator);
        end;

        if Board <> Nil then
            Board.ViewManager_FullUpdate;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'shape', 'Rounded Rectangle');
        AddJSONInteger(ResultProps, 'footprints_seen', FootprintsSeen);
        AddJSONInteger(ResultProps, 'footprints_processed', FootprintsProcessed);
        AddJSONInteger(ResultProps, 'footprints_modified', FootprintsModified);
        AddJSONInteger(ResultProps, 'pads_seen', PadsSeen);
        AddJSONInteger(ResultProps, 'pads_modified', PadsModified);
        ResultProps.Add(BuildJSONArray(SkippedFootprints, 'skipped_footprints'));
        ResultProps.Add(BuildJSONArray(ModifiedFootprints, 'modified_footprints'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
        ModifiedFootprints.Free;
        SkippedFootprints.Free;
    end;
end;

function GetPCBLibraryFootprints(ROOT_DIR: String): String;
var
    PcbLib            : IPCB_Library;
    FootprintIterator : IPCB_LibraryIterator;
    Footprint         : IPCB_LibComponent;
    FootprintsArray   : TStringList;
    ResultProps       : TStringList;
    OutputLines       : TStringList;
    FootprintCount    : Integer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    FootprintsArray := TStringList.Create;
    ResultProps := TStringList.Create;
    FootprintCount := 0;

    try
        FootprintIterator := PcbLib.LibraryIterator_Create;
        if FootprintIterator = Nil then
        begin
            Result := '{"success": false, "error": "Failed to create PCB library footprint iterator."}';
            Exit;
        end;

        try
            FootprintIterator.SetState_FilterAll;
            Footprint := FootprintIterator.FirstPCBObject;
            while Footprint <> Nil do
            begin
                FootprintCount := FootprintCount + 1;
                FootprintsArray.Add('"' + JSONEscapeString(Footprint.Name) + '"');
                Footprint := FootprintIterator.NextPCBObject;
            end;
        finally
            PcbLib.LibraryIterator_Destroy(FootprintIterator);
        end;

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONInteger(ResultProps, 'footprint_count', FootprintCount);
        ResultProps.Add(BuildJSONArray(FootprintsArray, 'footprints'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := WriteJSONToFile(OutputLines, ROOT_DIR + 'temp_pcblib_footprints.json');
        finally
            OutputLines.Free;
        end;
    finally
        FootprintsArray.Free;
        ResultProps.Free;
    end;
end;

// Create a PCB footprint (SMD pads + silkscreen + courtyard) in the active PcbLib
function CreatePCBFootprint(FootprintName: String; Description: String; PadsList: TStringList; CourtyardXMM: Double; CourtyardYMM: Double): String;
var
    PcbLib      : IPCB_Library;
    LibComp     : IPCB_Component;
    Pad         : IPCB_Pad;
    Track       : IPCB_Track;
    ResultProps : TStringList;
    OutputLines : TStringList;
    i, j        : Integer;
    PadData     : String;
    PadNum      : String;
    XMM, YMM    : Double;
    WMM, HMM    : Double;
    ShapeStr    : String;
    PadShape    : TShape;
    PadCount    : Integer;
    MaxX, MaxY  : Double;
    MinX, MinY  : Double;
    CrtX1, CrtY1, CrtX2, CrtY2 : Double;
    TrackWidth  : TCoord;
    FieldStart  : Integer;
    Fields      : TStringList;
    SilkLayer   : TLayer;
begin
    PcbLib := GetPcbLibSafe(0);
    if PcbLib = nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    ResultProps := TStringList.Create;
    Fields := TStringList.Create;
    PadCount := 0;
    MaxX := -1e9; MaxY := -1e9;
    MinX :=  1e9; MinY :=  1e9;
    SilkLayer := String2Layer('Top Overlay');

    try
        PCBServer.PreProcess;
        try
            LibComp := PCBServer.CreatePCBLibComp;
            LibComp.Name := FootprintName;
            LibComp.Description := Description;

            PcbLib.RegisterComponent(LibComp);

            for i := 0 to PadsList.Count - 1 do
            begin
                PadData := Trim(PadsList[i]);
                if (PadData = '') then continue;

                // Parse pipe-delimited fields manually
                Fields.Clear;
                FieldStart := 1;
                for j := 1 to Length(PadData) + 1 do
                begin
                    if (j > Length(PadData)) or (PadData[j] = '|') then
                    begin
                        Fields.Add(Trim(Copy(PadData, FieldStart, j - FieldStart)));
                        FieldStart := j + 1;
                    end;
                end;

                if Fields.Count < 5 then continue;

                PadNum := Fields[0];
                XMM := SafeStrToFloat(Fields[1]);
                YMM := SafeStrToFloat(Fields[2]);
                WMM := SafeStrToFloat(Fields[3]);
                HMM := SafeStrToFloat(Fields[4]);

                if Fields.Count >= 6 then
                    ShapeStr := Fields[5]
                else
                    ShapeStr := 'Rect';

                if ShapeStr = 'Round' then
                    PadShape := eRounded
                else if ShapeStr = 'Oval' then
                    PadShape := eRoundedRectangular
                else
                    PadShape := eRectangular;

                Pad := PCBServer.PCBObjectFactory(ePadObject, eNoDimension, eCreate_Default);
                Pad.Name := PadNum;
                Pad.Mode := ePadMode_Simple;
                Pad.HoleSize := 0;
                Pad.x := MMsToCoord(XMM);
                Pad.y := MMsToCoord(YMM);
                Pad.Layer := eTopLayer;
                Pad.TopXSize := MMsToCoord(WMM);
                Pad.TopYSize := MMsToCoord(HMM);
                Pad.TopShape := PadShape;
                // Every pad the tool creates is locked
                Pad.Moveable := False;

                LibComp.AddPCBObject(Pad);
                PCBServer.SendMessageToRobots(LibComp.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Pad.I_ObjectAddress);

                if (XMM - WMM/2) < MinX then MinX := XMM - WMM/2;
                if (YMM - HMM/2) < MinY then MinY := YMM - HMM/2;
                if (XMM + WMM/2) > MaxX then MaxX := XMM + WMM/2;
                if (YMM + HMM/2) > MaxY then MaxY := YMM + HMM/2;

                PadCount := PadCount + 1;
            end;

            // Compute courtyard extents
            if (CourtyardXMM > 0) and (CourtyardYMM > 0) then
            begin
                CrtX1 := -CourtyardXMM; CrtX2 :=  CourtyardXMM;
                CrtY1 := -CourtyardYMM; CrtY2 :=  CourtyardYMM;
            end
            else
            begin
                CrtX1 := MinX - 0.25; CrtX2 := MaxX + 0.25;
                CrtY1 := MinY - 0.25; CrtY2 := MaxY + 0.25;
            end;

            TrackWidth := MMsToCoord(0.1);

            // Courtyard on Mechanical 15
            Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
            Track.Layer := ILayer.MechanicalLayer(15);
            Track.x1 := MMsToCoord(CrtX1); Track.y1 := MMsToCoord(CrtY1);
            Track.x2 := MMsToCoord(CrtX2); Track.y2 := MMsToCoord(CrtY1);
            Track.Width := TrackWidth;
            LibComp.AddPCBObject(Track);
            PCBServer.SendMessageToRobots(LibComp.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Track.I_ObjectAddress);

            Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
            Track.Layer := ILayer.MechanicalLayer(15);
            Track.x1 := MMsToCoord(CrtX1); Track.y1 := MMsToCoord(CrtY2);
            Track.x2 := MMsToCoord(CrtX2); Track.y2 := MMsToCoord(CrtY2);
            Track.Width := TrackWidth;
            LibComp.AddPCBObject(Track);
            PCBServer.SendMessageToRobots(LibComp.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Track.I_ObjectAddress);

            Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
            Track.Layer := ILayer.MechanicalLayer(15);
            Track.x1 := MMsToCoord(CrtX1); Track.y1 := MMsToCoord(CrtY1);
            Track.x2 := MMsToCoord(CrtX1); Track.y2 := MMsToCoord(CrtY2);
            Track.Width := TrackWidth;
            LibComp.AddPCBObject(Track);
            PCBServer.SendMessageToRobots(LibComp.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Track.I_ObjectAddress);

            Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
            Track.Layer := ILayer.MechanicalLayer(15);
            Track.x1 := MMsToCoord(CrtX2); Track.y1 := MMsToCoord(CrtY1);
            Track.x2 := MMsToCoord(CrtX2); Track.y2 := MMsToCoord(CrtY2);
            Track.Width := TrackWidth;
            LibComp.AddPCBObject(Track);
            PCBServer.SendMessageToRobots(LibComp.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Track.I_ObjectAddress);

            // Silkscreen on TopOverlay (inset 0.1mm from courtyard)
            Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
            Track.Layer := SilkLayer;
            Track.x1 := MMsToCoord(CrtX1+0.1); Track.y1 := MMsToCoord(CrtY1+0.1);
            Track.x2 := MMsToCoord(CrtX2-0.1); Track.y2 := MMsToCoord(CrtY1+0.1);
            Track.Width := TrackWidth;
            LibComp.AddPCBObject(Track);
            PCBServer.SendMessageToRobots(LibComp.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Track.I_ObjectAddress);

            Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
            Track.Layer := SilkLayer;
            Track.x1 := MMsToCoord(CrtX1+0.1); Track.y1 := MMsToCoord(CrtY2-0.1);
            Track.x2 := MMsToCoord(CrtX2-0.1); Track.y2 := MMsToCoord(CrtY2-0.1);
            Track.Width := TrackWidth;
            LibComp.AddPCBObject(Track);
            PCBServer.SendMessageToRobots(LibComp.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Track.I_ObjectAddress);

            // Left silk — split to mark pin 1 (gap at top-left corner for pin 1 indicator)
            Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
            Track.Layer := SilkLayer;
            Track.x1 := MMsToCoord(CrtX1+0.1); Track.y1 := MMsToCoord(CrtY1+0.1);
            Track.x2 := MMsToCoord(CrtX1+0.1); Track.y2 := MMsToCoord(CrtY2-0.6);
            Track.Width := TrackWidth;
            LibComp.AddPCBObject(Track);
            PCBServer.SendMessageToRobots(LibComp.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Track.I_ObjectAddress);

            // Right silk
            Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
            Track.Layer := SilkLayer;
            Track.x1 := MMsToCoord(CrtX2-0.1); Track.y1 := MMsToCoord(CrtY1+0.1);
            Track.x2 := MMsToCoord(CrtX2-0.1); Track.y2 := MMsToCoord(CrtY2-0.1);
            Track.Width := TrackWidth;
            LibComp.AddPCBObject(Track);
            PCBServer.SendMessageToRobots(LibComp.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Track.I_ObjectAddress);

            PCBServer.SendMessageToRobots(PcbLib.Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, LibComp.I_ObjectAddress);
        finally
            PCBServer.PostProcess;
        end;
        PcbLib.CurrentComponent := LibComp;
        PcbLib.Board.ViewManager_FullUpdate;
        MarkDocumentModified(PcbLib.Board.FileName);

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'footprint_name', FootprintName);
        AddJSONInteger(ResultProps, 'pad_count', PadCount);
        AddJSONNumber(ResultProps, 'courtyard_width_mm', CrtX2 - CrtX1);
        AddJSONNumber(ResultProps, 'courtyard_height_mm', CrtY2 - CrtY1);
        AddJSONBoolean(ResultProps, 'document_saved', False);
        AddJSONBoolean(ResultProps, 'document_dirty', True);
        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
        Fields.Free;
    end;
end;

// Function to move components by X and Y offsets and set rotation
function MoveComponentsByDesignators(DesignatorsList: TStringList; XOffset, YOffset: TCoord; Rotation: TAngle): String;
var
    Board          : IPCB_Board;
    Component      : IPCB_Component;
    ResultProps    : TStringList;
    MissingArray   : TStringList;
    Designator     : String;
    i              : Integer;
    MovedCount     : Integer;
    OutputLines    : TStringList;
begin
    // Retrieve the current board
    Board := GetBoardSafe(0);
    if (Board = nil) then
    begin
        Result := 'ERROR: No PCB document is currently active';
        Exit;
    end;

    // Create output properties
    ResultProps := TStringList.Create;
    MissingArray := TStringList.Create;
    MovedCount := 0;

    try
        // Start transaction
        PCBServer.PreProcess;

        // Process each designator
        for i := 0 to DesignatorsList.Count - 1 do
        begin
            Designator := Trim(DesignatorsList[i]);

            // Use direct function to get component by designator
            Component := Board.GetPcbComponentByRefDes(Designator);

            if (Component <> Nil) then
            begin
                // Begin modify
                PCBServer.SendMessageToRobots(Component.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);

                // Move the component by the specified offsets
                Component.MoveByXY(XOffset, YOffset);

                // Set rotation if specified (non-zero)
                if (Rotation <> 0) then
                    Component.Rotation := Rotation;

                // End modify
                PCBServer.SendMessageToRobots(Component.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);

                MovedCount := MovedCount + 1;
            end
            else
            begin
                // Add to missing designators list
                MissingArray.Add('"' + JSONEscapeString(Designator) + '"');
            end;
        end;

        // End transaction
        PCBServer.PostProcess;

        // Update PCB document
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        // Create result JSON
        AddJSONInteger(ResultProps, 'moved_count', MovedCount);

        // Add missing designators array
        if (MissingArray.Count > 0) then
            ResultProps.Add(BuildJSONArray(MissingArray, 'missing_designators'))
        else
            ResultProps.Add('"missing_designators": []');

        // Build final JSON
        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
        MissingArray.Free;
    end;
end;

function JoinPadCornerRadius(Pad: IPCB_Pad): TCoord;
var
    Radius: TCoord;
    XSize : TCoord;
    YSize : TCoord;
begin
    Result := 0;
    if Pad = Nil then
        Exit;

    XSize := Pad.XSizeOnLayer[Pad.Layer];
    YSize := Pad.YSizeOnLayer[Pad.Layer];
    if (XSize <= 0) or (YSize <= 0) then
        Exit;

    if Pad.ShapeOnLayer[Pad.Layer] = eRoundedRectangular then
    begin
        Radius := Pad.CornerRadius(Pad.Layer);
        if Radius <= 0 then
            Radius := Min(XSize, YSize) div 4;
        if Radius > (XSize div 2) then
            Radius := XSize div 2;
        if Radius > (YSize div 2) then
            Radius := YSize div 2;
        Result := Radius;
    end;
end;

function AddJoinCustomPadContourTrack(Board: IPCB_Board; Footprint: IPCB_LibComponent; Layer: TLayer; X1, Y1, X2, Y2: TCoord; LineWidth: TCoord; TempObjects: TObjectList): Boolean;
var
    Track: IPCB_Track;
begin
    Result := False;

    if ((Board = Nil) and (Footprint = Nil)) or ((X1 = X2) and (Y1 = Y2)) then
        Exit;

    Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    if Track = Nil then
        Exit;

    Track.Layer := Layer;
    Track.X1 := X1;
    Track.Y1 := Y1;
    Track.X2 := X2;
    Track.Y2 := Y2;
    Track.Width := LineWidth;

    if Board <> Nil then
    begin
        PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
        Board.AddPCBObject(Track);
        PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
    end
    else
    begin
        Footprint.AddPCBObject(Track);
        PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);
    end;
    Track.Selected := True;
    TempObjects.Add(Track);
    Result := True;
end;

function AddJoinCustomPadContourArc(Board: IPCB_Board; Footprint: IPCB_LibComponent; Layer: TLayer; XCenter, YCenter, Radius: TCoord; StartAngle, EndAngle: Double; LineWidth: TCoord; TempObjects: TObjectList): Boolean;
var
    Arc: IPCB_Arc;
begin
    Result := False;

    if ((Board = Nil) and (Footprint = Nil)) or (Radius <= 0) then
        Exit;

    Arc := PCBServer.PCBObjectFactory(eArcObject, eNoDimension, eCreate_Default);
    if Arc = Nil then
        Exit;

    Arc.Layer := Layer;
    Arc.XCenter := XCenter;
    Arc.YCenter := YCenter;
    Arc.Radius := Radius;
    Arc.StartAngle := StartAngle;
    Arc.EndAngle := EndAngle;
    Arc.LineWidth := LineWidth;

    if Board <> Nil then
    begin
        PCBServer.SendMessageToRobots(Arc.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
        Board.AddPCBObject(Arc);
        PCBServer.SendMessageToRobots(Arc.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
    end
    else
    begin
        Footprint.AddPCBObject(Arc);
        PCBServer.SendMessageToRobots(Arc.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);
    end;
    Arc.Selected := True;
    TempObjects.Add(Arc);
    Result := True;
end;

function AddJoinSourceRoundedPad(Board: IPCB_Board; PadName: String; XMM, YMM, WMM, HMM: Double): IPCB_Pad;
begin
    Result := Nil;

    if Board = Nil then
        Exit;

    Result := PCBServer.PCBObjectFactory(ePadObject, eNoDimension, eCreate_Default);
    if Result = Nil then
        Exit;

    Result.Name := PadName;
    Result.Mode := ePadMode_Simple;
    Result.HoleSize := 0;
    Result.X := Board.XOrigin + MMsToCoord(XMM);
    Result.Y := Board.YOrigin + MMsToCoord(YMM);
    Result.Layer := eTopLayer;
    Result.TopXSize := MMsToCoord(WMM);
    Result.TopYSize := MMsToCoord(HMM);
    Result.TopShape := eRoundedRectangular;

    PCBServer.SendMessageToRobots(Result.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
    Board.AddPCBObject(Result);
    PCBServer.SendMessageToRobots(Result.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
end;

function IsRightStepPadJoinCandidate(MainPad, ExtensionPad: IPCB_Pad): Boolean;
var
    Layer: TLayer;
    MainXSize, MainYSize, ExtensionXSize, ExtensionYSize : TCoord;
    ML, MR, MB, MT, EL, ER, EB, ET : TCoord;
    Tolerance : TCoord;
begin
    Result := False;

    if (MainPad = Nil) or (ExtensionPad = Nil) then
        Exit;

    Layer := MainPad.Layer;
    if ExtensionPad.Layer <> Layer then
        Exit;

    MainXSize := MainPad.XSizeOnLayer[Layer];
    MainYSize := MainPad.YSizeOnLayer[Layer];
    ExtensionXSize := ExtensionPad.XSizeOnLayer[Layer];
    ExtensionYSize := ExtensionPad.YSizeOnLayer[Layer];

    ML := MainPad.X - (MainXSize div 2);
    MR := MainPad.X + (MainXSize div 2);
    MB := MainPad.Y - (MainYSize div 2);
    MT := MainPad.Y + (MainYSize div 2);
    EL := ExtensionPad.X - (ExtensionXSize div 2);
    ER := ExtensionPad.X + (ExtensionXSize div 2);
    EB := ExtensionPad.Y - (ExtensionYSize div 2);
    ET := ExtensionPad.Y + (ExtensionYSize div 2);

    Tolerance := MMsToCoord(0.002);
    Result := ((ER > MR + Tolerance) and (EL < MR + Tolerance) and
               (ET < MT - Tolerance) and (EB > MB + Tolerance));
end;

function AddRightStepCustomPadContour(Board: IPCB_Board; Footprint: IPCB_LibComponent; MainPad, ExtensionPad: IPCB_Pad; TempObjects: TObjectList): Integer;
var
    Layer     : TLayer;
    LineWidth : TCoord;
    MainXSize, MainYSize, ExtensionXSize, ExtensionYSize : TCoord;
    ML, MR, MB, MT, EL, ER, EB, ET : TCoord;
    MainR, ExtensionR : TCoord;
begin
    Result := 0;

    if (Footprint = Nil) or (MainPad = Nil) or (ExtensionPad = Nil) then
        Exit;

    if not IsRightStepPadJoinCandidate(MainPad, ExtensionPad) then
        Exit;

    Layer := MainPad.Layer;
    MainXSize := MainPad.XSizeOnLayer[Layer];
    MainYSize := MainPad.YSizeOnLayer[Layer];
    ExtensionXSize := ExtensionPad.XSizeOnLayer[Layer];
    ExtensionYSize := ExtensionPad.YSizeOnLayer[Layer];

    ML := MainPad.X - (MainXSize div 2);
    MR := MainPad.X + (MainXSize div 2);
    MB := MainPad.Y - (MainYSize div 2);
    MT := MainPad.Y + (MainYSize div 2);
    EL := ExtensionPad.X - (ExtensionXSize div 2);
    ER := ExtensionPad.X + (ExtensionXSize div 2);
    EB := ExtensionPad.Y - (ExtensionYSize div 2);
    ET := ExtensionPad.Y + (ExtensionYSize div 2);

    MainR := JoinPadCornerRadius(MainPad);
    ExtensionR := JoinPadCornerRadius(ExtensionPad);
    LineWidth := MMsToCoord(0.001);
    if LineWidth <= 0 then
        LineWidth := 1;

    if AddJoinCustomPadContourTrack(Board, Footprint, Layer, ML + MainR, MT, MR - MainR, MT, LineWidth, TempObjects) then Result := Result + 1;
    if AddJoinCustomPadContourArc(Board, Footprint, Layer, MR - MainR, MT - MainR, MainR, 0, 90, LineWidth, TempObjects) then Result := Result + 1;
    if AddJoinCustomPadContourTrack(Board, Footprint, Layer, MR, MT - MainR, MR, ET, LineWidth, TempObjects) then Result := Result + 1;
    if AddJoinCustomPadContourTrack(Board, Footprint, Layer, MR, ET, ER - ExtensionR, ET, LineWidth, TempObjects) then Result := Result + 1;
    if AddJoinCustomPadContourArc(Board, Footprint, Layer, ER - ExtensionR, ET - ExtensionR, ExtensionR, 0, 90, LineWidth, TempObjects) then Result := Result + 1;
    if AddJoinCustomPadContourTrack(Board, Footprint, Layer, ER, ET - ExtensionR, ER, EB + ExtensionR, LineWidth, TempObjects) then Result := Result + 1;
    if AddJoinCustomPadContourArc(Board, Footprint, Layer, ER - ExtensionR, EB + ExtensionR, ExtensionR, 270, 0, LineWidth, TempObjects) then Result := Result + 1;
    if AddJoinCustomPadContourTrack(Board, Footprint, Layer, ER - ExtensionR, EB, MR, EB, LineWidth, TempObjects) then Result := Result + 1;
    if AddJoinCustomPadContourTrack(Board, Footprint, Layer, MR, EB, MR, MB + MainR, LineWidth, TempObjects) then Result := Result + 1;
    if AddJoinCustomPadContourArc(Board, Footprint, Layer, MR - MainR, MB + MainR, MainR, 270, 0, LineWidth, TempObjects) then Result := Result + 1;
    if AddJoinCustomPadContourTrack(Board, Footprint, Layer, MR - MainR, MB, ML + MainR, MB, LineWidth, TempObjects) then Result := Result + 1;
    if AddJoinCustomPadContourArc(Board, Footprint, Layer, ML + MainR, MB + MainR, MainR, 180, 270, LineWidth, TempObjects) then Result := Result + 1;
    if AddJoinCustomPadContourTrack(Board, Footprint, Layer, ML, MB + MainR, ML, MT - MainR, LineWidth, TempObjects) then Result := Result + 1;
    if AddJoinCustomPadContourArc(Board, Footprint, Layer, ML + MainR, MT - MainR, MainR, 90, 180, LineWidth, TempObjects) then Result := Result + 1;
end;

procedure SelectOnlyJoinObjects(AnchorPad: IPCB_Pad; TempObjects: TObjectList);
var
    i        : Integer;
    Primitive: IPCB_Primitive;
begin
    Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);

    if AnchorPad <> Nil then
        AnchorPad.Selected := True;

    for i := 0 to TempObjects.Count - 1 do
        if TempObjects[i] <> Nil then
        begin
            Primitive := TempObjects[i];
            Primitive.Selected := True;
        end;
end;

procedure DeleteJoinObjects(ObjectsToDelete: TObjectList);
var
    i        : Integer;
    Primitive: IPCB_Primitive;
begin
    Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);

    for i := 0 to ObjectsToDelete.Count - 1 do
        if ObjectsToDelete[i] <> Nil then
        begin
            Primitive := ObjectsToDelete[i];
            Primitive.Selected := True;
        end;

    if ObjectsToDelete.Count > 0 then
        Client.SendMessage('PCB:DeleteObjects', 'Object=SELECTED', 255, Client.CurrentView);

    Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);
end;

function IsJoinTemporaryOutlinePrimitive(Primitive: IPCB_Primitive; Layer: TLayer): Boolean;
var
    Track    : IPCB_Track;
    Arc      : IPCB_Arc;
    LineWidth: TCoord;
begin
    Result := False;

    if Primitive = Nil then
        Exit;
    if Primitive.Layer <> Layer then
        Exit;

    LineWidth := MMsToCoord(0.001);
    if LineWidth <= 0 then
        LineWidth := 1;

    if Primitive.ObjectId = eTrackObject then
    begin
        Track := Primitive;
        Result := Track.Width = LineWidth;
    end
    else if Primitive.ObjectId = eArcObject then
    begin
        Arc := Primitive;
        Result := Arc.LineWidth = LineWidth;
    end;
end;

function CollectJoinTemporaryOutlines(Footprint: IPCB_LibComponent; Layer: TLayer; ObjectsToRemove: TObjectList): Integer;
var
    PrimitiveIterator : IPCB_GroupIterator;
    Primitive         : IPCB_Primitive;
begin
    Result := 0;

    if (Footprint = Nil) or (ObjectsToRemove = Nil) then
        Exit;

    PrimitiveIterator := Footprint.GroupIterator_Create;
    if PrimitiveIterator = Nil then
        Exit;

    try
        PrimitiveIterator.SetState_FilterAll;
        Primitive := PrimitiveIterator.FirstPCBObject;
        while Primitive <> Nil do
        begin
            if IsJoinTemporaryOutlinePrimitive(Primitive, Layer) then
            begin
                ObjectsToRemove.Add(Primitive);
                Result := Result + 1;
            end;

            Primitive := PrimitiveIterator.NextPCBObject;
        end;
    finally
        Footprint.GroupIterator_Destroy(PrimitiveIterator);
    end;
end;

function JoinSelectedPadsAsCustomPadShape(JoinAction: String): String;
var
    PcbLib            : IPCB_Library;
    Board             : IPCB_Board;
    Footprint         : IPCB_LibComponent;
    PrimitiveIterator : IPCB_GroupIterator;
    Primitive         : IPCB_Primitive;
    Pad               : IPCB_Pad;
    SelectedPads      : TObjectList;
    AllPads           : TObjectList;
    TempObjects       : TObjectList;
    ResultProps       : TStringList;
    OutputLines       : TStringList;
    AnchorPad         : IPCB_Pad;
    ExtensionPad      : IPCB_Pad;
    PadArea           : Double;
    AnchorArea        : Double;
    CandidateArea     : Double;
    CandidateCount    : Integer;
    CandidateAnchor   : IPCB_Pad;
    CandidateExtension: IPCB_Pad;
    SelectionSource   : String;
    OutlineObjects    : Integer;
    DeletedOutlines   : Integer;
    DeletedPads       : Integer;
    RebuiltPads       : Integer;
    i                 : Integer;
    ServerDocument    : IServerDocument;
    CurrentView       : IServerDocumentView;
begin
    JoinAction := UpperCase(Trim(JoinAction));
    if JoinAction = '' then
        JoinAction := 'FULL';

    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    Board := PcbLib.Board;
    Footprint := PcbLib.CurrentComponent;
    if Footprint = Nil then
    begin
        Result := '{"success": false, "error": "No active footprint in the PCB library."}';
        Exit;
    end;

    ResultProps := TStringList.Create;
    try
        if JoinAction = 'CONVERT' then
        begin
            Client.SendMessage('PCB:CustomPadShape', 'Action=Convert|Object=Track', 255, Client.CurrentView);
            AddJSONBoolean(ResultProps, 'success', True);
            AddJSONProperty(ResultProps, 'action', 'CONVERT');
            AddJSONProperty(ResultProps, 'command', 'PCB:CustomPadShape');
            AddJSONProperty(ResultProps, 'parameters', 'Action=Convert|Object=Track');
            AddJSONBoolean(ResultProps, 'conversion_command_sent', True);
            OutputLines := TStringList.Create;
            try
                OutputLines.Text := BuildJSONObject(ResultProps);
                Result := OutputLines.Text;
            finally
                OutputLines.Free;
            end;
            Exit;
        end;
    finally
        ResultProps.Free;
    end;

    SelectedPads := TObjectList.Create;
    SelectedPads.OwnsObjects := False;
    AllPads := TObjectList.Create;
    AllPads.OwnsObjects := False;
    TempObjects := TObjectList.Create;
    TempObjects.OwnsObjects := False;
    ResultProps := TStringList.Create;

    try
        PrimitiveIterator := Footprint.GroupIterator_Create;
        if PrimitiveIterator = Nil then
        begin
            Result := '{"success": false, "error": "Failed to create footprint primitive iterator."}';
            Exit;
        end;

        try
            PrimitiveIterator.AddFilter_ObjectSet(MkSet(ePadObject));
            Primitive := PrimitiveIterator.FirstPCBObject;
            while Primitive <> Nil do
            begin
                AllPads.Add(Primitive);
                if Primitive.Selected then
                    SelectedPads.Add(Primitive);
                Primitive := PrimitiveIterator.NextPCBObject;
            end;
        finally
            Footprint.GroupIterator_Destroy(PrimitiveIterator);
        end;

        if JoinAction = 'REBUILD_SOURCE' then
        begin
            DeletedOutlines := CollectJoinTemporaryOutlines(Footprint, eTopLayer, TempObjects);
            DeletedPads := 0;
            for i := 0 to AllPads.Count - 1 do
            begin
                Pad := AllPads[i];
                if (Pad <> Nil) and (Pad.Layer = eTopLayer) and (Pad.Name = '3') then
                begin
                    TempObjects.Add(Pad);
                    DeletedPads := DeletedPads + 1;
                end;
            end;

            if TempObjects.Count > 0 then
                DeleteJoinObjects(TempObjects);
            TempObjects.Clear;

            RebuiltPads := 0;
            PCBServer.PreProcess;
            try
                if AddJoinSourceRoundedPad(Board, '3', 0.2, 0.0, 0.4, 0.8) <> Nil then
                    RebuiltPads := RebuiltPads + 1;
                if AddJoinSourceRoundedPad(Board, '3', 0.5, 0.0, 0.4, 0.35) <> Nil then
                    RebuiltPads := RebuiltPads + 1;
            finally
                PCBServer.PostProcess;
            end;

            if Board <> Nil then
                Board.ViewManager_FullUpdate;
            Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

            CurrentView := Client.GetCurrentView;
            if CurrentView <> Nil then
            begin
                ServerDocument := CurrentView.OwnerDocument;
                if ServerDocument <> Nil then
                    ServerDocument.Modified := True;
            end;

            AddJSONBoolean(ResultProps, 'success', RebuiltPads = 2);
            AddJSONProperty(ResultProps, 'action', JoinAction);
            AddJSONProperty(ResultProps, 'footprint', Footprint.Name);
            AddJSONProperty(ResultProps, 'pad_name', '3');
            AddJSONInteger(ResultProps, 'deleted_pad3_primitives', DeletedPads);
            AddJSONInteger(ResultProps, 'temporary_outline_objects_deleted', DeletedOutlines);
            AddJSONInteger(ResultProps, 'rebuilt_source_pads', RebuiltPads);
            AddJSONBoolean(ResultProps, 'document_saved', False);
            AddJSONBoolean(ResultProps, 'document_dirty', True);

            OutputLines := TStringList.Create;
            try
                OutputLines.Text := BuildJSONObject(ResultProps);
                Result := OutputLines.Text;
            finally
                OutputLines.Free;
            end;
            Exit;
        end;

        SelectionSource := 'selected';
        if (SelectedPads.Count = 0) or ((JoinAction = 'CLEANUP') and (SelectedPads.Count <> 2)) then
        begin
            if SelectedPads.Count <> 0 then
                SelectedPads.Clear;
            CandidateCount := 0;
            CandidateAnchor := Nil;
            CandidateExtension := Nil;
            for i := 0 to AllPads.Count - 2 do
            begin
                AnchorPad := AllPads[i];
                for OutlineObjects := i + 1 to AllPads.Count - 1 do
                begin
                    ExtensionPad := AllPads[OutlineObjects];
                    if (AnchorPad.Name = ExtensionPad.Name) and (AnchorPad.Layer = ExtensionPad.Layer) then
                    begin
                        AnchorArea := CoordToMMs(AnchorPad.XSizeOnLayer[AnchorPad.Layer]) * CoordToMMs(AnchorPad.YSizeOnLayer[AnchorPad.Layer]);
                        CandidateArea := CoordToMMs(ExtensionPad.XSizeOnLayer[ExtensionPad.Layer]) * CoordToMMs(ExtensionPad.YSizeOnLayer[ExtensionPad.Layer]);
                        if CandidateArea > AnchorArea then
                        begin
                            Pad := AnchorPad;
                            AnchorPad := ExtensionPad;
                            ExtensionPad := Pad;
                        end;

                        if IsRightStepPadJoinCandidate(AnchorPad, ExtensionPad) then
                        begin
                            CandidateCount := CandidateCount + 1;
                            CandidateAnchor := AnchorPad;
                            CandidateExtension := ExtensionPad;
                        end;
                    end;
                end;
            end;

            if CandidateCount = 1 then
            begin
                SelectedPads.Add(CandidateAnchor);
                SelectedPads.Add(CandidateExtension);
                SelectionSource := 'auto_duplicate_same_name';
            end
            else if JoinAction = 'CLEANUP' then
            begin
                CandidateCount := 0;
                CandidateAnchor := Nil;
                CandidateExtension := Nil;
                for i := 0 to AllPads.Count - 2 do
                begin
                    AnchorPad := AllPads[i];
                    for OutlineObjects := i + 1 to AllPads.Count - 1 do
                    begin
                        ExtensionPad := AllPads[OutlineObjects];
                        if (AnchorPad.Name = ExtensionPad.Name) and (AnchorPad.Layer = ExtensionPad.Layer) then
                        begin
                            AnchorArea := CoordToMMs(AnchorPad.XSizeOnLayer[AnchorPad.Layer]) * CoordToMMs(AnchorPad.YSizeOnLayer[AnchorPad.Layer]);
                            CandidateArea := CoordToMMs(ExtensionPad.XSizeOnLayer[ExtensionPad.Layer]) * CoordToMMs(ExtensionPad.YSizeOnLayer[ExtensionPad.Layer]);
                            if CandidateArea > AnchorArea then
                            begin
                                Pad := AnchorPad;
                                AnchorPad := ExtensionPad;
                                ExtensionPad := Pad;
                            end;

                            CandidateCount := CandidateCount + 1;
                            CandidateAnchor := AnchorPad;
                            CandidateExtension := ExtensionPad;
                        end;
                    end;
                end;

                if CandidateCount = 1 then
                begin
                    SelectedPads.Add(CandidateAnchor);
                    SelectedPads.Add(CandidateExtension);
                    SelectionSource := 'cleanup_duplicate_same_name_largest_pad';
                end;
            end;
        end;

        if SelectedPads.Count <> 2 then
        begin
            AddJSONBoolean(ResultProps, 'success', False);
            AddJSONProperty(ResultProps, 'error', 'Select exactly two same-name rounded top-layer pads before running PCB_LIB_JOIN_SELECTED_PADS_CUSTOM, or leave exactly one supported duplicate same-name stepped pair in the active footprint.');
            AddJSONProperty(ResultProps, 'cleanup_fallback', 'cleanup_duplicate_same_name_largest_pad');
            AddJSONProperty(ResultProps, 'join_action', JoinAction);
            AddJSONInteger(ResultProps, 'all_pads', AllPads.Count);
            AddJSONInteger(ResultProps, 'selected_pads', SelectedPads.Count);
        end
        else
        begin
            AnchorPad := SelectedPads[0];
            ExtensionPad := SelectedPads[1];
            AnchorArea := CoordToMMs(AnchorPad.XSizeOnLayer[AnchorPad.Layer]) * CoordToMMs(AnchorPad.YSizeOnLayer[AnchorPad.Layer]);
            Pad := ExtensionPad;
            PadArea := CoordToMMs(Pad.XSizeOnLayer[Pad.Layer]) * CoordToMMs(Pad.YSizeOnLayer[Pad.Layer]);
            if PadArea > AnchorArea then
            begin
                AnchorPad := Pad;
                ExtensionPad := SelectedPads[0];
                AnchorArea := PadArea;
            end;

            if (AnchorPad.Name <> ExtensionPad.Name) or (AnchorPad.Layer <> ExtensionPad.Layer) then
            begin
                AddJSONBoolean(ResultProps, 'success', False);
                AddJSONProperty(ResultProps, 'error', 'Selected pads must have the same pad name and layer.');
            end
            else
            begin
                if JoinAction = 'CLEANUP' then
                begin
                    DeletedOutlines := 0;
                    DeletedPads := 0;
                    DeletedOutlines := CollectJoinTemporaryOutlines(Footprint, AnchorPad.Layer, TempObjects);
                    TempObjects.Add(ExtensionPad);
                    DeletedPads := 1;
                    DeleteJoinObjects(TempObjects);

                    if Board <> Nil then
                        Board.ViewManager_FullUpdate;
                    Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

                    CurrentView := Client.GetCurrentView;
                    if CurrentView <> Nil then
                    begin
                        ServerDocument := CurrentView.OwnerDocument;
                        if ServerDocument <> Nil then
                            ServerDocument.Modified := True;
                    end;

                    AddJSONBoolean(ResultProps, 'success', True);
                    AddJSONProperty(ResultProps, 'action', JoinAction);
                    AddJSONProperty(ResultProps, 'footprint', Footprint.Name);
                    AddJSONProperty(ResultProps, 'pad_name', AnchorPad.Name);
                    AddJSONProperty(ResultProps, 'selection_source', SelectionSource);
                    AddJSONInteger(ResultProps, 'deleted_source_pads', DeletedPads);
                    AddJSONInteger(ResultProps, 'temporary_outline_objects_deleted', DeletedOutlines);
                    AddJSONBoolean(ResultProps, 'document_saved', False);
                    AddJSONBoolean(ResultProps, 'document_dirty', True);
                end
                else
                begin
                    DeletedOutlines := CollectJoinTemporaryOutlines(Footprint, AnchorPad.Layer, TempObjects);
                    if DeletedOutlines > 0 then
                        DeleteJoinObjects(TempObjects);
                    TempObjects.Clear;

                    PCBServer.PreProcess;
                    try
                        OutlineObjects := AddRightStepCustomPadContour(Board, Footprint, AnchorPad, ExtensionPad, TempObjects);
                    finally
                        PCBServer.PostProcess;
                    end;

                    if OutlineObjects <= 0 then
                    begin
                        AddJSONBoolean(ResultProps, 'success', False);
                        AddJSONProperty(ResultProps, 'error', 'Selected pad geometry is not a supported right-side stepped rounded-rectangle join.');
                        AddJSONInteger(ResultProps, 'stale_temporary_outline_objects_deleted', DeletedOutlines);
                    end
                    else
                    begin
                        if Board <> Nil then
                            Board.ViewManager_FullUpdate;
                        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

                        CurrentView := Client.GetCurrentView;
                        if CurrentView <> Nil then
                        begin
                            ServerDocument := CurrentView.OwnerDocument;
                            if ServerDocument <> Nil then
                                ServerDocument.Modified := True;
                        end;

                        AddJSONBoolean(ResultProps, 'success', True);
                        AddJSONProperty(ResultProps, 'action', JoinAction);
                        AddJSONProperty(ResultProps, 'footprint', Footprint.Name);
                        AddJSONProperty(ResultProps, 'pad_name', AnchorPad.Name);
                        AddJSONProperty(ResultProps, 'selection_source', SelectionSource);
                        AddJSONInteger(ResultProps, 'selected_pads_prepared', SelectedPads.Count);
                        AddJSONInteger(ResultProps, 'temporary_outline_objects', TempObjects.Count);
                        AddJSONInteger(ResultProps, 'stale_temporary_outline_objects_deleted', DeletedOutlines);
                        AddJSONBoolean(ResultProps, 'pad_and_outline_selected_for_custom_conversion', True);

                        SelectOnlyJoinObjects(AnchorPad, TempObjects);
                        if JoinAction = 'FULL' then
                        begin
                            Client.SendMessage('PCB:CustomPadShape', 'Action=Convert|Object=Track', 255, Client.CurrentView);
                            AddJSONBoolean(ResultProps, 'conversion_command_sent', True);
                            AddJSONProperty(ResultProps, 'next_verification', 'Read back primitives, then run PCB_LIB_JOIN_SELECTED_PADS_CUSTOM_CLEANUP only after conversion is visible.');
                        end
                        else
                        begin
                            AddJSONBoolean(ResultProps, 'conversion_command_sent', False);
                            AddJSONProperty(ResultProps, 'next_step', 'Run PCB_LIB_JOIN_SELECTED_PADS_CUSTOM_CONVERT with this selection still active.');
                        end;
                        AddJSONBoolean(ResultProps, 'document_saved', False);
                        AddJSONBoolean(ResultProps, 'document_dirty', True);
                    end;
                end;
            end;
        end;

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
        TempObjects.Free;
        AllPads.Free;
        SelectedPads.Free;
    end;
end;

function MovePCBLibraryMechanicalLayers(ExcludeFootprints: TStringList; LayerMoves: TStringList): String;
var
    PcbLib              : IPCB_Library;
    Board               : IPCB_Board;
    FootprintIterator   : IPCB_LibraryIterator;
    Footprint           : IPCB_LibComponent;
    PrimitiveIterator   : IPCB_GroupIterator;
    Primitive           : IPCB_Primitive;
    ResultProps         : TStringList;
    MoveResultArray     : TStringList;
    ModifiedFootprints  : TStringList;
    SkippedFootprints   : TStringList;
    InvalidMoves        : TStringList;
    ParsedMoves         : TStringList;
    MoveCounts          : TStringList;
    MoveProps           : TStringList;
    OutputLines         : TStringList;
    FootprintName       : String;
    NormalizedMove      : String;
    FootprintsSeen      : Integer;
    FootprintsProcessed : Integer;
    FootprintsModified  : Integer;
    PrimitivesSeen      : Integer;
    PrimitivesMoved     : Integer;
    FootprintPrimitivesMoved : Integer;
    SourceLayerNumber   : Integer;
    DestinationLayerNumber : Integer;
    MoveIndex           : Integer;
    i                   : Integer;
    ProjectionLayerNumber : Integer;
    ProjectionLineWidthMM : Double;
    RemoveExistingProjection : Boolean;
    ReferenceFootprintName : String;
    TextDumpFootprintName : String;
    PrimitiveDumpFootprintName : String;
    DescriptionDumpFootprintName : String;
    OpenLibraryPath    : String;
    StatsDumpFootprintName : String;
    SchFootprintLibraryName : String;
    SchFootprintLibraryPath : String;
    SetDescriptionFootprintNames : TStringList;
    SetDescriptionTexts : TStringList;
    BatchCreateDataFileName : String;
    BatchCreateSkipExisting : Boolean;
    CleanPadsOverlayTargetNameContains : String;
    CleanPadsOverlayPadNamePrefix : String;
    CleanPadsOverlayLayerName : String;
    JoinSelectedPadsAction : String;
    Delete3DBodyFootprintName : String;
    Batch3DBodyImportDataFileName : String;
    Batch3DBodyImportSkipExisting : Boolean;
    Batch3DBodySetPlacementDataFileName : String;
    Batch3DBodySetIdentifierDataFileName : String;
    Import3DBodyFootprintName : String;
    Import3DBodyStepPath : String;
    Import3DBodyLocalXMM : Double;
    Import3DBodyLocalYMM : Double;
    Import3DBodyRotX : Double;
    Import3DBodyRotY : Double;
    Import3DBodyRotZ : Double;
    Import3DBodyModelZMM : Double;
    Import3DBodyStandoffMM : Double;
    Import3DBodyOverallHeightMM : Double;
    Set3DBodyHeightsFootprintName : String;
    Set3DBodyHeightsStandoffMM : Double;
    Set3DBodyHeightsOverallHeightMM : Double;
    Set3DBodyIdentifierFootprintName : String;
    Set3DBodyIdentifierText : String;
    Fix3DBodyOriginFootprintName : String;
    ParamsDump3DBodyFootprintName : String;
    Set3DBodyPlacementFootprintName : String;
    Set3DBodyPlacementLocalXMM : Double;
    Set3DBodyPlacementLocalYMM : Double;
    Set3DBodyPlacementRotX : Double;
    Set3DBodyPlacementRotY : Double;
    Set3DBodyPlacementRotZ : Double;
    Set3DBodyPlacementModelZMM : Double;
    Set3DBodyPlacementStandoffMM : Double;
    Set3DBodyPlacementOverallHeightMM : Double;
    Set3DBodyColorRed : Integer;
    Set3DBodyColorGreen : Integer;
    Set3DBodyColorBlue : Integer;
begin
    if Find3DBodyDumpCommand(LayerMoves) then
    begin
        Result := DumpPCBLibrary3DBodies(ExcludeFootprints);
        Exit;
    end;

    if FindPCBUndoCommand(LayerMoves) then
    begin
        Result := RunPCBUndoCommand;
        Exit;
    end;

    if FindPCBCancelCommand(LayerMoves) then
    begin
        Result := RunPCBCancelCommand;
        Exit;
    end;

    if FindPCBPostProcessCommand(LayerMoves) then
    begin
        Result := RunPCBPostProcessCommand;
        Exit;
    end;

    if FindSaveDocumentCommand(LayerMoves) then
    begin
        Result := RunSaveDocumentCommand;
        Exit;
    end;

    if Find3DBodyTrackCountCommand(LayerMoves, ProjectionLayerNumber, ProjectionLineWidthMM) then
    begin
        Result := CountPCBLibraryProjectionTracks(ExcludeFootprints, ProjectionLayerNumber, ProjectionLineWidthMM);
        Exit;
    end;

    if Find3DBodyTrackSelectCommand(LayerMoves, ProjectionLayerNumber, ProjectionLineWidthMM) then
    begin
        Result := SelectPCBLibraryProjectionTracksForEditor(ExcludeFootprints, ProjectionLayerNumber, ProjectionLineWidthMM);
        Exit;
    end;

    if Find3DBodySelectedDumpCommand(LayerMoves, ProjectionLayerNumber, ProjectionLineWidthMM) then
    begin
        Result := DumpSelectedProjectionPrimitives(ExcludeFootprints, ProjectionLayerNumber, ProjectionLineWidthMM);
        Exit;
    end;

    if Find3DBodyTextDumpCommand(LayerMoves, ProjectionLayerNumber, TextDumpFootprintName) then
    begin
        Result := DumpPCBLibraryProjectionTextPlacement(ProjectionLayerNumber, TextDumpFootprintName);
        Exit;
    end;

    if FindFootprintPrimitiveDumpCommand(LayerMoves, PrimitiveDumpFootprintName) then
    begin
        Result := DumpPCBLibraryFootprintPrimitives(PrimitiveDumpFootprintName);
        Exit;
    end;

    if FindPCBLibraryDescriptionDumpCommand(LayerMoves, DescriptionDumpFootprintName) then
    begin
        Result := DumpPCBLibraryFootprintDescriptions(DescriptionDumpFootprintName);
        Exit;
    end;

    if FindPCBLibraryOpenCommand(LayerMoves, OpenLibraryPath) then
    begin
        Result := OpenPCBLibraryByPath(OpenLibraryPath);
        Exit;
    end;

    if FindSchLibrarySetFootprintLibraryCommand(LayerMoves, SchFootprintLibraryName, SchFootprintLibraryPath) then
    begin
        Result := SetSchLibraryFootprintLibraryName(SchFootprintLibraryName, SchFootprintLibraryPath);
        Exit;
    end;

    if FindPCBLibraryStatsDumpCommand(LayerMoves, StatsDumpFootprintName) then
    begin
        Result := DumpPCBLibraryFootprintStats(StatsDumpFootprintName);
        Exit;
    end;

    SetDescriptionFootprintNames := TStringList.Create;
    SetDescriptionTexts := TStringList.Create;
    try
        if FindPCBLibrarySetDescriptionCommands(LayerMoves, SetDescriptionFootprintNames, SetDescriptionTexts) then
        begin
            Result := SetPCBLibraryFootprintDescriptions(SetDescriptionFootprintNames, SetDescriptionTexts);
            Exit;
        end;
    finally
        SetDescriptionTexts.Free;
        SetDescriptionFootprintNames.Free;
    end;

    if FindPCBLibraryBatchCreateCommand(LayerMoves, BatchCreateDataFileName, BatchCreateSkipExisting) then
    begin
        Result := CreatePCBLibraryBatchFootprints(BatchCreateDataFileName, BatchCreateSkipExisting);
        Exit;
    end;

    if FindPCBLibraryCleanPadsOverlayCommand(LayerMoves, CleanPadsOverlayTargetNameContains, CleanPadsOverlayPadNamePrefix, CleanPadsOverlayLayerName) then
    begin
        Result := CleanPCBLibraryPadsAndOverlayWithEditor(ExcludeFootprints, CleanPadsOverlayTargetNameContains, CleanPadsOverlayPadNamePrefix, CleanPadsOverlayLayerName);
        Exit;
    end;

    if FindPCBLibraryJoinSelectedPadsCustomCommand(LayerMoves, JoinSelectedPadsAction) then
    begin
        Result := JoinSelectedPadsAsCustomPadShape(JoinSelectedPadsAction);
        Exit;
    end;

    if Find3DBodyEditorDeleteCommand(LayerMoves, Delete3DBodyFootprintName) then
    begin
        Result := DeletePCBLibrary3DBodiesWithEditor(ExcludeFootprints, Delete3DBodyFootprintName);
        Exit;
    end;

    if Find3DBodyBatchImportCommand(LayerMoves, Batch3DBodyImportDataFileName, Batch3DBodyImportSkipExisting) then
    begin
        Result := Import3DBodiesFromBatchFile(Batch3DBodyImportDataFileName, Batch3DBodyImportSkipExisting);
        Exit;
    end;

    if Find3DBodyBatchSetPlacementCommand(LayerMoves, Batch3DBodySetPlacementDataFileName) then
    begin
        Result := SetPCBLibrary3DBodyPlacementsFromBatchFile(Batch3DBodySetPlacementDataFileName);
        Exit;
    end;

    if Find3DBodyBatchSetIdentifierCommand(LayerMoves, Batch3DBodySetIdentifierDataFileName) then
    begin
        Result := SetPCBLibrary3DBodyIdentifiersFromBatchFile(Batch3DBodySetIdentifierDataFileName);
        Exit;
    end;

    if Find3DBodyImportCommand(LayerMoves, Import3DBodyFootprintName, Import3DBodyStepPath, Import3DBodyLocalXMM, Import3DBodyLocalYMM, Import3DBodyRotX, Import3DBodyRotY, Import3DBodyRotZ, Import3DBodyModelZMM, Import3DBodyStandoffMM, Import3DBodyOverallHeightMM) then
    begin
        Result := Import3DBodyWithPlacement(Import3DBodyFootprintName, Import3DBodyStepPath, Import3DBodyLocalXMM, Import3DBodyLocalYMM, Import3DBodyRotX, Import3DBodyRotY, Import3DBodyRotZ, Import3DBodyModelZMM, Import3DBodyStandoffMM, Import3DBodyOverallHeightMM);
        Exit;
    end;

    if Find3DBodySetHeightsCommand(LayerMoves, Set3DBodyHeightsFootprintName, Set3DBodyHeightsStandoffMM, Set3DBodyHeightsOverallHeightMM) then
    begin
        Result := SetPCBLibrary3DBodyHeights(Set3DBodyHeightsFootprintName, Set3DBodyHeightsStandoffMM, Set3DBodyHeightsOverallHeightMM);
        Exit;
    end;

    if Find3DBodySetIdentifierCommand(LayerMoves, Set3DBodyIdentifierFootprintName, Set3DBodyIdentifierText) then
    begin
        Result := SetPCBLibrary3DBodyIdentifier(Set3DBodyIdentifierFootprintName, Set3DBodyIdentifierText);
        Exit;
    end;

    if Find3DBodySetPlacementCommand(
        LayerMoves,
        Set3DBodyPlacementFootprintName,
        Set3DBodyPlacementLocalXMM,
        Set3DBodyPlacementLocalYMM,
        Set3DBodyPlacementRotX,
        Set3DBodyPlacementRotY,
        Set3DBodyPlacementRotZ,
        Set3DBodyPlacementModelZMM,
        Set3DBodyPlacementStandoffMM,
        Set3DBodyPlacementOverallHeightMM
    ) then
    begin
        Result := SetPCBLibrary3DBodyPlacement(
            Set3DBodyPlacementFootprintName,
            Set3DBodyPlacementLocalXMM,
            Set3DBodyPlacementLocalYMM,
            Set3DBodyPlacementRotX,
            Set3DBodyPlacementRotY,
            Set3DBodyPlacementRotZ,
            Set3DBodyPlacementModelZMM,
            Set3DBodyPlacementStandoffMM,
            Set3DBodyPlacementOverallHeightMM
        );
        Exit;
    end;

    if Find3DBodyFixOriginOffsetCommand(LayerMoves, Fix3DBodyOriginFootprintName) then
    begin
        Result := FixPCBLibrary3DBodyOriginOffset(Fix3DBodyOriginFootprintName);
        Exit;
    end;

    if Find3DBodyParamsDumpCommand(LayerMoves, ParamsDump3DBodyFootprintName) then
    begin
        Result := Dump3DBodyParametersForFootprint(ParamsDump3DBodyFootprintName);
        Exit;
    end;

    if Find3DBodySetColorCommand(LayerMoves, Set3DBodyColorRed, Set3DBodyColorGreen, Set3DBodyColorBlue) then
    begin
        Result := SetPCBLibrary3DBodyColor(ExcludeFootprints, Set3DBodyColorRed, Set3DBodyColorGreen, Set3DBodyColorBlue);
        Exit;
    end;

    if Find3DBodyTextCommand(LayerMoves, ProjectionLayerNumber, ReferenceFootprintName) then
    begin
        Result := AddPCBLibraryProjectionTexts(ExcludeFootprints, ProjectionLayerNumber, ReferenceFootprintName);
        Exit;
    end;

    if Find3DBodyEditorCleanCommand(LayerMoves, ProjectionLayerNumber, ProjectionLineWidthMM) then
    begin
        Result := CleanPCBLibraryProjectionTracksWithEditor(ExcludeFootprints, ProjectionLayerNumber, ProjectionLineWidthMM);
        Exit;
    end;

    if Find3DBodyStepSilhouetteCommand(LayerMoves, ProjectionLayerNumber, ProjectionLineWidthMM, RemoveExistingProjection) then
    begin
        Result := ProjectPCBLibraryStepSilhouettes(ExcludeFootprints, ProjectionLayerNumber, ProjectionLineWidthMM, RemoveExistingProjection);
        Exit;
    end;

    if Find3DBodyProjectionCommand(LayerMoves, ProjectionLayerNumber, ProjectionLineWidthMM) then
    begin
        Result := ProjectPCBLibrary3DBodyOutlines(ExcludeFootprints, ProjectionLayerNumber, ProjectionLineWidthMM);
        Exit;
    end;

    PcbLib := GetPcbLibSafe(0);
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    Board := PcbLib.Board;
    ResultProps := TStringList.Create;
    MoveResultArray := TStringList.Create;
    ModifiedFootprints := TStringList.Create;
    SkippedFootprints := TStringList.Create;
    InvalidMoves := TStringList.Create;
    ParsedMoves := TStringList.Create;
    MoveCounts := TStringList.Create;
    FootprintsSeen := 0;
    FootprintsProcessed := 0;
    FootprintsModified := 0;
    PrimitivesSeen := 0;
    PrimitivesMoved := 0;

    try
        for i := 0 to LayerMoves.Count - 1 do
        begin
            if ParseMechanicalLayerMove(LayerMoves[i], SourceLayerNumber, DestinationLayerNumber) then
            begin
                NormalizedMove := IntToStr(SourceLayerNumber) + '|' + IntToStr(DestinationLayerNumber);
                if ParsedMoves.IndexOf(NormalizedMove) < 0 then
                begin
                    ParsedMoves.Add(NormalizedMove);
                    MoveCounts.Add('0');
                    EnsureMechanicalLayerEnabled(Board, DestinationLayerNumber);
                end;
            end
            else
            begin
                InvalidMoves.Add('"' + JSONEscapeString(LayerMoves[i]) + '"');
            end;
        end;

        if ParsedMoves.Count = 0 then
        begin
            Result := '{"success": false, "error": "No valid mechanical layer moves provided. Use source|destination, for example 13|1."}';
            Exit;
        end;

        FootprintIterator := PcbLib.LibraryIterator_Create;
        if FootprintIterator = Nil then
        begin
            Result := '{"success": false, "error": "Failed to create PCB library footprint iterator."}';
            Exit;
        end;

        FootprintIterator.SetState_FilterAll;

        PCBServer.PreProcess;
        try
            Footprint := FootprintIterator.FirstPCBObject;
            while Footprint <> Nil do
            begin
                FootprintsSeen := FootprintsSeen + 1;
                FootprintName := Footprint.Name;

                if StringListContainsText(ExcludeFootprints, FootprintName) then
                begin
                    SkippedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                end
                else
                begin
                    FootprintsProcessed := FootprintsProcessed + 1;
                    FootprintPrimitivesMoved := 0;

                    PrimitiveIterator := Footprint.GroupIterator_Create;
                    if PrimitiveIterator <> Nil then
                    begin
                        try
                            PrimitiveIterator.SetState_FilterAll;

                            Primitive := PrimitiveIterator.FirstPCBObject;
                            while Primitive <> Nil do
                            begin
                                PrimitivesSeen := PrimitivesSeen + 1;

                                if FindMechanicalLayerMove(Primitive.Layer, ParsedMoves, SourceLayerNumber, DestinationLayerNumber) then
                                begin
                                    PCBServer.SendMessageToRobots(Primitive.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
                                    Primitive.Layer := ILayer.MechanicalLayer(DestinationLayerNumber);
                                    PCBServer.SendMessageToRobots(Primitive.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);

                                    PrimitivesMoved := PrimitivesMoved + 1;
                                    FootprintPrimitivesMoved := FootprintPrimitivesMoved + 1;

                                    NormalizedMove := IntToStr(SourceLayerNumber) + '|' + IntToStr(DestinationLayerNumber);
                                    MoveIndex := ParsedMoves.IndexOf(NormalizedMove);
                                    if MoveIndex >= 0 then
                                        MoveCounts[MoveIndex] := IntToStr(StrToInt(MoveCounts[MoveIndex]) + 1);
                                end;

                                Primitive := PrimitiveIterator.NextPCBObject;
                            end;
                        finally
                            Footprint.GroupIterator_Destroy(PrimitiveIterator);
                        end;
                    end;

                    if FootprintPrimitivesMoved > 0 then
                    begin
                        FootprintsModified := FootprintsModified + 1;
                        ModifiedFootprints.Add('"' + JSONEscapeString(FootprintName) + '"');
                    end;
                end;

                Footprint := FootprintIterator.NextPCBObject;
            end;
        finally
            PCBServer.PostProcess;
            PcbLib.LibraryIterator_Destroy(FootprintIterator);
        end;

        if Board <> Nil then
            Board.ViewManager_FullUpdate;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        for i := 0 to ParsedMoves.Count - 1 do
        begin
            ParseMechanicalLayerMove(ParsedMoves[i], SourceLayerNumber, DestinationLayerNumber);
            MoveProps := TStringList.Create;
            try
                AddJSONInteger(MoveProps, 'from_mechanical_layer', SourceLayerNumber);
                AddJSONInteger(MoveProps, 'to_mechanical_layer', DestinationLayerNumber);
                AddJSONInteger(MoveProps, 'primitives_moved', StrToInt(MoveCounts[i]));
                MoveResultArray.Add(BuildJSONObject(MoveProps, 1));
            finally
                MoveProps.Free;
            end;
        end;

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONInteger(ResultProps, 'footprints_seen', FootprintsSeen);
        AddJSONInteger(ResultProps, 'footprints_processed', FootprintsProcessed);
        AddJSONInteger(ResultProps, 'footprints_modified', FootprintsModified);
        AddJSONInteger(ResultProps, 'primitives_seen', PrimitivesSeen);
        AddJSONInteger(ResultProps, 'primitives_moved', PrimitivesMoved);
        ResultProps.Add(BuildJSONArray(MoveResultArray, 'moves'));
        ResultProps.Add(BuildJSONArray(SkippedFootprints, 'skipped_footprints'));
        ResultProps.Add(BuildJSONArray(ModifiedFootprints, 'modified_footprints'));
        ResultProps.Add(BuildJSONArray(InvalidMoves, 'invalid_moves'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
        MoveResultArray.Free;
        ModifiedFootprints.Free;
        SkippedFootprints.Free;
        InvalidMoves.Free;
        ParsedMoves.Free;
        MoveCounts.Free;
    end;
end;

// Function to delete currently selected vias without deleting other selected objects
function DeleteSelectedVias(): String;
var
    Board        : IPCB_Board;
    Iterator     : IPCB_BoardIterator;
    Primitive    : IPCB_Primitive;
    ViasToDelete : TObjectList;
    KeepSelected : TObjectList;
    ResultProps  : TStringList;
    OutputLines  : TStringList;
    i            : Integer;
begin
    Board := GetBoardSafe(0);
    if (Board = nil) then
    begin
        Result := 'ERROR: No PCB document is currently active';
        Exit;
    end;

    ViasToDelete := TObjectList.Create;
    ViasToDelete.OwnsObjects := False;
    KeepSelected := TObjectList.Create;
    KeepSelected.OwnsObjects := False;
    ResultProps := TStringList.Create;

    try
        Iterator := Board.BoardIterator_Create;
        Iterator.AddFilter_IPCB_LayerSet(LayerSet.AllLayers);
        Iterator.AddFilter_Method(eProcessAll);

        Primitive := Iterator.FirstPCBObject;
        while (Primitive <> Nil) do
        begin
            if Primitive.Selected then
            begin
                if Primitive.ObjectId = eViaObject then
                    ViasToDelete.Add(Primitive)
                else
                    KeepSelected.Add(Primitive);
            end;

            Primitive := Iterator.NextPCBObject;
        end;

        Board.BoardIterator_Destroy(Iterator);

        if ViasToDelete.Count > 0 then
        begin
            PCBServer.PreProcess;

            for i := 0 to KeepSelected.Count - 1 do
            begin
                Primitive := KeepSelected[i];
                Primitive.Selected := False;
            end;

            for i := 0 to ViasToDelete.Count - 1 do
            begin
                Primitive := ViasToDelete[i];
                Primitive.Selected := True;
            end;

            Client.SendMessage('PCB:DeleteObjects', 'Object=SELECTED', 255, Client.CurrentView);

            for i := 0 to KeepSelected.Count - 1 do
            begin
                Primitive := KeepSelected[i];
                Primitive.Selected := True;
            end;

            PCBServer.PostProcess;
            Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);
            Board.ViewManager_FullUpdate;
        end;

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONInteger(ResultProps, 'deleted_vias', ViasToDelete.Count);
        AddJSONInteger(ResultProps, 'preserved_other_selected_objects', KeepSelected.Count);

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ViasToDelete.Free;
        KeepSelected.Free;
        ResultProps.Free;
    end;
end;

function PCBPrimitiveNetName(Primitive: IPCB_Primitive): String;
var Net: IPCB_Net;
begin
    Result := '';
    if Primitive = Nil then Exit;
    Net := Primitive.Net;
    if Net <> Nil then Result := Net.Name;
end;

function PCBLayerDisplayName(Board: IPCB_Board; Layer: TLayer): String;
var
    LayerObj: IPCB_LayerObject;
begin
    Result := Layer2String(Layer);
    if Board = Nil then
        Exit;

    LayerObj := Board.LayerStack.LayerObject[Layer];
    if (LayerObj <> Nil) and (LayerObj.Name <> '') then
        Result := LayerObj.Name;
end;

procedure AddPCBPolygonSummary(Props: TStringList; Prefix: String; Board: IPCB_Board; Polygon: IPCB_Primitive);
var
    Rect: TCoordRect;
begin
    if Polygon = Nil then
        Exit;

    Rect := Polygon.BoundingRectangle;
    AddJSONProperty(Props, Prefix + '_name', Polygon.Name);
    AddJSONProperty(Props, Prefix + '_net', PCBPrimitiveNetName(Polygon));
    AddJSONProperty(Props, Prefix + '_layer', PCBLayerDisplayName(Board, Polygon.Layer));
    AddJSONNumber(Props, Prefix + '_left_mils', CoordToMils(Rect.Left));
    AddJSONNumber(Props, Prefix + '_bottom_mils', CoordToMils(Rect.Bottom));
    AddJSONNumber(Props, Prefix + '_right_mils', CoordToMils(Rect.Right));
    AddJSONNumber(Props, Prefix + '_top_mils', CoordToMils(Rect.Top));
end;

function FindPCBPolygonByNameOrNet(Board: IPCB_Board; PolygonName: String; var LookupError: String): IPCB_Polygon;
var
    Iterator              : IPCB_BoardIterator;
    Polygon, ByName, ByNet : IPCB_Polygon;
    MatchName             : String;
    NameCount, NetCount   : Integer;
begin
    Result := Nil;
    LookupError := 'polygon not found: ' + PolygonName;
    MatchName := UpperCase(Trim(PolygonName));
    if (Board = Nil) or (MatchName = '') then Exit;

    NameCount := 0;
    NetCount := 0;
    ByName := Nil;
    ByNet := Nil;
    Iterator := Board.BoardIterator_Create;
    try
        Iterator.AddFilter_ObjectSet(MkSet(ePolyObject));
        Iterator.AddFilter_IPCB_LayerSet(LayerSet.AllLayers);
        Iterator.AddFilter_Method(eProcessAll);
        Polygon := Iterator.FirstPCBObject;
        while Polygon <> Nil do
        begin
            if UpperCase(Trim(Polygon.Name)) = MatchName then
            begin
                ByName := Polygon;
                Inc(NameCount);
            end;
            if UpperCase(Trim(PCBPrimitiveNetName(Polygon))) = MatchName then
            begin
                ByNet := Polygon;
                Inc(NetCount);
            end;
            Polygon := Iterator.NextPCBObject;
        end;
    finally
        Board.BoardIterator_Destroy(Iterator);
    end;

    if NameCount = 1 then Result := ByName
    else if (NameCount = 0) and (NetCount = 1) then Result := ByNet
    else if (NameCount > 1) or (NetCount > 1) then
        LookupError := 'polygon identifier is ambiguous: ' + PolygonName;
end;

function CopyPCBPolygonGeometry(SourcePolygonName, TargetPolygonName: String): String;
var
    Board         : IPCB_Board;
    SourcePoly    : IPCB_Polygon;
    TargetPoly    : IPCB_Polygon;
    LookupError   : String;
    Segment       : TPolySegment;
    i, PointCount : Integer;
    ResultProps   : TStringList;
    OutputLines   : TStringList;
begin
    Board := GetBoardSafe(0);
    if (Board = Nil) then
    begin
        Result := 'ERROR: No PCB document is currently active';
        Exit;
    end;

    ResultProps := TStringList.Create;
    try
        SourcePoly := FindPCBPolygonByNameOrNet(Board, SourcePolygonName, LookupError);
        if SourcePoly = Nil then
        begin
            AddJSONBoolean(ResultProps, 'success', False);
            AddJSONProperty(ResultProps, 'error', 'Source ' + LookupError);
        end
        else
        begin
            TargetPoly := FindPCBPolygonByNameOrNet(Board, TargetPolygonName, LookupError);
            if TargetPoly = Nil then
            begin
                AddJSONBoolean(ResultProps, 'success', False);
                AddJSONProperty(ResultProps, 'error', 'Target ' + LookupError);
            end
            else if SourcePoly = TargetPoly then
            begin
                AddJSONBoolean(ResultProps, 'success', False);
                AddJSONProperty(ResultProps, 'error', 'Source and target must be different polygons.');
            end
            else
            begin
                AddPCBPolygonSummary(ResultProps, 'source_before', Board, SourcePoly);
                AddPCBPolygonSummary(ResultProps, 'target_before', Board, TargetPoly);

                PCBServer.PreProcess;
                try
                    PCBServer.SendMessageToRobots(TargetPoly.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
                    try
                        // Copy the outline records, including arc geometry, in
                        // place so the target's pour settings and identity survive.
                        PointCount := SourcePoly.PointCount;
                        TargetPoly.SetState_PointCount(PointCount);
                        for i := 0 to PointCount - 1 do
                        begin
                            Segment := SourcePoly.Segments[i];
                            TargetPoly.SetState_Segments(i, Segment);
                        end;
                        TargetPoly.Rebuild;
                    finally
                        PCBServer.SendMessageToRobots(TargetPoly.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
                    end;
                finally
                    PCBServer.PostProcess;
                end;

                Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);
                Board.ConnectivelyValidateNets;
                Board.ViewManager_FullUpdate;

                AddJSONBoolean(ResultProps, 'success', True);
                AddJSONProperty(ResultProps, 'source_polygon', SourcePolygonName);
                AddJSONProperty(ResultProps, 'target_polygon', TargetPolygonName);
                AddPCBPolygonSummary(ResultProps, 'target_after', Board, TargetPoly);
                AddJSONBoolean(ResultProps, 'document_dirty', True);
            end;
        end;

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
    end;
end;

function PCBFillKindName(Primitive: IPCB_Primitive): String;
begin
    Result := 'unknown';
    if Primitive = Nil then
        Exit;

    case Primitive.ObjectId of
        eFillObject:
            Result := 'fill';
        eRegionObject:
            Result := 'region';
    end;
end;

function CopySelectedFillToSignalLayers(): String;
var
    Board          : IPCB_Board;
    LayerStack     : IPCB_LayerStack_V7;
    LayerObj       : IPCB_LayerObject;
    SelectedObj    : IPCB_Primitive;
    SourceFill     : IPCB_Primitive;
    NewFill        : IPCB_Primitive;
    CopiedLayers   : TStringList;
    ResultProps    : TStringList;
    OutputLines    : TStringList;
    i              : Integer;
    FillCount      : Integer;
begin
    Board := GetBoardSafe(0);
    if Board = Nil then
    begin
        Result := '{"success": false, "error": "No PCB document is currently active"}';
        Exit;
    end;

    ResultProps := TStringList.Create;
    CopiedLayers := TStringList.Create;
    try
        SourceFill := Nil;
        FillCount := 0;

        for i := 0 to Board.SelectecObjectCount - 1 do
        begin
            SelectedObj := Board.SelectecObject[i];
            if (SelectedObj <> Nil) and
               ((SelectedObj.ObjectId = eFillObject) or (SelectedObj.ObjectId = eRegionObject)) then
            begin
                FillCount := FillCount + 1;
                SourceFill := SelectedObj;
            end;
        end;

        if FillCount <> 1 then
        begin
            AddJSONBoolean(ResultProps, 'success', False);
            AddJSONProperty(ResultProps, 'error', 'Select exactly one fill or region before running copy_selected_fill_to_signal_layers.');
            AddJSONInteger(ResultProps, 'selected_fill_or_region_count', FillCount);
        end
        else if not LayerSet.SignalLayers.Contains(SourceFill.Layer) then
        begin
            AddJSONBoolean(ResultProps, 'success', False);
            AddJSONProperty(ResultProps, 'error', 'Selected fill/region is not on a signal layer.');
            AddJSONProperty(ResultProps, 'source_layer', PCBLayerDisplayName(Board, SourceFill.Layer));
        end
        else
        begin
            LayerStack := Board.LayerStack_V7;
            if LayerStack = Nil then
            begin
                AddJSONBoolean(ResultProps, 'success', False);
                AddJSONProperty(ResultProps, 'error', 'PCB layer stack is unavailable.');
            end
            else
            begin
                PCBServer.PreProcess;
                try
                    LayerObj := LayerStack.FirstLayer;
                    while LayerObj <> Nil do
                    begin
                        if LayerSet.SignalLayers.Contains(LayerObj.V6_LayerID) and
                           (LayerObj.V6_LayerID <> SourceFill.Layer) then
                        begin
                            NewFill := SourceFill.Replicate;
                            PCBServer.SendMessageToRobots(NewFill.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
                            NewFill.Layer := LayerObj.V6_LayerID;
                            NewFill.Selected := True;
                            Board.AddPCBObject(NewFill);
                            PCBServer.SendMessageToRobots(NewFill.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
                            Board.DispatchMessage(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, NewFill.I_ObjectAddress);
                            CopiedLayers.Add('"' + JSONEscapeString(PCBLayerDisplayName(Board, LayerObj.V6_LayerID)) + '"');
                        end;

                        LayerObj := LayerStack.NextLayer(LayerObj);
                    end;
                finally
                    PCBServer.PostProcess;
                end;

                Board.ConnectivelyValidateNets;
                Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);
                Board.ViewManager_FullUpdate;

                AddJSONBoolean(ResultProps, 'success', True);
                AddJSONProperty(ResultProps, 'source_kind', PCBFillKindName(SourceFill));
                AddJSONProperty(ResultProps, 'source_net', PCBPrimitiveNetName(SourceFill));
                AddJSONProperty(ResultProps, 'source_layer', PCBLayerDisplayName(Board, SourceFill.Layer));
                AddJSONInteger(ResultProps, 'copied_count', CopiedLayers.Count);
                ResultProps.Add(BuildJSONArray(CopiedLayers, 'target_layers'));
                AddJSONBoolean(ResultProps, 'document_dirty', True);
            end;
        end;

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        CopiedLayers.Free;
        ResultProps.Free;
    end;
end;

function PCBPrimitiveIsKeepout(Primitive: IPCB_Primitive): Boolean;
begin
    Result := False;
    if Primitive = Nil then
        Exit;

    Result := (UpperCase(Layer2String(Primitive.Layer)) = 'KEEP-OUT LAYER') or
              (UpperCase(Layer2String(Primitive.Layer)) = 'KEEP OUT LAYER');
end;

// Distance from PX,PY to the segment X1,Y1-X2,Y2
function GeoSegmentDistance(X1, Y1, X2, Y2, PX, PY: Integer): Double;
var
    DX, DY, L2, T : Double;
begin
    // + 0.0: DelphiScript keeps integer arithmetic otherwise (the declared
    // types are not enforced), and the squares of board coordinates
    // overflow 32 bits: every track longer than about 4.6 mil came out as
    // a point
    DX := X2 - X1 + 0.0;
    DY := Y2 - Y1 + 0.0;
    L2 := DX * DX + DY * DY;
    T := 0;
    if L2 > 0 then T := ((PX - X1) * DX + (PY - Y1) * DY) / L2;
    if T < 0 then T := 0;
    if T > 1 then T := 1;
    Result := Sqrt(Sqr(X1 + T * DX - PX) + Sqr(Y1 + T * DY - PY));
end;

function AddTentedPCBVia(Board: IPCB_Board; X, Y, ViaDiameter, ViaHole: TCoord; Net: IPCB_Net): Boolean;
var
    Via : IPCB_Primitive;
begin
    Result := False;
    if Board = Nil then
        Exit;

    Via := PCBServer.PCBObjectFactory(eViaObject, eNoDimension, eCreate_Default);
    if Via = Nil then
        Exit;

    Via.X := X;
    Via.Y := Y;
    Via.Size := ViaDiameter;
    Via.HoleSize := ViaHole;
    Via.LowLayer := eTopLayer;
    Via.HighLayer := eBottomLayer;
    if Net <> Nil then
        Via.Net := Net;
    Via.SetState_SolderMaskExpansion(-(ViaDiameter div 2));
    Via.IsTenting := True;
    Via.IsTenting_Top := True;
    Via.IsTenting_Bottom := True;
    Via.Selected := True;

    PCBServer.SendMessageToRobots(Via.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
    try
        Board.AddPCBObject(Via);
    finally
        PCBServer.SendMessageToRobots(Via.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
    end;
    Result := True;
end;

procedure CountKeepoutEndpoint(Endpoints: TStringList; X, Y: TCoord);
var
    Key: String;
    EndpointIndex: Integer;
begin
    Key := IntToStr(X) + '|' + IntToStr(Y);
    EndpointIndex := Endpoints.IndexOfName(Key);
    if EndpointIndex < 0 then
        Endpoints.Add(Key + '=1')
    else
        Endpoints[EndpointIndex] := Key + '=' + IntToStr(StrToInt(Endpoints.ValueFromIndex[EndpointIndex]) + 1);
end;

procedure AddKeepoutChord(Chords: TList; X1, Y1, X2, Y2: TCoord);
begin
    if (X1 = X2) and (Y1 = Y2) then Exit;
    Chords.Add(X1 + KEEPOUT_COORD_BIAS);
    Chords.Add(Y1 + KEEPOUT_COORD_BIAS);
    Chords.Add(X2 + KEEPOUT_COORD_BIAS);
    Chords.Add(Y2 + KEEPOUT_COORD_BIAS);
end;

function KeepoutArcSweep(Arc: IPCB_Arc): Double;
begin
    Result := Arc.EndAngle - Arc.StartAngle;
    if Result < 0 then Result := Result + 360.0;
    if Result <= 0.000001 then Result := 360.0;
end;

procedure AddKeepoutArcChords(Chords: TList; Arc: IPCB_Arc; Sagitta: Double);
var
    Radius, StartAngle, Sweep, Angle, MaxStep: Double;
    i, ChordCount: Integer;
    X1, Y1, X2, Y2: TCoord;
begin
    Radius := Arc.Radius + 0.0;
    StartAngle := Arc.StartAngle * KEEPOUT_DEGREES_TO_RADIANS;
    Sweep := KeepoutArcSweep(Arc) * KEEPOUT_DEGREES_TO_RADIANS;
    // R * angle^2 / 8 bounds the difference between an arc and its chord.
    MaxStep := Sqrt(8.0 * Sagitta / Radius);
    if MaxStep > 0.25 then MaxStep := 0.25;
    ChordCount := Trunc(Sweep / MaxStep) + 1;
    X1 := Arc.StartX;
    Y1 := Arc.StartY;
    for i := 1 to ChordCount do
    begin
        if i = ChordCount then
        begin
            X2 := Arc.EndX;
            Y2 := Arc.EndY;
        end
        else
        begin
            Angle := StartAngle + Sweep * i / ChordCount;
            X2 := Arc.XCenter + Round(Radius * Cos(Angle));
            Y2 := Arc.YCenter + Round(Radius * Sin(Angle));
        end;
        AddKeepoutChord(Chords, X1, Y1, X2, Y2);
        X1 := X2;
        Y1 := Y2;
    end;
end;

function KeepoutCenterIsClear(Chords: TList; X, Y: TCoord; MinDistance: Double): Boolean;
var
    i: Integer;
    X1, Y1, X2, Y2: TCoord;
    Crosses: Boolean;
begin
    Result := False;
    Crosses := False;
    i := 0;
    while i < Chords.Count do
    begin
        X1 := Chords.Items[i] - KEEPOUT_COORD_BIAS;
        Y1 := Chords.Items[i + 1] - KEEPOUT_COORD_BIAS;
        X2 := Chords.Items[i + 2] - KEEPOUT_COORD_BIAS;
        Y2 := Chords.Items[i + 3] - KEEPOUT_COORD_BIAS;
        if GeoSegmentDistance(X1, Y1, X2, Y2, X, Y) < MinDistance then Exit;
        if (Y1 > Y) <> (Y2 > Y) then
            if X < X1 + ((X2 - X1 + 0.0) * (Y - Y1)) / (Y2 - Y1) then
                Crosses := not Crosses;
        i := i + 4;
    end;
    Result := Crosses;
end;

procedure PlanKeepoutViaCenters(Primitive: IPCB_Primitive; Chords: TList; Centers: TStringList;
    Pitch: TCoord; MinDistance, Offset: Double);
var
    Track: IPCB_Track;
    Arc: IPCB_Arc;
    Radius, StartAngle, Angle, EdgeLength, Distance, Slack: Double;
    DX, DY, X, Y, NX, NY: Double;
    i, Side, StepCount: Integer;
    PX, PY: TCoord;
begin
    if Primitive.ObjectId = eTrackObject then
    begin
        Track := Primitive;
        DX := Track.X2 - Track.X1 + 0.0;
        DY := Track.Y2 - Track.Y1 + 0.0;
        EdgeLength := Sqrt(DX * DX + DY * DY);
        if EdgeLength = 0 then Exit;
        DX := DX / EdgeLength;
        DY := DY / EdgeLength;
        NX := -DY;
        NY := DX;
    end
    else
    begin
        Arc := Primitive;
        Radius := Arc.Radius + 0.0;
        StartAngle := Arc.StartAngle * KEEPOUT_DEGREES_TO_RADIANS;
        EdgeLength := Radius * KeepoutArcSweep(Arc) * KEEPOUT_DEGREES_TO_RADIANS;
    end;

    StepCount := Trunc(EdgeLength / Pitch);
    if StepCount < 1 then StepCount := 1;
    // Distribute the chain symmetrically and avoid placing candidates at joins.
    Slack := (EdgeLength - (StepCount - 1) * (Pitch + 0.0)) / 2.0;
    for i := 0 to StepCount - 1 do
    begin
        Distance := Slack + i * (Pitch + 0.0);
        if Primitive.ObjectId = eTrackObject then
        begin
            X := Track.X1 + DX * Distance;
            Y := Track.Y1 + DY * Distance;
        end
        else
        begin
            Angle := StartAngle + Distance / Radius;
            NX := Cos(Angle);
            NY := Sin(Angle);
            X := Arc.XCenter + Radius * NX;
            Y := Arc.YCenter + Radius * NY;
        end;
        // Test both normals against the actual contour so concavities and
        // nested contours do not depend on an arbitrary bounding-box center.
        for Side := -1 to 1 do
            if Side <> 0 then
            begin
                PX := Round(X + Side * NX * Offset);
                PY := Round(Y + Side * NY * Offset);
                if KeepoutCenterIsClear(Chords, PX, PY, MinDistance) then
                begin
                    Centers.Add(IntToStr(PX) + '|' + IntToStr(PY));
                    Break;
                end;
            end;
    end;
end;

function AddTentedViasAroundKeepoutContour(ViaDiameterMM, ViaHoleMM, EdgeClearanceMM, PitchMM: Double; NetName: String): String;
var
    Board: IPCB_Board;
    Iterator: IPCB_BoardIterator;
    Primitive: IPCB_Primitive;
    Track: IPCB_Track;
    Arc: IPCB_Arc;
    ResultProps, Endpoints, Centers: TStringList;
    Edges: TObjectList;
    Chords: TList;
    TargetNet: IPCB_Net;
    ViaDiameter, ViaHole, Pitch, X, Y: TCoord;
    Sagitta, MinDistance, Offset: Double;
    i, TracksSeen, ArcsSeen, ViasCreated: Integer;
begin
    Board := GetBoardSafe(0);
    if Board = Nil then
    begin
        Result := 'ERROR: No PCB document is currently active';
        Exit;
    end;
    if (ViaDiameterMM <= 0) or (ViaHoleMM <= 0) or (ViaHoleMM >= ViaDiameterMM) or
       (EdgeClearanceMM < 0) or (PitchMM <= 0) then
    begin
        Result := 'ERROR: Via diameter, hole and pitch must be positive, the hole must be smaller than the via, and clearance must be nonnegative.';
        Exit;
    end;
    ViaDiameter := MMsToCoord(ViaDiameterMM);
    ViaHole := MMsToCoord(ViaHoleMM);
    Pitch := MMsToCoord(PitchMM);
    if (ViaHole <= 0) or (ViaHole >= ViaDiameter) or (Pitch <= 0) then
    begin
        Result := 'ERROR: Via dimensions and pitch must be representable in PCB coordinates.';
        Exit;
    end;
    TargetNet := FindBoardNet(Board, NetName);
    if (NetName <> '') and (TargetNet = Nil) then
    begin
        Result := 'ERROR: Net not found: ' + NetName;
        Exit;
    end;

    ResultProps := TStringList.Create;
    Endpoints := TStringList.Create;
    Centers := TStringList.Create;
    Edges := TObjectList.Create;
    Edges.OwnsObjects := False;
    Chords := TList.Create;
    Centers.Sorted := True;
    Centers.Duplicates := dupIgnore;
    try
        Sagitta := MMsToCoord(0.002);
        TracksSeen := 0;
        ArcsSeen := 0;
        Iterator := Board.BoardIterator_Create;
        try
            Iterator.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject));
            Iterator.AddFilter_IPCB_LayerSet(LayerSet.AllLayers);
            Iterator.AddFilter_Method(eProcessAll);
            Primitive := Iterator.FirstPCBObject;
            while Primitive <> Nil do
            begin
                if PCBPrimitiveIsKeepout(Primitive) then
                begin
                    if Primitive.ObjectId = eTrackObject then
                    begin
                        Track := Primitive;
                        Inc(TracksSeen);
                        if (Track.X1 <> Track.X2) or (Track.Y1 <> Track.Y2) then
                        begin
                            CountKeepoutEndpoint(Endpoints, Track.X1, Track.Y1);
                            CountKeepoutEndpoint(Endpoints, Track.X2, Track.Y2);
                            AddKeepoutChord(Chords, Track.X1, Track.Y1, Track.X2, Track.Y2);
                            Edges.Add(Primitive);
                        end;
                    end
                    else
                    begin
                        Arc := Primitive;
                        Inc(ArcsSeen);
                        if Arc.Radius > 0 then
                        begin
                            CountKeepoutEndpoint(Endpoints, Arc.StartX, Arc.StartY);
                            CountKeepoutEndpoint(Endpoints, Arc.EndX, Arc.EndY);
                            AddKeepoutArcChords(Chords, Arc, Sagitta);
                            Edges.Add(Primitive);
                        end;
                    end;
                end;
                Primitive := Iterator.NextPCBObject;
            end;
        finally
            Board.BoardIterator_Destroy(Iterator);
        end;

        if Chords.Count = 0 then
        begin
            Result := 'ERROR: No Keep-Out Layer tracks or arcs found for PCB contour.';
            Exit;
        end;
        for i := 0 to Endpoints.Count - 1 do
            if Endpoints.ValueFromIndex[i] <> '2' then
            begin
                Result := 'ERROR: Keep-Out Layer tracks and arcs must form closed, unbranched contours.';
                Exit;
            end;

        MinDistance := MMsToCoord(EdgeClearanceMM) + ViaDiameter / 2.0 + 1.0;
        // An arc may extend beyond a chord by its sagitta plus endpoint rounding.
        if ArcsSeen > 0 then MinDistance := MinDistance + Sagitta + 2.0;
        Offset := MinDistance + 2.0;
        if ArcsSeen > 0 then Offset := Offset + Sagitta + 2.0;
        for i := 0 to Edges.Count - 1 do
        begin
            Primitive := Edges[i];
            PlanKeepoutViaCenters(Primitive, Chords, Centers, Pitch, MinDistance, Offset);
            ReportProgress;
        end;
        if Centers.Count = 0 then
        begin
            Result := 'ERROR: No via center meets the requested clearance inside the keepout contour.';
            Exit;
        end;

        ViasCreated := 0;
        PCBServer.PreProcess;
        try
            Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);
            for i := 0 to Centers.Count - 1 do
            begin
                X := StrToInt(GetFieldFromPipeString(Centers[i], 0));
                Y := StrToInt(GetFieldFromPipeString(Centers[i], 1));
                if AddTentedPCBVia(Board, X, Y, ViaDiameter, ViaHole, TargetNet) then
                    Inc(ViasCreated);
            end;
        finally
            PCBServer.PostProcess;
        end;
        Board.ConnectivelyValidateNets;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);
        Board.ViewManager_FullUpdate;

        AddJSONBoolean(ResultProps, 'success', ViasCreated = Centers.Count);
        if ViasCreated <> Centers.Count then
            AddJSONProperty(ResultProps, 'message', 'Some planned vias could not be created.');
        AddJSONInteger(ResultProps, 'keepout_tracks_seen', TracksSeen);
        AddJSONInteger(ResultProps, 'keepout_arcs_seen', ArcsSeen);
        AddJSONInteger(ResultProps, 'vias_created', ViasCreated);
        AddJSONNumber(ResultProps, 'via_diameter_mm', ViaDiameterMM);
        AddJSONNumber(ResultProps, 'via_hole_mm', ViaHoleMM);
        AddJSONNumber(ResultProps, 'edge_clearance_from_outer_diameter_mm', EdgeClearanceMM);
        AddJSONNumber(ResultProps, 'via_center_offset_from_keepout_mm', CoordToMMs(Round(Offset)));
        AddJSONNumber(ResultProps, 'pitch_mm', PitchMM);
        AddJSONProperty(ResultProps, 'net_name', NetName);
        AddJSONNumber(ResultProps, 'manual_solder_mask_expansion_mm', -(ViaDiameterMM / 2.0));
        AddJSONBoolean(ResultProps, 'tented_top', True);
        AddJSONBoolean(ResultProps, 'tented_bottom', True);
        AddJSONBoolean(ResultProps, 'created_vias_selected', ViasCreated > 0);
        AddJSONBoolean(ResultProps, 'document_dirty', ViasCreated > 0);
        AddJSONBoolean(ResultProps, 'document_saved', False);
        Result := BuildJSONObject(ResultProps);
    finally
        Chords.Free;
        Edges.Free;
        Centers.Free;
        Endpoints.Free;
        ResultProps.Free;
    end;
end;

// Function to move currently selected vias by X and Y offsets
function MoveSelectedViasByOffset(XOffset, YOffset: TCoord): String;
var
    Board       : IPCB_Board;
    Iterator    : IPCB_BoardIterator;
    Via         : IPCB_Primitive;
    ResultProps : TStringList;
    OutputLines : TStringList;
    MovedCount  : Integer;
begin
    Board := GetBoardSafe(0);
    if (Board = nil) then
    begin
        Result := 'ERROR: No PCB document is currently active';
        Exit;
    end;

    ResultProps := TStringList.Create;
    MovedCount := 0;

    try
        Iterator := Board.BoardIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(eViaObject));
        Iterator.AddFilter_IPCB_LayerSet(LayerSet.AllLayers);
        Iterator.AddFilter_Method(eProcessAll);

        PCBServer.PreProcess;

        Via := Iterator.FirstPCBObject;
        while (Via <> Nil) do
        begin
            if Via.Selected then
            begin
                PCBServer.SendMessageToRobots(Via.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
                Via.x := Via.x + XOffset;
                Via.y := Via.y + YOffset;
                PCBServer.SendMessageToRobots(Via.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
                MovedCount := MovedCount + 1;
            end;

            Via := Iterator.NextPCBObject;
        end;

        PCBServer.PostProcess;
        Board.BoardIterator_Destroy(Iterator);

        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONInteger(ResultProps, 'moved_count', MovedCount);
        AddJSONNumber(ResultProps, 'x_offset_mils', CoordToMils(XOffset));
        AddJSONNumber(ResultProps, 'y_offset_mils', CoordToMils(YOffset));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
    end;
end;

// Function to move selected pads and any vias touching those pads
function MoveSelectedPadsAndTouchingViasByOffset(XOffset, YOffset, TouchTolerance: TCoord): String;
var
    Board       : IPCB_Board;
    Iterator    : IPCB_BoardIterator;
    SelectedObj : IPCB_Primitive;
    Pad         : IPCB_Primitive;
    Via         : IPCB_Primitive;
    Pads        : TObjectList;
    Vias        : TObjectList;
    PadSeen     : TStringList;
    ViaSeen     : TStringList;
    ResultProps : TStringList;
    OutputLines : TStringList;
    i           : Integer;
    ObjKey      : String;
begin
    Board := GetBoardSafe(0);
    if (Board = nil) then
    begin
        Result := 'ERROR: No PCB document is currently active';
        Exit;
    end;

    Pads := TObjectList.Create;
    Pads.OwnsObjects := False;
    Vias := TObjectList.Create;
    Vias.OwnsObjects := False;
    PadSeen := TStringList.Create;
    PadSeen.Duplicates := dupIgnore;
    ViaSeen := TStringList.Create;
    ViaSeen.Duplicates := dupIgnore;
    ResultProps := TStringList.Create;

    try
        for i := 0 to Board.SelectecObjectCount - 1 do
        begin
            SelectedObj := Board.SelectecObject[i];
            if (SelectedObj <> Nil) and (SelectedObj.ObjectId = ePadObject) then
            begin
                ObjKey := IntToStr(SelectedObj.I_ObjectAddress);
                if PadSeen.IndexOf(ObjKey) < 0 then
                begin
                    PadSeen.Add(ObjKey);
                    Pads.Add(SelectedObj);
                end;
            end;
        end;

        if Pads.Count = 0 then
        begin
            Result := 'ERROR: No selected pads found';
            Exit;
        end;

        Iterator := Board.BoardIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(eViaObject));
        Iterator.AddFilter_IPCB_LayerSet(LayerSet.AllLayers);
        Iterator.AddFilter_Method(eProcessAll);

        Via := Iterator.FirstPCBObject;
        while (Via <> Nil) do
        begin
            for i := 0 to Pads.Count - 1 do
            begin
                Pad := Pads[i];
                if Board.PrimPrimDistance(Pad, Via) <= TouchTolerance then
                begin
                    ObjKey := IntToStr(Via.I_ObjectAddress);
                    if ViaSeen.IndexOf(ObjKey) < 0 then
                    begin
                        ViaSeen.Add(ObjKey);
                        Vias.Add(Via);
                    end;
                    Break;
                end;
            end;

            Via := Iterator.NextPCBObject;
        end;
        Board.BoardIterator_Destroy(Iterator);

        PCBServer.PreProcess;

        for i := 0 to Pads.Count - 1 do
        begin
            Pad := Pads[i];
            PCBServer.SendMessageToRobots(Pad.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
            Pad.x := Pad.x + XOffset;
            Pad.y := Pad.y + YOffset;
            PCBServer.SendMessageToRobots(Pad.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
        end;

        for i := 0 to Vias.Count - 1 do
        begin
            Via := Vias[i];
            PCBServer.SendMessageToRobots(Via.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
            Via.x := Via.x + XOffset;
            Via.y := Via.y + YOffset;
            PCBServer.SendMessageToRobots(Via.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
        end;

        PCBServer.PostProcess;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);
        Board.ViewManager_FullUpdate;

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONInteger(ResultProps, 'moved_pads', Pads.Count);
        AddJSONInteger(ResultProps, 'moved_vias', Vias.Count);
        AddJSONNumber(ResultProps, 'x_offset_mils', CoordToMils(XOffset));
        AddJSONNumber(ResultProps, 'y_offset_mils', CoordToMils(YOffset));
        AddJSONNumber(ResultProps, 'touch_tolerance_mils', CoordToMils(TouchTolerance));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        Pads.Free;
        Vias.Free;
        PadSeen.Free;
        ViaSeen.Free;
        ResultProps.Free;
    end;
end;


// Minimum primitive-to-primitive distance between two components in mils,
// ignoring text primitives (designator/comment strings float over neighbors
// and would poison the measurement). 0 = touching or overlapping.
function ComponentMinDistance(Board: IPCB_Board; CompA, CompB: IPCB_Component): Double;
var
    ItA, ItB : IPCB_GroupIterator;
    PA, PB   : IPCB_Primitive;
    D, MinD  : Integer;
begin
    MinD := 2147483647;

    ItA := CompA.GroupIterator_Create;
    ItA.SetState_FilterAll;
    PA := ItA.FirstPCBObject;
    while (PA <> nil) do
    begin
        if (PA.ObjectId <> eTextObject) then
        begin
            ItB := CompB.GroupIterator_Create;
            ItB.SetState_FilterAll;
            PB := ItB.FirstPCBObject;
            while (PB <> nil) do
            begin
                if (PB.ObjectId <> eTextObject) then
                begin
                    D := Board.PrimPrimDistance(PA, PB);
                    if (D < MinD) then MinD := D;
                end;

                // Early exit once touching - it cannot get closer
                if (MinD = 0) then
                    PB := nil
                else
                    PB := ItB.NextPCBObject;
            end;
            CompB.GroupIterator_Destroy(ItB);
        end;

        if (MinD = 0) then
            PA := nil
        else
            PA := ItA.NextPCBObject;
    end;
    CompA.GroupIterator_Destroy(ItA);

    Result := CoordToMils(MinD);
end;

// Check component placement for overlaps and clearance violations.
// Targets are the given designators (or the current selection when the list
// is empty); each target is checked against every other component on the same
// side of the board. Bounding boxes act as a fast prefilter; close pairs are
// measured precisely with Board.PrimPrimDistance (minimum distance between
// any two primitives of the components, 0 = touching/overlapping).
function CheckPlacement(DesignatorsList: TStringList; ClearanceMils: Double): String;
var
    Board           : IPCB_Board;
    Iterator        : IPCB_BoardIterator;
    Target, Other   : IPCB_Component;
    Targets         : TStringList;
    Processed       : TStringList;
    MissingArray    : TStringList;
    ViolationsArray : TStringList;
    VProps          : TStringList;
    ResultProps     : TStringList;
    RectA, RectB    : TCoordRect;
    Designator      : String;
    i               : Integer;
    OverlapX, OverlapY : Double;
    Separation      : Double;
    DistMils        : Double;
    PairsChecked    : Integer;
    IsOverlap       : Boolean;
begin
    Board := GetBoardSafe(0);
    if (Board = nil) then
    begin
        Result := 'ERROR: No PCB document is currently active';
        Exit;
    end;

    if (ClearanceMils <= 0) then
        ClearanceMils := 6;

    Targets := TStringList.Create;
    Processed := TStringList.Create;
    MissingArray := TStringList.Create;
    ViolationsArray := TStringList.Create;
    ResultProps := TStringList.Create;
    PairsChecked := 0;

    try
        // Build the target list: explicit designators, or current selection
        if (DesignatorsList.Count > 0) then
        begin
            for i := 0 to DesignatorsList.Count - 1 do
            begin
                Designator := Trim(DesignatorsList[i]);
                if (Board.GetPcbComponentByRefDes(Designator) <> nil) then
                    Targets.Add(Designator)
                else
                    MissingArray.Add('"' + JSONEscapeString(Designator) + '"');
            end;
        end
        else
        begin
            for i := 0 to Board.SelectecObjectCount - 1 do
                if (Board.SelectecObject[i].ObjectId = eComponentObject) then
                    Targets.Add(Board.SelectecObject[i].Name.Text);
        end;

        if (Targets.Count = 0) then
        begin
            if (DesignatorsList.Count > 0) then
                Result := 'ERROR: None of the given designators is on ' + ExtractFileName(Board.FileName) +
                          ': ' + DesignatorsList.CommaText
            else
                Result := 'ERROR: No components to check (no designators given and no components selected)';
            Exit;
        end;

        // Check each target against every other component on the same side
        for i := 0 to Targets.Count - 1 do
        begin
            Target := Board.GetPcbComponentByRefDes(Targets[i]);
            RectA := Target.BoundingRectangleNoNameComment;

            Iterator := Board.BoardIterator_Create;
            Iterator.AddFilter_ObjectSet(MkSet(eComponentObject));
            Iterator.AddFilter_IPCB_LayerSet(LayerSet.AllLayers);
            Iterator.AddFilter_Method(eProcessAll);

            Other := Iterator.FirstPCBObject;
            while (Other <> nil) do
            begin
                if (Other.Name.Text <> Target.Name.Text) and
                   (Other.Layer = Target.Layer) and
                   (Processed.IndexOf(Other.Name.Text) < 0) then
                begin
                    RectB := Other.BoundingRectangleNoNameComment;

                    // Bounding-box overlap/separation in mils (negative = gap)
                    OverlapX := CoordToMils(Min(RectA.Right, RectB.Right) - Max(RectA.Left, RectB.Left));
                    OverlapY := CoordToMils(Min(RectA.Top, RectB.Top) - Max(RectA.Bottom, RectB.Bottom));

                    if (OverlapX > 0) and (OverlapY > 0) then
                        Separation := 0
                    else
                        Separation := Max(-OverlapX, -OverlapY);

                    // Only measure precisely when the prefilter says "close"
                    if (Separation < ClearanceMils + 25) then
                    begin
                        PairsChecked := PairsChecked + 1;
                        DistMils := ComponentMinDistance(Board, Target, Other);
                        IsOverlap := (OverlapX > 0) and (OverlapY > 0);

                        if (IsOverlap) or (DistMils < ClearanceMils) then
                        begin
                            VProps := TStringList.Create;
                            try
                                AddJSONProperty(VProps, 'a', Target.Name.Text);
                                AddJSONProperty(VProps, 'b', Other.Name.Text);
                                AddJSONProperty(VProps, 'layer', Layer2String(Target.Layer));
                                if IsOverlap then
                                    AddJSONProperty(VProps, 'type', 'bounding_box_overlap')
                                else
                                    AddJSONProperty(VProps, 'type', 'clearance');
                                AddJSONNumber(VProps, 'distance_mils', Round(DistMils * 100) / 100);
                                if IsOverlap then
                                begin
                                    AddJSONNumber(VProps, 'overlap_x_mils', Round(OverlapX * 100) / 100);
                                    AddJSONNumber(VProps, 'overlap_y_mils', Round(OverlapY * 100) / 100);
                                end;
                                AddJSONNumber(VProps, 'b_x', CoordToMils(Other.x - Board.XOrigin));
                                AddJSONNumber(VProps, 'b_y', CoordToMils(Other.y - Board.YOrigin));
                                ViolationsArray.Add(BuildJSONObject(VProps, 2));
                            finally
                                VProps.Free;
                            end;
                        end;
                    end;
                end;

                Other := Iterator.NextPCBObject;
            end;

            Board.BoardIterator_Destroy(Iterator);
            Processed.Add(Target.Name.Text);
        end;

        AddJSONProperty(ResultProps, 'board_path', Board.FileName);
        AddJSONInteger(ResultProps, 'checked_count', Targets.Count);
        AddJSONNumber(ResultProps, 'clearance_mils', ClearanceMils);
        AddJSONInteger(ResultProps, 'close_pairs_measured', PairsChecked);
        AddJSONInteger(ResultProps, 'violation_count', ViolationsArray.Count);

        if (MissingArray.Count > 0) then
            ResultProps.Add(BuildJSONArray(MissingArray, 'missing_designators'))
        else
            ResultProps.Add('"missing_designators": []');

        if (ViolationsArray.Count > 0) then
            ResultProps.Add(BuildJSONArray(ViolationsArray, 'violations', 1))
        else
            ResultProps.Add('"violations": []');

        Result := BuildJSONObject(ResultProps);
    finally
        Targets.Free;
        Processed.Free;
        MissingArray.Free;
        ViolationsArray.Free;
        ResultProps.Free;
    end;
end;

// Get all pads on every net touched by the given components (or the current
// selection when the list is empty). Returns a flat board-wide pad list -
// including pads of components outside the target set - so the caller can
// group by net and compute airline lengths. Coordinates in mils relative to
// the board origin.
function GetNetConnections(ROOT_DIR: String; DesignatorsList: TStringList): String;
var
    Board       : IPCB_Board;
    Component   : IPCB_Component;
    Iterator    : IPCB_BoardIterator;
    GrpIter     : IPCB_GroupIterator;
    Pad         : IPCB_Pad;
    NetNames    : TStringList;
    TargetNames : TStringList;
    PadsArray   : TStringList;
    PadProps    : TStringList;
    ResultProps : TStringList;
    NamesArray  : TStringList;
    MissingArray : TStringList;
    OutputLines : TStringList;
    Designator  : String;
    xorigin, yorigin : Integer;
    i           : Integer;
begin
    Board := GetBoardSafe(0);
    if (Board = nil) then
    begin
        Result := 'ERROR: No PCB document is currently active';
        Exit;
    end;

    xorigin := Board.XOrigin;
    yorigin := Board.YOrigin;

    NetNames := TStringList.Create;
    TargetNames := TStringList.Create;
    PadsArray := TStringList.Create;
    ResultProps := TStringList.Create;
    NamesArray := TStringList.Create;
    MissingArray := TStringList.Create;

    try
        // Build the target component list: explicit designators, or selection
        if (DesignatorsList.Count > 0) then
        begin
            for i := 0 to DesignatorsList.Count - 1 do
            begin
                Designator := Trim(DesignatorsList[i]);
                if (Board.GetPcbComponentByRefDes(Designator) <> nil) then
                    TargetNames.Add(Designator)
                else
                    MissingArray.Add('"' + JSONEscapeString(Designator) + '"');
            end;
        end
        else
        begin
            for i := 0 to Board.SelectecObjectCount - 1 do
                if (Board.SelectecObject[i].ObjectId = eComponentObject) then
                    TargetNames.Add(Board.SelectecObject[i].Name.Text);
        end;

        if (TargetNames.Count = 0) then
        begin
            if (DesignatorsList.Count > 0) then
                Result := 'ERROR: None of the given designators is on ' + ExtractFileName(Board.FileName) +
                          ': ' + DesignatorsList.CommaText
            else
                Result := 'ERROR: No components found (no designators given and no components selected)';
            Exit;
        end;

        // Collect the set of nets touched by the target components
        for i := 0 to TargetNames.Count - 1 do
        begin
            Component := Board.GetPcbComponentByRefDes(TargetNames[i]);
            GrpIter := Component.GroupIterator_Create;
            GrpIter.SetState_FilterAll;
            GrpIter.AddFilter_ObjectSet(MkSet(ePadObject));

            Pad := GrpIter.FirstPCBObject;
            while (Pad <> nil) do
            begin
                if (Pad.Net <> nil) then
                    if (NetNames.IndexOf(Pad.Net.Name) < 0) then
                        NetNames.Add(Pad.Net.Name);
                Pad := GrpIter.NextPCBObject;
            end;

            Component.GroupIterator_Destroy(GrpIter);
        end;

        // One board-wide pass: emit every pad on any of those nets
        Iterator := Board.BoardIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(ePadObject));
        Iterator.AddFilter_IPCB_LayerSet(LayerSet.AllLayers);
        Iterator.AddFilter_Method(eProcessAll);

        Pad := Iterator.FirstPCBObject;
        while (Pad <> nil) do
        begin
            if (Pad.Net <> nil) then
            begin
                if (NetNames.IndexOf(Pad.Net.Name) >= 0) then
                begin
                    PadProps := TStringList.Create;
                    try
                        AddJSONProperty(PadProps, 'net', Pad.Net.Name);
                        if (Pad.Component <> nil) then
                            AddJSONProperty(PadProps, 'designator', Pad.Component.Name.Text)
                        else
                            AddJSONProperty(PadProps, 'designator', '');
                        AddJSONProperty(PadProps, 'pin', Pad.Name);
                        AddJSONNumber(PadProps, 'x', CoordToMils(Pad.x - xorigin));
                        AddJSONNumber(PadProps, 'y', CoordToMils(Pad.y - yorigin));
                        PadsArray.Add(BuildJSONObject(PadProps, 2));
                    finally
                        PadProps.Free;
                    end;
                end;
            end;
            Pad := Iterator.NextPCBObject;
        end;

        Board.BoardIterator_Destroy(Iterator);

        // Build the result - include the resolved targets so the caller
        // knows which components were analyzed when using the selection
        for i := 0 to TargetNames.Count - 1 do
            NamesArray.Add('"' + JSONEscapeString(TargetNames[i]) + '"');
        ResultProps.Add(BuildJSONArray(NamesArray, 'targets'));
        NamesArray.Clear;
        if (MissingArray.Count > 0) then
            ResultProps.Add(BuildJSONArray(MissingArray, 'missing_designators'))
        else
            ResultProps.Add('"missing_designators": []');

        for i := 0 to NetNames.Count - 1 do
            NamesArray.Add('"' + JSONEscapeString(NetNames[i]) + '"');

        if (NamesArray.Count > 0) then
            ResultProps.Add(BuildJSONArray(NamesArray, 'net_names'))
        else
            ResultProps.Add('"net_names": []');

        if (PadsArray.Count > 0) then
            ResultProps.Add(BuildJSONArray(PadsArray, 'pads', 1))
        else
            ResultProps.Add('"pads": []');

        // Potentially large (plane nets) - go through the temp-file path
        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := WriteJSONToFile(OutputLines, ROOT_DIR+'\temp_net_connections.json');
        finally
            OutputLines.Free;
        end;
    finally
        NetNames.Free;
        TargetNames.Free;
        PadsArray.Free;
        ResultProps.Free;
        NamesArray.Free;
        MissingArray.Free;
    end;
end;

// Place multiple components at absolute positions in a single transaction.
// Each entry in PlacementsList is 'Designator|X|Y|Rotation|Layer' where X/Y
// are mils relative to the board origin, Rotation is degrees CCW (-1 = keep
// current) and Layer is 'top', 'bottom' or '' (keep current side).
// Set a component's designator (IsName) or comment text from a spec
// 'x;y;rotation;height;stroke width;visible[;autoposition]' (mils, degrees,
// 1/0, TTextAutoposition) as get_layout reports it: x and y are the text's
// anchor, as Altium stores it. The text is placed manually positioned, or
// Altium would move it while placing it; a non-zero autoposition is set
// back afterwards. The text is added to Moved, whose stroke geometry is
// rebuilt afterwards.
procedure PlaceComponentText(Comp: IPCB_Component; IsName: Boolean; Spec: String; XO, YO: TCoord; Moved: TStringList);
var
    Txt    : IPCB_Text;
    TX, TY : TCoord;
    Parts  : TStringList;
begin
    if Trim(Spec) = '' then Exit;
    Parts := TStringList.Create;
    try
        Parts.Text := StringReplace(Spec, ';', #13#10, REPLACEALL);
        if Parts.Count < 6 then Exit;
        if IsName then Txt := Comp.Name else Txt := Comp.Comment;
        PCBServer.SendMessageToRobots(Comp.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
        PCBServer.SendMessageToRobots(Txt.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
        if IsName then
        begin
            Comp.NameOn := Parts[5] = '1';
            Comp.NameAutoPosition := eAutoPos_Manual;
        end
        else
        begin
            Comp.CommentOn := Parts[5] = '1';
            Comp.CommentAutoPosition := eAutoPos_Manual;
        end;
        Txt.Size := MilsToCoord(SafeStrToFloat(Parts[3]));
        Txt.Width := MilsToCoord(SafeStrToFloat(Parts[4]));
        Txt.Rotation := SafeStrToFloat(Parts[2]);
        PCBServer.SendMessageToRobots(Txt.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
        PCBServer.SendMessageToRobots(Comp.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
        TX := MilsToCoord(SafeStrToFloat(Parts[0])) + XO;
        TY := MilsToCoord(SafeStrToFloat(Parts[1])) + YO;
        if (TX <> Txt.XLocation) or (TY <> Txt.YLocation) then
        begin
            PCBServer.SendMessageToRobots(Txt.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
            Txt.MoveByXY(TX - Txt.XLocation, TY - Txt.YLocation);
            PCBServer.SendMessageToRobots(Txt.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
        end;
        if (Parts.Count > 6) and (Trim(Parts[6]) <> '') and (Trim(Parts[6]) <> '0') then
        begin
            PCBServer.SendMessageToRobots(Comp.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
            if IsName then
                Comp.NameAutoPosition := StrToInt(Trim(Parts[6]))
            else
                Comp.CommentAutoPosition := StrToInt(Trim(Parts[6]));
            PCBServer.SendMessageToRobots(Comp.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
        end;
        Moved.AddObject(Comp.Name.Text, Txt);
    finally
        Parts.Free;
    end;
end;

function PlaceComponentsFromList(PlacementsList: TStringList; RequireAll: Boolean): String;
var
    Board            : IPCB_Board;
    Component        : IPCB_Component;
    ResultProps      : TStringList;
    MissingArray     : TStringList;
    PlacedArray      : TStringList;
    CompProps        : TStringList;
    Entry            : String;
    Designator       : String;
    FieldValue       : String;
    LayerStr         : String;
    LockStr          : String;
    MovedTexts       : TStringList;
    Txt              : IPCB_Text;
    NewX, NewY       : Double;
    Rotation         : Double;
    xorigin, yorigin : TCoord;
    i                : Integer;
    PlacedCount      : Integer;
    Editing          : Boolean;
begin
    Board := GetBoardSafe(0);
    if (Board = nil) then
    begin
        Result := 'ERROR: No PCB document is currently active';
        Exit;
    end;

    if RequireAll then
        for i := 0 to PlacementsList.Count - 1 do
        begin
            Designator := Trim(GetFieldFromPipeString(PlacementsList[i], 0));
            if Board.GetPcbComponentByRefDes(Designator) = nil then
            begin
                Result := 'ERROR: Missing component ' + Designator + '. No placements applied.';
                Exit;
            end;
        end;

    xorigin := Board.XOrigin;
    yorigin := Board.YOrigin;

    ResultProps := TStringList.Create;
    MissingArray := TStringList.Create;
    PlacedArray := TStringList.Create;
    MovedTexts := TStringList.Create;
    PlacedCount := 0;
    Editing := False;

    try
        // Single transaction for the whole batch (one undo step)
        PCBServer.PreProcess;
        Editing := True;

        for i := 0 to PlacementsList.Count - 1 do
        begin
            Entry := Trim(PlacementsList[i]);
            if (Entry <> '') then
            begin
                Designator := Trim(GetFieldFromPipeString(Entry, 0));
                NewX := SafeStrToFloat(GetFieldFromPipeString(Entry, 1));
                NewY := SafeStrToFloat(GetFieldFromPipeString(Entry, 2));

                // Rotation is optional: missing/empty field means keep current
                FieldValue := Trim(GetFieldFromPipeString(Entry, 3));
                if (FieldValue <> '') then
                    Rotation := SafeStrToFloat(FieldValue)
                else
                    Rotation := -1;

                LayerStr := LowerCase(Trim(GetFieldFromPipeString(Entry, 4)));
                // Locked: '1' locks, '0' unlocks, '' (or absent) leaves it
                LockStr := Trim(GetFieldFromPipeString(Entry, 5));

                Component := Board.GetPcbComponentByRefDes(Designator);

                if (Component <> nil) then
                begin
                    PCBServer.SendMessageToRobots(Component.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);

                    // Change layer first: flipping mirrors the footprint, so
                    // position and rotation are applied afterwards to keep the
                    // requested values authoritative
                    if (LayerStr = 'top') and (Component.Layer = eBottomLayer) then
                        Component.Layer := eTopLayer
                    else if (LayerStr = 'bottom') and (Component.Layer = eTopLayer) then
                        Component.Layer := eBottomLayer;

                    Component.MoveToXY(MilsToCoord(NewX) + xorigin, MilsToCoord(NewY) + yorigin);

                    if (Rotation >= 0) then
                        Component.Rotation := Rotation;

                    if LockStr = '1' then
                        Component.Moveable := False
                    else if LockStr = '0' then
                        Component.Moveable := True;

                    PCBServer.SendMessageToRobots(Component.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);

                    // Designator and comment text, when given (get_layout's form)
                    PlaceComponentText(Component, True, GetFieldFromPipeString(Entry, 6), xorigin, yorigin, MovedTexts);
                    PlaceComponentText(Component, False, GetFieldFromPipeString(Entry, 7), xorigin, yorigin, MovedTexts);

                    // Report the final state as Altium sees it
                    CompProps := TStringList.Create;
                    try
                        AddJSONProperty(CompProps, 'designator', Component.Name.Text);
                        AddJSONNumber(CompProps, 'x', CoordToMils(Component.x - xorigin));
                        AddJSONNumber(CompProps, 'y', CoordToMils(Component.y - yorigin));
                        AddJSONNumber(CompProps, 'rotation', Component.Rotation);
                        AddJSONProperty(CompProps, 'layer', Layer2String(Component.Layer));
                        AddJSONBoolean(CompProps, 'locked', not Component.Moveable);
                        PlacedArray.Add(BuildJSONObject(CompProps, 2));
                    finally
                        CompProps.Free;
                    end;

                    PlacedCount := PlacedCount + 1;
                end
                else
                begin
                    MissingArray.Add('"' + JSONEscapeString(Designator) + '"');
                end;
            end;
        end;

        Editing := False;
        PCBServer.PostProcess;

        // Rebuild the stroke geometry of every text placed: batch DRC checks a
        // cached copy that scripted moves leave stale (see PlaceDesignatorsFromList)
        for i := 0 to MovedTexts.Count - 1 do
        begin
            Txt := MovedTexts.Objects[i];
            Txt.BeginModify;
            Txt.SetState_XSizeYSize;
            Txt.EndModify;
            Txt.GraphicallyInvalidate;
        end;

        // Update PCB document
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        AddJSONInteger(ResultProps, 'placed_count', PlacedCount);

        if (MissingArray.Count > 0) then
            ResultProps.Add(BuildJSONArray(MissingArray, 'missing_designators'))
        else
            ResultProps.Add('"missing_designators": []');

        if (PlacedArray.Count > 0) then
            ResultProps.Add(BuildJSONArray(PlacedArray, 'components', 1))
        else
            ResultProps.Add('"components": []');

        Result := BuildJSONObject(ResultProps);
    finally
        ResultProps.Free;
        MissingArray.Free;
        PlacedArray.Free;
        if Editing then PCBServer.PostProcess;
        MovedTexts.Free;
    end;
end;

// ---------------------------------------------------------------------------
// Silkscreen designator placement
//
// The placement itself is solved in Python (server/silkscreen.py) from a
// geometry dump. These routines export that geometry, apply the solved
// designator positions, and verify the result with Altium's own silk rules.
// ---------------------------------------------------------------------------

// Locale-safe mils string (3 decimals) for the silk dump
function SilkNum(Value: Double): String;
begin
    Result := StringReplace(FloatToStr(Round(Value * 1000) / 1000), ',', '.', REPLACEALL);
end;

function SilkLen(C: Integer): String;
begin
    Result := SilkNum(CoordToMils(C));
end;

// 'T' / 'B' for an overlay or solder mask layer, '' for any other layer
function SilkSideOfLayer(Layer: Integer): String;
begin
    Result := '';
    if (Layer = eTopOverlay) or (Layer = eTopSolder) then
        Result := 'T'
    else if (Layer = eBottomOverlay) or (Layer = eBottomSolder) then
        Result := 'B';
end;

function SilkRectStr(R: TCoordRect; XO, YO: Integer): String;
begin
    Result := SilkLen(R.Left - XO) + '|' + SilkLen(R.Bottom - YO) + '|' +
              SilkLen(R.Right - XO) + '|' + SilkLen(R.Top - YO);
end;

// True for designator/comment strings that are switched off on the component
function SilkTextHidden(Txt: IPCB_Text): Boolean;
begin
    Result := False;
    if Txt.IsDesignator then
    begin
        if (Txt.Component <> nil) then
            Result := not Txt.Component.NameOn;
    end
    else if Txt.IsComment then
    begin
        if (Txt.Component <> nil) then
            Result := not Txt.Component.CommentOn;
    end;
end;

// A pad's solder mask opening on MaskLayer as 'l|b|r|t|flag', or '' when it
// has none there. BoundingRectangleOnLayer can come back shifted from the pad
// for some shapes (seen on an offset SOT-89 tab, TopShape 10, 55 mil off), so
// the result is its union with the pad's own rectangle. flag 1 marks pads
// where the two disagree; the solver treats those as plain rectangles.
function SilkPadMaskStr(Pad: IPCB_Pad; MaskLayer: Integer; XO, YO: Integer): String;
var
    R, C        : TCoordRect;
    L, B, Rt, T : Integer;
    Flag        : String;
begin
    Result := '';
    R := Pad.BoundingRectangleOnLayer(MaskLayer);
    if (R.Right <= R.Left) then
        Exit;
    C := Pad.BoundingRectangle;
    L := R.Left;
    B := R.Bottom;
    Rt := R.Right;
    T := R.Top;
    Flag := '0';
    if (C.Left < L) then begin L := C.Left; Flag := '1'; end;
    if (C.Bottom < B) then begin B := C.Bottom; Flag := '1'; end;
    if (C.Right > Rt) then begin Rt := C.Right; Flag := '1'; end;
    if (C.Top > T) then begin T := C.Top; Flag := '1'; end;
    Result := SilkLen(L - XO) + '|' + SilkLen(B - YO) + '|' + SilkLen(Rt - XO) + '|' +
              SilkLen(T - YO) + '|' + Flag;
end;

// Export everything the silkscreen solver needs to ROOT_DIR\silk_data.txt,
// one pipe-delimited line per object, mils relative to the board origin:
//   B|file                                   the board's file path
//   RULE|S2S|clearance, RULE|S2M|clearance   largest enabled silk rules
//   RULE|EDGE|outline|cutout                 largest text-to-board-edge
//                                            clearances (Board Outline Clearance)
//   O|kind|vx|vy|cx|cy|radius|a1|a2          board outline (kind 0 line, 1 arc)
//   K|x1|y1|x2|y2|...                        board cutout contour
//   C|des|side|x|y|rot|nameon|l|b|r|t|tl|tb|tr|tt|trot|size|width|autopos|mirror|pattern|truetype
//                                            component (bbox without name/comment,
//                                            then the designator text box)
//   Y|owner|l|b|r|t                          3D body extent
//   ST|side|owner|x1|y1|x2|y2|w              silk track
//   SA|side|owner|cx|cy|r|a1|a2|w            silk arc
//   SX|side|owner|kind|l|b|r|t|stroke|tt|rot silk text (D designator, C comment, F free)
//                                            free text adds |text
//   SB|side|owner|l|b|r|t                    silk fill / region extent
//   MP|side|owner|pin|x|y|rot|shape|xs|ys|l|b|r|t|shifted   pad solder mask opening
//   MV|side|owner|x|y|diameter               untented via opening
//   MT|side|owner|x1|y1|x2|y2|w, MB|side|owner|l|b|r|t   solder mask layer objects
function ExportSilkscreenData(ROOT_DIR: String): String;
var
    Board     : IPCB_Board;
    Iterator  : IPCB_BoardIterator;
    Prim      : IPCB_Primitive;
    Comp      : IPCB_Component;
    Lines     : TStringList;
    R, T      : TCoordRect;
    XO, YO    : Integer;
    I         : Integer;
    Side      : String;
    Owner     : String;
    Kind      : String;
    Flag      : String;
    Flag2     : String;
    Detail    : String;
    ObjId     : Integer;
    PrimLayer : Integer;
    Wanted    : Boolean;
    FileName  : String;
    S2S, S2M  : Double;
    EdgeOut   : Double;
    EdgeCut   : Double;
    IsSilk    : Boolean;
    IsMask    : Boolean;
    Diameter  : Integer;
begin
    Board := GetBoardSafe(0);
    if (Board = nil) then
    begin
        Result := 'ERROR: No PCB document is currently active';
        Exit;
    end;

    XO := Board.XOrigin;
    YO := Board.YOrigin;
    S2S := -1;
    S2M := -1;
    EdgeOut := -1;
    EdgeCut := -1;
    Lines := TStringList.Create;

    try
        Lines.Add('V|1');
        Lines.Add('B|' + Board.FileName);

        // Design rules: the largest enabled silk clearances
        Iterator := Board.BoardIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(eRuleObject));
        Iterator.AddFilter_LayerSet(AllLayers);
        Iterator.AddFilter_Method(eProcessAll);
        Prim := Iterator.FirstPCBObject;
        while (Prim <> nil) do
        begin
            if Prim.Enabled then
            begin
                if (Prim.RuleKind = eRule_SilkToSilkClearance) then
                begin
                    if (CoordToMils(Prim.SilkToSilkClearance) > S2S) then
                        S2S := CoordToMils(Prim.SilkToSilkClearance);
                end
                else if (Prim.RuleKind = eRule_SilkToSolderMaskClearance) then
                begin
                    if (CoordToMils(Prim.SilkToMaskGap) > S2M) then
                        S2M := CoordToMils(Prim.SilkToMaskGap);
                end
                else if (Prim.RuleKind = eRule_BoardOutlineClearance) then
                begin
                    // Per-object table; the rule's Gap is only the generic value
                    if (CoordToMils(Prim.GetClearance(eObjectClearanceID_Text, eObjectClearanceID_OutlineEdge)) > EdgeOut) then
                        EdgeOut := CoordToMils(Prim.GetClearance(eObjectClearanceID_Text, eObjectClearanceID_OutlineEdge));
                    if (CoordToMils(Prim.GetClearance(eObjectClearanceID_Text, eObjectClearanceID_CutoutEdge)) > EdgeCut) then
                        EdgeCut := CoordToMils(Prim.GetClearance(eObjectClearanceID_Text, eObjectClearanceID_CutoutEdge));
                end;
            end;
            Prim := Iterator.NextPCBObject;
        end;
        Board.BoardIterator_Destroy(Iterator);
        Lines.Add('RULE|S2S|' + SilkNum(S2S));
        Lines.Add('RULE|S2M|' + SilkNum(S2M));
        if (EdgeOut >= 0) then
            Lines.Add('RULE|EDGE|' + SilkNum(EdgeOut) + '|' + SilkNum(EdgeCut));

        // Board outline, vertex by vertex (arcs start at their vertex)
        for I := 0 to Board.BoardOutline.PointCount - 1 do
            Lines.Add('O|' + IntToStr(Board.BoardOutline.Segments[I].Kind) + '|' +
                SilkLen(Board.BoardOutline.Segments[I].vx - XO) + '|' +
                SilkLen(Board.BoardOutline.Segments[I].vy - YO) + '|' +
                SilkLen(Board.BoardOutline.Segments[I].cx - XO) + '|' +
                SilkLen(Board.BoardOutline.Segments[I].cy - YO) + '|' +
                SilkLen(Board.BoardOutline.Segments[I].Radius) + '|' +
                SilkNum(Board.BoardOutline.Segments[I].Angle1) + '|' +
                SilkNum(Board.BoardOutline.Segments[I].Angle2));

        // Components and their designator text boxes
        Iterator := Board.BoardIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(eComponentObject));
        Iterator.AddFilter_LayerSet(AllLayers);
        Iterator.AddFilter_Method(eProcessAll);
        Comp := Iterator.FirstPCBObject;
        while (Comp <> nil) do
        begin
            R := Comp.BoundingRectangleNoNameComment;
            T := Comp.Name.BoundingRectangle;
            if Comp.NameOn then Flag := '1' else Flag := '0';
            Kind := '0';
            if Comp.Name.MirrorFlag then Kind := '1';
            Flag2 := '0';
            if Comp.Name.UseTTFonts then Flag2 := '1';
            Lines.Add('C|' + Comp.Name.Text + '|' + SilkSideOfLayer(Comp.Name.Layer) + '|' +
                SilkLen(Comp.x - XO) + '|' + SilkLen(Comp.y - YO) + '|' +
                SilkNum(Comp.Rotation) + '|' + Flag + '|' +
                SilkRectStr(R, XO, YO) + '|' + SilkRectStr(T, XO, YO) + '|' +
                SilkNum(Comp.Name.Rotation) + '|' + SilkLen(Comp.Name.Size) + '|' +
                SilkLen(Comp.Name.Width) + '|' + IntToStr(Comp.NameAutoPosition) + '|' +
                Kind + '|' + Comp.Pattern + '|' + Flag2);
            Comp := Iterator.NextPCBObject;
        end;
        Board.BoardIterator_Destroy(Iterator);

        // One pass over every other primitive kind the solver cares about
        Iterator := Board.BoardIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject, eTextObject, eFillObject,
                                           eRegionObject, ePadObject, eViaObject, eComponentBodyObject));
        Iterator.AddFilter_LayerSet(AllLayers);
        Iterator.AddFilter_Method(eProcessAll);
        Prim := Iterator.FirstPCBObject;
        while (Prim <> nil) do
        begin
            // Every property read leaks a little memory in the script engine
            // (about 40 MB per export on a 40k-object board), so each object's
            // kind and layer are read once, objects that produce no line are
            // skipped before anything else is read, and the owner is read
            // only for the rest
            ObjId := Prim.ObjectId;
            PrimLayer := Prim.Layer;
            IsSilk := (PrimLayer = eTopOverlay) or (PrimLayer = eBottomOverlay);
            IsMask := (PrimLayer = eTopSolder) or (PrimLayer = eBottomSolder);
            Wanted := IsSilk or IsMask or (ObjId = ePadObject) or (ObjId = eViaObject) or
                      (ObjId = eComponentBodyObject) or (ObjId = eRegionObject);
            Owner := '';
            if Wanted then
                if Prim.InComponent then
                begin
                    Comp := Prim.Component;
                    if (Comp <> nil) then
                        Owner := Comp.Name.Text;
                end;
            Side := SilkSideOfLayer(PrimLayer);

            if not Wanted then
                Side := Side        // nothing to export
            else if (ObjId = eTrackObject) then
            begin
                if IsSilk or IsMask then
                begin
                    if IsSilk then Kind := 'ST' else Kind := 'MT';
                    Lines.Add(Kind + '|' + Side + '|' + Owner + '|' +
                        SilkLen(Prim.X1 - XO) + '|' + SilkLen(Prim.Y1 - YO) + '|' +
                        SilkLen(Prim.X2 - XO) + '|' + SilkLen(Prim.Y2 - YO) + '|' +
                        SilkLen(Prim.Width));
                end;
            end
            else if (ObjId = eArcObject) then
            begin
                if IsSilk then
                    Lines.Add('SA|' + Side + '|' + Owner + '|' +
                        SilkLen(Prim.XCenter - XO) + '|' + SilkLen(Prim.YCenter - YO) + '|' +
                        SilkLen(Prim.Radius) + '|' + SilkNum(Prim.StartAngle) + '|' +
                        SilkNum(Prim.EndAngle) + '|' + SilkLen(Prim.LineWidth))
                else if IsMask then
                    Lines.Add('MB|' + Side + '|' + Owner + '|' + SilkRectStr(Prim.BoundingRectangle, XO, YO));
            end
            else if (ObjId = eTextObject) then
            begin
                if IsSilk then
                begin
                    if (not SilkTextHidden(Prim)) then
                    begin
                        if Prim.IsDesignator then Kind := 'D'
                        else if Prim.IsComment then Kind := 'C'
                        else Kind := 'F';
                        Flag := '0';
                        if Prim.UseTTFonts then Flag := '1';
                        Detail := '';
                        if (Kind = 'F') then
                            Detail := '|' + StringReplace(Prim.Text, '|', '/', REPLACEALL);
                        Lines.Add('SX|' + Side + '|' + Owner + '|' + Kind + '|' +
                            SilkRectStr(Prim.BoundingRectangle, XO, YO) + '|' +
                            SilkLen(Prim.Width) + '|' + Flag + '|' + SilkNum(Prim.Rotation) + Detail);
                    end;
                end;
            end
            else if (ObjId = eFillObject) then
            begin
                if IsSilk then
                    Lines.Add('SB|' + Side + '|' + Owner + '|' + SilkRectStr(Prim.BoundingRectangle, XO, YO))
                else if IsMask then
                    Lines.Add('MB|' + Side + '|' + Owner + '|' + SilkRectStr(Prim.BoundingRectangle, XO, YO));
            end
            else if (ObjId = eRegionObject) then
            begin
                if (Prim.Kind = eRegionKind_BoardCutout) then
                begin
                    // Contour vertices; a 'Layer Stack Region' also reports this
                    // kind and spans the whole board - the solver drops those
                    Kind := 'K';
                    for I := 0 to Prim.MainContour.Count - 1 do
                        Kind := Kind + '|' + SilkLen(Prim.MainContour.x[I] - XO) + '|' +
                                SilkLen(Prim.MainContour.y[I] - YO);
                    Lines.Add(Kind);
                end
                else if IsSilk then
                    Lines.Add('SB|' + Side + '|' + Owner + '|' + SilkRectStr(Prim.BoundingRectangle, XO, YO))
                else if IsMask then
                    Lines.Add('MB|' + Side + '|' + Owner + '|' + SilkRectStr(Prim.BoundingRectangle, XO, YO));
            end
            else if (ObjId = ePadObject) then
            begin
                // Mask opening per side (see SilkPadMaskStr)
                if ((PrimLayer = eTopLayer) or (PrimLayer = eMultiLayer)) and (not Prim.IsTenting_Top) then
                begin
                    Kind := SilkPadMaskStr(Prim, eTopSolder, XO, YO);
                    if (Kind <> '') then
                        Lines.Add('MP|T|' + Owner + '|' + Prim.Name + '|' +
                            SilkLen(Prim.x - XO) + '|' + SilkLen(Prim.y - YO) + '|' +
                            SilkNum(Prim.Rotation) + '|' + IntToStr(Prim.TopShape) + '|' +
                            SilkLen(Prim.TopXSize) + '|' + SilkLen(Prim.TopYSize) + '|' + Kind);
                end;
                if ((PrimLayer = eBottomLayer) or (PrimLayer = eMultiLayer)) and (not Prim.IsTenting_Bottom) then
                begin
                    Kind := SilkPadMaskStr(Prim, eBottomSolder, XO, YO);
                    if (Kind <> '') then
                        Lines.Add('MP|B|' + Owner + '|' + Prim.Name + '|' +
                            SilkLen(Prim.x - XO) + '|' + SilkLen(Prim.y - YO) + '|' +
                            SilkNum(Prim.Rotation) + '|' + IntToStr(Prim.BotShape) + '|' +
                            SilkLen(Prim.BotXSize) + '|' + SilkLen(Prim.BotYSize) + '|' + Kind);
                end;
            end
            else if (ObjId = eViaObject) then
            begin
                Diameter := Prim.Size;
                if (Prim.SolderMaskExpansion > 0) then
                    Diameter := Diameter + 2 * Prim.SolderMaskExpansion;
                if Prim.IntersectLayer(eTopLayer) and (not Prim.IsTenting_Top) then
                    Lines.Add('MV|T|' + Owner + '|' + SilkLen(Prim.x - XO) + '|' + SilkLen(Prim.y - YO) + '|' +
                        SilkLen(Diameter));
                if Prim.IntersectLayer(eBottomLayer) and (not Prim.IsTenting_Bottom) then
                    Lines.Add('MV|B|' + Owner + '|' + SilkLen(Prim.x - XO) + '|' + SilkLen(Prim.y - YO) + '|' +
                        SilkLen(Diameter));
            end
            else if (ObjId = eComponentBodyObject) then
            begin
                if (Owner <> '') then
                    Lines.Add('Y|' + Owner + '|' + SilkRectStr(Prim.BoundingRectangle, XO, YO));
            end;

            Prim := Iterator.NextPCBObject;
        end;
        Board.BoardIterator_Destroy(Iterator);

        FileName := ROOT_DIR + 'silk_data.txt';
        Lines.SaveToFile(FileName);
        Result := '{"file": "' + JSONEscapeString(FileName) + '", "line_count": ' + IntToStr(Lines.Count) + '}';
    finally
        Lines.Free;
    end;
end;

// Move designators so their text box is centred on a given point.
// Each entry is 'Designator|CX|CY|Rotation|Height|StrokeWidth|Visible' in
// mils relative to the board origin; an empty field keeps the current value
// (Visible is 1 or 0). Positioning by box centre makes the result independent
// of the text anchor, justification and bottom-side mirroring. The whole
// batch is one undo step.
function PlaceDesignatorsFromList(EntriesList: TStringList): String;
var
    Board        : IPCB_Board;
    Comp         : IPCB_Component;
    Txt          : IPCB_Text;
    R            : TCoordRect;
    Entry        : String;
    Designator   : String;
    FieldValue   : String;
    ResultProps  : TStringList;
    MissingArray : TStringList;
    PlacedArray  : TStringList;
    MovedTexts   : TStringList;
    TextProps    : TStringList;
    XO, YO       : Integer;
    TargetX      : Integer;
    TargetY      : Integer;
    DX, DY       : Integer;
    Pass         : Integer;
    i            : Integer;
begin
    Board := GetBoardSafe(0);
    if (Board = nil) then
    begin
        Result := 'ERROR: No PCB document is currently active';
        Exit;
    end;

    XO := Board.XOrigin;
    YO := Board.YOrigin;
    ResultProps := TStringList.Create;
    MissingArray := TStringList.Create;
    PlacedArray := TStringList.Create;
    MovedTexts := TStringList.Create;

    try
        PCBServer.PreProcess;

        for i := 0 to EntriesList.Count - 1 do
        begin
            Entry := Trim(EntriesList[i]);
            if (Entry <> '') then
            begin
                Designator := Trim(GetFieldFromPipeString(Entry, 0));
                Comp := Board.GetPcbComponentByRefDes(Designator);

                if (Comp = nil) then
                    MissingArray.Add('"' + JSONEscapeString(Designator) + '"')
                else
                begin
                    Txt := Comp.Name;
                    PCBServer.SendMessageToRobots(Comp.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
                    PCBServer.SendMessageToRobots(Txt.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);

                    FieldValue := Trim(GetFieldFromPipeString(Entry, 6));
                    if (FieldValue = '0') then
                        Comp.NameOn := False
                    else if (FieldValue = '1') then
                        Comp.NameOn := True;

                    // Manual, or Altium re-autopositions the text on the next move
                    Comp.NameAutoPosition := eAutoPos_Manual;

                    FieldValue := Trim(GetFieldFromPipeString(Entry, 4));
                    if (FieldValue <> '') then
                        Txt.Size := MilsToCoord(SafeStrToFloat(FieldValue));
                    FieldValue := Trim(GetFieldFromPipeString(Entry, 5));
                    if (FieldValue <> '') then
                        Txt.Width := MilsToCoord(SafeStrToFloat(FieldValue));
                    FieldValue := Trim(GetFieldFromPipeString(Entry, 3));
                    if (FieldValue <> '') then
                        Txt.Rotation := SafeStrToFloat(FieldValue);

                    PCBServer.SendMessageToRobots(Txt.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
                    PCBServer.SendMessageToRobots(Comp.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);

                    // Move only after the rotation is committed: mid-modify the
                    // box turns about its centre, but Altium can commit the
                    // turn about another pivot, so measure the committed box.
                    // A second pass corrects any residual shift.
                    FieldValue := Trim(GetFieldFromPipeString(Entry, 1));
                    if (FieldValue <> '') and (Trim(GetFieldFromPipeString(Entry, 2)) <> '') then
                    begin
                        TargetX := MilsToCoord(SafeStrToFloat(FieldValue)) + XO;
                        TargetY := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 2)))) + YO;
                        for Pass := 1 to 2 do
                        begin
                            R := Txt.BoundingRectangle;
                            DX := TargetX - (R.Left + (R.Right - R.Left) div 2);
                            DY := TargetY - (R.Bottom + (R.Top - R.Bottom) div 2);
                            if (Abs(DX) > 1) or (Abs(DY) > 1) then
                            begin
                                PCBServer.SendMessageToRobots(Txt.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
                                Txt.MoveByXY(DX, DY);
                                PCBServer.SendMessageToRobots(Txt.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
                            end;
                        end;
                    end;

                    MovedTexts.AddObject(Designator, Txt);

                    // Report the final text box as Altium sees it
                    R := Txt.BoundingRectangle;
                    TextProps := TStringList.Create;
                    try
                        AddJSONProperty(TextProps, 'designator', Comp.Name.Text);
                        AddJSONNumber(TextProps, 'cx', CoordToMils(R.Left + (R.Right - R.Left) div 2 - XO));
                        AddJSONNumber(TextProps, 'cy', CoordToMils(R.Bottom + (R.Top - R.Bottom) div 2 - YO));
                        AddJSONNumber(TextProps, 'width', CoordToMils(R.Right - R.Left));
                        AddJSONNumber(TextProps, 'height', CoordToMils(R.Top - R.Bottom));
                        AddJSONNumber(TextProps, 'rotation', Txt.Rotation);
                        AddJSONNumber(TextProps, 'text_height', CoordToMils(Txt.Size));
                        AddJSONNumber(TextProps, 'stroke_width', CoordToMils(Txt.Width));
                        AddJSONBoolean(TextProps, 'visible', Comp.NameOn);
                        PlacedArray.Add(BuildJSONObject(TextProps, 2));
                    finally
                        TextProps.Free;
                    end;
                end;
            end;
        end;

        PCBServer.PostProcess;

        // Rebuild the stroke geometry of every moved text: batch DRC checks a
        // cached copy that scripted moves and resizes leave stale, reporting
        // collisions (and missing real ones) at the old spot. Done after the
        // undo group closes: inside it the rebuild does not stick.
        for i := 0 to MovedTexts.Count - 1 do
        begin
            Txt := MovedTexts.Objects[i];
            Txt.BeginModify;
            Txt.SetState_XSizeYSize;
            Txt.EndModify;
            Txt.GraphicallyInvalidate;
        end;
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        AddJSONInteger(ResultProps, 'placed_count', PlacedArray.Count);
        if (MissingArray.Count > 0) then
            ResultProps.Add(BuildJSONArray(MissingArray, 'missing_designators'))
        else
            ResultProps.Add('"missing_designators": []');
        if (PlacedArray.Count > 0) then
            ResultProps.Add(BuildJSONArray(PlacedArray, 'designators', 1))
        else
            ResultProps.Add('"designators": []');

        Result := BuildJSONObject(ResultProps);
    finally
        ResultProps.Free;
        MissingArray.Free;
        PlacedArray.Free;
        MovedTexts.Free;
    end;
end;

// Verify designator silkscreen with Altium's own rule engine. Each visible
// designator in the list (all visible designators when the list is empty) is
// tested against nearby silk with the Silk To Silk Clearance rule and against
// pads, vias and solder mask objects with the Silk To Solder Mask Clearance
// rule, and against the board edge with the Board Outline Clearance rule,
// through Rule.ActualCheck - the same test a batch DRC runs.
function CheckSilkscreen(DesignatorsList: TStringList): String;
var
    Board           : IPCB_Board;
    Iterator        : IPCB_BoardIterator;
    SIter           : IPCB_SpatialIterator;
    Comp            : IPCB_Component;
    Txt             : IPCB_Text;
    Prim            : IPCB_Primitive;
    Rule            : IPCB_Rule;
    Targets         : TStringList;
    MissingArray    : TStringList;
    ViolationsArray : TStringList;
    VProps          : TStringList;
    ResultProps     : TStringList;
    R, PR           : TCoordRect;
    XO, YO          : Integer;
    Margin          : Integer;
    SilkLayer       : Integer;
    MaskLayer       : Integer;
    CopperLayer     : Integer;
    i               : Integer;
    RuleName        : String;
    Detail          : String;
    Owner           : String;
    HiddenCount     : Integer;
    CheckedCount    : Integer;
    DirtyCount      : Integer;
    Dirty           : Boolean;
    Skip            : Boolean;
begin
    Board := GetBoardSafe(0);
    if (Board = nil) then
    begin
        Result := 'ERROR: No PCB document is currently active';
        Exit;
    end;

    XO := Board.XOrigin;
    YO := Board.YOrigin;
    // Search radius around each text box; larger than any sane silk clearance
    Margin := MilsToCoord(30);
    HiddenCount := 0;
    CheckedCount := 0;
    DirtyCount := 0;

    Targets := TStringList.Create;
    MissingArray := TStringList.Create;
    ViolationsArray := TStringList.Create;
    ResultProps := TStringList.Create;

    try
        if (DesignatorsList.Count > 0) then
        begin
            for i := 0 to DesignatorsList.Count - 1 do
            begin
                if (Board.GetPcbComponentByRefDes(Trim(DesignatorsList[i])) <> nil) then
                    Targets.Add(Trim(DesignatorsList[i]))
                else
                    MissingArray.Add('"' + JSONEscapeString(Trim(DesignatorsList[i])) + '"');
            end;
        end
        else
        begin
            Iterator := Board.BoardIterator_Create;
            Iterator.AddFilter_ObjectSet(MkSet(eComponentObject));
            Iterator.AddFilter_LayerSet(AllLayers);
            Iterator.AddFilter_Method(eProcessAll);
            Comp := Iterator.FirstPCBObject;
            while (Comp <> nil) do
            begin
                Targets.Add(Comp.Name.Text);
                Comp := Iterator.NextPCBObject;
            end;
            Board.BoardIterator_Destroy(Iterator);
        end;

        for i := 0 to Targets.Count - 1 do
        begin
            Comp := Board.GetPcbComponentByRefDes(Targets[i]);
            Txt := Comp.Name;
            SilkLayer := Txt.Layer;

            if (not Comp.NameOn) or ((SilkLayer <> eTopOverlay) and (SilkLayer <> eBottomOverlay)) then
                HiddenCount := HiddenCount + 1
            else
            begin
                CheckedCount := CheckedCount + 1;
                Dirty := False;
                if (SilkLayer = eTopOverlay) then
                begin
                    MaskLayer := eTopSolder;
                    CopperLayer := eTopLayer;
                end
                else
                begin
                    MaskLayer := eBottomSolder;
                    CopperLayer := eBottomLayer;
                end;

                R := Txt.BoundingRectangle;
                SIter := Board.SpatialIterator_Create;
                SIter.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject, eTextObject, eFillObject,
                                                eRegionObject, ePadObject, eViaObject));
                SIter.AddFilter_LayerSet(AllLayers);
                SIter.AddFilter_Area(R.Left - Margin, R.Bottom - Margin, R.Right + Margin, R.Top + Margin);

                Prim := SIter.FirstPCBObject;
                while (Prim <> nil) do
                begin
                    RuleName := '';
                    if (Prim.I_ObjectAddress <> Txt.I_ObjectAddress) then
                    begin
                        if (Prim.Layer = SilkLayer) then
                        begin
                            // No short-circuit evaluation in DelphiScript:
                            // only ask text objects whether they are hidden
                            Skip := False;
                            if (Prim.ObjectId = eTextObject) then
                                Skip := SilkTextHidden(Prim);
                            if not Skip then
                            begin
                                Rule := Board.FindDominantRuleForObjectPair(Txt, Prim, eRule_SilkToSilkClearance);
                                if (Rule <> nil) then
                                    if (Rule.ActualCheck(Txt, Prim) <> nil) then
                                        RuleName := 'silk_to_silk';
                            end;
                        end
                        else if (((Prim.ObjectId = ePadObject) and
                                  ((Prim.Layer = CopperLayer) or (Prim.Layer = eMultiLayer))) or
                                 (Prim.ObjectId = eViaObject) or (Prim.Layer = MaskLayer)) then
                        begin
                            Rule := Board.FindDominantRuleForObjectPair(Txt, Prim, eRule_SilkToSolderMaskClearance);
                            if (Rule <> nil) then
                                if (Rule.ActualCheck(Txt, Prim) <> nil) or (Rule.ActualCheck(Prim, Txt) <> nil) then
                                    RuleName := 'silk_to_mask';
                        end;
                    end;

                    if (RuleName <> '') then
                    begin
                        Dirty := True;
                        Owner := '';
                        if Prim.InComponent then
                            if (Prim.Component <> nil) then
                                Owner := Prim.Component.Name.Text;
                        Detail := '';
                        if (Prim.ObjectId = ePadObject) then
                            Detail := Prim.Name
                        else if (Prim.ObjectId = eTextObject) then
                            Detail := Prim.Text;

                        PR := Prim.BoundingRectangle;
                        VProps := TStringList.Create;
                        try
                            AddJSONProperty(VProps, 'designator', Comp.Name.Text);
                            AddJSONProperty(VProps, 'rule', RuleName);
                            AddJSONProperty(VProps, 'object', Prim.ObjectIDString);
                            AddJSONProperty(VProps, 'owner', Owner);
                            AddJSONProperty(VProps, 'detail', Detail);
                            if (RuleName = 'silk_to_silk') then
                                AddJSONNumber(VProps, 'distance_mils', Round(CoordToMils(Board.PrimPrimDistance(Txt, Prim)) * 100) / 100);
                            AddJSONNumber(VProps, 'object_x', CoordToMils(PR.Left + (PR.Right - PR.Left) div 2 - XO));
                            AddJSONNumber(VProps, 'object_y', CoordToMils(PR.Bottom + (PR.Top - PR.Bottom) div 2 - YO));
                            ViolationsArray.Add(BuildJSONObject(VProps, 2));
                        finally
                            VProps.Free;
                        end;
                    end;

                    Prim := SIter.NextPCBObject;
                end;
                Board.SpatialIterator_Destroy(SIter);

                // Board Outline Clearance: text to the board edge and cutouts,
                // measured from the text's bounding box
                Rule := Board.FindDominantRuleForObject(Txt, eRule_BoardOutlineClearance);
                if (Rule <> nil) then
                    if (Rule.ActualCheck(Txt, Board.BoardOutline) <> nil) then
                    begin
                        Dirty := True;
                        VProps := TStringList.Create;
                        try
                            AddJSONProperty(VProps, 'designator', Comp.Name.Text);
                            AddJSONProperty(VProps, 'rule', 'board_edge');
                            AddJSONProperty(VProps, 'object', 'Board outline');
                            AddJSONProperty(VProps, 'owner', '');
                            AddJSONProperty(VProps, 'detail', '');
                            AddJSONNumber(VProps, 'distance_mils', Round(CoordToMils(Board.PrimPrimDistance(Txt, Board.BoardOutline)) * 100) / 100);
                            ViolationsArray.Add(BuildJSONObject(VProps, 2));
                        finally
                            VProps.Free;
                        end;
                    end;

                if Dirty then
                    DirtyCount := DirtyCount + 1;
            end;
        end;

        AddJSONInteger(ResultProps, 'checked_count', CheckedCount);
        AddJSONInteger(ResultProps, 'hidden_count', HiddenCount);
        AddJSONInteger(ResultProps, 'designators_with_violations', DirtyCount);
        AddJSONInteger(ResultProps, 'violation_count', ViolationsArray.Count);
        if (MissingArray.Count > 0) then
            ResultProps.Add(BuildJSONArray(MissingArray, 'missing_designators'))
        else
            ResultProps.Add('"missing_designators": []');
        if (ViolationsArray.Count > 0) then
            ResultProps.Add(BuildJSONArray(ViolationsArray, 'violations', 1))
        else
            ResultProps.Add('"violations": []');

        Result := BuildJSONObject(ResultProps);
    finally
        Targets.Free;
        MissingArray.Free;
        ViolationsArray.Free;
        ResultProps.Free;
    end;
end;

// Check one free silk primitive (a label-block link) with Altium's silk
// rules, as CheckSilkscreen does for designators: one JSON violation per
// problem, tagged with the request item it came from.
procedure SilkGraphicViolations(Board: IPCB_Board; Prim: IPCB_Primitive; ItemIndex: Integer; ViolationsArray: TStringList);
var
    SIter       : IPCB_SpatialIterator;
    Other       : IPCB_Primitive;
    Rule        : IPCB_Rule;
    R           : TCoordRect;
    Margin      : Integer;
    MaskLayer   : Integer;
    CopperLayer : Integer;
    RuleName    : String;
    Owner       : String;
    Detail      : String;
    Skip        : Boolean;
    VProps      : TStringList;
begin
    if (Prim.Layer = eTopOverlay) then
    begin
        MaskLayer := eTopSolder;
        CopperLayer := eTopLayer;
    end
    else
    begin
        MaskLayer := eBottomSolder;
        CopperLayer := eBottomLayer;
    end;
    Margin := MilsToCoord(30);
    R := Prim.BoundingRectangle;
    SIter := Board.SpatialIterator_Create;
    SIter.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject, eTextObject, eFillObject,
                                    eRegionObject, ePadObject, eViaObject));
    SIter.AddFilter_LayerSet(AllLayers);
    SIter.AddFilter_Area(R.Left - Margin, R.Bottom - Margin, R.Right + Margin, R.Top + Margin);
    Other := SIter.FirstPCBObject;
    while (Other <> nil) do
    begin
        RuleName := '';
        if (Other.I_ObjectAddress <> Prim.I_ObjectAddress) then
        begin
            if (Other.Layer = Prim.Layer) then
            begin
                Skip := False;
                if (Other.ObjectId = eTextObject) then
                    Skip := SilkTextHidden(Other);
                if not Skip then
                begin
                    Rule := Board.FindDominantRuleForObjectPair(Prim, Other, eRule_SilkToSilkClearance);
                    if (Rule <> nil) then
                        if (Rule.ActualCheck(Prim, Other) <> nil) then
                            RuleName := 'silk_to_silk';
                end;
            end
            else if (((Other.ObjectId = ePadObject) and
                      ((Other.Layer = CopperLayer) or (Other.Layer = eMultiLayer))) or
                     (Other.ObjectId = eViaObject) or (Other.Layer = MaskLayer)) then
            begin
                Rule := Board.FindDominantRuleForObjectPair(Prim, Other, eRule_SilkToSolderMaskClearance);
                if (Rule <> nil) then
                    if (Rule.ActualCheck(Prim, Other) <> nil) or (Rule.ActualCheck(Other, Prim) <> nil) then
                        RuleName := 'silk_to_mask';
            end;
        end;
        if (RuleName <> '') then
        begin
            Owner := '';
            if Other.InComponent then
                if (Other.Component <> nil) then
                    Owner := Other.Component.Name.Text;
            Detail := '';
            if (Other.ObjectId = ePadObject) then
                Detail := Other.Name
            else if (Other.ObjectId = eTextObject) then
                Detail := Other.Text;
            VProps := TStringList.Create;
            try
                AddJSONInteger(VProps, 'item', ItemIndex);
                AddJSONProperty(VProps, 'rule', RuleName);
                AddJSONProperty(VProps, 'object', Other.ObjectIDString);
                AddJSONProperty(VProps, 'owner', Owner);
                AddJSONProperty(VProps, 'detail', Detail);
                ViolationsArray.Add(BuildJSONObject(VProps, 2));
            finally
                VProps.Free;
            end;
        end;
        Other := SIter.NextPCBObject;
    end;
    Board.SpatialIterator_Destroy(SIter);

    Rule := Board.FindDominantRuleForObject(Prim, eRule_BoardOutlineClearance);
    if (Rule <> nil) then
        if (Rule.ActualCheck(Prim, Board.BoardOutline) <> nil) then
        begin
            VProps := TStringList.Create;
            try
                AddJSONInteger(VProps, 'item', ItemIndex);
                AddJSONProperty(VProps, 'rule', 'board_edge');
                AddJSONProperty(VProps, 'object', 'Board outline');
                AddJSONProperty(VProps, 'owner', '');
                AddJSONProperty(VProps, 'detail', '');
                ViolationsArray.Add(BuildJSONObject(VProps, 2));
            finally
                VProps.Free;
            end;
        end;
end;

// The free silk primitive matching a '-' item (without the '-'), or nil.
// Tracks match by end points (either direction), arcs by centre, radius and
// angles, text by its string and the centre of its box.
function FindSilkGraphic(Board: IPCB_Board; Entry: String; Layer: Integer): IPCB_Primitive;
var
    Iterator  : IPCB_BoardIterator;
    Prim      : IPCB_Primitive;
    Kind      : String;
    R         : TCoordRect;
    Tol       : Integer;
    X1, Y1    : Integer;
    X2, Y2    : Integer;
    CR        : Integer;
    A1, A2    : Integer;
    TextValue : String;
    Hit       : Boolean;
begin
    Result := nil;
    Tol := MilsToCoord(0.2);
    Kind := GetFieldFromPipeString(Entry, 0);
    X1 := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 2)))) + Board.XOrigin;
    Y1 := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 3)))) + Board.YOrigin;
    X2 := 0;
    Y2 := 0;
    CR := 0;
    A1 := 0;
    A2 := 0;
    TextValue := '';
    if (Kind = 'T') then
    begin
        X2 := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 4)))) + Board.XOrigin;
        Y2 := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 5)))) + Board.YOrigin;
    end
    else if (Kind = 'A') then
    begin
        CR := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 4))));
        A1 := Round(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 5))) * 100);
        A2 := Round(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 6))) * 100);
    end
    else
        TextValue := GetFieldFromPipeString(Entry, 7);

    Iterator := Board.BoardIterator_Create;
    Iterator.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject, eTextObject));
    Iterator.AddFilter_IPCB_LayerSet(MkSet(Layer));
    Iterator.AddFilter_Method(eProcessAll);
    Prim := Iterator.FirstPCBObject;
    while (Prim <> nil) do
    begin
        Hit := False;
        if not Prim.InComponent then
        begin
            if (Kind = 'T') and (Prim.ObjectId = eTrackObject) then
            begin
                if (Abs(Prim.X1 - X1) <= Tol) and (Abs(Prim.Y1 - Y1) <= Tol) and
                   (Abs(Prim.X2 - X2) <= Tol) and (Abs(Prim.Y2 - Y2) <= Tol) then
                    Hit := True
                else if (Abs(Prim.X1 - X2) <= Tol) and (Abs(Prim.Y1 - Y2) <= Tol) and
                        (Abs(Prim.X2 - X1) <= Tol) and (Abs(Prim.Y2 - Y1) <= Tol) then
                    Hit := True;
            end
            else if (Kind = 'A') and (Prim.ObjectId = eArcObject) then
            begin
                if (Abs(Prim.XCenter - X1) <= Tol) and (Abs(Prim.YCenter - Y1) <= Tol) and
                   (Abs(Prim.Radius - CR) <= Tol) and (Abs(Round(Prim.StartAngle * 100) - A1) <= 1) and
                   (Abs(Round(Prim.EndAngle * 100) - A2) <= 1) then
                    Hit := True;
            end
            else if (Kind = 'X') and (Prim.ObjectId = eTextObject) then
            begin
                if (Prim.Text = TextValue) then
                begin
                    R := Prim.BoundingRectangle;
                    if (Abs((R.Left + R.Right) div 2 - X1) <= MilsToCoord(1)) and
                       (Abs((R.Bottom + R.Top) div 2 - Y1) <= MilsToCoord(1)) then
                        Hit := True;
                end;
            end;
        end;
        if Hit then
        begin
            Result := Prim;
            Break;
        end;
        Prim := Iterator.NextPCBObject;
    end;
    Board.BoardIterator_Destroy(Iterator);
end;

// Add or remove free silkscreen graphics (the links of label blocks) in one
// undo step. Items, coordinates in mils from the board origin:
//   +T|side|x1|y1|x2|y2|width                   track
//   +A|side|cx|cy|radius|start|end|width        arc (degrees, CCW; 0 to 360 = circle)
//   +X|side|cx|cy|height|stroke|rotation|text   stroke text, box centred on cx, cy
// The same with '-' removes the matching free primitive. Every created
// primitive is then checked with Altium's silk rules.
function EditSilkGraphics(ItemsList: TStringList): String;
var
    Board           : IPCB_Board;
    Prim            : IPCB_Primitive;
    CreatedList     : TStringList;
    RemoveList      : TStringList;
    MissingArray    : TStringList;
    ViolationsArray : TStringList;
    ResultProps     : TStringList;
    Entry           : String;
    Op              : String;
    Kind            : String;
    Layer           : Integer;
    XO, YO          : Integer;
    TX, TY          : Integer;
    R               : TCoordRect;
    i               : Integer;
begin
    Board := GetBoardSafe(0);
    if (Board = nil) then
    begin
        Result := 'ERROR: No PCB document is currently active';
        Exit;
    end;
    XO := Board.XOrigin;
    YO := Board.YOrigin;
    CreatedList := TStringList.Create;
    RemoveList := TStringList.Create;
    MissingArray := TStringList.Create;
    ViolationsArray := TStringList.Create;
    ResultProps := TStringList.Create;
    try
        PCBServer.PreProcess;

        // Removals first, so they can never match what this call creates
        for i := 0 to ItemsList.Count - 1 do
        begin
            Entry := Trim(ItemsList[i]);
            if (Copy(Entry, 1, 1) = '-') then
            begin
                Entry := Copy(Entry, 2, Length(Entry) - 1);
                if (GetFieldFromPipeString(Entry, 1) = 'B') then
                    Layer := eBottomOverlay
                else
                    Layer := eTopOverlay;
                Prim := FindSilkGraphic(Board, Entry, Layer);
                if (Prim <> nil) then
                    RemoveList.AddObject(IntToStr(i), Prim)
                else
                    MissingArray.Add('"' + JSONEscapeString(Entry) + '"');
            end;
        end;
        for i := 0 to RemoveList.Count - 1 do
            Board.RemovePCBObject(RemoveList.Objects[i]);

        for i := 0 to ItemsList.Count - 1 do
        begin
            Entry := Trim(ItemsList[i]);
            Op := Copy(Entry, 1, 1);
            Entry := Copy(Entry, 2, Length(Entry) - 1);
            Kind := GetFieldFromPipeString(Entry, 0);
            if (GetFieldFromPipeString(Entry, 1) = 'B') then
                Layer := eBottomOverlay
            else
                Layer := eTopOverlay;
            Prim := nil;
            if (Op = '+') and (Kind = 'T') then
            begin
                Prim := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
                Prim.Layer := Layer;
                Prim.X1 := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 2)))) + XO;
                Prim.Y1 := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 3)))) + YO;
                Prim.X2 := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 4)))) + XO;
                Prim.Y2 := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 5)))) + YO;
                Prim.Width := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 6))));
                Board.AddPCBObject(Prim);
                PCBServer.SendMessageToRobots(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Prim.I_ObjectAddress);
            end
            else if (Op = '+') and (Kind = 'A') then
            begin
                Prim := PCBServer.PCBObjectFactory(eArcObject, eNoDimension, eCreate_Default);
                Prim.Layer := Layer;
                Prim.XCenter := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 2)))) + XO;
                Prim.YCenter := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 3)))) + YO;
                Prim.Radius := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 4))));
                Prim.StartAngle := SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 5)));
                Prim.EndAngle := SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 6)));
                Prim.LineWidth := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 7))));
                Board.AddPCBObject(Prim);
                PCBServer.SendMessageToRobots(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Prim.I_ObjectAddress);
            end
            else if (Op = '+') and (Kind = 'X') then
            begin
                TX := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 2)))) + XO;
                TY := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 3)))) + YO;
                Prim := PCBServer.PCBObjectFactory(eTextObject, eNoDimension, eCreate_Default);
                Prim.Layer := Layer;
                Prim.UseTTFonts := False;
                Prim.Text := GetFieldFromPipeString(Entry, 7);
                Prim.Size := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 4))));
                Prim.Width := MilsToCoord(SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 5))));
                Prim.MirrorFlag := (Layer = eBottomOverlay);
                Prim.Rotation := SafeStrToFloat(Trim(GetFieldFromPipeString(Entry, 6)));
                Prim.XLocation := TX;
                Prim.YLocation := TY;
                Board.AddPCBObject(Prim);
                PCBServer.SendMessageToRobots(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Prim.I_ObjectAddress);
                // Centre its box on the target, then rebuild the stroke
                // geometry that batch DRC uses
                R := Prim.BoundingRectangle;
                PCBServer.SendMessageToRobots(Prim.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
                Prim.MoveByXY(TX - (R.Left + R.Right) div 2, TY - (R.Bottom + R.Top) div 2);
                Prim.SetState_XSizeYSize;
                PCBServer.SendMessageToRobots(Prim.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
                Prim.GraphicallyInvalidate;
            end
            else if (Op <> '-') then
                MissingArray.Add('"' + JSONEscapeString('cannot read ' + ItemsList[i]) + '"');
            if (Prim <> nil) then
                CreatedList.AddObject(IntToStr(i), Prim);
        end;

        PCBServer.PostProcess;

        // As for designators: rebuild new text geometry outside the undo group
        for i := 0 to CreatedList.Count - 1 do
        begin
            Prim := CreatedList.Objects[i];
            if (Prim.ObjectId = eTextObject) then
            begin
                Prim.BeginModify;
                Prim.SetState_XSizeYSize;
                Prim.EndModify;
            end;
        end;
        Board.ViewManager_FullUpdate;

        for i := 0 to CreatedList.Count - 1 do
            SilkGraphicViolations(Board, CreatedList.Objects[i], StrToInt(CreatedList[i]), ViolationsArray);

        AddJSONInteger(ResultProps, 'created_count', CreatedList.Count);
        AddJSONInteger(ResultProps, 'removed_count', RemoveList.Count);
        if (MissingArray.Count > 0) then
            ResultProps.Add(BuildJSONArray(MissingArray, 'not_found'))
        else
            ResultProps.Add('"not_found": []');
        if (ViolationsArray.Count > 0) then
            ResultProps.Add(BuildJSONArray(ViolationsArray, 'violations', 1))
        else
            ResultProps.Add('"violations": []');
        Result := BuildJSONObject(ResultProps);
    finally
        CreatedList.Free;
        RemoveList.Free;
        MissingArray.Free;
        ViolationsArray.Free;
        ResultProps.Free;
    end;
end;

// The footprint with this name in a PCB library (case-insensitive), or nil
// Set a pad's paste and solder mask expansion before it is added to a
// footprint. Modes are TMaskExpansionMode ints as text (0 no mask, 1 rule,
// 2 manual), expansions in mils; '' leaves that setting alone. A manual
// expansion goes through the pad cache: the PasteMaskExpansion and
// SolderMaskExpansion setters stop the script. Mode 0 (no mask) cannot be set
// on a pad by script: neither mode setter accepts it, and PasteMaskEnabled
// and tenting are not kept. The result is then a problem to report,
// otherwise ''.
function SetPadMaskExpansion(Pad: IPCB_Pad; PasteMode, PasteExp, MaskMode, MaskExp: String): String;
var
    PadCache : IDispatch;
begin
    Result := '';
    if ((PasteMode = '2') and (PasteExp <> '')) or ((MaskMode = '2') and (MaskExp <> '')) then
    begin
        PadCache := Pad.GetState_Cache;
        if (PasteMode = '2') and (PasteExp <> '') then
        begin
            PadCache.PasteMaskExpansion := MilsToCoord(SafeStrToFloat(PasteExp));
            PadCache.PasteMaskExpansionValid := eCacheManual;
        end;
        if (MaskMode = '2') and (MaskExp <> '') then
        begin
            PadCache.SolderMaskExpansion := MilsToCoord(SafeStrToFloat(MaskExp));
            PadCache.SolderMaskExpansionValid := eCacheManual;
        end;
        Pad.SetState_Cache(PadCache);
    end;
    if (PasteMode = '1') then
        Pad.PasteMaskExpansionMode := 1;
    if (MaskMode = '1') then
        Pad.SolderMaskExpansionMode := 1;
    if (PasteMode = '0') and (MaskMode = '0') then
        Result := 'paste and solder mask mode 0 (no mask) cannot be set on a pad by script; left at rule'
    else if (PasteMode = '0') then
        Result := 'paste mask mode 0 (no mask) cannot be set on a pad by script; left at rule'
    else if (MaskMode = '0') then
        Result := 'solder mask mode 0 (no mask) cannot be set on a pad by script; left at rule';
end;

// ---------------------------------------------------------------------------
// Board-level read-only queries (get_board_summary, get_component_primitives).
// Coordinates are millimetres relative to the board origin.
// ---------------------------------------------------------------------------

// Increment the counter kept for Key in two parallel lists (Keys / Counts).
// TStringList.Values is avoided on purpose: it is unreliable in DelphiScript.
procedure TallyKey(Keys: TStringList; Counts: TStringList; Key: String);
var
    Idx: Integer;
begin
    Idx := Keys.IndexOf(Key);
    if Idx < 0 then
    begin
        Keys.Add(Key);
        Counts.Add('1');
    end
    else
        Counts[Idx] := IntToStr(StrToInt(Counts[Idx]) + 1);
end;

function PrimitiveTypeName(ObjectId: Integer): String;
begin
    if ObjectId = eArcObject then Result := 'arc'
    else if ObjectId = ePadObject then Result := 'pad'
    else if ObjectId = eViaObject then Result := 'via'
    else if ObjectId = eTrackObject then Result := 'track'
    else if ObjectId = eTextObject then Result := 'text'
    else if ObjectId = eFillObject then Result := 'fill'
    else if ObjectId = eRegionObject then Result := 'region'
    else Result := 'object_' + IntToStr(ObjectId);
end;

// Millimetres rounded to 0.1 um. Coordinates are stored in mil units, so
// a metric value comes back with float noise (0.2 mm reads 0.1999996).
function RoundedMMs(Coord: Integer): Double;
begin
    Result := Round(CoordToMMs(Coord) * 10000) / 10000;
end;

// Outline, origin, dimensions, vias by hole size, component sides, primitive
// counts per layer and the free texts on both overlays.
function GetBoardSummary(ROOT_DIR: String): String;
var
    Board        : IPCB_Board;
    Outline      : IPCB_BoardOutline;
    Iterator     : IPCB_BoardIterator;
    Obj          : IPCB_Primitive;
    Comp         : IPCB_Component;
    OX, OY       : Integer;
    I, TopCount, BottomCount, ViaCount : Integer;
    ResultProps  : TStringList;
    Props        : TStringList;
    DimArray     : TStringList;
    TextArray    : TStringList;
    HoleKeys, HoleCounts   : TStringList;
    LayerKeys, LayerCounts : TStringList;
    Items        : TStringList;
    OutputLines  : TStringList;
    LayerName    : String;
begin
    Board := GetBoardSafe(0);
    if Board = Nil then
    begin
        Result := 'ERROR: No PCB document focused';
        Exit;
    end;
    OX := Board.XOrigin;
    OY := Board.YOrigin;

    ResultProps := TStringList.Create;
    DimArray := TStringList.Create;
    TextArray := TStringList.Create;
    HoleKeys := TStringList.Create;
    HoleCounts := TStringList.Create;
    LayerKeys := TStringList.Create;
    LayerCounts := TStringList.Create;
    Items := TStringList.Create;
    try
        AddJSONProperty(ResultProps, 'pcb_path', Board.FileName);
        AddJSONNumber(ResultProps, 'origin_abs_x_mm', RoundedMMs(OX));
        AddJSONNumber(ResultProps, 'origin_abs_y_mm', RoundedMMs(OY));

        Outline := Board.BoardOutline;
        Props := TStringList.Create;
        try
            AddJSONNumber(Props, 'x1_mm', RoundedMMs(Outline.BoundingRectangle.Left - OX));
            AddJSONNumber(Props, 'y1_mm', RoundedMMs(Outline.BoundingRectangle.Bottom - OY));
            AddJSONNumber(Props, 'x2_mm', RoundedMMs(Outline.BoundingRectangle.Right - OX));
            AddJSONNumber(Props, 'y2_mm', RoundedMMs(Outline.BoundingRectangle.Top - OY));
            AddJSONNumber(Props, 'width_mm', RoundedMMs(Outline.BoundingRectangle.Right - Outline.BoundingRectangle.Left));
            AddJSONNumber(Props, 'height_mm', RoundedMMs(Outline.BoundingRectangle.Top - Outline.BoundingRectangle.Bottom));
            AddJSONInteger(Props, 'vertex_count', Outline.PointCount);
            ResultProps.Add('"board_outline": ' + Trim(BuildJSONObject(Props, 1)));
        finally
            Props.Free;
        end;

        // Dimensions (cotas)
        Iterator := Board.BoardIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(eDimensionObject));
        Iterator.AddFilter_LayerSet(AllLayers);
        Iterator.AddFilter_Method(eProcessAll);
        Obj := Iterator.FirstPCBObject;
        while Obj <> Nil do
        begin
            Props := TStringList.Create;
            try
                AddJSONProperty(Props, 'layer', Layer2String(Obj.Layer));
                AddJSONNumber(Props, 'x1_mm', RoundedMMs(Obj.BoundingRectangle.Left - OX));
                AddJSONNumber(Props, 'y1_mm', RoundedMMs(Obj.BoundingRectangle.Bottom - OY));
                AddJSONNumber(Props, 'x2_mm', RoundedMMs(Obj.BoundingRectangle.Right - OX));
                AddJSONNumber(Props, 'y2_mm', RoundedMMs(Obj.BoundingRectangle.Top - OY));
                DimArray.Add(BuildJSONObject(Props, 1));
            finally
                Props.Free;
            end;
            Obj := Iterator.NextPCBObject;
        end;
        Board.BoardIterator_Destroy(Iterator);

        // Vias by hole size
        ViaCount := 0;
        Iterator := Board.BoardIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(eViaObject));
        Iterator.AddFilter_LayerSet(AllLayers);
        Iterator.AddFilter_Method(eProcessAll);
        Obj := Iterator.FirstPCBObject;
        while Obj <> Nil do
        begin
            Inc(ViaCount);
            TallyKey(HoleKeys, HoleCounts, StringReplace(FloatToStr(RoundedMMs(Obj.HoleSize)), ',', '.', REPLACEALL));
            Obj := Iterator.NextPCBObject;
        end;
        Board.BoardIterator_Destroy(Iterator);

        // Components per side
        TopCount := 0;
        BottomCount := 0;
        Iterator := Board.BoardIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(eComponentObject));
        Iterator.AddFilter_LayerSet(AllLayers);
        Iterator.AddFilter_Method(eProcessAll);
        Comp := Iterator.FirstPCBObject;
        while Comp <> Nil do
        begin
            if Comp.Layer = eBottomLayer then Inc(BottomCount) else Inc(TopCount);
            Comp := Iterator.NextPCBObject;
        end;
        Board.BoardIterator_Destroy(Iterator);

        // Primitive counts per layer, and free overlay texts
        Iterator := Board.BoardIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject, eTextObject, eFillObject, eRegionObject, ePadObject));
        Iterator.AddFilter_LayerSet(AllLayers);
        Iterator.AddFilter_Method(eProcessAll);
        Obj := Iterator.FirstPCBObject;
        while Obj <> Nil do
        begin
            LayerName := Layer2String(Obj.Layer);
            if Obj.InComponent then
                TallyKey(LayerKeys, LayerCounts, LayerName + '|component')
            else
                TallyKey(LayerKeys, LayerCounts, LayerName + '|free');
            if (Obj.ObjectId = eTextObject) and (not Obj.InComponent) and
               ((Obj.Layer = eTopOverlay) or (Obj.Layer = eBottomOverlay)) then
                TextArray.Add('{"layer": "' + JSONEscapeString(LayerName) + '", "text": "' + JSONEscapeString(Obj.Text) + '"}');
            Obj := Iterator.NextPCBObject;
        end;
        Board.BoardIterator_Destroy(Iterator);

        ResultProps.Add(BuildJSONArray(DimArray, 'dimensions'));
        AddJSONInteger(ResultProps, 'via_count', ViaCount);
        Items.Clear;
        for I := 0 to HoleKeys.Count - 1 do
            Items.Add('{"hole_mm": ' + HoleKeys[I] + ', "count": ' + HoleCounts[I] + '}');
        ResultProps.Add(BuildJSONArray(Items, 'vias_by_hole'));
        AddJSONInteger(ResultProps, 'components_top', TopCount);
        AddJSONInteger(ResultProps, 'components_bottom', BottomCount);
        Items.Clear;
        for I := 0 to LayerKeys.Count - 1 do
            Items.Add('{"layer": "' + JSONEscapeString(GetFieldFromPipeString(LayerKeys[I], 0)) +
                '", "owner": "' + GetFieldFromPipeString(LayerKeys[I], 1) +
                '", "count": ' + LayerCounts[I] + '}');
        ResultProps.Add(BuildJSONArray(Items, 'layer_contents'));
        ResultProps.Add(BuildJSONArray(TextArray, 'overlay_texts'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := WriteJSONToFile(OutputLines, ROOT_DIR + 'temp_board_summary.json');
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
        DimArray.Free;
        TextArray.Free;
        HoleKeys.Free;
        HoleCounts.Free;
        LayerKeys.Free;
        LayerCounts.Free;
        Items.Free;
    end;
end;

// Layer of every primitive of the given components (e.g. to check that a
// flipped fiducial has its copper and its solder-mask pad on the same side).
function GetComponentPrimitivesFromList(ROOT_DIR: String; DesignatorsList: TStringList): String;
var
    Board       : IPCB_Board;
    Iterator    : IPCB_BoardIterator;
    GroupIter   : IPCB_GroupIterator;
    Comp        : IPCB_Component;
    Prim        : IPCB_Primitive;
    OX, OY      : Integer;
    CompArray   : TStringList;
    PrimArray   : TStringList;
    CompProps   : TStringList;
    PrimProps   : TStringList;
    Missing     : TStringList;
    ResultProps : TStringList;
    OutputLines : TStringList;
    Found       : TStringList;
    I           : Integer;
begin
    Board := GetBoardSafe(0);
    if Board = Nil then
    begin
        Result := 'ERROR: No PCB document focused';
        Exit;
    end;
    OX := Board.XOrigin;
    OY := Board.YOrigin;

    CompArray := TStringList.Create;
    Found := TStringList.Create;
    Missing := TStringList.Create;
    ResultProps := TStringList.Create;
    try
        Iterator := Board.BoardIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(eComponentObject));
        Iterator.AddFilter_LayerSet(AllLayers);
        Iterator.AddFilter_Method(eProcessAll);
        Comp := Iterator.FirstPCBObject;
        while Comp <> Nil do
        begin
            if DesignatorsList.IndexOf(Comp.Name.Text) >= 0 then
            begin
                Found.Add(Comp.Name.Text);
                PrimArray := TStringList.Create;
                CompProps := TStringList.Create;
                try
                    GroupIter := Comp.GroupIterator_Create;
                    GroupIter.AddFilter_ObjectSet(MkSet(ePadObject, eTrackObject, eArcObject, eFillObject, eRegionObject, eTextObject));
                    Prim := GroupIter.FirstPCBObject;
                    while Prim <> Nil do
                    begin
                        PrimProps := TStringList.Create;
                        try
                            AddJSONProperty(PrimProps, 'type', PrimitiveTypeName(Prim.ObjectId));
                            AddJSONProperty(PrimProps, 'layer', Layer2String(Prim.Layer));
                            if Prim.ObjectId = ePadObject then
                            begin
                                AddJSONProperty(PrimProps, 'name', Prim.Name);
                                AddJSONNumber(PrimProps, 'size_x_mm', RoundedMMs(Prim.TopXSize));
                                AddJSONNumber(PrimProps, 'size_y_mm', RoundedMMs(Prim.TopYSize));
                                AddJSONNumber(PrimProps, 'solder_mask_expansion_mm', RoundedMMs(Prim.SolderMaskExpansion));
                                AddJSONNumber(PrimProps, 'paste_mask_expansion_mm', RoundedMMs(Prim.PasteMaskExpansion));
                            end;
                            if Prim.ObjectId = eArcObject then
                            begin
                                AddJSONNumber(PrimProps, 'radius_mm', RoundedMMs(Prim.Radius));
                                AddJSONNumber(PrimProps, 'width_mm', RoundedMMs(Prim.LineWidth));
                            end;
                            if Prim.ObjectId = eTrackObject then
                                AddJSONNumber(PrimProps, 'width_mm', RoundedMMs(Prim.Width));
                            PrimArray.Add(BuildJSONObject(PrimProps, 2));
                        finally
                            PrimProps.Free;
                        end;
                        Prim := GroupIter.NextPCBObject;
                    end;
                    Comp.GroupIterator_Destroy(GroupIter);

                    AddJSONProperty(CompProps, 'designator', Comp.Name.Text);
                    AddJSONProperty(CompProps, 'footprint', Comp.Pattern);
                    AddJSONProperty(CompProps, 'layer', Layer2String(Comp.Layer));
                    AddJSONNumber(CompProps, 'x_mm', RoundedMMs(Comp.X - OX));
                    AddJSONNumber(CompProps, 'y_mm', RoundedMMs(Comp.Y - OY));
                    AddJSONNumber(CompProps, 'rotation', Comp.Rotation);
                    CompProps.Add(BuildJSONArray(PrimArray, 'primitives', 1));
                    CompArray.Add(BuildJSONObject(CompProps, 1));
                finally
                    PrimArray.Free;
                    CompProps.Free;
                end;
            end;
            Comp := Iterator.NextPCBObject;
        end;
        Board.BoardIterator_Destroy(Iterator);

        for I := 0 to DesignatorsList.Count - 1 do
            if Found.IndexOf(DesignatorsList[I]) < 0 then
                Missing.Add('"' + JSONEscapeString(DesignatorsList[I]) + '"');

        ResultProps.Add(BuildJSONArray(CompArray, 'components'));
        ResultProps.Add(BuildJSONArray(Missing, 'missing_designators'));
        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := WriteJSONToFile(OutputLines, ROOT_DIR + 'temp_component_primitives.json');
        finally
            OutputLines.Free;
        end;
    finally
        CompArray.Free;
        Found.Free;
        Missing.Free;
        ResultProps.Free;
    end;
end;

// The kind of a free primitive delete_pcb_objects and modify_pcb_objects act
// on, or '' for one they leave alone: pads, anything of a component, the
// copper a polygon poured (it is the polygon's own and goes with it),
// keepouts, and anything not on a copper layer (board outline, silkscreen,
// mechanical layers). A region is copper ('region') or a polygon pour
// cutout ('cutout'); board cutouts and named regions are left alone.
function EditableKind(Prim: IPCB_Primitive): String;
var
    Copper : Boolean;
begin
    Result := '';
    if Prim.InComponent or Prim.InPolygon then Exit;
    if Prim.ObjectId = eViaObject then
    begin
        Result := 'via';
        Exit;
    end;
    if Prim.IsKeepout then Exit;
    Copper := (Prim.Layer >= eTopLayer) and (Prim.Layer <= eBottomLayer);
    case Prim.ObjectId of
        eTrackObject:  if Copper then Result := 'track';
        eArcObject:    if Copper then Result := 'arc';
        ePolyObject:   if Copper then Result := 'polygon';
        eFillObject:   if Copper then Result := 'fill';
        eRegionObject:
            begin
                if (Prim.Kind = 0) and Copper then Result := 'region'
                else if (Prim.Kind = 1) and (Copper or (Prim.Layer = eMultiLayer)) then Result := 'cutout';
            end;
    end;
end;

// The primitives matching every filter: Kinds is '|track|via|...|', NetName
// and LayerName '' for any, Area 'x1|y1|x2|y2' (internal units from the board
// origin) or '' for anywhere; an object matches the area when it lies inside.
// A via matches a layer it spans. With Designators (upper-case names), the
// group's copper as get_layout lists it: inside Area (or the group's extent
// grown by Margin) or on one of the group's own nets. Locked objects are
// left out unless IncludeLocked, and listed in Locked.
function MatchPCBObjects(Board: IPCB_Board; Kinds: String; NetName: String; Layer: Integer;
                         Area: String; Designators: TStringList; Margin: Integer; IncludeLocked: Boolean;
                         Found: TInterfaceList; Locked: TInterfaceList): Integer;
var
    Iterator : IPCB_BoardIterator;
    Prim     : IPCB_Primitive;
    Comps    : TInterfaceList;
    Local    : TStringList;
    Kind, GroupArea : String;
    R        : TCoordRect;
    X1, Y1, X2, Y2 : Integer;
    Ok, HasArea, InArea : Boolean;
begin
    HasArea := Area <> '';
    if HasArea then
    begin
        X1 := Board.XOrigin + StrToInt(GetFieldFromPipeString(Area, 0));
        Y1 := Board.YOrigin + StrToInt(GetFieldFromPipeString(Area, 1));
        X2 := Board.XOrigin + StrToInt(GetFieldFromPipeString(Area, 2));
        Y2 := Board.YOrigin + StrToInt(GetFieldFromPipeString(Area, 3));
    end;
    Local := TStringList.Create;
    Local.Sorted := True;
    Comps := TInterfaceList.Create;
    if Designators.Count > 0 then
    begin
        LayoutFindComponents(Board, Designators, Comps);
        LayoutLocalNets(Board, Designators, Local);
        if (not HasArea) and (Comps.Count > 0) then
        begin
            GroupArea := LayoutGroupArea(Comps, Margin);
            X1 := StrToInt(GetFieldFromPipeString(GroupArea, 0));
            Y1 := StrToInt(GetFieldFromPipeString(GroupArea, 1));
            X2 := StrToInt(GetFieldFromPipeString(GroupArea, 2));
            Y2 := StrToInt(GetFieldFromPipeString(GroupArea, 3));
            HasArea := True;
        end;
    end;
    Iterator := Board.BoardIterator_Create;
    Iterator.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject, eViaObject, ePolyObject, eRegionObject, eFillObject));
    Iterator.AddFilter_LayerSet(AllLayers);
    Iterator.AddFilter_Method(eProcessAll);
    Prim := Iterator.FirstPCBObject;
    while Prim <> nil do
    begin
        Kind := EditableKind(Prim);
        Ok := (Kind <> '') and (Pos('|' + Kind + '|', Kinds) > 0);
        if Ok and (NetName <> '') then
            Ok := (Prim.Net <> nil) and (UpperCase(Prim.Net.Name) = UpperCase(NetName));
        if Ok and (Layer <> eNoLayer) then
        begin
            // Layer IDs are not in stack order: ask the via whether it spans it
            if Prim.ObjectId = eViaObject then
                Ok := Prim.IntersectLayer(Layer)
            else
                Ok := Prim.Layer = Layer;
        end;
        if Ok and HasArea then
        begin
            R := Prim.BoundingRectangle;
            InArea := (R.Left >= X1) and (R.Right <= X2) and (R.Bottom >= Y1) and (R.Top <= Y2);
            if Designators.Count > 0 then
                Ok := InArea or ((Prim.Net <> nil) and (Local.IndexOf(UpperCase(Prim.Net.Name)) >= 0))
            else
                Ok := InArea;
        end
        else if Ok and (Designators.Count > 0) then
            Ok := (Prim.Net <> nil) and (Local.IndexOf(UpperCase(Prim.Net.Name)) >= 0);
        if Ok then
        begin
            if (not IncludeLocked) and (not Prim.Moveable) then
                Locked.Add(Prim)
            else
                Found.Add(Prim);
        end;
        Prim := Iterator.NextPCBObject;
    end;
    Board.BoardIterator_Destroy(Iterator);
    Comps.Free;
    Local.Free;
    Result := Found.Count;
end;

// One matched object for the result: kind, net, layer, position in mils
function PCBObjectJSON(Board: IPCB_Board; Prim: IPCB_Primitive): String;
var
    Item : TStringList;
    R    : TCoordRect;
begin
    Item := TStringList.Create;
    try
        AddJSONProperty(Item, 'kind', EditableKind(Prim));
        if Prim.Net <> nil then AddJSONProperty(Item, 'net', Prim.Net.Name) else AddJSONProperty(Item, 'net', '');
        if Prim.ObjectId = eViaObject then
        begin
            AddJSONProperty(Item, 'layer', Layer2String(Prim.LowLayer) + ' - ' + Layer2String(Prim.HighLayer));
            AddJSONNumber(Item, 'x', CoordToMils(Prim.x - Board.XOrigin));
            AddJSONNumber(Item, 'y', CoordToMils(Prim.y - Board.YOrigin));
            AddJSONNumber(Item, 'diameter_mils', CoordToMils(Prim.Size));
            AddJSONNumber(Item, 'hole_mils', CoordToMils(Prim.HoleSize));
        end
        else
        begin
            AddJSONProperty(Item, 'layer', Layer2String(Prim.Layer));
            if Prim.ObjectId = eTrackObject then
            begin
                AddJSONNumber(Item, 'x1', CoordToMils(Prim.x1 - Board.XOrigin));
                AddJSONNumber(Item, 'y1', CoordToMils(Prim.y1 - Board.YOrigin));
                AddJSONNumber(Item, 'x2', CoordToMils(Prim.x2 - Board.XOrigin));
                AddJSONNumber(Item, 'y2', CoordToMils(Prim.y2 - Board.YOrigin));
                AddJSONNumber(Item, 'width_mils', CoordToMils(Prim.Width));
            end
            else
            begin
                R := Prim.BoundingRectangle;
                AddJSONNumber(Item, 'left', CoordToMils(R.Left - Board.XOrigin));
                AddJSONNumber(Item, 'bottom', CoordToMils(R.Bottom - Board.YOrigin));
                AddJSONNumber(Item, 'right', CoordToMils(R.Right - Board.XOrigin));
                AddJSONNumber(Item, 'top', CoordToMils(R.Top - Board.YOrigin));
                if Prim.ObjectId = eArcObject then AddJSONNumber(Item, 'width_mils', CoordToMils(Prim.LineWidth));
                if Prim.ObjectId = ePolyObject then AddJSONProperty(Item, 'name', Prim.Name);
            end;
        end;
        Result := BuildJSONObject(Item, 1);
    finally
        Item.Free;
    end;
end;

// delete_pcb_objects and modify_pcb_objects. Action is 'delete' or 'modify';
// with DryRun nothing changes and the matches are listed. Modify sets what is
// given: Width (tracks, arcs), ViaSize and ViaHole (vias), the net when SetNet
// ('' removes it), NewLayerName (tracks, arcs, fills, regions); -1 or ''
// leaves a value alone. All of it is one undo step.
function EditPCBObjects(Action: String; Kinds: String; NetName: String; LayerName: String; Area: String;
                        DesignatorText: String; Margin: Integer; IncludeLocked: Boolean;
                        DryRun: Boolean; Width: Integer; ViaSize: Integer; ViaHole: Integer;
                        SetNet: Boolean; NewNetName: String; NewLayerName: String): String;
var
    Board    : IPCB_Board;
    Found, Polys, Locked : TInterfaceList;
    Prim     : IPCB_Primitive;
    Layer, NewLayer, i, Changed, Skipped, BadSize, NewSize, NewHole : Integer;
    NewNet   : IPCB_Net;
    Kind     : String;
    Items, Props, LockedItems, Designators : TStringList;
    Did      : Boolean;
begin
    Board := GetBoardSafe(0);
    if Board = nil then
    begin
        Result := 'ERROR: No PCB document is focused';
        Exit;
    end;
    if (NetName <> '') and (FindBoardNet(Board, NetName) = nil) then
    begin
        Result := 'ERROR: Net not found on the board: ' + NetName;
        Exit;
    end;
    Layer := eNoLayer;
    if LayerName <> '' then
    begin
        Layer := ResolveBoardLayer(Board, LayerName);
        if Layer = eNoLayer then
        begin
            Result := 'ERROR: ' + LayerName + ' is not a copper layer of this board';
            Exit;
        end;
    end;
    NewNet := nil;
    if SetNet and (NewNetName <> '') then
    begin
        NewNet := FindBoardNet(Board, NewNetName);
        if NewNet = nil then
        begin
            Result := 'ERROR: Net not found on the board: ' + NewNetName;
            Exit;
        end;
    end;
    NewLayer := eNoLayer;
    if NewLayerName <> '' then
    begin
        NewLayer := ResolveBoardLayer(Board, NewLayerName);
        if NewLayer = eNoLayer then
        begin
            Result := 'ERROR: ' + NewLayerName + ' is not a copper layer of this board';
            Exit;
        end;
    end;

    Found := TInterfaceList.Create;
    Polys := TInterfaceList.Create;
    Locked := TInterfaceList.Create;
    Items := TStringList.Create;
    Props := TStringList.Create;
    LockedItems := TStringList.Create;
    Designators := TStringList.Create;
    try
        Designators.Text := UpperCase(StringReplace(DesignatorText, ';', #13#10, REPLACEALL));
        MatchPCBObjects(Board, Kinds, NetName, Layer, Area, Designators, Margin, IncludeLocked, Found, Locked);
        for i := 0 to Found.Count - 1 do
            if i < 50 then Items.Add(PCBObjectJSON(Board, Found.Items[i]));
        for i := 0 to Locked.Count - 1 do
            if i < 20 then LockedItems.Add(PCBObjectJSON(Board, Locked.Items[i]));

        Changed := 0;
        Skipped := 0;
        BadSize := 0;
        if (not DryRun) and (Found.Count > 0) then
        begin
            // PostProcess must run whatever happens, or Altium's undo stays broken
            PCBServer.PreProcess;
            try
                for i := 0 to Found.Count - 1 do
                begin
                    Prim := Found.Items[i];
                    if Action = 'delete' then
                    begin
                        Board.RemovePCBObject(Prim);
                        PCBServer.SendMessageToRobots(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Prim.I_ObjectAddress);
                        Changed := Changed + 1;
                    end
                    else
                    begin
                        Kind := EditableKind(Prim);
                        Did := False;
                        PCBServer.SendMessageToRobots(Prim.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
                        if (Width >= 0) and (Kind = 'track') then begin Prim.Width := Width; Did := True; end;
                        if (Width >= 0) and (Kind = 'arc') then begin Prim.LineWidth := Width; Did := True; end;
                        if (Kind = 'via') and ((ViaSize >= 0) or (ViaHole >= 0)) then
                        begin
                            // A size given alone is checked against the via's other size
                            NewSize := Prim.Size;
                            NewHole := Prim.HoleSize;
                            if ViaSize >= 0 then NewSize := ViaSize;
                            if ViaHole >= 0 then NewHole := ViaHole;
                            if NewHole < NewSize then
                            begin
                                Prim.Size := NewSize;
                                Prim.HoleSize := NewHole;
                                Did := True;
                            end
                            else
                                BadSize := BadSize + 1;
                        end;
                        if SetNet then begin Prim.Net := NewNet; Did := True; end;
                        if (NewLayer <> eNoLayer) and ((Kind = 'track') or (Kind = 'arc') or (Kind = 'fill') or (Kind = 'region')) then
                        begin
                            Prim.Layer := NewLayer;
                            Did := True;
                        end;
                        PCBServer.SendMessageToRobots(Prim.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
                        if Did then Changed := Changed + 1 else Skipped := Skipped + 1;
                        if Did and (Kind = 'polygon') then Polys.Add(Prim);
                    end;
                end;
                // a polygon given another net pours again for it
                for i := 0 to Polys.Count - 1 do
                    Polys.Items[i].Rebuild;
            finally
                PCBServer.PostProcess;
            end;
            Board.ViewManager_FullUpdate;
        end;

        AddJSONBoolean(Props, 'success', True);
        AddJSONProperty(Props, 'action', Action);
        AddJSONBoolean(Props, 'dry_run', DryRun);
        AddJSONInteger(Props, 'matched', Found.Count);
        if Action = 'delete' then AddJSONInteger(Props, 'deleted', Changed)
        else
        begin
            AddJSONInteger(Props, 'changed', Changed);
            AddJSONInteger(Props, 'unchanged', Skipped);
            AddJSONInteger(Props, 'vias_left_as_hole_would_not_fit', BadSize);
        end;
        if Items.Count > 0 then Props.Add(BuildJSONArray(Items, 'objects')) else Props.Add('"objects": []');
        AddJSONInteger(Props, 'locked_skipped', Locked.Count);
        if LockedItems.Count > 0 then Props.Add(BuildJSONArray(LockedItems, 'locked'));
        AddJSONProperty(Props, 'board', Board.FileName);
        Result := BuildJSONObject(Props);
    finally
        Found.Free;
        Polys.Free;
        Locked.Free;
        Items.Free;
        Props.Free;
        LockedItems.Free;
        Designators.Free;
    end;
end;

// Altium's query engine, as the PCB Filter panel runs it: PCB:RunQuery with
// Apply selects the objects an expression matches, which are read from the
// selection. The engine reads bare numbers in its own unit, which is not the
// board's display unit (a board shown in mil queried in mm), so it is found
// once per call by asking for a known via or track size.
//
// Queries change the selection and apply a filter. Each call saves the
// user's selection first, in memory and as object addresses in StoreFile,
// and selects it again and clears the filter when done. A call the server
// stops (an expression Altium cannot evaluate) never gets there: query_restore,
// or the next query call, selects it again from StoreFile. A filter the user
// had applied cannot be read by a script, so it is cleared, not restored.

// Number as the query engine reads it: always a dot, whatever the locale
function QueryNumber(V: Double): String;
begin
    Result := StringReplace(FormatFloat('0.######', V), DecimalSeparator, '.', REPLACEALL);
end;

procedure QueryClearFilter(Dummy: Integer);
begin
    ResetParameters;
    AddStringParameter('Clear', 'True');
    RunProcess('PCB:RunQuery');
end;

// The objects Expr matches, in Found; the selection is left empty
procedure RunBoardQuery(Board: IPCB_Board; Expr: String; Found: TInterfaceList);
var
    i : Integer;
begin
    Board.SelectedObjects_Clear;
    try
        ResetParameters;
        AddStringParameter('Apply', 'True');
        AddStringParameter('Expr', Expr);
        AddStringParameter('Select', 'True');
        RunProcess('PCB:RunQuery');
        for i := 0 to Board.SelectecObjectCount - 1 do
            Found.Add(Board.SelectecObject[i]);
    finally
        Board.SelectedObjects_Clear;
        QueryClearFilter(0);
    end;
end;

// Selects again what a stopped query call saved in StoreFile for this board,
// clears the filter and deletes the file. How many objects were selected,
// or -1 when nothing was saved for this board.
function QueryRestoreSelection(Board: IPCB_Board; StoreFile: String): Integer;
var
    Lines    : TStringList;
    Iterator : IPCB_BoardIterator;
    Prim     : IPCB_Primitive;
begin
    Result := -1;
    if not FileExists(StoreFile) then Exit;
    Lines := TStringList.Create;
    try
        Lines.LoadFromFile(StoreFile);
        if Lines.Count = 0 then Exit;
        // Saved for another board: left for a query call on that board
        if UpperCase(Lines[0]) <> UpperCase(Board.FileName) then Exit;
        Lines.Delete(0);
        Lines.Sorted := True;
        Result := 0;
        Board.SelectedObjects_Clear;
        QueryClearFilter(0);
        if Lines.Count > 0 then
        begin
            Iterator := Board.BoardIterator_Create;
            Iterator.AddFilter_ObjectSet(MkSet(eArcObject, ePadObject, eViaObject, eTrackObject, eTextObject,
                eFillObject, eComponentObject, ePolyObject, eRegionObject, eDimensionObject, eComponentBodyObject));
            Iterator.AddFilter_LayerSet(AllLayers);
            Iterator.AddFilter_Method(eProcessAll);
            Prim := Iterator.FirstPCBObject;
            while Prim <> nil do
            begin
                if Lines.IndexOf(IntToStr(Prim.I_ObjectAddress)) >= 0 then
                begin
                    Prim.Selected := True;
                    Result := Result + 1;
                end;
                Prim := Iterator.NextPCBObject;
            end;
            Board.BoardIterator_Destroy(Iterator);
        end;
        DeleteFile(StoreFile);
    finally
        Lines.Free;
    end;
end;

// Saves the selection in Saved and in StoreFile, first selecting again what
// a stopped call left in StoreFile
procedure QuerySaveSelection(Board: IPCB_Board; StoreFile: String; Saved: TInterfaceList);
var
    Lines : TStringList;
    Prim  : IPCB_Primitive;
    i     : Integer;
begin
    QueryRestoreSelection(Board, StoreFile);
    Lines := TStringList.Create;
    try
        Lines.Add(Board.FileName);
        for i := 0 to Board.SelectecObjectCount - 1 do
        begin
            Prim := Board.SelectecObject[i];
            Saved.Add(Prim);
            Lines.Add(IntToStr(Prim.I_ObjectAddress));
        end;
        Lines.SaveToFile(StoreFile);
    finally
        Lines.Free;
    end;
end;

// Selects again what QuerySaveSelection saved, with the filter cleared
procedure QueryEndSelection(Board: IPCB_Board; StoreFile: String; Saved: TInterfaceList);
var
    i : Integer;
begin
    Board.SelectedObjects_Clear;
    for i := 0 to Saved.Count - 1 do
        Saved.Items[i].Selected := True;
    DeleteFile(StoreFile);
end;

// query_restore: the selection a stopped query call left behind
function QueryRestore(StoreFile: String): String;
var
    Board : IPCB_Board;
    Props : TStringList;
    Count : Integer;
begin
    Board := GetBoardSafe(0);
    if Board = nil then
    begin
        Result := 'ERROR: No PCB document is focused';
        Exit;
    end;
    Count := QueryRestoreSelection(Board, StoreFile);
    Props := TStringList.Create;
    try
        AddJSONBoolean(Props, 'success', True);
        AddJSONBoolean(Props, 'restored', Count >= 0);
        if Count >= 0 then AddJSONInteger(Props, 'selected', Count);
        Result := BuildJSONObject(Props);
    finally
        Props.Free;
    end;
end;

// 'mm' or 'mil': how the engine reads bare numbers on this board, from a via
// hole or a track width it must find again; '' when the board has neither
function QueryUnit(Board: IPCB_Board): String;
var
    Iterator : IPCB_BoardIterator;
    Prim     : IPCB_Primitive;
    Found    : TInterfaceList;
    Prop, Kind : String;
    Size     : Integer;
begin
    Result := '';
    Iterator := Board.BoardIterator_Create;
    Iterator.AddFilter_ObjectSet(MkSet(eViaObject, eTrackObject));
    Iterator.AddFilter_LayerSet(AllLayers);
    Iterator.AddFilter_Method(eProcessAll);
    Prim := Iterator.FirstPCBObject;
    while (Prim <> nil) and (Prim.ObjectId <> eViaObject) do Prim := Iterator.NextPCBObject;
    if Prim = nil then Prim := Iterator.FirstPCBObject;
    Board.BoardIterator_Destroy(Iterator);
    if Prim = nil then Exit;
    if Prim.ObjectId = eViaObject then
    begin
        Kind := 'IsVia'; Prop := 'HoleSize'; Size := Prim.HoleSize;
    end
    else
    begin
        Kind := 'IsTrack'; Prop := 'Width'; Size := Prim.Width;
    end;
    Found := TInterfaceList.Create;
    try
        RunBoardQuery(Board, Kind + ' And (' + Prop + ' > ' + QueryNumber(CoordToMMs(Size) * 0.999) +
                      ') And (' + Prop + ' < ' + QueryNumber(CoordToMMs(Size) * 1.001) + ')', Found);
        if Found.Count > 0 then Result := 'mm'
        else
        begin
            RunBoardQuery(Board, Kind + ' And (' + Prop + ' > ' + QueryNumber(CoordToMils(Size) * 0.999) +
                          ') And (' + Prop + ' < ' + QueryNumber(CoordToMils(Size) * 1.001) + ')', Found);
            if Found.Count > 0 then Result := 'mil';
        end;
    finally
        Found.Free;
    end;
end;

// The board's own name of a layer ('GND1' for Mid Layer 1 on a board that
// renamed it), or '' when it has none of its own. Read from the V7 layer
// stack: Prim.Layer holds V7 ids, and the V6 stack names Mechanical 17 and
// up after other layers ('Mid-Layer 16' for Mechanical 17).
function QueryBoardLayerName(Board: IPCB_Board; Layer: Integer): String;
var
    Obj : IPCB_LayerObject;
begin
    Result := '';
    try
        Obj := Board.LayerStack_V7.LayerObject_V7[Layer];
        if Obj <> nil then Result := Obj.Name;
    except
        Result := '';
    end;
    if SameText(Result, Layer2String(Layer)) then Result := '';
end;

// Generic replaced by Named where a layer name is expected: OnLayer('..')
// (ExistsOnLayer too), Layer = '..' and Layer <> '..', written as
// pcb_query.layer_arguments writes them. Other quoted text is left alone.
function QueryRenameLayer(Expr: String; Generic: String; Named: String): String;
begin
    Result := Expr;
    if (Named = '') or SameText(Named, Generic) then Exit;
    Result := StringReplace(Result, 'OnLayer(''' + Generic + ''')', 'OnLayer(''' + Named + ''')',
                            MkSet(rfReplaceAll, rfIgnoreCase));
    Result := StringReplace(Result, 'Layer = ''' + Generic + '''', 'Layer = ''' + Named + '''',
                            MkSet(rfReplaceAll, rfIgnoreCase));
    Result := StringReplace(Result, 'Layer <> ''' + Generic + '''', 'Layer <> ''' + Named + '''',
                            MkSet(rfReplaceAll, rfIgnoreCase));
end;

// The engine knows layers only by the board's names: OnLayer('Mid Layer 3')
// matches nothing on a board that calls it 'SIG/PWR'. Each generic layer
// name given as a layer is replaced by the board's name for it, mechanical
// layers past 16 included (their V6 ids stop at Mechanical 16, #32).
function QueryLayerNames(Board: IPCB_Board; Expr: String): String;
var
    L, i      : Integer;
    MechLayer : IPCB_MechanicalLayer;
begin
    Result := Expr;
    for L := eTopLayer to eMultiLayer do
        Result := QueryRenameLayer(Result, Layer2String(L), QueryBoardLayerName(Board, L));
    if Pos('MECHANICAL ', UpperCase(Result)) = 0 then Exit;
    for i := 17 to MAX_MECH_LAYERS do
    begin
        MechLayer := Board.LayerStack_V7.LayerObject_V7[ILayer.MechanicalLayer(i)];
        if MechLayer <> nil then
            Result := QueryRenameLayer(Result, 'Mechanical ' + IntToStr(i), MechLayer.Name);
    end;
end;

// Area is 'x1|y1|x2|y2' in internal units from the board origin, or '' for
// the whole board; True when the object's bounds touch it
function QueryInArea(Board: IPCB_Board; Prim: IPCB_Primitive; Area: String): Boolean;
var
    R : TCoordRect;
    X1, Y1, X2, Y2 : Integer;
begin
    Result := True;
    if Area = '' then Exit;
    X1 := Board.XOrigin + StrToInt(GetFieldFromPipeString(Area, 0));
    Y1 := Board.YOrigin + StrToInt(GetFieldFromPipeString(Area, 1));
    X2 := Board.XOrigin + StrToInt(GetFieldFromPipeString(Area, 2));
    Y2 := Board.YOrigin + StrToInt(GetFieldFromPipeString(Area, 3));
    R := Prim.BoundingRectangle;
    Result := (R.Left <= X2) and (R.Right >= X1) and (R.Bottom <= Y2) and (R.Top >= Y1);
end;

// Keeps the objects of Found inside Area
procedure QueryKeepInArea(Board: IPCB_Board; Found: TInterfaceList; Area: String);
var
    i : Integer;
begin
    if Area = '' then Exit;
    for i := Found.Count - 1 downto 0 do
        if not QueryInArea(Board, Found.Items[i], Area) then Found.Delete(i);
end;

function QueryKindName(Prim: IPCB_Primitive): String;
begin
    case Prim.ObjectId of
        eArcObject:       Result := 'arc';
        ePadObject:       Result := 'pad';
        eViaObject:       Result := 'via';
        eTrackObject:     Result := 'track';
        eTextObject:      Result := 'text';
        eFillObject:      Result := 'fill';
        eComponentObject: Result := 'component';
        ePolyObject:      Result := 'polygon';
        eRegionObject:    Result := 'region';
        eNetObject:       Result := 'net';
        eRuleObject:      Result := 'rule';
        eDimensionObject: Result := 'dimension';
    else
        Result := 'object ' + IntToStr(Prim.ObjectId);
    end;
end;

// One matched object: kind, its name (designator, pad, polygon, rule, net),
// net, layer and bounds in mils from the board origin
function QueryObjectJSON(Board: IPCB_Board; Prim: IPCB_Primitive): String;
var
    Item : TStringList;
    R    : TCoordRect;
begin
    Item := TStringList.Create;
    try
        AddJSONProperty(Item, 'kind', QueryKindName(Prim));
        case Prim.ObjectId of
            eComponentObject: AddJSONProperty(Item, 'name', Prim.Name.Text);
            ePadObject:
                begin
                    if Prim.Component <> nil then
                        AddJSONProperty(Item, 'name', Prim.Component.Name.Text + '-' + Prim.Name)
                    else
                        AddJSONProperty(Item, 'name', Prim.Name);
                end;
            ePolyObject, eRuleObject, eNetObject: AddJSONProperty(Item, 'name', Prim.Name);
        end;
        if (Prim.ObjectId <> eNetObject) and (Prim.ObjectId <> eRuleObject) and (Prim.ObjectId <> eComponentObject) then
        begin
            if Prim.Net <> nil then AddJSONProperty(Item, 'net', Prim.Net.Name) else AddJSONProperty(Item, 'net', '');
        end;
        if (Prim.ObjectId <> eNetObject) and (Prim.ObjectId <> eRuleObject) then
        begin
            if Prim.ObjectId = eViaObject then
                AddJSONProperty(Item, 'layer', Layer2String(Prim.LowLayer) + ' - ' + Layer2String(Prim.HighLayer))
            else
            begin
                AddJSONProperty(Item, 'layer', Layer2String(Prim.Layer));
                // the name the board gives it, which is what OnLayer() takes
                if QueryBoardLayerName(Board, Prim.Layer) <> '' then
                    AddJSONProperty(Item, 'layer_name', QueryBoardLayerName(Board, Prim.Layer));
            end;
            R := Prim.BoundingRectangle;
            AddJSONNumber(Item, 'left', CoordToMils(R.Left - Board.XOrigin));
            AddJSONNumber(Item, 'bottom', CoordToMils(R.Bottom - Board.YOrigin));
            AddJSONNumber(Item, 'right', CoordToMils(R.Right - Board.XOrigin));
            AddJSONNumber(Item, 'top', CoordToMils(R.Top - Board.YOrigin));
        end;
        Result := BuildJSONObject(Item, 1);
    finally
        Item.Free;
    end;
end;

// query_objects: ExprMM and ExprMil are the expression with its unit values
// written in mm and in mil; the one in the engine's unit is run. Area keeps
// the objects touching it. StoreFile keeps the user's selection while the
// queries run.
function QueryObjects(ExprMM: String; ExprMil: String; Limit: Integer; Area: String; StoreFile: String): String;
var
    Board : IPCB_Board;
    Found, Saved : TInterfaceList;
    Items, Kinds, Counts, Props : TStringList;
    Units, Expr, Kind : String;
    i, k, NoNet : Integer;
begin
    Board := GetBoardSafe(0);
    if Board = nil then
    begin
        Result := 'ERROR: No PCB document is focused';
        Exit;
    end;
    Found := TInterfaceList.Create;
    Saved := TInterfaceList.Create;
    Items := TStringList.Create;
    Kinds := TStringList.Create;
    Counts := TStringList.Create;
    Props := TStringList.Create;
    try
        QuerySaveSelection(Board, StoreFile, Saved);
        try
            Units := QueryUnit(Board);
            if Units = 'mil' then Expr := ExprMil else Expr := ExprMM;
            Expr := QueryLayerNames(Board, Expr);
            RunBoardQuery(Board, Expr, Found);
        finally
            QueryEndSelection(Board, StoreFile, Saved);
        end;
        QueryKeepInArea(Board, Found, Area);
        NoNet := 0;
        for i := 0 to Found.Count - 1 do
        begin
            // A copper pour that lost its net: InNet() cannot find it, and a
            // repour would pour it as dead copper
            if Found.Items[i].ObjectId = ePolyObject then
                if (Found.Items[i].Net = nil) and (Found.Items[i].Layer >= eTopLayer) and (Found.Items[i].Layer <= eBottomLayer) then NoNet := NoNet + 1;
            if i < Limit then Items.Add(QueryObjectJSON(Board, Found.Items[i]));
            Kind := QueryKindName(Found.Items[i]);
            k := Kinds.IndexOf(Kind);
            if k < 0 then
            begin
                Kinds.Add(Kind);
                Counts.Add('1');
            end
            else
                Counts[k] := IntToStr(StrToInt(Counts[k]) + 1);
        end;
        AddJSONBoolean(Props, 'success', True);
        AddJSONProperty(Props, 'expression_run', Expr);
        AddJSONProperty(Props, 'engine_unit', Units);
        AddJSONInteger(Props, 'matched', Found.Count);
        if NoNet > 0 then AddJSONInteger(Props, 'copper_polygons_without_net', NoNet);
        Item_Counts_JSON(Props, Kinds, Counts);
        if Items.Count > 0 then Props.Add(BuildJSONArray(Items, 'objects')) else Props.Add('"objects": []');
        AddJSONProperty(Props, 'board', Board.FileName);
        Result := BuildJSONObject(Props);
    finally
        Found.Free;
        Saved.Free;
        Items.Free;
        Kinds.Free;
        Counts.Free;
        Props.Free;
    end;
end;

// "by_kind": {"track": 12, ...}
procedure Item_Counts_JSON(Props: TStringList; Kinds: TStringList; Counts: TStringList);
var
    i : Integer;
    S : String;
begin
    S := '';
    for i := 0 to Kinds.Count - 1 do
    begin
        if S <> '' then S := S + ', ';
        S := S + '"' + JSONEscapeString(Kinds[i]) + '": ' + Counts[i];
    end;
    Props.Add('"by_kind": {' + S + '}');
end;

// The rule kind called Name, or -1
function RuleKindByName(Name: String): Integer;
begin
    Name := LowerCase(Name);
    Result := -1;
    if Name = 'clearance' then Result := eRule_Clearance
    else if Name = 'width' then Result := eRule_MaxMinWidth
    else if Name = 'routing_via' then Result := eRule_RoutingViaStyle
    else if Name = 'hole_size' then Result := eRule_MaxMinHoleSize
    else if Name = 'polygon_connect' then Result := eRule_PolygonConnectStyle
    else if Name = 'plane_connect' then Result := eRule_PowerPlaneConnectStyle
    else if Name = 'solder_mask_expansion' then Result := eRule_SolderMaskExpansion
    else if Name = 'paste_mask_expansion' then Result := eRule_PasteMaskExpansion
    else if Name = 'short_circuit' then Result := eRule_ShortCircuit
    else if Name = 'hole_to_hole' then Result := eRule_HoleToHoleClearance
    else if Name = 'silk_to_silk' then Result := eRule_SilkToSilkClearance
    else if Name = 'silk_to_mask' then Result := eRule_SilkToSolderMaskClearance
    else if Name = 'component_clearance' then Result := eRule_ComponentClearance;
end;

// Rule kinds that apply to one object (FindDominantRuleForObject), not to a pair
function RuleKindIsUnary(Kind: Integer): Boolean;
begin
    Result := (Kind = eRule_MaxMinWidth) or (Kind = eRule_MaxMinHoleSize) or (Kind = eRule_RoutingViaStyle) or
              (Kind = eRule_SolderMaskExpansion) or (Kind = eRule_PasteMaskExpansion) or
              (Kind = eRule_PowerPlaneConnectStyle);
end;

// Rule kinds the DRC tests, so that Rule.ActualCheck says whether objects pass
function RuleKindIsChecked(Kind: Integer): Boolean;
begin
    Result := (Kind = eRule_Clearance) or (Kind = eRule_MaxMinWidth) or (Kind = eRule_MaxMinHoleSize) or
              (Kind = eRule_RoutingViaStyle) or (Kind = eRule_ShortCircuit) or
              (Kind = eRule_HoleToHoleClearance) or (Kind = eRule_SilkToSilkClearance) or
              (Kind = eRule_SilkToSolderMaskClearance) or (Kind = eRule_ComponentClearance);
end;

// which_rule: the rule of RuleName that applies to the one object ExprA
// matches, or between it and the one ExprB matches with the distance between
// them, and whether they pass it. ExprB is empty for a one-object kind.
// AreaA and AreaB keep the objects touching them. StoreFile keeps the user's
// selection while the queries run.
function WhichRule(ExprAMM, ExprAMil, ExprBMM, ExprBMil, RuleName, AreaA, AreaB, StoreFile: String): String;
var
    Board     : IPCB_Board;
    A, B      : TInterfaceList;
    Saved     : TInterfaceList;
    Rule      : IPCB_Rule;
    Violation : IPCB_Violation;
    Kind      : Integer;
    Unary     : Boolean;
    Units     : String;
    Props     : TStringList;
begin
    Board := GetBoardSafe(0);
    if Board = nil then
    begin
        Result := 'ERROR: No PCB document is focused';
        Exit;
    end;
    Kind := RuleKindByName(RuleName);
    if Kind < 0 then
    begin
        Result := 'ERROR: Unknown rule kind ' + RuleName;
        Exit;
    end;
    Unary := RuleKindIsUnary(Kind);
    if Unary and (ExprBMM <> '') then
    begin
        Result := 'ERROR: ' + RuleName + ' rules apply to one object: leave object_b empty';
        Exit;
    end;
    if (not Unary) and (ExprBMM = '') then
    begin
        Result := 'ERROR: ' + RuleName + ' rules apply between two objects: give object_b';
        Exit;
    end;
    A := TInterfaceList.Create;
    B := TInterfaceList.Create;
    Saved := TInterfaceList.Create;
    Props := TStringList.Create;
    try
        QuerySaveSelection(Board, StoreFile, Saved);
        try
            Units := QueryUnit(Board);
            if Units = 'mil' then RunBoardQuery(Board, QueryLayerNames(Board, ExprAMil), A)
            else RunBoardQuery(Board, QueryLayerNames(Board, ExprAMM), A);
            if not Unary then
            begin
                if Units = 'mil' then RunBoardQuery(Board, QueryLayerNames(Board, ExprBMil), B)
                else RunBoardQuery(Board, QueryLayerNames(Board, ExprBMM), B);
            end;
        finally
            QueryEndSelection(Board, StoreFile, Saved);
        end;
        QueryKeepInArea(Board, A, AreaA);
        QueryKeepInArea(Board, B, AreaB);
        if Unary and (A.Count <> 1) then
        begin
            Result := 'ERROR: The expression must match exactly one object; object_a matched ' + IntToStr(A.Count);
            Exit;
        end;
        if (not Unary) and ((A.Count <> 1) or (B.Count <> 1)) then
        begin
            Result := 'ERROR: Each expression must match exactly one object; object_a matched ' +
                      IntToStr(A.Count) + ' and object_b ' + IntToStr(B.Count);
            Exit;
        end;
        AddJSONBoolean(Props, 'success', True);
        Props.Add('"object_a": ' + QueryObjectJSON(Board, A.Items[0]));
        if Unary then
            Rule := Board.FindDominantRuleForObject(A.Items[0], Kind)
        else
        begin
            Props.Add('"object_b": ' + QueryObjectJSON(Board, B.Items[0]));
            AddJSONNumber(Props, 'distance_mils', CoordToMils(Board.PrimPrimDistance(A.Items[0], B.Items[0])));
            Rule := Board.FindDominantRuleForObjectPair(A.Items[0], B.Items[0], Kind);
        end;
        if Rule = nil then
            AddJSONProperty(Props, 'rule', '')
        else
        begin
            AddJSONProperty(Props, 'rule', Rule.Name);
            AddJSONProperty(Props, 'descriptor', Rule.Descriptor);
            AddJSONInteger(Props, 'priority', Rule.Priority);
            AddJSONBoolean(Props, 'enabled', Rule.Enabled);
            AddJSONProperty(Props, 'scope1', Rule.Scope1Expression);
            if not Unary then AddJSONProperty(Props, 'scope2', Rule.Scope2Expression);
            if Kind = eRule_Clearance then
                AddJSONNumber(Props, 'gap_mils', CoordToMils(Rule.Gap));
            // ActualCheck is the DRC's own test of one object or pair, net
            // scope and clearance matrix included: nil when they comply. A
            // pair is tested both ways round, as check_silkscreen does: a
            // rule whose two scopes differ may only see it one way round.
            if RuleKindIsChecked(Kind) then
            begin
                if Unary then
                    Violation := Rule.ActualCheck(A.Items[0], nil)
                else
                begin
                    Violation := Rule.ActualCheck(A.Items[0], B.Items[0]);
                    if Violation = nil then
                        Violation := Rule.ActualCheck(B.Items[0], A.Items[0]);
                end;
                AddJSONBoolean(Props, 'passes', Violation = nil);
            end;
        end;
        AddJSONProperty(Props, 'board', Board.FileName);
        Result := BuildJSONObject(Props);
    finally
        A.Free;
        B.Free;
        Saved.Free;
        Props.Free;
    end;
end;

// Add the vias of place_vias to the focused board. Each record is
// 'x|y|diameter|hole|net|start layer|end layer', x and y in internal units
// relative to the board origin, sizes in internal units, an empty net for a
// via without one. Every net and layer is checked before anything is added,
// so a bad record adds nothing.
function CreateVias(Records: TStringList): String;
var
    Board       : IPCB_Board;
    Via         : IPCB_Via;
    Net         : IPCB_Net;
    i, Created  : Integer;
    NetName, StartName, EndName : String;
    StartLayer, EndLayer : Integer;
    ResultProps : TStringList;
begin
    Board := GetBoardSafe(0);
    if Board = nil then
    begin
        Result := 'ERROR: No PCB document is focused';
        Exit;
    end;

    for i := 0 to Records.Count - 1 do
    begin
        if Trim(Records[i]) = '' then Continue;
        NetName := GetFieldFromPipeString(Records[i], 4);
        StartName := GetFieldFromPipeString(Records[i], 5);
        EndName := GetFieldFromPipeString(Records[i], 6);
        if (NetName <> '') and (FindBoardNet(Board, NetName) = nil) then
        begin
            Result := 'ERROR: Net not found on the board: ' + NetName + ' (via ' + IntToStr(i + 1) + '); nothing was added';
            Exit;
        end;
        StartLayer := ResolveBoardLayer(Board, StartName);
        EndLayer := ResolveBoardLayer(Board, EndName);
        if (StartLayer = eNoLayer) or (EndLayer = eNoLayer) or
           (StartLayer > eBottomLayer) or (EndLayer > eBottomLayer) or (StartLayer = EndLayer) then
        begin
            Result := 'ERROR: A via spans two different signal layers of the board; ' + StartName + ' to ' +
                      EndName + ' is not that (via ' + IntToStr(i + 1) + '); nothing was added';
            Exit;
        end;
    end;

    // PostProcess must run whatever happens, or Altium's undo stays broken
    Created := 0;
    PCBServer.PreProcess;
    try
        for i := 0 to Records.Count - 1 do
        begin
            if Trim(Records[i]) = '' then Continue;
            NetName := GetFieldFromPipeString(Records[i], 4);
            StartLayer := ResolveBoardLayer(Board, GetFieldFromPipeString(Records[i], 5));
            EndLayer := ResolveBoardLayer(Board, GetFieldFromPipeString(Records[i], 6));
            Via := PCBServer.PCBObjectFactory(eViaObject, eNoDimension, eCreate_Default);
            Via.X := Board.XOrigin + StrToInt(GetFieldFromPipeString(Records[i], 0));
            Via.Y := Board.YOrigin + StrToInt(GetFieldFromPipeString(Records[i], 1));
            Via.Size := StrToInt(GetFieldFromPipeString(Records[i], 2));
            Via.HoleSize := StrToInt(GetFieldFromPipeString(Records[i], 3));
            // LowLayer and HighLayer are the lower and higher layer numbers
            // (Top Layer is 1), whichever end the caller named first
            if StartLayer < EndLayer then
            begin
                Via.LowLayer := StartLayer;
                Via.HighLayer := EndLayer;
            end
            else
            begin
                Via.LowLayer := EndLayer;
                Via.HighLayer := StartLayer;
            end;
            if NetName <> '' then
            begin
                Net := FindBoardNet(Board, NetName);
                Via.Net := Net;
            end;
            Board.AddPCBObject(Via);
            PCBServer.SendMessageToRobots(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Via.I_ObjectAddress);
            Created := Created + 1;
        end;
    finally
        PCBServer.PostProcess;
    end;
    Board.ViewManager_FullUpdate;

    ResultProps := TStringList.Create;
    try
        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONInteger(ResultProps, 'created', Created);
        AddJSONProperty(ResultProps, 'board', Board.FileName);
        Result := BuildJSONObject(ResultProps);
    finally
        ResultProps.Free;
    end;
end;

// The focused board's routed copper for check_routing, one record per line
// in internal units: O|x origin|y origin, then T|layer|net|x1|y1|x2|y2|width
// for each track with a net outside components and polygon pours, A|layer|net
// for each such arc, and V|x|y|size and P|x|y|x size|y size for every via and
// pad (a corner under one is no corner). The server does the geometry: it is
// quicker in Python and can be tested there without Altium.
function GetRoutingGeometry(Dummy: Integer): String;
var
    Board    : IPCB_Board;
    Iterator : IPCB_BoardIterator;
    Prim     : IPCB_Primitive;
    Lines    : TStringList;
    NetName  : String;
begin
    Board := GetBoardSafe(0);
    if Board = nil then
    begin
        Result := 'ERROR: No PCB document is focused';
        Exit;
    end;

    Lines := TStringList.Create;
    try
        Lines.Add('O|' + IntToStr(Board.XOrigin) + '|' + IntToStr(Board.YOrigin));
        Iterator := Board.BoardIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject, eViaObject, ePadObject));
        Iterator.AddFilter_LayerSet(AllLayers);
        Iterator.AddFilter_Method(eProcessAll);
        Prim := Iterator.FirstPCBObject;
        while Prim <> nil do
        begin
            NetName := '';
            if Prim.Net <> nil then NetName := Prim.Net.Name;
            if (Prim.ObjectId = eTrackObject) or (Prim.ObjectId = eArcObject) then
            begin
                if (NetName <> '') and (not Prim.InComponent) and (not Prim.InPolygon) then
                begin
                    if Prim.ObjectId = eTrackObject then
                        Lines.Add('T|' + Layer2String(Prim.Layer) + '|' + NetName + '|' +
                                  IntToStr(Prim.x1) + '|' + IntToStr(Prim.y1) + '|' +
                                  IntToStr(Prim.x2) + '|' + IntToStr(Prim.y2) + '|' + IntToStr(Prim.Width))
                    else
                        Lines.Add('A|' + Layer2String(Prim.Layer) + '|' + NetName);
                end;
            end
            else if Prim.ObjectId = eViaObject then
                Lines.Add('V|' + IntToStr(Prim.x) + '|' + IntToStr(Prim.y) + '|' + IntToStr(Prim.Size))
            else
                Lines.Add('P|' + IntToStr(Prim.x) + '|' + IntToStr(Prim.y) + '|' +
                          IntToStr(Prim.TopXSize) + '|' + IntToStr(Prim.TopYSize));
            Prim := Iterator.NextPCBObject;
        end;
        Board.BoardIterator_Destroy(Iterator);
        Result := Lines.Text;
    finally
        Lines.Free;
    end;
end;

// Add the tracks of route_track to the focused board. Segments holds
// 'x1|y1|x2|y2' records in internal units relative to the board origin, as
// the server computed them, so every segment is exactly 0, 45 or 90 degrees.
function CreateRouteTracks(NetName: String; LayerName: String; Width: Integer; Segments: TStringList): String;
var
    Board       : IPCB_Board;
    Iterator    : IPCB_BoardIterator;
    Net         : IPCB_Net;
    Prim        : IPCB_Primitive;
    Track       : IPCB_Track;
    Layer       : Integer;
    i, Created  : Integer;
    ResultProps : TStringList;
begin
    Board := GetBoardSafe(0);
    if Board = nil then
    begin
        Result := 'ERROR: No PCB document is focused';
        Exit;
    end;
    Layer := String2Layer(LayerName);
    if Layer = eNoLayer then
    begin
        Result := 'ERROR: Unknown layer: ' + LayerName;
        Exit;
    end;

    Net := nil;
    Iterator := Board.BoardIterator_Create;
    Iterator.AddFilter_ObjectSet(MkSet(eNetObject));
    Iterator.AddFilter_LayerSet(AllLayers);
    Iterator.AddFilter_Method(eProcessAll);
    Prim := Iterator.FirstPCBObject;
    while (Prim <> nil) and (Net = nil) do
    begin
        if UpperCase(Prim.Name) = UpperCase(NetName) then Net := Prim;
        Prim := Iterator.NextPCBObject;
    end;
    Board.BoardIterator_Destroy(Iterator);
    if Net = nil then
    begin
        Result := 'ERROR: Net not found on the board: ' + NetName;
        Exit;
    end;

    // PostProcess must run whatever happens, or Altium's undo stays broken
    Created := 0;
    PCBServer.PreProcess;
    try
        for i := 0 to Segments.Count - 1 do
        begin
            if Trim(Segments[i]) <> '' then
            begin
                Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
                Track.x1 := Board.XOrigin + StrToInt(GetFieldFromPipeString(Segments[i], 0));
                Track.y1 := Board.YOrigin + StrToInt(GetFieldFromPipeString(Segments[i], 1));
                Track.x2 := Board.XOrigin + StrToInt(GetFieldFromPipeString(Segments[i], 2));
                Track.y2 := Board.YOrigin + StrToInt(GetFieldFromPipeString(Segments[i], 3));
                Track.Width := Width;
                Track.Layer := Layer;
                Track.Net := Net;
                Board.AddPCBObject(Track);
                PCBServer.SendMessageToRobots(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Track.I_ObjectAddress);
                Created := Created + 1;
            end;
        end;
    finally
        PCBServer.PostProcess;
    end;
    Board.ViewManager_FullUpdate;

    ResultProps := TStringList.Create;
    try
        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONInteger(ResultProps, 'created', Created);
        AddJSONProperty(ResultProps, 'net', Net.Name);
        AddJSONProperty(ResultProps, 'layer', Layer2String(Layer));
        Result := BuildJSONObject(ResultProps);
    finally
        ResultProps.Free;
    end;
end;


// The 'x|y' records of an outline (internal units, relative to the board
// origin) as a contour in board coordinates
function OutlineContour(Board: IPCB_Board; Points: TStringList): IPCB_Contour;
var
    i : Integer;
begin
    Result := PCBServer.PCBContourFactory;
    for i := 0 to Points.Count - 1 do
        if Trim(Points[i]) <> '' then
            Result.AddPoint(Board.XOrigin + StrToInt(GetFieldFromPipeString(Points[i], 0)),
                            Board.YOrigin + StrToInt(GetFieldFromPipeString(Points[i], 1)));
end;

// What a polygon poured: its regions, one per separate piece of solid
// copper, or with Regions False the tracks and arcs of a hatched pour
function PolygonPourCount(Poly: IPCB_Polygon; Regions: Boolean): Integer;
var
    Iterator : IPCB_GroupIterator;
    Prim     : IPCB_Primitive;
begin
    Result := 0;
    Iterator := Poly.GroupIterator_Create;
    if Regions then
        Iterator.AddFilter_ObjectSet(MkSet(eRegionObject))
    else
        Iterator.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject));
    Prim := Iterator.FirstPCBObject;
    while Prim <> nil do
    begin
        Result := Result + 1;
        Prim := Iterator.NextPCBObject;
    end;
    Poly.GroupIterator_Destroy(Iterator);
end;

// Add a polygon pour with the outline in Points to the focused board and pour
// it. Hatch is solid, hatched_45, hatched_90 or none (outline only); TrackSize
// and Grid (internal units, 0 for Altium's default) shape a hatched pour.
function CreatePolygonPour(LayerName: String; NetName: String; PolyName: String; Hatch: String;
                           PourOverSameNet: Boolean; RemoveDead: Boolean; TrackSize: Integer;
                           Grid: Integer; Points: TStringList): String;
var
    Board  : IPCB_Board;
    Poly   : IPCB_Polygon;
    Net    : IPCB_Net;
    Seg    : TPolySegment;
    Layer, i, n : Integer;
    Props  : TStringList;
begin
    Board := GetBoardSafe(0);
    if Board = nil then
    begin
        Result := 'ERROR: No PCB document is focused';
        Exit;
    end;
    Layer := ResolveBoardLayer(Board, LayerName);
    if (Layer = eNoLayer) or (Layer > eBottomLayer) then
    begin
        Result := 'ERROR: ' + LayerName + ' is not a signal layer of this board; a pour goes on one';
        Exit;
    end;
    Net := nil;
    if NetName <> '' then
    begin
        Net := FindBoardNet(Board, NetName);
        if Net = nil then
        begin
            Result := 'ERROR: Net not found on the board: ' + NetName;
            Exit;
        end;
    end;

    // PostProcess must run whatever happens, or Altium's undo stays broken
    PCBServer.PreProcess;
    try
        Poly := PCBServer.PCBObjectFactory(ePolyObject, eNoDimension, eCreate_Default);
        Poly.Layer := Layer;
        if Hatch = 'hatched_45' then Poly.PolyHatchStyle := ePolyHatch45
        else if Hatch = 'hatched_90' then Poly.PolyHatchStyle := ePolyHatch90
        else if Hatch = 'none' then Poly.PolyHatchStyle := ePolyNoHatch
        else Poly.PolyHatchStyle := ePolySolid;
        if TrackSize > 0 then Poly.TrackSize := TrackSize;
        if Grid > 0 then Poly.Grid := Grid;
        // A TPolySegment must be created with ':= TPolySegment' before its
        // fields can be written
        n := 0;
        for i := 0 to Points.Count - 1 do
            if Trim(Points[i]) <> '' then n := n + 1;
        Poly.PointCount := n;
        Seg := TPolySegment;
        Seg.Kind := ePolySegmentLine;
        n := 0;
        for i := 0 to Points.Count - 1 do
            if Trim(Points[i]) <> '' then
            begin
                Seg.vx := Board.XOrigin + StrToInt(GetFieldFromPipeString(Points[i], 0));
                Seg.vy := Board.YOrigin + StrToInt(GetFieldFromPipeString(Points[i], 1));
                Poly.Segments[n] := Seg;
                n := n + 1;
            end;
        if Net <> nil then Poly.Net := Net;
        if PourOverSameNet then
            Poly.PourOver := ePolygonPourOver_SameNet
        else
            Poly.PourOver := ePolygonPourOver_None;
        Poly.RemoveDead := RemoveDead;
        if PolyName <> '' then Poly.Name := PolyName;
        Board.AddPCBObject(Poly);
        PCBServer.SendMessageToRobots(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Poly.I_ObjectAddress);
        Poly.Rebuild;
    finally
        PCBServer.PostProcess;
    end;
    Board.ViewManager_FullUpdate;

    Props := TStringList.Create;
    try
        AddJSONBoolean(Props, 'success', True);
        AddJSONProperty(Props, 'name', Poly.Name);
        AddJSONProperty(Props, 'layer', Layer2String(Poly.Layer));
        if Net <> nil then AddJSONProperty(Props, 'net', Net.Name) else AddJSONProperty(Props, 'net', '');
        AddJSONInteger(Props, 'corners', Poly.PointCount);
        AddJSONInteger(Props, 'poured_regions', PolygonPourCount(Poly, True));
        AddJSONInteger(Props, 'hatch_tracks', PolygonPourCount(Poly, False));
        AddJSONProperty(Props, 'board', Board.FileName);
        Result := BuildJSONObject(Props);
    finally
        Props.Free;
    end;
end;

// One cutout region with the outline in Points
function AddCutoutRegion(Board: IPCB_Board; Points: TStringList; Layer: Integer; Kind: Integer): IPCB_Region;
begin
    Result := PCBServer.PCBObjectFactory(eRegionObject, eNoDimension, eCreate_Default);
    Result.SetOutlineContour(OutlineContour(Board, Points));
    Result.Layer := Layer;
    Result.Kind := Kind;
    Board.AddPCBObject(Result);
    PCBServer.SendMessageToRobots(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Result.I_ObjectAddress);
end;

// Add a cutout with the outline in Points to the focused board, then repour
// the polygons it overlaps so their copper leaves it free. Kind 'polygon' is
// a polygon pour cutout on LayerName, or on every signal layer for 'all';
// kind 'board' cuts the board itself.
function CreateCutout(Kind: String; LayerName: String; Points: TStringList): String;
var
    Board    : IPCB_Board;
    Iterator : IPCB_BoardIterator;
    LayerIt  : IPCB_LayerObjectIterator;
    Poly     : IPCB_Polygon;
    Region   : IPCB_Region;
    Rect, PolyRect : TCoordRect;
    Layer, Created, Repoured : Integer;
    Layers, Props : TStringList;
begin
    Board := GetBoardSafe(0);
    if Board = nil then
    begin
        Result := 'ERROR: No PCB document is focused';
        Exit;
    end;
    Layers := TStringList.Create;
    Props := TStringList.Create;
    try
        if Kind = 'board' then
            Layers.Add(IntToStr(eMultiLayer))
        else if UpperCase(Trim(LayerName)) = 'ALL' then
        begin
            LayerIt := Board.ElectricalLayerIterator;
            while LayerIt.Next do
                if LayerIt.LayerObject.LayerID <= eBottomLayer then
                    Layers.Add(IntToStr(LayerIt.LayerObject.LayerID));
        end
        else
        begin
            Layer := ResolveBoardLayer(Board, LayerName);
            if (Layer = eNoLayer) or (Layer > eBottomLayer) then
            begin
                Result := 'ERROR: ' + LayerName + ' is not a signal layer of this board';
                Exit;
            end;
            Layers.Add(IntToStr(Layer));
        end;

        Created := 0;
        Repoured := 0;
        // PostProcess must run whatever happens, or Altium's undo stays broken
        PCBServer.PreProcess;
        try
            for Layer := 0 to Layers.Count - 1 do
            begin
                if Kind = 'board' then
                    Region := AddCutoutRegion(Board, Points, eMultiLayer, eRegionKind_BoardCutout)
                else
                    Region := AddCutoutRegion(Board, Points, StrToInt(Layers[Layer]), eRegionKind_Cutout);
                Rect := Region.BoundingRectangle;
                Created := Created + 1;
            end;

            // Repour every polygon the cutout overlaps on its layers
            Iterator := Board.BoardIterator_Create;
            Iterator.AddFilter_ObjectSet(MkSet(ePolyObject));
            Iterator.AddFilter_LayerSet(AllLayers);
            Iterator.AddFilter_Method(eProcessAll);
            Poly := Iterator.FirstPCBObject;
            while Poly <> nil do
            begin
                PolyRect := Poly.BoundingRectangle;
                if ((Kind = 'board') or (Layers.IndexOf(IntToStr(Poly.Layer)) >= 0)) and
                   (PolyRect.Left < Rect.Right) and (Rect.Left < PolyRect.Right) and
                   (PolyRect.Bottom < Rect.Top) and (Rect.Bottom < PolyRect.Top) then
                begin
                    Poly.Rebuild;
                    Repoured := Repoured + 1;
                end;
                Poly := Iterator.NextPCBObject;
            end;
            Board.BoardIterator_Destroy(Iterator);
        finally
            PCBServer.PostProcess;
        end;
        Board.ViewManager_FullUpdate;

        AddJSONBoolean(Props, 'success', True);
        AddJSONProperty(Props, 'kind', Kind);
        AddJSONInteger(Props, 'regions', Created);
        AddJSONInteger(Props, 'polygons_repoured', Repoured);
        AddJSONProperty(Props, 'board', Board.FileName);
        Result := BuildJSONObject(Props);
    finally
        Layers.Free;
        Props.Free;
    end;
end;

// Whether Poly overlaps Area ('x1|y1|x2|y2' in internal units from the board
// origin; '' for anywhere). Overlap, not inside: a whole-board pour must be
// repoured after an edit anywhere on it.
function PolygonInArea(Board: IPCB_Board; Poly: IPCB_Polygon; Area: String): Boolean;
var
    R : TCoordRect;
    X1, Y1, X2, Y2 : Integer;
begin
    Result := True;
    if Area = '' then Exit;
    X1 := Board.XOrigin + StrToInt(GetFieldFromPipeString(Area, 0));
    Y1 := Board.YOrigin + StrToInt(GetFieldFromPipeString(Area, 1));
    X2 := Board.XOrigin + StrToInt(GetFieldFromPipeString(Area, 2));
    Y2 := Board.YOrigin + StrToInt(GetFieldFromPipeString(Area, 3));
    R := Poly.BoundingRectangle;
    Result := (R.Left < X2) and (X1 < R.Right) and (R.Bottom < Y2) and (Y1 < R.Top);
end;

// Repour the polygons of the focused board, all of them or those matching
// the filters: Names is '|NAME1|NAME2|' (any case; names need not be unique),
// NetName and LayerName a net and a signal layer, each '' for any, Area as
// for PolygonInArea. A shelved
// polygon (Poured false) is skipped unless IncludeShelved: repouring it
// unshelves it. Rebuild is what repours; PCB:PolygonActions RepourAll does
// nothing when run from a script.
function RepourPolygons(Names: String; NetName: String; LayerName: String; Area: String;
                        IncludeShelved: Boolean): String;
var
    Board    : IPCB_Board;
    Iterator : IPCB_BoardIterator;
    Poly     : IPCB_Polygon;
    Net      : IPCB_Net;
    Layer, Repoured, i : Integer;
    Done, Shelved, Item, Props, Order : TStringList;
begin
    Board := GetBoardSafe(0);
    if Board = nil then
    begin
        Result := 'ERROR: No PCB document is focused';
        Exit;
    end;
    Net := nil;
    if NetName <> '' then
    begin
        Net := FindBoardNet(Board, NetName);
        if Net = nil then
        begin
            Result := 'ERROR: Net not found on the board: ' + NetName;
            Exit;
        end;
    end;
    Layer := eNoLayer;
    if LayerName <> '' then
    begin
        Layer := ResolveBoardLayer(Board, LayerName);
        if (Layer = eNoLayer) or (Layer > eBottomLayer) then
        begin
            Result := 'ERROR: ' + LayerName + ' is not a signal layer of this board';
            Exit;
        end;
    end;
    Names := UpperCase(Names);

    Done := TStringList.Create;
    Shelved := TStringList.Create;
    Item := TStringList.Create;
    Props := TStringList.Create;
    // The polygons to repour, sorted by pour index: where pours of different
    // nets overlap, the order decides which gets the copper, and Altium's own
    // Repour All goes by the Polygon Pour Order (the pour index)
    Order := TStringList.Create;
    Order.Sorted := True;
    try
        Repoured := 0;
        // PostProcess must run whatever happens, or Altium's undo stays broken
        PCBServer.PreProcess;
        try
            Iterator := Board.BoardIterator_Create;
            Iterator.AddFilter_ObjectSet(MkSet(ePolyObject));
            Iterator.AddFilter_LayerSet(AllLayers);
            Iterator.AddFilter_Method(eProcessAll);
            Poly := Iterator.FirstPCBObject;
            while Poly <> nil do
            begin
                if ((Names = '') or (Pos('|' + UpperCase(Poly.Name) + '|', Names) > 0)) and
                   ((Net = nil) or (Poly.Net = Net)) and
                   ((Layer = eNoLayer) or (Poly.Layer = Layer)) and
                   PolygonInArea(Board, Poly, Area) then
                begin
                    if (not Poly.Poured) and (not IncludeShelved) then
                        Shelved.Add('"' + JSONEscapeString(Poly.Name + ' (' + Layer2String(Poly.Layer) + ')') + '"')
                    else
                        Order.AddObject(IntToStr(1000000000 + Poly.PourIndex) + '|' + IntToStr(100000000 + Order.Count), Poly);
                end;
                Poly := Iterator.NextPCBObject;
            end;
            Board.BoardIterator_Destroy(Iterator);
            for i := 0 to Order.Count - 1 do
            begin
                Poly := Order.Objects[i];
                Poly.Rebuild;
                Repoured := Repoured + 1;
                Item.Clear;
                AddJSONProperty(Item, 'name', Poly.Name);
                AddJSONProperty(Item, 'layer', Layer2String(Poly.Layer));
                if Poly.Net <> nil then AddJSONProperty(Item, 'net', Poly.Net.Name) else AddJSONProperty(Item, 'net', '');
                AddJSONInteger(Item, 'pour_index', Poly.PourIndex);
                AddJSONInteger(Item, 'poured_regions', PolygonPourCount(Poly, True));
                AddJSONInteger(Item, 'hatch_tracks', PolygonPourCount(Poly, False));
                Done.Add(BuildJSONObject(Item, 1));
            end;
        finally
            PCBServer.PostProcess;
        end;
        Board.ViewManager_FullUpdate;

        AddJSONBoolean(Props, 'success', True);
        AddJSONInteger(Props, 'repoured', Repoured);
        if Done.Count > 0 then Props.Add(BuildJSONArray(Done, 'polygons')) else Props.Add('"polygons": []');
        if Shelved.Count > 0 then Props.Add(BuildJSONArray(Shelved, 'shelved_skipped')) else Props.Add('"shelved_skipped": []');
        AddJSONProperty(Props, 'board', Board.FileName);
        Result := BuildJSONObject(Props);
    finally
        Done.Free;
        Shelved.Free;
        Item.Free;
        Props.Free;
        Order.Free;
    end;
end;

// What each matching polygon poured, for get_pour_report: its pieces of solid
// copper (regions) and their sizes, so islands, slivers and pours with no net
// or no copper stand out. A region's Area is its outline only, holes not
// counted, so piece areas are upper bounds.
function PourReport(Names: String; NetName: String; LayerName: String; Area: String; SliverArea: Double): String;
var
    Board    : IPCB_Board;
    Iterator : IPCB_BoardIterator;
    GroupIt  : IPCB_GroupIterator;
    Poly     : IPCB_Polygon;
    Region   : IPCB_Region;
    Net      : IPCB_Net;
    Layer, Pieces, Slivers, Count : Integer;
    A, Smallest, Total : Double;
    Flags    : String;
    Items, Item, Props : TStringList;
begin
    Board := GetBoardSafe(0);
    if Board = nil then
    begin
        Result := 'ERROR: No PCB document is focused';
        Exit;
    end;
    Net := nil;
    if NetName <> '' then
    begin
        Net := FindBoardNet(Board, NetName);
        if Net = nil then
        begin
            Result := 'ERROR: Net not found on the board: ' + NetName;
            Exit;
        end;
    end;
    Layer := eNoLayer;
    if LayerName <> '' then
    begin
        Layer := ResolveBoardLayer(Board, LayerName);
        if (Layer = eNoLayer) or (Layer > eBottomLayer) then
        begin
            Result := 'ERROR: ' + LayerName + ' is not a signal layer of this board';
            Exit;
        end;
    end;
    Names := UpperCase(Names);
    Items := TStringList.Create;
    Item := TStringList.Create;
    Props := TStringList.Create;
    try
        Count := 0;
        Iterator := Board.BoardIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(ePolyObject));
        Iterator.AddFilter_LayerSet(AllLayers);
        Iterator.AddFilter_Method(eProcessAll);
        Poly := Iterator.FirstPCBObject;
        while Poly <> nil do
        begin
            if ((Names = '') or (Pos('|' + UpperCase(Poly.Name) + '|', Names) > 0)) and
               ((Net = nil) or (Poly.Net = Net)) and
               ((Layer = eNoLayer) or (Poly.Layer = Layer)) and
               PolygonInArea(Board, Poly, Area) then
            begin
                Count := Count + 1;
                Pieces := 0;
                Slivers := 0;
                Smallest := -1;
                Total := 0;
                GroupIt := Poly.GroupIterator_Create;
                GroupIt.AddFilter_ObjectSet(MkSet(eRegionObject));
                Region := GroupIt.FirstPCBObject;
                while Region <> nil do
                begin
                    Pieces := Pieces + 1;
                    A := Region.Area / 100000000.0;     // internal units squared -> sq mil
                    Total := Total + A;
                    if (Smallest < 0) or (A < Smallest) then Smallest := A;
                    if A < SliverArea then Slivers := Slivers + 1;
                    Region := GroupIt.NextPCBObject;
                end;
                Poly.GroupIterator_Destroy(GroupIt);

                Flags := '';
                if not Poly.Poured then Flags := Flags + '"shelved", '
                else if (Pieces = 0) and (PolygonPourCount(Poly, False) = 0) then Flags := Flags + '"no_copper", ';
                // only on copper: a pour on a mask layer has no net by nature
                if (Poly.Net = nil) and (Poly.Layer <= eBottomLayer) then Flags := Flags + '"no_net", ';
                if Pieces > 1 then Flags := Flags + '"islands", ';
                if Slivers > 0 then Flags := Flags + '"slivers", ';
                if Flags <> '' then Flags := Copy(Flags, 1, Length(Flags) - 2);

                Item.Clear;
                AddJSONProperty(Item, 'name', Poly.Name);
                AddJSONProperty(Item, 'layer', Layer2String(Poly.Layer));
                if Poly.Net <> nil then AddJSONProperty(Item, 'net', Poly.Net.Name) else AddJSONProperty(Item, 'net', '');
                AddJSONBoolean(Item, 'shelved', not Poly.Poured);
                AddJSONInteger(Item, 'pieces', Pieces);
                AddJSONInteger(Item, 'hatch_tracks', PolygonPourCount(Poly, False));
                if Pieces > 0 then
                begin
                    AddJSONNumber(Item, 'smallest_piece_sq_mils', Smallest);
                    AddJSONNumber(Item, 'copper_sq_mils', Total);
                end;
                AddJSONInteger(Item, 'slivers', Slivers);
                Item.Add('"flags": [' + Flags + ']');
                Items.Add(BuildJSONObject(Item, 1));
            end;
            Poly := Iterator.NextPCBObject;
        end;
        Board.BoardIterator_Destroy(Iterator);

        AddJSONBoolean(Props, 'success', True);
        AddJSONInteger(Props, 'polygons_checked', Count);
        if Items.Count > 0 then Props.Add(BuildJSONArray(Items, 'polygons')) else Props.Add('"polygons": []');
        AddJSONProperty(Props, 'board', Board.FileName);
        Result := BuildJSONObject(Props);
    finally
        Items.Free;
        Item.Free;
        Props.Free;
    end;
end;

// ---------------------------------------------------------------- geometry
//
// objects_in_area, clearance and drag_copper. Objects travel as '|' strings
// of integers (internal units; angles in thousandths of a degree), so no
// number depends on the Windows decimal separator. A reference names one
// object again: track|layer|x1|y1|x2|y2, arc|layer|cx|cy|r, via|x|y,
// pad|designator|name (or pad|x|y for a free pad), fill|layer|x1|y1|x2|y2,
// region|layer|left|bottom|right|top, component|designator.

// The polygon a poured region or track belongs to, or nil
function GeoParentPolygon(Prim: IPCB_Primitive): IPCB_Polygon;
begin
    Result := nil;
    if Prim.InPolygon then Result := Prim.Polygon;
end;

// A pour's copper carries no net of its own, and Altium can leave it on the
// internal Connect Layer: its polygon's net and layer are the real ones
function GeoNet(Prim: IPCB_Primitive): String;
var
    Poly : IPCB_Polygon;
begin
    Result := '';
    if Prim.Net <> nil then Result := Prim.Net.Name
    else
    begin
        Poly := GeoParentPolygon(Prim);
        if (Poly <> nil) and (Poly.Net <> nil) then Result := Poly.Net.Name;
    end;
end;

function GeoLayer(Prim: IPCB_Primitive): Integer;
var
    Poly : IPCB_Polygon;
begin
    Result := Prim.Layer;
    Poly := GeoParentPolygon(Prim);
    if Poly <> nil then Result := Poly.Layer;
end;

function GeoPolygonName(Prim: IPCB_Primitive): String;
var
    Poly : IPCB_Polygon;
begin
    Result := '';
    Poly := GeoParentPolygon(Prim);
    if Poly <> nil then Result := Poly.Name;
end;

// Does the segment A-B cross the box X1,Y1-X2,Y2 (Liang-Barsky clipping)?
function GeoSegmentHitsBox(AX, AY, BX, BY, X1, Y1, X2, Y2: Double): Boolean;
var
    T0, T1, DX, DY, P, Q, R : Double;
    I : Integer;
begin
    Result := False;
    T0 := 0;
    T1 := 1;
    DX := BX - AX;
    DY := BY - AY;
    for I := 0 to 3 do
    begin
        case I of
            0: begin P := -DX; Q := AX - X1; end;
            1: begin P := DX;  Q := X2 - AX; end;
            2: begin P := -DY; Q := AY - Y1; end;
            3: begin P := DY;  Q := Y2 - AY; end;
        end;
        if P = 0 then
        begin
            if Q < 0 then Exit;
        end
        else
        begin
            R := Q / P;
            if P < 0 then
            begin
                if R > T1 then Exit;
                if R > T0 then T0 := R;
            end
            else
            begin
                if R < T0 then Exit;
                if R < T1 then T1 := R;
            end;
        end;
    end;
    Result := True;
end;

// One contour against the box: 0 outside it, 1 the box is inside the
// contour, 2 an edge crosses the box
function GeoContourVsBox(C: IDispatch; X1, Y1, X2, Y2: Integer): Integer;
var
    I, J, N : Integer;
    CX, CY, AX, AY, BX, BY : Double;
    Inside : Boolean;
begin
    N := C.Count;
    CX := (X1 + X2) / 2;
    CY := (Y1 + Y2) / 2;
    Inside := False;
    J := N - 1;
    for I := 0 to N - 1 do
    begin
        AX := C.x(J); AY := C.y(J);
        BX := C.x(I); BY := C.y(I);
        if GeoSegmentHitsBox(AX, AY, BX, BY, X1, Y1, X2, Y2) then
        begin
            Result := 2;
            Exit;
        end;
        // Nested: DelphiScript may not short-circuit 'and', and the division
        // is only safe once the edge is known not to be horizontal
        if (BY > CY) <> (AY > CY) then
            // 1.0 *: in integers the product of two coordinate spans overflows
            if CX < 1.0 * (AX - BX) * (CY - BY) / (AY - BY) + BX then Inside := not Inside;
        J := I;
    end;
    if Inside then Result := 1 else Result := 0;
end;

// Does a region's copper (its outline less its holes) touch the box? A
// whole-board pour's bounds touch every box; its shape does not.
function GeoRegionTouchesBox(Region: IPCB_Region; X1, Y1, X2, Y2: Integer): Boolean;
var
    GP : IDispatch;
    K  : Integer;
begin
    Result := False;
    GP := Region.GeometricPolygon;
    for K := 0 to GP.Count - 1 do
        if not GP.IsHole(K) then
            if GeoContourVsBox(GP.Contour(K), X1, Y1, X2, Y2) > 0 then Result := True;
    if not Result then Exit;
    // the box wholly inside a hole touches no copper
    for K := 0 to GP.Count - 1 do
        if GP.IsHole(K) then
            if GeoContourVsBox(GP.Contour(K), X1, Y1, X2, Y2) = 1 then
            begin
                Result := False;
                Exit;
            end;
end;

// Does the object's shape touch the box? Regions and tracks are tested by
// shape, the rest by bounds (the spatial iterator's own test).
function GeoTouchesBox(Prim: IPCB_Primitive; X1, Y1, X2, Y2: Integer): Boolean;
var
    Track : IPCB_Track;
    H     : Integer;
begin
    Result := True;
    if Prim.ObjectId = eRegionObject then
        Result := GeoRegionTouchesBox(Prim, X1, Y1, X2, Y2)
    else if Prim.ObjectId = eTrackObject then
    begin
        Track := Prim;
        H := Track.Width div 2;
        Result := GeoSegmentHitsBox(Track.x1, Track.y1, Track.x2, Track.y2, X1 - H, Y1 - H, X2 + H, Y2 + H);
    end;
end;

function GeoOwner(Prim: IPCB_Primitive): String;
begin
    Result := '';
    if Prim.InComponent then
        if Prim.Component <> nil then Result := Prim.Component.Name.Text;
end;

function GeoFlag(B: Boolean): String;
begin
    if B then Result := '1' else Result := '0';
end;

// A component's comment or designator switched off is still an object on
// the board, just not shown
function GeoHidden(Prim: IPCB_Primitive): Boolean;
begin
    Result := False;
    if (Prim.ObjectId = eTextObject) and Prim.InComponent and (Prim.Component <> nil) then
    begin
        if Prim.IsComment and not Prim.Component.CommentOn then Result := True;
        if Prim.IsDesignator and not Prim.Component.NameOn then Result := True;
    end;
end;

// One object as kind|layer|net|owner|fields...
function GeoRecord(Prim: IPCB_Primitive): String;
var
    Track : IPCB_Track;
    Arc   : IPCB_Arc;
    Via   : IPCB_Via;
    Pad   : IPCB_Pad;
    Fill  : IPCB_Fill;
    Txt   : IPCB_Text;
    Comp  : IPCB_Component;
    R     : TCoordRect;
    Head  : String;
begin
    Result := '';
    Head := Layer2String(GeoLayer(Prim)) + '|' + GeoNet(Prim) + '|' + GeoOwner(Prim) + '|';
    R := Prim.BoundingRectangle;
    case Prim.ObjectId of
        eTrackObject:
        begin
            Track := Prim;
            Result := 'track|' + Head + IntToStr(Track.x1) + '|' + IntToStr(Track.y1) + '|' + IntToStr(Track.x2) +
                      '|' + IntToStr(Track.y2) + '|' + IntToStr(Track.Width) + '|' + GeoFlag(Prim.InPolygon);
        end;
        eArcObject:
        begin
            Arc := Prim;
            Result := 'arc|' + Head + IntToStr(Arc.XCenter) + '|' + IntToStr(Arc.YCenter) + '|' + IntToStr(Arc.Radius) +
                      '|' + IntToStr(Round(Arc.StartAngle * 1000)) + '|' + IntToStr(Round(Arc.EndAngle * 1000)) +
                      '|' + IntToStr(Arc.LineWidth) + '|' + GeoFlag(Prim.InPolygon);
        end;
        eViaObject:
        begin
            Via := Prim;
            Result := 'via|' + Layer2String(Via.LowLayer) + ':' + Layer2String(Via.HighLayer) + '|' + GeoNet(Prim) +
                      '||' + IntToStr(Via.x) + '|' + IntToStr(Via.y) + '|' + IntToStr(Via.Size) + '|' + IntToStr(Via.HoleSize);
        end;
        ePadObject:
        begin
            Pad := Prim;
            Result := 'pad|' + Head + IntToStr(Pad.x) + '|' + IntToStr(Pad.y) + '|' + IntToStr(Pad.TopXSize) + '|' +
                      IntToStr(Pad.TopYSize) + '|' + IntToStr(Pad.TopShape) + '|' + IntToStr(Pad.HoleSize) + '|' +
                      IntToStr(Round(Pad.Rotation * 1000)) + '|' + Pad.Name;
        end;
        eFillObject:
        begin
            Fill := Prim;
            Result := 'fill|' + Head + IntToStr(Fill.X1Location) + '|' + IntToStr(Fill.Y1Location) + '|' +
                      IntToStr(Fill.X2Location) + '|' + IntToStr(Fill.Y2Location) + '|' + IntToStr(Round(Fill.Rotation * 1000));
        end;
        eRegionObject:
            Result := 'region|' + Head + IntToStr(R.Left) + '|' + IntToStr(R.Bottom) + '|' + IntToStr(R.Right) + '|' +
                      IntToStr(R.Top) + '|' + GeoFlag(Prim.InPolygon) + '|' + GeoPolygonName(Prim);
        ePolyObject:
            Result := 'polygon|' + Head + IntToStr(R.Left) + '|' + IntToStr(R.Bottom) + '|' + IntToStr(R.Right) + '|' +
                      IntToStr(R.Top);
        eTextObject:
        begin
            Txt := Prim;
            Result := 'text|' + Head + IntToStr(Txt.XLocation) + '|' + IntToStr(Txt.YLocation) + '|' + IntToStr(Txt.Size) +
                      '|' + IntToStr(Round(Txt.Rotation * 1000)) + '|' + GeoFlag(GeoHidden(Prim)) + '|' + Txt.Text;
        end;
        eComponentObject:
        begin
            Comp := Prim;
            Result := 'component|' + Layer2String(Comp.Layer) + '||' + Comp.Name.Text + '|' + IntToStr(Comp.x) + '|' +
                      IntToStr(Comp.y) + '|' + IntToStr(Round(Comp.Rotation * 1000)) + '|' + IntToStr(R.Left) + '|' +
                      IntToStr(R.Bottom) + '|' + IntToStr(R.Right) + '|' + IntToStr(R.Top) + '|' + Comp.Pattern;
        end;
    end;
end;

function GeoKindSet(Kinds: String): TObjectSet;
begin
    Result := MkSet();
    if (Kinds = '') or (Pos('|track|', Kinds) > 0) then Result := SetUnion(Result, MkSet(eTrackObject));
    if (Kinds = '') or (Pos('|arc|', Kinds) > 0) then Result := SetUnion(Result, MkSet(eArcObject));
    if (Kinds = '') or (Pos('|via|', Kinds) > 0) then Result := SetUnion(Result, MkSet(eViaObject));
    if (Kinds = '') or (Pos('|pad|', Kinds) > 0) then Result := SetUnion(Result, MkSet(ePadObject));
    if (Kinds = '') or (Pos('|fill|', Kinds) > 0) then Result := SetUnion(Result, MkSet(eFillObject));
    if (Kinds = '') or (Pos('|region|', Kinds) > 0) then Result := SetUnion(Result, MkSet(eRegionObject));
    if (Kinds = '') or (Pos('|polygon|', Kinds) > 0) then Result := SetUnion(Result, MkSet(ePolyObject));
    if (Kinds = '') or (Pos('|text|', Kinds) > 0) then Result := SetUnion(Result, MkSet(eTextObject));
    if (Kinds = '') or (Pos('|component|', Kinds) > 0) then Result := SetUnion(Result, MkSet(eComponentObject));
end;

// Does a polygon's outline (its vertices; an arc edge counts as its chord)
// touch the box: an edge crossing it, or the box inside?
function GeoOutlineTouchesBox(Poly: IPCB_Polygon; X1, Y1, X2, Y2: Integer): Boolean;
var
    I, J, N : Integer;
    CX, CY, AX, AY, BX, BY : Double;
    Inside : Boolean;
begin
    Result := False;
    N := Poly.PointCount;
    CX := (X1 + X2) / 2;
    CY := (Y1 + Y2) / 2;
    Inside := False;
    J := N - 1;
    for I := 0 to N - 1 do
    begin
        AX := Poly.Segments[J].vx; AY := Poly.Segments[J].vy;
        BX := Poly.Segments[I].vx; BY := Poly.Segments[I].vy;
        if GeoSegmentHitsBox(AX, AY, BX, BY, X1, Y1, X2, Y2) then
        begin
            Result := True;
            Exit;
        end;
        if (BY > CY) <> (AY > CY) then
            // 1.0 *: in integers the product of two coordinate spans overflows
            if CX < 1.0 * (AX - BX) * (CY - BY) / (AY - BY) + BX then Inside := not Inside;
        J := I;
    end;
    Result := Inside;
end;

// Does a polygon reach the box by its shape? Where it poured regions, one of
// them must reach it (a board-sized pour's bounds touch every box); with no
// regions (shelved, not poured or hatched) its outline must.
function GeoPolygonTouchesBox(Poly: IPCB_Polygon; X1, Y1, X2, Y2: Integer): Boolean;
var
    GroupIt : IPCB_GroupIterator;
    Region  : IPCB_Region;
    HasRegions : Boolean;
begin
    Result := False;
    HasRegions := False;
    GroupIt := Poly.GroupIterator_Create;
    GroupIt.AddFilter_ObjectSet(MkSet(eRegionObject));
    Region := GroupIt.FirstPCBObject;
    while (Region <> nil) and not Result do
    begin
        HasRegions := True;
        if GeoRegionTouchesBox(Region, X1, Y1, X2, Y2) then Result := True;
        Region := GroupIt.NextPCBObject;
    end;
    Poly.GroupIterator_Destroy(GroupIt);
    if not HasRegions then Result := GeoOutlineTouchesBox(Poly, X1, Y1, X2, Y2);
end;

// Adds Prim's record Rec to Items unless Prim is listed already (by its
// handle: the spatial iterator can return an object twice, while two
// identical objects are two). Complete goes False once Items holds Limit
// records, and the search stops there.
procedure GeoCollect(Prim: IPCB_Primitive; Rec: String; Items, Seen: TStringList; Limit: Integer;
                     var Total: Integer; var Complete: Boolean);
var
    Key : String;
begin
    if Rec = '' then Exit;
    Key := IntToStr(Prim.I_ObjectAddress);
    if Seen.IndexOf(Key) >= 0 then Exit;
    Seen.Add(Key);
    Total := Total + 1;
    Items.Add('"' + JSONEscapeString(Rec) + '"');
    if Items.Count >= Limit then Complete := False;
end;

// Components whose bounds touch the box and polygons whose shape does, of
// the kinds in Kinds: the spatial iterator never returns these two kinds
procedure GeoAddGroups(Board: IPCB_Board; X1, Y1, X2, Y2: Integer; Kinds: String; Limit: Integer;
                       Items, Seen: TStringList; var Total: Integer; var Complete: Boolean);
var
    It   : IPCB_BoardIterator;
    Prim : IPCB_Primitive;
    R    : TCoordRect;
    Wanted : TObjectSet;
begin
    Wanted := MkSet();
    if (Kinds = '') or (Pos('|component|', Kinds) > 0) then Wanted := SetUnion(Wanted, MkSet(eComponentObject));
    if (Kinds = '') or (Pos('|polygon|', Kinds) > 0) then Wanted := SetUnion(Wanted, MkSet(ePolyObject));
    if Wanted = MkSet() then Exit;
    It := Board.BoardIterator_Create;
    It.AddFilter_ObjectSet(Wanted);
    It.AddFilter_LayerSet(AllLayers);
    It.AddFilter_Method(eProcessAll);
    Prim := It.FirstPCBObject;
    while (Prim <> nil) and Complete do
    begin
        R := Prim.BoundingRectangle;
        if (R.Left <= X2) and (R.Right >= X1) and (R.Bottom <= Y2) and (R.Top >= Y1) then
            if (Prim.ObjectId <> ePolyObject) or GeoPolygonTouchesBox(Prim, X1, Y1, X2, Y2) then
                GeoCollect(Prim, GeoRecord(Prim), Items, Seen, Limit, Total, Complete);
        Prim := It.NextPCBObject;
    end;
    Board.BoardIterator_Destroy(It);
end;

// A region's outline for drawing: its contours joined by '~', each 's:' (solid)
// or 'h:' (hole) followed by x,y points joined by ';'
function GeoContours(Region: IPCB_Region): String;
var
    GP   : IDispatch;
    K, I : Integer;
    Part : String;
begin
    Result := '';
    GP := Region.GeometricPolygon;
    for K := 0 to GP.Count - 1 do
    begin
        if GP.IsHole(K) then Part := 'h:' else Part := 's:';
        for I := 0 to GP.Contour(K).Count - 1 do
        begin
            if I > 0 then Part := Part + ';';
            Part := Part + IntToStr(GP.Contour(K).x(I)) + ',' + IntToStr(GP.Contour(K).y(I));
        end;
        if K > 0 then Result := Result + '~';
        Result := Result + Part;
    end;
end;

// The board outline: vx,vy,kind(0 line, 1 arc),cx,cy,radius,angle1,angle2
// per segment (angles in thousandths of a degree), joined by ';'
function GeoOutline(Board: IPCB_Board): String;
var
    I   : Integer;
    Seg : TPolySegment;
    Props : TStringList;
    Text : String;
begin
    Text := '';
    for I := 0 to Board.BoardOutline.PointCount - 1 do
    begin
        Seg := Board.BoardOutline.Segments[I];
        if I > 0 then Text := Text + ';';
        Text := Text + IntToStr(Seg.vx) + ',' + IntToStr(Seg.vy) + ',' + IntToStr(Seg.Kind) + ',' +
                IntToStr(Seg.cx) + ',' + IntToStr(Seg.cy) + ',' + IntToStr(Seg.Radius) + ',' +
                IntToStr(Round(Seg.Angle1 * 1000)) + ',' + IntToStr(Round(Seg.Angle2 * 1000));
    end;
    Props := TStringList.Create;
    try
        AddJSONProperty(Props, 'board_path', Board.FileName);
        AddJSONInteger(Props, 'origin_x', Board.XOrigin);
        AddJSONInteger(Props, 'origin_y', Board.YOrigin);
        AddJSONProperty(Props, 'outline', Text);
        Result := BuildJSONObject(Props);
    finally
        Props.Free;
    end;
end;

// Objects touching the box X1,Y1-X2,Y2 (internal units) of the kinds in
// Kinds ('|track|via|', or '' for all), at most Limit: the search stops
// there and complete is false. Switched-off designators and comments only
// with IncludeHidden. copper_layers names the board's copper layers top to
// bottom, so the server knows which layers a blind via spans.
function ObjectsInArea(Board: IPCB_Board; X1, Y1, X2, Y2: Integer; Kinds: String; Limit: Integer;
                       Shapes, IncludeHidden: Boolean): String;
var
    It    : IPCB_SpatialIterator;
    Prim  : IPCB_Primitive;
    LayerIt : IPCB_LayerObjectIterator;
    Items, Props, Stack, Seen : TStringList;
    Rec   : String;
    Total : Integer;
    Complete : Boolean;
begin
    Items := TStringList.Create;
    Props := TStringList.Create;
    Stack := TStringList.Create;
    Seen := TStringList.Create;
    Seen.Sorted := True;
    try
        LayerIt := Board.ElectricalLayerIterator;
        while LayerIt.Next do
            Stack.Add('"' + JSONEscapeString(Layer2String(LayerIt.LayerObject.LayerID)) + '"');
        Total := 0;
        Complete := Limit > 0;
        It := Board.SpatialIterator_Create;
        It.AddFilter_ObjectSet(GeoKindSet(Kinds));
        It.AddFilter_LayerSet(AllLayers);
        It.AddFilter_Area(X1, Y1, X2, Y2);
        Prim := It.FirstPCBObject;
        while (Prim <> nil) and Complete do
        begin
            Rec := '';
            if GeoTouchesBox(Prim, X1, Y1, X2, Y2) and (IncludeHidden or not GeoHidden(Prim)) then
                Rec := GeoRecord(Prim);
            // For drawing: the outline of a region, not just its bounds
            if Shapes and (Rec <> '') and (Prim.ObjectId = eRegionObject) then
                Rec := Rec + '|' + GeoContours(Prim);
            GeoCollect(Prim, Rec, Items, Seen, Limit, Total, Complete);
            Prim := It.NextPCBObject;
        end;
        Board.SpatialIterator_Destroy(It);
        if Complete then GeoAddGroups(Board, X1, Y1, X2, Y2, Kinds, Limit, Items, Seen, Total, Complete);
        AddJSONProperty(Props, 'board_path', Board.FileName);
        AddJSONInteger(Props, 'origin_x', Board.XOrigin);
        AddJSONInteger(Props, 'origin_y', Board.YOrigin);
        AddJSONInteger(Props, 'total', Total);
        AddJSONBoolean(Props, 'complete', Complete);
        Props.Add(BuildJSONArray(Stack, 'copper_layers'));
        Props.Add(BuildJSONArray(Items, 'objects'));
        Result := BuildJSONObject(Props);
    finally
        Items.Free;
        Props.Free;
        Stack.Free;
        Seen.Free;
    end;
end;

// The pad Name of the component Designator, or nil
function GeoComponentPad(Board: IPCB_Board; Designator, Name: String): IPCB_Pad;
var
    Comp : IPCB_Component;
    GI   : IPCB_GroupIterator;
    Pad  : IPCB_Pad;
begin
    Result := nil;
    Comp := Board.GetPcbComponentByRefDes(Designator);
    if Comp = nil then Exit;
    GI := Comp.GroupIterator_Create;
    GI.AddFilter_ObjectSet(MkSet(ePadObject));
    Pad := GI.FirstPCBObject;
    while (Pad <> nil) and (Result = nil) do
    begin
        if SameText(Pad.Name, Name) then Result := Pad;
        Pad := GI.NextPCBObject;
    end;
    Comp.GroupIterator_Destroy(GI);
end;

// Everything in S from field Index on, '|' included
function GeoFieldsFrom(S: String; Index: Integer): String;
var
    I, N : Integer;
begin
    Result := '';
    N := 0;
    for I := 1 to Length(S) do
        if S[I] = '|' then
        begin
            N := N + 1;
            if N = Index then
            begin
                Result := Copy(S, I + 1, Length(S) - I);
                Exit;
            end;
        end;
end;

// The object a reference names (see the top of this section), or nil
function GeoFind(Board: IPCB_Board; Ref: String): IPCB_Primitive;
var
    Kind, LayerName : String;
    It   : IPCB_SpatialIterator;
    Prim : IPCB_Primitive;
    Track : IPCB_Track;
    Arc  : IPCB_Arc;
    Via  : IPCB_Via;
    Pad  : IPCB_Pad;
    Fill : IPCB_Fill;
    R    : TCoordRect;
    A, B, C, D, M : Integer;
    ObjSet : TObjectSet;
    TextWanted : String;
begin
    Result := nil;
    Kind := GetFieldFromPipeString(Ref, 0);
    if Kind = 'component' then
    begin
        Result := Board.GetPcbComponentByRefDes(GetFieldFromPipeString(Ref, 1));
        Exit;
    end;
    if (Kind = 'pad') and (StrToIntDef(GetFieldFromPipeString(Ref, 1), -1) = -1) then
    begin
        Result := GeoComponentPad(Board, GetFieldFromPipeString(Ref, 1), GetFieldFromPipeString(Ref, 2));
        Exit;
    end;
    if (Kind = 'via') or (Kind = 'pad') then
    begin
        A := StrToInt(GetFieldFromPipeString(Ref, 1));
        B := StrToInt(GetFieldFromPipeString(Ref, 2));
        C := A;
        D := B;
        LayerName := '';
    end
    else
    begin
        LayerName := GetFieldFromPipeString(Ref, 1);
        A := StrToInt(GetFieldFromPipeString(Ref, 2));
        B := StrToInt(GetFieldFromPipeString(Ref, 3));
        C := StrToIntDef(GetFieldFromPipeString(Ref, 4), A);
        D := StrToIntDef(GetFieldFromPipeString(Ref, 5), B);
    end;
    // A text ref ends in the text itself (which may hold '|'): two texts at
    // one point are told apart by it
    TextWanted := '';
    if Kind = 'text' then
    begin
        C := A;
        D := B;
        TextWanted := GeoFieldsFrom(Ref, 4);
    end;
    if Kind = 'track' then ObjSet := MkSet(eTrackObject)
    else if Kind = 'arc' then ObjSet := MkSet(eArcObject)
    else if Kind = 'via' then ObjSet := MkSet(eViaObject)
    else if Kind = 'pad' then ObjSet := MkSet(ePadObject)
    else if Kind = 'fill' then ObjSet := MkSet(eFillObject)
    else if Kind = 'region' then ObjSet := MkSet(eRegionObject)
    else if Kind = 'text' then ObjSet := MkSet(eTextObject)
    else Exit;
    M := 10;
    It := Board.SpatialIterator_Create;
    It.AddFilter_ObjectSet(ObjSet);
    It.AddFilter_LayerSet(AllLayers);
    It.AddFilter_Area(Min(A, C) - M, Min(B, D) - M, Max(A, C) + M, Max(B, D) + M);
    Prim := It.FirstPCBObject;
    while (Prim <> nil) and (Result = nil) do
    begin
        if (LayerName = '') or SameText(Layer2String(GeoLayer(Prim)), LayerName) then
        begin
            if Kind = 'track' then
            begin
                Track := Prim;
                if ((Track.x1 = A) and (Track.y1 = B) and (Track.x2 = C) and (Track.y2 = D)) or
                   ((Track.x1 = C) and (Track.y1 = D) and (Track.x2 = A) and (Track.y2 = B)) then Result := Prim;
            end
            else if Kind = 'arc' then
            begin
                Arc := Prim;
                if (Arc.XCenter = A) and (Arc.YCenter = B) and (Arc.Radius = C) then Result := Prim;
            end
            else if Kind = 'via' then
            begin
                Via := Prim;
                if (Via.x = A) and (Via.y = B) then Result := Prim;
            end
            else if Kind = 'pad' then
            begin
                Pad := Prim;
                if (Pad.x = A) and (Pad.y = B) then Result := Prim;
            end
            else if Kind = 'fill' then
            begin
                Fill := Prim;
                if (Fill.X1Location = A) and (Fill.Y1Location = B) and (Fill.X2Location = C) and
                   (Fill.Y2Location = D) then Result := Prim;
            end
            else if Kind = 'region' then
            begin
                R := Prim.BoundingRectangle;
                if (R.Left = A) and (R.Bottom = B) and (R.Right = C) and (R.Top = D) then Result := Prim;
            end
            else if Kind = 'text' then
            begin
                if (Prim.XLocation = A) and (Prim.YLocation = B) and (Prim.Text = TextWanted) then Result := Prim;
            end;
        end;
        Prim := It.NextPCBObject;
    end;
    Board.SpatialIterator_Destroy(It);
end;

// Distance between two referenced objects, and the clearance rule between them
function GeoClearance(Board: IPCB_Board; RefA, RefB: String): String;
var
    A, B  : IPCB_Primitive;
    Rule  : IPCB_Rule;
    Props : TStringList;
begin
    A := GeoFind(Board, RefA);
    B := GeoFind(Board, RefB);
    if A = nil then begin Result := 'ERROR: object not found: ' + RefA; Exit; end;
    if B = nil then begin Result := 'ERROR: object not found: ' + RefB; Exit; end;
    Props := TStringList.Create;
    try
        AddJSONProperty(Props, 'a', GeoRecord(A));
        AddJSONProperty(Props, 'b', GeoRecord(B));
        AddJSONInteger(Props, 'distance', Board.PrimPrimDistance(A, B));
        Rule := Board.FindDominantRuleForObjectPair(A, B, eRule_Clearance);
        if Rule <> nil then
        begin
            AddJSONProperty(Props, 'rule', Rule.Name);
            AddJSONInteger(Props, 'rule_gap', Rule.Gap);
            AddJSONBoolean(Props, 'rule_violated', Rule.ActualCheck(A, B) <> nil);
        end;
        Result := BuildJSONObject(Props);
    finally
        Props.Free;
    end;
end;

// The copper layers Via spans, as '|id|id|' for GeoAttached
function GeoViaLayers(Board: IPCB_Board; Via: IPCB_Primitive): String;
var
    LayerIt : IPCB_LayerObjectIterator;
begin
    Result := '|';
    LayerIt := Board.ElectricalLayerIterator;
    while LayerIt.Next do
        if Via.IntersectLayer(LayerIt.LayerObject.LayerID) then
            Result := Result + IntToStr(LayerIt.LayerObject.LayerID) + '|';
end;

// True when Prim is on one of Layers ('|id|id|', or '' for every layer): a
// via when it spans one of them, a Multi Layer pad always
function GeoOnLayers(Board: IPCB_Board; Prim: IPCB_Primitive; Layers: String): Boolean;
var
    LayerIt : IPCB_LayerObjectIterator;
begin
    Result := (Layers = '') or (Prim.Layer = eMultiLayer);
    if Result then Exit;
    if Prim.ObjectId = eViaObject then
    begin
        LayerIt := Board.ElectricalLayerIterator;
        while LayerIt.Next do
            if (Pos('|' + IntToStr(LayerIt.LayerObject.LayerID) + '|', Layers) > 0) and
               Prim.IntersectLayer(LayerIt.LayerObject.LayerID) then Result := True;
    end
    else
        Result := Pos('|' + IntToStr(Prim.Layer) + '|', Layers) > 0;
end;

function GeoListHas(List: TInterfaceList; Prim: IPCB_Primitive): Boolean;
var
    I : Integer;
    Other : IPCB_Primitive;
begin
    Result := False;
    for I := 0 to List.Count - 1 do
    begin
        Other := List[I];
        if Other.I_ObjectAddress = Prim.I_ObjectAddress then Result := True;
    end;
end;

// True when PX,PY lies on the copper of the track X1,Y1-X2,Y2 of Width but
// at neither of its ends: a T-junction
function GeoPartway(X1, Y1, X2, Y2, Width, PX, PY, Tol: Integer): Boolean;
begin
    Result := (GeoSegmentDistance(X1, Y1, X2, Y2, PX, PY) <= Width / 2) and
              not ((Abs(X1 - PX) <= Tol) and (Abs(Y1 - PY) <= Tol)) and
              not ((Abs(X2 - PX) <= Tol) and (Abs(Y2 - PY) <= Tol));
end;

// What sits at X,Y (internal units), for a drag by DX,DY: track ends on a
// layer in Layers ('|id|id|', or '' for every layer) go into Tracks with the
// end in EndNos ('1' or '2'), vias not yet in Vias into Vias; an arc ending
// there, a pad under it or a track of the same net running through it (a
// T-junction the moved point would leave) is named in Blocker, since none of
// them can follow. Skip is the object being moved.
procedure GeoAttached(Board: IPCB_Board; X, Y, DX, DY: Integer; Layers: String; Skip: IPCB_Primitive;
                      Tracks: TInterfaceList; EndNos: TStringList; Vias: TInterfaceList; var Blocker: String);
var
    It    : IPCB_SpatialIterator;
    Prim  : IPCB_Primitive;
    Track : IPCB_Track;
    Arc   : IPCB_Arc;
    R     : TCoordRect;
    Tol   : Integer;
begin
    Tol := 100;
    It := Board.SpatialIterator_Create;
    It.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject, eViaObject, ePadObject));
    It.AddFilter_LayerSet(AllLayers);
    It.AddFilter_Area(X - Tol, Y - Tol, X + Tol, Y + Tol);
    Prim := It.FirstPCBObject;
    while Prim <> nil do
    begin
        if (Prim.I_ObjectAddress <> Skip.I_ObjectAddress) and not Prim.InPolygon and
           GeoOnLayers(Board, Prim, Layers) then
        begin
            if Prim.ObjectId = eTrackObject then
            begin
                Track := Prim;
                if (Abs(Track.x1 - X) <= Tol) and (Abs(Track.y1 - Y) <= Tol) then
                begin
                    Tracks.Add(Track);
                    EndNos.Add('1');
                end
                else if (Abs(Track.x2 - X) <= Tol) and (Abs(Track.y2 - Y) <= Tol) then
                begin
                    Tracks.Add(Track);
                    EndNos.Add('2');
                end
                // A point sliding along the track stays on it
                else if (GeoNet(Track) = GeoNet(Skip)) and
                        GeoPartway(Track.x1, Track.y1, Track.x2, Track.y2, Track.Width, X, Y, Tol) and
                        (GeoSegmentDistance(Track.x1, Track.y1, Track.x2, Track.y2, X + DX, Y + DY) > Track.Width / 2) then
                    Blocker := 'a track (' + Layer2String(Track.Layer) + ', ' + GeoNet(Track) +
                               ') runs through a moved point and would be left behind';
            end
            else if Prim.ObjectId = eViaObject then
            begin
                if (Abs(Prim.x - X) <= Tol) and (Abs(Prim.y - Y) <= Tol) and not GeoListHas(Vias, Prim) then
                    Vias.Add(Prim);
            end
            else if Prim.ObjectId = eArcObject then
            begin
                Arc := Prim;
                if ((Abs(Arc.StartX - X) <= Tol) and (Abs(Arc.StartY - Y) <= Tol)) or
                   ((Abs(Arc.EndX - X) <= Tol) and (Abs(Arc.EndY - Y) <= Tol)) then
                    Blocker := 'an arc (' + Layer2String(Prim.Layer) + ') ends at a moved point and cannot follow';
            end
            else if Prim.ObjectId = ePadObject then
            begin
                R := Prim.BoundingRectangle;
                if (X >= R.Left) and (X <= R.Right) and (Y >= R.Bottom) and (Y <= R.Top) then
                    Blocker := 'pad ' + GeoOwner(Prim) + '-' + Prim.Name + ' lies under a moved point and cannot follow';
            end;
        end;
        Prim := It.NextPCBObject;
    end;
    Board.SpatialIterator_Destroy(It);
end;

// Blocker names Prim when it is locked: a drag would move it anyway
procedure GeoCheckLocked(Prim: IPCB_Primitive; var Blocker: String);
begin
    if not Prim.Moveable then
    begin
        if Prim.ObjectId = eViaObject then
            Blocker := 'a locked via (' + GeoNet(Prim) + ') would move'
        else
            Blocker := 'a locked track (' + Layer2String(Prim.Layer) + ', ' + GeoNet(Prim) + ') would move';
    end;
end;

// True when PX,PY lies partway along Track and is off it once Track runs
// NX1,NY1-NX2,NY2 (a point the move slides along the track stays on it)
function GeoTeeBreaks(Track: IPCB_Track; NX1, NY1, NX2, NY2, PX, PY: Integer): Boolean;
begin
    Result := GeoPartway(Track.x1, Track.y1, Track.x2, Track.y2, Track.Width, PX, PY, 100) and
              (GeoSegmentDistance(NX1, NY1, NX2, NY2, PX, PY) > Track.Width / 2);
end;

// Blocker names copper of Track's net whose end (or centre, for a via or a
// pad) lies partway along Track and is off it once Track runs NX1,NY1-NX2,NY2:
// a T-junction the drag would break. Copper in Tracks and Vias moves anyway.
procedure GeoCheckTees(Board: IPCB_Board; Track: IPCB_Track; NX1, NY1, NX2, NY2: Integer;
                       Tracks, Vias: TInterfaceList; var Blocker: String);
var
    It    : IPCB_SpatialIterator;
    Prim  : IPCB_Primitive;
    Other : IPCB_Track;
    Arc   : IPCB_Arc;
    R     : TCoordRect;
    Kind  : String;
begin
    R := Track.BoundingRectangle;
    It := Board.SpatialIterator_Create;
    It.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject, eViaObject, ePadObject));
    It.AddFilter_LayerSet(AllLayers);
    It.AddFilter_Area(R.Left, R.Bottom, R.Right, R.Top);
    Prim := It.FirstPCBObject;
    while Prim <> nil do
    begin
        Kind := '';
        if (Prim.I_ObjectAddress <> Track.I_ObjectAddress) and not Prim.InPolygon and
           (GeoNet(Prim) = GeoNet(Track)) and not GeoListHas(Tracks, Prim) and not GeoListHas(Vias, Prim) then
        begin
            if Prim.ObjectId = eTrackObject then
            begin
                Other := Prim;
                if (Other.Layer = Track.Layer) and (GeoTeeBreaks(Track, NX1, NY1, NX2, NY2, Other.x1, Other.y1) or
                                                GeoTeeBreaks(Track, NX1, NY1, NX2, NY2, Other.x2, Other.y2)) then
                    Kind := 'a track (' + Layer2String(Other.Layer) + ', ' + GeoNet(Other) + ') ends';
            end
            else if Prim.ObjectId = eArcObject then
            begin
                Arc := Prim;
                if (Arc.Layer = Track.Layer) and (GeoTeeBreaks(Track, NX1, NY1, NX2, NY2, Arc.StartX, Arc.StartY) or
                                              GeoTeeBreaks(Track, NX1, NY1, NX2, NY2, Arc.EndX, Arc.EndY)) then
                    Kind := 'an arc (' + Layer2String(Arc.Layer) + ', ' + GeoNet(Arc) + ') ends';
            end
            else if Prim.ObjectId = eViaObject then
            begin
                if Prim.IntersectLayer(Track.Layer) and GeoTeeBreaks(Track, NX1, NY1, NX2, NY2, Prim.x, Prim.y) then
                    Kind := 'a via (' + GeoNet(Prim) + ') sits';
            end
            else if Prim.ObjectId = ePadObject then
            begin
                if ((Prim.Layer = Track.Layer) or (Prim.Layer = eMultiLayer)) and GeoTeeBreaks(Track, NX1, NY1, NX2, NY2, Prim.x, Prim.y) then
                    Kind := 'pad ' + GeoOwner(Prim) + '-' + Prim.Name + ' sits';
            end;
        end;
        if Kind <> '' then
            Blocker := Kind + ' partway along a moved track (' + Layer2String(Track.Layer) + ', ' + GeoNet(Track) +
                       ') and would be left behind';
        Prim := It.NextPCBObject;
    end;
    Board.SpatialIterator_Destroy(It);
end;

procedure GeoBeginModify(Prim: IPCB_Primitive);
begin
    PCBServer.SendMessageToRobots(Prim.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
end;

procedure GeoEndModify(Prim: IPCB_Primitive);
begin
    PCBServer.SendMessageToRobots(Prim.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
    Prim.GraphicallyInvalidate;
end;

// Drag a via, or a track segment, by DX,DY and keep its copper connected:
// track ends at a moved point follow, and a via at a moved end of a track
// moves too, with the tracks on the other layers it spans. Refused when an
// arc ends at a moved point, a pad lies under one, copper of the same net
// meets a moving track partway along it (a T-junction) or any of that copper
// is locked. With DryRun nothing changes.
function DragCopper(Board: IPCB_Board; Ref: String; DX, DY: Integer; DryRun: Boolean): String;
var
    Obj    : IPCB_Primitive;
    Track, OtherTrack : IPCB_Track;
    Via, OtherVia : IPCB_Via;
    Tracks, Vias, PointVias : TInterfaceList;
    EndNos, Moved, Stretched, Props : TStringList;
    Blocker : String;
    I, J, K, PX, PY : Integer;
    NX1, NY1, NX2, NY2 : Integer;
begin
    Obj := GeoFind(Board, Ref);
    if Obj = nil then begin Result := 'ERROR: object not found: ' + Ref; Exit; end;
    if (Obj.ObjectId <> eViaObject) and (Obj.ObjectId <> eTrackObject) then
    begin
        Result := 'ERROR: only a via or a track can be dragged';
        Exit;
    end;
    if Obj.InPolygon then begin Result := 'ERROR: that is part of a polygon pour'; Exit; end;
    Tracks := TInterfaceList.Create;
    Vias := TInterfaceList.Create;
    PointVias := TInterfaceList.Create;
    EndNos := TStringList.Create;
    Moved := TStringList.Create;
    Stretched := TStringList.Create;
    Props := TStringList.Create;
    try
        Blocker := '';
        if Obj.ObjectId = eViaObject then
        begin
            // A via stacked at the same point moves along, with the tracks
            // on the layers each of them spans (a blind via only its own)
            Vias.Add(Obj);
            I := 0;
            while I < Vias.Count do
            begin
                GeoAttached(Board, Obj.x, Obj.y, DX, DY, GeoViaLayers(Board, Vias[I]), Vias[I], Tracks, EndNos,
                            Vias, Blocker);
                I := I + 1;
            end;
        end
        else
        begin
            Track := Obj;
            for K := 1 to 2 do
            begin
                if K = 1 then begin PX := Track.x1; PY := Track.y1; end
                else begin PX := Track.x2; PY := Track.y2; end;
                // A via at this end moves along, so its tracks on the layers
                // it spans follow
                PointVias.Clear;
                GeoAttached(Board, PX, PY, DX, DY, '|' + IntToStr(Track.Layer) + '|', Obj, Tracks, EndNos, PointVias,
                            Blocker);
                I := 0;
                while I < PointVias.Count do
                begin
                    if not GeoListHas(Vias, PointVias[I]) then Vias.Add(PointVias[I]);
                    GeoAttached(Board, PX, PY, DX, DY, GeoViaLayers(Board, PointVias[I]), PointVias[I], Tracks, EndNos,
                                PointVias, Blocker);
                    I := I + 1;
                end;
            end;
        end;
        // The dragged track, and anything found twice, counts once. By
        // I_ObjectAddress: a track counted twice would move twice as far.
        for I := Tracks.Count - 1 downto 0 do
        begin
            Track := Tracks[I];
            if Track.I_ObjectAddress = Obj.I_ObjectAddress then
            begin
                Tracks.Delete(I);
                EndNos.Delete(I);
                Continue;
            end;
            for J := 0 to I - 1 do
            begin
                OtherTrack := Tracks[J];
                if (Track.I_ObjectAddress = OtherTrack.I_ObjectAddress) and (EndNos[I] = EndNos[J]) then
                begin
                    Tracks.Delete(I);
                    EndNos.Delete(I);
                    Break;
                end;
            end;
        end;
        for I := Vias.Count - 1 downto 1 do
        begin
            Via := Vias[I];
            for J := 0 to I - 1 do
            begin
                OtherVia := Vias[J];
                if Via.I_ObjectAddress = OtherVia.I_ObjectAddress then
                begin
                    Vias.Delete(I);
                    Break;
                end;
            end;
        end;
        // Copper of the same net joined partway along a track that moves
        // stays put: refuse rather than leave it unconnected
        if Obj.ObjectId = eTrackObject then
        begin
            Track := Obj;
            GeoCheckTees(Board, Track, Track.x1 + DX, Track.y1 + DY, Track.x2 + DX, Track.y2 + DY, Tracks, Vias,
                         Blocker);
        end;
        for I := 0 to Tracks.Count - 1 do
        begin
            Track := Tracks[I];
            NX1 := Track.x1;
            NY1 := Track.y1;
            NX2 := Track.x2;
            NY2 := Track.y2;
            // A track between two moved points moves whole
            for J := 0 to Tracks.Count - 1 do
            begin
                OtherTrack := Tracks[J];
                if OtherTrack.I_ObjectAddress = Track.I_ObjectAddress then
                begin
                    if EndNos[J] = '1' then begin NX1 := NX1 + DX; NY1 := NY1 + DY; end
                    else begin NX2 := NX2 + DX; NY2 := NY2 + DY; end;
                end;
            end;
            GeoCheckTees(Board, Track, NX1, NY1, NX2, NY2, Tracks, Vias, Blocker);
        end;
        // Locked copper stays put: refuse rather than move it
        GeoCheckLocked(Obj, Blocker);
        for I := 0 to Vias.Count - 1 do
            GeoCheckLocked(Vias[I], Blocker);
        for I := 0 to Tracks.Count - 1 do
            GeoCheckLocked(Tracks[I], Blocker);
        if (Blocker <> '') and not DryRun then
        begin
            Result := 'ERROR: not dragged: ' + Blocker;
            Exit;
        end;
        if not DryRun then PCBServer.PreProcess;
        try
            if Obj.ObjectId = eTrackObject then
            begin
                Track := Obj;
                if not DryRun then
                begin
                    GeoBeginModify(Track);
                    Track.x1 := Track.x1 + DX;
                    Track.y1 := Track.y1 + DY;
                    Track.x2 := Track.x2 + DX;
                    Track.y2 := Track.y2 + DY;
                    GeoEndModify(Track);
                end;
                Moved.Add('"' + JSONEscapeString(GeoRecord(Track)) + '"');
            end;
            for I := 0 to Vias.Count - 1 do
            begin
                Via := Vias[I];
                if not DryRun then
                begin
                    GeoBeginModify(Via);
                    Via.x := Via.x + DX;
                    Via.y := Via.y + DY;
                    GeoEndModify(Via);
                end;
                Moved.Add('"' + JSONEscapeString(GeoRecord(Via)) + '"');
            end;
            for I := 0 to Tracks.Count - 1 do
            begin
                Track := Tracks[I];
                if not DryRun then
                begin
                    GeoBeginModify(Track);
                    if EndNos[I] = '1' then
                    begin
                        Track.x1 := Track.x1 + DX;
                        Track.y1 := Track.y1 + DY;
                    end
                    else
                    begin
                        Track.x2 := Track.x2 + DX;
                        Track.y2 := Track.y2 + DY;
                    end;
                    GeoEndModify(Track);
                end;
                Stretched.Add('"' + JSONEscapeString(EndNos[I] + '|' + GeoRecord(Track)) + '"');
            end;
        finally
            if not DryRun then PCBServer.PostProcess;
        end;
        if not DryRun then Board.ViewManager_FullUpdate;
        AddJSONBoolean(Props, 'dry_run', DryRun);
        AddJSONProperty(Props, 'blocker', Blocker);
        AddJSONInteger(Props, 'origin_x', Board.XOrigin);
        AddJSONInteger(Props, 'origin_y', Board.YOrigin);
        Props.Add(BuildJSONArray(Moved, 'moved'));
        Props.Add(BuildJSONArray(Stretched, 'stretched'));
        Result := BuildJSONObject(Props);
    finally
        Tracks.Free;
        Vias.Free;
        PointVias.Free;
        EndNos.Free;
        Moved.Free;
        Stretched.Free;
        Props.Free;
    end;
end;

// ---------------------------------------------------------------- object DRC
// The board's own rules run on chosen objects only: each object's
// width / hole rule, and the clearance, short-circuit and hole-to-hole
// rules against every object near it. Rule.ActualCheck is the test the
// batch DRC uses for one object or pair; it returns nil when they comply.

function GeoRuleKindName(Kind: Integer): String;
begin
    case Kind of
        eRule_Clearance:            Result := 'clearance';
        eRule_ShortCircuit:         Result := 'short_circuit';
        eRule_HoleToHoleClearance:  Result := 'hole_to_hole';
        eRule_MaxMinWidth:          Result := 'width';
        eRule_MaxMinHoleSize:       Result := 'hole_size';
    else
        Result := IntToStr(Kind);
    end;
end;

// How far to look for neighbours by default: twice the largest Gap of the
// board's enabled clearance and hole-to-hole rules, plus 10 mil. A rule's
// per-object table (track to pad, ...) can exceed its Gap and is not read
// here; the caller's margin covers a larger entry.
function GeoLargestGap(Board: IPCB_Board): Integer;
var
    It   : IPCB_BoardIterator;
    Rule : IPCB_Rule;
    Gap  : Integer;
begin
    Gap := 0;
    It := Board.BoardIterator_Create;
    It.AddFilter_ObjectSet(MkSet(eRuleObject));
    It.AddFilter_LayerSet(AllLayers);
    It.AddFilter_Method(eProcessAll);
    Rule := It.FirstPCBObject;
    while Rule <> nil do
    begin
        if Rule.Enabled and ((Rule.RuleKind = eRule_Clearance) or (Rule.RuleKind = eRule_HoleToHoleClearance)) then
            if Rule.Gap > Gap then Gap := Rule.Gap;
        Rule := It.NextPCBObject;
    end;
    Board.BoardIterator_Destroy(It);
    Result := 2 * Gap + MilsToCoord(10);
end;

// Copper: a via, a Multi Layer pad, or an object on a signal layer or
// internal plane (pour copper by its polygon's layer). Overlay, mask and
// mechanical objects are not checked.
function GeoOnCopper(Prim: IPCB_Primitive): Boolean;
var
    L : Integer;
begin
    L := GeoLayer(Prim);
    Result := (Prim.ObjectId = eViaObject) or (L = eMultiLayer) or ((L >= eTopLayer) and (L <= eBottomLayer)) or
              ((L >= eInternalPlane1) and (L <= eInternalPlane16));
end;

function GeoHasHole(Prim: IPCB_Primitive): Boolean;
begin
    Result := False;
    if Prim.ObjectId = eViaObject then Result := True
    else if Prim.ObjectId = ePadObject then Result := Prim.HoleSize > 0;
end;

// Pour copper with no net of its own, on the net of Other: a pair the rule
// may judge as two nets (to be confirmed in Altium), so it is flagged
function GeoSameNetPour(Pour, Other: IPCB_Primitive): Boolean;
begin
    Result := False;
    if Pour.InPolygon then
        if Pour.Net = nil then
            if GeoNet(Pour) <> '' then
                Result := SameText(GeoNet(Pour), GeoNet(Other));
end;

// Copper a polygon poured: its regions, or a hatched pour's tracks and arcs
function GeoIsPourCopper(Prim: IPCB_Primitive): Boolean;
begin
    Result := False;
    if Prim <> nil then
        Result := Prim.InPolygon and ((Prim.ObjectId = eRegionObject) or (Prim.ObjectId = eTrackObject) or
                                      (Prim.ObjectId = eArcObject));
end;

procedure GeoAddViolation(Board: IPCB_Board; Items: TStringList; Rule: IPCB_Rule; A, B: IPCB_Primitive;
                          var Hard: Integer);
var
    Item : TStringList;
begin
    // a hit on pour copper goes away with a repour; the rest are hard
    if not (GeoIsPourCopper(A) or GeoIsPourCopper(B)) then Hard := Hard + 1;
    Item := TStringList.Create;
    try
        AddJSONProperty(Item, 'rule', Rule.Name);
        AddJSONProperty(Item, 'kind', GeoRuleKindName(Rule.RuleKind));
        AddJSONProperty(Item, 'a', GeoRecord(A));
        if B <> nil then
        begin
            AddJSONProperty(Item, 'b', GeoRecord(B));
            AddJSONInteger(Item, 'distance', Board.PrimPrimDistance(A, B));
            if GeoSameNetPour(A, B) or GeoSameNetPour(B, A) then AddJSONBoolean(Item, 'same_net_pour', True);
        end;
        if Rule.RuleKind = eRule_Clearance then AddJSONInteger(Item, 'gap', Rule.Gap);
        AddJSONProperty(Item, 'descriptor', Rule.Descriptor);
        Items.Add(BuildJSONObject(Item, 1));
    finally
        Item.Free;
    end;
end;

// Checks Objects against what lies within Margin of them; Items gets one
// JSON object per violation, Hard counts those not against pour copper
procedure GeoCheckObjects(Board: IPCB_Board; Objects: TInterfaceList; Items: TStringList; Margin: Integer;
                          var Pairs: Integer; var Hard: Integer);
var
    A, B  : IPCB_Primitive;
    Rule  : IPCB_Rule;
    It    : IPCB_SpatialIterator;
    R     : TCoordRect;
    i, k, Kind : Integer;
    Seen  : TStringList;
    Key   : String;
begin
    Seen := TStringList.Create;
    try
        Seen.Sorted := True;
        for i := 0 to Objects.Count - 1 do
        begin
            A := Objects.Items[i];
            // the object's own rules
            for k := 0 to 1 do
            begin
                Kind := -1;
                if (k = 0) and ((A.ObjectId = eTrackObject) or (A.ObjectId = eArcObject)) and GeoOnCopper(A) then
                    Kind := eRule_MaxMinWidth;
                if (k = 1) and GeoHasHole(A) then Kind := eRule_MaxMinHoleSize;
                if Kind >= 0 then
                begin
                    Rule := Board.FindDominantRuleForObject(A, Kind);
                    if (Rule <> nil) and Rule.Enabled then
                        if Rule.ActualCheck(A, nil) <> nil then GeoAddViolation(Board, Items, Rule, A, nil, Hard);
                end;
            end;
            // against what is near it
            R := A.BoundingRectangle;
            It := Board.SpatialIterator_Create;
            It.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject, eViaObject, ePadObject, eFillObject, eRegionObject));
            It.AddFilter_LayerSet(AllLayers);
            It.AddFilter_Area(R.Left - Margin, R.Bottom - Margin, R.Right + Margin, R.Top + Margin);
            B := It.FirstPCBObject;
            while B <> nil do
            begin
                if (B.I_ObjectAddress <> A.I_ObjectAddress) and GeoOnCopper(B) then
                begin
                    // each pair once, also when both objects were asked for
                    if A.I_ObjectAddress < B.I_ObjectAddress then
                        Key := IntToStr(A.I_ObjectAddress) + '-' + IntToStr(B.I_ObjectAddress)
                    else
                        Key := IntToStr(B.I_ObjectAddress) + '-' + IntToStr(A.I_ObjectAddress);
                    if Seen.IndexOf(Key) < 0 then
                    begin
                        Seen.Add(Key);
                        Pairs := Pairs + 1;
                        for k := 0 to 2 do
                        begin
                            if k = 0 then Kind := eRule_Clearance
                            else if k = 1 then Kind := eRule_ShortCircuit
                            else Kind := eRule_HoleToHoleClearance;
                            if (Kind <> eRule_HoleToHoleClearance) or (GeoHasHole(A) and GeoHasHole(B)) then
                            begin
                                Rule := Board.FindDominantRuleForObjectPair(A, B, Kind);
                                if (Rule <> nil) and Rule.Enabled then
                                    if Rule.ActualCheck(A, B) <> nil then GeoAddViolation(Board, Items, Rule, A, B, Hard);
                            end;
                        end;
                    end;
                end;
                B := It.NextPCBObject;
            end;
            Board.SpatialIterator_Destroy(It);
        end;
    finally
        Seen.Free;
    end;
end;

// check: Refs ('~'-separated refs) and/or the box X1..Y2 (all copper in it;
// a ref also in the box counts once); at most Limit objects from the box.
// Neighbours are looked for within Margin, or by default (Margin < 0)
// GeoLargestGap.
function GeoCheck(Board: IPCB_Board; Refs: String; HasBox: Boolean; X1, Y1, X2, Y2, Limit, Margin: Integer): String;
var
    Objects : TInterfaceList;
    Items, Props, Missing, RefList : TStringList;
    Prim : IPCB_Primitive;
    It   : IPCB_SpatialIterator;
    Ref  : String;
    i, Pairs, Total, FromRefs, Hard : Integer;
begin
    Objects := TInterfaceList.Create;
    Items := TStringList.Create;
    Props := TStringList.Create;
    Missing := TStringList.Create;
    RefList := TStringList.Create;
    try
        RefList.Text := StringReplace(Refs, '~', #13#10, REPLACEALL);
        for i := 0 to RefList.Count - 1 do
        begin
            Ref := Trim(RefList[i]);
            if Ref = '' then Continue;
            Prim := GeoFind(Board, Ref);
            if Prim = nil then Missing.Add('"' + JSONEscapeString(Ref) + '"')
            else if not GeoListHas(Objects, Prim) then Objects.Add(Prim);
        end;
        Total := Objects.Count;
        FromRefs := Objects.Count;
        if HasBox then
        begin
            It := Board.SpatialIterator_Create;
            It.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject, eViaObject, ePadObject, eFillObject));
            It.AddFilter_LayerSet(AllLayers);
            It.AddFilter_Area(X1, Y1, X2, Y2);
            Prim := It.FirstPCBObject;
            while Prim <> nil do
            begin
                // a ref in the box is checked once, with the refs
                if GeoTouchesBox(Prim, X1, Y1, X2, Y2) and GeoOnCopper(Prim) and not GeoListHas(Objects, Prim) then
                begin
                    Total := Total + 1;
                    if Objects.Count - FromRefs < Limit then Objects.Add(Prim);
                end;
                Prim := It.NextPCBObject;
            end;
            Board.SpatialIterator_Destroy(It);
        end;
        Pairs := 0;
        Hard := 0;
        if Objects.Count = 0 then Margin := 0
        else
        begin
            if Margin < 0 then Margin := GeoLargestGap(Board) + MilsToCoord(1);
            GeoCheckObjects(Board, Objects, Items, Margin, Pairs, Hard);
        end;
        AddJSONProperty(Props, 'board_path', Board.FileName);
        AddJSONInteger(Props, 'origin_x', Board.XOrigin);
        AddJSONInteger(Props, 'origin_y', Board.YOrigin);
        AddJSONInteger(Props, 'objects_checked', Objects.Count);
        AddJSONInteger(Props, 'objects_found', Total);
        AddJSONInteger(Props, 'pairs_checked', Pairs);
        AddJSONInteger(Props, 'search_margin', Margin);
        Props.Add(BuildJSONArray(Missing, 'not_found'));
        Props.Add(BuildJSONArray(Items, 'violations'));
        Result := BuildJSONObject(Props);
    finally
        Objects.Free;
        Items.Free;
        Props.Free;
        Missing.Free;
        RefList.Free;
    end;
end;

// ---------------------------------------------------------------- route
// route_path's Altium side: where pins are, and adding a planned route's
// tracks and vias in one undo step, sized by the rules when no size is
// given, then checked with GeoCheckObjects.

// locate: Refs ('~'-separated) as kind|x|y|layer|through_hole|net each, in
// order ('' when not found). through_hole is 1 for a pad or via on the Multi
// Layer (reachable on any copper layer), told by its layer id, not its name.
// Pads, vias and components only: they have one point, and the other kinds
// have no x and y to read.
function GeoLocate(Board: IPCB_Board; Refs: String): String;
var
    List, Items, Props : TStringList;
    Prim : IPCB_Primitive;
    Comp : IPCB_Component;
    i    : Integer;
    Kind, Rec : String;
begin
    List := TStringList.Create;
    Items := TStringList.Create;
    Props := TStringList.Create;
    try
        List.Text := StringReplace(Refs, '~', #13#10, REPLACEALL);
        for i := 0 to List.Count - 1 do
        begin
            Rec := '';
            Kind := GetFieldFromPipeString(Trim(List[i]), 0);
            Prim := nil;
            if (Kind = 'pad') or (Kind = 'via') or (Kind = 'component') then
                Prim := GeoFind(Board, Trim(List[i]));
            if Prim <> nil then
            begin
                if (Prim.ObjectId = eViaObject) or (Prim.ObjectId = ePadObject) then
                begin
                    if Prim.ObjectId = eViaObject then Kind := 'via|' else Kind := 'pad|';
                    Rec := Kind + IntToStr(Prim.x - Board.XOrigin) + '|' + IntToStr(Prim.y - Board.YOrigin) + '|' +
                           Layer2String(Prim.Layer) + '|' + GeoFlag(Prim.Layer = eMultiLayer) + '|' + GeoNet(Prim);
                end
                else if Prim.ObjectId = eComponentObject then
                begin
                    Comp := Prim;
                    Rec := 'component|' + IntToStr(Comp.x - Board.XOrigin) + '|' + IntToStr(Comp.y - Board.YOrigin) +
                           '||0|';
                end;
            end;
            Items.Add('"' + JSONEscapeString(Rec) + '"');
        end;
        AddJSONProperty(Props, 'board_path', Board.FileName);
        Props.Add(BuildJSONArray(Items, 'located'));
        Result := BuildJSONObject(Props);
    finally
        List.Free;
        Items.Free;
        Props.Free;
    end;
end;

// route: Tracks 'layer|x1|y1|x2|y2' and Vias 'x|y|layer|layer' per
// '~'-separated item (internal units from the origin). Width, ViaSize,
// ViaHole 0: from the rules. The net and every layer are checked before
// anything is added, so a bad item adds nothing. With Undo, a route that
// breaks a rule (other than against pour copper) is taken off again before
// the undo step closes: nothing of it is left, and Ctrl+Z cannot bring it
// back.
function GeoRoute(Board: IPCB_Board; NetName, Tracks, Vias, Layers: String; Width, ViaSize, ViaHole: Integer;
                  Check, Undo: Boolean): String;
var
    Net    : IPCB_Net;
    TrackList, ViaList, LayerList, Items, Made, Props : TStringList;
    Created : TInterfaceList;
    Track  : IPCB_Track;
    Via    : IPCB_Via;
    Rule   : IPCB_Rule;
    Prim   : IPCB_Primitive;
    i, Pairs, L, LowL, HighL, Hard : Integer;
    Removed : Boolean;
    Bad    : String;
begin
    Net := FindBoardNet(Board, NetName);
    if Net = nil then
    begin
        Result := 'ERROR: no net ' + NetName + ' on the board';
        Exit;
    end;
    TrackList := TStringList.Create;
    ViaList := TStringList.Create;
    LayerList := TStringList.Create;
    Items := TStringList.Create;
    Made := TStringList.Create;
    Props := TStringList.Create;
    Created := TInterfaceList.Create;
    try
        TrackList.Text := StringReplace(Tracks, '~', #13#10, REPLACEALL);
        ViaList.Text := StringReplace(Vias, '~', #13#10, REPLACEALL);
        // Every layer is checked before PreProcess, as in CreateVias:
        // String2Layer alone accepts layers the board does not have
        Bad := '';
        // every layer the route names, also one that gets no copper
        LayerList.Text := StringReplace(Layers, '~', #13#10, REPLACEALL);
        for i := 0 to LayerList.Count - 1 do
            if Trim(LayerList[i]) <> '' then
            begin
                L := ResolveBoardLayer(Board, Trim(LayerList[i]));
                if (L = eNoLayer) or (L > eBottomLayer) then
                    Bad := Trim(LayerList[i]) + ' is not a signal layer of this board';
            end;
        for i := 0 to TrackList.Count - 1 do
            if Trim(TrackList[i]) <> '' then
            begin
                L := ResolveBoardLayer(Board, GetFieldFromPipeString(TrackList[i], 0));
                if (L = eNoLayer) or (L > eBottomLayer) then
                    Bad := GetFieldFromPipeString(TrackList[i], 0) + ' is not a signal layer of this board';
            end;
        for i := 0 to ViaList.Count - 1 do
            if Trim(ViaList[i]) <> '' then
            begin
                LowL := ResolveBoardLayer(Board, GetFieldFromPipeString(ViaList[i], 2));
                HighL := ResolveBoardLayer(Board, GetFieldFromPipeString(ViaList[i], 3));
                if (LowL = eNoLayer) or (HighL = eNoLayer) or (LowL > eBottomLayer) or (HighL > eBottomLayer) or
                   (LowL = HighL) then
                    Bad := 'a via joins two different signal layers of this board; ' +
                           GetFieldFromPipeString(ViaList[i], 2) + ' to ' + GetFieldFromPipeString(ViaList[i], 3) +
                           ' is not that';
            end;
        if Bad <> '' then
        begin
            Result := 'ERROR: ' + Bad + '; nothing was added';
            Exit;
        end;

        Pairs := 0;
        Hard := 0;
        Removed := False;
        // PostProcess must run whatever happens, or Altium's undo stays broken
        PCBServer.PreProcess;
        try
            for i := 0 to TrackList.Count - 1 do
            begin
                if Trim(TrackList[i]) = '' then Continue;
                Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
                Track.x1 := Board.XOrigin + StrToInt(GetFieldFromPipeString(TrackList[i], 1));
                Track.y1 := Board.YOrigin + StrToInt(GetFieldFromPipeString(TrackList[i], 2));
                Track.x2 := Board.XOrigin + StrToInt(GetFieldFromPipeString(TrackList[i], 3));
                Track.y2 := Board.YOrigin + StrToInt(GetFieldFromPipeString(TrackList[i], 4));
                Track.Layer := ResolveBoardLayer(Board, GetFieldFromPipeString(TrackList[i], 0));
                Track.Net := Net;
                if Width > 0 then Track.Width := Width else Track.Width := MilsToCoord(10);
                Board.AddPCBObject(Track);
                PCBServer.SendMessageToRobots(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Track.I_ObjectAddress);
                // The width rule for this net and layer, as interactive routing
                // uses it. A rule is found only for an object on the board, so
                // the width changes after AddPCBObject, inside Begin/EndModify.
                if Width <= 0 then
                begin
                    Rule := Board.FindDominantRuleForObject(Track, eRule_MaxMinWidth);
                    if Rule <> nil then
                    begin
                        GeoBeginModify(Track);
                        Track.Width := Rule.FavoredWidth(Track.Layer);
                        GeoEndModify(Track);
                    end;
                end;
                Created.Add(Track);
            end;
            for i := 0 to ViaList.Count - 1 do
            begin
                if Trim(ViaList[i]) = '' then Continue;
                LowL := ResolveBoardLayer(Board, GetFieldFromPipeString(ViaList[i], 2));
                HighL := ResolveBoardLayer(Board, GetFieldFromPipeString(ViaList[i], 3));
                Via := PCBServer.PCBObjectFactory(eViaObject, eNoDimension, eCreate_Default);
                Via.x := Board.XOrigin + StrToInt(GetFieldFromPipeString(ViaList[i], 0));
                Via.y := Board.YOrigin + StrToInt(GetFieldFromPipeString(ViaList[i], 1));
                // LowLayer and HighLayer are the lower and higher layer
                // numbers (Top Layer is 1), whichever end came first
                Via.LowLayer := Min(LowL, HighL);
                Via.HighLayer := Max(LowL, HighL);
                Via.Net := Net;
                if ViaSize > 0 then Via.Size := ViaSize else Via.Size := MilsToCoord(20);
                if ViaHole > 0 then Via.HoleSize := ViaHole else Via.HoleSize := MilsToCoord(10);
                Board.AddPCBObject(Via);
                PCBServer.SendMessageToRobots(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Via.I_ObjectAddress);
                if (ViaSize <= 0) or (ViaHole <= 0) then
                begin
                    Rule := Board.FindDominantRuleForObject(Via, eRule_RoutingViaStyle);
                    if Rule <> nil then
                    begin
                        GeoBeginModify(Via);
                        if ViaSize <= 0 then Via.Size := Rule.PreferedWidth;
                        if ViaHole <= 0 then Via.HoleSize := Rule.PreferedHoleWidth;
                        GeoEndModify(Via);
                    end;
                end;
                Created.Add(Via);
            end;
            if Check then
                GeoCheckObjects(Board, Created, Items, GeoLargestGap(Board) + MilsToCoord(1), Pairs, Hard);
            for i := 0 to Created.Count - 1 do
                Made.Add('"' + JSONEscapeString(GeoRecord(Created.Items[i])) + '"');
            // Taken off inside the same undo step it was added in
            if Undo and (Hard > 0) then
            begin
                for i := 0 to Created.Count - 1 do
                begin
                    Prim := Created.Items[i];
                    Board.RemovePCBObject(Prim);
                    PCBServer.SendMessageToRobots(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration,
                                                  Prim.I_ObjectAddress);
                end;
                Removed := True;
            end;
        finally
            PCBServer.PostProcess;
        end;
        // Bring the ratsnest up to date on the net, as place_copper does, or
        // the lines the route now connects stay drawn
        Board.AnalyzeNet(Net);
        Board.ViewManager_FullUpdate;
        AddJSONProperty(Props, 'board_path', Board.FileName);
        AddJSONInteger(Props, 'origin_x', Board.XOrigin);
        AddJSONInteger(Props, 'origin_y', Board.YOrigin);
        AddJSONBoolean(Props, 'removed_again', Removed);
        AddJSONInteger(Props, 'pairs_checked', Pairs);
        Props.Add(BuildJSONArray(Made, 'created'));
        Props.Add(BuildJSONArray(Items, 'violations'));
        Result := BuildJSONObject(Props);
    finally
        TrackList.Free;
        ViaList.Free;
        LayerList.Free;
        Items.Free;
        Made.Free;
        Props.Free;
        Created.Free;
    end;
end;

// geometry requests: "geometry" names the command (area, outline, clearance,
// check, drag)
function ExecuteGeometry(RequestData: TStringList): String;
var
    Board : IPCB_Board;
    Cmd   : String;
begin
    Board := GetBoardSafe(0);
    if Board = nil then
    begin
        Result := 'ERROR: no PCB is focused';
        Exit;
    end;
    Cmd := RequestText(RequestData, 'geometry', '');
    if Cmd = 'area' then
        // The box is relative to the board origin, as in the other PCB tools
        Result := ObjectsInArea(Board, Board.XOrigin + StrToInt(RequestText(RequestData, 'x1', '0')),
                                Board.YOrigin + StrToInt(RequestText(RequestData, 'y1', '0')),
                                Board.XOrigin + StrToInt(RequestText(RequestData, 'x2', '0')),
                                Board.YOrigin + StrToInt(RequestText(RequestData, 'y2', '0')),
                                RequestText(RequestData, 'kinds', ''),
                                StrToInt(RequestText(RequestData, 'limit', '500')),
                                RequestText(RequestData, 'shapes', 'false') = 'true',
                                RequestText(RequestData, 'include_hidden', 'false') = 'true')
    else if Cmd = 'outline' then
        Result := GeoOutline(Board)
    else if Cmd = 'clearance' then
        Result := GeoClearance(Board, RequestText(RequestData, 'a', ''), RequestText(RequestData, 'b', ''))
    else if Cmd = 'locate' then
        Result := GeoLocate(Board, RequestText(RequestData, 'refs', ''))
    else if Cmd = 'route' then
        Result := GeoRoute(Board, RequestText(RequestData, 'net', ''), RequestText(RequestData, 'tracks', ''),
                           RequestText(RequestData, 'vias', ''), RequestText(RequestData, 'layers', ''),
                           StrToInt(RequestText(RequestData, 'width', '0')),
                           StrToInt(RequestText(RequestData, 'via_size', '0')),
                           StrToInt(RequestText(RequestData, 'via_hole', '0')),
                           RequestText(RequestData, 'check', 'true') = 'true',
                           RequestText(RequestData, 'undo_on_violation', 'false') = 'true')
    else if Cmd = 'check' then
        Result := GeoCheck(Board, RequestText(RequestData, 'refs', ''), RequestText(RequestData, 'x1', '') <> '',
                           Board.XOrigin + StrToIntDef(RequestText(RequestData, 'x1', '0'), 0),
                           Board.YOrigin + StrToIntDef(RequestText(RequestData, 'y1', '0'), 0),
                           Board.XOrigin + StrToIntDef(RequestText(RequestData, 'x2', '0'), 0),
                           Board.YOrigin + StrToIntDef(RequestText(RequestData, 'y2', '0'), 0),
                           StrToInt(RequestText(RequestData, 'limit', '300')),
                           StrToIntDef(RequestText(RequestData, 'margin', '-1'), -1))
    else if Cmd = 'drag' then
        Result := DragCopper(Board, RequestText(RequestData, 'ref', ''),
                             StrToInt(RequestText(RequestData, 'dx', '0')),
                             StrToInt(RequestText(RequestData, 'dy', '0')),
                             RequestText(RequestData, 'dry_run', 'false') = 'true')
    else
        Result := 'ERROR: unknown geometry command ' + Cmd;
end;
