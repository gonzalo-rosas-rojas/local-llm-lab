#Requires -Version 5.1
<#
  02-pull-models.ps1
  ------------------------------------------------------------------
  Downloads the lab's models into Ollama (stage 1).

  - By default Ollama pulls Q4_K_M (a good quality/size balance,
    ~90-95% of FP16 quality at ~30% of the size).
  - The store ends up in  C:\Users\<user>\.ollama\models

  Decision (2026-06-02): the MAIN model is gpt-oss:20b because it fits 100%
  in the 16 GB of VRAM (~14 GB, MoE with ~3.6B active parameters -> fast,
  ~113 tok/s measured).
  Gemma 4 26B-A4B at Q4_K_M weighs 18 GB > 16 GB of VRAM, so it is DEFERRED to
  stage 3 (MoE offload to RAM). Correct tag: gemma4:26b-a4b-it-q4_K_M
#>

function Pull-Model {
    param([string]$Tag, [string]$Note)
    Write-Host "`n==> $Tag  ($Note)" -ForegroundColor Cyan
    if ((ollama list) -match [regex]::Escape($Tag)) {
        Write-Host "    Already downloaded." -ForegroundColor Green
        return
    }
    ollama pull $Tag
    if ($LASTEXITCODE -eq 0) { Write-Host "    OK." -ForegroundColor Green }
    else { Write-Host "    Pull of $Tag failed." -ForegroundColor Red }
}

# Fast starter: validates the pipeline in minutes (~89 tok/s, 100% GPU)
Pull-Model -Tag 'qwen3:8b'    -Note 'starter ~5GB, fast iteration'

# Quality main model that FITS 100% on the GPU (~113 tok/s, 100% GPU)
Pull-Model -Tag 'gpt-oss:20b' -Note 'main ~13GB, MoE with 3.6B active, fits entirely'

# --- DEFERRED to stage 3 (does not fit in 16GB; needs offload to RAM) ---
# Uncomment to experiment with MoE offload (--cpu-moe in llama.cpp):
# Pull-Model -Tag 'gemma4:26b-a4b-it-q4_K_M' -Note '18GB > 16GB VRAM; offload to 64GB RAM'

Write-Host "`n==> Available models:" -ForegroundColor Cyan
ollama list
