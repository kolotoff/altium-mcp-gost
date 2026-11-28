using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;
using DXP;
using PCB;

namespace AltiumMcpSdk;

internal sealed partial class EditorCommands
{
    // PCBM_BoardRegisteration in the Altium PCB API. A null destination broadcasts it.
    private const ushort CopperBoardRegistration = 2;

    private readonly record struct CopperPoint(int X, int Y);
    private readonly record struct CopperLayer(TV6_Layer V6, V7_LayerBase V7);
    private sealed record CopperPlacement(char Kind, TObjectId ObjectId, IPCB_Net? Net,
        Action<IPCB_ServerInterface, IPCB_Primitive> Configure);

    private object PlaceCopper(JsonElement parameters)
    {
        string wanted = StringParameter(parameters, "board_path");
        if (wanted.Length == 0 && client.GetDXPWorkspace()?.DM_FocusedProject() is null)
            throw new CommandUnavailable("Let the DelphiScript bridge resolve the PCB project");
        var board = RequireActivePcb(wanted);
        var server = PCB.GlobalVars.PCBServer
            ?? throw new CommandUnavailable("The PCB editor is unavailable");

        string file = StringParameter(parameters, "copper_spec_file");
        if (!Path.IsPathFullyQualified(file))
            throw new CommandUnavailable("Expected an absolute PCB copper specification path");
        string[] lines;
        try
        {
            lines = File.ReadAllLines(file, new UTF8Encoding(false, true));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or DecoderFallbackException)
        {
            throw new CommandUnavailable("The managed bridge could not read the PCB copper specification");
        }

        // These mandatory polygon flags have no managed setters on Altium 26.11.
        // Decline the entire batch before creating any of its earlier primitives.
        if (lines.Any(line => line.StartsWith("G|", StringComparison.Ordinal)))
            throw new CommandUnavailable("Use the DelphiScript bridge for exact polygon pour settings");

        var placements = new List<CopperPlacement>();
        var problems = new List<string>();
        var usedNets = new Dictionary<string, IPCB_Net>(StringComparer.Ordinal);
        var layers = CopperElectricalLayers(board);
        var nets = CopperBoardNets(board);
        var origin = new CopperPoint(board.GetState_XOrigin(), board.GetState_YOrigin());
        for (int index = 0; index < lines.Length; index++)
        {
            if (lines[index].Length == 0)
                continue;
            string[] row = lines[index].Split('|');
            int line = index + 1;
            ValidateCopperRow(row);
            char kind = row[0][0];
            string layerText = kind == 'V' ? row[6] : row[1];
            layers.TryGetValue(CopperKey(layerText.Trim()), out var layer);
            var endLayer = default(CopperLayer);
            string? problem = null;
            if (kind == 'V')
            {
                layers.TryGetValue(CopperKey(row[7].Trim()), out endLayer);
                if (layer.V7 is null || endLayer.V7 is null || layer.V6 == endLayer.V6)
                    problem = $"a via must span two different signal layers: {row[6]} to {row[7]}";
            }
            else if (kind == 'U')
            {
                if (CopperKey(layerText.Trim()) == "MULTI LAYER")
                    layer = new CopperLayer(TV6_Layer.eV6_MultiLayer, new V7_Layer(TV6_Layer.eV6_MultiLayer));
                else if (layer.V7 is null)
                    problem = $"a cutout goes on a signal layer or the Multi Layer, not {layerText}";
            }
            else if (layer.V7 is null)
                problem = $"{layerText} is not a signal layer of this board";

            string netName = kind == 'U' ? "" : row[kind == 'V' ? 1 : 2];
            IPCB_Net? net = null;
            string netKey = CopperKey(netName);
            if (problem is null && netName.Length != 0 && !nets.TryGetValue(netKey, out net))
                problem = $"net not found on the board: {netName}";

            var placement = ReadCopperPlacement(lines, ref index, row, origin, layer, endLayer, net);
            if (problem is not null)
            {
                if (problems.Count < 20)
                    problems.Add($"line {line}: {problem}");
                continue;
            }
            placements.Add(placement);
            if (net is not null)
                usedNets.TryAdd(netKey, net);
        }
        if (problems.Count != 0)
            return Success(new
            {
                success = false,
                error = "Nothing was added: some records name a net or layer the board does not have",
                problems
            });
        if (placements.Count == 0)
            throw new CommandUnavailable("No supported PCB copper records were supplied");

