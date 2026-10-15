# AGENTS.md — Kingmaker Memory Diagnostics lab

Rules for any agent working in this repository. The governing mission is `MISSION.md`; if anything here conflicts with it, the
mission wins, and owner instructions win over both.

* **Diagnosis only.** Never implement, prototype or pseudocode a fix; never install or enable a repair mod; never clear game caches,
  unsubscribe game handlers, call `GC.Collect`/`GC.GetTotalMemory(true)`/`Resources.UnloadUnusedAssets`, or alter serialization.
* **Never modify** the game installation, the live `Mods` folder, UMM configuration, saves, PlayerPrefs, Steam settings, other
  `C:\Dev` projects or their locks/fixtures. Read-only inspection is allowed; record hashes before/after.
* **Runtime only through `scripts/Invoke-KmldRun.ps1`**: Steam URL launch of App 640820 (never the exe), preflight must pass, one
  owned process, identity-revalidated close. Do not launch while the console is in use unless the owner authorizes that run
  (`-AllowActiveConsole -AuthorizationNote`). Never take over, attach to or close a process this lab did not launch.
* Before any runtime work, inspect `C:\Dev\KingmakerMemoryLeakResearchLab\runtime-state\` (lock, state file, violations). Never delete
  a lock without establishing that its run's processes are gone; a protected-save violation blocks all runs until the owner reviews it.
* Raw evidence, save copies, decompiled code and personal paths stay in `..\..\private\` (outside Git). Inspect staged content
  before every commit. Never push, tag, publish or open PRs.
* Label synthetic data as synthetic; never cite tool tests as evidence about Kingmaker. Distinguish measured results from hypotheses;
  write "not measured" instead of guessing.
* Keep `STATUS.md`, `JOURNAL.md`, `RESUME.md` current at checkpoints.
