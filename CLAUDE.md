# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Claude Code plugin that speaks a session aloud on Windows, so it can be used
without looking at the screen. It is an accessibility tool first. The design
rule that everything else follows from is: **silence means "you are up", speech
means "I am working"**. When changing behaviour, check the change against that
rule before checking it against anything else.

Windows only. PowerShell 5.1, VBScript, and a Python daemon using `winsound` and
`msvcrt`. There is no cross-platform path and adding one would be a rewrite.

## Verifying changes

There is no build and no test framework. Verification is these four checks, and
they should all be run after touching anything under `scripts/`.

Parse every PowerShell file without executing it:

```powershell
Get-ChildItem scripts\*.ps1 | ForEach-Object {
  $t=$null; $e=$null
  [System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$t,[ref]$e) | Out-Null
  if ($e.Count) { $_.Name; $e | ForEach-Object { "  " + $_.Message } }
}
```

Compile the Python:

```powershell
python -m py_compile scripts\piper-daemon.py scripts\make-cues.py
```

Confirm every `.ps1` and `.vbs` is pure ASCII (see the invariant below):

```powershell
Get-ChildItem scripts\*.ps1,scripts\*.vbs | ForEach-Object {
  $n = ([System.IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 }).Count
  if ($n) { "$($_.Name): $n non-ASCII bytes" }
}
```

Validate the manifests:

```powershell
claude plugin validate .
```

### Running the hooks without a session

Set `CLAUDE_TTS_DATA` to a scratch directory and pipe a JSON payload into a hook
on stdin. With no `.onnx` in `<data>/voices`, nothing is spoken and the failure
is written to `<data>/tts.log`, which makes this safe to run while a real
session is active:

```powershell
$env:CLAUDE_TTS_DATA = "C:\temp\ttstest"
'{"tool_name":"Bash","tool_use_id":"c1","tool_input":{"description":"List files"}}' |
  powershell -NoProfile -File scripts\narrate-preamble.ps1
```

To test queue ordering in-process, dot-source `tts-common.ps1`, then shadow the
daemon launcher with `function Start-PiperDaemon {}` before calling
`Submit-Speech`. That exercises the real prefix and release logic without
producing audio.

To test the plugin as a whole, use `claude --plugin-dir .` from a separate
session. It does not disturb an existing install.

## Architecture

Read `docs/architecture.md` before changing behaviour. It records which failure
caused each decision. The summary below is orientation only.

**Six hooks, one job each.** `UserPromptSubmit` prepares state and injects the
language directive; `PreToolUse` narrates and announces; `PermissionRequest`
announces approvals fast; `Notification` is a fallback for the same;
`PostToolUse` clears markers and stops the waiting tone; `Stop` speaks the final
answer. Registered in `hooks/hooks.json`.

**Two roots.** `${CLAUDE_PLUGIN_ROOT}` is the program and is read-only and
version-bound. `${CLAUDE_PLUGIN_DATA}` is everything mutable and survives
updates. `tts-common.ps1` resolves them into `$script:TtsScripts`,
`$script:TtsHome` and `$script:TtsData`; `piper-daemon.py` receives the data root
as `argv[1]`. A third fixed directory, `%USERPROFILE%\.claude\read-aloud`, holds
`hush.vbs` and `data.path`, because a keyboard shortcut needs a path that does
not change on update.

**A queue, not direct playback.** Every utterance is a file in `<data>/queue`
named `<prefix>-<ticks>-<guid>.txt`, drained in filename order by a resident
daemon that keeps the voice model in memory. Prefix `0` is urgent, `1` normal,
`2` held.

**Two background loops** (`wait-loop.ps1`, `work-loop.ps1`), each governed by a
marker file whose existence is the lock and whose contents are an ownership
token. They own no state and stop when their marker changes or disappears.

## Invariants

These are the things that look like details and are not. Each one exists because
its absence produced a specific, hard-to-diagnose fault.

- **Never kill the daemon to produce silence.** Write `stop.flag`. Killing it
  drops the voice model from memory and the next utterance starts five or six
  seconds late.
- **Ordering between the permission question and the tool announcement comes
  from the filename sort, never from a timer.** `PreToolUse` fires before Claude
  Code decides to ask, so the announcement is queued as `2-` and renamed to `1-`
  once the question is queued as `0-`. An earlier timer-based version lost the
  race. `holdMs` is only a ceiling for the case where no question ever comes.
- **Keep every `.ps1` and `.vbs` pure ASCII.** PowerShell 5.1 reads a BOM-less
  UTF-8 file as ANSI. Non-ASCII characters needed in regular expressions must be
  written as `\u` escapes; `ConvertTo-Speakable` depends on `\u2014` and
  `\u2013` surviving, because the daemon splits on them to insert pauses.
- **Every hook exits 0 and writes nothing to stdout**, except `tts-prompt.ps1`,
  which must write exactly the hook JSON. `PermissionRequest` must make no
  decision. The plugin must never be able to block or deny a tool call.
- **Never interrupt an utterance in progress.** A version that let a question
  break in between two sentences worked, but cutting a sentence mid-thought was
  heard as a fault.
- **The daemon is a singleton via an `msvcrt` file lock**, not the pid file,
  which is written too late to prevent a startup race. Queue items are claimed
  by renaming before the text is read.
- **Do not add a `language` key to `settings.json`.** The language is decided
  solely by the directive `tts-prompt.ps1` injects on every prompt, which is why
  changes take effect without a restart. Two sources of truth would disagree.
- **Never read command text aloud.** Paths and punctuation are miserable to
  listen to. Use the human-written description instead. The single exception is
  `AskUserQuestion`, where the question and its options are the message.
- **Cue tones stay above roughly 500 Hz and 100 ms**, and play with `PlaySync`.
  Below that they are inaudible on laptop speakers; asynchronous playback is cut
  off when the hook process exits.

## Deliberately absent

Do not reintroduce these without a reason that survives the original objection.

- A fallback speech engine. The Windows voice could not queue, so it clipped
  narration, and an engine that only runs after something has gone wrong is
  never tested. A missing Piper fails loudly in the log.
- Reading Claude's thinking aloud. The transcript stores every thinking block
  with an empty `thinking` field, so it cannot work. `work-loop.ps1` reports the
  state instead.
- Extra cue tones at the question and at completion. Both duplicated speech that
  followed a moment later and lay on top of it.

## Project memory

If a file is absent, it simply has not been written yet.

- `STATUS.md` is the present-tense picture. Read it first after a `/clear`.
- `sessionslog/<date>.md` is an archive of what happened. It is local and does not
  come with a clone. Read it only when asked; it is history, not context.
- `.claude/decision-log.md` records decisions the user has settled. **Read it
  before changing anything that looks wrong or redundant.** An entry marked
  `besluttet` is decided: do not reverse it, and do not work around it, without
  asking first. If a decision looks wrong, say so and let the user rule on it.

Maintained by `/update-session-log`, not by hand.

## Conventions

English throughout: comments, docstrings, documentation and commit messages.
Comments explain **why**, and where a decision came from a failure, the failure
is named. Avoid em dashes in prose written for this repository.
