# Shared helpers for the read-aloud hooks. Dot-sourced by each hook.
#
# Keep this file pure ASCII. PowerShell 5.1 reads a BOM-less UTF-8 file as ANSI,
# which corrupts any non-ASCII character. Writing in English makes that rule
# free to follow; em dashes in regular expressions are still written as \u
# escapes for the same reason.

# --- two roots, not one -----------------------------------------------------
# The program and its data have to live apart. When installed as a plugin the
# program directory is tied to the version: its path changes on every update,
# and the documentation says explicitly not to write state there. Config, voice
# models and cache would be lost each time.
#
#   TtsHome    the program: scripts/ and cues/. Read only.
#   TtsData    everything that changes: config, queue, cache, voices, log, flags.
#
# The data root is looked up in three places, in this order:
#   CLAUDE_TTS_DATA     set by hand; used for test runs
#   CLAUDE_PLUGIN_DATA  set by Claude Code for an installed plugin, and survives
#                       plugin updates
#   otherwise           ~/.claude/read-aloud/data, the fixed home of a manual
#                       install. Deliberately OUTSIDE any git checkout, so a
#                       clone does not fill up with queue files and logs.
$script:TtsScripts = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:TtsHome    = Split-Path -Parent $script:TtsScripts
$script:TtsStable  = Join-Path $env:USERPROFILE '.claude\read-aloud'
if     ($env:CLAUDE_TTS_DATA)    { $script:TtsData = $env:CLAUDE_TTS_DATA }
elseif ($env:CLAUDE_PLUGIN_DATA) { $script:TtsData = $env:CLAUDE_PLUGIN_DATA }
else                             { $script:TtsData = Join-Path $script:TtsStable 'data' }

function Write-TtsLog([string]$msg) {
    try {
        Add-Content -LiteralPath (Join-Path $script:TtsData 'tts.log') -Value ((Get-Date -Format 's') + ' ' + $msg) -Encoding UTF8
    } catch {}
}

function Initialize-TtsData {
    # First run: build the data root, install a default config, and put the
    # silence shortcut somewhere that does not move.
    #
    # Called from UserPromptSubmit, which always fires first in a session. It is
    # cheap to repeat: if everything is already in place, it does nothing.
    try {
        foreach ($d in @($script:TtsData,
                         (Join-Path $script:TtsData 'queue'),
                         (Join-Path $script:TtsData 'cache'),
                         (Join-Path $script:TtsData 'state'),
                         (Join-Path $script:TtsData 'running'),
                         (Join-Path $script:TtsData 'voices'),
                         $script:TtsStable)) {
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        }

        $cfg = Join-Path $script:TtsData 'tts-config.json'
        if (-not (Test-Path -LiteralPath $cfg)) {
            $src = Join-Path $script:TtsHome 'defaults\tts-config.json'
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $cfg -Force }
        }

        # The keyboard shortcut points at a FIXED path. If it pointed into the
        # program directory it would break on every plugin update, because that
        # directory is version-bound. So hush.vbs lives here, next to the note
        # telling it where the data is.
        [System.IO.File]::WriteAllText((Join-Path $script:TtsStable 'data.path'), $script:TtsData)

        $hushSrc = Join-Path $script:TtsScripts 'hush.vbs'
        $hushDst = Join-Path $script:TtsStable  'hush.vbs'
        if (Test-Path -LiteralPath $hushSrc) {
            $stale = $true
            if (Test-Path -LiteralPath $hushDst) {
                $stale = (Get-Item -LiteralPath $hushSrc).LastWriteTimeUtc -gt (Get-Item -LiteralPath $hushDst).LastWriteTimeUtc
            }
            if ($stale) { Copy-Item -LiteralPath $hushSrc -Destination $hushDst -Force }
        }
    } catch { Write-TtsLog ('could not prepare the data root: ' + $_.Exception.Message) }
}

function Get-TtsConfig {
    $cfgPath = Join-Path $script:TtsData 'tts-config.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { return $null }
    try { return Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Get-TtsField($cfg, [string]$name, $fallback) {
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains $name)) { return $cfg.$name }
    return $fallback
}

