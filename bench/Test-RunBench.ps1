#Requires -Version 5.1
<#
  Test-RunBench.ps1
  ------------------------------------------------------------------
  Checks the pure functions of bench/lib.ps1 without running llama-bench.
  Exit code 0 when every check passes, 1 otherwise.

  With -EmitSample <path> it also writes a record built by Get-ResultRecord from
  values written in this file (not from llama-bench output), so that
  tests/test_bench_record.py can validate the layout against results/schema.json.

  ConvertFrom-BenchOutput is deliberately not tested here: see bench/lib.ps1.
#>
param([string]$EmitSample)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$script:failures = 0
function Confirm-Equal {
    param($Actual, $Expected, [string]$Name)
    $a = ConvertTo-Json -InputObject $Actual -Compress -Depth 6
    $e = ConvertTo-Json -InputObject $Expected -Compress -Depth 6
    if ($a -ne $e) {
        $script:failures++
        Write-Host "FAIL $Name`n  expected: $e`n  actual:   $a" -ForegroundColor Red
    } else {
        Write-Host "ok   $Name" -ForegroundColor Green
    }
}
function Confirm-Throws {
    param([scriptblock]$Block, [string]$Pattern, [string]$Name)
    try { & $Block; $script:failures++; Write-Host "FAIL $Name (no error)" -ForegroundColor Red }
    catch {
        if ($_.Exception.Message -match $Pattern) { Write-Host "ok   $Name" -ForegroundColor Green }
        else { $script:failures++; Write-Host "FAIL $Name (message: $($_.Exception.Message))" -ForegroundColor Red }
    }
}

# Median
Confirm-Equal (Get-Median -Values @(3.0)) 3.0 'median of one value'
Confirm-Equal (Get-Median -Values @(9.0, 1.0, 5.0)) 5.0 'median of three, unsorted'
Confirm-Equal (Get-Median -Values @(4.0, 2.0, 8.0, 6.0)) 5.0 'median of four is the mean of the middle two'
Confirm-Throws { Get-Median -Values @() } 'at least one' 'median of nothing'

# Flags
Confirm-Equal (Get-FlagValue -Flags @('-ngl', '99', '-fa', '1') -Name '-ngl') '99' 'flag value found'
Confirm-Equal (Get-FlagValue -Flags @('-ngl', '99') -Name '-fa') $null 'flag value absent'
Confirm-Equal (Get-FlagValue -Flags @('-fa') -Name '-fa') $null 'flag at the end has no value'

# Command construction
Confirm-Equal (Get-BenchArgumentList -ModelPath 'm.gguf') @('-m', 'm.gguf', '-p', '512', '-n', '128', '-r', '1', '-o', 'json') 'default arguments'
Confirm-Equal (Get-BenchArgumentList -ModelPath 'm.gguf' -Flags @('-ngl', '99', '-fa', '1') -Prompt 256 -Generate 64) `
    @('-m', 'm.gguf', '-p', '256', '-n', '64', '-r', '1', '-o', 'json', '-ngl', '99', '-fa', '1') 'arguments with flags'
Confirm-Throws { Get-BenchArgumentList -ModelPath 'm.gguf' -Flags @('-r', '5') } "set by run-bench" 'reserved flag -r is refused'
Confirm-Throws { Get-BenchArgumentList -ModelPath 'm.gguf' -Flags @('-o', 'csv') } "set by run-bench" 'reserved flag -o is refused'

# Argument quoting
Confirm-Equal (Join-NativeArgument -Arguments @('-m', 'a b.gguf', '-ngl', '99')) '-m "a b.gguf" -ngl 99' 'quotes an argument with a space'
Confirm-Equal (Join-NativeArgument -Arguments @('x')) 'x' 'leaves a plain argument alone'
Confirm-Equal (Join-NativeArgument -Arguments @('C:\my dir\')) '"C:\my dir\\"' 'doubles a trailing backslash inside quotes'

# Record layout
$series = @(
    [pscustomobject]@{ Name = 'prompt_processing_speed'; Label = 'pp512'; Samples = @(100.0, 300.0, 200.0) },
    [pscustomobject]@{ Name = 'generation_speed'; Label = 'tg128'; Samples = @(10.0, 12.0, 11.0) }
)
$record = Get-ResultRecord -ModelFile 'Test-Model-Q4_K_M.gguf' -ModelSizeGiB 1.234 -Build 'b1' -Backend 'CUDA' `
    -Flags @('-ngl', '99', '-fa', '1') -Command 'llama-bench -m x' -Series $series -Runs 3 `
    -TimestampUtc '2000-01-02T03:04:05Z' -Gpu 'Test GPU' -VramGb 8 -RamGb 16 -Cpu 'Test CPU' `
    -Os 'Test OS' -Driver '1.2.3'
Confirm-Equal $record.metrics[0].value 200.0 'pp median in the record'
Confirm-Equal $record.metrics[1].value 11.0 'tg median in the record'
Confirm-Equal $record.metrics[1].samples @(10.0, 12.0, 11.0) 'samples are kept in run order'
Confirm-Equal $record.parameters.gpu_layers 99 'gpu_layers read from -ngl'
Confirm-Equal $record.parameters.flash_attention $true 'flash_attention read from -fa'
Confirm-Equal $record.measured_on.date_kind 'measurement' 'date kind'
Confirm-Equal $record.model.size_gb 1.23 'size rounded to two decimals'
Confirm-Equal $record.id 'bench-20000102t030405z-test-model-q4-k-m' 'record id'
$bare = Get-ResultRecord -ModelFile 'x.gguf' -Command 'c' -Series $series -Runs 1 -TimestampUtc '2000-01-02T03:04:05Z'
Confirm-Equal $bare.hardware.gpu $null 'unknown GPU is null'
Confirm-Equal $bare.system.gpu_driver $null 'unknown driver is null'
Confirm-Equal $bare.model.size_gb $null 'unknown size is null'
Confirm-Equal $bare.parameters.gpu_layers $null 'absent -ngl is null'

if ($EmitSample) {
    (($record | ConvertTo-Json -Depth 8) + "`n") | Set-Content -LiteralPath $EmitSample -Encoding UTF8
}
if ($script:failures -gt 0) {
    Write-Host "$($script:failures) check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed.' -ForegroundColor Green
