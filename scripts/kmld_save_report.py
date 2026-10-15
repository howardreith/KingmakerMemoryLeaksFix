"""Summarise kmld_saves.py analysis output into per-save rows and per-campaign trends.

Writes <analysis_dir>/save-table.csv (private: raw save names) and <analysis_dir>/save-report.md, plus an
optional sanitized table (--sanitized-out) where campaign IDs are hashed and save names are reduced to
their type prefix. Pure post-processing; it never opens archives.
"""
from __future__ import annotations

import argparse
import csv
import glob
import hashlib
import json
import os
import re
import statistics
import sys

MIB = 1048576.0


def parse_timespan(s):
    """'d.hh:mm:ss.fffffff' or 'hh:mm:ss' -> hours (float) or None."""
    if not isinstance(s, str):
        return None
    m = re.match(r"^(?:(\d+)\.)?(\d+):(\d+):(\d+(?:\.\d+)?)$", s)
    if not m:
        return None
    d, h, mi, se = m.groups()
    return (int(d or 0) * 24 + int(h)) + int(mi) / 60 + float(se) / 3600


def load(analysis_dir):
    rows = []
    for p in sorted(glob.glob(os.path.join(analysis_dir, "*.zks.analysis.json"))):
        r = json.load(open(p, encoding="utf-8"))
        mem = {m["name"].lower(): m for m in r["members"]}
        hdr = (mem.get("header.json") or {}).get("header") or {}
        cats = r.get("by_category") or {}
        hist = mem.get("history") or {}
        hs = hist.get("structure") or {}
        player = (mem.get("player.json") or {}).get("structure") or {}
        party = (mem.get("party.json") or {}).get("structure") or {}
        area_types = sum(m.get("type_total", 0) for m in r["members"] if m["category"] in ("area-state", "area-part-state"))
        name = r["copy"].split("__", 1)[1]
        rows.append({
            "copy": r["copy"], "save_name": name, "save_type": name.split("_")[0],
            "campaign": hdr.get("GameId"), "campaign_hash": hashlib.sha256(str(hdr.get("GameId")).encode()).hexdigest()[:8],
            "header_type": hdr.get("Type"), "area": (hdr.get("Area") or {}).get("m_AssetGuid") if isinstance(hdr.get("Area"), dict) else hdr.get("Area"),
            "game_total_hours": parse_timespan(hdr.get("GameTotalTime")), "game_save_time": hdr.get("GameSaveTime"),
            "system_save_time": hdr.get("SystemSaveTime"), "loaded_times": hdr.get("LoadedTimes"), "versions": len(hdr.get("Versions") or []),
            "compressed_MiB": r["bytes"] / MIB, "uncompressed_MiB": r["uncompressed_total"] / MIB, "members": len(r["members"]),
            "history_MiB": (cats.get("history") or {}).get("uncompressed", 0) / MIB,
            "history_top_array": (hs.get("largest_arrays") or [{}])[0].get("path") if hs.get("largest_arrays") else None,
            "history_top_array_len": (hs.get("largest_arrays") or [{}])[0].get("max_length") if hs.get("largest_arrays") else None,
            "area_states": (cats.get("area-state") or {}).get("members", 0), "area_state_MiB": (cats.get("area-state") or {}).get("uncompressed", 0) / MIB,
            "area_parts": (cats.get("area-part-state") or {}).get("members", 0), "area_part_MiB": (cats.get("area-part-state") or {}).get("uncompressed", 0) / MIB,
            "area_type_records": area_types,
            "player_MiB": (cats.get("player") or {}).get("uncompressed", 0) / MIB, "player_type_records": player.get("type_total"),
            "party_MiB": (cats.get("party") or {}).get("uncompressed", 0) / MIB, "party_type_records": party.get("type_total"),
            "images_MiB": ((cats.get("image") or {}).get("uncompressed", 0) + (cats.get("fog-image") or {}).get("uncompressed", 0)) / MIB,
            "rejected": r.get("rejected"),
        })
    return rows


