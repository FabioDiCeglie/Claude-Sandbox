# DinD-Proxy sandbox

DinD sandbox with an egress-filtering proxy layer. Same Docker-in-Docker isolation as `DinD/`, plus Squid sitting between every container and the internet — only allowlisted domains pass.

## How it works

```
Your Mac (host Docker)
  └── claude-sandbox-proxy-shell        ← nested Docker daemon (DinD)
        │
        ├── proxy-egress  (normal bridge — internet-accessible)
        │     └── sandbox-proxy (Squid :3128) ──── internet
        │
        └── sandbox-net  (--internal — NO direct internet)
              ├── sandbox-proxy  (also here — accepts requests from CLI/app)
              └── claude-sandbox-cli   ← you + Claude CLI
                    └── ./scripts/run-tests.sh / run-app.sh
                          └── claude-sandbox-app   ← Python + uv
```

**Five layers:**

| Layer | Container | Role |
|-------|-----------|------|
| **Shell** | `claude-sandbox-proxy-shell` | Inner Docker daemon (DinD) |
| **Squid** | `sandbox-proxy` | HTTP egress filter — domain allowlist + audit log |
| **Socket proxy** | `socket-proxy` | Docker API filter — blocks `--privileged`, dangerous caps, host network/pid |
| **CLI** | `claude-sandbox-cli` | Claude CLI; all outbound via proxies |
| **App** | `claude-sandbox-app` | Tests and server; all outbound via proxies |

### What the proxies enforce

**Squid (HTTP egress — `sandbox-proxy`)**
- Domain allowlist — only PyPI, Anthropic API, Docker Hub, GHCR, npm, Debian apt, GitHub, uv/Astral pass.
- Deny-all default — any unlisted domain returns `403 Forbidden`.
- Audit log — every request written to `/var/log/squid/access.log`.
- Internal network — `sandbox-net` is `--internal`; kernel blocks direct internet at routing level.

**Socket proxy (Docker API — `socket-proxy`)**
- Blocks `docker run --privileged`
- Blocks dangerous capabilities (`SYS_ADMIN`, `NET_ADMIN`, `SYS_PTRACE`, …)
- Blocks `--network host`, `--pid host`, `--ipc host`
- Logs every allowed/blocked container-create call to stdout
- CLI uses `DOCKER_HOST=tcp://socket-proxy:2375` — never touches the real socket directly

### Known limitation

Docker image pulls (base images like `python:3.11-slim`) are fetched by the inner daemon directly — not through Squid. Those pulls happen when `run-tests.sh` or `run-app.sh` builds the app image, using the inner daemon's default bridge which has direct internet access. The proxy filtering applies at runtime: the app container
is placed on `sandbox-net` so any network calls the app or tests make go through Squid.

## Setup

Make scripts executable (once):

```bash
chmod +x scripts/*.sh
```

## Usage

**Start** — boots the shell, creates proxy networks, starts Squid, builds CLI, drops you in:

```bash
./scripts/sandbox-start.sh
```

Then run `claude` when ready.

**Stop:**

```bash
./scripts/sandbox-stop.sh
```

**Manual test flow** (inside cli, without Claude):

```bash
./scripts/run-tests.sh
```

**Inspect proxy logs** (from your Mac, while sandbox is running):

```bash
docker exec claude-sandbox-proxy-shell \
  docker exec sandbox-proxy \
  tail -f /var/log/squid/access.log
```

**Edit the allowlist** — modify `docker/squid/squid.conf`, then restart the sandbox. Add a new `acl allowed dstdomain .example.com` line above the final `http_access deny all`.

## Project layout

```
src/
  main.py
tests/
  unit/
    test_greet.py
CLAUDE.md                      # agent rules
docker/
  Dockerfile                   # app image — Python + uv
  Dockerfile.claude-cli        # CLI image — Claude CLI + docker client
  Dockerfile.squid             # Squid image — HTTP egress filter
  Dockerfile.socket-proxy      # socket proxy image — Docker API filter
  squid/
    squid.conf                 # ACL allowlist + deny-all default
  socket-proxy/
    proxy.py                   # Python proxy — inspects /containers/create
  docker-compose.yaml          # host: shell container only
scripts/
  sandbox-start.sh             # host: boot everything, drop into CLI
  sandbox-stop.sh              # host: tear everything down
  run-tests.sh                 # inside cli: pytest (via proxy)
  run-app.sh                   # inside cli: FastAPI server (via proxy)
```
