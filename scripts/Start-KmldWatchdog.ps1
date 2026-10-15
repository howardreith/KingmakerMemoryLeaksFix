#requires -Version 7.0
<#
.SYNOPSIS
  Out-of-process watchdog for one KMLD run. Closes ONLY the identity-verified mission-owned game
  process, and only when the controller has died, the hard deadline has passed, or a limit breach
  was not handled by the controller in time. Records every action it takes.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$ControllerPid,
    [Parameter(Mandatory)][long]$ControllerCreationFileTimeUtc,
    [Parameter(Mandatory)][int]$GamePid,
    [Parameter(Mandatory)][long]$GameCreationFileTimeUtc,
    [Parameter(Mandatory)][string]$RunDir,
    [Parameter(Mandatory)][datetime]$DeadlineUtc,
    [int]$ControllerGraceSeconds = 30,
    [int]$BreachGraceSeconds = 120,
    [int]$CloseWaitSeconds = 120
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KmldRuntime.Common.ps1')
if (-not ('Kmld.BoundProcess' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'KmldNative.cs') }
$RunDir = Assert-KmldLabPath $RunDir
$log = Join-Path $RunDir 'watchdog-log.jsonl'
function Log($event, $detail) { ([ordered]@{ utc = (Get-Date).ToUniversalTime().ToString('o'); event = $event; detail = $detail } | ConvertTo-Json -Compress) | Add-Content -LiteralPath $log -Encoding utf8 }

$game = [Kmld.BoundProcess]::Bind($GamePid, $GameCreationFileTimeUtc, $false)
$controller = $null
try { $controller = [Kmld.BoundProcess]::Bind($ControllerPid, $ControllerCreationFileTimeUtc, $false) } catch { Log 'controller-bind-failed' $_.Exception.Message }
Log 'started' "game=$GamePid controller=$ControllerPid deadline=$($DeadlineUtc.ToString('o'))"

function Close-Game([string]$why) {
    Log 'close-requested' $why
    try { $game.VerifyIdentity() } catch { Log 'identity-mismatch' $_.Exception.Message; return }
    $p = [Diagnostics.Process]::GetProcessById($GamePid)
    if ($p.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $GameCreationFileTimeUtc) { Log 'identity-mismatch' 'Process.StartTime differs'; return }
    [void]$p.CloseMainWindow()
    if ($game.WaitForExit($CloseWaitSeconds * 1000)) { Log 'closed' 'graceful'; return }
    try { $game.VerifyIdentity() } catch { Log 'identity-mismatch-before-force' $_.Exception.Message; return }
    Log 'force-terminate' 'graceful close did not complete; last-resort termination of the verified mission-owned process'
    Stop-Process -Id $GamePid -Force
    [void]$game.WaitForExit(30000)
    Log 'terminated' "exited=$($game.HasExited)"
}

$controllerGoneAt = $null; $breachSeenAt = $null
try {
    while (-not $game.HasExited) {
        $now = (Get-Date).ToUniversalTime()
        if ($now -ge $DeadlineUtc.ToUniversalTime()) {
            New-Item -ItemType File -Force -Path (Join-Path $RunDir 'CANCEL-deadline') | Out-Null
            Log 'deadline' 'hard deadline reached; giving controller 60 s'
            if (-not $game.WaitForExit(60000)) { Close-Game 'deadline' }
            break
        }
        if ($controller -and $controller.HasExited) {
            if (-not $controllerGoneAt) { $controllerGoneAt = $now; Log 'controller-exited' "code=$($controller.ExitCode)" }
            elseif (($now - $controllerGoneAt).TotalSeconds -ge $ControllerGraceSeconds) { Close-Game 'controller-exited'; break }
        }
        if (Test-Path -LiteralPath (Join-Path $RunDir 'limit-breach.json')) {
            if (-not $breachSeenAt) { $breachSeenAt = $now; Log 'limit-breach-seen' 'waiting for controller to close' }
            elseif (($now - $breachSeenAt).TotalSeconds -ge $BreachGraceSeconds) { Close-Game 'limit-breach-unhandled'; break }
        }
        [void]$game.WaitForExit(2000)
    }
    Log 'exiting' "gameExited=$($game.HasExited)"
} finally { $game.Dispose(); if ($controller) { $controller.Dispose() } }
