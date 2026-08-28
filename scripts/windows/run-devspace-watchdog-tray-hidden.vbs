Option Explicit

Dim shell
Dim fileSystem
Dim scriptDirectory
Dim trayPath
Dim configPath
Dim mode
Dim command

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
trayPath = scriptDirectory & "\devspace-watchdog-tray.ps1"
configPath = scriptDirectory & "\devspace-watchdog.config.json"
mode = "Run"

If WScript.Arguments.Count > 0 Then
  If LCase(WScript.Arguments(0)) = "-stop" Then mode = "Stop"
End If

command = """C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File """ & trayPath & """ -Mode " & mode & " -ConfigPath """ & configPath & """"
shell.Run command, 0, False
WScript.Quit 0
