using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;
using DXP;
using PCB;

namespace AltiumMcpSdk;

internal sealed partial class EditorCommands
{
    private const string RoutingBatchHeader = "kind\taction\tnet\told_geometry\tnew_geometry";
    private const string RoutingAuditHeader = "row\tkind\taction\tresult";
    private const string ChangedRoutingBaseline = "PCB changed since baseline snapshot; refresh and replan.";
    private const string RoutingNativeFailure = "Native API or file call failed; inspect exact PCB and operation artifacts before retry.";
    private static readonly UTF8Encoding RoutingUtf8 = new(false, true);

    private sealed class RoutingBatchRejected(string message) : Exception(message);

    private readonly record struct RoutingKey(string Kind, string Net, string Geometry);

    private sealed record RoutingRow(string Kind, string Action, string Net, string OldGeometry, string NewGeometry)
    {
        internal RoutingKey NetKey => new("net", Net, "");
        internal RoutingKey OldKey => new(Kind, Net, OldGeometry);
        internal RoutingKey NewKey => new(Kind, Net, NewGeometry);
        internal IPCB_Primitive? Target { get; set; }
        internal IPCB_Primitive? Candidate { get; set; }
        internal IPCB_Net? TargetNet { get; set; }
    }

    // An absent key was not requested. A requested key has zero, one, or more matches.
    private sealed class RoutingMatches
    {
        private readonly Dictionary<RoutingKey, (int Count, IPCB_Primitive? Primitive)> matches = [];

        internal void Request(RoutingKey key) => matches.TryAdd(key, (0, null));

        internal void Record(RoutingKey key, IPCB_Primitive primitive)
        {
            if (matches.TryGetValue(key, out var match))
                matches[key] = (match.Count + 1, match.Count == 0 ? primitive : null);
        }

        internal (int Count, IPCB_Primitive? Primitive) Find(RoutingKey key) => matches[key];
    }

    private object ApplyGuardedRoutingBatch(JsonElement parameters, string requestId)
    {
        string directory = StringParameter(parameters, "operation_directory");
        string expectedBoard = StringParameter(parameters, "expected_board");
        string snapshotId = StringParameter(parameters, "snapshot_id");
        if (!Path.IsPathFullyQualified(directory) || !Directory.Exists(directory) ||
            !Path.IsPathFullyQualified(expectedBoard) || snapshotId.Length == 0)
            throw new CommandUnavailable("A guarded routing batch requires an operation directory, exact PCB path and snapshot ID");

        var server = PCB.GlobalVars.PCBServer
            ?? throw new CommandUnavailable("The PCB editor is unavailable");
        RoutingFloatValues floatValues;
        try
        {
            RequireSupportedRoutingCollation(directory);
            floatValues = RoutingFloatValues.Read(directory);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or DecoderFallbackException)
        {
            throw new CommandUnavailable("The managed bridge requires the staged PCB signature and floating-point values");
        }
        var receipt = new RoutingBatchReceipt(directory, requestId);
        var rows = new List<RoutingRow>();
        bool groupUndo = RoutingFlag(parameters, "undo_group");
        bool allowViaInPad = RoutingFlag(parameters, "allow_via_in_pad");

