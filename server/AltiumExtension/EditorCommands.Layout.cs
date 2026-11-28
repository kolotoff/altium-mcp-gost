using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using PCB;
using DXP;

namespace AltiumMcpSdk;

internal sealed partial class EditorCommands
{
    private static readonly PCB.TObjectId[] CopperKinds =
        [PCB.TObjectId.eTrackObject, PCB.TObjectId.eArcObject, PCB.TObjectId.eViaObject,
         PCB.TObjectId.eFillObject, PCB.TObjectId.eRegionObject];

    private readonly record struct LayoutArea(int Left, int Bottom, int Right, int Top)
    {
        internal bool Contains(PCB.CoordRect bounds) =>
            bounds.Left >= Left && bounds.Bottom >= Bottom && bounds.Right <= Right && bounds.Top <= Top;

        internal bool Intersects(PCB.CoordRect bounds) =>
            bounds.Left <= Right && bounds.Bottom <= Top && bounds.Right >= Left && bounds.Top >= Bottom;

        internal bool IntersectsInterior(PCB.CoordRect bounds) =>
            bounds.Left < Right && bounds.Bottom < Top && bounds.Right > Left && bounds.Top > Bottom;
    }

    private readonly record struct BoardOrigin(int X, int Y);

    private object ReadLayout(JsonElement parameters)
    {
        var board = RequireActivePcb(StringParameter(parameters, "board_path"));
        var wanted = new HashSet<string>(StringParameter(parameters, "layout_designators")
            .Split([';', '\r', '\n'], StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries),
            StringComparer.OrdinalIgnoreCase);
        var origin = new BoardOrigin(board.GetState_XOrigin(), board.GetState_YOrigin());
        bool includeTouching = BooleanParameter(parameters, "layout_touching");
        bool includePads = BooleanParameter(parameters, "layout_pads");
        bool includeComponentCopper = BooleanParameter(parameters, "layout_component_copper");

        var localNets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (wanted.Count != 0 && BooleanParameter(parameters, "layout_local_nets"))
            localNets = LayoutLocalNets(board, wanted);

        var found = new List<IPCB_Component>();
        var text = new StringBuilder();
        if (wanted.Count != 0)
        {
            foreach (var primitive in BoardObjects(board, PCB.TObjectId.eComponentObject))
            {
                var component = (IPCB_Component)primitive;
                string name = ComponentDesignator(component);
                if (wanted.Contains(name))
                {
                    found.Add(component);
                    text.Append("N|").AppendLine(name);
                }
            }
        }

        LayoutArea area;
        string specifiedArea = StringParameter(parameters, "layout_area");
        if (specifiedArea.Length != 0)
        {
            string[] values = specifiedArea.Split('|');
            if (values.Length != 4)
                throw new CommandUnavailable("Invalid PCB layout area");
            area = new LayoutArea(int.Parse(values[0], CultureInfo.InvariantCulture) + origin.X,
                int.Parse(values[1], CultureInfo.InvariantCulture) + origin.Y,
                int.Parse(values[2], CultureInfo.InvariantCulture) + origin.X,
                int.Parse(values[3], CultureInfo.InvariantCulture) + origin.Y);
        }
        else
        {
            if (found.Count == 0)
                return Error("None of the designators is on the board, and no area was given");
            int margin = parameters.TryGetProperty("layout_margin", out var value) ? value.GetInt32() : 0;
            var bounds = found.Select(component => component.BoundingRectangleNoNameComment()).ToList();
            area = new LayoutArea(bounds.Min(x => x.Left) - margin, bounds.Min(x => x.Bottom) - margin,
                bounds.Max(x => x.Right) + margin, bounds.Max(x => x.Top) + margin);
        }
        AddLayoutLine(text, $"O|{area.Left - origin.X}|{area.Bottom - origin.Y}|{area.Right - origin.X}|{area.Top - origin.Y}");

