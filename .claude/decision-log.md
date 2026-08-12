# Decision log

**Durable design and architecture decisions** for `read-aloud`, in the spirit of
an ADR: the ones a future developer asks "why is it built like this?" about, and
which are expensive or surprising to roll back. Litmus test: would it cost
something to undo? Transient workflow noise (commit flow, file placement, ad hoc
choices) belongs in `sessionslog/`, not here. Maintained via
`/update-session-log`.

Written in English, like the rest of this repository. It is committed on purpose:
its job is to stop a later session reversing something that was settled, and it
can only do that for other people if they have it.

Operational rules that follow from these decisions are stated as invariants in
`CLAUDE.md`. This file records why they exist.

## Oversigt

| ID | Dato | Beslutning | Status |
|----|------|------------|--------|
| B1 | 2026-08-12 | Distributed as a Claude Code plugin with a marketplace manifest; manual install documented as a fallback | besluttet |
| B2 | 2026-08-12 | Program and data live in separate roots; the hush shortcut gets a fixed directory outside the plugin | besluttet; 2026-08-12 genvejen omdirigeret til den faste mappe efter cutover |
| B3 | 2026-08-12 | English throughout: comments, docstrings, documentation, commit messages | besluttet |
| B4 | 2026-08-12 | No fallback speech engine, and no code path that cannot be exercised | besluttet |
| B5 | 2026-08-12 | Project memory: session log local, STATUS and this log committed | besluttet |
| B6 | 2026-08-12 | Per-call state is keyed by `tool_use_id`, never a single shared flag | besluttet; 2026-08-12 bekraeftet at `PermissionRequest` ikke baerer et id |
| B7 | 2026-08-12 | Speech belonging to an open question is never aged out; the stale rule keys on `pending/`, not on age alone | besluttet |
| B8 | 2026-08-12 | The daemon is started only on a verified real interpreter, never a bare name from `PATH` | besluttet |
| B9 | 2026-08-12 | The data root name is whatever the harness computes; it is read from `data.path` and never renamed by hand | besluttet |
| B10 | 2026-08-12 | A new prompt cuts speech off at once; the only deliberate exception to "never interrupt an utterance" | besluttet; 2026-08-12 udvidet af B11 og B12, så undtagelsen er "lytteren handler" med fire veje |
| B11 | 2026-08-12 | Answering a question silences that question's speech and nothing else, through `skip.flag` and a per-call tag | besluttet |
| B12 | 2026-08-12 | Where Claude Code emits no event for a user action, the transcript is the signal | besluttet |
| B13 | 2026-08-12 | Cue tones open with an inaudible lead-in, because a Bluetooth link sleeps between sounds | besluttet |

## Detaljer

### B1 — Distributed as a plugin, manual install as fallback (2026-08-12)

**Kontekst:** The setup existed as loose scripts in the author's home directory
with six hooks hand-registered in `settings.json`. Publishing it meant either
documenting that hand installation for strangers, or packaging it. The reference
point was `gvzdv/claudish-to-english`, which ships through the plugin
marketplace and installs in two commands.

**Beslutning:** Ship as a plugin. The repository carries
`.claude-plugin/plugin.json`, `hooks/hooks.json` and
`.claude-plugin/marketplace.json`, so installation is `/plugin marketplace add`
followed by `/plugin install`, with no hand editing of anyone's settings. The
manual path stays documented in the README for anyone who prefers it.

**Konsekvens:** Hook commands must use `${CLAUDE_PLUGIN_ROOT}`, which forces B2.
The voice model cannot be bundled and remains a manual prerequisite either way,
which is why the README puts requirements before installation. Skills are
namespaced, so the command is `/read-aloud:read-aloud` rather than the
`/read-aloud` the author was used to.

### B2 — Program and data in separate roots (2026-08-12)

**Kontekst:** Every script derived its own directory and put everything there:
config, queue, cache, voice models, log and flag files. As a plugin that breaks.
The plugin directory is version-bound, its path changes on every update, and the
documentation says explicitly not to write state there. Config would be
overwritten and a few hundred megabytes of voice model re-downloaded on every
update.

**Beslutning:** Two roots. The program directory is read-only and holds scripts
and cue tones. `${CLAUDE_PLUGIN_DATA}` holds everything mutable and survives
updates. Resolution order is `CLAUDE_TTS_DATA`, then `CLAUDE_PLUGIN_DATA`, then
`%USERPROFILE%\.claude\read-aloud\data` for a manual install, deliberately
outside any git checkout. The daemon receives the data root as `argv[1]` because
it does not reliably inherit the hook's environment.