        try
        {
            var board = server.GetCurrentPCBBoard();
            if (board is null)
                throw new RoutingBatchRejected("Activate the exact requested PCB first.");
            string path = board.GetState_FileName();
            if (RoutingUpperCase(path) != RoutingUpperCase(expectedBoard))
                throw new RoutingBatchRejected("Activate the exact requested PCB first. PCB full-path mismatch.");
            RequireExactRoutingView(server, path);
            boardPath = path;
            receipt.Status("started", 0);

            var matches = new RoutingMatches();
            ReadRoutingBatch(receipt, rows, matches);
            receipt.Measure("baseline_index_ms", () => CheckRoutingBaseline(board, directory, floatValues, matches));
            receipt.WriteTimings();
            receipt.Measure("candidate_preparation_ms", () =>
                PrepareRoutingCandidates(board, server, receipt, rows, matches, allowViaInPad));
            receipt.Measure("baseline_recheck_ms", () => CheckRoutingBaseline(board, directory, floatValues));
            receipt.Measure("mutation_ms", () => MutateRoutingBatch(board, server, path, receipt, rows, groupUndo));
            receipt.Measure("post_edit_inventory_ms", () => ExportRoutingInventory(board, directory, snapshotId, floatValues));
            receipt.Status("complete_native_drc_not_checked", rows.Count);
            board.ViewManager_FullUpdate();

            return Success(new
            {
                applied = true,
                completed_rows = receipt.CompletedRows,
                undo_steps = receipt.UndoSteps,
                native_drc_checked = false,
                saved = false
            });
        }
        catch (RoutingBatchRejected error)
        {
            receipt.Status("failed_inspect_artifacts_before_retry", 0, error.Message);
            return Error(error.Message);
        }
        catch (Exception error)
        {
            Trace.TraceError("Altium guarded routing batch {0}: {1}", requestId, error);
            CSharpPlugin.SdkStartupLog.Write($"Guarded routing batch {requestId}: {error}");
            receipt.Status("failed_inspect_artifacts_before_retry", 0, RoutingNativeFailure);
            return Error(RoutingNativeFailure, uncertain: receipt.MutationAttempted);
        }
        finally
        {
            try
            {
                foreach (var row in rows)
                    if (row.Candidate is { } candidate)
                        server.DestroyPCBObject(ref candidate);
            }
            finally
            {
                receipt.WriteTimings();
            }
        }
    }

    private static bool RoutingFlag(JsonElement parameters, string name) =>
        parameters.TryGetProperty(name, out var value) &&
        (value.ValueKind == JsonValueKind.True || value.ValueKind == JsonValueKind.String && value.GetString() == "true");

    private void RequireExactRoutingView(IPCB_ServerInterface server, string path)
    {
        var activeBoard = server.GetCurrentPCBBoard();
        if (activeBoard is null)
            throw new RoutingBatchRejected("Activate the exact requested PCB first.");
        if (RoutingUpperCase(activeBoard.GetState_FileName()) != RoutingUpperCase(path))
            throw new RoutingBatchRejected("The requested PCB must be active.");
        var view = client.GetCurrentView();
        if (view is null)
            throw new RoutingBatchRejected("The exact PCB must have an active document view.");
        var document = view.GetOwnerDocument();
        if (document is null)
            throw new RoutingBatchRejected("The active view has no PCB document.");
        if (RoutingUpperCase(document.GetFileName()) != RoutingUpperCase(path))
            throw new RoutingBatchRejected("The active document view must belong to the exact requested PCB.");
    }

    private static void ReadRoutingBatch(RoutingBatchReceipt receipt, List<RoutingRow> rows, RoutingMatches matches)
    {
        string[] lines = File.ReadAllLines(Path.Combine(receipt.Directory, "operations.tsv"), RoutingUtf8);
        if (lines.Length is < 2 or > 257)
            throw new RoutingBatchRejected("Batch requires 1-256 rows.");
        if (lines[0] != RoutingBatchHeader)
            throw new RoutingBatchRejected("Invalid batch header.");

        for (int index = 1; index < lines.Length; index++)
        {
            receipt.Status("preflight", index);
            string[] fields = lines[index].Split('\t');
            if (fields.Length != 5)
                throw new RoutingBatchRejected("Batch row requires five columns.");
            var row = new RoutingRow(fields[0], fields[1], fields[2], fields[3], fields[4]);
            if (row.Kind is not ("track" or "via"))
                throw new RoutingBatchRejected("Unsupported batch primitive.");
            if (row.Action is not ("add" or "edit" or "remove"))
                throw new RoutingBatchRejected("Unsupported batch action.");
            if (row.Action == "add" && row.OldGeometry != "-")
                throw new RoutingBatchRejected("Add must omit old geometry.");
            if (row.Action == "remove" && row.NewGeometry != "-")
                throw new RoutingBatchRejected("Remove must omit new geometry.");

            if (row.Net.Length != 0)
                matches.Request(row.NetKey);
            if (row.Action != "add")
                matches.Request(row.OldKey);
            if (row.Action != "remove")
                matches.Request(row.NewKey);
            rows.Add(row);
        }
    }

