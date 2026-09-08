Option Explicit

Dim shell
Dim fileSystem
Dim scriptDirectory
Dim trayPath
Dim configPath
Dim powershellPath
Dim command
Dim execProcess
Dim errorPath
Dim errorText
Dim writer

Function QuoteArg(value)
  QuoteArg = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function

Sub WriteLaunchError(message)
  On Error Resume Next
  Set writer = fileSystem.OpenTextFile(errorPath, 2, True, -1)
  writer.WriteLine Now & " " & message
  writer.Close
  Set writer = Nothing
  On Error GoTo 0
End Sub

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
trayPath = scriptDirectory & "\devspace-watchdog-tray-ui.ps1"
If WScript.Arguments.Count > 0 Then
  configPath = WScript.Arguments(0)
Else
  configPath = scriptDirectory & "\devspace-watchdog.config.json"
End If
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
errorPath = fileSystem.GetParentFolderName(configPath) & "\watchdog-tray-ui-launch.err.log"

If Not fileSystem.FileExists(trayPath) Then WriteLaunchError "Tray script is missing: " & trayPath : WScript.Quit 2
If Not fileSystem.FileExists(configPath) Then WriteLaunchError "Config is missing: " & configPath : WScript.Quit 3
If Not fileSystem.FileExists(powershellPath) Then WriteLaunchError "PowerShell is missing: " & powershellPath : WScript.Quit 4

command = QuoteArg(powershellPath) & _
  " -NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
  QuoteArg(trayPath) & " -Mode Run -ConfigPath " & QuoteArg(configPath)

On Error Resume Next
Set execProcess = shell.Exec(command)
If Err.Number <> 0 Then
  WriteLaunchError "PowerShell launch failed: " & Err.Description
  WScript.Quit 5
End If
On Error GoTo 0

Do While execProcess.Status = 0
  WScript.Sleep 250
Loop

errorText = execProcess.StdErr.ReadAll
If execProcess.ExitCode <> 0 Then
  If Len(errorText) = 0 Then errorText = execProcess.StdOut.ReadAll
  WriteLaunchError "PowerShell exited " & execProcess.ExitCode & ": " & errorText
End If
WScript.Quit execProcess.ExitCode
