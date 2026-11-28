using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using DXP;
using PCB;
using SCH;

namespace AltiumMcpSdk;

// Dispatches only on the Altium editor thread. Results contain no native objects.
internal sealed partial class EditorCommands(IClient client)
{
    internal IReadOnlyList<string> Supported { get; } =
        ["list_open_documents", "get_board_summary", "get_schematic_data", "get_schematic_pins",
         "get_layout", "get_symbol_primitives", "get_component_pins", "place_components", "create_schematic_symbol",
         "get_net_connections", "check_placement", "create_symbols_batch", "get_unrouted_connections",
         "net_rules", "place_copper", "pcb_routing_batch"];
    internal IReadOnlyList<string> Mutations { get; } =
        ["place_components", "create_schematic_symbol", "create_symbols_batch", "get_unrouted_connections",
         "net_rules", "place_copper", "pcb_routing_batch"];
    private string? boardPath;
    private string? projectPath;

    internal object Execute(string command, JsonElement parameters, string requestId)
    {
        boardPath = null;
        projectPath = null;
        var workspace = client.GetDXPWorkspace();
        var project = workspace?.DM_FocusedProject();
        if (project is null && workspace?.DM_ProjectCount() > 0)
            throw new CommandUnavailable("Let the DelphiScript bridge restore the previous design project");
        string? focusedProject = project?.DM_ProjectFullPath();
        if (Path.GetExtension(focusedProject)?.Equals(".PrjScr",
                StringComparison.OrdinalIgnoreCase) == true)
            throw new CommandUnavailable("The selected project is a script project");
        if (!string.IsNullOrEmpty(focusedProject))
            projectPath = focusedProject;

        return command switch
        {
            "list_open_documents" => Success(ListOpenDocuments()),
            "get_board_summary" => BoardSummary(),
            "get_schematic_data" => SchematicData(project, parameters),
            "get_schematic_pins" => SchematicPins(parameters),
            "get_layout" => ReadLayout(parameters),
            "get_symbol_primitives" => ReadSymbolPrimitives(parameters),
            "get_component_pins" => PcbComponentPins(parameters),
            "place_components" => PlacePcbComponents(parameters),
            "create_schematic_symbol" => CreateSchematicSymbol(parameters),
            "get_net_connections" => ReadPlacementNets(parameters),
            "check_placement" => CheckPcbPlacement(parameters),
            "create_symbols_batch" => CreateSymbolsBatch(parameters),
            "get_unrouted_connections" => ReadUnroutedConnections(parameters),
            "net_rules" => ReadNetRules(parameters),
            "place_copper" => PlaceCopper(parameters),
            "pcb_routing_batch" => ApplyGuardedRoutingBatch(parameters, requestId),
            _ => throw new CommandUnavailable("The command is unavailable in the managed bridge")
        };
    }

    private object ListOpenDocuments()
    {
        string activePath = NormalizedPath(client.GetCurrentView()?.GetOwnerDocument()?.GetFileName());
        var documents = new List<object>();
        int modules = client.GetCount();
        for (int moduleIndex = 0; moduleIndex < modules; moduleIndex++)
        {
            var module = client.GetServerModule(moduleIndex);
            if (module is null)
                continue;
            int count = module.GetDocumentCount();
            for (int documentIndex = 0; documentIndex < count; documentIndex++)
            {
                var document = module.GetDocuments(documentIndex);
                string? path = document?.GetFileName();
                if (string.IsNullOrEmpty(path))
                    continue;
                documents.Add(new
                {
                    path,
                    kind = document!.GetKind(),
                    modified = document.GetModified(),
                    active = string.Equals(NormalizedPath(path), activePath, StringComparison.OrdinalIgnoreCase)
                });
            }
        }
        return new { success = true, documents };
    }

    private object BoardSummary()
    {
        var board = RequireActivePcb("");
        string path = board.GetState_FileName();

