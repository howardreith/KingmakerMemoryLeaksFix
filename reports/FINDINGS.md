# Findings — Kingmaker memory diagnostics

**Completion label: Investigation partially completed.** Static ownership analysis, save-state analysis and tooling are complete, and
the only input-free runtime workload (W01 main-menu idle, configuration M0) was executed with owner authorization. Every gameplay
workload (W01b–W08) is blocked by the lack of an authorized input/driver path, save isolation and a loader-free configuration
(`COVERAGE.md`). **No leak is confirmed.** Nothing was fixed.

Scope of every statement: Pathfinder: Kingmaker 2.1.7b, Steam build 6757524, Unity 2018.4.10f1, Mono bdwgc, Assembly-CSharp
`3b6450ff…` (MVID `07fa1e4d…`), configuration **M0** = Doorstop + UMM 0.33.0 + 16 enabled mods including **KingmakerBugfixes 1.3.3**,
Windows 10 19045 on the owner's workstation. Not extrapolated to other versions, Linux/Proton or consoles.

## Executive diagnosis

<!-- W01-EXEC-ROW -->

| ID | Finding | Behaviour class | Evidence status | Magnitude | Main limitation |
|---|---|---|---|---|---|
| F-H04 | Save size grows with the number of persisted per-area states (and, in one campaign, an append-only text `history` log) | Persistent save-state growth | **Measured (descriptive, read-only copies)** | One campaign: 114.6 → 163.0 MiB uncompressed over 28.4 → 37.8 play-hours; r = 0.994 with persisted-area count (≈1.2 MiB per area); largest save 240.6 MiB incl. 26.8 MiB `history` (243,278 lines) | By design; runtime load cost not measured; campaigns confounded |
| F-H02a | Every return to the main menu leaves the previous `AuraSupport` subscribed to the static `EventBus` | Managed retention (small, per main-menu return) | **Static candidate only** — ownership path fully determined from installed code | Not measured; expected one small object graph (+ an `AuraService`) per return | No runtime count |
| F-H02b | Every return to the main menu leaves the previous `GameStatistic` subscribed (with its `GameHistoryLog` strings) | Managed retention (per main-menu return) | **Static candidate only** — ownership path fully determined from installed code | Not measured; bounded by history accumulated since the last save/load | No runtime count |
| F-H01b | Desktop turn-based UI can overwrite a live `InitiativeTrackerVM` without disposing it; an overwritten one stays rooted by `EventBus` + UniRx per-frame subjects with unit references | Managed retention + per-frame work (if triggered) | **Static candidate only** | Not measured | Only trigger found depends on an unreadable asset flag (settings reset during turn-based combat); may never occur |
| F-H01 | `InitiativeTrackerUnitVM.UpdateBuffs` discards `BuffVM`s without disposing them (public lead S2) | Allocation churn; bounded staleness | **Static candidate only — retention not supported** | Not measured | No global root holds discarded `BuffVM`s; **already patched in M0 by KingmakerBugfixes 1.3.3** |
| F-H03 | Asset/resource caches with weak eviction; main-menu return unloads assets *before* resetting game state | Bounded cache growth / lifecycle lag (candidate) | **Static candidate only** | Not measured | Most caches are content-keyed (warm-up), native sizes unknown |

Unexplained share of observed growth: **not estimable** — no gameplay growth was observed because no gameplay workload could run.

---

## Finding records

### F-H04 — Persistent save-state growth

* **Behaviour classification:** persistent save-state growth.
* **Evidence status / rationale:** measured on 95 read-only copies (originals hash-verified unchanged before/after copying; copies
  unchanged by analysis). Descriptive only: campaigns differ in age, areas, party and mod requirements.
* **Affected identities:** saves produced by this installation's history (header `Versions` lists, game 2.1.x); tool
  `scripts/kmld_saves.py` @ `04ec7ed`.
* **Configurations and fixtures:** no game process; 95 `.zks` files (57 campaigns by header `GameId`; 3 saves without a readable
  header).
* **Player-visible symptom:** larger saves and longer save/load (not measured here).
* **Minimal reproducer:** `kmld_saves.py copy` + `analyze` + `kmld_save_report.py` (README).
* **Exposure denominator:** play-hours (header `GameTotalTime`) and persisted-area count.
* **Independent runs and controls:** within-campaign series of 17 saves (campaign `ed8b7fd3`); cross-campaign comparison only
  descriptive.
