using System;
using System.Diagnostics;
using System.IO;
using System.Text;

internal static class Program
{
    private static string Quote(string value)
    {
        if (value.IndexOf('"') >= 0 || value.IndexOf('\r') >= 0 || value.IndexOf('\n') >= 0)
            throw new InvalidOperationException("Launcher paths cannot contain quotes or control characters.");
        return "\"" + value + "\"";
    }

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
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
            try
            {
                File.AppendAllText(
                    Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "watchdog-tray-launcher.err.log"),
                    DateTimeOffset.Now.ToString("o") + " " + ex + Environment.NewLine,
                    Encoding.UTF8);
            }
            catch { }
            return 1;
        }
    }
}
