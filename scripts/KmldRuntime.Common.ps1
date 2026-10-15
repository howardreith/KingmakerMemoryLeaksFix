#requires -Version 7.0
# Shared helpers for the KMLD guarded runtime controller. Read-only except for files under the lab root.
Set-StrictMode -Version Latest

$script:KmldLabRoot = 'C:\Dev\KingmakerMemoryLeakResearchLab'
$script:KmldStateDir = Join-Path $script:KmldLabRoot 'runtime-state'
$script:KmldLockPath = Join-Path $script:KmldStateDir 'kmld-runtime.lock'
$script:KmldCancelPath = Join-Path $script:KmldStateDir 'CANCEL'
$script:KmldViolationDir = Join-Path $script:KmldStateDir 'protected-save-violations'
$script:KmldGameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Pathfinder Kingmaker'
$script:KmldGameExe = Join-Path $script:KmldGameRoot 'Kingmaker.exe'
$script:KmldSteamRoot = 'C:\Program Files (x86)\Steam'
$script:KmldSteamExe = Join-Path $script:KmldSteamRoot 'steam.exe'
$script:KmldLocalLow = Join-Path $env:USERPROFILE 'AppData\LocalLow\Owlcat Games\Pathfinder Kingmaker'
$script:KmldSaveDir = Join-Path $script:KmldLocalLow 'Saved Games'
$script:KmldGameLog = Join-Path $script:KmldLocalLow 'output_log.txt'
$script:KmldAppId = 640820
# Other projects' runtime leases on the same installation (checked, never created or removed here).
$script:KmldForeignLeases = @(
    'C:\Dev\KingmakerBuffPlannerLab\runtime-state\deployment.lock',
    'C:\Dev\KingmakerBuffPlannerLab\runtime-fixture-state\fixture.lock',
    'C:\Dev\KingmakerGunslingerLab\compatibility-state\compatibility.lock')
$script:KmldForeignLeaseDirs = @(
    'C:\Dev\KingmakerBuffPlannerLab\runtime-state',
    'C:\Dev\KingmakerBuffPlannerLab\runtime-fixture-state',
    'C:\Dev\KingmakerGunslingerLab\compatibility-state')

function Assert-KmldLabPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($script:KmldLabRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to write outside the lab: $full" }
    return $full
}

function Write-KmldJson([string]$Path, $Object) {
    $p = Assert-KmldLabPath $Path
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
    $tmp = "$p.tmp"
    $Object | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $p -Force
}

function Get-KmldSha256([string]$Path) {
    try { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } catch { 'unreadable:' + $_.Exception.GetType().Name }
}

# Identity of every Kingmaker.exe process, read through a process handle (creation FILETIME and
# QueryFullProcessImageName). Win32_Process.ExecutablePath is NOT used: it was observed empty for a
# just-created Kingmaker.exe (incident kmld-w01menu-m0-r1). Path is $null when not yet readable.
function Get-KmldGameProcesses([string]$Name = 'Kingmaker') {
    @(Get-Process -Name $Name -ErrorAction SilentlyContinue | ForEach-Object {
        $id = $_.Id; $path = $null; $creation = 0L
        try { $b = [Kmld.BoundProcess]::Bind($id, 0, $false); try { $creation = $b.CreationFileTimeUtc; $path = $b.ImagePath } finally { $b.Dispose() } } catch { }
        [pscustomobject]@{ Pid = $id; Path = $path; CreationFileTimeUtc = $creation
            CreationUtc = if ($creation) { [DateTime]::FromFileTimeUtc($creation) } else { [DateTime]::MinValue } } })
}

# Kingmaker processes created at or after a launch time (5 s tolerance), i.e. candidates launched by this run.
function Get-KmldLaunchedGames([DateTime]$LaunchUtc, [string]$Name = 'Kingmaker') {
    @(Get-KmldGameProcesses $Name | Where-Object { $_.CreationFileTimeUtc -ne 0 -and $_.CreationUtc -ge $LaunchUtc.AddSeconds(-5) })
}

# Waits up to $Seconds for the image path of a bound candidate to become readable.
function Resolve-KmldImagePath([int]$TargetPid, [long]$CreationFileTimeUtc, [int]$Seconds = 20) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try { $b = [Kmld.BoundProcess]::Bind($TargetPid, $CreationFileTimeUtc, $false); try { if ($b.ImagePath) { return $b.ImagePath } } finally { $b.Dispose() } }
        catch { return $null }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