A third, fixed directory, `%USERPROFILE%\.claude\read-aloud`, holds `hush.vbs`
and a `data.path` pointer. This is not tidiness: a keyboard shortcut into the
plugin directory would become invalid on every update, and the hush script runs
outside Claude Code where no environment variables are available.

**Konsekvens:** Three path variables to keep straight in `tts-common.ps1`, and a
first-run step that provisions the data root and copies the hush script. In
exchange, updates are non-destructive and the hotkey never breaks.

### B3 — English throughout (2026-08-12)

**Kontekst:** All comments and docstrings were in Danish, and unusually good:
they explain why, usually naming the failure that caused the decision. For an
international audience that is a barrier. The author works mainly in Danish.

**Beslutning:** English for comments, docstrings, documentation and commit
messages. The author's own working notes stay Danish.

**Konsekvens:** A side effect worth keeping: the PowerShell files must be pure
ASCII, because PowerShell 5.1 reads a BOM-less UTF-8 file as ANSI. In Danish that
forced `ae`/`oe`/`aa` transliteration throughout, which served neither audience.
English satisfies the constraint for free. Non-ASCII characters that a regular
expression genuinely needs are written as `\u` escapes.

### B4 — No fallback engine, and no inert code (2026-08-12)

**Kontekst:** A Windows speech fallback existed for a broken Piper, and a
`thinking` switch existed to read Claude's reasoning aloud.

**Beslutning:** Both removed. A missing Piper now fails loudly in the log and
speaks nothing.

**Konsekvens:** The fallback could not queue, so it clipped narration, and an
engine that only runs after something has already gone wrong is never exercised
and cannot be trusted. The thinking switch could never work at all: the
transcript stores every thinking block with an empty `thinking` field, verified
across 34 blocks. The state is reported by `work-loop.ps1` instead, which is what
a listener actually wants. The two cue tones removed at the same time duplicated
speech that followed a moment later. Everything is in git history if it needs to
come back.

### B5 — Project memory: what is committed and what is not (2026-08-12)

**Kontekst:** The author's session-log convention keeps three files per project.
The question was which belong in a public repository.

**Beslutning:** `sessionslog/` is local and ignored. `STATUS.md` and this file
are committed.

**Konsekvens:** The decision log exists to constrain a later session. Kept local
it would constrain only one machine, which defeats its purpose. STATUS gives a
fresh clone the present-tense picture. The cost is that STATUS is overwritten
every session, so on a project with several people working in parallel it will
conflict every time; there, ignoring it may be the better trade. Placement inside
`.claude/` is deliberate but does no enforcing by itself: nothing there is loaded
automatically, and it is the pointer in `CLAUDE.md` that gives this file effect.

### B6 — Per-call state is keyed by `tool_use_id` (2026-08-12)

**Kontekst:** Three separate faults turned out to be the same fault. A single
`running.flag` was deleted by whichever call finished first, so the status
message reported the wrong command and the wrong elapsed time. A single
`pending.flag` was cleared the same way, so the waiting tone stopped while the
approval question was still on screen. And `Release-HeldSpeech` freed every held
announcement at once, so with two calls in flight the first to finish let the
second one's description out before Claude Code had decided whether to ask about
it, and the question then arrived after its own answer. Tools run in parallel,
and every shared flag in this design was cleared by the wrong owner.

**Beslutning:** Anything that belongs to one tool call is keyed by its
`tool_use_id`: one marker file per call in `running/`, one entry per open
approval in `pending/`, and the id embedded in the queue file name of a held
announcement so `PostToolUse` can release its own and nothing else. A hook that
has no id does the safe thing instead of the prompt thing: it releases nothing
and lets `holdMs` expire.

**Konsekvens:** Three directories where there were three flag files, and a
sweep for entries a denied call left behind, since a denial never reaches
`PostToolUse`. Two places still cannot be keyed, and both are documented where
they are: the `Notification` fallback carries neither an id nor a tool name, and
`PermissionRequest` is undocumented on this point, so it falls back to the tool
name and logs when it has to. Do not simplify any of these back to a single
flag; each one was a shared flag first, and this is the failure that followed.

