# UserPromptSubmit hook. Three jobs:
#   1. Cut off any speech still running when the user types again.
#   2. Start the "still thinking" loop, so silence does not get mistaken for
#      "it is your turn".
#   3. Inject the language directive that matches the current state, so the
#      spoken reply is in a language the installed voice can actually read,
#      while everything written to disk stays in the written language.
#
# stdout must be the hook JSON and nothing else. Keep this file pure ASCII:
# PowerShell 5.1 reads a BOM-less UTF-8 script as ANSI.
$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $root 'tts-common.ps1')

# From here $root means the DATA. The scripts live in the program directory, but
# everything we write (config, flags, queue) belongs in the data root.
$root = $script:TtsData

# --- 0. first run: build the data root --------------------------------------
# UserPromptSubmit fires first in any session, so this is where preparation
# belongs. If everything is already in place the call costs nothing.
Initialize-TtsData

# --- 1. acknowledge that the prompt was sent --------------------------------
# When you are not looking at the screen there is no way to know whether what
# you typed or dictated actually went anywhere.
#
# The tone plays BEFORE Stop-AllSpeech. It used to come after, on the theory
# that the silencing would otherwise kill the tone, but it is the other order
# that does that: the stop flag makes the daemon call PlaySound with SND_PURGE,
# which clears playback on the device, including the tone this hook is in the
# middle of playing. With several daemons there was a purge every 50 ms, so the
# tone vanished every time. PlaySync blocks until the tone has finished, so by
# the time the stop flag is written there is nothing left to purge. The price is
# the roughly 0.3 seconds the tone lasts before the previous speech falls quiet.
Play-Cue 'submitted'

# --- 2. silence any running speech ------------------------------------------
# Stop-AllSpeech also empties the queue, so narration from the previous turn
# does not carry on talking after you have typed something new.
Stop-AllSpeech

# --- 2b. warm the daemon up while Claude thinks -----------------------------
# Otherwise the daemon only starts once there is something to say, and then both
# process startup and model loading sit in front of the first word. Here there
# is time to spare: the user has just sent a prompt, and it will be seconds
# before any text arrives. Runs where the daemon is already alive cost nothing,
# because the new process finds the lock and exits without touching anything.
#
# AFTER Stop-AllSpeech, not before: the stop flag is written in there, and a
# daemon that started first would read it as an order to be quiet.
$cfgWarm = Get-TtsConfig
# One answer, used twice: it decides whether to start the daemon here, and
# whether section 3 may tell Claude that a voice is listening. The name is the
# whole condition on purpose, switch included, because -and short circuits and
# this says nothing about an installed voice when speech is simply switched off.
#
# Resolve-PythonExe is part of the question, not an extra. Test-PiperReady only
# proves the model and its sidecar are on disk. The failure recorded as B8 gets
# that far and then finds nothing but a Store alias stub, so without this check
# the directive would announce a voice, ask for prose over tables and switch the
# reply into spokenLanguage while the user hears nothing whatsoever. That is the
# fault this section exists to prevent, one step further down the chain.
#
# It still cannot see everything. A real interpreter without piper-tts installed
# passes here and dies at import in the daemon, and only the log shows it. Short
# of running Python from a hook, which costs seconds on every prompt, that one
# stays out of reach.
$canSpeak = [bool]($cfgWarm -and $cfgWarm.enabled -and (Test-PiperReady $cfgWarm) -and (Resolve-PythonExe))
if ($canSpeak) { Start-PiperDaemon }

# --- 2b2. tell the loops where the transcript is ----------------------------
# The pointer used to be written only by the PreToolUse hook, so in a turn with
# no tool calls it still named the PREVIOUS turn's transcript. In a new session
# that means the working loop watches the wrong file and cannot see that you
# interrupted; in a resumed one there was no pointer at all until the first tool
# ran. Written here it is correct from the first prompt onwards.
#
# Note that this is one file for one data root: two Claude Code sessions running
# side by side share it, and the last prompt wins. See the note on concurrent
# sessions in docs/architecture.md.
# IsInputRedirected is checked first. Claude Code always pipes the payload in
# and closes the handle, but run by hand from a console this would sit and wait
# for a key that is never coming, and the hook would hang until it was killed.
# The repository's own test procedure ran it that way.
try {
    $raw = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $tp = [string]($raw | ConvertFrom-Json).transcript_path
        if ($tp) {
            $tp = $tp -replace '/', '\'
            if (Test-Path -LiteralPath $tp) {
                [System.IO.File]::WriteAllText((Join-Path $root 'transcript.path'), $tp)
            }
        }
    }
} catch {}

