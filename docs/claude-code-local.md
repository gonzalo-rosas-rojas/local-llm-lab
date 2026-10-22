# Claude Code on a local LLM (Ollama)

Use the same **Claude Code** you already know, but **powered by a local Ollama** instead of Anthropic's cloud. It works because **Ollama 0.14+ speaks Anthropic's native API** (`/v1/messages`); Ollama 0.24 was verified to support it.

## How it works

Claude Code respects environment variables. The launcher `scripts/claude-local.ps1` sets them **only in that process**, so a normal Claude Code (Anthropic) is NOT affected:

| Variable | Value |
|---|---|
| `ANTHROPIC_BASE_URL` | `http://localhost:11434` |
| `ANTHROPIC_AUTH_TOKEN` | `ollama` |
| `ANTHROPIC_API_KEY` | (empty) |
| `ANTHROPIC_MODEL` | `gpt-oss-cc:latest` |
| `ANTHROPIC_SMALL_FAST_MODEL` | `qwen3:8b` |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `1` |

## Context

Claude Code recommends at least 64k of context and Ollama's default is small, so the launcher creates a **`gpt-oss-cc`** variant (`num_ctx 32768`) from `gpt-oss:20b`. 32k is a balance for 16 GB; raise it if your VRAM allows, lower it if it gets slow.

## Usage

```powershell
.\scripts\start-lab.ps1        # makes sure Ollama is running
.\scripts\claude-local.ps1     # Claude Code with local gpt-oss (interactive)
```

## Honest expectations

- **It works** (verified: Claude Code converses with local gpt-oss through the Anthropic API).
- But a local 8-30B LLM is **much weaker** than the real Claude in the agentic loop (tool use, multi-step edits). Expect failed tool calls, imprecise edits, and distraction with long prompts or contexts.
- Good for **learning, light tasks and privacy**; it does not replace the real Claude for heavy work.
- **Tip:** global plugins and hooks that inject many instructions confuse weaker models. For cleaner local sessions, consider a separate config (the `CLAUDE_CONFIG_DIR` variable) without heavy plugins.

## Notes

- `ruvnet/open-claude-code` is an open-source reimplementation of the CLI, but it still needs an API backend; it is not needed here: the official Claude Code plus Ollama is enough.
- `ollama launch claude` (an Ollama subcommand) does something similar; the explicit launcher gives more control and does not touch the global config.
