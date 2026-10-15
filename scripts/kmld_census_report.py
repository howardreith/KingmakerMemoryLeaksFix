"""Summarise content-census-*.json files (Get-KmldContentCensus.ps1) for one or more runs.

Prints, per run and group (allocations new since idle start vs. pre-existing), the pointer-target mix and the most frequent
first-qword values with their resolved Mono class names. String samples are summarised by count only unless --strings is
given (strings stay in private output). Usage: python -I scripts/kmld_census_report.py <run_dir> [<run_dir> ...] [--strings]
"""
import json
import os
import sys


def main(argv):
    show_strings = "--strings" in argv
    runs = [a for a in argv if not a.startswith("--")]
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    for rd in runs:
        for name in sorted(os.listdir(rd)):
            if not (name.startswith("content-census-") and name.endswith(".json")):
                continue
            d = json.load(open(os.path.join(rd, name), encoding="utf-8-sig"))
            print(f"# {os.path.basename(os.path.normpath(rd))} / {name}: allocations of {d['allocationSize']} B: {d['allocationsOfSize']} "
                  f"(new since idle start {d['newSinceBaseline']}, present at idle start {d['presentAtBaseline']}); {d.get('elapsedMs')} ms")
            for gname, g in d["groups"].items():
                if isinstance(g, str):
                    print(f"  [{gname}] {g}")
                    continue
                print(f"  [{gname}] sampled {g['allocationsSampled']} allocations, read {g['bytesRead']/1048576:.1f} MiB, failures {g['readFailures']}, zero slots {g['zeroSlotFraction']:.1%}")
                print("    pointer targets (share of 16-byte slots): " + ", ".join(f"{k} {v:.1%}" for k, v in g["pointerTargetKinds"].items()))
                for t in g["topTypes"][:20]:
                    label = f"{t.get('namespace') or ''}.{t.get('name')}".lstrip(".") if t.get("name") else "-"
                    print(f"    {t['slotsFraction']:7.3%}  {t['count']:>9}  {t['kind']:<14} {label:<60} {t['evidence'][:70]}")
                if show_strings:
                    for s in g["topUtf16"][:15]:
                        print(f"      u16 x{s['n']}: {s['s'][:70]}")
                    for s in g["topAscii"][:10]:
                        print(f"      asc x{s['n']}: {s['s'][:70]}")
                else:
                    print(f"    strings: {len(g['topUtf16'])} UTF-16 and {len(g['topAscii'])} ASCII top entries recorded (use --strings)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
