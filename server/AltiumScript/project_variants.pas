// Project operations use the live workspace, never project files on disk.
function InspectProjectVariants(ProjectFilter: String): String;
var
    Project: IProject;
    ProjectVariant: IProjectVariant;
    Variation: IComponentVariation;
    Parameter: IParameterVariation;
    Projects, Variants, Changes, Parameters, Props: TStringList;
    i, j, k, p: Integer;
    ProjectPath, VariantName: String;
begin
    if Trim(ProjectFilter) = '' then
    begin
        Result := '{"success": false, "error": "An exact project selector is required."}';
        Exit;
    end;
    Projects := TStringList.Create;
    Variants := TStringList.Create;
    Changes := TStringList.Create;
    Parameters := TStringList.Create;
    Props := TStringList.Create;
    try
        for i := 0 to GetWorkspace.DM_ProjectCount - 1 do
        begin
            Project := GetWorkspace.DM_Projects(i);
            ProjectPath := Project.DM_ProjectFullPath;
            if (UpperCase(ExtractFileExt(ProjectPath)) = '.PRJPCB') and
               ((UpperCase(ProjectFilter) = UpperCase(ProjectPath)) or
                (UpperCase(ProjectFilter) = UpperCase(ChangeFileExt(ExtractFileName(ProjectPath), '')))) then
            begin
                Variants.Clear;
                for j := 0 to Project.DM_ProjectVariantCount - 1 do
                begin
                    ProjectVariant := Project.DM_ProjectVariants(j);
                    VariantName := ProjectVariant.DM_Description;
                    Changes.Clear;
                    for k := 0 to ProjectVariant.DM_VariationCount - 1 do
                    begin
                        Variation := ProjectVariant.DM_Variations(k);
                        Parameters.Clear;
                        for p := 0 to Variation.DM_VariationCount - 1 do
                        begin
                            Parameter := Variation.DM_Variations(p);
                            Props.Clear;
                            AddJSONProperty(Props, 'name', Parameter.DM_ParameterName);
                            AddJSONProperty(Props, 'value', Parameter.DM_VariedValue);
                            Parameters.Add(BuildJSONObject(Props, 0));
                        end;
                        Props.Clear;
                        AddJSONProperty(Props, 'designator', Variation.DM_PhysicalDesignator);
                        AddJSONProperty(Props, 'unique_id', Variation.DM_UniqueId);
                        AddJSONInteger(Props, 'kind', Ord(Variation.DM_VariationKind));
                        AddJSONProperty(Props, 'alternate_part', Variation.DM_AlternatePart);
                        Props.Add(BuildJSONArray(Parameters, 'parameters'));
                        Changes.Add(BuildJSONObject(Props, 0));
                    end;
                    Props.Clear;
                    AddJSONProperty(Props, 'name', ProjectVariant.DM_Name);
                    AddJSONProperty(Props, 'description', VariantName);
                    Props.Add(BuildJSONArray(Changes, 'variations'));
                    Variants.Add(BuildJSONObject(Props, 0));
                end;
                Props.Clear;
                AddJSONProperty(Props, 'path', ProjectPath);
                Props.Add(BuildJSONArray(Variants, 'variants'));
                Projects.Add(BuildJSONObject(Props, 0));
            end;
        end;
        Props.Clear;
        AddJSONBoolean(Props, 'success', Projects.Count = 1);
        if Projects.Count <> 1 then
            AddJSONProperty(Props, 'error', 'Project selector must match exactly one open PCB project.');
        Props.Add(BuildJSONArray(Projects, 'projects'));
        Result := BuildJSONObject(Props, 0);
    finally
        Props.Free;
        Parameters.Free;
        Changes.Free;
        Variants.Free;
        Projects.Free;
    end;
end;

function FindVariantProject(Selector: String): IProject;
var
    i, Count: Integer;
    Candidate: IProject;
begin
    Result := nil;
    Count := 0;
    for i := 0 to GetWorkspace.DM_ProjectCount - 1 do
    begin
        Candidate := GetWorkspace.DM_Projects(i);
        if (UpperCase(ExtractFileExt(Candidate.DM_ProjectFullPath)) = '.PRJPCB') and
           ((UpperCase(Candidate.DM_ProjectFullPath) = UpperCase(Selector)) or
            (UpperCase(ChangeFileExt(ExtractFileName(Candidate.DM_ProjectFullPath), '')) = UpperCase(Selector))) then
        begin
            Result := Candidate;
            Count := Count + 1;
        end;
    end;
    if Count <> 1 then Result := nil;
