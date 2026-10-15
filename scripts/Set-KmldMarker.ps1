#requires -Version 7.0
<#
.SYNOPSIS
  Operator marker for an attended KMLD run: sets the current cycle/phase that the sampler stamps into
  every sample, and appends the change to operator-markers.csv in the active run directory.
.EXAMPLE
  pwsh -File scripts/Set-KmldMarker.ps1 -Cycle 3 -Phase settle -Note "back in area A after load"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Cycle,
    [Parameter(Mandatory)][string]$Phase,
    [string]$Note = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KmldRuntime.Common.ps1')
$statePath = Join-Path $script:KmldStateDir 'kmld-runtime.lock.state.json'
if (-not (Test-Path -LiteralPath $statePath)) { throw 'No active KMLD run (lock state file missing).' }
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -DateKind String
$runDir = Assert-KmldLabPath $state.runDir
foreach ($v in $Cycle, $Phase) { if ($v -notmatch '^[A-Za-z0-9_.-]{1,40}$') { throw "Unsafe marker value: $v" } }
Write-KmldJson (Join-Path $runDir 'marker.json') ([ordered]@{ cycle = $Cycle; phase = $Phase })
$csv = Join-Path $runDir 'operator-markers.csv'
if (-not (Test-Path -LiteralPath $csv)) { 'utc,cycle,phase,note' | Set-Content -LiteralPath $csv -Encoding utf8 }
('{0},{1},{2},"{3}"' -f (Get-Date).ToUniversalTime().ToString('o'), $Cycle, $Phase, ($Note -replace '"', "'")) | Add-Content -LiteralPath $csv -Encoding utf8
"marker set: run=$($state.runId) cycle=$Cycle phase=$Phase"
