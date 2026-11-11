#Requires -Version 5.1
<#
  check-loopback.ps1
  ------------------------------------------------------------------
  Checks that everything the lab starts listens on this machine only.

  It reads the ports out of the lab's own scripts (localhost:<port>, 127.0.0.1:<port>
  and --port <n>: today Ollama 11434, Open WebUI 3000 and llama-server 8080), asks
  Windows which of them have a listener, and fails if any listens on an address that
  is not loopback (127.0.0.0/8 or ::1). A listener on 0.0.0.0 or :: is reachable from
  the network and is reported with the name of the process that owns it.

  Read-only: it only calls Get-NetTCPConnection and Get-Process. A port with no
  listener is fine (the lab is off).

  Usage:  .\scripts\check-loopback.ps1
          .\scripts\check-loopback.ps1 -Port 11434,8080   # check only these ports
  Exit code: 0 when every listener is on loopback, 1 when one is exposed, 2 when
  the check itself could not run.
#>
param(
    [int[]]$Port
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

try {
    if (-not $Port) {
        $scripts = @(Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' -Recurse | Where-Object { $_.Name -ne 'check-loopback.ps1' } | ForEach-Object { $_.FullName })
        $Port = Get-LabPort -ScriptPath $scripts
    }
    if (-not $Port) { throw 'No lab ports found in the scripts; pass -Port.' }
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction Ignore)) {
        throw 'Get-NetTCPConnection is not available (this check needs Windows).'
    }

    Write-Host "==> Lab ports: $($Port -join ', ')" -ForegroundColor Cyan
    $exposed = 0
    foreach ($p in $Port) {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction Ignore)
        if ($listeners.Count -eq 0) {
            Write-Host "    ${p}: no listener" -ForegroundColor Green
            continue
        }
        foreach ($l in $listeners) {
            $owner = Get-Process -Id $l.OwningProcess -ErrorAction Ignore
            $who = 'unknown process'
            if ($owner) { $who = "$($owner.ProcessName) (pid $($l.OwningProcess))" }
            if (Test-LoopbackAddress -Address $l.LocalAddress) {
                Write-Host "    ${p}: $($l.LocalAddress)  $who  loopback only" -ForegroundColor Green
            } else {
                $exposed++
                Write-Host "    ${p}: $($l.LocalAddress)  $who  EXPOSED beyond this machine" -ForegroundColor Red
            }
        }
    }
    if ($exposed -gt 0) {
        Write-Host "==> FAIL: $exposed listener(s) reachable from the network." -ForegroundColor Red
        exit 1
    }
    Write-Host "==> OK: nothing the lab uses listens beyond loopback." -ForegroundColor Green
    exit 0
} catch {
    Write-Host "check-loopback: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}
