# Safety audit

Final checks are re-run at the end of the mission; the "verified" column records the command that actually ran.

## Final checks — 2026-10-15 17:07 UTC (`pwsh -File scripts/Test-KmldSafetyAudit.ps1`, output in private `manifests/safety-audit-*.json`)

| Check | Result |
|---|---|
| Owned / any `Kingmaker.exe` processes | **none running** |
| KMLD sampler / watchdog / controller processes | **none running** |
| KMLD runtime lock | **absent** (every run released its lock; `-r2` via `Complete-KmldRun.ps1`) |
| Protected-save violation records | **none** |
| Foreign runtime leases (Buff Planner, Gunslinger) | none present; never created or removed by KMLD |
| Original saves | **95/95 identical** (SHA-256, size, mtime) to the first pre-launch snapshot (2026-10-15 08:37 local); none added or removed. Read-only save copies were hash-verified at copy time |
| Game, Unity, Mono, Doorstop, UMM and mod assemblies | **34/34 SHA-256 equal** to `environment.json` |
| Mod configuration | identity hash `71580945…` equal to the first preflight; same 16 mod folders; same 16 mods enabled in UMM |
| Repair mods | none installed or enabled by KMLD; KingmakerBugfixes 1.3.3 was already installed and enabled and is unchanged |
| Display PlayerPrefs | equal to the first pre-launch snapshot (`Use Native` 1, `ScreenResolution` 8, 1920×1080, mode 1); intermediate changes during the session were written by the game and reverted by later launches (see exception 4) |
| Steam | offline mode; every App 640820 exit record `Sync Disabled` / `offlineMode=true`; no cloud transfer |
| Fixes implemented | **none**. No game/mod/UMM file, save, cache, serialization or setting was changed by KMLD code; nothing calls `GC.Collect` or `UnloadUnusedAssets` |
| Temporary instrumentation | none injected into the game (all observation external: process queries, `VirtualQueryEx`, bounded `ReadProcessMemory`, one window minimize in `-r4`) |
| Unrelated projects | not modified: other `C:\Dev` labs were only read (docs, lease paths, the pre-existing ilspycmd); writes were confined to `C:\Dev\KingmakerMemoryLeakResearchLab`, the Claude memory folder for this project, and Python test temp dirs (auto-removed) |
| Public upload / push | **none**. Branch `codex/kingmaker-memory-diagnostics` has local commits only; `origin` untouched. Two read-only web fetches (Owlcat profiler README, pinned KingmakerBugfixes source) |
| Background tasks | all finished (run chains, monitors, sub-agents) |

## Exceptions and incidents (reported plainly)

1. **Unobserved launched process (run `kmld-w01menu-m0-r1`, 08:37–08:40 local).** A guard defect (empty `Win32_Process.ExecutablePath`
   for the just-created process) made the controller abort before binding, so it could neither observe nor close the game and it
   released its lock while the game ran. The owner closed the window at 08:40:07 (owner confirmed). Post-hoc verification against
   the pre-launch snapshot: 95/95 saves byte-identical; `Mods` and the game root content unchanged; Steam exit record
   `Sync Disabled`/`offlineMode=true`. Root cause fixed (`c9f8c3a`) with regression tests.
2. **Controller post-processing failure (run `-r2`).** After a graceful exit (WM_CLOSE, code 0) the verification step threw on an
   empty manifest, leaving the lock held and the manifest unfinalized. No process was left running. Verification was completed by
   `scripts/Complete-KmldRun.ps1` under the run's own lock (saves unchanged) and the lock was released. Fixed (`f511b8d`).
3. **Readiness marker defect (run `-r2`).** The previous session's log lines were read as the new session's main-menu marker; the
   idle window remained after real readiness (verified from `-r3`: readiness ≈ 35 s after launch, `-r2` idle began at 63 s).
4. **Owner settings written by the game.** Each launch makes the game/UMM/mods rewrite files and preferences as any normal launch
   does: UMM `Log.txt`/`Params.xml`; mods' `Settings.xml`/`loaded_blueprints.txt`/Gunslinger `FeatureModules.json(.previous)` (same
   SHA-256, new timestamps); `output_log.txt` (previous log preserved first); PlayerPrefs `unity.player_session_count`/`sessionid`.
   Additionally, across these launches the game rewrote **`ScreenResolution` (index 8 → 7)** and toggled
   **`Screenmanager Resolution Use Native`** (1 at 08:2x → 0 after the owner closed `-r1` → 1 after `-r2`). Width/height (1920×1080)
   and fullscreen mode are unchanged. KMLD did **not** write to the registry to undo this; the owner may want to check the in-game
   resolution selection.
5. **Console use.** `-r2`…`-r4` ran while the owner was active at the console, on the owner's explicit authorization ("Run now,
   3 runs").
