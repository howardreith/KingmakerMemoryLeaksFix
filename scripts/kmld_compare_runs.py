"""Cross-run comparison for W01 runs: idle slopes and candidate covariates (display PlayerPrefs at run start, GPU memory,
CPU, window state when recorded). Reads each run's analysis.json (run kmld_analyze.py first), preflight.json, samples.csv.
Usage: python -I scripts/kmld_compare_runs.py <run_dir> [<run_dir> ...] [--csv out.csv]
"""
import csv
import json
import os
import statistics
import sys

MIB = 1048576.0
PREF_KEYS = {"use_native": "Screenmanager Resolution Use Native", "resolution_index": "ScreenResolution_",
             "width": "Screenmanager Resolution Width", "height": "Screenmanager Resolution Height", "fullscreen_mode": "Screenmanager Fullscreen mode"}


def pref(prefs, prefix):
    for k, v in (prefs or {}).items():
        if k.startswith(prefix):
            return v
    return None


def row_for(rd):
    a = json.load(open(os.path.join(rd, "analysis.json"), encoding="utf-8"))
    pf = json.load(open(os.path.join(rd, "preflight.json"), encoding="utf-8-sig"))
    ev = list(csv.DictReader(open(os.path.join(rd, "events.csv"), encoding="utf-8-sig")))
    launch = next((float(e["elapsed_ms"]) for e in ev if e["event"] == "launch"), None)
    ready = next((float(e["elapsed_ms"]) for e in ev if e["event"] == "main-menu-ready"), None)
    idle_start = next((float(e["elapsed_ms"]) for e in ev if e["event"] == "phase" and e["detail"].endswith("menu-idle")), None)
    idle = a.get("idle") or {}
    pb = idle.get("private_bytes") or {}
    ws = idle.get("working_set_bytes") or {}
    seg = next((s for s in a.get("segments", []) if s["phase"] == "menu-idle"), {})
    fg = mn = None
    rows = list(csv.DictReader(open(os.path.join(rd, "samples.csv"), encoding="utf-8-sig")))
    idle_rows = [r for r in rows if r["phase"] == "menu-idle"]
    if idle_rows and "game_foreground" in idle_rows[0]:
        vals = [int(r["game_foreground"]) for r in idle_rows if r["game_foreground"] not in ("", "-1")]
        fg = statistics.mean(vals) if vals else None
        mvals = [int(r["game_minimized"]) for r in idle_rows if r["game_minimized"] not in ("", "-1")]
        mn = statistics.mean(mvals) if mvals else None
    out = {"run": os.path.basename(os.path.normpath(rd)), "status": a.get("manifest_status"),
           "ready_after_launch_s": (ready - launch) / 1000 if ready and launch else None,
           "idle_start_after_launch_s": (idle_start - launch) / 1000 if idle_start and launch else None,
           "idle_slope_private_MiB_per_min": pb.get("slope_per_min"), "idle_early_slope": pb.get("early_half_slope_per_min"),
           "idle_late_slope": pb.get("late_half_slope_per_min"), "idle_tail_minus_head_MiB": pb.get("tail_minus_head"),
           "idle_head_private_MiB": pb.get("head_median"), "idle_tail_private_MiB": pb.get("tail_median"),
           "idle_slope_ws_MiB_per_min": ws.get("slope_per_min"),
           "gpu_dedicated_MiB": (seg.get("gpu_dedicated_bytes") or {}).get("median", 0) / MIB if seg.get("gpu_dedicated_bytes") else None,
           "gpu_shared_MiB": (seg.get("gpu_shared_bytes") or {}).get("median", 0) / MIB if seg.get("gpu_shared_bytes") else None,
           "idle_cpu_percent_one_core": seg.get("cpu_percent_one_core"), "foreground_fraction": fg, "minimized_fraction": mn,
           "peak_private_MiB": (a.get("peak_private") or {}).get("MiB")}
    for k, p in PREF_KEYS.items():
        out["start_" + k] = pref(pf.get("playerPrefs"), p)
    return out


def main(argv):
    out_csv = None
    if "--csv" in argv:
        i = argv.index("--csv"); out_csv = argv[i + 1]; argv = argv[:i] + argv[i + 2:]
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    rows = [row_for(rd) for rd in argv]
    keys = list(rows[0].keys())
    for k in keys:
        print(f"{k:<34}" + "".join(f"{('n/a' if r[k] is None else (f'{r[k]:.2f}' if isinstance(r[k], float) else str(r[k]))):>26}" for r in rows))
    if out_csv:
        with open(out_csv, "w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=keys); w.writeheader(); w.writerows(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