**Status (opdateret 2026-08-12):** `PermissionRequest` is now known to carry no
`tool_use_id`. The first install test logged it twice, for `WebFetch` and for
`AskUserQuestion`. Nothing needs changing, since the fallback to the tool name
was written for exactly this, but the question is settled and the logging can
stay as evidence rather than as an open enquiry.

### B7 — Speech that belongs to an open question is never aged out (2026-08-12)

**Kontekst:** The daemon discards queue items older than `staleMs`, so a backlog
built up while it was busy or down is not read out minutes late. The first
install test showed what that costs when it catches the wrong item. A permission
announcement queued behind a long narration was discarded after 51 seconds, and
because the waiting tone runs off its own marker it went on sounding. The result
is the worst state this plugin can produce: a tone saying somebody is waiting on
you, and no sentence saying what for. Two rules that are each right alone
collided, since never interrupting an utterance in progress is exactly what makes
an urgent item wait long enough to be aged out.

**Beslutning:** The rule is about relevance, not age. Ageing is suspended for
speech queued from the moment `pending/` says the user was asked something, since
an unanswered question does not go out of date by waiting in a queue.

Three narrower choices inside it, each of which was the second attempt, and each
of which a future session will be tempted to simplify away:

- **Keyed on `pending/`, not on the `0-` prefix.** The `AskUserQuestion` text is
  queued as `1-` on purpose, because the narration leading into it must be spoken
  first. A prefix test protects the generic permission line and drops the actual
  question, which is the half that cannot be guessed from the tone.
- **Scoped to what was queued at or after the question, not the whole queue.**
  Protecting everything preserved the backlog from before it too, and since
  `wait-loop.ps1` counts a non-empty queue as speech, the tone then never sounded
  at all. Unbroken speech means "I am working" here, so the listener was told the
  opposite of the truth at the moment they were the one holding things up.
- **Anchored on the oldest open entry, not the newest.** Two entries can be open
  at once by design. Anchored on the newest, a later approval moved the line
  forward and retracted an earlier question's protection.

**Konsekvens:** `narrate-preamble.ps1` must write the pending marker BEFORE the
speech it protects, matching `permission-request.ps1`. That ordering used to be
irrelevant and is now load-bearing. Two bounds keep the exemption from becoming
the old bug in a new shape: 15 seconds of slack before the marker, because on the
`Notification` fallback path the marker lands 6.8 to 9.6 s after the announcement,
and 120 seconds after it, because a denied call strands its entry and would
otherwise suspend ageing for the rest of a long turn. `pendingHoldMs` caps the
whole thing at thirty minutes.

### B8 — The daemon starts only on a verified real interpreter (2026-08-12)

**Kontekst:** `Start-PiperDaemon` launched a bare `pythonw.exe` and let `PATH`
resolve it. On Windows what `PATH` offers first is usually a Microsoft Store app
execution alias: a zero-length stub that forwards to the real interpreter. It
forwards perfectly from a console, which is what makes this so hard to see, since
`python -c` at a prompt works and the interpreter looks healthy. Started hidden
and without a console, the way this plugin starts it, the stub can simply hang.
Observed on both launches of the first install day: the stub sat at 16 MB and a
tenth of a second of CPU for hours while a second daemon did the work.

**Beslutning:** Resolve the interpreter and verify it. A zero-length file is the
signal, since a real `python.exe` is a hundred-odd kilobytes and an alias is
exactly zero. Order: an explicit `pythonPath`, then the cached answer in
`python.path`, then anything on `PATH` that is not zero length, then the Windows
launcher. If nothing survives, the daemon is not started and one line says why.

**Konsekvens:** Falling back to the bare name is deliberately not an option. The
stub hangs BEFORE `claim_singleton`, so the lock never sees it; had it taken the
lock first it would hold it while hung, and the result is total silence with an
empty log, indistinguishable from the plugin not being installed at all. That is
the worst failure mode available here, which is what justifies this much code for
a launcher. Three ordering details are load-bearing and were each wrong first:
`pythonPath` is read before the cache, or it can never take effect in the case it
exists for; `PATH` is preferred over the launcher, because `pip install
piper-tts` installs into whatever is on `PATH` while the launcher answers with
the system default; and the launcher is invoked with a three second ceiling
rather than synchronously, since a function whose whole premise is that these
stubs hang must not stake a blocking hook on one answering.

