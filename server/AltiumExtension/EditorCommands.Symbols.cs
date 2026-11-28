using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;
using DXP;
using SCH;

namespace AltiumMcpSdk;

internal sealed partial class EditorCommands
{
    private static readonly string[] TextJustifications =
        ["bottom_left", "bottom_center", "bottom_right", "center_left", "center",
         "center_right", "top_left", "top_center", "top_right"];

    private object ReadSymbolPrimitives(JsonElement parameters)
    {
        string requestedPath = StringParameter(parameters, "library_path");
        string symbolName = StringParameter(parameters, "symbol_name");
        var library = FocusedSymbolLibrary();
        var activeDocument = client.GetCurrentView()?.GetOwnerDocument();
        if (requestedPath.Length != 0)
        {
            if (!File.Exists(requestedPath))
                return Error($"Library file not found: {requestedPath}");
            string targetPath = SymbolLibraryPath(requestedPath);
            if (!SameSymbolLibrary(activeDocument?.GetFileName(), targetPath) ||
                !SameSymbolLibrary(library?.GetState_DocumentName(), targetPath))
                throw new CommandUnavailable("The requested schematic library is not active in both editor views");
        }

        if (library is null)
            return Error("No schematic library is open (provide library_path or open a .SchLib)");
        string libraryPath = library.GetState_DocumentName();
        if (!string.Equals(activeDocument?.GetKind(), "SCHLIB", StringComparison.OrdinalIgnoreCase) ||
            !SameSymbolLibrary(activeDocument!.GetFileName(), libraryPath))
            throw new CommandUnavailable("The schematic library and active editor do not agree");

        string libraryName = Path.GetFileName(libraryPath);
        if (symbolName.Length == 0)
        {
            var symbols = Symbols(library).Select(CountSymbolPrimitives).ToList();
            return Success(new { library_name = libraryName, symbol_count = symbols.Count, symbols });
        }

        var fontManager = SCH.GlobalVars.SchServer.GetState_FontManager();
        if (symbolName == "*")
        {
            var symbols = Symbols(library).Select(component => DescribeSymbol(component, fontManager)).ToList();
            return Success(new { library_name = libraryName, symbol_count = symbols.Count, symbols });
        }

        var match = Symbols(library).LastOrDefault(component =>
            string.Equals(component.GetState_LibReference(), symbolName, StringComparison.OrdinalIgnoreCase));
        if (match is null)
            return Error($"Symbol not found in library: {symbolName}");
        return Success(DescribeSymbol(match, fontManager, libraryName));
    }

    private static ISch_Lib? FocusedSymbolLibrary()
    {
        var document = SCH.GlobalVars.SchServer?.GetCurrentSchDocument();
        return document?.GetState_ObjectId() == TObjectId.eSchLib ? (ISch_Lib)document : null;
    }

    private static string SymbolLibraryPath(string path) => Path.GetFullPath(path.Replace('/', '\\'));

    private static bool SameSymbolLibrary(string? first, string? second) =>
        !string.IsNullOrEmpty(first) && !string.IsNullOrEmpty(second) &&
        string.Equals(SymbolLibraryPath(first), SymbolLibraryPath(second), StringComparison.OrdinalIgnoreCase);

    private static IEnumerable<ISch_Component> Symbols(ISch_Lib owner)
    {
        var iterator = owner.SchLibIterator_Create();
        try
        {
            iterator.AddFilter_ObjectSet(new TObjectSet(TObjectId.eSchComponent));
            for (var item = iterator.FirstSchObject(); item is not null; item = iterator.NextSchObject())
                yield return (ISch_Component)item;
        }
        finally
        {
            owner.SchIterator_Destroy(ref iterator);
        }
    }

    private static IEnumerable<ISch_BasicContainer> SymbolPrimitives(ISch_Component owner)
    {
        var iterator = owner.SchIterator_Create();
        try
        {
            for (var item = iterator.FirstSchObject(); item is not null; item = iterator.NextSchObject())
                yield return item;
        }
        finally
        {
            owner.SchIterator_Destroy(ref iterator);
        }
    }

    private static object CountSymbolPrimitives(ISch_Component component)
    {
        var result = new Dictionary<string, object?>
        {
            ["name"] = component.GetState_LibReference() ?? "",
            ["description"] = component.GetState_ComponentDescription() ?? "",
            ["part_count"] = component.GetState_PartCountNoPart0()
        };
        var counts = new Dictionary<string, int>();
        foreach (var primitive in SymbolPrimitives(component))
        {
            string? key = primitive.GetState_ObjectId() switch
            {
                TObjectId.ePin => "pins",
                TObjectId.eRectangle => "rectangles",
                TObjectId.eLine => "lines",
                TObjectId.ePolyline => "polylines",
                TObjectId.ePolygon => "polygons",
                TObjectId.eArc => "arcs",
                TObjectId.eEllipticalArc => "elliptical_arcs",
                TObjectId.eEllipse => "ellipses",
                TObjectId.eBezier => "beziers",
                TObjectId.ePie => "pies",
                TObjectId.eRoundRectangle => "round_rectangles",
                TObjectId.eLabel => "labels",
                TObjectId.eParameter or TObjectId.eDesignator => null,
                _ => "other"
            };
            if (key is not null)
                counts[key] = counts.GetValueOrDefault(key) + 1;
        }
        foreach (var (type, count) in counts)
            result[type] = count;
        return result;
    }

    private static Dictionary<string, object?> DescribeSymbol(ISch_Component component, ISch_FontManager fontManager,
        string? libraryName = null)
    {
        var comment = component.GetState_SchComment();
        var parameters = new List<object>();
        foreach (var parameter in OwnedSymbolParameters(component))
        {
            string name = parameter.GetState_Name() ?? "";
            if (name.Equals("COMMENT", StringComparison.OrdinalIgnoreCase))
                continue;

            var location = parameter.GetState_Location();
            int fontId = parameter.GetState_FontId();
            int justification = (int)parameter.GetState_Justification();
            parameters.Add(new
            {
                name,
                value = parameter.GetState_Text() ?? "",
                visible = !parameter.GetState_IsHidden(),
                x = SymbolMils(location.X),
                y = SymbolMils(location.Y),
                justification = justification >= 0 && justification < TextJustifications.Length
                    ? TextJustifications[justification] : "",
                autoposition = parameter.GetState_Autoposition(),
                font = new { name = fontManager.GetState_FontName(fontId) ?? "", size = fontManager.GetState_Size(fontId) }
            });
        }

        var primitives = new List<object>();
        foreach (var item in SymbolPrimitives(component))
        {
            try
            {
                var primitive = DescribeSymbolPrimitive(item);
                if (primitive is not null)
                    primitives.Add(primitive);
            }
            catch (Exception)
            {
                // A single unreadable primitive is reported without losing the rest of the dump.
                primitives.Add(new { type = "unreadable" });
            }
        }
        var result = new Dictionary<string, object?>();
        if (libraryName is not null)
            result["library_name"] = libraryName;
        result["symbol_name"] = component.GetState_LibReference() ?? "";
        result["description"] = component.GetState_ComponentDescription() ?? "";
        result["part_count"] = component.GetState_PartCountNoPart0();
        result["comment"] = new { text = comment?.GetState_Text() ?? "", visible = comment is not null && !comment.GetState_IsHidden() };
        result["parameters"] = parameters;
        result["primitives"] = primitives;
        return result;
    }

