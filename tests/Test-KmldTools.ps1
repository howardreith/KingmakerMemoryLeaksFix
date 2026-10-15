#requires -Version 7.0
<#
.SYNOPSIS
  Tool-validation tests for the KMLD sampler, watchdog and runtime helpers. SYNTHETIC ONLY:
  targets are disposable child processes created by this script (pwsh, notepad). Outputs go to
  private\tool-validation and are never runtime evidence about Kingmaker.
#>
[CmdletBinding()] param([string]$OutRoot = 'C:\Dev\KingmakerMemoryLeakResearchLab\private\tool-validation')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scripts = Join-Path $PSScriptRoot '..\scripts'
. (Join-Path $scripts 'KmldRuntime.Common.ps1')
if (-not ('Kmld.BoundProcess' -as [type])) { Add-Type -Path (Join-Path $scripts 'KmldNative.cs') }
$pwsh = (Get-Process -Id $PID).Path
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$root = Join-Path $OutRoot "tools-$stamp"
New-Item -ItemType Directory -Force -Path $root | Out-Null
$results = [Collections.Generic.List[object]]::new()
function Check([string]$name, [bool]$ok, [string]$detail = '') { $results.Add([pscustomobject]@{ test = $name; pass = $ok; detail = $detail }); Write-Host ("{0} {1} {2}" -f ($(if ($ok) { 'PASS' } else { 'FAIL' })), $name, $detail) }
function New-Child([string]$cmd) { Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-Command', $cmd) -PassThru -WindowStyle Hidden }
$sampler = Join-Path $scripts 'Start-KmldSampler.ps1'

# 1. Staircase allocation is observed; target exit stops sampling; output preserved.
$c = New-Child 'Start-Sleep -Milliseconds 2500; $l=[Collections.Generic.List[byte[]]]::new(); 1..3 | % { $b=[byte[]]::new(64MB); for($i=0;$i -lt $b.Length;$i+=4096){$b[$i]=1}; $l.Add($b); Start-Sleep -Milliseconds 1200 }; Start-Sleep 1'
Start-Sleep -Milliseconds 300
$d1 = Join-Path $root 't1'
& $sampler -ProcessId $c.Id -RunId 'tv-t1' -OutDir $d1 -IntervalMs 250 -MaxDurationSeconds 30 -NoGpu
$st = Get-Content (Join-Path $d1 'sampler-status.json') -Raw | ConvertFrom-Json
$rows = @(Import-Csv (Join-Path $d1 'samples.csv'))
$pb = @($rows | Where-Object { $_.private_bytes } | ForEach-Object { [double]$_.private_bytes })
Check 'staircase-observed' (($pb[-1] - $pb[0]) -gt 150MB) ("growth MiB=" + [math]::Round(($pb[-1] - $pb[0]) / 1MB))
Check 'exit-stops-sampler' ($st.stopReason -like 'target-exited*') $st.stopReason
Check 'csv-hash-recorded' ([bool]$st.csvSha256) $st.csvSha256
Check 'identity-columns' (@($rows | Where-Object { $_.pid -ne [string]$c.Id }).Count -eq 0 -and @($rows.process_creation_time | Sort-Object -Unique).Count -eq 1) ''
Check 'gpu-disabled-not-zero' (@($rows | Where-Object { $_.gpu_dedicated_bytes -ne '' }).Count -eq 0 -and @($rows | Where-Object { $_.metric_status -notmatch 'gpu:disabled' }).Count -eq 0) 'missing GPU left empty and explained'

# 2. Wrong creation time is refused (PID alone is insufficient).
$c2 = New-Child 'Start-Sleep 20'
Start-Sleep -Milliseconds 300
$real = [Kmld.BoundProcess]::GetCreationTime($c2.Id)
$refused = $false
try { & $sampler -ProcessId $c2.Id -ExpectedCreationFileTimeUtc ($real + 10000000) -RunId 'tv-t2' -OutDir (Join-Path $root 't2') -IntervalMs 250 -MaxDurationSeconds 5 -NoGpu } catch { $refused = $_.Exception.Message -match 'identity mismatch' }
Check 'creation-time-mismatch-refused' $refused ''

# 3. Cancellation file stops sampling with partial output.
$d3 = Join-Path $root 't3'; $cancel = Join-Path $d3 'CANCEL'
$job = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-File', $sampler, '-ProcessId', $c2.Id, '-ExpectedCreationFileTimeUtc', $real, '-RunId', 'tv-t3', '-OutDir', $d3, '-IntervalMs', 250, '-MaxDurationSeconds', 30, '-CancelFile', $cancel, '-NoGpu') -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $root 't3-stderr.txt')
Start-Sleep -Seconds 3
New-Item -ItemType File -Force -Path $cancel | Out-Null
$exited = $job.WaitForExit(15000)
$st3 = Get-Content (Join-Path $d3 'sampler-status.json') -Raw | ConvertFrom-Json
Check 'cancel-file-stops' ($exited -and $st3.stopReason -eq 'cancelled') $st3.stopReason
Check 'partial-output-preserved' ((@(Import-Csv (Join-Path $d3 'samples.csv')).Count -ge 4)) "rows=$(@(Import-Csv (Join-Path $d3 'samples.csv')).Count)"
Check 'target-not-touched-by-cancel' (-not $c2.HasExited) 'sampler cancellation leaves the target running'

# 4. Writes outside the allowed root are refused; run ids are not reused.
$out = $false; try { & $sampler -ProcessId $c2.Id -RunId 'tv-t4' -OutDir (Join-Path $env:TEMP 'kmld-should-not-exist') -MaxDurationSeconds 2 -NoGpu } catch { $out = $_.Exception.Message -match 'outside allowed root' }
Check 'outside-root-refused' ($out -and -not (Test-Path (Join-Path $env:TEMP 'kmld-should-not-exist'))) ''
$reuse = $false; try { & $sampler -ProcessId $c2.Id -RunId 'tv-t3' -OutDir $d3 -MaxDurationSeconds 2 -NoGpu } catch { $reuse = $_.Exception.Message -match 'already exists' }
Check 'run-id-reuse-refused' $reuse ''
$bad = $false; try { & $sampler -ProcessId $c2.Id -RunId '..\evil' -OutDir (Join-Path $root 't4b') -MaxDurationSeconds 2 -NoGpu } catch { $bad = $_.Exception.Message -match 'Unsafe run id' }
Check 'unsafe-run-id-refused' $bad ''

# 5. Capture cap and marker stamping.
$d5 = Join-Path $root 't5'; $marker = Join-Path $root 't5-marker.json'
'{"cycle":"3","phase":"menu-idle"}' | Set-Content $marker
& $sampler -ProcessId $c2.Id -RunId 'tv-t5' -OutDir $d5 -IntervalMs 100 -MaxDurationSeconds 30 -MaxCsvBytes 3KB -MarkerFile $marker -NoGpu
$st5 = Get-Content (Join-Path $d5 'sampler-status.json') -Raw | ConvertFrom-Json
$r5 = @(Import-Csv (Join-Path $d5 'samples.csv'))
Check 'capture-cap-stops' ($st5.stopReason -eq 'capture-cap') $st5.stopReason
Check 'marker-stamped' (@($r5 | Where-Object { $_.cycle -ne '3' -or $_.phase -ne 'menu-idle' }).Count -eq 0) ''

# 6. Limit breach is recorded (threshold forced high) without stopping or touching the target.
$d6 = Join-Path $root 't6'
& $sampler -ProcessId $c2.Id -RunId 'tv-t6' -OutDir $d6 -IntervalMs 200 -MaxDurationSeconds 2 -MinAvailableBytes ([long]::MaxValue) -NoGpu
Check 'limit-breach-recorded' (Test-Path (Join-Path $d6 'limit-breach.json')) ''
Check 'limit-breach-target-alive' (-not $c2.HasExited) ''
Stop-Process -Id $c2.Id -ErrorAction SilentlyContinue

# 7. Watchdog closes ONLY the verified target when the controller dies; refuses a mismatched identity.
$np = Start-Process notepad.exe -PassThru
Start-Sleep -Seconds 2
$npCreation = [Kmld.BoundProcess]::GetCreationTime($np.Id)
$fakeController = New-Child 'Start-Sleep 2'
Start-Sleep -Milliseconds 300
$fcCreation = [Kmld.BoundProcess]::GetCreationTime($fakeController.Id)
$d7 = Join-Path $root 't7'; New-Item -ItemType Directory -Force $d7 | Out-Null
$wd = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-File', (Join-Path $scripts 'Start-KmldWatchdog.ps1'), '-ControllerPid', $fakeController.Id, '-ControllerCreationFileTimeUtc', $fcCreation,
    '-GamePid', $np.Id, '-GameCreationFileTimeUtc', $npCreation, '-RunDir', $d7, '-DeadlineUtc', (Get-Date).ToUniversalTime().AddMinutes(5).ToString('o'), '-ControllerGraceSeconds', 3, '-CloseWaitSeconds', 20) -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $root 't7-stderr.txt')
