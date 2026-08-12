# Architecture

How the pieces fit together, and why they are the way they are. Most of the
decisions here look arbitrary until you know which failure caused them, so the
failures are recorded alongside.

## The six hooks

| Event | Script | Job |
| --- | --- | --- |
| `UserPromptSubmit` | `tts-prompt.ps1` | prepare the data directory, empty the queue, play the submitted tone, inject the language directive, start the working loop |
| `PreToolUse` | `narrate-preamble.ps1` | speak the narration, announce the tool, read out questions with options |
| `PermissionRequest` | `permission-request.ps1` | say immediately that you are being waited on, start the waiting tone |
| `Notification` | `notify-permission.ps1` | fallback for notifications that are not tool approvals |
| `PostToolUse` | `notify-granted.ps1` | stop the waiting tone once an approved tool has run, clear its marker |
| `Stop` | `speak-response.ps1` | stop the working loop and speak the final answer |

Every hook exits 0 and writes nothing to standard output. `PermissionRequest` in
particular makes no decision: writing anything that is not valid JSON produces a
non-blocking error, and denial would require a decision object, which is
deliberately not used. The plugin should never be able to block a tool call.

## Two roots

The program and its data live apart.

`${CLAUDE_PLUGIN_ROOT}` holds the scripts and the cue tones and is only read
from. It is version-bound: the path changes on every plugin update, and the
documentation is explicit that state must not be written there.

`${CLAUDE_PLUGIN_DATA}` holds everything that changes: the config, the queue,
the synthesis cache, the voice models, the log and the flag files. It survives
updates, which is what keeps a few hundred megabytes of voice model from being
re-downloaded and a customised config from being overwritten.

A manual install has no such variables, so the scripts fall back to
`%USERPROFILE%\.claude\read-aloud\data`. That is deliberately outside any git
checkout, so cloning the repository does not fill it with queue files and logs.
`CLAUDE_TTS_DATA` overrides both, for testing.

There is a third, fixed location: `%USERPROFILE%\.claude\read-aloud`. It holds
`hush.vbs` and `data.path`. The keyboard shortcut has to point somewhere that
does not move, and a shortcut into the plugin directory would break on every
update. `data.path` is rewritten on every prompt and tells the hush script where
the data root currently is.

## The queue

All speech becomes a numbered text file in `queue/`, and `piper-daemon.py`
drains it in filename order. The daemon holds the voice model in memory, so only
the first utterance after startup pays the roughly two seconds of loading, and
it shuts itself down after `idleTimeout` seconds of quiet.

The queue exists so that one utterance cannot cut off the previous one. Prefixes
give three classes:

- `0-` urgent. Approval requests. Sorts to the front without interrupting
  whatever is playing.
- `1-` normal.
- `2-` held. A tool announcement that must not be spoken yet.

### Why announcements are held

`PreToolUse` fires before Claude Code decides whether a call needs approval. So
the description of the command is queued before the question exists, and without
intervention it would always be spoken first, which is backwards: you would hear
what the command does and only then be asked whether it may run.

The fix is ordering, not timing. The announcement is queued as `2-` and the
daemon leaves it alone. Then one of three things releases it:

1. `PermissionRequest` queues the question as `0-` and renames the announcement
   to `1-`, so it sorts behind.
2. `PostToolUse` renames it, because the tool ran and no question ever came.
3. `holdMs` expires, which only happens for a long-running tool that was never
   asked about.

The first version of this used `holdMs` alone and tried to outlast Claude Code's
own `Notification` delay. That is a race, and races get lost. Do not go back to
it.

A held item carries the `tool_use_id` of the call it belongs to, appended to the
file name after the timestamp so it cannot disturb the sort. `PostToolUse`
releases only its own. Releasing all of them held only while calls were
sequential: with two in flight, the first to finish let the second one's
description out before Claude Code had decided whether to ask about it, and the
question then arrived after its own answer. An announcement that carries no id
simply waits for `holdMs`, which is the safe direction to fail in.

The two approval hooks still release everything, and should. Their question is
already queued as `0-`, so whatever is released now sorts behind it no matter
whose it is.

### Who is waiting on you

`pending/` holds one file per open approval, keyed by `tool_use_id` where the
event carries one and by tool name otherwise. `PostToolUse` stops the waiting
tone only when it recognises one of its own keys and nothing else is left open.

