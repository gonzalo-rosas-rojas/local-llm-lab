# Security

This repository is a personal lab for running language models on one Windows machine. It has no server of its own, no accounts and no secrets. What matters is what the scripts start on your computer.

## What the lab exposes

Everything the scripts start is meant to listen on this machine only:

| Service | Address | Started by |
|---|---|---|
| Ollama (native and OpenAI-compatible API) | `127.0.0.1:11434` | `scripts/start-lab.ps1` (Ollama's own default binding) |
| Open WebUI (chat UI in Docker) | `127.0.0.1:3000` | `scripts/03-start-openwebui.ps1`, with `-p 127.0.0.1:3000:8080` |
| llama-server (UI and `/v1` API) | `127.0.0.1:8080` | `scripts/llama-server/*.ps1`, with `--host 127.0.0.1` |

Nothing is published to the local network or the internet. Open WebUI's own quick start publishes its port on every interface; the script here deliberately does not.

## What it does not protect

- Loopback is not a security boundary against software running on the same machine. Ollama and llama-server have no authentication, so any local process, and any other user of the PC, can call them and use your GPU.
- Open WebUI keeps a local admin account and its chats in a Docker volume on this machine. Protect it like any local application data.
- The Open WebUI image defaults to a moving tag (`:main`). `scripts/03-start-openwebui.ps1` explains how to pin it by digest with `-Image`; until you do, a new container may run different code than the last one.
- If you set `OLLAMA_HOST` to an address other than loopback, or edit the scripts, the statements above stop being true. The check below tells you.

## Checking it

```powershell
.\scripts\check-loopback.ps1
```

The script reads the ports from the lab's scripts, lists the TCP listeners on them with `Get-NetTCPConnection`, and exits with code 1, naming the owning process, if any listens on an address that is not loopback (for example `0.0.0.0` or `::`). It is read-only. A port with no listener is fine: it means that part of the lab is off.

## The `ollama` key

`scripts/claude-local.ps1` sets `ANTHROPIC_AUTH_TOKEN` to the literal string `ollama`, and `clients/smoke_test.py` passes `api_key="ollama"`. These are placeholders: the local servers do not check them and the SDKs only insist on a non-empty value. They are not secrets and do not give access to anything. Real keys never belong in this repository; `.gitignore` also keeps model weights and local settings out.

## Reporting a problem

Use the repository's Security tab and choose "Report a vulnerability". If that option is not available, open an issue that says only that you have a security report, with no details, and ask for a private way to send it.
