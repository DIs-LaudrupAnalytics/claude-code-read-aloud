# SessionStart hook: fall silent when the user clears the session.
#
# /clear is handled inside Claude Code and submits no prompt, so
# UserPromptSubmit never fires and nothing ever writes the stop flag. By then
# the previous turn's answer is already in the queue as files, and the daemon
# goes on reading it into a context window that no longer contains it. Observed
# in live use: a clear, a fresh session, and the old answer still being spoken
# over the top of it.
#
# This is the same event as B10 in the decision log rather than a new rule. A
# prompt cuts speech off because typing proves the listener has read ahead and
# is done with the previous turn. Clearing the session is that same proof
# arriving by a different key, and the plugin was only ever listening for one of
# them.
#
# Registered with matcher "clear", and the other sources are left out on
# purpose:
#
#   startup, resume, fork   Nothing belonging to THIS session is speaking yet,
#                           so there is nothing here to stop. What may well be
#                           speaking is another session sharing the data root,
#                           and silencing that one is a fault, not a feature.
#                           Opening a second window is far more common than
#                           clearing, so this is where the concurrency problem
#                           described in docs/architecture.md would actually
#                           start hurting.
#                           Note that `clear` carries the same cost, since the
#                           data root is per install and not per session: a
#                           second window speaking will be silenced too. It is
#                           accepted rather than solved, because clearing is a
#                           deliberate act and much rarer than opening a window,
#                           and because the alternative is the fault this hook
#                           exists for. The real fix is the one the whole family
#                           needs, which is keying the flags by session id; see
#                           the note on concurrent sessions in
#                           docs/architecture.md.
#   compact                 Automatic compaction happens by itself in the middle
#                           of a turn. Cutting speech there is the plugin
#                           interrupting itself, which is precisely what B10 is
#                           an exception to rather than a repeal of. A hand
#                           typed /compact carries the same source value and
#                           cannot be told apart from the automatic one, so the
#                           safe reading has to win for both.
#
# Must always exit 0 and write nothing to stdout. SessionStart is one of the
# events whose stdout is injected into Claude's context, so a stray character
# here does not vanish: it becomes part of the conversation. Keep this file pure
# ASCII, since PowerShell 5.1 reads a BOM-less UTF-8 file as ANSI.
$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'tts-common.ps1')

try {
    # Drain stdin whatever happens. Claude Code pipes the payload in and closes
    # the handle, but the guard is for a hand run from a console, where reading
    # an unredirected stdin waits for a key that never comes and the hook hangs
    # until it is killed. The same guard is in tts-prompt.ps1 for the same
    # reason: the repository's own test procedure runs hooks that way.
    $payload = $null
    try {
        $raw = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($raw)) { $payload = $raw | ConvertFrom-Json }
    } catch {}

    # Nothing is provisioned yet, so there is nothing to silence and nothing to
    # log into. Provisioning belongs to UserPromptSubmit, which runs before any
    # speech can exist; doing it here would build a data root for a session that
    # may never say a word.
    if (-not (Test-Path -LiteralPath $script:TtsData)) { exit 0 }

    # Deliberately not conditional on the config being enabled. The job here is
    # to stop sound, and a queue full of speech alongside a config that says
    # enabled is false is exactly the state a moment after somebody switched the
    # voice off. Refusing to silence in that case would be reading the switch
    # backwards.
    Stop-AllSpeech

    # One line per clear, kept as evidence rather than as diagnosis. The
    # documentation says SessionStart fires with source "clear", but this plugin
    # has been wrong before about what the harness emits and when, so the log
    # records what actually arrived. Compare with B6, where the same kind of line
    # settled whether PermissionRequest carries a tool_use_id.
    $src = [string]$payload.source
    if (-not $src) { $src = 'unknown' }
    Write-TtsLog ('session-start silenced: source=' + $src)
} catch {
    Write-TtsLog ('silence-on-clear FAILED: ' + $_.Exception.Message)
}
exit 0
