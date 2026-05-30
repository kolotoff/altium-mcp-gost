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

        if Client.IsDocumentOpen(LibraryPath) then
        begin
            ServerDoc := Client.GetDocumentByPath(LibraryPath);
            WasAlreadyOpen := True;
        end
        else
            ServerDoc := Client.OpenDocument('PcbLib', LibraryPath);

        if ServerDoc = Nil then
        begin
            AddJSONBoolean(ResultProps, 'success', False);
            AddJSONProperty(ResultProps, 'error', 'Failed to open PcbLib: ' + LibraryPath);
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
            Exit;
        end;

        Client.ShowDocument(ServerDoc);
        Sleep(500);

        PcbLib := PCBServer.GetCurrentPCBLibrary;
        if PcbLib = Nil then
        begin
            AddJSONBoolean(ResultProps, 'success', False);
            AddJSONProperty(ResultProps, 'error', 'Opened document is not the active PCB library: ' + LibraryPath);
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
            Exit;
        end;

        Board := PcbLib.Board;
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
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
            Footprint := FindPCBLibraryFootprintByName(PcbLib, FootprintName);
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
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
            Footprint := FindPCBLibraryFootprintByName(PcbLib, FootprintName);
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

    PcbLib := PCBServer.GetCurrentPCBLibrary;
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
            Footprint := FindPCBLibraryFootprintByName(PcbLib, FootprintNames[i]);
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
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

                ExistingFootprint := FindPCBLibraryFootprintByName(PcbLib, CurrentName);
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    Footprint := FindPCBLibraryFootprintByName(PcbLib, FootprintName);
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
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

                Footprint := FindPCBLibraryFootprintByName(PcbLib, FootprintName);
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
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
                TargetFootprint := FindPCBLibraryFootprintByName(PcbLib, FootprintName);
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    TargetFootprint := FindPCBLibraryFootprintByName(PcbLib, FootprintName);
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
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
                TargetFootprint := FindPCBLibraryFootprintByName(PcbLib, FootprintName);
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
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

                Footprint := FindPCBLibraryFootprintByName(PcbLib, FootprintName);
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
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

                Footprint := FindPCBLibraryFootprintByName(PcbLib, FootprintName);
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
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
                TargetFootprint := FindPCBLibraryFootprintByName(PcbLib, FootprintName);
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    Footprint := FindPCBLibraryFootprintByName(PcbLib, FootprintName);
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
    if PcbLib = Nil then
    begin
        Result := '{"success": false, "error": "No PCB library document is currently active. Open a .PcbLib file first."}';
        Exit;
    end;

    Board := PcbLib.Board;
    Footprint := FindPCBLibraryFootprintByName(PcbLib, FootprintName);
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

    Board := PcbLib.Board;
    DestinationLayer := ILayer.MechanicalLayer(DestinationLayerNumber);
    ProjectionLineWidth := MMsToCoord(0.1);
    Footprint := FindPCBLibraryFootprintByName(PcbLib, FootprintName);
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
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
            Footprint := FindPCBLibraryFootprintByName(PcbLib, FootprintName);
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
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
            Footprint := FindPCBLibraryFootprintByName(PcbLib, FootprintName);
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
            Footprint := FindPCBLibraryFootprintByName(PcbLib, FootprintName);
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
            Footprint := FindPCBLibraryFootprintByName(PcbLib, FootprintName);
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
            Footprint := FindPCBLibraryFootprintByName(PcbLib, FootprintName);
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
    ReferenceFootprintName : String;
    TextDumpFootprintName : String;
    PrimitiveDumpFootprintName : String;
    DescriptionDumpFootprintName : String;
    OpenLibraryPath    : String;
    StatsDumpFootprintName : String;
    SetDescriptionFootprintNames : TStringList;
    SetDescriptionTexts : TStringList;
    BatchCreateDataFileName : String;
    BatchCreateSkipExisting : Boolean;
    CleanPadsOverlayTargetNameContains : String;
    CleanPadsOverlayPadNamePrefix : String;
    CleanPadsOverlayLayerName : String;
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
    PcbLib := PCBServer.GetCurrentPCBLibrary;
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
