"""
smoke_test.py - Streams a short answer from an OpenAI-compatible server (Ollama's
http://localhost:11434/v1 by default) and reports the two numbers that matter here:

  - TTFT (time to first token): how long it takes to START answering. Dominated by
    prefill, the processing of the prompt, which scales with compute.
  - generation speed: output speed, which scales with VRAM memory bandwidth.

Speed is tokens per second when the server reports a token count (the `usage` field of
the last streamed chunk). When it does not, the script counts streamed chunks instead
and labels the number "chunks/s": a chunk is not always one token, so the two are not
interchangeable. Time starts at the first streamed chunk, so the first token is not
counted in the speed. Each number is the median over the measured runs; warm-up runs
are executed and discarded.

Usage:
    python -m venv .venv
    .\\.venv\\Scripts\\Activate.ps1
    pip install -r clients\\requirements.txt
    python clients\\smoke_test.py                       # qwen3:8b, 3 runs after 1 warm-up
    python clients\\smoke_test.py gpt-oss:20b --runs 5
    python clients\\smoke_test.py qwen3:8b --json results\\my-smoke.json

Exit code: 0 on success; 1 when the server cannot be reached, the model does not exist
or the request fails; 2 for invalid arguments.
"""
import argparse
import datetime
import json
import os
import re
import statistics
import sys
import time

DEFAULT_MODEL = "qwen3:8b"
DEFAULT_BASE_URL = "http://localhost:11434/v1"
PROMPT = "Explain in 3 sentences what quantization of an LLM is."


def make_client(base_url):
    """Create the real OpenAI client. The package is imported here, not at load time."""
    try:
        from openai import OpenAI
    except ImportError as exc:
        raise RuntimeError(
            "the 'openai' package is not installed (pip install -r clients/requirements.txt)"
        ) from exc
    # api_key is a placeholder: Ollama does not check it, but the SDK requires one.
    return OpenAI(base_url=base_url, api_key="ollama")


def _has_text(chunk):
    """True when a streamed chunk carries visible or reasoning text."""
    if not getattr(chunk, "choices", None):
        return False
    delta = chunk.choices[0].delta
    for field in ("content", "reasoning_content", "reasoning"):
        if getattr(delta, field, None):
            return True
    return False


def run_once(client, model, prompt, clock=time.perf_counter, on_text=None):
    """One streamed request. Returns a dict with ttft, gen_time, chunks and tokens.

    `tokens` is the server's completion token count, or None when it did not send one.
    `client` is anything with the OpenAI client's chat.completions.create interface.
    """
    start = clock()
    first_at = None
    chunks = 0
    tokens = None
    stream = client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": prompt}],
        stream=True,
        stream_options={"include_usage": True},
    )
    for chunk in stream:
        usage = getattr(chunk, "usage", None)
        if usage is not None and getattr(usage, "completion_tokens", None) is not None:
            tokens = usage.completion_tokens
        if _has_text(chunk):
            if first_at is None:
                first_at = clock()
            chunks += 1
            if on_text:
                on_text(chunk.choices[0].delta.content or "")
    end = clock()
    if first_at is None:
        raise RuntimeError("the server answered but sent no text")
    return {"ttft": first_at - start, "gen_time": end - first_at, "chunks": chunks, "tokens": tokens}


def speed_of(run):
    """(value, unit) for one run: tokens/s if the server counted tokens, else chunks/s."""
    if run["gen_time"] <= 0:
        return None, None
    if run["tokens"] is not None:
        return (run["tokens"] - 1) / run["gen_time"], "tok/s"
    return (run["chunks"] - 1) / run["gen_time"], "chunks/s"


def measure(client, model, prompt, runs=3, warmup=1, clock=time.perf_counter, on_text=None):
    """Run `warmup` discarded requests then `runs` measured ones; return the summary."""
    for _ in range(warmup):
        run_once(client, model, prompt, clock=clock)
    results = [run_once(client, model, prompt, clock=clock, on_text=on_text) for _ in range(runs)]
    speeds = [speed_of(r) for r in results]
    units = {u for _, u in speeds}
    if None in {v for v, _ in speeds} or len(units) != 1:
        unit = None
        values = []
    else:
        unit = units.pop()
        values = [v for v, _ in speeds]
    ttfts = [r["ttft"] for r in results]
    return {
        "runs": runs,
        "warmup": warmup,
        "ttft_samples": ttfts,
        "ttft_median": statistics.median(ttfts),
        "speed_unit": unit,
        "speed_samples": values,
        "speed_median": statistics.median(values) if values else None,
        "tokens_samples": [r["tokens"] for r in results],
    }


def describe_error(exc, base_url, model):
    """One line for an error raised while talking to the server."""
    name = type(exc).__name__
    status = getattr(exc, "status_code", None)
    if name in ("APIConnectionError", "APITimeoutError", "ConnectError") or isinstance(
        exc, (ConnectionError, TimeoutError)
    ):
        return f"cannot reach the server at {base_url}: is it running?"
    if status == 404 or name == "NotFoundError":
        return f"the server at {base_url} has no model '{model}' (for Ollama: ollama pull {model})"
    if isinstance(exc, RuntimeError):
        return str(exc)
    return f"request to {base_url} failed: {name}: {exc}"


