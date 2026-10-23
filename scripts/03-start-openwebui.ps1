#Requires -Version 5.1
<#
  03-start-openwebui.ps1
  ------------------------------------------------------------------
  Starts Open WebUI (a ChatGPT-style UI) in Docker, connected to the local Ollama.

    - Port 3000 on 127.0.0.1 only -> open http://localhost:3000
      (Open WebUI's own quick start uses -p 3000:8080, which listens on every
      network interface, so other machines on your Wi-Fi/LAN could reach it.)
    - --add-host host.docker.internal:host-gateway  lets the container talk to
      Ollama running on the HOST (localhost:11434).
    - The 'open-webui' volume keeps chats/users across restarts.
    - --restart always  makes it start by itself when Docker starts.
    - A container created by an earlier version of this script keeps its old port
      binding: run  docker rm -f open-webui  and then this script again (the
      'open-webui' volume keeps chats and users).

  Requires Docker Desktop to be running.
#>

# 1) Docker must be available and running
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker is not running. Open Docker Desktop and try again." -ForegroundColor Red
    exit 1
}

# 2) Idempotent: if the container already exists, just start it
$exists = docker ps -a --filter "name=open-webui" --format "{{.Names}}"
if ($exists -eq 'open-webui') {
    Write-Host "==> The 'open-webui' container already exists. Starting it..." -ForegroundColor Yellow
    docker start open-webui
} else {
    Write-Host "==> Creating the 'open-webui' container..." -ForegroundColor Cyan
    docker run -d `
        -p 127.0.0.1:3000:8080 `
        --add-host=host.docker.internal:host-gateway `
        -v open-webui:/app/backend/data `
        --name open-webui `
        --restart always `
        ghcr.io/open-webui/open-webui:main
}

Write-Host "`nOpen WebUI -> http://localhost:3000" -ForegroundColor Green
Write-Host "(The first time it asks you to create a LOCAL admin account; it stays on your machine.)" -ForegroundColor Green
