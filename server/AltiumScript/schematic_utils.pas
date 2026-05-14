// Helper function to convert string to pin electrical type
function StrToPinElectricalType(ElecType: String): TPinElectrical;
begin
    if ElecType = 'eElectricHiZ' then
        Result := eElectricHiZ
    else if ElecType = 'eElectricInput' then
        Result := eElectricInput
    else if ElecType = 'eElectricIO' then
        Result := eElectricIO
    else if ElecType = 'eElectricOpenCollector' then
        Result := eElectricOpenCollector
    else if ElecType = 'eElectricOpenEmitter' then
        Result := eElectricOpenEmitter
    else if ElecType = 'eElectricOutput' then
        Result := eElectricOutput
    else if ElecType = 'eElectricPassive' then
        Result := eElectricPassive
    else if ElecType = 'eElectricPower' then
        Result := eElectricPower
    else
        Result := eElectricPassive; // Default
end;

// Helper function to convert string to pin orientation
function StrToPinOrientation(Orient: String): TRotationBy90;
begin
    if Orient = 'eRotate0' then
        Result := eRotate0
    else if Orient = 'eRotate90' then
        Result := eRotate90
    else if Orient = 'eRotate180' then
        Result := eRotate180
    else if Orient = 'eRotate270' then
        Result := eRotate270
    else
        Result := eRotate0; // Default
end;

// Function to get current schematic library component data
function GetLibrarySymbolReference(ROOT_DIR: String): String;
var
    CurrentLib       : ISch_Lib;
    SchComponent     : ISch_Component;
    PinIterator      : ISch_Iterator;
    ParameterIterator : ISch_Iterator;
    Pin              : ISch_Pin;
    Parameter        : ISch_Parameter;
    ComponentProps   : TStringList;
    PinsArray        : TStringList;
    ParametersProps  : TStringList;
    PinProps         : TStringList;
    OutputLines      : TStringList;
    PinName, PinNum  : String;
    ParameterName, ParameterValue : String;
    PinType          : String;
    PinOrient        : String;
    PinX, PinY       : Integer;
begin
    Result := '';
    
    // Check if we have a schematic library document
    CurrentLib := SchServer.GetCurrentSchDocument;
    if (CurrentLib.ObjectID <> eSchLib) Then
    begin
        Result := 'ERROR: Please open a schematic library document';
        Exit;
    end;
    
    // Get the currently focused component from the library
    SchComponent := CurrentLib.CurrentSchComponent;
    if SchComponent = Nil Then
    begin
        Result := 'ERROR: No component is currently selected in the library';
        Exit;
    end;
    
    // Create component properties
    ComponentProps := TStringList.Create;
    
    try
        // Add basic component properties
        AddJSONProperty(ComponentProps, 'library_name', ExtractFileName(CurrentLib.DocumentName));
        AddJSONProperty(ComponentProps, 'component_name', SchComponent.LibReference);
        AddJSONProperty(ComponentProps, 'description', SchComponent.ComponentDescription);
        AddJSONProperty(ComponentProps, 'designator', SchComponent.Designator.Text);
        if (SchComponent.Comment <> Nil) then
            AddJSONProperty(ComponentProps, 'comment', SchComponent.Comment.Text)
        else
            AddJSONProperty(ComponentProps, 'comment', '');
        AddJSONInteger(ComponentProps, 'part_count', SchComponent.PartCount);

        ParametersProps := TStringList.Create;
        try
            ParameterIterator := SchComponent.SchIterator_Create;
            ParameterIterator.AddFilter_ObjectSet(MkSet(eParameter));
            Parameter := ParameterIterator.FirstSchObject;
            while (Parameter <> Nil) do
            begin
                ParameterName := Parameter.Name;
                ParameterValue := Parameter.Text;
                AddJSONProperty(ParametersProps, ParameterName, ParameterValue);
                Parameter := ParameterIterator.NextSchObject;
            end;
            SchComponent.SchIterator_Destroy(ParameterIterator);
            ComponentProps.Add('"parameters": ' + BuildJSONObject(ParametersProps, 1));
        finally
            ParametersProps.Free;
        end;

        // Create an array for pins
        PinsArray := TStringList.Create;
        
        try
            // Create pin iterator
            PinIterator := SchComponent.SchIterator_Create;
            PinIterator.AddFilter_ObjectSet(MkSet(ePin));
            
            Pin := PinIterator.FirstSchObject;
            
            // Process all pins
            while (Pin <> nil) do
            begin
                // Create pin properties
                PinProps := TStringList.Create;
                
                try
                    // Get pin properties
                    PinNum := Pin.Designator;
                    PinName := Pin.Name;
                    
                    // Convert electrical type to string
                    case Pin.Electrical of
                        eElectricHiZ: PinType := 'eElectricHiZ';
                        eElectricInput: PinType := 'eElectricInput';
                        eElectricIO: PinType := 'eElectricIO';
                        eElectricOpenCollector: PinType := 'eElectricOpenCollector';
                        eElectricOpenEmitter: PinType := 'eElectricOpenEmitter';
                        eElectricOutput: PinType := 'eElectricOutput';
                        eElectricPassive: PinType := 'eElectricPassive';
                        eElectricPower: PinType := 'eElectricPower';
                        else PinType := 'eElectricPassive';
                    end;
                    
                    // Convert orientation to string
                    case Pin.Orientation of
                        eRotate0: PinOrient := 'eRotate0';
                        eRotate90: PinOrient := 'eRotate90';
                        eRotate180: PinOrient := 'eRotate180';
                        eRotate270: PinOrient := 'eRotate270';
                        else PinOrient := 'eRotate0';
                    end;
                    
                    // Get coordinates
                    PinX := CoordToMils(Pin.Location.X);
                    PinY := CoordToMils(Pin.Location.Y);
                    
                    // Add pin properties
                    AddJSONProperty(PinProps, 'pin_number', PinNum);
                    AddJSONProperty(PinProps, 'pin_name', PinName);
                    AddJSONProperty(PinProps, 'description', Pin.Description);
                    AddJSONProperty(PinProps, 'pin_type', PinType);
                    AddJSONProperty(PinProps, 'pin_orientation', PinOrient);
                    AddJSONNumber(PinProps, 'x', PinX);
                    AddJSONNumber(PinProps, 'y', PinY);
                    AddJSONInteger(PinProps, 'owner_part_id', Pin.OwnerPartId);

                    // Add this pin to the pins array
                    PinsArray.Add(BuildJSONObject(PinProps, 1));
                    
                    // Move to next pin
                    Pin := PinIterator.NextSchObject;
                finally
                    PinProps.Free;
                end;
            end;
            
            SchComponent.SchIterator_Destroy(PinIterator);
            
            // Add pins array to component - pass empty string as the array name
            // because we're adding it directly to the ComponentProps
            ComponentProps.Add('"pins": ' + BuildJSONArray(PinsArray));
            
            // Build final JSON
            OutputLines := TStringList.Create;
            
            try
                OutputLines.Text := BuildJSONObject(ComponentProps);
                Result := WriteJSONToFile(OutputLines, ROOT_DIR+'temp_symbol_reference.json');
            finally
                OutputLines.Free;
            end;
        finally
            PinsArray.Free;
        end;
    finally
        ComponentProps.Free;
    end;
