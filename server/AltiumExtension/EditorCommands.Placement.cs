using System.Globalization;
using System.Text.Json;
using DXP;
using PCB;

namespace AltiumMcpSdk;

internal sealed partial class EditorCommands
{
    private sealed record ComponentMove(string Designator, int X, int Y, double Rotation,
        string Side, string Lock, ComponentTextMove? Name, ComponentTextMove? Comment);

    private sealed record ComponentTextMove(int X, int Y, double Rotation, int Height, int Width,
        bool Visible, TTextAutoposition AutoPosition);

    private object PlacePcbComponents(JsonElement parameters)
    {
        string boardPath = StringParameter(parameters, "board_path");
        if (boardPath.Length == 0 && client.GetDXPWorkspace()?.DM_FocusedProject() is null)
            throw new CommandUnavailable("There is no focused PCB project");
        var board = RequireActivePcb(boardPath);
        var server = PCB.GlobalVars.PCBServer
                     ?? throw new CommandUnavailable("The PCB editor is unavailable");
        if (!parameters.TryGetProperty("placements", out var entries) ||
            entries.ValueKind != JsonValueKind.Array || entries.GetArrayLength() == 0)
            throw new CommandUnavailable("A placement batch requires at least one placement");

        var originX = board.GetState_XOrigin();
        var originY = board.GetState_YOrigin();
        var requireAll = StringParameter(parameters, "placement_require_all") == "true";
        var components = new List<(ComponentMove Move, IPCB_Component Component)>();
        var missing = new List<string>();
        foreach (var entry in entries.EnumerateArray())
        {
            if (entry.ValueKind != JsonValueKind.String)
                throw new CommandUnavailable("Expected the PCB placement record format");
            string[] fields = entry.GetString()!.Split('|');
            if (fields.Length != 8 || fields[0].Length == 0 ||
                fields[4] is not ("" or "top" or "bottom") || fields[5] is not ("" or "0" or "1"))
                throw new CommandUnavailable("Expected a valid PCB placement record");

            var move = new ComponentMove(fields[0],
                PlacementCoordinate(fields[1], originX), PlacementCoordinate(fields[2], originY),
                PlacementNumber(fields[3]), fields[4], fields[5],
                ParseComponentText(fields[6], originX, originY), ParseComponentText(fields[7], originX, originY));
            if (move.Rotation != -1 && (move.Rotation < 0 || move.Rotation > 360))
                throw new CommandUnavailable("Unsupported PCB rotation");

            var component = board.GetPcbComponentByRefDes(move.Designator);
            if (component is null)
            {
                if (requireAll)
                    return Error($"Missing component {move.Designator}. No placements applied.");
                missing.Add(move.Designator);
                continue;
            }
            if ((move.Name is not null && component.GetState_Name() is null) ||
                (move.Comment is not null && component.GetState_Comment() is null))
                throw new CommandUnavailable("A targeted component text object is unavailable");
            components.Add((move, component));
        }

        var movedTexts = new List<IPCB_Text>();
        var placed = new List<object>();
        server.PreProcess();
        try
        {
            foreach (var (move, component) in components)
            {
                component.BeginModify();
                try
                {
                    // Changing layer mirrors the footprint. Position and angle follow it.
                    var layer = component.GetState_Layer();
                    if (move.Side == "top" && layer == TV6_Layer.eV6_BottomLayer)
                        component.SetState_Layer(TV6_Layer.eV6_TopLayer);
                    else if (move.Side == "bottom" && layer == TV6_Layer.eV6_TopLayer)
                        component.SetState_Layer(TV6_Layer.eV6_BottomLayer);
                    component.MoveToXY(move.X, move.Y);
                    if (move.Rotation >= 0)
                        component.SetState_Rotation(move.Rotation);
                    if (move.Lock.Length != 0)
                        component.SetState_Moveable(move.Lock == "0");
                }
                finally
                {
                    component.EndModify();
                }

                if (move.Name is { } name)
                    movedTexts.Add(PlaceComponentText(component, name, isName: true));
                if (move.Comment is { } comment)
                    movedTexts.Add(PlaceComponentText(component, comment, isName: false));
                placed.Add(new
                {
                    designator = ComponentDesignator(component),
                    x = EDP.Utils.CoordToMils(component.GetState_XLocation() - originX),
                    y = EDP.Utils.CoordToMils(component.GetState_YLocation() - originY),
                    rotation = component.GetState_Rotation(),
                    layer = LayerName(component),
                    locked = !component.GetState_Moveable()
                });
            }
        }
        finally
        {
            server.PostProcess();
        }

