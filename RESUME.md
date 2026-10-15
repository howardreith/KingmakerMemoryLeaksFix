# Resume

1. **Inspect live state first:** `Get-Process Kingmaker`; `C:\Dev\KingmakerMemoryLeakResearchLab\runtime-state\` — a
   `kmld-runtime.lock` (+ `.state.json`) means a run did not finish: if its game process (pid + creation time in the state file) is
   gone, run `pwsh -File scripts/Complete-KmldRun.ps1 -RunId <run>`; never delete the lock by hand. Any file in
   `runtime-state\protected-save-violations\` blocks runs until the owner reviews it.
2. Check foreign leases (Buff Planner `deployment.lock`/`fixture.lock`, Gunslinger `compatibility.lock`) — the controller refuses
   while any exists.
3. Read `STATUS.md`, `reports/FINDINGS.md`, `reports/COVERAGE.md`, the end of `JOURNAL.md`.
4. The next safe actions are listed in `reports/NEXT-INVESTIGATIONS.md`. Runtime runs need: console idle ≥ 15 min, or explicit owner
   authorization recorded with `-AllowActiveConsole -AuthorizationNote`. Gameplay workloads need the owner decisions listed in
   COVERAGE "Exact blockers".
5. Reanalyse without the game: `python -I scripts/kmld_analyze.py ..\..\private\run-data\<run> --idle-phase menu-idle`,
   `python -I scripts/kmld_compare_runs.py <run dirs…>`, `python -I scripts/kmld_census_report.py <run dir>`.
