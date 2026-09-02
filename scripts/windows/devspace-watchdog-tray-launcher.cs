using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Management;
using System.Text;
using System.Text.RegularExpressions;

internal static class Program
{
    private const int FreshHeartbeatSeconds = 15;

    private static string Quote(string value)
    {
        if (value.IndexOf('"') >= 0 || value.IndexOf('\r') >= 0 || value.IndexOf('\n') >= 0)
            throw new InvalidOperationException("Launcher paths cannot contain quotes or control characters.");
        return "\"" + value + "\"";
    }

    private static void Log(string baseDir, string message)
    {
        try
        {
            File.AppendAllText(
                Path.Combine(baseDir, "watchdog-tray-launcher.err.log"),
                DateTimeOffset.Now.ToString("o") + " " + message + Environment.NewLine,
                Encoding.UTF8);
        }
        catch { }
    }

    private static bool TryReadHeartbeat(string heartbeatPath, out int pid, out DateTimeOffset timestamp)
    {
        pid = 0;
        timestamp = DateTimeOffset.MinValue;
        try
        {
            if (!File.Exists(heartbeatPath)) return false;
            string text = File.ReadAllText(heartbeatPath, Encoding.UTF8);
            Match pidMatch = Regex.Match(text, "\\\"pid\\\"\\s*:\\s*(\\d+)", RegexOptions.IgnoreCase);
            Match timeMatch = Regex.Match(text, "\\\"timestamp\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"", RegexOptions.IgnoreCase);
            if (!pidMatch.Success || !timeMatch.Success) return false;
            if (!int.TryParse(pidMatch.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out pid)) return false;
            if (!DateTimeOffset.TryParse(timeMatch.Groups[1].Value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out timestamp)) return false;
            return pid > 0;
        }
        catch { return false; }
    }

    private static bool IsExactTrayProcess(int pid, string trayPath, string configPath)
    {
        try
        {
            using (var searcher = new ManagementObjectSearcher(
                "SELECT Name, CommandLine FROM Win32_Process WHERE ProcessId=" + pid.ToString(CultureInfo.InvariantCulture)))
            using (ManagementObjectCollection results = searcher.Get())
            {
                foreach (ManagementObject process in results)
                {
                    string name = Convert.ToString(process["Name"], CultureInfo.InvariantCulture) ?? "";
                    string commandLine = Convert.ToString(process["CommandLine"], CultureInfo.InvariantCulture) ?? "";
                    return name.Equals("powershell.exe", StringComparison.OrdinalIgnoreCase) &&
                        commandLine.IndexOf(trayPath, StringComparison.OrdinalIgnoreCase) >= 0 &&
                        commandLine.IndexOf(configPath, StringComparison.OrdinalIgnoreCase) >= 0;
                }
            }
        }
        catch { }
        return false;
    }

    private static bool ExistingTrayIsFresh(string baseDir, string trayPath, string configPath)
    {
        int pid;
        DateTimeOffset timestamp;
        string heartbeatPath = Path.Combine(baseDir, "watchdog-tray-heartbeat.json");
        if (!TryReadHeartbeat(heartbeatPath, out pid, out timestamp)) return false;
        if (!IsExactTrayProcess(pid, trayPath, configPath)) return false;
        return (DateTimeOffset.UtcNow - timestamp.ToUniversalTime()).TotalSeconds <= FreshHeartbeatSeconds;
    }

    private static void RecoverStaleTrayIfNeeded(string baseDir, string trayPath, string configPath)
    {
        int pid;
        DateTimeOffset timestamp;
        string heartbeatPath = Path.Combine(baseDir, "watchdog-tray-heartbeat.json");
        if (!TryReadHeartbeat(heartbeatPath, out pid, out timestamp)) return;
        if ((DateTimeOffset.UtcNow - timestamp.ToUniversalTime()).TotalSeconds <= FreshHeartbeatSeconds) return;
        if (!IsExactTrayProcess(pid, trayPath, configPath)) return;

        try
        {
            Process stale = Process.GetProcessById(pid);
            stale.Kill();
            stale.WaitForExit(3000);
            stale.Dispose();
            Log(baseDir, "Recovered stale Tray PID " + pid.ToString(CultureInfo.InvariantCulture) + ".");
        }
        catch (Exception ex)
        {
            Log(baseDir, "Failed to recover stale Tray PID " + pid.ToString(CultureInfo.InvariantCulture) + ": " + ex.Message);
        }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
        try
        {
            string trayPath = Path.Combine(baseDir, "devspace-watchdog-tray.ps1");
            string configPath = Path.Combine(baseDir, "devspace-watchdog.config.json");
            string powershell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "System32", "WindowsPowerShell", "v1.0", "powershell.exe");

            if (!File.Exists(trayPath)) throw new FileNotFoundException("Tray script is missing.", trayPath);
            if (!File.Exists(configPath)) throw new FileNotFoundException("Watchdog config is missing.", configPath);
            if (!File.Exists(powershell)) throw new FileNotFoundException("Windows PowerShell is missing.", powershell);

            string mode = "Run";
            if (args.Length > 0 && string.Equals(args[0], "-Stop", StringComparison.OrdinalIgnoreCase)) mode = "Stop";

            if (mode == "Run")
            {
                if (ExistingTrayIsFresh(baseDir, trayPath, configPath)) return 0;
                RecoverStaleTrayIfNeeded(baseDir, trayPath, configPath);
            }

            string arguments = string.Join(" ", new[] {
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-STA",
                "-ExecutionPolicy", "Bypass",
                "-File", Quote(trayPath),
                "-Mode", mode,
                "-ConfigPath", Quote(configPath)
            });

            var startInfo = new ProcessStartInfo
            {
                FileName = powershell,
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                WorkingDirectory = baseDir
            };

            Process child = Process.Start(startInfo);
            if (child == null) throw new InvalidOperationException("Tray PowerShell process did not start.");
            child.Dispose();
            return 0;
        }
        catch (Exception ex)
        {
            Log(baseDir, ex.ToString());
            return 1;
        }
    }
}
