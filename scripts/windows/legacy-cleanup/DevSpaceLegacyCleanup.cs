using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Management;
using System.Security.Principal;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

namespace DevSpaceLegacyCleanup
{
    internal static class Program
    {
        private static string _installDirOverride = "";
        private static string _targetSid = "";
        private static string _targetUser = "";

        private static readonly string[] LegacyTaskNames = new[]
        {
            "DevSpaceNgrokWatchdog",
            "DevSpaceNgrokWatchdogPoller",
            "DevSpaceNgrokWatchdogUserPoller",
            "DevSpace Serve Watchdog"
        };

        private static readonly string[] LegacyStartupPrefixes = new[]
        {
            "DevSpaceWatchdogStartup",
            "DevSpace ngrok bootstrap",
            "DevSpaceNgrokWatchdog"
        };

        private static string InstallDir
        {
            get
            {
                if (!string.IsNullOrWhiteSpace(_installDirOverride)) return Path.GetFullPath(_installDirOverride);
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".devspace");
            }
        }

        private static string TargetProfileDir
        {
            get { return Directory.GetParent(InstallDir).FullName; }
        }

        private static string ScanReportPath
        {
            get { return Path.Combine(InstallDir, "DevSpaceLegacyCleanup.scan.txt"); }
        }

        [STAThread]
        private static void Main(string[] args)
        {
            _installDirOverride = GetOption(args, "--install-dir");
            _targetSid = GetOption(args, "--target-sid");
            _targetUser = GetOption(args, "--target-user");
            if (string.IsNullOrWhiteSpace(_targetSid)) _targetSid = WindowsIdentity.GetCurrent().User.Value;
            if (string.IsNullOrWhiteSpace(_targetUser)) _targetUser = Environment.UserDomainName + "\\" + Environment.UserName;

            bool scanOnly = args.Any(a => string.Equals(a, "--scan", StringComparison.OrdinalIgnoreCase));
            bool scanSilent = args.Any(a => string.Equals(a, "--scan-silent", StringComparison.OrdinalIgnoreCase));

            try
            {
                if (scanOnly || scanSilent)
                {
                    ScanResult result = ScanEnvironment();
                    File.WriteAllText(ScanReportPath, result.ToText(), new UTF8Encoding(false));
                    Environment.ExitCode = result.SupervisorPresent ? 0 : 2;
                    if (!scanSilent)
                    {
                        MessageBox.Show(result.ToText() + "\r\n\r\nReport: " + ScanReportPath,
                            "DevSpace Legacy Cleanup - Scan", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    }
                    return;
                }

                if (!IsAdministrator())
                {
                    RelaunchElevated();
                    return;
                }

                CleanupResult cleanup = CleanupEnvironment();
                MessageBox.Show(cleanup.ToText(),
                    cleanup.Success ? "DevSpace Legacy Cleanup - Complete" : "DevSpace Legacy Cleanup - Incomplete",
                    MessageBoxButtons.OK,
                    cleanup.Success ? MessageBoxIcon.Information : MessageBoxIcon.Warning);
                Environment.ExitCode = cleanup.Success ? 0 : 3;
            }
            catch (System.ComponentModel.Win32Exception ex)
            {
                if (ex.NativeErrorCode == 1223)
                {
                    return; // UAC was cancelled.
                }
                ShowFailure(ex);
            }
            catch (Exception ex)
            {
                ShowFailure(ex);
            }
        }

        private static void ShowFailure(Exception ex)
        {
            MessageBox.Show(ex.Message, "DevSpace Legacy Cleanup - Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Environment.ExitCode = 1;
        }

        private static bool IsAdministrator()
        {
            WindowsIdentity identity = WindowsIdentity.GetCurrent();
            WindowsPrincipal principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }

        private static void RelaunchElevated()
        {
            string args = "--cleanup --install-dir " + Quote(InstallDir) +
                          " --target-sid " + Quote(_targetSid) +
                          " --target-user " + Quote(_targetUser);
            ProcessStartInfo psi = new ProcessStartInfo
            {
                FileName = Application.ExecutablePath,
                Arguments = args,
                UseShellExecute = true,
                Verb = "runas",
                WorkingDirectory = Path.GetDirectoryName(Application.ExecutablePath),
                WindowStyle = ProcessWindowStyle.Hidden
            };
            Process.Start(psi);
        }

        private static CleanupResult CleanupEnvironment()
        {
            ScanResult before = ScanEnvironment();
            if (!before.SupervisorPresent)
            {
                throw new InvalidOperationException(
                    "The current DevSpaceWatchdogSupervisor task was not found. Legacy cleanup is blocked so the machine is not left without monitoring.");
            }

            string backupDir = Path.Combine(InstallDir, "configuration-backups",
                "legacy-cleanup-" + DateTime.Now.ToString("yyyyMMdd-HHmmss"));
            Directory.CreateDirectory(backupDir);
            Directory.CreateDirectory(Path.Combine(backupDir, "tasks"));
            Directory.CreateDirectory(Path.Combine(backupDir, "startup"));

            List<string> actions = new List<string>();
            List<string> errors = new List<string>();

            foreach (LegacyTask task in before.LegacyTasks)
            {
                try
                {
                    File.WriteAllText(Path.Combine(backupDir, "tasks", SafeName(task.Name) + ".xml"),
                        task.Xml, Encoding.Unicode);
                    RunProcess("schtasks.exe", "/End /TN " + Quote("\\" + task.Name), false);
                    ProcessResult deleted = RunProcess("schtasks.exe", "/Delete /TN " + Quote("\\" + task.Name) + " /F", true);
                    if (deleted.ExitCode != 0)
                    {
                        throw new InvalidOperationException("schtasks delete failed: " + deleted.Error + deleted.Output);
                    }
                    actions.Add("Removed legacy task: " + task.Name);
                }
                catch (Exception ex)
                {
                    errors.Add("Task " + task.Name + ": " + ex.Message);
                }
            }

            foreach (string file in before.LegacyStartupFiles)
            {
                try
                {
                    string dest = Path.Combine(backupDir, "startup", SafeName(Path.GetFileName(file)) + "-" + Math.Abs(file.GetHashCode()));
                    File.Copy(file, dest, true);
                    File.Delete(file);
                    actions.Add("Removed legacy Startup item: " + file);
                }
                catch (Exception ex)
                {
                    errors.Add("Startup " + file + ": " + ex.Message);
                }
            }

            using (StreamWriter registryBackup = new StreamWriter(Path.Combine(backupDir, "registry-run.txt"), false, new UTF8Encoding(false)))
            {
                foreach (LegacyRunValue runValue in before.LegacyRunValues)
                {
                    try
                    {
                        registryBackup.WriteLine(runValue.Hive + "\\" + runValue.KeyPath + "\t" + runValue.Name + "\t" + runValue.Value);
                        if (string.Equals(runValue.Hive, "HKCU", StringComparison.OrdinalIgnoreCase))
                        {
                            using (RegistryKey targetUser = Registry.Users.OpenSubKey(_targetSid, true))
                            using (RegistryKey key = targetUser == null ? null : targetUser.OpenSubKey(runValue.KeyPath, true))
                            {
                                if (key == null) throw new InvalidOperationException("Target user's Run key no longer exists.");
                                key.DeleteValue(runValue.Name, false);
                            }
                        }
                        else
                        {
                            using (RegistryKey key = Registry.LocalMachine.OpenSubKey(runValue.KeyPath, true))
                            {
                                if (key == null) throw new InvalidOperationException("Machine Run key no longer exists.");
                                key.DeleteValue(runValue.Name, false);
                            }
                        }
                        actions.Add("Removed legacy Run value: " + runValue.Hive + "\\...\\" + runValue.Name);
                    }
                    catch (Exception ex)
                    {
                        errors.Add("Run value " + runValue.Name + ": " + ex.Message);
                    }
                }
            }

            foreach (LegacyProcess process in before.LegacyProcesses)
            {
                try
                {
                    Process.GetProcessById(process.ProcessId).Kill();
                    actions.Add("Stopped legacy watchdog process PID " + process.ProcessId);
                }
                catch (ArgumentException)
                {
                    // It already exited.
                }
                catch (Exception ex)
                {
                    errors.Add("Process " + process.ProcessId + ": " + ex.Message);
                }
            }

            ScanResult after = ScanEnvironment();
            bool success = after.SupervisorPresent && after.LegacyTasks.Count == 0 &&
                           after.LegacyStartupFiles.Count == 0 && after.LegacyRunValues.Count == 0 &&
                           after.LegacyProcesses.Count == 0 && errors.Count == 0;

            StringBuilder log = new StringBuilder();
            log.AppendLine("DevSpace Legacy Cleanup");
            log.AppendLine("Machine: " + Environment.MachineName);
            log.AppendLine("Target user: " + _targetUser + " (" + _targetSid + ")");
            log.AppendLine("Time: " + DateTimeOffset.Now.ToString("O"));
            log.AppendLine("InstallDir: " + InstallDir);
            log.AppendLine();
            log.AppendLine("Before:");
            log.AppendLine(before.ToText());
            log.AppendLine();
            log.AppendLine("Actions:");
            foreach (string action in actions) log.AppendLine("- " + action);
            foreach (string error in errors) log.AppendLine("ERROR: " + error);
            log.AppendLine();
            log.AppendLine("After:");
            log.AppendLine(after.ToText());
            File.WriteAllText(Path.Combine(backupDir, "legacy-cleanup.log"), log.ToString(), new UTF8Encoding(false));

            return new CleanupResult(success, backupDir, actions, errors, after);
        }

        private static ScanResult ScanEnvironment()
        {
            if (!Directory.Exists(InstallDir) || !File.Exists(Path.Combine(InstallDir, "devspace-watchdog.config.json")))
            {
                throw new InvalidOperationException("DevSpace installation was not found at " + InstallDir);
            }

            bool supervisorPresent = QueryAllTasks().IndexOf("DevSpaceWatchdogSupervisor-", StringComparison.OrdinalIgnoreCase) >= 0;
            List<LegacyTask> tasks = ScanLegacyTasks();
            List<string> startup = ScanLegacyStartup();
            List<LegacyRunValue> runValues = ScanLegacyRunValues();
            List<LegacyProcess> processes = ScanLegacyProcesses();
            return new ScanResult(supervisorPresent, tasks, startup, runValues, processes);
        }

        private static string QueryAllTasks()
        {
            ProcessResult result = RunProcess("schtasks.exe", "/Query /FO CSV /NH", true);
            if (result.ExitCode != 0)
            {
                throw new InvalidOperationException("Cannot query Scheduled Tasks: " + result.Error + result.Output);
            }
            return result.Output;
        }

        private static List<LegacyTask> ScanLegacyTasks()
        {
            List<LegacyTask> found = new List<LegacyTask>();
            string install = Normalize(InstallDir);
            foreach (string name in LegacyTaskNames)
            {
                ProcessResult result = RunProcess("schtasks.exe", "/Query /TN " + Quote("\\" + name) + " /XML", true);
                if (result.ExitCode != 0 || string.IsNullOrWhiteSpace(result.Output)) continue;
                string xml = result.Output;
                string normalized = Normalize(xml);
                bool belongs = normalized.Contains(install) &&
                               (normalized.Contains("devspace-watchdog") || normalized.Contains("devspace serve") || normalized.Contains("dist\\cli.js"));
                if (belongs)
                {
                    found.Add(new LegacyTask(name, xml));
                }
            }
            return found;
        }

        private static List<string> ScanLegacyStartup()
        {
            List<string> found = new List<string>();
            string[] dirs = new[]
            {
                Path.Combine(TargetProfileDir, "AppData", "Roaming", "Microsoft", "Windows", "Start Menu", "Programs", "Startup"),
                Environment.GetFolderPath(Environment.SpecialFolder.CommonStartup)
            };
            foreach (string dir in dirs.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                if (string.IsNullOrWhiteSpace(dir) || !Directory.Exists(dir)) continue;
                foreach (string file in Directory.GetFiles(dir))
                {
                    string name = Path.GetFileNameWithoutExtension(file);
                    if (LegacyStartupPrefixes.Any(prefix => name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)))
                    {
                        found.Add(file);
                    }
                }
            }
            return found;
        }

        private static List<LegacyRunValue> ScanLegacyRunValues()
        {
            List<LegacyRunValue> found = new List<LegacyRunValue>();
            const string runPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
            using (RegistryKey targetUser = Registry.Users.OpenSubKey(_targetSid, false))
            {
                if (targetUser != null) ScanRunHive(found, "HKCU", targetUser, runPath);
            }
            ScanRunHive(found, "HKLM", Registry.LocalMachine, runPath);
            return found;
        }

        private static void ScanRunHive(List<LegacyRunValue> found, string hiveName, RegistryKey hive, string path)
        {
            using (RegistryKey key = hive.OpenSubKey(path, false))
            {
                if (key == null) return;
                foreach (string name in key.GetValueNames())
                {
                    object raw = key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
                    string value = raw == null ? "" : Convert.ToString(raw);
                    string lower = Normalize(value);
                    bool legacy = lower.Contains("devspace-watchdog.ps1") ||
                                  lower.Contains("devspacengrokwatchdog") ||
                                  lower.Contains("devspace ngrok bootstrap");
                    bool current = lower.Contains("run-devspace-watchdog-tray-hidden.vbs") ||
                                   lower.Contains("devspace-watchdog-bootstrap.ps1");
                    if (legacy && !current)
                    {
                        found.Add(new LegacyRunValue(hiveName, path, name, value));
                    }
                }
            }
        }

        private static List<LegacyProcess> ScanLegacyProcesses()
        {
            List<LegacyProcess> found = new List<LegacyProcess>();
            string install = Normalize(InstallDir);
            using (ManagementObjectSearcher searcher = new ManagementObjectSearcher("SELECT ProcessId,Name,CommandLine FROM Win32_Process"))
            using (ManagementObjectCollection rows = searcher.Get())
            {
                foreach (ManagementObject row in rows)
                {
                    string cmd = Convert.ToString(row["CommandLine"]);
                    if (string.IsNullOrWhiteSpace(cmd)) continue;
                    string lower = Normalize(cmd);
                    if (!lower.Contains(install + "\\devspace-watchdog.ps1")) continue;
                    if (lower.Contains("devspace-watchdog-bootstrap.ps1") || lower.Contains("run-devspace-watchdog-tray-hidden.vbs")) continue;
                    int pid = Convert.ToInt32((uint)row["ProcessId"]);
                    if (pid == Process.GetCurrentProcess().Id) continue;
                    found.Add(new LegacyProcess(pid, Convert.ToString(row["Name"]), cmd));
                }
            }
            return found;
        }

        private static ProcessResult RunProcess(string fileName, string arguments, bool capture)
        {
            ProcessStartInfo psi = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                RedirectStandardOutput = capture,
                RedirectStandardError = capture
            };
            using (Process p = Process.Start(psi))
            {
                string output = capture ? p.StandardOutput.ReadToEnd() : "";
                string error = capture ? p.StandardError.ReadToEnd() : "";
                p.WaitForExit();
                return new ProcessResult(p.ExitCode, output, error);
            }
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static string GetOption(string[] args, string option)
        {
            for (int i = 0; i < args.Length - 1; i++)
            {
                if (string.Equals(args[i], option, StringComparison.OrdinalIgnoreCase)) return args[i + 1];
            }
            return "";
        }

        private static string Normalize(string value)
        {
            return (value ?? "").Replace('/', '\\').ToLowerInvariant();
        }

        private static string SafeName(string value)
        {
            foreach (char c in Path.GetInvalidFileNameChars()) value = value.Replace(c, '_');
            return value;
        }

        private sealed class ProcessResult
        {
            public readonly int ExitCode;
            public readonly string Output;
            public readonly string Error;
            public ProcessResult(int exitCode, string output, string error) { ExitCode = exitCode; Output = output ?? ""; Error = error ?? ""; }
        }

        private sealed class LegacyTask
        {
            public readonly string Name;
            public readonly string Xml;
            public LegacyTask(string name, string xml) { Name = name; Xml = xml; }
        }

        private sealed class LegacyRunValue
        {
            public readonly string Hive;
            public readonly string KeyPath;
            public readonly string Name;
            public readonly string Value;
            public LegacyRunValue(string hive, string keyPath, string name, string value) { Hive = hive; KeyPath = keyPath; Name = name; Value = value; }
        }

        private sealed class LegacyProcess
        {
            public readonly int ProcessId;
            public readonly string Name;
            public readonly string CommandLine;
            public LegacyProcess(int processId, string name, string commandLine) { ProcessId = processId; Name = name; CommandLine = commandLine; }
        }

        private sealed class ScanResult
        {
            public readonly bool SupervisorPresent;
            public readonly List<LegacyTask> LegacyTasks;
            public readonly List<string> LegacyStartupFiles;
            public readonly List<LegacyRunValue> LegacyRunValues;
            public readonly List<LegacyProcess> LegacyProcesses;

            public ScanResult(bool supervisorPresent, List<LegacyTask> tasks, List<string> startup,
                List<LegacyRunValue> runValues, List<LegacyProcess> processes)
            {
                SupervisorPresent = supervisorPresent;
                LegacyTasks = tasks;
                LegacyStartupFiles = startup;
                LegacyRunValues = runValues;
                LegacyProcesses = processes;
            }

            public string ToText()
            {
                StringBuilder sb = new StringBuilder();
                sb.AppendLine("Machine: " + Environment.MachineName);
                sb.AppendLine("InstallDir: " + InstallDir);
                sb.AppendLine("Current Supervisor present: " + SupervisorPresent);
                sb.AppendLine("Legacy tasks: " + LegacyTasks.Count + (LegacyTasks.Count == 0 ? "" : " [" + string.Join(", ", LegacyTasks.Select(t => t.Name).ToArray()) + "]"));
                sb.AppendLine("Legacy Startup items: " + LegacyStartupFiles.Count);
                sb.AppendLine("Legacy Run values: " + LegacyRunValues.Count);
                sb.AppendLine("Legacy watchdog processes: " + LegacyProcesses.Count);
                return sb.ToString().TrimEnd();
            }
        }

        private sealed class CleanupResult
        {
            public readonly bool Success;
            public readonly string BackupDir;
            public readonly List<string> Actions;
            public readonly List<string> Errors;
            public readonly ScanResult After;

            public CleanupResult(bool success, string backupDir, List<string> actions, List<string> errors, ScanResult after)
            {
                Success = success;
                BackupDir = backupDir;
                Actions = actions;
                Errors = errors;
                After = after;
            }

            public string ToText()
            {
                StringBuilder sb = new StringBuilder();
                sb.AppendLine(Success ? "PASS: legacy DevSpace execution surfaces were removed." : "Cleanup completed with remaining items.");
                sb.AppendLine();
                sb.AppendLine(After.ToText());
                sb.AppendLine();
                sb.AppendLine("Backup / log: " + BackupDir);
                if (Errors.Count > 0)
                {
                    sb.AppendLine();
                    sb.AppendLine("Errors:");
                    foreach (string error in Errors) sb.AppendLine("- " + error);
                }
                return sb.ToString().TrimEnd();
            }
        }
    }
}
