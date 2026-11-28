using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using PCB;

namespace AltiumMcpSdk;

internal sealed partial class EditorCommands
{
    private static readonly TObjectId[] RoutingSignatureObjects =
    [TObjectId.eNetObject, TObjectId.ePadObject, TObjectId.eTrackObject, TObjectId.eViaObject,
        TObjectId.eRuleObject, TObjectId.eComponentObject, TObjectId.eArcObject, TObjectId.ePolyObject];

    private static readonly TObjectId[] RoutingInventoryObjects =
        [.. RoutingSignatureObjects, TObjectId.eConnectionObject];

    private static string RoutingFormat(FormattableString value) => value.ToString(CultureInfo.InvariantCulture);

    private static string RoutingUpperCase(string? value) => string.Create(value?.Length ?? 0, value,
        static (destination, source) =>
        {
            for (int index = 0; index < destination.Length; index++)
            {
                char character = source![index];
                destination[index] = character is >= 'a' and <= 'z' ? (char)(character - ('a' - 'A')) : character;
            }
        });

    private static string RoutingBool(bool value) => value ? "true" : "false";

    private static string RoutingEscape(string? value)
    {
        if (string.IsNullOrEmpty(value))
            return "";
        StringBuilder? escaped = null;
        for (int i = 0; i < value.Length; i++)
        {
            char character = value[i];
            if (character is '\\' or '"' || character < 32 || character > 126)
            {
                escaped ??= new StringBuilder(value[..i]);
                if (character is '\\' or '"')
                    escaped.Append('\\').Append(character);
                else
                    escaped.Append(CultureInfo.InvariantCulture, $"\\u{(int)character:X4}");
            }
            else
                escaped?.Append(character);
        }
        return escaped?.ToString() ?? value;
    }

    // TStringList sorts with the Windows user locale, ignoring case.
    [DllImport("kernel32.dll", EntryPoint = "CompareStringEx", CharSet = CharSet.Unicode, ExactSpelling = true,
        SetLastError = true)]
    private static extern int CompareRoutingString(string? locale, uint flags, string left, int leftLength,
        string right, int rightLength, IntPtr version, IntPtr reserved, IntPtr parameter);

