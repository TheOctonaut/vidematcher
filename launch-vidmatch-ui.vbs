Option Explicit

Dim fso, shell, scriptDir, uiScript, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
uiScript = fso.BuildPath(scriptDir, "vidmatch-ui.ps1")

If Not fso.FileExists(uiScript) Then
    MsgBox "Could not find UI script: " & uiScript, vbCritical, "vidmatch"
    WScript.Quit 1
End If

' Use PowerShell from PATH and hide the console window (windowstyle=0).
cmd = "powershell -NoProfile -ExecutionPolicy Bypass -STA -File """ & uiScript & """"
shell.Run cmd, 0, False
WScript.Quit 0
