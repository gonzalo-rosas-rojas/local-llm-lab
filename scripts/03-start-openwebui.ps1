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
    - --restart unless-stopped  makes it start by itself when Docker starts, but not if you
      stopped it (stop-lab.ps1 does), so what you turned off stays off after a Docker restart.
      A container made with the earlier policy (always) keeps it until you recreate it.
    - A container created by an earlier version of this script keeps its old port
      binding: run  docker rm -f open-webui  and then this script again (the
      'open-webui' volume keeps chats and users).

  The image: -Image defaults to the moving tag ghcr.io/open-webui/open-webui:main, which
  changes whenever the project publishes, so two runs on different days can run different
  code. Pin it instead. After one pull, read the digest of the image you tested:

      docker image inspect ghcr.io/open-webui/open-webui:main --format "{{index .RepoDigests 0}}"

  and pass it (or put it in this default):

      .\scripts\03-start-openwebui.ps1 -Image ghcr.io/open-webui/open-webui@sha256:<digest>

  No digest is written here because the image was not present on the machine where this
  script was last edited, so there was nothing real to pin. -Image only matters when the
  container is created; an existing container keeps the image it was created with.

  Requires Docker Desktop to be running. Exit code 1 if Docker is not running or a
  docker command fails.
#>
param(
    [string]$Image = 'ghcr.io/open-webui/open-webui:main'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$ContainerName = Get-OpenWebUiContainerName

try {
    # 1) Docker must be available and running
    $info = Invoke-External -Exe 'docker' -Arguments @('info') -Capture
    if ($info.ExitCode -ne 0) {
        throw "Docker is not running. Open Docker Desktop and try again."
    }

    # 2) Idempotent: if the container already exists, just start it
    $names = Invoke-External -Exe 'docker' -Arguments @('ps', '-a', '--filter', "name=$ContainerName", '--format', '{{.Names}}') -Capture
    if ($names.ExitCode -ne 0) { throw "'docker ps' failed (exit code $($names.ExitCode))." }
    if ($names.Output -contains $ContainerName) {
        Write-Host "==> The '$ContainerName' container already exists. Starting it..." -ForegroundColor Yellow
        $r = Invoke-External -Exe 'docker' -Arguments @('start', $ContainerName)
        if ($r.ExitCode -ne 0) { throw "'docker start $ContainerName' failed (exit code $($r.ExitCode))." }
    } else {
        Write-Host "==> Creating the '$ContainerName' container from $Image..." -ForegroundColor Cyan
        $r = Invoke-External -Exe 'docker' -Arguments @(
            'run', '-d',
            '-p', '127.0.0.1:3000:8080',
            '--add-host=host.docker.internal:host-gateway',
            '-v', "${ContainerName}:/app/backend/data",
            '--name', $ContainerName,
            '--restart', 'unless-stopped',
            $Image
        )
        if ($r.ExitCode -ne 0) { throw "'docker run' failed (exit code $($r.ExitCode))." }
    }

    Write-Host "`nOpen WebUI -> http://localhost:3000" -ForegroundColor Green
    Write-Host "(The first time it asks you to create a LOCAL admin account; it stays on your machine.)" -ForegroundColor Green
} catch {
    Write-Host "03-start-openwebui: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
