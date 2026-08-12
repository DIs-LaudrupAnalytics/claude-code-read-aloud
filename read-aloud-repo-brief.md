# Briefing note: publishing the read-aloud setup for Claude Code

## Purpose of this document

This is a framing document, not a specification. It captures the motivation, the rough shape of what exists, and the surrounding landscape of similar projects, so that you (a Claude Code instance running locally with access to the actual scripts, hooks and configuration) can make your own assessment of what is worth documenting, what the feature set actually is, and how the repository should be structured.

Nothing here should be treated as a description of what the code does. It came out of a spoken conversation and reflects the author's recollection rather than the source. Where this note and the code disagree, the code is right. Please read the actual hook scripts, settings files and any supporting tooling before deciding what to write.

## Motivation

The author has been medically advised to minimise screen time following a head injury. The goal of the setup is eyes-free operation of Claude Code: once a session is running in the terminal, it should be possible to work without looking at the screen at all. In practice the remaining screen dependency is confined to getting started (activating voice input, opening the editor, launching the session).

This matters for how the repository is framed. This is an accessibility tool that happens to be convenient, rather than a convenience tool that happens to be accessible. That framing is likely to be the most useful thing about it to other people, and it should probably shape the README, the repository description and any topic tags.

## Rough shape of the setup, as recalled

Input and output are handled by separate tools. Dictation into the terminal is handled by Windows Voice Access. Spoken output is produced by Piper, running locally.

The read-aloud side hooks into Claude Code's notification mechanism rather than scraping the terminal or watching log files. It appears to distinguish between different kinds of pause: when Claude is requesting permission, and when Claude is asking the user to choose between options. The behaviour differs in each case, with the permission text or the available options being read aloud as appropriate. A waiting tone then signals that the session is blocked on user input, and stops once a response is given.

Please verify all of this against the code. In particular, it is worth establishing precisely which hook events are being used, how the branching between cases is actually determined, whether the waiting tone is genuinely tied to the remote-control functionality or something else, and whether there are behaviours in the implementation that this summary omits entirely. There may well be features here that the author has stopped noticing because they simply work.

## Landscape of existing work

A search of the ecosystem suggests the following, which should be checked and updated rather than trusted, since it may be incomplete or out of date.

Text-to-speech output for Claude Code via hooks is a well-populated category. Several projects exist using Piper, Kokoro, edge-tts, ElevenLabs, Deepgram and macOS `say`. Most of them read the final assistant response aloud after a Stop hook, which is a different problem from signalling and narrating interactive pauses.

The closest neighbour appears to be `jvosloo/claude-voice`, which pairs Whisper for input with Piper for output and offers both a short-status-phrase mode and a summarising narration mode. It reportedly distinguishes permission prompts from question prompts. It is built for macOS. This is the project most worth reading directly and crediting as prior art, and the most useful thing to position against.

There is also at least one Windows-adjacent project, `moto-pu/claude-code-voicevox-notify`, which provides voice notifications on WSL2 plus Windows for task completion and input-waiting states, though it appears to be notification-only without narration of the prompt content.

On the platform side, there are open issues against Claude Code requesting built-in read-aloud, bidirectional voice, a hook that fires when the session yields control back to the user, and notification hook support for `AskUserQuestion` events specifically. That last one is worth investigating carefully. If notification hooks genuinely do not fire for `AskUserQuestion`, then whatever mechanism this setup uses to read out multiple-choice options is doing something the platform does not officially expose, and that is both the most technically interesting part of the project and the part most likely to break on upgrade. Determine what is actually happening before making any claim about it publicly, and consider documenting the version it was tested against.

## Suggested angles, subject to your own judgement

The candidate differentiators are the Windows-native pairing with Voice Access rather than a bundled speech-to-text engine, the accessibility motivation, the handling of interactive pauses rather than just final responses, and whatever turns out to be true about the question-prompt handling. Whether all of these hold up is for you to determine from the source.

Be conservative in the claims. It is better to describe accurately what the setup does and let readers judge its novelty than to overstate it against prior art that a reader may know better than the author does.

## What the repository probably needs

At minimum: installation that works for someone who has not built this themselves, a clear statement of prerequisites including the Piper voice models and the Voice Access configuration, the hook registration steps, and an honest statement of what has and has not been tested. Assess for yourself whether an uninstall path, a configuration file, or a toggle for the read-aloud behaviour would be warranted.

Consider also whether any of this is worth contributing upstream as a comment on the existing feature requests, since the author's use case is a concrete accessibility argument for first-class support.

## Working preferences

Avoid em-dashes in any prose written for this repository. Prefer flowing prose to clipped fragments in the README and documentation. Keep the tone plain and non-promotional.
