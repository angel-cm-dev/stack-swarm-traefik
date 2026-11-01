#!/usr/bin/env python3
"""Valida stack.yml y traefik/dynamic.yml sin dependencias externas.

1. Renderiza el stack con `docker compose config --format json` (interpola .env.example).
2. Verifica reglas de la plantilla: HTTPS, redirección, dashboard protegido,
   rolling update start-first con rollback automático y middlewares de seguridad.
3. Revisa que dynamic.yml declare los middlewares referenciados con @file.

Uso: python scripts/validate.py
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parent.parent
errors: list[str] = []


def check(condition: bool, message: str) -> None:
    status = "OK " if condition else "ERR"
    print(f"[{status}] {message}")
    if not condition:
        errors.append(message)


def render_stack() -> dict:
    cmd = [
        "docker", "compose",
        "--env-file", str(ROOT / ".env.example"),
        "-f", str(ROOT / "stack.yml"),
        "config", "--format", "json",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        sys.exit("docker compose config falló")
    return json.loads(result.stdout)


def labels_of(service: dict) -> dict:
    raw = service.get("deploy", {}).get("labels", {})
    if isinstance(raw, list):
        return dict(item.split("=", 1) for item in raw)
    return raw


def main() -> int:
    stack = render_stack()
    services = stack.get("services", {})
    check({"traefik", "whoami"} <= services.keys(), "servicios traefik y whoami definidos")

    traefik = services["traefik"]
    cmd = " ".join(traefik.get("command", []))
    check("--providers.swarm=true" in cmd, "proveedor swarm habilitado")
    check("--providers.swarm.exposedByDefault=false" in cmd, "exposedByDefault=false")
    check("redirections.entrypoint.to=websecure" in cmd, "redirección HTTP -> HTTPS")
    check("redirections.entrypoint.scheme=https" in cmd, "esquema de redirección https")
    check("acme.tlschallenge=true" in cmd, "Let's Encrypt con TLS challenge")
    check("acme.email=admin@example.com" in cmd, "ACME_EMAIL interpolado desde .env.example")
    check("--ping=true" in cmd, "endpoint ping activo")
    check("healthcheck" in traefik and "--ping" in traefik["healthcheck"]["test"], "healthcheck de Traefik")
    ports = {p.get("published") for p in traefik.get("ports", [])}
    check({"80", "443"} <= {str(p) for p in ports}, "puertos 80 y 443 publicados")
    check(any(s.get("source") == "dashboard_users" for s in traefik.get("secrets", [])),
          "secret dashboard_users montado")

    tl = labels_of(traefik)
    check(tl.get("traefik.http.routers.dashboard.service") == "api@internal", "dashboard -> api@internal")
    check("dashboard-auth" in tl.get("traefik.http.routers.dashboard.middlewares", ""),
          "dashboard protegido con basic auth")
    check(tl.get("traefik.http.middlewares.dashboard-auth.basicauth.usersfile") == "/run/secrets/dashboard_users",
          "basic auth usa usersfile desde secret")
    check("example.com" in tl.get("traefik.http.routers.dashboard.rule", ""), "DOMAIN interpolado en la regla")

    whoami = services["whoami"]
    deploy = whoami.get("deploy", {})
    upd = deploy.get("update_config", {})
    check(upd.get("order") == "start-first", "whoami: rolling update start-first")
    check(upd.get("failure_action") == "rollback", "whoami: rollback automático")
    check(deploy.get("rollback_config", {}).get("order") == "start-first", "whoami: rollback start-first")
    check(int(deploy.get("replicas", 0)) >= 2, "whoami: al menos 2 réplicas")
    wl = labels_of(whoami)
    check(wl.get("traefik.http.services.whoami.loadbalancer.healthcheck.path") == "/health",
          "whoami: healthcheck en Traefik")
    check("secure-chain@file" in wl.get("traefik.http.routers.whoami.middlewares", ""),
          "whoami: middlewares de seguridad")
    check(wl.get("traefik.http.routers.whoami.tls.certresolver") == "le", "whoami: TLS con resolver le")

    dynamic = (ROOT / "traefik" / "dynamic.yml").read_text(encoding="utf-8")
    check("\t" not in dynamic, "dynamic.yml sin tabulaciones")
    for name in ("security-headers", "rate-limit", "secure-chain"):
        check(re.search(rf"^    {re.escape(name)}:\s*$", dynamic, re.M) is not None,
              f"dynamic.yml define middleware {name}")
    check("rateLimit:" in dynamic and "stsSeconds:" in dynamic, "rate limit y HSTS configurados")

    print()
    if errors:
        print(f"{len(errors)} verificación(es) fallaron.")
        return 1
    print("Todas las verificaciones pasaron.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
