#requires -Version 7.0
<#
.SYNOPSIS
  Guarded KMLD runtime controller. One owned Kingmaker process, launched only through Steam
  (App 640820), externally observed, closed only after identity revalidation.

.DESCRIPTION
  Workloads:
    W01-menu-idle  No input is sent. Launch -> wait for UMM "[Manager] Spawning." (MainMenu.Start)
                   -> settle -> idle at the main menu -> graceful close. No save is loaded.
    Attended       For an owner-attended session (not run autonomously): launch and sample until the
                   game exits; the operator records phases with Set-KmldMarker.ps1. Requires the
                   owner's own fixture/autosave containment decision (see protocols/).
  Preflight refuses on: a running Kingmaker, any foreign runtime lease, an existing KMLD lock or
  unreviewed protected-save violation, Steam not proven offline/Sync Disabled in the current
  session, an unexpected app build or binary hash, insufficient RAM/commit/disk headroom.
  Every save file is hashed before launch and after exit; any change is a blocking violation.
  -PreflightOnly performs every read-only check and writes nothing outside the run directory.
#>
[CmdletBinding()]
param(
    [ValidateSet('W01-menu-idle', 'Attended')][string]$Workload = 'W01-menu-idle',
    [string]$RunId,
    [string]$ConfigurationId = 'M0',
    [int]$SettleSeconds = 60,
    [int]$IdleSeconds = 600,
    [int]$StartupTimeoutSeconds = 420,
    [int]$MaxRunSeconds = 1800,
    [int]$IntervalMs = 1000,
    [long]$GameHeadroomBytes = 6GB,
    [switch]$PreflightOnly,
    [switch]$NoMemoryMaps,
    # Read-only content census of allocations that grew during idle, taken after the measured window.
    [switch]$ContentCensusAtEnd,
    # A launch opens a full-screen window on the console session. Refuse while someone is using it.
    [int]$MinConsoleIdleMinutes = 15,
    [switch]$AllowActiveConsole,
    # Free-text record of who authorized this run (copied into the manifest).
    [string]$AuthorizationNote = '',
    [string]$ExpectedEnvironment = 'C:\Dev\KingmakerMemoryLeakResearchLab\repo\KingmakerMemoryLeaksFix\environment.json'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KmldRuntime.Common.ps1')
if (-not ('Kmld.BoundProcess' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'KmldNative.cs') }

if (-not $RunId) { $RunId = 'kmld-{0}-{1}-{2}' -f $Workload.ToLowerInvariant(), (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'), ([guid]::NewGuid().ToString('N').Substring(0, 6)) }
if ($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{2,80}$') { throw "Unsafe run id: $RunId" }
$runDir = Assert-KmldLabPath (Join-Path $script:KmldLabRoot "private\run-data\$RunId")
if (Test-Path -LiteralPath $runDir) { throw "Run directory already exists; run ids are never reused: $runDir" }
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$eventsPath = Join-Path $runDir 'events.csv'
'utc,elapsed_ms,event,detail' | Set-Content -LiteralPath $eventsPath -Encoding utf8
$clock = [Diagnostics.Stopwatch]::StartNew()
function Event([string]$name, [string]$detail = '') {
    $line = '{0},{1},{2},"{3}"' -f (Get-Date).ToUniversalTime().ToString('o'), $clock.ElapsedMilliseconds, $name, ($detail -replace '"', "'")
    Add-Content -LiteralPath $eventsPath -Value $line -Encoding utf8
    Write-Host "[$($clock.Elapsed.ToString('hh\:mm\:ss'))] $name $detail"
}
$markerPath = Join-Path $runDir 'marker.json'
function Set-Phase([string]$cycle, [string]$phase) { Write-KmldJson $markerPath ([ordered]@{ cycle = $cycle; phase = $phase }); Event 'phase' "$cycle/$phase" }

$codeRevision = (& git -C $PSScriptRoot rev-parse HEAD 2>$null)
$codeDirty = [bool](& git -C $PSScriptRoot status --porcelain -- . 2>$null)
$manifest = [ordered]@{
    schema_version = 1; run_id = $RunId; experiment_id = $Workload; hypothesis_ids = @('H05', 'H06', 'H08')
    host_id = $null; started_utc = (Get-Date).ToUniversalTime().ToString('o'); ended_utc = $null
    process_pid = $null; process_creation_time = $null; executable_hash = $null
    code_revision = $codeRevision; code_dirty = $codeDirty
    tool_versions_and_hashes = [ordered]@{ pwsh = $PSVersionTable.PSVersion.ToString()
        scripts = @('Invoke-KmldRun.ps1', 'KmldRuntime.Common.ps1', 'KmldNative.cs', 'Start-KmldSampler.ps1', 'Start-KmldWatchdog.ps1') | ForEach-Object { [ordered]@{ file = "scripts/$_"; sha256 = Get-KmldSha256 (Join-Path $PSScriptRoot $_) } } }
    authorization_note = $AuthorizationNote; console_override = [bool]$AllowActiveConsole
    configuration_id = $ConfigurationId; mod_manifest_hash = $null; settings_hash = $null
    fixture_id = 'none (main menu; no save loaded)'; fixture_hash = $null; save_isolation_method = 'no save loaded; all save files hashed before/after; Steam offline + Sync Disabled proven'
    instrumentation_mode = 'none (external observation only)'; profiler_capture_mode = 'none'
    warmup_protocol = $null; measurement_protocol = $null; settling_rule = $null
    completed_cycles = 0; elapsed_seconds = $null; sampling_interval = "$IntervalMs ms"
    counter_capabilities_and_units = 'see sampler-status.json'
    resource_limits = $null; workload_deviations = @(); completion_status = 'started'; abort_or_blocker_reason = $null; artifact_paths_and_sha256 = @()
}
$manifestPath = Join-Path $runDir 'manifest.json'
function Save-Manifest { Write-KmldJson $manifestPath $manifest }

# ------------------------------------------------------------------ preflight (read-only)
$problems = [Collections.Generic.List[string]]::new()
$expected = Get-Content -LiteralPath $ExpectedEnvironment -Raw | ConvertFrom-Json
$manifest.host_id = $expected.host.hostId
if (Test-Path -LiteralPath $script:KmldLockPath) { $problems.Add("KMLD lock exists: $script:KmldLockPath (inspect; never assume the previous run is dead)") }
if ((Test-Path -LiteralPath $script:KmldViolationDir) -and @(Get-ChildItem -LiteralPath $script:KmldViolationDir -Filter '*.json' -File).Count) { $problems.Add('Unreviewed protected-save violation records exist') }
if (Test-Path -LiteralPath $script:KmldCancelPath) { $problems.Add("Cancel file present: $script:KmldCancelPath") }
$running = @(Get-KmldGameProcesses)
if ($running.Count) { $problems.Add("Kingmaker is already running (pid $($running.Pid -join ',')); never taking over another session") }
$leases = @(Get-KmldForeignLeases)
if ($leases.Count) { $problems.Add("Foreign runtime lease(s) held: $($leases -join '; ')") }
$steam = Get-KmldSteamState
foreach ($p in $steam.problems) { $problems.Add("Steam: $p") }
$app = Get-KmldAppManifest
if ($app.buildId -ne $expected.game.steam.buildId -or $app.targetBuildId -ne $app.buildId -or $app.stateFlags -ne '4') { $problems.Add("App manifest differs from recorded environment or an update is pending: $($app | ConvertTo-Json -Compress)") }
$exeHash = Get-KmldSha256 $script:KmldGameExe
$expectedExe = ($expected.game.coreFiles | Where-Object relativePath -eq 'Kingmaker.exe').sha256
if ($exeHash -ne $expectedExe) { $problems.Add('Kingmaker.exe hash differs from the recorded environment') }
$acsHash = Get-KmldSha256 (Join-Path $script:KmldGameRoot 'Kingmaker_Data\Managed\Assembly-CSharp.dll')
$expectedAcs = ($expected.game.keyManagedAssemblies | Where-Object relativePath -like '*\Assembly-CSharp.dll').sha256
if ($acsHash -ne $expectedAcs) { $problems.Add('Assembly-CSharp.dll hash differs from the recorded environment') }
$idleMs = [Kmld.SystemInfo]::MillisecondsSinceLastInput()
if (-not $AllowActiveConsole -and ($idleMs -lt 0 -or $idleMs -lt $MinConsoleIdleMinutes * 60000)) { $problems.Add("Console session input within the last $MinConsoleIdleMinutes min (idle $([math]::Round($idleMs/60000,1)) min); a launch would disrupt an active user") }
$sys = [Kmld.SystemInfo]::Memory()
$installed = $sys[3]
$minAvail = [Math]::Max(2GB, [long]($installed * 0.10))
$disk = [Kmld.SystemInfo]::DiskFree($script:KmldLabRoot)
$limits = [ordered]@{ minAvailableBytes = $minAvail; maxCommitFraction = 0.90; minDiskFreeBytes = 10GB; captureCapBytes = 5GB; gameHeadroomBytes = $GameHeadroomBytes
    preflightAvailableBytes = $sys[0]; preflightCommitBytes = $sys[1]; preflightCommitLimitBytes = $sys[2]; preflightDiskFreeBytes = $disk; maxRunSeconds = $MaxRunSeconds }
$manifest.resource_limits = $limits
if ($sys[0] - $GameHeadroomBytes -lt $minAvail) { $problems.Add("Insufficient available RAM: $([math]::Round($sys[0]/1GB,2)) GiB available, need $([math]::Round(($minAvail+$GameHeadroomBytes)/1GB,2)) GiB including game headroom") }
if (($sys[1] + $GameHeadroomBytes) / $sys[2] -ge 0.90) { $problems.Add('Commit would reach 90% of the limit with game headroom') }
if ($disk -lt (10GB + 5GB)) { $problems.Add('Less than 15 GiB free on the capture disk') }

# Configuration identity (M0 = the installation as found).
$modsManifest = Get-KmldTreeManifest (Join-Path $script:KmldGameRoot 'Mods') -Recurse
$ummManifest = Get-KmldTreeManifest (Join-Path $script:KmldGameRoot 'Kingmaker_Data\Managed\UnityModManager')
$hashOf = { param($rows, $exclude) $sb = [Text.StringBuilder]::new(); foreach ($r in @($rows)) { if ($exclude -and $r.path -match $exclude) { continue }; [void]$sb.Append($r.path).Append('|').Append($r.sha256).Append("`n") }; ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sb.ToString()))) -replace '-', '').ToLowerInvariant() }
# Assemblies and Info.json define the code configuration; logs/settings written by mods at runtime are excluded from this identity hash but still diffed.
$manifest.mod_manifest_hash = & $hashOf ($modsManifest | Where-Object { $_.path -match '\.(dll|json)$' -and $_.path -notmatch '(?i)settings|log' }) $null
$prefs = Get-KmldPlayerPrefs
$manifest.settings_hash = & $hashOf ($prefs.GetEnumerator() | ForEach-Object { [pscustomobject]@{ path = $_.Key; sha256 = $_.Value } }) $null
$manifest.executable_hash = $exeHash
$preflight = [ordered]@{ utc = (Get-Date).ToUniversalTime().ToString('o'); problems = @($problems); steam = $steam; appManifest = $app; foreignLeases = $leases
    kingmakerRunning = @($running); consoleIdleMs = $idleMs; assemblyCSharpSha256 = $acsHash; limits = $limits; modManifestHash = $manifest.mod_manifest_hash; settingsHash = $manifest.settings_hash; playerPrefs = $prefs }
