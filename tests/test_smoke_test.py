"""Tests for clients/smoke_test.py with a fake client: no network, no openai package."""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "clients"))
sys.path.insert(0, str(ROOT / "tools"))

import render_results as rr  # noqa: E402
import smoke_test as st  # noqa: E402


def text_chunk(text):
    return SimpleNamespace(choices=[SimpleNamespace(delta=SimpleNamespace(content=text))], usage=None)


def usage_chunk(tokens):
    return SimpleNamespace(choices=[], usage=SimpleNamespace(completion_tokens=tokens))


class FakeClock:
    """Returns the given instants one by one, so durations are exact."""

    def __init__(self, instants):
        self.instants = list(instants)

    def __call__(self):
        return self.instants.pop(0)


class FakeClient:
    """Mimics client.chat.completions.create(...) returning a list of chunks per call."""

    def __init__(self, streams=None, error=None):
        self.streams = list(streams or [])
        self.error = error
        self.calls = []
        self.chat = SimpleNamespace(completions=SimpleNamespace(create=self._create))

    def _create(self, **kwargs):
        self.calls.append(kwargs)
        if self.error:
            raise self.error
        return iter(self.streams.pop(0))


# start 0.0, first chunk at 0.5, end at 2.5 -> TTFT 0.5 s, 2.0 s of generation
RUN_TIMES = [0.0, 0.5, 2.5]


class RunOnce(unittest.TestCase):
    def test_uses_server_token_count_when_present(self):
        client = FakeClient([[text_chunk("a"), text_chunk("b"), usage_chunk(41)]])
        run = st.run_once(client, "m", "p", clock=FakeClock(RUN_TIMES))
        self.assertEqual(run["tokens"], 41)
        self.assertEqual(run["chunks"], 2)
        self.assertAlmostEqual(run["ttft"], 0.5)
        value, unit = st.speed_of(run)
        self.assertEqual(unit, "tok/s")
        self.assertAlmostEqual(value, 20.0)  # (41 - 1) tokens in 2.0 s

    def test_falls_back_to_chunks_per_second_with_its_own_name(self):
        client = FakeClient([[text_chunk("a"), text_chunk("b"), text_chunk("c")]])
        run = st.run_once(client, "m", "p", clock=FakeClock(RUN_TIMES))
        self.assertIsNone(run["tokens"])
        value, unit = st.speed_of(run)
        self.assertEqual(unit, "chunks/s")
        self.assertAlmostEqual(value, 1.0)  # (3 - 1) chunks in 2.0 s

    def test_requests_usage_and_streaming(self):
        client = FakeClient([[text_chunk("a")]])
        st.run_once(client, "m", "p", clock=FakeClock(RUN_TIMES))
        call = client.calls[0]
        self.assertTrue(call["stream"])
        self.assertEqual(call["stream_options"], {"include_usage": True})
        self.assertEqual(call["model"], "m")

    def test_reasoning_text_counts_as_the_first_token(self):
        reasoning = SimpleNamespace(
            choices=[SimpleNamespace(delta=SimpleNamespace(content=None, reasoning_content="hm"))], usage=None)
        client = FakeClient([[reasoning, text_chunk("a")]])
        run = st.run_once(client, "m", "p", clock=FakeClock(RUN_TIMES))
        self.assertEqual(run["chunks"], 2)

    def test_a_stream_without_text_is_an_error(self):
        client = FakeClient([[usage_chunk(0)]])
        with self.assertRaises(RuntimeError):
            st.run_once(client, "m", "p", clock=FakeClock([0.0, 1.0]))


class Measure(unittest.TestCase):
    def test_median_over_runs_and_warmup_is_discarded(self):
        # warm-up run, then three runs with 10, 40 and 20 tok/s
        def stream(n):
            return [text_chunk("a"), usage_chunk(n)]
        client = FakeClient([stream(999), stream(11), stream(41), stream(21)])
        times = [0, 1, 2] + [0, 1, 2] + [0, 1, 2] + [0, 1, 2]  # warm-up then 3 runs, each 1 s of generation
        summary = st.measure(client, "m", "p", runs=3, warmup=1, clock=FakeClock(times))
        self.assertEqual(len(client.calls), 4)
        self.assertEqual(summary["speed_samples"], [10.0, 40.0, 20.0])
        self.assertEqual(summary["speed_median"], 20.0)
        self.assertEqual(summary["speed_unit"], "tok/s")
        self.assertEqual(summary["tokens_samples"], [11, 41, 21])

    def test_no_warmup_when_zero(self):
        client = FakeClient([[text_chunk("a"), usage_chunk(5)]])
        st.measure(client, "m", "p", runs=1, warmup=0, clock=FakeClock([0, 1, 2]))
        self.assertEqual(len(client.calls), 1)


