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

**Four layers:**

| Layer | Container | Role |
|-------|-----------|------|
| **Shell** | `claude-sandbox-proxy-shell` | Inner Docker daemon (DinD) |
| **Proxy** | `sandbox-proxy` | Squid — egress filter + audit log |
| **CLI** | `claude-sandbox-cli` | Claude CLI; all outbound via proxy |
| **App** | `claude-sandbox-app` | Tests and server; all outbound via proxy |

### What the proxy enforces

- **Allowlist** — only the domains in `docker/squid/squid.conf` are reachable: PyPI, Anthropic API, Docker Hub, GHCR, npm, Debian apt, GitHub, uv/Astral.
- **Deny-all default** — any domain not on the list returns `403 Forbidden`.
- **Audit log** — every request (allowed or denied) is written to `/var/log/squid/access.log` inside `sandbox-proxy`.
- **Internal network** — `sandbox-net` is created with `--internal`, so the kernel itself prevents CLI/app containers from bypassing the proxy at the routing level.

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
  Dockerfile.squid             # proxy image — Squid on Alpine
  squid/
    squid.conf                 # ACL allowlist + deny-all default
  docker-compose.yaml          # host: shell container only
scripts/
  sandbox-start.sh             # host: boot everything, drop into CLI
  sandbox-stop.sh              # host: tear everything down
  run-tests.sh                 # inside cli: pytest (via proxy)
  run-app.sh                   # inside cli: FastAPI server (via proxy)
```
