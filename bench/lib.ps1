#Requires -Version 5.1
<#
  lib.ps1
  ------------------------------------------------------------------
  Functions used by run-bench.ps1, kept apart so they can be loaded and tested
  without running a benchmark (see Test-RunBench.ps1). Nothing here starts a
  process on its own except Invoke-Native.

  What is tested and what is not:
    - Get-Median, Join-NativeArguments, Get-BenchArguments, Get-FlagValue and
      New-ResultRecord are tested with values written in the test itself.
    - ConvertFrom-BenchOutput is NOT tested. It reads llama-bench's JSON output
      (-o json) using the fields n_prompt, n_gen, avg_ts, build_number,
      build_commit and backends, as documented by llama.cpp, but this repository
      holds no real llama-bench output to test against, and inventing one would
      prove nothing. The first real run is the test: if a field is missing, the
      function stops with a message naming it.
#>

function Get-Median {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { throw 'Get-Median needs at least one value.' }
    $sorted = @($Values | Sort-Object)
    $n = $sorted.Count
    $mid = [int][math]::Floor($n / 2)
    if ($n % 2 -eq 1) { return [double]$sorted[$mid] }
    return ([double]$sorted[$mid - 1] + [double]$sorted[$mid]) / 2
}

function Get-FlagValue {
    # Value that follows a flag in a flag list, or $null when the flag is absent.
    param([string[]]$Flags, [Parameter(Mandatory)][string]$Name)
    if (-not $Flags) { return $null }
    for ($i = 0; $i -lt $Flags.Count - 1; $i++) {
        if ($Flags[$i] -eq $Name) { return $Flags[$i + 1] }
    }
    return $null
}

function Test-BenchFlags {
    # Flags the runner sets itself cannot be passed again.
    param([string[]]$Flags)
    $reserved = '-m', '--model', '-p', '--n-prompt', '-n', '--n-gen', '-r', '--repetitions', '-o', '--output', '-oe', '--output-err'
    foreach ($f in @($Flags)) {
        if ($reserved -contains $f) {
            throw "The flag '$f' is set by run-bench.ps1 itself; remove it from -Flags."
        }
    }
}

function Get-BenchArguments {
    # Arguments for ONE llama-bench invocation: a single repetition of the prompt
    # and generation tests, JSON on stdout. The script calls it -Runs times.
    param(
        [Parameter(Mandatory)][string]$ModelPath,
        [string[]]$Flags = @(),
        [int]$Prompt = 512,
        [int]$Generate = 128
    )
    Test-BenchFlags -Flags $Flags
    return @('-m', $ModelPath, '-p', "$Prompt", '-n', "$Generate", '-r', '1', '-o', 'json') + @($Flags)
}

function Join-NativeArguments {
    # Quotes an argument list into the single string that .NET (Windows PowerShell
    # 5.1 has no ArgumentList) hands to CreateProcess. Also used for the command
    # line written to the result record.
    param([string[]]$Arguments)
    $parts = foreach ($a in @($Arguments)) {
        if ($a -eq '' -or $a -match '[\s"]') {
            '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
        } else {
            $a
        }
    }
    return ($parts -join ' ')
}

function Invoke-Native {
    # Runs a program and returns ExitCode, StdOut and StdErr. Reads both streams so a
    # chatty program cannot block, and avoids PowerShell 5.1 turning stderr lines
    # into errors.
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @())
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = Join-NativeArguments -Arguments $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $out = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = $out; StdErr = $errTask.Result }
}

function ConvertFrom-BenchOutput {
    # llama-bench JSON (-o json) -> one object per prompt-only or generation-only test.
    # NOT covered by tests: see the header of this file.
    param([Parameter(Mandatory)][string]$JsonText)
    try { $rows = @($JsonText | ConvertFrom-Json) }
    catch { throw "llama-bench did not print valid JSON: $($_.Exception.Message)" }
    if ($rows.Count -eq 0) { throw 'llama-bench printed no results.' }
    $found = @()
    foreach ($row in $rows) {
        foreach ($field in 'n_prompt', 'n_gen', 'avg_ts') {
            if ($null -eq $row.PSObject.Properties[$field]) {
                throw "llama-bench output has no '$field' field; this runner expects the JSON that llama.cpp documents for -o json."
            }
        }
        $backends = $null
        if ($null -ne $row.PSObject.Properties['backends']) { $backends = [string]$row.backends }
        $buildNumber = $null
        if ($null -ne $row.PSObject.Properties['build_number']) { $buildNumber = [string]$row.build_number }
        $buildCommit = $null
        if ($null -ne $row.PSObject.Properties['build_commit']) { $buildCommit = [string]$row.build_commit }
        if ([int]$row.n_prompt -gt 0 -and [int]$row.n_gen -eq 0) {
            $name = 'prompt_processing_speed'; $label = "pp$([int]$row.n_prompt)"
        } elseif ([int]$row.n_gen -gt 0 -and [int]$row.n_prompt -eq 0) {
            $name = 'generation_speed'; $label = "tg$([int]$row.n_gen)"
        } else {
            continue
        }
        $found += [pscustomobject]@{
            Name = $name; Label = $label; Value = [double]$row.avg_ts
            BuildNumber = $buildNumber; BuildCommit = $buildCommit; Backends = $backends
        }
    }
    if ($found.Count -eq 0) { throw 'llama-bench output holds no prompt-only or generation-only test.' }
    return $found
}

