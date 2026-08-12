# PostToolUse hook: acknowledge when a tool that was waiting for approval has
# finished running.
#
# There is no "permission was just granted" event. The nearest thing is that the
# tool actually ran, and that is also what you want to know: that things are
# moving again. Without this you stand listening for something that never comes,
# when you are not watching the screen.
#
# The acknowledgement is only given if permission was actually requested.
# Otherwise there would be a signal after every single tool call, and then it
# would mean nothing.
#
# Must always exit 0 and write nothing. Keep this file pure ASCII.
$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'tts-common.ps1')

try {
    $cfg = Get-TtsConfig
    if (-not $cfg -or -not $cfg.enabled) { exit 0 }

    # This hook did not use to read its own stdin: there was nothing it needed
    # to know about the call. There is now. The "this call is running" marker is
    # named after tool_use_id, and without reading the payload the markers could
    # not be cleared. They piled up, and the working message counted its elapsed
    # time from the first call of the turn instead of the one actually running.
    $payload = $null
    try {
        $raw = [Console]::In.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($raw)) { $payload = $raw | ConvertFrom-Json }
    } catch {}

    # The tool has run. If permission was never requested, the held announcement
    # should be released now rather than sitting out the window.
    #
    # Only OUR OWN announcement, identified by tool_use_id. Releasing every held
    # item meant that with two calls in flight the first to finish let the
    # second one's description out before Claude Code had decided whether to ask
    # about it, and the question then arrived after its own answer. An item we
    # cannot identify keeps waiting for holdMs, which is what that ceiling is
    # for.
    #
    # The guard is the point: Release-HeldSpeech with an empty tag releases
    # EVERYTHING, so calling it unguarded on a payload without an id would put
    # the old race straight back. Set-RunningMarker defends against a missing id
    # for the same reason.
    $callId = [string]$payload.tool_use_id
    if ($callId) { Release-HeldSpeech $callId }

    # This call is no longer running. If others are, their markers stay, and the
    # working message goes on reporting the oldest of them.
    if ($payload) { Clear-RunningMarker $payload }

    # Was THIS call the one being waited on? Entries are keyed by tool_use_id,
    # prefixed with the kind: 'q-' for a question, 'p-' for an approval. A
    # single flag was cleared by whichever tool finished first, and the tone
    # then stopped while the question was still on screen.
    #
    # 'p-<tool name>' is the fallback for an approval event that carried no id.
    # It is a heuristic and it can be cleared by a different call of the same
    # tool, for instance a second Bash that needed no approval. That is a
    # narrower version of the bug being fixed rather than a cure for it, and it
    # only applies where there is no id to pair on.
    $answered = Remove-Pending @(
        ('q-' + [string]$payload.tool_use_id),
        ('p-' + [string]$payload.tool_use_id),
        ('p-' + [string]$payload.tool_name))
    if (-not $answered) {
        # The Notification fallback cannot key its entry to a call at all, so it
        # uses the shared key. Only reached when nothing of our own matched.
        $answered = Remove-Pending @('p-any')
    }
    if (-not $answered) { exit 0 }

    # Another approval may still be open. Stopping the tone then would remove
    # the one signal saying that something is waiting on you.
    if (Test-AnyPending) { exit 0 }

    # The silence IS the acknowledgement. No tone is played here: the waiting
    # tone stops, and that is heard more clearly than a single short sound in
    # the middle of speech, which in practice just drowned.
    Stop-Waiting
} catch {
    Write-TtsLog ('granted FAILED: ' + $_.Exception.Message)
}
exit 0