        // Batch DRC reads the rebuilt stroke geometry for the moved text.
        foreach (var text in movedTexts)
        {
            text.BeginModify();
            try
            {
                text.SetState_XSizeYSize();
            }
            finally
            {
                text.EndModify();
            }
            text.GraphicallyInvalidate();
        }
        DXP.Utils.RunCommand("PCB:Zoom", "Action=Redraw", client.GetCurrentView());

        return Success(new { placed_count = placed.Count, missing_designators = missing, components = placed });
    }

    private static IPCB_Text PlaceComponentText(IPCB_Component component, ComponentTextMove move, bool isName)
    {
        var text = isName ? component.GetState_Name() : component.GetState_Comment();
        component.BeginModify();
        try
        {
            text.BeginModify();
            try
            {
                if (isName)
                {
                    component.SetState_NameOn(move.Visible);
                    component.SetState_NameAutoPos(TTextAutoposition.eAutoPos_Manual);
                }
                else
                {
                    component.SetState_CommentOn(move.Visible);
                    component.SetState_CommentAutoPos(TTextAutoposition.eAutoPos_Manual);
                }
                text.SetState_Size(move.Height);
                text.SetState_Width(move.Width);
                text.SetState_Rotation(move.Rotation);
            }
            finally
            {
                text.EndModify();
            }
        }
        finally
        {
            component.EndModify();
        }

        int dx = move.X - text.GetState_XLocation();
        int dy = move.Y - text.GetState_YLocation();
        if (dx != 0 || dy != 0)
        {
            text.BeginModify();
            try
            {
                text.MoveByXY(dx, dy);
            }
            finally
            {
                text.EndModify();
            }
        }
        if (move.AutoPosition != TTextAutoposition.eAutoPos_Manual)
        {
            component.BeginModify();
            try
            {
                if (isName)
                    component.SetState_NameAutoPos(move.AutoPosition);
                else
                    component.SetState_CommentAutoPos(move.AutoPosition);
            }
            finally
            {
                component.EndModify();
            }
        }
        return text;
    }

    private static ComponentTextMove? ParseComponentText(string value, int originX, int originY)
    {
        if (value.Length == 0)
            return null;
        string[] fields = value.Split(';');
        if (fields.Length != 7 || fields[5] is not ("0" or "1") ||
            !int.TryParse(fields[6], NumberStyles.None, CultureInfo.InvariantCulture, out int auto) ||
            !Enum.IsDefined((TTextAutoposition)auto))
            throw new CommandUnavailable("Unsupported PCB component text positioning");
        return new(PlacementCoordinate(fields[0], originX), PlacementCoordinate(fields[1], originY),
            PlacementNumber(fields[2]), PlacementCoordinate(fields[3], 0), PlacementCoordinate(fields[4], 0),
            fields[5] == "1", (TTextAutoposition)auto);
    }

    private static int PlacementCoordinate(string value, int origin)
    {
        var mils = PlacementNumber(value);
        if (Math.Abs(mils) > 100_000)
            throw new CommandUnavailable("PCB placement is outside the supported coordinate range");
        long position = (long)EDP.Utils.MilsToCoord(mils) + origin;
        if (position < PCBConstant.MinCoord || position > PCBConstant.MaxCoord)
            throw new CommandUnavailable("PCB placement is outside the managed editor coordinate range");
        return (int)position;
    }

