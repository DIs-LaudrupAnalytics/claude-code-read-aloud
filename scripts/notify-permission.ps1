# Notification hook: say out loud when Claude is waiting for you.
#
# Claude Code sends this event when a command needs your approval, among other
# things. Without sound you can sit waiting for nothing while the terminal is
# still behind another window.
#
# This is now a FALLBACK. permission-request.ps1 does the same job seven to nine
# seconds earlier, so this file only covers notifications that are not tool
# approvals (notifyFilter 'all') and Claude Code versions without the
# PermissionRequest event.
#
# The command itself is not read aloud, only the message that you are being
# waited on. That is deliberate: commands are long, full of paths and
# punctuation, and they sound terrible spelled out.
#
# notifyFilter in tts-config.json:
#   'permission' (default) - only messages about approval
#   'all'                  - every notification, including "waiting for input"
#   'off'                  - none
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
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $payload = $raw | ConvertFrom-Json
    $msg = [string]$payload.message
    if ([string]::IsNullOrWhiteSpace($msg)) { exit 0 }

    $isPermission = $msg -match '(?i)permission|approve|allow|confirm'
    if ($filter -ne 'all' -and -not $isPermission) { exit 0 }

    # If the question was already spoken by permission-request.ps1, which fires
    # the moment approval is required, it must not be read again here seven to
    # nine seconds later.
    #
    # The marker is used ONCE and removed immediately, so a stranded marker, for
    # example after a denied call where no Notification ever arrived, does not
    # swallow the next approval.
    if ($isPermission) {
        $said = Join-Path $root 'announced.flag'
        if (Test-Path -LiteralPath $said) {
            $age = ((Get-Date) - (Get-Item -LiteralPath $said).LastWriteTime).TotalSeconds
            Remove-Item -LiteralPath $said -Force -ErrorAction SilentlyContinue
            if ($age -lt 120) { Start-Waiting; exit 0 }
        }
    }

    # No tone here. There used to be a rising three-note figure at this point,
    # but it said the same thing as the sentence read out a moment later, and it
    # lay on top of it. There is now only ONE tone in the approval sequence: the
    # gentle repeating one, which starts once the question has been read and
    # stops the moment speech resumes. Silence means "it is your turn".
    Start-Waiting

    # Remember that we asked, so PostToolUse can acknowledge once permission has
    # been granted.
    if ($isPermission) {
        try { [System.IO.File]::WriteAllText((Join-Path $root 'pending.flag'), 'x') } catch {}
    }

    $text = ConvertTo-Speakable $msg
    if (-not $text) { exit 0 }
    if ($text -notmatch '[.!?]$') { $text = $text + '.' }

    Submit-Speech $text -Priority

    # The question is now queued as '0-'. Release the held tool announcement
    # straight away: it becomes '1-' and therefore sorts BEHIND the question.
    # The order is settled by the sort, not by a time window.
    #
    # Without this the order depended on holdMs being longer than the sum of
    # Claude Code's own delay (7.1 s), PowerShell startup (0.37 s) and the tone
    # (0.48 s). You lose that kind of race sooner or later, and we did: the
    # description slipped out through the gap.
    Release-HeldSpeech
} catch {
    Write-TtsLog ('notify FAILED: ' + $_.Exception.Message)
}
exit 0
