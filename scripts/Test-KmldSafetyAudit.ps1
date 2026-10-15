#requires -Version 7.0
<#
.SYNOPSIS
  Read-only end-of-mission safety audit. Writes private\manifests\safety-audit-<stamp>.json and prints a summary.
  Compares the save folder with the earliest KMLD pre-launch snapshot, installation/loader binaries with environment.json,
  the mod configuration identity with the first preflight, and lists live processes/locks.
#>
[CmdletBinding()]
param(
    [string]$BaselineSnapshot = 'C:\Dev\KingmakerMemoryLeakResearchLab\private\run-data\kmld-w01menu-m0-r1\snapshot-before.json',
    [string]$BaselinePreflight = 'C:\Dev\KingmakerMemoryLeakResearchLab\private\run-data\kmld-preflight-dryrun-02\preflight.json'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KmldRuntime.Common.ps1')
if (-not ('Kmld.BoundProcess' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'KmldNative.cs') }
$env0 = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\environment.json') -Raw | ConvertFrom-Json -DateKind String
$snap = Get-Content -LiteralPath $BaselineSnapshot -Raw | ConvertFrom-Json -DateKind String
$pf = Get-Content -LiteralPath $BaselinePreflight -Raw | ConvertFrom-Json -DateKind String
$a = [ordered]@{ utc = (Get-Date).ToUniversalTime().ToString('o'); baselineSnapshot = $BaselineSnapshot }

$a.kingmakerProcesses = @(Get-KmldGameProcesses | ForEach-Object { "$($_.Pid) $($_.Path)" })
$a.kmldHelperProcesses = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match 'Start-KmldSampler|Start-KmldWatchdog|Invoke-KmldRun' } | ForEach-Object { "$($_.ProcessId) $($_.CommandLine.Substring(0, [Math]::Min(120, $_.CommandLine.Length)))" })
$a.kmldLockPresent = Test-Path -LiteralPath $script:KmldLockPath
$a.protectedSaveViolations = @(Get-ChildItem -LiteralPath $script:KmldViolationDir -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object Name)
$a.foreignLeases = @(Get-KmldForeignLeases)

$now = Get-KmldTreeManifest $script:KmldSaveDir
$cmp = Compare-KmldManifest @($snap.saves) $now
$a.saves = [ordered]@{ baselineCount = @($snap.saves).Count; nowCount = @($now).Count; unchangedVsPreLaunch = $cmp.unchanged; added = $cmp.added; removed = $cmp.removed; changed = $cmp.changed }

$bin = [ordered]@{}
foreach ($c in $env0.game.coreFiles) { if ($c.PSObject.Properties.Name -contains 'sha256' -and $c.sha256) { $bin[$c.relativePath] = (Get-KmldSha256 (Join-Path $script:KmldGameRoot $c.relativePath)) -eq $c.sha256 } }
foreach ($c in $env0.game.keyManagedAssemblies) { $bin[$c.relativePath] = (Get-KmldSha256 (Join-Path $script:KmldGameRoot $c.relativePath)) -eq $c.sha256 }
foreach ($c in $env0.game.loader.files) { if ($c.relativePath -match '\.dll$') { $bin[$c.relativePath] = (Get-KmldSha256 (Join-Path $script:KmldGameRoot $c.relativePath)) -eq $c.sha256 } }
foreach ($m in $env0.game.mods) { if ($m.PSObject.Properties.Name -contains 'assembly' -and $m.assembly) { $bin[$m.assembly.relativePath] = (Get-KmldSha256 (Join-Path $script:KmldGameRoot $m.assembly.relativePath)) -eq $m.assembly.sha256 } }
$a.binariesUnchanged = [ordered]@{ allEqual = -not ($bin.Values -contains $false); mismatches = @($bin.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object Key); checked = $bin.Count }

$mods = Get-KmldTreeManifest (Join-Path $script:KmldGameRoot 'Mods') -Recurse
$sb = [Text.StringBuilder]::new(); foreach ($r in @($mods | Where-Object { $_.path -match '\.(dll|json)$' -and $_.path -notmatch '(?i)settings|log' })) { [void]$sb.Append($r.path).Append('|').Append($r.sha256).Append("`n") }
$modHash = ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sb.ToString()))) -replace '-', '').ToLowerInvariant()
$a.modConfiguration = [ordered]@{ hashNow = $modHash; hashAtFirstPreflight = $pf.modManifestHash; equal = $modHash -eq $pf.modManifestHash
    modsFolders = @(Get-ChildItem -LiteralPath (Join-Path $script:KmldGameRoot 'Mods') -Directory | ForEach-Object Name) }
$ummParams = [xml](Get-Content -LiteralPath (Join-Path $script:KmldGameRoot 'Kingmaker_Data\Managed\UnityModManager\Params.xml') -Raw)
$a.ummEnabledMods = @($ummParams.Param.ModParams.Mod | Where-Object { $_.Enabled -eq 'true' } | ForEach-Object Id)

$prefsNow = Get-KmldPlayerPrefs
$a.displayPrefs = [ordered]@{}
foreach ($k in @($prefsNow.Keys | Where-Object { $_ -match 'Use Native|ScreenResolution_|Resolution Width|Resolution Height|Fullscreen mode' })) {
    $before = $snap.playerPrefs.PSObject.Properties[$k]
    $a.displayPrefs[$k] = [ordered]@{ atFirstLaunchSnapshot = $(if ($before) { $before.Value } else { $null }); now = $prefsNow[$k] }
}
$a.steam = Get-KmldSteamState
$a.repoGit = [ordered]@{ branch = (& git -C $PSScriptRoot rev-parse --abbrev-ref HEAD); head = (& git -C $PSScriptRoot rev-parse --short HEAD)
    statusPorcelain = @(& git -C $PSScriptRoot status --porcelain); remotes = @(& git -C $PSScriptRoot remote -v)
    unpushedVsOrigin = @(& git -C $PSScriptRoot log --oneline origin/main..HEAD 2>$null).Count }
$out = Join-Path $script:KmldLabRoot ("private\manifests\safety-audit-{0}.json" -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
Write-KmldJson $out $a
$a | ConvertTo-Json -Depth 6
