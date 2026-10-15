"""KMLD run analysis (Python standard library only).

Reanalyses a run directory produced by Invoke-KmldRun.ps1 without relaunching the game:
  samples.csv (Tier A), events.csv, manifest.json, memmap-*.json.

Outputs analysis.json and analysis.md next to the input (or --out). Every exclusion is counted and
reported; missing metrics stay missing (never zero). Synthetic test data must be labelled synthetic
by the caller and is never mixed with runtime evidence.

Usage:  python -I scripts/kmld_analyze.py <run_dir> [--out DIR] [--idle-phase menu-idle]
        [--settle-phase PHASE --settle-tail-s 10 --warmup-cycles 2]
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import statistics
import sys
from datetime import datetime

MIB = 1024.0 * 1024.0
METRICS = [
    "private_bytes", "working_set_bytes", "handle_count", "thread_count",
    "gpu_dedicated_bytes", "gpu_shared_bytes", "pagefile_bytes", "collector_private_bytes",
]
REQUIRED = ["run_id", "timestamp_utc", "elapsed_ms", "pid", "process_creation_time", "cycle", "phase",
            "private_bytes", "working_set_bytes", "handle_count", "thread_count", "process_cpu_seconds",
            "system_available_bytes", "system_commit_bytes", "system_commit_limit_bytes",
            "capture_disk_free_bytes", "metric_status"]


def _num(v):
    if v is None:
        return None
    v = v.strip()
    if v == "":
        return None
    try:
        x = float(v)
    except ValueError:
        return None
    return x if math.isfinite(x) else None


def load_samples(path, expected_run_id=None):
    """Return (rows, report). Rows are dicts with numeric metrics (None when missing)."""
    report = {"file": os.path.basename(path), "raw_rows": 0, "kept_rows": 0, "incomplete_rows": 0,
              "mismatched_run_id_rows": 0, "mismatched_identity_rows": 0, "duplicate_rows": 0,
              "non_monotonic_rows": 0, "missing_columns": [], "missing_values": {}, "status_counts": {}}
    rows = []
    with open(path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.reader(fh)
        header = next(reader, None)
        if header is None:
            report["error"] = "empty file"
            return rows, report
        report["missing_columns"] = [c for c in REQUIRED if c not in header]
        if report["missing_columns"]:
            report["error"] = "required columns missing"
            return rows, report
        idx = {c: i for i, c in enumerate(header)}
        identity = None
        seen = set()
        last_elapsed = None
        for rec in reader:
            report["raw_rows"] += 1
            if len(rec) != len(header):
                report["incomplete_rows"] += 1          # e.g. a truncated final line after an interruption
                continue
            run_id = rec[idx["run_id"]]
            if expected_run_id is None:
                expected_run_id = run_id
            if run_id != expected_run_id:
                report["mismatched_run_id_rows"] += 1
                continue
            ident = (rec[idx["pid"]], rec[idx["process_creation_time"]])
            if identity is None:
                identity = ident
            if ident != identity:
                report["mismatched_identity_rows"] += 1
                continue
            elapsed = _num(rec[idx["elapsed_ms"]])
            if elapsed is None:
                report["incomplete_rows"] += 1
                continue
            if elapsed in seen:
                report["duplicate_rows"] += 1
                continue
            if last_elapsed is not None and elapsed < last_elapsed:
                report["non_monotonic_rows"] += 1
                continue
            seen.add(elapsed)
            last_elapsed = elapsed
            row = {"elapsed_s": elapsed / 1000.0, "timestamp_utc": rec[idx["timestamp_utc"]],
                   "cycle": rec[idx["cycle"]], "phase": rec[idx["phase"]],
                   "cpu_s": _num(rec[idx["process_cpu_seconds"]]),
                   "sys_avail": _num(rec[idx["system_available_bytes"]]),
                   "sys_commit": _num(rec[idx["system_commit_bytes"]]),
                   "sys_limit": _num(rec[idx["system_commit_limit_bytes"]]),
                   "status": rec[idx["metric_status"]]}
            for m in METRICS:
                row[m] = _num(rec[idx[m]]) if m in idx else None
                if row[m] is None:
                    report["missing_values"][m] = report["missing_values"].get(m, 0) + 1
            for s in row["status"].split("|"):
                key = s.split(":")[0] + (":" + s.split(":")[1] if s.startswith("gpu:") and ":" in s else "")
                report["status_counts"][key] = report["status_counts"].get(key, 0) + 1
            rows.append(row)
    report["kept_rows"] = len(rows)
    report["run_id"] = expected_run_id
    report["identity"] = list(identity) if identity else None
    return rows, report


def ols(xs, ys):
    """Least-squares slope/intercept; None when underdetermined."""
    pts = [(x, y) for x, y in zip(xs, ys) if x is not None and y is not None]
    n = len(pts)
    if n < 3:
        return None
    mx = sum(p[0] for p in pts) / n
    my = sum(p[1] for p in pts) / n
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    if sxx == 0:
        return None
    slope = sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx
    resid = [p[1] - (my + slope * (p[0] - mx)) for p in pts]
    rmse = math.sqrt(sum(r * r for r in resid) / n)
    return {"slope": slope, "intercept": my - slope * mx, "n": n, "rmse": rmse}


def _median(vals):
    vals = [v for v in vals if v is not None]
    return statistics.median(vals) if vals else None


def segments(rows):
    """Contiguous (cycle, phase) segments in time order."""
    segs = []
    for r in rows:
        key = (r["cycle"], r["phase"])
        if not segs or segs[-1]["key"] != key:
            segs.append({"key": key, "rows": []})
        segs[-1]["rows"].append(r)
    return segs


def summarize_segment(seg):
    rs = seg["rows"]
    out = {"cycle": seg["key"][0], "phase": seg["key"][1], "samples": len(rs),
           "start_s": rs[0]["elapsed_s"], "end_s": rs[-1]["elapsed_s"],
           "duration_s": rs[-1]["elapsed_s"] - rs[0]["elapsed_s"]}
    for m in METRICS:
        vals = [r[m] for r in rs if r[m] is not None]
        if not vals:
            out[m] = None
            continue
        out[m] = {"start": vals[0], "end": vals[-1], "min": min(vals), "max": max(vals), "median": statistics.median(vals),
                  "missing": len(rs) - len(vals)}
    cpu = [r for r in rs if r["cpu_s"] is not None]
    if len(cpu) >= 2 and cpu[-1]["elapsed_s"] > cpu[0]["elapsed_s"]:
        out["cpu_percent_one_core"] = 100.0 * (cpu[-1]["cpu_s"] - cpu[0]["cpu_s"]) / (cpu[-1]["elapsed_s"] - cpu[0]["elapsed_s"])
    return out


def idle_analysis(rows, phase, window_s=60.0, exclude_head_s=10.0):
    """Time-dependent growth within one idle phase: OLS slope (MiB/min), head/tail medians, half slopes."""
    rs = [r for r in rows if r["phase"] == phase]
    if len(rs) < 10:
        return {"phase": phase, "error": "insufficient samples", "samples": len(rs)}
    t0 = rs[0]["elapsed_s"] + exclude_head_s
    rs = [r for r in rs if r["elapsed_s"] >= t0]
    t_end = rs[-1]["elapsed_s"]
    res = {"phase": phase, "samples": len(rs), "duration_s": t_end - rs[0]["elapsed_s"], "excluded_head_s": exclude_head_s}
    mid = (rs[0]["elapsed_s"] + t_end) / 2.0
    for m in ["private_bytes", "working_set_bytes", "handle_count", "thread_count", "gpu_dedicated_bytes", "gpu_shared_bytes", "collector_private_bytes"]:
        xs = [r["elapsed_s"] / 60.0 for r in rs]
        ys = [r[m] for r in rs]
        if all(y is None for y in ys):
            res[m] = None
            continue
        scale = MIB if m.endswith("bytes") else 1.0
        unit = "MiB" if m.endswith("bytes") else "count"
        full = ols(xs, ys)
        early = ols([x for x, r in zip(xs, rs) if r["elapsed_s"] <= mid], [r[m] for r in rs if r["elapsed_s"] <= mid])
        late = ols([x for x, r in zip(xs, rs) if r["elapsed_s"] > mid], [r[m] for r in rs if r["elapsed_s"] > mid])
        head = _median([r[m] for r in rs if r["elapsed_s"] <= rs[0]["elapsed_s"] + window_s])
        tail = _median([r[m] for r in rs if r["elapsed_s"] >= t_end - window_s])
        vals = [y for y in ys if y is not None]
        res[m] = {
            "unit": unit,
            "slope_per_min": full["slope"] / scale if full else None,
            "early_half_slope_per_min": early["slope"] / scale if early else None,
            "late_half_slope_per_min": late["slope"] / scale if late else None,
            "rmse": full["rmse"] / scale if full else None,
            "head_median": head / scale if head is not None else None,
            "tail_median": tail / scale if tail is not None else None,
            "tail_minus_head": (tail - head) / scale if head is not None and tail is not None else None,
            "min": min(vals) / scale, "max": max(vals) / scale, "missing": len(ys) - len(vals),
        }
    return res


def cycle_analysis(rows, settle_phase, tail_s=10.0, warmup_cycles=2):
    """Settled value per cycle = median of the last tail_s seconds of each settle segment; slope per cycle."""
    per = []
    for seg in segments(rows):
        if seg["key"][1] != settle_phase:
            continue
        rs = seg["rows"]
        t_end = rs[-1]["elapsed_s"]
        tail = [r for r in rs if r["elapsed_s"] >= t_end - tail_s]
        entry = {"cycle": seg["key"][0], "settle_duration_s": t_end - rs[0]["elapsed_s"], "tail_samples": len(tail)}
        for m in ["private_bytes", "working_set_bytes", "handle_count", "gpu_dedicated_bytes"]:
            entry[m] = _median([r[m] for r in tail])
        per.append(entry)
    out = {"settle_phase": settle_phase, "tail_s": tail_s, "warmup_cycles": warmup_cycles, "cycles": per}
    measured = per[warmup_cycles:]
    if len(measured) >= 3:
        for m in ["private_bytes", "working_set_bytes", "handle_count", "gpu_dedicated_bytes"]:
            scale = MIB if m.endswith("bytes") else 1.0
            idxs = list(range(len(measured)))
            f = ols(idxs, [c[m] for c in measured])
            half = len(measured) // 2
            e = ols(idxs[:half + 1], [c[m] for c in measured[:half + 1]]) if half + 1 >= 3 else None
            l = ols(idxs[half:], [c[m] for c in measured[half:]]) if len(measured) - half >= 3 else None
            diffs = [(b[m] - a[m]) / scale for a, b in zip(measured, measured[1:]) if a[m] is not None and b[m] is not None]
            # minutes per cycle from settle-end timestamps for MiB/min
            out[m] = {"slope_per_cycle": f["slope"] / scale if f else None,
                      "early_slope_per_cycle": e["slope"] / scale if e else None,
                      "late_slope_per_cycle": l["slope"] / scale if l else None,
                      "per_cycle_deltas": diffs,
                      "delta_median": statistics.median(diffs) if diffs else None,
                      "delta_spread_mad": statistics.median([abs(d - statistics.median(diffs)) for d in diffs]) if diffs else None}
    else:
        out["note"] = "fewer than 3 post-warm-up cycles; no slope estimated"
    return out


def read_events(path):
    ev = []
    if not os.path.exists(path):
        return ev
    with open(path, newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            ev.append(r)
    return ev


def analyze(run_dir, out_dir=None, idle_phase=None, settle_phase=None, settle_tail_s=10.0, warmup_cycles=2):
    out_dir = out_dir or run_dir
    samples_path = os.path.join(run_dir, "samples.csv")
    manifest = {}
    mp = os.path.join(run_dir, "manifest.json")
    if os.path.exists(mp):
        with open(mp, encoding="utf-8-sig") as fh:
            manifest = json.load(fh)
    rows, load = load_samples(samples_path, manifest.get("run_id"))
    result = {"schema_version": 1, "analyzer": "scripts/kmld_analyze.py", "run_dir": os.path.basename(os.path.normpath(run_dir)),
              "synthetic": bool(manifest.get("synthetic", False)), "load_report": load,
              "manifest_status": manifest.get("completion_status"), "configuration_id": manifest.get("configuration_id")}
    if not rows:
        result["error"] = "no usable samples"
    else:
        result["first_sample_s"] = rows[0]["elapsed_s"]
        result["last_sample_s"] = rows[-1]["elapsed_s"]
        result["segments"] = [summarize_segment(s) for s in segments(rows)]
        peak = max((r for r in rows if r["private_bytes"] is not None), key=lambda r: r["private_bytes"], default=None)
        if peak:
            result["peak_private"] = {"bytes": peak["private_bytes"], "MiB": peak["private_bytes"] / MIB, "phase": peak["phase"], "elapsed_s": peak["elapsed_s"]}
        pws = max((r for r in rows if r["working_set_bytes"] is not None), key=lambda r: r["working_set_bytes"], default=None)
        if pws:
            result["peak_working_set"] = {"bytes": pws["working_set_bytes"], "MiB": pws["working_set_bytes"] / MIB, "phase": pws["phase"], "elapsed_s": pws["elapsed_s"]}
        sys_min = min((r["sys_avail"] for r in rows if r["sys_avail"] is not None), default=None)
        commit_max = max(((r["sys_commit"] / r["sys_limit"]) for r in rows if r["sys_commit"] and r["sys_limit"]), default=None)
        result["system_extremes"] = {"min_available_MiB": sys_min / MIB if sys_min else None, "max_commit_fraction": commit_max}
        if idle_phase:
            result["idle"] = idle_analysis(rows, idle_phase)
        if settle_phase:
            result["cycles"] = cycle_analysis(rows, settle_phase, settle_tail_s, warmup_cycles)
    events = read_events(os.path.join(run_dir, "events.csv"))
    result["events"] = [{"elapsed_ms": e.get("elapsed_ms"), "event": e.get("event"), "detail": (e.get("detail") or "")[:200]} for e in events
                        if e.get("event") not in ("phase",) or True][:400]
    mm = []
    for name in sorted(os.listdir(run_dir)) if os.path.isdir(run_dir) else []:
        if name.startswith("memmap-") and name.endswith(".json"):
            with open(os.path.join(run_dir, name), encoding="utf-8-sig") as fh:
                mm.append(json.load(fh))
    if mm:
        result["memory_maps"] = [{"label": m.get("label"), "regions": m.get("regionCount"),
                                  "byTypeState_MiB": {k: v["bytes"] / MIB for k, v in (m.get("byTypeState") or {}).items()},
                                  "privateByAllocSize_MiB": {k: v / MIB for k, v in ((m.get("committedPrivateByAllocationSize") or {}).get("bytes") or {}).items()},
                                  "privateAllocCounts": (m.get("committedPrivateByAllocationSize") or {}).get("allocations")} for m in mm]
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "analysis.json"), "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2)
    with open(os.path.join(out_dir, "analysis.md"), "w", encoding="utf-8") as fh:
        fh.write(render_md(result))
    return result


def _f(v, nd=1):
    return "n/a" if v is None else (f"{v:.{nd}f}" if isinstance(v, float) else str(v))


def render_md(r):
    L = [f"# Analysis: {r['run_dir']}", "", f"- synthetic: {r['synthetic']}", f"- manifest status: {r.get('manifest_status')}",
         f"- configuration: {r.get('configuration_id')}", f"- load report: kept {r['load_report'].get('kept_rows')} of {r['load_report'].get('raw_rows')} rows; "
         f"incomplete {r['load_report'].get('incomplete_rows')}, duplicates {r['load_report'].get('duplicate_rows')}, mismatched run id {r['load_report'].get('mismatched_run_id_rows')}, "
         f"mismatched identity {r['load_report'].get('mismatched_identity_rows')}, non-monotonic {r['load_report'].get('non_monotonic_rows')}", ""]
    if "segments" in r:
        L += ["## Phase segments", "", "| cycle | phase | s | private start→end (max) MiB | WS end MiB | handles end | threads end | GPU ded end MiB | GPU shared end MiB | CPU %core |", "|---|---|---|---|---|---|---|---|---|---|"]
        for s in r["segments"]:
            def g(m, k="end"):
                return None if s.get(m) is None else s[m][k]
            pb = s.get("private_bytes")
            pbs = "n/a" if pb is None else f"{pb['start']/MIB:.1f}→{pb['end']/MIB:.1f} ({pb['max']/MIB:.1f})"
            L.append(f"| {s['cycle']} | {s['phase']} | {s['duration_s']:.0f} | {pbs} | {_f(g('working_set_bytes') and g('working_set_bytes')/MIB)} | {_f(g('handle_count'),0)} | {_f(g('thread_count'),0)} | "
                     f"{_f(g('gpu_dedicated_bytes') and g('gpu_dedicated_bytes')/MIB)} | {_f(g('gpu_shared_bytes') and g('gpu_shared_bytes')/MIB)} | {_f(s.get('cpu_percent_one_core'))} |")
        L.append("")
    if r.get("idle"):
        i = r["idle"]
        L += [f"## Idle analysis ({i['phase']}, {i.get('samples')} samples, {_f(i.get('duration_s'),0)} s, first {i.get('excluded_head_s')} s excluded)", "",
              "| metric | slope /min | early-half /min | late-half /min | head median | tail median | tail−head | rmse |", "|---|---|---|---|---|---|---|---|"]
        for m, v in i.items():
            if isinstance(v, dict):
                L.append(f"| {m} ({v['unit']}) | {_f(v['slope_per_min'],3)} | {_f(v['early_half_slope_per_min'],3)} | {_f(v['late_half_slope_per_min'],3)} | {_f(v['head_median'],1)} | {_f(v['tail_median'],1)} | {_f(v['tail_minus_head'],2)} | {_f(v['rmse'],2)} |")
        L.append("")
    if r.get("cycles"):
        c = r["cycles"]
        L += [f"## Cycle analysis (settle phase {c['settle_phase']}, tail {c['tail_s']} s, warm-up cycles {c['warmup_cycles']})", ""]
        for cy in c["cycles"]:
            L.append(f"- cycle {cy['cycle']}: private {_f(cy['private_bytes'] and cy['private_bytes']/MIB)} MiB, WS {_f(cy['working_set_bytes'] and cy['working_set_bytes']/MIB)} MiB, handles {_f(cy['handle_count'],0)}")
        for m in ["private_bytes", "working_set_bytes", "handle_count", "gpu_dedicated_bytes"]:
            if isinstance(c.get(m), dict):
                v = c[m]
                L.append(f"- {m}: slope/cycle {_f(v['slope_per_cycle'],3)} (early {_f(v['early_slope_per_cycle'],3)}, late {_f(v['late_slope_per_cycle'],3)}), median Δ {_f(v['delta_median'],3)} ± MAD {_f(v['delta_spread_mad'],3)}")
        L.append("")
    if r.get("memory_maps"):
        L += ["## Memory maps (VirtualQueryEx census, MiB)", ""]
        for m in r["memory_maps"]:
            L.append(f"- {m['label']}: regions {m['regions']}; " + ", ".join(f"{k} {v:.1f}" for k, v in sorted(m["byTypeState_MiB"].items())))
            L.append(f"  - committed private by allocation size: " + ", ".join(f"{k} {v:.1f}" for k, v in m["privateByAllocSize_MiB"].items()) + f"; allocations {m['privateAllocCounts']}")
        L.append("")
    return "\n".join(L) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("run_dir")
    ap.add_argument("--out")
    ap.add_argument("--idle-phase")
    ap.add_argument("--settle-phase")
    ap.add_argument("--settle-tail-s", type=float, default=10.0)
    ap.add_argument("--warmup-cycles", type=int, default=2)
    a = ap.parse_args(argv)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    r = analyze(a.run_dir, a.out, a.idle_phase, a.settle_phase, a.settle_tail_s, a.warmup_cycles)
    print(render_md(r))
    return 0 if "error" not in r else 2


if __name__ == "__main__":
    sys.exit(main())
