# DooD-Proxy sandbox

Isolated environment for running Claude CLI — Docker-outside-of-Docker with an egress-filtering proxy layer. Uses the host daemon directly (no privileged shell), plus Squid sitting between every container and the internet, and a socket proxy filtering all Docker API calls.

## How it works

```
Your Mac (host Docker)
  │
  ├── proxy-egress  (bridge — internet-accessible)
  │     └── claude-sandbox-dood-proxy  (Squid)
  │
  └── sandbox-net   (--internal — no direct internet)
        ├── claude-sandbox-dood-proxy        (Squid, also here)
        ├── claude-sandbox-dood-socket-proxy (Docker API filter)
        └── claude-sandbox-dood-cli          ← Claude edits here
              └── claude-sandbox-dood-proxy-app  (tests · server)
```

**Three layers, no privileged shell needed:**

| Layer | Container | Role |
|-------|-----------|------|
| **CLI** | `claude-sandbox-dood-cli` | Claude runs here; edits files in `/workspace` |
| **App** | `claude-sandbox-dood-proxy-app` | Tests and server run here — project is `COPY`'d in at build |
| **Squid** | `claude-sandbox-dood-proxy` | Egress filter — only allowlisted domains pass |
| **Socket proxy** | `claude-sandbox-dood-socket-proxy` | Docker API filter — blocks `--privileged`, dangerous caps, host net/pid |

The CLI container is on the `--internal` `sandbox-net` network and cannot reach the internet directly. All HTTP/HTTPS goes through Squid. All Docker API calls go through the socket proxy — the CLI never touches the raw host socket.

> **Known limitation:** `docker build` base-image pulls happen via the host daemon's default network, bypassing Squid. Runtime app traffic (pip, npm, API calls) is fully filtered.

## Setup

Make scripts executable (once):

```bash
chmod +x scripts/*.sh
```

## Usage

**Start** — builds all images, starts proxy + socket-proxy, locks secrets, drops you into `claude-sandbox-dood-cli`:

```bash
./scripts/sandbox-start.sh
```

Then run `claude` when ready.

**Stop:**

```bash
./scripts/sandbox-stop.sh
```

**Manual test flow** (inside CLI, without Claude):

```bash
./scripts/run-tests.sh
```

## Project layout

```
src/
  main.py
tests/
  unit/
    test_greet.py
CLAUDE.md                 # agent rules (scripts only, no raw docker)
docker/
  Dockerfile              # app image — COPY project + uv sync
  Dockerfile.claude-cli   # cli image — Claude CLI + docker client
  Dockerfile.squid        # Squid egress filter
  Dockerfile.socket-proxy # Docker API filter
  squid/
    squid.conf            # allowlist (PyPI, Anthropic, Docker Hub, npm, GitHub…)
  socket-proxy/
    proxy.py              # blocks --privileged, dangerous caps, host net/pid
scripts/
  sandbox-start.sh        # host — create networks, start proxies, enter CLI
  sandbox-stop.sh         # host — remove all containers and networks
  run-tests.sh            # inside cli — build + pytest
  run-app.sh              # inside cli — build + server
```