# --- markdown to speakable prose --------------------------------------------
function ConvertTo-Speakable([string]$text) {
    if (-not $text) { return '' }
    $t = $text
    $t = [regex]::Replace($t, '(?ms)^\s*```.*?```\s*$', "`n")          # code blocks
    $t = [regex]::Replace($t, '(?m)^\s*\|.*\|\s*$', '')                # table rows
    $t = [regex]::Replace($t, '!\[[^\]]*\]\([^)]*\)', '')              # images
    $t = [regex]::Replace($t, '\[([^\]]+)\]\([^)]*\)', '$1')           # links to text
    $t = [regex]::Replace($t, '`([^`]*)`', '$1')                       # inline code
    $t = [regex]::Replace($t, '(?m)^\s{0,3}#{1,6}\s*', '')             # headings
    $t = [regex]::Replace($t, '(?m)^\s*>\s?', '')                      # quotes
    $t = [regex]::Replace($t, '(?m)^\s*[-*+]\s+', '')                  # bullets
    $t = [regex]::Replace($t, '(?m)^\s*\d+[.)]\s+', '')                # numbers
    $t = [regex]::Replace($t, '(?m)^\s*([-*_]\s*){3,}\s*$', '')        # horizontal rules
    $t = $t -replace '\*\*', '' -replace '__', ''                      # bold
    $t = [regex]::Replace($t, '(?<=\s|^)[*_](\S[^*_]*)[*_](?=\s|$|\p{P})', '$1')
    # Drop everything that is not readable text: emoji, box drawing, arrows.
    # The em dash (u2014) and en dash (u2013) must survive: the daemon uses them
    # to insert a pause, exactly as it does at a full stop.
    $t = [regex]::Replace($t, '[^\p{L}\p{N}\s.,;:!?()\-''"/%&+=@\u2014\u2013]', ' ')
    $t = [regex]::Replace($t, '[ \t]+', ' ')
    $t = [regex]::Replace($t, '(\r?\n\s*){2,}', "`n")
    return $t.Trim()
}

# --- watermark: what has already been spoken in this session? ---------------
function Get-SpokenFile([string]$sessionId) {
    if (-not $sessionId) { $sessionId = 'unknown' }
    $dir = Join-Path $script:TtsData 'state'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    # Clean out old sessions, or the directory grows without limit.
    try {
        Get-ChildItem -LiteralPath $dir -Filter '*.txt' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-2) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {}
    $safe = ($sessionId -replace '[^A-Za-z0-9_-]', '_')
    return (Join-Path $dir ($safe + '.txt'))
}

function Test-AlreadySpoken([string]$sessionId, [string]$uuid) {
    if (-not $uuid) { return $false }
    $f = Get-SpokenFile $sessionId
    if (-not (Test-Path -LiteralPath $f)) { return $false }
    try { return (@(Get-Content -LiteralPath $f -Encoding ASCII) -contains $uuid) } catch { return $false }
}

function Register-Spoken([string]$sessionId, [string]$uuid) {
    if (-not $uuid) { return }
    try { Add-Content -LiteralPath (Get-SpokenFile $sessionId) -Value $uuid -Encoding ASCII } catch {}
}

