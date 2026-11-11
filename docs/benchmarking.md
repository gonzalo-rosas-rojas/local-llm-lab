# Measuring again: `bench/run-bench.ps1`

The figures in the README were typed in as they were measured; the lab had no runner that produced them. `bench/run-bench.ps1` is that runner. It has not been run by the author yet, so every record currently in [`results/`](../results/) predates it and says so.

## What it does

It calls `llama-bench` `-Runs` times (default 3) as separate invocations, each with `-r 1`, on one model with one set of flags, and writes one JSON record in the layout described in [results/README.md](../results/README.md):

- the exact command line, the build number that `llama-bench` reports, and the NVIDIA driver, GPU and VRAM from `nvidia-smi`;
- the UTC time of the measurement;
- every run's value and the median, for the prompt-processing test (`pp<N>`) and the generation test (`tg<N>`);
- `null` for anything it cannot learn (for example the quantization, which it does not read from the file), with a note.

## Usage

```powershell
# Qwen3 8B with the flags from docs/llama-cpp.md
.\bench\run-bench.ps1 -Model .\models\gguf\Qwen3-8B-Q4_K_M.gguf -Flags '-ngl','99','-fa','1'

# five runs, a different prompt length, a named output file
.\bench\run-bench.ps1 -Model .\models\gguf\Qwen3-8B-Q4_K_M.gguf -Flags '-ngl','99' -Runs 5 -Prompt 1024 -OutFile .\results\qwen3-8b-pp1024.json
```

| Parameter | Default | Meaning |
|---|---|---|
| `-Model` | required | Path to a `.gguf` file. |
| `-Flags` | none | Extra `llama-bench` flags, one array element per token. `-m`, `-p`, `-n`, `-r` and `-o` are set by the runner and are refused. |
| `-Runs` | 3 | Separate invocations (1 to 100). |
| `-Prompt`, `-Generate` | 512, 128 | Token counts of the two tests. |
| `-LlamaBench` | `tools\llamacpp\llama-bench.exe` | Path to the binary. |
| `-OutFile` | `results\bench-<UTC time>-<model>.json` | Output path. |

It stops with a one-line message and exit code 1 if the binary or the model is missing, if an input is invalid, if `llama-bench` fails, or if the output file already exists. It never overwrites a record.

A record written by the runner has `stage: null`, so [`tools/render_results.py`](../tools/render_results.py) checks it against the schema but does not put it in the README tables or the chart. To publish one, give it a `stage`, an `order` and a `chart` block, then run the generator.

## What is tested, and what is not

`bench/Test-RunBench.ps1` checks the median, the flag handling, the command construction, the argument quoting and the layout of the record, with values written in the test. `tests/test_bench_record.py` runs it and validates the record it emits against the schema.

The conversion of `llama-bench`'s JSON output into those records (`ConvertFrom-BenchOutput`) has no test. It reads the fields `n_prompt`, `n_gen`, `avg_ts`, `build_number`, `build_commit` and `backends` of `llama-bench -o json`, as llama.cpp documents them, but this repository holds no real `llama-bench` output to test against, and an invented sample would only test the invention. The first real run is the test; if a field is missing, the runner stops and names it.
