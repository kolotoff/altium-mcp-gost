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
    Board := PCBServer.GetCurrentPCBBoard;
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
    OutputLines : TStringList;
begin
    // Initialize result
    ResultProps := TStringList.Create;
    AddedCount := 0;
    ClassExists := False;
    
    try
        // Retrieve the current board
        Board := PCBServer.GetCurrentPCBBoard;
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
        
        // Add nets to the class
        PCBServer.PreProcess;
        for i := 0 to NetNames.Count - 1 do
        begin
            // Add each net to the class
            if NetClass.AddMemberByName(NetNames[i]) then
                AddedCount := AddedCount + 1;
        end;
        PCBServer.PostProcess;
        
        // Clean up iterator
        Board.BoardIterator_Destroy(ClassIterator);
        
        // Build result JSON
        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'class_name', ClassName);
        AddJSONBoolean(ResultProps, 'class_created', not ClassExists);
        AddJSONInteger(ResultProps, 'nets_added', AddedCount);
        
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
    Board := PCBServer.GetCurrentPCBBoard;
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
                AddJSONNumber(LayerProps, 'copper_thickness_um', LayerObject.CopperThickness / 254);
                
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
                    AddJSONNumber(LayerProps, 'dielectric_height_um', LayerObject.Dielectric.DielectricHeight / 254);
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
    Board := PCBServer.GetCurrentPCBBoard;
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
        
        // Process mechanical layers
        for i := 1 to 32 do
        begin
            MechLayer := TheLayerStack.LayerObject_V7[ILayer.MechanicalLayer(i)];
            
            if MechLayer.MechanicalLayerEnabled then
            begin
                // Create layer properties
                LayerProps := TStringList.Create;
                try
                    // Add properties
                    AddJSONProperty(LayerProps, 'name', MechLayer.Name);
                    AddJSONProperty(LayerProps, 'layer_id', IntToStr(MechLayer.V6_LayerID));
                    AddJSONProperty(LayerProps, 'layer_type', 'mechanical');
                    AddJSONProperty(LayerProps, 'mechanical_number', IntToStr(i));
                    AddJSONBoolean(LayerProps, 'is_displayed', MechLayer.IsDisplayed[Board]);
                    AddJSONBoolean(LayerProps, 'is_enabled', MechLayer.MechanicalLayerEnabled);
                    AddJSONBoolean(LayerProps, 'link_to_sheet', MechLayer.LinkToSheet);
                    AddJSONBoolean(LayerProps, 'is_paired', Board.MechanicalPairs.LayerUsed(ILayer.MechanicalLayer(i)));
                    AddJSONProperty(LayerProps, 'color', ColorToString(PCBServer.SystemOptions.LayerColors[MechLayer.V6_LayerID]));
                    
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
            
            // Get the number of enabled mechanical layers
            i := 0;
            for i := 1 to 32 do
                if TheLayerStack.LayerObject_V7[ILayer.MechanicalLayer(i)].MechanicalLayerEnabled then
                    i := i + 1;
            AddJSONInteger(LayerProps, 'mechanical_layers_count', i);
            
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
function SetPCBLayerVisibility(LayerNamesList: TStringList; Visible: Boolean): String;
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
begin
    // Retrieve the current board
    Board := PCBServer.GetCurrentPCBBoard;
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
            
            // Check mechanical layers (they can have custom names)
            for j := 1 to 32 do
            begin
                MechLayer := TheLayerStack.LayerObject_V7[ILayer.MechanicalLayer(j)];
                
                if MechLayer.MechanicalLayerEnabled and (MechLayer.Name = LayerName) then
                begin
                    FoundLayers.Add(IntToStr(MechLayer.V6_LayerID));
                    FoundCount := FoundCount + 1;
                    break;
                end;
            end;
            
            // If we've checked all layer types and didn't find a match, add to not found list
            if j > 32 then
                NotFoundList.Add('"' + JSONEscapeString(LayerName) + '"');
        end;
        
        // Second phase: set visibility for all layers based on mode
        if Visible then
        begin
            // Visibility mode: show only specified layers, hide all others
            
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
            for j := 1 to 32 do
            begin
                MechLayer := TheLayerStack.LayerObject_V7[ILayer.MechanicalLayer(j)];
                
                if MechLayer.MechanicalLayerEnabled then
                begin
                    if (FoundLayers.IndexOf(IntToStr(MechLayer.V6_LayerID)) >= 0) then
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
            // Hide mode: only hide specified layers, leave others unchanged
            
            // For copper layers
            LayerObj := TheLayerStack.FirstLayer;
            while (LayerObj <> nil) do
            begin
                // Check if this layer is in our found list
                if (FoundLayers.IndexOf(IntToStr(LayerObj.V6_LayerID)) >= 0) then
                    LayerObj.IsDisplayed[Board] := False;
                
                LayerObj := TheLayerStack.NextLayer(LayerObj);
            end;
            
            // For mechanical layers
            for j := 1 to 32 do
            begin
                MechLayer := TheLayerStack.LayerObject_V7[ILayer.MechanicalLayer(j)];
                
                if MechLayer.MechanicalLayerEnabled then
                begin
                    if (FoundLayers.IndexOf(IntToStr(MechLayer.V6_LayerID)) >= 0) then
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
                    Board.LayerIsDisplayed[LayerID] := False;
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
    Board := PCBServer.GetCurrentPCBBoard;
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
    Board := PCBServer.GetCurrentPCBBoard;
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
                    AddJSONNumber(ComponentProps, 'height', CoordToMils(Rect.Bottom - Rect.Top));
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
    Board := PCBServer.GetCurrentPCBBoard;
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
                    AddJSONNumber(ComponentProps, 'x', CoordToMils(Component.x - xorigin));
                    AddJSONNumber(ComponentProps, 'y', CoordToMils(Component.y - yorigin));
                    AddJSONNumber(ComponentProps, 'width', CoordToMils(Rect.Right - Rect.Left));
                    AddJSONNumber(ComponentProps, 'height', CoordToMils(Rect.Bottom - Rect.Top));
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
begin
    // Retrieve the current board
    Board := PCBServer.GetCurrentPCBBoard;
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
                                AddJSONNumber(PinProps, 'rotation', Pad.Rotation);
                                AddJSONProperty(PinProps, 'layer', Layer2String(Pad.Layer));
                                AddJSONNumber(PinProps, 'width', CoordToMils(Pad.XSizeOnLayer[Pad.Layer]));
                                AddJSONNumber(PinProps, 'height', CoordToMils(Pad.YSizeOnLayer[Pad.Layer]));
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
    Board := PCBServer.GetCurrentPCBBoard;
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
        AddJSONProperty(ResultProps, 'new_x', FloatToStr(NewX), False);
        AddJSONProperty(ResultProps, 'new_y', FloatToStr(NewY), False);
        AddJSONProperty(ResultProps, 'rotation', FloatToStr(Component.Rotation), False);
        
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

