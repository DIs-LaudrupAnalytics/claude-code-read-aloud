---
description: Turn spoken output on or off, or change the voice, speed, pauses and narration settings. Use when the user asks to read replies aloud, stop the speech, switch voice, or adjust how much is spoken.
---

# read-aloud

Edit the read-aloud configuration file and confirm briefly what changed. Touch
only the fields named in the argument; leave everything else alone.

## Finding the configuration file

The config lives in the data root, not next to the scripts, because the plugin
directory is replaced on every update. Resolve it in this order:

1. Read `%USERPROFILE%\.claude\read-aloud\data.path`. It contains the absolute
   path to the data root, and the config is `tts-config.json` inside it. This
   file is written on every prompt, so it is reliable.
2. If it does not exist, the plugin has not run yet. Fall back to
   `%USERPROFILE%\.claude\read-aloud\data\tts-config.json`.

The scripts referenced below live in the plugin's `scripts/` directory.

## Arguments

An empty argument means `status`. Keywords are English on purpose: the intended
user dictates them with Windows Voice Access while the speech is running.

- `on` — set `enabled` to `true`. Mention that terminal replies will switch to
  `spokenLanguage` if `switchLanguage` is on, while anything written to disk
  stays `writtenLanguage`.
- `off` — set `enabled` to `false`, then stop any speech in progress by running
  `powershell -NoProfile -File "<plugin>/scripts/tts-hush.ps1"`. That also
  empties the queue and lets the daemon shut down.
- `hush` — stop the current utterance but leave `enabled` as `true`, so the next
  reply is spoken normally. Run `wscript "%USERPROFILE%\.claude\read-aloud\hush.vbs"`.

  You rarely need the command. The same script is on **Ctrl+Alt+H** and on the
  Voice Access phrase **"silent"**, and both are faster than typing. Submitting
  any new prompt also stops the speech.
- `status` — show the config in plain words: is it speaking, which voice, which
  language in the terminal, is narration on, are you told about approvals.
- `voices` — list the Piper models actually installed:

  ```
  Get-ChildItem "<data root>\voices\*.onnx" | ForEach-Object { $_.BaseName }
  ```

  More can be fetched with
  `python -m piper.download_voices <name> --data-dir "<data root>\voices"`.
  The catalogue of 173 voices is in `voices.json` at `rhasspy/piper-voices` on
  Hugging Face. Prefer `medium` over `high`: `high` runs only about 1.5 times
  faster than real time and pins a core for the whole utterance, while `medium`
  runs more than ten times faster with almost the same sound.
- `voice <name>` — set `piperModel`. Must match a file in the voices directory.
- `speed <n>` — set `rate`: a multiplier where `1.0` is normal, valid range
  `0.5` to `6.0`. Piper converts it to `length_scale`.
- `pause <sec>` — set `sentencePause`: extra silence between sentences on top of
  what Piper inserts. `0.35` is the default.
- `dashpause <sec>` — set `dashPause`: the same, but at a dash. Also `0.35`. The
  daemon splits on em dash, en dash, and a hyphen surrounded by spaces. If a
  fragment is under 25 characters it is joined to the previous one with a comma
  instead, so short asides do not chop the reading up.
- `itempause <sec>` — set `itemPause`: the gap **between two queue items**,
  default `0.6`. `sentencePause` only applies inside one item; without this the
  question and the description ran straight into each other and sounded like one
  sentence being cut off.
- `wait on` / `wait off` — set `waitTone`: the repeating tone while something is
  pending. `waitIntervalMs` (default 3000) is the spacing, and `waitMaxMs`
  (default 120000) is a ceiling so the tone dies by itself if a hook stalls.
- `hold <ms>` — set `holdMs`: how long a tool announcement is held back at most.
  Default `2500`. The number is **only a safety net**. Ordering is not decided
  by it: both `PermissionRequest` and `PostToolUse` release the announcement
  actively, so the ceiling is only reached when neither happens, which means a
  long-running tool that was never asked about. Set `0` to disable holding.

  Below about 1.5 seconds the description risks escaping ahead of the question.
- `stale <ms>` — set `staleMs`, default `45000`: queue items older than this are
  discarded rather than spoken. If the daemon has been down there is otherwise a
  pile waiting, and speech about something that happened two minutes ago is
  noise on top of the present. `0` disables discarding.

  With one exception: nothing queued from the moment you were asked something is
  discarded, however long it waited, because a question you have not answered is
  still on screen and has not gone out of date. Anything queued before that
  still ages out normally.
- `pendinghold <ms>` — set `pendingHoldMs`, default `1800000`, thirty minutes:
  how long that exception can last. It is a backstop for an approval or a
  question whose record was never cleared, not something to tune for comfort.
  Long on purpose, because it only ever preserves the question and what came
  after it, and someone who steps away for ten minutes should still be told what
  is being asked when they get back.