# Graceful close of a launched process after identity revalidation; force only as a last resort.
function Close-KmldOwnedGame([int]$TargetPid, [long]$CreationFileTimeUtc, [string]$ExpectedPath) {
    $b = [Kmld.BoundProcess]::Bind($TargetPid, $CreationFileTimeUtc, $false)
    try {
        if ($b.HasExited) { return 'already-exited' }
        if ($ExpectedPath -and $b.ImagePath -ine $ExpectedPath) { return "refused-path-mismatch:$($b.ImagePath)" }
        $p = [Diagnostics.Process]::GetProcessById($TargetPid)
        if ($p.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $CreationFileTimeUtc) { return 'refused-identity-mismatch' }
        [void]$p.CloseMainWindow()
        if ($b.WaitForExit(120000)) { return 'graceful-wm-close' }
        [void]$p.CloseMainWindow()
        if ($b.WaitForExit(60000)) { return 'graceful-wm-close-retry' }
        $b.VerifyIdentity()
        Stop-Process -Id $TargetPid -Force
        [void]$b.WaitForExit(30000)
        return 'forced'
    } finally { $b.Dispose() }
}

function Get-KmldForeignLeases {
    $held = [Collections.Generic.List[string]]::new()
    foreach ($l in $script:KmldForeignLeases) { if (Test-Path -LiteralPath $l) { $held.Add($l) } }
    foreach ($d in $script:KmldForeignLeaseDirs) {
        if (Test-Path -LiteralPath $d) {
            Get-ChildItem -LiteralPath $d -Filter '*.lock' -File -ErrorAction SilentlyContinue | ForEach-Object { if (-not $held.Contains($_.FullName)) { $held.Add($_.FullName) } }
        }
    }
    return @($held)
}

# Steam Cloud / offline proof for App 640820 within the current Steam client session. No account IDs are returned.
function Get-KmldSteamState {
    $steam = @(Get-Process -Name steam -ErrorAction SilentlyContinue)
    $state = [ordered]@{ steamProcessCount = $steam.Count; steamPathOk = $false; steamStartUtc = $null; lastCloudRecordUtc = $null
        lastCloudRecordOffline = $false; lastRecordAfterSteamStart = $false; cloudLines = 0; problems = @() }
    if ($steam.Count -ne 1) { $state.problems += "expected exactly one steam.exe, found $($steam.Count)" }
    else {
        $state.steamPathOk = ($steam[0].Path -ieq $script:KmldSteamExe)
        if (-not $state.steamPathOk) { $state.problems += 'steam.exe path is not the expected path' }
        $state.steamStartUtc = $steam[0].StartTime.ToUniversalTime().ToString('o')
    }
    $log = Join-Path $script:KmldSteamRoot 'logs\cloud_log.txt'
    if (-not (Test-Path -LiteralPath $log)) { $state.problems += 'cloud_log.txt missing'; return $state }
    $lines = @(Select-String -LiteralPath $log -Pattern '\[AppID 640820\]' | ForEach-Object Line)
    $state.cloudLines = $lines.Count
    $last = $lines | Select-Object -Last 1
    if (-not $last) { $state.problems += 'no App 640820 cloud record'; return $state }
    if ($last -match '^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\]') {
        $local = [DateTime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal)
        $state.lastCloudRecordUtc = $local.ToUniversalTime().ToString('o')
        if ($state.steamStartUtc) { $state.lastRecordAfterSteamStart = $local.ToUniversalTime() -gt ([DateTime]::Parse($state.steamStartUtc).ToUniversalTime()) }
    }
    # The terminal record of a game exit in offline mode is the failed sync line or the cache write that follows it.
    $tail = @($lines | Select-Object -Last 6)
    $state.lastCloudRecordOffline = [bool]($tail | Where-Object { $_ -match 'Sync Disabled' -and $_ -match 'offlineMode=true' }) -and ($last -match 'offlineMode=true|YldWriteCacheDirectoryToFile')
    if (-not $state.lastCloudRecordOffline) { $state.problems += 'last App 640820 cloud record does not prove Sync Disabled + offlineMode=true' }
    if (-not $state.lastRecordAfterSteamStart) { $state.problems += 'offline cloud proof is not from the current Steam session' }
    return $state
}