$wdExited = $wd.WaitForExit(60000)
$wlog = Get-Content (Join-Path $d7 'watchdog-log.jsonl') -ErrorAction SilentlyContinue
Check 'watchdog-closes-on-controller-death' ($wdExited -and $np.HasExited -and ($wlog -match '"closed"')) ($wlog -join ' ')
$np2 = Start-Process notepad.exe -PassThru
Start-Sleep -Seconds 2
$d7b = Join-Path $root 't7b'; New-Item -ItemType Directory -Force $d7b | Out-Null
$wd2 = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-File', (Join-Path $scripts 'Start-KmldWatchdog.ps1'), '-ControllerPid', $PID, '-ControllerCreationFileTimeUtc', ([Kmld.BoundProcess]::GetCreationTime($PID)),
    '-GamePid', $np2.Id, '-GameCreationFileTimeUtc', ([Kmld.BoundProcess]::GetCreationTime($np2.Id) + 1), '-RunDir', $d7b, '-DeadlineUtc', (Get-Date).ToUniversalTime().AddSeconds(3).ToString('o')) -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $root 't7b-stderr.txt')
[void]$wd2.WaitForExit(30000)
Check 'watchdog-refuses-mismatched-identity' (-not $np2.HasExited) 'bind with wrong creation time must fail and leave the process alone'
[void]$np2.CloseMainWindow(); [void]$np2.WaitForExit(10000)