        if (wanted.Count == 0)
            foreach (var primitive in BoardObjects(board, PCB.TObjectId.eComponentObject))
            {
                var component = (IPCB_Component)primitive;
                if (area.Contains(component.BoundingRectangleNoNameComment()))
                    found.Add(component);
            }
        foreach (var component in found)
            AppendComponent(text, origin, component);

        // Hold the COM objects for the whole snapshot so their identity stays valid
        // across spatial, component and net inventory.
        var seen = new Dictionary<nint, IPCB_Primitive>();
        if (includePads)
            foreach (var primitive in SpatialObjects(board, area, [PCB.TObjectId.ePadObject]))
                if (MarkSeen(seen, primitive))
                    AppendPad(text, origin, (IPCB_Pad)primitive);

        foreach (var primitive in BoardObjects(board, PCB.TObjectId.ePolyObject))
        {
            var bounds = primitive.BoundingRectangle();
            if (area.IntersectsInterior(bounds) && (area.Contains(bounds) || includeTouching) && IsSignal(primitive))
                AppendPour(text, origin, (IPCB_Polygon)primitive);
        }

        int skipped = 0;
        foreach (var primitive in SpatialObjects(board, area, CopperKinds))
        {
            if ((!includeComponentCopper && primitive.GetState_InComponent()) || primitive.GetState_InPolygon() ||
                !MarkSeen(seen, primitive))
                continue;
            string net = NetName(primitive);
            if (area.Contains(primitive.BoundingRectangle()) || includeTouching ||
                (net.Length != 0 && localNets.Contains(net)))
                skipped += AppendCopper(text, origin, primitive, net);
        }

        if (includeComponentCopper)
            foreach (var primitive in BoardObjects(board, PCB.TObjectId.eComponentObject))
            {
                var component = (IPCB_Component)primitive;
                if (!area.Intersects(component.BoundingRectangleNoNameComment()))
                    continue;
                foreach (var child in GroupCopper(component))
                {
                    var bounds = child.BoundingRectangle();
                    if ((area.Contains(bounds) || includeTouching && area.Intersects(bounds)) &&
                        !child.GetState_InPolygon() && MarkSeen(seen, child))
                        skipped += AppendCopper(text, origin, child, NetName(child));
                }
            }

        if (localNets.Count != 0)
            foreach (var primitive in BoardObjects(board, CopperKinds))
            {
                if (primitive.GetState_InComponent() || primitive.GetState_InPolygon())
                    continue;
                string net = NetName(primitive);
                if (localNets.Contains(net) && MarkSeen(seen, primitive))
                    skipped += AppendCopper(text, origin, primitive, net);
            }

        AddLayoutLine(text, $"X|{skipped}");
        text.Append("B|").AppendLine(board.GetState_FileName());
        return Success(text.ToString());
    }

    private IPCB_Board RequireActivePcb(string wantedPath)
    {
        var board = PCB.GlobalVars.PCBServer?.GetCurrentPCBBoard();
        if (board is null)
            throw new CommandUnavailable("There is no active PCB editor");

        string active = NormalizedPath(client.GetCurrentView()?.GetOwnerDocument()?.GetFileName());
        string nativePath = board.GetState_FileName();
        string canonicalBoardPath = NormalizedPath(nativePath);
        if (!Path.GetExtension(canonicalBoardPath).Equals(".PcbDoc", StringComparison.OrdinalIgnoreCase)
            || active.Length == 0 || !string.Equals(active, canonicalBoardPath, StringComparison.OrdinalIgnoreCase))
            throw new CommandUnavailable("The active document and PCB editor disagree");
        if (wantedPath.Length != 0 &&
            !string.Equals(canonicalBoardPath, NormalizedPath(Path.GetFullPath(wantedPath)), StringComparison.OrdinalIgnoreCase))
            throw new CommandUnavailable("The requested PCB is not the active editor document");
        boardPath = nativePath;
        return board;
    }

