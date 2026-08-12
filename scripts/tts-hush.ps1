# Stop all speech at once: empty the queue and ask the daemon to fall silent.
# Called by the read-aloud skill when switching off, and can be run by hand.
#
# For the keyboard shortcut, use hush.vbs instead: PowerShell spends about half
# a second starting up, and that is half a second of the voice carrying on.
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'tts-common.ps1')
Stop-AllSpeech
exit 0
