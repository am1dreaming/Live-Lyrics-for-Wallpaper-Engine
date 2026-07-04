' MinenkoY
Dim shell, fso, scriptDir
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
shell.CurrentDirectory = scriptDir
shell.Run "node """ & scriptDir & "\bridge-server.js""", 0, False
