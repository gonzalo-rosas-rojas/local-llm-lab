#Requires -Version 5.1
<#
  start-lab.ps1
  ------------------------------------------------------------------
  Turns the lab on when you are about to work.
    - Starts the Ollama server (it no longer starts with Windows).
    - If Docker Desktop is running, starts Open WebUI and opens the UI.
  Usage:  .\scripts\start-lab.ps1
          (if the policy blocks it: powershell -ExecutionPolicy Bypass -File .\scripts\start-lab.ps1)
#>

$ollamaApp = "$env:LOCALAPPDATA\Programs\Ollama\ollama app.exe"
$ollamaExe = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"

function Test-Ollama {
    try { Invoke-WebRequest 'http://localhost:11434/api/version' -UseBasicParsing -TimeoutSec 2 | Out-Null; return $true }
    catch { return $false }
}

Write-Host "==> Ollama..." -ForegroundColor Cyan
if (Test-Ollama) {
    Write-Host "    Already running." -ForegroundColor Green
} else {
    if (Test-Path $ollamaApp) { Start-Process $ollamaApp }
    elseif (Test-Path $ollamaExe) { Start-Process $ollamaExe -ArgumentList 'serve' -WindowStyle Hidden }
    else { Write-Host "    Ollama is not installed." -ForegroundColor Red }
    for ($i = 0; $i -lt 20 -and -not (Test-Ollama); $i++) { Start-Sleep -Seconds 1 }
    if (Test-Ollama) { Write-Host "    Started." -ForegroundColor Green } else { Write-Host "    Not answering yet (check the tray)." -ForegroundColor Yellow }
}

Write-Host "==> Open WebUI (only if Docker is running)..." -ForegroundColor Cyan
docker info 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    docker start open-webui 2>$null | Out-Null
    Write-Host "    Open WebUI -> http://localhost:3000" -ForegroundColor Green
    Start-Process 'http://localhost:3000'
} else {
    Write-Host "    Docker is not running. Open Docker Desktop and Open WebUI will start by itself." -ForegroundColor Yellow
}
