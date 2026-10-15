#requires -Version 7.0
<#
.SYNOPSIS
  Read-only environment inventory for the Kingmaker memory diagnostics lab (KMLD).

.DESCRIPTION
  Collects host, game, runtime, loader, mod and tool identities without modifying
  anything outside the lab. Writes:
    - <PrivateDir>\environment-<stamp>.json      full record (raw paths, host name)
    - <PrivateDir>\file-hashes-<stamp>.csv       SHA-256 / MVID of every inventoried file
    - <RepoOut>                                  sanitized copy (user profile and host name replaced)
  Missing facts are recorded as "unavailable" with a reason, never as zero.
  It does not collect environment variables, credentials, browser state or account IDs.
#>
[CmdletBinding()]
param(
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Pathfinder Kingmaker',
    [string]$SteamRoot = 'C:\Program Files (x86)\Steam',
    [string]$PrivateDir = 'C:\Dev\KingmakerMemoryLeakResearchLab\private\manifests',
    [string]$RepoOut = (Join-Path $PSScriptRoot '..\environment.json'),
    [string]$CaptureDrive = 'C'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$labRoot = 'C:\Dev\KingmakerMemoryLeakResearchLab'
foreach ($p in @($PrivateDir, (Split-Path -Parent ([IO.Path]::GetFullPath($RepoOut))))) {
    if (-not ([IO.Path]::GetFullPath($p)).StartsWith($labRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to write outside the lab: $p"
    }
}

function Unavailable([string]$reason) { [ordered]@{ status = 'unavailable'; reason = $reason } }

function Get-Sha256([string]$path) {
    try { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() } catch { $null }
}

# Assembly identity via System.Reflection.Metadata; never loads the assembly for execution.
function Get-AssemblyIdentity([string]$path) {
    $fs = $null; $pe = $null
    try {
        $fs = [IO.File]::OpenRead($path)
        $pe = [System.Reflection.PortableExecutable.PEReader]::new($fs)
        if (-not $pe.HasMetadata) { return $null }
        $md = [System.Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($pe)
        $mvid = $md.GetGuid($md.GetModuleDefinition().Mvid)
        $ver = $null; $name = $null
        if ($md.IsAssembly) {
            $ad = $md.GetAssemblyDefinition()
            $ver = $ad.Version.ToString(); $name = $md.GetString($ad.Name)
        }
        $runtime = $md.MetadataVersion
        return [ordered]@{ name = $name; assemblyVersion = $ver; mvid = $mvid.ToString(); metadataVersion = $runtime }
    } catch { return $null } finally { if ($pe) { $pe.Dispose() }; if ($fs) { $fs.Dispose() } }
}

function Get-PeMachine([string]$path) {
    try {
        $fs = [IO.File]::OpenRead($path)
        try { $pe = [System.Reflection.PortableExecutable.PEReader]::new($fs); $pe.PEHeaders.CoffHeader.Machine.ToString() }
        finally { $fs.Dispose() }
    } catch { 'unknown' }
}

function Get-FileRecord([string]$path, [string]$root) {
    $fi = Get-Item -LiteralPath $path
    $vi = $fi.VersionInfo
    $rec = [ordered]@{
        relativePath = [IO.Path]::GetRelativePath($root, $fi.FullName)
        bytes = $fi.Length
        lastWriteUtc = $fi.LastWriteTimeUtc.ToString('o')
        sha256 = Get-Sha256 $fi.FullName
        fileVersion = $vi.FileVersion
        productVersion = $vi.ProductVersion
    }
    if ($fi.Extension -in '.dll', '.exe') {
        $id = Get-AssemblyIdentity $fi.FullName
        if ($id) { $rec.assembly = $id }
        $rec.peMachine = Get-PeMachine $fi.FullName
    }
    return $rec
}

$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$env = [ordered]@{ schemaVersion = 1; collectedUtc = (Get-Date).ToUniversalTime().ToString('o'); collector = 'scripts/Get-KmldEnvironment.ps1' }

# ---- Host ----
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cpu = @(Get-CimInstance Win32_Processor)
$gpus = @(Get-CimInstance Win32_VideoController)
$perf = Get-CimInstance Win32_PerfRawData_PerfOS_Memory
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($CaptureDrive):'"
$pagefiles = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
$env.host = [ordered]@{
    computerName = $env:COMPUTERNAME
    hostId = ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($env:COMPUTERNAME))) -replace '-', '').Substring(0, 12).ToLowerInvariant()
    os = [ordered]@{ caption = $os.Caption; version = $os.Version; build = $os.BuildNumber; architecture = $os.OSArchitecture }
    cpu = @($cpu | ForEach-Object { [ordered]@{ name = $_.Name.Trim(); cores = $_.NumberOfCores; logicalProcessors = $_.NumberOfLogicalProcessors } })
    installedRamBytes = [int64]$cs.TotalPhysicalMemory
    availableRamBytesAtCollection = [int64]$perf.AvailableBytes
    committedBytesAtCollection = [int64]$perf.CommittedBytes
    commitLimitBytes = [int64]$perf.CommitLimit
    pagefiles = @($pagefiles | ForEach-Object { [ordered]@{ name = $_.Name; allocatedMiB = $_.AllocatedBaseSize; currentUsageMiB = $_.CurrentUsage } })
    captureDisk = [ordered]@{ drive = "$($CaptureDrive):"; sizeBytes = [int64]$disk.Size; freeBytes = [int64]$disk.FreeSpace }
    gpus = @($gpus | ForEach-Object { [ordered]@{
        name = $_.Name; driverVersion = $_.DriverVersion; driverDate = if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { $null }
        adapterRamBytesWmi = $_.AdapterRAM; adapterRamNote = 'Win32_VideoController.AdapterRAM is a 32-bit field and unreliable above 4 GiB'
        currentResolution = "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)"; refreshHz = $_.CurrentRefreshRate } })
}

