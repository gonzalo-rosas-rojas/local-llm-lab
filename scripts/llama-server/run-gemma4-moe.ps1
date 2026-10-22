#Requires -Version 5.1
<#
  run-gemma4-moe.ps1
  ------------------------------------------------------------------
  Serves Gemma 4 26B-A4B (MoE: 25B total / ~3.8B active), which does NOT fit
  entirely in 16 GB of VRAM, by offloading experts to RAM. OpenAI API on :8080/v1.

  The model weighs 15.78 GB. With --fit-target, llama.cpp keeps as many experts
  on the GPU as fit (leaving ~1 GB of margin) and sends the rest to the 64 GB of RAM.
  Measured: ~76 tok/s  (vs ~34 if ALL experts go to RAM with --cpu-moe).

  Flags:
    -ngl 99            all layers to the GPU (experts are relocated by fit/cpu-moe)
    -fa 1              Flash Attention
    --fit-target 1024  auto-fit: fills VRAM leaving ~1 GB of margin (the fastest)
    -c 8192 / --jinja  context size and the model's chat template

  Conservative alternative (ALL experts in RAM -> ~5 GB VRAM, ~34 tok/s):
    replace  --fit-target 1024  with  --cpu-moe
  Tip: Gemma 4 is a "thinking" model; raise max_tokens or it keeps reasoning without answering.
#>
$ErrorActionPreference = 'Stop'
$llama = Join-Path $PSScriptRoot '..\..\tools\llamacpp\llama-server.exe'
$model = Join-Path $PSScriptRoot '..\..\models\gguf\gemma-4-26B-A4B-it-UD-Q4_K_M.gguf'

if (-not (Test-Path $model)) { Write-Host "The Gemma 4 GGUF is missing in models\gguf (see docs/moe-offload.md)." -ForegroundColor Red; exit 1 }

Write-Host "Gemma 4 26B-A4B (MoE offload) -> http://localhost:8080   (Ctrl+C to stop)" -ForegroundColor Green
& $llama -m $model -ngl 99 -fa 1 --fit-target 1024 -c 8192 --jinja --host 127.0.0.1 --port 8080
