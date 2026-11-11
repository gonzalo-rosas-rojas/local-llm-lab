#Requires -Version 5.1
<#
  01-install-ollama.ps1
  ------------------------------------------------------------------
  Installs Ollama on Windows (idempotent) and checks that the server answers.

  Ollama is the inference engine (it uses llama.cpp underneath) and exposes:
    - native API : http://localhost:11434/api/...
    - OpenAI API : http://localhost:11434/v1   <- the one used from code
  After installing, Ollama runs as a background app/service.

  Stops with a message and exit code 1 if winget is missing, winget fails, or Ollama is
  still not found after the install.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

try {
    Write-Host "==> Checking whether Ollama is already installed..." -ForegroundColor Cyan
    $ollama = Get-Command ollama -ErrorAction Ignore
    if ($ollama) {
        Write-Host "    Already installed: $($ollama.Source)" -ForegroundColor Green
    } else {
        Write-Host "==> Installing Ollama with winget..." -ForegroundColor Cyan
        $r = Invoke-External -Exe 'winget' -Arguments @('install', '--id', 'Ollama.Ollama', '-e', '--accept-package-agreements', '--accept-source-agreements')
        if ($r.ExitCode -eq 127) { throw "winget was not found. Install Ollama from https://ollama.com/download and run this script again." }
        if ($r.ExitCode -ne 0) { throw "winget failed to install Ollama (exit code $($r.ExitCode))." }
        # Refresh PATH in this session so 'ollama' is found without reopening the terminal
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                    [System.Environment]::GetEnvironmentVariable('Path','User')
        if (-not (Get-Command ollama -ErrorAction Ignore)) {
            throw "winget reported success but 'ollama' is not on the PATH yet. Open a new terminal and run this script again."
        }
    }

    Write-Host "==> Ollama version:" -ForegroundColor Cyan
    $v = Invoke-External -Exe 'ollama' -Arguments @('--version')
    if ($v.ExitCode -ne 0) { throw "'ollama --version' failed (exit code $($v.ExitCode))." }

    Write-Host "==> Testing the server on localhost:11434..." -ForegroundColor Cyan
    try {
        $r = Invoke-WebRequest -Uri 'http://localhost:11434/api/version' -UseBasicParsing -TimeoutSec 5
        Write-Host "    Server OK: $($r.Content)" -ForegroundColor Green
    } catch {
        Write-Host "    The server did not answer yet." -ForegroundColor Yellow
        Write-Host "    Open the Ollama app (tray icon) or run 'ollama serve' and try again." -ForegroundColor Yellow
    }
} catch {
    Write-Host "01-install-ollama: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
