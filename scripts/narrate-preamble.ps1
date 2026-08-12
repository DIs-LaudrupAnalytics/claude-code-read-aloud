# PreToolUse hook: say what is happening, while it happens.
#
# The Stop hook only reads the final answer. Everything in between, the running
# commentary and which tool is being used, was silent. This hook fills that
# silence so you can follow along without looking at the screen.
#
# Two parts, each with its own switch in tts-config.json:
#   narrate        true/false   the text written before a call
#   announceTools  true/false   which tool is being run
#
# The command itself is never read aloud; only the short description that comes
# with it.
#
# There used to be a third switch, 'thinking', which read Claude's reasoning
# aloud. It has been removed. The transcript stores every thinking block as
# {type, thinking, signature} with 'thinking' always empty, checked across 34
# blocks in one session, so the feature could never do anything. The state is
# reported instead by work-loop.ps1, which is what you actually want to hear.
#
# The transcript stores text, thinking and tool calls as SEPARATE entries. That
# is why the whole current round is collected, from the last user entry onwards,
# rather than looking only at the newest entry.
#
# Double reading is prevented by a per-session watermark: one answer can trigger
# several calls, and then this hook fires several times for the same content.
#
# Must always exit 0 and write nothing. Keep this file pure ASCII.
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'tts-common.ps1')

try {
    $cfg = Get-TtsConfig
    if (-not $cfg -or -not $cfg.enabled) { exit 0 }

    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $payload = $raw | ConvertFrom-Json
    $tp = $payload.transcript_path
    if (-not $tp) { exit 0 }
    $tp = $tp -replace '/', '\'
    if (-not (Test-Path -LiteralPath $tp)) { exit 0 }
    $session = [string]$payload.session_id

    $wantNarrate  = [bool](Get-TtsField $cfg 'narrate' $true)
    $wantTools    = [bool](Get-TtsField $cfg 'announceTools' $true)

    # --- collect the current round, in the order it was written -------------
    # Only the tail is read. The loop below walks backwards and stops at the
    # user entry, so everything before that is never looked at, and loading a
    # multi-megabyte transcript on every tool call was pushing this hook towards
    # its 10 second timeout. If the window does not reach back to the prompt,
    # the extra entries are caught by the per-uuid watermark and stay silent.
    $lines = Get-TranscriptTail $tp ([int](Get-TtsField $cfg 'transcriptTailKb' 256) * 1024)
    $round = New-Object System.Collections.Generic.List[object]
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ([string]::IsNullOrWhiteSpace($lines[$i])) { continue }
        $o = $null
        try { $o = $lines[$i] | ConvertFrom-Json } catch { continue }
        if (-not $o -or -not $o.message) { continue }   # meta entries: mode, ai-title, ...
        if ($o.type -eq 'user') {
            # A tool result is ALSO a 'user' entry, and it must not stop us
            # here. If a call was blocked by a guard or denied by the user, this
            # hook never ran for that call, and the narration in front of it
            # then sits behind a result that the next round starts after. It
            # would never be read at all. That is exactly what happened with a
            # blocked sleep command: the text before the call disappeared while
            # the next one was read fine.
            #
            # So we go all the way back to the real prompt. Double reading is
            # already handled by the per-uuid watermark.
            $uc = $o.message.content
            $isToolResult = $false
            if ($uc -is [System.Array]) {
                foreach ($b in $uc) { if ($b.type -eq 'tool_result') { $isToolResult = $true; break } }
            }
            if (-not $isToolResult) { break }
            continue
        }
        if ($o.type -ne 'assistant') { continue }
        if ($o.message.content -isnot [System.Array]) { continue }
        $round.Insert(0, $o)
    }

    $say = New-Object System.Collections.Generic.List[string]

    foreach ($o in $round) {
        $uuid = [string]$o.uuid
        if (Test-AlreadySpoken $session $uuid) { continue }
        $content = $o.message.content

        $texts = @($content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text })

        if ($wantNarrate -and $texts.Count -gt 0) {
            $t = ConvertTo-Speakable ($texts -join "`n")
            if ($t) { $say.Add($t) }
        }

        # Mark the entry as handled even when it only contained a call, so it is
        # not walked again at the next tool in the same answer.
        Register-Spoken $session $uuid
    }

    # The loop has no other route to the transcript: it is started by a hook
    # that does not pass the path along. Without this it cannot detect that you
    # have interrupted.
    try { [System.IO.File]::WriteAllText((Join-Path $script:TtsData 'transcript.path'), $tp) } catch {}

    # Marker for "this call is running now", so the working message can say what
    # is going on instead of just "still thinking".
    Set-RunningMarker $payload

    # AskUserQuestion is the exception to the rule that tool calls are only
    # announced. Here the content IS the message: the question and its options
    # have to be audible so you can answer without reading the screen. The
    # generic announcement ("Using AskUserQuestion.") is skipped, since it would
    # just sit in front of the real content saying nothing.
    $askMode = [string](Get-TtsField $cfg 'askAloud' 'full')
    $isAsk   = ([string]$payload.tool_name -eq 'AskUserQuestion') -and ($askMode -ne 'off')

    $announce = $null
    if ($wantTools -and -not $isAsk) { $announce = Get-ToolAnnouncement $payload }

    if ($say.Count -gt 0) { Submit-Speech ($say -join ' ') }

    if ($isAsk) {
        $qtext = Get-QuestionSpeech $payload $askMode ([int](Get-TtsField $cfg 'askDescChars' 220))
        if ($qtext) {
            # NOT -Priority: the narration just above is the lead-in to the
            # question and has to come first. And not -Hold: no permission
            # request is coming, so there is nothing to overtake.
            Submit-Speech $qtext

            # From here it is your turn. The pending entry makes PostToolUse
            # stop the waiting tone the moment you have answered; without it the
            # tone would only stop the next time something was spoken. It is
            # keyed by tool_use_id, so another tool finishing in the meantime
            # cannot answer on your behalf.
            Add-Pending ('q-' + [string]$payload.tool_use_id)
            Start-Waiting
        }
    }

    # The announcement is sent on its own and HELD. This hook fires before
    # Claude Code decides whether the command needs approval, so without the
    # delay the description of the command would always arrive before the
    # question itself. The daemon lets a '2-' file lie for a moment so the
    # permission request can get in front.
    #
    # It is tagged with tool_use_id so PostToolUse can release this one and only
    # this one. With several calls in flight, releasing them all let another
    # call's description slip out ahead of its own permission question.
    if ($announce) { Submit-Speech $announce -Hold -Tag ([string]$payload.tool_use_id) }
} catch {
    Write-TtsLog ('narrate FAILED: ' + $_.Exception.Message)
}
exit 0
