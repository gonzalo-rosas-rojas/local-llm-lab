#Requires -Version 5.1
<#
  Test-Scripts.ps1
  ------------------------------------------------------------------
  Checks the helpers in scripts/common.ps1 without starting Ollama, Docker or any model.
  Exit code 0 when every check passes, 1 otherwise. Windows only (it runs cmd.exe).
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

$script:failures = 0
function Confirm-Equal {
    param($Actual, $Expected, [string]$Name)
    $a = ConvertTo-Json -InputObject $Actual -Compress -Depth 4
    $e = ConvertTo-Json -InputObject $Expected -Compress -Depth 4
    if ($a -ne $e) {
        $script:failures++
        Write-Host "FAIL $Name`n  expected: $e`n  actual:   $a" -ForegroundColor Red
    } else {
        Write-Host "ok   $Name" -ForegroundColor Green
    }
}

# Exact model names: the original script matched substrings.
$list = @(
    'NAME                 ID              SIZE      MODIFIED',
    'qwen3:8b-q8          aaaaaaaaaaaa    8.7 GB    2 days ago',
    'gpt-oss:20b          bbbbbbbbbbbb    13 GB     3 days ago',
    'gpt-oss-cc:latest    cccccccccccc    13 GB     3 days ago'
)
Confirm-Equal (Test-ModelListed -ListLines $list -Tag 'qwen3:8b') $false 'qwen3:8b is not qwen3:8b-q8'
Confirm-Equal (Test-ModelListed -ListLines $list -Tag 'qwen3:8b-q8') $true 'exact name matches'
Confirm-Equal (Test-ModelListed -ListLines $list -Tag 'gpt-oss:20b') $true 'gpt-oss:20b is listed'
Confirm-Equal (Test-ModelListed -ListLines $list -Tag 'gpt-oss') $false 'gpt-oss means gpt-oss:latest, which is absent'
Confirm-Equal (Test-ModelListed -ListLines $list -Tag 'gpt-oss-cc') $true 'a tag without a colon means :latest'
Confirm-Equal (Test-ModelListed -ListLines $list -Tag 'GPT-OSS:20B') $true 'names compare without regard to case'
Confirm-Equal (Test-ModelListed -ListLines @() -Tag 'qwen3:8b') $false 'empty list'
Confirm-Equal (Test-ModelListed -ListLines @('NAME ID SIZE MODIFIED') -Tag 'NAME') $false 'the header is not a model'

# Paths: only the lab's own folders count.
Confirm-Equal (Test-PathUnder -Path 'C:\Lab\tools\llamacpp\llama-server.exe' -Root 'C:\Lab\tools\llamacpp') $true 'path inside the root'
Confirm-Equal (Test-PathUnder -Path 'C:\Lab\tools\llamacpp2\llama-server.exe' -Root 'C:\Lab\tools\llamacpp') $false 'a sibling with the same prefix is outside'
Confirm-Equal (Test-PathUnder -Path 'c:\lab\TOOLS\llamacpp\x.exe' -Root 'C:\Lab\tools\llamacpp\') $true 'case and trailing slash do not matter'
Confirm-Equal (Test-PathUnder -Path 'C:\Lab\tools\llamacpp\..\..\evil.exe' -Root 'C:\Lab\tools\llamacpp') $false 'parent segments are resolved'
Confirm-Equal (Test-PathUnder -Path $null -Root 'C:\Lab') $false 'an unreadable path is outside'

# Loopback: only 127.0.0.0/8 and ::1 are local; "every interface" addresses are not.
Confirm-Equal (Test-LoopbackAddress -Address '127.0.0.1') $true '127.0.0.1 is loopback'
Confirm-Equal (Test-LoopbackAddress -Address '127.5.4.3') $true 'all of 127/8 is loopback'
Confirm-Equal (Test-LoopbackAddress -Address '::1') $true '::1 is loopback'
Confirm-Equal (Test-LoopbackAddress -Address '::ffff:127.0.0.1') $true 'IPv4-mapped loopback'
Confirm-Equal (Test-LoopbackAddress -Address '0.0.0.0') $false '0.0.0.0 listens on every interface'
Confirm-Equal (Test-LoopbackAddress -Address '::') $false ':: listens on every interface'
Confirm-Equal (Test-LoopbackAddress -Address '192.168.1.20') $false 'a LAN address is not loopback'
Confirm-Equal (Test-LoopbackAddress -Address '::ffff:10.0.0.1') $false 'IPv4-mapped LAN address'
Confirm-Equal (Test-LoopbackAddress -Address 'not-an-address') $false 'garbage is not loopback'

# Ports are read from the scripts, not typed in again.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('lab-ports-' + [guid]::NewGuid().ToString('N') + '.ps1')
try {
    Set-Content -LiteralPath $tmp -Value @(
        '# http://localhost:11434/api and http://127.0.0.1:3000',
        '& $llama -m $m --host 127.0.0.1 --port 8080',
        '-p 127.0.0.1:3000:8080'
    )
    Confirm-Equal (Get-LabPort -ScriptPath $tmp) @(3000, 8080, 11434) 'ports found in a script, container-side port ignored'
} finally {
    Remove-Item -LiteralPath $tmp -ErrorAction Ignore
}
$real = @(Get-ChildItem -Path (Join-Path $PSScriptRoot '..\scripts') -Filter '*.ps1' -Recurse | Where-Object { $_.Name -ne 'check-loopback.ps1' } | ForEach-Object { $_.FullName })
Confirm-Equal (Get-LabPort -ScriptPath $real) @(3000, 8080, 11434) 'the lab scripts name exactly Ollama, Open WebUI and llama-server ports'

# External programs: exit codes come back, stderr does not throw, a missing program is 127.
$missing = Invoke-External -Exe 'definitely-not-installed-xyz'
Confirm-Equal $missing.ExitCode 127 'missing program gives 127'
$failing = Invoke-External -Exe 'cmd.exe' -Arguments @('/c', 'exit 3')
Confirm-Equal $failing.ExitCode 3 'exit code is returned'
$noisy = Invoke-External -Exe 'cmd.exe' -Arguments @('/c', 'echo to-stdout & echo to-stderr 1>&2 & exit 2') -Capture
Confirm-Equal $noisy.ExitCode 2 'stderr output under Stop does not throw, exit code kept'
Confirm-Equal @($noisy.Output | ForEach-Object { $_.ToString().Trim() }) @('to-stdout') 'only stdout is captured'

if ($script:failures -gt 0) {
    Write-Host "$($script:failures) check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed.' -ForegroundColor Green
