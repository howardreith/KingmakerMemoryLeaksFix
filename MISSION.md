# Mission

The governing mission is [`CODEX-KINGMAKER-MEMORY-DIAGNOSTICS-MISSION.md`](CODEX-KINGMAKER-MEMORY-DIAGNOSTICS-MISSION.md) (committed
by the owner as `008f4f8 add mission`; unchanged). It was executed by Claude Code on 2026-10-15 at the owner's request ("execute it as
the governing mission … investigation and diagnosis project only").

Local adaptations, all within the mission's allowances:

* **Lab location.** The owner created `C:\Dev\KingmakerMemoryLeakResearchLab` with this repository for the mission; it was used
  instead of the suggested `C:\Dev\KingmakerMemoryDiagnosticsLab` (which did not exist). The repository name contains "Fix", but no
  fix work is in scope.
* **Branch.** `codex/kingmaker-memory-diagnostics` (the mission's suggested name), local commits during the mission; pushed to `origin` with PR #1 afterwards at the owner's explicit request.
* **Runtime guard.** No pre-existing owner-authorized runtime workflow covers this mission (the Buff Planner and Gunslinger harnesses
  are project-owned). KMLD implements the same contract in `scripts/Invoke-KmldRun.ps1` and added an owner-presence check after
  incident `kmld-w01menu-m0-r1`. The W01 confirmation runs were explicitly authorized by the owner on 2026-10-15.