class ErrorMessages(unittest.TestCase):
    def test_connection_error_names_the_url(self):
        class APIConnectionError(Exception):
            pass
        msg = st.describe_error(APIConnectionError("boom"), "http://x/v1", "m")
        self.assertIn("http://x/v1", msg)
        self.assertNotIn("\n", msg)

    def test_missing_model(self):
        exc = Exception("nope")
        exc.status_code = 404
        msg = st.describe_error(exc, "http://x/v1", "qwen3:8b")
        self.assertIn("qwen3:8b", msg)
        self.assertIn("ollama pull", msg)

    def test_other_errors_keep_their_type(self):
        self.assertIn("ValueError", st.describe_error(ValueError("bad"), "u", "m"))

    def test_importing_the_module_does_not_import_openai(self):
        self.assertNotIn("openai", sys.modules)

    def test_missing_package_gives_install_hint(self):
        saved = sys.modules.get("openai")
        sys.modules["openai"] = None  # makes "from openai import OpenAI" raise ImportError
        try:
            with self.assertRaises(RuntimeError) as ctx:
                st.make_client("http://x/v1")
        finally:
            if saved is None:
                del sys.modules["openai"]
            else:
                sys.modules["openai"] = saved
        self.assertIn("requirements.txt", str(ctx.exception))


class Main(unittest.TestCase):
    def run_main(self, argv, client, clock=None):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = st.main(argv, client_factory=lambda url: client, clock=clock or FakeClock(range(1000)))
        return code, out.getvalue(), err.getvalue()

    def good_client(self, n=3):
        return FakeClient([[text_chunk("a"), usage_chunk(30)] for _ in range(n)])

    def test_success_prints_medians(self):
        code, out, err = self.run_main(["m", "--runs", "2", "--warmup", "1"], self.good_client(3))
        self.assertEqual(code, 0, err)
        self.assertIn("tok/s", out)
        self.assertIn("median of 2", out)

    def test_unreachable_server_is_one_line_and_nonzero(self):
        class APIConnectionError(Exception):
            pass
        code, out, err = self.run_main(["m"], FakeClient(error=APIConnectionError("refused")))
        self.assertEqual(code, 1)
        self.assertEqual(len(err.strip().splitlines()), 1)
        self.assertIn("cannot reach", err)
        self.assertNotIn("Traceback", err)

    def test_missing_model_is_one_line_and_nonzero(self):
        exc = Exception("not found")
        exc.status_code = 404
        code, _, err = self.run_main(["nope:1b"], FakeClient(error=exc))
        self.assertEqual(code, 1)
        self.assertEqual(len(err.strip().splitlines()), 1)
        self.assertIn("nope:1b", err)

    def test_missing_openai_package_is_one_line(self):
        def factory(url):
            raise RuntimeError("the 'openai' package is not installed (pip install -r clients/requirements.txt)")
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = st.main(["m"], client_factory=factory)
        self.assertEqual(code, 1)
        self.assertIn("not installed", err.getvalue())

    def test_invalid_arguments_exit_2(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as ctx:
            st.main(["m", "--runs", "0"], client_factory=lambda u: None)
        self.assertEqual(ctx.exception.code, 2)

    def test_json_output_validates_against_the_schema(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "out.json")
            code, _, err = self.run_main(["qwen3:8b", "--runs", "3", "--json", path], self.good_client(4))
            self.assertEqual(code, 0, err)
            record = json.loads(Path(path).read_text(encoding="utf-8"))
        self.assertEqual(rr.validate(record, rr.load_schema(ROOT)), [])
        names = {m["name"]: m for m in record["metrics"]}
        self.assertEqual(names["generation_speed"]["unit"], "tok/s")
        self.assertEqual(len(names["generation_speed"]["samples"]), 3)
        self.assertEqual(record["runs"], 3)
        self.assertIsNone(record["engine"]["version"])

    def test_json_output_with_chunk_counts_uses_chunks_unit(self):
        client = FakeClient([[text_chunk("a"), text_chunk("b")] for _ in range(2)])
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "out.json")
            code, out, _ = self.run_main(["m", "--runs", "1", "--json", path], client)
            record = json.loads(Path(path).read_text(encoding="utf-8"))
        self.assertEqual(code, 0)
        self.assertIn("chunks/s", out)
        self.assertEqual(rr.validate(record, rr.load_schema(ROOT)), [])
        gen = [m for m in record["metrics"] if m["name"] == "generation_speed"][0]
        self.assertEqual(gen["unit"], "chunks/s")

    def test_no_output_file_is_left_when_the_run_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "out.json")
            code, _, _ = self.run_main(["m", "--json", path], FakeClient(error=ValueError("x")))
            self.assertEqual(code, 1)
            self.assertFalse(os.path.exists(path))

    def test_existing_output_file_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "keep.json")
            Path(path).write_text("old", encoding="utf-8")
            client = self.good_client(4)
            code, _, err = self.run_main(["m", "--json", path], client)
            self.assertEqual(code, 1)
            self.assertIn("never overwritten", err)
            self.assertEqual(Path(path).read_text(encoding="utf-8"), "old")
            self.assertEqual(client.calls, [])  # refused before any request


if __name__ == "__main__":
    unittest.main()
