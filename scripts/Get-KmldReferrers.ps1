#requires -Version 7.0
<#
.SYNOPSIS
  Heuristic one-hop referrer census for the dominant Mono types found by Get-KmldContentCensus.ps1 in allocations that
  grew during idle. For each selected type: sample objects (first qword == its vtable) in the new allocations, scan
  committed private memory for qwords equal to those object addresses, and attribute each hit to the nearest preceding
  object header whose vtable resolves to a Mono class. Read-only (ReadProcessMemory); results are labelled heuristic.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$ProcessId,
    [Parameter(Mandatory)][long]$ExpectedCreationFileTimeUtc,
    [Parameter(Mandatory)][string]$RunDir,
    [Parameter(Mandatory)][string]$BaselineMemmapCsv,
    [string]$CensusJson,
    [long]$AllocationSize = 4198400,
    [int]$Types = 3,
    [int]$MaxTargets = 400,
    [long]$MaxScanBytes = 6GB,
    [int]$MaxBackBytes = 4096,
    [int]$MaxHits = 20000
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KmldRuntime.Common.ps1')
if (-not ('Kmld.BoundProcess' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'KmldNative.cs') }
if (-not ('Kmld.ContentCensus' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'KmldContentCensus.cs') }
$RunDir = Assert-KmldLabPath $RunDir
if (-not $CensusJson) { $CensusJson = Join-Path $RunDir 'content-census-idle-end.json' }
$census = Get-Content -LiteralPath $CensusJson -Raw | ConvertFrom-Json -DateKind String
$new = $census.groups.new
if ($new -is [string]) { throw 'Census has no new allocations.' }
$picked = @($new.topTypes | Where-Object { $_.kind -eq 'mono-object' } | Select-Object -First $Types)
if (-not $picked.Count) { throw 'No resolved Mono types among the top values of new allocations.' }

$bound = [Kmld.BoundProcess]::Bind($ProcessId, $ExpectedCreationFileTimeUtc, $true)
try {
    $regions = $bound.QueryRegions($true)
    $map = [Collections.Generic.List[Kmld.RegionSpan]]::new()
    $alloc = @{}
    foreach ($r in $regions) {
        if ($r.State -ne 0x1000) { continue }
        $kind = switch ([int]$r.Type) { 0x1000000 { 'Image' } 0x40000 { 'Mapped' } 0x20000 { 'Private' } default { 'Other' } }
        $map.Add([Kmld.RegionSpan]@{ Base = $r.BaseAddress; Size = $r.RegionSize; Kind = $kind; Module = $(if ($r.MappedName) { Split-Path -Leaf $r.MappedName } else { $null }) })
        if ($kind -eq 'Private') { $alloc[$r.AllocationBase] = [uint64]($alloc[$r.AllocationBase] + $r.RegionSize) }
    }
    $baseline = @{}
    foreach ($row in (Import-Csv -LiteralPath $BaselineMemmapCsv)) { if ($row.type -eq 'Private') { $baseline[[Convert]::ToUInt64($row.allocation_base.Substring(2), 16)] = $true } }
    $targetRegions = [Collections.Generic.List[Kmld.RegionSpan]]::new()
    $scanRegions = [Collections.Generic.List[Kmld.RegionSpan]]::new()
    foreach ($r in $regions) {
        if ($r.State -ne 0x1000 -or $r.Type -ne 0x20000) { continue }
        $span = [Kmld.RegionSpan]@{ Base = $r.BaseAddress; Size = $r.RegionSize; Kind = 'Private' }
        $scanRegions.Add($span)
        if ($alloc[$r.AllocationBase] -eq [uint64]$AllocationSize -and -not $baseline.ContainsKey($r.AllocationBase)) { $targetRegions.Add($span) }
    }
    $out = [ordered]@{ utc = (Get-Date).ToUniversalTime().ToString('o'); pid = $ProcessId; method = 'heuristic one-hop referrers: nearest preceding Mono object header within MaxBackBytes; large arrays beyond that window are not attributed'
        maxBackBytes = $MaxBackBytes; scanRegions = $scanRegions.Count; targetRegions = $targetRegions.Count; types = @() }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($t in $picked) {
        $bound.VerifyIdentity()
        $vt = [Convert]::ToUInt64($t.pointer.Substring(2), 16)
        $r = [Kmld.ContentCensus]::Referrers($ProcessId, $ExpectedCreationFileTimeUtc, $vt, $targetRegions, $scanRegions, $map, $MaxTargets, $MaxScanBytes, $MaxBackBytes, $MaxHits)
        $out.types += [ordered]@{ type = "$($t.namespace).$($t.name)"; vtable = $t.pointer; targetsSampled = $r.TargetsSampled; bytesScanned = $r.BytesScanned; hits = $r.Hits; attributed = $r.Attributed
            referrers = @($r.ReferrerTypes | Select-Object -First 15 | ForEach-Object { [ordered]@{ type = "$($_.Namespace).$($_.Name)"; count = $_.Count } })
            fieldOffsets = @($r.FieldOffsets.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15 | ForEach-Object { [ordered]@{ at = $_.Key; count = $_.Value } }) }
    }
    $out.elapsedMs = $sw.ElapsedMilliseconds
    Write-KmldJson (Join-Path $RunDir 'referrers-idle-end.json') $out
    $out
} finally { $bound.Dispose() }