    private static IEnumerable<ISch_Parameter> OwnedSymbolParameters(ISch_GraphicalObject owner)
    {
        var ownerType = owner.GetState_ObjectId();
        string? ownerHandle = owner.GetState_Handle();
        foreach (var item in SchematicObjects(owner, TObjectId.eParameter))
        {
            var parameter = (ISch_Parameter)item;
            var container = parameter.GetState_SchBasicContainer();
            if (container is not null && (ReferenceEquals(container, owner) ||
                (!string.IsNullOrEmpty(ownerHandle) && ownerHandle == container.GetState_Handle()) ||
                (ownerType == TObjectId.eSchComponent && container.GetState_ObjectId() == TObjectId.eSchLib)))
                yield return parameter;
        }
    }

    private static Dictionary<string, object?>? DescribeSymbolPrimitive(ISch_BasicContainer primitive)
    {
        var id = primitive.GetState_ObjectId();
        var result = new Dictionary<string, object?>();
        switch (id)
        {
            case TObjectId.eParameter or TObjectId.eDesignator or TObjectId.eImplementation or TObjectId.eImplementationMap:
                return null;
            case TObjectId.ePin:
                DescribeSymbolPin(result, (ISch_Pin)primitive);
                break;
            case TObjectId.eLine:
                var line = (ISch_Line)primitive;
                result["type"] = "line";
                SymbolCoordinates(result, "x1", "y1", line.GetState_Location());
                SymbolCoordinates(result, "x2", "y2", line.GetState_Corner());
                result["line_width"] = (int)line.GetState_LineWidth();
                break;
            case TObjectId.eRectangle or TObjectId.eRoundRectangle:
                var rectangle = (ISch_Rectangle)primitive;
                result["type"] = id == TObjectId.eRectangle ? "rectangle" : "round_rectangle";
                SymbolCoordinates(result, "x1", "y1", rectangle.GetState_Location());
                SymbolCoordinates(result, "x2", "y2", rectangle.GetState_Corner());
                if (id == TObjectId.eRoundRectangle)
                {
                    var rounded = (ISch_RoundRectangle)primitive;
                    result["corner_x_radius"] = SymbolMils(rounded.GetState_CornerXRadius());
                    result["corner_y_radius"] = SymbolMils(rounded.GetState_CornerYRadius());
                }
                result["line_width"] = rectangle.Internal_GetState_LineWidth();
                result["is_solid"] = rectangle.GetState_IsSolid();
                break;
            case TObjectId.ePolygon or TObjectId.ePolyline or TObjectId.eBezier:
                var vertices = (ISch_Polygon)primitive;
                result["type"] = id == TObjectId.ePolygon ? "polygon" : id == TObjectId.ePolyline ? "polyline" : "bezier";
                result["line_width"] = (int)vertices.GetState_LineWidth();
                if (id == TObjectId.ePolygon)
                    result["is_solid"] = vertices.GetState_IsSolid();
                var points = new List<object>();
                int count = vertices.GetState_VerticesCount();
                for (int i = 1; i <= count; i++)
                {
                    var point = vertices.GetState_Vertex(i);
                    points.Add(new { x = SymbolMils(point.X), y = SymbolMils(point.Y) });
                }
                result["vertices"] = points;
                break;
            case TObjectId.eArc or TObjectId.eEllipticalArc or TObjectId.ePie:
                var arc = (ISch_Arc)primitive;
                result["type"] = id == TObjectId.eArc ? "arc" : id == TObjectId.eEllipticalArc ? "elliptical_arc" : "pie";
                SymbolCoordinates(result, "cx", "cy", arc.GetState_Location());
                result["radius"] = SymbolMils(arc.GetState_Radius());
                if (id == TObjectId.eEllipticalArc)
                    result["secondary_radius"] = SymbolMils(((ISch_EllipticalArc)primitive).GetState_SecondaryRadius());
                result["start_angle"] = arc.GetState_StartAngle();
                result["end_angle"] = arc.GetState_EndAngle();
                if (id == TObjectId.ePie)
                    result["is_solid"] = ((ISch_Pie)primitive).GetState_IsSolid();
                result["line_width"] = (int)arc.GetState_LineWidth();
                break;
            case TObjectId.eEllipse:
                var ellipse = (ISch_Ellipse)primitive;
                result["type"] = "ellipse";
                SymbolCoordinates(result, "cx", "cy", ellipse.GetState_Location());
                result["radius"] = SymbolMils(ellipse.GetState_Radius());
                result["secondary_radius"] = SymbolMils(ellipse.GetState_SecondaryRadius());
                result["is_solid"] = ellipse.GetState_IsSolid();
                result["line_width"] = (int)ellipse.GetState_LineWidth();
                break;
            case TObjectId.eLabel:
                var label = (ISch_Label)primitive;
                result["type"] = "label";
                result["text"] = label.GetState_Text() ?? "";
                SymbolCoordinates(result, "x", "y", label.GetState_Location());
                break;
            default:
                return new Dictionary<string, object?> { ["type"] = "unknown", ["object_id"] = (int)id };
        }

        result["owner_part_id"] = ((ISch_GraphicalObject)primitive).GetState_OwnerPartId();
        return result;
    }

    private static void SymbolCoordinates(Dictionary<string, object?> result, string x, string y, DXP.Point point)
    {
        result[x] = SymbolMils(point.X);
        result[y] = SymbolMils(point.Y);
    }

    // DelphiScript rounds the fractional part after converting to binary mils.
    private static double SymbolMils(int coordinate)
    {
        double mils = coordinate / 10_000.0;
        double whole = Math.Truncate(mils);
        double thousandths = Math.Round((mils - whole) * 1000, MidpointRounding.ToEven);
        return (whole * 1000 + thousandths) / 1000;
    }

    private static void DescribeSymbolPin(Dictionary<string, object?> result, ISch_Pin pin)
    {
        result["type"] = "pin";
        result["pin_number"] = pin.GetState_Designator() ?? "";
        result["pin_name"] = pin.GetState_Name() ?? "";
        result["electrical"] = (int)pin.GetState_Electrical();
        result["orientation"] = (int)pin.GetState_Orientation();
        SymbolCoordinates(result, "x", "y", pin.GetState_Location());
        result["length"] = SymbolMils(pin.GetState_PinLength());
        result["show_name"] = pin.GetState_ShowName();
        result["show_designator"] = pin.GetState_ShowDesignator();
        result["description"] = pin.GetState_Description() ?? "";
        result["symbol_inside"] = IeeeSymbolName(pin.GetState_Symbol_Inner());
        result["symbol_inside_edge"] = IeeeSymbolName(pin.GetState_Symbol_InnerEdge());
        result["symbol_outside_edge"] = IeeeSymbolName(pin.GetState_Symbol_OuterEdge());
        result["symbol_outside"] = IeeeSymbolName(pin.GetState_Symbol_Outer());
        var parameters = OwnedSymbolParameters(pin).Select(parameter =>
            new { name = parameter.GetState_Name() ?? "", value = parameter.GetState_Text() ?? "" }).ToList();
        if (parameters.Count != 0)
            result["parameters"] = parameters;
        var functions = SymbolPinFunctions(pin);
        if (functions.Length != 0)
            result["functions"] = functions;
    }

