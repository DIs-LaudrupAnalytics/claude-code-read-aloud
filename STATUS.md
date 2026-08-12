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
- [ ] **The event surface when the user acts: settled, and the answer was no.**
      Established 12 August 2026 from the hooks documentation for this version
      plus live tests. Answering a question is covered, because answering runs
      the tool and `PostToolUse` fires. Everything else is not: no event fires
      when a question is DISMISSED, `PermissionDenied` covers auto mode denials
      only, `PostToolUseFailure` covers a tool that ran and errored, and Claude
      Code does not run `Stop` on an interruption. `/clear` submits no prompt at
      all, which is what the new `SessionStart` hook is for.
      - **Confirmed live:** pressing Escape on an `AskUserQuestion` left the
        speech reading to the end. Nothing stopped it but typing.
      - **Fixed without an event:** `work-loop.ps1` already watched the
        transcript for the `[Request interrupted by user]` entry, since that is
        the only evidence there is, and used it only to stop reporting a dead
        command. It now calls `Stop-AllSpeech`, so an interruption falls quiet
        within the 2 s poll. An interruption is the listener acting, the same
        class as a new prompt (B10), not the plugin cutting itself off.
      - **Still open:** the poll is 2 s, which is a long time to hear a question
        you have already dismissed. A faster poll costs a transcript read every
        cycle for the whole turn. Worth measuring before tightening.
      - **Still unread:** this version documents around thirty hook events
        against the six the plugin was built for. `TaskCompleted`,
        `SubagentStop`, `MessageDisplay` and `Notification`'s
        `notification_type` (which includes `agent_completed`) are each a
        candidate for one of the threads above and below. Names only so far; no
        payload has been verified.
- [ ] **An unreadable config is read as speech being switched off.** The daemon's
      `load_config` returns `{}` on any failure, and `main` then sees
      `enabled` missing and exits. Observed in the live log on 12 August 2026:
      rewriting `tts-config.json` from a hook let the daemon read the file in the
      moment it was empty, so it shut down and the next utterance paid for a
      model reload. Two fixes, both cheap: keep the last good config on a read
      failure rather than treating it as off, and write the config atomically
      through a temporary file and a rename. The second one matters because the
      read-aloud skill rewrites this file while the daemon is running.
- [ ] **The waiting cue works now, but its lead-in is audible.** Settled on
      12 August 2026: the tone was never inaudible because of its level. The
      listener is on Bluetooth, the A2DP link powers down after a few seconds of
      silence and takes up to a second to return, and a 200 ms beep was over
      before the headset was receiving. Proved by playing the same file from a
      console, where it was heard, and from the hidden loop, where it was not.
      The cue now carries a 0.9 s lead-in of the same note at 0.01 amplitude,
      built as one continuous rising envelope after a two-segment version was
      heard as rough, and all four test tones were then heard. What remains is
      that 0.01 is not inaudible on headphones: it is heard as a slow swell into
      the beep. **Next thing to try:** a lead-in of literal digital silence, on
      the theory that what wakes the link is the audio stream opening rather than
      anything in it. If that fails, an amplitude around 0.0008. Kept as it is
      for now on the user's decision, since it is audible, which it was not
      before.
- [ ] **The submitted cue has no wake-up lead-in, and by the Bluetooth argument it
      should.** Raised by the review on 12 August 2026 and deliberately not
      acted on. It plays at `UserPromptSubmit`, right after you have been typing
      in silence, which is exactly the idle-link case. Left alone because it is
      empirically heard every time, and because it plays synchronously BEFORE
      `Stop-AllSpeech` by design (B10): a 0.9 s lead-in would mean the previous
      turn's speech carried on for almost a second longer after you pressed
      Enter. If it ever does go missing, the fix is known and the trade is the
      latency.
- [ ] **The waiting cue can now overlap speech by up to a second.** `Play-Cue` is
      synchronous and `Test-Talking` is checked only before it starts, so with a
      1.1 s cue, speech that begins during the lead-in gets the beep on top of
      it. The window used to be 0.2 s, so the exposure is five times what it was,
      and the review points out that the likeliest case is the one that matters
      most: you approve, Claude resumes, and the beep lands on the first words of
      the answer. Raised in both review rounds. Deferred on the user's decision
      to move on, and it belongs with the other cue-shape work rather than being
      fixed on its own. **The fix:** two files rather than one, so the loop plays
      the inaudible lead-in, re-checks `Test-Talking`, and only then plays the
      beep. Watch the smoothness when doing it: a two-segment version inside one
      file was heard as rough.
- [ ] **Two approval dialogs at once has never been verified.** The plugin has
      assumed since the pending entries were written that Claude Code asks about
      one approval at a time, and `Clear-PendingKind 'p'` now silences the retired
      question's speech on that basis. If the assumption is wrong, a second
      question would silence a first one that was still on screen. A log line was
      added where it would show: `retired pending <key> after <n> ms`, and two
      questions within a second or two of each other is the shape to look for.
      Read the log after a batch of tool calls that needed several approvals.
- [ ] **Two concurrent identical calls share one signature.** `Get-CallSignature`
      is the tool name plus a hash of the tool input, since `PermissionRequest`
      carries no `tool_use_id`, so two parallel calls with byte-identical input
      collapse into one key and the first to finish silences the second's
      question. Narrow: both calls must be the same tool, with identical input,
      and both must need approval. Closing it properly means a side channel from
      `PreToolUse`, which owns the id, to `PermissionRequest`, which does not, for
      instance a `sig/<signature>.txt` file holding the id. Not worth the
      machinery until the case is seen.
- [ ] **Escape silencing is gated on the `working` setting.** It lives in
      `work-loop.ps1`, the only process already watching the transcript, and that
      loop runs only while `working.flag` exists. With `working` off, or after
      `workingMaxMs`, Escape silences nothing. Both are on by default and both are
      on here. A watcher of its own would fix it and is more machinery than the
      case has earned.
- [ ] **Speech may be losing its first word to the same cause.** Untested. A long
      utterance survives a sleeping Bluetooth link by sacrificing its opening,
      which would be heard as a clipped first word rather than as a fault, and
      the daemon's 0.30 s tail margin has no counterpart at the start. Worth one
      deliberate listen after a long silence before deciding whether it needs a
      lead-in of its own.
- [ ] **Mathematics is unlistenable.** Piper phonemises through espeak-ng and has
      no notion of notation, so LaTeX arrives as a stream of symbol names and
      fragments: `\frac{a}{b}` is read roughly as backslash, frac, brace, and is
      impossible to follow. Inline `$...$` and display `$$...$$` are both
      affected, and so is plain notation like `x^2` or `\alpha`. The place to fix
      it is `ConvertTo-Speakable`, which already rewrites markdown, by
      translating the common constructs into words before the text reaches the
      voice: fraction a over b, x squared, alpha. Worth scoping before writing,
      since the tail of LaTeX is infinite and the useful part is small: the few
      dozen constructs that actually turn up in prose. Raised 12 August 2026.
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
