{ Generalized inventory and explicit geometry tools. Never saves a document.
  Portions adapted from Quilter routing scripts, MIT, copyright 2026 Allegro
  Labs, Inc. See LICENSES/Quilter-MIT.txt. No experiment net/coordinate policy.
  Native operations pass replies through var output parameters all the way to
  Run. AD 26.11.1 corrupted nested function Result values around selection;
  keep these operations outside the String-returning ExecuteCommand path. }

var
    RoutingFailure : String;

procedure RoutingFail(ErrorText : String);
begin
    if RoutingFailure = '' then RoutingFailure := ErrorText;
end;

function RoutingQuote(Value : String) : String;
begin
    Result := '"' + JSONEscapeString(Value) + '"';
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

function RoutingBoard(ExpectedPath : String) : IPCB_Board;
begin
    Result := PCBServer.GetCurrentPCBBoard;
    if Result = nil then begin RoutingFail('Activate the exact requested PCB first.'); Exit; end;
    if UpperCase(Result.FileName) <> UpperCase(ExpectedPath) then
        RoutingFail('Activate the exact requested PCB first. PCB full-path mismatch.');
end;

procedure RoutingRequireActive(Board : IPCB_Board);
var Active : IPCB_Board; ActiveView : IServerDocumentView; ActiveDocument : IServerDocument;
begin
    Active:=PCBServer.GetCurrentPCBBoard;
    if Active=nil then begin RoutingFail('Activate the exact requested PCB first.'); Exit; end;
    if UpperCase(Active.FileName)<>UpperCase(Board.FileName) then begin RoutingFail('The requested PCB must be active.'); Exit; end;
    ActiveView:=Client.CurrentView;
    if ActiveView=nil then begin RoutingFail('The exact PCB must have an active document view.'); Exit; end;
    ActiveDocument:=ActiveView.GetOwnerDocument;
    if ActiveDocument=nil then begin RoutingFail('The active view has no PCB document.'); Exit; end;
    if UpperCase(ActiveDocument.FileName)<>UpperCase(Board.FileName) then
    begin RoutingFail('The active document view must belong to the exact requested PCB.'); Exit; end;
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

function RoutingTrackGeometry(X1, Y1, X2, Y2, Width, LayerID : Integer) : String;
var T : Integer;
begin
    if (X1 > X2) or ((X1 = X2) and (Y1 > Y2)) then
    begin
        T := X1; X1 := X2; X2 := T; T := Y1; Y1 := Y2; Y2 := T;
    end;
    Result := Format('%d,%d,%d,%d,%d,%d',[X1,Y1,X2,Y2,Width,LayerID]);
end;

function RoutingGeometry(Primitive : IPCB_Primitive) : String;
var Track : IPCB_Track; Via : IPCB_Via; Pad : IPCB_Pad; Arc : IPCB_Arc;
begin
    Result := '';
    case Primitive.ObjectId of
        eTrackObject:
        begin
            Track := Primitive;
            Result := RoutingTrackGeometry(Track.X1,Track.Y1,Track.X2,Track.Y2,Track.Width,Track.Layer);
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

procedure RoutingSignalContext(Board : IPCB_Board; Summary, Signature : TStringList);
var Iterator : IPCB_BoardIterator; PairItem : IPCB_DifferentialPair;
    Net : IPCB_Net; Pairs : TStringList; PositiveName, NegativeName, Outline, PairJSON : String;
    Segment : TPolySegment; I : Integer;
