{ Generalized inventory and explicit geometry tools. Never saves a document.
  Portions adapted from Quilter routing scripts, MIT, copyright 2026 Allegro
  Labs, Inc. See LICENSES/Quilter-MIT.txt. No experiment net/coordinate policy. }

var RoutingFailure : String;

procedure RoutingFail(ErrorText : String);
begin
    RoutingFailure := ErrorText;
    Raise(ErrorText);
end;

function RoutingField(Value : String) : String;
var I, N : Integer;
begin
    Result := '';
    for I := 1 to Length(Value) do
    begin
        N := Ord(Value[I]);
        if Value[I] = '\' then Result := Result + '\\'
        else if Value[I] = '"' then Result := Result + '\"'
        else if (N < 32) or (N > 126) then Result := Result + '\u' + IntToHex(N, 4)
        else Result := Result + Value[I];
    end;
end;

function RoutingQuote(Value : String) : String;
begin
    Result := '"' + RoutingField(Value) + '"';
end;

function RoutingFloat(Value : Double) : String;
begin
    Result := StringReplace(FloatToStr(Value), ',', '.', MkSet(rfReplaceAll));
end;

function RoutingBool(Value : Boolean) : String;
begin
    Result := 'false';
    if Value then Result := 'true';
end;

procedure RoutingSplit(Value, Separator : String; Fields : TStringList);
var P : Integer;
begin
    Fields.Clear;
    P := Pos(Separator, Value);
    while P > 0 do
    begin
        Fields.Add(Copy(Value, 1, P - 1));
        Value := Copy(Value, P + Length(Separator), Length(Value));
        P := Pos(Separator, Value);
    end;
    Fields.Add(Value);
end;

function RoutingNet(Primitive : IPCB_Primitive) : String;
begin
    Result := '';
    if Primitive.Net <> nil then Result := Primitive.Net.Name;
end;

function RoutingBoard(ExpectedPath : String) : IPCB_Board;
begin
    Result := PCBServer.GetPCBBoardByPath(ExpectedPath);
    if Result = nil then RoutingFail('The exact requested PCB is not open.');
    if UpperCase(Result.FileName) <> UpperCase(ExpectedPath) then RoutingFail('PCB full-path mismatch.');
end;

procedure RoutingRequireActive(Board : IPCB_Board);
var Active : IPCB_Board;
begin
    Active:=PCBServer.GetCurrentPCBBoard;
    if Active=nil then RoutingFail('Activate the exact requested PCB first.');
    if UpperCase(Active.FileName)<>UpperCase(Board.FileName) then RoutingFail('The requested PCB must be active.');
end;

procedure RoutingWrite(Path, Value : String);
var Lines : TStringList;
begin
    { All output is ASCII, including escaped UTF-16 code units. }
    Lines := TStringList.Create;
    try
        Lines.Text := Value;
        Lines.SaveToFile(Path);
    finally
        Lines.Free;
    end;
end;

procedure RoutingStatus(Directory, RequestID, Phase : String; Row, Completed : Integer);
begin
    RoutingWrite(Directory + '\operation-status.json', '{"request_id":' + RoutingQuote(RequestID) +
        ',"phase":' + RoutingQuote(Phase) + ',"row":' + IntToStr(Row) +
        ',"completed_rows":' + IntToStr(Completed) + ',"error":' + RoutingQuote(RoutingFailure) + ',"saved":false}');
end;

function RoutingGeometry(Primitive : IPCB_Primitive) : String;
var Track : IPCB_Track; Via : IPCB_Via; Pad : IPCB_Pad; Arc : IPCB_Arc;
    X1, Y1, X2, Y2, T : Integer;
begin
    Result := '';
    case Primitive.ObjectId of
        eTrackObject:
        begin
            Track := Primitive;
            X1 := Track.X1; Y1 := Track.Y1; X2 := Track.X2; Y2 := Track.Y2;
            if (X1 > X2) or ((X1 = X2) and (Y1 > Y2)) then
            begin
                T := X1; X1 := X2; X2 := T; T := Y1; Y1 := Y2; Y2 := T;
            end;
            Result := IntToStr(X1)+','+IntToStr(Y1)+','+IntToStr(X2)+','+IntToStr(Y2)+','+IntToStr(Track.Width)+','+IntToStr(Track.Layer);
        end;
        eViaObject:
        begin
            Via := Primitive;
            Result := IntToStr(Via.X)+','+IntToStr(Via.Y)+','+IntToStr(Via.Size)+','+IntToStr(Via.HoleSize)+','+IntToStr(Via.LowLayer)+','+IntToStr(Via.HighLayer);
        end;
        ePadObject:
        begin
            Pad := Primitive;
            Result := IntToStr(Pad.X)+','+IntToStr(Pad.Y)+','+IntToStr(Pad.Layer);
        end;
        eArcObject:
        begin
            Arc := Primitive;
            Result := IntToStr(Arc.XCenter)+','+IntToStr(Arc.YCenter)+','+IntToStr(Arc.Radius)+','+RoutingFloat(Arc.StartAngle)+','+RoutingFloat(Arc.EndAngle)+','+IntToStr(Arc.LineWidth)+','+IntToStr(Arc.Layer);
        end;
    end;
end;

function RoutingKind(Primitive : IPCB_Primitive) : String;
begin
    Result := '';
    case Primitive.ObjectId of
        eTrackObject: Result := 'track';
        eViaObject: Result := 'via';
        ePadObject: Result := 'pad';
        eArcObject: Result := 'arc';
        ePolyObject: Result := 'polygon';
        eConnectionObject: Result := 'connection';
    end;
end;

function RoutingPolygonDefinition(Polygon : IPCB_Polygon) : String;
var I : Integer; Segment : TPolySegment;
begin
    Result := IntToStr(Polygon.PolygonType)+','+IntToStr(Polygon.PolyHatchStyle)+','+
        IntToStr(Polygon.PourOver)+','+RoutingBool(Polygon.RemoveDead)+','+
        IntToStr(Polygon.BorderWidth)+','+IntToStr(Polygon.Grid)+','+IntToStr(Polygon.TrackSize)+','+
        IntToStr(Polygon.MinTrack)+','+RoutingBool(Polygon.UseOctagons)+','+
        RoutingBool(Polygon.RemoveIslandsByArea)+','+RoutingFloat(Polygon.IslandAreaThreshold)+','+
        RoutingBool(Polygon.RemoveNarrowNecks)+','+IntToStr(Polygon.NeckWidthThreshold)+','+IntToStr(Polygon.ArcApproximation);
    for I := 0 to Polygon.PointCount - 1 do
    begin
        Segment := Polygon.Segments[I];
        Result := Result + ';' + IntToStr(Segment.Kind)+','+IntToStr(Segment.vx)+','+IntToStr(Segment.vy)+','+
            IntToStr(Segment.cx)+','+IntToStr(Segment.cy)+','+IntToStr(Segment.Radius)+','+
            RoutingFloat(Segment.Angle1)+','+RoutingFloat(Segment.Angle2);
    end;
