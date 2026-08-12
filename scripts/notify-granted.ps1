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
$root = $script:TtsData   # the flags belong to the data, not to the program

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
    Release-HeldSpeech

    # This call is no longer running. If others are, their markers stay, and the
    # working message goes on reporting the oldest of them.
    if ($payload) { Clear-RunningMarker $payload }

    $flag = Join-Path $root 'pending.flag'
    if (-not (Test-Path -LiteralPath $flag)) { exit 0 }
    Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue

    # The silence IS the acknowledgement. No tone is played here: the waiting
    # tone stops, and that is heard more clearly than a single short sound in
    # the middle of speech, which in practice just drowned.
    Stop-Waiting
} catch {
    Write-TtsLog ('granted FAILED: ' + $_.Exception.Message)
}
exit 0