    private static void CheckRoutingBaseline(IPCB_Board board, string directory, RoutingFloatValues floatValues,
        RoutingMatches? matches = null)
    {
        // Reload immediately at each check. Older snapshots omitted one or both signal-context records.
        string[] baseline = File.ReadAllLines(Path.Combine(directory, "baseline-signature.txt"), RoutingUtf8);
        List<string> signature;
        try
        {
            signature = CollectRoutingInventory(board, floatValues, matches, null);
        }
        catch (MissingRoutingFloatValue)
        {
            throw new RoutingBatchRejected(ChangedRoutingBaseline);
        }
        if (!baseline.Contains("routing-context-v1", StringComparer.OrdinalIgnoreCase))
            signature.RemoveAll(line => line.StartsWith("routing-", StringComparison.Ordinal));
        else if (!baseline.Any(line => line.StartsWith("routing-depths\t", StringComparison.Ordinal)))
            signature.RemoveAll(line => line.StartsWith("routing-depths\t", StringComparison.Ordinal));

        signature.Sort(CompareRoutingRows);
        if (!signature.SequenceEqual(baseline, StringComparer.Ordinal))
            throw new RoutingBatchRejected(ChangedRoutingBaseline);
    }

    private static void RequireSupportedRoutingCollation(string directory)
    {
        // Different strings can compare as equal in TStringList's locale sort. Its
        // ordering of those records is unspecified, so let the resident guard compare
        // such a baseline before the managed handler starts or creates candidates.
        string? previous = null;
        foreach (string line in File.ReadLines(Path.Combine(directory, "baseline-signature.txt"), RoutingUtf8))
        {
            if (previous is not null && previous != line && CompareRoutingRows(previous, line) == 0)
                throw new CommandUnavailable("The baseline has records that cannot be ordered exactly by the managed bridge");
            previous = line;
        }
    }