# 8. Manifest comparison helper.
$a = @([pscustomobject]@{ path = 'x'; bytes = 1; lastWriteUtc = 't'; sha256 = 'a' }, [pscustomobject]@{ path = 'y'; bytes = 1; lastWriteUtc = 't'; sha256 = 'b' })
$b = @([pscustomobject]@{ path = 'x'; bytes = 1; lastWriteUtc = 't'; sha256 = 'a' }, [pscustomobject]@{ path = 'y'; bytes = 1; lastWriteUtc = 't'; sha256 = 'c' }, [pscustomobject]@{ path = 'z'; bytes = 1; lastWriteUtc = 't'; sha256 = 'd' })
$cmp = Compare-KmldManifest $a $b
Check 'manifest-diff' (($cmp.changed -join ',') -eq 'y' -and ($cmp.added -join ',') -eq 'z' -and -not $cmp.unchanged) ''
$guard = $false; try { Write-KmldJson (Join-Path $env:TEMP 'kmld-x.json') @{} } catch { $guard = $true }
Check 'write-json-outside-lab-refused' $guard ''

# 9. Memory-map census on a synthetic process.
$c9 = New-Child 'Start-Sleep 15'
Start-Sleep -Milliseconds 500
$b9 = [Kmld.BoundProcess]::Bind($c9.Id, 0, $true)
$mm = Write-KmldMemoryMap $b9 (Join-Path $root 't9') 'synthetic'
$b9.Dispose(); Stop-Process -Id $c9.Id -ErrorAction SilentlyContinue
Check 'memmap-census' ($mm.regionCount -gt 100 -and $mm.byTypeState.Contains('Private/Commit') -and $mm.byTypeState.Contains('Image/Commit')) "regions=$($mm.regionCount) ms=$($mm.queryMs)"

