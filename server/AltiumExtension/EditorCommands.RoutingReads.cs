using System.IO;
using System.Text;
using System.Text.Json;
using PCB;

namespace AltiumMcpSdk;

internal sealed partial class EditorCommands
{
    private object ReadUnroutedConnections(JsonElement parameters)
    {
        var board = RequireActiveRoutingBoard(parameters);
        var nets = ReadRoutingFilter(parameters, "unrouted_nets");
        var designators = ReadRoutingFilter(parameters, "unrouted_designators");
        var output = new StringBuilder();
        var origin = new BoardOrigin(board.GetState_XOrigin(), board.GetState_YOrigin());

        if (designators.Count != 0)
        {
            foreach (var primitive in BoardObjects(board, PCB.TObjectId.eComponentObject))
            {
                var component = (IPCB_Component)primitive;
                string designator = ComponentDesignator(component);
                if (!designators.Contains(designator))
                    continue;
                foreach (var padPrimitive in PlacementPrimitives(component, PCB.TObjectId.ePadObject))
                {
                    var pad = (IPCB_Pad)padPrimitive;
                    string net = NetName(pad);
                    AddLayoutLine(output,
                        $"P|{designator}|{pad.GetState_Name()}|{pad.GetState_XLocation() - origin.X}|{pad.GetState_YLocation() - origin.Y}|{net}");
                    if (net.Length != 0)
                        nets.Add(net);
                }
            }
        }

        // Altium may retain a ratsnest line after a scripted routing edit.
        // AnalyzeNet refreshes it and can merge adjacent collinear tracks.
        foreach (var primitive in BoardObjects(board, PCB.TObjectId.eNetObject))
        {
            var net = (IPCB_Net)primitive;
            if (nets.Count == 0 || nets.Contains(net.GetState_Name()))
                board.AnalyzeNet(net);
        }

        foreach (var primitive in BoardObjects(board, PCB.TObjectId.eConnectionObject))
        {
            var connection = (IPCB_Connection)primitive;
            string net = NetName(connection);
            if (nets.Count != 0 && !nets.Contains(net))
                continue;
            AddLayoutLine(output,
                $"C|{net}|{connection.GetState_X1() - origin.X}|{connection.GetState_Y1() - origin.Y}|{connection.GetState_X2() - origin.X}|{connection.GetState_Y2() - origin.Y}|{LayerName(new V7_Layer(connection.GetState_Layer1()))}|{LayerName(new V7_Layer(connection.GetState_Layer2()))}");
        }
        output.Append("B|").AppendLine(board.GetState_FileName());
        return Success(output.ToString());
    }

    private object ReadNetRules(JsonElement parameters)
    {
        var board = RequireActiveRoutingBoard(parameters);
        string rawNames = StringParameter(parameters, "net_rules_nets");
        if (rawNames.Length == 0)
            throw new CommandUnavailable("The net rule request has no nets");

        var pcbServer = PCB.GlobalVars.PCBServer;
        var layer = NetRuleLayer(board, StringParameter(parameters, "net_rules_layer"));
        var layerId = new V7_Layer(layer);
        var origin = new BoardOrigin(board.GetState_XOrigin(), board.GetState_YOrigin());
        var boardNets = new Dictionary<string, IPCB_Net>(StringComparer.OrdinalIgnoreCase);
        foreach (var primitive in BoardObjects(board, PCB.TObjectId.eNetObject))
        {
            var net = (IPCB_Net)primitive;
            boardNets.TryAdd(net.GetState_Name(), net);
        }