    private static void PrepareRoutingCandidates(IPCB_Board board, IPCB_ServerInterface server,
        RoutingBatchReceipt receipt, List<RoutingRow> rows, RoutingMatches matches, bool allowViaInPad)
    {
        var oldTargets = new HashSet<RoutingKey>();
        var destinations = new HashSet<(string Kind, string Geometry)>();
        Dictionary<TV6_Layer, V7_LayerBase>? copperLayers = null;
        for (int index = 0; index < rows.Count; index++)
        {
            int number = index + 1;
            var row = rows[index];
            receipt.Status("preflight", number);
            if (row.Net.Length != 0)
            {
                row.TargetNet = matches.Find(row.NetKey).Primitive as IPCB_Net;
                if (row.TargetNet is null)
                    throw new RoutingBatchRejected("Net must resolve to exactly one existing PCB net.");
            }
            if (row.Action == "add" && row.TargetNet is null)
                throw new RoutingBatchRejected("New copper requires an assigned net.");
            if (row.Action != "add")
            {
                row.Target = matches.Find(row.OldKey).Primitive;
                if (row.Target is null)
                    throw new RoutingBatchRejected("Old target does not resolve exactly once.");
                if (!oldTargets.Add(row.OldKey))
                    throw new RoutingBatchRejected("Repeated old target.");
            }
            if (row.Action != "remove")
            {
                var objectId = row.Kind == "track" ? TObjectId.eTrackObject : TObjectId.eViaObject;
                var candidate = server.PCBObjectFactory(objectId, TDimensionKind.eNoDimension,
                                    TObjectCreationMode.eCreate_Default)
                                ?? throw new RoutingBatchRejected("Primitive factory failed.");
                row.Candidate = candidate;
                if (row.Kind == "via")
                    copperLayers ??= CopperElectricalLayers(board).Values.DistinctBy(layer => layer.V6)
                        .ToDictionary(layer => layer.V6, layer => layer.V7);
                SetRoutingGeometry(candidate, row.NewGeometry, copperLayers);
                if (row.TargetNet is not null)
                    candidate.SetState_Net(row.TargetNet);
                if (RoutingGeometry(candidate) != row.NewGeometry)
                    throw new RoutingBatchRejected("Noncanonical geometry request.");
                if (row.Kind == "via")
                {
                    var via = (IPCB_Via)candidate;
                    CheckRoutingViaCenter(board, row, via, allowViaInPad);
                    if (row.Action == "add" && (RoutingLowLayer(via) != (int)TV6_Layer.eV6_TopLayer ||
                                               RoutingHighLayer(via) != (int)TV6_Layer.eV6_BottomLayer))
                        throw new RoutingBatchRejected("New vias support through span only.");
                    if (row.Target is not null)
                    {
                        var oldVia = (IPCB_Via)row.Target;
                        if (RoutingLowLayer(via) != RoutingLowLayer(oldVia) || RoutingHighLayer(via) != RoutingHighLayer(oldVia))
                            throw new RoutingBatchRejected("Via edits must preserve drill span.");
                    }
                }
                int count = matches.Find(row.NewKey).Count;
                if (count > 0)
                {
                    if (row.Target is null)
                        throw new RoutingBatchRejected("Destination already exists.");
                    if (count != 1)
                        throw new RoutingBatchRejected("Destination is ambiguous.");
                    if (row.NewKey != row.OldKey)
                        throw new RoutingBatchRejected("Destination already exists.");
                }
                if (!destinations.Add((row.Kind, row.NewGeometry)))
                    throw new RoutingBatchRejected("Repeated destination.");
            }
            receipt.Audit(number, row, "preflight_ok");
        }
        receipt.WriteAudit();
    }

    private static void CheckRoutingViaCenter(IPCB_Board board, RoutingRow row, IPCB_Via via, bool allowViaInPad)
    {
        int x = via.GetState_XLocation();
        int y = via.GetState_YLocation();
        double radius = via.GetState_Size() / 2.0;
        foreach (var primitive in BoardObjects(board, TObjectId.eViaObject, TObjectId.ePadObject))
        {
            if (primitive.GetState_ObjectID() == TObjectId.eViaObject)
            {
                var existing = (IPCB_Via)primitive;
                if (existing.GetState_XLocation() == x && existing.GetState_YLocation() == y &&
                    (row.Target is null || RoutingNet(existing) != row.Net || RoutingGeometry(existing) != row.OldGeometry))
                    throw new RoutingBatchRejected("Via center is already occupied.");
                continue;
            }

            var pad = (IPCB_Pad)primitive;
            double angle = pad.GetState_Rotation() * 0.017453292519943295;
            double cosine = Math.Cos(angle);
            double sine = Math.Sin(angle);
            double dx = (double)x - pad.GetState_XLocation();
            double dy = (double)y - pad.GetState_YLocation();
            double u = Math.Max(0, Math.Abs(dx * cosine + dy * sine) - pad.GetState_TopXSize() / 2.0);
            double v = Math.Max(0, Math.Abs(-dx * sine + dy * cosine) - pad.GetState_TopYSize() / 2.0);
            if (u * u + v * v <= radius * radius && (!allowViaInPad || RoutingNet(pad) != row.Net))
                throw new RoutingBatchRejected("Via in pad requires explicit same-net allowance.");
        }
    }