* **Measured magnitude:** campaign `ed8b7fd3`: uncompressed 114.6 MiB at 28.4 h (70 area states, 73.8 MiB; 62 area-part states,
  35.1 MiB) → 159–163 MiB at 37.5–37.8 h (105–106 area states, 104.4 MiB; 79–80 parts, 47.5–51.3 MiB). Correlation with persisted
  area count r = 0.994, slope ≈ 1.20 MiB per area. Player ≈ 1.0 MiB, party ≈ 3 MiB. `history` absent/empty in this campaign.
  Campaign `7ab9f4e2` (one save, 30.0 h): 240.6 MiB uncompressed (31.6 MiB compressed), 107 area states (145.9 MiB), 86 parts
  (61.0 MiB), `history` 26.8 MiB = 243,278 timestamped text lines (Dialog 56 %, System 26 %, Area 10 %; several global-map entries
  repeated ≈7,200 times each). Across all saves, area states are the median 44.7 % of uncompressed bytes.
* **Warm-up/plateau:** none — monotonic with exploration by design.
* **Objects implicated:** per-area `AreaPersistentState` JSON (one per visited area, kept for the whole campaign) and per-scene-part
  states; `GameStatistic.GameHistoryLog` → `Areas\history` text file.
* **Allocation site / retaining root:** not applicable (persistence). Statically, non-current areas are stashed to
  `LocalLow\…\Areas` by `AreaDataStash` and unstashed on area load (with game-initiated `GC.Collect`), so the in-memory cost is
  *plausibly* limited to the current area plus per-area shells — **hypothesis, not measured**.
* **Expected vs observed lifetime:** campaign lifetime by design; no violation identified.
* **Alternative explanations tested:** n/a (descriptive).
* **Limitations:** load-time memory and duration not measured; history's runtime residency not established.
* **Contribution to total growth:** not estimable (no runtime growth measured).
* **Evidence:** `reports/data/save-structure-sanitized.csv` (sanitized); private `save-analysis/run-20261015/` (per-save JSON,
  `save-table.csv`, `save-report.md`), `fixtures/save-copies/copy-manifest-*.json`.
* **Smallest additional experiment:** N6 (fresh-process cold loads of the smallest vs largest save of campaign `ed8b7fd3`).

### F-H02a — Stale `AuraSupport` subscriber per main-menu return

* **Behaviour classification:** managed retention (candidate).
* **Evidence status:** static candidate only. The retention path is fully determined by installed code; accumulation, size and
  consequences are unmeasured.
* **Static implementation evidence (installed Assembly-CSharp):** `Game` has a field `AuraSupport = new AuraSupport()` (Game.cs:166);
  game initialisation calls `AuraSupport.Initialize()` (Game.cs:362), which creates an `AuraService` and calls
  `EventBus.Subscribe(this)`; `AuraSupport` has no unsubscribe or dispose path. Return to main menu calls `Game.Reset()`
  (Game.cs:1496–1514), which creates and initializes a **new** `Game`. `EventBus.GlobalSubscribers` is a `static readonly`
  `SubscriptionManager` holding subscribers in plain lists (strong references), never bulk-cleared (verified).
* **Expected vs observed lifetime:** expected to end with its `Game`; statically it lives until process exit.
* **Retaining root/path (static, not captured):** `EventBus.GlobalSubscribers` → per-interface `SubscribersList.List` → stale
  `AuraSupport` → `AuraService`, key-binding arrays. It does not appear to reference the old `Game` directly (handlers use
  `Game.Instance`) — not verified at runtime.
* **Exposure denominator:** returns to main menu. **Magnitude:** not measured.
* **Alternative explanations:** none tested at runtime. KingmakerBugfixes does not touch it (only its tracker patch was found).
* **Smallest additional experiment:** N1.

### F-H02b — Stale `GameStatistic` subscriber per main-menu return

* **Classification / status:** managed retention (candidate); static candidate only, path determined from code.
* **Static evidence:** `Game.Statistic = new GameStatistic()` (Game.cs:97); the constructor subscribes to `EventBus`
  (GameStatistic.cs:276–279); `Dispose()` (unsubscribe) has no callers; `Reset()` is empty; `Game.Reset()` calls only
  `Statistic.Reset()` before creating a new `Game`. Loading a save does unsubscribe the current instance
  (`GameStatistic.Deserialize`, GameStatistic.cs:252–255), so the stale instance is specifically the one alive at a main-menu return.
  Its handlers guard with `this == Game.Instance.Statistic`, so stale instances still receive every event.
