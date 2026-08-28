Option Explicit

Dim shell
Dim scriptDirectory
Dim watchdogPath
Dim configPath
Dim arguments
Dim argument
Dim index
Dim command

Set shell = CreateObject("WScript.Shell")
scriptDirectory = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
watchdogPath = scriptDirectory & "\devspace-watchdog.ps1"
configPath = scriptDirectory & "\devspace-watchdog.config.json"
arguments = "-Once"
If WScript.Arguments.Count > 0 Then
  arguments = ""
  For index = 0 To WScript.Arguments.Count - 1
    argument = LCase(WScript.Arguments(index))
    If argument <> "-once" And argument <> "-ngrokonly" Then WScript.Quit 2
    If Len(arguments) > 0 Then arguments = arguments & " "
    arguments = arguments & argument
  Next
End If

command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & watchdogPath & """ " & arguments & " -ConfigPath """ & configPath & """"
shell.Run command, 0, False
WScript.Quit 0
