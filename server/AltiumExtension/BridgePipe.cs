using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Text.Json;
using System.Windows.Forms;

namespace AltiumMcpSdk;

internal sealed class BridgePipe(Control dispatcher, EditorCommands commands)
{
    private const int ProtocolVersion = 1;
    private const int RequestLimit = 1024 * 1024;
    private const int ResponseLimit = 64 * 1024 * 1024;
    private const int MaximumConnections = 16;
    private const int MaximumReceipts = 32;
    private static readonly JsonSerializerOptions WireJson = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower
    };

    private readonly string instanceId = Guid.NewGuid().ToString("N");
    private readonly object receiptLock = new();
    private readonly Dictionary<Guid, Completed> terminalReplies = [];
    private readonly Queue<Guid> receiptOrder = new();
    private readonly SemaphoreSlim connectionSlots = new(MaximumConnections);
    private Pending? pending;
    private int receiptBytes;

    private sealed record Request(int Protocol, string? RequestId, string? Command, JsonElement Params,
        string? InstanceId);
    private sealed record Reply(int Protocol, string? RequestId, string State, object Result);
    private sealed record Invocation(Reply Reply, long UiStart, long UiEnd);
    private sealed record Completed(Reply Reply, byte[] Frame, object TimingsMs);
    private sealed record Pending(Guid Id, long Accepted, TaskCompletionSource<byte[]> Completion);
    private static readonly Lazy<string?> HostVersion = new(() => Environment.ProcessPath is { } path
        ? FileVersionInfo.GetVersionInfo(path).ProductVersion : null);

    internal void Start()
    {
        var listener = LocalPipe.Create(Environment.ProcessId, MaximumConnections, firstInstance: true);
        _ = Listen(listener);
    }

    private async Task Listen(NamedPipeServerStream listener)
    {
        while (true)
        {
            await connectionSlots.WaitAsync().ConfigureAwait(false);
            try
            {
                await listener.WaitForConnectionAsync().ConfigureAwait(false);
                _ = ServeConnection(listener);
            }
            catch (IOException)
            {
                listener.Dispose();
                connectionSlots.Release();
            }

            while (true)
            {
                try
                {
                    listener = LocalPipe.Create(Environment.ProcessId, MaximumConnections, firstInstance: false);
                    break;
                }
                catch (IOException error)
                {
                    Trace.TraceWarning("Failed to rearm the Altium MCP pipe: {0}", error.Message);
                    await Task.Delay(250).ConfigureAwait(false);
                }
            }
        }
    }

    private async Task ServeConnection(NamedPipeServerStream connection)
    {
        using (connection)
        {
            try
            {
                if (!LocalPipe.IsSameSession(connection))
                    return;
                using var readDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                using var body = new MemoryStream();
                var readBuffer = new byte[8192];
                while (true)
                {
                    int count = await connection.ReadAsync(readBuffer, readDeadline.Token).ConfigureAwait(false);
                    if (count == 0)
                        return;
                    int end = Array.IndexOf(readBuffer, (byte)'\n', 0, count);
                    int length = end >= 0 ? end : count;
                    if (body.Length + length > RequestLimit)
                        return;
                    body.Write(readBuffer, 0, length);
                    if (end >= 0)
                        break;
                }

                byte[] reply;
                try
                {
                    var request = JsonSerializer.Deserialize<Request>(body.GetBuffer().AsSpan(0, (int)body.Length), WireJson);
                    reply = await Handle(request).ConfigureAwait(false);
                }
                catch (JsonException)
                {
                    reply = Encode(Refused(null, "Invalid bridge JSON request"));
                }

                using var writeDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                await connection.WriteAsync(reply, writeDeadline.Token).ConfigureAwait(false);
                await connection.WriteAsync("\n"u8.ToArray(), writeDeadline.Token).ConfigureAwait(false);
            }
            catch (IOException)
            {
                // A disconnected caller can recover the terminal receipt on a new connection.
            }
            catch (OperationCanceledException)
            {
                // A client can stall a pipe but cannot keep it open indefinitely.
            }
            finally
            {
                connectionSlots.Release();
            }
        }
    }

    private async Task<byte[]> Handle(Request? request)
    {
        if (request is null || request.Protocol != ProtocolVersion ||
            !Guid.TryParseExact(request.RequestId, "N", out var id) ||
            string.IsNullOrEmpty(request.Command) || request.Params.ValueKind != JsonValueKind.Object)
            return Encode(Refused(request?.RequestId, "Invalid bridge request"));

        if (request.Command == "hello")
            return Encode(Terminal(request.RequestId, new
            {
                success = true,
                pid = Environment.ProcessId,
                instance_id = instanceId,
                build = typeof(BridgePipe).Module.ModuleVersionId.ToString("N"),
                version = HostVersion.Value,
                commands = commands.Supported,
                mutating_commands = commands.Mutations
            }));

        if (request.InstanceId is not null && request.InstanceId != instanceId)
            return Encode(Refused(request.RequestId, "This request targets a different Altium extension instance"));
        if (request.Command == "status")
            return Encode(Status(request));
        if (!commands.Supported.Contains(request.Command, StringComparer.Ordinal))
            return Encode(Refused(request.RequestId, "This command is unavailable in the managed bridge"));

        Task<byte[]> result;
        lock (receiptLock)
        {
            if (terminalReplies.TryGetValue(id, out var completed))
                return completed.Frame;
            if (pending is { } existing)
            {
                if (existing.Id != id)
                    return Encode(Refused(request.RequestId, "The Altium editor is processing another managed bridge request"));
                result = existing.Completion.Task;
            }
            else
            {
                pending = new Pending(id, Stopwatch.GetTimestamp(), new(TaskCreationOptions.RunContinuationsAsynchronously));
                result = pending.Completion.Task;
                _ = Complete(pending, request);
            }
        }
        return await result.ConfigureAwait(false);
    }

    private Reply Status(Request request)
    {
        if (!request.Params.TryGetProperty("target_request_id", out var target) ||
            target.ValueKind != JsonValueKind.String || !Guid.TryParseExact(target.GetString(), "N", out var id))
            return Refused(request.RequestId, "The status query must identify its target request");
        lock (receiptLock)
        {
            terminalReplies.TryGetValue(id, out var completed);
            return Terminal(request.RequestId, new
            {
                success = true,
                pid = Environment.ProcessId,
                instance_id = instanceId,
                status = completed is { Reply.Result: EditorReply { ExecutionState: "unknown" } } ? "unknown"
                    : completed is not null ? "terminal" : pending?.Id == id ? "pending" : "unknown",
                result = completed?.Reply.Result,
                timings_ms = completed?.TimingsMs
            });
        }
    }

    private async Task Complete(Pending owned, Request request)
    {
        var onEditor = new TaskCompletionSource<Invocation>(TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            dispatcher.BeginInvoke((Action)(() =>
            {
                long started = Stopwatch.GetTimestamp();
                var reply = Execute(request);
                onEditor.SetResult(new Invocation(reply, started, Stopwatch.GetTimestamp()));
            }));
        }
        catch (InvalidOperationException)
        {
            long now = Stopwatch.GetTimestamp();
            onEditor.SetResult(new Invocation(Refused(request.RequestId, "The Altium editor dispatcher is unavailable"), now, now));
        }

        var invocation = await onEditor.Task.ConfigureAwait(false);
        var reply = invocation.Reply;
        byte[] frame;
        long encodeStart = Stopwatch.GetTimestamp();
        try
        {
            frame = Encode(reply, ResponseLimit - 4096);
        }
        catch (Exception error) when (error is IOException or JsonException or NotSupportedException)
        {
            // The editor may already have completed, so this is a terminal error.
            reply = Terminal(request.RequestId, EditorCommands.Error("Managed bridge could not encode the Altium response",
                uncertain: IsMutation(request)));
            frame = Encode(reply);
        }
        long encodeEnd = Stopwatch.GetTimestamp();

        lock (receiptLock)
        {
            terminalReplies.Add(owned.Id, new Completed(reply, frame, new
            {
                accepted_to_ui = Stopwatch.GetElapsedTime(owned.Accepted, invocation.UiStart).TotalMilliseconds,
                native_ui = Stopwatch.GetElapsedTime(invocation.UiStart, invocation.UiEnd).TotalMilliseconds,
                encode = Stopwatch.GetElapsedTime(encodeStart, encodeEnd).TotalMilliseconds
            }));
            receiptOrder.Enqueue(owned.Id);
            receiptBytes += frame.Length;
            while (receiptOrder.Count > MaximumReceipts || receiptBytes > ResponseLimit)
            {
                Guid oldest = receiptOrder.Dequeue();
                receiptBytes -= terminalReplies[oldest].Frame.Length;
                terminalReplies.Remove(oldest);
            }
            pending = null;
        }
        owned.Completion.SetResult(frame);
    }

    private Reply Execute(Request request)
    {
        try
        {
            return Terminal(request.RequestId,
                commands.RememberTargets(commands.Execute(request.Command!, request.Params, request.RequestId!)));
        }
        catch (CommandUnavailable error)
        {
            return Refused(request.RequestId, error.Message);
        }
        catch (Exception error)
        {
            Trace.TraceError("Altium managed command {0}: {1}", request.Command, error);
            return Terminal(request.RequestId, commands.RememberTargets(EditorCommands.Error(error.Message,
                uncertain: IsMutation(request))));
        }
    }

    private bool IsMutation(Request request) => commands.Mutations.Contains(request.Command, StringComparer.Ordinal);

    private static Reply Terminal(string? id, object result) => new(ProtocolVersion, id, "terminal", result);
    private static Reply Refused(string? id, string message) => new(ProtocolVersion, id, "not_started", EditorCommands.Error(message));

    private static byte[] Encode(Reply reply, int limit = ResponseLimit)
    {
        // Keep space in the limit for a status request's enclosing envelope.
        using var destination = new BoundedReplyStream(limit);
        JsonSerializer.Serialize(destination, reply, WireJson);
        return destination.ToArray();
    }

    private sealed class BoundedReplyStream(int limit) : MemoryStream
    {
        public override void Write(ReadOnlySpan<byte> bytes)
        {
            if (Position + bytes.Length > limit)
                throw new IOException("Altium MCP reply exceeds its pipe limit");
            base.Write(bytes);
        }

        public override void Write(byte[] buffer, int offset, int count)
        {
            if (Position + count > limit)
                throw new IOException("Altium MCP reply exceeds its pipe limit");
            base.Write(buffer, offset, count);
        }
    }
}