# --- 2c. speak up while Claude works ----------------------------------------
# The terminal shows "Thinking", and after a while "still thinking". If you are
# listening instead, that exact state is pure silence, and silence otherwise
# means "it is your turn" here. The loop reports the state at intervals and
# falls quiet the moment something real is said. See work-loop.ps1.
#
# AFTER Stop-AllSpeech, which also clears the working marker: otherwise the new
# loop would be killed in the same breath as it was started.
Start-Working

# --- 3. decide the language directive ---------------------------------------
# Speech is not what the config says on its own: it is the config AND everything
# needed to act on it, which section 2b has already established.
$speaking = $canSpeak

# $cfgWarm, not a second read of the same file. Reading it twice in one hook let
# the two halves describe different configs whenever the file was rewritten in
# between, which the read-aloud skill does and a second session sharing the data
# root can do at any moment.
#
# The fallbacks are the shipped values in defaults/tts-config.json. A key is
# missing only from a config that was hand edited or truncated, since
# Initialize-TtsData writes the defaults whole; landing such a config on the
# shipped default is the least surprising thing available.
$switch  = [bool](Get-TtsField $cfgWarm 'switchLanguage' $false)
$spoken  = [string](Get-TtsField $cfgWarm 'spokenLanguage' 'English')
$written = [string](Get-TtsField $cfgWarm 'writtenLanguage' 'English')

# The language split is the reason this hook injects context at all. A voice
# model reads one language well and everything else badly, but the language you
# want in your files is a separate question from the language you want in your
# ears. With switchLanguage on, the terminal reply follows the voice while
# anything written to disk keeps its own language.
#
# Note that there is no 'language' key in settings.json. The language is decided
# here and nowhere else, which is why a change takes effect immediately with no
# restart. Do not add a settings key for it: the two would contradict each other.

# Three cases, not two. Speech and the language split are separate switches, and
# an earlier version tested them together: with the split off, a speaking session
# fell through to the "voice output is OFF" branch. Two faults at once. It told
# Claude the wrong thing about the state of the session, and it dropped the
# request for flowing prose, so a session that was being read aloud answered with
# an ASCII table. A table is unlistenable, and nothing in the reply explained why
# it had arrived. The prose request belongs to speech being on, not to the split.
$prose = "Prefer flowing prose over dense tables and long code blocks in the terminal reply, since it is heard rather than read."

if ($speaking -and $switch) {
    $ctx = "Voice output is ON: your reply is read aloud by a $spoken text-to-speech voice. " +
           "Write the conversational reply in the terminal in $spoken, so it is spoken naturally. " +
           "Everything you write to disk stays in ${written}: file contents, code comments and docstrings, " +
           "chart titles, axis labels and annotations, CSV headers, markdown documents, and commit messages. " +
           "Use correct $written orthography including all diacritics in everything written to disk. " +
           "Leave code identifiers, file paths and technical terms unchanged. " +
           $prose
} elseif ($speaking) {
    # Split off: one language for everything, and it is writtenLanguage, which is
    # what the skill documents. The voice reads it whether or not the model is a
    # good match for that language, since the alternative is silently overriding
    # a switch the user turned off on purpose.
    $ctx = "Voice output is ON: your reply is read aloud by a text-to-speech voice. " +
           "Write everything in ${written}, both the terminal reply and anything written to disk, " +
           "with correct $written orthography including all diacritics. " +
           "Leave code identifiers, file paths and technical terms unchanged. " +
           $prose
} else {
    $ctx = "Voice output is OFF: reply in $written, with correct $written orthography including all diacritics."
}

$out = @{
    hookSpecificOutput = @{
        hookEventName    = 'UserPromptSubmit'
        additionalContext = $ctx
    }
}
[Console]::Out.Write(($out | ConvertTo-Json -Depth 5 -Compress))
exit 0
