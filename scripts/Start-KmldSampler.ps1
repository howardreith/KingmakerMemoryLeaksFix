#requires -Version 7.0
<#
.SYNOPSIS
  Tier A external sampler: binds to one process identity (PID + creation time) and streams
  bounded 1-second samples to CSV. Observation only.

.DESCRIPTION
  Stops on: target exit, cancellation file, maximum duration, CSV size cap, or identity failure.
  A resource-limit breach is recorded to limit-breach.json (the run controller decides what to
  stop); the sampler keeps recording so shutdown is captured. Missing metrics are left empty and
  explained in metric_status; they are never written as zero.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$ProcessId,
    [long]$ExpectedCreationFileTimeUtc = 0,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$OutDir,
    [int]$IntervalMs = 1000,
    [int]$MaxDurationSeconds = 3600,
    [long]$MaxCsvBytes = 64MB,
    [string]$CancelFile,
    [string]$MarkerFile,
    [string]$CaptureDir = 'C:\Dev\KingmakerMemoryLeakResearchLab',
    [string]$AllowedRoot = 'C:\Dev\KingmakerMemoryLeakResearchLab',
    [long]$MinAvailableBytes = 0,
    [double]$MaxCommitFraction = 0.90,
    [long]$MinDiskFreeBytes = 10GB,
    [switch]$NoGpu
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fullOut = [IO.Path]::GetFullPath($OutDir)
$root = [IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\') + '\'
if (-not $fullOut.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to write outside allowed root: $fullOut" }
if ($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{2,80}$') { throw "Unsafe run id: $RunId" }
New-Item -ItemType Directory -Force -Path $fullOut | Out-Null

if (-not ('Kmld.BoundProcess' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'KmldNative.cs') }

$csvPath = Join-Path $fullOut 'samples.csv'
$statusPath = Join-Path $fullOut 'sampler-status.json'
$breachPath = Join-Path $fullOut 'limit-breach.json'
if (Test-Path -LiteralPath $csvPath) { throw "samples.csv already exists; run ids are not reused: $csvPath" }

$status = [ordered]@{
    schemaVersion = 1; runId = $RunId; pid = $ProcessId; samplerPid = $PID; samplerScript = 'scripts/Start-KmldSampler.ps1'
    startedUtc = (Get-Date).ToUniversalTime().ToString('o'); endedUtc = $null; stopReason = $null; samples = 0; failedSamples = 0
    markerReadErrors = 0; intervalMs = $IntervalMs; overruns = 0; maxSampleDurationMs = 0; gpuStatusAtStart = $null; limitBreaches = 0
    units = [ordered]@{ bytes = 'bytes'; cpu = 'seconds (kernel+user)'; time = 'UTC ISO-8601; elapsed_ms from a monotonic Stopwatch' }
    counters = [ordered]@{
        private_bytes = 'PROCESS_MEMORY_COUNTERS_EX.PrivateUsage via GetProcessMemoryInfo (Private Bytes)'
        working_set_bytes = 'PROCESS_MEMORY_COUNTERS_EX.WorkingSetSize'
        handle_count = 'GetProcessHandleCount'; thread_count = 'Toolhelp32 thread snapshot filtered by owner pid'
        system_commit = 'GetPerformanceInfo CommitTotal/CommitLimit x PageSize'; system_available = 'GetPerformanceInfo PhysicalAvailable x PageSize'
        gpu = 'PDH \GPU Process Memory(pid_<pid>_*)\Dedicated Usage and Shared Usage, summed over adapters; WDDM accounting, not attributable to resource types'
        collector_private_bytes = 'Private Bytes of this sampler process (tool overhead, measured separately)'
    }
}
function Write-Status { $status | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statusPath -Encoding utf8 }

$bp = $null; $gpu = $null; $writer = $null
try {
    $bp = [Kmld.BoundProcess]::Bind($ProcessId, $ExpectedCreationFileTimeUtc, $false)
    $status.creationFileTimeUtc = $bp.CreationFileTimeUtc
    $status.creationTimeUtc = [DateTime]::FromFileTimeUtc($bp.CreationFileTimeUtc).ToString('o')
    $status.imagePath = $bp.ImagePath
    $creationIso = $status.creationTimeUtc
    if (-not $NoGpu) { $gpu = [Kmld.GpuCounters]::new($ProcessId); $status.gpuStatusAtStart = $gpu.Status } else { $status.gpuStatusAtStart = 'disabled' }
    Write-Status

    $writer = [IO.StreamWriter]::new($csvPath, $false, [Text.UTF8Encoding]::new($false))
    $writer.WriteLine('run_id,timestamp_utc,elapsed_ms,pid,process_creation_time,cycle,phase,private_bytes,working_set_bytes,handle_count,thread_count,process_cpu_seconds,system_available_bytes,system_commit_bytes,system_commit_limit_bytes,capture_disk_free_bytes,gpu_dedicated_bytes,gpu_shared_bytes,pagefile_bytes,peak_working_set_bytes,page_fault_count,collector_private_bytes,sample_duration_ms,game_foreground,game_minimized,console_idle_ms,metric_status')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $self = [Diagnostics.Process]::GetCurrentProcess()
    $targetProc = [Diagnostics.Process]::GetProcessById($ProcessId)   # PID cannot be reused while $bp holds a handle
    $cycle = ''; $phase = ''; $next = 0L; $breached = $false

    while ($true) {
        if ($CancelFile -and (Test-Path -LiteralPath $CancelFile)) { $status.stopReason = 'cancelled'; break }
        if ($sw.Elapsed.TotalSeconds -ge $MaxDurationSeconds) { $status.stopReason = 'max-duration'; break }
        if ($bp.HasExited) { $status.stopReason = "target-exited(code=$($bp.ExitCode))"; break }
        if ($writer.BaseStream.Length -ge $MaxCsvBytes) { $status.stopReason = 'capture-cap'; break }

        $t0 = $sw.ElapsedMilliseconds
        $notes = [Collections.Generic.List[string]]::new()
        if ($MarkerFile -and (Test-Path -LiteralPath $MarkerFile)) {
            try { $m = Get-Content -LiteralPath $MarkerFile -Raw | ConvertFrom-Json; $cycle = [string]$m.cycle; $phase = [string]$m.phase }
            catch { $status.markerReadErrors++; $notes.Add('marker-read-error') }
        }
        $s = $null
        try { $bp.VerifyIdentity(); $s = $bp.Sample() } catch { $notes.Add('sample-error:' + $_.Exception.Message.Replace(',', ';')); $status.failedSamples++ }
        $sys = [Kmld.SystemInfo]::Memory()
        $disk = [Kmld.SystemInfo]::DiskFree($CaptureDir)
        $gd = ''; $gs = ''
        if ($gpu) { $gstat = $null; $g = $gpu.Read([ref]$gstat); if ($gstat -eq 'ok') { $gd = $g[0]; $gs = $g[1] } else { $notes.Add('gpu:' + $gstat) } } else { $notes.Add('gpu:disabled') }
        if ($null -eq $sys) { $notes.Add('system-memory:unavailable') }
        if ($disk -lt 0) { $notes.Add('disk:unavailable') }
        $self.Refresh()
        $fg = [Kmld.SystemInfo]::IsForeground($ProcessId); $mn = -1; try { $targetProc.Refresh(); $mn = [Kmld.SystemInfo]::IsMinimized($targetProc.MainWindowHandle) } catch { }; $idleIn = [Kmld.SystemInfo]::MillisecondsSinceLastInput()
        $pb = ''; $ws = ''; $hc = ''; $tc = ''; $cpu = ''; $pf = ''; $pws = ''; $pfc = ''
        if ($s) {
            if ($s.MemoryOk) { $pb = $s.PrivateBytes; $ws = $s.WorkingSetBytes; $pf = $s.PagefileBytes; $pws = $s.PeakWorkingSetBytes; $pfc = $s.PageFaultCount }
            if ($s.HandlesOk) { $hc = $s.HandleCount }
            if ($s.ThreadCount -ge 0) { $tc = $s.ThreadCount }
            if ($s.CpuOk) { $cpu = [Math]::Round($s.CpuSeconds, 3) }
            foreach ($e in $s.Errors) { $notes.Add($e.Replace(',', ';')) }
        }
        $avail = if ($sys) { $sys[0] } else { '' }; $commit = if ($sys) { $sys[1] } else { '' }; $limit = if ($sys) { $sys[2] } else { '' }
        $dur = $sw.ElapsedMilliseconds - $t0
        if ($dur -gt $status.maxSampleDurationMs) { $status.maxSampleDurationMs = $dur }
        $metricStatus = if ($notes.Count) { ($notes -join '|') } else { 'ok' }
        $line = @($RunId, (Get-Date).ToUniversalTime().ToString('o'), $t0, $ProcessId, $creationIso, $cycle.Replace(',', ';'), $phase.Replace(',', ';'),
            $pb, $ws, $hc, $tc, $cpu, $avail, $commit, $limit, ($(if ($disk -ge 0) { $disk } else { '' })), $gd, $gs, $pf, $pws, $pfc, $self.PrivateMemorySize64, $dur, $fg, $mn, $idleIn, $metricStatus) -join ','
        $writer.WriteLine($line)
        $status.samples++
        if (($status.samples % 5) -eq 0) { $writer.Flush(); Write-Status }

        if ($sys) {
            $reasons = @()
            if ($MinAvailableBytes -gt 0 -and $sys[0] -lt $MinAvailableBytes) { $reasons += "available-ram<$MinAvailableBytes" }
            if ($sys[2] -gt 0 -and ($sys[1] / $sys[2]) -ge $MaxCommitFraction) { $reasons += "commit>=$MaxCommitFraction" }
            if ($disk -ge 0 -and $disk -lt $MinDiskFreeBytes) { $reasons += "disk-free<$MinDiskFreeBytes" }
            if ($reasons.Count -and -not $breached) {
                $breached = $true; $status.limitBreaches++
                [ordered]@{ runId = $RunId; utc = (Get-Date).ToUniversalTime().ToString('o'); elapsedMs = $t0; reasons = $reasons; availableBytes = $sys[0]; commitBytes = $sys[1]; commitLimitBytes = $sys[2]; diskFreeBytes = $disk } |
                    ConvertTo-Json | Set-Content -LiteralPath $breachPath -Encoding utf8
            }
        }

        $next += $IntervalMs
        $wait = $next - $sw.ElapsedMilliseconds
        if ($wait -gt 0) { [void]$bp.WaitForExit([int]$wait) } else { $status.overruns++; $next = $sw.ElapsedMilliseconds }
    }
}
catch {
    $status.stopReason = 'error: ' + $_.Exception.Message
    throw
}
finally {
    if ($writer) { $writer.Flush(); $writer.Dispose() }
    if ($gpu) { $gpu.Dispose() }
    if ($bp) { $bp.Dispose() }
    $status.endedUtc = (Get-Date).ToUniversalTime().ToString('o')
    if (-not $status.stopReason) { $status.stopReason = 'interrupted' }
    if (Test-Path -LiteralPath $csvPath) { $status.csvSha256 = (Get-FileHash -LiteralPath $csvPath -Algorithm SHA256).Hash.ToLowerInvariant(); $status.csvBytes = (Get-Item -LiteralPath $csvPath).Length }
    Write-Status
}