end;

function IsSymbolMetadataLine(Line: String): Boolean;
begin
    Result := (Pos('Description=', Line) = 1) or
              (Pos('CenterLabel=', Line) = 1) or
              (Pos('CenterLabelPosition=', Line) = 1) or
              (Pos('Comment=', Line) = 1) or
              (Pos('Manufacturer=', Line) = 1) or
              (Pos('PinDescription=', Line) = 1) or
              (Pos('GroupDelimiter=', Line) = 1) or
              (Pos('GroupDelimiterYMM=', Line) = 1) or
              (Pos('SideSectionWidthMM=', Line) = 1) or
              (Pos('Parameter=', Line) = 1);
end;

function MilsStringToGridIndex(Value: String; GridMM: Double): Integer;
begin
    Result := Round(CoordToMMs(MilsToCoord(SafeStrToFloat(Value))) / GridMM);
end;

function CoordToGridIndex(Value: Integer; GridMM: Double): Integer;
begin
    Result := Round(CoordToMMs(Value) / GridMM);
end;

function GridIndexToCoord(GridIndex: Integer; GridMM: Double): Integer;
begin
    Result := MMsToCoord(GridIndex * GridMM);
end;

function StripPinNameFormatting(PinName: String): String;
begin
    Result := StringReplace(PinName, '\', '', REPLACEALL);
end;

function RoundUpMMToGrid(ValueMM: Double; GridMM: Double): Integer;
begin
    Result := Trunc(ValueMM / GridMM);
    if ((Result * GridMM) + 0.001) < ValueMM then
        Result := Result + 1;
end;

function EstimatePinNameLabelWidthGrid(PinName: String; GridMM: Double): Integer;
var
    VisibleText : String;
begin
    VisibleText := StripPinNameFormatting(PinName);
    Result := RoundUpMMToGrid(Length(VisibleText) * 1.55, GridMM);
end;

function PinNameLabelWidthGrid(PinName: String; ReferenceLabel: ISch_Label; GridMM: Double): Integer;
var
    MeasurementLabel : ISch_Label;
    MeasurementRect  : TCoordRect;
    WidthCoord       : Integer;
    MeasuredGrid     : Integer;
begin
    Result := EstimatePinNameLabelWidthGrid(PinName, GridMM);

    MeasurementLabel := Nil;
    if (ReferenceLabel <> Nil) then
        MeasurementLabel := ReferenceLabel.Replicate;
    if (MeasurementLabel = Nil) then
        MeasurementLabel := SchServer.SchObjectFactory(eLabel, eCreate_Default);

    if (MeasurementLabel <> Nil) then
    begin
        MeasurementLabel.Text := StripPinNameFormatting(PinName);
        MeasurementLabel.Location := Point(0, 0);
        MeasurementRect := MeasurementLabel.BoundingRectangle;
        WidthCoord := Abs(MeasurementRect.Right - MeasurementRect.Left);
        MeasuredGrid := RoundUpMMToGrid(CoordToMMs(WidthCoord), GridMM);
        if (MeasuredGrid > 1) then
            MeasuredGrid := MeasuredGrid - 1;
        if (MeasuredGrid > Result) and (MeasuredGrid < 30) then
            Result := MeasuredGrid;
    end;
end;

function CreateSchematicSymbol(SymbolName: String; PinsList: TStringList; PartCount: Integer = 1): String;
var
    CurrentLib       : ISch_Lib;
    ReferenceComponent : ISch_Component;
    ReferencePin     : ISch_Pin;
    ReferenceRect    : ISch_Rectangle;
    ReferenceLine1   : ISch_Line;
    ReferenceLine2   : ISch_Line;
    ReferenceHorizontalLine : ISch_Line;
    ReferenceLabel   : ISch_Label;
    ReferenceParameter : ISch_Parameter;
    SourceParameter  : ISch_Parameter;
    StyleIterator    : ISch_Iterator;
    ParameterIterator : ISch_Iterator;
    ExistingComponent : ISch_Component;
    ExistingComponentToRemove : ISch_Component;
    ExistingIterator  : ISch_Iterator;
    SchComponent     : ISch_Component;
    SchPin           : ISch_Pin;
    SchParameter      : ISch_Parameter;
    SchLine          : ISch_Line;
    SchLabel         : ISch_Label;
    R                : ISch_Rectangle;
    LabelRect        : TCoordRect;
    I, J, PinCount   : Integer;
    ReferenceLineCount : Integer;
    PinData          : TStringList;
    PinName, PinNum  : String;
    PinType          : String;
    PinOrient        : String;
    PinX, PinY       : Integer;
    PinDescription   : String;
    PinOwnerPartId   : Integer;
    PinElec          : TPinElectrical;
    PinOrientation   : TRotationBy90;
    MinX, MaxX, MinY, MaxY : Integer;
    RefMinX, RefMaxX : Integer;
    RefLine1X, RefLine2X : Integer;
    Divider1X, Divider2X : Integer;
    CenterLabelX, CenterLabelY : Integer;
    DelimiterY, DelimiterX1, DelimiterX2 : Integer;
    RequiredSideSectionWidthGrid : Integer;
    PinNameWidthGrid : Integer;
    HasPins          : Boolean;
    ResultProps      : TStringList;
    Description      : String;
    CenterLabel      : String;
    CenterLabelPosition : String;
    CommentText      : String;
    ManufacturerValue : String;
    GridSizeMM       : Double;
    SideSectionWidthGrid : Integer;
    RefSideSectionWidthGrid : Integer;
    BodyCenterXCoord : Integer;
    LabelCenterOffsetX : Integer;
    LabelYCoord      : Integer;
    ParameterName    : String;
    ParameterValue   : String;
    ParameterLine    : String;
    DelimiterSpec, DelimiterSide, DelimiterYText : String;
    PipePos          : Integer;
    ParameterOverrides : TStringList;
    CopiedParameterNames : TStringList;
    PinDescriptions  : TStringList;
    GroupDelimiters  : TStringList;
    OutputLines      : TStringList;
begin
    // Check if we have a schematic library document
    CurrentLib := SchServer.GetCurrentSchDocument;
    if (CurrentLib.ObjectID <> eSchLib) Then
    begin
        Result := 'ERROR: Please open a schematic library document';
        Exit;
    end;

    // Use the currently selected/open library component as a style reference.
    // The new symbol still gets its own pins and body bounds, but replicated
    // primitives preserve the reference pin length, font, colours, and line style.
    ReferenceComponent := CurrentLib.CurrentSchComponent;
    ReferencePin := Nil;
    ReferenceRect := Nil;
    ReferenceLine1 := Nil;
    ReferenceLine2 := Nil;
    ReferenceHorizontalLine := Nil;
    ReferenceLabel := Nil;
    ReferenceParameter := Nil;
    if (ReferenceComponent <> Nil) then
    begin
        StyleIterator := ReferenceComponent.SchIterator_Create;
        try
            StyleIterator.AddFilter_ObjectSet(MkSet(ePin));
            ReferencePin := StyleIterator.FirstSchObject;
        finally
            ReferenceComponent.SchIterator_Destroy(StyleIterator);
        end;

        StyleIterator := ReferenceComponent.SchIterator_Create;
        try
            StyleIterator.AddFilter_ObjectSet(MkSet(eRectangle));
            ReferenceRect := StyleIterator.FirstSchObject;
        finally
            ReferenceComponent.SchIterator_Destroy(StyleIterator);
        end;

        StyleIterator := ReferenceComponent.SchIterator_Create;
        try
            StyleIterator.AddFilter_ObjectSet(MkSet(eLine));
            ReferenceLineCount := 0;
            SchLine := StyleIterator.FirstSchObject;
            while (SchLine <> Nil) do
            begin
                if (Round(CoordToMils(SchLine.Location.X)) = Round(CoordToMils(SchLine.Corner.X))) then
                begin
                    ReferenceLineCount := ReferenceLineCount + 1;
                    if (ReferenceLineCount = 1) then
                        ReferenceLine1 := SchLine
                    else if (ReferenceLineCount = 2) then
                        ReferenceLine2 := SchLine;
                end
                else if (Round(CoordToMils(SchLine.Location.Y)) = Round(CoordToMils(SchLine.Corner.Y))) and
                        (ReferenceHorizontalLine = Nil) then
                begin
                    ReferenceHorizontalLine := SchLine;
                end;
                SchLine := StyleIterator.NextSchObject;
            end;
        finally
            ReferenceComponent.SchIterator_Destroy(StyleIterator);
        end;

        StyleIterator := ReferenceComponent.SchIterator_Create;
        try
            StyleIterator.AddFilter_ObjectSet(MkSet(eLabel));
            ReferenceLabel := StyleIterator.FirstSchObject;
        finally
            ReferenceComponent.SchIterator_Destroy(StyleIterator);
        end;

        StyleIterator := ReferenceComponent.SchIterator_Create;
        try
            StyleIterator.AddFilter_ObjectSet(MkSet(eParameter));
            ReferenceParameter := StyleIterator.FirstSchObject;
        finally
            ReferenceComponent.SchIterator_Destroy(StyleIterator);
        end;
    end;

    Description := 'New Component';  // Default description
    CenterLabel := '';
    CenterLabelPosition := '';
    CommentText := SymbolName;
    ManufacturerValue := '';
    GridSizeMM := 2.5;
    SideSectionWidthGrid := 0;
    RefSideSectionWidthGrid := 0;
    ParameterOverrides := TStringList.Create;
    CopiedParameterNames := TStringList.Create;
    PinDescriptions := TStringList.Create;
    GroupDelimiters := TStringList.Create;
    ParameterOverrides.CaseSensitive := False;
    CopiedParameterNames.CaseSensitive := False;
    PinDescriptions.CaseSensitive := False;

    try
        // Parse the pins list for metadata and auto-detect PartCount from max owner_part_id
        for I := 0 to PinsList.Count - 1 do
        begin
            if (Pos('Description=', PinsList[I]) = 1) then
            begin
                Description := Copy(PinsList[I], 13, Length(PinsList[I]) - 12);
            end
            else if (Pos('CenterLabel=', PinsList[I]) = 1) then
            begin
                CenterLabel := Copy(PinsList[I], 13, Length(PinsList[I]) - 12);
            end
            else if (Pos('CenterLabelPosition=', PinsList[I]) = 1) then
            begin
                CenterLabelPosition := UpperCase(Copy(PinsList[I], 21, Length(PinsList[I]) - 20));
            end
            else if (Pos('Comment=', PinsList[I]) = 1) then
            begin
                CommentText := Copy(PinsList[I], 9, Length(PinsList[I]) - 8);
            end
            else if (Pos('Manufacturer=', PinsList[I]) = 1) then
            begin
                ManufacturerValue := Copy(PinsList[I], 14, Length(PinsList[I]) - 13);
                ParameterOverrides.Values['Manufacturer'] := ManufacturerValue;
            end
            else if (Pos('PinDescription=', PinsList[I]) = 1) then
            begin
                ParameterLine := Copy(PinsList[I], 16, Length(PinsList[I]) - 15);
                PipePos := Pos('|', ParameterLine);
                if (PipePos > 0) then
                begin
                    PinNum := Copy(ParameterLine, 1, PipePos - 1);
                    PinDescription := Copy(ParameterLine, PipePos + 1, Length(ParameterLine) - PipePos);
                    if (PinNum <> '') then
                        PinDescriptions.Values[PinNum] := PinDescription;
                end;
            end
            else if (Pos('GroupDelimiter=', PinsList[I]) = 1) then
            begin
                GroupDelimiters.Add(Copy(PinsList[I], 16, Length(PinsList[I]) - 15));
            end
            else if (Pos('GroupDelimiterYMM=', PinsList[I]) = 1) then
            begin
                GroupDelimiters.Add('BOTH|' + Copy(PinsList[I], 19, Length(PinsList[I]) - 18));
            end
            else if (Pos('SideSectionWidthMM=', PinsList[I]) = 1) then
            begin
                SideSectionWidthGrid := Round(SafeStrToFloat(Copy(PinsList[I], 20, Length(PinsList[I]) - 19)) / GridSizeMM);
            end
            else if (Pos('Parameter=', PinsList[I]) = 1) then
            begin
                ParameterLine := Copy(PinsList[I], 11, Length(PinsList[I]) - 10);
                PipePos := Pos('|', ParameterLine);
                if (PipePos > 0) then
                begin
                    ParameterName := Copy(ParameterLine, 1, PipePos - 1);
                    ParameterValue := Copy(ParameterLine, PipePos + 1, Length(ParameterLine) - PipePos);
                    if (ParameterName <> '') then
                        ParameterOverrides.Values[ParameterName] := ParameterValue;
                end;
            end
            else
            begin
                // Check for owner_part_id in pin data to auto-detect PartCount
                PinData := TStringList.Create;
                try
                    PinData.Delimiter := '|';
                    PinData.DelimitedText := PinsList[I];
                    if (PinData.Count >= 7) then
                    begin
                        PinOwnerPartId := StrToInt(PinData[6]);
                        if (PinOwnerPartId > PartCount) then
                            PartCount := PinOwnerPartId;
                    end;
                finally
                    PinData.Free;
                end;
            end;
        end;

        if (CenterLabel <> '') and (CenterLabelPosition = '') then
            CenterLabelPosition := 'TOPCENTER';
        CommentText := SymbolName;
        ParameterOverrides.Values['PartNumber'] := '=Comment';

    // Find an existing symbol with the same library reference so it can be
    // replaced after the new component has copied all style primitives. This
    // also allows the active target symbol itself to be used as the reference.
    ExistingComponentToRemove := Nil;
    ExistingIterator := CurrentLib.SchLibIterator_Create;
    try
        ExistingIterator.AddFilter_ObjectSet(MkSet(eSchComponent));
        ExistingComponent := ExistingIterator.FirstSchObject;
        while (ExistingComponent <> Nil) do
        begin
            if (UpperCase(ExistingComponent.LibReference) = UpperCase(SymbolName)) then
            begin
                ExistingComponentToRemove := ExistingComponent;
                Break;
            end;
            ExistingComponent := ExistingIterator.NextSchObject;
        end;
    finally
        CurrentLib.SchIterator_Destroy(ExistingIterator);
    end;

    // Create a library component (a page of the library is created)
    SchComponent := SchServer.SchObjectFactory(eSchComponent, eCreate_Default);
    if (SchComponent = Nil) Then
    begin
        Result := 'ERROR: Failed to create component';
        Exit;
    end;

        // Set up parameters for the library component
        SchComponent.CurrentPartID := 1;
        SchComponent.DisplayMode := 0;
        SchComponent.PartCount := PartCount;

        // Define the LibReference, description, and comment
        SchComponent.LibReference := SymbolName;
        SchComponent.ComponentDescription := Description;
        if (SchComponent.Comment <> Nil) then
            SchComponent.Comment.Text := CommentText;
        if (ReferenceComponent <> Nil) then
            SchComponent.Designator.Text := ReferenceComponent.Designator.Text
        else
            SchComponent.Designator.Text := 'U?';

    // Create a body rectangle for each part
    PinCount := 0;
    for J := 1 to PartCount do
    begin
        // Compute bounding box for this part's pins (including shared pins with OwnerPartId=0)
        MinX := 9999; MaxX := -9999; MinY := 9999; MaxY := -9999;
        HasPins := False;
        RequiredSideSectionWidthGrid := 0;

        for I := 0 to PinsList.Count - 1 do
        begin
            if IsSymbolMetadataLine(PinsList[I]) then Continue;

            PinData := TStringList.Create;
            try
                PinData.Delimiter := '|';
                PinData.DelimitedText := PinsList[I];

                if (PinData.Count >= 6) then
                begin
                    PinX := MilsStringToGridIndex(PinData[4], GridSizeMM);
                    PinY := MilsStringToGridIndex(PinData[5], GridSizeMM);

                    // Determine owner part id (default 1 for backward compatibility)
                    if (PinData.Count >= 7) then
                        PinOwnerPartId := StrToInt(PinData[6])
                    else
                        PinOwnerPartId := 1;

                    // Include pin in this part's bounding box if it belongs to this part or is shared (0)
                    if (PinOwnerPartId = J) or (PinOwnerPartId = 0) then
                    begin
                        PinName := PinData[1];
                        PinOrient := PinData[3];
                        MinX := Min(MinX, PinX);
                        MaxX := Max(MaxX, PinX);
                        MinY := Min(MinY, PinY);
                        MaxY := Max(MaxY, PinY);
                        if (PinOrient = 'eRotate0') or (PinOrient = 'eRotate180') then
                        begin
                            PinNameWidthGrid := PinNameLabelWidthGrid(PinName, ReferenceLabel, GridSizeMM);
                            if (PinNameWidthGrid > RequiredSideSectionWidthGrid) then
                                RequiredSideSectionWidthGrid := PinNameWidthGrid;
                        end;
                        HasPins := True;
                    end;
                end;
            finally
                PinData.Free;
            end;
        end;

        // Default rectangle if no pins for this part
        if not HasPins then
        begin
            MinX := 3; MinY := 0; MaxX := 10; MaxY := 10;
        end;

        // Create a rectangle for this part's body
        R := Nil;
        if (ReferenceRect <> Nil) then
            R := ReferenceRect.Replicate;
        if (R = Nil) then
            R := SchServer.SchObjectFactory(eRectangle, eCreate_Default);
        if (R <> Nil) Then
        begin
            if (ReferenceRect = Nil) then
                R.LineWidth := eSmall;
            R.Location := Point(GridIndexToCoord(MinX, GridSizeMM), GridIndexToCoord(MinY - 1, GridSizeMM));
            R.Corner := Point(GridIndexToCoord(MaxX, GridSizeMM), GridIndexToCoord(MaxY + 1, GridSizeMM));
            if (ReferenceRect = Nil) then
            begin
                R.AreaColor := $00B0FFFF; // Yellow (BGR format)
                R.Color := $00FF0000;     // Blue (BGR format)
                R.IsSolid := True;
            end;
            R.OwnerPartId := J;
            R.OwnerPartDisplayMode := 0;
            SchComponent.AddSchObject(R);
        end;

        // Position designator using Part 1's bounding box
        if (J = 1) then
            SchComponent.Designator.Location := Point(GridIndexToCoord(MinX, GridSizeMM), GridIndexToCoord(MaxY + 1, GridSizeMM));

        if (SideSectionWidthGrid > 0) and ((SideSectionWidthGrid * 2) < (MaxX - MinX)) then
        begin
            Divider1X := MinX + SideSectionWidthGrid;
            Divider2X := MaxX - SideSectionWidthGrid;
        end
        else if (ReferenceLine1 <> Nil) and (ReferenceLine2 <> Nil) and (ReferenceRect <> Nil) then
        begin
            RefMinX := Min(CoordToGridIndex(ReferenceRect.Location.X, GridSizeMM), CoordToGridIndex(ReferenceRect.Corner.X, GridSizeMM));
            RefMaxX := Max(CoordToGridIndex(ReferenceRect.Location.X, GridSizeMM), CoordToGridIndex(ReferenceRect.Corner.X, GridSizeMM));
            RefLine1X := CoordToGridIndex(ReferenceLine1.Location.X, GridSizeMM);
            RefLine2X := CoordToGridIndex(ReferenceLine2.Location.X, GridSizeMM);
            if (RefLine1X > RefLine2X) then
            begin
                Divider1X := RefLine1X;
                RefLine1X := RefLine2X;
                RefLine2X := Divider1X;
            end;
            RefSideSectionWidthGrid := Max(RefLine1X - RefMinX, RefMaxX - RefLine2X);
            if (RefSideSectionWidthGrid > 0) and ((RefSideSectionWidthGrid * 2) < (MaxX - MinX)) then
            begin
                Divider1X := MinX + RefSideSectionWidthGrid;
                Divider2X := MaxX - RefSideSectionWidthGrid;
            end
            else
            begin
                Divider1X := MinX + ((MaxX - MinX) div 3);
                Divider2X := MinX + (((MaxX - MinX) * 2) div 3);
            end;
        end
        else
        begin
            Divider1X := MinX + ((MaxX - MinX) div 3);
            Divider2X := MinX + (((MaxX - MinX) * 2) div 3);
        end;

        if (RequiredSideSectionWidthGrid > 0) and ((RequiredSideSectionWidthGrid * 2) < (MaxX - MinX)) then
        begin
            if ((Divider1X - MinX) < RequiredSideSectionWidthGrid) then
                Divider1X := MinX + RequiredSideSectionWidthGrid;
            if ((MaxX - Divider2X) < RequiredSideSectionWidthGrid) then
                Divider2X := MaxX - RequiredSideSectionWidthGrid;
        end;

        if (CenterLabel <> '') and (CenterLabelPosition = 'TOPCENTER') then
            CenterLabelY := MaxY - 1;

        SchLine := Nil;
        if (ReferenceLine1 <> Nil) then
            SchLine := ReferenceLine1.Replicate;
        if (SchLine = Nil) then
            SchLine := SchServer.SchObjectFactory(eLine, eCreate_Default);
        if (SchLine <> Nil) then
        begin
            if (ReferenceLine1 = Nil) and (ReferenceRect <> Nil) then
            begin
                SchLine.Color := ReferenceRect.Color;
                SchLine.LineWidth := ReferenceRect.LineWidth;
            end;
            SchLine.Location := Point(GridIndexToCoord(Divider1X, GridSizeMM), GridIndexToCoord(MinY - 1, GridSizeMM));
            SchLine.Corner := Point(GridIndexToCoord(Divider1X, GridSizeMM), GridIndexToCoord(MaxY + 1, GridSizeMM));
            SchLine.OwnerPartId := J;
            SchLine.OwnerPartDisplayMode := 0;
            SchComponent.AddSchObject(SchLine);
        end;

        SchLine := Nil;
        if (ReferenceLine2 <> Nil) then
            SchLine := ReferenceLine2.Replicate;
        if (SchLine = Nil) then
            SchLine := SchServer.SchObjectFactory(eLine, eCreate_Default);
        if (SchLine <> Nil) then
        begin
            if (ReferenceLine2 = Nil) and (ReferenceRect <> Nil) then
            begin
                SchLine.Color := ReferenceRect.Color;
                SchLine.LineWidth := ReferenceRect.LineWidth;
            end;
            SchLine.Location := Point(GridIndexToCoord(Divider2X, GridSizeMM), GridIndexToCoord(MinY - 1, GridSizeMM));
            SchLine.Corner := Point(GridIndexToCoord(Divider2X, GridSizeMM), GridIndexToCoord(MaxY + 1, GridSizeMM));
            SchLine.OwnerPartId := J;
            SchLine.OwnerPartDisplayMode := 0;
            SchComponent.AddSchObject(SchLine);
        end;

        for I := 0 to GroupDelimiters.Count - 1 do
        begin
            DelimiterSpec := GroupDelimiters[I];
            PipePos := Pos('|', DelimiterSpec);
            if (PipePos > 0) then
            begin
                DelimiterSide := UpperCase(Copy(DelimiterSpec, 1, PipePos - 1));
                DelimiterYText := Copy(DelimiterSpec, PipePos + 1, Length(DelimiterSpec) - PipePos);
            end
            else
            begin
                DelimiterSide := 'BOTH';
                DelimiterYText := DelimiterSpec;
            end;
            DelimiterY := Round(SafeStrToFloat(DelimiterYText) / GridSizeMM);

            if (DelimiterSide = 'FULL') then
            begin
                DelimiterX1 := MinX;
                DelimiterX2 := MaxX;
            end
            else if (DelimiterSide = 'CENTER') then
            begin
                DelimiterX1 := Divider1X;
                DelimiterX2 := Divider2X;
            end
            else if (DelimiterSide = 'RIGHT') then
            begin
                DelimiterX1 := Divider2X;
                DelimiterX2 := MaxX;
            end
            else
            begin
                DelimiterX1 := MinX;
                DelimiterX2 := Divider1X;
            end;

            SchLine := Nil;
            if (ReferenceHorizontalLine <> Nil) then
                SchLine := ReferenceHorizontalLine.Replicate
            else if (ReferenceLine1 <> Nil) then
                SchLine := ReferenceLine1.Replicate;
            if (SchLine = Nil) then
                SchLine := SchServer.SchObjectFactory(eLine, eCreate_Default);
            if (SchLine <> Nil) then
            begin
                if (ReferenceHorizontalLine = Nil) and (ReferenceLine1 = Nil) and (ReferenceRect <> Nil) then
                begin
                    SchLine.Color := ReferenceRect.Color;
                    SchLine.LineWidth := ReferenceRect.LineWidth;
                end;
                SchLine.Location := Point(GridIndexToCoord(DelimiterX1, GridSizeMM), GridIndexToCoord(DelimiterY, GridSizeMM));
                SchLine.Corner := Point(GridIndexToCoord(DelimiterX2, GridSizeMM), GridIndexToCoord(DelimiterY, GridSizeMM));
                SchLine.OwnerPartId := J;
                SchLine.OwnerPartDisplayMode := 0;
                SchComponent.AddSchObject(SchLine);
            end;

            if (DelimiterSide = 'BOTH') then
            begin
                SchLine := Nil;
                if (ReferenceHorizontalLine <> Nil) then
                    SchLine := ReferenceHorizontalLine.Replicate
                else if (ReferenceLine2 <> Nil) then
                    SchLine := ReferenceLine2.Replicate
                else if (ReferenceLine1 <> Nil) then
                    SchLine := ReferenceLine1.Replicate;
                if (SchLine = Nil) then
                    SchLine := SchServer.SchObjectFactory(eLine, eCreate_Default);
                if (SchLine <> Nil) then
                begin
                    if (ReferenceHorizontalLine = Nil) and (ReferenceLine1 = Nil) and (ReferenceRect <> Nil) then
                    begin
                        SchLine.Color := ReferenceRect.Color;
                        SchLine.LineWidth := ReferenceRect.LineWidth;
                    end;
                    SchLine.Location := Point(GridIndexToCoord(Divider2X, GridSizeMM), GridIndexToCoord(DelimiterY, GridSizeMM));
                    SchLine.Corner := Point(GridIndexToCoord(MaxX, GridSizeMM), GridIndexToCoord(DelimiterY, GridSizeMM));
                    SchLine.OwnerPartId := J;
                    SchLine.OwnerPartDisplayMode := 0;
                    SchComponent.AddSchObject(SchLine);
                end;
            end;
        end;

        if (CenterLabel <> '') then
        begin
            if (CenterLabelPosition = 'TOPCENTER') then
                CenterLabelY := MaxY - 1
            else
            begin
                CenterLabelX := Divider1X + 1;
                CenterLabelY := MinY + ((MaxY - MinY) div 2);
            end;
            SchLabel := Nil;
            if (ReferenceLabel <> Nil) then
                SchLabel := ReferenceLabel.Replicate;
            if (SchLabel = Nil) then
                SchLabel := SchServer.SchObjectFactory(eLabel, eCreate_Default);
            if (SchLabel <> Nil) then
            begin
                SchLabel.Text := CenterLabel;
                if (CenterLabelPosition = 'TOPCENTER') then
                begin
                    BodyCenterXCoord := (GridIndexToCoord(MinX, GridSizeMM) + GridIndexToCoord(MaxX, GridSizeMM)) div 2;
                    LabelYCoord := GridIndexToCoord(CenterLabelY, GridSizeMM);
                    SchLabel.Location := Point(BodyCenterXCoord, LabelYCoord);
                    LabelRect := SchLabel.BoundingRectangle;
                    LabelCenterOffsetX := ((LabelRect.Left + LabelRect.Right) div 2) - BodyCenterXCoord;
                    SchLabel.Location := Point(BodyCenterXCoord - LabelCenterOffsetX, LabelYCoord);
                end
                else
                    SchLabel.Location := Point(GridIndexToCoord(CenterLabelX, GridSizeMM), GridIndexToCoord(CenterLabelY, GridSizeMM));
                SchLabel.OwnerPartId := J;
                SchLabel.OwnerPartDisplayMode := 0;
                SchComponent.AddSchObject(SchLabel);
            end;
        end;
    end;

    // Add pins to the component
    for I := 0 to PinsList.Count - 1 do
    begin
        if IsSymbolMetadataLine(PinsList[I]) then Continue;

        PinData := TStringList.Create;
        try
            PinData.Delimiter := '|';
            PinData.DelimitedText := PinsList[I];

            if (PinData.Count >= 6) then
            begin
                PinNum := PinData[0];
                PinName := PinData[1];
                PinType := PinData[2];
                PinOrient := PinData[3];
                PinX := MilsStringToGridIndex(PinData[4], GridSizeMM);
                PinY := MilsStringToGridIndex(PinData[5], GridSizeMM);

                // Determine owner part id (default 1 for backward compatibility)
                if (PinData.Count >= 7) then
                    PinOwnerPartId := StrToInt(PinData[6])
                else
                    PinOwnerPartId := 1;

                // Create a pin
                SchPin := Nil;
                if (ReferencePin <> Nil) then
                    SchPin := ReferencePin.Replicate;
                if (SchPin = Nil) then
                    SchPin := SchServer.SchObjectFactory(ePin, eCreate_Default);
                if (SchPin = Nil) Then
                    Continue;

                // Set pin properties
                PinElec := StrToPinElectricalType(PinType);
                PinOrientation := StrToPinOrientation(PinOrient);

                SchPin.Designator := PinNum;
                SchPin.Name := PinName;
                SchPin.Electrical := PinElec;
                SchPin.Orientation := PinOrientation;
                SchPin.Location := Point(GridIndexToCoord(PinX, GridSizeMM), GridIndexToCoord(PinY, GridSizeMM));
                SchPin.Description := PinDescriptions.Values[PinNum];

                // Set ownership to the specified part (0 = shared across all parts)
                SchPin.OwnerPartId := PinOwnerPartId;
                SchPin.OwnerPartDisplayMode := 0;

                SchComponent.AddSchObject(SchPin);
                PinCount := PinCount + 1;
            end;
        finally
            PinData.Free;
        end;
    end;

    // Copy all component parameters from the reference symbol, with explicit
    // metadata overrides for fields that belong to the new part.
    if (ReferenceComponent <> Nil) then
    begin
        ParameterIterator := ReferenceComponent.SchIterator_Create;
        try
            ParameterIterator.AddFilter_ObjectSet(MkSet(eParameter));
            SourceParameter := ParameterIterator.FirstSchObject;
            while (SourceParameter <> Nil) do
            begin
                ParameterName := SourceParameter.Name;
                ParameterValue := SourceParameter.Text;

                if (UpperCase(ParameterName) = 'MANUFACTURER') and (ManufacturerValue <> '') then
                    ParameterValue := ManufacturerValue;
                if (UpperCase(ParameterName) = 'COMMENT') and (CommentText <> '') then
                    ParameterValue := CommentText;
                if (ParameterOverrides.Values[ParameterName] <> '') then
                    ParameterValue := ParameterOverrides.Values[ParameterName];

                SchParameter := SourceParameter.Replicate;
                if (SchParameter = Nil) then
                    SchParameter := SchServer.SchObjectFactory(eParameter, eCreate_Default);
                if (SchParameter <> Nil) then
                begin
                    SchParameter.Name := ParameterName;
                    SchParameter.Text := ParameterValue;
                    SchComponent.AddSchObject(SchParameter);
                    CopiedParameterNames.Add(UpperCase(ParameterName));
                end;

                SourceParameter := ParameterIterator.NextSchObject;
            end;
        finally
            ReferenceComponent.SchIterator_Destroy(ParameterIterator);
        end;
    end;

    if (ManufacturerValue <> '') and (CopiedParameterNames.IndexOf('MANUFACTURER') < 0) then
    begin
        SchParameter := Nil;
        if (ReferenceParameter <> Nil) then
            SchParameter := ReferenceParameter.Replicate;
        if (SchParameter = Nil) then
            SchParameter := SchServer.SchObjectFactory(eParameter, eCreate_Default);
        if (SchParameter <> Nil) then
        begin
            SchParameter.Name := 'Manufacturer';
            SchParameter.Text := ManufacturerValue;
            SchComponent.AddSchObject(SchParameter);
            CopiedParameterNames.Add('MANUFACTURER');
        end;
    end;

    if (CopiedParameterNames.IndexOf('PARTNUMBER') < 0) then
    begin
        SchParameter := Nil;
        if (ReferenceParameter <> Nil) then
            SchParameter := ReferenceParameter.Replicate;
        if (SchParameter = Nil) then
            SchParameter := SchServer.SchObjectFactory(eParameter, eCreate_Default);
        if (SchParameter <> Nil) then
        begin
            SchParameter.Name := 'PartNumber';
            SchParameter.Text := '=Comment';
            SchComponent.AddSchObject(SchParameter);
            CopiedParameterNames.Add('PARTNUMBER');
        end;
    end;

    // Replace the old component only after all reference style objects have
    // been replicated into the new component.
    if (ExistingComponentToRemove <> Nil) then
        CurrentLib.RemoveSchComponent(ExistingComponentToRemove);

    // Add the component to the library
    CurrentLib.AddSchComponent(SchComponent);

    // Send a system notification that a new component has been added to the library
    SchServer.RobotManager.SendMessage(nil, c_BroadCast, SCHM_PrimitiveRegistration, SchComponent.I_ObjectAddress);
    CurrentLib.CurrentSchComponent := SchComponent;

    // Refresh library
    CurrentLib.GraphicallyInvalidate;

    // Create result JSON
    ResultProps := TStringList.Create;
    try
        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'component_name', SymbolName);
        AddJSONInteger(ResultProps, 'pins_count', PinCount);
        AddJSONInteger(ResultProps, 'part_count', PartCount);

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
    end;
    finally
        ParameterOverrides.Free;
        CopiedParameterNames.Free;
        PinDescriptions.Free;
        GroupDelimiters.Free;
    end;
