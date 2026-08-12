' Starts work-loop.ps1 with no window.
'
' Same reason as wait-loop.vbs: PowerShell launched straight from a hook flashes
' a console window, and this loop lives for the whole turn.
Option Explicit
Dim fso, sh, root
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
root = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -File """ & root & "\work-loop.ps1""", 0, False
