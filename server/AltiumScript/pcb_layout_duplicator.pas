procedure AddLayoutDuplicatorPrimitive(Board: IPCB_Board; Prim: IPCB_Primitive);
begin
    PCBServer.SendMessageToRobots(Prim.I_ObjectAddress, c_Broadcast, PCBM_BeginModify, c_NoEventData);
    try
        Board.AddPCBObject(Prim);
    finally
        PCBServer.SendMessageToRobots(Prim.I_ObjectAddress, c_Broadcast, PCBM_EndModify, c_NoEventData);
    end;
end;

// Duplicate selected objects of the given types.
procedure DuplicateSelectedObjects(Board: IPCB_Board; ObjectSet: TSet; DuplicatedObjects: TObjectList);
var
    Iterator       : IPCB_BoardIterator;
    OrigObj, NewObj : IPCB_Primitive;
begin
    Iterator := Board.BoardIterator_Create;
    try
        Iterator.AddFilter_ObjectSet(ObjectSet);
        Iterator.AddFilter_IPCB_LayerSet(LayerSet.AllLayers);
        Iterator.AddFilter_Method(eProcessAll);

        PCBServer.PreProcess;
        try
            OrigObj := Iterator.FirstPCBObject;
            while OrigObj <> Nil do
            begin
                if OrigObj.Selected then
                begin
                    NewObj := OrigObj.Replicate;
                    AddLayoutDuplicatorPrimitive(Board, NewObj);
                    DuplicatedObjects.Add(NewObj);
                end;
                OrigObj := Iterator.NextPCBObject;
            end;
        finally
            PCBServer.PostProcess;
        end;
    finally
        Board.BoardIterator_Destroy(Iterator);
    end;
    Board.ViewManager_FullUpdate();
end;

// Function to get source and destination component lists with pin data
function GetLayoutDuplicatorComponents(SelectedOnly: Boolean = True): String;
var
    Board          : IPCB_Board;
    Iterator       : IPCB_BoardIterator;
    SourceCmps     : TStringList;
    ResultProps    : TStringList;
    SourceArray    : TStringList;
    DestArray      : TStringList;
    Component      : IPCB_Component;
    CompProps      : TStringList;
    PinsArray      : TStringList;
    GrpIter        : IPCB_GroupIterator;
    Pad            : IPCB_Pad;
    i, j           : Integer;
    PinCount       : Integer;
    NetName        : String;
    xorigin, yorigin : Integer;
    PinProps       : TStringList;
    OutputLines    : TStringList;
    
    // For duplicated objects
    DuplicatedObjects : TObjectList;
    Obj               : IPCB_Primitive;
