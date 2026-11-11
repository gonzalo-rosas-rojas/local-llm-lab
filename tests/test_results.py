"""Tests for results/ and for the files generated from it."""
import copy
import io
import json
import shutil
import sys
import tempfile
import unittest
import xml.dom.minidom
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import render_results as rr  # noqa: E402

# The figures the README stated before the measurements became data: (record id,
# metric name, value). If one of these changes, someone edited a measurement.
ORIGINAL_FIGURES = [
    ("stage1-ollama-qwen3-8b", "generation_speed", 89),
    ("stage1-ollama-qwen3-8b", "vram", 6),
    ("stage1-ollama-gpt-oss-20b", "generation_speed", 113),
    ("stage1-ollama-gpt-oss-20b", "vram", 14),
    ("stage2-llamacpp-qwen3-8b-bench", "prompt_processing_speed", 5724),
    ("stage2-llamacpp-qwen3-8b-bench", "generation_speed", 101),
    ("stage2-llamacpp-qwen3-8b-vram", "vram", 6.3),
    ("stage3-llamacpp-gemma4-cpu-moe", "prompt_processing_speed", 459),
    ("stage3-llamacpp-gemma4-cpu-moe", "generation_speed", 34),
    ("stage3-llamacpp-gemma4-cpu-moe", "vram", 5),
    ("stage3-llamacpp-gemma4-fit-target", "prompt_processing_speed", 1628),
    ("stage3-llamacpp-gemma4-fit-target", "generation_speed", 76),
    ("stage3-llamacpp-gemma4-fit-target", "vram", 15),
]


def record_files():
    return sorted(p for p in (ROOT / "results").glob("*.json") if p.name != "schema.json")


def norm(text):
    return text.replace("\r\n", "\n")


class RecordsMatchSchema(unittest.TestCase):
    def setUp(self):
        self.schema = rr.load_schema(ROOT)

    def test_there_are_records(self):
        self.assertGreaterEqual(len(record_files()), 6)

    def test_every_record_validates(self):
        for path in record_files():
            with self.subTest(path.name):
                record = json.loads(path.read_text(encoding="utf-8"))
                self.assertEqual(rr.validate(record, self.schema), [])
                self.assertEqual(record["id"], path.stem)

    def test_unrecorded_fields_are_explained_in_notes(self):
        for path in record_files():
            with self.subTest(path.name):
                record = json.loads(path.read_text(encoding="utf-8"))
                notes = " ".join(record["notes"]).lower()
                if record["runs"] is None:
                    self.assertIn("runs", notes)
                if record["command"] is None:
                    self.assertIn("command", notes)
                if record["measured_on"]["date_kind"] == "commit":
                    self.assertIn("commit", notes)

    def test_original_figures_are_unchanged(self):
        records = {r["id"]: r for r in rr.load_records(ROOT)}
        for record_id, name, value in ORIGINAL_FIGURES:
            with self.subTest(f"{record_id} {name}"):
                m = rr.metric(records[record_id], name)
                self.assertIsNotNone(m)
                self.assertEqual(m["value"], value)
                self.assertTrue(m["approximate"])
        stated = sum(len(r["metrics"]) for r in records.values())
        self.assertEqual(stated, len(ORIGINAL_FIGURES), "a metric was added that the README never had")

    def test_every_figure_appears_in_the_file_the_record_cites(self):
        for record in rr.load_records(ROOT):
            source = (ROOT / record["source"]["file"]).read_text(encoding="utf-8")
            for m in record["metrics"]:
                with self.subTest(f"{record['id']} {m['name']}"):
                    self.assertIn(rr.shown(m), source)

    def test_validator_rejects_bad_records(self):
        good = json.loads(record_files()[0].read_text(encoding="utf-8"))
        cases = {}
        bad = copy.deepcopy(good)
        del bad["runs"]
        cases["missing key"] = bad
        bad = copy.deepcopy(good)
        bad["extra"] = 1
        cases["unexpected key"] = bad
        bad = copy.deepcopy(good)
        bad["metrics"][0]["value"] = "89"
        cases["value as string"] = bad
        bad = copy.deepcopy(good)
        bad["metrics"][0]["unit"] = "furlongs"
        cases["unknown unit"] = bad
        bad = copy.deepcopy(good)
        bad["measured_on"]["date"] = "22/10/2026"
        cases["date format"] = bad
        bad = copy.deepcopy(good)
        bad["runs"] = 0
        cases["zero runs"] = bad
        bad = copy.deepcopy(good)
        bad["schema_version"] = 2
        cases["version"] = bad
        for label, record in cases.items():
            with self.subTest(label):
                self.assertNotEqual(rr.validate(record, self.schema), [])

    def test_null_is_accepted_where_the_schema_allows_it(self):
        good = json.loads(record_files()[0].read_text(encoding="utf-8"))
        good["engine"]["version"] = None
        good["runs"] = None
        self.assertEqual(rr.validate(good, self.schema), [])


