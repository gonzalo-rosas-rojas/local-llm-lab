#Requires -Version 5.1
<#
  run-bench.ps1
  ------------------------------------------------------------------
  Runs llama-bench several times for one model and one set of flags, and writes a
  JSON record in the layout of results/schema.json: the exact command, the build
  and the NVIDIA driver, the UTC time, every run and the median.

  It never overwrites a record: if the output file exists it stops before running
  anything.

  Usage:
    .\bench\run-bench.ps1 -Model .\models\gguf\Qwen3-8B-Q4_K_M.gguf -Flags '-ngl','99','-fa','1'
    .\bench\run-bench.ps1 -Model <gguf> -Runs 5 -Prompt 512 -Generate 128 -OutFile .\results\my-run.json

  Parameters:
    -Model      path to the GGUF file (required)
    -Flags      extra llama-bench flags, one array element per token, for example
                '-ngl','99','-fa','1'. The runner sets -m, -p, -n, -r and -o itself.
    -Runs       number of separate llama-bench invocations (default 3)
    -Prompt     prompt tokens for the prompt-processing test (default 512)
    -Generate   tokens for the generation test (default 128)
    -LlamaBench path to llama-bench (default tools\llamacpp\llama-bench.exe)
    -OutFile    where to write the record (default results\bench-<time>-<model>.json)

  Records written here have stage = null, so tools/render_results.py validates them
  but keeps them out of the README tables; see docs/benchmarking.md.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Model,
    [string[]]$Flags = @(),
    [ValidateRange(1, 100)][int]$Runs = 3,
    [ValidateRange(1, 1000000)][int]$Prompt = 512,
    [ValidateRange(1, 1000000)][int]$Generate = 128,
    [string]$LlamaBench,
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')
if (-not $LlamaBench) { $LlamaBench = Join-Path $PSScriptRoot '..\tools\llamacpp\llama-bench.exe' }

function Get-Hardware {
    $info = @{ Gpu = $null; VramGb = $null; Driver = $null; RamGb = $null; Cpu = $null; Os = $null; Notes = @() }
    $smi = Get-Command nvidia-smi -ErrorAction Ignore
    if ($smi) {
        $r = Invoke-Native -Exe $smi.Source -Arguments @('--query-gpu=name,driver_version,memory.total', '--format=csv,noheader,nounits')
        if ($r.ExitCode -eq 0 -and $r.StdOut.Trim()) {
            $f = ($r.StdOut.Trim() -split "`r?`n")[0] -split ',\s*'
            if ($f.Count -ge 3) {
                $info.Gpu = $f[0].Trim()
                $info.Driver = $f[1].Trim()
                $info.VramGb = [math]::Round([double]$f[2] / 1024, 1)
            }
        }
    }
    if (-not $info.Driver) { $info.Notes += 'nvidia-smi was not available or failed, so GPU, driver and VRAM are null.' }
    try {
        $info.RamGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
        $info.Cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
        $info.Os = (Get-CimInstance Win32_OperatingSystem).Caption.Trim()
    } catch {
        $info.Notes += 'CPU, RAM and operating system could not be read (Get-CimInstance failed).'
    }
    return $info
}

try {
    if (-not (Test-Path -LiteralPath $LlamaBench -PathType Leaf)) {
        throw "llama-bench was not found at '$LlamaBench'. Download the llama.cpp binaries to tools\llamacpp (see docs/llama-cpp.md) or pass -LlamaBench."
    }
    if (-not (Test-Path -LiteralPath $Model -PathType Leaf)) {
        throw "The model file '$Model' does not exist. Download the GGUF to models\gguf or pass the right -Model."
    }
    if ([System.IO.Path]::GetExtension($Model) -ne '.gguf') {
        throw "The model '$Model' is not a .gguf file."
    }
    $benchArgs = Get-BenchArguments -ModelPath (Resolve-Path -LiteralPath $Model).Path -Flags $Flags -Prompt $Prompt -Generate $Generate

    $stamp = [DateTime]::UtcNow
    $timestampUtc = $stamp.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    if (-not $OutFile) {
        $stem = ([System.IO.Path]::GetFileNameWithoutExtension($Model) -replace '[^A-Za-z0-9._-]+', '-')
        $OutFile = Join-Path $PSScriptRoot ('..\results\bench-' + $stamp.ToString('yyyyMMdd-HHmmss') + 'Z-' + $stem.ToLower() + '.json')
    }
    if (Test-Path -LiteralPath $OutFile) {
        throw "Refusing to overwrite '$OutFile'. Choose another -OutFile or remove the old record yourself."
    }
    $outDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutFile))
    if (-not (Test-Path -LiteralPath $outDir -PathType Container)) {
        throw "The output folder '$outDir' does not exist."
    }

    $command = Join-NativeArguments -Arguments (@($LlamaBench) + $benchArgs)
    Write-Host "==> $Runs run(s): $command" -ForegroundColor Cyan

    $samples = @{}      # label -> list of values, in run order
    $meta = @{}         # label -> Name
    $build = $null; $backend = $null
    for ($i = 1; $i -le $Runs; $i++) {
        Write-Host "    run $i of $Runs..." -ForegroundColor Cyan
        $r = Invoke-Native -Exe $LlamaBench -Arguments $benchArgs
        if ($r.ExitCode -ne 0) {
            $tail = (($r.StdErr -split "`r?`n") | Select-Object -Last 5) -join ' | '
            throw "llama-bench exited with code $($r.ExitCode) on run $i. Last stderr lines: $tail"
        }
        foreach ($t in (ConvertFrom-BenchOutput -JsonText $r.StdOut)) {
            if (-not $samples.ContainsKey($t.Label)) { $samples[$t.Label] = @(); $meta[$t.Label] = $t.Name }
            $samples[$t.Label] += $t.Value
            if (-not $build -and $t.BuildNumber) { $build = 'b' + $t.BuildNumber }
            if (-not $build -and $t.BuildCommit) { $build = $t.BuildCommit }
            if (-not $backend -and $t.Backends) { $backend = $t.Backends }
        }
    }

    $series = foreach ($label in ($samples.Keys | Sort-Object)) {
        [pscustomobject]@{ Name = $meta[$label]; Label = $label; Samples = $samples[$label] }
    }
    $hw = Get-Hardware
    $size = (Get-Item -LiteralPath $Model).Length / 1GB
    $record = New-ResultRecord -ModelFile ([System.IO.Path]::GetFileName($Model)) -ModelSizeGiB $size `
        -Build $build -Backend $backend -Flags $Flags -Command $command -Series @($series) -Runs $Runs `
        -TimestampUtc $timestampUtc -Gpu $hw.Gpu -VramGb $hw.VramGb -RamGb $hw.RamGb -Cpu $hw.Cpu `
        -Os $hw.Os -Driver $hw.Driver `
        -ExtraNotes (@('size_gb is the file size in GiB (bytes / 1024^3).') + $hw.Notes)

    $json = ($record | ConvertTo-Json -Depth 8) + "`n"
    $stream = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    try {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally {
        $stream.Dispose()
    }
    Write-Host "==> Wrote $OutFile" -ForegroundColor Green
    foreach ($m in $record.metrics) {
        Write-Host ("    {0}: median {1} tok/s over {2} run(s)" -f $m.label, $m.value, $Runs) -ForegroundColor Green
    }
} catch {
    Write-Host "run-bench: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
