# Stop hook: read the session transcript, find Claude's final answer, strip the
# markdown and send it to be spoken.
#
# Narration along the way is handled by narrate-preamble.ps1. This hook
# therefore still stops at the first entry containing a tool call: everything
# above that has either been spoken already or belongs to an earlier turn.
#
# Must always exit 0 and write nothing. Keep this file pure ASCII.
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'tts-common.ps1')

try {
    $cfg = Get-TtsConfig
    if (-not $cfg -or -not $cfg.enabled) { exit 0 }

    # The turn is over, so nothing is being thought about any more. This has to
    # happen BEFORE the answer is sent for speaking, or the loop will wedge a
    # "still thinking" in front of the final answer.
    Stop-Working

    # The turn is over, so no tool is running either. A call that was
    # interrupted never reaches its PostToolUse and its marker would be left
    # behind. Since the loop deliberately picks the OLDEST marker, a single
    # stranded file would both report the wrong elapsed time and go on
    # announcing a command that finished long ago.
    Clear-AllRunningMarkers

    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $payload = $raw | ConvertFrom-Json
    $tp = $payload.transcript_path
    if (-not $tp) { exit 0 }
    $tp = $tp -replace '/', '\'
    if (-not (Test-Path -LiteralPath $tp)) { exit 0 }
    $session = [string]$payload.session_id

    # Only the tail is read. The search below runs backwards from the end and
    # stops at the first user entry or tool call, so the rest of the file is
    # dead weight, and on a long session loading all of it took real time inside
    # a hook that is killed after 10 seconds.
    $lines = Get-TranscriptTail $tp ([int](Get-TtsField $cfg 'transcriptTailKb' 256) * 1024)
    $parts = New-Object System.Collections.Generic.List[string]
    $uuids = New-Object System.Collections.Generic.List[string]
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $o = $null
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if (-not $o) { continue }

        # A user entry, whether a real prompt or a tool result, ends the turn.
        if ($o.type -eq 'user') { break }
        if ($o.type -ne 'assistant') { continue }

        $content = $o.message.content
        if ($content -isnot [System.Array]) { continue }

        # A tool call in the entry means everything above it is intermediate
        # work.
        if (($content | Where-Object { $_.type -eq 'tool_use' })) { break }

        $chunk = @($content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text })
        if ($chunk.Count -gt 0) {
            $parts.Insert(0, ($chunk -join "`n"))
            $uuids.Add([string]$o.uuid)
        }
    }
    if ($parts.Count -eq 0) { exit 0 }

    # If the narration hook already read this text, stay quiet.
    $fresh = @($uuids | Where-Object { -not (Test-AlreadySpoken $session $_) })
    if ($fresh.Count -eq 0) { exit 0 }
    foreach ($u in $uuids) { Register-Spoken $session $u }

    $text = ConvertTo-Speakable ($parts -join "`n")
    if (-not $text) { exit 0 }

    Submit-Speech $text
} catch {
    Write-TtsLog ('ERROR: ' + $_.Exception.Message)
}
exit 0