    private void MutateRoutingBatch(IPCB_Board board, IPCB_ServerInterface server, string path,
        RoutingBatchReceipt receipt, List<RoutingRow> rows, bool groupUndo)
    {
        bool undoOpen = false;
        try
        {
            for (int index = 0; index < rows.Count; index++)
            {
                int number = index + 1;
                var row = rows[index];
                RequireExactRoutingView(server, path);
                if (row.Target is { } target && (RoutingNet(target) != row.Net || RoutingGeometry(target) != row.OldGeometry))
                    throw new RoutingBatchRejected("Target changed during batch.");

                receipt.Status("applying_partial_changes_possible", number);
                receipt.Audit(number, row, "mutation_attempted");
                receipt.WriteAudit();
                receipt.MutationAttempted = true;
                if (!undoOpen)
                {
                    server.PreProcess();
                    undoOpen = true;
                    receipt.UndoSteps++;
                }

                IPCB_Primitive primitive;
                try
                {
                    primitive = MutateRoutingRow(board, row);
                }
                finally
                {
                    if (!groupUndo)
                    {
                        undoOpen = false;
                        server.PostProcess();
                    }
                }
                if (row.Action != "remove" && row.Kind == "track")
                    CheckAttachedRoutingWidth(board, (IPCB_Track)primitive, row.TargetNet);
                receipt.CompletedRows++;
                receipt.Audit(number, row, "readback_pending_exact_batch_comparison");
                receipt.WriteAudit();
            }
        }
        finally
        {
            if (undoOpen)
                server.PostProcess();
        }
    }

    private static IPCB_Primitive MutateRoutingRow(IPCB_Board board, RoutingRow row)
    {
        if (row.Action == "remove")
        {
            var target = row.Target!;
            board.RemovePCBObject(target);
            IPCB_BoardHelper.DispatchMessage(board, board, null!, CopperBoardRegistration, target);
            return target;
        }

        if (row.Action == "add")
        {
            var candidate = row.Candidate!;
            // Attachment may have happened even if the SDK call throws. Once handed to
            // the board, the cleanup path cannot assume the candidate is still detached.
            row.Candidate = null;
            board.AddPCBObject(candidate);
            IPCB_BoardHelper.DispatchMessage(board, board, null!, CopperBoardRegistration, candidate);
            if (RoutingGeometry(candidate) != row.NewGeometry)
                throw new RoutingBatchRejected("Added primitive readback failed.");
            return candidate;
        }

        var primitive = row.Target!;
        primitive.BeginModify();
        try
        {
            SetRoutingGeometry(primitive, row.NewGeometry);
        }
        finally
        {
            primitive.EndModify();
        }
        if (RoutingGeometry(primitive) != row.NewGeometry)
            throw new RoutingBatchRejected("Edited primitive readback failed.");
        return primitive;
    }

    private static void CheckAttachedRoutingWidth(IPCB_Board board, IPCB_Track track, IPCB_Net? net)
    {
        const string recovery = "inspect the attempted row and Undo before retrying.";
        var layer = new V7_Layer(track.GetState_Layer());
        int minimum;
        int maximum;
        if (net?.GetState_InDifferentialPair() == true)
        {
            var rule = board.FindDominantRuleForObject(track, TRuleKind.eRule_DifferentialPairsRouting)
                as IPCB_DifferentialPairsRoutingRule
                ?? throw new RoutingBatchRejected("Attached pair track has no dominant differential routing rule; " + recovery);
            minimum = rule.GetState_MinWidth(layer);
            maximum = rule.GetState_MaxWidth(layer);
        }
        else
        {
            var rule = board.FindDominantRuleForObject(track, TRuleKind.eRule_MaxMinWidth)
                as IPCB_MaxMinWidthConstraint
                ?? throw new RoutingBatchRejected("Attached track has no dominant width rule; " + recovery);
            minimum = rule.GetState_MinWidth(layer);
            maximum = rule.GetState_MaxWidth(layer);
        }
        int width = track.GetState_Width();
        if (width < minimum || width > maximum)
            throw new RoutingBatchRejected("Applied track width is outside its native dominant rule; " + recovery);
    }

