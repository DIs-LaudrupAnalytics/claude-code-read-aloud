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
    $callId = ''
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try {
            $payload = $raw | ConvertFrom-Json
            $tool   = [string]$payload.tool_name
            # PreToolUse and PostToolUse are documented to carry a tool_use_id.
            # For this event the documentation is silent, so treat it as
            # optional and say so in the log when it is missing: with the id we
            # can pair the answer with exactly this call, and without it the
            # tool name is the next best key, which still separates a Read
            # finishing from a Bash waiting for approval.
            $callId = [string]$payload.tool_use_id
        } catch {}
    }

    # Keep the name as it came in for the pending key. PostToolUse compares
    # against the raw tool_name, and the rewriting just below is for the ear
    # only.
    $toolKey = $tool

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
    # been granted. One entry per call: a single flag was cleared by whichever
    # tool happened to finish first, which stopped the waiting tone while the
    # question was still open.
    #
    # The previous approval is retired first. Claude Code asks about one call at
    # a time, so anything still marked pending here has already been answered or
    # denied, and a DENIED call never reaches PostToolUse. Left behind, its entry
    # would make the next Stop-Waiting believe something was still open and the
    # tone would go on sounding while Claude worked. Only approvals are cleared;
    # an AskUserQuestion may legitimately still be open.
    Clear-PendingKind 'p'
    if ($callId) {
        Add-Pending ('p-' + $callId)
    } else {
        # Logged, not silent. This is the weaker path: another call of the same
        # tool can clear the entry, and the held announcement is left to holdMs
        # instead of being released here. If this line never appears in your
        # log, the event carries an id and none of that applies.
        Write-TtsLog ('permission event carried no tool_use_id; keying on the tool name: ' + $toolKey)
        Add-Pending ('p-' + $toolKey)
    }

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
    #
    # Only OUR OWN announcement. Releasing every held item is not safe just
    # because our question is already in front of them: with two calls announced
    # in the same batch, the second one's description would be freed before
    # Claude Code had decided whether to ask about IT, and its question would
    # then arrive after its own description. Without an id we release nothing
    # and let holdMs do it, which costs a second or so and cannot get the order
    # wrong.
    if ($callId) { Release-HeldSpeech $callId }
} catch {
    Write-TtsLog ('permissionrequest FAILED: ' + $_.Exception.Message)
}
exit 0
