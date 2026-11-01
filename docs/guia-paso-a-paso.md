# Guía paso a paso

Esta guía lleva un servidor limpio (Ubuntu 22.04/24.04) hasta tener Traefik v3 sirviendo HTTPS en Docker Swarm.

## 1. Preparar el servidor

```bash
# Docker Engine + Compose plugin
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER" && newgrp docker

# Firewall: SSH, HTTP y HTTPS
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

Si vas a unir más nodos al clúster abre también `2377/tcp`, `7946/tcp+udp` y `4789/udp` **solo entre nodos**.

## 2. Configurar DNS

Crea registros `A` (o un wildcard `*.example.com`) apuntando a la IP pública del nodo manager:

| Registro | Tipo | Valor |
|---|---|---|
| `traefik.example.com` | A | `203.0.113.10` |
| `whoami.example.com` | A | `203.0.113.10` |

Verifica la propagación con `dig +short whoami.example.com`.

## 3. Inicializar Swarm

```bash
docker swarm init --advertise-addr <IP_PRIVADA_O_PUBLICA>
docker node ls
```

## 4. Configurar variables

```bash
cp .env.example .env
nano .env
```

- `DOMAIN`: dominio base.
- `ACME_EMAIL`: correo para avisos de Let's Encrypt.
- `ACME_CA_SERVER`: usa **staging** en la primera prueba para no chocar con los límites de Let's Encrypt; luego cambia a producción.
- `DASHBOARD_USERS`: genera el hash y pégalo **entre comillas simples**:

```bash
docker run --rm httpd:2.4-alpine htpasswd -nbB admin 'TuClaveSegura'
```

## 5. Validar y desplegar

```bash
python3 scripts/validate.py
./scripts/deploy.sh
```

El script es idempotente: puedes ejecutarlo de nuevo para aplicar cambios.

## 6. Verificar

```bash
docker stack services edge
docker service logs -f edge_traefik
curl -I http://whoami.example.com      # espera 308 hacia https
curl https://whoami.example.com
```

Abre `https://traefik.example.com/dashboard/` (la barra final es necesaria) e inicia sesión con tu usuario.

## 7. Pasar de staging a producción

1. Cambia `ACME_CA_SERVER` a `https://acme-v02.api.letsencrypt.org/directory`.
2. Elimina los certificados de staging: `docker stack rm edge && docker volume rm edge_letsencrypt`.
3. Vuelve a ejecutar `./scripts/deploy.sh`.

## 8. Actualizaciones y rollback

`whoami` usa `order: start-first`: Swarm arranca la tarea nueva, espera `monitor: 30s` y solo entonces detiene la anterior. Si la tarea nueva falla, `failure_action: rollback` restaura la versión previa automáticamente.

```bash
# Actualizar imagen
docker service update --image traefik/whoami:v1.10.1 edge_whoami

# Rollback manual
docker service rollback edge_whoami
```

## 9. Rotar la contraseña del dashboard

Los secrets de Swarm son inmutables. Crea uno nuevo y cámbialo en el servicio:

```bash
printf '%s\n' 'admin:$2y$05$...' | docker secret create dashboard_users_v2 -
docker service update \
  --secret-rm dashboard_users \
  --secret-add source=dashboard_users_v2,target=dashboard_users \
  edge_traefik
```

## 10. Añadir tus propios servicios

Conecta tus stacks a la red externa `traefik-public` y usa labels bajo `deploy.labels` (en Swarm, los labels del contenedor se ignoran). Reutiliza `secure-chain@file` para heredar cabeceras de seguridad y rate limit. Consulta el ejemplo del README.

## Solución de problemas

| Síntoma | Causa probable |
|---|---|
| `404 page not found` | Falta `traefik.enable=true` o el servicio no está en `traefik-public`. |
| Certificado `TRAEFIK DEFAULT CERT` | DNS no apunta al servidor o el puerto 443 está bloqueado; revisa logs de ACME. |
| `401` en el dashboard | Hash mal copiado; recuerda las comillas simples en `.env`. |
| `Gateway Timeout` | Puerto incorrecto en `loadbalancer.server.port`. |