begin
    // Retrieve the current board
    Board := GetBoardSafe(0);
    if (Board = Nil) then
    begin
        Result := '{"success": false, "message": "No PCB document is currently active"}';
        Exit;
    end;

    // Get board origin coordinates
    xorigin := Board.XOrigin;
    yorigin := Board.YOrigin;

    // Create result properties
    ResultProps := TStringList.Create;
    SourceCmps := TStringList.Create;
    SourceArray := TStringList.Create;
    DuplicatedObjects := TObjectList.Create;
    DuplicatedObjects.OwnsObjects := False;
    
    try
        // Get selected components as source
        Iterator := Board.BoardIterator_Create;
        Iterator.AddFilter_ObjectSet(MkSet(eComponentObject));
        Iterator.AddFilter_LayerSet(MkSet(eTopLayer, eBottomLayer));
        Iterator.AddFilter_Method(eProcessAll);

        Component := Iterator.FirstPCBObject;
        while (Component <> Nil) do
        begin
            if (Component.Selected = True) then
                SourceCmps.Add(Component.Name.Text);

            Component := Iterator.NextPCBObject;
        end;
        Board.BoardIterator_Destroy(Iterator);

        // Check if any source components were selected
        if (SourceCmps.Count = 0) then
        begin
            AddJSONBoolean(ResultProps, 'success', False);
            AddJSONProperty(ResultProps, 'message', 'No source components selected. Please select source components first.');
            
            OutputLines := TStringList.Create;
            try
                OutputLines.Text := BuildJSONObject(ResultProps);
                Result := OutputLines.Text;
            finally
                OutputLines.Free;
            end;
            
            Exit;
        end;
        
        // Duplicate all object types in one call
        DuplicateSelectedObjects(Board, MkSet(eTrackObject, eArcObject, eViaObject, ePolyObject, eRegionObject, eFillObject), DuplicatedObjects);
        
        // Deselect all original objects to avoid duplicating them again
        Iterator := Board.BoardIterator_Create;
        try
            Iterator.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject, eViaObject, ePolyObject, eRegionObject, eFillObject));
            Iterator.AddFilter_IPCB_LayerSet(LayerSet.AllLayers);
            Iterator.AddFilter_Method(eProcessAll);
            PCBServer.PreProcess;
            try
                Obj := Iterator.FirstPCBObject;
                while Obj <> Nil do
                begin
                    if Obj.Selected and (DuplicatedObjects.IndexOf(Obj) < 0) then
                        Obj.Selected := False;
                    Obj := Iterator.NextPCBObject;
                end;
            finally
                PCBServer.PostProcess;
            end;
        finally
            Board.BoardIterator_Destroy(Iterator);
        end;

        // Select only the duplicated objects
        for i := 0 to DuplicatedObjects.Count - 1 do
        begin
            Obj := DuplicatedObjects[i];
            if (Obj <> nil) then
                Obj.Selected := True;
        end;

        // Add source components to JSON
        for i := 0 to SourceCmps.Count - 1 do
        begin
            Component := Board.GetPcbComponentByRefDes(SourceCmps[i]);
            if (Component <> nil) then
            begin
                // Create component properties
                CompProps := TStringList.Create;
                PinsArray := TStringList.Create;
                
                try
                    // Add component properties
                    AddJSONProperty(CompProps, 'designator', Component.Name.Text);
                    AddJSONProperty(CompProps, 'description', Component.SourceDescription);
                    AddJSONProperty(CompProps, 'footprint', Component.Pattern);
                    AddJSONNumber(CompProps, 'rotation', Component.Rotation);
                    AddJSONProperty(CompProps, 'layer', Layer2String(Component.Layer));
                    
                    // Add pin data
                    // Create pad iterator
                    GrpIter := Component.GroupIterator_Create;
                    GrpIter.SetState_FilterAll;
                    GrpIter.AddFilter_ObjectSet(MkSet(ePadObject));

                    // Process each pad
                    Pad := GrpIter.FirstPCBObject;
                    while (Pad <> Nil) do
                    begin
                        if Pad.InComponent then
                        begin
                            // Get net name if connected
                            if (Pad.Net <> Nil) then
                                NetName := JSONEscapeString(Pad.Net.Name)
                            else
                                NetName := '';

                            // Create pin properties
                            PinProps := TStringList.Create;
                            try
                                AddJSONProperty(PinProps, 'name', Pad.Name);
                                AddJSONProperty(PinProps, 'net', NetName);
                                AddJSONNumber(PinProps, 'x', CoordToMils(Pad.x - xorigin));
                                AddJSONNumber(PinProps, 'y', CoordToMils(Pad.y - yorigin));
                                AddJSONProperty(PinProps, 'layer', Layer2String(Pad.Layer));
                                
                                // Add to pins array
                                PinsArray.Add(BuildJSONObject(PinProps, 3));
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
                    
                    // Add to source array
                    SourceArray.Add(BuildJSONObject(CompProps, 2));
                finally
                    CompProps.Free;
                    PinsArray.Free;
                end;
            end;
        end;

        // Do not start Altium's interactive area-select command from MCP.
        // Keep the duplicated routing primitives selected for layout_duplicator_apply.
        ResetParameters;
        RunProcess('PCB:Cancel');
        Client.SendMessage('PCB:Cancel', '', 255, Client.CurrentView);
        Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);

        SourceCmps.Clear();
        DestArray := TStringList.Create();
        
        try
            // Select all duplicated objects for the apply step.
            for i := 0 to DuplicatedObjects.Count - 1 do
            begin
                Obj := DuplicatedObjects[i];
                if (Obj <> nil) then
                    Obj.Selected := True;
            end;
            
            // Add all arrays to result
            AddJSONBoolean(ResultProps, 'success', True);
            ResultProps.Add(BuildJSONArray(SourceArray, 'source_components'));
            ResultProps.Add(BuildJSONArray(DestArray, 'destination_components'));
            AddJSONProperty(ResultProps, 'message', 'Successfully duplicated objects without starting interactive PCB selection. Determine destination components separately, then call layout_duplicator_apply and pass the source and destination lists in matching order.');
            
            // Build final JSON
            OutputLines := TStringList.Create;
            try
                OutputLines.Text := BuildJSONObject(ResultProps);
                Result := OutputLines.Text;
            finally
                OutputLines.Free;
            end;
        finally
            DestArray.Free;
        end;
    finally
        DuplicatedObjects.Free;
        ResultProps.Free;
        SourceCmps.Free;
        SourceArray.Free;
    end;
end;

// Function to check if two points are within tolerance
function CheckWithTolerance(X1, Y1, X2, Y2 : TCoord) : Boolean;
begin
    if (Abs(X1 - X2) <= Tolerance) and (Abs(Y1 - Y2) <= Tolerance) then
        Result := True
    else
        Result := False;
end;

function CountComponentPads(Component: IPCB_Component): Integer;
var
    GrpIter : IPCB_GroupIterator;
    Pad     : IPCB_Pad;
begin
    Result := 0;

    if (Component = nil) then
        Exit;

    GrpIter := Component.GroupIterator_Create;
    if (GrpIter = nil) then
        Exit;

    try
        GrpIter.SetState_FilterAll;
        GrpIter.AddFilter_ObjectSet(MkSet(ePadObject));

        Pad := GrpIter.FirstPCBObject;
        while (Pad <> Nil) do
        begin
            if Pad.InComponent then
                Result := Result + 1;

            Pad := GrpIter.NextPCBObject;
        end;
    finally
        Component.GroupIterator_Destroy(GrpIter);
    end;
end;

function DetermineLayoutDuplicatorSourceGroupSize(SourceList: TStringList): Integer;
var
    i          : Integer;
    FirstSource : String;
