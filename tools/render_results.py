#!/usr/bin/env python3
"""Render the README tables and the bar chart from the records in results/.

Standard library only. Usage:

    python tools/render_results.py           # rewrite README.md blocks and the SVG
    python tools/render_results.py --check   # exit 1 if either is out of date

Every figure shown in the README comes from a JSON file in results/. The generated
parts of the README sit between <!-- NAME:begin --> and <!-- NAME:end --> markers;
everything outside the markers is hand-written and is never touched.
"""
import argparse
import json
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
SVG_PATH = Path("docs/img/tokens-per-second.svg")
SVG_REF = "docs/img/tokens-per-second.svg"

# Record ids the prose below compares against each other.
ID_OLLAMA_QWEN = "stage1-ollama-qwen3-8b"
ID_BENCH_QWEN = "stage2-llamacpp-qwen3-8b-bench"
ID_VRAM_QWEN = "stage2-llamacpp-qwen3-8b-vram"
ID_GEMMA_CPU = "stage3-llamacpp-gemma4-cpu-moe"
ID_GEMMA_FIT = "stage3-llamacpp-gemma4-fit-target"

STAGE_TITLES = {
    1: "Stage 1: Ollama, models that fit in VRAM",
    2: "Stage 2: llama.cpp directly, same model as Ollama",
    3: "Stage 3: Mixture-of-experts offload, a model that does not fit",
}


# ---------------------------------------------------------------- validation

def _type_ok(value, name):
    if name == "null":
        return value is None
    if name == "boolean":
        return isinstance(value, bool)
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if name == "string":
        return isinstance(value, str)
    if name == "array":
        return isinstance(value, list)
    if name == "object":
        return isinstance(value, dict)
    raise ValueError(f"unsupported type in schema: {name}")


def validate(value, schema, path="$"):
    """Check `value` against the JSON Schema subset used by results/schema.json.

    Supported keywords: type, const, enum, pattern, minimum, required, properties,
    additionalProperties (false only) and items. Returns a list of error strings.
    """
    errors = []
    if "type" in schema:
        names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_type_ok(value, n) for n in names):
            return [f"{path}: expected {' or '.join(names)}, got {type(value).__name__}"]
    if "const" in schema and value != schema["const"]:
        errors.append(f"{path}: expected {schema['const']!r}, got {value!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} is not one of {schema['enum']}")
    if isinstance(value, str) and "pattern" in schema and not re.search(schema["pattern"], value):
        errors.append(f"{path}: {value!r} does not match {schema['pattern']}")
    if (isinstance(value, (int, float)) and not isinstance(value, bool)
            and "minimum" in schema and value < schema["minimum"]):
        errors.append(f"{path}: {value} is below the minimum {schema['minimum']}")
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing required key '{key}'")
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in props:
                    errors.append(f"{path}: unexpected key '{key}'")
        for key, sub in props.items():
            if key in value:
                errors.extend(validate(value[key], sub, f"{path}.{key}"))
    if isinstance(value, list) and "items" in schema:
        for i, item in enumerate(value):
            errors.extend(validate(item, schema["items"], f"{path}[{i}]"))
    return errors


def load_schema(root=ROOT):
    return json.loads((Path(root) / "results" / "schema.json").read_text(encoding="utf-8"))


def load_records(root=ROOT):
    """Read and validate every results/*.json record; return them sorted for display."""
    root = Path(root)
    schema = load_schema(root)
    records = []
    problems = []
    for path in sorted((root / "results").glob("*.json")):
        if path.name == "schema.json":
            continue
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            problems.append(f"{path.name}: not valid JSON ({exc})")
            continue
        errs = validate(record, schema)
        if not errs and record["id"] != path.stem:
            errs = [f"$.id: '{record['id']}' must equal the file name '{path.stem}'"]
        problems.extend(f"{path.name}: {e}" for e in errs)
        records.append(record)
    if problems:
        raise ValueError("invalid results:\n  " + "\n  ".join(problems))
    if not records:
        raise ValueError("no records found in results/")
    ids = [r["id"] for r in records]
    if len(set(ids)) != len(ids):
        raise ValueError("duplicate record ids in results/")
    # Records with no stage (for example the output of bench/run-bench.ps1) are valid
    # data but are not part of the README tables or the chart.
    staged = [r for r in records if r["stage"] is not None]
    return sorted(staged, key=lambda r: (r["stage"], r["order"] or 0))


# ----------------------------------------------------------------- formatting

def num(value):
    return str(int(value)) if float(value).is_integer() else str(value)


def metric(record, name):
    for m in record["metrics"]:
        if m["name"] == name:
            return m
    return None


def shown(m):
    """Value with a leading '~' when the source states it as approximate."""
    return ("~" if m["approximate"] else "") + num(m["value"])