end;

procedure RoutingCollect(Board : IPCB_Board; Tables : TStringList; Signature : TStringList);
var Iterator : IPCB_BoardIterator; Primitive : IPCB_Primitive;
    Net : IPCB_Net; Pad : IPCB_Pad; Track : IPCB_Track; Via : IPCB_Via;
    Connection : IPCB_Connection; Rule : IPCB_Rule; Component : IPCB_Component;
    Arc : IPCB_Arc; Polygon : IPCB_Polygon; Stack : IPCB_LayerStack; LayerObject : IPCB_LayerObject;
    Nets, Pads, Tracks, Vias, Connections, Rules, Components, Layers, Arcs, Polygons, Summary : TStringList;
    Row, Refdes, ModeName : String; RatsnestCount, RedundantCount, InvalidNetCount, LayerCount : Integer;
begin
    Nets:=TStringList.Create; Pads:=TStringList.Create; Tracks:=TStringList.Create; Vias:=TStringList.Create;
    Connections:=TStringList.Create; Rules:=TStringList.Create; Components:=TStringList.Create;
    Layers:=TStringList.Create; Arcs:=TStringList.Create; Polygons:=TStringList.Create; Summary:=TStringList.Create;
    try
        Nets.Add('net'+#9+'pin_count'+#9+'via_count'+#9+'routed_length_raw'+#9+'connectivity_invalid'+#9+'connections_visible');
        Pads.Add('refdes'+#9+'pad'+#9+'net'+#9+'x_raw'+#9+'y_raw'+#9+'layer_id'+#9+'layer'+#9+'rotation_degrees'+#9+'top_x_size_raw'+#9+'top_y_size_raw'+#9+'hole_size_raw'+#9+'selected');
        Tracks.Add('net'+#9+'x1_raw'+#9+'y1_raw'+#9+'x2_raw'+#9+'y2_raw'+#9+'width_raw'+#9+'layer_id'+#9+'layer'+#9+'selected');
        Vias.Add('net'+#9+'x_raw'+#9+'y_raw'+#9+'size_raw'+#9+'hole_size_raw'+#9+'low_layer_id'+#9+'high_layer_id'+#9+'selected');
        Connections.Add('net'+#9+'x1_raw'+#9+'y1_raw'+#9+'x2_raw'+#9+'y2_raw'+#9+'layer1_id'+#9+'layer2_id'+#9+'mode'+#9+'redundant'+#9+'selected');
        Rules.Add('name'+#9+'kind_id'+#9+'priority'+#9+'drc_enabled'+#9+'scope1'+#9+'scope2'+#9+'summary');
        Components.Add('refdes'+#9+'comment'+#9+'footprint'+#9+'x_raw'+#9+'y_raw'+#9+'rotation_degrees'+#9+'layer_id'+#9+'layer');
        Layers.Add('stack_index'+#9+'layer_id'+#9+'layer_name'+#9+'copper_thickness_raw');
        Arcs.Add('net'+#9+'x_raw'+#9+'y_raw'+#9+'radius_raw'+#9+'start_angle'+#9+'end_angle'+#9+'width_raw'+#9+'layer_id'+#9+'selected');
        Polygons.Add('name'+#9+'net'+#9+'layer_id'+#9+'definition');
        RatsnestCount:=0; RedundantCount:=0; InvalidNetCount:=0;
        Signature.Clear;
        Signature.Add('board'+#9+RoutingField(UpperCase(Board.FileName))+#9+IntToStr(Board.XOrigin)+#9+IntToStr(Board.YOrigin)+#9+IntToStr(MilsToCoord(1)));
        Iterator:=Board.BoardIterator_Create;
        try
            Iterator.AddFilter_ObjectSet(MkSet(eNetObject,ePadObject,eTrackObject,eViaObject,eConnectionObject,eRuleObject,eComponentObject,eArcObject,ePolyObject));
            Iterator.AddFilter_LayerSet(AllLayers);
            Iterator.AddFilter_Method(eProcessAll);
            Primitive:=Iterator.FirstPCBObject;
            while Primitive<>nil do
            begin
                case Primitive.ObjectId of
                    eNetObject:
                    begin
                        Net:=Primitive;
                        Nets.Add(RoutingField(Net.Name)+#9+IntToStr(Net.PinCount)+#9+IntToStr(Net.ViaCount)+#9+IntToStr(Net.RoutedLength)+#9+RoutingBool(Net.ConnectivelyInvalid)+#9+RoutingBool(Net.ConnectsVisible));
                        Signature.Add('net'+#9+RoutingField(Net.Name)+#9+IntToStr(Net.PinCount));
                        if Net.ConnectivelyInvalid then Inc(InvalidNetCount);
                    end;
                    ePadObject:
                    begin
                        Pad:=Primitive; Refdes:='';
                        if Pad.Component<>nil then Refdes:=Pad.Component.Name.Text;
                        Row:=RoutingField(Refdes)+#9+RoutingField(Pad.Name)+#9+RoutingField(RoutingNet(Pad))+#9+IntToStr(Pad.X)+#9+IntToStr(Pad.Y)+#9+IntToStr(Pad.Layer)+#9+RoutingField(Layer2String(Pad.Layer))+#9+RoutingFloat(Pad.Rotation)+#9+IntToStr(Pad.TopXSize)+#9+IntToStr(Pad.TopYSize)+#9+IntToStr(Pad.HoleSize);
                        Pads.Add(Row+#9+RoutingBool(Pad.Selected)); Signature.Add('pad'+#9+Row);
                    end;
                    eTrackObject:
                    begin
                        Track:=Primitive;
                        Row:=RoutingField(RoutingNet(Track))+#9+IntToStr(Track.X1)+#9+IntToStr(Track.Y1)+#9+IntToStr(Track.X2)+#9+IntToStr(Track.Y2)+#9+IntToStr(Track.Width)+#9+IntToStr(Track.Layer)+#9+RoutingField(Layer2String(Track.Layer));
                        Tracks.Add(Row+#9+RoutingBool(Track.Selected));
                        Signature.Add('track'+#9+RoutingField(RoutingNet(Track))+#9+RoutingGeometry(Track));
                    end;
                    eViaObject:
                    begin
                        Via:=Primitive;
                        Row:=RoutingField(RoutingNet(Via))+#9+IntToStr(Via.X)+#9+IntToStr(Via.Y)+#9+IntToStr(Via.Size)+#9+IntToStr(Via.HoleSize)+#9+IntToStr(Via.LowLayer)+#9+IntToStr(Via.HighLayer);
                        Vias.Add(Row+#9+RoutingBool(Via.Selected)); Signature.Add('via'+#9+Row);
                    end;
                    eConnectionObject:
                    begin
                        Connection:=Primitive; ModeName:='other';
                        if Connection.Mode=eRatsNestConnection then ModeName:='ratsnest';
                        if Connection.Mode=eBrokenNetMarker then ModeName:='broken_net_marker';
                        Connections.Add(RoutingField(RoutingNet(Connection))+#9+IntToStr(Connection.X1)+#9+IntToStr(Connection.Y1)+#9+IntToStr(Connection.X2)+#9+IntToStr(Connection.Y2)+#9+IntToStr(Connection.Layer1)+#9+IntToStr(Connection.Layer2)+#9+ModeName+#9+RoutingBool(Connection.IsRedundant)+#9+RoutingBool(Connection.Selected));
                        if Connection.IsRedundant then Inc(RedundantCount)
                        else if Connection.Mode=eRatsNestConnection then Inc(RatsnestCount);
                    end;
                    eRuleObject:
                    begin
                        Rule:=Primitive;
                        Row:=RoutingField(Rule.Name)+#9+IntToStr(Rule.RuleKind)+#9+IntToStr(Rule.Priority)+#9+RoutingBool(Rule.DRCEnabled)+#9+RoutingField(Rule.Scope1Expression)+#9+RoutingField(Rule.Scope2Expression)+#9+RoutingField(Rule.GetState_DataSummaryString);
                        Rules.Add(Row); Signature.Add('rule'+#9+Row);
                    end;
                    eComponentObject:
                    begin
                        Component:=Primitive;
                        Row:=RoutingField(Component.Name.Text)+#9+RoutingField(Component.Comment.Text)+#9+RoutingField(Component.Pattern)+#9+IntToStr(Component.X)+#9+IntToStr(Component.Y)+#9+RoutingFloat(Component.Rotation)+#9+IntToStr(Component.Layer)+#9+RoutingField(Layer2String(Component.Layer));
                        Components.Add(Row); Signature.Add('component'+#9+Row);
                    end;
                    eArcObject:
                    begin
                        Arc:=Primitive;
                        Row:=RoutingField(RoutingNet(Arc))+#9+IntToStr(Arc.XCenter)+#9+IntToStr(Arc.YCenter)+#9+IntToStr(Arc.Radius)+#9+RoutingFloat(Arc.StartAngle)+#9+RoutingFloat(Arc.EndAngle)+#9+IntToStr(Arc.LineWidth)+#9+IntToStr(Arc.Layer);
                        Arcs.Add(Row+#9+RoutingBool(Arc.Selected)); Signature.Add('arc'+#9+Row);
                    end;
                    ePolyObject:
                    begin
                        Polygon:=Primitive;
                        Row:=RoutingField(Polygon.Name)+#9+RoutingField(RoutingNet(Polygon))+#9+IntToStr(Polygon.Layer)+#9+RoutingField(RoutingPolygonDefinition(Polygon));
                        Polygons.Add(Row); Signature.Add('polygon'+#9+Row);
                    end;
                end;
                Primitive:=Iterator.NextPCBObject;
            end;
        finally
            Board.BoardIterator_Destroy(Iterator);
        end;
        Stack:=Board.LayerStack;
        if Stack=nil then RoutingFail('PCB has no legacy layer stack.');
        LayerCount:=0; LayerObject:=Stack.FirstLayer;
        while LayerObject<>nil do
        begin
            Inc(LayerCount);
            if LayerCount>64 then RoutingFail('Layer stack iteration exceeded 64 entries.');
            Row:=IntToStr(LayerCount)+#9+IntToStr(LayerObject.LayerID)+#9+RoutingField(LayerObject.Name)+#9+IntToStr(LayerObject.CopperThickness);
            Layers.Add(Row); Signature.Add('layer'+#9+Row);
            LayerObject:=Stack.NextLayer(LayerObject);
        end;
        Signature.Sort;
        Summary.Add('field'+#9+'value');
        Summary.Add('board_file'+#9+RoutingField(Board.FileName));
        Summary.Add('coordinate_units'+#9+'Altium internal units');
        Summary.Add('field_encoding'+#9+'json-string');
        Summary.Add('internal_units_per_mil'+#9+IntToStr(MilsToCoord(1)));
        Summary.Add('x_origin_raw'+#9+IntToStr(Board.XOrigin)); Summary.Add('y_origin_raw'+#9+IntToStr(Board.YOrigin));
        Summary.Add('net_count'+#9+IntToStr(Nets.Count-1)); Summary.Add('pad_count'+#9+IntToStr(Pads.Count-1));
        Summary.Add('track_segment_count'+#9+IntToStr(Tracks.Count-1)); Summary.Add('via_count'+#9+IntToStr(Vias.Count-1));
        Summary.Add('connection_object_count'+#9+IntToStr(Connections.Count-1)); Summary.Add('rule_count'+#9+IntToStr(Rules.Count-1));
        Summary.Add('nonredundant_ratsnest_connections'+#9+IntToStr(RatsnestCount));
        Summary.Add('redundant_connection_objects'+#9+IntToStr(RedundantCount)); Summary.Add('connectivity_invalid_nets'+#9+IntToStr(InvalidNetCount));
        Summary.Add('components_count'+#9+IntToStr(Components.Count-1)); Summary.Add('layers_count'+#9+IntToStr(Layers.Count-1));
        Summary.Add('arcs_count'+#9+IntToStr(Arcs.Count-1)); Summary.Add('polygons_count'+#9+IntToStr(Polygons.Count-1));
        Tables.Values['board']:=Summary.Text; Tables.Values['nets']:=Nets.Text; Tables.Values['pads']:=Pads.Text;
        Tables.Values['tracks']:=Tracks.Text; Tables.Values['vias']:=Vias.Text; Tables.Values['connections']:=Connections.Text;
        Tables.Values['rules']:=Rules.Text; Tables.Values['components']:=Components.Text; Tables.Values['layers']:=Layers.Text;
        Tables.Values['arcs']:=Arcs.Text; Tables.Values['polygons']:=Polygons.Text;
    finally
        Summary.Free; Polygons.Free; Arcs.Free; Layers.Free; Components.Free; Rules.Free;
        Connections.Free; Vias.Free; Tracks.Free; Pads.Free; Nets.Free;
    end;
end;

procedure RoutingExport(Board : IPCB_Board; Directory, SnapshotID : String);
var Tables, Signature, Names : TStringList; I : Integer;
begin
    Tables:=TStringList.Create; Signature:=TStringList.Create; Names:=TStringList.Create;
    try
        RoutingWrite(Directory+'\inventory-status.txt','exporting');
        RoutingCollect(Board,Tables,Signature);
        Names.CommaText:='board,nets,pads,tracks,vias,connections,rules,components,layers,arcs,polygons';
        for I:=0 to Names.Count-1 do
        begin
            if Names[I]='board' then Tables.Values['board']:=Tables.Values['board']+'snapshot_id'+#9+SnapshotID+#13#10;
            RoutingWrite(Directory+'\'+Names[I]+'.tsv',Tables.Values[Names[I]]);
        end;
        Signature.SaveToFile(Directory+'\board-signature.txt');
        RoutingWrite(Directory+'\inventory-status.txt','complete');
    finally
        Names.Free; Signature.Free; Tables.Free;
    end;
end;

procedure RoutingCheckBaseline(Board : IPCB_Board; Directory : String);
var Tables, Signature, Baseline : TStringList;
begin
    Tables:=TStringList.Create; Signature:=TStringList.Create; Baseline:=TStringList.Create;
    try
        Baseline.LoadFromFile(Directory+'\baseline-signature.txt');
        RoutingCollect(Board,Tables,Signature);
        if Baseline.Text<>Signature.Text then RoutingFail('PCB changed since baseline snapshot; refresh and replan.');
    finally
        Baseline.Free; Signature.Free; Tables.Free;
    end;
end;

function RoutingFind(Board : IPCB_Board; Kind, NetName, Geometry : String; var Matches : Integer) : IPCB_Primitive;
var Iterator : IPCB_BoardIterator; Primitive : IPCB_Primitive;
begin
    Result:=nil; Matches:=0;
    Iterator:=Board.BoardIterator_Create;
    try
        Iterator.AddFilter_ObjectSet(MkSet(eTrackObject,eViaObject,ePadObject,eArcObject));
        Iterator.AddFilter_LayerSet(AllLayers); Iterator.AddFilter_Method(eProcessAll);
        Primitive:=Iterator.FirstPCBObject;
        while Primitive<>nil do
        begin
            if (RoutingKind(Primitive)=Kind) and (RoutingNet(Primitive)=NetName) and (RoutingGeometry(Primitive)=Geometry) then
            begin
                Result:=Primitive; Inc(Matches);
            end;
            Primitive:=Iterator.NextPCBObject;
        end;
    finally
        Board.BoardIterator_Destroy(Iterator);
    end;
end;

function RoutingFindNet(Board : IPCB_Board; Name : String) : IPCB_Net;
var Iterator : IPCB_BoardIterator; Net : IPCB_Net; Count : Integer;
begin
    Result:=nil; Count:=0;
    Iterator:=Board.BoardIterator_Create;
    try
        Iterator.AddFilter_ObjectSet(MkSet(eNetObject)); Iterator.AddFilter_LayerSet(AllLayers); Iterator.AddFilter_Method(eProcessAll);
        Net:=Iterator.FirstPCBObject;
        while Net<>nil do
        begin
            if Net.Name=Name then begin Result:=Net; Inc(Count); end;
            Net:=Iterator.NextPCBObject;
        end;
    finally
        Board.BoardIterator_Destroy(Iterator);
    end;
    if Count<>1 then RoutingFail('Net must resolve to exactly one existing PCB net.');
end;

procedure RoutingSetGeometry(Primitive : IPCB_Primitive; Geometry : String);
var Fields : TStringList; Track : IPCB_Track; Via : IPCB_Via;
begin
    Fields:=TStringList.Create;
    try
        RoutingSplit(Geometry,',',Fields);
        if Fields.Count<>6 then RoutingFail('Track/via geometry requires six integer fields.');
        case Primitive.ObjectId of
            eTrackObject:
            begin
                Track:=Primitive; Track.X1:=StrToInt(Fields[0]); Track.Y1:=StrToInt(Fields[1]);
                Track.X2:=StrToInt(Fields[2]); Track.Y2:=StrToInt(Fields[3]);
                Track.Width:=StrToInt(Fields[4]); Track.Layer:=StrToInt(Fields[5]);
                if (Track.Width<=0) or ((Track.X1=Track.X2) and (Track.Y1=Track.Y2)) then RoutingFail('Invalid track dimensions.');
            end;
            eViaObject:
            begin
                Via:=Primitive; Via.X:=StrToInt(Fields[0]); Via.Y:=StrToInt(Fields[1]);
                Via.Size:=StrToInt(Fields[2]); Via.HoleSize:=StrToInt(Fields[3]);
                Via.LowLayer:=StrToInt(Fields[4]); Via.HighLayer:=StrToInt(Fields[5]);
                if (Via.HoleSize<=0) or (Via.Size<=Via.HoleSize) then RoutingFail('Invalid via dimensions.');
            end;
        else RoutingFail('Unsupported geometry kind.');
        end;
    finally Fields.Free; end;
end;

procedure RoutingCheckViaCenter(Board : IPCB_Board; Candidate, Target : IPCB_Primitive; AllowViaInPad : Boolean);
var Iterator : IPCB_BoardIterator; Primitive : IPCB_Primitive; Via, Existing : IPCB_Via; Pad : IPCB_Pad;
    SameTarget : Boolean;
begin
    Via:=Candidate;
    Iterator:=Board.BoardIterator_Create;
    try
        Iterator.AddFilter_ObjectSet(MkSet(eViaObject,ePadObject)); Iterator.AddFilter_LayerSet(AllLayers); Iterator.AddFilter_Method(eProcessAll);
        Primitive:=Iterator.FirstPCBObject;
        while Primitive<>nil do
        begin
            SameTarget:=False;
            if Target<>nil then SameTarget:=Primitive.I_ObjectAddress=Target.I_ObjectAddress;
            if Primitive.ObjectId=eViaObject then
            begin
                Existing:=Primitive;
                if (Existing.X=Via.X) and (Existing.Y=Via.Y) and not SameTarget then RoutingFail('Via center is already occupied.');
            end
            else
            begin
                Pad:=Primitive;
                if (Pad.X=Via.X) and (Pad.Y=Via.Y) then
                    if not AllowViaInPad or (RoutingNet(Pad)<>RoutingNet(Via)) then RoutingFail('Via in pad requires explicit same-net allowance.');
            end;
            Primitive:=Iterator.NextPCBObject;
        end;
    finally Board.BoardIterator_Destroy(Iterator); end;
end;

function RoutingRules(Board : IPCB_Board; Directory : String) : String;
var Lines, Fields, Rows : TStringList; I, Matches, QueryLayer : Integer;
    Primitive : IPCB_Primitive; WidthRule : IPCB_MaxMinWidthConstraint; PairRule : IPCB_DifferentialPairsRoutingRule;
    Row, WidthJSON, PairJSON : String;
begin
    Lines:=TStringList.Create; Fields:=TStringList.Create; Rows:=TStringList.Create;
    try
        Lines.LoadFromFile(Directory+'\selectors.tsv');
        for I:=1 to Lines.Count-1 do
        begin
            RoutingSplit(Lines[I],#9,Fields);
            if Fields.Count<>4 then RoutingFail('Rule selector requires four columns.');
            Primitive:=RoutingFind(Board,Fields[0],Fields[1],Fields[2],Matches);
            if Matches<>1 then RoutingFail('Rule query must identify exactly one existing primitive.');
            QueryLayer:=StrToInt(Fields[3]); WidthJSON:='null'; PairJSON:='null';
            WidthRule:=Board.FindDominantRuleForObject(Primitive,eRule_MaxMinWidth);
            if WidthRule<>nil then
                WidthJSON:='{"name":'+RoutingQuote(WidthRule.Name)+',"scope1":'+RoutingQuote(WidthRule.Scope1Expression)+
                    ',"minimum_raw":'+IntToStr(WidthRule.MinWidth(QueryLayer))+',"preferred_raw":'+IntToStr(WidthRule.FavoredWidth(QueryLayer))+
                    ',"maximum_raw":'+IntToStr(WidthRule.MaxWidth(QueryLayer))+',"impedance_driven":'+RoutingBool(WidthRule.ImpedanceDriven)+
                    ',"minimum_impedance":'+RoutingFloat(WidthRule.MinImpedance)+',"preferred_impedance":'+RoutingFloat(WidthRule.FavoredImpedance)+
                    ',"maximum_impedance":'+RoutingFloat(WidthRule.MaxImpedance)+'}';
            PairRule:=Board.FindDominantRuleForObject(Primitive,eRule_DifferentialPairsRouting);
            if PairRule<>nil then
                PairJSON:='{"name":'+RoutingQuote(PairRule.Name)+',"scope1":'+RoutingQuote(PairRule.Scope1Expression)+
                    ',"minimum_gap_raw":'+IntToStr(PairRule.GetState_MinGap(QueryLayer))+',"preferred_gap_raw":'+IntToStr(PairRule.GetState_PreferedGap(QueryLayer))+
                    ',"maximum_gap_raw":'+IntToStr(PairRule.GetState_MaxGap(QueryLayer))+'}';
            Row:='{"kind":'+RoutingQuote(Fields[0])+',"net":'+RoutingQuote(Fields[1])+',"geometry":'+RoutingQuote(Fields[2])+
                ',"layer_id":'+IntToStr(QueryLayer)+',"width_rule":'+WidthJSON+',"differential_rule":'+PairJSON+'}';
            Rows.Add(Row);
        end;
        Result:='{"objects":'+BuildJSONArray(Rows)+',"scope":"existing_object_on_requested_layer","prospective_geometry_qualified":false}';
    finally Rows.Free; Fields.Free; Lines.Free; end;
end;

function RoutingSelect(Board : IPCB_Board; Directory : String; Zoom : Boolean) : String;
var Lines, Fields, MatchesList : TStringList; Iterator : IPCB_BoardIterator;
    Primitive : IPCB_Primitive; Kinds, Nets, Geometries : array[1..256] of String;
    I, Count, SelectedCount : Integer; Wanted : Boolean;
begin
    Lines:=TStringList.Create; Fields:=TStringList.Create; MatchesList:=TStringList.Create;
    try
        Lines.LoadFromFile(Directory+'\selectors.tsv'); Count:=Lines.Count-1;
        if (Count<1) or (Count>256) then RoutingFail('Selection requires 1-256 selectors.');
        for I:=1 to Count do
        begin
            RoutingSplit(Lines[I],#9,Fields);
            if Fields.Count<>4 then RoutingFail('Selection requires four columns.');
            Kinds[I]:=Fields[0]; Nets[I]:=Fields[1]; Geometries[I]:=Fields[2];
            RoutingFindNet(Board,Nets[I]); MatchesList.Add('0');
        end;
        { Resolve every selector before replacing the user's selection. }
        Iterator:=Board.BoardIterator_Create;
        try
            Iterator.AddFilter_ObjectSet(MkSet(eTrackObject,eViaObject,ePadObject,eArcObject,ePolyObject,eConnectionObject));
            Iterator.AddFilter_LayerSet(AllLayers); Iterator.AddFilter_Method(eProcessAll);
            Primitive:=Iterator.FirstPCBObject;
            while Primitive<>nil do
            begin
                for I:=1 to Count do
                    if ((Kinds[I]='all') or (Kinds[I]=RoutingKind(Primitive))) and (RoutingNet(Primitive)=Nets[I]) then
                        if (Geometries[I]='') or (Geometries[I]=RoutingGeometry(Primitive)) then
                            MatchesList[I-1]:=IntToStr(StrToInt(MatchesList[I-1])+1);
                Primitive:=Iterator.NextPCBObject;
            end;
        finally Board.BoardIterator_Destroy(Iterator); end;
        for I:=0 to Count-1 do if MatchesList[I]='0' then RoutingFail('A selector matched no primitives; selection preserved.');
        RoutingRequireActive(Board);
        Iterator:=Board.BoardIterator_Create;
        try
            Iterator.AddFilter_ObjectSet(AllPrimitives); Iterator.AddFilter_LayerSet(AllLayers); Iterator.AddFilter_Method(eProcessAll);
            Primitive:=Iterator.FirstPCBObject;
            while Primitive<>nil do
            begin
                Primitive.Selected:=False;
                Primitive:=Iterator.NextPCBObject;
            end;
        finally Board.BoardIterator_Destroy(Iterator); end;
        SelectedCount:=0;
        Iterator:=Board.BoardIterator_Create;
        try
            Iterator.AddFilter_ObjectSet(MkSet(eTrackObject,eViaObject,ePadObject,eArcObject,ePolyObject,eConnectionObject));
            Iterator.AddFilter_LayerSet(AllLayers); Iterator.AddFilter_Method(eProcessAll);
            Primitive:=Iterator.FirstPCBObject;
            while Primitive<>nil do
            begin
                Wanted:=False;
                for I:=1 to Count do
                    if ((Kinds[I]='all') or (Kinds[I]=RoutingKind(Primitive))) and (RoutingNet(Primitive)=Nets[I]) then
                        if (Geometries[I]='') or (Geometries[I]=RoutingGeometry(Primitive)) then Wanted:=True;
                Primitive.Selected:=Wanted;
                if Wanted then Inc(SelectedCount);
                Primitive:=Iterator.NextPCBObject;
            end;
        finally Board.BoardIterator_Destroy(Iterator); end;
        if Zoom then Client.SendMessage('PCB:Zoom','Action=Selected',255,Client.CurrentView)
        else Client.SendMessage('PCB:Zoom','Action=Redraw',255,Client.CurrentView);
        Result:='{"selected_count":'+IntToStr(SelectedCount)+',"saved":false}';
    finally MatchesList.Free; Fields.Free; Lines.Free; end;
end;

function RoutingBatch(Board : IPCB_Board; Directory, SnapshotID, RequestID : String; var Completed : Integer) : String;
var Lines, Fields, Values, Audit : TStringList; I, J, Count, Matches : Integer;
    Kinds, Actions, Nets, OldGeometry, NewGeometry : array[1..256] of String;
    Targets, Candidates : array[1..256] of IPCB_Primitive;
    TargetNets : array[1..256] of IPCB_Net;
    Primitive, Existing : IPCB_Primitive; Track : IPCB_Track; Via : IPCB_Via;
    WidthRule : IPCB_MaxMinWidthConstraint; ActiveBoard : IPCB_Board;
begin
    Lines:=TStringList.Create; Fields:=TStringList.Create; Values:=TStringList.Create; Audit:=TStringList.Create;
    Count:=0; Completed:=0;
    for I:=1 to 256 do begin Targets[I]:=nil; Candidates[I]:=nil; end;
    try
        RoutingCheckBaseline(Board,Directory);
        Lines.LoadFromFile(Directory+'\operations.tsv'); Count:=Lines.Count-1;
        if (Count<1) or (Count>256) then RoutingFail('Batch requires 1-256 rows.');
        if Lines[0]<>'kind'+#9+'action'+#9+'net'+#9+'old_geometry'+#9+'new_geometry' then RoutingFail('Invalid batch header.');
        Audit.Add('row'+#9+'kind'+#9+'action'+#9+'result');
        for I:=1 to Count do
        begin
            RoutingStatus(Directory,RequestID,'preflight',I,Completed);
            RoutingSplit(Lines[I],#9,Fields);
            if Fields.Count<>5 then RoutingFail('Batch row requires five columns.');
            Kinds[I]:=Fields[0]; Actions[I]:=Fields[1]; Nets[I]:=Fields[2];
            OldGeometry[I]:=Fields[3]; NewGeometry[I]:=Fields[4];
            if (Kinds[I]<>'track') and (Kinds[I]<>'via') then RoutingFail('Unsupported batch primitive.');
            if (Actions[I]<>'add') and (Actions[I]<>'edit') and (Actions[I]<>'remove') then RoutingFail('Unsupported batch action.');
            if Nets[I]<>'' then TargetNets[I]:=RoutingFindNet(Board,Nets[I]) else TargetNets[I]:=nil;
            if (Actions[I]='add') and (TargetNets[I]=nil) then RoutingFail('New copper requires an assigned net.');
            if Actions[I]<>'add' then
            begin
                Targets[I]:=RoutingFind(Board,Kinds[I],Nets[I],OldGeometry[I],Matches);
                if Matches<>1 then RoutingFail('Old target does not resolve exactly once.');
                for J:=1 to I-1 do
                    if Targets[J]<>nil then
                        if Targets[J].I_ObjectAddress=Targets[I].I_ObjectAddress then RoutingFail('Repeated old target.');
            end
            else if OldGeometry[I]<>'-' then RoutingFail('Add must omit old geometry.');
            if Actions[I]<>'remove' then
            begin
                if Kinds[I]='track' then Candidates[I]:=PCBServer.PCBObjectFactory(eTrackObject,eNoDimension,eCreate_Default)
                else Candidates[I]:=PCBServer.PCBObjectFactory(eViaObject,eNoDimension,eCreate_Default);
                if Candidates[I]=nil then RoutingFail('Primitive factory failed.');
                Candidates[I].Net:=TargetNets[I]; RoutingSetGeometry(Candidates[I],NewGeometry[I]);
                if RoutingGeometry(Candidates[I])<>NewGeometry[I] then RoutingFail('Noncanonical geometry request.');
                if Kinds[I]='track' then
                begin
                    Track:=Candidates[I];
                    WidthRule:=Board.FindDominantRuleForObject(Track,eRule_MaxMinWidth);
                    if WidthRule=nil then RoutingFail('No dominant width rule for proposed track geometry.');
                    if (Track.Width<WidthRule.MinWidth(Track.Layer)) or (Track.Width>WidthRule.MaxWidth(Track.Layer)) then RoutingFail('Track width is outside its native dominant rule.');
                end
                else
                begin
                    Via:=Candidates[I];
                    RoutingCheckViaCenter(Board,Candidates[I],Targets[I],Params.Values['allow_via_in_pad']='true');
                    if Actions[I]='add' then
                        if (Via.LowLayer<>eTopLayer) or (Via.HighLayer<>eBottomLayer) then RoutingFail('New vias support through span only.');
                    if Actions[I]='edit' then
                    begin
                        Via:=Targets[I];
                        RoutingSplit(NewGeometry[I],',',Values);
                        if (Via.LowLayer<>StrToInt(Values[4])) or (Via.HighLayer<>StrToInt(Values[5])) then RoutingFail('Via edits must preserve drill span.');
                    end;
                end;
                Existing:=RoutingFind(Board,Kinds[I],Nets[I],NewGeometry[I],Matches);
                if Matches>0 then
                begin
                    if Targets[I]=nil then RoutingFail('Destination already exists.');
                    if Matches<>1 then RoutingFail('Destination is ambiguous.');
                    if Existing.I_ObjectAddress<>Targets[I].I_ObjectAddress then RoutingFail('Destination already exists.');
                end;
                for J:=1 to I-1 do
                    if (Kinds[J]=Kinds[I]) and (NewGeometry[J]=NewGeometry[I]) then RoutingFail('Repeated destination.');
            end
            else if NewGeometry[I]<>'-' then RoutingFail('Remove must omit new geometry.');
            Audit.Add(IntToStr(I)+#9+Kinds[I]+#9+Actions[I]+#9+'preflight_ok');
        end;
        Audit.SaveToFile(Directory+'\batch-audit.tsv');
        { The sole writer rechecks all baseline records immediately before writes. }
        RoutingCheckBaseline(Board,Directory);
        for I:=1 to Count do
        begin
            ActiveBoard:=PCBServer.GetCurrentPCBBoard;
            if ActiveBoard=nil then RoutingFail('Activate the exact requested PCB before applying a batch.');
            if UpperCase(ActiveBoard.FileName)<>UpperCase(Board.FileName) then RoutingFail('Active PCB changed.');
            if Targets[I]<>nil then
                if (RoutingNet(Targets[I])<>Nets[I]) or (RoutingGeometry(Targets[I])<>OldGeometry[I]) then RoutingFail('Target changed during batch.');
            RoutingStatus(Directory,RequestID,'applying_partial_changes_possible',I,Completed);
            Audit[I]:=IntToStr(I)+#9+Kinds[I]+#9+Actions[I]+#9+'mutation_attempted';
            Audit.SaveToFile(Directory+'\batch-audit.tsv');
            PCBServer.PreProcess;
            try
                if Actions[I]='remove' then
                begin
                    Board.RemovePCBObject(Targets[I]);
                    PCBServer.SendMessageToRobots(Board.I_ObjectAddress,c_Broadcast,PCBM_BoardRegisteration,Targets[I].I_ObjectAddress);
                    Targets[I]:=nil;
                end
                else if Actions[I]='add' then
                begin
                    Primitive:=Candidates[I]; Board.AddPCBObject(Primitive);
                    PCBServer.SendMessageToRobots(Board.I_ObjectAddress,c_Broadcast,PCBM_BoardRegisteration,Primitive.I_ObjectAddress);
                    Candidates[I]:=nil;
                    if RoutingGeometry(Primitive)<>NewGeometry[I] then RoutingFail('Added primitive readback failed.');
                end
                else
                begin
                    Primitive:=Targets[I];
                    PCBServer.SendMessageToRobots(Primitive.I_ObjectAddress,c_Broadcast,PCBM_BeginModify,c_NoEventData);
                    try RoutingSetGeometry(Primitive,NewGeometry[I]);
                    finally PCBServer.SendMessageToRobots(Primitive.I_ObjectAddress,c_Broadcast,PCBM_EndModify,c_NoEventData); end;
                    if RoutingGeometry(Primitive)<>NewGeometry[I] then RoutingFail('Edited primitive readback failed.');
                end;
            finally PCBServer.PostProcess; end;
            Inc(Completed);
            Audit[I]:=IntToStr(I)+#9+Kinds[I]+#9+Actions[I]+#9+'readback_pending_exact_batch_comparison';
            Audit.SaveToFile(Directory+'\batch-audit.tsv');
        end;
        RoutingExport(Board,Directory,SnapshotID);
        RoutingStatus(Directory,RequestID,'complete_native_drc_not_checked',Count,Completed);
        Client.SendMessage('PCB:Zoom','Action=Redraw',255,Client.CurrentView);
        Result:='{"applied":true,"completed_rows":'+IntToStr(Completed)+',"native_drc_checked":false,"saved":false}';
    finally
        { Factory objects never added to the board are released exactly once. }
        for I:=1 to Count do if Candidates[I]<>nil then PCBServer.DestroyPCBObject(Candidates[I]);
        Audit.Free; Values.Free; Fields.Free; Lines.Free;
    end;
end;

function RoutingPolygonOutline(Board : IPCB_Board; Directory, SnapshotID, RequestID : String; var Completed : Integer) : String;
var Lines, Fields, Vertices : TStringList; Iterator : IPCB_BoardIterator;
    Polygon, Target : IPCB_Polygon; Net : IPCB_Net; Segment : TPolySegment;
    I, Matches, LayerID : Integer; Name, OldDefinition, Action : String;
begin
    Lines:=TStringList.Create; Fields:=TStringList.Create; Vertices:=TStringList.Create; Target:=nil;
    try
        RoutingCheckBaseline(Board,Directory);
        Lines.LoadFromFile(Directory+'\polygon.tsv');
        if (Lines.Count<5) or (Lines.Count>258) then RoutingFail('Polygon requires header, settings, and 3-256 vertices.');
        RoutingSplit(Lines[1],#9,Fields);
        if Fields.Count<>5 then RoutingFail('Polygon settings require five fields.');
        Action:=Fields[0]; Name:=Fields[1]; Net:=RoutingFindNet(Board,Fields[2]); LayerID:=StrToInt(Fields[3]); OldDefinition:=Fields[4];
        if (Action<>'add') and (Action<>'edit') then RoutingFail('Unsupported polygon action.');
        Matches:=0; Iterator:=Board.BoardIterator_Create;
        try
            Iterator.AddFilter_ObjectSet(MkSet(ePolyObject)); Iterator.AddFilter_LayerSet(AllLayers); Iterator.AddFilter_Method(eProcessAll);
            Polygon:=Iterator.FirstPCBObject;
            while Polygon<>nil do
            begin
                if Polygon.Name=Name then begin Target:=Polygon; Inc(Matches); end;
                Polygon:=Iterator.NextPCBObject;
            end;
        finally Board.BoardIterator_Destroy(Iterator); end;
        if (Action='add') and (Matches<>0) then RoutingFail('Polygon name already exists.');
        if Action='edit' then
        begin
            if Matches<>1 then RoutingFail('Polygon name must resolve exactly once.');
            if (RoutingPolygonDefinition(Target)<>OldDefinition) or (Target.Layer<>LayerID) or (RoutingNet(Target)<>Net.Name) then RoutingFail('Polygon target changed.');
        end;
        for I:=2 to Lines.Count-1 do
        begin
            RoutingSplit(Lines[I],#9,Fields);
            if Fields.Count<>2 then RoutingFail('Vertex requires two integers.');
            StrToInt(Fields[0]); StrToInt(Fields[1]); Vertices.Add(Lines[I]);
        end;
        RoutingRequireActive(Board);
        RoutingStatus(Directory,RequestID,'polygon_mutation_attempted',1,Completed);
        PCBServer.PreProcess;
        try
            if Action='add' then
            begin
                Target:=PCBServer.PCBObjectFactory(ePolyObject,eNoDimension,eCreate_Default);
                if Target=nil then RoutingFail('Polygon factory failed.');
                Target.Name:=Name; Target.Net:=Net; Target.Layer:=LayerID;
                Target.SetState_PolygonType(eSignalLayerPolygon); Target.SetState_PolyHatchStyle(ePolySolid);
                Target.SetState_PourOver(ePolygonPourOver_SameNet); Target.SetState_RemoveDead(True);
            end
            else PCBServer.SendMessageToRobots(Target.I_ObjectAddress,c_Broadcast,PCBM_BeginModify,c_NoEventData);
            try
                Target.SetState_PointCount(Vertices.Count);
                Segment:=Target.Segments[0]; Segment.Kind:=ePolySegmentLine;
                Segment.cx:=0; Segment.cy:=0; Segment.Radius:=0; Segment.Angle1:=0; Segment.Angle2:=0;
                for I:=0 to Vertices.Count-1 do
                begin
                    RoutingSplit(Vertices[I],#9,Fields);
                    Segment.vx:=StrToInt(Fields[0]); Segment.vy:=StrToInt(Fields[1]);
                    Target.SetState_Segments(I,Segment);
                end;
            finally
                if Action='edit' then PCBServer.SendMessageToRobots(Target.I_ObjectAddress,c_Broadcast,PCBM_EndModify,c_NoEventData);
            end;
            if Action='add' then
            begin
                Board.AddPCBObject(Target);
                PCBServer.SendMessageToRobots(Board.I_ObjectAddress,c_Broadcast,PCBM_BoardRegisteration,Target.I_ObjectAddress);
            end;
        finally PCBServer.PostProcess; end;
        Completed:=1; RoutingExport(Board,Directory,SnapshotID);
        RoutingStatus(Directory,RequestID,'complete_repour_and_native_drc_required',1,Completed);
        Result:='{"applied":true,"polygon_definition":'+RoutingQuote(RoutingPolygonDefinition(Target))+',"repour_required":true,"saved":false}';
    finally Vertices.Free; Fields.Free; Lines.Free; end;
end;

function ExecutePCBRouting : String;
var Board, ActiveBoard : IPCB_Board; Operation, Directory, SnapshotID, RequestID : String;
    Completed : Integer;
begin
    Operation:=Params.Values['operation']; Directory:=Params.Values['operation_directory'];
    SnapshotID:=Params.Values['snapshot_id']; RequestID:=Params.Values['request_id'];
    if not DirectoryExists(Directory) then begin Result:='ERROR: Operation directory does not exist.'; Exit; end;
    Completed:=0; RoutingFailure:='';
    try
        Board:=RoutingBoard(Params.Values['expected_board']);
        RoutingStatus(Directory,RequestID,'started',0,0);
        if Operation='snapshot' then
        begin
            RoutingExport(Board,Directory,SnapshotID);
            Result:='{"exported":true,"snapshot_id":'+RoutingQuote(SnapshotID)+'}';
        end
        else if Operation='rules' then
        begin
            RoutingCheckBaseline(Board,Directory);
            Result:=RoutingRules(Board,Directory);
        end
        else if Operation='select' then
        begin
            RoutingCheckBaseline(Board,Directory);
            Result:=RoutingSelect(Board,Directory,Params.Values['zoom']='true');
        end
        else if Operation='batch' then Result:=RoutingBatch(Board,Directory,SnapshotID,RequestID,Completed)
        else if Operation='polygon' then Result:=RoutingPolygonOutline(Board,Directory,SnapshotID,RequestID,Completed)
        else if Operation='repour' then
        begin
            RoutingCheckBaseline(Board,Directory);
            ActiveBoard:=PCBServer.GetCurrentPCBBoard;
            if ActiveBoard=nil then RoutingFail('Activate the exact PCB before repouring.');
            if UpperCase(ActiveBoard.FileName)<>UpperCase(Board.FileName) then RoutingFail('Wrong active PCB for repour.');
            RoutingStatus(Directory,RequestID,'repour_requested',0,0);
            Client.SendMessage('PCB:ChangeObject','ContextObject=Polygon|Action=RepourAllPolygons',255,Client.CurrentView);
            RoutingExport(Board,Directory,SnapshotID);
            RoutingStatus(Directory,RequestID,'complete_native_drc_not_checked',0,0);
            Result:='{"repour_requested":true,"native_drc_checked":false,"saved":false}';
        end
        else RoutingFail('Unsupported routing operation.');
        if (Operation='snapshot') or (Operation='rules') or (Operation='select') then RoutingStatus(Directory,RequestID,'complete',0,0);
    except
        if RoutingFailure='' then RoutingFailure:='Native API or file call failed; inspect operation status and exact PCB before retry.';
        RoutingStatus(Directory,RequestID,'failed_inspect_artifacts_before_retry',0,Completed);
        Result:='ERROR: '+RoutingFailure;
    end;
end;