function Get-KmldAppManifest {
    $acf = Get-Content -LiteralPath (Join-Path $script:KmldSteamRoot 'steamapps\appmanifest_640820.acf') -Raw
    $pick = { param($k) if ($acf -match ('"' + $k + '"\s+"([^"]*)"')) { $Matches[1] } else { $null } }
    [ordered]@{ buildId = (& $pick 'buildid'); targetBuildId = (& $pick 'TargetBuildID'); stateFlags = (& $pick 'StateFlags') }
}

# File manifest of a directory. Files larger than MaxHashBytes are recorded by size/mtime only.
function Get-KmldTreeManifest([string]$Root, [switch]$Recurse, [long]$MaxHashBytes = 128MB, [switch]$NoHash) {
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    $files = if ($Recurse) { Get-ChildItem -LiteralPath $Root -File -Recurse -Force -ErrorAction SilentlyContinue } else { Get-ChildItem -LiteralPath $Root -File -Force -ErrorAction SilentlyContinue }
    @($files | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{
            path = [IO.Path]::GetRelativePath($Root, $_.FullName); bytes = $_.Length; lastWriteUtc = $_.LastWriteTimeUtc.ToString('o')
            sha256 = if ($NoHash -or $_.Length -gt $MaxHashBytes) { $null } else { Get-KmldSha256 $_.FullName } } })
}

# Compares by path, size, mtime and SHA-256. Empty/$null manifests are valid (regression: run -r2, empty Areas folder).
# Manifests read back from JSON must be parsed with -DateKind String so lastWriteUtc stays a string.
function Compare-KmldManifest($Before, $After) {
    $b = @{}; foreach ($x in @($Before | Where-Object { $null -ne $_ })) { $b[[string]$x.path] = $x }
    $a = @{}; foreach ($x in @($After | Where-Object { $null -ne $_ })) { $a[[string]$x.path] = $x }
    $added = @($a.Keys | Where-Object { -not $b.ContainsKey($_) } | Sort-Object)
    $removed = @($b.Keys | Where-Object { -not $a.ContainsKey($_) } | Sort-Object)
    $changed = @($a.Keys | Where-Object { $b.ContainsKey($_) } | Where-Object {
        $x = $b[$_]; $y = $a[$_]
        ($x.bytes -ne $y.bytes) -or ($x.lastWriteUtc -ne $y.lastWriteUtc) -or ($x.sha256 -ne $y.sha256) } | Sort-Object)
    [ordered]@{ added = $added; removed = $removed; changed = $changed; unchanged = ($added.Count + $removed.Count + $changed.Count) -eq 0 }
}

function Get-KmldPlayerPrefs {
    $k = 'HKCU:\Software\Owlcat Games\Pathfinder Kingmaker'
    $o = [ordered]@{}
    if (Test-Path $k) {
        (Get-ItemProperty $k).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | Sort-Object Name | ForEach-Object {
            $v = $_.Value; if ($v -is [byte[]]) { $v = ([Text.Encoding]::UTF8.GetString($v)).TrimEnd([char]0) }
            $o[$_.Name] = [string]$v }
    }
    return $o
}

# Reads lines appended to a file that another process is writing (shared read).
function Read-KmldAppendedLines([string]$Path, [ref]$Offset) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        if ($fs.Length -lt $Offset.Value) { $Offset.Value = 0 }
        [void]$fs.Seek($Offset.Value, [IO.SeekOrigin]::Begin)
        $sr = [IO.StreamReader]::new($fs)
        $text = $sr.ReadToEnd()
        $Offset.Value = $fs.Position
        if (-not $text) { return @() }
        return @($text -split "`r?`n" | Where-Object { $_ -ne '' })
    } finally { $fs.Dispose() }
}