        var counts = new Dictionary<char, int>();
        server.PreProcess();
        try
        {
            foreach (var placement in placements)
            {
                var primitive = server.PCBObjectFactory(placement.ObjectId,
                    TDimensionKind.eNoDimension, TObjectCreationMode.eCreate_Default)
                    ?? throw new InvalidOperationException($"Cannot create native PCB primitive {placement.ObjectId}");
                ConfigureDetachedCopper(server, placement, primitive);
                board.AddPCBObject(primitive);
                IPCB_BoardHelper.DispatchMessage(board, board, null!, CopperBoardRegistration, primitive);
                Increment(counts, placement.Kind);
            }
        }
        finally
        {
            server.PostProcess();
        }

        foreach (var net in usedNets.Values)
            board.AnalyzeNet(net);
        board.ViewManager_FullUpdate();

        return Success(new
        {
            success = true,
            tracks = counts.GetValueOrDefault('T'),
            arcs = counts.GetValueOrDefault('A'),
            vias = counts.GetValueOrDefault('V'),
            fills = counts.GetValueOrDefault('F'),
            regions = counts.GetValueOrDefault('R'),
            cutouts = counts.GetValueOrDefault('U'),
            pours = Array.Empty<object>(),
            board = board.GetState_FileName()
        });
    }

    private static void ConfigureDetachedCopper(IPCB_ServerInterface server, CopperPlacement placement,
        IPCB_Primitive primitive)
    {
        try
        {
            placement.Configure(server, primitive);
            if (placement.Net is not null)
                primitive.SetState_Net(placement.Net);
        }
        catch
        {
            // The factory object has not been handed to the board.
            server.DestroyPCBObject(ref primitive);
            throw;
        }
    }

    private static Dictionary<string, CopperLayer> CopperElectricalLayers(IPCB_Board board)
    {
        var layers = new Dictionary<string, CopperLayer>(StringComparer.Ordinal);
        var iterator = board.ElectricalLayerIterator();
        while (iterator.Next())
        {
            var layer = iterator.LayerObject();
            var id = layer.V6_LayerID();
            if (id is < TV6_Layer.eV6_TopLayer or > TV6_Layer.eV6_BottomLayer)
                continue;
            var info = new CopperLayer(id, layer.V7_LayerID());
            layers.TryAdd(CopperKey(layer.GetState_LayerName() ?? ""), info);
            layers.TryAdd(CopperKey(LayerName(new V7_Layer(id))), info);
        }
        return layers;
    }

    private static Dictionary<string, IPCB_Net> CopperBoardNets(IPCB_Board board)
    {
        var nets = new Dictionary<string, IPCB_Net>(StringComparer.Ordinal);
        foreach (var item in BoardObjects(board, PCB.TObjectId.eNetObject))
        {
            var net = (IPCB_Net)item;
            nets.TryAdd(CopperKey(net.GetState_Name() ?? ""), net);
        }
        return nets;
    }

    // DelphiScript's UpperCase folds ASCII letters only for these identifiers.
    private static string CopperKey(string value) =>
        string.Create(value.Length, value, static (buffer, text) =>
        {
            for (int index = 0; index < text.Length; index++)
            {
                char c = text[index];
                buffer[index] = c is >= 'a' and <= 'z' ? (char)(c - ('a' - 'A')) : c;
            }
        });

    private static void ValidateCopperRow(string[] row)
    {
        int fields = row[0] switch
        {
            "T" or "V" or "F" => 8,
            "A" => 9,
            "R" => 3,
            "U" => 2,
            _ => 0
        };
        if (fields == 0 || row.Length != fields)
            throw new CommandUnavailable("Unsupported or malformed PCB copper specification record");
    }