    private static HashSet<string> LayoutLocalNets(IPCB_Board board, HashSet<string> wanted)
    {
        var mine = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var other = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var primitive in BoardObjects(board, PCB.TObjectId.ePadObject))
        {
            var net = primitive.GetState_Net();
            if (net is null)
                continue;
            var parent = primitive.GetState_InComponent() ? primitive.GetState_Component() : null;
            var names = parent is not null && wanted.Contains(ComponentDesignator(parent)) ? mine : other;
            names.Add(net.GetState_Name());
        }
        mine.ExceptWith(other);
        return mine;
    }

    private static void AppendComponent(StringBuilder destination, BoardOrigin origin, IPCB_Component component)
    {
        var name = component.GetState_Name();
        var comment = component.GetState_Comment();
        destination.Append(CultureInfo.InvariantCulture,
            $"K|{name.GetState_Text()}|{component.GetState_XLocation() - origin.X}|{component.GetState_YLocation() - origin.Y}");
        destination.Append(CultureInfo.InvariantCulture,
            $"|{LayoutAngle(component.GetState_Rotation())}|{LayerName(component)}|{!component.GetState_Moveable()}|{component.GetState_Pattern()}");
        AddLayoutTextPlacement(destination, origin, name, component.GetState_NameOn());
        AddLayoutTextPlacement(destination, origin, comment, component.GetState_CommentOn());
        AddLayoutLine(destination, $"|{(int)component.GetState_NameAutoPos()}|{(int)component.GetState_CommentAutoPos()}");
    }

    private static void AddLayoutTextPlacement(StringBuilder destination, BoardOrigin origin, IPCB_Text text, bool visible) =>
        destination.Append(CultureInfo.InvariantCulture,
                $"|{text.GetState_XLocation() - origin.X}|{text.GetState_YLocation() - origin.Y}|{LayoutAngle(text.GetState_Rotation())}")
            .Append(CultureInfo.InvariantCulture, $"|{text.GetState_Size()}|{text.GetState_Width()}|{visible}");

    private static void AppendPad(StringBuilder destination, BoardOrigin origin, IPCB_Pad pad)
    {
        var component = pad.GetState_InComponent() ? pad.GetState_Component() : null;
        var parent = component is null ? "" : ComponentDesignator(component);
        destination.Append(CultureInfo.InvariantCulture,
            $"P|{parent}|{pad.GetState_Name()}|{pad.GetState_XLocation() - origin.X}|{pad.GetState_YLocation() - origin.Y}|{LayerName(pad)}");
        destination.Append(CultureInfo.InvariantCulture,
            $"|{(int)pad.GetState_TopShape()}|{pad.GetState_TopXSize()}|{pad.GetState_TopYSize()}|{LayoutAngle(pad.GetState_Rotation())}");
        AddLayoutLine(destination, $"|{pad.GetState_HoleSize()}|{NetName(pad)}");
        if (pad.GetState_Layer() == TV6_Layer.eV6_MultiLayer && pad.GetState_Mode() != TPadMode.ePadMode_Simple)
        {
            var bounds = pad.BoundingRectangle();
            AddLayoutLine(destination, $"PB|{bounds.Left - origin.X}|{bounds.Bottom - origin.Y}|{bounds.Right - origin.X}|{bounds.Top - origin.Y}");
        }
    }

    private static int AppendCopper(StringBuilder destination, BoardOrigin origin, IPCB_Primitive primitive, string net)
    {
        var kind = primitive.GetState_ObjectID();
        if (kind == PCB.TObjectId.eViaObject)
        {
            var via = (IPCB_Via)primitive;
            AddLayoutLine(destination,
                $"V|{net}|{via.GetState_XLocation() - origin.X}|{via.GetState_YLocation() - origin.Y}|{via.GetState_Size()}|{via.GetState_HoleSize()}|{LayerName(via.GetState_LowLayer())}|{LayerName(via.GetState_HighLayer())}");
            return 0;
        }

        var regionKind = kind == PCB.TObjectId.eRegionObject ? ((IPCB_Region)primitive).GetState_Kind() : (TRegionKind?)null;
        bool isSignal = IsSignal(primitive);
        if (regionKind == TRegionKind.eRegionKind_Cutout &&
            (isSignal || primitive.GetState_Layer() == TV6_Layer.eV6_MultiLayer))
        {
            destination.Append("U|").AppendLine(LayerName(primitive));
            AppendRegionSegments(destination, origin, primitive);
            return 0;
        }

        if (primitive.GetState_IsKeepout() || !isSignal)
            return 1;
        string layer = LayerName(primitive);
        switch (kind)
        {
            case PCB.TObjectId.eTrackObject:
                var track = (IPCB_Track)primitive;
                AddLayoutLine(destination,
                    $"T|{layer}|{net}|{track.GetState_Width()}|{track.GetState_X1() - origin.X}|{track.GetState_Y1() - origin.Y}|{track.GetState_X2() - origin.X}|{track.GetState_Y2() - origin.Y}");
                return 0;
            case PCB.TObjectId.eArcObject:
                var arc = (IPCB_Arc)primitive;
                AddLayoutLine(destination,
                    $"A|{layer}|{net}|{arc.GetState_LineWidth()}|{arc.GetState_CenterX() - origin.X}|{arc.GetState_CenterY() - origin.Y}|{arc.GetState_Radius()}|{LayoutAngle(arc.GetState_StartAngle())}|{LayoutAngle(arc.GetState_EndAngle())}");
                return 0;
            case PCB.TObjectId.eFillObject:
                var fill = (IPCB_Fill)primitive;
                AddLayoutLine(destination,
                    $"F|{layer}|{net}|{fill.GetState_X1Location() - origin.X}|{fill.GetState_Y1Location() - origin.Y}|{fill.GetState_X2Location() - origin.X}|{fill.GetState_Y2Location() - origin.Y}|{LayoutAngle(fill.GetState_Rotation())}");
                return 0;
            case PCB.TObjectId.eRegionObject when regionKind == TRegionKind.eRegionKind_Copper:
                destination.Append("R|").Append(layer).Append('|').AppendLine(net);
                AppendRegionSegments(destination, origin, primitive);
                return 0;
            default:
                return 1;
        }
    }

    private static void AppendRegionSegments(StringBuilder destination, BoardOrigin origin, IPCB_Primitive region)
    {
        try
        {
            var shape = (IPCB_RegionShape)region;
            int count = shape.GetState_ShapeSegmentCount();
            for (int index = 0; index < count; index++)
                AppendOutlineSegment(destination, origin, shape.GetState_ShapeSegment(index));
        }
        catch (Exception error) when (error is InvalidCastException or COMException)
        {
            throw new CommandUnavailable("The installed SDK could not read the PCB region's outline");
        }
    }

    private static void AppendPour(StringBuilder destination, BoardOrigin origin, IPCB_Polygon pour)
    {
        // These two fields have no strongly typed getter in the Altium 26.11 SDK.
        // Only use its parameter export when both flags are available.
        string exported = "";
        try
        {
            pour.Export_ToParameters(ref exported);
        }
        catch (COMException)
        {
            throw new CommandUnavailable("The installed SDK could not export the polygon pour properties");
        }
        if (!TryReadExportedFlag(exported, "ObeyPolygonCutout", out bool obeyCutouts) ||
            !TryReadExportedFlag(exported, "OptimalVoidRotation", out bool optimalVoidRotation))
            throw new CommandUnavailable("The installed SDK cannot return both exact polygon pour flags");

        destination.Append(CultureInfo.InvariantCulture,
            $"G|{LayerName(pour)}|{NetName(pour)}|{pour.GetState_Name()}|{(int)pour.GetState_PolyHatchStyle()}|{(int)pour.GetState_PourOver()}");
        destination.Append(CultureInfo.InvariantCulture,
            $"|{pour.GetState_RemoveDead()}|{pour.GetState_RemoveIslandsByArea()}|{Math.Round(pour.GetState_IslandAreaThreshold() / 1E5)}");
        destination.Append(CultureInfo.InvariantCulture,
            $"|{pour.GetState_RemoveNarrowNecks()}|{pour.GetState_NeckWidthThreshold()}|{pour.GetState_Grid()}|{pour.GetState_TrackSize()}");
        AddLayoutLine(destination,
            $"|{pour.GetState_ArcApproximation()}|{pour.GetState_PourIndex()}|{pour.GetState_PrimitiveLock()}|{obeyCutouts}|{optimalVoidRotation}");
        int count = pour.GetState_PointCount();
        for (int index = 0; index < count; index++)
            AppendOutlineSegment(destination, origin, pour.GetState_Segments(index));
    }

    private static bool TryReadExportedFlag(string properties, string key, out bool value)
    {
        foreach (var field in properties.Split(['|', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            int separator = field.IndexOf('=');
            if (separator < 0 || !field[..separator].Trim().Equals(key, StringComparison.OrdinalIgnoreCase))
                continue;
            switch (field[(separator + 1)..].Trim().ToUpperInvariant())
            {
                case "TRUE":
                case "1":
                case "T":
                    value = true;
                    return true;
                case "FALSE":
                case "0":
                case "F":
                    value = false;
                    return true;
            }
        }
        value = false;
        return false;
    }

    private static void AppendOutlineSegment(StringBuilder destination, BoardOrigin origin, PolySegment segment)
    {
        if (segment.Kind == TPolySegmentType.ePolySegmentArc)
            AddLayoutLine(destination,
                $"S|A|{segment.Vx - origin.X}|{segment.Vy - origin.Y}|{segment.Cx - origin.X}|{segment.Cy - origin.Y}|{segment.Radius}|{LayoutAngle(segment.Angle1)}|{LayoutAngle(segment.Angle2)}");
        else
            AddLayoutLine(destination, $"S|L|{segment.Vx - origin.X}|{segment.Vy - origin.Y}");
    }

    private static IEnumerable<IPCB_Primitive> SpatialObjects(IPCB_Board board, LayoutArea area, PCB.TObjectId[] ids)
    {
        var iterator = board.SpatialIterator_Create();
        try
        {
            iterator.AddFilter_ObjectSet(new PCB.TObjectSet(ids));
            iterator.AddFilter_LayerSet_2(PCBConstant.AllLayersSet);
            iterator.AddFilter_Area(area.Left, area.Bottom, area.Right, area.Top);
            for (var primitive = iterator.FirstPCBObject(); primitive is not null; primitive = iterator.NextPCBObject())
                yield return primitive;
        }
        finally
        {
            board.SpatialIterator_Destroy(ref iterator);
        }
    }

    private static IEnumerable<IPCB_Primitive> GroupCopper(IPCB_Component component)
    {
        var iterator = component.GroupIterator_Create();
        try
        {
            iterator.SetState_FilterAll();
            iterator.AddFilter_ObjectSet(new PCB.TObjectSet(CopperKinds));
            for (var primitive = iterator.FirstPCBObject(); primitive is not null; primitive = iterator.NextPCBObject())
                yield return primitive;
        }
        finally
        {
            component.GroupIterator_Destroy(ref iterator);
        }
    }

    private static bool MarkSeen(Dictionary<nint, IPCB_Primitive> seen, IPCB_Primitive item)
    {
        nint identity = Marshal.GetIUnknownForObject(item);
        try
        {
            return seen.TryAdd(identity, item);
        }
        finally
        {
            Marshal.Release(identity);
        }
    }

    private static string ComponentDesignator(IPCB_Component component) => component.GetState_Name().GetState_Text();

    private static string NetName(IPCB_Primitive primitive) => primitive.GetState_Net()?.GetState_Name() ?? "";

    private static int LayoutAngle(double value) => (int)Math.Round(value * 1000);

    private static bool IsSignal(IPCB_Primitive primitive) =>
        primitive.GetState_Layer() is >= TV6_Layer.eV6_TopLayer and <= TV6_Layer.eV6_BottomLayer;

    private static bool BooleanParameter(JsonElement parameters, string name) =>
        parameters.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;

    private static void AddLayoutLine(StringBuilder destination, FormattableString line) =>
        destination.AppendLine(FormattableString.Invariant(line));
}
