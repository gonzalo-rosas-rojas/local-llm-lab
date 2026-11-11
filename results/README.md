# results/

One JSON file per measured configuration. These files are the source of the tables and the chart in the top-level README: `python tools/render_results.py` regenerates both, and `python tools/render_results.py --check` fails when they are out of date. The machine-readable schema is [schema.json](schema.json); `tests/test_results.py` validates every record against it.

## Honesty rules

- A record holds only what the repository had already written down. Nothing here was measured again.
- Every key is required. A value the lab did not record is `null`, never a guess, and `notes` says what is missing.
- `measured_on.date_kind` is `"commit"` when the date is that of the git commit that first stated the figure, which is only an upper bound on when it was measured. Records written by `bench/run-bench.ps1` or `clients/smoke_test.py` use `"measurement"` and a UTC timestamp.
- `approximate: true` means the figure was written with a leading `~`. Values are stored exactly as written, with no rounding.

## Fields

| Key | Meaning |
|---|---|
| `schema_version` | Always `1`. |
| `id` | Unique, and equal to the file name without `.json`. |
| `stage` / `order` | README stage (1 to 3) and position inside it. `null` keeps the record out of the README tables and the chart (the case for records written by the scripts). |
| `role` | Short description used in the README tables. |
| `chart` | `{label, sublabel, series}` for the bar chart, or `null` to leave the record out of it. |
| `model` | `name`, `quantization`, `file`, `size_gb`, `parameters_b`, `active_parameters_b`. |
| `engine` | `name`, `version`, `build`, `backend` (for example the CUDA version of the binaries). |
| `parameters` | `gpu_layers`, `gpu_offload` (text such as "100% GPU"), `context`, `kv_cache_type`, `flash_attention`, `flags` (list of strings). |
| `metrics` | List of `{name, label, unit, value, approximate, statistic, samples}`. `name` is one of `generation_speed`, `prompt_processing_speed`, `vram`, `time_to_first_token`; `label` is the name used in the source (`pp512`, `tg128`). `statistic` is `"median"` or `"single"` when known, else `null`; `samples` lists the per-run values when they were kept. |
| `hardware` | `gpu`, `vram_gb`, `ram_gb`, `cpu`. |
| `system` | `os`, `gpu_driver`. |
| `measured_on` | `date` (`YYYY-MM-DD`, or a UTC timestamp), `date_kind` (`"measurement"` or `"commit"`), `commit` (short hash). |
| `command` | The exact command line, or `null` when the repository does not log it. |
| `runs` | Number of repetitions, or `null` when not recorded. |
| `source` | `file`, `section` and `also_in`: where in this repository the figure was written. |
| `notes` | List of strings: what was not recorded, and anything a reader needs to interpret the figure. |

## Adding a record

Copy an existing file, change `id` (and the file name), fill in what you know and use `null` for the rest, then run `python tools/render_results.py` and `python -m unittest discover -s tests`. Records produced by `bench/run-bench.ps1` already follow this layout; give it a `stage`, an `order` and, if you want it charted, a `chart` to include it in the README.
