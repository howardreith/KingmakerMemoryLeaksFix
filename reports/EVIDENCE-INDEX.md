# Evidence index

Raw evidence is private (outside Git) under `C:\Dev\KingmakerMemoryLeakResearchLab\private\`. Paths below are relative to that
folder. Each run folder holds a `manifest.json` whose `artifact_paths_and_sha256` lists every artifact with its SHA-256; the hashes
are the integrity reference. Nothing here is published.

## Runtime runs (configuration M0, external observation, no profiler)

| Run ID | Purpose | Status | Valid for | Key artifacts |
|---|---|---|---|---|
| `kmld-preflight-dryrun-01` | preflight only | refused by a controller defect (StrictMode) before any check completed | tool history only | `events.csv` |
| `kmld-preflight-dryrun-02` | preflight only | 0 problems | environment/config identity (mod manifest hash, settings hash) | `preflight.json` |
| `kmld-preflight-dryrun-03` | preflight only (owner override) | 0 problems | — | `preflight.json` |
| `kmld-w01menu-m0-r1` | W01 attempt | **aborted** — guard defect; game ran ~185 s unobserved, closed by the owner | incident record only; **no samples** | `incident.json`, `snapshot-before.json`, `output_log.full-session-recovered.txt` |
| `kmld-w01menu-m0-r2` | W01 pilot | completed-recovered (controller post-processing failed; verification completed by `Complete-KmldRun.ps1`) | idle window valid (starts launch + 63 s, after main-menu readiness); settle window overlapped startup because readiness was mis-detected from the previous log | `samples.csv`, `memmap-idle-{start,mid,end}.{csv,json}`, `analysis.{json,md}`, `write-audit.json`, `snapshot-*.json`, `output_log.this-run.txt` |
| `kmld-w01menu-m0-r3` | W01 confirmation 1 + post-idle content census | completed | idle flat; census of pre-existing 4 MiB + 4 KiB blocks (Unity native content) | same as `-r2` + `content-census-idle-end.json` |
| `kmld-w01menu-m0-r4` | W01 confirmation 2 + post-idle census + 300 s minimized condition | completed | idle flat; minimized flat; window state sampled | same + `content-census-minimized-end.json`, `memmap-minimized-{start,end}`, `analysis-minimized/` |

Runtime state: `C:\Dev\KingmakerMemoryLeakResearchLab\runtime-state\` (lock, lock state, `protected-save-violations\` — empty).

## Static analysis (private)

| Evidence | Location | Integrity |
|---|---|---|
| Decompiled Assembly-CSharp (ilspycmd 9.1.0.7988) | `local-assembly-analysis/Assembly-CSharp-decompiled/` | input SHA-256 `3b6450ff…` unchanged before/after |
| UniRx subset, Assembly-CSharp-firstpass subset | `local-assembly-analysis/UniRx-decompiled/`, `firstpass-types/` | input hashes recorded in the notes; unchanged |
| KingmakerBugfixes 1.3.3 decompile | `local-assembly-analysis/KingmakerBugfixes-1.3.3-decompiled/` | DLL SHA-256 `87888cbe…` unchanged |
| H01 lifecycle notes | `local-assembly-analysis/notes/H01-initiative-tracker-lifecycle.md` | sub-agent output; key claims spot-verified (JOURNAL) |
| H02/H03 census | `local-assembly-analysis/notes/H02-H03-static-census.md`, `static-collection-census.csv`, `eventbus-subscription-census.csv` | sub-agent output; top claims spot-verified |

## Save analysis (private)

| Evidence | Location |
|---|---|
| Save copies + copy manifest (originals' hashes before/after) | `fixtures/save-copies/`, `fixtures/save-copies/copy-manifest-*.json` |
| Per-save structure JSON, table, report | `save-analysis/run-20261015/` |
| Sanitized table (published in repo) | `repo/.../reports/data/save-structure-sanitized.csv` |

## Pre-existing logs

| Evidence | Location |
|---|---|
| `output_log.txt` as found before any KMLD launch (last written 2026-10-14 06:44 UTC) | `existing-logs/output_log.preexisting-20261014T0644Z.txt` (SHA-256 `d19a7de0…`, equal to the source at copy time) |

## Tool validation (synthetic, not evidence about Kingmaker)

`tool-validation/tools-*` (PowerShell suite results), `tool-validation/census*`, `tool-validation/smoke-1`.
