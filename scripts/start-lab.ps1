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
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$ollamaApp = Join-Path (Get-OllamaRoot) 'ollama app.exe'
$ollamaExe = Join-Path (Get-OllamaRoot) 'ollama.exe'
$ollamaVersionUrl = 'http://localhost:11434/api/version'
$ollamaWaitSeconds = 20
$ollamaProbeTimeoutSec = 2
$webUiUrl = 'http://localhost:3000'
$webUiContainer = Get-OpenWebUiContainerName

function Test-Ollama {
    try { Invoke-WebRequest $ollamaVersionUrl -UseBasicParsing -TimeoutSec $ollamaProbeTimeoutSec | Out-Null; return $true }
    catch { return $false }
}

Write-Host "==> Ollama..." -ForegroundColor Cyan
if (Test-Ollama) {
    Write-Host "    Already running." -ForegroundColor Green
} else {
    if (Test-Path $ollamaApp) { Start-Process $ollamaApp }
    elseif (Test-Path $ollamaExe) { Start-Process $ollamaExe -ArgumentList 'serve' -WindowStyle Hidden }
    else { Write-Host "    Ollama is not installed." -ForegroundColor Red }
    for ($i = 0; $i -lt $ollamaWaitSeconds -and -not (Test-Ollama); $i++) { Start-Sleep -Seconds 1 }
    if (Test-Ollama) { Write-Host "    Started." -ForegroundColor Green } else { Write-Host "    Not answering yet (check the tray)." -ForegroundColor Yellow }
}

Write-Host "==> Open WebUI (only if Docker is running)..." -ForegroundColor Cyan
$docker = Invoke-External -Exe 'docker' -Arguments @('info') -Capture
if ($docker.ExitCode -eq 0) {
    $start = Invoke-External -Exe 'docker' -Arguments @('start', $webUiContainer) -Capture
    if ($start.ExitCode -eq 0) {
        Write-Host "    Open WebUI -> $webUiUrl" -ForegroundColor Green
        Start-Process $webUiUrl
    } else {
        Write-Host "    The '$webUiContainer' container could not be started (it may not exist yet: run .\scripts\03-start-openwebui.ps1)." -ForegroundColor Yellow
    }
} else {
    Write-Host "    Docker is not running. Open Docker Desktop, then run this script again to start Open WebUI." -ForegroundColor Yellow
}