### B9 — The data root name belongs to the harness (2026-08-12)

**Kontekst:** The cutover built a data root at
`~/.claude/plugins/data/read-aloud`, on the assumption that a marketplace
install drops the `-inline` suffix that `--plugin-dir` adds. It does not. Claude
Code names the directory after the plugin joined to the marketplace it came
from, so the real root is `read-aloud-read-aloud-tools` and the hand-built one
sat beside it holding both voice models while the plugin spoke from an empty
directory. The stutter in that name invites tidying, which is exactly the risk.

**Beslutning:** The name is not ours to choose. The harness computes the path
and hands it to the plugin, and the only authority on where it currently is is
`%USERPROFILE%\.claude\read-aloud\data.path`, which the prompt hook rewrites on
every prompt. Read that file. Do not derive the path, do not hardcode it, and do
not rename the directory to something tidier.

**Konsekvens:** Renaming it by hand is not a cosmetic change with a cosmetic
cost. The next session computes the old path, finds nothing, provisions a fresh
root with a default config, and the voice models are orphaned again: 120 MB in a
directory nothing reads, a language split silently reset, and silence as the
only symptom. The README already says not to guess the directory and to read
`data.path` instead; this entry records that the advice binds the maintainers
too, since the cutover was done by guessing while the README said otherwise.

### B10 — A new prompt cuts speech off at once (2026-08-12)

**Kontekst:** The plugin holds a strict rule against interrupting: an utterance
that has started is always finished. An early version let an approval question
break in between two sentences, and although it worked mechanically, a sentence
cut mid-thought was heard as a fault rather than as a signal. The rule as stated
in `CLAUDE.md` is unconditional, and read literally it forbids what
`tts-prompt.ps1` does at the top of every prompt.

**Beslutning:** The user's own prompt is the exception, and the only one. The
`submitted` cue is played first and synchronously, then `Stop-AllSpeech` writes
the stop flag and empties the queue, so the previous turn's narration dies
immediately rather than talking over what comes next. Confirmed as wanted from
live use on 2026-08-12.

**Konsekvens:** The rule against interrupting is about the plugin cutting itself
off. This is the opposite: the listener cutting the plugin off, and the two are
not the same event. Typing is proof that the user has read ahead and is done
listening, so finishing the sentence would be talking to nobody, and the queued
remainder of a long turn would then delay everything about the new one. Anyone
reading the invariant literally will find this and think it a bug. It is not.
Do not make the prompt path wait for the current utterance, and do not soften
the cut into a fade or a queue drain that lets the sentence finish. The cue
stays before the stop, so the acknowledgement is heard even when it lands on top
of the last word being cut.

### B11 — Answering a question silences that question, and nothing else (2026-08-12)

**Kontekst:** Speech lags the screen by design, since nothing is ever
interrupted. The consequence in use is that you answer a question and then go on
hearing it read out, describing a decision you have already made and delaying
whatever comes next. The obvious lever was the stop flag, which the plugin
already had, and it is the wrong one: a stop empties the backlog with the
utterance, and Claude Code queues a second question directly behind the first, so
stopping would silence exactly what the listener is waiting for. The wish was
stated precisely by the user: answering question one should stop question one and
leave question two audible.

**Beslutning:** A separate `skip.flag` that ends ONE utterance. The speech
belonging to a question is queued with a tag, the daemon writes the tag of what
it is currently speaking into `speaking.flag`, and the flag carries the tag it is
aimed at. The daemon compares the two before purging anything. Nothing else in
the queue is touched, so the narration leading up to the question survives.

Silencing is keyed to one CALL, never to a tool name, and that distinction is
the whole entry. Doing it inside `Remove-Pending` was the first attempt: that
function is also handed the tool-name fallback key, because `PermissionRequest`
carries no `tool_use_id` (B6), so an auto-approved Bash finishing would cut off
the question about a different Bash whose dialog was still on screen. Tone and
speech therefore use different keys on purpose: the pending entry stays broad,
since a tone left running is the cheaper error, and the speech carries either the
`tool_use_id` or a signature of the tool name plus a hash of `tool_input`.

**Konsekvens:** Three things a later session will want to tidy and must not. The
tag and the pending key are deliberately different strings on the fallback path.
The tag comparison in the daemon is not belt and braces: without it, an answer
arriving as the queue moves on cuts off the following, unanswered question, which
is worse than the fault being fixed. And `Stop-AllSpeech` has to clear a stale
skip flag, because the daemon consumes it only while playing and the stop check
returns before reading it.

