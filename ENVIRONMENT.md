# Environment (measured 2026-10-15)

Machine-readable record: [`environment.json`](environment.json) (sanitized: user profile → `%USERPROFILE%`, host name redacted;
full record and every file hash in the lab's private `manifests/environment-20261015T122357Z.json` and `file-hashes-20261015T122357Z.csv`).
Collector: `scripts/Get-KmldEnvironment.ps1` (read-only). Values below are copied from that record unless marked *observed*.

## Host

| Item | Value |
|---|---|
| Host ID | `hostId` in environment.json (SHA-256 prefix of the computer name) |
| OS | Windows 10 Pro 10.0.19045 (build 19045), x64; local console session (*observed*: `query session` shows `console` Active, not RDP) |
| CPU | AMD Ryzen AI MAX 385 w/ Radeon 8050S — 8 cores / 16 logical |
| RAM | 31.6 GiB installed; 10.3–12.1 GiB available during this mission (*observed* by preflights) |
| Commit | ~28–29 GiB committed of a 65.6 GiB limit; one 34 GiB page file on C: (not changed) |
| Capture disk | C: 952.8 GiB, ~483 GiB free |
| GPU | AMD Radeon 8050S (integrated/UMA), driver 32.0.31041.1004 (2026-08-16); a Microsoft Remote Display Adapter is also present. The game log reports D3D11 level 11.1 and "VRAM 32592 MB" (shared/UMA carve-out as reported by Unity) |
| Display/game graphics | Desktop 3840×2160; game PlayerPrefs: 1920×1080, fullscreen-window mode 1, VSync on, texture/shadow/light quality 2 (read-only registry read) |
| Competing workload | Other Claude Code and Codex sessions, Firefox, Steam (offline mode). Snapshot in environment.json. Not controlled; recorded per run |

## Game

| Item | Value |
|---|---|
| Install | Steam App 640820, `C:\Program Files (x86)\Steam\steamapps\common\Pathfinder Kingmaker`, build ID 6757524 (== target; StateFlags 4; no pending update) |
| Version | **2.1.7b** (UMM log: "Found game version string: '2.1.7b'"); `Version.info`: `2021-May-25 14:14 a7e887a561dd745cb5910fc4001cbe397f0f77b8` |
| Executable | `Kingmaker.exe` x64 (AMD64), file version 2018.4.10.10503941, SHA-256 `94a779c5…` |
| Unity Player | **2018.4.10f1 (a0470569e97b)** (game log); `UnityPlayer.dll` SHA-256 `537ff99b…` |
| Mono runtime | `MonoBleedingEdge\EmbedRuntime\mono-2.0-bdwgc.dll` (Boehm-Demers-Weiser, non-moving collector by name), SHA-256 `9dde653c…`; managed `mscorlib` 4.6.57.0 |
| Assembly-CSharp.dll | SHA-256 `3b6450ffec440e296e586f71c711b195aed144b28d53e1cbb29406d18fef5afb`, MVID `07fa1e4d-8618-41b3-9b8d-faa17d3b26f7` (unchanged by every analysis step) |
| Assembly-CSharp-firstpass.dll | SHA-256 `069a7362…`, MVID `57f03756-55de-42f5-8bb3-e983306082b2` |
| UniRx.dll | SHA-256 `bfee7eca…`, MVID `40cbbc24-b3ca-4ec5-a257-546f2dffd396` |
| Managed set | 109 DLLs, set hash `2725eff2…` |
| DLC | `DigitalRewards` folder present; save headers carry DLC fields (not further inventoried) |

## Loader and mods (configuration **M0**)

* **Loader: Unity Mod Manager 0.33.0.0** (game log), injected through the **Doorstop proxy** `winhttp.dll` (4.5.0.0) with
  `doorstop_config.ini` → `target_assembly = Kingmaker_Data\Managed\UnityModManager\UnityModManager.dll`. Harmony 1.2/2.x/"12" assemblies
  ship in the UMM folder. Doorstop injection does not require rewriting Assembly-CSharp; a pristine depot hash is not available offline,
  so "Assembly-CSharp unmodified" is **not proven**, only consistent with the Doorstop method.
* UMM `Params.xml`: `CheckUpdates=1` (no Nexus API key, so the check is a logged no-op), `ShowOnStart=1`; **all 16 mods enabled**;
  the game log of every observed launch reports `SUCCESSFUL LOADED 16/16 MODS`.

| Mod (folder) | Version | Notes |
|---|---|---|
| BagOfTricks | 1.16.4 | cheats/QoL |
| BetterVendors | 2.0.8 | |
| CallOfTheWild | 1.14.4c-2.1 | large content mod |
| CheatMenu | 1.2.3 | |
| CraftMagicItems | 2.1.0 | |
| EddicKingmakerRespec | 1.0 | |
| KingmakerBuffPlanner | 0.1.1-rc3 | owner's project (live install is an rc build) |
| **KingmakerBugfixes** | **1.3.3** | **repair mod; includes an `InitiativeTrackerUnitVM.UpdateBuffs` prefix ("InitiativeTrackerUnitVM Memory Leak"), always applied — game log line 94** |
| KingmakerDiceRoller | 0.1.6 | owner's project |
| KingmakerGunslinger | 0.0.140 | owner's project |
| KingmakerLastAzlantiPreserver | 0.1.1 | owner's project |
| ProperFlanking2 | 1.2.3-2.1 | |
| RacesUnleashed | 1.0.11 | |
| SkipIntro | 1.3.1 | |
| TweakOrTreat | 1.1.0 | |
| ZFavoredClass | 1.3.1 | |

Assembly hashes per mod are in environment.json (`game.mods[].assembly`). Configuration identity used by runs: `mod_manifest_hash`
`71580945d09325cbd454f5302ce29c8589186f081df6eb5ff353154622b0b6d4` (DLL + JSON files, excluding runtime settings/logs); PlayerPrefs
`settings_hash` `1ab338a6…` (preflight `kmld-preflight-dryrun-02`).

**Configuration ladder availability:** V0 (loader-free) **unavailable** — the live install has Doorstop + UMM and the mission forbids
altering it. L0/D0 **unavailable** without changing the live UMM configuration or Mods folder. **M0** = the installation as found,
externally observed. M-subsets unavailable for the same reason. No isolated second installation exists.

## Write destinations and isolation (established before any launch)

| Destination | Observed writer | Isolation |
|---|---|---|
| `%USERPROFILE%\AppData\LocalLow\Owlcat Games\Pathfinder Kingmaker\Saved Games` | game (saves, autosaves, quicksaves) | **Shared** with the owner's campaigns and other labs' fixtures. No redirection exists. Every file hashed before/after each KMLD run |
| `…\Pathfinder Kingmaker\output_log.txt` | Unity log, overwritten each launch | previous log copied into the run folder before launch |
| `…\Pathfinder Kingmaker\Areas` | area-state stash (`AreaDataStash`) during play | not touched by a main-menu run (listed before/after) |
| `…\Kingmaker_Data\Managed\UnityModManager\Log.txt`, `Params.xml` | UMM on every launch | normal launch writes; diffed |
| `Mods\*` | mods (settings/logs) | diffed (no changes observed) |
| `HKCU\Software\Owlcat Games\Pathfinder Kingmaker` | Unity PlayerPrefs | values diffed |
| Steam Cloud (App 640820) | Steam on launch/exit | **Steam in offline mode and Sync Disabled**, proven from `cloud_log.txt` in the current Steam session before each launch and re-checked after exit |

Autosave rotation cannot be contained for workloads that change area or save, because saves are not redirectable; this is the main
reason W02–W08 are blocked (see `reports/COVERAGE.md`).

## Runtime guard (this lab)

There is no generic owner-authorized runtime harness for this mission; the Buff Planner and Gunslinger harnesses are project-owned.
KMLD therefore uses its own guard (`scripts/Invoke-KmldRun.ps1`) implementing the same contract: Steam URL launch of App 640820 (never
the exe directly), Steam offline/Sync-Disabled proof, refusal on any running Kingmaker or foreign lease
(`KingmakerBuffPlannerLab\runtime-state\deployment.lock`, `…\runtime-fixture-state\fixture.lock`,
`KingmakerGunslingerLab\compatibility-state\compatibility.lock`), an exclusive KMLD lock, protected-save hashing, identity-bound
observation and close, an out-of-process watchdog, and (after incident `kmld-w01menu-m0-r1`) a console-presence check.

## Tools

| Tool | Status |
|---|---|
| PowerShell 7.6.7 (pwsh), Windows PowerShell 5.1 | used (pwsh) |
| Python 3.14.7 | used, standard library only, `-I` |
| .NET SDK 8.0.424 | present, not needed |
| Git 2.55 | used (local commits only) |
| ilspycmd **9.1.0.7988** (pre-existing at `C:\Dev\KingmakerDevSetup\tools\ilspycmd`, SHA-256 `d4486d03…`) | used read-only; outputs private |
| Owlcat Mono Profiler | **not installed**; acquiring/launching it is blocked (see COVERAGE) |
| Sysinternals VMMap / ProcDump, WinDbg/cdb | **not installed**; not installed by this mission. A VirtualQueryEx region census (`KmldNative.cs`) substitutes for a coarse map |
| PresentMon / frame-time provider | not available; frame time not measured |
| GPU memory | Windows PDH `\GPU Process Memory(pid_*)\Dedicated/Shared Usage` (validated against `Get-Counter`, exact match) |
