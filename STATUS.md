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
- **Both code review rounds are closed.** Twelve findings in the first pass,
  seven more from the second, all fixed and pushed. The state that belongs to
  one tool call is keyed by `tool_use_id` throughout (B6), the synthesis cache
  and the log have ceilings, and the transcript hooks read only the tail.
- **Documentation is written from the verified source**, not from recollection:
  README, `docs/architecture.md` and `CLAUDE.md`. The invariants section of
  CLAUDE.md is the part that matters most, since each entry prevents a specific
  fault.
- **Tested:** every script parses and compiles, all six hooks run end to end with
  realistic payloads and exit cleanly, and there is now a regression check per
  review finding covering queue ordering, the hold-and-release logic, the
  pending set, the tail reader and the cache and log ceilings. Not yet tested as
  an installed plugin.

## Åbne tråde

- [ ] **Test the plugin the way a user installs it.** This is the next job and
      the last untested path. From a fresh session:
      `claude --plugin-dir "C:\Users\jave\OneDrive - DI\Documents\GitHub\read-aload"`,
      then check that the six hooks fire, that `/read-aloud:read-aloud on` works,
      and that the data directory is created under
      `~/.claude/plugins/data/`. A voice model must be downloaded into its
      `voices/` directory first, or you get silence and a line in `tts.log`.
      The live install is still the old manual one in `~/.claude/hooks/tts`, and
      this does not disturb it.
- [ ] **Does `PermissionRequest` carry a `tool_use_id`?** Undocumented, and the
      code takes a weaker path without it. It now logs one line when the id is
      missing, so the answer is in `tts.log` after the next few approvals.
- [ ] **Concurrent sessions are documented, not fixed.** Two sessions sharing a
      data root share `transcript.path`, `working.flag` and `waiting.flag`, and
      each prompt sweeps the other's markers. The fix is to key the three flags
      by `session_id` and scope the two sweeps.
- [ ] **Rename the local folder** from `read-aload` to `claude-code-read-aloud`.
      The GitHub repository is already renamed; only the directory on disk still
      has the transposed name. It cannot be renamed from inside a running
      session, and the `.code-workspace` file is named after it and can go.
- [ ] **Ownership left as it is for now.** The repository sits under the work
      account `DIs-LaudrupAnalytics`, which is also in the manifests and the
      licence. Transferring later stays cheap because GitHub keeps redirects, but
      it would mean editing those files and the README install line.

## Senest

12 August 2026: fixed the seven remaining review findings, had them reviewed
again, fixed the two faults that review found in the fixes, and pushed `f24217d`.
See `sessionslog/2026-08-12.md`.