# ---- Game ----
$game = [ordered]@{ root = $GameRoot }
$manifest = Join-Path $SteamRoot 'steamapps\appmanifest_640820.acf'
if (Test-Path -LiteralPath $manifest) {
    $acf = Get-Content -LiteralPath $manifest -Raw
    $pick = { param($k) if ($acf -match ('"' + $k + '"\s+"([^"]*)"')) { $Matches[1] } else { $null } }
    $game.steam = [ordered]@{ appId = 640820; name = (& $pick 'name'); buildId = (& $pick 'buildid'); targetBuildId = (& $pick 'TargetBuildID');
        stateFlags = (& $pick 'StateFlags'); autoUpdateBehavior = (& $pick 'AutoUpdateBehavior'); lastUpdatedUnix = (& $pick 'LastUpdated'); sizeOnDisk = (& $pick 'SizeOnDisk') }
} else { $game.steam = Unavailable 'appmanifest_640820.acf not found' }
$versionInfo = Join-Path $GameRoot 'Kingmaker_Data\StreamingAssets\Version.info'
$game.versionInfo = if (Test-Path -LiteralPath $versionInfo) { (Get-Content -LiteralPath $versionInfo -Raw).Trim() } else { $null }
$game.versionInfoNote = 'Owlcat build stamp (date + source commit). The marketing version (e.g. 2.1.7b) is read from the game log line "Game version"; see ENVIRONMENT.md.'
$logPath = Join-Path $env:USERPROFILE 'AppData\LocalLow\Owlcat Games\Pathfinder Kingmaker\output_log.txt'
if (Test-Path -LiteralPath $logPath) {
    $head = Get-Content -LiteralPath $logPath -TotalCount 400
    $game.lastLogObservations = [ordered]@{
        source = 'output_log.txt from the most recent launch (read-only)'
        logLastWriteUtc = (Get-Item -LiteralPath $logPath).LastWriteTimeUtc.ToString('o')
        unityEngineLine = ($head | Where-Object { $_ -match '^Initialize engine version' } | Select-Object -First 1)
        rendererLines = @($head | Where-Object { $_ -match '^\s+(Version|Renderer|VRAM|Driver):' } | ForEach-Object { $_.Trim() })
        ummVersionLine = ($head | Where-Object { $_ -match '^\[Manager\] Version:' } | Select-Object -First 1)
        gameVersionLine = (Select-String -LiteralPath $logPath -Pattern '\[Manager\] Game version|Game version' -List | Select-Object -First 1 | ForEach-Object { $_.Line })
    }
} else { $game.lastLogObservations = Unavailable 'output_log.txt not found' }

