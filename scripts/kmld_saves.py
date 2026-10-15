"""KMLD read-only save analysis (Python standard library only).

Two steps, kept separate so originals are only ever read:
  copy     Hash each original save, copy it into the lab's private fixture area, verify the copy,
           re-hash the original and record both hashes (originals must be unchanged).
  analyze  Analyse COPIES only. Archives are read in memory member by member; nothing is extracted
           to disk, member names are validated, and size / ratio / count limits bound the work.

Usage:
  python -I scripts/kmld_saves.py copy --src "<Saved Games dir>" --dst <private\\fixtures\\save-copies> [--pattern *.zks]
  python -I scripts/kmld_saves.py analyze --copies <dir> --out <private\\save-analysis> [--max-member-mib 1024]
"""
from __future__ import annotations

import argparse
import collections
import fnmatch
import hashlib
import json
import os
import re
import shutil
import sys
import zipfile
from datetime import datetime, timezone

LAB_ROOT = os.path.normcase(os.path.abspath(r"C:\Dev\KingmakerMemoryLeakResearchLab"))
TYPE_RE = re.compile(rb'"\$type"\s*:\s*"([^"]{1,300})"')
TOKEN_RE = re.compile(rb'"(?:[^"\\]|\\.)*"|[{}\[\],:]')


def sha256(path, bufsize=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(bufsize), b""):
            h.update(chunk)
    return h.hexdigest()


def inside_lab(path, root=LAB_ROOT):
    p = os.path.normcase(os.path.abspath(path))
    return p == root or p.startswith(root + os.sep)


def require_lab(path, root=LAB_ROOT):
    if not inside_lab(path, root):
        raise SystemExit(f"refusing to write outside the lab: {path}")


def now():
    return datetime.now(timezone.utc).isoformat()


# ----------------------------------------------------------------------------- copy