Keys carry their kind in front: `p-` for an approval, `q-` for a question asked
through `AskUserQuestion`. A new approval question retires every `p-` entry
first, because Claude Code asks about one call at a time, so anything still
marked has been answered or denied by then. The denial is the case that needs
it: a denied call never reaches `PostToolUse`, and its entry would otherwise
convince the next `Stop-Waiting` that something was still open, leaving the tone
sounding while Claude worked. Questions are left alone, since one can still be
open when an approval arrives.

This used to be a single `pending.flag`, and any tool finishing cleared it. With
parallel calls that stopped the tone while the question was still on screen,
which removes the one signal saying you are being waited on. The `Notification`
fallback carries neither an id nor a tool name, so it writes a shared key that
`PostToolUse` only falls back to when it recognises nothing of its own; on that
path the old behaviour survives, because nothing better is available.

Entries are swept when they grow older than `waitMaxMs`. A denied call never
reaches `PostToolUse`, and without the sweep its entry would keep the tone alive
through every approval after it.

### Why the daemon is never killed

Killing it produces silence, but it also drops the model from memory, and the
next utterance then starts five or six seconds late. The daemon falls silent on
`stop.flag` instead, and playback is asynchronous specifically so it can be cut
off mid-sentence.

A single daemon is guaranteed by an `msvcrt` file lock rather than the pid file.
The pid file is only written after Python has started, and hooks fire in
clusters, so two of them could each see no pid file and start a daemon. With two
different `pythonw.exe` on `PATH` this once produced four daemons reading the
same queue and speaking the same message on top of each other. Queue items are
also claimed by renaming before the text is read, so even a race cannot produce
a double utterance.

## The two loops

Both loops own nothing. Each is controlled by a marker file whose **existence**
is the lock and whose **contents** are an ownership token. A loop reads the
token at startup and exits the moment it changes or disappears, so any hook can
stop a loop by deleting one file, without knowing anything about the process.
The token matters: without it, two loops could run at once and double the tones,
which happened when one hook deleted and recreated a marker mid-flight.

Both are launched through a `.vbs` wrapper, because PowerShell started directly
from a hook flashes a console window, and these loops live for minutes.

### `wait-loop.ps1`

The gentle repeating tone. Phase one waits for the question to finish being
read, so the tone never lands on top of it. Phase two sounds in the silence
until speech resumes.

It watches `speaking.flag`, which the daemon maintains while it talks, and also
checks whether anything is queued. Both are needed, or the tone slips into the
gap between two queue items and sounds like a fault.

### `work-loop.ps1`

The spoken status message. It escalates from "Thinking" to "Still working on
it", or reports the running tool and its elapsed time. It only speaks in
silence: speech, a queued item or a pending approval all reset the clock.
Approval takes precedence, because there the state is "you are up", not "I am
thinking".

Two details worth keeping:

**One marker per call.** `running/` holds one file per in-flight `tool_use_id`.
A single marker would be deleted by whichever call finished first, dropping the
narration back to "still thinking" while work continued. The loop reports the
**oldest** marker, because that is the one dragging.

**Interruption detection.** There is no hook for "the user interrupted". The
turn simply ends, and the loop used to go on announcing a dead command until you
typed something. It now tails the last 8 kB of the transcript looking for a
`user` entry containing `[Request interrupted by user]`. Both conditions are
required: Claude sometimes writes that sentence in an answer, and an `assistant`
entry is not an interruption.

## Caching

Messages under 300 characters are stored as finished WAV files in `cache/`, keyed
by a hash of the text, model, rate and volume. Approval messages are worded
identically every time on purpose, so after a handful of approvals the cache is
warm and the question plays with no synthesis delay at all.

Cache files are written to a temporary name and moved into place with
`os.replace`, which is atomic. Before that, two daemons could write the same
file simultaneously and leave half a WAV that broke playback every time that
message recurred.

The cache is pruned to `cacheMaxFiles` and `cacheMaxMb`, oldest use first, at
startup and every ten minutes while the queue is idle. The premise of caching is
that short messages repeat word for word, and tool announcements break it: they
carry the command's own description, so each one is unique, cached once and
never read again. Twelve hours of use left 337 files and 40 MB that nothing
would ever look at. A cache hit touches the file, so the mtime is a record of
last use and the messages that keep coming back are the last to go. Windows
atime is not reliable enough to use instead.

`tts.log` is rotated the same way, at 2 MB, keeping one generation. Every hook,
both loops and the daemon append to it, and nothing used to trim it.

## Text handling

`ConvertTo-Speakable` strips markdown down to prose: headings, bullets, code
fences, tables, link targets, emphasis and anything outside readable text. Em
dash and en dash survive on purpose, because the daemon splits on them to insert
a pause.