def with_unit(m):
    return f"{shown(m)} {m['unit']}"


def by_id(records, record_id):
    for r in records:
        if r["id"] == record_id:
            return r
    raise KeyError(f"record '{record_id}' is missing from results/")


def need(record, name):
    m = metric(record, name)
    if m is None:
        raise KeyError(f"record '{record['id']}' has no '{name}' metric")
    return m


# ------------------------------------------------------------------- README

def stage1_section(records):
    rows = [r for r in records if r["stage"] == 1]
    lines = ["| Model | Role | Speed | GPU / VRAM |", "|---|---|---|---|"]
    for r in rows:
        gpu = ", ".join(
            p for p in (r["parameters"]["gpu_offload"], with_unit_vram(r)) if p
        )
        lines.append(
            f"| `{r['model']['name']}` | {r['role']} "
            f"| {with_unit(need(r, 'generation_speed'))} | {gpu} |"
        )
    return lines


def with_unit_vram(record):
    m = metric(record, "vram")
    return f"{shown(m)} {m['unit']}" if m else None


def stage2_section(records):
    bench = by_id(records, ID_BENCH_QWEN)
    vram = by_id(records, ID_VRAM_QWEN)
    ollama = by_id(records, ID_OLLAMA_QWEN)
    model = bench["model"]
    eng = bench["engine"]
    pp = need(bench, "prompt_processing_speed")
    tg = need(bench, "generation_speed")
    vm = need(vram, "vram")
    vp = vram["parameters"]
    ollama_tg = need(ollama, "generation_speed")
    gain = round((tg["value"] / ollama_tg["value"] - 1) * 100)
    lines = [
        f"{model['name']} {model['quantization']} ({num(model['size_gb'])} GB), "
        f"llama.cpp build {eng['build']} with {eng['backend']} binaries, "
        f"NVIDIA driver {bench['system']['gpu_driver']}.",
        "",
        "| Metric | Value |",
        "|---|---|",
        f"| Prompt processing ({pp['label']}) | {with_unit(pp)} |",
        f"| Generation ({tg['label']}) | {with_unit(tg)} |",
        f"| VRAM, model + KV cache at {vp['kv_cache_type']}, context {vp['context']} "
        f"| {with_unit(vm)} |",
        "",
        f"Same model through Ollama generates at {with_unit(ollama_tg)}, so llama.cpp is "
        f"~{gain}% faster, in exchange for managing the flags yourself. "
        "See [docs/llama-cpp.md](docs/llama-cpp.md).",
    ]
    return lines


def moe_gain(records):
    cpu = need(by_id(records, ID_GEMMA_CPU), "generation_speed")
    fit = need(by_id(records, ID_GEMMA_FIT), "generation_speed")
    return cpu, fit, fit["value"] / cpu["value"]


def stage3_section(records):
    rows = [by_id(records, ID_GEMMA_CPU), by_id(records, ID_GEMMA_FIT)]
    model = rows[0]["model"]
    cpu, fit, ratio = moe_gain(records)
    best = max(need(r, "generation_speed")["value"] for r in rows)
    lines = [
        f"{model['name']} ({num(model['parameters_b'])}B parameters, "
        f"~{num(model['active_parameters_b'])}B active per token), GGUF {model['quantization']}, "
        f"{num(model['size_gb'])} GB: too big for {num(rows[0]['hardware']['vram_gb'])} GB "
        "of VRAM once the KV cache and buffers are counted.",
        "",
        "| Configuration | Experts | pp512 | tg128 | VRAM |",
        "|---|---|---|---|---|",
    ]
    for r in rows:
        tg = need(r, "generation_speed")
        tg_text = with_unit(tg)
        if tg["value"] == best:
            tg_text = f"**{tg_text}**"
        lines.append(
            f"| `{r['parameters']['flags'][0]}` | {r['role']} "
            f"| {with_unit(need(r, 'prompt_processing_speed'))} | {tg_text} "
            f"| {with_unit_vram(r)} |"
        )
    speedup = "more than doubled" if ratio > 2 else f"multiplied by {ratio:.1f}"
    lines += [
        "",
        "Do not offload more than you must: fill VRAM first and send only the remainder "
        f'to RAM. Going from "everything in RAM" to auto-fit {speedup} generation speed '
        f"({num(cpu['value'])} to {num(fit['value'])} tok/s, {ratio:.1f}x). "
        "See [docs/moe-offload.md](docs/moe-offload.md).",
    ]
    return lines


