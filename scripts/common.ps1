#Requires -Version 5.1
<#
  common.ps1
  ------------------------------------------------------------------
  Small helpers shared by the lab scripts (dot-sourced, never run on its own).

  Why Invoke-External exists: in Windows PowerShell 5.1 a native program that writes
  to stderr (ollama pull prints its progress there, docker prints errors there)
  raises a terminating error under $ErrorActionPreference = 'Stop', even with
  2>$null. The scripts want Stop for their own mistakes but a plain exit code from
  other programs, so every external call goes through this function.
#>

function Invoke-External {
    <#
      Runs a program and returns an object with ExitCode and Output (stdout lines).
      -Capture keeps stdout (stderr is discarded); without it the program's output goes
      straight to the console. A program that is not installed gives ExitCode 127.
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @(),
        [switch]$Capture
    )
    if (-not (Get-Command $Exe -ErrorAction Ignore)) {
        return [pscustomobject]@{ ExitCode = 127; Output = @() }
    }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Capture) {
            $lines = @(& $Exe @Arguments 2>$null)
        } else {
            & $Exe @Arguments | Out-Host
            $lines = @()
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $lines }
}

function Test-ModelListed {
    <#
      True when the model Tag is in the output of `ollama list`. The comparison is on the
      whole NAME column, so qwen3:8b does not match qwen3:8b-q8. A tag without a colon
      means :latest, as in Ollama.
    #>
    param([string[]]$ListLines, [Parameter(Mandatory)][string]$Tag)
    $wanted = $Tag
    if ($wanted -notmatch ':') { $wanted = "${wanted}:latest" }
    foreach ($line in @($ListLines)) {
        $fields = ($line.Trim() -split '\s+')
        if ($fields.Count -eq 0 -or $fields[0] -eq 'NAME') { continue }
        if ($fields[0] -ieq $wanted) { return $true }
    }
    return $false
}

function Test-PathUnder {
    # True when Path is inside the folder Root (not merely a name that starts the same).
    param([string]$Path, [Parameter(Mandatory)][string]$Root)
    if (-not $Path) { return $false }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + $sep
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    return $pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-LabProcess {
    <#
      Processes with the given names, split into those whose executable lives under one of
      the lab's folders (Match) and the rest (Other, including processes whose path cannot
      be read).
    #>
    param([Parameter(Mandatory)][string[]]$Name, [Parameter(Mandatory)][string[]]$Root)
    $match = @()
    $other = @()
    foreach ($p in @(Get-Process -Name $Name -ErrorAction Ignore)) {
        $path = $null
        try { $path = $p.Path } catch { $path = $null }
        $inside = $false
        foreach ($r in $Root) {
            if (Test-PathUnder -Path $path -Root $r) { $inside = $true }
        }
        if ($inside) { $match += $p } else { $other += [pscustomobject]@{ Process = $p; Path = $path } }
    }
    return [pscustomobject]@{ Match = $match; Other = $other }
}

function Test-LoopbackAddress {
    # True for 127.0.0.0/8, ::1 and their IPv4-mapped IPv6 forms. Everything else, including
    # 0.0.0.0 and ::, which mean "every interface", is not loopback.
    param([Parameter(Mandatory)][string]$Address)
    $text = $Address.Trim()
    if ($text -match '^::ffff:(\d+\.\d+\.\d+\.\d+)$') { $text = $Matches[1] }
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($text, [ref]$ip)) { return $false }
    return [System.Net.IPAddress]::IsLoopback($ip)
}

function Get-LabPort {
    # Ports the lab's scripts mention: host:port after localhost or 127.0.0.1, and --port N.
    param([Parameter(Mandatory)][string[]]$ScriptPath)
    $ports = @()
    foreach ($path in $ScriptPath) {
        $text = Get-Content -LiteralPath $path -Raw
        foreach ($m in [regex]::Matches($text, '(?:localhost|127\.0\.0\.1):(\d{2,5})')) { $ports += [int]$m.Groups[1].Value }
        foreach ($m in [regex]::Matches($text, '--port\s+(\d{2,5})')) { $ports += [int]$m.Groups[1].Value }
    }
    return @($ports | Sort-Object -Unique)
}
