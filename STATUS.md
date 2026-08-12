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
