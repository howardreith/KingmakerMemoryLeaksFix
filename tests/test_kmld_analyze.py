"""Tests for scripts/kmld_analyze.py on LABELLED SYNTHETIC datasets (never runtime evidence).

Run:  python -I -m unittest discover -s tests -p "test_*.py"   (from the repo root)
"""
import csv
import json
import os
import random
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
import kmld_analyze as ka  # noqa: E402

MIB = 1024 * 1024
HEADER = ["run_id", "timestamp_utc", "elapsed_ms", "pid", "process_creation_time", "cycle", "phase", "private_bytes",
          "working_set_bytes", "handle_count", "thread_count", "process_cpu_seconds", "system_available_bytes",
          "system_commit_bytes", "system_commit_limit_bytes", "capture_disk_free_bytes", "gpu_dedicated_bytes",
          "gpu_shared_bytes", "pagefile_bytes", "peak_working_set_bytes", "page_fault_count", "collector_private_bytes",
          "sample_duration_ms", "metric_status"]


def write_run(d, rows, run_id="syn-run", manifest_extra=None, truncate_last=False):
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "samples.csv")
    with open(p, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(HEADER)
        for r in rows:
            w.writerow([r.get(h, "") for h in HEADER])
    if truncate_last:
        with open(p, "a", encoding="utf-8") as fh:
            fh.write(f"{run_id},2026-01-01T00:00:00Z,99999999,1,ct,9,idle,123")   # interrupted write, no newline
    m = {"run_id": run_id, "synthetic": True, "completion_status": "synthetic"}
    m.update(manifest_extra or {})
    with open(os.path.join(d, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(m, fh)


def row(t_s, pb, phase="idle", cycle="1", run_id="syn-run", pid="1", ws=None, gpu="", status="ok", handles=500):
    return {"run_id": run_id, "timestamp_utc": f"2026-01-01T00:00:{t_s % 60:06.3f}Z", "elapsed_ms": int(t_s * 1000), "pid": pid,
            "process_creation_time": "2026-01-01T00:00:00Z", "cycle": cycle, "phase": phase, "private_bytes": int(pb),
            "working_set_bytes": int(ws if ws is not None else pb * 1.2), "handle_count": handles, "thread_count": 40,
            "process_cpu_seconds": round(t_s * 0.5, 3), "system_available_bytes": 8 * 1024 * MIB,
            "system_commit_bytes": 20 * 1024 * MIB, "system_commit_limit_bytes": 64 * 1024 * MIB,
            "capture_disk_free_bytes": 400 * 1024 * MIB, "gpu_dedicated_bytes": gpu, "gpu_shared_bytes": gpu,
            "collector_private_bytes": 90 * MIB, "sample_duration_ms": 20, "metric_status": status}


class AnalyzeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="kmld-syn-")
        self.rng = random.Random(1234)

    def tearDown(self):
        self.tmp.cleanup()

    def d(self, name):
        return os.path.join(self.tmp.name, name)

    def test_plateau_has_near_zero_slope(self):
        rows = [row(t, 2000 * MIB + self.rng.gauss(0, 2 * MIB)) for t in range(0, 600)]
        write_run(self.d("plateau"), rows)
        r = ka.analyze(self.d("plateau"), idle_phase="idle")
        self.assertTrue(r["synthetic"])
        self.assertLess(abs(r["idle"]["private_bytes"]["slope_per_min"]), 0.2)

    def test_linear_growth_slope_recovered(self):
        rows = [row(t, 2000 * MIB + t * (3 * MIB / 60.0) + self.rng.gauss(0, 1 * MIB)) for t in range(0, 600)]
        write_run(self.d("linear"), rows)
        r = ka.analyze(self.d("linear"), idle_phase="idle")
        self.assertAlmostEqual(r["idle"]["private_bytes"]["slope_per_min"], 3.0, delta=0.15)
        self.assertGreater(r["idle"]["private_bytes"]["tail_minus_head"], 20)

    def test_warmup_then_plateau_early_late_differ(self):
        rows = [row(t, 2000 * MIB + min(t, 120) * (50 * MIB / 120.0) + self.rng.gauss(0, 1 * MIB)) for t in range(0, 600)]
        write_run(self.d("warm"), rows)
        r = ka.analyze(self.d("warm"), idle_phase="idle")
        v = r["idle"]["private_bytes"]
        self.assertGreater(v["early_half_slope_per_min"], 3.0)
        self.assertLess(abs(v["late_half_slope_per_min"]), 0.3)

    def test_staircase_cycles(self):
        rows, t = [], 0
        base = 2000 * MIB
        for c in range(8):
            for _ in range(20):   # action peak
                rows.append(row(t, base + c * 12 * MIB + 300 * MIB, phase="action", cycle=str(c)))
                t += 1
            for _ in range(30):   # settle
                rows.append(row(t, base + c * 12 * MIB + self.rng.gauss(0, 0.5 * MIB), phase="settle", cycle=str(c)))
                t += 1
        write_run(self.d("stairs"), rows)
        r = ka.analyze(self.d("stairs"), settle_phase="settle", warmup_cycles=2)
        cyc = r["cycles"]["private_bytes"]
        self.assertAlmostEqual(cyc["slope_per_cycle"], 12.0, delta=0.5)
        self.assertEqual(len(r["cycles"]["cycles"]), 8)
        self.assertAlmostEqual(r["peak_private"]["MiB"], (base + 7 * 12 * MIB + 300 * MIB) / MIB, delta=1)

    def test_one_time_warmup_excluded_by_warmup_cycles(self):
        rows, t = [], 0
        for c in range(7):
            level = 2000 * MIB + (80 * MIB if c >= 1 else 0)   # step only in the first cycle
            for _ in range(30):
                rows.append(row(t, level + self.rng.gauss(0, 0.5 * MIB), phase="settle", cycle=str(c)))
                t += 1
        write_run(self.d("onetime"), rows)
        r = ka.analyze(self.d("onetime"), settle_phase="settle", warmup_cycles=2)
        self.assertLess(abs(r["cycles"]["private_bytes"]["slope_per_cycle"]), 0.5)

    def test_missing_values_are_not_zero(self):
        rows = [row(t, 2000 * MIB, gpu="", status="gpu:no-instance-for-pid") for t in range(0, 120)]
        rows[50]["private_bytes"] = ""
        write_run(self.d("missing"), rows)
        r = ka.analyze(self.d("missing"), idle_phase="idle")
        self.assertIsNone(r["idle"]["gpu_dedicated_bytes"])
        self.assertEqual(r["load_report"]["missing_values"]["private_bytes"], 1)
        self.assertEqual(r["idle"]["private_bytes"]["min"], 2000.0)   # a zero would have shown here
        self.assertIn("gpu:no-instance-for-pid", r["load_report"]["status_counts"])

    def test_interrupted_duplicate_and_mismatched_rows_counted(self):
        rows = [row(t, 2000 * MIB) for t in range(0, 60)]
        rows.insert(10, dict(rows[10]))                    # duplicate
        rows.append(row(61, 2000 * MIB, run_id="other"))   # wrong run id
        rows.append(row(62, 2000 * MIB, pid="999"))        # wrong identity
        rows.append(row(5, 2000 * MIB))                    # time goes backwards (also duplicate elapsed)
        write_run(self.d("dirty"), rows, truncate_last=True)
        r = ka.analyze(self.d("dirty"), idle_phase="idle")
        lr = r["load_report"]
        self.assertEqual(lr["kept_rows"], 60)
        self.assertEqual(lr["duplicate_rows"], 2)
        self.assertEqual(lr["mismatched_run_id_rows"], 1)
        self.assertEqual(lr["mismatched_identity_rows"], 1)
        self.assertEqual(lr["incomplete_rows"], 1)

    def test_noise_only_short_run_reports_insufficient(self):
        write_run(self.d("short"), [row(t, 2000 * MIB) for t in range(0, 5)])
        r = ka.analyze(self.d("short"), idle_phase="idle")
        self.assertIn("error", r["idle"])

    def test_empty_and_missing_columns(self):
        os.makedirs(self.d("bad"), exist_ok=True)
        with open(os.path.join(self.d("bad"), "samples.csv"), "w", encoding="utf-8") as fh:
            fh.write("run_id,elapsed_ms\nx,1\n")
        r = ka.analyze(self.d("bad"))
        self.assertIn("error", r)
        self.assertIn("private_bytes", r["load_report"]["missing_columns"])

    def test_outputs_written(self):
        write_run(self.d("out"), [row(t, 2000 * MIB) for t in range(0, 30)])
        ka.analyze(self.d("out"), idle_phase="idle")
        self.assertTrue(os.path.exists(os.path.join(self.d("out"), "analysis.json")))
        with open(os.path.join(self.d("out"), "analysis.md"), encoding="utf-8") as fh:
            self.assertIn("synthetic: True", fh.read())


if __name__ == "__main__":
    unittest.main()