function New-KmldLock([string]$RunId, [string]$Token) {
    New-Item -ItemType Directory -Force -Path $script:KmldStateDir | Out-Null
    $body = [ordered]@{ runId = $RunId; token = $Token; controllerPid = $PID
        controllerCreationUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o'); createdUtc = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json
    $fs = [IO.File]::Open($script:KmldLockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $bytes = [Text.Encoding]::UTF8.GetBytes($body); $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
}

function Remove-KmldLock([string]$RunId, [string]$Token) {
    if (-not (Test-Path -LiteralPath $script:KmldLockPath)) { return $false }
    $l = Get-Content -LiteralPath $script:KmldLockPath -Raw | ConvertFrom-Json
    if ($l.runId -cne $RunId -or $l.token -cne $Token) { throw "Lock is not owned by this run ($RunId); not removing." }
    Remove-Item -LiteralPath $script:KmldLockPath
    return $true
}

function Write-KmldMemoryMap([Kmld.BoundProcess]$Bound, [string]$Directory, [string]$Label) {
    $dir = Assert-KmldLabPath $Directory
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $regions = $Bound.QueryRegions($true)
    $elapsed = $sw.ElapsedMilliseconds
    $typeName = @{ 0x1000000 = 'Image'; 0x40000 = 'Mapped'; 0x20000 = 'Private'; 0 = 'None' }
    $stateName = @{ 0x1000 = 'Commit'; 0x2000 = 'Reserve'; 0x10000 = 'Free' }
    $csv = Join-Path $dir "memmap-$Label.csv"
    $w = [IO.StreamWriter]::new($csv, $false, [Text.UTF8Encoding]::new($false))
    try {
        $w.WriteLine('base,allocation_base,size,state,type,protect,allocation_protect,mapped_name')
        foreach ($r in $regions) {
            $name = if ($r.MappedName) { '"' + ($r.MappedName -replace '"', "'") + '"' } else { '' }
            $w.WriteLine(('0x{0:X},0x{1:X},{2},{3},{4},0x{5:X},0x{6:X},{7}' -f $r.BaseAddress, $r.AllocationBase, $r.RegionSize, $stateName[[int]$r.State], $typeName[[int]$r.Type], $r.Protect, $r.AllocationProtect, $name))
        }
    } finally { $w.Dispose() }
    $summary = [ordered]@{}
    foreach ($g in ($regions | Where-Object { $_.State -ne 0x10000 } | Group-Object { "$($typeName[[int]$_.Type])/$($stateName[[int]$_.State])" })) {
        $summary[$g.Name] = [ordered]@{ regions = $g.Count; bytes = [long](($g.Group | ForEach-Object { [double]$_.RegionSize } | Measure-Object -Sum).Sum) }
    }
    # Committed image bytes by module file (top 15) and committed private bytes by allocation size bucket.
    $byModule = $regions | Where-Object { $_.State -eq 0x1000 -and $_.Type -eq 0x1000000 -and $_.MappedName } | Group-Object { Split-Path -Leaf $_.MappedName } |
        ForEach-Object { [pscustomobject]@{ module = $_.Name; bytes = [long](($_.Group | ForEach-Object { [double]$_.RegionSize } | Measure-Object -Sum).Sum) } } | Sort-Object bytes -Descending | Select-Object -First 15
    $alloc = $regions | Where-Object { $_.State -eq 0x1000 -and $_.Type -eq 0x20000 } | Group-Object AllocationBase | ForEach-Object { [double](($_.Group | ForEach-Object { [double]$_.RegionSize } | Measure-Object -Sum).Sum) }
    $buckets = [ordered]@{ '<1MiB' = 0L; '1-16MiB' = 0L; '16-64MiB' = 0L; '64-256MiB' = 0L; '>=256MiB' = 0L }
    $bucketCounts = [ordered]@{ '<1MiB' = 0; '1-16MiB' = 0; '16-64MiB' = 0; '64-256MiB' = 0; '>=256MiB' = 0 }
    foreach ($b in $alloc) {
        $k = if ($b -lt 1MB) { '<1MiB' } elseif ($b -lt 16MB) { '1-16MiB' } elseif ($b -lt 64MB) { '16-64MiB' } elseif ($b -lt 256MB) { '64-256MiB' } else { '>=256MiB' }
        $buckets[$k] += [long]$b; $bucketCounts[$k]++
    }
    $result = [ordered]@{ label = $Label; utc = (Get-Date).ToUniversalTime().ToString('o'); queryMs = $elapsed; regionCount = $regions.Count
        byTypeState = $summary; committedImageTopModules = @($byModule); committedPrivateByAllocationSize = [ordered]@{ bytes = $buckets; allocations = $bucketCounts }
        csv = [IO.Path]::GetFileName($csv); csvSha256 = Get-KmldSha256 $csv
        note = 'VirtualQueryEx region census; categories localize memory, they do not attribute it to a subsystem. Private/Commit includes the Mono heap, Unity native allocations and driver user-mode allocations alike.' }
    Write-KmldJson (Join-Path $dir "memmap-$Label.json") $result
    return $result
}
