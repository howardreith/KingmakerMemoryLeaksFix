# Status (2026-10-15 17:10 UTC)

**Overall label: Investigation partially completed** — see `reports/FINDINGS.md`.

| Gate | State |
|---|---|
| A — workspace & environment | Done. `ENVIRONMENT.md`, `environment.json`, hypothesis/coverage registers |
| B — trustworthy measurements | Done. Tier A sampler (+ window/console covariates), watchdog, guarded controller with recovery, region census, read-only content census, analysis; 31 PowerShell + 16 Python synthetic tests pass |
| C — screening | W01a main-menu idle executed in M0: 3 fresh runs (pilot `-r2` grew +157 MiB/min; `-r3`, `-r4` flat; `-r4` minimized condition flat). W01b–W08 safely unavailable (input/driver, save isolation, configuration ladder) |
| D — diagnosis | Static ownership analysis done (H01/H01b/H02/H03); H04 save analysis done; W01 growth localized to native-allocator-sized private blocks, trigger not isolated (next: N0) |
| E — synthesis & audit | Done. Reports, evidence index, safety audit (all checks clean; exceptions listed) |

No owned process is running; no lock is held; no protected-save violation exists.
**Next safe action:** N0 in `reports/NEXT-INVESTIGATIONS.md` (needs owner authorization).
