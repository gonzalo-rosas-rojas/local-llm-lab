#Requires -Version 5.1
<#
  stop-lab.ps1
  ------------------------------------------------------------------
  Turns the lab off to free resources (VRAM/RAM) when you are done.
    - Stops the Open WebUI container (if running).
    - Stops Ollama (server + tray app) -> frees the model's VRAM.
    - Stops llama-server (if running).
  Does NOT close Docker Desktop: to get that RAM back, close it from its icon.

  Only processes whose executable is inside a folder the lab itself uses are stopped:
    %LOCALAPPDATA%\Programs\Ollama   (where winget installs Ollama; see start-lab.ps1)
    tools\llamacpp                   (where the llama.cpp binaries go; see docs/llama-cpp.md)
  A process with one of those names that runs from anywhere else (or whose path cannot
  be read) is left alone, and you are asked whether to stop it.

  Usage:  .\scripts\stop-lab.ps1
          .\scripts\stop-lab.ps1 -WhatIf     # show what would be stopped
          .\scripts\stop-lab.ps1 -Confirm    # ask before each step
#>
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$ollamaRoot = Join-Path $env:LOCALAPPDATA 'Programs\Ollama'
$llamaRoot = Join-Path $PSScriptRoot '..\tools\llamacpp'

function Stop-LabProcess {
    [CmdletBinding(SupportsShouldProcess)]
    # -Force stops a process outside the lab folders without asking; this script never passes it.
    param([string[]]$Name, [string]$Root, [string]$Label, [switch]$Force)
    $found = Get-LabProcess -Name $Name -Root @($Root)
    if (-not $found.Match -and -not $found.Other) {
        Write-Host "    $Label was not running." -ForegroundColor Yellow
        return
    }
    foreach ($p in $found.Match) {
        if ($PSCmdlet.ShouldProcess("$($p.Name) (pid $($p.Id))", 'Stop process')) {
            Stop-Process -Id $p.Id
            Write-Host "    Stopped $($p.Name) (pid $($p.Id))." -ForegroundColor Green
        }
    }
    foreach ($o in $found.Other) {
        $where = $o.Path
        if (-not $where) { $where = 'path unreadable' }
        Write-Host "    Not stopped: $($o.Process.Name) (pid $($o.Process.Id)) runs from outside the lab folders ($where)." -ForegroundColor Yellow
        $ask = "Stop $($o.Process.Name) (pid $($o.Process.Id)) anyway?"
        $yes = $Force.IsPresent
        if (-not $yes) { try { $yes = $PSCmdlet.ShouldContinue($ask, 'Process outside the lab folders') } catch { $yes = $false } }
        if ($yes) { Stop-Process -Id $o.Process.Id; Write-Host "    Stopped pid $($o.Process.Id)." -ForegroundColor Green }
    }
}

Write-Host "==> Stopping Open WebUI..." -ForegroundColor Cyan
if ($PSCmdlet.ShouldProcess('open-webui', 'docker stop')) {
    $r = Invoke-External -Exe 'docker' -Arguments @('stop', 'open-webui') -Capture
    if ($r.ExitCode -eq 0) { Write-Host "    Container stopped." -ForegroundColor Green }
    else { Write-Host "    It was not running (or Docker is off)." -ForegroundColor Yellow }
}

Write-Host "==> Stopping Ollama..." -ForegroundColor Cyan
Stop-LabProcess -Name @('ollama', 'ollama app') -Root $ollamaRoot -Label 'Ollama'

Write-Host "==> Stopping llama-server (if running)..." -ForegroundColor Cyan
Stop-LabProcess -Name @('llama-server') -Root $llamaRoot -Label 'llama-server'