$coreFiles = @('Kingmaker.exe', 'UnityPlayer.dll', 'UnityCrashHandler64.exe', 'winhttp.dll', 'doorstop_config.ini',
    'MonoBleedingEdge\EmbedRuntime\mono-2.0-bdwgc.dll', 'MonoBleedingEdge\EmbedRuntime\MonoPosixHelper.dll',
    'Galaxy64.dll', 'GalaxyCSharpGlue.dll', 'WinPixEventRuntime.dll', 'Kingmaker_Data\StreamingAssets\Version.info')
$game.coreFiles = @($coreFiles | ForEach-Object {
    $p = Join-Path $GameRoot $_
    if (Test-Path -LiteralPath $p) { Get-FileRecord $p $GameRoot } else { [ordered]@{ relativePath = $_; status = 'absent' } } })
$game.executableArchitecture = Get-PeMachine (Join-Path $GameRoot 'Kingmaker.exe')
$game.monoRuntime = [ordered]@{ file = 'MonoBleedingEdge\EmbedRuntime\mono-2.0-bdwgc.dll'; gcFamily = 'bdwgc (Boehm-Demers-Weiser, non-moving) by file name; behaviour not otherwise verified' }
$game.digitalRewardsDirs = @(Get-ChildItem -LiteralPath (Join-Path $GameRoot 'DigitalRewards') -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)

# Managed assemblies (full list goes to the CSV; key ones are summarized).
$managedDir = Join-Path $GameRoot 'Kingmaker_Data\Managed'
$managed = @(Get-ChildItem -LiteralPath $managedDir -File -Filter *.dll | Sort-Object Name | ForEach-Object { Get-FileRecord $_.FullName $GameRoot })
$keyNames = 'Assembly-CSharp.dll', 'Assembly-CSharp-firstpass.dll', 'UnityEngine.dll', 'UnityEngine.CoreModule.dll', 'UnityEngine.UI.dll', 'mscorlib.dll', 'Owlcat.Runtime.Core.dll', 'UniRx.dll'
$game.keyManagedAssemblies = @($managed | Where-Object { (Split-Path -Leaf $_.relativePath) -in $keyNames })
$game.managedAssemblyCount = $managed.Count
$sb = [Text.StringBuilder]::new(); foreach ($m in $managed) { [void]$sb.Append($m.relativePath).Append('|').Append($m.sha256).Append("`n") }
$game.managedSetSha256 = ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sb.ToString()))) -replace '-', '').ToLowerInvariant()

# ---- Loader ----
$ummDir = Join-Path $managedDir 'UnityModManager'
$loader = [ordered]@{ injection = 'unknown' }
$doorstop = Join-Path $GameRoot 'doorstop_config.ini'
if ((Test-Path -LiteralPath (Join-Path $GameRoot 'winhttp.dll')) -and (Test-Path -LiteralPath $doorstop)) {
    $loader.injection = 'Doorstop proxy (winhttp.dll) with doorstop_config.ini'
    $loader.doorstopConfig = (Get-Content -LiteralPath $doorstop) -join "`n"
}
$loader.files = @(Get-ChildItem -LiteralPath $ummDir -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { Get-FileRecord $_.FullName $GameRoot })
$params = Join-Path $ummDir 'Params.xml'
if (Test-Path -LiteralPath $params) {
    [xml]$px = Get-Content -LiteralPath $params -Raw
    $loader.params = [ordered]@{ checkUpdates = $px.Param.CheckUpdates; showOnStart = $px.Param.ShowOnStart
        mods = @($px.Param.ModParams.Mod | ForEach-Object { [ordered]@{ id = $_.Id; enabled = $_.Enabled } }) }
}
# A loader-modified Assembly-CSharp would differ from Steam's depot; the Doorstop method does not rewrite it.
$loader.assemblyCSharpModifiedByLoader = 'not determined by hash alone (no pristine depot hash available offline); Doorstop injection does not require rewriting Assembly-CSharp. See ENVIRONMENT.md.'
$game.loader = $loader

