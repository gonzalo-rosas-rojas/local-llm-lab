#Requires -Version 5.1
<#
  claude-local.ps1
  ------------------------------------------------------------------
  Launches Claude Code against a LOCAL LLM (Ollama) instead of Anthropic's cloud.
  It works because Ollama 0.14+ speaks the native Anthropic API (/v1/messages).

  IMPORTANT: the variables are set only while Claude Code runs and the script
  restores the previous values when it exits, so the normal Claude Code setup
  (with Anthropic) stays untouched, even in the same PowerShell window.

  Usage:
    .\scripts\claude-local.ps1                      # interactive, gpt-oss (ctx 32k)
    .\scripts\claude-local.ps1 -Model qwen3:8b      # another Ollama model
    .\scripts\claude-local.ps1 -p "explain x.py"    # extra args are passed to claude

  Requirements: Ollama running (start-lab.ps1) and the model downloaded.
  Honest note: a local LLM (8-30B) is MUCH weaker than the real Claude at agentic
  tool use; expect less precise edits and less reliable loops.
#>
param(
    [string]$Model = 'gpt-oss-cc:latest',
    [Parameter(ValueFromRemainingArguments = $true)] $Rest
)
$ErrorActionPreference = 'Stop'

# A script run from a prompt shares the caller's process, so $env: changes would
# outlive it. Save what we touch and put it back in the finally block below.
$names = 'Path', 'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY',
         'ANTHROPIC_MODEL', 'ANTHROPIC_SMALL_FAST_MODEL', 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'
$saved = @{}
foreach ($n in $names) { $saved[$n] = [System.Environment]::GetEnvironmentVariable($n, 'Process') }

try {
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')

    # Ollama must be running
    try { Invoke-WebRequest 'http://localhost:11434/api/version' -UseBasicParsing -TimeoutSec 3 | Out-Null }
    catch { Write-Host "Ollama is not answering. Run first: .\scripts\start-lab.ps1" -ForegroundColor Red; exit 1 }

    # Claude Code needs a lot of context. If you asked for gpt-oss-cc and it does not
    # exist, create a gpt-oss variant with a large num_ctx (Ollama's default is small).
    if ($Model -eq 'gpt-oss-cc:latest' -and -not (ollama list | Select-String -SimpleMatch 'gpt-oss-cc')) {
        Write-Host "Creating gpt-oss-cc (num_ctx 32768) from gpt-oss:20b..." -ForegroundColor Cyan
        $mf = Join-Path $env:TEMP 'Modelfile.gpt-oss-cc'
        "FROM gpt-oss:20b`nPARAMETER num_ctx 32768" | Set-Content -Path $mf -Encoding ascii
        ollama create gpt-oss-cc -f $mf | Out-Null
    }

    # Variables for this launch only (restored when claude exits)
    $env:ANTHROPIC_BASE_URL = 'http://localhost:11434'
    $env:ANTHROPIC_AUTH_TOKEN = 'ollama'
    $env:ANTHROPIC_API_KEY = ''
    $env:ANTHROPIC_MODEL = $Model
    $env:ANTHROPIC_SMALL_FAST_MODEL = 'qwen3:8b'
    $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'

    Write-Host "Claude Code -> LOCAL Ollama ($Model). Your normal Claude Code is NOT affected." -ForegroundColor Green
    & claude --model $Model @Rest
}
finally {
    foreach ($n in $names) { [System.Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
}
