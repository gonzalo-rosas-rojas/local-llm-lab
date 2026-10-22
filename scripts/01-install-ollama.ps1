#Requires -Version 5.1
<#
  01-install-ollama.ps1
  ------------------------------------------------------------------
  Installs Ollama on Windows (idempotent) and checks that the server answers.

  Ollama is the inference engine (it uses llama.cpp underneath) and exposes:
    - native API : http://localhost:11434/api/...
    - OpenAI API : http://localhost:11434/v1   <- the one used from code
  After installing, Ollama runs as a background app/service.
#>

Write-Host "==> Checking whether Ollama is already installed..." -ForegroundColor Cyan
$ollama = Get-Command ollama -ErrorAction Ignore
if ($ollama) {
    Write-Host "    Already installed: $($ollama.Source)" -ForegroundColor Green
} else {
    Write-Host "==> Installing Ollama with winget..." -ForegroundColor Cyan
    winget install --id Ollama.Ollama -e --accept-package-agreements --accept-source-agreements
    # Refresh PATH in this session so 'ollama' is found without reopening the terminal
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path','User')
}

Write-Host "==> Ollama version:" -ForegroundColor Cyan
ollama --version

Write-Host "==> Testing the server on localhost:11434..." -ForegroundColor Cyan
try {
    $r = Invoke-WebRequest -Uri 'http://localhost:11434/api/version' -UseBasicParsing -TimeoutSec 5
    Write-Host "    Server OK: $($r.Content)" -ForegroundColor Green
} catch {
    Write-Host "    The server did not answer yet." -ForegroundColor Yellow
    Write-Host "    Open the Ollama app (tray icon) or run 'ollama serve' and try again." -ForegroundColor Yellow
}