end;

function InspectVariantComponents(ProjectSelector: String): String;
var
    Project: IProject;
    Flat: IDocument;
    Component: IComponent;
    i: Integer;
    Props, Items: TStringList;
begin
    Project := FindVariantProject(ProjectSelector);
    if Project = nil then
    begin
        Result := '{"success": false, "error": "Project selector must match exactly one open project."}';
        Exit;
    end;
    if not Project.DM_Compile then
    begin
        Result := '{"success": false, "error": "Project compilation failed."}';
        Exit;
    end;
    Flat := Project.DM_DocumentFlattened;
    if Flat = nil then
    begin
        Result := '{"success": false, "error": "No compiled flattened schematic."}';
        Exit;
    end;
    Props := TStringList.Create;
    Items := TStringList.Create;
    try
        for i := 0 to Flat.DM_ComponentCount - 1 do
        begin
            Component := Flat.DM_Components(i);
            Props.Clear;
            AddJSONProperty(Props, 'designator', Component.DM_PhysicalDesignator);
            AddJSONProperty(Props, 'unique_id', Component.DM_UniqueId);
            AddJSONProperty(Props, 'unique_id_path', Component.DM_UniqueIdPath);
            AddJSONProperty(Props, 'library_reference', Component.DM_LibraryReference);
            AddJSONProperty(Props, 'comment', Component.DM_Comment);
            AddJSONProperty(Props, 'footprint', Component.DM_Footprint);
            Items.Add(BuildJSONObject(Props, 0));
        end;
        Props.Clear;
        AddJSONBoolean(Props, 'success', True);
        AddJSONProperty(Props, 'path', Project.DM_ProjectFullPath);
        Props.Add(BuildJSONArray(Items, 'components'));
        Result := BuildJSONObject(Props, 0);
    finally
        Items.Free;
        Props.Free;
    end;
end;

function FindMaterialVariant(Project: IProject; VariantName: String): IProjectVariant;
var
    i, Matches: Integer;
begin
    Result := nil;
    Matches := 0;
    for i := 0 to Project.DM_ProjectVariantCount - 1 do
        if UpperCase(Project.DM_ProjectVariants(i).DM_Description) = UpperCase(VariantName) then
        begin
            Result := Project.DM_ProjectVariants(i);
            Matches := Matches + 1;
        end;
    if Matches > 1 then Result := nil;
end;

function FindMaterialComponent(Flat: IDocument; Designator: String): IComponent;
var
    i, Matches: Integer;
    Component: IComponent;
begin
    Result := nil;
    Matches := 0;
    for i := 0 to Flat.DM_ComponentCount - 1 do
    begin
        Component := Flat.DM_Components(i);
        if UpperCase(Component.DM_PhysicalDesignator) = UpperCase(Designator) then
        begin
            Result := Component;
            Matches := Matches + 1;
        end;
    end;
    if Matches > 1 then Result := nil;
end;

function MaterialOverrideValuesMatch(Source, Target: IComponentVariation): Boolean;
var
    i: Integer;
    SourceParameter, TargetParameter: IParameterVariation;
begin
    Result := False;
    if Target = nil then Exit;
    if Source.DM_VariationKind <> Target.DM_VariationKind then Exit;
    if Source.DM_AlternatePart <> Target.DM_AlternatePart then Exit;
    if Source.DM_VariationCount <> Target.DM_VariationCount then Exit;
    for i := 0 to Source.DM_VariationCount - 1 do
    begin
        SourceParameter := Source.DM_Variations(i);
        TargetParameter := Target.DM_FindParameterVariation(SourceParameter.DM_ParameterName);
        if TargetParameter = nil then Exit;
        if TargetParameter.DM_VariedValue <> SourceParameter.DM_VariedValue then Exit;
    end;
    Result := True;
end;

function MaterialVariationMatches(Source, Target: IComponentVariation; TargetId: String): Boolean;
begin
    Result := False;
    if Target = nil then Exit;
    if Source.DM_PhysicalDesignator <> Target.DM_PhysicalDesignator then Exit;
    if Target.DM_UniqueId <> TargetId then Exit;
    Result := MaterialOverrideValuesMatch(Source, Target);