    private static string[] SymbolPinFunctions(ISch_Pin pin)
    {
        // Skip the expensive native export when the pin has no defined functions.
        int count = pin.GetDefinedFunctionsCount();
        if (count == 0)
            return [];
        string[] pairs = pin.ExportToParameters().Split('|');
        var functions = new string[count];
        for (int i = 0; i < count; i++)
        {
            string key = $"PINDEFINEDFUNCTION{i + 1}=";
            string? pair = pairs.FirstOrDefault(value => value.StartsWith(key, StringComparison.Ordinal));
            functions[i] = pair is null ? "" : pair[key.Length..];
        }
        // The native bridge serializes the "/"-separated exported text as a list.
        string joined = string.Join('/', functions);
        return joined.Length == 0 ? [] : joined.Split('/', '\r', '\n');
    }

    private static string IeeeSymbolName(TIeeeSymbol symbol) => (int)symbol switch
    {
        0 => "none",
        >= 1 and <= 34 => symbol.ToString()[1..].ToLowerInvariant(),
        _ => ""
    };

    private sealed record SymbolPinSpec(string Number, string Name, EDP.TPinElectrical Electrical,
        TRotationBy90 Orientation, DXP.Point Location, int Part, int? Length, bool? ShowName, bool? ShowDesignator);

    private sealed record SymbolGraphicSpec(TObjectId Kind, int Part, TSize Width, bool Solid,
        DXP.Point[] Points, int Radius = 0, int SecondaryRadius = 0,
        double StartAngle = 0, double EndAngle = 0, string Text = "");

    private sealed record SymbolCreateSpec(string Name, string Description, string Designator, string Comment,
        int Parts, List<SymbolPinSpec> Pins, List<SymbolGraphicSpec> Graphics, int ExplicitGraphicsCount,
        Dictionary<string, string> Parameters, Dictionary<string, string> PinDescriptions);

    private object CreateSchematicSymbol(JsonElement parameters)
    {
        var library = FocusedSymbolLibrary();
        var document = client.GetCurrentView()?.GetOwnerDocument();
        if (projectPath is null || library is null ||
            !string.Equals(document?.GetKind(), "SCHLIB", StringComparison.OrdinalIgnoreCase) ||
            !SameSymbolLibrary(document!.GetFileName(), library.GetState_DocumentName()))
            throw new CommandUnavailable("The symbol editor does not have an active schematic library and design project");

        string name = StringParameter(parameters, "symbol_name");
        if (name.Length == 0)
            return Error("Error: No component name provided");

        var pins = SymbolStringArray(parameters, "pins");
        var graphics = SymbolStringArray(parameters, "graphics");
        bool referenceStyle = !parameters.TryGetProperty("reference_style", out var style) ||
            style.ValueKind != JsonValueKind.False;
        if (graphics.Count == 0 && referenceStyle)
            throw new CommandUnavailable("Reference-styled symbols use the DelphiScript bridge");

        int partCount = 1;
        if (parameters.TryGetProperty("part_count", out var count) && !count.TryGetInt32(out partCount))
            throw new CommandUnavailable("The symbol part count could not be parsed");
        var spec = ParseExplicitSymbol(name, StringParameter(parameters, "description"), partCount, pins, graphics);

        if (Symbols(library).Any(component =>
            string.Equals(component.GetState_LibReference(), spec.Name, StringComparison.OrdinalIgnoreCase)))
            throw new CommandUnavailable("Duplicate symbol handling uses the DelphiScript bridge");

        CreateSymbolInLibrary(library, document, spec);
        return Success(new
        {
            success = true,
            component_name = spec.Name,
            pins_count = spec.Pins.Count,
            part_count = spec.Parts,
            document_saved = false,
            document_dirty = true
        });
    }

    private static List<string> SymbolStringArray(JsonElement parameters, string key)
    {
        var values = new List<string>();
        if (!parameters.TryGetProperty(key, out var value))
            return values;
        if (value.ValueKind != JsonValueKind.Array)
            throw new CommandUnavailable($"Expected a symbol {key} array");
        foreach (var entry in value.EnumerateArray())
        {
            if (entry.ValueKind != JsonValueKind.String)
                throw new CommandUnavailable($"Expected a string in the symbol {key} array");
            values.Add(entry.GetString()!);
        }
        return values;
    }

    private static SymbolCreateSpec ParseExplicitSymbol(string name, string description, int partCount,
        List<string> pinRecords, List<string> graphicRecords)
    {
        List<SymbolPinSpec> pins = [];
        List<SymbolGraphicSpec> graphics = [];
        var parameters = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var pinDescriptions = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string designator = "U?";
        string comment = "";
        string manufacturer = "";
        foreach (string record in pinRecords)
        {
            int equals = record.IndexOf('=');
            int pipe = record.IndexOf('|');
            if (equals >= 0 && (pipe < 0 || equals < pipe))
            {
                string value = record[(equals + 1)..];
                switch (record[..equals])
                {
                    case "Description": description = value; continue;
                    case "Designator": designator = value.Length == 0 ? "U?" : value; continue;
                    case "Comment": comment = value; continue;
                    case "Manufacturer":
                        manufacturer = value;
                        parameters["Manufacturer"] = value;
                        continue;
                    case "Parameter": SetSymbolPair(parameters, value); continue;
                    case "PinDescription": SetSymbolPair(pinDescriptions, value); continue;
                    case "CenterLabel" or "CenterLabelPosition" or "VerticalSeparators" or "NoVerticalSeparators" or
                         "GroupDelimiter" or "GroupDelimiterYMM" or "SideSectionWidthMM":
                        // These records affect only the reference-style drawing.
                        continue;
                    case "Footprint" or "FootprintLibrary" or "FootprintLibraryPath":
                        throw new CommandUnavailable("Symbol footprint model links use the DelphiScript bridge");
                }
            }

            string[] fields = record.Split('|');
            int part = SymbolInteger(SymbolField(fields, 6), 1);
            partCount = Math.Max(partCount, part);
            if (SymbolField(fields, 4).Trim().Length == 0 || SymbolField(fields, 5).Trim().Length == 0)
                continue;
            if (part < 0)
                throw new CommandUnavailable("The symbol pin part could not be parsed");

            var electrical = SymbolField(fields, 2).Trim() switch
            {
                "eElectricInput" => EDP.TPinElectrical.eElectricInput,
                "eElectricIO" => EDP.TPinElectrical.eElectricIO,
                "eElectricOutput" => EDP.TPinElectrical.eElectricOutput,
                "eElectricOpenCollector" => EDP.TPinElectrical.eElectricOpenCollector,
                "eElectricOpenEmitter" => EDP.TPinElectrical.eElectricOpenEmitter,
                "eElectricHiZ" => EDP.TPinElectrical.eElectricHiZ,
                "eElectricPower" => EDP.TPinElectrical.eElectricPower,
                _ => EDP.TPinElectrical.eElectricPassive
            };
            var orientation = SymbolField(fields, 3).Trim() switch
            {
                "eRotate90" => TRotationBy90.eRotate90,
                "eRotate180" => TRotationBy90.eRotate180,
                "eRotate270" => TRotationBy90.eRotate270,
                _ => TRotationBy90.eRotate0
            };
            string length = SymbolField(fields, 7).Trim();
            pins.Add(new SymbolPinSpec(fields[0].Trim(), SymbolField(fields, 1), electrical, orientation,
                ReadSymbolPoint(fields, 4), part, length.Length == 0 ? null : ReadSymbolCoord(length),
                SymbolOptionalVisibility(SymbolField(fields, 8)), SymbolOptionalVisibility(SymbolField(fields, 9))));
        }

        // Native creation emits the explicit Manufacturer before other override records.
        if (manufacturer.Length != 0)
        {
            parameters.Remove("Manufacturer");
            parameters = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["Manufacturer"] = manufacturer }
                .Concat(parameters).ToDictionary(item => item.Key, item => item.Value, StringComparer.OrdinalIgnoreCase);
        }

