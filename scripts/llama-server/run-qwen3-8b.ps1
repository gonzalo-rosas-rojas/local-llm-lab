#Requires -Version 5.1
<#
  run-qwen3-8b.ps1
  ------------------------------------------------------------------
  Starts llama-server (llama.cpp) serving Qwen3 8B on the GPU.
    - Web UI:  http://localhost:8080
    - OpenAI-compatible API: http://localhost:8080/v1
  Runs in the foreground: Ctrl+C stops it.

  The "knobs" that Ollama hides:
    -ngl 99            n-gpu-layers: ALL layers on the GPU
    -fa 1              Flash Attention: less attention VRAM + faster
    -c 8192            context size (= size of the KV cache)
    -ctk/-ctv q8_0     quantizes the KV cache to 8 bits (needs -fa) -> ~6.3 GB total
    --jinja            uses the model's chat template (handles Qwen3's "thinking";
                       tip: add " /no_think" to the prompt to answer directly)
#>
$ErrorActionPreference = 'Stop'
$llama = Join-Path $PSScriptRoot '..\..\tools\llamacpp\llama-server.exe'
$model = Join-Path $PSScriptRoot '..\..\models\gguf\Qwen3-8B-Q4_K_M.gguf'

if (-not (Test-Path $llama)) { Write-Host "llama-server is missing in tools\llamacpp (see docs/llama-cpp.md)." -ForegroundColor Red; exit 1 }
if (-not (Test-Path $model)) { Write-Host "The GGUF is missing in models\gguf." -ForegroundColor Red; exit 1 }

Write-Host "llama-server -> http://localhost:8080   (Ctrl+C to stop)" -ForegroundColor Green
& $llama -m $model -ngl 99 -fa 1 -c 8192 -ctk q8_0 -ctv q8_0 --jinja --host 127.0.0.1 --port 8080