        int originX = board.GetState_XOrigin();
        int originY = board.GetState_YOrigin();
        var outline = board.GetState_BoardOutline();
        var bounds = outline.BoundingRectangle();
        var dimensions = new List<object>();
        foreach (var dimension in BoardObjects(board, PCB.TObjectId.eDimensionObject))
        {
            var rect = dimension.BoundingRectangle();
            dimensions.Add(new
            {
                layer = LayerName(dimension),
                x1_mm = RoundedMillimeters(rect.Left - originX),
                y1_mm = RoundedMillimeters(rect.Bottom - originY),
                x2_mm = RoundedMillimeters(rect.Right - originX),
                y2_mm = RoundedMillimeters(rect.Top - originY)
            });
        }

        int totalVias = 0;
        var holeSizes = new Dictionary<double, int>();
        foreach (var primitive in BoardObjects(board, PCB.TObjectId.eViaObject))
        {
            totalVias++;
            Increment(holeSizes, RoundedMillimeters(((IPCB_Via)primitive).GetState_HoleSize()));
        }

        int top = 0;
        int bottom = 0;
        foreach (var component in BoardObjects(board, PCB.TObjectId.eComponentObject))
        {
            if (component.GetState_Layer() == TV6_Layer.eV6_BottomLayer)
                bottom++;
            else
                top++;
        }

        var layerCounts = new Dictionary<(string Layer, string Owner), int>();
        var overlayTexts = new List<object>();
        foreach (var primitive in BoardObjects(board, PCB.TObjectId.eTrackObject, PCB.TObjectId.eArcObject,
                     PCB.TObjectId.eTextObject, PCB.TObjectId.eFillObject, PCB.TObjectId.eRegionObject,
                     PCB.TObjectId.ePadObject))
        {
            string layer = LayerName(primitive);
            bool inComponent = primitive.GetState_InComponent();
            Increment(layerCounts, (layer, inComponent ? "component" : "free"));
            if (!inComponent && primitive.GetState_ObjectID() == PCB.TObjectId.eTextObject &&
                layer is "Top Overlay" or "Bottom Overlay")
                overlayTexts.Add(new { layer, text = ((IPCB_Text)primitive).GetState_Text() ?? "" });
        }

        return Success(new
        {
            pcb_path = path,
            origin_abs_x_mm = RoundedMillimeters(originX),
            origin_abs_y_mm = RoundedMillimeters(originY),
            board_outline = new
            {
                x1_mm = RoundedMillimeters(bounds.Left - originX),
                y1_mm = RoundedMillimeters(bounds.Bottom - originY),
                x2_mm = RoundedMillimeters(bounds.Right - originX),
                y2_mm = RoundedMillimeters(bounds.Top - originY),
                width_mm = RoundedMillimeters(bounds.Right - bounds.Left),
                height_mm = RoundedMillimeters(bounds.Top - bounds.Bottom),
                vertex_count = outline.GetState_PointCount()
            },
            dimensions,
            via_count = totalVias,
            vias_by_hole = holeSizes.Select(x => new { hole_mm = x.Key, count = x.Value }).ToArray(),
            components_top = top,
            components_bottom = bottom,
            layer_contents = layerCounts.Select(x => new { layer = x.Key.Layer, owner = x.Key.Owner, count = x.Value }).ToArray(),
            overlay_texts = overlayTexts
        });
    }

    private object SchematicData(IDXPProject? project, JsonElement parameters)
    {
        if (project is null)
            throw new CommandUnavailable("Altium has no focused design project");
        var editor = SCH.GlobalVars.SchServer?.GetCurrentSchDocument();
        var active = client.GetCurrentView()?.GetOwnerDocument();
        if (editor?.GetState_ObjectId() != SCH.TObjectId.eSheet ||
            !string.Equals(active?.GetKind(), "SCH", StringComparison.OrdinalIgnoreCase) ||
            !SameSymbolLibrary(editor.GetState_DocumentName(), active!.GetFileName()))
            throw new CommandUnavailable("The schematic sheet and active editor do not agree");

