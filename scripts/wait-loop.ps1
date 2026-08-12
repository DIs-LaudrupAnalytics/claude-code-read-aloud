# A gentle repeating tone for as long as something is waiting on you.
#
# Background: there is no "the user approved" event in Claude Code. A single
# tone could therefore only be placed at the tool's COMPLETION, which is seconds
# after you pressed yes, so it does not feel like an answer to anything. The fix
# is to invert it: the tone means "something is pending", and the message is the
# tone STOPPING. Silence is impossible to miss.
#
# The loop owns nothing. It reads waiting.flag between tones and stops when the
# file is gone, so any other hook can end it simply by deleting the file,
# without knowing anything about this process.
#
# Started hidden by wait-loop.vbs. Keep this file pure ASCII.
$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'tts-common.ps1')
$root = $script:TtsData   # flags, queue and markers belong to the data

$flag = Join-Path $root 'waiting.flag'
try {
    $cfg = Get-TtsConfig
    if (-not $cfg -or -not $cfg.enabled) { exit 0 }
    if (-not [bool](Get-TtsField $cfg 'cues' $true)) { exit 0 }
    if (-not [bool](Get-TtsField $cfg 'waitTone' $true)) { exit 0 }

    $interval = [int](Get-TtsField $cfg 'waitIntervalMs' 3000)
    $maxMs    = [int](Get-TtsField $cfg 'waitMaxMs' 120000)
    # The floor is the length of the cue plus a little air. It used to be 500 ms,
    # which the cue itself now exceeds: with a 1.1 s tone and a 250 ms minimum
    # rest, anything under about 1350 ms could not be honoured, so the setting
    # quietly stopped meaning what it said at the bottom of its own range.
    if ($interval -lt 1500) { $interval = 1500 }

    # The ceiling is a safety line, not an expectation: if a hook stalls without
    # clearing the marker, the tone must die by itself rather than run until the
    # machine is switched off.
    #
    # Start and end are logged with a tone count. The tones themselves are not,
    # since they would flood the log, but without those two lines you cannot
    # tell "the loop never started" from "it started and was stopped at once".
    #
    # The ownership token: the marker's contents as they were when WE started.
    # If they are swapped out, a newer loop has taken over and this one must
    # stop immediately.
    #
    # Reading it can legitimately fail. The approval may already have been
    # answered by the time this process finishes starting, in which case the
    # marker is gone and there is simply nothing to do. That is a normal race,
    # not a fault, so it must not be logged as one.
    $mine = $null
    try { $mine = [System.IO.File]::ReadAllText($flag) } catch {}
    if (-not $mine) { Write-TtsLog 'waiting tone: marker already gone, nothing to do'; exit 0 }

    $speaking = Join-Path $root 'speaking.flag'
    $qdir     = Join-Path $root 'queue'

    function Test-Talking {
        # Either speech is happening, or something is queued waiting to be said.
        # Both count: otherwise the tone would slip into the gap between two
        # queue items.
        if (Test-Path -LiteralPath $speaking) { return $true }
        return @(Get-ChildItem -LiteralPath $qdir -Filter '*.txt' -ErrorAction SilentlyContinue).Count -gt 0
    }

    function Test-Mine {
        if (-not (Test-Path -LiteralPath $flag)) { return $false }
        try { return ([System.IO.File]::ReadAllText($flag) -eq $mine) } catch { return $false }
    }

    Write-TtsLog 'waiting tone: start'

    # PHASE 1 - let the question be read to the end.
    # Both the question itself and the description of the command are spoken
    # just after this loop starts. The tone must not sound on top of them, and
    # it certainly must not take them for "speech has resumed" and shut itself
    # down before you have even heard what is being asked.
    # Real elapsed time, not the sum of the sleeps. The cue itself now lasts 1.1 s
    # because of the Bluetooth wake-up lead-in, and counting only the sleeps put
    # the ceiling out by more than a third: 120 s of setting ran for about 164 s
    # of tones.
    $started = [datetime]::Now
    $spent = 0
    while ($spent -lt $maxMs) {
        Start-Sleep -Milliseconds 250
        $spent = [int](([datetime]::Now - $started).TotalMilliseconds)
        if (-not (Test-Mine)) { break }
        if (-not (Test-Talking)) { break }
    }

    # PHASE 2 - a gentle tone in the silence, until speech resumes.
    # Speech resuming means, in practice, that you have answered and the work
    # has continued. The tone is then done for this time and does not come back.
    $n = 0
    $why = 'marker cleared'
    while ($spent -lt $maxMs) {
        if (-not (Test-Mine)) { $why = 'marker cleared'; break }
        if (Test-Talking)     { $why = 'speech resumed'; break }
        # The cue plays synchronously and is no longer short, so its own length
        # comes out of the interval rather than being added to it. Otherwise
        # waitIntervalMs of 3000 produced a tone every 4.1 s, and the setting
        # stopped meaning what it says.
        $t0 = [datetime]::Now
        Play-Cue 'waiting' -Quiet
        $n++
        $rest = $interval - [int](([datetime]::Now - $t0).TotalMilliseconds)
        if ($rest -lt 250) { $rest = 250 }
        Start-Sleep -Milliseconds $rest
        $spent = [int](([datetime]::Now - $started).TotalMilliseconds)
    }
    if ($spent -ge $maxMs) { $why = 'time ceiling' }
    Write-TtsLog "waiting tone: done after $n tones ($why)"
} catch {
    Write-TtsLog ('wait-loop FAILED: ' + $_.Exception.Message)
}

# Clean up only after OURSELVES. If we stopped because a newer loop took over,
# the marker now belongs to that one, and deleting it would kill it. Otherwise
# it has to go, including when we stopped on time, so the next waiting tone can
# start.
try {
    if ((Test-Path -LiteralPath $flag) -and ([System.IO.File]::ReadAllText($flag) -eq $mine)) {
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    }
} catch {}
exit 0