function New-ResultRecord {
    # Builds a record in the results/schema.json layout. Every key is present; what
    # the caller could not learn is $null. `Series` is a list of objects with Name,
    # Label and Samples (one value per run, in run order).
    param(
        [Parameter(Mandatory)][string]$ModelFile,
        [double]$ModelSizeGiB = -1,
        [string]$Build,
        [string]$Backend,
        [string[]]$Flags = @(),
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][object[]]$Series,
        [Parameter(Mandatory)][int]$Runs,
        [Parameter(Mandatory)][string]$TimestampUtc,
        [string]$Gpu, [object]$VramGb, [object]$RamGb, [string]$Cpu,
        [string]$Os, [string]$Driver,
        [string[]]$ExtraNotes = @()
    )
    $nullIfEmpty = { param($v) if ([string]::IsNullOrEmpty($v)) { $null } else { $v } }
    $ngl = Get-FlagValue -Flags $Flags -Name '-ngl'
    $fa = Get-FlagValue -Flags $Flags -Name '-fa'
    $ctk = Get-FlagValue -Flags $Flags -Name '-ctk'
    $metrics = @()
    foreach ($s in $Series) {
        $samples = @($s.Samples | ForEach-Object { [double]$_ })
        $metrics += [ordered]@{
            name = $s.Name; label = $s.Label; unit = 'tok/s'
            value = (Get-Median -Values $samples); approximate = $false
            statistic = 'median'; samples = $samples
        }
    }
    $notes = @(
        "Median of $Runs separate llama-bench invocations, each with -r 1; 'samples' holds one value per invocation, in order.",
        'Model parameters, quantization and context were not read from the model; they are null unless the flags state them.'
    ) + @($ExtraNotes)
    $sizeValue = $null
    if ($ModelSizeGiB -ge 0) { $sizeValue = [math]::Round($ModelSizeGiB, 2) }
    $fa1 = $null
    if ($fa) { $fa1 = ($fa -ne '0') }
    $nglValue = $null
    if ($ngl) { $nglValue = [int]$ngl }
    return [ordered]@{
        schema_version = 1
        id = 'bench-' + ($TimestampUtc -replace '[^0-9TZ]', '').ToLower() + '-' + (($ModelFile -replace '\.gguf$', '') -replace '[^A-Za-z0-9]+', '-').ToLower().Trim('-')
        stage = $null
        order = $null
        role = $null
        chart = $null
        model = [ordered]@{
            name = $ModelFile; quantization = $null; file = $ModelFile
            size_gb = $sizeValue; parameters_b = $null; active_parameters_b = $null
        }
        engine = [ordered]@{
            name = 'llama.cpp (llama-bench)'; version = $null
            build = (& $nullIfEmpty $Build); backend = (& $nullIfEmpty $Backend)
        }
        parameters = [ordered]@{
            gpu_layers = $nglValue; gpu_offload = $null; context = $null
            kv_cache_type = (& $nullIfEmpty $ctk); flash_attention = $fa1
            flags = @($Flags)
        }
        metrics = @($metrics)
        hardware = [ordered]@{
            gpu = (& $nullIfEmpty $Gpu); vram_gb = $VramGb; ram_gb = $RamGb; cpu = (& $nullIfEmpty $Cpu)
        }
        system = [ordered]@{ os = (& $nullIfEmpty $Os); gpu_driver = (& $nullIfEmpty $Driver) }
        measured_on = [ordered]@{ date = $TimestampUtc; date_kind = 'measurement'; commit = $null }
        command = $Command
        runs = $Runs
        source = [ordered]@{ file = 'bench/run-bench.ps1'; section = 'generated by the script'; also_in = @() }
        notes = @($notes)
    }
}