        HashSet<string> filter = new(StringComparer.Ordinal);
        if (parameters.TryGetProperty("filter_designators", out var filters))
        {
            if (filters.ValueKind != JsonValueKind.Array)
                throw new CommandUnavailable("Expected a schematic designator array");
            foreach (var item in filters.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.String)
                    throw new CommandUnavailable("Expected a schematic designator string");
                filter.Add(item.GetString()!);
            }
        }

        var components = new List<object>();
        bool hasComponents = false;
        int documentCount = project.DM_LogicalDocumentCount();
        for (int index = 0; index < documentCount; index++)
        {
            var logical = project.DM_LogicalDocuments(index);
            if (logical?.DM_DocumentKind() != "SCH")
                continue;
            string path = logical.DM_FullPath();
            var document = SchematicDocument(path, showOpened: false);
            if (document is null)
                continue;
            foreach (var item in SchematicObjects(document, SCH.TObjectId.eSchComponent))
            {
                var component = (ISch_Component)item;
                hasComponents = true;
                string designator = Designator(component);
                if (filter.Count != 0 && !filter.Contains(designator))
                    continue;

                var location = component.GetState_Location();
                var bounds = component.BoundingRectangle();
                var properties = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (var candidate in SchematicObjects(component, SCH.TObjectId.eParameter))
                {
                    var parameter = (ISch_Parameter)candidate;
                    properties[parameter.GetState_Name() ?? ""] = parameter.GetState_Text() ?? "";
                }
                components.Add(new
                {
                    designator,
                    sheet = path,
                    schematic_x = EDP.Utils.CoordToMils(location.X),
                    schematic_y = EDP.Utils.CoordToMils(location.Y),
                    schematic_width = EDP.Utils.CoordToMils(bounds.Right - bounds.Left),
                    schematic_height = EDP.Utils.CoordToMils(bounds.Bottom - bounds.Top),
                    schematic_rotation = (int)component.GetState_Orientation() * 90,
                    parameters = properties
                });
            }
        }
        return Success(filter.Count != 0 ? new { has_components = hasComponents, components } : components);
    }

    private object SchematicPins(JsonElement parameters)
    {
        string path = StringParameter(parameters, "sheet_path");
        string filter = StringParameter(parameters, "designators");
        var document = SchematicDocument(path, showOpened: true);
        if (document is null)
            return Error(File.Exists(path) ? $"Altium could not open the sheet {path}" : $"Sheet not found: {path}");

        var pins = new List<object>();
        foreach (var item in SchematicObjects(document, SCH.TObjectId.eSchComponent))
        {
            var component = (ISch_Component)item;
            string designator = Designator(component);
            if (filter.Length != 0 && !filter.Contains($"|{designator}|", StringComparison.OrdinalIgnoreCase))
                continue;
            int part = component.GetState_CurrentPartID();
            byte displayMode = component.GetState_DisplayMode();
            foreach (var candidate in SchematicObjects(component, SCH.TObjectId.ePin))
            {
                var pin = (ISch_Pin)candidate;
                int owner = pin.GetState_OwnerPartId();
                if ((owner != 0 && owner != part) || pin.GetState_OwnerPartDisplayMode() != displayMode)
                    continue;

                var location = pin.GetState_Location();
                int x = location.X;
                int y = location.Y;
                int length = pin.GetState_PinLength();
                switch (pin.GetState_Orientation())
                {
                    case TRotationBy90.eRotate0: x += length; break;
                    case TRotationBy90.eRotate90: y += length; break;
                    case TRotationBy90.eRotate180: x -= length; break;
                    case TRotationBy90.eRotate270: y -= length; break;
                }
                pins.Add(new
                {
                    designator,
                    part,
                    pin = pin.GetState_Designator() ?? "",
                    name = pin.GetState_Name() ?? "",
                    x,
                    y,
                    electrical = (int)pin.GetState_Electrical(),
                    hidden = pin.GetState_IsHidden()
                });
            }
        }
        return Success(new { success = true, count = pins.Count, pins });
    }

    private ISch_Document? SchematicDocument(string path, bool showOpened)
    {
        if (string.IsNullOrEmpty(path))
            return null;
        var existing = SCH.GlobalVars.SchServer?.GetSchDocumentByPath(path);
        if (existing is not null || !File.Exists(path))
            return existing;

        var opened = client.OpenDocument("SCH", path);
        if (opened is not null && showOpened)
            client.ShowDocument(opened);
        return SCH.GlobalVars.SchServer?.GetSchDocumentByPath(path);
    }

    private static IEnumerable<IPCB_Primitive> BoardObjects(IPCB_Board board, params PCB.TObjectId[] ids)
    {
        var iterator = board.BoardIterator_Create();
        try
        {
            iterator.AddFilter_ObjectSet(new PCB.TObjectSet(ids));
            iterator.AddFilter_LayerSet_2(PCBConstant.AllLayersSet);
            iterator.AddFilter_Method(TIterationMethod.eProcessAll);
            for (var obj = iterator.FirstPCBObject(); obj is not null; obj = iterator.NextPCBObject())
                yield return obj;
        }
        finally
        {
            board.BoardIterator_Destroy(ref iterator);
        }
    }

    private static IEnumerable<ISch_BasicContainer> SchematicObjects(ISch_BasicContainer owner, SCH.TObjectId id)
    {
        var iterator = owner.SchIterator_Create();
        try
        {
            iterator.AddFilter_ObjectSet(new SCH.TObjectSet(id));
            for (var obj = iterator.FirstSchObject(); obj is not null; obj = iterator.NextSchObject())
                yield return obj;
        }
        finally
        {
            owner.SchIterator_Destroy(ref iterator);
        }
    }

    private static string LayerName(IPCB_Primitive primitive) => LayerName(primitive.GetState_V7Layer());

    private static string LayerName(V7_LayerBase layer)
    {
        string name = EDP.Utils.LayerToString(new V7_Layer(layer));
        return NumberedLayer().Replace(name, "$1 $2");
    }

    [GeneratedRegex(@"^(Mechanical Layer|Mid Layer|Internal Plane)([0-9]+)$", RegexOptions.CultureInvariant)]
    private static partial Regex NumberedLayer();

    private static double RoundedMillimeters(int coordinate) =>
        Math.Round(EDP.Utils.CoordToMMs(coordinate) * 10000) / 10000;

    private static void Increment<TKey>(Dictionary<TKey, int> counts, TKey key) where TKey : notnull =>
        counts[key] = counts.GetValueOrDefault(key) + 1;

    private static string Designator(ISch_Component component) => component.GetState_SchDesignator()?.GetState_Text() ?? "";

    private static string NormalizedPath(string? path)
    {
        string normalized = (path ?? "").Trim().Replace('/', '\\');
        bool unc = normalized.StartsWith(@"\\", StringComparison.Ordinal);
        return (unc ? @"\\" : "") + string.Join('\\', normalized[(unc ? 2 : 0)..].Split('\\', StringSplitOptions.RemoveEmptyEntries));
    }

    private static string StringParameter(JsonElement parameters, string key) =>
        parameters.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString()! : "";

    internal object RememberTargets(object result) => result is EditorReply reply
        ? reply with { ManagedBoardPath = boardPath, ManagedProjectPath = projectPath }
        : result;

    internal static EditorReply Success(object result) => new(true, Result: result);
    internal static EditorReply Error(string message, bool uncertain = false) =>
        new(false, Error: message, ExecutionState: uncertain ? "unknown" : null);
}

internal sealed record EditorReply(bool Success,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] object? Result = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Error = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? ExecutionState = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? ManagedBoardPath = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? ManagedProjectPath = null);

internal sealed class CommandUnavailable(string message) : Exception(message);