function FindSaveDocumentCommand(LayerMoves: TStringList): Boolean;
var
    i: Integer;
begin
    Result := False;

    for i := 0 to LayerMoves.Count - 1 do
    begin
        if UpperCase(Trim(LayerMoves[i])) = 'SAVE_DOCUMENT' then
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
    BodyIterator        : IPCB_GroupIterator;
    Primitive           : IPCB_Primitive;
    Body                : IPCB_ComponentBody;
    Rect                : TCoordRect;
    ResultProps         : TStringList;
    BodyArray           : TStringList;
    BodyProps           : TStringList;
    OutputLines         : TStringList;
    FootprintName       : String;
    FootprintsSeen      : Integer;
    FootprintsProcessed : Integer;
    BodiesSeen          : Integer;
begin
    PcbLib := PCBServer.GetCurrentPCBLibrary;
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
                                Body := Primitive;
                                Rect := Primitive.BoundingRectangle;

                                BodyProps := TStringList.Create;
                                try
                                    AddJSONProperty(BodyProps, 'footprint', FootprintName);
                                    AddJSONProperty(BodyProps, 'object_id', Primitive.ObjectIDString);
                                    AddJSONProperty(BodyProps, 'layer', Layer2String(Primitive.Layer));
                                    AddJSONNumber(BodyProps, 'left_mm', CoordToMMs(Rect.Left));
                                    AddJSONNumber(BodyProps, 'bottom_mm', CoordToMMs(Rect.Bottom));
                                    AddJSONNumber(BodyProps, 'right_mm', CoordToMMs(Rect.Right));
                                    AddJSONNumber(BodyProps, 'top_mm', CoordToMMs(Rect.Top));
                                    AddJSONNumber(BodyProps, 'standoff_height_mm', CoordToMMs(Body.StandoffHeight));
                                    AddJSONNumber(BodyProps, 'overall_height_mm', CoordToMMs(Body.OverallHeight));
                                    AddJSONInteger(BodyProps, 'body_projection', Body.BodyProjection);
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