def pearson(xs, ys):
    pts = [(x, y) for x, y in zip(xs, ys) if x is not None and y is not None]
    if len(pts) < 4:
        return None
    mx = statistics.mean(p[0] for p in pts); my = statistics.mean(p[1] for p in pts)
    sx = sum((p[0] - mx) ** 2 for p in pts) ** 0.5; sy = sum((p[1] - my) ** 2 for p in pts) ** 0.5
    if sx == 0 or sy == 0:
        return None
    return sum((p[0] - mx) * (p[1] - my) for p in pts) / (sx * sy)


def report(rows):
    L = ["# Save structure report (read-only copies)", "",
         "Sizes are uncompressed member bytes unless marked compressed. Campaign = header GameId (hashed). Different campaigns, areas, party",
         "states and mod requirements are confounders: this is descriptive, not a controlled small-vs-large experiment.", ""]
    by = {}
    for r in rows:
        by.setdefault(r["campaign_hash"], []).append(r)
    L += ["## Per campaign", "", "| campaign | saves | play hours (min–max) | uncompressed MiB (min–max) | history MiB (min–max) | area states max | corr(hours, uncompressed) | corr(hours, history) |", "|---|---|---|---|---|---|---|---|"]
    for k, rs in sorted(by.items(), key=lambda kv: -max(r["uncompressed_MiB"] for r in kv[1])):
        hrs = [r["game_total_hours"] for r in rs if r["game_total_hours"] is not None]
        L.append(f"| {k} | {len(rs)} | {min(hrs):.1f}–{max(hrs):.1f} | {min(r['uncompressed_MiB'] for r in rs):.1f}–{max(r['uncompressed_MiB'] for r in rs):.1f} | "
                 f"{min(r['history_MiB'] for r in rs):.2f}–{max(r['history_MiB'] for r in rs):.2f} | {max(r['area_states'] for r in rs)} | "
                 f"{_f(pearson([r['game_total_hours'] for r in rs], [r['uncompressed_MiB'] for r in rs]))} | {_f(pearson([r['game_total_hours'] for r in rs], [r['history_MiB'] for r in rs]))} |" if hrs else f"| {k} | {len(rs)} | n/a |")
    L += ["", "## Largest saves", "", "| campaign | type | play h | compressed MiB | uncompressed MiB | history MiB | area states (MiB) | area parts (MiB) | player MiB | party MiB | area $type records |", "|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in sorted(rows, key=lambda r: -r["uncompressed_MiB"])[:15]:
        L.append(f"| {r['campaign_hash']} | {r['save_type']} | {_f(r['game_total_hours'])} | {r['compressed_MiB']:.1f} | {r['uncompressed_MiB']:.1f} | {r['history_MiB']:.2f} | "
                 f"{r['area_states']} ({r['area_state_MiB']:.1f}) | {r['area_parts']} ({r['area_part_MiB']:.1f}) | {r['player_MiB']:.2f} | {r['party_MiB']:.2f} | {r['area_type_records']} |")
    tot = [r for r in rows if r["uncompressed_MiB"] > 0]
    L += ["", "## Composition across all saves (share of uncompressed bytes)", ""]
    for key in ["history_MiB", "area_state_MiB", "area_part_MiB", "player_MiB", "party_MiB", "images_MiB"]:
        share = [r[key] / r["uncompressed_MiB"] for r in tot]
        L.append(f"- {key}: median share {statistics.median(share):.1%}, max {max(share):.1%}; total {sum(r[key] for r in tot):.1f} MiB")
    return "\n".join(L) + "\n"


def _f(v):
    return "n/a" if v is None else f"{v:.2f}"


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("analysis_dir")
    ap.add_argument("--sanitized-out")
    a = ap.parse_args(argv)
    rows = load(a.analysis_dir)
    fields = list(rows[0].keys())
    with open(os.path.join(a.analysis_dir, "save-table.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=fields); w.writeheader(); w.writerows(rows)
    md = report(rows)
    with open(os.path.join(a.analysis_dir, "save-report.md"), "w", encoding="utf-8") as fh:
        fh.write(md)
    if a.sanitized_out:
        keep = [f for f in fields if f not in ("copy", "save_name", "campaign", "area", "game_save_time", "system_save_time")]
        with open(a.sanitized_out, "w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=keep, extrasaction="ignore"); w.writeheader()
            for r in sorted(rows, key=lambda r: (r["campaign_hash"], r["game_total_hours"] or 0)):
                w.writerow(r)
    print(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
