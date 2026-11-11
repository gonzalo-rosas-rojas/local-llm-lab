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
  Gemma 4 26B-A4B is DEFERRED to stage 3 (MoE offload to RAM): Ollama's tag
  gemma4:26b-a4b-it-q4_K_M weighs about 18 GB, more than the 16 GB of VRAM. Stage 3
  uses a different file, the unsloth UD-Q4_K_M GGUF of 15.78 GB (docs/moe-offload.md),
  which is why the two sizes differ.

  A model counts as already downloaded only when its full name matches the NAME
  column of `ollama list` (qwen3:8b does not match qwen3:8b-q8). Exit code 1 when
  Ollama cannot be reached or any pull fails.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Install-OllamaModel {
    param([string]$Tag, [string]$Note, [string[]]$ListLines)
    Write-Host "`n==> $Tag  ($Note)" -ForegroundColor Cyan
    if (Test-ModelListed -ListLines $ListLines -Tag $Tag) {
        Write-Host "    Already downloaded." -ForegroundColor Green
        return $true
    }
    $r = Invoke-External -Exe 'ollama' -Arguments @('pull', $Tag)
    if ($r.ExitCode -eq 0) { Write-Host "    OK." -ForegroundColor Green; return $true }
    Write-Host "    Pull of $Tag failed (exit code $($r.ExitCode))." -ForegroundColor Red
    return $false
}

# Dot-sourcing this file (to test Install-OllamaModel) must not start downloads.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $list = Invoke-External -Exe 'ollama' -Arguments @('list') -Capture
        if ($list.ExitCode -eq 127) { throw "ollama was not found. Run .\scripts\01-install-ollama.ps1 first." }
        if ($list.ExitCode -ne 0) { throw "'ollama list' failed (exit code $($list.ExitCode)). Is the server running? Try .\scripts\start-lab.ps1" }

        $failed = 0
        # Fast starter: validates the pipeline in minutes (~89 tok/s, 100% GPU)
        if (-not (Install-OllamaModel -Tag 'qwen3:8b' -Note 'starter ~5GB, fast iteration' -ListLines $list.Output)) { $failed++ }

        # Quality main model that FITS 100% on the GPU (~113 tok/s, 100% GPU)
        if (-not (Install-OllamaModel -Tag 'gpt-oss:20b' -Note 'main ~13GB, MoE with 3.6B active, fits entirely' -ListLines $list.Output)) { $failed++ }

        # --- DEFERRED to stage 3 (does not fit in 16GB; needs offload to RAM) ---
        # Uncomment to experiment with MoE offload (--cpu-moe in llama.cpp):
        # if (-not (Install-OllamaModel -Tag 'gemma4:26b-a4b-it-q4_K_M' -Note '~18GB > 16GB VRAM; offload to 64GB RAM' -ListLines $list.Output)) { $failed++ }

        Write-Host "`n==> Available models:" -ForegroundColor Cyan
        [void](Invoke-External -Exe 'ollama' -Arguments @('list'))
        if ($failed -gt 0) { throw "$failed model(s) could not be downloaded." }
    } catch {
        Write-Host "02-pull-models: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
