# Kingmaker Memory Diagnostics (KMLD)

Diagnosis-only investigation of memory growth in Pathfinder: Kingmaker 2.1.7b (Unity 2018.4.10f1, Mono bdwgc) on the owner's Windows
workstation. **Nothing here fixes, patches or cleans anything.** Governing mission: [`MISSION.md`](MISSION.md).

Start with **[`reports/FINDINGS.md`](reports/FINDINGS.md)** (executive diagnosis table), then `reports/COVERAGE.md` (what ran and what
is blocked) and `reports/SAFETY-AUDIT.md`.

## Layout

```text
C:\Dev\KingmakerMemoryLeakResearchLab\
  repo\KingmakerMemoryLeaksFix\      this Git repository (branch codex/kingmaker-memory-diagnostics; local commits only)
    environment.json, ENVIRONMENT.md  measured environment (sanitized)
    scripts\                          collectors, guarded runtime controller, sampler, watchdog, analysis
    tests\                            synthetic tool tests (PowerShell + Python unittest)
    protocols\                        workload procedures (W01 executed; attended session specified)
    reports\                          findings, coverage, hypotheses, evidence index, safety audit, sources
  private\                            outside Git: run data, save copies, decompiled code, manifests (never publish)
  runtime-state\                      KMLD runtime lock, cancel file, protected-save violation records
```

## Reproduce / reanalyse

```powershell
# environment (read-only)
pwsh -File scripts/Get-KmldEnvironment.ps1
# tool tests (synthetic only)
pwsh -File tests/Test-KmldTools.ps1
python -I -m unittest discover -s tests -p "test_*.py"
# preflight without launching
pwsh -File scripts/Invoke-KmldRun.ps1 -PreflightOnly
# W01 main-menu idle (launches Kingmaker through Steam; refuses while the console is in use unless the owner authorizes)
pwsh -File scripts/Invoke-KmldRun.ps1 -Workload W01-menu-idle -RunId kmld-w01menu-m0-rN
# reanalyse a run without the game
python -I scripts/kmld_analyze.py ..\..\private\run-data\kmld-w01menu-m0-r3 --idle-phase menu-idle
# save structure (copies originals read-only into private, then analyses copies)
python -I scripts/kmld_saves.py copy --src "%USERPROFILE%\AppData\LocalLow\Owlcat Games\Pathfinder Kingmaker\Saved Games" --dst ..\..\private\fixtures\save-copies
python -I scripts/kmld_saves.py analyze --copies ..\..\private\fixtures\save-copies --out ..\..\private\save-analysis\<name>
python -I scripts/kmld_save_report.py ..\..\private\save-analysis\<name> --sanitized-out reports\data\save-structure-sanitized.csv
```

Requirements: PowerShell 7 (pwsh), Python 3 (standard library only). No other dependency; nothing is installed.