end;

function MaterialComponentMatchCount(Flat: IDocument; Designator: String): Integer;
var
    i: Integer;
begin
    Result := 0;
    for i := 0 to Flat.DM_ComponentCount - 1 do
        if UpperCase(Flat.DM_Components(i).DM_PhysicalDesignator) = UpperCase(Designator) then
            Result := Result + 1;
end;

function MaterialVariationReadback(Change: IComponentVariation): String;
var
    Props, Parameters: TStringList;
    Parameter: IParameterVariation;
    i: Integer;
begin
    Props := TStringList.Create;
    Parameters := TStringList.Create;
    try
        for i := 0 to Change.DM_VariationCount - 1 do
        begin
            Parameter := Change.DM_Variations(i);
            Props.Clear;
            AddJSONProperty(Props, 'name', Parameter.DM_ParameterName);
            AddJSONProperty(Props, 'value', Parameter.DM_VariedValue);
            Parameters.Add(BuildJSONObject(Props, 0));
        end;
        Props.Clear;
        AddJSONProperty(Props, 'designator', Change.DM_PhysicalDesignator);
        AddJSONProperty(Props, 'unique_id', Change.DM_UniqueId);
        AddJSONInteger(Props, 'kind', Ord(Change.DM_VariationKind));
        AddJSONProperty(Props, 'alternate_part', Change.DM_AlternatePart);
        Props.Add(BuildJSONArray(Parameters, 'parameters'));
        Result := BuildJSONObject(Props, 0);
    finally
        Parameters.Free;
        Props.Free;
    end;
end;

// Only parameter/material overrides are supported. Alternate library models and
// fitted/not-fitted states need a different workflow and fail before mutation.
function CopyProjectVariantMaterials(SourceSelector, TargetSelector, VariantName: String;
    AllowMissing, ApplyChanges: Boolean): String;
var
    SourceProject, TargetProject: IProject;
    SourceVariant, TargetVariant: IProjectVariant;
    SourceFlat, TargetFlat: IDocument;
    SourceComponent, TargetComponent: IComponent;
    SourceChange, TargetChange: IComponentVariation;
    SourceParameter, TargetParameter: IParameterVariation;
    ServerDocument: IServerDocument;
    Missing, Mapped, TargetIds, Props: TStringList;
    i, j, NewIndex, MappedCount: Integer;
    Existing, Created, Verified, TargetModified: Boolean;
    ErrorText, ReadbackDetails: String;