# 10. Regression for incident kmld-w01menu-m0-r1: a just-launched process must be discoverable by
#     handle (creation time + image path) and closable by the error path even before binding.
$launch = (Get-Date).ToUniversalTime()
$n1 = Start-Process notepad.exe -PassThru
$found = @(); $deadline = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $deadline -and -not $found.Count) { $found = @(Get-KmldLaunchedGames $launch 'notepad'); Start-Sleep -Milliseconds 100 }
Check 'launched-process-found-by-handle' ($found.Count -ge 1 -and @($found.Pid) -contains $n1.Id) "found=$($found.Pid -join ',')"
$np1 = $found | Where-Object Pid -eq $n1.Id | Select-Object -First 1
$path = if ($np1) { Resolve-KmldImagePath $np1.Pid $np1.CreationFileTimeUtc 10 } else { $null }
Check 'image-path-resolved-via-handle' ([bool]$path -and $path -like '*notepad.exe') "path=$path"
Start-Sleep -Seconds 1
$mis = if ($np1) { Close-KmldOwnedGame $np1.Pid $np1.CreationFileTimeUtc 'C:\not\the\game.exe' } else { 'no-target' }
Check 'close-refuses-path-mismatch' ($mis -like 'refused-path-mismatch*' -and -not $n1.HasExited) $mis
$wrongId = $false; try { [void](Close-KmldOwnedGame $n1.Id ($np1.CreationFileTimeUtc + 1) $path) } catch { $wrongId = $_.Exception.Message -match 'identity mismatch' }
Check 'close-refuses-identity-mismatch' ($wrongId -and -not $n1.HasExited) ''
$ok = if ($np1) { Close-KmldOwnedGame $np1.Pid $np1.CreationFileTimeUtc $path } else { 'no-target' }
Check 'close-owned-graceful' ($ok -eq 'graceful-wm-close' -and $n1.HasExited) $ok
Check 'launched-list-empty-after-close' (@(Get-KmldLaunchedGames $launch 'notepad' | Where-Object Pid -eq $n1.Id).Count -eq 0) ''
$idle = [Kmld.SystemInfo]::MillisecondsSinceLastInput()
Check 'console-idle-readable' ($idle -ge 0) "idleMs=$idle"

# 11. Content census: string extraction on a known buffer (both alignments) and identity refusal.
if (-not ('Kmld.ContentCensus' -as [type])) { Add-Type -Path (Join-Path $scripts 'KmldContentCensus.cs') }
$ms = [IO.MemoryStream]::new()
foreach ($i in 1..500) { $u = [Text.Encoding]::Unicode.GetBytes('KMLD_UTF16_MARKER'); $ms.Write($u, 0, $u.Length); $ms.Write([byte[]]::new(8), 0, 8); $a = [Text.Encoding]::ASCII.GetBytes('KMLD_ASCII_MARKER_LONG'); $ms.Write($a, 0, $a.Length); $ms.WriteByte(0) }
$buf = $ms.ToArray(); $u16 = [Collections.Generic.Dictionary[string, int]]::new(); $asc = [Collections.Generic.Dictionary[string, int]]::new()
[Kmld.ContentCensus]::ExtractStrings($buf, $buf.Length, $u16, $asc)
$u16hits = ($u16.GetEnumerator() | Where-Object { $_.Key -like '*KMLD_UTF16_MARKER*' } | Measure-Object Value -Sum).Sum
Check 'census-strings-both-alignments' ($u16hits -eq 500 -and $asc['KMLD_ASCII_MARKER_LONG'] -eq 500) "utf16=$u16hits ascii=$($asc['KMLD_ASCII_MARKER_LONG'])"
$c11 = New-Child 'Start-Sleep 10'
Start-Sleep -Milliseconds 500
$cr11 = [Kmld.BoundProcess]::GetCreationTime($c11.Id)
$refusedCensus = $false
try { [void][Kmld.ContentCensus]::Run($c11.Id, $cr11 + 1, [Collections.Generic.List[Kmld.RegionSpan]]::new(), [Collections.Generic.List[Kmld.RegionSpan]]::new(), 1MB, 5) } catch { $refusedCensus = $_.Exception.Message -match 'identity mismatch' }
Check 'census-identity-mismatch-refused' $refusedCensus ''
Stop-Process -Id $c11.Id -ErrorAction SilentlyContinue
$e0 = Compare-KmldManifest $null @()
Check 'manifest-diff-empty-and-null' ($e0.unchanged) 'regression: run -r2 (empty Areas folder)'

$results | Export-Csv (Join-Path $root 'results.csv') -NoTypeInformation
$fail = @($results | Where-Object { -not $_.pass }).Count
"TOTAL: $($results.Count) tests, $fail failed. Output: $root"
if ($fail) { exit 1 }