function RemoveProjectionTracks(Footprint: IPCB_LibComponent; DestinationLayer: TLayer; LineWidth: TCoord): Integer;
var
    PrimitiveIterator: IPCB_GroupIterator;
    Primitive: IPCB_Primitive;
    Track: IPCB_Track;
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
        PrimitiveIterator.AddFilter_ObjectSet(MkSet(eTrackObject));
        PrimitiveIterator.AddFilter_LayerSet(MkSet(DestinationLayer));

        Primitive := PrimitiveIterator.FirstPCBObject;
        while Primitive <> Nil do
        begin
            Track := Primitive;

            if Track.Width = LineWidth then
                TracksToRemove.Add(Primitive);

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
    TotalTrackCount     : Integer;
begin
    PcbLib := PCBServer.GetCurrentPCBLibrary;
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

                    PrimitiveIterator := Footprint.GroupIterator_Create;
                    if PrimitiveIterator <> Nil then
                    begin
                        try
                            PrimitiveIterator.AddFilter_ObjectSet(MkSet(eTrackObject));
                            PrimitiveIterator.AddFilter_LayerSet(MkSet(DestinationLayer));

                            Primitive := PrimitiveIterator.FirstPCBObject;
                            while Primitive <> Nil do
                            begin
                                Track := Primitive;
                                if Track.Width = LineWidth then
                                    FootprintTrackCount := FootprintTrackCount + 1;
                                Primitive := PrimitiveIterator.NextPCBObject;
                            end;
                        finally
                            Footprint.GroupIterator_Destroy(PrimitiveIterator);
                        end;
                    end;

                    TotalTrackCount := TotalTrackCount + FootprintTrackCount;
                    CountProps := TStringList.Create;
                    try
                        AddJSONProperty(CountProps, 'footprint', FootprintName);
                        AddJSONInteger(CountProps, 'tracks', FootprintTrackCount);
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

function RunSaveDocumentCommand: String;
var
    PcbLib      : IPCB_Library;
    Board       : IPCB_Board;
    ResultProps : TStringList;
    OutputLines : TStringList;
begin
    PcbLib := PCBServer.GetCurrentPCBLibrary;
    Board := Nil;
    if PcbLib <> Nil then
        Board := PcbLib.Board
    else
        Board := PCBServer.GetCurrentPCBBoard;

    ResetParameters;
    AddStringParameter('ObjectKind', 'Document');
    AddStringParameter('SaveMode', 'Standard');
    RunProcess('WorkspaceManager:SaveObject');
    Client.SendMessage('WorkspaceManager:SaveObject', 'ObjectKind=Document|SaveMode=Standard', 255, Client.CurrentView);

    ResultProps := TStringList.Create;
    try
        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'process', 'WorkspaceManager:SaveObject');
        if Board <> Nil then
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
begin
    Result := 0;

    if Footprint = Nil then
        Exit;

    PrimitiveIterator := Footprint.GroupIterator_Create;
    if PrimitiveIterator = Nil then
        Exit;

    try
        PrimitiveIterator.AddFilter_ObjectSet(MkSet(eTrackObject));
        PrimitiveIterator.AddFilter_LayerSet(MkSet(DestinationLayer));

        Primitive := PrimitiveIterator.FirstPCBObject;
        while Primitive <> Nil do
        begin
            Track := Primitive;
            if Track.Width = LineWidth then
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

function FindPCBLibraryFootprintByName(PcbLib: IPCB_Library; FootprintName: String): IPCB_LibComponent;
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
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
            Footprint := FindPCBLibraryFootprintByName(PcbLib, FootprintName);
            if Footprint <> Nil then
            begin
                Client.SendMessage('PCB:DeSelect', 'Scope=All', 255, Client.CurrentView);
                PcbLib.CurrentComponent := Footprint;
                if Board <> Nil then
                    Board.ViewManager_FullUpdate;

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
    TracksRemoved       : Integer;
    FootprintTracksCreated : Integer;
    X1MM, Y1MM, X2MM, Y2MM : Double;
    i                   : Integer;