begin
    Result := '{"success": false, "error": "Variant copy failed."}';
    SourceProject := FindVariantProject(SourceSelector);
    TargetProject := FindVariantProject(TargetSelector);
    if (SourceProject = nil) or (TargetProject = nil) then
    begin
        Result := '{"success": false, "error": "Each selector must match exactly one open project."}';
        Exit;
    end;
    if (SourceProject.DM_ProjectFullPath = TargetProject.DM_ProjectFullPath) or (Trim(VariantName) = '') then Exit;
    SourceVariant := FindMaterialVariant(SourceProject, VariantName);
    if SourceVariant = nil then
    begin
        Result := '{"success": false, "error": "Source variant missing or ambiguous."}';
        Exit;
    end;
    if SourceProject.DM_NeedsCompile then
        if not SourceProject.DM_Compile then
        begin
            Result := '{"success": false, "error": "Source project compilation failed."}';
            Exit;
        end;
    if TargetProject.DM_NeedsCompile then
        if not TargetProject.DM_Compile then
        begin
            Result := '{"success": false, "error": "Target project compilation failed."}';
            Exit;
        end;
    SourceFlat := SourceProject.DM_DocumentFlattened;
    TargetFlat := TargetProject.DM_DocumentFlattened;
    if (SourceFlat = nil) or (TargetFlat = nil) then Exit;
    Missing := TStringList.Create;
    Mapped := TStringList.Create;
    TargetIds := TStringList.Create;
    Props := TStringList.Create;
    Created := False;
    try
        ErrorText := '';
        ReadbackDetails := '';
        for i := 0 to SourceVariant.DM_VariationCount - 1 do
        begin
            SourceChange := SourceVariant.DM_Variations(i);
            if Ord(SourceChange.DM_VariationKind) <> 0 then
                ErrorText := 'Only parameter/material overrides are supported.';
            SourceComponent := FindMaterialComponent(SourceFlat, SourceChange.DM_PhysicalDesignator);
            TargetComponent := FindMaterialComponent(TargetFlat, SourceChange.DM_PhysicalDesignator);
            if MaterialComponentMatchCount(TargetFlat, SourceChange.DM_PhysicalDesignator) > 1 then
                ErrorText := 'Ambiguous target designator: ' + SourceChange.DM_PhysicalDesignator;
            if SourceComponent = nil then
                ErrorText := 'Source designator missing or ambiguous: ' + SourceChange.DM_PhysicalDesignator
            else if SourceComponent.DM_UniqueId <> SourceChange.DM_UniqueId then
                ErrorText := 'Source variant has a stale component ID: ' + SourceChange.DM_PhysicalDesignator;
            if TargetComponent = nil then
                Missing.Add('"' + JSONEscapeString(SourceChange.DM_PhysicalDesignator) + '"')
            else if SourceComponent <> nil then
            begin
                if (SourceComponent.DM_LibraryReference <> TargetComponent.DM_LibraryReference) or
                   (SourceComponent.DM_Comment <> TargetComponent.DM_Comment) or
                   (SourceComponent.DM_Footprint <> TargetComponent.DM_Footprint) then
                    ErrorText := 'Base component mismatch: ' + SourceChange.DM_PhysicalDesignator;
                if (Mapped.IndexOf(SourceChange.DM_PhysicalDesignator) >= 0) or
                   (TargetIds.IndexOf(TargetComponent.DM_UniqueId) >= 0) or
                   (TargetComponent.DM_UniqueId = '') then
                    ErrorText := 'Duplicate or empty component identity: ' + SourceChange.DM_PhysicalDesignator;
                Mapped.Add(SourceChange.DM_PhysicalDesignator);
                TargetIds.Add(TargetComponent.DM_UniqueId);
            end;
        end;
        MappedCount := Mapped.Count;
        if (Missing.Count > 0) and (not AllowMissing) then
            ErrorText := 'Target components missing or ambiguous; inspect skipped_designators and explicitly allow missing components.';
        if MappedCount = 0 then ErrorText := 'No compatible target components.';
        TargetVariant := FindMaterialVariant(TargetProject, VariantName);
        Existing := TargetVariant <> nil;
        // A duplicate description must not be mistaken for an absent variant.
        if not Existing then
            for i := 0 to TargetProject.DM_ProjectVariantCount - 1 do
                if UpperCase(TargetProject.DM_ProjectVariants(i).DM_Description) = UpperCase(VariantName) then
                    ErrorText := 'Target variant name is ambiguous.';
        if Existing then
        begin
            if TargetVariant.DM_VariationCount <> MappedCount then
                ErrorText := 'Existing target variant differs; refusing to overwrite.';
            for i := 0 to MappedCount - 1 do
            begin
                SourceChange := SourceVariant.DM_FindComponentVariationByDesignator(Mapped[i]);
                TargetChange := TargetVariant.DM_FindComponentVariationByDesignator(Mapped[i]);
                if not MaterialVariationMatches(SourceChange, TargetChange, TargetIds[i]) then
                    ErrorText := 'Existing target variant differs; refusing to overwrite.';
            end;
        end;
        ServerDocument := TargetProject.DM_ServerDocument;
        if ServerDocument = nil then ErrorText := 'Target project has no server document for dirty-state tracking.';
        if (ErrorText = '') and ApplyChanges and (not Existing) then
        begin
            NewIndex := TargetProject.DM_ProjectVariantCount;
            TargetProject.DM_BeginUpdate;
            try
                try
                    TargetVariant := TargetProject.DM_AddProjectVariant;
                    Created := True;
                    TargetVariant.DM_SetDescription(VariantName);
                    for i := 0 to MappedCount - 1 do
                    begin
                        SourceChange := SourceVariant.DM_FindComponentVariationByDesignator(Mapped[i]);
                        TargetChange := TargetVariant.DM_AddComponentVariation;
                        TargetChange.DM_SetPhysicalDesignator(Mapped[i]);
                        TargetChange.DM_SetUniqueId(TargetIds[i]);
                        TargetChange.DM_SetVariationKind(SourceChange.DM_VariationKind);
                        TargetChange.DM_SetAlternatePart(SourceChange.DM_AlternatePart);
                        for j := 0 to SourceChange.DM_VariationCount - 1 do
                        begin
                            SourceParameter := SourceChange.DM_Variations(j);
                            // SetAlternatePart creates a Comment override in AD26.
                            // Reuse it instead of adding a duplicate parameter.
                            TargetParameter := TargetChange.DM_FindParameterVariation(SourceParameter.DM_ParameterName);
                            if TargetParameter = nil then
                                TargetParameter := TargetChange.DM_AddParameterVariation;
                            TargetParameter.DM_SetParameterName(SourceParameter.DM_ParameterName);
                            TargetParameter.DM_SetVariedValue(SourceParameter.DM_VariedValue);
                        end;
                        if not MaterialVariationMatches(SourceChange, TargetChange, TargetIds[i]) then
                        begin
                            ErrorText := 'Material readback mismatch; new variant removed.';
                            ReadbackDetails := MaterialVariationReadback(TargetChange);
                            Break;
                        end;
                    end;
                    if ErrorText <> '' then
                    begin
                        TargetProject.DM_RemoveProjectVariant(NewIndex);
                        Created := False;
                    end
                    else
                        ServerDocument.SetModified(True);
                except
                    if Created then TargetProject.DM_RemoveProjectVariant(NewIndex);
                    Created := False;
                    ErrorText := 'Copy failed; new variant removed. Inspect live project state before retrying.';
                end;
            finally
                TargetProject.DM_EndUpdate;
            end;
            TargetProject.DM_RefreshInWorkspaceForm;
        end;
        // AD26's project server can ignore this flag; report its actual value
        // and never treat live readback as evidence of a save to disk.
        if (ErrorText = '') and Created then
            ServerDocument.SetModified(True);
        Verified := (ErrorText = '') and (Existing or Created);
        AddJSONBoolean(Props, 'success', ErrorText = '');
        AddJSONBoolean(Props, 'applied', Created);
        AddJSONBoolean(Props, 'already_matches', Existing and (ErrorText = ''));
        AddJSONBoolean(Props, 'verified', Verified);
        AddJSONBoolean(Props, 'save_requested', False);
        if ServerDocument <> nil then
        begin
            TargetModified := ServerDocument.GetModified;
            AddJSONBoolean(Props, 'target_modified', TargetModified);
        end;
        AddJSONProperty(Props, 'save_state_warning',
            'No save command was issued. Live verification does not confirm persistence. If target_modified is false, the project dirty state is ambiguous; keep Altium open for inspection.');
        AddJSONProperty(Props, 'source_project', SourceProject.DM_ProjectFullPath);
        AddJSONProperty(Props, 'target_project', TargetProject.DM_ProjectFullPath);
        AddJSONProperty(Props, 'variant', VariantName);
        AddJSONInteger(Props, 'source_changes', SourceVariant.DM_VariationCount);
        AddJSONInteger(Props, 'mapped_changes', MappedCount);
        Props.Add(BuildJSONArray(Missing, 'skipped_designators'));
        if ErrorText <> '' then AddJSONProperty(Props, 'error', ErrorText);
        if ReadbackDetails <> '' then Props.Add('"failed_readback": ' + ReadbackDetails);
        Result := BuildJSONObject(Props, 0);
    finally
        Props.Free;
        TargetIds.Free;
        Mapped.Free;
        Missing.Free;
    end;
