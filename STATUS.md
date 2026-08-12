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
- **The language directive has three cases, not two, and is gated on the voice
  model.** `tts-prompt.ps1` no longer tells a speaking session that the voice is
  off when `switchLanguage` is off, and no longer announces a voice when
  neither the voice model nor a usable Python is there. `$switch` now defaults to
  the shipped `false` rather than `true`, and the config is read once per prompt
  rather than twice. Two review rounds, eight findings, all acted on. Exercised
  across five configurations through the real hook, including the B8 case where
  the model is present and `PATH` offers no interpreter.
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

- [ ] **The tool announcement is heard before the text that preceded it on
      screen.** `narrate-preamble.ps1` submits the narration at line 123 and the
      announcement at line 160, both at normal priority, so the filename sort
      should already keep them in that order. The likely cause is timing rather
      than ordering: `PreToolUse` fires before the text block exists in the
      transcript, so the hook narrates nothing, speaks the announcement, and the
      text arrives on the next pass, after it. Unverified: it needs `tts.log`
      from a live turn. Worth fixing rather than accepting, because the preamble
      is usually where the reason for the action is, and that matters most when
      the next thing is an approval.
- [ ] **A background agent finishing is never spoken.** `/code-review` completed
      and said nothing. `notify-permission.ps1` line 41 drops any notification
      whose text does not match `permission|approve|allow|confirm`, and
      `notifyFilter` is `permission`. Whether `all` would cover it depends on
      Claude Code emitting a Notification event for a background task, which is
      unverified. This is the case the whole design is for: silence means you are
      up, and here silence meant the opposite.
- [ ] **Which events does Claude Code emit when the USER acts?** This decides two
      separate wishes and should be settled before either is designed.
      - Does Escape stop the waiting tone? The `Stop` hook now clears the pending
        entries and the marker, but Claude Code appears not to run `Stop` on a
        user interrupt, so the case that prompted the change may not be covered.
        Press Escape at a live prompt and watch whether the tone stops at once or
        runs to its ceiling. Note that `waitTone` is currently off, so it has to
        be switched on before the test means anything.
      - Is anything emitted when a permission question or an `AskUserQuestion` is
        answered or dismissed? Nothing in the plugin reacts to that moment today.
      If the answer is no in both cases, the plugin cannot respond when the user
      acts, however it is written, and both wishes are blocked on the same
      missing signal rather than on our own design. Establish the event surface
      first; the rest is cheap afterwards.
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
