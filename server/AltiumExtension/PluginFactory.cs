using System.Runtime.InteropServices;
using System.IO;
using System.Windows.Forms;
using AltiumMcpSdk;
using DXP;

[assembly: ComVisible(true)]
[assembly: Guid("a918f3e5-b0f4-4b94-8e21-1a5e5f71b36a")]

namespace CSharpPlugin;

public interface IPluginFactory
{
    object InvokePluginFactory(IClient client);
}

[ClassInterface(ClassInterfaceType.AutoDispatch)]
public class PluginFactory : IPluginFactory
{
    public object InvokePluginFactory(IClient client)
    {
        SdkStartupLog.Write("Factory entered");
        try
        {
            return new PluginServerModule(client);
        }
        catch (Exception error)
        {
            SdkStartupLog.Write("Factory failed: " + error);
            throw;
        }
    }
}

[ClassInterface(ClassInterfaceType.AutoDispatch)]
public class PluginServerModule : ServerModule
{
    private readonly IClient client;
    private BridgePipe? pipe;

    public PluginServerModule(IClient client) : base(client, "AltiumMcpSdk")
    {
        this.client = client;
        SdkStartupLog.Write("Server module constructed");
        StartBridge();
    }

    protected override void InitializeCommands()
    {
        SdkStartupLog.Write("InitializeCommands entered");
        try
        {
            var launcher = (CommandLauncher)CommandLauncher;
            launcher.RegisterCommand("Start", Start, GetStartState);
            launcher.RegisterCommand("Run", Start, GetStartState);
            SdkStartupLog.Write("Start and Run commands registered");
        }
        catch (Exception error)
        {
            SdkStartupLog.Write("InitializeCommands failed: " + error);
            throw;
        }
    }

    protected override IServerDocument NewDocumentInstance(string kind, string fileName) => null!;

    private void Start(IServerDocumentView view, ref string parameters)
    {
        SdkStartupLog.Write("Start command entered");
        StartBridge();
    }

    private void StartBridge()
    {
        if (pipe is not null)
            return;

        var dispatcher = new Control();
        // Its handle binds BeginInvoke to Altium's main editor thread.
        try
        {
            _ = dispatcher.Handle;
            var newPipe = new BridgePipe(dispatcher, new EditorCommands(client));
            newPipe.Start();
            pipe = newPipe;
            SdkStartupLog.Write("Managed pipe bound");
        }
        catch (Exception error)
        {
            SdkStartupLog.Write("Managed pipe startup failed: " + error);
            dispatcher.Dispose();
            throw;
        }
    }

    private void GetStartState(IServerDocumentView view, ref string parameters, ref bool enabled,
        ref bool isChecked, ref bool visible, ref string caption, ref string imageFile)
    {
        enabled = true;
        visible = true;
    }
}

internal static class SdkStartupLog
{
    internal static void Write(string message)
    {
        string? file = Environment.GetEnvironmentVariable("ALTIUM_MCP_SDK_LOG");
        if (string.IsNullOrEmpty(file) || !Path.IsPathFullyQualified(file))
            return;
        try
        {
            File.AppendAllText(file, $"{DateTimeOffset.UtcNow:O} [{Environment.ProcessId}] {message}{Environment.NewLine}");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            // Diagnostic output is optional.
        }
    }
}