Write-KmldJson (Join-Path $runDir 'preflight.json') $preflight
if ($problems.Count) {
    $manifest.completion_status = 'refused-preflight'; $manifest.abort_or_blocker_reason = ($problems -join ' | '); $manifest.ended_utc = (Get-Date).ToUniversalTime().ToString('o'); Save-Manifest
    Event 'preflight-refused' ($problems -join ' | ')
    Write-Error "Preflight refused: $($problems -join ' | ')"
    return
}
Event 'preflight-ok'
if ($PreflightOnly) { $manifest.completion_status = 'preflight-only'; $manifest.ended_utc = (Get-Date).ToUniversalTime().ToString('o'); Save-Manifest; Event 'preflight-only-complete'; return }

# ------------------------------------------------------------------ lock + before snapshots
$token = [guid]::NewGuid().ToString('N')
New-KmldLock $RunId $token
Event 'lock-acquired' $script:KmldLockPath
$lockHeld = $true
$bound = $null; $samplerProc = $null; $watchdogProc = $null; $launchUtc = $null
$closeMethod = 'not-attempted'
try {
    $leases = @(Get-KmldForeignLeases)
    if ($leases.Count -or @(Get-KmldGameProcesses).Count) { throw "Foreign lease or game process appeared after locking: $($leases -join '; ')" }
    Event 'snapshot-before-start'
    $before = [ordered]@{
        saves = Get-KmldTreeManifest $script:KmldSaveDir
        localLowTop = Get-KmldTreeManifest $script:KmldLocalLow -MaxHashBytes 64MB
        areas = Get-KmldTreeManifest (Join-Path $script:KmldLocalLow 'Areas') -Recurse -NoHash
        mods = $modsManifest; umm = $ummManifest
        gameRoot = Get-KmldTreeManifest $script:KmldGameRoot -MaxHashBytes 64MB
        streamingAssetsTop = Get-KmldTreeManifest (Join-Path $script:KmldGameRoot 'Kingmaker_Data\StreamingAssets') -NoHash
        playerPrefs = $prefs }
    Write-KmldJson (Join-Path $runDir 'snapshot-before.json') $before
    if (Test-Path -LiteralPath $script:KmldGameLog) { Copy-Item -LiteralPath $script:KmldGameLog -Destination (Join-Path $runDir 'output_log.previous-launch.txt') }
    Event 'snapshot-before-done' "saves=$(@($before.saves).Count)"

    # ------------------------------------------------------------------ launch via Steam
    # The previous session's log is still in place until the new process truncates it; start reading at its
    # end and accept markers only after the new log's first line (regression: pilot run kmld-w01menu-m0-r2).
    $logStartOffset = if (Test-Path -LiteralPath $script:KmldGameLog) { (Get-Item -LiteralPath $script:KmldGameLog).Length } else { 0L }
    $launchUtc = (Get-Date).ToUniversalTime()
    Event 'launch' "steam://rungameid/$script:KmldAppId"
    Start-Process "steam://rungameid/$script:KmldAppId"
    $game = $null
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline) {
        $cands = @(Get-KmldLaunchedGames $launchUtc)
        if ($cands.Count -gt 1) { throw "More than one new Kingmaker process: $($cands.Pid -join ',')" }
        if ($cands.Count -eq 1) { $game = $cands[0]; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $game) { throw 'No Kingmaker process appeared within 180 s of the Steam launch' }
    $creation = $game.CreationFileTimeUtc
    # Bind by handle immediately so every later error path can find and close this process.
    $bound = [Kmld.BoundProcess]::Bind($game.Pid, $creation, $true)
    $imagePath = Resolve-KmldImagePath $game.Pid $creation 20
    Event 'process-found' "pid=$($game.Pid) image=$imagePath"
    if ($imagePath -ine $script:KmldGameExe) { throw "Unexpected or unreadable executable path for the launched process: '$imagePath'" }
    $manifest.process_pid = $game.Pid; $manifest.process_creation_time = [DateTime]::FromFileTimeUtc($creation).ToString('o'); Save-Manifest
    Write-KmldJson (Join-Path $script:KmldStateDir 'kmld-runtime.lock.state.json') ([ordered]@{ runId = $RunId; token = $token; gamePid = $game.Pid; gameCreationFileTimeUtc = $creation; gameImage = $bound.ImagePath; controllerPid = $PID; runDir = $runDir })
    Event 'process-bound' "pid=$($game.Pid) creation=$($manifest.process_creation_time)"
    if (@(Get-KmldForeignLeases).Count) { throw 'A foreign runtime lease appeared during launch' }

    # ------------------------------------------------------------------ sampler + watchdog
    Set-Phase '' 'startup'
    $samplerArgs = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'Start-KmldSampler.ps1'), '-ProcessId', $game.Pid, '-ExpectedCreationFileTimeUtc', $creation, '-RunId', $RunId,
        '-OutDir', $runDir, '-IntervalMs', $IntervalMs, '-MaxDurationSeconds', ($MaxRunSeconds + 300), '-MaxCsvBytes', 256MB, '-CancelFile', (Join-Path $runDir 'CANCEL-sampler'),
        '-MarkerFile', $markerPath, '-MinAvailableBytes', $minAvail)
    $samplerProc = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $samplerArgs -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $runDir 'sampler-stderr.txt')
    $selfCreation = [Kmld.BoundProcess]::GetCreationTime($PID)
    $wdArgs = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'Start-KmldWatchdog.ps1'), '-ControllerPid', $PID, '-ControllerCreationFileTimeUtc', $selfCreation, '-GamePid', $game.Pid,
        '-GameCreationFileTimeUtc', $creation, '-RunDir', $runDir, '-DeadlineUtc', (Get-Date).ToUniversalTime().AddSeconds($MaxRunSeconds).ToString('o'))
    $watchdogProc = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $wdArgs -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $runDir 'watchdog-stderr.txt')
    Event 'observers-started' "sampler=$($samplerProc.Id) watchdog=$($watchdogProc.Id)"
    $manifest.tool_versions_and_hashes.samplerPid = $samplerProc.Id; $manifest.tool_versions_and_hashes.watchdogPid = $watchdogProc.Id

    # ------------------------------------------------------------------ workload
    $logOffset = [long]$logStartOffset
    $newLogStarted = $false
    $abort = $null
    $check = {
        if (Test-Path -LiteralPath $script:KmldCancelPath) { return 'cancel-file' }
        if (Test-Path -LiteralPath (Join-Path $runDir 'CANCEL-deadline')) { return 'deadline' }
        if (Test-Path -LiteralPath (Join-Path $runDir 'limit-breach.json')) { return 'limit-breach' }
        if (@(Get-KmldForeignLeases).Count) { return 'foreign-lease-appeared' }
        if ($bound.HasExited) { return "game-exited-unexpectedly(code=$($bound.ExitCode))" }
        if ($samplerProc.HasExited) { return 'sampler-exited' }
        return $null
    }
    $milestones = [ordered]@{}
    $startupDeadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
    $ready = $false
    while (-not $ready -and -not $abort) {
        foreach ($l in (Read-KmldAppendedLines $script:KmldGameLog ([ref]$logOffset))) {
            if (-not $newLogStarted) { if ($l -match '^Initialize engine version') { $newLogStarted = $true; Event 'new-log-detected' $l }; continue }
            if ($l -match '^\[Manager\] FINISH\. SUCCESSFUL LOADED (\d+)/(\d+) MODS') { $milestones.modsLoaded = $l; Event 'umm-mods-loaded' $l }
            elseif ($l -match '^\[Manager\] FINISH') { $milestones.modsLoaded = $l; Event 'umm-mods-loaded-partial' $l }
            elseif ($l -match '^\[Manager\] Spawning\.') { $ready = $true; $milestones.mainMenuStart = (Get-Date).ToUniversalTime().ToString('o'); Event 'main-menu-ready' 'UMM [Manager] Spawning. (MainMenu.Start:After)' }
            elseif ($l -match 'Game version detected') { $milestones.gameVersion = $l }
        }
        if ($ready) { break }
        if ((Get-Date) -gt $startupDeadline) { $abort = 'startup-timeout'; break }
        $abort = & $check
        Start-Sleep -Milliseconds 500
    }
    $manifest.warmup_protocol = "W01: process start -> UMM '[Manager] Spawning.' (main menu ready) -> $SettleSeconds s settle at main menu; no input sent"
    $manifest.measurement_protocol = "W01: $IdleSeconds s main-menu idle, no input; memory maps at idle start/middle/end"
    $manifest.settling_rule = 'Single idle condition; analysis reports first/last 60 s medians and OLS slope over the idle window; first 10 s after main-menu-ready excluded from settle summary'

    if (-not $abort -and $Workload -eq 'W01-menu-idle') {
        Set-Phase '0' 'menu-settle'
        $until = (Get-Date).AddSeconds($SettleSeconds)
        while ((Get-Date) -lt $until -and -not $abort) { $abort = & $check; Start-Sleep -Milliseconds 1000; [void](Read-KmldAppendedLines $script:KmldGameLog ([ref]$logOffset)) }
        if (-not $abort) {
            Set-Phase '1' 'menu-idle'
            if (-not $NoMemoryMaps) { $mm = Write-KmldMemoryMap $bound $runDir 'idle-start'; Event 'memmap' "idle-start regions=$($mm.regionCount) ms=$($mm.queryMs)" }
            $t0 = Get-Date; $midDone = $false
            while (((Get-Date) - $t0).TotalSeconds -lt $IdleSeconds -and -not $abort) {
                $abort = & $check
                if (-not $midDone -and ((Get-Date) - $t0).TotalSeconds -ge ($IdleSeconds / 2)) {
                    $midDone = $true
                    if (-not $NoMemoryMaps) { $mm = Write-KmldMemoryMap $bound $runDir 'idle-mid'; Event 'memmap' "idle-mid regions=$($mm.regionCount) ms=$($mm.queryMs)" }
                }
                foreach ($l in (Read-KmldAppendedLines $script:KmldGameLog ([ref]$logOffset))) {
                    if ($l -match 'Unloading \d+ unused Assets|Unloading \d+ Unused Serialized|UnloadTime|System memory in use') { Event 'game-log-memory-line' $l }
                }
                Start-Sleep -Milliseconds 1000
            }
            if (-not $abort) {
                if (-not $NoMemoryMaps) { $mm = Write-KmldMemoryMap $bound $runDir 'idle-end'; Event 'memmap' "idle-end regions=$($mm.regionCount) ms=$($mm.queryMs)" }
                $manifest.completed_cycles = 1
                # After the measured window: bounded read-only content census of allocations that grew during idle.
                if ($ContentCensusAtEnd -and -not $NoMemoryMaps) {
                    Set-Phase '1' 'post-idle-census'
                    try {
                        $cc = & (Join-Path $PSScriptRoot 'Get-KmldContentCensus.ps1') -ProcessId $game.Pid -ExpectedCreationFileTimeUtc $creation -RunDir $runDir -BaselineMemmapCsv (Join-Path $runDir 'memmap-idle-start.csv') -Label 'idle-end'
                        Event 'content-census' "allocationsOfSize=$($cc.allocationsOfSize) new=$($cc.newSinceBaseline) ms=$($cc.elapsedMs)"
                    } catch { Event 'content-census-failed' $_.Exception.Message }
                }
            }
        }
    }
    elseif (-not $abort -and $Workload -eq 'Attended') {
        Set-Phase '' 'attended'
        Event 'attended-mode' 'waiting for the operator to exit the game; markers via Set-KmldMarker.ps1'
        while (-not $bound.HasExited -and -not $abort) { $abort = & $check; if ($abort -like 'game-exited*') { $abort = $null; break }; Start-Sleep -Seconds 1 }
    }
    if ($abort) { Event 'abort' $abort; $manifest.abort_or_blocker_reason = $abort }

    # ------------------------------------------------------------------ close (identity revalidated)
    Set-Phase '' 'shutdown'
    if (-not $bound.HasExited) {
        $bound.VerifyIdentity()
        $p = [Diagnostics.Process]::GetProcessById($game.Pid)
        if ($p.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $creation) { throw 'Identity mismatch before close' }
        Event 'close-request' 'CloseMainWindow (WM_CLOSE)'
        [void]$p.CloseMainWindow()
        if ($bound.WaitForExit(120000)) { $closeMethod = 'graceful-wm-close' }
        else {
            Event 'close-retry' 'second CloseMainWindow'
            [void]$p.CloseMainWindow()
            if ($bound.WaitForExit(60000)) { $closeMethod = 'graceful-wm-close-retry' }
            else {
                $bound.VerifyIdentity()
                Event 'force-terminate' 'last resort on the verified mission-owned process'
                Stop-Process -Id $game.Pid -Force
                [void]$bound.WaitForExit(30000); $closeMethod = 'forced'
            }
        }
    } else { $closeMethod = 'already-exited' }
    Event 'game-exited' "method=$closeMethod code=$($bound.ExitCode)"
    foreach ($l in (Read-KmldAppendedLines $script:KmldGameLog ([ref]$logOffset))) { if ($l -match '^\[Manager\] Destroying when exit') { Event 'umm-exit-line' $l } }
    if ($samplerProc -and -not $samplerProc.WaitForExit(30000)) { New-Item -ItemType File -Force -Path (Join-Path $runDir 'CANCEL-sampler') | Out-Null; [void]$samplerProc.WaitForExit(15000) }
    if ($watchdogProc) { [void]$watchdogProc.WaitForExit(30000) }
}
catch {
    Event 'controller-error' $_.Exception.Message
    $manifest.abort_or_blocker_reason = 'controller-error: ' + $_.Exception.Message
    # Close whatever this run launched, bound or not (regression: kmld-w01menu-m0-r1 left an unbound process running).
    $targets = @()
    if ($bound -and -not $bound.HasExited) { $targets += [pscustomobject]@{ Pid = $bound.Pid; CreationFileTimeUtc = $bound.CreationFileTimeUtc } }
    elseif ($launchUtc) { $targets += @(Get-KmldLaunchedGames $launchUtc) }
    foreach ($t in $targets) {
        try {
            $r = Close-KmldOwnedGame $t.Pid $t.CreationFileTimeUtc $script:KmldGameExe
            $closeMethod = "after-error:$r"; Event 'close-after-error' "pid=$($t.Pid) result=$r"
        } catch { Event 'close-after-error-failed' $_.Exception.Message }
    }
}
finally {
    # ------------------------------------------------------------------ after snapshots + verification
    $gameStillRunning = ($bound -and -not $bound.HasExited) -or ($launchUtc -and @(Get-KmldLaunchedGames $launchUtc).Count -gt 0)
    Start-Sleep -Seconds 5   # let Steam write its exit cloud record
    $after = [ordered]@{
        saves = Get-KmldTreeManifest $script:KmldSaveDir
        localLowTop = Get-KmldTreeManifest $script:KmldLocalLow -MaxHashBytes 64MB
        areas = Get-KmldTreeManifest (Join-Path $script:KmldLocalLow 'Areas') -Recurse -NoHash
        mods = Get-KmldTreeManifest (Join-Path $script:KmldGameRoot 'Mods') -Recurse
        umm = Get-KmldTreeManifest (Join-Path $script:KmldGameRoot 'Kingmaker_Data\Managed\UnityModManager')
        gameRoot = Get-KmldTreeManifest $script:KmldGameRoot -MaxHashBytes 64MB
        streamingAssetsTop = Get-KmldTreeManifest (Join-Path $script:KmldGameRoot 'Kingmaker_Data\StreamingAssets') -NoHash
        playerPrefs = Get-KmldPlayerPrefs }
    Write-KmldJson (Join-Path $runDir 'snapshot-after.json') $after
    # Verification is isolated: if it cannot complete, the lock is kept and Complete-KmldRun.ps1 finishes it
    # (regression: run -r2 threw here and left the manifest unfinalized).
    $verified = $false
    try {
        $diff = [ordered]@{}
        if (Get-Variable before -ErrorAction SilentlyContinue) {
            foreach ($k in 'saves', 'localLowTop', 'areas', 'mods', 'umm', 'gameRoot', 'streamingAssetsTop') { $diff[$k] = Compare-KmldManifest $before[$k] $after[$k] }
            $prefChanges = @($after.playerPrefs.Keys | Where-Object { $before.playerPrefs[$_] -ne $after.playerPrefs[$_] }) + @($before.playerPrefs.Keys | Where-Object { -not $after.playerPrefs.Contains($_) })
            $diff.playerPrefsChanged = @($prefChanges | Sort-Object -Unique)
        }
        $diff.steamAfter = Get-KmldSteamState
        Write-KmldJson (Join-Path $runDir 'write-audit.json') $diff
        if ($diff.Contains('saves') -and -not $diff.saves.unchanged) {
            Write-KmldJson (Join-Path $script:KmldViolationDir "$RunId.json") ([ordered]@{ runId = $RunId; utc = (Get-Date).ToUniversalTime().ToString('o'); diff = $diff.saves; note = 'Blocking: owner review required before any further KMLD run.' })
            Event 'PROTECTED-SAVE-VIOLATION' ($diff.saves | ConvertTo-Json -Compress)
            $manifest.abort_or_blocker_reason = (@($manifest.abort_or_blocker_reason, 'protected save changed') | Where-Object { $_ }) -join ' | '
        }
        $verified = $diff.Contains('saves')
    } catch {
        Event 'post-run-verification-failed' $_.Exception.Message
        $manifest.abort_or_blocker_reason = (@($manifest.abort_or_blocker_reason, ('post-run verification failed: ' + $_.Exception.Message)) | Where-Object { $_ }) -join ' | '
    }
    try { if (Test-Path -LiteralPath $script:KmldGameLog) { Copy-Item -LiteralPath $script:KmldGameLog -Destination (Join-Path $runDir 'output_log.this-run.txt') -Force } } catch { Event 'log-copy-failed' $_.Exception.Message }
    $manifest.ended_utc = (Get-Date).ToUniversalTime().ToString('o')
    $manifest.elapsed_seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
    $manifest.workload_deviations += "close_method=$closeMethod"
    $manifest.completion_status = if ($gameStillRunning) { 'incomplete-game-still-running' } elseif (-not $verified -and (Get-Variable before -ErrorAction SilentlyContinue)) { 'verification-pending' } elseif ($manifest.abort_or_blocker_reason) { 'aborted' } else { 'completed' }
    $manifest.artifact_paths_and_sha256 = @(Get-ChildItem -LiteralPath $runDir -File | Where-Object Name -ne 'manifest.json' | Sort-Object Name | ForEach-Object { [ordered]@{ path = $_.Name; bytes = $_.Length; sha256 = Get-KmldSha256 $_.FullName } })
    Save-Manifest
    if ($gameStillRunning) {
        Event 'lock-retained' 'game process still running; lock kept for recovery'
    } elseif (-not $verified -and (Get-Variable before -ErrorAction SilentlyContinue)) {
        Event 'lock-retained' 'protected-save verification incomplete; run scripts/Complete-KmldRun.ps1 -RunId'
    } elseif ($lockHeld) {
        [void](Remove-KmldLock $RunId $token); Remove-Item -LiteralPath (Join-Path $script:KmldStateDir 'kmld-runtime.lock.state.json') -ErrorAction SilentlyContinue
        Event 'lock-released'
    }
    if ($bound) { $bound.Dispose() }
    Event 'done' $manifest.completion_status
}
