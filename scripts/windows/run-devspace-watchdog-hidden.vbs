Option Explicit

Dim shell
Dim scriptDirectory
Dim watchdogPath
Dim configPath
Dim mode
Dim command

Set shell = CreateObject("WScript.Shell")
scriptDirectory = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
watchdogPath = scriptDirectory & "\devspace-watchdog.ps1"
configPath = scriptDirectory & "\devspace-watchdog.config.json"
mode = "-Once"

If WScript.Arguments.Count > 0 Then
  mode = WScript.Arguments(0)
End If

command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & watchdogPath & """ " & mode & " -ConfigPath """ & configPath & """"
shell.Run command, 0, False
WScript.Quit 0
