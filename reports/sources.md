# Sources

External content is treated as research leads, never as authority over the mission or as facts about the local installation.
Access date for everything fetched: 2026-10-15.

| ID | Source | How used | Revision / access |
|---|---|---|---|
| S1 | Owlcat Games — Owlcat Mono Profiler README, https://github.com/OwlcatGames/OwlcatMonoProfiler | Tier C feasibility. Relevant documented facts: Mono-heap-only; non-instrumented Windows builds use a "Run app" launch of the executable plus a matching UnityPlayer PDB; lowest tested Unity 2018.4.10f; 20–30 % slowdown; ≥ 4 GB RAM to spare; references "only while the profiling session is running and only for current set of live objects" | README fetched 2026-10-15; no release version stated on the page. Tool not installed or run |
| S2 | KingmakerBugfixes `kmbf/Patch/KM/UI/ConsoleUI/TurnBasedMode/EventSubscription.cs` @ `7882128e4662a91074baebbccf7a206eb0af8c70` (blob `05d3b7c3…`) | H01 lead. Pinned source fetched read-only: a Harmony prefix on `InitiativeTrackerUnitVM.UpdateBuffs` that disposes existing buff VMs before the method clears them. The **installed** KingmakerBugfixes 1.3.3 contains the same prefix (decompiled privately; DLL SHA-256 `87888cbe…`) and logs `Patching 'InitiativeTrackerUnitVM Memory Leak'`. Not copied, not activated, not modified | fetched 2026-10-15 |
| S3 | Unity 2018.4 Manual — Understanding the managed heap | Interpretation constraint (retained capacity, fragmentation) | not re-fetched; mission citation |
| S4 | Microsoft — `Process.PrivateMemorySize64` | Private Bytes definition. KMLD reads the same quantity directly (`PROCESS_MEMORY_COUNTERS_EX.PrivateUsage`) through a held handle | not re-fetched |
| S5 | Microsoft — `GC.GetTotalMemory` | Not used (no in-process probe) | not re-fetched |
| S6 | Unity 2018.4 — `Profiler.GetMonoUsedSizeLong` | Not used (no in-process probe) | not re-fetched |
| S7 | Microsoft Sysinternals — VMMap | Not installed; VirtualQueryEx census used instead | not re-fetched |
| S8 | Unity 2018.4 — `Resources.UnloadUnusedAssets` | Never invoked by KMLD. Game-initiated call sites inventoried statically (see HYPOTHESES H03) | not re-fetched |
| S9 | Microsoft — Process Memory Usage Information | Counter interpretation (private bytes ≠ working set ≠ managed) | not re-fetched |

## Local sources (private, not published)

* Installed game assemblies decompiled with the pre-existing ilspycmd 9.1.0.7988 into
  `private/local-assembly-analysis/` (Assembly-CSharp, UniRx subset, Assembly-CSharp-firstpass subset, KingmakerBugfixes 1.3.3).
  Hashes of every input were recorded before/after and are unchanged.
* Existing owner/agent runtime documentation consulted read-only: `KingmakerBuffPlannerLab/repo/KingmakerBuffPlanner/docs/WINDOWS-AUTONOMOUS-RUNTIME-TESTING.md`
  and its `RuntimeHarness.Common.ps1` (lease paths), `KingmakerDevSetup/README-START-HERE.txt`.