- `cachefiles <n>` / `cachemb <n>` — set `cacheMaxFiles` (default `300`) and
  `cacheMaxMb` (default `30`): the ceiling on the synthesis cache, pruned oldest
  use first while the queue is idle. Caching assumes short messages repeat word
  for word, and tool announcements do not: each carries its own command
  description, so it is cached once and never read again. Without a ceiling the
  directory simply grows. `0` on either means no limit on that one.
- `tailkb <n>` — set `transcriptTailKb`, default `256`: how much of the end of
  the transcript the hooks read. They search backwards and stop at the last
  prompt, so the rest is never used, and reading a multi-megabyte file on every
  tool call pushes the hook towards the 10 second timeout, where narration dies
  silently. Raise it only if a single turn can exceed it.
- `narrate on` / `narrate off` — set `narrate`. On, the text written along the
  way is also spoken, just before each tool call, not only the final answer.
- `tools on` / `tools off` — set `announceTools`. On, you hear briefly which
  tool is running ("Reading plot_utils.py", or the description that comes with a
  shell command). The command itself is never read aloud. This is the setting
  that fills the long silent stretches where tools run without commentary.
- `ask full|labels|off` — set `askAloud`: reading out the questions Claude asks
  with options (`AskUserQuestion`). `full` reads the question, every option and
  its description; `labels` reads only the question and the option labels; `off`
  disables it.

  This is the **one** kind of tool call where the content itself is spoken.
  Commands are never read out, precisely because they are full of paths and
  punctuation, but a question with options is written for a human, and if you
  are answering without a screen it is exactly what you need to hear.

  Options are numbered in **words**, "option one", not "option 1". Spoken aloud
  a digit vanishes inside the sentence while the word stands out. `Other` is
  mentioned at the end, since it is easy to miss when you only hear the list.

  Afterwards the waiting tone starts, because now it is your turn.
- `askchars <n>` — set `askDescChars`, default `220`: how much of each option
  description is read, trimmed at the nearest sentence end. `0` means no
  trimming.
- `cues on` / `cues off` — set `cues`: the two small tones.

  - **two falling notes** (`submitted`) — your prompt has been sent. It exists
    because otherwise there is no way to know, without looking, whether what you
    typed or dictated actually went anywhere.
  - **a gentle single note, repeated** (`waiting`) — something is waiting on
    you. It waits until the question has been read, repeats every
    `waitIntervalMs` in the silence, and stops the moment speech resumes, which
    in practice is when you have answered. The tone means "you are up"; speech
    means "I am working".

  It is the **shape** that carries the meaning, not the pitch. Keep any tone
  above about 500 Hz and above about 100 ms: laptop speakers reproduce poorly
  below that, and a short low tone is inaudible. The tones are pre-rendered in
  `cues/` and play without synthesis. Regenerate them with `scripts/make-cues.py`
  if you change anything.
- `working on` / `working off` — set `working`: the spoken status message while
  Claude works without saying anything. The terminal shows "Thinking" and later
  "still thinking"; listening, that same state is pure silence, and silence
  otherwise means "you are up" here.

  The wording escalates: `Thinking.` then `Still thinking.` then
  `Still working on it.`, after which the last repeats. If a **tool** is
  running it says what is going on and for how long instead: "Still running the
  command. Forty seconds so far." The time is the real information when
  something drags, and it is rounded coarsely on purpose.

  The message only comes in **silence**. Speech, a queued item, or a pending
  approval all reset the clock. The approval takes precedence: there the state
  is not "I am thinking" but "you are up", and the two must never overlap.
- `workdelay <sec>` — set `workingDelay`: how much silence before the **first**
  message. Default `3000` ms. Under 1 second is rejected.
- `runningdelay <sec>` — set `runningDelay`, default `10000`: the same, but when
  a tool is running. Longer on purpose, since a six second command does not need
  commentary.
- `workinterval <sec>` — set `workingInterval`: the spacing of the messages that
  follow. Default `20000` ms, minimum 3 seconds. `workingMaxMs` (default
  600000) is a ceiling so the loop dies by itself if a turn never ends.
- `notify permission|all|off` — set `notifyFilter`. `permission` speaks up when
  Claude asks for approval, `all` reads every notification including "waiting
  for input", `off` stays quiet.
- `language on` / `language off` — set `switchLanguage`. Off, Claude always
  replies in `writtenLanguage`, even while speaking.
- `spoken <language>` / `written <language>` — set `spokenLanguage` and
  `writtenLanguage`. The split exists so an English voice can read the
  conversation while files, comments and commit messages stay in your own
  language. There is no `language` key in `settings.json`; the language is
  decided by the `UserPromptSubmit` hook alone, which is why a change takes
  effect immediately with no restart.

Edit the JSON file directly and confirm briefly what changed. The confirmation
follows the same language rule as everything else: `writtenLanguage` when speech
is off, `spokenLanguage` in the terminal when it is on.

For how the pieces fit together, see `docs/architecture.md` in the repository.