begin
    Result := 0;

    if SourceList.Count = 0 then
        Exit;

    FirstSource := SourceList[0];
    Result := SourceList.Count;

    for i := 1 to SourceList.Count - 1 do
    begin
        if SourceList[i] = FirstSource then
        begin
            Result := i;
            Exit;
        end;
    end;
end;

function FindLayoutDuplicatorBoardNetByName(Board: IPCB_Board; NetName: String): IPCB_Net;
var
    Iterator : IPCB_BoardIterator;
    Net      : IPCB_Net;
begin
    Result := nil;

    if (Board = nil) or (NetName = '') then
        Exit;

    Iterator := Board.BoardIterator_Create;
    Iterator.AddFilter_ObjectSet(MkSet(eNetObject));
    Iterator.AddFilter_LayerSet(AllLayers);
    Iterator.AddFilter_Method(eProcessAll);

    try
        Net := Iterator.FirstPCBObject;
        while (Net <> nil) do
        begin
            if Net.Name = NetName then
            begin
                Result := Net;
                Break;
            end;

            Net := Iterator.NextPCBObject;
        end;
    finally
        Board.BoardIterator_Destroy(Iterator);
    end;
end;

function FindLayoutDuplicatorComponentPadByName(Component: IPCB_Component; PadName: String): IPCB_Pad;
var
    GrpIter : IPCB_GroupIterator;
    Pad     : IPCB_Pad;
begin
    Result := nil;

    if (Component = nil) or (PadName = '') then
        Exit;

    GrpIter := Component.GroupIterator_Create;
    if (GrpIter = nil) then
        Exit;

    try
        GrpIter.SetState_FilterAll;
        GrpIter.AddFilter_ObjectSet(MkSet(ePadObject));

        Pad := GrpIter.FirstPCBObject;
        while (Pad <> nil) do
        begin
            if Pad.InComponent and (Pad.Name = PadName) then
            begin
                Result := Pad;
                Break;
            end;

            Pad := GrpIter.NextPCBObject;
        end;
    finally
        Component.GroupIterator_Destroy(GrpIter);
    end;
end;

procedure BuildLayoutDuplicatorNetNameMap(Board: IPCB_Board; SourceList: TStringList; DestList: TStringList; GroupStart: Integer; GroupEnd: Integer; NetNameMap: TStringList);
var
    i         : Integer;
    CmpSrc    : IPCB_Component;
    CmpDst    : IPCB_Component;
    SrcPad    : IPCB_Pad;
    DstPad    : IPCB_Pad;
    GrpIter   : IPCB_GroupIterator;
    SrcNetName: String;
    DstNetName: String;
begin
    NetNameMap.Clear;

    for i := GroupStart to GroupEnd do
    begin
        CmpSrc := Board.GetPcbComponentByRefDes(SourceList.Get(i));
        CmpDst := Board.GetPcbComponentByRefDes(DestList.Get(i));

        if (CmpSrc = nil) or (CmpDst = nil) then
            Continue;

        GrpIter := CmpSrc.GroupIterator_Create;
        if (GrpIter = nil) then
            Continue;

        try
            GrpIter.SetState_FilterAll;
            GrpIter.AddFilter_ObjectSet(MkSet(ePadObject));

            SrcPad := GrpIter.FirstPCBObject;
            while (SrcPad <> nil) do
            begin
                if SrcPad.InComponent and (SrcPad.Net <> nil) then
                begin
                    DstPad := FindLayoutDuplicatorComponentPadByName(CmpDst, SrcPad.Name);
                    if (DstPad <> nil) and (DstPad.Net <> nil) then
                    begin
                        SrcNetName := SrcPad.Net.Name;
                        DstNetName := DstPad.Net.Name;

                        if NetNameMap.IndexOfName(SrcNetName) < 0 then
                            NetNameMap.Values[SrcNetName] := DstNetName;
                    end;
                end;

                SrcPad := GrpIter.NextPCBObject;
            end;
        finally
            CmpSrc.GroupIterator_Destroy(GrpIter);
        end;
    end;
end;

procedure SetLayoutDuplicatorPrimitiveNet(Prim: IPCB_Primitive; Net: IPCB_Net);
begin
    Prim.BeginModify;
    try
        Prim.Net := Net;
    finally
        Prim.EndModify;
    end;
end;

procedure TranslateLayoutDuplicatorPrimitiveNets(Board: IPCB_Board; GroupObjects: TObjectList; NetNameMap: TStringList);
var
    i          : Integer;
    Prim       : IPCB_Primitive;
    SourceName : String;
    DestName   : String;
    DestNet    : IPCB_Net;
begin
    if (Board = nil) or (GroupObjects = nil) or (NetNameMap = nil) then
        Exit;

    for i := 0 to GroupObjects.Count - 1 do
    begin
        Prim := GroupObjects[i];

        if (Prim <> nil) and (Prim.Net <> nil) then
        begin
            SourceName := Prim.Net.Name;
            DestName := NetNameMap.Values[SourceName];

            if (DestName <> '') and (DestName <> SourceName) then
            begin
                DestNet := FindLayoutDuplicatorBoardNetByName(Board, DestName);
                if (DestNet <> nil) then
                begin
                    SetLayoutDuplicatorPrimitiveNet(Prim, DestNet);

                    Board.DispatchMessage(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Prim.I_ObjectAddress);
                end;
            end;
        end;
    end;
