# "Still thinking" - a spoken status message at intervals for as long as Claude
# works without saying anything.
#
# Background: in the terminal you can SEE that something is happening. It says
# "Thinking", and after a while "still thinking". If you are listening instead,
# that same state is pure silence, and silence otherwise means "it is your turn"
# in this system. That confusion is exactly what this loop removes.
#
# The thinking itself CANNOT be read aloud. The transcript stores a thinking
# block as {type, thinking, signature} where 'thinking' is always empty, checked
# across 34 blocks in one session. So we report the state, not the content.
#
# The loop owns nothing. It reads working.flag between rounds and stops when the
# file is gone, so any hook can halt it simply by deleting the file.
#
# Started hidden by work-loop.vbs. Keep this file pure ASCII.
$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'tts-common.ps1')
$root = $script:TtsData   # flags, queue and markers belong to the data

$flag = Join-Path $root 'working.flag'
try {
    $cfg = Get-TtsConfig
    if (-not $cfg -or -not $cfg.enabled) { exit 0 }
    if (-not [bool](Get-TtsField $cfg 'working' $true)) { exit 0 }

    # The settings are read AGAIN while running, not only here at startup.
    #
    # The loop lives for a whole turn, so without this a change would not take
    # effect until the next prompt, which looks exactly like the change not
    # working at all. It cost one misleading test run: the code was fixed, but
    # the running process still had the old version in memory.
    #
    # The SCRIPT itself cannot be swapped out mid-run, since PowerShell reads
    # the file once, so edits to work-loop.ps1 only apply from the next prompt.
    $delay = 3000; $runDelay = 10000; $interval = 20000; $maxMs = 600000; $runMaxMs = 180000
    function Sync-Settings {
        $c = Get-TtsConfig
        if (-not $c) { return $true }
        if (-not [bool](Get-TtsField $c 'working' $true)) { return $false }
        $script:delay    = [int](Get-TtsField $c 'workingDelay' 3000)
        $script:runDelay = [int](Get-TtsField $c 'runningDelay' 10000)
        $script:interval = [int](Get-TtsField $c 'workingInterval' 20000)
        $script:maxMs    = [int](Get-TtsField $c 'workingMaxMs' 600000)
        $script:runMaxMs = [int](Get-TtsField $c 'runningMaxMs' 180000)
        if ($script:delay -lt 1000)    { $script:delay = 1000 }
        if ($script:interval -lt 3000) { $script:interval = 3000 }
        return $true
    }
    if (-not (Sync-Settings)) { exit 0 }

    # The ownership token: the marker's contents as they were when WE started.
    #
    # Reading it can legitimately fail: the turn may already have ended by the
    # time this process finishes starting. That is a normal race, not a fault.
    $mine = $null
    try { $mine = [System.IO.File]::ReadAllText($flag) } catch {}
    if (-not $mine) { Write-TtsLog 'working message: marker already gone, nothing to do'; exit 0 }

    $speaking = Join-Path $root 'speaking.flag'
    $waiting  = Join-Path $root 'waiting.flag'
    $qdir     = Join-Path $root 'queue'

    function Test-Talking {
        if (Test-Path -LiteralPath $speaking) { return $true }
        return @(Get-ChildItem -LiteralPath $qdir -Filter '*.txt' -ErrorAction SilentlyContinue).Count -gt 0
    }

    function Get-RunningState {
        # The OLDEST call still running. If several are in flight, the oldest is
        # the one that is dragging, and that is also the one you want to hear
        # about.
        $dir = Join-Path $root 'running'
        if (-not (Test-Path -LiteralPath $dir)) { return $null }
        $best = $null
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.txt' -ErrorAction SilentlyContinue)) {
            try {
                $raw = [System.IO.File]::ReadAllText($f.FullName)
                $i = $raw.IndexOf('|')
                if ($i -lt 1) { continue }
                $t = [long]$raw.Substring(0, $i)

                # A safety net underneath the interruption check: a marker for a
                # call that never got its PostToolUse (denied, interrupted,
                # crashed) must not be able to report a command forever. Past
                # the ceiling it is cleared and the narration falls back to the
                # thinking message.
                if (((([datetime]::Now).Ticks - $t) / 10000) -gt $runMaxMs) {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                    continue
                }

                if (($best -eq $null) -or ($t -lt $best.Ticks)) {
                    $best = @{ Ticks = $t; Phrase = $raw.Substring($i + 1) }
                }
            } catch { continue }
        }
        return $best
    }

    function Get-ElapsedPhrase([long]$ticks) {
        # How long it has been going on. That is the real information when
        # something drags: "still running" only says it is not finished, while a
        # number tells you whether to wait or to step in.
        #
        # Rounded coarsely on purpose. "Forty seconds" is something you can act
        # on; "thirty-eight seconds" sounds like a precision that is not there.
        $sec = [int]((([datetime]::Now).Ticks - $ticks) / 10000000)
        if ($sec -lt 20) { return '' }
        if ($sec -lt 90) { return ([string]([int]([Math]::Round($sec / 10.0) * 10)) + ' seconds so far.') }
        $min = [int][Math]::Round($sec / 60.0)
        if ($min -le 1) { return 'about a minute so far.' }
        return ('about ' + [string]$min + ' minutes so far.')
    }

    function Test-Interrupted {
        # There is NO hook for "the user interrupted". The turn simply ends, and
        # without this the loop went on reporting a command that had been dead
        # for ages, right up until you typed something new. The user heard that
        # as the old run still running.
        #
        # The signal is the transcript itself: an interruption writes a 'user'
        # entry with the text "[Request interrupted by user]". Only the last few
        # kilobytes are read, because the transcript grows to many megabytes and
        # this runs every couple of seconds.
        try {
            $pf = Join-Path $root 'transcript.path'
            if (-not (Test-Path -LiteralPath $pf)) { return $false }
            $tp = ([System.IO.File]::ReadAllText($pf)).Trim()
            if (-not $tp -or -not (Test-Path -LiteralPath $tp)) { return $false }

            # ReadWrite sharing: Claude Code is writing to the file at the same
            # time, and opening it without that fails mid-turn.
            $fs = [System.IO.File]::Open($tp, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $take = [int][Math]::Min(8192, $fs.Length)
                if ($take -le 0) { return $false }
                $fs.Seek(-$take, [System.IO.SeekOrigin]::End) | Out-Null
                $buf = New-Object byte[] $take
                $fs.Read($buf, 0, $take) | Out-Null
            } finally { $fs.Close() }

            $tail = [System.Text.Encoding]::UTF8.GetString($buf)
            $lines = @($tail -split "`n" | Where-Object { $_.Trim() })
            if ($lines.Count -eq 0) { return $false }
            $last = $lines[$lines.Count - 1]

            # Both conditions are required. If Claude writes the sentence itself
            # in an answer, and it did, in the very conversation where this was
            # built, the entry is of type 'assistant' and is not an
            # interruption.
            return (($last -match '"type"\s*:\s*"user"') -and ($last -match 'Request interrupted by user'))
        } catch { return $false }
    }

    function Reset-RunningClocks {
        # A call's clock should run from the moment the command actually starts,
        # not from when it asked for permission.
        #
        # While an approval is pending NOTHING is running: the call has been
        # proposed, not executed. The marker was stamped at the call anyway, so
        # your deliberation time landed on the command's account, and a command
        # that had run for five seconds could report "30 seconds so far". Here
        # the stamp is pushed forward ahead of you, so the clock reads zero when
        # you answer.
        #
        # All markers are pushed. If another call runs alongside one that is
        # waiting for permission, its time is then set too low. That is the
        # cheaper of the two errors, and the rarer one.
        $dir = Join-Path $root 'running'
        if (-not (Test-Path -LiteralPath $dir)) { return }
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.txt' -ErrorAction SilentlyContinue)) {
            try {
                $raw = [System.IO.File]::ReadAllText($f.FullName)
                $i = $raw.IndexOf('|')
                if ($i -lt 1) { continue }
                [System.IO.File]::WriteAllText($f.FullName, (([datetime]::Now).Ticks.ToString('D19') + '|' + $raw.Substring($i + 1)))
            } catch {}
        }
    }

    function Test-Mine {
        if (-not (Test-Path -LiteralPath $flag)) { return $false }
        try { return ([System.IO.File]::ReadAllText($flag) -eq $mine) } catch { return $false }
    }

    # The messages escalate, so you can hear roughly how long it has been
    # without counting. The last one then repeats: a fourth and fifth wording
    # would be decoration, and decoration becomes noise when you hear it every
    # day.
    $phrases = @('Thinking.', 'Still thinking.', 'Still working on it.')
    $idx = 0
    $n = 0
    $why = 'marker cleared'

    Write-TtsLog 'working message: start'

    $spent   = 0
    $silence = 0
    while ($spent -lt $maxMs) {
        if (-not (Test-Mine)) { $why = 'marker cleared'; break }

        # If speech is happening, or something is queued waiting to be said, you
        # already know things are moving. The clock resets, and the message only
        # comes if the silence returns.
        #
        # waiting.flag also counts as "not silent": an approval question is
        # waiting on you, and then the state is not "I am thinking" but "you are
        # up". Those two must never talk over each other.
        if ((Test-Talking) -or (Test-Path -LiteralPath $waiting)) {
            $silence = 0
            if ((Test-Path -LiteralPath $waiting) -and (($spent % 1000) -eq 0)) { Reset-RunningClocks }
        } else {
            $silence += 250

            # If a tool is running, say what is going on and for how long.
            # Otherwise it is thinking, and the wording escalates.
            #
            # The first message waits longer when a tool is running: a six
            # second command does not need commentary, it is finished before
            # anyone starts wondering.
            $run = Get-RunningState
            $due = if ($n -eq 0) { if ($run) { $runDelay } else { $delay } } else { $interval }
            if ($silence -ge $due) {
                if ($run) {
                    $msg = [string]$run.Phrase
                    $el  = Get-ElapsedPhrase ([long]$run.Ticks)
                    if ($el) { $msg = $msg + ' ' + $el }
                    Submit-Speech $msg
                    # The wording is logged. The queue only records file names,
                    # and afterwards you cannot tell whether it was the working
                    # message or the thinking message that sounded. That exact
                    # question came up.
                    Write-TtsLog ('working message: "' + $msg + '"')
                } else {
                    Write-TtsLog ('working message: "' + $phrases[$idx] + '"')
                    Submit-Speech $phrases[$idx]
                    if ($idx -lt ($phrases.Count - 1)) { $idx++ }
                }
                $n++
                $silence = 0
            }
        }

        Start-Sleep -Milliseconds 250
        $spent += 250
        if (($spent % 2000) -eq 0) {
            if (-not (Sync-Settings)) { $why = 'switched off mid-run'; break }
            if (Test-Interrupted) {
                # Escape is the listener acting, exactly like typing a new
                # prompt, so it gets the same answer: everything falls quiet at
                # once. This loop already knew about the interruption and used it
                # only to stop reporting a dead command, so the queue carried on
                # reading out a question that had just been dismissed, and the
                # one thing that stopped it was typing something new, which is
                # precisely what a listener presses Escape to avoid.
                #
                # There is no hook for this. Claude Code does not run Stop on an
                # interruption, and no event fires when a question is dismissed;
                # the transcript entry read above is the only evidence that
                # exists. Verified live on 12 August 2026: dismissing a question
                # with Escape left the speech running to the end.
                #
                # Stop-AllSpeech includes Clear-AllRunningMarkers, which is what
                # used to be here on its own.
                #
                # Known limitation, and it is the price of putting this in the
                # only process that already watches the transcript: this loop
                # runs only while working.flag exists, so with `working` set to
                # false, or after workingMaxMs, Escape silences nothing. An
                # unrelated setting therefore gates it. The alternative is a
                # watcher process of its own, which is more machinery than the
                # case has earned so far.
                # Ownership is re-checked HERE, and not only at the top of the
                # loop, because the gap between the two is exactly where this
                # goes wrong. Pressing Escape and then typing is the normal
                # sequence, and typing runs Stop-AllSpeech and Start-Working in
                # another process while this one is still inside its 250 ms
                # sleep. The interruption entry is a level, not an edge: it stays
                # the last line of the transcript until Claude Code appends the
                # new prompt. So this branch could fire on a turn that had
                # already begun and silence it: the new loop's marker deleted,
                # the new pending entries cleared, and the first speech of the
                # new turn drained by the stop flag. While the branch only
                # cleared running markers that race was nearly harmless, which
                # is why it survived; silencing makes it expensive.
                if (-not (Test-Mine)) { $why = 'taken over during the interruption'; break }
                $why = 'interrupted by the user'
                Stop-AllSpeech
                break
            }
        }
    }
    if ($spent -ge $maxMs) { $why = 'time ceiling' }
    Write-TtsLog "working message: done after $n messages ($why)"
} catch {
    Write-TtsLog ('work-loop FAILED: ' + $_.Exception.Message)
}

# Clean up only after OURSELVES, or we kill a newer loop's marker.
try {
    if ((Test-Path -LiteralPath $flag) -and ([System.IO.File]::ReadAllText($flag) -eq $mine)) {
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    }
} catch {}
exit 0
