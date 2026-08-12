# read-aloud

A Claude Code plugin that lets you run a session without looking at the screen.
It speaks Claude's answers, the narration along the way, and the questions
Claude needs you to answer, using a Piper voice that runs locally on your
machine.

This exists because its author was told to minimise screen time after a head
injury. That framing matters more than it might sound, because it decides what
the plugin bothers with. Reading the final answer aloud is the easy part and
plenty of projects already do it. The hard part is everything in between: the
long silences while tools run, the moment a command needs your approval, the
multiple-choice question you cannot answer if you cannot see the options. Those
are the states where a screen tells you something and speech, by default, tells
you nothing.

The guiding rule is that silence means "you are up" and speech means "I am
working". Everything below follows from that.

It is Windows only, and it has been tested by one person on one machine. Please
read the requirements before installing.

## Requirements (read this first)

- **Windows.** The hooks are PowerShell and VBScript, and the daemon uses
  `winsound` and `msvcrt`. There is no macOS or Linux path, and adding one would
  be a rewrite rather than a port.
- **Python 3** on `PATH`, with the `piper-tts` package installed. Developed
  against Python 3.12.
- **A Piper voice model.** Not bundled: a voice is a few hundred megabytes. One
  is downloaded during installation, see below.
- **Claude Code 2.1 or newer** for the `PermissionRequest` hook event. Older
  versions still work, but approvals are announced seven to nine seconds later
  through `Notification` instead. Developed against 2.1.220.
- **Optional: Windows Voice Access**, if you also want to dictate rather than
  type. The plugin does no speech recognition of its own, deliberately, and
  pairs with whatever dictation you already use.

If any of this is missing, the plugin does nothing to your session. Every hook
exits cleanly, writes nothing to standard output, and swallows its own errors.
A missing voice model means you get silence and a line in the log, not a broken
session and not a blocked tool call.

## Install

```
/plugin marketplace add DIs-LaudrupAnalytics/claude-code-read-aloud
/plugin install read-aloud@read-aloud-tools
```

Then send one prompt in Claude Code. Nothing will be spoken yet, but the plugin
creates its data directory and writes the path to it into
`%USERPROFILE%\.claude\read-aloud\data.path`.

Read that file, and download a voice into the `voices` directory inside the path
it names:

```
pip install piper-tts
type "%USERPROFILE%\.claude\read-aloud\data.path"
python -m piper.download_voices en_US-lessac-medium --data-dir "<that path>\voices"
```

Do not guess the directory. `--data-dir` creates whatever you point it at, so a
wrong path downloads sixty megabytes somewhere the plugin never looks, and the
only symptom is silence plus one line in `tts.log`. The data directory is
deliberately separate from the plugin so that updates do not discard the model.

Finally, switch it on:

```
/read-aloud:read-aloud on
```

### Upgrading from a manual install

If you already run these scripts with the six hooks registered by hand, remove
those entries from your `settings.json` before enabling the plugin. Otherwise
both copies fire on every event, against the same data directory: you get
doubled speech and two daemons competing for the same queue.

### Manual install

If you would rather not use a plugin, clone the repository anywhere and copy the
`hooks` block from `hooks/hooks.json` into your `settings.json`, replacing
`${CLAUDE_PLUGIN_ROOT}` with the path to the clone. Copy
`skills/read-aloud/SKILL.md` to `~/.claude/commands/read-aloud.md` if you want
the slash command. The scripts fall back to
`%USERPROFILE%\.claude\read-aloud\data` when they are not running as a plugin,
so the voice model goes in the `voices` directory there.

## Turning it off

Three ways, in order of how useful they are when you are not looking at the
screen:

- **Ctrl+Alt+H**, or any keyboard shortcut you bind to
  `%USERPROFILE%\.claude\read-aloud\hush.vbs`. Stops the current utterance and
  clears the queue, leaving speech switched on for the next reply.
- A **Voice Access phrase**. The author uses "silent", pointed at the same file.
- `/read-aloud:read-aloud off` to switch it off entirely.

Typing any new prompt also stops whatever is being said, since the old answer is
rarely what you still want to hear.

The hush script is deliberately VBScript and not PowerShell. PowerShell takes
about half a second to start, and that is half a second of the voice carrying
on. Everything hush does is file operations, so it does them itself.

## What gets spoken

- **The final answer**, with the markdown stripped out. Headings, bullets, code
  fences, tables and link targets are removed, because they sound like nothing.
- **The narration in between**, the text Claude writes before each tool call.
  This is what turns a long silent stretch into something you can follow.
- **Which tool is running**, briefly. "Reading plot_utils.py", or the short
  description that comes with a shell command. The command itself is never read
  aloud: commands are full of paths and punctuation and they are miserable to
  listen to.
- **Questions with options**, in full. This is the one exception to the rule
  that tool calls are only announced, and it is the one that makes eyes-free
  work possible. The options are numbered in words, because a digit disappears
  inside a spoken sentence, and `Other` is named at the end because it is easy
  to miss when you only hear a list.
