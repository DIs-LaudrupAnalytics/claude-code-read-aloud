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
| B2 | 2026-08-12 | Program and data live in separate roots; the hush shortcut gets a fixed directory outside the plugin | besluttet |
| B3 | 2026-08-12 | English throughout: comments, docstrings, documentation, commit messages | besluttet |
| B4 | 2026-08-12 | No fallback speech engine, and no code path that cannot be exercised | besluttet |
| B5 | 2026-08-12 | Project memory: session log local, STATUS and this log committed | besluttet |
| B6 | 2026-08-12 | Per-call state is keyed by `tool_use_id`, never a single shared flag | besluttet |

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
