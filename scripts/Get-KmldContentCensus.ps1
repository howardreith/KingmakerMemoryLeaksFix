#requires -Version 7.0
<#
.SYNOPSIS
  Bounded, read-only content census of a bound process's committed private allocations of one size
  (default 4,198,400 bytes = the allocation unit seen growing during W01 idle), comparing allocations that
  are NEW since a baseline region map with a control sample of allocations that already existed.
  Observation only: ReadProcessMemory; no suspend, no debugger, no GC, nothing written to the target.
  Output (private): content-census-<label>.json in the run directory.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$ProcessId,
    [Parameter(Mandatory)][long]$ExpectedCreationFileTimeUtc,
    [Parameter(Mandatory)][string]$RunDir,
    [Parameter(Mandatory)][string]$BaselineMemmapCsv,
    [string]$Label = 'census',
    [long]$AllocationSize = 4198400,
    [int]$MaxRegionsPerGroup = 24,
    [long]$MaxBytesPerGroup = 96MB,
    [int]$TopN = 40
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KmldRuntime.Common.ps1')
if (-not ('Kmld.BoundProcess' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'KmldNative.cs') }
if (-not ('Kmld.ContentCensus' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'KmldContentCensus.cs') }
$RunDir = Assert-KmldLabPath $RunDir

$bound = [Kmld.BoundProcess]::Bind($ProcessId, $ExpectedCreationFileTimeUtc, $true)
try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $regions = $bound.QueryRegions($true)
    $map = [Collections.Generic.List[Kmld.RegionSpan]]::new()
    $allocTotals = @{}
    foreach ($r in $regions) {
        if ($r.State -ne 0x1000) { continue }
        $kind = switch ([int]$r.Type) { 0x1000000 { 'Image' } 0x40000 { 'Mapped' } 0x20000 { 'Private' } default { 'Other' } }
        $map.Add([Kmld.RegionSpan]@{ Base = $r.BaseAddress; Size = $r.RegionSize; Kind = $kind; Module = $(if ($r.MappedName) { Split-Path -Leaf $r.MappedName } else { $null }) })
        if ($kind -eq 'Private') { $k = [string]$r.AllocationBase; $allocTotals[$k] = [uint64]($allocTotals[$k] + $r.RegionSize) }
    }
    $baseline = @{}
    foreach ($row in (Import-Csv -LiteralPath $BaselineMemmapCsv)) { if ($row.type -eq 'Private') { $baseline[[string]([Convert]::ToUInt64($row.allocation_base.Substring(2), 16))] = $true } }
    $candidates = @($allocTotals.GetEnumerator() | Where-Object { $_.Value -eq [uint64]$AllocationSize })
    $new = @($candidates | Where-Object { -not $baseline.ContainsKey($_.Key) } | ForEach-Object { [uint64]$_.Key } | Sort-Object)
    $old = @($candidates | Where-Object { $baseline.ContainsKey($_.Key) } | ForEach-Object { [uint64]$_.Key } | Sort-Object)
    function Pick($bases, $n) {
        if ($bases.Count -le $n) { return $bases }
        $step = $bases.Count / $n; @(0..($n - 1) | ForEach-Object { $bases[[int][Math]::Floor($_ * $step)] })
    }
    function Spans($bases) {
        $l = [Collections.Generic.List[Kmld.RegionSpan]]::new()
        foreach ($b in $bases) { foreach ($r in $regions) { if ($r.AllocationBase -eq $b -and $r.State -eq 0x1000) { $l.Add([Kmld.RegionSpan]@{ Base = $r.BaseAddress; Size = $r.RegionSize; Kind = 'Private' }) } } }
        return , $l
    }
    $result = [ordered]@{ label = $Label; utc = (Get-Date).ToUniversalTime().ToString('o'); pid = $ProcessId; allocationSize = $AllocationSize
        allocationsOfSize = $candidates.Count; newSinceBaseline = $new.Count; presentAtBaseline = $old.Count; mapRegions = $map.Count
        method = 'ReadProcessMemory of sampled allocations; first qword at each 16-byte boundary tallied; top values classified by target region; Mono names resolved heuristically via vtable->klass (name, namespace) char* pair'
        groups = [ordered]@{} }
    foreach ($g in @(@{ name = 'new'; bases = @(Pick $new $MaxRegionsPerGroup) }, @{ name = 'pre-existing'; bases = @(Pick $old $MaxRegionsPerGroup) })) {
        if (-not $g.bases.Count) { $result.groups[$g.name] = 'none'; continue }
        $bound.VerifyIdentity()
        $c = [Kmld.ContentCensus]::Run($ProcessId, $ExpectedCreationFileTimeUtc, (Spans @($g.bases)), $map, $MaxBytesPerGroup, $TopN)
        $slots = [double][Math]::Max(1, $c.Slots)
        $ptk = [ordered]@{}
        foreach ($kv in ($c.PointerTargetKinds.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 12)) { $ptk[$kv.Key] = [Math]::Round($kv.Value / $slots, 4) }
        $result.groups[$g.name] = [ordered]@{
            allocationsSampled = @($g.bases).Count; regionsRead = $c.RegionsRead; bytesRead = $c.BytesRead; readFailures = $c.ReadFailures
            zeroSlotFraction = [Math]::Round($c.ZeroQwords / $slots, 4)
            pointerTargetKinds = $ptk
            topTypes = @($c.Top | ForEach-Object { [ordered]@{ pointer = ('0x{0:X}' -f $_.Pointer); slotsFraction = [Math]::Round($_.Count / $slots, 5); count = $_.Count; kind = $_.Kind; name = $_.Name; namespace = $_.Namespace; evidence = $_.Evidence } })
            topUtf16 = @($c.Utf16Strings | ForEach-Object { [ordered]@{ s = $_.Key; n = $_.Value } })
            topAscii = @($c.AsciiStrings | ForEach-Object { [ordered]@{ s = $_.Key; n = $_.Value } }) }
    }
    $result.elapsedMs = $sw.ElapsedMilliseconds
    Write-KmldJson (Join-Path $RunDir "content-census-$Label.json") $result
    $result
} finally { $bound.Dispose() }
