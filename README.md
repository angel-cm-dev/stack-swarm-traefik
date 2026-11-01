# stack-swarm-traefik

Plantilla lista para producción de Docker Swarm + Traefik v3 con HTTPS automático, dashboard protegido y despliegues sin downtime.

![CI](https://img.shields.io/github/actions/workflow/status/angel-cm-dev/stack-swarm-traefik/ci.yml?branch=main&label=CI)
![Traefik](https://img.shields.io/badge/Traefik-v3-24A1C1?logo=traefikproxy&logoColor=white)
![Docker Swarm](https://img.shields.io/badge/Docker-Swarm-2496ED?logo=docker&logoColor=white)
![Let's Encrypt](https://img.shields.io/badge/HTTPS-Let's%20Encrypt-003A70?logo=letsencrypt&logoColor=white)
![License](https://img.shields.io/badge/licencia-MIT-green)

## Características

- **Traefik v3** con proveedor Swarm (`exposedByDefault=false`) y proveedor file para middlewares compartidos.
- **HTTPS con Let's Encrypt** (TLS-ALPN-01) y **redirección permanente HTTP → HTTPS**; TLS 1.2 como mínimo.
- **Dashboard protegido** con basic auth; el archivo de usuarios se monta como **Docker secret** (nunca en labels ni en el repo).
- **Servicio de ejemplo `whoami`** con 2 réplicas, **rolling update `start-first`**, **rollback automático** (`failure_action: rollback`) y healthcheck en el balanceador.
- **Middlewares de seguridad**: HSTS, `nosniff`, `frame-deny`, `Referrer-Policy`, `Permissions-Policy`, oculta `Server`/`X-Powered-By`, **rate limit** (50 req/s, ráfaga 100) y compresión.
- Healthcheck de Traefik (`traefik healthcheck --ping`), logs de acceso en JSON y límites de CPU/RAM.
- Scripts idempotentes de despliegue: **`deploy.sh`** (Linux/macOS) y **`deploy.ps1`** (Windows).
- Validación automática: `docker compose config`, yamllint, reglas de la plantilla en Python y **despliegue real en Swarm dentro de CI**.

## Requisitos

- Docker Engine 24+ con Compose v2 y Swarm inicializado (`docker swarm init`).
- Un dominio con registros DNS `A` para `traefik.<dominio>` y `whoami.<dominio>` apuntando al nodo manager.
- Puertos 80 y 443 abiertos en el firewall.
- Python 3.10+ (solo para `scripts/validate.py`).

## Instalación y uso

```bash
git clone https://github.com/angel-cm-dev/stack-swarm-traefik.git
cd stack-swarm-traefik
cp .env.example .env

# Genera el usuario del dashboard y pégalo en DASHBOARD_USERS (entre comillas simples)
docker run --rm httpd:2.4-alpine htpasswd -nbB admin 'TuClaveSegura'

# Despliega
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

En Windows (PowerShell):

```powershell
Copy-Item .env.example .env
.\scripts\deploy.ps1
```

El script verifica que Swarm esté activo, crea la red overlay `traefik-public` y el secret `dashboard_users` si no existen, valida `stack.yml` y ejecuta `docker stack deploy`.

La guía completa (DNS, firewall, staging de Let's Encrypt, rollback manual, cómo añadir tus servicios) está en [docs/guia-paso-a-paso.md](docs/guia-paso-a-paso.md).

## Ejemplo

Exponer tu propia API detrás de Traefik reutilizando la red y los middlewares:

```yaml
services:
  api:
    image: ghcr.io/angel-cm-dev/mi-api:1.0.0
    networks: [traefik-public]
    deploy:
      replicas: 2
      update_config: { order: start-first, failure_action: rollback }
      labels:
        - traefik.enable=true
        - traefik.http.routers.api.rule=Host(`api.example.com`)
        - traefik.http.routers.api.entrypoints=websecure
        - traefik.http.routers.api.tls.certresolver=le
        - traefik.http.routers.api.middlewares=secure-chain@file
        - traefik.http.services.api.loadbalancer.server.port=8080
networks:
  traefik-public:
    external: true
```

Comprobación rápida tras el despliegue:

```bash
curl -I http://whoami.example.com      # 308 -> https://
curl https://whoami.example.com        # Hostname, IP, cabeceras...
docker service ps edge_whoami          # réplicas y estado
```

## Estructura del proyecto

```text
stack-swarm-traefik/
├── stack.yml                  # Stack Swarm: traefik + whoami
├── traefik/dynamic.yml        # Middlewares (headers, rate limit, chain) y opciones TLS
├── scripts/
│   ├── deploy.sh              # Despliegue Linux/macOS
│   ├── deploy.ps1             # Despliegue Windows
│   └── validate.py            # Reglas de la plantilla (stdlib)
├── docs/guia-paso-a-paso.md   # Guía detallada
├── .env.example               # Variables de ejemplo (sin secretos reales)
├── .yamllint.yml
└── .github/workflows/ci.yml
```

## Pruebas / validación

```bash
docker compose --env-file .env.example -f stack.yml config --quiet   # sintaxis + interpolación
python scripts/validate.py                                           # 27 verificaciones de la plantilla
pip install yamllint && yamllint -c .yamllint.yml stack.yml traefik/ .github/
```

En CI además se ejecuta ShellCheck sobre `deploy.sh`, el parser de PowerShell sobre `deploy.ps1` y un **smoke test** que inicializa Swarm, despliega el stack y verifica réplicas `2/2`, el enrutamiento por Traefik y la redirección HTTP → HTTPS.

## Roadmap

- [ ] Challenge DNS-01 (Cloudflare) para certificados wildcard.
- [ ] Métricas Prometheus + dashboard Grafana.
- [ ] Middleware de autenticación ForwardAuth (Authelia / OAuth2 Proxy).

## Licencia y autor

Distribuido bajo licencia [MIT](LICENSE).

Hecho por **Angel Castañeda Meza** — Ingeniero de Sistemas, Lima, Perú · [github.com/angel-cm-dev](https://github.com/angel-cm-dev)
