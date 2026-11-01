<#
.SYNOPSIS
  Despliega el stack Traefik v3 + whoami en Docker Swarm (Windows / PowerShell).
.EXAMPLE
  .\scripts\deploy.ps1
  .\scripts\deploy.ps1 -EnvFile .\.env.prod
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env')
)
$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..')
$Network = 'traefik-public'
$Secret = 'dashboard_users'

function Write-Step([string]$Message) { Write-Host "[deploy] $Message" -ForegroundColor Cyan }

# Ejecuta docker sin propagar stderr como error (PowerShell 5.1) y devuelve si tuvo exito
function Test-Docker {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { docker @args 2>&1 | Out-Null; return ($LASTEXITCODE -eq 0) }
    finally { $ErrorActionPreference = $prev }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker no esta instalado.' }
if (-not (Test-Path $EnvFile)) { throw "No existe $EnvFile. Copia .env.example a .env y editalo." }

# Carga KEY=VALUE literal (sin interpretar $ del hash htpasswd)
foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $idx = $line.IndexOf('=')
    $key = $line.Substring(0, $idx).Trim()
    $value = $line.Substring($idx + 1).Trim().Trim('"').Trim("'")
    Set-Item -Path "Env:$key" -Value $value
}

foreach ($required in 'DOMAIN', 'ACME_EMAIL', 'DASHBOARD_USERS') {
    if (-not (Get-Item "Env:$required" -ErrorAction SilentlyContinue)) { throw "Falta $required en $EnvFile" }
}
$StackName = if ($env:STACK_NAME) { $env:STACK_NAME } else { 'edge' }

$state = docker info --format '{{.Swarm.LocalNodeState}}'
if ($state -ne 'active') { throw 'Swarm no esta activo. Ejecuta: docker swarm init' }

if (-not (Test-Docker network inspect $Network)) {
    Write-Step "Creando red overlay $Network"
    docker network create --driver overlay --attachable $Network | Out-Null
}

if (-not (Test-Docker secret inspect $Secret)) {
    Write-Step "Creando secret $Secret"
    $env:DASHBOARD_USERS | docker secret create $Secret - | Out-Null
} else {
    Write-Step "Secret $Secret ya existe"
}

Write-Step 'Validando stack.yml'
docker compose -f (Join-Path $Root 'stack.yml') config --quiet
if ($LASTEXITCODE -ne 0) { throw 'stack.yml invalido' }

Write-Step "Desplegando stack $StackName"
Push-Location $Root
try {
    docker stack deploy --with-registry-auth --prune --detach=false -c stack.yml $StackName
    if ($LASTEXITCODE -ne 0) { throw 'Fallo docker stack deploy' }
    docker stack services $StackName
} finally {
    Pop-Location
}
Write-Step "Listo: https://whoami.$($env:DOMAIN)  |  https://traefik.$($env:DOMAIN)/dashboard/"
