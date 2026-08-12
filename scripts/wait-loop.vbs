' Starts wait-loop.ps1 with no window.
'
' PowerShell launched straight from a hook flashes a console window, and this
' loop lives for minutes, so it would sit there blinking in the middle of your
' work. wscript can start it fully hidden (0 = no window, False = do not wait).
Option Explicit
Dim fso, sh, root
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
root = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -File """ & root & "\wait-loop.ps1""", 0, False
