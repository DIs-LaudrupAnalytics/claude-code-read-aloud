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
if ($cfgWarm -and $cfgWarm.enabled -and (Test-PiperReady $cfgWarm)) { Start-PiperDaemon }

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
$speaking = $false
$switch   = $true
$spoken   = 'English'
$written  = 'English'
try {
    $cfgPath = Join-Path $root 'tts-config.json'
    if (Test-Path -LiteralPath $cfgPath) {
        $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $names = $cfg.PSObject.Properties.Name
        if ($names -contains 'enabled')        { $speaking = [bool]$cfg.enabled }
        if ($names -contains 'switchLanguage') { $switch   = [bool]$cfg.switchLanguage }
        if ($names -contains 'spokenLanguage') { $spoken   = [string]$cfg.spokenLanguage }
        if ($names -contains 'writtenLanguage'){ $written  = [string]$cfg.writtenLanguage }
    }
} catch {}

# The language split is the reason this hook injects context at all. A voice
# model reads one language well and everything else badly, but the language you
# want in your files is a separate question from the language you want in your
# ears. With switchLanguage on, the terminal reply follows the voice while
# anything written to disk keeps its own language.
#
# Note that there is no 'language' key in settings.json. The language is decided
# here and nowhere else, which is why a change takes effect immediately with no
# restart. Do not add a settings key for it: the two would contradict each other.
if ($speaking -and $switch) {
    $ctx = "Voice output is ON: your reply is read aloud by a $spoken text-to-speech voice. " +
           "Write the conversational reply in the terminal in $spoken, so it is spoken naturally. " +
           "Everything you write to disk stays in ${written}: file contents, code comments and docstrings, " +
           "chart titles, axis labels and annotations, CSV headers, markdown documents, and commit messages. " +
           "Use correct $written orthography including all diacritics in everything written to disk. " +
           "Leave code identifiers, file paths and technical terms unchanged. " +
           "Prefer flowing prose over dense tables and long code blocks in the terminal reply, since it is heard rather than read."
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