    private static void SetRoutingGeometry(IPCB_Primitive primitive, string geometry,
        IReadOnlyDictionary<TV6_Layer, V7_LayerBase>? copperLayers = null)
    {
        string[] fields = geometry.Split(',');
        if (fields.Length != 6)
            throw new RoutingBatchRejected("Track/via geometry requires six integer fields.");
        var values = Array.ConvertAll(fields, field => int.Parse(field, CultureInfo.InvariantCulture));
        // The SDK's COM wrappers support the interface cast before the native
        // object has been checked. Dispatch on ObjectID before calling setters.
        if (primitive.GetState_ObjectID() == TObjectId.eTrackObject)
        {
            var track = (IPCB_Track)primitive;
            track.SetState_X1(values[0]);
            track.SetState_Y1(values[1]);
            track.SetState_X2(values[2]);
            track.SetState_Y2(values[3]);
            track.SetState_Width(values[4]);
            track.SetState_Layer((TV6_Layer)values[5]);
            if (track.GetState_Width() <= 0 ||
                track.GetState_X1() == track.GetState_X2() && track.GetState_Y1() == track.GetState_Y2())
                throw new RoutingBatchRejected("Invalid track dimensions.");
        }
        else
        {
            var via = (IPCB_Via)primitive;
            via.SetState_XLocation(values[0]);
            via.SetState_YLocation(values[1]);
            via.SetState_Size(values[2]);
            via.SetState_HoleSize(values[3]);
            if (copperLayers is not null)
            {
                if (!copperLayers.TryGetValue((TV6_Layer)values[4], out var low) ||
                    !copperLayers.TryGetValue((TV6_Layer)values[5], out var high))
                    throw new RoutingBatchRejected("Via span is absent from the copper stack.");
                via.SetState_LowLayer(low);
                via.SetState_HighLayer(high);
            }
            if (via.GetState_HoleSize() <= 0 || via.GetState_Size() <= via.GetState_HoleSize())
                throw new RoutingBatchRejected("Invalid via dimensions.");
        }
    }

    private sealed class RoutingBatchReceipt(string directory, string requestId)
    {
        private readonly List<string> audit = [RoutingAuditHeader];
        private readonly Dictionary<string, double> timings = [];

        internal string Directory => directory;
        internal int CompletedRows { get; set; }
        internal int UndoSteps { get; set; }
        internal bool MutationAttempted { get; set; }

        internal void Status(string phase, int row, string error = "") =>
            File.WriteAllText(Path.Combine(directory, "operation-status.json"), JsonSerializer.Serialize(new
            {
                request_id = requestId,
                phase,
                row,
                completed_rows = CompletedRows,
                error,
                saved = false
            }) + Environment.NewLine);

        internal void Audit(int number, RoutingRow row, string result)
        {
            string line = RoutingFormat($"{number}\t{row.Kind}\t{row.Action}\t{result}");
            if (audit.Count == number)
                audit.Add(line);
            else
                audit[number] = line;
        }

        internal void WriteAudit() => File.WriteAllLines(Path.Combine(directory, "batch-audit.tsv"), audit);

        internal void Measure(string phase, Action action)
        {
            long start = Stopwatch.GetTimestamp();
            try
            {
                action();
            }
            finally
            {
                timings[phase] = Stopwatch.GetElapsedTime(start).TotalMilliseconds;
            }
        }

        internal void WriteTimings()
        {
            try
            {
                File.WriteAllText(Path.Combine(directory, "batch-timings.json"), JsonSerializer.Serialize(new
                {
                    request_id = requestId,
                    backend = "managed",
                    pid = Environment.ProcessId,
                    build = typeof(EditorCommands).Module.ModuleVersionId.ToString("N"),
                    timings_ms = timings
                }) + Environment.NewLine);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                Trace.TraceWarning("Cannot write guarded routing phase timings for {0}: {1}", requestId, error);
            }
        }
    }
}
