' Stop the speech immediately. Bound to a global keyboard shortcut (Ctrl+Alt+H)
' and can also be triggered by a Voice Access voice shortcut.
'
' Why VBScript and not PowerShell: PowerShell spends about half a second
' starting up, and that is half a second of the voice carrying on. Everything
' needed to produce silence is plain file I/O, and it can be done here
' immediately.
'
' The daemon must NEVER be killed to produce silence. It holds the voice model
' in memory, and a restart costs about 2 seconds of loading, which then hits the
' first utterance afterwards. It falls silent on the flag and clears it itself
' in its main loop, so the next message is spoken as normal.
'
' This file is run from TWO places, deliberately. It lives in the repository
' under scripts/, but the first-run setup copies it to ~/.claude/read-aloud/,
' and THAT copy is the one the keyboard shortcut points at. The reason is that
' the program directory is version-bound when installed as a plugin: a shortcut
' into it would break on every single update. The fixed directory never moves.
Option Explicit
Dim fso, data, qdir, rdir, pdir, f, ts, pointer

Set fso = CreateObject("Scripting.FileSystemObject")
On Error Resume Next

' --- find the data root ----------------------------------------------------
' The keyboard shortcut starts us outside Claude Code, so there are no
' environment variables to lean on. The first-run setup therefore leaves a note
' with the path next to this file.
data = ""
pointer = fso.GetParentFolderName(WScript.ScriptFullName) & "\data.path"
If fso.FileExists(pointer) Then
    Set ts = fso.OpenTextFile(pointer, 1)
    data = Trim(ts.ReadAll)
    ts.Close
End If
If data = "" Or Not fso.FolderExists(data) Then
    ' Run straight from the repository, before anything has been set up.
    data = CreateObject("WScript.Shell").ExpandEnvironmentStrings("%USERPROFILE%") & "\.claude\read-aloud\data"
End If
If Not fso.FolderExists(data) Then WScript.Quit 0

' --- 1. ask the daemon to stop mid-sentence --------------------------------
Set ts = fso.CreateTextFile(data & "\stop.flag", True)
ts.Close

' --- 2. empty the queue ----------------------------------------------------
' Otherwise the rest of the turn's narration is read out afterwards, and it
' feels less like silence than like a pause.
qdir = data & "\queue"
If fso.FolderExists(qdir) Then
    For Each f In fso.GetFolder(qdir).Files
        If LCase(fso.GetExtensionName(f.Name)) = "txt" Then f.Delete True
    Next
End If

' --- 3. halt the two loops --------------------------------------------------
' The waiting tone and the working message own nothing and stop by themselves
' once their marker disappears. If you ask for silence, that covers them too.
If fso.FileExists(data & "\waiting.flag") Then fso.DeleteFile data & "\waiting.flag", True
If fso.FileExists(data & "\working.flag") Then fso.DeleteFile data & "\working.flag", True

' --- 4. forget what was running ---------------------------------------------
' Without this the next turn could report a tool that is long gone.
rdir = data & "\running"
If fso.FolderExists(rdir) Then
    For Each f In fso.GetFolder(rdir).Files
        f.Delete True
    Next
End If

' --- 5. forget what was waiting on an answer --------------------------------
' One file per open approval. Left behind, they would keep the next waiting
' tone alive after it should have stopped.
pdir = data & "\pending"
If fso.FolderExists(pdir) Then
    For Each f In fso.GetFolder(pdir).Files
        f.Delete True
    Next
End If
