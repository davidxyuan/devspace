using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

internal static class OpenCodexTrayLauncher
{
    private static string Quote(string value)
    {
        if (value == null) return "\"\"";
        var sb = new StringBuilder();
        sb.Append('"');
        int backslashes = 0;
        foreach (char ch in value)
        {
            if (ch == '\\') { backslashes++; continue; }
            if (ch == '"')
            {
                sb.Append('\\', backslashes * 2 + 1);
                sb.Append('"');
                backslashes = 0;
                continue;
            }
            if (backslashes > 0) { sb.Append('\\', backslashes); backslashes = 0; }
            sb.Append(ch);
        }
        if (backslashes > 0) sb.Append('\\', backslashes * 2);
        sb.Append('"');
        return sb.ToString();
    }

    private static string Required(Dictionary<string, object> state, string key)
    {
        object raw;
        if (!state.TryGetValue(key, out raw) || raw == null)
            throw new InvalidDataException("Missing tray state field: " + key);
        var value = Convert.ToString(raw);
        if (String.IsNullOrWhiteSpace(value))
            throw new InvalidDataException("Empty tray state field: " + key);
        return value;
    }

    private static void Log(string message)
    {
        try
        {
            var dir = AppDomain.CurrentDomain.BaseDirectory;
            File.AppendAllText(Path.Combine(dir, "opencodex-tray-launcher.log"),
                DateTimeOffset.Now.ToString("o") + " " + message + Environment.NewLine,
                Encoding.UTF8);
        }
        catch { }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            var home = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var statePath = Path.Combine(home, "tray-state.json");
            var json = File.ReadAllText(statePath, Encoding.UTF8);
            var serializer = new JavaScriptSerializer();
            var state = serializer.Deserialize<Dictionary<string, object>>(json);
            if (state == null) throw new InvalidDataException("Invalid tray-state.json");

            var script = Required(state, "script");
            var bun = Required(state, "bun");
            var bunRuntimeSource = Required(state, "bunRuntimeSource");
            var cli = Required(state, "cli");
            var codexHome = Required(state, "codexHome");
            var opencodexHome = Required(state, "opencodexHome");

            if (args != null && Array.IndexOf(args, "--validate") >= 0)
            {
                Log("validation ok");
                return 0;
            }

            var powershell = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
            if (!File.Exists(powershell)) powershell = "powershell.exe";

            var powerShellArgs = String.Join(" ", new [] {
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-STA",
                "-ExecutionPolicy", "Bypass",
                "-File", Quote(script),
                "-BunPath", Quote(bun),
                "-BunRuntimeSource", Quote(bunRuntimeSource),
                "-CliPath", Quote(cli),
                "-CodexHome", Quote(codexHome),
                "-OpenCodexHome", Quote(opencodexHome),
                "-Mode", "Run"
            });

            var startInfo = new ProcessStartInfo
            {
                FileName = powershell,
                Arguments = powerShellArgs,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                WorkingDirectory = home
            };

            var process = Process.Start(startInfo);
            if (process == null) throw new InvalidOperationException("Tray process did not start.");
            Log("started tray process pid=" + process.Id);
            process.Dispose();
            return 0;
        }
        catch (Exception ex)
        {
            Log("ERROR " + ex.GetType().Name + ": " + ex.Message);
            return 1;
        }
    }
}
