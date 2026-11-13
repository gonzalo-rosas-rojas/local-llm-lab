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
    [string]$Model,
    [Parameter(ValueFromRemainingArguments = $true)] $Rest
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# The default model: a gpt-oss variant created below with a large context.
$CustomModelName = 'gpt-oss-cc'
$CustomModelTag = "${CustomModelName}:latest"
if (-not $PSBoundParameters.ContainsKey('Model')) { $Model = $CustomModelTag }

# The variables set for this launch only. 'ollama' is a placeholder, not a secret: Ollama
# does not check the token, but Claude Code wants a non-empty value here.
$launchEnv = [ordered]@{
    ANTHROPIC_BASE_URL = 'http://localhost:11434'
    ANTHROPIC_AUTH_TOKEN = 'ollama'
    ANTHROPIC_API_KEY = ''
    ANTHROPIC_MODEL = $Model
    ANTHROPIC_SMALL_FAST_MODEL = 'qwen3:8b'
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
}
# A script run from a prompt shares the caller's process, so $env: changes would
# outlive it. Save what we touch (the table above and Path) and put it back in the
# finally block below.
$names = @('Path') + @($launchEnv.Keys)
$saved = @{}
foreach ($n in $names) { $saved[$n] = [System.Environment]::GetEnvironmentVariable($n, 'Process') }
$exitCode = 0
# num_ctx of the gpt-oss-cc variant: Claude Code needs far more context than Ollama's default.
$ClaudeContextTokens = 32768

try {
    Sync-SessionPath

    # Ollama must be running
    try { Invoke-WebRequest 'http://localhost:11434/api/version' -UseBasicParsing -TimeoutSec 3 | Out-Null }
    catch { Write-Host "Ollama is not answering. Run first: .\scripts\start-lab.ps1" -ForegroundColor Red; exit 1 }

    # Claude Code needs a lot of context. If you asked for gpt-oss-cc and it does not
    # exist, create a gpt-oss variant with a large num_ctx (Ollama's default is small).
    if ($Model -eq $CustomModelTag) {
        $list = Invoke-External -Exe 'ollama' -Arguments @('list') -Capture
        if ($list.ExitCode -ne 0) { throw "'ollama list' failed (exit code $($list.ExitCode)).$(Get-StderrTail -Result $list)" }
        if (-not (Test-ModelListed -ListLines $list.Output -Tag $CustomModelTag)) {
            Write-Host "Creating $CustomModelName (num_ctx $ClaudeContextTokens) from gpt-oss:20b..." -ForegroundColor Cyan
            $mf = Join-Path $env:TEMP 'Modelfile.gpt-oss-cc'
            "FROM gpt-oss:20b`nPARAMETER num_ctx $ClaudeContextTokens" | Set-Content -Path $mf -Encoding ascii
            $create = Invoke-External -Exe 'ollama' -Arguments @('create', $CustomModelName, '-f', $mf) -Capture
            if ($create.ExitCode -ne 0) { throw "'ollama create $CustomModelName' failed (exit code $($create.ExitCode)). Is gpt-oss:20b downloaded? Run .\scripts\02-pull-models.ps1$(Get-StderrTail -Result $create)" }
        }
    }
    if (-not (Get-Command claude -ErrorAction Ignore)) { throw "The 'claude' command was not found. Install Claude Code first." }

    # Variables for this launch only (restored when claude exits)
    foreach ($name in $launchEnv.Keys) { Set-Item -LiteralPath "Env:$name" -Value $launchEnv[$name] }

    Write-Host "Claude Code -> LOCAL Ollama ($Model). Your normal Claude Code is NOT affected." -ForegroundColor Green
    & claude --model $Model @Rest
    $exitCode = $LASTEXITCODE
}
catch {
    Write-Host "claude-local: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
finally {
    foreach ($n in $names) { [System.Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
}
exit $exitCode
