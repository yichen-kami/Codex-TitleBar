Option Explicit

Dim shell, fileSystem, scriptDirectory, powerShell, watcher, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
powerShell = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
watcher = fileSystem.BuildPath(scriptDirectory, "CodexQuotaWatcher.ps1")
command = Chr(34) & powerShell & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & watcher & Chr(34)
shell.Run command, 0, True
