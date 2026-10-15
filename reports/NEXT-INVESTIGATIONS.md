# Next diagnostic questions (smallest experiments)

This is not a fix roadmap. Each item names the uncertainty, the smallest experiment that would resolve it, and the authorization it
needs that this mission did not have.

| # | Question | Smallest discriminating experiment | Needs |
|---|---|---|---|
| N0 | **Highest priority.** Does main-menu idle grow when the game starts in display state `Use Native = 0` (as in pilot `-r2`, +157 MiB/min), and what fills the new 4 MiB + 4 KiB blocks? | One fresh W01 run with `Use Native = 0` at start (set before launch and restored after, or equivalent Unity screen arguments passed through Steam), `-ContentCensusAtEnd` so the **new** blocks are censused, window state sampled; if it grows, 3 runs per state | Owner authorization to change (and restore) the display PlayerPrefs or pass launch arguments; ~15 min per run |
| N1 | Does the stale-`AuraSupport`-per-main-menu-return path (H02) accumulate at runtime, and how much does it retain? | 5 owner-attended main-menu ↔ game round trips (load the same fixture, return to menu) under M0 with a Tier B census of `EventBus.GlobalSubscribers` by concrete type at each main-menu arrival. Expected if the static path holds: +1 `AuraSupport` per return | Owner-attended session (input) + Tier B probe deployment authorization, or the built-in `-menu-snapshot` crawler as a separately authorized collection experiment |
| N2 | Can H01b (overwritten `InitiativeTrackerVM`) occur in normal play? | Read the two asset flags (`ImmediateApplying`, `SaveWithTheGame`) on `SettingsRoot.EnableTurnBasedMode` — e.g. from the blueprint/asset data or an in-process read; if `ImmediateApplying` is true, one attended turn-based fight with Settings → reset-to-defaults and a Tier B count of live `InitiativeTrackerVM` subscribers before/after | Asset read (static or Tier B); attended session |
| N3 | Is H01 (`BuffVM` non-disposal) observable at all without KingmakerBugfixes? | W05 on a configuration without KingmakerBugfixes using a compatible fixture, counting `BuffVM`/`InitiativeTrackerBuffView` instances across 50 buff changes and the next natural collection (e.g. area transition, which calls `GC.Collect`) | Isolated installation or owner-approved transactional mod switching + compatible fixture |
| N4 | Does reloading the same save in one process (W02) grow settled private bytes / handles / GPU memory per cycle after warm-up? | Owner-attended W02 (`protocols/attended-session.md`): 2 warm-up + 20 measured reloads, settle 30 s, plus the game's own `Unloading N unused Assets … Loaded Objects now: X` lines per cycle (logged by Unity on each load) | Owner-attended session (no save writes) |
| N5 | Does area cycling (W03) retain resources (`ResourcesLibrary` cache, bundles, scenes, GPU)? | Owner-attended W03 with region census + GPU counters per cycle and `Loaded Objects now` per load | Attended session + autosave containment decision |
| N6 | What does cumulative save state (H04) cost at load time? | Fresh-process cold loads of the smallest (114.6 MiB) and largest (163.0 MiB) saves of the same campaign (`ed8b7fd3`), 3 runs each, measuring peak and settled private bytes and time to area-ready | Attended loads; confirmation that the campaign's mod requirements match M0 |
| N7 | How much of process memory is Mono heap vs Unity native vs driver? | Tier B read-only counters (`Profiler.GetMonoHeapSizeLong`, `GetMonoUsedSizeLong`, `GetTotalAllocatedMemoryLong`, `GetTotalReservedMemoryLong`, `GC.CollectionCount` if supported by this Mono) sampled on the main thread every 5 s, joined to Tier A by timestamp | Probe deployment authorization (observation-only assembly in live `Mods`, D0/MD labelling) |
| N8 | Which objects survive equivalent boundaries (ownership graphs)? | Owlcat Mono Profiler on a disposable session, references captured live before termination; or the built-in UnityHeapCrawler snapshot at the main menu after N round trips (diff mode exists) | Profiler acquisition + launch arrangement compatible with the Steam guard; or explicit authorization of a GC-forcing collection experiment |
| N9 | Are mods (H07) contributors? | Matched M0 vs M-subset comparisons (e.g. without the owner's verbose-logging dev mods) on one compatible fixture | Isolated installation / transactional configuration switching |

## Tier B probe specification (not built)

Observation-only UMM assembly, labelled **D0/MD** (never "vanilla"):

* Runs on the Unity main thread from a single `LateUpdate` hook every 5 s (bounded); no Harmony patches on game methods.
* Reads: Unity `Profiler` memory counters (verify non-zero first), `GC.GetTotalMemory(false)`, a census of
  `EventBus.GlobalSubscribers`' internal lists (count per concrete type, via reflection, copying only type names and counts),
  `ResourcesLibrary.LoadedResources` count, `Game.Instance` identity hash (to detect resets).
* Never stores references to game objects; never calls `GC.Collect`, `GC.GetTotalMemory(true)` or `Resources.UnloadUnusedAssets`.
* Writes one bounded CSV (row cap, drop counter) under a lab-owned path passed by command-line argument; disposes only its own
  file handle; records its own overhead (time per census).
