# Stage 3: MoE offload (running models that do NOT fit in 16 GB)

**Technique:** in a Mixture-of-Experts (MoE) model, most of the weights are "experts" that are rarely active for any given token. With llama.cpp you can keep those experts in **system RAM** (64 GB here) and keep only what is used on the **GPU**. That lets you run models whose total size exceeds the 16 GB of VRAM.

## Model used

- **Gemma 4 26B-A4B**: 25.23B total / ~3.8B active parameters. GGUF `UD-Q4_K_M` from unsloth, **15.78 GB**.
- It does not fit entirely in 16 GB next to the KV cache and buffers, so offload is needed.
- It is a **"thinking"** model (it fills `reasoning_content`); raise `max_tokens` to see the final answer.

## The offload knobs (llama.cpp)

| Flag | What it does |
|---|---|
| `--cpu-moe` | ALL experts to RAM (maximum VRAM saving, slower) |
| `-ncmoe N` | experts of the first N layers to RAM (partial offload). `llama-bench` only accepts this one |
| `--fit-target <MiB>` | auto: keeps as many experts on the GPU as fit, leaving that margin (the fastest that fits) |

## Measured results (RTX 4090 Laptop, Gemma 4 26B-A4B)

| Config | Experts | Prefill (pp512) | Generation (tg128) | VRAM |
|---|---|---|---|---|
| `--cpu-moe` / `-ncmoe 99` | all in RAM | ~459 t/s | ~34 tok/s | ~5 GB |
| `--fit-target 1024` | most on the GPU | ~1628 t/s | **~76 tok/s** | ~15 GB |

**Lesson:** do not offload more than you must. Fill your VRAM first and send only the surplus to RAM. Going from "everything in RAM" to auto-fit **doubled** the speed (34 to 76 tok/s).

## Running it

```powershell
.\scripts\llama-server\run-gemma4-moe.ps1   # -> http://localhost:8080 (UI + /v1 API)
```

The GGUF (`gemma-4-26B-A4B-it-UD-Q4_K_M.gguf`) goes in `models/gguf/` and is not versioned.

## Alternative: Qwen3-30B-A3B

Same trick with `Qwen/Qwen3-30B-A3B-GGUF` (`Qwen3-30B-A3B-Q4_K_M.gguf`), another classic MoE for offload. Download it to `models/gguf/` and point the script at that file.

## What I learned

- **Total vs active:** a 25B-parameter model runs like a small one because only ~3.8B are active per token; the inactive experts can wait in RAM.
- **VRAM vs speed:** every expert you move back to the GPU speeds things up; `--fit-target` automates the sweet spot for your card.
- **It unlocks larger models** without buying more VRAM, which is the key to getting more quality locally.
