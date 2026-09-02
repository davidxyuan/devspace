Option Explicit

Dim shell
Dim fileSystem
Dim scriptDirectory
Dim launcherPath
Dim command

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
launcherPath = scriptDirectory & "\devspace-watchdog-tray-launcher.exe"
command = """" & launcherPath & """"

If WScript.Arguments.Count > 0 Then
  If LCase(WScript.Arguments(0)) = "-stop" Then command = command & " -Stop"
End If

shell.Run command, 0, False
WScript.Quit 0
