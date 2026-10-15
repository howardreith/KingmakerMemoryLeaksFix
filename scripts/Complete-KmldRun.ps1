#requires -Version 7.0
<#
.SYNOPSIS
  Finishes the post-run work of a KMLD run whose controller did not complete it (interruption or
  verification failure): proves the run's game process is gone, re-takes the after-snapshot, compares
  protected saves and installation files with the run's own before-snapshot, finalizes the manifest
  and only then releases the run's lock. Never deletes a lock it cannot attribute to the run, and
  never assumes the previous process is dead.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RunId)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KmldRuntime.Common.ps1')
if (-not ('Kmld.BoundProcess' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'KmldNative.cs') }

if ($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{2,80}$') { throw "Unsafe run id: $RunId" }
$runDir = Assert-KmldLabPath (Join-Path $script:KmldLabRoot "private\run-data\$RunId")
if (-not (Test-Path -LiteralPath (Join-Path $runDir 'snapshot-before.json'))) { throw "No before-snapshot for $RunId" }
if (-not (Test-Path -LiteralPath $script:KmldLockPath)) { throw 'No KMLD lock present; nothing to complete under a lock.' }
$lock = Get-Content -LiteralPath $script:KmldLockPath -Raw | ConvertFrom-Json -DateKind String
if ($lock.runId -cne $RunId) { throw "The lock belongs to run '$($lock.runId)', not '$RunId'." }
$manifest = Get-Content -LiteralPath (Join-Path $runDir 'manifest.json') -Raw | ConvertFrom-Json -DateKind String -AsHashtable

# The run's process must be provably gone.
$statePath = Join-Path $script:KmldStateDir 'kmld-runtime.lock.state.json'
if (Test-Path -LiteralPath $statePath) {
    $st = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -DateKind String
    $alive = $false
    try { $b = [Kmld.BoundProcess]::Bind([int]$st.gamePid, [long]$st.gameCreationFileTimeUtc, $false); $alive = -not $b.HasExited; $b.Dispose() } catch { $alive = $false }
    if ($alive) { throw "The run's game process (pid $($st.gamePid)) is still alive; close it through the guard first." }
}
$launched = @(if ($manifest.process_creation_time) { Get-KmldLaunchedGames ([DateTime]::Parse($manifest.process_creation_time).ToUniversalTime().AddSeconds(-1)) } else { Get-KmldGameProcesses })
if ($launched.Count) { throw "Kingmaker process(es) created since this run are alive: $($launched.Pid -join ','). Not completing." }

$before = Get-Content -LiteralPath (Join-Path $runDir 'snapshot-before.json') -Raw | ConvertFrom-Json -DateKind String
$after = [ordered]@{
    saves = Get-KmldTreeManifest $script:KmldSaveDir
    localLowTop = Get-KmldTreeManifest $script:KmldLocalLow -MaxHashBytes 64MB
    areas = Get-KmldTreeManifest (Join-Path $script:KmldLocalLow 'Areas') -Recurse -NoHash
    mods = Get-KmldTreeManifest (Join-Path $script:KmldGameRoot 'Mods') -Recurse
    umm = Get-KmldTreeManifest (Join-Path $script:KmldGameRoot 'Kingmaker_Data\Managed\UnityModManager')
    gameRoot = Get-KmldTreeManifest $script:KmldGameRoot -MaxHashBytes 64MB
    streamingAssetsTop = Get-KmldTreeManifest (Join-Path $script:KmldGameRoot 'Kingmaker_Data\StreamingAssets') -NoHash
    playerPrefs = Get-KmldPlayerPrefs }
Write-KmldJson (Join-Path $runDir 'snapshot-after-recovered.json') $after
$diff = [ordered]@{ recovered = $true; recoveredUtc = (Get-Date).ToUniversalTime().ToString('o')
    note = 'After-snapshot taken by Complete-KmldRun.ps1 after the controller failed to finish; no KMLD launch occurred in between (lock held).' }
foreach ($k in 'saves', 'localLowTop', 'areas', 'mods', 'umm', 'gameRoot', 'streamingAssetsTop') { $diff[$k] = Compare-KmldManifest @($before.$k) @($after[$k]) }
$bp = @{}; foreach ($p in $before.playerPrefs.PSObject.Properties) { $bp[$p.Name] = [string]$p.Value }
$diff.playerPrefsChanged = @(@($after.playerPrefs.Keys | Where-Object { $bp[$_] -ne $after.playerPrefs[$_] }) + @($bp.Keys | Where-Object { -not $after.playerPrefs.Contains($_) }) | Sort-Object -Unique)
$diff.steamAfter = Get-KmldSteamState
Write-KmldJson (Join-Path $runDir 'write-audit.json') $diff
if (-not $diff.saves.unchanged) {
    Write-KmldJson (Join-Path $script:KmldViolationDir "$RunId.json") ([ordered]@{ runId = $RunId; utc = (Get-Date).ToUniversalTime().ToString('o'); diff = $diff.saves; note = 'Blocking: owner review required.' })
    $manifest.abort_or_blocker_reason = (@($manifest.abort_or_blocker_reason, 'protected save changed') | Where-Object { $_ }) -join ' | '
}
$logPath = $script:KmldGameLog
if ((Test-Path -LiteralPath $logPath) -and -not (Test-Path -LiteralPath (Join-Path $runDir 'output_log.this-run.txt'))) {
    Copy-Item -LiteralPath $logPath -Destination (Join-Path $runDir 'output_log.this-run.txt')
}
$manifest.workload_deviations = @($manifest.workload_deviations) + 'post-run verification completed by Complete-KmldRun.ps1 (controller post-processing failed)'
if (-not $manifest.ended_utc) { $manifest.ended_utc = (Get-Date).ToUniversalTime().ToString('o') }
$manifest.completion_status = if ($manifest.abort_or_blocker_reason) { 'aborted-recovered' } else { 'completed-recovered' }
$manifest.artifact_paths_and_sha256 = @(Get-ChildItem -LiteralPath $runDir -File | Where-Object Name -ne 'manifest.json' | Sort-Object Name | ForEach-Object { [ordered]@{ path = $_.Name; bytes = $_.Length; sha256 = Get-KmldSha256 $_.FullName } })
Write-KmldJson (Join-Path $runDir 'manifest.json') $manifest
[void](Remove-KmldLock $RunId ([string]$lock.token))
Remove-Item -LiteralPath $statePath -ErrorAction SilentlyContinue
Add-Content -LiteralPath (Join-Path $runDir 'events.csv') -Value ('{0},,recovery-completed,"status={1}; saves unchanged={2}"' -f (Get-Date).ToUniversalTime().ToString('o'), $manifest.completion_status, $diff.saves.unchanged) -Encoding utf8
[pscustomobject]@{ runId = $RunId; status = $manifest.completion_status; savesUnchanged = $diff.saves.unchanged; modsUnchanged = $diff.mods.unchanged
    ummChanged = ($diff.umm.changed -join ';'); localLowChanged = ($diff.localLowTop.changed -join ';'); areas = "added=$($diff.areas.added.Count) removed=$($diff.areas.removed.Count)" }