class GeneratedFilesAreCurrent(unittest.TestCase):
    def test_generated_files_match_the_generator(self):
        for rel, want in rr.build(ROOT).items():
            with self.subTest(rel):
                have = norm((ROOT / rel).read_text(encoding="utf-8"))
                self.assertEqual(have, want, f"{rel} is stale: run python tools/render_results.py")

    def test_svg_is_well_formed_and_accessible(self):
        text = (ROOT / rr.SVG_PATH).read_text(encoding="utf-8")
        doc = xml.dom.minidom.parseString(text.encode("utf-8"))
        root = doc.documentElement
        self.assertEqual(root.tagName, "svg")
        self.assertEqual(root.getAttribute("role"), "img")
        self.assertTrue(doc.getElementsByTagName("title")[0].firstChild.data)
        self.assertIn("prefers-color-scheme: dark", text)
        for needle in ("~89", "~113", "~101", "~34", "~76"):
            self.assertIn(needle, text)

    def test_readme_alt_text_names_every_bar(self):
        text = (ROOT / "README.md").read_text(encoding="utf-8")
        alt = text.split("![", 1)[1].split("](", 1)[0]
        for needle in ("qwen3:8b", "gpt-oss:20b", "Qwen3 8B", "Gemma 4 26B-A4B", "~113", "~34", "~76"):
            self.assertIn(needle, alt)

    def test_chart_axis_covers_the_largest_bar(self):
        self.assertGreaterEqual(rr.nice_max(113), 113)
        self.assertEqual(rr.nice_max(113), 140)


class GeneratorBehaviour(unittest.TestCase):
    def make_repo(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        shutil.copytree(ROOT / "results", tmp / "results")
        shutil.copy(ROOT / "README.md", tmp / "README.md")
        (tmp / "docs" / "img").mkdir(parents=True)
        shutil.copy(ROOT / rr.SVG_PATH, tmp / rr.SVG_PATH)
        return tmp

    def run_main(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = rr.main(list(args))
        return code, out.getvalue(), err.getvalue()

    def test_check_passes_on_a_current_copy(self):
        tmp = self.make_repo()
        code, _, _ = self.run_main("--check", "--root", str(tmp))
        self.assertEqual(code, 0)

    def test_check_fails_when_data_changes_and_write_fixes_it(self):
        tmp = self.make_repo()
        path = tmp / "results" / "stage3-llamacpp-gemma4-fit-target.json"
        record = json.loads(path.read_text(encoding="utf-8"))
        for m in record["metrics"]:
            if m["name"] == "generation_speed":
                m["value"] = 80
        path.write_text(json.dumps(record, indent=2), encoding="utf-8")
        code, _, err = self.run_main("--check", "--root", str(tmp))
        self.assertEqual(code, 1)
        self.assertIn("README.md", err)
        self.assertIn("tokens-per-second.svg", err)
        self.assertEqual(self.run_main("--root", str(tmp))[0], 0)
        self.assertEqual(self.run_main("--check", "--root", str(tmp))[0], 0)
        self.assertIn("~80", (tmp / "README.md").read_text(encoding="utf-8"))

    def test_check_fails_when_the_readme_is_edited_by_hand(self):
        tmp = self.make_repo()
        readme = tmp / "README.md"
        readme.write_text(readme.read_text(encoding="utf-8").replace("~13% faster", "~50% faster"),
                          encoding="utf-8")
        self.assertEqual(self.run_main("--check", "--root", str(tmp))[0], 1)

    def test_text_outside_the_markers_is_preserved(self):
        tmp = self.make_repo()
        readme = tmp / "README.md"
        text = readme.read_text(encoding="utf-8").replace("## What I learned", "## What I learned (edited)")
        readme.write_text(text, encoding="utf-8")
        self.run_main("--root", str(tmp))
        self.assertIn("## What I learned (edited)", readme.read_text(encoding="utf-8"))

    def test_crlf_readme_keeps_its_line_endings(self):
        tmp = self.make_repo()
        readme = tmp / "README.md"
        data = readme.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
        data = data.replace(b"~13% faster", b"~50% faster")
        readme.write_bytes(data)
        self.assertEqual(self.run_main("--root", str(tmp))[0], 0)
        self.assertIn(b"\r\n", readme.read_bytes())
        self.assertNotIn(b"\n", readme.read_bytes().replace(b"\r\n", b""))
        self.assertEqual(self.run_main("--check", "--root", str(tmp))[0], 0)

    def test_missing_markers_is_an_error(self):
        tmp = self.make_repo()
        readme = tmp / "README.md"
        readme.write_text(readme.read_text(encoding="utf-8").replace("<!-- results:end -->", ""),
                          encoding="utf-8")
        code, _, err = self.run_main("--check", "--root", str(tmp))
        self.assertEqual(code, 2)
        self.assertIn("results:begin", err)

    def test_invalid_record_is_an_error_naming_the_file(self):
        tmp = self.make_repo()
        path = tmp / "results" / "stage1-ollama-qwen3-8b.json"
        record = json.loads(path.read_text(encoding="utf-8"))
        del record["runs"]
        path.write_text(json.dumps(record), encoding="utf-8")
        code, _, err = self.run_main("--check", "--root", str(tmp))
        self.assertEqual(code, 2)
        self.assertIn("stage1-ollama-qwen3-8b.json", err)

    def test_records_without_a_stage_are_valid_but_not_rendered(self):
        tmp = self.make_repo()
        extra = json.loads((tmp / "results" / "stage1-ollama-qwen3-8b.json").read_text(encoding="utf-8"))
        extra["id"] = "bench-example"
        extra["stage"] = None
        extra["order"] = None
        extra["chart"] = None
        (tmp / "results" / "bench-example.json").write_text(json.dumps(extra), encoding="utf-8")
        self.assertEqual(self.run_main("--check", "--root", str(tmp))[0], 0)


if __name__ == "__main__":
    unittest.main()