end;

// Inspect every component in a material family, including components with no
// variant record. Looking only at existing overrides cannot detect omissions.
function InspectEffectiveVariantMaterials(ProjectSelector, VariantName, LibraryPrefix: String): String;
var
    Project: IProject;
    ProjectVariant, ActiveVariant: IProjectVariant;
    Flat: IDocument;
    Component: IComponent;
    Change: IComponentVariation;
    Parameter: IParameterVariation;
    Items, Props: TStringList;
    i: Integer;
    EffectiveComment: String;
begin
    Result := '{"success": false, "error": "Project or variant missing or ambiguous."}';
    Project := FindVariantProject(ProjectSelector);
    if Project = nil then Exit;
    ProjectVariant := FindMaterialVariant(Project, VariantName);
    if ProjectVariant = nil then Exit;
    if Project.DM_NeedsCompile then
        if not Project.DM_Compile then Exit;
    Flat := Project.DM_DocumentFlattened;
    if Flat = nil then Exit;
    Items := TStringList.Create;
    Props := TStringList.Create;
    try
        for i := 0 to Flat.DM_ComponentCount - 1 do
        begin
            Component := Flat.DM_Components(i);
            if Pos(UpperCase(LibraryPrefix), UpperCase(Component.DM_LibraryReference)) = 1 then
            begin
                Change := ProjectVariant.DM_FindComponentVariationByUniqueId(Component.DM_UniqueId);
                EffectiveComment := Component.DM_Comment;
                if Change <> nil then
                    EffectiveComment := Change.DM_CalculatedAlternatePart(Component);
                Props.Clear;
                AddJSONProperty(Props, 'designator', Component.DM_PhysicalDesignator);
                AddJSONProperty(Props, 'base_library_reference', Component.DM_LibraryReference);
                AddJSONProperty(Props, 'base_comment', Component.DM_Comment);
                AddJSONProperty(Props, 'effective_comment', EffectiveComment);
                AddJSONBoolean(Props, 'has_override', Change <> nil);
                if Change <> nil then
                begin
                    Parameter := Change.DM_FindParameterVariation('PartNumber');
                    if Parameter <> nil then
                        AddJSONProperty(Props, 'effective_part_number', Parameter.DM_CalculatedValue(Component, Change));
                end;
                Items.Add(BuildJSONObject(Props, 0));
            end;
        end;
        Props.Clear;
        AddJSONBoolean(Props, 'success', True);
        AddJSONProperty(Props, 'project', Project.DM_ProjectFullPath);
        AddJSONProperty(Props, 'variant', VariantName);
        ActiveVariant := Project.DM_CurrentProjectVariant;
        if ActiveVariant <> nil then
            AddJSONProperty(Props, 'active_variant', ActiveVariant.DM_Description);
        Props.Add(BuildJSONArray(Items, 'materials'));
        Result := BuildJSONObject(Props, 0);
    finally
        Props.Free;
        Items.Free;
    end;
