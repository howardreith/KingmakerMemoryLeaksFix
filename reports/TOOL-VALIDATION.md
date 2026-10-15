# Tool validation

All tests below use **synthetic** targets or data created by the tests themselves (disposable `pwsh` children that allocate memory,
disposable Notepad instances, generated CSVs and zip archives). Their outputs live in `private/tool-validation/` or temporary
directories and are **never** runtime evidence about Kingmaker. A passing suite proves only the tested tool behaviour; it does not
prove observational neutrality, profiler completeness, or anything about a leak.

## Commands that ran

| Suite | Command (from repo root) | Result |
|---|---|---|
| Sampler / watchdog / runtime helpers | `pwsh -NoProfile -File tests/Test-KmldTools.ps1` | **28/28 pass** (final run `tools-20261015T160508Z`; earlier runs: 21/21 twice before the regression tests were added; one first-run failure was a test-design error — the child allocated before sampling began — fixed by a quiet baseline) |
| Analysis | `python -I -m unittest discover -s tests -p "test_*.py"` | **16/16 pass** (10 analysis + 6 save-analyzer tests) |
| GPU counter reader | ad hoc cross-check of `Kmld.GpuCounters` against `Get-Counter '\GPU Process Memory(pid_N_*)\…'` on a GPU-using process | exact match (dedicated 513,085,440 B; shared 55,201,792 B) |
| Controller preflight | `scripts/Invoke-KmldRun.ps1 -PreflightOnly` (`kmld-preflight-dryrun-02`, `-03`) | 0 problems; the first dry run (`-01`) exposed a StrictMode `.Count` defect, fixed before any launch |

## What is covered

**Sampler (`Start-KmldSampler.ps1`, `KmldNative.cs`)** — binds to PID + creation FILETIME through a held process handle (PID reuse
impossible while bound); refuses a wrong creation time; refreshes every sample (staircase of 3×64 MiB observed: +214 MiB); stops on
target exit, cancellation file, duration and CSV cap, preserving partial output and recording a SHA-256; stamps cycle/phase markers;
records limit breaches without touching the target; refuses writes outside the lab and unsafe/reused run IDs; leaves unavailable
metrics empty with an explanation in `metric_status` (never zero); records its own private bytes separately.

**Watchdog (`Start-KmldWatchdog.ps1`)** — closes the verified target after the controller dies (graceful WM_CLOSE observed); refuses
to act on a mismatched identity.

**Runtime helpers (`KmldRuntime.Common.ps1`)** — manifest diffing; JSON writes refused outside the lab; VirtualQueryEx census
(≈1,850 regions in ≈10 ms on a synthetic process); **regression for incident `kmld-w01menu-m0-r1`**: a just-launched process is found
by handle, its image path resolved via `QueryFullProcessImageName`, close refuses path or identity mismatch, close of the owned process
is graceful; console idle time readable.

**Analysis (`kmld_analyze.py`)** — plateau (|slope| < 0.2 MiB/min), linear growth (3.0 ± 0.15 MiB/min recovered), warm-up then
plateau (early ≫ late slope), staircase cycles (12.0 ± 0.5 MiB/cycle; peak recovered), one-time warm-up excluded by warm-up cycles,
missing values not treated as zero, duplicate / mismatched run-ID / mismatched identity / time-reversed / truncated rows counted and
excluded, insufficient data reported, outputs labelled synthetic.

**Save analysis (`kmld_saves.py`)** — rejects traversal, absolute, drive-letter and control-character member names without extracting;
member size limit and compression-ratio (zip-bomb) limit; structural scan counts (`$type`, arrays incl. empty and scalar arrays, key
spans); copy step keeps originals byte-identical and refuses destinations outside the lab; analysis leaves copies unchanged;
corrupt archives reported, not raised.

## Known limits of the tools

* Thread counts come from a system-wide Toolhelp snapshot (≈20–45 ms per sample on this host); sample duration is recorded.
* GPU counters are WDDM per-process accounting summed over adapters (UMA device here): not attributable to textures/buffers, and not
  a VRAM-only figure on an integrated GPU.
* The region census localizes memory by type/state/allocation size; it cannot attribute private memory to Mono vs Unity native vs
  driver allocations.
* Game-log markers depend on UMM lines (`[Manager] Spawning.`). Pilot run `-r2` showed the previous session's log must be skipped until
  the new log starts; fixed in commit `b8edd27` and applied from run `-r3`.
* The save structure scanner is a tokenizer, not a validating JSON parser; it reports structure, not semantics.
