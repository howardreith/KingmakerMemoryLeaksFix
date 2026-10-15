# Journal

Times are local (EDT, UTC−4) on 2026-10-15 unless stated. Only actions that actually ran are listed.

## Gate A — workspace and environment (08:15–08:30)

* Read the mission; inspected `C:\Dev` read-only. Applicable instructions: Buff Planner `AGENTS.md` and
  `docs/WINDOWS-AUTONOMOUS-RUNTIME-TESTING.md` (runtime contract: Steam App 640820 launch only, offline/Sync-Disabled proof,
  transactional Mods staging, protected-save hashing), lease paths in its `RuntimeHarness.Common.ps1`; `KingmakerDevSetup` README.
  No AGENTS.md existed in this lab.
* Live state: no Kingmaker process; Steam running (offline mode; last App 640820 record `Sync Disabled`, `offlineMode=true`); no
  foreign lease files; latest Buff Planner transaction `Restored`, `restorationVerified=True`. Other Claude Code and Codex sessions
  active (left untouched).
* Created branch `codex/kingmaker-memory-diagnostics` and `..\..\private\{fixtures,local-assembly-analysis,captures,run-data,manifests,existing-logs,save-analysis,tool-validation}`.
* Decompiled installed Assembly-CSharp with the pre-existing ilspycmd 9.1.0.7988 into private storage (11.7 s, 6,071 files; input
  SHA-256 `3B6450FF…` identical before/after).
* `scripts/Get-KmldEnvironment.ps1` → `environment.json` (sanitized) + private full record/CSV.
* Copied the pre-existing `output_log.txt` (last written 2026-10-14 02:44) to private storage (SHA-256 equal).
* Static reading of `InitiativeTrackerUnitVM`, `BuffVM`, `BaseDisposable`, `ViewBase`, `InitiativeTrackerBuffView`,
  `WidgetListMultiMVVM`, `InitiativeTrackerVM`, `TurnBasedModeUIController`, `InGameUiStaticPartContext` (findings in HYPOTHESES).
* Delegated two read-only static analyses to sub-agents (H01 lifecycle incl. KingmakerBugfixes and UniRx; H02/H03 census). Both were
  interrupted by an API usage limit (~08:45) and resumed at 12:02; their key claims were spot-verified by direct reading
  (EventBus storage/dedup, KingmakerBugfixes prefix, `OnAreaDidLoad` raise, settings callbacks, `AuraSupport`, `Game.Reset`,
  `GameHeapSnapshot`, main-menu teardown order, `AreaDataStash`).

## Gate B — measurement tools (08:25–08:37)

* Wrote `KmldNative.cs`, `Start-KmldSampler.ps1`, `KmldRuntime.Common.ps1`, `Start-KmldWatchdog.ps1`, `Invoke-KmldRun.ps1`,
  `tests/Test-KmldTools.ps1`. Smoke test on a synthetic child; GPU reader cross-checked with `Get-Counter` (exact).
* Tool tests: 20/21 (test-design error), then 21/21 twice. Preflight dry runs `-01` (StrictMode defect, fixed) and `-02` (0 problems).
* Commit `9b52dba`.

## Incident — run `kmld-w01menu-m0-r1` (08:37–08:40)

* Launched via `steam://rungameid/640820` at 08:37:02. `Win32_Process.ExecutablePath` was empty for the new process; the controller
  threw before binding, its error path had nothing bound to close, and it released the lock at 08:37:10 while the game kept running.
  No samples, no watchdog. The owner closed the game window at 08:40:07 (owner confirmed at ~12:15).
* Verified at 12:03 against the pre-launch snapshot (content hashes): 95/95 saves identical (hash, size, mtime), none added/removed;
  `Mods` and game root unchanged; only UMM `Log.txt`/`Params.xml` and `output_log.txt` rewritten (normal launch writes); Steam exit
  record `Sync Disabled`, `offlineMode=true`. `incident.json` written; manifest marked `aborted-controller-error-process-unobserved`.
* Fix (commit `c9f8c3a`): handle-based discovery and image path; error path closes any process launched by the run; lock retained
  while any post-launch process lives; console-presence preflight. Regression tests → 28/28.
* A session pause (API usage limit) lasted from ~08:45 to 12:00.

## Static/offline work (12:00–12:20)

* Python analysis (`kmld_analyze.py`) and save tooling (`kmld_saves.py`, `kmld_save_report.py`) with synthetic tests: 16/16.
* `kmld_saves.py copy`: 95 saves copied to private fixtures; all originals unchanged (hash before/after), all copies verified (444 MB).
* `kmld_saves.py analyze`: 95/95 analysed in 16 s, none rejected, copies unchanged → save report (H04).
* Commit `04ec7ed`.

## Gate C — W01 runs (owner-authorized)

* Console idle was 9.4 → 10.4 → 0.0 min (owner active) so the 15-min rule refused launching; asked the owner, who chose
  "Run now, 3 runs" (~12:15).
* `kmld-preflight-dryrun-03` with `-AllowActiveConsole`: 0 problems. Chain started 12:18:20 (runs `-r2`, `-r3`, `-r4`).
* `-r2` logged `main-menu-ready` 2.9 s after launch from the **previous** session's log lines (defect). Fixed for later runs (commit
  `b8edd27`, before `-r3` started); `-r2` is kept as a pilot with the deviation recorded.
* W01 signal criterion pre-declared and committed (`44e2f55`) before `-r3`/`-r4` data existed and before `-r2` samples were viewed.