    private static double PlacementNumber(string value) =>
        double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out double number) && double.IsFinite(number)
            ? number : throw new CommandUnavailable("Expected a finite PCB placement coordinate or angle");

    private object PcbComponentPins(JsonElement parameters)
    {
        if (client.GetDXPWorkspace()?.DM_FocusedProject() is null ||
            !parameters.TryGetProperty("designators", out var designators) ||
            designators.ValueKind != JsonValueKind.Array || designators.GetArrayLength() == 0)
            throw new CommandUnavailable("Expected a focused design project and a PCB designator array");
        var board = RequireActivePcb("");
        var originX = board.GetState_XOrigin();
        var originY = board.GetState_YOrigin();
        var components = new List<object>();
        foreach (var item in designators.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String)
                throw new CommandUnavailable("Expected a PCB designator string");
            string requested = item.GetString()!.Trim();
            var component = board.GetPcbComponentByRefDes(requested);
            if (component is null)
            {
                components.Add(new { designator = requested, pins = Array.Empty<object>() });
                continue;
            }

            double x = EDP.Utils.CoordToMils(component.GetState_XLocation() - originX);
            double y = EDP.Utils.CoordToMils(component.GetState_YLocation() - originY);
            double rotation = component.GetState_Rotation();
            double radians = rotation * Math.PI / 180;
            var (sin, cos) = Math.SinCos(radians);
            bool bottom = component.GetState_Layer() == TV6_Layer.eV6_BottomLayer;
            var pins = new List<object>();
            foreach (var primitive in PlacementPrimitives(component, PCB.TObjectId.ePadObject))
            {
                var pad = (IPCB_Pad)primitive;
                if (!pad.GetState_InComponent())
                    continue;
                double px = EDP.Utils.CoordToMils(pad.GetState_XLocation() - originX);
                double py = EDP.Utils.CoordToMils(pad.GetState_YLocation() - originY);
                double dx = px - x;
                double dy = py - y;
                // Preserve the baseline's distinct bottom-side inverse transform.
                double localX = bottom ? -(dx * cos - dy * sin) : dx * cos + dy * sin;
                double localY = bottom ? dx * sin + dy * cos : -dx * sin + dy * cos;
                var layer = new V7_Layer(pad.GetState_Layer());
                var shape = pad.GetState_ShapeOnLayer(layer) switch
                {
                    TShape.eRounded => "Round",
                    TShape.eRectangular => "Rectangular",
                    _ => throw new CommandUnavailable("This pad shape requires the DelphiScript display name")
                };
                pins.Add(new
                {
                    name = pad.GetState_Name(),
                    net = NetName(pad),
                    x = px,
                    y = py,
                    dx = Math.Round(localX * 10000) / 10000,
                    dy = Math.Round(localY * 10000) / 10000,
                    rotation = pad.GetState_Rotation(),
                    layer = LayerName(pad),
                    width = EDP.Utils.CoordToMils(pad.GetState_XSizeOnLayer(layer)),
                    height = EDP.Utils.CoordToMils(pad.GetState_YSizeOnLayer(layer)),
                    hole_size = EDP.Utils.CoordToMils(pad.GetState_HoleSize()),
                    shape
                });
            }
            components.Add(new { designator = ComponentDesignator(component), x, y, rotation, layer = LayerName(component), pins });
        }
        return Success(components);
    }

    private object ReadPlacementNets(JsonElement parameters)
    {
        if (client.GetDXPWorkspace()?.DM_FocusedProject() is null)
            throw new CommandUnavailable("There is no focused PCB project");
        var board = RequireActivePcb("");
        var (targets, missing) = PlacementTargets(board, parameters);
        var nets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var netNames = new List<string>();
        foreach (var (_, component) in targets)
        {
            foreach (var primitive in PlacementPrimitives(component, PCB.TObjectId.ePadObject))
            {
                var net = primitive.GetState_Net();
                if (net is not null)
                {
                    string name = net.GetState_Name();
                    if (nets.Add(name))
                        netNames.Add(name);
                }
            }
        }

        var pads = new List<object>();
        int originX = board.GetState_XOrigin();
        int originY = board.GetState_YOrigin();
        if (nets.Count != 0)
        {
            foreach (var primitive in BoardObjects(board, PCB.TObjectId.ePadObject))
            {
                var pad = (IPCB_Pad)primitive;
                var net = pad.GetState_Net();
                if (net is null)
                    continue;
                string netName = net.GetState_Name();
                if (!nets.Contains(netName))
                    continue;
                var component = pad.GetState_Component();
                pads.Add(new
                {
                    net = netName,
                    designator = component is null ? "" : ComponentDesignator(component),
                    pin = pad.GetState_Name(),
                    x = EDP.Utils.CoordToMils(pad.GetState_XLocation() - originX),
                    y = EDP.Utils.CoordToMils(pad.GetState_YLocation() - originY)
                });
            }
        }
        return Success(new { targets = targets.Select(x => x.Name).ToArray(),
            missing_designators = missing, net_names = netNames, pads });
    }

    private object CheckPcbPlacement(JsonElement parameters)
    {
        string boardPath = StringParameter(parameters, "board_path");
        if (boardPath.Length == 0 && client.GetDXPWorkspace()?.DM_FocusedProject() is null)
            throw new CommandUnavailable("There is no focused PCB project");
        var board = RequireActivePcb(boardPath);
        double clearance = 6;
        if (parameters.TryGetProperty("clearance_mils", out var value))
        {
            if (value.ValueKind != JsonValueKind.Number || !value.TryGetDouble(out clearance) || !double.IsFinite(clearance))
                throw new CommandUnavailable("Expected a finite PCB placement clearance");
            if (clearance <= 0)
                clearance = 6;
        }

        var (targets, missing) = PlacementTargets(board, parameters);
        var others = BoardObjects(board, PCB.TObjectId.eComponentObject)
            .Cast<IPCB_Component>()
            .Select(c => (Component: c, Name: ComponentDesignator(c), Layer: c.GetState_Layer(),
                Bounds: c.BoundingRectangleNoNameComment()))
            .ToArray();
        var processed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var violations = new List<Dictionary<string, object>>();
        int closePairs = 0;
        int originX = board.GetState_XOrigin();
        int originY = board.GetState_YOrigin();
        foreach (var (_, target) in targets)
        {
            string name = ComponentDesignator(target);
            var box = target.BoundingRectangleNoNameComment();
            var layer = target.GetState_Layer();
            foreach (var other in others)
            {
                if (other.Name == name || other.Layer != layer || processed.Contains(other.Name))
                    continue;
                var bounds = other.Bounds;
                double overlapX = EDP.Utils.CoordToMils(Math.Min(box.Right, bounds.Right) - Math.Max(box.Left, bounds.Left));
                double overlapY = EDP.Utils.CoordToMils(Math.Min(box.Top, bounds.Top) - Math.Max(box.Bottom, bounds.Bottom));
                bool overlap = overlapX > 0 && overlapY > 0;
                double separation = overlap ? 0 : Math.Max(-overlapX, -overlapY);
                if (separation >= clearance + 25)
                    continue;

                closePairs++;
                double distance = PlacementComponentDistance(board, target, other.Component);
                if (!overlap && distance >= clearance)
                    continue;
                var violation = new Dictionary<string, object>
                {
                    ["a"] = name,
                    ["b"] = other.Name,
                    ["layer"] = LayerName(target),
                    ["type"] = overlap ? "bounding_box_overlap" : "clearance",
                    ["distance_mils"] = Math.Round(distance * 100) / 100,
                };
                if (overlap)
                {
                    violation["overlap_x_mils"] = Math.Round(overlapX * 100) / 100;
                    violation["overlap_y_mils"] = Math.Round(overlapY * 100) / 100;
                }
                violation["b_x"] = EDP.Utils.CoordToMils(other.Component.GetState_XLocation() - originX);
                violation["b_y"] = EDP.Utils.CoordToMils(other.Component.GetState_YLocation() - originY);
                violations.Add(violation);
            }
            processed.Add(name);
        }
        return Success(new
        {
            board_path = board.GetState_FileName(),
            checked_count = targets.Count,
            clearance_mils = clearance,
            close_pairs_measured = closePairs,
            violation_count = violations.Count,
            missing_designators = missing,
            violations
        });
    }

    private static (List<(string Name, IPCB_Component Component)> Targets, List<string> Missing)
        PlacementTargets(IPCB_Board board, JsonElement parameters)
    {
        var names = new List<string>();
        if (parameters.TryGetProperty("designators", out var requested))
        {
            if (requested.ValueKind != JsonValueKind.Array)
                throw new CommandUnavailable("Expected a PCB designator array");
            foreach (var item in requested.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.String)
                    throw new CommandUnavailable("Expected a PCB designator string");
                names.Add(item.GetString()!.Trim());
            }
        }
        if (names.Count == 0)
        {
            int selectedCount = board.GetState_SelectecObjectCount();
            for (int index = 0; index < selectedCount; index++)
            {
                var selected = board.GetState_SelectecObject(index);
                if (selected?.GetState_ObjectID() == PCB.TObjectId.eComponentObject)
                    names.Add(ComponentDesignator((IPCB_Component)selected));
            }
        }

        var targets = new List<(string Name, IPCB_Component Component)>();
        var missing = new List<string>();
        foreach (string name in names)
        {
            var component = board.GetPcbComponentByRefDes(name);
            if (component is null)
                missing.Add(name);
            else
                targets.Add((name, component));
        }
        if (targets.Count == 0)
            throw new CommandUnavailable("No target components were found on the active PCB");
        return (targets, missing);
    }

    private static double PlacementComponentDistance(IPCB_Board board, IPCB_Component first, IPCB_Component second)
    {
        int minimum = int.MaxValue;
        var secondPrimitives = PlacementPrimitives(second)
            .Where(primitive => primitive.GetState_ObjectID() != PCB.TObjectId.eTextObject).ToArray();
        foreach (var a in PlacementPrimitives(first))
        {
            if (a.GetState_ObjectID() == PCB.TObjectId.eTextObject)
                continue;
            foreach (var b in secondPrimitives)
            {
                minimum = Math.Min(minimum, board.PrimPrimDistance(a, b));
                if (minimum == 0)
                    return 0;
            }
        }
        return EDP.Utils.CoordToMils(minimum);
    }

    private static IEnumerable<IPCB_Primitive> PlacementPrimitives(IPCB_Component component, params PCB.TObjectId[] kinds)
    {
        var iterator = component.GroupIterator_Create();
        try
        {
            iterator.SetState_FilterAll();
            if (kinds.Length != 0)
                iterator.AddFilter_ObjectSet(new PCB.TObjectSet(kinds));
            for (var primitive = iterator.FirstPCBObject(); primitive is not null; primitive = iterator.NextPCBObject())
                yield return primitive;
        }
        finally
        {
            component.GroupIterator_Destroy(ref iterator);
        }
    }
}