    private static CopperPlacement ReadCopperPlacement(string[] lines, ref int index, string[] row, CopperPoint origin,
        CopperLayer layer, CopperLayer endLayer, IPCB_Net? net)
    {
        switch (row[0][0])
        {
            case 'T':
            {
                int width = CopperInteger(row[3]);
                var start = CopperPosition(row, 4, origin);
                var end = CopperPosition(row, 6, origin);
                return new('T', PCB.TObjectId.eTrackObject, net, (_, item) =>
                {
                    var track = (IPCB_Track)item;
                    track.SetState_Layer(layer.V6);
                    track.SetState_Width(width);
                    track.SetState_X1(start.X);
                    track.SetState_Y1(start.Y);
                    track.SetState_X2(end.X);
                    track.SetState_Y2(end.Y);
                });
            }
            case 'A':
            {
                int width = CopperInteger(row[3]);
                var center = CopperPosition(row, 4, origin);
                int radius = CopperInteger(row[6]);
                double start = CopperInteger(row[7]) / 1000.0;
                double end = CopperInteger(row[8]) / 1000.0;
                return new('A', PCB.TObjectId.eArcObject, net, (_, item) =>
                {
                    var arc = (IPCB_Arc)item;
                    arc.SetState_Layer(layer.V6);
                    arc.SetState_LineWidth(width);
                    arc.SetState_CenterX(center.X);
                    arc.SetState_CenterY(center.Y);
                    arc.SetState_Radius(radius);
                    arc.SetState_StartAngle(start);
                    arc.SetState_EndAngle(end);
                });
            }
            case 'V':
            {
                var location = CopperPosition(row, 2, origin);
                int diameter = CopperInteger(row[4]);
                int hole = CopperInteger(row[5]);
                var (low, high) = layer.V6 < endLayer.V6 ? (layer, endLayer) : (endLayer, layer);
                return new('V', PCB.TObjectId.eViaObject, net, (_, item) =>
                {
                    var via = (IPCB_Via)item;
                    via.SetState_XLocation(location.X);
                    via.SetState_YLocation(location.Y);
                    via.SetState_Size(diameter);
                    via.SetState_HoleSize(hole);
                    via.SetState_LowLayer(low.V7);
                    via.SetState_HighLayer(high.V7);
                });
            }
            case 'F':
            {
                var first = CopperPosition(row, 3, origin);
                var second = CopperPosition(row, 5, origin);
                double rotation = CopperInteger(row[7]) / 1000.0;
                return new('F', PCB.TObjectId.eFillObject, net, (_, item) =>
                {
                    var fill = (IPCB_Fill)item;
                    fill.SetState_Layer(layer.V6);
                    fill.SetState_X1Location(first.X);
                    fill.SetState_Y1Location(first.Y);
                    fill.SetState_X2Location(second.X);
                    fill.SetState_Y2Location(second.Y);
                    fill.SetState_Rotation(rotation);
                });
            }
            default:
            {
                char kind = row[0][0];
                var points = new List<CopperPoint>();
                while (index + 1 < lines.Length && lines[index + 1].StartsWith("S|", StringComparison.Ordinal))
                {
                    string[] point = lines[++index].Split('|');
                    if (point.Length != 4 || point[1] != "L")
                        throw new CommandUnavailable("The region specification requires straight outline segments");
                    points.Add(CopperPosition(point, 2, origin));
                }
                if (points.Count < 3)
                    throw new CommandUnavailable("The region specification requires at least three vertices");
                return new(kind, PCB.TObjectId.eRegionObject, net, (server, item) =>
                {
                    var region = (IPCB_Region)item;
                    var contour = server.PCBContourFactory()
                        ?? throw new InvalidOperationException("Cannot create the native region outline");
                    try
                    {
                        foreach (var point in points)
                            contour.AddPoint(point.X, point.Y);
                    }
                    catch
                    {
                        server.DestroyPCBContour(ref contour);
                        throw;
                    }
                    region.SetOutlineContour(contour);
                    region.SetState_Layer(layer.V6);
                    region.SetState_Kind(kind == 'U' ? TRegionKind.eRegionKind_Cutout : TRegionKind.eRegionKind_Copper);
                });
            }
        }
    }

    private static CopperPoint CopperPosition(string[] row, int index, CopperPoint origin) =>
        new(CopperOffset(row[index], origin.X), CopperOffset(row[index + 1], origin.Y));

    private static int CopperInteger(string value) =>
        int.TryParse(value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out int number)
            ? number : throw new CommandUnavailable("Invalid integer in the PCB copper specification");

    private static int CopperOffset(string value, int origin)
    {
        long coordinate = (long)CopperInteger(value) + origin;
        if (coordinate is < int.MinValue or > int.MaxValue)
            throw new CommandUnavailable("PCB copper coordinate overflows the board origin");
        return (int)coordinate;
    }
}