    private static int CompareRoutingRows(string left, string right)
    {
        const uint ignoreCase = 1;
        int comparison = CompareRoutingString(null, ignoreCase, left, left.Length, right, right.Length,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (comparison == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return comparison - 2;
    }

    private static string RoutingNet(IPCB_Primitive primitive) => primitive.GetState_Net()?.GetState_Name() ?? "";

    private static int RoutingLowLayer(IPCB_Via via) => (int)new V7_Layer(via.GetState_LowLayer()).SafeV6Layer();

    private static int RoutingHighLayer(IPCB_Via via) => (int)new V7_Layer(via.GetState_HighLayer()).SafeV6Layer();

    private static string RoutingTrackGeometry(int x1, int y1, int x2, int y2, int width, int layer)
    {
        if (x1 > x2 || x1 == x2 && y1 > y2)
            (x1, y1, x2, y2) = (x2, y2, x1, y1);
        return RoutingFormat($"{x1},{y1},{x2},{y2},{width},{layer}");
    }

    private static string RoutingViaGeometry(IPCB_Via via, char separator) => RoutingFormat(
        $"{via.GetState_XLocation()}{separator}{via.GetState_YLocation()}{separator}{via.GetState_Size()}{separator}{via.GetState_HoleSize()}{separator}{RoutingLowLayer(via)}{separator}{RoutingHighLayer(via)}");

    private static string RoutingGeometry(IPCB_Primitive primitive) => primitive.GetState_ObjectID() switch
    {
        TObjectId.eTrackObject => RoutingTrackGeometry((IPCB_Track)primitive),
        TObjectId.eViaObject => RoutingViaGeometry((IPCB_Via)primitive, ','),
        _ => throw new InvalidOperationException("Unsupported PCB routing primitive")
    };

    private static string RoutingTrackGeometry(IPCB_Track track) => RoutingTrackGeometry(track.GetState_X1(),
        track.GetState_Y1(), track.GetState_X2(), track.GetState_Y2(), track.GetState_Width(), (int)track.GetState_Layer());

    private static void ExportRoutingInventory(IPCB_Board board, string directory, string snapshotId,
        RoutingFloatValues floatValues)
    {
        File.WriteAllText(Path.Combine(directory, "inventory-status.txt"), "exporting\r\n");
        var tables = new RoutingInventoryTables();
        var signature = CollectRoutingInventory(board, floatValues, null, tables);
        signature.Sort(CompareRoutingRows);
        tables.Summary.Add(RoutingFormat($"snapshot_id\t{snapshotId}"));
        tables.Write(directory);
        File.WriteAllLines(Path.Combine(directory, "board-signature.txt"), signature);
        floatValues.CopyTo(directory);
        File.WriteAllText(Path.Combine(directory, "inventory-status.txt"), "complete\r\n");
    }

    private static List<string> CollectRoutingInventory(IPCB_Board board, RoutingFloatValues floatValues,
        RoutingMatches? matches, RoutingInventoryTables? tables)
    {
        string path = board.GetState_FileName();
        int originX = board.GetState_XOrigin();
        int originY = board.GetState_YOrigin();
        int units = EDP.Utils.MilsToCoord(1);
        var signature = new List<string> { RoutingFormat($"board\t{RoutingEscape(RoutingUpperCase(path))}\t{originX}\t{originY}\t{units}") };
        var layerNames = new Dictionary<TV6_Layer, string>();
        foreach (var primitive in BoardObjects(board, tables is null ? RoutingSignatureObjects : RoutingInventoryObjects))
        {
            switch (primitive.GetState_ObjectID())
            {
                case TObjectId.eNetObject:
                {
                    var net = (IPCB_Net)primitive;
                    string name = net.GetState_Name() ?? "";
                    string encoded = RoutingEscape(name);
                    int pinCount = net.GetState_PinCount();
                    signature.Add(RoutingFormat($"net\t{encoded}\t{pinCount}"));
                    matches?.Record(new RoutingKey("net", name, ""), net);
                    if (tables is not null)
                    {
                        bool invalid = net.GetState_ConnectivelyInvalid();
                        if (invalid)
                            tables.InvalidNets++;
                        tables.Nets.Add(RoutingFormat($"{encoded}\t{pinCount}\t{net.GetState_ViaCount()}\t{net.GetState_RoutedLength()}\t{RoutingBool(invalid)}\t{RoutingBool(net.GetState_ConnectsVisible())}"));
                    }
                    break;
                }
                case TObjectId.ePadObject:
                {
                    var pad = (IPCB_Pad)primitive;
                    string designator = pad.GetState_Component()?.GetState_Name()?.GetState_Text() ?? "";
                    var layer = pad.GetState_Layer();
                    string row = RoutingFormat($"{RoutingEscape(designator)}\t{RoutingEscape(pad.GetState_Name())}\t{RoutingEscape(RoutingNet(pad))}\t{pad.GetState_XLocation()}\t{pad.GetState_YLocation()}\t{(int)layer}\t{RoutingLayerLabel(layer, layerNames)}\t{floatValues.Format(pad.GetState_Rotation())}\t{pad.GetState_TopXSize()}\t{pad.GetState_TopYSize()}\t{pad.GetState_HoleSize()}");
                    signature.Add("pad\t" + row);
                    tables?.Pads.Add(row + "\t" + RoutingBool(pad.GetState_Selected()));
                    break;
                }
                case TObjectId.eTrackObject:
                {
                    var track = (IPCB_Track)primitive;
                    string net = RoutingNet(track);
                    string encoded = RoutingEscape(net);
                    int x1 = track.GetState_X1();
                    int y1 = track.GetState_Y1();
                    int x2 = track.GetState_X2();
                    int y2 = track.GetState_Y2();
                    int width = track.GetState_Width();
                    var layer = track.GetState_Layer();
                    string geometry = RoutingTrackGeometry(x1, y1, x2, y2, width, (int)layer);
                    signature.Add($"track\t{encoded}\t{geometry}");
                    matches?.Record(new RoutingKey("track", net, geometry), track);
                    tables?.Tracks.Add(RoutingFormat($"{encoded}\t{x1}\t{y1}\t{x2}\t{y2}\t{width}\t{(int)layer}\t{RoutingLayerLabel(layer, layerNames)}\t{RoutingBool(track.GetState_Selected())}"));
                    break;
                }
                case TObjectId.eViaObject:
                {
                    var via = (IPCB_Via)primitive;
                    string net = RoutingNet(via);
                    string geometry = RoutingViaGeometry(via, '\t');
                    string row = $"{RoutingEscape(net)}\t{geometry}";
                    signature.Add("via\t" + row);
                    matches?.Record(new RoutingKey("via", net, geometry.Replace('\t', ',')), via);
                    tables?.Vias.Add(row + "\t" + RoutingBool(via.GetState_Selected()));
                    break;
                }
                case TObjectId.eConnectionObject:
                    CollectRoutingConnection((IPCB_Connection)primitive, tables!);
                    break;
                case TObjectId.eRuleObject:
                {
                    var rule = (IPCB_Rule)primitive;
                    string row = RoutingFormat($"{RoutingEscape(rule.GetState_Name())}\t{(int)rule.GetState_RuleKind()}\t{rule.Priority()}\t{RoutingBool(rule.GetState_DRCEnabled())}\t{RoutingEscape(rule.GetState_Scope1Expression())}\t{RoutingEscape(rule.GetState_Scope2Expression())}\t{RoutingEscape(rule.GetState_DataSummaryString())}");
                    signature.Add("rule\t" + row);
                    tables?.Rules.Add(row);
                    break;
                }
                case TObjectId.eComponentObject:
                {
                    var component = (IPCB_Component)primitive;
                    var layer = component.GetState_Layer();
                    string row = RoutingFormat($"{RoutingEscape(component.GetState_Name()?.GetState_Text())}\t{RoutingEscape(component.GetState_Comment()?.GetState_Text())}\t{RoutingEscape(component.GetState_Pattern())}\t{component.GetState_XLocation()}\t{component.GetState_YLocation()}\t{floatValues.Format(component.GetState_Rotation())}\t{(int)layer}\t{RoutingLayerLabel(layer, layerNames)}");
                    signature.Add("component\t" + row);
                    tables?.Components.Add(row);
                    break;
                }
                case TObjectId.eArcObject:
                {
                    var arc = (IPCB_Arc)primitive;
                    string row = RoutingFormat($"{RoutingEscape(RoutingNet(arc))}\t{arc.GetState_CenterX()}\t{arc.GetState_CenterY()}\t{arc.GetState_Radius()}\t{floatValues.Format(arc.GetState_StartAngle())}\t{floatValues.Format(arc.GetState_EndAngle())}\t{arc.GetState_LineWidth()}\t{(int)arc.GetState_Layer()}");
                    signature.Add("arc\t" + row);
                    tables?.Arcs.Add(row + "\t" + RoutingBool(arc.GetState_Selected()));
                    break;
                }
                case TObjectId.ePolyObject:
                {
                    var polygon = (IPCB_Polygon)primitive;
                    string row = RoutingFormat($"{RoutingEscape(polygon.GetState_Name())}\t{RoutingEscape(RoutingNet(polygon))}\t{(int)polygon.GetState_Layer()}\t{RoutingEscape(RoutingPolygonDefinition(polygon, floatValues))}");
                    signature.Add("polygon\t" + row);
                    tables?.Polygons.Add(row);
                    break;
                }
            }
        }

        string depths = CollectRoutingLayers(board, signature, tables, floatValues);
        string outline = RoutingSegments(board.GetState_BoardOutline(), floatValues);
        string pairs = CollectRoutingPairs(board);
        signature.AddRange(["routing-context-v1", "routing-outline\t" + outline, "routing-pairs\t" + pairs]);
        tables?.AddSummary(path, units, originX, originY, depths, outline, pairs);
        return signature;
    }

    private static string RoutingLayerLabel(TV6_Layer layer, Dictionary<TV6_Layer, string> labels)
    {
        if (!labels.TryGetValue(layer, out var label))
            labels.Add(layer, label = RoutingEscape(LayerName(new V7_Layer(layer))));
        return label;
    }

    private static void CollectRoutingConnection(IPCB_Connection connection, RoutingInventoryTables tables)
    {
        var mode = connection.GetState_Mode();
        string modeName = mode switch
        {
            TConnectionMode.eRatsNestConnection => "ratsnest",
            TConnectionMode.eBrokenNetMarker => "broken_net_marker",
            _ => "other"
        };
        bool redundant = connection.IsRedundant();
        if (redundant)
            tables.RedundantConnections++;
        else if (mode == TConnectionMode.eRatsNestConnection)
            tables.RatsnestConnections++;
        tables.Connections.Add(RoutingFormat($"{RoutingEscape(RoutingNet(connection))}\t{connection.GetState_X1()}\t{connection.GetState_Y1()}\t{connection.GetState_X2()}\t{connection.GetState_Y2()}\t{(int)connection.GetState_Layer1()}\t{(int)connection.GetState_Layer2()}\t{modeName}\t{RoutingBool(redundant)}\t{RoutingBool(connection.GetState_Selected())}"));
    }

    private static string CollectRoutingLayers(IPCB_Board board, List<string> signature,
        RoutingInventoryTables? tables, RoutingFloatValues floatValues)
    {
        var stack = board.GetState_LayerStack_V7() ?? throw new RoutingBatchRejected("PCB has no V7 layer stack.");
        int count = 0;
        int dielectricBelow = 0;
        double depth = 0;
        bool hasDepths = true;
        var depths = new List<string>();
        for (var layer = stack.FirstLayer(); layer is not null; layer = stack.NextLayer(layer))
        {
            if (++count > 64)
                throw new RoutingBatchRejected("Layer stack iteration exceeded 64 entries.");
            if (count > 1 && dielectricBelow <= 0)
                hasDepths = false;
            int layerId = (int)layer.V6_LayerID();
            int thickness = layer.GetState_CopperThickness();
            string row = RoutingFormat($"{count}\t{layerId}\t{RoutingEscape(layer.GetState_LayerName())}\t{thickness}");
            signature.Add("layer\t" + row);
            tables?.Layers.Add(row);
            depths.Add(RoutingFormat($"{layerId},{floatValues.Format(depth + thickness / 2.0)}"));
            var dielectric = layer.Dielectric();
            dielectricBelow = dielectric is not null && dielectric.GetState_DielectricType() != TDielectricType.eNoDielectric
                ? dielectric.GetState_DielectricHeight() : 0;
            depth += thickness + dielectricBelow;
        }
        string value = hasDepths ? string.Join(';', depths) : "";
        signature.Add("routing-depths\t" + value);
        return value;
    }

    private static string RoutingSegments(IPCB_Polygon polygon, RoutingFloatValues floatValues)
    {
        var segments = new List<string>();
        int count = polygon.GetState_PointCount();
        for (int index = 0; index < count; index++)
        {
            var segment = polygon.GetState_Segments(index);
            segments.Add(RoutingFormat($"{(int)segment.Kind},{segment.Vx},{segment.Vy},{segment.Cx},{segment.Cy},{segment.Radius},{floatValues.Format(segment.Angle1)},{floatValues.Format(segment.Angle2)}"));
        }
        return string.Join(';', segments);
    }

    private static string RoutingPolygonDefinition(IPCB_Polygon polygon, RoutingFloatValues floatValues)
    {
        string properties = RoutingFormat($"{(int)polygon.GetState_PolygonType()},{(int)polygon.GetState_PolyHatchStyle()},{(int)polygon.GetState_PourOver()},{RoutingBool(polygon.GetState_RemoveDead())},{polygon.GetState_BorderWidth()},{polygon.GetState_Grid()},{polygon.GetState_TrackSize()},{polygon.GetState_MinTrack()},{RoutingBool(polygon.GetState_UseOctagons())},{RoutingBool(polygon.GetState_RemoveIslandsByArea())},{floatValues.Format(polygon.GetState_IslandAreaThreshold())},{RoutingBool(polygon.GetState_RemoveNarrowNecks())},{polygon.GetState_NeckWidthThreshold()},{polygon.GetState_ArcApproximation()}");
        string segments = RoutingSegments(polygon, floatValues);
        return segments.Length == 0 ? properties : properties + ';' + segments;
    }

    private static string CollectRoutingPairs(IPCB_Board board)
    {
        var pairs = new List<string>();
        foreach (var primitive in BoardObjects(board, TObjectId.eDifferentialPairObject))
        {
            var pair = (IPCB_DifferentialPair)primitive;
            pairs.Add($"[\"{RoutingEscape(pair.GetState_Name())}\",\"{RoutingEscape(pair.GetState_PositiveNet()?.GetState_Name())}\",\"{RoutingEscape(pair.GetState_NegativeNet()?.GetState_Name())}\"]");
        }
        pairs.Sort(CompareRoutingRows);
        return RoutingEscape("[" + string.Join(',', pairs) + "]");
    }

    private sealed class RoutingInventoryTables
    {
        internal List<string> Summary { get; } = ["field\tvalue"];
        internal List<string> Nets { get; } = ["net\tpin_count\tvia_count\trouted_length_raw\tconnectivity_invalid\tconnections_visible"];
        internal List<string> Pads { get; } = ["refdes\tpad\tnet\tx_raw\ty_raw\tlayer_id\tlayer\trotation_degrees\ttop_x_size_raw\ttop_y_size_raw\thole_size_raw\tselected"];
        internal List<string> Tracks { get; } = ["net\tx1_raw\ty1_raw\tx2_raw\ty2_raw\twidth_raw\tlayer_id\tlayer\tselected"];
        internal List<string> Vias { get; } = ["net\tx_raw\ty_raw\tsize_raw\thole_size_raw\tlow_layer_id\thigh_layer_id\tselected"];
        internal List<string> Connections { get; } = ["net\tx1_raw\ty1_raw\tx2_raw\ty2_raw\tlayer1_id\tlayer2_id\tmode\tredundant\tselected"];
        internal List<string> Rules { get; } = ["name\tkind_id\tpriority\tdrc_enabled\tscope1\tscope2\tsummary"];
        internal List<string> Components { get; } = ["refdes\tcomment\tfootprint\tx_raw\ty_raw\trotation_degrees\tlayer_id\tlayer"];
        internal List<string> Layers { get; } = ["stack_index\tlayer_id\tlayer_name\tcopper_thickness_raw"];
        internal List<string> Arcs { get; } = ["net\tx_raw\ty_raw\tradius_raw\tstart_angle\tend_angle\twidth_raw\tlayer_id\tselected"];
        internal List<string> Polygons { get; } = ["name\tnet\tlayer_id\tdefinition"];
        internal int InvalidNets { get; set; }
        internal int RedundantConnections { get; set; }
        internal int RatsnestConnections { get; set; }

        internal void AddSummary(string path, int units, int originX, int originY, string depths, string outline, string pairs)
        {
            Summary.AddRange([
                $"board_file\t{RoutingEscape(path)}", "coordinate_units\tAltium internal units", "field_encoding\tjson-string",
                RoutingFormat($"internal_units_per_mil\t{units}"), RoutingFormat($"x_origin_raw\t{originX}"),
                RoutingFormat($"y_origin_raw\t{originY}"), RoutingFormat($"net_count\t{Nets.Count - 1}"),
                RoutingFormat($"pad_count\t{Pads.Count - 1}"), RoutingFormat($"track_segment_count\t{Tracks.Count - 1}"),
                RoutingFormat($"via_count\t{Vias.Count - 1}"), RoutingFormat($"connection_object_count\t{Connections.Count - 1}"),
                RoutingFormat($"rule_count\t{Rules.Count - 1}"), RoutingFormat($"nonredundant_ratsnest_connections\t{RatsnestConnections}"),
                RoutingFormat($"redundant_connection_objects\t{RedundantConnections}"), RoutingFormat($"connectivity_invalid_nets\t{InvalidNets}"),
                RoutingFormat($"components_count\t{Components.Count - 1}"), RoutingFormat($"layers_count\t{Layers.Count - 1}"),
                RoutingFormat($"arcs_count\t{Arcs.Count - 1}"), RoutingFormat($"polygons_count\t{Polygons.Count - 1}"),
                $"copper_depths_raw\t{depths}", $"outline_raw\t{outline}", $"differential_pairs_json\t{pairs}"]);
        }

        internal void Write(string directory)
        {
            File.WriteAllLines(Path.Combine(directory, "board.tsv"), Summary);
            File.WriteAllLines(Path.Combine(directory, "nets.tsv"), Nets);
            File.WriteAllLines(Path.Combine(directory, "pads.tsv"), Pads);
            File.WriteAllLines(Path.Combine(directory, "tracks.tsv"), Tracks);
            File.WriteAllLines(Path.Combine(directory, "vias.tsv"), Vias);
            File.WriteAllLines(Path.Combine(directory, "connections.tsv"), Connections);
            File.WriteAllLines(Path.Combine(directory, "rules.tsv"), Rules);
            File.WriteAllLines(Path.Combine(directory, "components.tsv"), Components);
            File.WriteAllLines(Path.Combine(directory, "layers.tsv"), Layers);
            File.WriteAllLines(Path.Combine(directory, "arcs.tsv"), Arcs);
            File.WriteAllLines(Path.Combine(directory, "polygons.tsv"), Polygons);
        }
    }
}
