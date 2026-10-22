# Stage 2: llama.cpp directly

Dropping from Ollama to **llama.cpp** (the engine Ollama uses underneath) to control and understand the knobs Ollama hides.

## What was installed

- `llama.cpp` build **b9482**, **CUDA 12.4** binaries (compatible with driver 555.97 / CUDA 12.5; the 13.3 build does NOT work) in `tools/llamacpp/` (not versioned).
- Model **`Qwen3-8B-Q4_K_M.gguf`** (4.68 GB) in `models/gguf/` (not versioned), downloaded from the official `Qwen/Qwen3-8B-GGUF` repository on Hugging Face.

## The knobs (`llama-server` / `llama-bench` flags)

| Flag | What it does |
|---|---|
| `-ngl 99` | n-gpu-layers: how many layers go to the GPU (99 = all) |
| `-fa 1` | Flash Attention: less attention VRAM and faster |
| `-c 8192` | context size = size of the KV cache |
| `-ctk q8_0` / `-ctv q8_0` | quantizes the KV cache to 8 bits (needs `-fa`); about half the context VRAM |
| `--jinja` | uses the model's chat template (handles Qwen3's "thinking") |

## Measured results (RTX 4090 Laptop, Qwen3 8B Q4_K_M)

| Metric | Value |
|---|---|
| Prefill (pp512) | ~5724 t/s |
| Generation (tg128) | ~101 t/s |
| VRAM (model + KV q8_0, ctx 8192) | ~6.3 GB |

### llama.cpp vs Ollama (same model)

| Engine | Generation |
|---|---|
| Ollama | ~89 tok/s |
| llama.cpp | ~101 tok/s (**~13% faster**) |

## Running it

```powershell
.\scripts\llama-server\run-qwen3-8b.ps1   # -> http://localhost:8080 (UI + /v1 API)
```

Qwen3 tip: add `/no_think` at the end of the prompt for direct answers (no reasoning).

To measure again:

```powershell
.\tools\llamacpp\llama-bench.exe -m .\models\gguf\Qwen3-8B-Q4_K_M.gguf -ngl 99 -fa 1
```

## What I learned

- **Prefill (compute-bound) is far faster than generation (bandwidth-bound):** 5724 vs 101 t/s. A laptop GPU suffers more in generation because it depends on VRAM bandwidth, not on CUDA cores.
- **A quantized KV cache (q8_0)** keeps context cheap: 8192 tokens in ~6.3 GB total.
- **llama.cpp has less overhead than Ollama:** ~13% faster on the same model, in exchange for managing the flags yourself.
- **CUDA compatibility matters:** the 12.4 build was used (not 13.3) because of the driver.
