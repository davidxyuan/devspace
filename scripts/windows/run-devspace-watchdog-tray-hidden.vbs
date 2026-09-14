Option Explicit

Dim shell
Dim fileSystem
Dim scriptDirectory
Dim bootstrapPath
Dim configPath
Dim powershellPath
Dim command
Dim exitCode
Dim mode
Dim scheduledSupervisor

Function QuoteArg(value)
  QuoteArg = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
bootstrapPath = scriptDirectory & "\devspace-watchdog-bootstrap.ps1"
configPath = scriptDirectory & "\devspace-watchdog.config.json"
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"

If Not fileSystem.FileExists(bootstrapPath) Then WScript.Quit 2
If Not fileSystem.FileExists(configPath) Then WScript.Quit 3
If Not fileSystem.FileExists(powershellPath) Then WScript.Quit 4

mode = "Watch"
scheduledSupervisor = ""
If WScript.Arguments.Count > 1 Then WScript.Quit 5
If WScript.Arguments.Count = 1 Then
  Select Case LCase(WScript.Arguments(0))
    Case "-stop"
      mode = "Stop"
    Case "-supervisor"
      scheduledSupervisor = " -ScheduledSupervisorLauncher"
    Case Else
      WScript.Quit 5
  End Select
End If

command = QuoteArg(powershellPath) & _
  " -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File " & _
  QuoteArg(bootstrapPath) & " -Mode " & mode & scheduledSupervisor & " -ConfigPath " & QuoteArg(configPath)

exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
