# Protocol W01a — main-menu idle (M0, external observation)

**Hypotheses addressed:** H05/H06 (time-dependent background growth without player action), H08 (collector overhead), baseline for
all later comparisons. **Distinguishing observation:** a non-zero, persistent slope of private bytes / handles / GPU memory over a
600 s main-menu idle window, versus a plateau.

## Preconditions (enforced by `scripts/Invoke-KmldRun.ps1` preflight; the run refuses otherwise)

* No `Kingmaker.exe` running; no KMLD lock; no unreviewed protected-save violation; no cancel file.
* No foreign runtime lease (`KingmakerBuffPlannerLab\runtime-state\deployment.lock`, `…\runtime-fixture-state\fixture.lock`,
  `KingmakerGunslingerLab\compatibility-state\compatibility.lock`, or any `*.lock` in those folders).
* Steam: exactly one client at the expected path; the last App 640820 cloud record is `Sync Disabled` + `offlineMode=true` and is
  newer than the Steam process start.
* App manifest build 6757524 == target, StateFlags 4; `Kingmaker.exe` and `Assembly-CSharp.dll` hashes equal `environment.json`.
* Available RAM − 6 GiB headroom ≥ max(2 GiB, 10 % installed); commit + headroom < 90 % of limit; ≥ 15 GiB free on C:.
* Console session idle ≥ 15 min, unless the owner explicitly authorizes the run (`-AllowActiveConsole -AuthorizationNote …`).

## Procedure (no input is ever sent to the game)

1. Lock (`runtime-state\kmld-runtime.lock`), snapshot: SHA-256 of every save; LocalLow top-level files; `Areas` listing; full `Mods`
   tree; UMM folder; game root; StreamingAssets listing; PlayerPrefs values. Copy the previous `output_log.txt`.
2. Launch `steam://rungameid/640820`. Find the new `Kingmaker.exe` by handle (creation ≥ launch − 5 s), bind, resolve the image path
   (must equal the installed exe), record PID + creation time.
3. Start the out-of-process sampler (1 s) and watchdog (hard deadline 1,800 s).
4. Phase `startup` until the **new** log's UMM line `[Manager] Spawning.` (MainMenu.Start completed). Lines of the previous
   session's log are ignored until the new log's first line `Initialize engine version` (fixed after pilot `-r2`).
5. Phase `menu-settle` 60 s. Phase `menu-idle` 600 s with VirtualQueryEx region censuses at idle start, middle and end. Any game log
   memory line (`Unloading … unused Assets`, `UnloadTime`) is recorded as an event.
6. Close: revalidate identity, `CloseMainWindow` (WM_CLOSE), wait ≤ 120 s, retry once ≤ 60 s, force only as a last resort on the
   verified process. Wait for the sampler to see the exit.
7. Snapshot again and diff; any save change ⇒ blocking violation record. Copy this run's `output_log.txt`. Write `manifest.json` with
   artifact hashes; release the lock (kept if any launched process is still alive).

## Analysis

`python -I scripts/kmld_analyze.py private/run-data/<run> --idle-phase menu-idle` — OLS slope per minute over the idle window (first
10 s excluded), early/late half slopes, head/tail 60 s medians, segment table, memory-map comparison. Natural collections are not
observable externally in this configuration; a collected object need not reduce private bytes (S3).

**Signal criterion (pre-declared before the confirmation runs):** report a time-dependent growth signal only if all valid runs show a
private-bytes idle slope > 0.5 MiB/min **and** a tail−head difference > 5 MiB, with the late-half slope not reversing sign. Smaller or
inconsistent effects are reported as "not reproduced under tested conditions" with the measured values.