* **Objects implicated:** `GameStatistic` incl. `GameHistoryLog` (`List<string>`, history since the last save/load).
* **Magnitude:** not measured. **Smallest additional experiment:** N1 (same census).

### F-H01b — Overwritten `InitiativeTrackerVM` (desktop path)

* **Classification / status:** managed retention + per-frame CPU (if triggered); static candidate only.
* **Static evidence:** `Kingmaker.UI.TurnBasedMode.TurnBasedModeUIController.ShowInitiativeTracker()` assigns
  `m_InitiativeTrackerVm = new InitiativeTrackerVM()` without disposing a previous instance. The VM subscribes to `EventBus` and
  `MainThreadDispatcher.LateUpdateAsObservable()`; each unit VM subscribes to `EventBus` and `UpdateAsObservable()` and holds
  `UnitEntityData`. UniRx `MainThreadDispatcher` is a DontDestroyOnLoad singleton whose subjects hold observers until disposed.
  The desktop controller is created per area (UI scene reload) and disposed on `OnAreaBeginUnloading` via its canvas (parent canvas
  not confirmed from scene data).
* **Trigger analysis:** party-combat events alternate true/false; settings **Apply** raises only on a value change; the area-load
  raise reaches a fresh controller. The only path found that re-raises `true` while the tracker is shown is **Settings → reset to
  defaults** during turn-based combat, and only if the turn-based setting has `ImmediateApplying` (asset flag, unread).
* **Magnitude / frequency:** unknown; may be zero in normal play. **Smallest experiment:** N2.

### F-H01 — `InitiativeTrackerUnitVM.UpdateBuffs` non-disposal (public lead S2)

* **Classification / status:** allocation churn with bounded staleness; static candidate only; **retention not supported** by the
  ownership analysis.
* **Static evidence:** installed `UpdateBuffs` calls `UnitBuffs.Clear()` and re-creates a `BuffVM` per displayed buff whenever the
  per-frame check sees `Unit.Buffs.Count` change. `BuffVM` (a `VMBase`) registers nothing global. Its referrers are the collection and
  a pooled `InitiativeTrackerBuffView`; `WidgetListMultiMVVM` reuses views and `ViewBase.Bind` unbinds the previous VM, so discarded
  VMs become unreachable once their view is rebound; hidden widgets keep at most a pool-size of stale VMs.
* **Desktop relevance:** the PC turn-based UI (`TurnBasedModeUIController`, `*PCView`) uses these `_ConsoleUI` view models, so the
  code does run on desktop when turn-based mode is used.
* **Configuration note:** **KingmakerBugfixes 1.3.3 is installed and enabled in M0; its always-on Harmony prefix disposes the buff VMs
  before `Clear()` and logs "Patching 'InitiativeTrackerUnitVM Memory Leak'"** in every observed launch. M0 measurements therefore
  cannot show the unpatched behaviour, and the patch does not address F-H01b.
* **Smallest experiment:** N3.

### F-H03 — Cache and teardown candidates

* **Classification / status:** bounded cache growth or lifecycle lag (candidates); static candidate only.
* **Static evidence (census, top items spot-checked):** `ResourcesLibrary.s_LoadedResources` caches resources with their bundles and
  evicts only in `CleanupLoadedCache` (counter-based; skipped on area loads that unload no scenes); no `startup.json` exists, so the
  "unload bundles" option is off. Return to main menu runs `UnloadUnusedAssetsCoroutine` (cleanup, `GC.Collect`,
  `Resources.UnloadUnusedAssets`) **before** `DisposeState()`/`Game.Reset()` (SceneLoader.cs ≈1049–1063, verified), with no later
  pass shown, so assets referenced only by the discarded state remain loaded until a subsequent unload.
  Other never-trimmed structures: `AnimationClipEventsCache`, custom-portrait and save-screenshot textures, firstpass
  `ListPool`/`ObjectPool`, `HotScenesManager` deactivated scenes.
* **Counterpoint:** many of these are keyed by content (bounded warm-up, not leaks).
* **Smallest experiments:** N4/N5 (with Unity's own `Loaded Objects now: X` lines per load).

<!-- W01-RECORD -->