end;

// Function to search for a symbol in a schematic library and navigate to it
function SearchLibrarySymbol(ROOT_DIR: String; LibraryPath: String; SymbolName: String): String;
var
    CurrentLib       : ISch_Lib;
    LibIterator      : ISch_Iterator;
    LibComp          : ISch_Component;
    MatchedComp      : ISch_Component;
    ResultProps      : TStringList;
    MatchesArray     : TStringList;
    AllSymbolsArray  : TStringList;
    MatchProps       : TStringList;
    OutputLines      : TStringList;
    SearchUpper      : String;
    LibRefUpper      : String;
    MatchCount       : Integer;
    ServerDoc        : IServerDocument;
    OpenDlg          : TOpenDialog;
    NeedToOpen       : Boolean;
begin
    Result := '';
    MatchedComp := Nil;
    MatchCount := 0;
    SearchUpper := UpperCase(SymbolName);
    NeedToOpen := False;

    // If a library path is provided, open it
    if (LibraryPath <> '') then
    begin
        NeedToOpen := True;
    end
    else
    begin
        // No path provided - check if a SchLib is already open
        if (SchServer <> Nil) then
        begin
            CurrentLib := SchServer.GetCurrentSchDocument;
            if (CurrentLib <> Nil) and (CurrentLib.ObjectID = eSchLib) then
                NeedToOpen := False  // Already have a SchLib open
            else
                NeedToOpen := True;  // No SchLib open, need to browse
        end
        else
            NeedToOpen := True;
    end;

    // If we need to open a library and no path was given, prompt the user
    if NeedToOpen and (LibraryPath = '') then
    begin
        OpenDlg := TOpenDialog.Create(nil);
        try
            OpenDlg.Title := 'Select Schematic Library (.SchLib)';
            OpenDlg.Filter := 'Schematic Library (*.SchLib)|*.SchLib|All Files (*.*)|*.*';
            OpenDlg.FilterIndex := 1;
            if OpenDlg.Execute then
                LibraryPath := OpenDlg.FileName
            else
            begin
                Result := 'ERROR: No library selected. User cancelled the file browser.';
                Exit;
            end;
        finally
            OpenDlg.Free;
        end;
    end;

    // Open the library if we have a path
    if (LibraryPath <> '') then
    begin
        // Check if the file exists
        if not FileExists(LibraryPath) then
        begin
            Result := 'ERROR: Library file not found: ' + LibraryPath;
            Exit;
        end;

        // Open the library document
        ServerDoc := Client.OpenDocument('SchLib', LibraryPath);
        if ServerDoc = Nil then
        begin
            Result := 'ERROR: Failed to open library: ' + LibraryPath;
            Exit;
        end;
        Client.ShowDocument(ServerDoc);
        Sleep(500); // Give Altium time to focus the document
    end;

    // Get the current schematic library document
    CurrentLib := SchServer.GetCurrentSchDocument;
    if CurrentLib = Nil then
    begin
        Result := 'ERROR: No schematic library document is currently open';
        Exit;
    end;

    if (CurrentLib.ObjectID <> eSchLib) then
    begin
        Result := 'ERROR: Current document is not a schematic library. Please open a .SchLib file';
        Exit;
    end;

    // Create arrays for results
    MatchesArray := TStringList.Create;
    AllSymbolsArray := TStringList.Create;
    ResultProps := TStringList.Create;

    try
        // Create library iterator to enumerate all symbols
        // NOTE: Must use SchLibIterator_Create (not SchIterator_Create) for SchLib documents
        LibIterator := CurrentLib.SchLibIterator_Create;
        LibIterator.AddFilter_ObjectSet(MkSet(eSchComponent));

        LibComp := LibIterator.FirstSchObject;
        while (LibComp <> Nil) do
        begin
            LibRefUpper := UpperCase(LibComp.LibReference);

            // Add to all symbols list
            AllSymbolsArray.Add('"' + LibComp.LibReference + '"');

            // Check for partial match
            if (Pos(SearchUpper, LibRefUpper) > 0) then
            begin
                MatchCount := MatchCount + 1;

                // Record this match
                MatchProps := TStringList.Create;
                try
                    AddJSONProperty(MatchProps, 'name', LibComp.LibReference);
                    AddJSONProperty(MatchProps, 'description', LibComp.ComponentDescription);

                    // Check for exact match
                    if (LibRefUpper = SearchUpper) then
                        AddJSONBoolean(MatchProps, 'exact_match', True)
                    else
                        AddJSONBoolean(MatchProps, 'exact_match', False);

                    MatchesArray.Add(BuildJSONObject(MatchProps, 1));
                finally
                    MatchProps.Free;
                end;

                // Prefer exact match, otherwise use first partial match
                if (LibRefUpper = SearchUpper) then
                    MatchedComp := LibComp
                else if (MatchedComp = Nil) then
                    MatchedComp := LibComp;
            end;

            LibComp := LibIterator.NextSchObject;
        end;

        CurrentLib.SchIterator_Destroy(LibIterator);

        // Navigate to the matched component if found
        if (MatchedComp <> Nil) then
        begin
            CurrentLib.CurrentSchComponent := MatchedComp;
            CurrentLib.GraphicallyInvalidate;

            AddJSONBoolean(ResultProps, 'found', True);
            AddJSONProperty(ResultProps, 'navigated_to', MatchedComp.LibReference);
            AddJSONProperty(ResultProps, 'description', MatchedComp.ComponentDescription);
        end
        else
        begin
            AddJSONBoolean(ResultProps, 'found', False);
            AddJSONProperty(ResultProps, 'message', 'No symbol matching "' + SymbolName + '" was found');
        end;

        AddJSONInteger(ResultProps, 'match_count', MatchCount);
        AddJSONProperty(ResultProps, 'library_name', ExtractFileName(CurrentLib.DocumentName));
        AddJSONInteger(ResultProps, 'total_symbols', AllSymbolsArray.Count);
        ResultProps.Add('"matches": ' + BuildJSONArray(MatchesArray));

        // Build final JSON
        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := WriteJSONToFile(OutputLines, ROOT_DIR + 'temp_search_symbol.json');
        finally
            OutputLines.Free;
        end;
    finally
        MatchesArray.Free;
        AllSymbolsArray.Free;
        ResultProps.Free;
    end;
