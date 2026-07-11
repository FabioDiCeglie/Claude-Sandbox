# Colima VM + Proxy sandbox

Claude runs inside a dedicated Colima Linux VM with a Squid egress filter. Only allowlisted domains pass — everything else is blocked at the kernel level by `iptables`.

## How it works

```
Your Mac (host)
  │
  └── Colima VM "claude-sandbox-proxy"
        │  Only /workspace mounted — no host home dir, no ~/.aws, ~/.ssh
        │
        ├── Squid (port 3128) — domain allowlist, default-deny
        │     Docker daemon image pulls also routed through Squid.
        │
        ├── iptables OUTPUT — kernel backstop
        │     Direct port 80/443 blocked; Squid is the only path out.
        │
        └── Claude CLI — HTTP_PROXY / HTTPS_PROXY → Squid
              VM Docker daemon (separate from host)
                └── claude-sandbox-colima-proxy-app (tests · server)
```

## Prerequisites

```bash
brew install colima docker-buildx
```

## Setup

```bash
chmod +x scripts/*.sh
./scripts/sandbox-start.sh
```

On first start the VM is created and tools are installed (~3–6 min). Subsequent starts are fast (~20–40s). Run `claude` once inside.

**Stop** (deletes the VM entirely):

```bash
./scripts/sandbox-stop.sh
```

## Allowlist

Domains permitted through Squid (edit `squid/squid.conf` to customise):

`*.anthropic.com` · `*.pypi.org` · `*.npmjs.com` · `*.docker.io` · `*.ghcr.io` · `*.github.com` · `*.astral.sh` · `*.ubuntu.com`

Everything else → 403 from Squid or TCP reset from iptables.

## Resource tuning

```bash
SANDBOX_CPU=4 SANDBOX_MEMORY=8 SANDBOX_DISK=40 ./scripts/sandbox-start.sh
```

| Variable | Default |
|----------|---------|
| `SANDBOX_CPU` | `2` |
| `SANDBOX_MEMORY` | `4` GB |
| `SANDBOX_DISK` | `20` GB |

## Project layout

```
src/
  main.py
tests/
  unit/
    test_greet.py
squid/
  squid.conf          # allowlist — edit to customise egress
docker/
  Dockerfile
scripts/
  sandbox-start.sh   # host — create/start VM + Squid + iptables
  sandbox-stop.sh    # host — delete the VM
  run-tests.sh       # inside VM — build image + pytest
  run-app.sh         # inside VM — build image + server
```