end;

function SameBaseMaterial(Source, Target: IComponent): Boolean;
begin
    Result := (Source.DM_LibraryReference = Target.DM_LibraryReference) and
              (Source.DM_Comment = Target.DM_Comment) and
              (Source.DM_Footprint = Target.DM_Footprint);
end;

procedure PopulateMaterialOverride(Source, Target: IComponentVariation);
var
    SourceParameter, TargetParameter: IParameterVariation;
    i: Integer;
begin
    Target.DM_SetVariationKind(Source.DM_VariationKind);
    Target.DM_SetAlternatePart(Source.DM_AlternatePart);
    for i := 0 to Source.DM_VariationCount - 1 do
    begin
        SourceParameter := Source.DM_Variations(i);
        TargetParameter := Target.DM_FindParameterVariation(SourceParameter.DM_ParameterName);
        if TargetParameter = nil then TargetParameter := Target.DM_AddParameterVariation;
        TargetParameter.DM_SetParameterName(SourceParameter.DM_ParameterName);
        TargetParameter.DM_SetVariedValue(SourceParameter.DM_VariedValue);
    end;
end;

// Extend an existing copied variant to target-only instances of one explicitly
// selected base material. Infer a rule only when ALL source instances are
// overridden identically; a partial source substitution must not become global.
function ExtendProjectVariantMaterial(SourceSelector, TargetSelector, VariantName,
    LibraryReference: String; ApplyChanges: Boolean): String;
var
    SourceProject, TargetProject: IProject;
    SourceVariant, TargetVariant: IProjectVariant;
    SourceFlat, TargetFlat: IDocument;
    Component, TemplateComponent: IComponent;
    Change, TemplateChange, NewChange: IComponentVariation;
    ServerDocument: IServerDocument;
    Pending, Ids, Records, Props: TStringList;
    i, SourceCount, TargetCount, NewIndex, AddedCount: Integer;
    ErrorText: String;