The daemon splits text into one sentence per chunk so it can place a pause
between them, then splits again at dashes. Fragments shorter than 25 characters
are joined to the previous chunk with a comma instead, or the pause swallows the
gap entirely and "Short - ok" is read as "Short ok".

Stale items, older than `staleMs`, are discarded rather than spoken. If the
daemon has been down there is otherwise a backlog, and hearing about something
that happened two minutes ago is noise on top of the present.

The rule is suspended for speech queued at or after the moment `pending/` says
the user was asked something. It is a rule about relevance rather than about
age, and an unanswered question does not stop being relevant by waiting in the
queue. The first install test produced the failure it now prevents: an urgent
item queued behind a long narration was dropped after 51 seconds, and because
the waiting tone runs off its own marker it carried on sounding, so the tone
said somebody was waiting and nothing said what for. Two rules that are each
correct alone collided, since never interrupting an utterance in progress is
exactly what makes an urgent item wait long enough to be aged out.

Keying on `pending/` rather than on the `0-` prefix is deliberate, and the
prefix was tried first. The question text from `AskUserQuestion` is queued as
`1-` on purpose, because the narration leading into it has to be spoken first,
so a prefix test would have protected the generic permission line and dropped
the question itself, which is the half that cannot be inferred from the tone.

Protecting the whole queue rather than only what followed the question was also
tried, and it is worse than the bug it fixes. A backlog queued *before* the
question sorts behind it and was preserved too, so the answer was followed by
minutes of narration about work already finished. Worse, the waiting tone never
sounded at all: `wait-loop.ps1` counts a non-empty queue as speech and waits for
it to drain, so the listener got unbroken speech, which by the central rule
means "I am working", at the exact moment they were the one holding things up.
The scoping is what keeps that from happening, and it is why
`narrate-preamble.ps1` now writes the pending entry *before* the question it
protects, matching what `permission-request.ps1` already did. Queued first, the
question would fall outside its own protection.

The anchor is the oldest open entry rather than the newest, because two can be
open at once by design: an approval request retires a previous approval but
leaves an `AskUserQuestion` alone, since a question can still be on screen when
a parallel call asks for permission. Anchored on the newest, a later approval
moved the line forward and retracted the earlier question's protection, so the
question was discarded with its dialog still up. Anchored on the oldest, the
risk is instead an uncleared entry holding the line open behind it, which is the
lesser fault and is bounded by `pendingHoldMs`. Speech queued shortly *before*
its marker is covered too, by a fifteen second allowance: on the `Notification`
fallback path the marker arrives 6.8 to 9.6 seconds after the announcement was
queued, and without the allowance the listener would be told permission is
needed but not what the command does.

Protection also has a ceiling on how far *after* the marker it reaches, two
minutes. Without one, a single entry that never gets cleared suspends ageing for
the whole remainder of the turn, which is the failure protecting the entire
queue produced in the first place. A denied call is the ordinary way to strand
one: it never reaches `PostToolUse`, and `Clear-PendingKind` only retires it
when another approval arrives, so on a long turn where Claude works around the
denial nothing would age out at all. The `Stop` hook and the next prompt do
clear it, but only at the end of the turn, which is too late to help. Two
minutes is measured against what legitimately arrives after a question, which is
very little: while something waits on an answer there is not much new to say,
and parallel calls narrate within seconds.

Because the protection is scoped, the window can be generous, and it is:
`pendingHoldMs`, thirty minutes by default. The only thing a long window can
preserve is the question and whatever followed it, so being wrong is cheap,
while being too eager means dropping a question that is still on screen.
Somebody who steps away for ten minutes is who this plugin is for, and they
should still be told what is being asked when they come back. A stranded entry
cannot hold it open indefinitely: the `Stop` hook clears `pending/` at the end
of every turn, and a new prompt empties the queue outright.

The `Stop` hook clears the pending entries and the waiting marker for the same
reason it clears the running markers: a call that never reaches `PostToolUse`
strands its state, and a stranded pending entry keeps the tone sounding. This
does not cover dismissing a question with Escape, because Claude Code appears
not to run `Stop` when a turn ends as a user interrupt. That is untested rather
than settled.

Duplicate speech is prevented by a per-session watermark in `state/`, recording
the `uuid` of every entry already spoken. One answer can trigger several tool
calls, so `PreToolUse` fires repeatedly over the same content.

