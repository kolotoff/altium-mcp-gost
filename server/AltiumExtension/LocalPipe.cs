using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace AltiumMcpSdk;

internal static class LocalPipe
{
    private const uint Duplex = 3;
    private const uint Overlapped = 0x40000000;
    private const uint FirstPipeInstance = 0x00080000;
    private const uint RejectRemoteClients = 0x00000008;
    private static readonly int SessionId = Process.GetCurrentProcess().SessionId;
    private static readonly string UserSid = GetUserSid();

    internal static NamedPipeServerStream Create(int pid, int maximumConnections, bool firstInstance)
    {
        // Explicit DACL and pipe mode keep both other users and remote clients out.
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor($"D:P(A;;GA;;;{UserSid})", 1,
                out var descriptor, IntPtr.Zero))
            throw Error("Cannot create security descriptor for the Altium MCP pipe");
        try
        {
            var security = new SecurityAttributes
            {
                Length = Marshal.SizeOf<SecurityAttributes>(),
                Descriptor = descriptor
            };
            uint openMode = Duplex | Overlapped | (firstInstance ? FirstPipeInstance : 0);
            var handle = CreateNamedPipe($@"\\.\pipe\altium-mcp-sdk-{pid}", openMode, RejectRemoteClients,
                maximumConnections, 65536, 65536, 0, ref security);
            if (handle.IsInvalid)
            {
                var error = Error("Cannot create the Altium MCP pipe");
                handle.Dispose();
                throw error;
            }
            try
            {
                return new NamedPipeServerStream(PipeDirection.InOut, isAsync: true, isConnected: false, handle);
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }
        finally
        {
            _ = LocalFree(descriptor);
        }
    }

    internal static bool IsSameSession(NamedPipeServerStream pipe) =>
        GetNamedPipeClientSessionId(pipe.SafePipeHandle, out uint sessionId) && sessionId == SessionId;

    private static string GetUserSid()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return identity.User?.Value ?? throw new InvalidOperationException("Cannot identify the Altium user");
    }

    private static IOException Error(string message) => new(message, new Win32Exception(Marshal.GetLastWin32Error()));

    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes
    {
        public int Length;
        public IntPtr Descriptor;
        public int InheritHandle;
    }

    [DllImport("advapi32.dll", EntryPoint = "ConvertStringSecurityDescriptorToSecurityDescriptorW",
        CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string text, uint revision,
        out IntPtr descriptor, IntPtr size);

    [DllImport("kernel32.dll", EntryPoint = "CreateNamedPipeW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafePipeHandle CreateNamedPipe(string name, uint openMode, uint pipeMode,
        int maximumInstances, int outputBufferSize, int inputBufferSize, int defaultTimeout,
        ref SecurityAttributes attributes);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientSessionId(SafePipeHandle pipe, out uint sessionId);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}