begin
    Result := '{"success": false, "error": "Both open projects and existing named variants are required. Copy the variant first."}';
    SourceProject := FindVariantProject(SourceSelector);
    TargetProject := FindVariantProject(TargetSelector);
    if (SourceProject = nil) or (TargetProject = nil) then Exit;
    if SourceProject.DM_ProjectFullPath = TargetProject.DM_ProjectFullPath then Exit;
    SourceVariant := FindMaterialVariant(SourceProject, VariantName);
    TargetVariant := FindMaterialVariant(TargetProject, VariantName);
    if (SourceVariant = nil) or (TargetVariant = nil) then Exit;
    if SourceProject.DM_NeedsCompile then
        if not SourceProject.DM_Compile then Exit;
    if TargetProject.DM_NeedsCompile then
        if not TargetProject.DM_Compile then Exit;
    SourceFlat := SourceProject.DM_DocumentFlattened;
    TargetFlat := TargetProject.DM_DocumentFlattened;
    if (SourceFlat = nil) or (TargetFlat = nil) then Exit;
    Pending := TStringList.Create;
    Ids := TStringList.Create;
    Records := TStringList.Create;
    Props := TStringList.Create;
    try
        ErrorText := '';
        SourceCount := 0;
        TargetCount := 0;
        AddedCount := 0;
        TemplateComponent := nil;
        TemplateChange := nil;
        for i := 0 to SourceFlat.DM_ComponentCount - 1 do
        begin
            Component := SourceFlat.DM_Components(i);
            if Component.DM_LibraryReference = LibraryReference then
            begin
                SourceCount := SourceCount + 1;
                Change := SourceVariant.DM_FindComponentVariationByUniqueId(Component.DM_UniqueId);
                if Change = nil then
                    ErrorText := 'Source material is only partially overridden; refusing a global material rule.'
                else if Ord(Change.DM_VariationKind) <> 0 then
                    ErrorText := 'Only fitted parameter overrides are supported.'
                else if TemplateChange = nil then
                begin
                    TemplateComponent := Component;
                    TemplateChange := Change;
                end
                else if (not SameBaseMaterial(TemplateComponent, Component)) or
                        (not MaterialOverrideValuesMatch(TemplateChange, Change)) then
                    ErrorText := 'Source material has conflicting base values or override values.';
            end;
        end;
        if (SourceCount = 0) or (TemplateChange = nil) then
            ErrorText := 'No source material rule found for the exact library reference.';
        if ErrorText = '' then
            for i := 0 to TargetFlat.DM_ComponentCount - 1 do
            begin
                Component := TargetFlat.DM_Components(i);
                if Component.DM_LibraryReference = LibraryReference then
                begin
                    TargetCount := TargetCount + 1;
                    if not SameBaseMaterial(TemplateComponent, Component) then
                        ErrorText := 'Target base material differs: ' + Component.DM_PhysicalDesignator;
                    if (Component.DM_UniqueId = '') or
                       (MaterialComponentMatchCount(TargetFlat, Component.DM_PhysicalDesignator) <> 1) then
                        ErrorText := 'Target identity missing or ambiguous: ' + Component.DM_PhysicalDesignator;
                    Change := TargetVariant.DM_FindComponentVariationByDesignator(Component.DM_PhysicalDesignator);
                    if Change = nil then
                    begin
                        Pending.Add(Component.DM_PhysicalDesignator);
                        Ids.Add(Component.DM_UniqueId);
                        Records.Add('"' + JSONEscapeString(Component.DM_PhysicalDesignator) + '"');
                    end
                    else if (Change.DM_UniqueId <> Component.DM_UniqueId) or
                            (not MaterialOverrideValuesMatch(TemplateChange, Change)) then
                        ErrorText := 'Existing target override conflicts: ' + Component.DM_PhysicalDesignator;
                end;
            end;
        if TargetCount = 0 then ErrorText := 'No compatible target material found.';
        ServerDocument := TargetProject.DM_ServerDocument;
        if ServerDocument = nil then ErrorText := 'Target project server document is unavailable.';
        if (ErrorText = '') and ApplyChanges and (Pending.Count > 0) then
        begin
            NewIndex := TargetVariant.DM_VariationCount;
            TargetProject.DM_BeginUpdate;
            try
                try
                    for i := 0 to Pending.Count - 1 do
                    begin
                        NewChange := TargetVariant.DM_AddComponentVariation;
                        NewChange.DM_SetPhysicalDesignator(Pending[i]);
                        NewChange.DM_SetUniqueId(Ids[i]);
                        PopulateMaterialOverride(TemplateChange, NewChange);
                        if (NewChange.DM_UniqueId <> Ids[i]) or
                           (not MaterialOverrideValuesMatch(TemplateChange, NewChange)) then
                        begin
                            ErrorText := 'New material override failed readback.';
                            Break;
                        end;
                    end;
                except
                    ErrorText := 'Material extension failed; inspect live state before retrying.';
                end;
                if ErrorText <> '' then
                begin
                    while TargetVariant.DM_VariationCount > NewIndex do
                        TargetVariant.DM_RemoveComponentVariation(TargetVariant.DM_VariationCount - 1);
                end
                else
                    AddedCount := Pending.Count;
            finally
                TargetProject.DM_EndUpdate;
            end;
            if AddedCount > 0 then
            begin
                TargetProject.DM_RefreshInWorkspaceForm;
                ServerDocument.SetModified(True);
            end;
        end;
        AddJSONBoolean(Props, 'success', ErrorText = '');
        AddJSONInteger(Props, 'source_material_count', SourceCount);
        AddJSONInteger(Props, 'target_material_count', TargetCount);
        AddJSONInteger(Props, 'pending_changes', Pending.Count);
        AddJSONInteger(Props, 'added_changes', AddedCount);
        AddJSONBoolean(Props, 'already_matches', Pending.Count = 0);
        AddJSONProperty(Props, 'library_reference', LibraryReference);
        AddJSONProperty(Props, 'variant', VariantName);
        if TemplateChange <> nil then
            AddJSONProperty(Props, 'replacement_comment', TemplateChange.DM_AlternatePart);
        Props.Add(BuildJSONArray(Records, 'extension_designators'));
        AddJSONBoolean(Props, 'save_requested', False);
        if ServerDocument <> nil then
            AddJSONBoolean(Props, 'target_modified', ServerDocument.GetModified);
        AddJSONProperty(Props, 'save_state_warning', 'No save command issued. Keep Altium open; persistence and project dirty state require inspection.');
        if ErrorText <> '' then AddJSONProperty(Props, 'error', ErrorText);
        Result := BuildJSONObject(Props, 0);
    finally
        Props.Free;
        Records.Free;
        Ids.Free;
        Pending.Free;
    end;