def build_record(model, base_url, summary, command, when=None):
    """A results/ record (see results/schema.json) for one smoke-test session."""
    when = when or datetime.datetime.now(datetime.timezone.utc)
    stamp = when.strftime("%Y-%m-%dT%H:%M:%SZ")
    slug = re.sub(r"[^a-z0-9]+", "-", model.lower()).strip("-")
    runs = summary["runs"]
    statistic = "single" if runs == 1 else "median"
    metrics = [{
        "name": "time_to_first_token", "label": "TTFT", "unit": "s",
        "value": summary["ttft_median"], "approximate": False,
        "statistic": statistic, "samples": summary["ttft_samples"],
    }]
    notes = [
        f"{summary['warmup']} warm-up run(s) were executed and discarded.",
        "Speed starts at the first streamed chunk, so the first token is not counted.",
        "The client cannot see the server's engine, build, flags, GPU or driver; those fields are null.",
    ]
    if summary["speed_unit"] is not None:
        label = ("generation, server token count" if summary["speed_unit"] == "tok/s"
                 else "generation, streamed chunks")
        metrics.append({
            "name": "generation_speed", "label": label, "unit": summary["speed_unit"],
            "value": summary["speed_median"], "approximate": False,
            "statistic": statistic, "samples": summary["speed_samples"],
        })
        if summary["speed_unit"] == "chunks/s":
            notes.append("The server sent no token count, so speed is streamed chunks per second, not tokens.")
    else:
        notes.append("No generation speed: the runs were too short to time or mixed token counts and chunk counts.")
    return {
        "schema_version": 1,
        "id": f"smoke-{when.strftime('%Y%m%dt%H%M%Sz')}-{slug}",
        "stage": None, "order": None, "role": None, "chart": None,
        "model": {"name": model, "quantization": None, "file": None, "size_gb": None,
                  "parameters_b": None, "active_parameters_b": None},
        "engine": {"name": "OpenAI-compatible API", "version": None, "build": None, "backend": None},
        "parameters": {"gpu_layers": None, "gpu_offload": None, "context": None,
                       "kv_cache_type": None, "flash_attention": None, "flags": None},
        "metrics": metrics,
        "hardware": {"gpu": None, "vram_gb": None, "ram_gb": None, "cpu": None},
        "system": {"os": None, "gpu_driver": None},
        "measured_on": {"date": stamp, "date_kind": "measurement", "commit": None},
        "command": command,
        "runs": runs,
        "source": {"file": "clients/smoke_test.py", "section": "generated by the script", "also_in": []},
        "notes": notes,
    }


def _positive(text):
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError("must be 1 or more")
    return value


def _non_negative(text):
    value = int(text)
    if value < 0:
        raise argparse.ArgumentTypeError("must be 0 or more")
    return value


def parse_args(argv):
    ap = argparse.ArgumentParser(description="Time-to-first-token and generation speed over an OpenAI-compatible API.")
    ap.add_argument("model", nargs="?", default=DEFAULT_MODEL, help=f"model name (default {DEFAULT_MODEL})")
    ap.add_argument("--base-url", default=DEFAULT_BASE_URL, help=f"API base URL (default {DEFAULT_BASE_URL})")
    ap.add_argument("--runs", type=_positive, default=3, help="measured runs (default 3)")
    ap.add_argument("--warmup", type=_non_negative, default=1, help="discarded warm-up runs (default 1)")
    ap.add_argument("--prompt", default=PROMPT, help="prompt to send")
    ap.add_argument("--json", metavar="PATH", help="also write a results/ record to PATH (never overwrites)")
    ap.add_argument("--show-text", action="store_true", help="print the streamed answer of each measured run")
    return ap.parse_args(argv)


def main(argv=None, client_factory=make_client, clock=time.perf_counter):
    argv = sys.argv[1:] if argv is None else list(argv)
    args = parse_args(argv)
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:  # not a console stream, or an old Python
        pass
    if args.json and os.path.exists(args.json):
        print(f"smoke_test: {args.json} already exists; it is never overwritten", file=sys.stderr)
        return 1
    try:
        client = client_factory(args.base_url)
        print(f"== Model: {args.model} at {args.base_url} ({args.warmup} warm-up, {args.runs} measured) ==")
        on_text = (lambda t: print(t, end="", flush=True)) if args.show_text else None
        summary = measure(client, args.model, args.prompt, args.runs, args.warmup, clock=clock, on_text=on_text)
    except Exception as exc:  # any failure becomes one line, not a traceback
        print(f"smoke_test: {describe_error(exc, args.base_url, args.model)}", file=sys.stderr)
        return 1
    if args.show_text:
        print()
    print(f"TTFT, median of {args.runs}: {summary['ttft_median']:.2f} s")
    if summary["speed_unit"] is None:
        print("Generation speed: not available (runs too short to time)")
    else:
        print(f"Generation speed, median of {args.runs}: {summary['speed_median']:.1f} {summary['speed_unit']}")
        if summary["speed_unit"] == "chunks/s":
            print("(the server sent no token count, so this counts streamed chunks, not tokens)")
    if args.json:
        record = build_record(args.model, args.base_url, summary, "python clients/smoke_test.py " + " ".join(argv))
        try:
            with open(args.json, "x", encoding="utf-8") as fh:
                json.dump(record, fh, indent=2)
                fh.write("\n")
        except OSError as exc:  # includes FileExistsError if the file appeared meanwhile
            print(f"smoke_test: cannot write {args.json}: {exc}", file=sys.stderr)
            return 1
        print(f"Wrote {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