Two limits are accepted and recorded in `STATUS.md`: two concurrent calls with
byte-identical input share a signature, and the `Notification` fallback path stays
untagged, because its only key is shared and silencing on it would cut whichever
question happened to be open. A mismatch anywhere degrades to the old behaviour,
where the question finishes being read, which is the safe direction.

### B12 — Where there is no event, the transcript is the signal (2026-08-12)

**Kontekst:** Two wishes were blocked on the same unknown: stopping speech when
the user dismisses a question, and stopping it on `/clear`. Both were held open
across sessions pending the answer to "what does Claude Code emit when the user
acts?". Settled by reading the hooks documentation for this version and then
testing live. The answer is mostly nothing. Answering a question is covered,
because answering runs the tool and `PostToolUse` fires. Dismissal emits nothing;
`PermissionDenied` covers auto mode denials, `PostToolUseFailure` covers a tool
that ran and errored, and `Stop` does not run on an interruption. `/clear` was
the exception in the other direction: it submits no prompt, so
`UserPromptSubmit` never runs, but `SessionStart` does fire with a `source` field.

**Beslutning:** Use an event where one exists and the transcript where none does.
`/clear` gets a `SessionStart` hook matched on `clear` alone. An interruption is
detected from the `[Request interrupted by user]` entry in the transcript, in
`work-loop.ps1`, which already read it for another purpose. Both then treat the
moment the same way a new prompt is treated, because in all three the listener has
finished with the whole turn.

**Konsekvens:** Reading the transcript to infer a user action is now an accepted
technique here rather than a workaround, and the price is stated where it is paid.
Detection lags by the 2 s poll. It lives in the loop that reports progress, so an
unrelated setting gates it: with the working messages off, Escape silences
nothing. And ownership has to be re-checked immediately before acting, because the
transcript entry is a level rather than an edge: it stays the last line until the
next prompt is appended, so Escape followed by typing could otherwise silence the
turn that had just begun.

The matcher on `SessionStart` is `clear` and nothing else. `startup`, `resume` and
`fork` have nothing of their own to silence and would cut off a second window
sharing the data root; automatic compaction arrives mid-turn and would be the
plugin interrupting itself, and a hand typed `/compact` cannot be told apart from
it. `clear` carries the same cost against a second window and the file says so:
accepted because clearing is deliberate and rare.

### B13 — Cue tones open with an inaudible lead-in (2026-08-12)

**Kontekst:** The waiting tone had never been audible. It was raised twice on the
assumption that the level was wrong, from 0.30 amplitude and 110 ms to 0.50 and
200 ms, and neither helped. The log showed the file being played every time. The
deciding experiment was to play the same file from a console, where it was heard,
and from the hidden loop, where it was not: the listener is on Bluetooth. An A2DP
link powers down after a few seconds of silence and takes up to a second to come
back, so a 200 ms tone is over before the headset is receiving. Speech survives
this by losing only its opening; a short tone is lost whole.

**Beslutning:** The cue opens with 0.9 s of the same note at an amplitude you
cannot hear, which is signal enough to hold the link open, and then the beep at
full level. Built as one continuous rising envelope, not two tones back to back:
that version was audible but was heard as rough, because each segment faded to
zero at its edges and the codec was handed a step in the moment before the beep.

**Konsekvens:** A cue file is now five times longer than the sound it makes, which
looks like a mistake and is not. The wait loop had to follow: real elapsed time
instead of the sum of the sleeps, the cue's own length taken out of the interval
rather than added to it, and an interval floor of 1500 ms, since anything shorter
could no longer be honoured.

Two prices are accepted for now and recorded in `STATUS.md`. At 0.01 the lead-in
is not quite inaudible on headphones and is heard as a slow swell. And because the
cue is played synchronously with the check for speech happening before it, the
window in which a tone can land on top of speech grew from 0.2 s to over a second.
Both are fixed by the same later change: a lead-in of digital silence, or a much
lower amplitude, and splitting the cue in two so the loop can re-check between the
lead-in and the beep.

The `submitted` cue deliberately has no lead-in. It is heard every time, and it
plays synchronously before the silencing (B10), so a lead-in would leave the
previous turn talking almost a second longer after Enter.