begin
    Outline:='';
    for I:=0 to Board.BoardOutline.PointCount-1 do
    begin
        Segment:=Board.BoardOutline.Segments[I];
        if I>0 then Outline:=Outline+';';
        Outline:=Outline+IntToStr(Segment.Kind)+','+IntToStr(Segment.vx)+','+IntToStr(Segment.vy)+','+
            IntToStr(Segment.cx)+','+IntToStr(Segment.cy)+','+IntToStr(Segment.Radius)+','+
            RoutingFloat(Segment.Angle1)+','+RoutingFloat(Segment.Angle2);
    end;
    Pairs:=TStringList.Create;
    Iterator:=Board.BoardIterator_Create;
    try
        Iterator.AddFilter_ObjectSet(MkSet(eDifferentialPairObject));
        Iterator.AddFilter_LayerSet(AllLayers);
        Iterator.AddFilter_Method(eProcessAll);
        PairItem:=Iterator.FirstPCBObject;
        while PairItem<>nil do
        begin
            PositiveName:=''; NegativeName:='';
            Net:=PairItem.PositiveNet; if Net<>nil then PositiveName:=Net.Name;
            Net:=PairItem.NegativeNet; if Net<>nil then NegativeName:=Net.Name;
            Pairs.Add('["'+JSONEscapeString(PairItem.Name)+'","'+JSONEscapeString(PositiveName)+'","'+
                JSONEscapeString(NegativeName)+'"]');
            PairItem:=Iterator.NextPCBObject;
        end;
        Pairs.Sort;
        PairJSON:='[';
        for I:=0 to Pairs.Count-1 do
        begin
            if I>0 then PairJSON:=PairJSON+',';
            PairJSON:=PairJSON+Pairs[I];
        end;
        PairJSON:=PairJSON+']';
    finally
        Board.BoardIterator_Destroy(Iterator);
        Pairs.Free;
    end;
    PairJSON:=JSONEscapeString(PairJSON);
    if Summary<>nil then
    begin
        Summary.Add('outline_raw'+#9+Outline);
        Summary.Add('differential_pairs_json'+#9+PairJSON);
    end;
    Signature.Add('routing-context-v1');
    Signature.Add('routing-outline'+#9+Outline);
    Signature.Add('routing-pairs'+#9+PairJSON);
end;

function RoutingBatchKey(Kind, NetName, Geometry : String) : String;
begin
    Result:=Kind+#9+NetName+#9+Geometry;
end;

procedure RoutingRecordBatchMatch(Keys, Hits : TStringList; Found : TInterfaceList;
                                  Primitive : IPCB_Primitive; Kind, Name, Geometry : String);
var Key : String; Slot : Integer;
begin
    Key:=RoutingBatchKey(Kind,Name,Geometry);
    Slot:=Keys.IndexOf(Key);
    if Slot<0 then Exit;
    if Keys[Slot]<>Key then Exit;
    if Hits[Slot]='-1' then
    begin
        Hits[Slot]:=IntToStr(Found.Count);
        Found.Add(Primitive);
    end
    else Hits[Slot]:='-2';
end;

function RoutingEncodedText(Value : String; Keys, Encoded : TStringList) : String;
var Slot : Integer;
begin
    Result:='';
    if Value='' then Exit;
    Slot:=Keys.IndexOf(Value);
    if Slot>=0 then
    begin
        { TStringList lookup uses the locale. Only reuse an exact match. }
        if Keys[Slot]=Value then Result:=Encoded[Slot]
        else Result:=JSONEscapeString(Value);
        Exit;
    end;
    Result:=JSONEscapeString(Value);
    { Bound the per-pass cache on boards with many distinct strings. }
    if Keys.Count<256 then
    begin
        Slot:=Keys.Add(Value);
        Encoded.Insert(Slot,Result);
    end;
end;

function RoutingEncodedLayer(LayerID : Integer; Labels : TStringList) : String;
var Key : String;
begin
    Key:=IntToStr(LayerID);
    Result:=Labels.Values[Key];
    if Result='' then
    begin
        Result:=JSONEscapeString(Layer2String(LayerID));
        Labels.Values[Key]:=Result;
    end;
end;

procedure RoutingCollect(Board : IPCB_Board; Signature : TStringList; Directory, SnapshotID : String;
                         IndexKeys, IndexHits : TStringList; IndexObjects : TInterfaceList);
var Iterator : IPCB_BoardIterator; Primitive : IPCB_Primitive;
    Net : IPCB_Net; Pad : IPCB_Pad; Track : IPCB_Track; Via : IPCB_Via;
    Connection : IPCB_Connection; Rule : IPCB_Rule; Component : IPCB_Component;
    Arc : IPCB_Arc; Polygon : IPCB_Polygon; Stack : IPCB_LayerStack_V7; LayerObject : IPCB_LayerObject_V7;
    Nets, Pads, Tracks, Vias, Connections, Rules, Components, Layers, Arcs, Polygons, Summary : TStringList;
    TextKeys, EncodedText, LayerLabels : TStringList;
    Row, Refdes, ModeName, CopperDepths, NetName, RawName, Geometry, PadRowFormat, TrackRowFormat, UnassignedKey : String;
    RatsnestCount, RedundantCount, InvalidNetCount, LayerCount, DielectricBelow, XOrigin, YOrigin, UnitsPerMil : Integer;
    LayerID, CopperThickness, PinCount, X1, Y1, X2, Y2, Width, KeySlot : Integer;
    Depth : Double; HasCopperDepths, EmitTables, Invalid, Redundant, BuildIndex, IndexUnassigned : Boolean;
    ObjectSet : TObjectSet;
begin
    { Baseline guards need the same signature, without inventory-only fields
      such as net connectivity, ratsnest objects or primitive selection. }
    EmitTables:=Directory<>'';
    PadRowFormat:='%s'+#9+'%s'+#9+'%s'+#9+'%d'+#9+'%d'+#9+'%d'+#9+'%s'+#9+'%s'+#9+'%d'+#9+'%d'+#9+'%d';
    BuildIndex:=IndexKeys<>nil;
    IndexUnassigned:=False;
    if BuildIndex then
    begin
        UnassignedKey:=RoutingBatchKey('net','','');
        KeySlot:=IndexKeys.IndexOf(UnassignedKey);
        if KeySlot>=0 then IndexUnassigned:=IndexKeys[KeySlot]=UnassignedKey;
    end;
    TextKeys:=TStringList.Create; EncodedText:=TStringList.Create; LayerLabels:=TStringList.Create;
    TextKeys.CaseSensitive:=True; TextKeys.Sorted:=True;
    Summary:=nil;
    if EmitTables then
    begin
        TrackRowFormat:='%s'+#9+'%d'+#9+'%d'+#9+'%d'+#9+'%d'+#9+'%d'+#9+'%d'+#9+'%s'+#9+'%s';
        Nets:=TStringList.Create; Pads:=TStringList.Create; Tracks:=TStringList.Create; Vias:=TStringList.Create;
        Connections:=TStringList.Create; Rules:=TStringList.Create; Components:=TStringList.Create;
        Layers:=TStringList.Create; Arcs:=TStringList.Create; Polygons:=TStringList.Create; Summary:=TStringList.Create;
    end;
    try
        if EmitTables then
        begin
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
        end;
        XOrigin:=Board.XOrigin; YOrigin:=Board.YOrigin; UnitsPerMil:=MilsToCoord(1);
        Signature.Clear;
        Signature.Add('board'+#9+JSONEscapeString(UpperCase(Board.FileName))+#9+IntToStr(XOrigin)+#9+IntToStr(YOrigin)+#9+IntToStr(UnitsPerMil));
        ObjectSet:=MkSet(eNetObject,ePadObject,eTrackObject,eViaObject,eRuleObject,eComponentObject,eArcObject,ePolyObject);
        if EmitTables then ObjectSet:=SetUnion(ObjectSet,MkSet(eConnectionObject));
        Iterator:=Board.BoardIterator_Create;
        try
            Iterator.AddFilter_ObjectSet(ObjectSet);
            Iterator.AddFilter_LayerSet(AllLayers);
            Iterator.AddFilter_Method(eProcessAll);
            Primitive:=Iterator.FirstPCBObject;
            while Primitive<>nil do
            begin
                case Primitive.ObjectId of
                    eNetObject:
                    begin
                        Net:=Primitive;
                        RawName:=Net.Name; PinCount:=Net.PinCount;
                        NetName:=RoutingEncodedText(RawName,TextKeys,EncodedText);
                        if BuildIndex then
                            RoutingRecordBatchMatch(IndexKeys,IndexHits,IndexObjects,Net,'net',RawName,'');
                        if EmitTables then
                        begin
                            Invalid:=Net.ConnectivelyInvalid;
                            Nets.Add(NetName+#9+IntToStr(PinCount)+#9+IntToStr(Net.ViaCount)+#9+IntToStr(Net.RoutedLength)+#9+
                                RoutingBool(Invalid)+#9+RoutingBool(Net.ConnectsVisible));
                            if Invalid then Inc(InvalidNetCount);
                        end;
                        Signature.Add('net'+#9+NetName+#9+IntToStr(PinCount));
                    end;
                    ePadObject:
                    begin
                        Pad:=Primitive; Refdes:='';
                        Component:=Pad.Component;
                        if Component<>nil then Refdes:=Component.Name.Text;
                        LayerID:=Pad.Layer;
                        Net:=Pad.Net; NetName:='';
                        if Net<>nil then NetName:=RoutingEncodedText(Net.Name,TextKeys,EncodedText);
                        Row:=Format(PadRowFormat,[
                            RoutingEncodedText(Refdes,TextKeys,EncodedText),RoutingEncodedText(Pad.Name,TextKeys,EncodedText),
                            NetName,Pad.X,Pad.Y,LayerID,RoutingEncodedLayer(LayerID,LayerLabels),
                            RoutingFloat(Pad.Rotation),Pad.TopXSize,Pad.TopYSize,Pad.HoleSize]);
                        if EmitTables then Pads.Add(Row+#9+RoutingBool(Pad.Selected));
                        Signature.Add('pad'+#9+Row);
                    end;
                    eTrackObject:
                    begin
                        Track:=Primitive;
                        Net:=Track.Net; RawName:=''; NetName:='';
                        if Net<>nil then
                        begin
                            RawName:=Net.Name;
                            NetName:=RoutingEncodedText(RawName,TextKeys,EncodedText);
                        end;
                        X1:=Track.X1; Y1:=Track.Y1; X2:=Track.X2; Y2:=Track.Y2;
                        Width:=Track.Width; LayerID:=Track.Layer;
                        if EmitTables then
                            Tracks.Add(Format(TrackRowFormat,[NetName,X1,Y1,X2,Y2,Width,LayerID,
                                RoutingEncodedLayer(LayerID,LayerLabels),RoutingBool(Track.Selected)]));
                        Geometry:=RoutingTrackGeometry(X1,Y1,X2,Y2,Width,LayerID);
                        Signature.Add('track'+#9+NetName+#9+Geometry);
                        if BuildIndex and (IndexUnassigned or (RawName<>'')) then
                            RoutingRecordBatchMatch(IndexKeys,IndexHits,IndexObjects,Track,'track',RawName,Geometry);
                    end;
                    eViaObject:
                    begin
                        Via:=Primitive;
                        RawName:=PCBPrimitiveNetName(Via);
                        NetName:=RoutingEncodedText(RawName,TextKeys,EncodedText);
                        Geometry:=IntToStr(Via.X)+#9+IntToStr(Via.Y)+#9+IntToStr(Via.Size)+#9+IntToStr(Via.HoleSize)+
                            #9+IntToStr(Via.LowLayer)+#9+IntToStr(Via.HighLayer);
                        Row:=NetName+#9+Geometry;
                        if EmitTables then Vias.Add(Row+#9+RoutingBool(Via.Selected));
                        Signature.Add('via'+#9+Row);
                        if BuildIndex then
                            RoutingRecordBatchMatch(IndexKeys,IndexHits,IndexObjects,Via,'via',RawName,
                                StringReplace(Geometry,#9,',',MkSet(rfReplaceAll)));
                    end;
                    eConnectionObject:
                    begin
                        Connection:=Primitive; ModeName:='other';
                        if Connection.Mode=eRatsNestConnection then ModeName:='ratsnest'
                        else if Connection.Mode=eBrokenNetMarker then ModeName:='broken_net_marker';
                        Redundant:=Connection.IsRedundant;
                        NetName:=RoutingEncodedText(PCBPrimitiveNetName(Connection),TextKeys,EncodedText);
                        Connections.Add(NetName+#9+IntToStr(Connection.X1)+#9+IntToStr(Connection.Y1)+#9+
                            IntToStr(Connection.X2)+#9+IntToStr(Connection.Y2)+#9+IntToStr(Connection.Layer1)+#9+
                            IntToStr(Connection.Layer2)+#9+ModeName+#9+RoutingBool(Redundant)+#9+RoutingBool(Connection.Selected));
                        if Redundant then Inc(RedundantCount)
                        else if ModeName='ratsnest' then Inc(RatsnestCount);
                    end;
                    eRuleObject:
                    begin
                        Rule:=Primitive;
                        Row:=JSONEscapeString(Rule.Name)+#9+IntToStr(Rule.RuleKind)+#9+IntToStr(Rule.Priority)+
                            #9+RoutingBool(Rule.DRCEnabled)+#9+RoutingEncodedText(Rule.Scope1Expression,TextKeys,EncodedText)+
                            #9+RoutingEncodedText(Rule.Scope2Expression,TextKeys,EncodedText)+#9+
                            JSONEscapeString(Rule.GetState_DataSummaryString);
                        if EmitTables then Rules.Add(Row);
                        Signature.Add('rule'+#9+Row);
                    end;
                    eComponentObject:
                    begin
                        Component:=Primitive;
                        LayerID:=Component.Layer;
                        Row:=RoutingEncodedText(Component.Name.Text,TextKeys,EncodedText)+#9+
                            RoutingEncodedText(Component.Comment.Text,TextKeys,EncodedText)+#9+
                            RoutingEncodedText(Component.Pattern,TextKeys,EncodedText)+#9+IntToStr(Component.X)+#9+IntToStr(Component.Y)+#9+
                            RoutingFloat(Component.Rotation)+#9+IntToStr(LayerID)+#9+RoutingEncodedLayer(LayerID,LayerLabels);
                        if EmitTables then Components.Add(Row);
                        Signature.Add('component'+#9+Row);
                    end;
                    eArcObject:
                    begin
                        Arc:=Primitive;
                        NetName:=RoutingEncodedText(PCBPrimitiveNetName(Arc),TextKeys,EncodedText);
                        Row:=NetName+#9+IntToStr(Arc.XCenter)+#9+IntToStr(Arc.YCenter)+#9+IntToStr(Arc.Radius)+#9+
                            RoutingFloat(Arc.StartAngle)+#9+RoutingFloat(Arc.EndAngle)+#9+IntToStr(Arc.LineWidth)+#9+IntToStr(Arc.Layer);
                        if EmitTables then Arcs.Add(Row+#9+RoutingBool(Arc.Selected));
                        Signature.Add('arc'+#9+Row);
                    end;
                    ePolyObject:
                    begin
                        Polygon:=Primitive;
                        NetName:=RoutingEncodedText(PCBPrimitiveNetName(Polygon),TextKeys,EncodedText);
                        Row:=JSONEscapeString(Polygon.Name)+#9+NetName+#9+IntToStr(Polygon.Layer)+#9+
                            JSONEscapeString(RoutingPolygonDefinition(Polygon));
                        if EmitTables then Polygons.Add(Row);
                        Signature.Add('polygon'+#9+Row);
                    end;
                end;
                Primitive:=Iterator.NextPCBObject;
            end;
        finally
            Board.BoardIterator_Destroy(Iterator);
        end;
        Stack:=Board.LayerStack_V7;
        if Stack=nil then begin RoutingFail('PCB has no V7 layer stack.'); Exit; end;
        LayerCount:=0; Depth:=0; DielectricBelow:=0; HasCopperDepths:=True;
        CopperDepths:=''; LayerObject:=Stack.FirstLayer;
        while LayerObject<>nil do
        begin
            Inc(LayerCount);
            if LayerCount>64 then begin RoutingFail('Layer stack iteration exceeded 64 entries.'); Exit; end;
            if (LayerCount>1) and (DielectricBelow<=0) then HasCopperDepths:=False;
            LayerID:=LayerObject.V6_LayerID; CopperThickness:=LayerObject.CopperThickness;
            Row:=IntToStr(LayerCount)+#9+IntToStr(LayerID)+#9+JSONEscapeString(LayerObject.Name)+#9+IntToStr(CopperThickness);
            if EmitTables then Layers.Add(Row);
            Signature.Add('layer'+#9+Row);
            if LayerCount>1 then CopperDepths:=CopperDepths+';';
            CopperDepths:=CopperDepths+IntToStr(LayerID)+','+RoutingFloat(Depth+CopperThickness/2.0);
            DielectricBelow:=0;
            if LayerObject.Dielectric.DielectricType<>eNoDielectric then
                DielectricBelow:=LayerObject.Dielectric.DielectricHeight;
            Depth:=Depth+CopperThickness+DielectricBelow;
            LayerObject:=Stack.NextLayer(LayerObject);
        end;
        if not HasCopperDepths then CopperDepths:='';
        Signature.Add('routing-depths'+#9+CopperDepths);
        if EmitTables then
        begin
            Summary.Add('field'+#9+'value');
            Summary.Add('board_file'+#9+JSONEscapeString(Board.FileName));
            Summary.Add('coordinate_units'+#9+'Altium internal units');
            Summary.Add('field_encoding'+#9+'json-string');
            Summary.Add('internal_units_per_mil'+#9+IntToStr(UnitsPerMil));
            Summary.Add('x_origin_raw'+#9+IntToStr(XOrigin)); Summary.Add('y_origin_raw'+#9+IntToStr(YOrigin));
            Summary.Add('net_count'+#9+IntToStr(Nets.Count-1)); Summary.Add('pad_count'+#9+IntToStr(Pads.Count-1));
            Summary.Add('track_segment_count'+#9+IntToStr(Tracks.Count-1)); Summary.Add('via_count'+#9+IntToStr(Vias.Count-1));
            Summary.Add('connection_object_count'+#9+IntToStr(Connections.Count-1)); Summary.Add('rule_count'+#9+IntToStr(Rules.Count-1));
            Summary.Add('nonredundant_ratsnest_connections'+#9+IntToStr(RatsnestCount));
            Summary.Add('redundant_connection_objects'+#9+IntToStr(RedundantCount)); Summary.Add('connectivity_invalid_nets'+#9+IntToStr(InvalidNetCount));
            Summary.Add('components_count'+#9+IntToStr(Components.Count-1)); Summary.Add('layers_count'+#9+IntToStr(Layers.Count-1));
            Summary.Add('arcs_count'+#9+IntToStr(Arcs.Count-1)); Summary.Add('polygons_count'+#9+IntToStr(Polygons.Count-1));
            Summary.Add('copper_depths_raw'+#9+CopperDepths);
        end;
        RoutingSignalContext(Board,Summary,Signature);
        Signature.Sort;
        if not EmitTables then Exit;
        Summary.Add('snapshot_id'+#9+SnapshotID);
        Summary.SaveToFile(Directory+'\board.tsv');
        Nets.SaveToFile(Directory+'\nets.tsv');
        Pads.SaveToFile(Directory+'\pads.tsv');
        Tracks.SaveToFile(Directory+'\tracks.tsv');
        Vias.SaveToFile(Directory+'\vias.tsv');
        Connections.SaveToFile(Directory+'\connections.tsv');
        Rules.SaveToFile(Directory+'\rules.tsv');
        Components.SaveToFile(Directory+'\components.tsv');
        Layers.SaveToFile(Directory+'\layers.tsv');
        Arcs.SaveToFile(Directory+'\arcs.tsv');
        Polygons.SaveToFile(Directory+'\polygons.tsv');
    finally
        LayerLabels.Free; EncodedText.Free; TextKeys.Free;
        if EmitTables then
        begin
            Summary.Free; Polygons.Free; Arcs.Free; Layers.Free; Components.Free; Rules.Free;
            Connections.Free; Vias.Free; Tracks.Free; Pads.Free; Nets.Free;
        end;
    end;
end;

procedure RoutingExport(Board : IPCB_Board; Directory, SnapshotID : String);
var Signature : TStringList;
begin
    Signature:=TStringList.Create;
    try
        RoutingWrite(Directory+'\inventory-status.txt','exporting');
        RoutingCollect(Board,Signature,Directory,SnapshotID,nil,nil,nil); if RoutingFailure<>'' then Exit;
        Signature.SaveToFile(Directory+'\board-signature.txt');
        RoutingWrite(Directory+'\inventory-status.txt','complete');
    finally
        Signature.Free;
    end;
end;

procedure RoutingCheckBaselineIndex(Board : IPCB_Board; Directory : String;
                                    IndexKeys, IndexHits : TStringList; IndexObjects : TInterfaceList);
var Signature, Baseline : TStringList; I : Integer; HasDepths : Boolean;
begin
    Signature:=TStringList.Create; Baseline:=TStringList.Create;
    try
        Baseline.LoadFromFile(Directory+'\baseline-signature.txt');
        if IndexKeys<>nil then
            for I:=0 to IndexKeys.Count-1 do IndexHits.Add('-1');
        RoutingCollect(Board,Signature,'','',IndexKeys,IndexHits,IndexObjects); if RoutingFailure<>'' then Exit;
        HasDepths:=False;
        for I:=0 to Baseline.Count-1 do
            if Pos('routing-depths'+#9,Baseline[I])=1 then HasDepths:=True;
        if not HasDepths then
            for I:=Signature.Count-1 downto 0 do
                if Pos('routing-depths'+#9,Signature[I])=1 then Signature.Delete(I);
        if Baseline.IndexOf('routing-context-v1')<0 then
            for I:=Signature.Count-1 downto 0 do
                if Pos('routing-',Signature[I])=1 then Signature.Delete(I);
        if Baseline.Text<>Signature.Text then begin RoutingFail('PCB changed since baseline snapshot; refresh and replan.'); Exit; end;
    finally
        Baseline.Free; Signature.Free;
    end;
end;

procedure RoutingCheckBaseline(Board : IPCB_Board; Directory : String);
begin
    RoutingCheckBaselineIndex(Board,Directory,nil,nil,nil);
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
            if (RoutingKind(Primitive)=Kind) and (PCBPrimitiveNetName(Primitive)=NetName) and (RoutingGeometry(Primitive)=Geometry) then
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
    if Count<>1 then begin RoutingFail('Net must resolve to exactly one existing PCB net.'); Exit; end;
end;

procedure RoutingSetGeometry(Primitive : IPCB_Primitive; Geometry : String);
var Fields : TStringList; Track : IPCB_Track; Via : IPCB_Via;
begin
    Fields:=TStringList.Create;
    try
        RoutingSplit(Geometry,',',Fields);
        if Fields.Count<>6 then begin RoutingFail('Track/via geometry requires six integer fields.'); Exit; end;
        case Primitive.ObjectId of
            eTrackObject:
            begin
                Track:=Primitive; Track.X1:=StrToInt(Fields[0]); Track.Y1:=StrToInt(Fields[1]);
                Track.X2:=StrToInt(Fields[2]); Track.Y2:=StrToInt(Fields[3]);
                Track.Width:=StrToInt(Fields[4]); Track.Layer:=StrToInt(Fields[5]);
                if (Track.Width<=0) or ((Track.X1=Track.X2) and (Track.Y1=Track.Y2)) then begin RoutingFail('Invalid track dimensions.'); Exit; end;
            end;
            eViaObject:
            begin
                Via:=Primitive; Via.X:=StrToInt(Fields[0]); Via.Y:=StrToInt(Fields[1]);
                Via.Size:=StrToInt(Fields[2]); Via.HoleSize:=StrToInt(Fields[3]);
                Via.LowLayer:=StrToInt(Fields[4]); Via.HighLayer:=StrToInt(Fields[5]);
                if (Via.HoleSize<=0) or (Via.Size<=Via.HoleSize) then begin RoutingFail('Invalid via dimensions.'); Exit; end;
            end;
        else begin RoutingFail('Unsupported geometry kind.'); Exit; end;
        end;
    finally Fields.Free; end;
end;

function RoutingViaOverlapsPadBounds(Via : IPCB_Via; Pad : IPCB_Pad) : Boolean;
var Angle, C, S, DX, DY, U, V, Radius : Double;
begin
    { Conservative rotated top-pad rectangle, including the via's radius.
      Full custom pad stacks remain subject to native DRC. }
    Angle:=Pad.Rotation*0.017453292519943295;
    C:=Cos(Angle); S:=Sin(Angle);
    DX:=1.0*(Via.X-Pad.X); DY:=1.0*(Via.Y-Pad.Y);
    U:=Abs(DX*C+DY*S)-Pad.TopXSize/2.0;
    V:=Abs(-DX*S+DY*C)-Pad.TopYSize/2.0;
    if U<0 then U:=0.0;
    if V<0 then V:=0.0;
    Radius:=Via.Size/2.0;
    Result:=U*U+V*V<=Radius*Radius;
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
                if (Existing.X=Via.X) and (Existing.Y=Via.Y) and not SameTarget then begin RoutingFail('Via center is already occupied.'); Exit; end;
            end
            else
            begin
                Pad:=Primitive;
                if RoutingViaOverlapsPadBounds(Via,Pad) then
                    if not AllowViaInPad or (PCBPrimitiveNetName(Pad)<>PCBPrimitiveNetName(Via)) then begin RoutingFail('Via in pad requires explicit same-net allowance.'); Exit; end;
            end;
            Primitive:=Iterator.NextPCBObject;
        end;
    finally Board.BoardIterator_Destroy(Iterator); end;
end;

procedure RoutingRules(Board : IPCB_Board; Directory : String; var ResponseText : String);
var Lines, Fields, Rows : TStringList; I, Matches, QueryLayer : Integer;
    Primitive : IPCB_Primitive; WidthRule : IPCB_MaxMinWidthConstraint; PairRule : IPCB_DifferentialPairsRoutingRule;
    Row, WidthJSON, PairJSON : String;
begin
    ResponseText:='';
    Lines:=TStringList.Create; Fields:=TStringList.Create; Rows:=TStringList.Create;
    try
        Lines.LoadFromFile(Directory+'\selectors.tsv');
        for I:=1 to Lines.Count-1 do
        begin
            RoutingSplit(Lines[I],#9,Fields);
            if Fields.Count<>4 then begin RoutingFail('Rule selector requires four columns.'); Exit; end;
            Primitive:=RoutingFind(Board,Fields[0],Fields[1],Fields[2],Matches);
            if Matches<>1 then begin RoutingFail('Rule query must identify exactly one existing primitive.'); Exit; end;
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
                    ',"maximum_gap_raw":'+IntToStr(PairRule.GetState_MaxGap(QueryLayer))+
                    ',"minimum_width_raw":'+IntToStr(PairRule.GetState_MinWidth(QueryLayer))+
                    ',"preferred_width_raw":'+IntToStr(PairRule.GetState_PreferedWidth(QueryLayer))+
                    ',"maximum_width_raw":'+IntToStr(PairRule.GetState_MaxWidth(QueryLayer))+'}';
            Row:='{"kind":'+RoutingQuote(Fields[0])+',"net":'+RoutingQuote(Fields[1])+',"geometry":'+RoutingQuote(Fields[2])+
                ',"layer_id":'+IntToStr(QueryLayer)+',"width_rule":'+WidthJSON+',"differential_rule":'+PairJSON+'}';
            Rows.Add(Row);
        end;
        ResponseText:='{"objects":'+BuildJSONArray(Rows)+',"scope":"existing_object_on_requested_layer","prospective_geometry_qualified":false}';
    finally Rows.Free; Fields.Free; Lines.Free; end;
end;

procedure RoutingSelect(Board : IPCB_Board; Directory : String; Zoom : Boolean; var ResponseText : String);
var Lines, Fields, MatchesList : TStringList; Iterator : IPCB_BoardIterator;
    Primitive : IPCB_Primitive; Kinds, Nets, Geometries : array[1..256] of String;
    RequestedNet : IPCB_Net;
    I, Count, SelectedCount : Integer; Wanted : Boolean;
begin
    ResponseText:='';
    Lines:=TStringList.Create; Fields:=TStringList.Create; MatchesList:=TStringList.Create;
    try
        Lines.LoadFromFile(Directory+'\selectors.tsv'); Count:=Lines.Count-1;
        if (Count<1) or (Count>256) then begin RoutingFail('Selection requires 1-256 selectors.'); Exit; end;
        for I:=1 to Count do
        begin
            RoutingSplit(Lines[I],#9,Fields);
            if Fields.Count<>4 then begin RoutingFail('Selection requires four columns.'); Exit; end;
            Kinds[I]:=Fields[0]; Nets[I]:=Fields[1]; Geometries[I]:=Fields[2];
            RequestedNet:=RoutingFindNet(Board,Nets[I]); if RoutingFailure<>'' then Exit; MatchesList.Add('0');
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
                    if ((Kinds[I]='all') or (Kinds[I]=RoutingKind(Primitive))) and (PCBPrimitiveNetName(Primitive)=Nets[I]) then
                        if (Geometries[I]='') or (Geometries[I]=RoutingGeometry(Primitive)) then
                            MatchesList[I-1]:=IntToStr(StrToInt(MatchesList[I-1])+1);
                Primitive:=Iterator.NextPCBObject;
            end;
        finally Board.BoardIterator_Destroy(Iterator); end;
        for I:=0 to Count-1 do if MatchesList[I]='0' then begin RoutingFail('A selector matched no primitives; selection preserved.'); Exit; end;
        RoutingRequireActive(Board); if RoutingFailure<>'' then Exit;
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
                    if ((Kinds[I]='all') or (Kinds[I]=RoutingKind(Primitive))) and (PCBPrimitiveNetName(Primitive)=Nets[I]) then
                        if (Geometries[I]='') or (Geometries[I]=RoutingGeometry(Primitive)) then Wanted:=True;
                Primitive.Selected:=Wanted;
                if Wanted then Inc(SelectedCount);
                Primitive:=Iterator.NextPCBObject;
            end;
        finally Board.BoardIterator_Destroy(Iterator); end;
        if Zoom then Client.SendMessage('PCB:Zoom','Action=Selected',255,Client.CurrentView)
        else Client.SendMessage('PCB:Zoom','Action=Redraw',255,Client.CurrentView);
        ResponseText:='{"selected_count":'+IntToStr(SelectedCount)+',"saved":false}';
    finally MatchesList.Free; Fields.Free; Lines.Free; end;
end;

function RoutingIndexedMatch(Keys, Hits : TStringList; Found : TInterfaceList;
                             Key : String; var Matches : Integer) : IPCB_Primitive;
var Slot, Entry : Integer;
begin
    Result:=nil; Matches:=0;
    Slot:=Keys.IndexOf(Key);
    if Slot<0 then Exit;
    if Keys[Slot]<>Key then Exit;
    Entry:=StrToInt(Hits[Slot]);
    if Entry=-2 then Matches:=2
    else if Entry>=0 then
    begin
        Matches:=1; Result:=Found.Items[Entry];
    end;
end;

procedure RoutingBatch(Board : IPCB_Board; Directory, SnapshotID, RequestID : String; var Completed : Integer; var ResponseText : String);
var Lines, Fields, Values, Audit, IndexKeys, IndexHits : TStringList; IndexObjects : TInterfaceList;
    I, J, Count, Matches, MinimumWidth, MaximumWidth, UndoSteps : Integer;
    Kinds, Actions, Nets, OldGeometry, NewGeometry : array[1..256] of String;
    Targets, Candidates : array[1..256] of IPCB_Primitive;
    TargetNets : array[1..256] of IPCB_Net;
    Primitive, Existing : IPCB_Primitive; Track : IPCB_Track; Via : IPCB_Via;
    WidthRule : IPCB_MaxMinWidthConstraint; PairRule : IPCB_DifferentialPairsRoutingRule;
    AllowViaInPad, GroupUndo, UndoOpen : Boolean;
begin
    ResponseText:='';
    Lines:=TStringList.Create; Fields:=TStringList.Create; Values:=TStringList.Create; Audit:=TStringList.Create;
    IndexKeys:=TStringList.Create; IndexHits:=TStringList.Create; IndexObjects:=TInterfaceList.Create;
    IndexKeys.CaseSensitive:=True; IndexKeys.Sorted:=True; IndexKeys.Duplicates:=dupIgnore;
    Count:=0; Completed:=0;
    AllowViaInPad:=Params.Values['allow_via_in_pad']='true';
    GroupUndo:=Params.Values['undo_group']='true'; UndoOpen:=False; UndoSteps:=0;
    for I:=1 to 256 do begin Targets[I]:=nil; Candidates[I]:=nil; end;
    try
        Lines.LoadFromFile(Directory+'\operations.tsv'); Count:=Lines.Count-1;
        if (Count<1) or (Count>256) then begin RoutingFail('Batch requires 1-256 rows.'); Exit; end;
        if Lines[0]<>'kind'+#9+'action'+#9+'net'+#9+'old_geometry'+#9+'new_geometry' then begin RoutingFail('Invalid batch header.'); Exit; end;
        Audit.Add('row'+#9+'kind'+#9+'action'+#9+'result');
        for I:=1 to Count do
        begin
            RoutingStatus(Directory,RequestID,'preflight',I,Completed);
            RoutingSplit(Lines[I],#9,Fields);
            if Fields.Count<>5 then begin RoutingFail('Batch row requires five columns.'); Exit; end;
            Kinds[I]:=Fields[0]; Actions[I]:=Fields[1]; Nets[I]:=Fields[2];
            OldGeometry[I]:=Fields[3]; NewGeometry[I]:=Fields[4];
            if (Kinds[I]<>'track') and (Kinds[I]<>'via') then begin RoutingFail('Unsupported batch primitive.'); Exit; end;
            if (Actions[I]<>'add') and (Actions[I]<>'edit') and (Actions[I]<>'remove') then begin RoutingFail('Unsupported batch action.'); Exit; end;
            IndexKeys.Add(RoutingBatchKey('net',Nets[I],''));
            if Actions[I]<>'add' then IndexKeys.Add(RoutingBatchKey(Kinds[I],Nets[I],OldGeometry[I]))
            else if OldGeometry[I]<>'-' then begin RoutingFail('Add must omit old geometry.'); Exit; end;
            if Actions[I]<>'remove' then IndexKeys.Add(RoutingBatchKey(Kinds[I],Nets[I],NewGeometry[I]))
            else if NewGeometry[I]<>'-' then begin RoutingFail('Remove must omit new geometry.'); Exit; end;
        end;
        { Build target matches during the first exact baseline pass. }
        RoutingCheckBaselineIndex(Board,Directory,IndexKeys,IndexHits,IndexObjects);
        if RoutingFailure<>'' then Exit;
        for I:=1 to Count do
        begin
            RoutingStatus(Directory,RequestID,'preflight',I,Completed);
            TargetNets[I]:=nil;
            if Nets[I]<>'' then
            begin
                TargetNets[I]:=RoutingIndexedMatch(IndexKeys,IndexHits,IndexObjects,
                    RoutingBatchKey('net',Nets[I],''),Matches);
                if Matches<>1 then begin RoutingFail('Net must resolve to exactly one existing PCB net.'); Exit; end;
            end;
            if (Actions[I]='add') and (TargetNets[I]=nil) then begin RoutingFail('New copper requires an assigned net.'); Exit; end;
            if Actions[I]<>'add' then
            begin
                Targets[I]:=RoutingIndexedMatch(IndexKeys,IndexHits,IndexObjects,
                    RoutingBatchKey(Kinds[I],Nets[I],OldGeometry[I]),Matches);
                if Matches<>1 then begin RoutingFail('Old target does not resolve exactly once.'); Exit; end;
                for J:=1 to I-1 do
                    if Targets[J]<>nil then
                        if Targets[J].I_ObjectAddress=Targets[I].I_ObjectAddress then begin RoutingFail('Repeated old target.'); Exit; end;
            end;
            if Actions[I]<>'remove' then
            begin
                if Kinds[I]='track' then Candidates[I]:=PCBServer.PCBObjectFactory(eTrackObject,eNoDimension,eCreate_Default)
                else Candidates[I]:=PCBServer.PCBObjectFactory(eViaObject,eNoDimension,eCreate_Default);
                if Candidates[I]=nil then begin RoutingFail('Primitive factory failed.'); Exit; end;
                Candidates[I].Net:=TargetNets[I]; RoutingSetGeometry(Candidates[I],NewGeometry[I]); if RoutingFailure<>'' then Exit;
                if RoutingGeometry(Candidates[I])<>NewGeometry[I] then begin RoutingFail('Noncanonical geometry request.'); Exit; end;
                if Kinds[I]='via' then
                begin
                    Via:=Candidates[I];
                    RoutingCheckViaCenter(Board,Candidates[I],Targets[I],AllowViaInPad); if RoutingFailure<>'' then Exit;
                    if Actions[I]='add' then
                        if (Via.LowLayer<>eTopLayer) or (Via.HighLayer<>eBottomLayer) then begin RoutingFail('New vias support through span only.'); Exit; end;
                    if Actions[I]='edit' then
                    begin
                        Via:=Targets[I];
                        RoutingSplit(NewGeometry[I],',',Values);
                        if (Via.LowLayer<>StrToInt(Values[4])) or (Via.HighLayer<>StrToInt(Values[5])) then begin RoutingFail('Via edits must preserve drill span.'); Exit; end;
                    end;
                end;
                Existing:=RoutingIndexedMatch(IndexKeys,IndexHits,IndexObjects,
                    RoutingBatchKey(Kinds[I],Nets[I],NewGeometry[I]),Matches);
                if Matches>0 then
                begin
                    if Targets[I]=nil then begin RoutingFail('Destination already exists.'); Exit; end;
                    if Matches<>1 then begin RoutingFail('Destination is ambiguous.'); Exit; end;
                    if Existing.I_ObjectAddress<>Targets[I].I_ObjectAddress then begin RoutingFail('Destination already exists.'); Exit; end;
                end;
                for J:=1 to I-1 do
                    if (Kinds[J]=Kinds[I]) and (NewGeometry[J]=NewGeometry[I]) then begin RoutingFail('Repeated destination.'); Exit; end;
            end;
            Audit.Add(IntToStr(I)+#9+Kinds[I]+#9+Actions[I]+#9+'preflight_ok');
        end;
        Audit.SaveToFile(Directory+'\batch-audit.tsv');
        { The sole writer rechecks all baseline records immediately before writes. }
        RoutingCheckBaseline(Board,Directory); if RoutingFailure<>'' then Exit;
        for I:=1 to Count do
        begin
            RoutingRequireActive(Board); if RoutingFailure<>'' then Exit;
            if Targets[I]<>nil then
                if (PCBPrimitiveNetName(Targets[I])<>Nets[I]) or (RoutingGeometry(Targets[I])<>OldGeometry[I]) then begin RoutingFail('Target changed during batch.'); Exit; end;
            RoutingStatus(Directory,RequestID,'applying_partial_changes_possible',I,Completed);
            Audit[I]:=IntToStr(I)+#9+Kinds[I]+#9+Actions[I]+#9+'mutation_attempted';
            Audit.SaveToFile(Directory+'\batch-audit.tsv');
            if not UndoOpen then
            begin
                PCBServer.PreProcess;
                UndoOpen:=True;
                Inc(UndoSteps);
            end;
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
                    Candidates[I]:=nil;
                    PCBServer.SendMessageToRobots(Board.I_ObjectAddress,c_Broadcast,PCBM_BoardRegisteration,Primitive.I_ObjectAddress);
                    if RoutingGeometry(Primitive)<>NewGeometry[I] then begin RoutingFail('Added primitive readback failed.'); Exit; end;
                end
                else
                begin
                    Primitive:=Targets[I];
                    PCBServer.SendMessageToRobots(Primitive.I_ObjectAddress,c_Broadcast,PCBM_BeginModify,c_NoEventData);
                    try RoutingSetGeometry(Primitive,NewGeometry[I]); if RoutingFailure<>'' then Exit;
                    finally PCBServer.SendMessageToRobots(Primitive.I_ObjectAddress,c_Broadcast,PCBM_EndModify,c_NoEventData); end;
                    if RoutingGeometry(Primitive)<>NewGeometry[I] then begin RoutingFail('Edited primitive readback failed.'); Exit; end;
                end;
            finally
                if not GroupUndo then
                begin
                    UndoOpen:=False;
                    PCBServer.PostProcess;
                end;
            end;
            { Dominant-rule lookup requires an attached object in AD 26.11.1.
              This is post-write validation: failure leaves the attempted row
              explicitly partial, with its Undo transaction and audit intact. }
            if (Kinds[I]='track') and (Actions[I]<>'remove') then
            begin
                Track:=Primitive;
                if TargetNets[I].InDifferentialPair then
                begin
                    PairRule:=Board.FindDominantRuleForObject(Track,eRule_DifferentialPairsRouting);
                    if PairRule=nil then
                    begin RoutingFail('Attached pair track has no dominant differential routing rule; inspect the attempted row and Undo before retrying.'); Exit; end;
                    MinimumWidth:=PairRule.GetState_MinWidth(Track.Layer);
                    MaximumWidth:=PairRule.GetState_MaxWidth(Track.Layer);
                end
                else
                begin
                    WidthRule:=Board.FindDominantRuleForObject(Track,eRule_MaxMinWidth);
                    if WidthRule=nil then
                    begin RoutingFail('Attached track has no dominant width rule; inspect the attempted row and Undo before retrying.'); Exit; end;
                    MinimumWidth:=WidthRule.MinWidth(Track.Layer);
                    MaximumWidth:=WidthRule.MaxWidth(Track.Layer);
                end;
                if (Track.Width<MinimumWidth) or (Track.Width>MaximumWidth) then
                begin RoutingFail('Applied track width is outside its native dominant rule; inspect the attempted row and Undo before retrying.'); Exit; end;
            end;
            Inc(Completed);
            Audit[I]:=IntToStr(I)+#9+Kinds[I]+#9+Actions[I]+#9+'readback_pending_exact_batch_comparison';
            Audit.SaveToFile(Directory+'\batch-audit.tsv');
        end;
        if UndoOpen then
        begin
            UndoOpen:=False;
            PCBServer.PostProcess;
        end;
        RoutingExport(Board,Directory,SnapshotID); if RoutingFailure<>'' then Exit;
        RoutingStatus(Directory,RequestID,'complete_native_drc_not_checked',Count,Completed);
        Client.SendMessage('PCB:Zoom','Action=Redraw',255,Client.CurrentView);
        ResponseText:='{"applied":true,"completed_rows":'+IntToStr(Completed)+
            ',"undo_steps":'+IntToStr(UndoSteps)+',"native_drc_checked":false,"saved":false}';
    finally
        try
            if UndoOpen then PCBServer.PostProcess;
        finally
            { Factory objects never added to the board are released exactly once. }
            for I:=1 to 256 do if Candidates[I]<>nil then PCBServer.DestroyPCBObject(Candidates[I]);
            IndexObjects.Free; IndexHits.Free; IndexKeys.Free;
            Audit.Free; Values.Free; Fields.Free; Lines.Free;
        end;
    end;
end;

procedure RoutingPolygonOutline(Board : IPCB_Board; Directory, SnapshotID, RequestID : String; var Completed : Integer; var ResponseText : String);
var Lines, Fields, Vertices : TStringList; Iterator : IPCB_BoardIterator;
    Polygon, Target : IPCB_Polygon; Net : IPCB_Net; Segment : TPolySegment;
    I, Matches, LayerID : Integer; Name, OldDefinition, Action : String;
    DetachedTarget : Boolean;
begin
    ResponseText:='';
    Lines:=TStringList.Create; Fields:=TStringList.Create; Vertices:=TStringList.Create; Target:=nil; DetachedTarget:=False;
    try
        RoutingCheckBaseline(Board,Directory); if RoutingFailure<>'' then Exit;
        Lines.LoadFromFile(Directory+'\polygon.tsv');
        if (Lines.Count<5) or (Lines.Count>258) then begin RoutingFail('Polygon requires header, settings, and 3-256 vertices.'); Exit; end;
        RoutingSplit(Lines[1],#9,Fields);
        if Fields.Count<>5 then begin RoutingFail('Polygon settings require five fields.'); Exit; end;
        Action:=Fields[0]; Name:=Fields[1]; Net:=RoutingFindNet(Board,Fields[2]); LayerID:=StrToInt(Fields[3]); OldDefinition:=Fields[4];
        if RoutingFailure<>'' then Exit;
        if (Action<>'add') and (Action<>'edit') then begin RoutingFail('Unsupported polygon action.'); Exit; end;
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
        if (Action='add') and (Matches<>0) then begin RoutingFail('Polygon name already exists.'); Exit; end;
        if Action='edit' then
        begin
            if Matches<>1 then begin RoutingFail('Polygon name must resolve exactly once.'); Exit; end;
            if (RoutingPolygonDefinition(Target)<>OldDefinition) or (Target.Layer<>LayerID) or (PCBPrimitiveNetName(Target)<>Net.Name) then begin RoutingFail('Polygon target changed.'); Exit; end;
        end;
        for I:=2 to Lines.Count-1 do
        begin
            RoutingSplit(Lines[I],#9,Fields);
            if Fields.Count<>2 then begin RoutingFail('Vertex requires two integers.'); Exit; end;
            StrToInt(Fields[0]); StrToInt(Fields[1]); Vertices.Add(Lines[I]);
        end;
        RoutingRequireActive(Board); if RoutingFailure<>'' then Exit;
        RoutingStatus(Directory,RequestID,'polygon_mutation_attempted',1,Completed);
        PCBServer.PreProcess;
        try
            if Action='add' then
            begin
                Target:=PCBServer.PCBObjectFactory(ePolyObject,eNoDimension,eCreate_Default);
                if Target=nil then begin RoutingFail('Polygon factory failed.'); Exit; end;
                DetachedTarget:=True;
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
                Board.AddPCBObject(Target); DetachedTarget:=False;
                PCBServer.SendMessageToRobots(Board.I_ObjectAddress,c_Broadcast,PCBM_BoardRegisteration,Target.I_ObjectAddress);
            end;
        finally PCBServer.PostProcess; end;
        Completed:=1; RoutingExport(Board,Directory,SnapshotID); if RoutingFailure<>'' then Exit;
        RoutingStatus(Directory,RequestID,'complete_repour_and_native_drc_required',1,Completed);
        ResponseText:='{"applied":true,"polygon_definition":'+RoutingQuote(RoutingPolygonDefinition(Target))+',"repour_required":true,"saved":false}';
    finally
        if DetachedTarget then if Target<>nil then PCBServer.DestroyPCBObject(Target);
        Vertices.Free; Fields.Free; Lines.Free;
    end;
end;

procedure RoutingCopperStats(Board : IPCB_Board; Path : String; var PolygonCount, ChildCount, RegionCount : Integer);
var Iterator : IPCB_BoardIterator; Children : IPCB_GroupIterator;
    Polygon : IPCB_Polygon; Primitive : IPCB_Primitive; Rows : TStringList;
    Tracks, Arcs, Regions, Fills : Integer;
begin
    PolygonCount:=0; ChildCount:=0; RegionCount:=0;
    Rows:=TStringList.Create;
    try
        Rows.Add('name'+#9+'net'+#9+'layer_id'+#9+'tracks'+#9+'arcs'+#9+'regions'+#9+'fills');
        Iterator:=Board.BoardIterator_Create;
        try
            Iterator.AddFilter_ObjectSet(MkSet(ePolyObject));
            Iterator.AddFilter_LayerSet(AllLayers); Iterator.AddFilter_Method(eProcessAll);
            Polygon:=Iterator.FirstPCBObject;
            while Polygon<>nil do
            begin
                Inc(PolygonCount); Tracks:=0; Arcs:=0; Regions:=0; Fills:=0;
                Children:=Polygon.GroupIterator_Create;
                try
                    Children.AddFilter_ObjectSet(MkSet(eTrackObject,eArcObject,eRegionObject,eFillObject));
                    Children.AddFilter_LayerSet(AllLayers);
                    Primitive:=Children.FirstPCBObject;
                    while Primitive<>nil do
                    begin
                        Inc(ChildCount);
                        case Primitive.ObjectId of
                            eTrackObject: Inc(Tracks);
                            eArcObject: Inc(Arcs);
                            eRegionObject: begin Inc(Regions); Inc(RegionCount); end;
                            eFillObject: Inc(Fills);
                        end;
                        Primitive:=Children.NextPCBObject;
                    end;
                finally Polygon.GroupIterator_Destroy(Children); end;
                Rows.Add(JSONEscapeString(Polygon.Name)+#9+JSONEscapeString(PCBPrimitiveNetName(Polygon))+#9+IntToStr(Polygon.Layer)+#9+
                    IntToStr(Tracks)+#9+IntToStr(Arcs)+#9+IntToStr(Regions)+#9+IntToStr(Fills));
                Polygon:=Iterator.NextPCBObject;
            end;
        finally Board.BoardIterator_Destroy(Iterator); end;
        Rows.SaveToFile(Path);
    finally Rows.Free; end;
end;

procedure RoutingNativeDRC(Board : IPCB_Board; Directory, RequestID : String; var ResponseText : String);
var Doc : IServerDocument; ReportBase : String; BeforeModified, AfterModified : Boolean;
begin
    RoutingRequireActive(Board); if RoutingFailure<>'' then Exit;
    Doc:=Client.GetDocumentByPath(Board.FileName);
    if Doc=nil then begin RoutingFail('Cannot verify the PCB editor state.'); Exit; end;
    ReportBase:=Directory+'\native-drc';
    if FileExists(ReportBase+'.txt') or FileExists(ReportBase+'.drc') then
    begin RoutingFail('The native DRC output already exists.'); Exit; end;

    BeforeModified:=Doc.GetModified;
    RoutingStatus(Directory,RequestID,'native_drc_running',0,0);
    { Altium writes the compact report with a .txt extension for this call. }
    Board.RunBatchDesignRuleCheck(ReportBase+'.drc',eDRC_Text,False,False);
    AfterModified:=Doc.GetModified;
    if not FileExists(ReportBase+'.txt') then
    begin RoutingFail('Native DRC returned without a compact report.'); Exit; end;
    ResponseText:='{"board_file":'+RoutingQuote(Board.FileName)+
        ',"pcb_modified_before":'+RoutingBool(BeforeModified)+
        ',"pcb_modified_after":'+RoutingBool(AfterModified)+',"saved":false}';
end;

procedure RoutingExecute(Operation, Directory, SnapshotID, RequestID : String; var Completed : Integer; var DispatchText : String);
var Board : IPCB_Board; Steps, UndoIndex, PolygonCount, BeforeChildren, AfterChildren, BeforeRegions, AfterRegions : Integer; WantZoom : Boolean;
begin
    DispatchText:='';
    Board:=RoutingBoard(Params.Values['expected_board']);
    if RoutingFailure<>'' then Exit;
    RoutingStatus(Directory,RequestID,'started',0,0);
    if Operation='snapshot' then
    begin
        RoutingExport(Board,Directory,SnapshotID); if RoutingFailure<>'' then Exit;
        DispatchText:='{"exported":true,"snapshot_id":'+RoutingQuote(SnapshotID)+'}';
    end
    else if Operation='native_drc' then RoutingNativeDRC(Board,Directory,RequestID,DispatchText)
    else if Operation='rules' then
    begin
        RoutingCheckBaseline(Board,Directory); if RoutingFailure<>'' then Exit;
        RoutingRules(Board,Directory,DispatchText);
    end
    else if Operation='select' then
    begin
        RoutingCheckBaseline(Board,Directory); if RoutingFailure<>'' then Exit;
        WantZoom:=Params.Values['zoom']='true';
        RoutingSelect(Board,Directory,WantZoom,DispatchText);
    end
    else if Operation='batch' then
    begin
        RoutingBatch(Board,Directory,SnapshotID,RequestID,Completed,DispatchText);
    end
    else if Operation='polygon' then RoutingPolygonOutline(Board,Directory,SnapshotID,RequestID,Completed,DispatchText)
    else if Operation='undo' then
    begin
        RoutingCheckBaseline(Board,Directory); if RoutingFailure<>'' then Exit;
        Steps:=StrToInt(Params.Values['steps']);
        if (Steps<1) or (Steps>256) then
        begin RoutingFail('Undo requires 1-256 steps.'); Exit; end;
        for UndoIndex:=1 to Steps do
        begin
            RoutingRequireActive(Board); if RoutingFailure<>'' then Exit;
            RoutingStatus(Directory,RequestID,'undo_requested',UndoIndex,Completed);
            ResetParameters;
            RunProcess('PCB:Undo');
            Inc(Completed);
        end;
        RoutingExport(Board,Directory,SnapshotID); if RoutingFailure<>'' then Exit;
        RoutingStatus(Directory,RequestID,'complete_compare_restoration_required',Steps,Completed);
        DispatchText:='{"undo_requested":'+IntToStr(Steps)+',"saved":false}';
    end
    else if Operation='repour' then
    begin
        RoutingCheckBaseline(Board,Directory); if RoutingFailure<>'' then Exit;
        RoutingRequireActive(Board); if RoutingFailure<>'' then Exit;
        RoutingCopperStats(Board,Directory+'\polygon-copper-before.tsv',PolygonCount,BeforeChildren,BeforeRegions);
        RoutingStatus(Directory,RequestID,'repour_requested',0,0);
        Client.SendMessage('PCB:ChangeObject','ContextObject=Polygon|Action=RepourAllPolygons',255,Client.CurrentView);
        RoutingCopperStats(Board,Directory+'\polygon-copper-after.tsv',PolygonCount,AfterChildren,AfterRegions);
        RoutingExport(Board,Directory,SnapshotID); if RoutingFailure<>'' then Exit;
        RoutingStatus(Directory,RequestID,'complete_native_drc_not_checked',0,0);
        DispatchText:='{"repour_requested":true,"native_drc_checked":false,"saved":false,"copper_observations":'+
            '{"polygon_count":'+IntToStr(PolygonCount)+',"before_child_count":'+IntToStr(BeforeChildren)+
            ',"after_child_count":'+IntToStr(AfterChildren)+',"before_region_count":'+IntToStr(BeforeRegions)+
            ',"after_region_count":'+IntToStr(AfterRegions)+'}}';
    end
    else begin RoutingFail('Unsupported routing operation.'); Exit; end;
end;

procedure ExecutePCBRouting(var ReplyText : String);
var Operation, Directory, SnapshotID, RequestID, ResponseText : String;
    Completed : Integer;
begin
    Operation:=Params.Values['operation']; Directory:=Params.Values['operation_directory'];
    SnapshotID:=Params.Values['snapshot_id']; RequestID:=Params.Values['request_id'];
    RoutingFailure:=''; Completed:=0; ResponseText:='';
    if not DirectoryExists(Directory) then
    begin ReplyText:='ERROR: Operation directory does not exist.'; Exit; end;
    try
        RoutingExecute(Operation,Directory,SnapshotID,RequestID,Completed,ResponseText);
    except
        RoutingFail('Native API or file call failed; inspect exact PCB and operation artifacts before retry.');
    end;
    if RoutingFailure='' then
        if Copy(ResponseText,1,1)<>'{' then RoutingFail('Native routing returned an invalid response object.');
    if RoutingFailure<>'' then
    begin
        RoutingStatus(Directory,RequestID,'failed_inspect_artifacts_before_retry',0,Completed);
        ResponseText:='ERROR: '+RoutingFailure;
    end
    else if (Operation='snapshot') or (Operation='native_drc') or (Operation='rules') or (Operation='select') then
        RoutingStatus(Directory,RequestID,'complete',0,Completed);
    ReplyText:=ResponseText;
end;