- **Approval requests**, as soon as they happen.
- **A status message** when Claude works in silence for a while, escalating from
  "Thinking" to "Still working on it", and reporting elapsed time when a tool is
  the thing taking a while.

## The waiting tone

There is no "the user approved" event in Claude Code, so a single tone could
only ever be placed at the completion of a tool, seconds after you pressed yes.
That does not feel like an answer to anything.

So it is inverted. A gentle tone repeats while something is pending, and the
message is the tone **stopping**. Silence is impossible to miss, and it needs no
interpretation. It starts once the question has been read out, never on top of
it, and it ends the moment speech resumes, which in practice is the moment you
answered.

That is the only tone in the approval sequence. There is one other sound, two
falling notes, confirming that a prompt you typed or dictated was actually sent.

## Timing: why the permission announcement is fast

Most of the design here is ordinary. This part is the measurement worth
publishing.

The obvious place to announce an approval request is the `Notification` hook.
Measured across 120 approvals in this plugin's own log, `Notification` fires
between 6.8 and 9.6 seconds after `PreToolUse`, with a floor of 6.79 seconds so
sharp that it looks like a built-in delay rather than anything tunable. The
approval dialog is on screen immediately, so for those seconds a listener sits
in silence with no idea they are the one holding things up.

`PermissionRequest` fires the moment a call requires a decision, before the
dialog appears. Measured on the same machine: 0.86 and 0.93 seconds. That is the
difference between usable and not, and it is why the plugin needs a recent
Claude Code. `Notification` is kept as a fallback, and a marker file stops the
same question being read twice.

There is a second ordering problem hiding behind that one. `PreToolUse` fires
before Claude Code has decided whether to ask for approval at all, so the
description of the command would always be spoken before the question. The fix
is not a timer. The tool announcement is queued with a prefix that holds it, and
when the approval arrives it is queued ahead and the announcement is renamed to
sort behind it. Ordering comes from the sort, not from winning a race. An
earlier version did use a timer, and it lost.

## The language split

If you work in a language your voice model does not read well, the plugin can
separate the two. With `switchLanguage` on, the terminal reply is written in
`spokenLanguage` so it sounds natural, while everything written to disk stays in
`writtenLanguage`: file contents, comments, docstrings, chart labels, commit
messages. The author dictates in English through Voice Access, listens in
English, and keeps his files in Danish.

This is done by injecting a directive on every prompt, so a change takes effect
immediately. There is deliberately no language key in `settings.json`, because
two sources of truth would eventually disagree.

## Privacy

Piper runs entirely on your machine. No conversation content is sent anywhere,
and the plugin makes no network requests at all once the voice model has been
downloaded.

## Configuration

Everything is in `tts-config.json` in the data directory. The `/read-aloud`
skill edits it in plain language, which is the point: you can change the voice,
the speed or how much gets narrated without reading a settings file. Run it with
no argument for a spoken summary of the current state.

The settings are documented in `skills/read-aloud/SKILL.md`.

## What has and has not been tested

This is new software. It was built over a couple of days of continuous use, and
the measurements quoted above come from a log covering roughly twelve hours.
Nothing here has had time to age.

Tested: Windows 11, Claude Code 2.1.220, Python 3.12, the
`en_US-lessac-medium` voice, one machine, one user.

Not tested: any other operating system, any other Python version, Windows
PowerShell versions other than 5.1, other Piper voices beyond brief trials, and
installation by anybody other than the author. The manual install path has had
less use than the plugin path.

**One session at a time.** Two Claude Code sessions sharing a data directory
also share the files that say which transcript is current and whether something
is waiting on you, so the narration follows whichever session spoke last.
Nothing breaks and no tool call is affected, but the running commentary will be
confusing. Give a second session its own `CLAUDE_TTS_DATA` if you need both
talking. See `docs/architecture.md` for what it would take to fix properly.

If you try it and it breaks, an issue with the contents of `tts.log` from your
data directory is genuinely useful.

## Layout

```
.claude-plugin/     plugin.json and marketplace.json
hooks/hooks.json    the six hook registrations
scripts/            the hooks, the two background loops, the Piper daemon
cues/               the two pre-rendered tones
defaults/           the config installed on first run
skills/read-aloud/  the /read-aloud skill
docs/               architecture notes
```

The data directory, created on first run, holds the config, the queue, the
synthesis cache, the voice models, the log and the flag files. It is kept
separate from the plugin directory because the latter is replaced on every
update.

## Prior art

[`jvosloo/claude-voice`](https://github.com/jvosloo/claude-voice) is the closest
neighbour: it pairs Whisper for input with Piper for output and also
distinguishes permission prompts from question prompts. It is built for macOS.
If you are on a Mac, start there.

[`moto-pu/claude-code-voicevox-notify`](https://github.com/moto-pu/claude-code-voicevox-notify)
covers voice notifications on WSL2 plus Windows for completion and
input-waiting states.

Text-to-speech output for Claude Code is a well-populated category. Most of it
reads the final response after a `Stop` hook, which is a different problem from
narrating and signalling the interactive pauses.

## License

MIT. See [LICENSE](LICENSE).