end;

function LayoutDuplicatorPrimitiveInBounds(Prim: IPCB_Primitive; LeftBound: TCoord; RightBound: TCoord; BottomBound: TCoord; TopBound: TCoord): Boolean;
var
    Rect : TCoordRect;
begin
    Result := False;

    if (Prim = nil) then
        Exit;

    Rect := Prim.BoundingRectangle;
    Result := (Rect.Left <= RightBound) and
              (Rect.Right >= LeftBound) and
              (Rect.Bottom <= TopBound) and
              (Rect.Top >= BottomBound);
end;

procedure GetLayoutDuplicatorDestGroupBounds(Board: IPCB_Board; DestList: TStringList; GroupStart: Integer; GroupEnd: Integer; Margin: TCoord; var LeftBound: TCoord; var RightBound: TCoord; var BottomBound: TCoord; var TopBound: TCoord; var HasBounds: Boolean);
var
    i      : Integer;
    CmpDst : IPCB_Component;
    Rect   : TCoordRect;
begin
    HasBounds := False;

    for i := GroupStart to GroupEnd do
    begin
        CmpDst := Board.GetPcbComponentByRefDes(DestList.Get(i));
        if (CmpDst = nil) then
            Continue;

        Rect := CmpDst.BoundingRectangle;

        if not HasBounds then
        begin
            LeftBound := Rect.Left;
            RightBound := Rect.Right;
            BottomBound := Rect.Bottom;
            TopBound := Rect.Top;
            HasBounds := True;
        end
        else
        begin
            if Rect.Left < LeftBound then
                LeftBound := Rect.Left;
            if Rect.Right > RightBound then
                RightBound := Rect.Right;
            if Rect.Bottom < BottomBound then
                BottomBound := Rect.Bottom;
            if Rect.Top > TopBound then
                TopBound := Rect.Top;
        end;
    end;

    if HasBounds then
    begin
        LeftBound := LeftBound - Margin;
        RightBound := RightBound + Margin;
        BottomBound := BottomBound - Margin;
        TopBound := TopBound + Margin;
    end;
end;

function RepairLayoutDuplicatorCopiedNets(SourceList: TStringList; DestList: TStringList): String;
var
    Board          : IPCB_Board;
    ResultProps    : TStringList;
    OutputLines    : TStringList;
    NetNameMap     : TStringList;
    Iterator       : IPCB_BoardIterator;
    Prim           : IPCB_Primitive;
    SourceGroupSize: Integer;
    GroupStart     : Integer;
    GroupEnd       : Integer;
    RepairedCount  : Integer;
    LeftBound      : TCoord;
    RightBound     : TCoord;
    BottomBound    : TCoord;
    TopBound       : TCoord;
    HasBounds      : Boolean;
    Margin         : TCoord;
    SourceName     : String;
    DestName       : String;
    DestNet        : IPCB_Net;
    EditStarted    : Boolean;
begin
    Board := PCBServer.GetCurrentPCBBoard;
    if (Board = nil) then
    begin
        Result := '{"success": false, "error": "No PCB document is currently active"}';
        Exit;
    end;

    ResultProps := TStringList.Create;
    NetNameMap := TStringList.Create;
    NetNameMap.NameValueSeparator := '=';
    RepairedCount := 0;
    EditStarted := False;
    SourceGroupSize := DetermineLayoutDuplicatorSourceGroupSize(SourceList);
    Margin := MilsToCoord(250);

    try
        if (SourceGroupSize <= 0) or ((SourceList.Count mod SourceGroupSize) <> 0) or (DestList.Count < SourceList.Count) then
        begin
            AddJSONBoolean(ResultProps, 'success', False);
            AddJSONProperty(ResultProps, 'error', 'Source and destination lists must contain one or more complete layout duplicator groups.');

            OutputLines := TStringList.Create;
            try
                OutputLines.Text := BuildJSONObject(ResultProps);
                Result := OutputLines.Text;
            finally
                OutputLines.Free;
            end;

            Exit;
        end;

        PCBServer.PreProcess;
        EditStarted := True;

        GroupStart := SourceList.Count - SourceGroupSize;
        while GroupStart >= 0 do
        begin
            GroupEnd := GroupStart + SourceGroupSize - 1;

            BuildLayoutDuplicatorNetNameMap(Board, SourceList, DestList, GroupStart, GroupEnd, NetNameMap);
            GetLayoutDuplicatorDestGroupBounds(Board, DestList, GroupStart, GroupEnd, Margin, LeftBound, RightBound, BottomBound, TopBound, HasBounds);

            if HasBounds then
            begin
                Iterator := Board.BoardIterator_Create;
                Iterator.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject, eViaObject, ePolyObject, eRegionObject, eFillObject));
                Iterator.AddFilter_IPCB_LayerSet(LayerSet.AllLayers);
                Iterator.AddFilter_Method(eProcessAll);

                try
                    Prim := Iterator.FirstPCBObject;
                    while (Prim <> nil) do
                    begin
                        if (Prim.Net <> nil) and LayoutDuplicatorPrimitiveInBounds(Prim, LeftBound, RightBound, BottomBound, TopBound) then
                        begin
                            SourceName := Prim.Net.Name;
                            DestName := NetNameMap.Values[SourceName];

                            if (DestName <> '') and (DestName <> SourceName) then
                            begin
                                DestNet := FindLayoutDuplicatorBoardNetByName(Board, DestName);
                                if (DestNet <> nil) then
                                begin
                                    SetLayoutDuplicatorPrimitiveNet(Prim, DestNet);

                                    Board.DispatchMessage(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Prim.I_ObjectAddress);
                                    RepairedCount := RepairedCount + 1;
                                end;
                            end;
                        end;

                        Prim := Iterator.NextPCBObject;
                    end;
                finally
                    Board.BoardIterator_Destroy(Iterator);
                end;
            end;

            GroupStart := GroupStart - SourceGroupSize;
        end;

        EditStarted := False;
        PCBServer.PostProcess;

        ResetParameters;
        AddStringParameter('Action', 'RebuildConnectivity');
        RunProcess('PCB:UpdateConnectivity');
        Board.ConnectivelyValidateNets;
        Board.ViewManager_FullUpdate;

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONInteger(ResultProps, 'repaired_count', RepairedCount);
        AddJSONProperty(ResultProps, 'message', 'Repaired ' + IntToStr(RepairedCount) + ' copied primitives that still carried source nets.');

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        try
            if EditStarted then PCBServer.PostProcess;
        finally
            NetNameMap.Free;
            ResultProps.Free;
        end;
    end;