begin
    PcbLib := PCBServer.GetCurrentPCBLibrary;
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
    FootprintsSeen := 0;
    FootprintsProcessed := 0;
    FootprintsModified := 0;
    SegmentsMatched := 0;
    TracksCreated := 0;
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
                    FootprintTracksCreated := 0;

                    if RemoveExisting then
                        TracksRemoved := TracksRemoved + RemoveProjectionTracks(Footprint, DestinationLayer, LineWidth);

                    for i := 0 to SegmentLines.Count - 1 do
                    begin
                        if ParseSilhouetteSegment(SegmentLines[i], SegmentFootprint, X1MM, Y1MM, X2MM, Y2MM) then
                        begin
                            if UpperCase(SegmentFootprint) = UpperCase(FootprintName) then
                            begin
                                if AddProjectionTrack(
                                    Footprint,
                                    DestinationLayer,
                                    MMsToCoord(X1MM),
                                    MMsToCoord(Y1MM),
                                    MMsToCoord(X2MM),
                                    MMsToCoord(Y2MM),
                                    LineWidth
                                ) then
                                begin
                                    FootprintTracksCreated := FootprintTracksCreated + 1;
                                    TracksCreated := TracksCreated + 1;
                                    SegmentsMatched := SegmentsMatched + 1;
                                end;
                            end;
                        end;
                    end;

                    if FootprintTracksCreated > 0 then
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
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

    PcbLib := PCBServer.GetCurrentPCBLibrary;
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
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
        LibComp := PCBServer.CreatePCBLibComp;
        LibComp.Name := FootprintName;

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

            LibComp.AddPCBObject(Pad);
            PCBServer.SendMessageToRobots(Pad.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

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
        PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

        Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
        Track.Layer := ILayer.MechanicalLayer(15);
        Track.x1 := MMsToCoord(CrtX1); Track.y1 := MMsToCoord(CrtY2);
        Track.x2 := MMsToCoord(CrtX2); Track.y2 := MMsToCoord(CrtY2);
        Track.Width := TrackWidth;
        LibComp.AddPCBObject(Track);
        PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

        Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
        Track.Layer := ILayer.MechanicalLayer(15);
        Track.x1 := MMsToCoord(CrtX1); Track.y1 := MMsToCoord(CrtY1);
        Track.x2 := MMsToCoord(CrtX1); Track.y2 := MMsToCoord(CrtY2);
        Track.Width := TrackWidth;
        LibComp.AddPCBObject(Track);
        PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

        Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
        Track.Layer := ILayer.MechanicalLayer(15);
        Track.x1 := MMsToCoord(CrtX2); Track.y1 := MMsToCoord(CrtY1);
        Track.x2 := MMsToCoord(CrtX2); Track.y2 := MMsToCoord(CrtY2);
        Track.Width := TrackWidth;
        LibComp.AddPCBObject(Track);
        PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

        // Silkscreen on TopOverlay (inset 0.1mm from courtyard)
        Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
        Track.Layer := SilkLayer;
        Track.x1 := MMsToCoord(CrtX1+0.1); Track.y1 := MMsToCoord(CrtY1+0.1);
        Track.x2 := MMsToCoord(CrtX2-0.1); Track.y2 := MMsToCoord(CrtY1+0.1);
        Track.Width := TrackWidth;
        LibComp.AddPCBObject(Track);
        PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

        Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
        Track.Layer := SilkLayer;
        Track.x1 := MMsToCoord(CrtX1+0.1); Track.y1 := MMsToCoord(CrtY2-0.1);
        Track.x2 := MMsToCoord(CrtX2-0.1); Track.y2 := MMsToCoord(CrtY2-0.1);
        Track.Width := TrackWidth;
        LibComp.AddPCBObject(Track);
        PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

        // Left silk — split to mark pin 1 (gap at top-left corner for pin 1 indicator)
        Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
        Track.Layer := SilkLayer;
        Track.x1 := MMsToCoord(CrtX1+0.1); Track.y1 := MMsToCoord(CrtY1+0.1);
        Track.x2 := MMsToCoord(CrtX1+0.1); Track.y2 := MMsToCoord(CrtY2-0.6);
        Track.Width := TrackWidth;
        LibComp.AddPCBObject(Track);
        PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

        // Right silk
        Track := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
        Track.Layer := SilkLayer;
        Track.x1 := MMsToCoord(CrtX2-0.1); Track.y1 := MMsToCoord(CrtY1+0.1);
        Track.x2 := MMsToCoord(CrtX2-0.1); Track.y2 := MMsToCoord(CrtY2-0.1);
        Track.Width := TrackWidth;
        LibComp.AddPCBObject(Track);
        PCBServer.SendMessageToRobots(Track.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, c_NoEventData);

        // Register with library board, navigate, and refresh
        PCBServer.SendMessageToRobots(PcbLib.Board.I_ObjectAddress, c_Broadcast, PCBM_BoardRegisteration, LibComp.I_ObjectAddress);
        PcbLib.CurrentComponent := LibComp;
        PcbLib.Board.ViewManager_FullUpdate;

        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'footprint_name', FootprintName);
        AddJSONInteger(ResultProps, 'pad_count', PadCount);
        AddJSONNumber(ResultProps, 'courtyard_width_mm', CrtX2 - CrtX1);
        AddJSONNumber(ResultProps, 'courtyard_height_mm', CrtY2 - CrtY1);

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
    Board := PCBServer.GetCurrentPCBBoard;
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
    Board := PCBServer.GetCurrentPCBBoard;
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
    Board := PCBServer.GetCurrentPCBBoard;
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
