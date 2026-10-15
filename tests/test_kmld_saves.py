"""Tests for scripts/kmld_saves.py on SYNTHETIC archives (never real saves)."""
import json
import os
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
import kmld_saves as ks  # noqa: E402


def make_zip(path, members):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, data in members.items():
            zi = zipfile.ZipInfo(name)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(zi, data)


class SaveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="kmld-syn-saves-")
        self.root = os.path.normcase(os.path.abspath(self.tmp.name))

    def tearDown(self):
        self.tmp.cleanup()

    def p(self, *parts):
        return os.path.join(self.tmp.name, *parts)

    def test_member_name_validation(self):
        for bad in ["../evil.json", "a/../../b", "/abs.json", "C:/x.json", "C:\\x.json", "a\x01b"]:
            with self.assertRaises(ks.ArchiveRejected, msg=bad):
                ks.validate_member_name(bad)
        self.assertEqual(ks.validate_member_name("area\\x.json"), "area/x.json")

    def test_traversal_member_rejects_archive_without_extracting(self):
        z = self.p("trav.zks")
        make_zip(z, {"header.json": b"{}", "../../outside.json": b"{}"})
        r = ks.analyze_archive(z, 10 * 1024 * 1024)
        self.assertIn("path traversal", r["rejected"])
        self.assertFalse(os.path.exists(self.p("..", "outside.json")))

    def test_size_and_ratio_limits(self):
        z = self.p("big.zks")
        make_zip(z, {"player.json": b"{" + b'"a":' + b"0" * (3 * 1024 * 1024) + b"}"})
        r = ks.analyze_archive(z, 1024 * 1024)
        self.assertIn("limit", r["rejected"])
        z2 = self.p("bomb.zks")
        make_zip(z2, {"x.json": b" " * (80 * 1024 * 1024)})
        r2 = ks.analyze_archive(z2, 512 * 1024 * 1024, max_ratio=200)
        self.assertIn("compression ratio", r2["rejected"])

    def test_structure_scan_counts(self):
        doc = {"$id": "1", "$type": "Kingmaker.Player, Assembly-CSharp",
               "History": {"Entries": [{"$type": "Ev, A", "v": i} for i in range(50)]},
               "Small": [1, 2, 3], "Empty": [], "Name": "x"}
        data = json.dumps(doc).encode()
        s = ks.scan_json(data)
        self.assertEqual(dict(s["type_counts"])["Ev"], 50)
        self.assertEqual(dict(s["type_counts"])["Kingmaker.Player"], 1)
        arrays = {a["path"]: a["max_length"] for a in s["largest_arrays"]}
        self.assertEqual(arrays["History/Entries[]"], 50)
        self.assertEqual(arrays["Small[]"], 3)
        self.assertEqual(arrays["Empty[]"], 0)
        spans = {k["path"]: k["bytes"] for k in s["key_bytes_by_path"]}
        self.assertGreater(spans["History"], spans["Small"])
        self.assertEqual(s["id_count"], 1)

    def test_copy_preserves_original_and_refuses_outside_lab(self):
        src = self.p("src"); os.makedirs(src)
        make_zip(os.path.join(src, "Manual_1_X.zks"), {"header.json": b'{"Name":"x"}', "player.json": b'{"a":[1,2]}'})
        before = ks.sha256(os.path.join(src, "Manual_1_X.zks"))
        dst = self.p("lab", "copies")
        m = ks.copy_saves(src, dst, lab_root=os.path.normcase(os.path.abspath(self.p("lab"))))
        self.assertTrue(m["all_originals_unchanged"])
        self.assertTrue(m["all_copies_verified"])
        self.assertEqual(ks.sha256(os.path.join(src, "Manual_1_X.zks")), before)
        with self.assertRaises(SystemExit):
            ks.copy_saves(src, self.p("not-lab"), lab_root=os.path.normcase(os.path.abspath(self.p("lab"))))
        s = ks.analyze_copies(dst, self.p("lab", "out"), lab_root=os.path.normcase(os.path.abspath(self.p("lab"))))
        self.assertTrue(s["saves"][0]["copy_unchanged_by_analysis"])
        self.assertEqual(s["saves"][0]["members"], 2)

    def test_bad_zip_is_reported_not_raised(self):
        z = self.p("bad.zks")
        with open(z, "wb") as fh:
            fh.write(b"not a zip")
        r = ks.analyze_archive(z, 1024)
        self.assertIsNotNone(r["rejected"])


if __name__ == "__main__":
    unittest.main()