end;

function FindLayoutDuplicatorAnchor(Board: IPCB_Board; SourceList, DestList: TStringList;
    GroupStart, GroupEnd: Integer): Integer;
var
    CmpSrc, CmpDst: IPCB_Component;
    i, PadCount, LargestPadCount: Integer;
begin
    Result := -1;
    LargestPadCount := -1;
    // Use the most-connected source component as the placement anchor.
    for i := GroupStart to GroupEnd do
    begin
        CmpSrc := Board.GetPcbComponentByRefDes(SourceList[i]);
        CmpDst := Board.GetPcbComponentByRefDes(DestList[i]);
        if (CmpSrc <> nil) and (CmpDst <> nil) then
        begin
            PadCount := CountComponentPads(CmpSrc);
            if PadCount > LargestPadCount then
            begin
                LargestPadCount := PadCount;
                Result := i;
            end;
        end;
    end;
end;

// Function to apply layout duplication with provided source and destination lists
function ApplyLayoutDuplicator(SourceList: TStringList; DestList: TStringList): String;
var
    Board          : IPCB_Board;
    CmpSrc, CmpDst : IPCB_Component;
    AnchorSrc, AnchorDst : IPCB_Component;
    NameSrc, NameDst : TPCB_String;
    i, j           : Integer;
    ResultProps    : TStringList;
    MovedCount     : Integer;
    OutputLines    : TStringList;
    PadIterator    : IPCB_GroupIterator;
    Pad            : IPCB_Pad;
    ProcessedPoints: TStringList;
    Tolerance      : TCoord;

    // For faster tracking of processed primitives
    ProcessedObjects : TStringList;

    // For net tracing
    SelectedObjects : TObjectList;
    TemplateObjects : TObjectList;
    GroupObjects    : TObjectList;
    ConnectedPrim   : IPCB_Primitive;
    TemplatePrim    : IPCB_Primitive;
    NewPrim         : IPCB_Primitive;
    TraceStack      : TStringList;
    X, Y, NextX, NextY : TCoord;
    StackSize       : Integer;
    PointInfo       : String;
    Net             : IPCB_Net;
    ObjectAddress   : Integer;

    // For polygon processing
    Polygon        : IPCB_Primitive;
    PadRect        : TCoordRect;
    PolyRect       : TCoordRect;
    Overlapping    : Boolean;
    PolygonCount   : Integer;

    // For net invalidation
    NetsToInvalidate: TStringList;

    // For source-relative placement around the destination base component
    Anchors         : TStringList;
    AnchorPair      : Integer;
    AnchorDstOriginalX : TCoord;
    AnchorDstOriginalY : TCoord;
    AnchorOffsetX   : TCoord;
    AnchorOffsetY   : TCoord;
    SourceGroupSize : Integer;
    GroupStart      : Integer;
    GroupEnd        : Integer;
    NetNameMap      : TStringList;
    EditStarted     : Boolean;
