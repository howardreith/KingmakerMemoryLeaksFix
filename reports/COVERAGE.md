# Coverage and blockers

Classification: **completed**, **not applicable**, **safely unavailable**, **inconclusive**, **not attempted** (with reason).
Configuration for every runtime item: **M0** (installation as found: Doorstop + UMM 0.33.0 + 16 enabled mods incl. KingmakerBugfixes
1.3.3), external observation only, no profiler attached, Steam offline + Sync Disabled.

## Priority workloads (mission §7.3)

| ID | Workload | Status | Exposure actually obtained | Reason / smallest missing prerequisite |
|---|---|---|---|---|
| W01a | Main-menu idle, 10 min | **Completed (3 fresh runs) — inconclusive across runs**: `-r2` +157 MiB/min, `-r3`/`-r4` flat; post-idle minimized condition (`-r4`, 300 s) flat. See FINDINGS F-W01 | 3 × 600 s idle + 300 s minimized | First attempt `-r1` aborted (guard defect, 0 samples; incident record). Owner-authorized runs ("Run now, 3 runs"). A matched `Use Native = 0` run (N0) needs further owner authorization |
| W01b | Loaded-area idle, 10 min | **Safely unavailable** | none | Loading a save requires GUI input or an in-process driver. KMLD sends no synthetic input to a shared desktop and has no authorized in-game driver; an in-process driver would be a D0-class instrumentation deployed into the live `Mods` folder (not authorized for this lab). Idle in a loaded area is also exposed to autosave/time-based writes into the shared save folder |
| W02 | Reload identical fixture ×20 | **Safely unavailable** | none | Same input/driver blocker. Fixture handling would be possible (copy an existing baseline to `KMLD_AUTOMATION_BASELINE_*`), but the save folder is shared with the owner's campaigns and two other labs' fixtures, and no redirection exists |
| W03 | Area A→B→A ×10 | **Safely unavailable** | none | Area transitions write **autosaves** into the shared save folder (rotation can replace the owner's `Auto_*` files). No containment exists without changing game settings or the save location; plus the input/driver blocker |
| W04 | Encounter cycles (RTwP / turn-based) | **Safely unavailable** | none | Input/driver blocker; resetting the encounter requires loads (W02 exposure) |
| W05 | Turn-based buff-display hold/changes (H01) | **Safely unavailable**, and **not informative in M0** | none | Input/driver blocker; additionally M0 contains KingmakerBugfixes 1.3.3 whose always-on prefix disposes the `BuffVM`s that H01 is about (patch logged as applied), so M0 cannot reproduce the unpatched behaviour. A meaningful W05 needs a dependency-safe configuration without KingmakerBugfixes and a compatible fixture |
| W06 | UI open/close ×50 | **Safely unavailable** | none | Input/driver blocker |
| W07 | Repeated saves ×10 | **Safely unavailable** | none | Writes into the shared save folder (slot topology, quicksave/manual numbering); plus the input/driver blocker |
| W08 | Extended mixed workload | **Not attempted** | none | Depends on a positive screening signal from W02–W07 |

## Measurement tiers

| Tier | Status | Notes |
|---|---|---|
| A — external process sampler | **Completed & validated** | 28 synthetic tool tests pass (identity binding by handle, refresh, exit, cancellation, partial output, cap, markers, limit breach, outside-root refusal, watchdog, launch-path regression). GPU PDH reader matches `Get-Counter` exactly |
| B — in-process observation | **Not built (not needed yet / no isolated runtime)** | Requires deploying an assembly into the live `Mods` folder of a shared installation and a workload that exercises gameplay. Specification in `NEXT-INVESTIGATIONS.md` |
| C — managed allocation/reference profiling | **Blocked** | Owlcat Mono Profiler is not installed (no approved acquisition channel recorded); for non-instrumented builds it launches the executable itself ("Run app"), which bypasses the Steam launch guard; needs a matching UnityPlayer PDB. The game's **built-in** `GameHeapSnapshot` (UnityHeapCrawler, `-start-snapshot`/`-menu-snapshot`) exists but calls `GC.Collect()` twice and writes a `snapshot-*` folder relative to the working directory — a collection intervention and an install write, so not authorized here |
| D — native/resource accounting | **Partially available** | VirtualQueryEx region census (type × state, image modules, private allocation-size buckets) validated synthetically and captured at W01 idle start/mid/end. VMMap/ProcDump not installed (not installed by this mission). GPU per-process dedicated/shared counters available; frame time unavailable |

## Static and offline work

| Item | Status |
|---|---|
| Environment inventory (hashes, MVIDs, versions, loader, mods, destinations) | Completed (`ENVIRONMENT.md`, `environment.json`) |
| H01 installed-code inspection incl. desktop call path and KingmakerBugfixes comparison | Completed (static) |
| H02/H03 static census (static collections, EventBus subscribe/unsubscribe, caches, game-initiated GC/unload sites, teardown) | Completed (static; regex-based census with manual review of top candidates) |
| H04 read-only save analysis (95 copies, originals hash-verified unchanged) | Completed (descriptive) |
| Existing-log review (UMM/mod load, KingmakerBugfixes patch application, MVVM logging availability) | Completed |
| Mod code review beyond KingmakerBugfixes' tracker patch | Not attempted (scope; mods inventoried only) |
| Owlcat.Runtime / UniRx / DOTween static census | Partially (UniRx `MainThreadDispatcher`/subjects only) |

## Exact blockers (smallest missing prerequisite)

1. **Gameplay workload driver** — owner authorization for either (a) an attended session following `protocols/attended-session.md`
   while the KMLD sampler records, or (b) a lab-owned in-process workload driver deployed transactionally into `Mods` (same contract
   as the Buff Planner harness) with per-run allowances.
2. **Save isolation for area/save workloads** — an owner decision on autosave containment (e.g. a dedicated fixture campaign whose
   autosaves may rotate, or a separate Windows profile/installation). KMLD will not declare existing saves disposable.
3. **Configuration ladder** — a second, isolated installation (or owner-approved transactional Mods/UMM switching) to obtain L0 and
   KingmakerBugfixes-free comparisons with a compatible vanilla fixture.
4. **Tier C** — an approved acquisition of Owlcat Mono Profiler plus a Steam-compatible launch arrangement and the matching
   UnityPlayer PDB; or separate authorization for the built-in `GameHeapSnapshot` (a GC-forcing collection experiment).