# --- which tool is being run? -----------------------------------------------
function Get-ToolAnnouncement($payload) {
    # The command itself is never read aloud: paths and punctuation sound
    # terrible spelled out. Bash and PowerShell carry a short description
    # written for humans, so use that instead.
    $name = [string]$payload.tool_name
    if (-not $name) { return '' }
    $ti = $payload.tool_input

    switch -Regex ($name) {
        '^(Bash|PowerShell)$' {
            $d = [string]$ti.description
            if ($d) {
                if ($d -notmatch '[.!?]$') { $d = $d + '.' }
                return $d
            }
            return 'Running a command.'
        }
        '^Read$' {
            $f = [string]$ti.file_path
            if ($f) { return ('Reading ' + (Split-Path -Leaf ($f -replace '/', '\')) + '.') }
            return 'Reading a file.'
        }
        '^(Write|Edit)$' {
            $f = [string]$ti.file_path
            if ($f) { return ('Editing ' + (Split-Path -Leaf ($f -replace '/', '\')) + '.') }
            return 'Editing a file.'
        }
        '^NotebookEdit$' { return 'Editing a notebook.' }
        '^Grep$'         { return 'Searching the files.' }
        '^Glob$'         { return 'Looking for files.' }
        '^WebFetch$'     { return 'Fetching a web page.' }
        '^WebSearch$'    { return 'Searching the web.' }
        '^Agent$'        { return 'Starting a subagent.' }
        default          { return ('Using ' + $name + '.') }
    }
}

function Get-QuestionSpeech($payload, [string]$mode, [int]$descChars) {
    # Read an AskUserQuestion prompt aloud together with its options.
    #
    # This is the one kind of tool call where the CONTENT is spoken. Commands
    # are never read out, precisely because they are full of paths and
    # punctuation, but a question with options is written for a human, and if
    # you are answering without looking at the screen then the options are
    # exactly what you are missing.
    #
    # Options are numbered in words ("option one"), not digits. Spoken aloud a
    # digit disappears inside the sentence, while the word stands out.
    $qs = @($payload.tool_input.questions)
    if ($qs.Count -eq 0) { return '' }

    $ord = @('one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight')
    $parts = New-Object System.Collections.Generic.List[string]

    $qi = 0
    foreach ($q in $qs) {
        $qi++
        if ($qs.Count -gt 1) { $parts.Add('Question ' + $ord[$qi - 1] + ' of ' + $qs.Count + '.') }
        else                 { $parts.Add('A question for you.') }

        $t = ConvertTo-Speakable ([string]$q.question)
        if ($t) { $parts.Add($t) }
        if ([bool]$q.multiSelect) { $parts.Add('You can pick more than one.') }

        $oi = 0
        foreach ($o in @($q.options)) {
            $oi++
            $word = if ($oi -le $ord.Count) { $ord[$oi - 1] } else { [string]$oi }
            $label = ConvertTo-Speakable ([string]$o.label)
            $line = 'Option ' + $word + '. ' + $label
            if ($line -notmatch '[.!?]$') { $line = $line + '.' }
            $parts.Add($line)

            # 'labels' when you know the setup and just need to pick; 'full'
            # when you are working without a screen and have to make the choice
            # by ear alone.
            if ($mode -eq 'full') {
                $d = ConvertTo-Speakable ([string]$o.description)
                if ($d -and $descChars -gt 0 -and $d.Length -gt $descChars) {
                    $cut  = $d.Substring(0, $descChars)
                    $stop = [Math]::Max([Math]::Max($cut.LastIndexOf('. '), $cut.LastIndexOf('! ')), $cut.LastIndexOf('? '))
                    if ($stop -gt ($descChars * 0.35)) { $cut = $cut.Substring(0, $stop + 1) }
                    $d = $cut.TrimEnd()
                    if ($d -notmatch '[.!?]$') { $d = $d + '.' }
                }
                if ($d) { $parts.Add($d) }
            }
        }

        # Other is always on screen, but it is easy to miss when you are only
        # hearing the list, and it is often the one you want.
        $parts.Add('Or choose Other and answer in your own words.')
    }

    return ($parts -join ' ')
}

function Get-ToolProgressPhrase($payload) {
    # What to say WHILE a tool is still running. Not the same as the
    # announcement, because this has to make sense after the word "still".
    #
    # Note that the Bash description is NOT reused here. It is written in the
    # imperative ("Read TTS config"), and "Still read TTS config" is nonsense.
    # We say what kind of work is under way instead; what the command actually
    # does, you heard in the announcement a moment earlier.
    $name = [string]$payload.tool_name
    if (-not $name) { return '' }
    switch -Regex ($name) {
        '^(Bash|PowerShell)$'      { return 'Still running the command.' }
        '^Read$'                   { return 'Still reading.' }
        '^(Write|Edit|NotebookEdit)$' { return 'Still editing.' }
        '^Grep$'                   { return 'Still searching the files.' }
        '^Glob$'                   { return 'Still looking for files.' }
        '^WebFetch$'               { return 'Still fetching the page.' }
        '^WebSearch$'              { return 'Still searching the web.' }
        '^Agent$'                  { return 'The subagent is still working.' }
        '^AskUserQuestion$'        { return '' }
        default                    { return ('Still using ' + $name + '.') }
    }
}

function Set-RunningMarker($payload) {
    # One call in flight equals one file in running/, named after tool_use_id.
    #
    # A single marker file would not do: several tools can run at once, and the
    # first one to finish would delete the marker for all of them, dropping the
    # narration back to "still thinking" while work was still going on. With one
    # file per call the count is right, and the loop can pick the OLDEST call,
    # which is the one that is actually dragging.
    $phrase = Get-ToolProgressPhrase $payload
    if (-not $phrase) { return }
    $id = [string]$payload.tool_use_id
    if (-not $id) { $id = [guid]::NewGuid().ToString('N') }
    $id = $id -replace '[^A-Za-z0-9_-]', ''
    try {
        $dir = Join-Path $script:TtsData 'running'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        $body = (Get-Date).Ticks.ToString('D19') + '|' + $phrase
        [System.IO.File]::WriteAllText((Join-Path $dir ($id + '.txt')), $body)
    } catch {}
}

function Clear-RunningMarker($payload) {
    $id = [string]$payload.tool_use_id
    if (-not $id) { return }
    $id = $id -replace '[^A-Za-z0-9_-]', ''
    try {
        $f = Join-Path (Join-Path $script:TtsData 'running') ($id + '.txt')
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    } catch {}
}

function Clear-AllRunningMarkers {
    # New prompt, or hush: whatever was going on is no longer going on.
    # Without this a stranded marker, for example from an interrupted call where
    # PostToolUse never fired, would make the next turn report a tool that is
    # long gone.
    try {
        $dir = Join-Path $script:TtsData 'running'
        if (Test-Path -LiteralPath $dir) {
            Get-ChildItem -LiteralPath $dir -Filter '*.txt' -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

# --- small sounds: instant acknowledgement without synthesis ----------------
function Play-Cue([string]$name, [switch]$Quiet) {
    $cfg = Get-TtsConfig
    if (-not $cfg -or -not $cfg.enabled) { return }
    if (-not [bool](Get-TtsField $cfg 'cues' $true)) { return }
    # The tones follow the PROGRAM, not the data: they are finished files that
    # ship with the repository.
    $wav = Join-Path (Join-Path $script:TtsHome 'cues') ($name + '.wav')
    if (-not (Test-Path -LiteralPath $wav)) { Write-TtsLog "cue missing: $wav"; return }
    try {
        # .Play() is asynchronous, and that does not work here. The hook exits
        # immediately afterwards, the process dies, and the tone is cut off
        # mid-sound. That is why the permission tone was barely audible.
        # PlaySync costs only the few hundred milliseconds the tone lasts, and
        # the hook timeout is 10 seconds.
        $player = New-Object System.Media.SoundPlayer($wav)
        $player.PlaySync()
        # The waiting tone repeats every few seconds and would flood the log.
        if (-not $Quiet) { Write-TtsLog "cue: $name" }
    } catch { Write-TtsLog ("cue FAILED " + $name + ': ' + $_.Exception.Message) }
}

# --- dispatch ---------------------------------------------------------------
function Test-PiperReady($cfg) {
    # There used to be an 'engine' switch here, because the built-in Windows
    # voice could serve as a fallback. It is gone, so there is only one answer
    # left: either Piper is in place, or there is no speech.
    $model = [string](Get-TtsField $cfg 'piperModel' 'en_US-lessac-medium')
    # The voice model belongs to the DATA: it runs to a few hundred megabytes
    # and must not be re-downloaded every time the plugin updates.
    $onnx  = Join-Path (Join-Path $script:TtsData 'voices') ($model + '.onnx')
    if (-not (Test-Path -LiteralPath $onnx)) { Write-TtsLog "piper: model missing $onnx"; return $false }
    # The sidecar matters as much as the model. Piper needs both, and an
    # interrupted download leaves the .onnx alone, which used to pass this gate
    # and hand the daemon a model it could not load.
    if (-not (Test-Path -LiteralPath ($onnx + '.json'))) {
        Write-TtsLog "piper: config missing $onnx.json (incomplete download?)"
        return $false
    }
    if (-not (Test-Path -LiteralPath (Join-Path $script:TtsScripts 'piper-daemon.py'))) { return $false }
    return $true
}

function Start-PiperDaemon {
    $pidFile = Join-Path $script:TtsData 'piper.pid'
    if (Test-Path -LiteralPath $pidFile) {
        try {
            $old = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
            $p = Get-Process -Id $old -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -match 'python') { return }   # already running
        } catch {}
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }
    $daemon = Join-Path $script:TtsScripts 'piper-daemon.py'
    $exe = 'pythonw.exe'
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { $exe = 'python.exe' }
    try {
        # The data root is passed as an argument. The daemon cannot work it out
        # for itself: it lives in the program directory, and it does not
        # necessarily inherit the hook's environment variables.
        Start-Process -FilePath $exe -ArgumentList @("`"$daemon`"", "`"$script:TtsData`"") -WindowStyle Hidden | Out-Null
    } catch { Write-TtsLog ('could not start piper-daemon: ' + $_.Exception.Message) }
}

function Submit-Speech([string]$text, [switch]$Priority, [switch]$Hold) {
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $cfg = Get-TtsConfig
    if (-not $cfg -or -not $cfg.enabled) { return }

    $minChars = [int](Get-TtsField $cfg 'minChars' 0)
    $maxChars = [int](Get-TtsField $cfg 'maxChars' 100000)
    if ($text.Length -lt $minChars) { return }
    if ($text.Length -gt $maxChars) {
        $cut  = $text.Substring(0, $maxChars)
        $stop = [Math]::Max([Math]::Max($cut.LastIndexOf('. '), $cut.LastIndexOf('! ')), $cut.LastIndexOf('? '))
        if ($stop -gt ($maxChars * 0.4)) { $cut = $cut.Substring(0, $stop + 1) }
        $text = $cut.TrimEnd() + ' ... the rest is in the terminal.'
    }

    if ($env:CLAUDE_TTS_DRYRUN -eq '1') { Write-Output $text; return }

    if (Test-PiperReady $cfg) {
        # Queue file: the name sorts chronologically, so the daemon reads in
        # order.
        $qdir = Join-Path $script:TtsData 'queue'
        if (-not (Test-Path -LiteralPath $qdir)) { New-Item -ItemType Directory -Path $qdir | Out-Null }
        # An urgent item ("may I run this command?") goes to the front. File
        # names sort as text, so the prefix 0 lands first without interrupting
        # whatever is playing right now.
        #
        # Prefix 2 is a HELD message: the tool announcement. It must not be
        # spoken before we know whether a permission question is coming, because
        # PreToolUse fires BEFORE Claude Code decides to ask. The daemon leaves
        # it lying for a moment so a permission request can overtake it.
        $prefix = if ($Priority) { '0' } elseif ($Hold) { '2' } else { '1' }
        $name = $prefix + '-' + ((Get-Date).Ticks.ToString('D19')) + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt'
        [System.IO.File]::WriteAllText((Join-Path $qdir $name), $text, (New-Object System.Text.UTF8Encoding($false)))
        Start-PiperDaemon
    } else {
        # There is no fallback engine. The built-in Windows voice used to sit
        # here, but it cannot queue and therefore cut narration short, and a
        # worse engine that only runs when something has already gone wrong
        # never gets tested. A missing Piper must fail LOUDLY: you get silence,
        # and the log says why. See the README on prerequisites.
        Write-TtsLog 'no speech: Piper is not ready (see the lines above)'
    }
}

function Stop-Waiting {
    # Remove the waiting marker so the repeating tone stops.
    #
    # The loop in wait-loop.ps1 checks the file between tones and exits once it
    # is gone. No process is killed: the loop has to notice for itself, exactly
    # as the daemon notices stop.flag.
    $flag = Join-Path $script:TtsData 'waiting.flag'
    if (Test-Path -LiteralPath $flag) {
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    }
}

function Start-Waiting {
    # Set the waiting marker and start the loop, unless one is already running.
    #
    # The marker's existence IS the lock: if it is already there, a loop is
    # running, and a second one would produce double tones.
    $flag = Join-Path $script:TtsData 'waiting.flag'
    if (Test-Path -LiteralPath $flag) {
        # If the marker is left behind by a loop that died unexpectedly, it
        # would block the waiting tone forever. If it is older than any run can
        # last, it has been abandoned, so clear it.
        $age = ((Get-Date) - (Get-Item -LiteralPath $flag).LastWriteTime).TotalMilliseconds
        $cfgw = Get-TtsConfig
        $maxw = [int](Get-TtsField $cfgw 'waitMaxMs' 120000)
        if ($age -lt ($maxw + 30000)) { return }
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    }
    try {
        # The contents are the loop's ownership token, not just a tick mark. The
        # loop reads it at startup and exits the moment it changes or vanishes.
        # Without it two loops could live side by side and produce double tones,
        # which they did, when another hook managed to delete and recreate the
        # marker in the middle of everything.
        [System.IO.File]::WriteAllText($flag, [guid]::NewGuid().ToString('N'))
        $vbs = Join-Path $script:TtsScripts 'wait-loop.vbs'
        if (Test-Path -LiteralPath $vbs) {
            Start-Process -FilePath 'wscript.exe' -ArgumentList @("`"$vbs`"") -WindowStyle Hidden | Out-Null
        }
    } catch { Write-TtsLog ('could not start the waiting tone: ' + $_.Exception.Message) }
}

function Stop-Working {
    # Remove the working marker so the "still thinking" messages stop.
    $flag = Join-Path $script:TtsData 'working.flag'
    if (Test-Path -LiteralPath $flag) {
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    }
}

function Start-Working {
    # Set the working marker and start the loop that speaks up at intervals for
    # as long as Claude works without saying anything.
    #
    # Same pattern as Start-Waiting: the marker's EXISTENCE is the lock, and its
    # CONTENTS are the loop's ownership token. Two loops would talk over each
    # other.
    $cfg = Get-TtsConfig
    if (-not $cfg -or -not $cfg.enabled) { return }
    if (-not [bool](Get-TtsField $cfg 'working' $true)) { return }

    $flag = Join-Path $script:TtsData 'working.flag'
    if (Test-Path -LiteralPath $flag) {
        $age  = ((Get-Date) - (Get-Item -LiteralPath $flag).LastWriteTime).TotalMilliseconds
        $maxw = [int](Get-TtsField $cfg 'workingMaxMs' 600000)
        if ($age -lt ($maxw + 30000)) { return }
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    }
    try {
        [System.IO.File]::WriteAllText($flag, [guid]::NewGuid().ToString('N'))
        $vbs = Join-Path $script:TtsScripts 'work-loop.vbs'
        if (Test-Path -LiteralPath $vbs) {
            Start-Process -FilePath 'wscript.exe' -ArgumentList @("`"$vbs`"") -WindowStyle Hidden | Out-Null
        }
    } catch { Write-TtsLog ('could not start the working message: ' + $_.Exception.Message) }
}

function Release-HeldSpeech {
    # Release held tool announcements by renaming '2-' to '1-'.
    #
    # Called from PostToolUse. If the tool got to run, no permission question
    # ever came, so there is no reason to let the announcement sit out the
    # window. Without this, fast tools would only be announced several seconds
    # after they had finished.
    #
    # The timestamp in the name is preserved, so the order between queue items
    # holds.
    $qdir = Join-Path $script:TtsData 'queue'
    if (-not (Test-Path -LiteralPath $qdir)) { return }
    Get-ChildItem -LiteralPath $qdir -Filter '2-*.txt' -ErrorAction SilentlyContinue | ForEach-Object {
        try { Rename-Item -LiteralPath $_.FullName -NewName ('1' + $_.Name.Substring(1)) -ErrorAction Stop } catch {}
    }
}

# --- silence ----------------------------------------------------------------
function Stop-AllSpeech {
    # Empty the queue, and ask the daemon to fall silent through the stop flag.
    #
    # The waiting tone has to stop too: if you type something new, or press the
    # silence key, nothing is waiting on you any more.
    Stop-Waiting

    # And the working messages: asking for silence covers "still thinking" as
    # well. Note that tts-prompt.ps1 calls Stop-AllSpeech BEFORE Start-Working,
    # so a new prompt restarts them rather than killing them.
    Stop-Working
    Clear-AllRunningMarkers

    # The daemon must NOT be killed here. It holds the voice model in memory,
    # and a restart costs both process startup and about 2 seconds of loading,
    # which would then hit the first utterance after every single thing you
    # type.
    $qdir = Join-Path $script:TtsData 'queue'
    if (Test-Path -LiteralPath $qdir) {
        Get-ChildItem -LiteralPath $qdir -Filter '*.txt' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    # The stop flag is ALWAYS written, even with no pid file. It used to depend
    # on the pid file existing, and that is exactly the condition that fails
    # when you most need silence: the pid file is only written a moment after
    # the daemon starts, and if the daemon was killed there is either a stale
    # file or none at all. In both cases the voice kept talking. A redundant
    # flag costs nothing, since the daemon clears it itself both at startup and
    # in its main loop.
    try { [System.IO.File]::WriteAllText((Join-Path $script:TtsData 'stop.flag'), 'x') } catch {}
}