begin
    // Retrieve the current board
    Board := GetBoardSafe(0);
    if (Board = Nil) then
    begin
        Result := '{"success": false, "error": "No PCB document is currently active"}';
        Exit;
    end;

    SourceGroupSize := DetermineLayoutDuplicatorSourceGroupSize(SourceList);
    Result := '{"success": false, "error": "Source and destination lists must contain one or more complete layout duplicator groups."}';
    if SourceGroupSize <= 0 then Exit;
    if ((SourceList.Count mod SourceGroupSize) <> 0) or (DestList.Count < SourceList.Count) then Exit;

    ResultProps := TStringList.Create;
    EditStarted := False;
    MovedCount := 0;
    PolygonCount := 0;
    AnchorDstOriginalX := 0;
    AnchorDstOriginalY := 0;
    AnchorOffsetX := 0;
    AnchorOffsetY := 0;
    SelectedObjects := nil;
    GroupObjects := nil;

    // Create list to track processed points
    ProcessedPoints := TStringList.Create;
    ProcessedPoints.Duplicates := dupIgnore;  // Ignore duplicate entries

    // Create list to track processed primitives (using object address as string)
    ProcessedObjects := TStringList.Create;
    ProcessedObjects.Duplicates := dupIgnore;  // Ignore duplicate entries

    // Create list for net invalidation (using net names)
    NetsToInvalidate := TStringList.Create;
    NetsToInvalidate.Duplicates := dupIgnore;

    NetNameMap := TStringList.Create;
    NetNameMap.NameValueSeparator := '=';

    // Create stack for tracking points to process
    TraceStack := TStringList.Create;

    // Set a small tolerance for connection checking (1 mil)
    Tolerance := MilsToCoord(1);

    // Create collection for all selected template objects
    TemplateObjects := TObjectList.Create; // Don't own objects
    TemplateObjects.OwnsObjects := False; // Don't destroy objects when list is freed
    Anchors := TStringList.Create;

    try
        // Check every group before moving any components or copying copper.
        GroupStart := 0;
        while GroupStart < SourceList.Count do
        begin
            AnchorPair := FindLayoutDuplicatorAnchor(Board, SourceList, DestList, GroupStart,
                GroupStart + SourceGroupSize - 1);
            if AnchorPair < 0 then
            begin
                Result := '{"success": false, "error": "No valid source/destination component pair in group ' +
                    IntToStr(GroupStart div SourceGroupSize + 1) + '."}';
                Exit;
            end;
            Anchors.Add(IntToStr(AnchorPair));
            GroupStart := GroupStart + SourceGroupSize;
        end;

        // Begin board modification
        PCBServer.PreProcess;
        EditStarted := True;

        // Collect all selected objects first - OPTIMIZATION #1
        // This is our biggest optimization - collecting all selected objects once
        for i := 0 to Board.SelectecObjectCount - 1 do
        begin
            ConnectedPrim := Board.SelectecObject[i];

            // Only collect relevant object types
            if (ConnectedPrim.ObjectId = eTrackObject) or
               (ConnectedPrim.ObjectId = eArcObject) or
               (ConnectedPrim.ObjectId = eViaObject) or
               (ConnectedPrim.ObjectId = ePolyObject) or
               (ConnectedPrim.ObjectId = eRegionObject) or
               (ConnectedPrim.ObjectId = eFillObject) then
            begin
                TemplateObjects.Add(ConnectedPrim);
            end;
        end;

        GroupStart := SourceList.Count - SourceGroupSize;
        while GroupStart >= 0 do
        begin
            GroupEnd := GroupStart + SourceGroupSize - 1;

            AnchorPair := StrToInt(Anchors[GroupStart div SourceGroupSize]);
            AnchorSrc := Board.GetPcbComponentByRefDes(SourceList[AnchorPair]);
            AnchorDst := Board.GetPcbComponentByRefDes(DestList[AnchorPair]);
            AnchorDstOriginalX := AnchorDst.x;
            AnchorDstOriginalY := AnchorDst.y;
            AnchorOffsetX := AnchorDstOriginalX - AnchorSrc.x;
            AnchorOffsetY := AnchorDstOriginalY - AnchorSrc.y;

            BuildLayoutDuplicatorNetNameMap(Board, SourceList, DestList, GroupStart, GroupEnd, NetNameMap);

            GroupObjects := TObjectList.Create;
            GroupObjects.OwnsObjects := False;
            try
                // Copy or move routing primitives from the reference to the current destination anchor.
                for i := 0 to TemplateObjects.Count - 1 do
                begin
                    TemplatePrim := TemplateObjects[i];

                    if GroupStart = 0 then
                        NewPrim := TemplatePrim
                    else
                    begin
                        NewPrim := TemplatePrim.Replicate;
                        AddLayoutDuplicatorPrimitive(Board, NewPrim);
                    end;

                    ConnectedPrim := NewPrim;
                    ConnectedPrim.BeginModify;
                    try
                        ConnectedPrim.MoveByXY(AnchorOffsetX, AnchorOffsetY);
                    finally
                        ConnectedPrim.EndModify;
                    end;

                    Board.DispatchMessage(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, ConnectedPrim.I_ObjectAddress);
                    GroupObjects.Add(NewPrim);
                end;

                SelectedObjects := GroupObjects;

                // Process component pairs
                for i := GroupStart to GroupEnd do
                begin
                    NameSrc := SourceList.Get(i);
                    CmpSrc := Board.GetPcbComponentByRefDes(NameSrc);

                    NameDst := DestList.Get(i);
                    CmpDst := Board.GetPcbComponentByRefDes(NameDst);

                    if ((CmpSrc <> nil) and (CmpDst <> nil)) then
                    begin
                        CmpDst.BeginModify;
                        try
                            CmpDst.Rotation := CmpSrc.Rotation;
                            CmpDst.Layer_V6 := CmpSrc.Layer_V6;
                            CmpDst.x := CmpSrc.x + AnchorOffsetX;
                            CmpDst.y := CmpSrc.y + AnchorOffsetY;
                            CmpDst.Selected := True;
                        finally
                            CmpDst.EndModify;
                        end;

                        // Register component with the board
                        Board.DispatchMessage(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, CmpDst.I_ObjectAddress);

                        // Clear the processed points list for this component
                        ProcessedPoints.Clear;

                        // Clear processed objects list
                        ProcessedObjects.Clear;

                        // Clear nets to invalidate
                        NetsToInvalidate.Clear;

                        // Process all pads in the destination component
                        PadIterator := CmpDst.GroupIterator_Create;
                        PadIterator.AddFilter_ObjectSet(MkSet(ePadObject));

                        Pad := PadIterator.FirstPCBObject;
                        while Pad <> nil do
                        begin
                            // Skip if pad has no net
                            if (Pad.Net <> nil) then
                            begin
                                Net := Pad.Net;

                                // Track this net for final invalidation
                                if NetsToInvalidate.IndexOf(Net.Name) < 0 then
                                    NetsToInvalidate.Add(Net.Name);

                                // Clear the stack
                                TraceStack.Clear;

                                // Add initial pad position to stack
                                TraceStack.Add(IntToStr(Pad.x) + ',' + IntToStr(Pad.y));

                                // Process until stack is empty
                                while TraceStack.Count > 0 do
                                begin
                                    // Pop a point from the stack
                                    StackSize := TraceStack.Count;
                                    PointInfo := TraceStack[StackSize - 1];
                                    TraceStack.Delete(StackSize - 1);

                                    // Skip if we've already processed this point
                                    if ProcessedPoints.IndexOf(PointInfo) >= 0 then
                                        Continue;

                                    // Mark this point as processed
                                    ProcessedPoints.Add(PointInfo);

                                    // Extract X,Y from the point info
                                    X := StrToInt(Copy(PointInfo, 1, Pos(',', PointInfo) - 1));
                                    Y := StrToInt(Copy(PointInfo, Pos(',', PointInfo) + 1, Length(PointInfo)));

                                    // Process all selected objects - OPTIMIZATION
                                    for j := SelectedObjects.Count - 1 downto 0 do
                                    begin
                                        ConnectedPrim := SelectedObjects[j];

                                        // Skip if already processed
                                        ObjectAddress := ConnectedPrim.I_ObjectAddress;
                                        if ProcessedObjects.IndexOf(IntToStr(ObjectAddress)) >= 0 then
                                            Continue;

                                        // Skip if already processed (using object address as identifier)
                                        ObjectAddress := ConnectedPrim.I_ObjectAddress;
                                        if ProcessedObjects.IndexOf(IntToStr(ObjectAddress)) >= 0 then
                                            Continue;

                                        // Check if primitive is at this point
                                        if ConnectedPrim.ObjectId = eTrackObject then
                                        begin
                                            // Check both endpoints
                                            if CheckWithTolerance(ConnectedPrim.x1, ConnectedPrim.y1, X, Y) or
                                               CheckWithTolerance(ConnectedPrim.x2, ConnectedPrim.y2, X, Y) then
                                            begin
                                                // Apply the net
                                                SetLayoutDuplicatorPrimitiveNet(ConnectedPrim, Net);

                                                // Register primitive with the board
                                                Board.DispatchMessage(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, ConnectedPrim.I_ObjectAddress);

                                                // Mark as processed
                                                ProcessedObjects.Add(IntToStr(ObjectAddress));

                                                // Add other endpoint to stack
                                                if CheckWithTolerance(ConnectedPrim.x1, ConnectedPrim.y1, X, Y) then
                                                    TraceStack.Add(IntToStr(ConnectedPrim.x2) + ',' + IntToStr(ConnectedPrim.y2))
                                                else
                                                    TraceStack.Add(IntToStr(ConnectedPrim.x1) + ',' + IntToStr(ConnectedPrim.y1));

                                                // Remove from selected objects to speed up future searches
                                                SelectedObjects.Delete(j);
                                            end;
                                        end
                                        else if ConnectedPrim.ObjectId = eArcObject then
                                        begin
                                            // Check both endpoints
                                            if CheckWithTolerance(ConnectedPrim.StartX, ConnectedPrim.StartY, X, Y) or
                                               CheckWithTolerance(ConnectedPrim.EndX, ConnectedPrim.EndY, X, Y) then
                                            begin
                                                // Apply the net
                                                SetLayoutDuplicatorPrimitiveNet(ConnectedPrim, Net);

                                                // Register primitive with the board
                                                Board.DispatchMessage(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, ConnectedPrim.I_ObjectAddress);

                                                // Mark as processed
                                                ProcessedObjects.Add(IntToStr(ObjectAddress));

                                                // Add other endpoint to stack
                                                if CheckWithTolerance(ConnectedPrim.StartX, ConnectedPrim.StartY, X, Y) then
                                                    TraceStack.Add(IntToStr(ConnectedPrim.EndX) + ',' + IntToStr(ConnectedPrim.EndY))
                                                else
                                                    TraceStack.Add(IntToStr(ConnectedPrim.StartX) + ',' + IntToStr(ConnectedPrim.StartY));

                                                // Remove from selected objects
                                                SelectedObjects.Delete(j);
                                            end;
                                        end
                                        else if ConnectedPrim.ObjectId = eViaObject then
                                        begin
                                            // Check single point
                                            if CheckWithTolerance(ConnectedPrim.x, ConnectedPrim.y, X, Y) then
                                            begin
                                                SetLayoutDuplicatorPrimitiveNet(ConnectedPrim, Net);

                                                // Register primitive with the board
                                                Board.DispatchMessage(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, ConnectedPrim.I_ObjectAddress);

                                                // Mark as processed
                                                ProcessedObjects.Add(IntToStr(ObjectAddress));

                                                // Remove from selected objects
                                                SelectedObjects.Delete(j);

                                                // Mark as processed rather than removing
                                                //ProcessedObjects.Add(IntToStr(ObjectAddress));
                                            end;
                                        end;
                                    end;
                                end;

                                // Process polygons for this pad - using filtered list
                                PadRect := Pad.BoundingRectangle;

                                // Process each selected polygon from our collected objects
                                for j := SelectedObjects.Count - 1 downto 0 do
                                begin
                                    Polygon := SelectedObjects[j];

                                    // Skip if already processed
                                    ObjectAddress := Polygon.I_ObjectAddress;
                                    if ProcessedObjects.IndexOf(IntToStr(ObjectAddress)) >= 0 then
                                        Continue;

                                    // Check if it's a polygon type on the same layer
                                    if ((Polygon.ObjectId = ePolyObject) or
                                        (Polygon.ObjectId = eRegionObject) or
                                        (Polygon.ObjectId = eFillObject)) and
                                        (Polygon.Layer = Pad.Layer) then
                                    begin
                                        // Get polygon's bounding rectangle
                                        PolyRect := Polygon.BoundingRectangle;

                                        // Faster bounding box check
                                        if (PadRect.Left <= PolyRect.Right + Tolerance) and
                                           (PadRect.Right >= PolyRect.Left - Tolerance) and
                                           (PadRect.Bottom <= PolyRect.Top + Tolerance) and
                                           (PadRect.Top >= PolyRect.Bottom - Tolerance) then
                                        begin
                                            Overlapping := False;

                                            // For polygon, use PointInPolygon
                                            if Polygon.ObjectId = ePolyObject then
                                            begin
                                                // Check pad center and corners
                                                X := (PadRect.Left + PadRect.Right) div 2;
                                                Y := (PadRect.Bottom + PadRect.Top) div 2;

                                                if Polygon.PointInPolygon(X, Y) or
                                                   Polygon.PointInPolygon(PadRect.Left, PadRect.Bottom) or
                                                   Polygon.PointInPolygon(PadRect.Left, PadRect.Top) or
                                                   Polygon.PointInPolygon(PadRect.Right, PadRect.Bottom) or
                                                   Polygon.PointInPolygon(PadRect.Right, PadRect.Top) then
                                                begin
                                                    Overlapping := True;
                                                end;
                                            end
                                            // For regions and fills, use distance checking
                                            else if Board.PrimPrimDistance(Pad, Polygon) <= Tolerance then
                                            begin
                                                Overlapping := True;
                                            end;

                                            if Overlapping then
                                            begin
                                                // Assign pad's net to the polygon
                                                SetLayoutDuplicatorPrimitiveNet(Polygon, Net);

                                                // Register with board
                                                Board.DispatchMessage(Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, Polygon.I_ObjectAddress);

                                                // Mark as processed
                                                ProcessedObjects.Add(IntToStr(ObjectAddress));

                                                // Remove from the selected objects
                                                SelectedObjects.Delete(j);

                                                Inc(PolygonCount);
                                            end;
                                        end;
                                    end;
                                end;
                            end;

                            Pad := PadIterator.NextPCBObject;
                        end;

                        CmpDst.GroupIterator_Destroy(PadIterator);

                        MovedCount := MovedCount + 1;
                    end;
                end;

                TranslateLayoutDuplicatorPrimitiveNets(Board, GroupObjects, NetNameMap);
            finally
                SelectedObjects := nil;
                GroupObjects.Free;
                GroupObjects := nil;
            end;

            GroupStart := GroupStart - SourceGroupSize;
        end;

        // End board modification
        EditStarted := False;
        PCBServer.PostProcess;

        // Force redraw of the view - once at the end
        Client.SendMessage('PCB:Zoom', 'Action=Redraw', 255, Client.CurrentView);

        // Update connectivity
        ResetParameters;
        AddStringParameter('Action', 'RebuildConnectivity');
        RunProcess('PCB:UpdateConnectivity');

        // Rebuild net connectivity so ratsnest and net highlighting work correctly
        Board.ConnectivelyValidateNets;

        // Run full update
        Board.ViewManager_FullUpdate;

        // Create result JSON
        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONInteger(ResultProps, 'moved_count', MovedCount);
        AddJSONInteger(ResultProps, 'polygon_count', PolygonCount);
        AddJSONProperty(ResultProps, 'message', 'Successfully duplicated layout and applied nets for ' + IntToStr(MovedCount) +
                        ' components and ' + IntToStr(PolygonCount) + ' polygons/regions/fills.');

        // Build final JSON
        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        try
            if EditStarted then PCBServer.PostProcess;
        finally
            Anchors.Free;
            NetNameMap.Free;
            TemplateObjects.Free;
            NetsToInvalidate.Free;
            ProcessedObjects.Free;
            ProcessedPoints.Free;
            TraceStack.Free;
            ResultProps.Free;
        end;
    end;
end;