        foreach (string record in graphicRecords)
        {
            if (record.Trim().Length == 0)
                continue;
            var graphic = ReadSymbolGraphic(record.Trim().Split('|'));
            partCount = Math.Max(partCount, graphic.Part);
            graphics.Add(graphic);
        }
        if (partCount is < 1 or > 255)
            throw new CommandUnavailable("The symbol part count is outside the managed editor range");
        return new SymbolCreateSpec(name, description, designator, comment, partCount,
            pins, graphics, graphicRecords.Count, parameters, pinDescriptions);
    }

    private static void SetSymbolPair(Dictionary<string, string> pairs, string value)
    {
        int split = value.IndexOf('|');
        if (split > 0)
            pairs[value[..split]] = value[(split + 1)..];
    }

    private static string SymbolField(string[] fields, int index) => index < fields.Length ? fields[index] : "";

    private static int SymbolInteger(string value, int fallback)
    {
        if (value.Trim().Length == 0)
            return fallback;
        if (int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out int result))
            return result;
        throw new CommandUnavailable("An integer field in the symbol specification could not be parsed");
    }

    private static double ReadSymbolNumber(string value)
    {
        if (double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out double number) &&
            double.IsFinite(number))
            return number;
        throw new CommandUnavailable("A numeric field in the symbol specification could not be parsed");
    }

    private static int ReadSymbolCoord(string value)
    {
        double mils = ReadSymbolNumber(value);
        if (mils is < -210_000 or > 210_000)
            throw new CommandUnavailable("A symbol coordinate is outside the managed editor range");
        return EDP.Utils.MilsToCoord(mils);
    }

    private static DXP.Point ReadSymbolPoint(string[] fields, int index) =>
        new() { X = ReadSymbolCoord(SymbolField(fields, index)), Y = ReadSymbolCoord(SymbolField(fields, index + 1)) };

    private static bool? SymbolOptionalVisibility(string value) => value.Trim() switch
    {
        "" => null,
        "1" => true,
        _ => false
    };

    private static SymbolGraphicSpec ReadSymbolGraphic(string[] fields)
    {
        string type = fields[0].Trim().ToLowerInvariant();
        int part = SymbolInteger(SymbolField(fields, 1), 1);
        if (part is < 0 or > 255)
            throw new CommandUnavailable("A symbol graphic part is outside the managed editor range");
        if (type == "label")
            return new SymbolGraphicSpec(TObjectId.eLabel, part, TSize.eSmall, false,
                [ReadSymbolPoint(fields, 2)], Text: SymbolField(fields, 4));
        int width = SymbolInteger(SymbolField(fields, 2), 1);
        if (width is < 0 or > 3)
            throw new CommandUnavailable("A symbol line width is outside the managed editor range");
        bool solid = SymbolField(fields, 3).Trim() == "1";
        var size = (TSize)width;
        switch (type)
        {
            case "line":
                return new SymbolGraphicSpec(TObjectId.eLine, part, size, false,
                    [ReadSymbolPoint(fields, 3), ReadSymbolPoint(fields, 5)]);
            case "rectangle":
                return new SymbolGraphicSpec(TObjectId.eRectangle, part, size, solid,
                    [ReadSymbolPoint(fields, 4), ReadSymbolPoint(fields, 6)]);
            case "polyline" or "polygon":
                var points = new List<DXP.Point>();
                int index = type == "polygon" ? 4 : 3;
                while (SymbolField(fields, index).Trim().Length != 0 &&
                       SymbolField(fields, index + 1).Trim().Length != 0)
                {
                    points.Add(ReadSymbolPoint(fields, index));
                    index += 2;
                }
                return new SymbolGraphicSpec(type == "polygon" ? TObjectId.ePolygon : TObjectId.ePolyline,
                    part, size, solid, points.ToArray());
            case "arc":
                return new SymbolGraphicSpec(TObjectId.eArc, part, size, false,
                    [ReadSymbolPoint(fields, 3)], ReadSymbolCoord(SymbolField(fields, 5)),
                    StartAngle: ReadSymbolNumber(SymbolField(fields, 6)), EndAngle: ReadSymbolNumber(SymbolField(fields, 7)));
            case "elliptical_arc":
                return new SymbolGraphicSpec(TObjectId.eEllipticalArc, part, size, false,
                    [ReadSymbolPoint(fields, 3)], ReadSymbolCoord(SymbolField(fields, 5)),
                    ReadSymbolCoord(SymbolField(fields, 6)), ReadSymbolNumber(SymbolField(fields, 7)),
                    ReadSymbolNumber(SymbolField(fields, 8)));
            case "ellipse":
                return new SymbolGraphicSpec(TObjectId.eEllipse, part, size, solid,
                    [ReadSymbolPoint(fields, 4)], ReadSymbolCoord(SymbolField(fields, 6)),
                    ReadSymbolCoord(SymbolField(fields, 7)));
            default:
                throw new CommandUnavailable($"The symbol graphic type '{type}' uses the DelphiScript bridge");
        }
    }

    private void CreateSymbolInLibrary(ISch_Lib library, IServerDocument document, SymbolCreateSpec spec)
    {
        var server = SCH.GlobalVars.SchServer;
        var process = client.GetProcessControl();
        var robot = server.GetState_RobotManager();
        var component = (ISch_Component)NewSymbolObject(server, TObjectId.eSchComponent);
        bool publicationAttempted = false;
        try
        {
            component.SetState_CurrentPartID(1);
            component.SetState_DisplayMode(0);
            component.SetState_PartCountNoPart0(spec.Parts);
            component.SetState_LibReference(spec.Name);
            component.SetState_ComponentDescription(spec.Description);
            if (spec.Comment.Length != 0)
                component.GetState_SchComment()?.SetState_Text(spec.Comment);
            var designator = component.GetState_SchDesignator();
            designator.SetState_Text(spec.Designator);

            const int standardMargin = 1_000_000; // 100 mil in native units.
            for (int part = 1; part <= spec.Parts; part++)
            {
                var pins = spec.Pins.Where(pin => pin.Part == part || pin.Part == 0).ToList();
                int left = pins.Count == 0 ? 3_000_000 : pins.Min(pin => pin.Location.X);
                int right = pins.Count == 0 ? 10_000_000 : pins.Max(pin => pin.Location.X);
                int bottom = pins.Count == 0 ? -standardMargin : pins.Min(pin => pin.Location.Y) - standardMargin;
                int top = pins.Count == 0 ? 11_000_000 : pins.Max(pin => pin.Location.Y) + standardMargin;
                if (spec.ExplicitGraphicsCount == 0 && pins.Count != 0)
                    AddSymbolGraphic(server, component, new SymbolGraphicSpec(TObjectId.eRectangle, part,
                        TSize.eSmall, true, [new DXP.Point { X = left, Y = bottom }, new DXP.Point { X = right, Y = top }]));
                if (part == 1)
                    designator.SetState_Location(new DXP.Point { X = left, Y = top });
            }

            foreach (var graphic in spec.Graphics)
                AddSymbolGraphic(server, component, graphic);
            foreach (var input in spec.Pins)
            {
                AddSymbolPrimitive<ISch_Pin>(server, component, TObjectId.ePin, pin =>
                {
                    pin.SetState_Designator(input.Number);
                    pin.SetState_Name(input.Name);
                    pin.SetState_Electrical(input.Electrical);
                    pin.SetState_Orientation(input.Orientation);
                    pin.SetState_Location(input.Location);
                    if (spec.PinDescriptions.TryGetValue(input.Number, out string? description))
                        pin.SetState_Description(description);
                    if (input.Length.HasValue)
                        pin.SetState_PinLength(input.Length.Value);
                    if (input.ShowName.HasValue)
                        pin.SetState_ShowName(input.ShowName.Value);
                    if (input.ShowDesignator.HasValue)
                        pin.SetState_ShowDesignator(input.ShowDesignator.Value);
                    pin.SetState_OwnerPartId(input.Part);
                    pin.SetState_OwnerPartDisplayMode(0);
                });
            }
            foreach (var (name, value) in spec.Parameters)
            {
                AddSymbolPrimitive<ISch_Parameter>(server, component, TObjectId.eParameter, parameter =>
                {
                    parameter.SetState_Name(name);
                    parameter.SetState_Text(value);
                });
            }

            process.PreProcess(library, "");
            try
            {
                publicationAttempted = true;
                library.AddSchComponent(component);
                robot.SendMessage(library, SCHConstant.BroadCast, SCHConstant.SCHMPrimitiveRegistration, component);
            }
            finally
            {
                process.PostProcess(library, "");
            }
            library.SetState_Current_SchComponent(component);
            library.GraphicallyInvalidate();
            document.SetModified(true);
        }
        finally
        {
            // The editor owns the object after publication may have happened, even if a native call threw.
            if (!publicationAttempted)
            {
                ISch_BasicContainer objectToDestroy = component;
                server.DestroySchObject(ref objectToDestroy);
            }
        }
    }

    private static ISch_BasicContainer NewSymbolObject(ISch_ServerInterface server, TObjectId kind) =>
        server.SchObjectFactory(kind, TObjectCreationMode.eCreate_Default)
        ?? throw new InvalidOperationException($"Altium could not create a symbol {kind} object");

    private static void AddSymbolPrimitive<T>(ISch_ServerInterface server, ISch_Component component,
        TObjectId kind, Action<T> initialize) where T : ISch_BasicContainer
    {
        var native = NewSymbolObject(server, kind);
        bool insertionAttempted = false;
        try
        {
            initialize((T)native);
            insertionAttempted = true;
            component.AddSchObject(native);
        }
        finally
        {
            if (!insertionAttempted)
                server.DestroySchObject(ref native);
        }
    }

    private static void AddSymbolGraphic(ISch_ServerInterface server, ISch_Component component, SymbolGraphicSpec spec)
    {
        AddSymbolPrimitive<ISch_GraphicalObject>(server, component, spec.Kind, graphic =>
        {
            switch (spec.Kind)
            {
                case TObjectId.eLine:
                    var line = (ISch_Line)graphic;
                    line.SetState_LineWidth(spec.Width);
                    line.SetState_Location(spec.Points[0]);
                    line.SetState_Corner(spec.Points[1]);
                    break;
                case TObjectId.eRectangle:
                    var rectangle = (ISch_Rectangle)graphic;
                    rectangle.SetState_LineWidth(spec.Width);
                    rectangle.SetState_IsSolid(spec.Solid);
                    rectangle.SetState_AreaColor(0x00B0FFFF);
                    rectangle.SetState_Color(0x00FF0000);
                    rectangle.SetState_Location(spec.Points[0]);
                    rectangle.SetState_Corner(spec.Points[1]);
                    break;
                case TObjectId.ePolyline or TObjectId.ePolygon:
                    var polygon = (ISch_Polygon)graphic;
                    polygon.SetState_LineWidth(spec.Width);
                    if (spec.Kind == TObjectId.ePolygon)
                    {
                        polygon.SetState_IsSolid(spec.Solid);
                        polygon.SetState_AreaColor(0x00B0FFFF);
                        polygon.SetState_Color(0x00FF0000);
                    }
                    polygon.SetState_VerticesCount(spec.Points.Length);
                    for (int i = 0; i < spec.Points.Length; i++)
                        polygon.SetState_Vertex(i + 1, spec.Points[i]);
                    break;
                case TObjectId.eArc or TObjectId.eEllipticalArc:
                    var arc = (ISch_Arc)graphic;
                    arc.SetState_LineWidth(spec.Width);
                    arc.SetState_Location(spec.Points[0]);
                    arc.SetState_Radius(spec.Radius);
                    if (spec.Kind == TObjectId.eEllipticalArc)
                        ((ISch_EllipticalArc)graphic).SetState_SecondaryRadius(spec.SecondaryRadius);
                    arc.SetState_StartAngle(spec.StartAngle);
                    arc.SetState_EndAngle(spec.EndAngle);
                    break;
                case TObjectId.eEllipse:
                    var ellipse = (ISch_Ellipse)graphic;
                    ellipse.SetState_LineWidth(spec.Width);
                    ellipse.SetState_IsSolid(spec.Solid);
                    ellipse.SetState_Location(spec.Points[0]);
                    ellipse.SetState_Radius(spec.Radius);
                    ellipse.SetState_SecondaryRadius(spec.SecondaryRadius);
                    break;
                case TObjectId.eLabel:
                    var label = (ISch_Label)graphic;
                    label.SetState_Location(spec.Points[0]);
                    label.SetState_Text(spec.Text);
                    break;
            }
            graphic.SetState_OwnerPartId(spec.Part);
            graphic.SetState_OwnerPartDisplayMode(0);
        });
    }

    private sealed record SymbolEdit(string Kind, string First, string Second = "", string Third = "",
        bool Visible = false, DXP.Point? Position = null, TTextJustification? Justification = null,
        string? FontName = null, int FontSize = 0, TIeeeSymbol Symbol = TIeeeSymbol.eNoSymbol);

    private sealed record SymbolBatchEntry(string Name, SymbolCreateSpec? Create, List<SymbolEdit> Edits);

    private object CreateSymbolsBatch(JsonElement parameters)
    {
        string specFile = StringParameter(parameters, "spec_file");
        if (specFile.Length == 0)
            return Error("No spec_file provided for create_symbols_batch");
        if (!File.Exists(specFile))
            return Error($"Spec file not found: {specFile}");

        var (requestedLibrary, entries) = ReadSymbolBatch(specFile);
        var library = FocusedSymbolLibrary();
        var document = client.GetCurrentView()?.GetOwnerDocument();
        string? path = library?.GetState_DocumentName();
        if (library is null || !SameSymbolLibrary(document?.GetFileName(), path) ||
            (requestedLibrary.Length != 0 && !SameSymbolLibrary(path, requestedLibrary)))
            throw new CommandUnavailable("Batch creation requires the target library to be active in the managed bridge");

        // Validate every create name before editing the library. Existing duplicate semantics stay with Pascal.
        var names = Symbols(library).Select(symbol => symbol.GetState_LibReference())
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in entries)
        {
            if (entry.Create is not null && !names.Add(entry.Name))
                throw new CommandUnavailable("Batch duplicate symbol handling uses the DelphiScript bridge");
        }

        int created = 0;
        int edited = 0;
        bool editsApplied = false;
        var failed = new List<string>();
        var problems = new List<string>();
        foreach (var entry in entries)
        {
            if (entry.Create is not null)
            {
                CreateSymbolInLibrary(library, document!, entry.Create);
                created++;
                if (entry.Edits.Count == 0)
                    continue;
            }
            var component = Symbols(library).FirstOrDefault(symbol =>
                string.Equals(symbol.GetState_LibReference(), entry.Name, StringComparison.OrdinalIgnoreCase));
            if (component is null)
            {
                if (entry.Create is not null)
                    problems.Add($"{entry.Name}: created, but not found again to set its properties");
                else
                {
                    failed.Add(entry.Name);
                    problems.Add($"{entry.Name}: not in the focused schematic library (EDITSYMBOL never creates a symbol)");
                }
                continue;
            }
            if (entry.Create is null)
                edited++;
            if (entry.Edits.Count != 0)
            {
                ApplySymbolEditRecords(library, component, entry.Edits, problems);
                editsApplied = true;
            }
        }
        if (edited != 0)
            document!.SetModified(true);
        if (editsApplied && !RestoreSymbolEditorPicture(library))
        {
            string name = library.GetState_Current_SchComponent()?.GetState_LibReference() ?? "";
            problems.Add($"{name}: the library has no other symbol to switch to, so the editor may not draw its " +
                "new parameters until the library is reopened");
        }
        return Success(new { created, edited, failed, problems });
    }

    private static (string Library, List<SymbolBatchEntry> Entries) ReadSymbolBatch(string path)
    {
        byte[] bytes = File.ReadAllBytes(path);
        bool utf8Bom = bytes.AsSpan().StartsWith(Encoding.UTF8.Preamble);
        if (!utf8Bom && bytes.Any(value => value >= 128))
            throw new CommandUnavailable("Non-ASCII symbol batches require a UTF-8 BOM in the managed bridge");
        string text;
        try
        {
            text = new UTF8Encoding(false, true).GetString(bytes.AsSpan(utf8Bom ? Encoding.UTF8.Preamble.Length : 0));
        }
        catch (DecoderFallbackException)
        {
            throw new CommandUnavailable("The symbol batch is not valid UTF-8");
        }

        string library = "";
        string name = "";
        string description = "";
        int parts = 1;
        bool creating = false;
        List<string> pins = [];
        List<string> graphics = [];
        List<SymbolEdit> edits = [];
        List<SymbolBatchEntry> entries = [];
        using var reader = new StringReader(text);
        while (reader.ReadLine() is { } line)
        {
            string[] fields = line.Split('|');
            string kind = fields[0].Trim().ToUpperInvariant();
            switch (kind)
            {
                case "LIBRARY":
                    if (library.Length != 0 || name.Length != 0 || entries.Count != 0)
                        throw new CommandUnavailable("A managed symbol batch can target one library");
                    library = SymbolField(fields, 1).Trim();
                    if (library.Length == 0)
                        throw new CommandUnavailable("A symbol batch library path is required");
                    break;
                case "SYMBOL" or "EDITSYMBOL":
                    Flush();
                    creating = kind == "SYMBOL";
                    name = SymbolField(fields, 1).Trim();
                    if (name.Length == 0)
                        throw new CommandUnavailable("A name is required for each managed symbol batch entry");
                    description = creating ? SymbolField(fields, 2) : "";
                    parts = creating ? SymbolInteger(SymbolField(fields, 3), 1) : 1;
                    break;
                case "PIN" or "GRAPHIC":
                    if (!creating || name.Length == 0 || line.Length < kind.Length + 1)
                        throw new CommandUnavailable("Pins and graphics must follow a symbol create entry");
                    (kind == "PIN" ? pins : graphics).Add(line[(kind.Length + 1)..]);
                    break;
                case "COMMENT" or "DESCRIPTION" or "SYMPARAM" or "PINDESC" or "PINPARAM" or "PINSYMBOL" or "PINFUNC":
                    if (name.Length == 0)
                        throw new CommandUnavailable("Symbol edit records must follow a named entry");
                    edits.Add(ReadSymbolEdit(kind, fields));
                    break;
                case "":
                    break;
                default:
                    throw new CommandUnavailable($"The symbol batch record '{kind}' uses the DelphiScript bridge");
            }
        }
        Flush();
        return (library, entries);

        void Flush()
        {
            if (name.Length == 0)
                return;
            SymbolCreateSpec? spec = null;
            if (creating)
            {
                if (description.Length != 0)
                    pins.Add("Description=" + description);
                spec = ParseExplicitSymbol(name, "New Component", parts, pins, graphics);
            }
            entries.Add(new SymbolBatchEntry(name, spec, edits));
            pins = [];
            graphics = [];
            edits = [];
        }
    }

    private static SymbolEdit ReadSymbolEdit(string kind, string[] fields)
    {
        string first = SymbolField(fields, 1);
        string second = SymbolField(fields, 2);
        string third = SymbolField(fields, 3);
        if (kind == "COMMENT")
            return new SymbolEdit(kind, first, Visible: second.Trim() == "1");
        if (kind == "DESCRIPTION")
            return new SymbolEdit(kind, first);
        if (kind == "PINSYMBOL")
        {
            string edge = second.Trim().ToLowerInvariant();
            if (edge is not ("inside" or "inside_edge" or "outside_edge" or "outside"))
                throw new CommandUnavailable("An unknown symbol pin edge uses the DelphiScript bridge");
            string name = third.Trim();
            var symbol = TIeeeSymbol.eNoSymbol;
            if (!name.Equals("none", StringComparison.OrdinalIgnoreCase) &&
                (!Enum.TryParse($"e{name}", true, out symbol) || (int)symbol is < 0 or > 34))
                throw new CommandUnavailable("An unknown IEEE symbol name uses the DelphiScript bridge");
            return new SymbolEdit(kind, first.Trim(), edge, Symbol: symbol);
        }
        if (kind != "SYMPARAM")
            return new SymbolEdit(kind, first.Trim(), second, third);

        DXP.Point? position = SymbolField(fields, 4).Trim().Length == 0 ? null : ReadSymbolPoint(fields, 4);
        TTextJustification? justification = null;
        string justify = SymbolField(fields, 6).Trim();
        if (justify.Length != 0)
        {
            int index = Array.FindIndex(TextJustifications, value =>
                string.Equals(value, justify, StringComparison.OrdinalIgnoreCase));
            if (index < 0)
                throw new CommandUnavailable("Unknown symbol text justification uses the DelphiScript bridge");
            justification = (TTextJustification)index;
        }
        string spec = SymbolField(fields, 7).Trim();
        string? font = null;
        int size = 0;
        if (spec.Length != 0)
        {
            int separator = spec.LastIndexOf(':');
            if (separator <= 0)
                throw new CommandUnavailable("An invalid symbol font specification uses the DelphiScript bridge");
            font = spec[..separator].Trim();
            string sizeText = spec[(separator + 1)..].Trim();
            if (font.Length == 0 || sizeText.Length is < 1 or > 3 ||
                !sizeText.All(char.IsAsciiDigit) || !int.TryParse(sizeText, out size) || size < 1)
                throw new CommandUnavailable("An invalid symbol font specification uses the DelphiScript bridge");
        }
        return new SymbolEdit(kind, first.Trim(), second, Visible: third.Trim() == "1",
            Position: position, Justification: justification, FontName: font, FontSize: size);
    }

    private void ApplySymbolEditRecords(ISch_Lib library, ISch_Component component, List<SymbolEdit> edits,
        List<string> problems)
    {
        var server = SCH.GlobalVars.SchServer;
        var process = client.GetProcessControl();
        var robot = server.GetState_RobotManager();
        bool needCorner = edits.Any(edit => edit.Kind == "SYMPARAM" && edit.Position is null);
        DXP.Point corner = needCorner ? SymbolBodyCorner(component) : new DXP.Point();
        var pins = edits.Any(edit => edit.Kind.StartsWith("PIN", StringComparison.Ordinal))
            ? SchematicObjects(component, TObjectId.ePin).Cast<ISch_Pin>()
                .ToLookup(pin => pin.GetState_Designator(), StringComparer.Ordinal)
            : null;
        int placed = 0;
        process.PreProcess(library, "");
        try
        {
            foreach (var edit in edits)
            {
                switch (edit.Kind)
                {
                    case "COMMENT":
                        SetManagedSymbolComment(library, component, robot, edit);
                        break;
                    case "DESCRIPTION":
                        ChangeSymbolItem(robot, component, () => component.SetState_ComponentDescription(edit.First));
                        break;
                    case "SYMPARAM":
                        if (edit.Position is null && edit.Visible)
                            placed++;
                        var position = edit.Position ?? new DXP.Point { X = corner.X, Y = corner.Y - 1_000_000 * placed };
                        ApplySymbolParameter(server, robot, component, edit, position);
                        break;
                    default:
                        ApplySymbolPinEdit(server, robot, component, edit, pins![edit.First], problems);
                        break;
                }
            }
        }
        finally
        {
            process.PostProcess(library, "");
        }
        library.GraphicallyInvalidate();
    }

    private static bool SameSchematicObject(ISch_BasicContainer first, ISch_BasicContainer second) =>
        ReferenceEquals(first, second) ||
        (first.GetState_Handle() is { Length: > 0 } firstHandle && firstHandle == second.GetState_Handle());

    private static bool RestoreSymbolEditorPicture(ISch_Lib library)
    {
        var current = library.GetState_Current_SchComponent();
        if (current is null)
            return true;
        var other = Symbols(library).FirstOrDefault(item => !SameSchematicObject(item, current));
        if (other is null)
            return false;
        library.SetState_Current_SchComponent(other);
        library.SetState_Current_SchComponent(current);
        library.GraphicallyInvalidate();
        return true;
    }

    private static void SetManagedSymbolComment(ISch_Lib library, ISch_Component component,
        ISch_RobotManager robot, SymbolEdit edit)
    {
        var comment = component.GetState_SchComment();
        ChangeSymbolItem(robot, component, () =>
        {
            comment.SetState_Text(edit.First);
            comment.SetState_IsHidden(!edit.Visible);
        });
        var current = library.GetState_Current_SchComponent();
        if (current is null || !SameSchematicObject(component, current))
            return;
        var iterator = library.SchLibIterator_Create();
        ISch_Parameter? editorComment = null;
        try
        {
            iterator.AddFilter_ObjectSet(new TObjectSet(TObjectId.eParameter));
            for (var item = iterator.FirstSchObject(); item is not null; item = iterator.NextSchObject())
            {
                var parameter = (ISch_Parameter)item;
                var owner = parameter.GetState_SchBasicContainer();
                if (owner is not null && SameSchematicObject(owner, library) &&
                    string.Equals(parameter.GetState_Name(), "COMMENT", StringComparison.OrdinalIgnoreCase))
                    editorComment = parameter;
            }
        }
        finally
        {
            library.SchIterator_Destroy(ref iterator);
        }
        if (editorComment is not null)
            ChangeSymbolItem(robot, editorComment, () =>
            {
                editorComment.SetState_Text(edit.First);
                editorComment.SetState_IsHidden(!edit.Visible);
            });
    }

    private static void ChangeSymbolItem(ISch_RobotManager robot, ISch_BasicContainer item, Action change)
    {
        robot.SendMessage(item, SCHConstant.BroadCast, SCHConstant.SCHMBeginModify, SCHConstant.NoEventData);
        try
        {
            change();
        }
        finally
        {
            robot.SendMessage(item, SCHConstant.BroadCast, SCHConstant.SCHMEndModify, SCHConstant.NoEventData);
        }
    }

    private static void AddSymbolEditParameter(ISch_ServerInterface server, ISch_RobotManager robot,
        ISch_Component component, ISch_GraphicalObject owner, Action<ISch_Parameter> initialize)
    {
        var item = NewSymbolObject(server, TObjectId.eParameter);
        var parameter = (ISch_Parameter)item;
        bool insertionAttempted = false;
        try
        {
            initialize(parameter);
            insertionAttempted = true;
            owner.AddSchObject(parameter);
            robot.SendMessage(component, SCHConstant.BroadCast, SCHConstant.SCHMPrimitiveRegistration, parameter);
        }
        finally
        {
            if (!insertionAttempted)
                server.DestroySchObject(ref item);
        }
    }

    private static void ApplySymbolParameter(ISch_ServerInterface server, ISch_RobotManager robot,
        ISch_Component component, SymbolEdit edit, DXP.Point position)
    {
        int? fontId = edit.FontName is null ? null : server.GetState_FontManager()
            .GetFontID(edit.FontSize, 0, false, false, false, false, edit.FontName);
        var existing = OwnedSymbolParameters(component).FirstOrDefault(item =>
            string.Equals(item.GetState_Name(), edit.First, StringComparison.OrdinalIgnoreCase));
        void Write(ISch_Parameter parameter, bool newParameter)
        {
            parameter.SetState_Text(edit.Second);
            parameter.SetState_IsHidden(!edit.Visible);
            if (newParameter || edit.Visible || edit.Position is not null)
            {
                parameter.SetState_Autoposition(false);
                parameter.SetState_Location(position);
            }
            if (edit.Justification is { } justification)
                parameter.SetState_Justification(justification);
            if (fontId is >= 0)
                parameter.SetState_FontId(fontId.Value);
        }
        if (existing is null)
            AddSymbolEditParameter(server, robot, component, component, parameter =>
            {
                parameter.SetState_Name(edit.First);
                parameter.SetState_ShowName(false);
                Write(parameter, true);
            });
        else
            ChangeSymbolItem(robot, existing, () => Write(existing, false));
    }

    private static void ApplySymbolPinEdit(ISch_ServerInterface server, ISch_RobotManager robot,
        ISch_Component component, SymbolEdit edit, IEnumerable<ISch_Pin> pins, List<string> problems)
    {
        string name = component.GetState_LibReference();
        string functions = edit.Kind == "PINFUNC"
            ? string.Join('/', edit.Second.Split('/').Select(item => item.Trim()).Where(item => item.Length != 0))
            : "";
        if (edit.Kind == "PINFUNC" && functions.Length == 0)
        {
            problems.Add($"{name}: PINFUNC for pin {edit.First} lists no functions. A script cannot clear a pin's functions; clear them in the Properties panel");
            return;
        }

        bool matched = false;
        string stored = "";
        foreach (var pin in pins)
        {
            matched = true;
            if (edit.Kind == "PINPARAM")
            {
                string parameterName = edit.Second.Trim();
                var existing = OwnedSymbolParameters(pin).FirstOrDefault(item =>
                    string.Equals(item.GetState_Name(), parameterName, StringComparison.OrdinalIgnoreCase));
                if (existing is null)
                    AddSymbolEditParameter(server, robot, component, pin, parameter =>
                    {
                        parameter.SetState_Name(parameterName);
                        parameter.SetState_Text(edit.Third);
                        parameter.SetState_IsHidden(true);
                        parameter.SetState_Location(pin.GetState_Location());
                    });
                else
                    ChangeSymbolItem(robot, existing, () =>
                    {
                        existing.SetState_Text(edit.Third);
                        existing.SetState_IsHidden(true);
                    });
                continue;
            }

            ChangeSymbolItem(robot, pin, () =>
            {
                switch (edit.Kind)
                {
                    case "PINDESC": pin.SetState_Description(edit.Second); break;
                    case "PINSYMBOL":
                        switch (edit.Second)
                        {
                            case "inside": pin.SetState_Symbol_Inner(edit.Symbol); break;
                            case "inside_edge": pin.SetState_Symbol_InnerEdge(edit.Symbol); break;
                            case "outside_edge": pin.SetState_Symbol_OuterEdge(edit.Symbol); break;
                            case "outside": pin.SetState_Symbol_Outer(edit.Symbol); break;
                        }
                        break;
                    case "PINFUNC":
                        string original = pin.GetState_Name();
                        try
                        {
                            pin.SetState_Name(functions.Contains('/') ? functions : functions + "/");
                            pin.SetState_FunctionsFromName();
                        }
                        finally
                        {
                            pin.SetState_Name(original);
                        }
                        break;
                }
            });
            if (edit.Kind == "PINFUNC")
                stored = string.Join('/', SymbolPinFunctions(pin));
        }
        if (!matched)
        {
            string suffix = edit.Kind == "PINPARAM" ? " " + edit.Second.Trim() : "";
            problems.Add($"{name}: no pin {edit.First} for {edit.Kind}{suffix}");
        }
        else if (edit.Kind == "PINFUNC" && stored != functions)
            problems.Add($"{name}: pin {edit.First} stored the functions {stored}, not {functions} (Altium merges repeated names)");
    }

    private static DXP.Point SymbolBodyCorner(ISch_Component component)
    {
        DXP.Point? body = null;
        DXP.Point? pin = null;
        foreach (var item in SymbolPrimitives(component))
        {
            var id = item.GetState_ObjectId();
            if (id is not (TObjectId.ePin or TObjectId.eLine or TObjectId.eRectangle or TObjectId.eRoundRectangle or
                TObjectId.ePolygon or TObjectId.ePolyline or TObjectId.eBezier or TObjectId.eArc or TObjectId.ePie or
                TObjectId.eEllipticalArc or TObjectId.eEllipse))
                continue;
            var primitive = (ISch_GraphicalObject)item;
            if (primitive.GetState_OwnerPartId() > 1)
                continue;
            var location = primitive.GetState_Location();

            switch (id)
            {
                case TObjectId.ePin:
                    Include(ref pin, location.X, location.Y);
                    break;
                case TObjectId.eLine:
                    var line = ((ISch_Line)primitive).GetState_Corner();
                    Include(ref body, Math.Min(location.X, line.X), Math.Min(location.Y, line.Y));
                    break;
                case TObjectId.eRectangle or TObjectId.eRoundRectangle:
                    var rect = ((ISch_Rectangle)primitive).GetState_Corner();
                    Include(ref body, Math.Min(location.X, rect.X), Math.Min(location.Y, rect.Y));
                    break;
                case TObjectId.ePolygon or TObjectId.ePolyline or TObjectId.eBezier:
                    var polygon = (ISch_Polygon)primitive;
                    int count = polygon.GetState_VerticesCount();
                    for (int i = 1; i <= count; i++)
                    {
                        var vertex = polygon.GetState_Vertex(i);
                        Include(ref body, vertex.X, vertex.Y);
                    }
                    break;
                case TObjectId.eArc or TObjectId.ePie or TObjectId.eEllipticalArc:
                    int radius = ((ISch_Arc)primitive).GetState_Radius();
                    int vertical = id == TObjectId.eEllipticalArc
                        ? ((ISch_EllipticalArc)primitive).GetState_SecondaryRadius() : radius;
                    Include(ref body, location.X - radius, location.Y - vertical);
                    break;
                case TObjectId.eEllipse:
                    var ellipse = (ISch_Ellipse)primitive;
                    Include(ref body, location.X - ellipse.GetState_Radius(), location.Y - ellipse.GetState_SecondaryRadius());
                    break;
            }
        }
        return body ?? pin ?? new DXP.Point();

        static void Include(ref DXP.Point? bounds, int x, int y)
        {
            bounds = bounds is { } point
                ? new DXP.Point { X = Math.Min(point.X, x), Y = Math.Min(point.Y, y) }
                : new DXP.Point { X = x, Y = y };
        }
    }
}
