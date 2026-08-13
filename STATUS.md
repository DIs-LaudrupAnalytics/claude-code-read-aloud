# Status — 2026-08-13

## Hvor vi står

- **Installed as a plugin at `0.2.0`, commit `2bb7bd9`, and in daily use.** The
  data root is `~/.claude/plugins/data/read-aloud-read-aloud-tools`: the plugin
  name joined to the marketplace name, read from `data.path` and never derived
  (B9). The hooks must never go back into `settings.json`; both copies would fire.
- **Seven hooks now.** `SessionStart` matched on `clear` was added today, because
  `/clear` submits no prompt and nothing else in the plugin silences anything.
  Registered in the installed copy but only active from the next session, since
  hooks are read at startup. Untested for that reason.
- **The plugin reacts when the user acts, in all four cases:** a new prompt,
  `/clear`, Escape, and answering a question. The last one silences only that
  question (B11); the other three silence everything. Three of the four were
  verified live today.
- **Config:** speech on, language split on, English spoken and Danish written,
  `askAloud: labels` so the question is read in full and only the option
  headlines follow, `waitTone: true`. Ctrl+Alt+H works.
- **The waiting tone can be heard at last.** It was never a level problem: the
  listener is on Bluetooth, and a 200 ms beep was over before the link woke. The
  cue now opens with an inaudible 0.9 s lead-in (B13).
- **Tested:** all four repository checks green. 22 regression assertions on tags,
  queue, skip and signatures, and 10 on the daemon's tag parsing and skip flag,
  both in the scratchpad since there is still no test framework here.
- **Two review rounds today, fourteen findings, all answered:** six fixed, and the
  rest recorded below with the fix and the reason for leaving it.

## Åbne tråde

- [ ] **Test `/clear` in the next session.** The previous answer should stop dead,
      and the log should show `session-start silenced: source=clear`.
- [ ] **The tool announcement is heard before the text that preceded it on screen.**
      Reproduced again today with an `AskUserQuestion`. `PreToolUse` most likely
      fires before the text block reaches the transcript, so the hook narrates
      nothing and the text is picked up on the next pass. `MessageDisplay` is the
      candidate event. Worth fixing: the preamble is where the reason for an
      action is, and that matters most when an approval follows.
- [ ] **A background agent finishing is never spoken.** `/code-review` completed in
      silence, twice. `notify-permission.ps1` drops notifications that do not
      match `permission|approve|allow|confirm`. `TaskCompleted`, `SubagentStop`
      and `Notification`'s `notification_type` (which includes `agent_completed`)
      are the candidates. This is the case the whole design exists for.
- [ ] **Around thirty hook events exist and the plugin uses seven.** Names read
      from the documentation today; no payload verified beyond the ones in use.
      Several open threads here are probably one event away.
- [ ] **The cue lead-in is audible as a slow swell**, since 0.01 amplitude is not
      inaudible on headphones, and the 1.1 s cue also widened the window where a
      tone can land on top of speech from 0.2 s to over a second. Both belong to
      the same piece of work. Next to try: a lead-in of digital silence, on the
      theory that the link wakes when the stream opens rather than because of what
      is in it; then 0.0008 amplitude. Then split the cue in two so the loop can
      re-check for speech between the lead-in and the beep. Deferred on the user's
      decision, since it is audible now, which it was not before.
- [ ] **The `submitted` cue has no lead-in**, and by the same Bluetooth argument it
      should. Left alone because it is heard every time, and because it plays
      synchronously before the silencing (B10): a lead-in would leave the previous
      turn talking almost a second longer after Enter.
- [ ] **Speech may be losing its first word to the same cause.** Untested. A long
      utterance survives a sleeping link by sacrificing its opening, which sounds
      like a clipped word rather than a fault. One deliberate listen after a long
      silence would settle it.
- [ ] **An unreadable config is read as speech being switched off.** `load_config`
      returns `{}` on any failure and `main` then exits. Seen live today: a config
      rewritten from a hook was read while empty, so the daemon shut down and the
      next utterance paid for a model reload. Keep the last good config instead,
      and write the file through a temporary and a rename.
- [ ] **Escape silencing is gated on the `working` setting**, because it lives in
      the only process that already reads the transcript, and that loop runs only
      while `working.flag` exists. Both are on by default. A watcher of its own
      would fix it and has not earned the machinery yet. The 2 s poll is also a
      long time to hear a question you have dismissed.
- [ ] **Two approval dialogs at once has never been verified**, and
      `Clear-PendingKind 'p'` now silences the retired question's speech on the
      assumption that it cannot happen. The log line `retired pending <key> after
      <n> ms` is there to catch it: two retirements a second apart is the shape.
- [ ] **Two concurrent identical calls share one signature.** `Get-CallSignature`
      is the tool name plus a hash of `tool_input`, so two parallel calls with
      identical input collapse and the first to finish silences the second's
      question. Narrow. The fix is a side channel from `PreToolUse`, which owns
      the id, to `PermissionRequest`, which does not.
- [ ] **Mathematics is unlistenable.** Piper has no notion of notation, so LaTeX
      arrives as symbol names. Fix it in `ConvertTo-Speakable`, which already
      rewrites markdown, for the few dozen constructs that turn up in prose:
      fraction a over b, x squared, alpha. Scope it before writing.
- [ ] **Concurrent sessions are documented, not fixed.** Two sessions sharing a
      data root share `transcript.path`, `working.flag` and `waiting.flag`, and
      each prompt sweeps the other's markers. `/clear` now joins that family and
      says so in the file. The fix is the same for all of it: key by `session_id`.
- [ ] **One speaking session at a time, chosen by an owner token.** Wanted
      feature, and the cheaper half of the thread above. Nothing separates
      sessions today: one data root, one queue, one daemon, and a queue item is
      only `<prefix>-<ticks>-<guid>.txt`, so every session speaks into the same
      ear. `state/<session>.txt` is the only keyed state there is, and it stops a
      repeat within a session, not another session. The shape: `tts-prompt.ps1`
      writes an owner token on every prompt, the other six hooks return early
      unless they match, and the session you last typed into is the one that
      talks. Roughly six guard lines, one helper pair in `tts-common.ps1`, and a
      hand-over that is mostly a rewrite of the sweep the prompt hook already
      does. `piper-daemon.py` is untouched. Four things to settle first: the guard
      goes before any state change and not in front of `Submit-Speech`; no token
      or no `session_id` must mean speak, since silence means "you are up";
      `/clear` arrives as a new session, so the token needs `cwd` as well; and
      `work-loop.ps1`'s marker logic needs reading rather than assuming. Design
      and the two rejected alternatives are in `sessionslog/2026-08-13.md`.
- [ ] **Delete `~/.claude/hooks/tts.retired-2026-08-12`** when satisfied, plus the
      two `.pre-plugin-test.bak` files, and the now unused `0.1.0` plugin cache.
- [ ] **Rename the local folder** from `read-aload` to `claude-code-read-aloud`.
      The GitHub repository is already renamed. It cannot be done from inside a
      running session, and the `.code-workspace` file can go with it.
- [ ] **Ownership left as it is.** The repository sits under the work account
      `DIs-LaudrupAnalytics`. Transferring later stays cheap: GitHub keeps
      redirects.

## Senest

13 August 2026: no code changed. Read how sessions share one voice, and settled
on the owner token as the shape of the fix when it gets built. See
`sessionslog/2026-08-13.md`; the 0.2.0 work the day before is in
`sessionslog/2026-08-12.md`.