end;

// Function to get all schematic component data
function GetSchematicData(ROOT_DIR: String): String;
var
    Project     : IProject;
    Doc         : IDocument;
    CurrentSch  : ISch_Document;
    Iterator    : ISch_Iterator;
    PIterator   : ISch_Iterator;
    Component   : ISch_Component;
    Parameter, NextParameter : ISch_Parameter;
    Rect        : TCoordRect;
    ComponentsArray : TStringList;
    CompProps   : TStringList;
    ParamsProps : TStringList;
    OutputLines : TStringList;
    Designator, Sheet, ParameterName, ParameterValue : String;
    x, y, width, height, rotation : String;
    left, right, top, bottom : String;
    i : Integer;
    SchematicCount, ComponentCount : Integer;
begin
    Result := '';

    // Retrieve the current project
    Project := GetWorkspace.DM_FocusedProject;
    If (Project = Nil) Then
    begin
        ShowMessage('Error: No project is currently open');
        Exit;
    end;

    // Create array for components
    ComponentsArray := TStringList.Create;
    
    try
        // Count the number of schematic documents
        SchematicCount := 0;
        For i := 0 to Project.DM_LogicalDocumentCount - 1 Do
        Begin
            Doc := Project.DM_LogicalDocuments(i);
            If Doc.DM_DocumentKind = 'SCH' Then
                SchematicCount := SchematicCount + 1;
        End;

        // Process each schematic document
        ComponentCount := 0;
        For i := 0 to Project.DM_LogicalDocumentCount - 1 Do
        Begin
            Doc := Project.DM_LogicalDocuments(i);
            If Doc.DM_DocumentKind = 'SCH' Then
            Begin
                // Open the schematic document
                Client.OpenDocument('SCH', Doc.DM_FullPath);
                CurrentSch := SchServer.GetSchDocumentByPath(Doc.DM_FullPath);

                If (CurrentSch <> Nil) Then
                Begin
                    // Get schematic components
                    Iterator := CurrentSch.SchIterator_Create;
                    Iterator.AddFilter_ObjectSet(MkSet(eSchComponent));

                    Component := Iterator.FirstSchObject;
                    While (Component <> Nil) Do
                    Begin
                        // Create component properties
                        CompProps := TStringList.Create;
                        
                        try
                            // Get basic component properties
                            Designator := Component.Designator.Text;
                            Sheet := Doc.DM_FullPath;

                            // Get position, dimensions and rotation
                            x := FloatToStr(CoordToMils(Component.Location.X));
                            y := FloatToStr(CoordToMils(Component.Location.Y));

                            Rect := Component.BoundingRectangle;
                            left := FloatToStr(CoordToMils(Rect.Left));
                            right := FloatToStr(CoordToMils(Rect.Right));
                            top := FloatToStr(CoordToMils(Rect.Top));
                            bottom := FloatToStr(CoordToMils(Rect.Bottom));

                            width := FloatToStr(CoordToMils(Rect.Right - Rect.Left));
                            height := FloatToStr(CoordToMils(Rect.Bottom - Rect.Top));

                            If Component.Orientation = eRotate0 Then
                                rotation := '0'
                            Else If Component.Orientation = eRotate90 Then
                                rotation := '90'
                            Else If Component.Orientation = eRotate180 Then
                                rotation := '180'
                            Else If Component.Orientation = eRotate270 Then
                                rotation := '270'
                            Else
                                rotation := '0';

                            // Add component properties
                            AddJSONProperty(CompProps, 'designator', Designator);
                            AddJSONProperty(CompProps, 'sheet', Sheet);
                            AddJSONNumber(CompProps, 'schematic_x', StrToFloat(x));
                            AddJSONNumber(CompProps, 'schematic_y', StrToFloat(y));
                            AddJSONNumber(CompProps, 'schematic_width', StrToFloat(width));
                            AddJSONNumber(CompProps, 'schematic_height', StrToFloat(height));
                            AddJSONNumber(CompProps, 'schematic_rotation', StrToFloat(rotation));
                            
                            // Get parameters
                            ParamsProps := TStringList.Create;
                            try
                                // Create parameter iterator
                                PIterator := Component.SchIterator_Create;
                                PIterator.AddFilter_ObjectSet(MkSet(eParameter));

                                Parameter := PIterator.FirstSchObject;
                                
                                // Process all parameters
                                while (Parameter <> nil) do
                                begin
                                    // Get this parameter's info
                                    ParameterName := Parameter.Name;
                                    ParameterValue := Parameter.Text;

                                    // Add parameter to the list
                                    AddJSONProperty(ParamsProps, ParameterName, ParameterValue);
                                    
                                    // Move to next parameter
                                    Parameter := PIterator.NextSchObject;
                                end;

                                Component.SchIterator_Destroy(PIterator);
                                
                                // Add parameters to component
                                CompProps.Add('"parameters": ' + BuildJSONObject(ParamsProps, 2));
                                
                                // Add to components array
                                ComponentsArray.Add(BuildJSONObject(CompProps, 1));
                                ComponentCount := ComponentCount + 1;
                            finally
                                ParamsProps.Free;
                            end;
                        finally
                            CompProps.Free;
                        end;

                        // Move to next component
                        Component := Iterator.NextSchObject;
                    End;

                    CurrentSch.SchIterator_Destroy(Iterator);
                End;
            End;
        End;
        
        // Build the final JSON array
        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONArray(ComponentsArray);
            Result := WriteJSONToFile(OutputLines, ROOT_DIR+'temp_schematic_data.json');
        finally
            OutputLines.Free;
        end;
    finally
        ComponentsArray.Free;
    end;
end;