# ---- Mods ----
$modsDir = Join-Path $GameRoot 'Mods'
$game.mods = @(Get-ChildItem -LiteralPath $modsDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
    $d = $_
    $info = Join-Path $d.FullName 'Info.json'
    $rec = [ordered]@{ folder = $d.Name }
    if (Test-Path -LiteralPath $info) {
        try {
            $j = Get-Content -LiteralPath $info -Raw | ConvertFrom-Json
            foreach ($k in 'Id', 'DisplayName', 'Version', 'AssemblyName', 'EntryMethod', 'ManagerVersion', 'GameVersion', 'Requirements', 'LoadAfter', 'HomePage') {
                if ($j.PSObject.Properties.Name -contains $k) { $rec[$k] = $j.$k }
            }
        } catch { $rec.infoJsonError = $_.Exception.Message }
    }
    $files = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File | Sort-Object FullName)
    $rec.fileCount = $files.Count
    $rec.totalBytes = ($files | Measure-Object Length -Sum).Sum
    $asm = if ($rec.Contains('AssemblyName')) { Join-Path $d.FullName $rec.AssemblyName } else { $null }
    if ($asm -and (Test-Path -LiteralPath $asm)) { $rec.assembly = Get-FileRecord $asm $GameRoot }
    $rec.configFiles = @($files | Where-Object { $_.Extension -in '.xml', '.json', '.ini', '.cfg', '.txt' -and $_.Name -ne 'Info.json' -and $_.Length -lt 50MB } |
        Select-Object -First 25 | ForEach-Object { [ordered]@{ relativePath = [IO.Path]::GetRelativePath($GameRoot, $_.FullName); bytes = $_.Length; sha256 = Get-Sha256 $_.FullName; lastWriteUtc = $_.LastWriteTimeUtc.ToString('o') } })
    $rec })
$game.modBackupsDirPresent = Test-Path -LiteralPath (Join-Path $GameRoot 'ModBackups')

$env.game = $game

# ---- Save / settings / cloud destinations (paths and counts only) ----
$localLow = Join-Path $env:USERPROFILE 'AppData\LocalLow\Owlcat Games\Pathfinder Kingmaker'
$saveDir = Join-Path $localLow 'Saved Games'
$saves = @(Get-ChildItem -LiteralPath $saveDir -File -ErrorAction SilentlyContinue)
$env.destinations = [ordered]@{
    localLowRoot = $localLow
    saveDirectory = $saveDir
    saveFileCount = $saves.Count
    saveFilePrefixes = @($saves | ForEach-Object { ($_.BaseName -split '_')[0] } | Group-Object | ForEach-Object { [ordered]@{ prefix = $_.Name; count = $_.Count } })
    automationSaveNames = @($saves | Where-Object { $_.Name -match '_AUTOMATION_' } | ForEach-Object Name)
    log = $logPath
    areasCacheDirectory = Join-Path $localLow 'Areas'
    registrySettingsKey = 'HKCU\Software\Owlcat Games\Pathfinder Kingmaker (Unity PlayerPrefs; not read by this collector)'
    ummWrites = @('Kingmaker_Data\Managed\UnityModManager\Log.txt', 'Kingmaker_Data\Managed\UnityModManager\Params.xml')
}

