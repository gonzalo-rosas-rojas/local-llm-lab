#Requires -Version 5.1
<#
  stop-lab.ps1
  ------------------------------------------------------------------
  Turns the lab off to free resources (VRAM/RAM) when you are done.
    - Stops the Open WebUI container (if running).
    - Stops Ollama (server + tray app) -> frees the model's VRAM.
  Does NOT close Docker Desktop: to get that RAM back, close it from its icon.
  Usage:  .\scripts\stop-lab.ps1
#>

Write-Host "==> Stopping Open WebUI..." -ForegroundColor Cyan
docker stop open-webui 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "    Container stopped." -ForegroundColor Green }
else { Write-Host "    It was not running (or Docker is off)." -ForegroundColor Yellow }

Write-Host "==> Stopping Ollama..." -ForegroundColor Cyan
$procs = Get-Process -Name 'ollama', 'ollama app' -ErrorAction Ignore
if ($procs) {
    $procs | Stop-Process -Force
    Write-Host "    Ollama stopped (VRAM freed)." -ForegroundColor Green
} else {
    Write-Host "    Ollama was not running." -ForegroundColor Yellow
}

Write-Host "==> Stopping llama-server (if running)..." -ForegroundColor Cyan
$ls = Get-Process -Name 'llama-server' -ErrorAction Ignore
if ($ls) { $ls | Stop-Process -Force; Write-Host "    llama-server stopped." -ForegroundColor Green }
else { Write-Host "    llama-server was not running." -ForegroundColor Yellow }