def provenance_section(records):
    lines = [
        "### Where each figure comes from",
        "",
        "Each row is one JSON record in [`results/`](results/) "
        "(schema and field meanings in [results/README.md](results/README.md)). "
        "Dates are the date of the commit that first states the figure, not of the "
        "measurement. \"not recorded\" means the lab never logged it; the record holds `null` "
        "and a note.",
        "",
        "| Record | Engine | Date | Runs | Exact command logged |",
        "|---|---|---|---|---|",
    ]
    for r in records:
        mo = r["measured_on"]
        if mo["date"] is None:
            date = "not recorded"
        else:
            date = f"{mo['date']} ({mo['date_kind']} date)"
        runs = "not recorded" if r["runs"] is None else str(r["runs"])
        logged = "no" if r["command"] is None else "yes"
        lines.append(
            f"| [`{r['id']}`](results/{r['id']}.json) | {r['engine']['name']} "
            f"| {date} | {runs} | {logged} |"
        )
    return lines


def results_block(records):
    out = []
    for stage in sorted({r["stage"] for r in records}):
        out += [f"### {STAGE_TITLES[stage]}", ""]
        out += {1: stage1_section, 2: stage2_section, 3: stage3_section}[stage](records)
        out.append("")
    out += provenance_section(records)
    return "\n".join(out)


def chart_rows(records):
    return [r for r in records if r["chart"] and metric(r, "generation_speed")]


def alt_text(records):
    parts = []
    for r in chart_rows(records):
        c = r["chart"]
        parts.append(f"{c['label']} on {c['sublabel']} {shown(metric(r, 'generation_speed'))}")
    return ("Horizontal bar chart of generation speed in tokens per second: "
            + "; ".join(parts) + ".")


def summary_block(records):
    cpu, fit, _ = moe_gain(records)
    return "\n".join([
        f"![{alt_text(records)}]({SVG_REF})",
        "",
        f"**Main finding:** with Gemma 4 26B-A4B, a mixture-of-experts model that does not "
        f"fit in 16 GB of VRAM, generation went from {shown(cpu)} to {shown(fit)} tok/s "
        "when the experts were placed in VRAM first and only the remainder in system RAM, "
        "instead of all in RAM.",
        "Why that works, and its limits: [MoE offload notes](docs/moe-offload.md).",
    ])


BLOCKS = {"summary": summary_block, "results": results_block}


def replace_block(text, name, body):
    begin = f"<!-- {name}:begin -->"
    end = f"<!-- {name}:end -->"
    pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.S)
    if len(pattern.findall(text)) != 1:
        raise ValueError(f"README.md needs exactly one '{begin}' ... '{end}' pair")
    note = "<!-- generated by tools/render_results.py from results/*.json; do not edit by hand -->"
    replacement = f"{begin}\n{note}\n\n{body}\n\n{end}"
    return pattern.sub(lambda _m: replacement, text)


def render_readme(text, records):
    """Return `text` (LF newlines) with every generated block rewritten."""
    for name, fn in BLOCKS.items():
        text = replace_block(text, name, fn(records))
    return text


# ----------------------------------------------------------------------- SVG

CSS = """\
    text { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }
    .bg { fill: #ffffff; stroke: #d0d7de; }
    .ink { fill: #1f2328; }
    .muted { fill: #59636e; }
    .grid { stroke: #d8dee4; stroke-width: 1; }
    .axis { stroke: #8c959f; stroke-width: 1; }
    .s0 { fill: #c2410c; }
    .s1 { fill: #0969da; }
    @media (prefers-color-scheme: dark) {
      .bg { fill: #0d1117; stroke: #30363d; }
      .ink { fill: #e6edf3; }
      .muted { fill: #9198a1; }
      .grid { stroke: #30363d; }
      .axis { stroke: #6e7681; }
      .s0 { fill: #f0883e; }
      .s1 { fill: #58a6ff; }
    }"""


