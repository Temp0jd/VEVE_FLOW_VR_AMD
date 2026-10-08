using System.Diagnostics;

static string Quote(string value)
{
    return "\"" + value.Replace("\"", "\\\"") + "\"";
}

static string? FindProjectRoot(string start)
{
    var dir = new DirectoryInfo(start);
    while (dir != null)
    {
        var sender = Path.Combine(
            dir.FullName,
            "Wave_Native_SDK",
            "samples",
            "wvr_flow_probe",
            "tools",
            "live_h264_socket_sender.py");
        if (File.Exists(sender))
        {
            return dir.FullName;
        }
        dir = dir.Parent;
    }
    return null;
}

// "nvenc" on Nvidia, "amf" on AMD/Radeon, "qsv" on Intel, x264 when nothing matches. The
// fallback stream has no D3D device to ask, so the adapter name from CIM is used instead.
static string DetectEncoder()
{
    try
    {
        using var probe = new Process();
        probe.StartInfo = new ProcessStartInfo
        {
            FileName = "powershell",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            CreateNoWindow = true,
        };
        probe.StartInfo.ArgumentList.Add("-NoProfile");
        probe.StartInfo.ArgumentList.Add("-Command");
        probe.StartInfo.ArgumentList.Add("(Get-CimInstance Win32_VideoController | Select-Object -First 1 -ExpandProperty Name)");
        probe.Start();
        var name = probe.StandardOutput.ReadToEnd();
        probe.WaitForExit(5000);
        if (name.Contains("NVIDIA", StringComparison.OrdinalIgnoreCase))
        {
            return "nvenc";
        }
        if (name.Contains("AMD", StringComparison.OrdinalIgnoreCase) || name.Contains("Radeon", StringComparison.OrdinalIgnoreCase))
        {
            return "amf";
        }
        if (name.Contains("Intel", StringComparison.OrdinalIgnoreCase))
        {
            return "qsv";
        }
    }
    catch
    {
        // Fall through to software encoding.
    }
    return "x264";
}

var projectRoot = FindProjectRoot(AppContext.BaseDirectory)
                  ?? FindProjectRoot(Environment.CurrentDirectory);
if (projectRoot == null)
{
    Console.Error.WriteLine("Cannot find the project root (run from inside the VEVE_FLOW_VR checkout).");
    return 2;
}

var sender = Path.Combine(projectRoot, "Wave_Native_SDK", "samples", "wvr_flow_probe", "tools", "live_h264_socket_sender.py");
if (!File.Exists(sender))
{
    Console.Error.WriteLine("Cannot find sender script: " + sender);
    return 2;
}

var senderWorkDir = Path.GetDirectoryName(sender)!;

// Encoder for the fallback stream: an explicit nvenc/amf/qsv/mf/x264 argument, or "auto" to pick
// by the installed GPU. The SteamVR driver path chooses its own encoder the same way.
var encoder = args.Length > 0 ? args[0].ToLowerInvariant() : "auto";
if (encoder == "auto")
{
    encoder = DetectEncoder();
}

var senderArgs = string.Join(" ", new[]
{
    Quote(sender),
    "--source", "ddagrab",
    "--encoder", encoder,
    "--width", "1920",
    "--height", "1080",
    "--fps", "75",
    "--bitrate", "60M",
    "--frames", "0"
});

Console.WriteLine("Flow desktop streamer");
Console.WriteLine($"PC sender: 1920x1080 @ 75 fps, {encoder}, LAN discovery enabled");
Console.WriteLine("Open the Flow app from the headset. No ADB or SteamVR dashboard is required.");
Console.WriteLine("Press Ctrl+C to stop.");
Console.WriteLine();

using var process = new Process();
process.StartInfo = new ProcessStartInfo
{
    FileName = "python",
    Arguments = senderArgs,
    WorkingDirectory = senderWorkDir,
    UseShellExecute = false,
    RedirectStandardOutput = true,
    RedirectStandardError = true,
    CreateNoWindow = false,
};

process.OutputDataReceived += (_, e) =>
{
    if (e.Data != null)
    {
        Console.WriteLine(e.Data);
    }
};
process.ErrorDataReceived += (_, e) =>
{
    if (e.Data != null)
    {
        Console.Error.WriteLine(e.Data);
    }
};

Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    try
    {
        if (!process.HasExited)
        {
            process.Kill(entireProcessTree: true);
        }
    }
    catch
    {
    }
};

process.Start();
process.BeginOutputReadLine();
process.BeginErrorReadLine();
process.WaitForExit();
return process.ExitCode;
