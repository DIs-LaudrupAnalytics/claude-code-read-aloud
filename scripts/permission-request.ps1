# PermissionRequest hook: say immediately that you are being waited on.
#
# This is the whole point of the file: the Notification event arrives TOO LATE.
# Measured across 120 permission requests in tts.log it lands 6.8 to 9.6 seconds
# after PreToolUse, and the floor of 6.79 s is so sharp that it must be a
# built-in delay in Claude Code rather than something we can tune. The approval
# dialog is on screen immediately, so during those seconds the user sat in
# silence, not knowing they were the one holding things up.
#
# PermissionRequest fires the moment a tool call requires a decision, which is
# before the dialog is shown. Measured afterwards: 0.86 and 0.93 seconds from
# PreToolUse. Same work as notify-permission.ps1, without the wait.
#
# The hook makes NO decision. It must write nothing to stdout and exit 0; the
# normal approval flow then applies unchanged. Writing anything that is not
# valid JSON produces a non-blocking error in Claude Code. Note that exit 2
# means nothing for this event: denial happens only through a decision object,
# and we do not touch that.
#
# announced.flag tells the later Notification that the question has already been
# spoken, so it is not read out twice. See notify-permission.ps1.
#
# Must always exit 0 and write nothing. Keep this file pure ASCII.
$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'tts-common.ps1')
$root = $script:TtsData   # the flags belong to the data, not to the program

try {
    $cfg = Get-TtsConfig
    if (-not $cfg -or -not $cfg.enabled) { exit 0 }

    $filter = [string](Get-TtsField $cfg 'notifyFilter' 'permission')
    if ($filter -eq 'off') { exit 0 }

    $raw = [Console]::In.ReadToEnd()
    $tool = ''
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try { $tool = [string]($raw | ConvertFrom-Json).tool_name } catch {}
    }

    # The tool name is read aloud, so keep it in human language. MCP tools are
    # called mcp__server__action, and the double underscores sound like nothing.
    if ($tool) {
        $tool = $tool -replace '^mcp__', '' -replace '__', ' '
    }

    # The sentence is kept WORD FOR WORD identical from one time to the next.
    # Short messages are cached as finished audio, and with only a handful of
    # tool names the cache fills after a few approvals, after which the question
    # plays with no delay at all.
    $text = if ($tool) { 'Claude needs your permission to use ' + $tool + '.' }
            else       { 'Claude needs your permission.' }

    # The waiting tone first: it will not sound until the speech falls quiet
    # anyway.
    Start-Waiting

    # Remember that we asked, so PostToolUse can acknowledge once permission has
    # been granted.
    try { [System.IO.File]::WriteAllText((Join-Path $root 'pending.flag'), 'x') } catch {}

    # And remember that the question has been spoken, so Notification can stay
    # quiet.
    try { [System.IO.File]::WriteAllText((Join-Path $root 'announced.flag'), 'x') } catch {}

    Submit-Speech $text -Priority

    # The question is now queued as '0-'. Release the held tool announcement: it
    # becomes '1-' and therefore sorts BEHIND the question. The order is decided
    # by the sort, not by a time window.
    #
    # Note how much cheaper holdMs became as a result. The announcement used to
    # be held for over seven seconds to wait for Notification; now it is
    # released after half of one.
    Release-HeldSpeech
} catch {
    Write-TtsLog ('permissionrequest FAILED: ' + $_.Exception.Message)
}
exit 0
