# Status — 2026-08-12

## Hvor vi står

- **The plugin is complete and validates.** Six hooks, the Piper daemon, two
  background loops, the skill, three manifests. `claude plugin validate .`
  passes.
- **Program and data are separated** (B2), so a plugin update no longer
  overwrites the config or discards the voice model. The hush hotkey points at a
  fixed directory that survives updates.
- **All code and documentation is in English** (B3) and every PowerShell and
  VBScript file is pure ASCII.
- **Documentation is written from the verified source**, not from recollection:
  README, `docs/architecture.md` and `CLAUDE.md`. The invariants section of
  CLAUDE.md is the part that matters most, since each entry prevents a specific
  fault.
- **Tested:** every script parses and compiles, all six hooks run end to end with
  realistic payloads and exit cleanly, queue ordering and the hold-and-release
  mechanism behave correctly, and the hush script clears queue, flags and markers
  through its pointer file. Not yet tested as an installed plugin.
- **`/update-session-log` is installed at user level** and reviewed. It is what
  wrote this file.

## Åbne tråde

- [ ] **Second pass on the code review.** Five findings fixed; these remain, in
      the order I would take them:
      - The synthesis cache never evicts. Tool announcements embed a unique
        command description, so they are cached and never reused: 337 files and
        40 MB after twelve hours of real use. `tts.log` never rotates either.
      - Both transcript-reading hooks (`narrate-preamble.ps1:48`,
        `speak-response.ps1:38`) load the whole transcript on every call, when
        only the tail is needed. `work-loop.ps1` already tails 8 kB for exactly
        this reason. On a long session this can approach the 10 s hook timeout,
        and narration then dies silently.
      - `Release-HeldSpeech` releases every held announcement, not the one
        belonging to the tool that finished. With parallel tool calls this lets a
        second description escape before Claude Code has decided whether to ask,
        which defeats the ordering guarantee. `pending.flag` has the same shape:
        any tool finishing clears it while another approval may still be open.
      - `transcript.path`, `working.flag` and `waiting.flag` are single files in
        one data root, so two concurrent sessions collide. At minimum document
        it; the transcript pointer is also stale in a turn with no tool calls.
      - `drain_queue` is unconditional, so it also deletes items queued in the
        ~1 s window after a stop, not just the backlog the stop was aimed at.
      - `@($payload.tool_input.questions)` has count 1 when `questions` is null
        in PowerShell 5.1, so the zero guard never fires and a malformed payload
        is read aloud as "Option one. ." Also `$ord` is indexed without the
        bounds check the option loop has, so more than eight questions gives
        "Question, of nine."
      - The first two comment blocks in `.gitignore` are Danish, which
        contradicts B3.

- [ ] **Test the plugin the way a user installs it.** This is the next job and
      the last untested path. From a fresh session:
      `claude --plugin-dir "C:\Users\jave\OneDrive - DI\Documents\GitHub\read-aload"`,
      then check that the six hooks fire, that `/read-aloud:read-aloud on` works,
      and that the data directory is created under
      `~/.claude/plugins/data/`. A voice model must be downloaded into its
      `voices/` directory first, or you get silence and a line in `tts.log`.
      This does not disturb the existing hooks in `~/.claude/hooks/tts/`.
- [ ] **Rename the local folder** from `read-aload` to `claude-code-read-aloud`.
      The GitHub repository is already renamed; only the directory on disk still
      has the transposed name. It cannot be renamed from inside a running
      session, and the `.code-workspace` file is named after it and can go.
- [ ] **Ownership left as it is for now.** The repository sits under the work
      account `DIs-LaudrupAnalytics`, which is also in the manifests and the
      licence. Transferring later stays cheap because GitHub keeps redirects, but
      it would mean editing those files and the README install line.

## Senest

12 August 2026: verified the implementation against the source, split program
from data, removed the dead code, translated everything to English, wrote the
packaging and documentation, and pushed the first two commits. See
`sessionslog/2026-08-12.md`.
