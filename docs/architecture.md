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

Duplicate speech is prevented by a per-session watermark in `state/`, recording
the `uuid` of every entry already spoken. One answer can trigger several tool
calls, so `PreToolUse` fires repeatedly over the same content.

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

`tts-prompt.ps1` injects a directive on every prompt, derived from `enabled` and
`switchLanguage`. That is the only place the language is decided, which is why a
change takes effect immediately with no restart. Do not add a `language` key to
`settings.json`: two sources of truth would eventually disagree.

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