def copy_saves(src, dst, pattern="*.zks", lab_root=LAB_ROOT):
    require_lab(dst, lab_root)
    if inside_lab(src, lab_root):
        raise SystemExit("source must be the game's save directory, not a lab path")
    os.makedirs(dst, exist_ok=True)
    records = []
    for name in sorted(os.listdir(src)):
        full = os.path.join(src, name)
        if not os.path.isfile(full) or not fnmatch.fnmatch(name, pattern):
            continue
        st = os.stat(full)
        before = sha256(full)
        target = os.path.join(dst, f"{before[:12]}__{name}")
        if os.path.exists(target):
            copied = sha256(target)
            status = "already-copied" if copied == before else "conflict-existing-copy-differs"
        else:
            shutil.copy2(full, target)             # reads the original; never writes to it
            copied = sha256(target)
            status = "copied" if copied == before else "copy-mismatch"
        after = sha256(full)
        st2 = os.stat(full)
        records.append({"original_name": name, "bytes": st.st_size, "mtime_utc": datetime.fromtimestamp(st.st_mtime, timezone.utc).isoformat(),
                        "sha256_before": before, "sha256_after": after, "original_unchanged": before == after and st.st_mtime == st2.st_mtime and st.st_size == st2.st_size,
                        "copy": os.path.basename(target), "copy_sha256": copied, "status": status})
    manifest = {"schema_version": 1, "created_utc": now(), "tool": "scripts/kmld_saves.py copy", "source_dir": src, "pattern": pattern,
                "count": len(records), "all_originals_unchanged": all(r["original_unchanged"] for r in records),
                "all_copies_verified": all(r["status"] in ("copied", "already-copied") for r in records), "records": records}
    with open(os.path.join(dst, f"copy-manifest-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2)
    return manifest


# ----------------------------------------------------------------------------- archive safety

class ArchiveRejected(Exception):
    pass


def validate_member_name(name):
    """Reject absolute paths, drive letters, traversal and control characters (we never extract,
    but names are reported and must not be trusted as paths)."""
    if not name or len(name) > 400:
        raise ArchiveRejected(f"bad member name length: {name!r}")
    if any(ord(c) < 32 for c in name):
        raise ArchiveRejected(f"control character in member name: {name!r}")
    n = name.replace("\\", "/")
    if n.startswith("/") or re.match(r"^[A-Za-z]:", n):
        raise ArchiveRejected(f"absolute member path: {name!r}")
    if any(part == ".." for part in n.split("/")):
        raise ArchiveRejected(f"path traversal in member name: {name!r}")
    return n


def read_member_bounded(zf, info, max_bytes, max_ratio):
    if info.file_size > max_bytes:
        raise ArchiveRejected(f"member {info.filename!r} declares {info.file_size} bytes > limit {max_bytes}")
    if info.compress_size > 0 and info.file_size / info.compress_size > max_ratio and info.file_size > 64 * 1024 * 1024:
        raise ArchiveRejected(f"member {info.filename!r} compression ratio {info.file_size / info.compress_size:.0f} > {max_ratio}")
    out = bytearray()
    with zf.open(info, "r") as fh:
        while True:
            chunk = fh.read(1 << 20)
            if not chunk:
                break
            out += chunk
            if len(out) > max_bytes:
                raise ArchiveRejected(f"member {info.filename!r} exceeded {max_bytes} bytes while reading (declared {info.file_size})")
    return bytes(out)


# ----------------------------------------------------------------------------- JSON structure scan

def scan_json(data, max_depth=3, top_arrays=15):
    """Streaming structural scan without building the object graph.
    Returns byte spans of keys at depth <= max_depth, the largest arrays (path, length), node counts,
    $type counts, $id/$ref counts."""
    types = collections.Counter(m.group(1).decode("utf-8", "replace").split(",")[0] for m in TYPE_RE.finditer(data))
    stack = []            # entries: [kind, key_or_index, start_offset, element_count, pending_key]
    key_spans = collections.Counter()
    key_counts = collections.Counter()
    arrays = []
    objects = 0
    arrays_total = 0
    last_string = None
    expecting_key = False
    for m in TOKEN_RE.finditer(data):
        tok = m.group(0)
        c = tok[:1]
        if c == b'"':
            if stack and stack[-1][0] == "o" and expecting_key:
                last_string = tok[1:-1]
            continue
        if c == b":":
            if stack and stack[-1][0] == "o":
                stack[-1][4] = last_string
                stack[-1][5] = m.end()
                expecting_key = False
            continue
        if c == b",":
            if stack:
                top = stack[-1]
                if top[0] == "o":
                    _close_value(stack, m.start(), key_spans, key_counts, max_depth)
                    expecting_key = True
                else:
                    top[3] += 1
            continue
        if c in (b"{", b"["):
            kind = "o" if c == b"{" else "a"
            if kind == "o":
                objects += 1
            else:
                arrays_total += 1
            stack.append([kind, None, m.start(), 0, None, None])
            expecting_key = kind == "o"
            continue
        if c in (b"}", b"]"):
            top = stack.pop() if stack else None
            if top is None:
                break
            if top[0] == "o":
                _close_value_of(top, stack, m.start(), key_spans, key_counts, max_depth)
            else:
                # elements = commas + 1, or 0 for an empty array (scalars are not tokenized, so check the span)
                n = top[3] + 1 if top[3] > 0 else (1 if data[top[2] + 1:m.start()].strip() else 0)
                arrays.append((n, _path(stack) + "[]"))
            expecting_key = bool(stack and stack[-1][0] == "o")
            continue
    arrays.sort(reverse=True)
    agg = collections.defaultdict(lambda: [0, 0])
    for n, p in arrays:
        agg[p][0] += 1
        agg[p][1] += n
    largest = []
    seen = set()
    for n, p in arrays:
        if p in seen:
            continue
        seen.add(p)
        largest.append({"path": p, "max_length": n, "instances": agg[p][0], "total_elements": agg[p][1]})
        if len(largest) >= top_arrays:
            break
    return {"bytes": len(data), "objects": objects, "arrays": arrays_total,
            "type_counts": types.most_common(40), "distinct_types": len(types), "type_total": sum(types.values()),
            "ref_count": data.count(b'"$ref"'), "id_count": data.count(b'"$id"'),
            "key_bytes_by_path": [{"path": k, "bytes": v, "occurrences": key_counts[k]} for k, v in key_spans.most_common(40)],
            "largest_arrays": largest}


def _path(stack):
    parts = []
    for e in stack:
        if e[0] == "o" and e[4] is not None:
            parts.append(e[4].decode("utf-8", "replace")[:60])
        elif e[0] == "a":
            parts.append("[]")
    return "/".join(parts).replace("/[]", "[]")


def _close_value(stack, end, key_spans, key_counts, max_depth):
    top = stack[-1]
    if top[4] is not None and top[5] is not None and len(stack) <= max_depth:
        p = _path(stack)
        key_spans[p] += end - top[5]
        key_counts[p] += 1
    top[4] = None
    top[5] = None


def _close_value_of(closed, stack, end, key_spans, key_counts, max_depth):
    # the last key/value of the closed object ends at its closing brace
    stack.append(closed)
    _close_value(stack, end, key_spans, key_counts, max_depth)
    stack.pop()


# ----------------------------------------------------------------------------- analyze

DEEP_MEMBERS = {"history", "player.json", "party.json", "header.json", "statistic.json"}


def categorize(name):
    n = name.lower()
    if n.endswith(".png"):
        return "fog-image" if n.endswith(".fog.png") else "image"
    if n in ("header.json", "statistic.json", "player.json", "party.json", "history"):
        return n.replace(".json", "")
    if re.fullmatch(r"[0-9a-f]{32}\.json", n):
        return "area-state"             # one per visited area (area blueprint GUID)
    if re.match(r"[0-9a-f]{32}", n):
        return "area-part-state"        # per-scene-part state of an area (GUID + scene name)
    return "other"


def analyze_archive(path, max_member_bytes, max_ratio=200, max_members=5000, deep_all=False):
    """Sizes for every member; full structure scan for DEEP_MEMBERS (or all JSON with deep_all);
    $type counts (C-speed regex) for every other JSON member. JSON is sniffed by its first byte."""
    res = {"copy": os.path.basename(path), "bytes": os.path.getsize(path), "sha256": sha256(path), "members": [], "rejected": None}
    try:
        with zipfile.ZipFile(path, "r") as zf:
            infos = zf.infolist()
            if len(infos) > max_members:
                raise ArchiveRejected(f"{len(infos)} members > limit {max_members}")
            for info in infos:
                name = validate_member_name(info.filename)
                entry = {"name": name, "category": categorize(name), "compressed": info.compress_size, "uncompressed": info.file_size}
                if not name.lower().endswith(".png"):
                    data = read_member_bounded(zf, info, max_member_bytes, max_ratio)
                    first = data.lstrip()[:1]
                    entry["is_json"] = first in (b"{", b"[")
                    if entry["is_json"]:
                        try:
                            if deep_all or name.lower() in DEEP_MEMBERS:
                                entry["structure"] = scan_json(data)
                            else:
                                types = collections.Counter(m.group(1).decode("utf-8", "replace").split(",")[0] for m in TYPE_RE.finditer(data))
                                entry["type_counts"] = types.most_common(25)
                                entry["type_total"] = sum(types.values())
                        except Exception as exc:      # best-effort; sizes remain valid
                            entry["structure_error"] = repr(exc)
                        if name.lower() == "header.json" and len(data) < 1_000_000:
                            try:
                                entry["header"] = json.loads(data.decode("utf-8-sig"))
                            except Exception as exc:
                                entry["header_error"] = repr(exc)
                    del data
                res["members"].append(entry)
    except (ArchiveRejected, zipfile.BadZipFile) as exc:
        res["rejected"] = str(exc)
    res["uncompressed_total"] = sum(m["uncompressed"] for m in res["members"])
    res["compressed_total"] = sum(m["compressed"] for m in res["members"])
    cats = collections.defaultdict(lambda: {"members": 0, "uncompressed": 0, "compressed": 0})
    for m in res["members"]:
        c = cats[m["category"]]
        c["members"] += 1; c["uncompressed"] += m["uncompressed"]; c["compressed"] += m["compressed"]
    res["by_category"] = dict(cats)
    return res


def analyze_copies(copies, out, max_member_mib=1024, only=None, lab_root=LAB_ROOT):
    require_lab(out, lab_root)
    os.makedirs(out, exist_ok=True)
    results = []
    for name in sorted(os.listdir(copies)):
        if not name.lower().endswith(".zks") or (only and not fnmatch.fnmatch(name, only)):
            continue
        p = os.path.join(copies, name)
        before = sha256(p)
        r = analyze_archive(p, max_member_mib * 1024 * 1024)
        r["copy_unchanged_by_analysis"] = sha256(p) == before
        results.append(r)
        with open(os.path.join(out, name + ".analysis.json"), "w", encoding="utf-8") as fh:
            json.dump(r, fh, indent=2)
        print(f"{name}: members={len(r['members'])} uncompressed={r['uncompressed_total']/1048576:.1f} MiB rejected={r['rejected']}", flush=True)
    summary = {"schema_version": 1, "created_utc": now(), "tool": "scripts/kmld_saves.py analyze", "count": len(results),
               "saves": [{"copy": r["copy"], "bytes": r["bytes"], "uncompressed_total": r["uncompressed_total"], "members": len(r["members"]),
                          "rejected": r["rejected"], "copy_unchanged_by_analysis": r["copy_unchanged_by_analysis"],
                          "by_category": r.get("by_category"),
                          "header": next((m.get("header") for m in r["members"] if m["name"].lower() == "header.json"), None)} for r in results]}
    with open(os.path.join(out, "summary.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2)
    return summary


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("copy")
    c.add_argument("--src", required=True)
    c.add_argument("--dst", required=True)
    c.add_argument("--pattern", default="*.zks")
    a = sub.add_parser("analyze")
    a.add_argument("--copies", required=True)
    a.add_argument("--out", required=True)
    a.add_argument("--max-member-mib", type=int, default=1024)
    a.add_argument("--only")
    args = ap.parse_args(argv)
    if args.cmd == "copy":
        m = copy_saves(args.src, args.dst, args.pattern)
        print(json.dumps({k: m[k] for k in ("count", "all_originals_unchanged", "all_copies_verified")}))
        return 0 if m["all_originals_unchanged"] and m["all_copies_verified"] else 3
    s = analyze_copies(args.copies, args.out, args.max_member_mib, args.only)
    return 0 if all(x["copy_unchanged_by_analysis"] for x in s["saves"]) else 3


if __name__ == "__main__":
    sys.exit(main())