        var output = new StringBuilder();
        // Match the script's probe coordinates and net assignments. Dominant
        // rule evaluation needs registered tracks.
        WithRuleProbe(pcbServer, board, layer, origin, null, reference =>
        {
            foreach (string name in SplitRoutingLines(rawNames))
            {
                if (!boardNets.TryGetValue(name, out var net))
                {
                    output.Append("M|").AppendLine(name);
                    continue;
                }

                WithRuleProbe(pcbServer, board, layer, origin, net, probe =>
                {
                    var width = (IPCB_MaxMinWidthConstraint?)board.FindDominantRuleForObject(
                        probe, TRuleKind.eRule_MaxMinWidth);
                    string widthValues = width is null ? "||| " : FormattableString.Invariant(
                        $"{width.GetState_MinWidth(layerId)}|{width.GetState_FavoredWidth(layerId)}|{width.GetState_MaxWidth(layerId)}|{width.GetState_Name()}");
                    var clearance = (IPCB_ClearanceConstraint?)board.FindDominantRuleForObjectPair(
                        probe, reference, TRuleKind.eRule_Clearance);
                    int gap = clearance?.GetState_Gap() ?? -1;
                    AddLayoutLine(output, $"N|{net.GetState_Name()}|{widthValues}|{gap}|{net.GetState_InDifferentialPair()}");
                });
            }
        });
        return Success(output.ToString());
    }

    private IPCB_Board RequireActiveRoutingBoard(JsonElement parameters)
    {
        var board = RequireActivePcb(StringParameter(parameters, "board_path"));
        if (!string.Equals(Path.GetExtension(board.GetState_FileName()), ".PcbDoc", StringComparison.OrdinalIgnoreCase))
            throw new CommandUnavailable("Routing reads require an active PCB document");
        return board;
    }

    private static HashSet<string> ReadRoutingFilter(JsonElement parameters, string name) =>
        new(SplitRoutingLines(StringParameter(parameters, name))
            .Select(value => value.Trim()).Where(value => value.Length != 0), StringComparer.OrdinalIgnoreCase);

    private static IEnumerable<string> SplitRoutingLines(string value)
    {
        var lines = value.Replace("\r\n", "\n").Replace('\r', '\n').Replace(';', '\n').Split('\n');
        return lines[^1].Length == 0 ? lines[..^1] : lines;
    }

    private static TV6_Layer NetRuleLayer(IPCB_Board board, string name)
    {
        string requested = name.Trim();
        var iterator = board.ElectricalLayerIterator();
        iterator.SetBeforeFirst();
        while (iterator.Next())
        {
            var layer = iterator.LayerObject();
            var id = layer.V6_LayerID();
            if (requested.Equals(layer.GetState_LayerName(), StringComparison.OrdinalIgnoreCase) ||
                requested.Equals(LayerName(new V7_Layer(id)), StringComparison.OrdinalIgnoreCase))
                return id is >= TV6_Layer.eV6_TopLayer and <= TV6_Layer.eV6_BottomLayer
                    ? id : TV6_Layer.eV6_TopLayer;
        }
        return TV6_Layer.eV6_TopLayer;
    }

    private static void WithRuleProbe(IPCB_ServerInterface pcbServer, IPCB_Board board, TV6_Layer layer,
        BoardOrigin origin, IPCB_Net? net, Action<IPCB_Track> read)
    {
        IPCB_Primitive primitive = pcbServer.PCBObjectFactory(PCB.TObjectId.eTrackObject,
            TDimensionKind.eNoDimension, PCB.TObjectCreationMode.eCreate_Default);
        if (primitive is null)
            throw new InvalidOperationException("Altium could not create a rule probe track");

        bool attemptedAdd = false;
        bool registered = false;
        try
        {
            var track = (IPCB_Track)primitive;
            track.SetState_Layer(layer);
            track.SetState_Width(10_000);
            track.SetState_Net(net);
            int y = origin.Y - (net is null ? 900_000_000 : 899_000_000);
            track.SetState_X1(origin.X - 900_000_000);
            track.SetState_Y1(y);
            track.SetState_X2(origin.X - 899_000_000);
            track.SetState_Y2(y);
            attemptedAdd = true;
            board.AddPCBObject(track);
            registered = true;
            read(track);
        }
        finally
        {
            // Undo history can retain an added or removed native object.
            if (registered || (attemptedAdd && primitive.GetState_InBoard()))
                board.RemovePCBObject(primitive);
            else if (!attemptedAdd)
                pcbServer.DestroyPCBObject(ref primitive);
        }
    }
}
