# Status — 2026-08-12

## Hvor vi står

- **Installed as a real plugin, cut over to, and confirmed in use.** The data
  root is `~/.claude/plugins/data/read-aloud-read-aloud-tools`, which is the
  plugin name joined to the marketplace name. The earlier guess of plain
  `read-aloud` was wrong and the contents were moved across. A daemon runs
  against it from the plugin's own cached copy and speaks. The six hooks are no
  longer in `settings.json` and must not go back: both copies would fire.
- **Read aloud is on**, with the language split and `waitTone: false` carried
  over from the manual install. Ctrl+Alt+H works; the shortcut had to be
  repointed at `~/.claude/read-aloud\hush.vbs` after the cutover renamed the old
  install out from under it.
- **Both leftover data roots are deleted** and about 245 MB came back.
- **The install path is tested.** A session that had never seen the plugin
  provisioned its own data root, loaded the voice and spoke.
- **Two faults found by that test are fixed, reviewed and pushed.** `ee7a9f6`
  stops speech belonging to an open question being aged out (B7). `87850c3`
  stops the daemon being started on a Store alias stub that hangs (B8).
- **`PermissionRequest` carries no `tool_use_id`.** Confirmed from the log, twice.
  The fallback to the tool name was written for this, so nothing needs changing.
- **Tested:** every script parses, the Python compiles, everything is pure ASCII,
  manifests validate. 19 regression assertions on the stale rule and 4 on the
  interpreter resolver, both in the scratchpad rather than the repository, since
  there is still no test framework here.

## Åbne tråde

- [ ] **`tts-prompt.ps1` says voice output is off while it is on.** Line 119
      requires `enabled` AND `switchLanguage`, so with the split off it takes the
      else branch. That branch also drops the request for flowing prose, which is
      why a session reading aloud produced an ASCII table. Needs three cases, not
      two. Not visible while the split is on, which is the current setting.
- [ ] **Does Escape stop the waiting tone?** The `Stop` hook now clears the
      pending entries and the marker, but Claude Code appears not to run `Stop`
      on a user interrupt, so the case that prompted the change may not be
      covered. Press Escape at a live prompt and watch whether the tone stops at
      once or runs to its ceiling. If it is the ceiling, the fix belongs
      somewhere that fires on an interrupt, and there may be no such hook.
- [ ] **Concurrent sessions are documented, not fixed.** Two sessions sharing a
      data root share `transcript.path`, `working.flag` and `waiting.flag`, and
      each prompt sweeps the other's markers. `Clear-AllPending` and
      `Stop-Waiting` in the `Stop` hook now join that family and are the worst
      members, since they produce silence at the wrong moment. The fix is the
      same for all of it: key the flags by `session_id`.
- [ ] **Delete `~/.claude/hooks/tts.retired-2026-08-12`** when satisfied, plus
      the two `.pre-plugin-test.bak` files beside `settings.json` and
      `data.path`. Renamed rather than deleted on purpose, so anything still
      pointing at the old path fails loudly. It did exactly that today.
- [ ] **Rename the local folder** from `read-aload` to `claude-code-read-aloud`.
      The GitHub repository is already renamed. It cannot be done from inside a
      running session, and the `.code-workspace` file is named after it and can
      go.
- [ ] **Ownership left as it is for now.** The repository sits under the work
      account `DIs-LaudrupAnalytics`, which is also in the manifests and the
      licence. Transferring later stays cheap because GitHub keeps redirects.

## Senest

12 August 2026: ran the first real install test, fixed the two faults it exposed,
cut over to the plugin, then settled the data root name and cleared both
leftovers. See `sessionslog/2026-08-12.md`.