def nice_max(top):
    step = 20
    return int(-(-top * 1.15 // step) * step)


def render_svg(records):
    rows = chart_rows(records)
    series = []
    for r in rows:
        if r["chart"]["series"] not in series:
            series.append(r["chart"]["series"])
    if len(series) > 2:
        raise ValueError("the chart palette has two series")
    width = 800
    left, right = 250, 40
    plot_w = width - left - right
    top = 92
    row_h = 46
    bar_h = 26
    axis_y = top + row_h * len(rows)
    height = axis_y + 82
    values = [metric(r, "generation_speed")["value"] for r in rows]
    vmax = nice_max(max(values))
    ticks = list(range(0, vmax + 1, 20))

    def x_of(v):
        return left + plot_w * v / vmax

    first_hw = rows[0]["hardware"]
    subtitle = (f"{first_hw['gpu']}, {num(first_hw['vram_gb'])} GB VRAM. "
                "Approximate figures; run counts are not recorded (see results/).")
    title = "Generation speed in tokens per second (higher is better)"
    out = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img" aria-labelledby="t d">',
        f"  <title id=\"t\">{escape(title)}</title>",
        f"  <desc id=\"d\">{escape(alt_text(records))}</desc>",
        "  <style>",
        CSS,
        "  </style>",
        f'  <rect class="bg" x="0.5" y="0.5" width="{width - 1}" height="{height - 1}" rx="8"/>',
        f'  <text class="ink" x="24" y="36" font-size="18" font-weight="600">{escape(title)}</text>',
        f'  <text class="muted" x="24" y="58" font-size="12.5">{escape(subtitle)}</text>',
    ]
    for t in ticks:
        x = x_of(t)
        out.append(f'  <line class="grid" x1="{x:.1f}" y1="{top - 8}" x2="{x:.1f}" y2="{axis_y}"/>')
        out.append(f'  <text class="muted" x="{x:.1f}" y="{axis_y + 18}" font-size="12" '
                   f'text-anchor="middle">{t}</text>')
    out.append(f'  <line class="axis" x1="{left}" y1="{top - 8}" x2="{left}" y2="{axis_y}"/>')
    out.append(f'  <line class="axis" x1="{left}" y1="{axis_y}" x2="{left + plot_w}" y2="{axis_y}"/>')
    for i, r in enumerate(rows):
        c = r["chart"]
        m = metric(r, "generation_speed")
        y = top + row_h * i
        cy = y + row_h / 2
        w = x_of(m["value"]) - left
        cls = f"s{series.index(c['series'])}"
        out.append(f'  <text class="ink" x="{left - 12}" y="{cy - 3:.1f}" font-size="14" '
                   f'font-weight="600" text-anchor="end">{escape(c["label"])}</text>')
        out.append(f'  <text class="muted" x="{left - 12}" y="{cy + 13:.1f}" font-size="12" '
                   f'text-anchor="end">{escape(c["sublabel"])}</text>')
        out.append(f'  <rect class="{cls}" x="{left}" y="{cy - bar_h / 2:.1f}" width="{w:.1f}" '
                   f'height="{bar_h}" rx="3"/>')
        out.append(f'  <text class="ink" x="{left + w + 8:.1f}" y="{cy + 5:.1f}" font-size="14" '
                   f'font-weight="600">{escape(shown(m))}</text>')
    out.append(f'  <text class="muted" x="{left + plot_w / 2:.1f}" y="{axis_y + 40}" '
               f'font-size="12.5" text-anchor="middle">tokens per second</text>')
    lx = left
    ly = axis_y + 64
    for i, name in enumerate(series):
        out.append(f'  <rect class="s{i}" x="{lx}" y="{ly - 10}" width="12" height="12" rx="2"/>')
        out.append(f'  <text class="ink" x="{lx + 18}" y="{ly}" font-size="12.5">{escape(name)}</text>')
        lx += 18 + 8 * len(name) + 28
    out.append("</svg>")
    return "\n".join(out) + "\n"


# ------------------------------------------------------------------ commands

def normalize(text):
    return text.replace("\r\n", "\n")


def build(root):
    """Return (readme_text, svg_text) as they should be on disk, with LF newlines."""
    root = Path(root)
    records = load_records(root)
    readme = normalize((root / "README.md").read_text(encoding="utf-8"))
    return render_readme(readme, records), render_svg(records)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--check", action="store_true",
                    help="do not write; exit 1 if README.md or the SVG is out of date")
    ap.add_argument("--root", default=str(ROOT), help="repository root (default: this repo)")
    args = ap.parse_args(argv)
    root = Path(args.root)
    try:
        want_readme, want_svg = build(root)
    except (ValueError, KeyError, OSError) as exc:
        print(f"render_results: {exc}", file=sys.stderr)
        return 2
    readme_path = root / "README.md"
    svg_path = root / SVG_PATH
    have_readme = normalize(readme_path.read_text(encoding="utf-8"))
    have_svg = normalize(svg_path.read_text(encoding="utf-8")) if svg_path.exists() else None
    stale = []
    if have_readme != want_readme:
        stale.append("README.md")
    if have_svg != want_svg:
        stale.append(str(SVG_PATH).replace("\\", "/"))
    if args.check:
        if stale:
            print("render_results: out of date: " + ", ".join(stale)
                  + ". Run: python tools/render_results.py", file=sys.stderr)
            return 1
        print("render_results: README.md and SVG match results/")
        return 0
    if "README.md" in stale:
        raw = readme_path.read_bytes().decode("utf-8")
        eol = "\r\n" if "\r\n" in raw else "\n"
        readme_path.write_bytes(want_readme.replace("\n", eol).encode("utf-8"))
    if str(SVG_PATH).replace("\\", "/") in stale:
        svg_path.parent.mkdir(parents=True, exist_ok=True)
        svg_path.write_bytes(want_svg.encode("utf-8"))
    print("render_results: wrote " + (", ".join(stale) if stale else "nothing (already current)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
