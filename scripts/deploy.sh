#!/usr/bin/env bash
# Despliega el stack Traefik v3 + whoami en Docker Swarm.
# Uso: ./scripts/deploy.sh [ruta/.env]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-$ROOT_DIR/.env}"
NETWORK="traefik-public"
SECRET="dashboard_users"

log() { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "Docker no está instalado."
[[ -f "$ENV_FILE" ]] || die "No existe $ENV_FILE. Copia .env.example a .env y edítalo."

# Carga KEY=VALUE literal (sin evaluar $ del hash htpasswd)
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  key="${line%%=*}"
  value="${line#*=}"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  export "$key=$value"
done < "$ENV_FILE"

: "${DOMAIN:?Falta DOMAIN en $ENV_FILE}"
: "${ACME_EMAIL:?Falta ACME_EMAIL en $ENV_FILE}"
: "${DASHBOARD_USERS:?Falta DASHBOARD_USERS en $ENV_FILE}"
STACK_NAME="${STACK_NAME:-edge}"

state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"
[[ "$state" == "active" ]] || die "Swarm no está activo. Ejecuta: docker swarm init"

if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
  log "Creando red overlay $NETWORK"
  docker network create --driver overlay --attachable "$NETWORK" >/dev/null
fi

if ! docker secret inspect "$SECRET" >/dev/null 2>&1; then
  log "Creando secret $SECRET"
  printf '%s\n' "$DASHBOARD_USERS" | docker secret create "$SECRET" - >/dev/null
else
  log "Secret $SECRET ya existe (para rotarlo: docker secret rm $SECRET tras retirar el stack)"
fi

log "Validando stack.yml"
docker compose -f "$ROOT_DIR/stack.yml" config --quiet

log "Desplegando stack $STACK_NAME"
cd "$ROOT_DIR"
docker stack deploy --with-registry-auth --prune --detach=false -c stack.yml "$STACK_NAME"

log "Servicios:"
docker stack services "$STACK_NAME"
log "Listo: https://whoami.$DOMAIN  |  https://traefik.$DOMAIN/dashboard/"