Both hooks that read the transcript read only the last `transcriptTailKb`
kilobytes of it. Each walks backwards from the end and stops at the first user
entry, so the rest of the file was never looked at, and a hook has ten seconds
before Claude Code kills it. On a long session, loading a multi-megabyte
transcript on every single tool call was approaching that ceiling, and narration
that dies that way dies silently. If the window does not reach back to the
prompt, the extra entries are caught by the watermark and stay quiet.

## One data root, one session

`transcript.path`, `working.flag` and `waiting.flag` are single files in one data
root. Two Claude Code sessions sharing a data root therefore share them, and the
last prompt wins: the working loop can end up watching the other session's
transcript, and either session can stop the other's waiting tone. Nothing
crashes and no tool call is affected, but the narration belongs to whichever
session spoke last.

It reaches further than those three files. `running/` and `pending/` are keyed
by `tool_use_id`, which is unique enough not to collide, but they are swept
wholesale: `Stop-AllSpeech` runs `Clear-AllRunningMarkers` and
`Clear-AllPending`, so a prompt in one session discards the other session's
in-flight markers and open approvals. Only `state/`, the spoken watermark, is
keyed by `session_id` and genuinely per session.

This is a known limitation, not a design goal. The way out, if it ever matters,
is to key the three flag files by `session_id` and to scope the two sweeps to
the session that asked for them. Until then, run one session at a time, or give
the second one its own `CLAUDE_TTS_DATA`.

`transcript.path` is written by `UserPromptSubmit` as well as `PreToolUse`. It
used to be written only by the latter, so a turn with no tool calls left the
previous turn's transcript in place, and a fresh session had no pointer at all
until its first tool ran.

## The tones

Two, both pre-rendered in `cues/` so they play without synthesis.

The **shape** carries the meaning, not the pitch. The first attempt at the
submitted cue was a single low tone at 392 Hz for 90 ms, chosen for contrast. It
played correctly and could not be heard: laptop speakers reproduce poorly below
about 500 Hz, and 90 ms is too short for the ear to register a low tone. Keep
any tone above roughly 500 Hz and 100 ms.

Playback uses `PlaySync`, not `Play`. The asynchronous call returns immediately,
the hook process exits, and the tone is cut off mid-sound. That is why the
approval tone was once almost inaudible.

Two tones were removed. A rising figure at the question and a short
acknowledgement at completion both said the same thing as the speech a moment
later, and lay on top of it. The waiting tone now carries the whole sequence,
and its stopping is the acknowledgement.

## The language directive

`tts-prompt.ps1` injects a directive on every prompt. That is the only place the
language is decided, which is why a change takes effect immediately with no
restart. Do not add a `language` key to `settings.json`: two sources of truth
would eventually disagree.

There are three cases, and they are three because speech and the language split
are separate switches. With speech on and `switchLanguage` on, the terminal reply
follows `spokenLanguage` while everything written to disk stays
`writtenLanguage`. With speech on and the split off, one language governs both,
and it is `writtenLanguage`. With speech off, the same single language applies
and the directive says so. An earlier version tested the two switches together,
so a speaking session with the split off was told the voice was off. That branch
also drops the request for flowing prose, and the visible symptom was an ASCII
table read aloud.

"Speech on" here means the config says so, `Test-PiperReady` agrees, and
`Resolve-PythonExe` finds an interpreter. All three, because each one alone is
survivable and the combination is not: the directive would announce a voice, ask
for prose rather than tables and switch the reply into `spokenLanguage` while the
user heard nothing at all. The Python half is the failure recorded as B8, where
the model is on disk and `PATH` offers only a Store alias stub.

One case still escapes it. A real interpreter without `piper-tts` installed
passes both checks and dies at import inside the daemon, so only `tts.log` shows
it. Detecting that from a hook means running Python on every prompt, which costs
seconds where there are none to spare.

## Removed on purpose

**The Windows fallback voice.** It could not queue, so it clipped narration, and
a worse engine that only runs when something has already gone wrong never gets
tested. A missing Piper now fails loudly in the log.

**The thinking switch.** The transcript stores every thinking block as
`{type, thinking, signature}` with `thinking` always empty, verified across 34
blocks in one session, so it could never do anything. `work-loop.ps1` reports the
state instead, which is what you actually want to hear.

**Interrupting speech for an approval.** An earlier version let a question break
in between two sentences and read the rest afterwards. It worked, but cutting a
sentence in half mid-thought sounded like a fault. The question waits its turn
now, and ordering is handled by holding the description back instead.