end;

function ExecuteProjectVariantMaintenance(Commands: TStringList): String;
var
    Fields: TStringList;
begin
    Result := '';
    if Commands.Count <> 1 then Exit;
    Fields := TStringList.Create;
    try
        Fields.StrictDelimiter := True;
        Fields.Delimiter := '|';
        Fields.DelimitedText := Commands[0];
        if Fields.Count = 0 then Exit;
        if Pos('PROJECT_VARIANT', Fields[0]) = 1 then
            Result := '{"success": false, "error": "Invalid project variant command or field count."}';
        if Fields[0] = 'PROJECT_VARIANTS_INSPECT' then
        begin
            if Fields.Count = 2 then Result := InspectProjectVariants(Fields[1]);
        end;
        if Fields[0] = 'PROJECT_VARIANT_COMPONENTS' then
        begin
            if Fields.Count = 2 then Result := InspectVariantComponents(Fields[1]);
        end;
        if Fields[0] = 'PROJECT_VARIANT_EFFECTIVE_MATERIALS' then
        begin
            if Fields.Count = 4 then
                Result := InspectEffectiveVariantMaterials(Fields[1], Fields[2], Fields[3]);
        end;
        if Fields[0] = 'PROJECT_VARIANT_EXTEND_MATERIAL' then
        begin
            if Fields.Count = 6 then
                if (UpperCase(Fields[5]) = 'APPLY') or (UpperCase(Fields[5]) = 'DRY_RUN') then
                    Result := ExtendProjectVariantMaterial(Fields[1], Fields[2], Fields[3], Fields[4],
                        UpperCase(Fields[5]) = 'APPLY');
        end;
        if Fields[0] = 'PROJECT_VARIANT_MATERIALS' then
        begin
            if Fields.Count = 6 then
                if ((UpperCase(Fields[4]) = 'TRUE') or (UpperCase(Fields[4]) = 'FALSE')) and
                   ((UpperCase(Fields[5]) = 'APPLY') or (UpperCase(Fields[5]) = 'DRY_RUN')) then
                    Result := CopyProjectVariantMaterials(Fields[1], Fields[2], Fields[3],
                        UpperCase(Fields[4]) = 'TRUE', UpperCase(Fields[5]) = 'APPLY');
        end;
    finally
        Fields.Free;
    end;
end;