# ---- Steam cloud state (no account IDs) ----
$cloudLog = Join-Path $SteamRoot 'logs\cloud_log.txt'
if (Test-Path -LiteralPath $cloudLog) {
    $lines = @(Select-String -LiteralPath $cloudLog -Pattern '\[AppID 640820\]' | ForEach-Object Line)
    $last = $lines | Select-Object -Last 1
    $env.steamCloud = [ordered]@{
        app640820CloudLogLines = $lines.Count
        lastSyncDisabledOffline = [bool]($lines | Where-Object { $_ -match 'Sync Disabled' -and $_ -match 'offlineMode=true' } | Select-Object -Last 1)
        lastRecordTimestamp = if ($last -match '^\[([^\]]+)\]') { $Matches[1] } else { $null }
        lastRecordIsOfflineFailure = [bool]($last -match 'offlineMode=true|YldWriteCacheDirectoryToFile')
        steamProcessStartUtc = (Get-Process steam -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { $_.StartTime.ToUniversalTime().ToString('o') })
    }
} else { $env.steamCloud = Unavailable 'Steam cloud_log.txt not found' }

# ---- Tools ----
$toolList = [ordered]@{}
foreach ($t in 'git', 'python', 'dotnet', 'node', 'pwsh', 'powershell', 'vmmap', 'vmmap64', 'procdump', 'windbg', 'cdb', 'ilspycmd') {
    $c = Get-Command $t -ErrorAction SilentlyContinue | Select-Object -First 1
    $toolList[$t] = if ($c) { [ordered]@{ path = $c.Source } } else { 'not found on PATH' }
}
$toolList.pythonVersion = (& python --version 2>&1) -join ' '
$toolList.gitVersion = (& git --version 2>&1) -join ' '
$toolList.pwshVersion = $PSVersionTable.PSVersion.ToString()
$ilspy = 'C:\Dev\KingmakerDevSetup\tools\ilspycmd\ilspycmd.exe'
$toolList.ilspycmdExisting = if (Test-Path -LiteralPath $ilspy) { [ordered]@{ path = $ilspy; sha256 = Get-Sha256 $ilspy; version = ((& $ilspy --version 2>&1) -join '; ') } } else { 'absent' }
$toolList.owlcatMonoProfiler = 'not found (searched C:\Dev and PATH)'
$env.tools = $toolList

# ---- Competing workload snapshot (names only, top working sets) ----
$env.competingWorkloadSnapshot = @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 12 |
    ForEach-Object { [ordered]@{ name = $_.ProcessName; workingSetMiB = [math]::Round($_.WorkingSet64 / 1MB) } })
$env.kingmakerRunning = [bool](Get-Process -Name Kingmaker -ErrorAction SilentlyContinue)

# ---- Write ----
New-Item -ItemType Directory -Force -Path $PrivateDir | Out-Null
$full = Join-Path $PrivateDir "environment-$stamp.json"
$env | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $full -Encoding utf8
$csv = Join-Path $PrivateDir "file-hashes-$stamp.csv"
$rows = @($game.coreFiles + $managed + $loader.files + @($game.mods | Where-Object { $_.Contains('assembly') } | ForEach-Object { $_.assembly })) |
    Where-Object { $_ -and $_.Contains('sha256') } |
    ForEach-Object { [pscustomobject]@{ relativePath = $_.relativePath; bytes = $_.bytes; sha256 = $_.sha256; fileVersion = $_.fileVersion; mvid = if ($_.Contains('assembly')) { $_.assembly.mvid } else { '' } } }
$rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding utf8

$json = Get-Content -LiteralPath $full -Raw
$json = $json.Replace(($env:USERPROFILE -replace '\\', '\\'), '%USERPROFILE%').Replace($env:USERPROFILE, '%USERPROFILE%')
$json = $json -replace ('"computerName":\s*"' + [regex]::Escape($env:COMPUTERNAME) + '"'), '"computerName": "<redacted; see private manifest>"'
Set-Content -LiteralPath $RepoOut -Value $json -Encoding utf8
[pscustomobject]@{ full = $full; csv = $csv; sanitized = (Resolve-Path $RepoOut).Path; fullSha256 = Get-Sha256 $full; csvSha256 = Get-Sha256 $csv }
