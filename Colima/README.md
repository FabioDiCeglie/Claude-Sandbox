# Colima VM sandbox

Isolated environment for running Claude CLI — inside a dedicated Colima Linux VM. Unlike the Docker-based solutions (DinD, DooD), isolation here is enforced by the **VM hypervisor**, not just Linux kernel namespaces.

## How it works

```
Your Mac (host)
  │
  └── Colima VM "claude-sandbox"  (Lima/QEMU, isolated)
        │  Only /workspace mounted — no host home dir, no ~/.aws, ~/.ssh
        │
        ├── Claude CLI runs here natively (not inside a container)
        │
        └── VM Docker daemon (separate from host)
              └── claude-sandbox-colima-app  (tests · server)
```

**Isolation is enforced by the VM hypervisor** — Claude runs in its own Linux kernel, the host Docker daemon is completely unreachable, and only `/workspace` is mounted from the host.

## Prerequisites

```bash
brew install colima docker-buildx
```

Colima brings its own Docker daemon — Docker Desktop is **not** required (and can be stopped to free resources).

## Setup

Make scripts executable (once):

```bash
chmod +x scripts/*.sh
```

## Usage

**Start** — creates/starts the VM, provisions tools (Node, Claude CLI, uv) on first boot, locks secrets, drops you into the VM:

```bash
./scripts/sandbox-start.sh
```

On first start the VM is created and tools are installed (~2–5 min). Subsequent starts reuse the VM disk and are fast (~15–30s).

Then run `claude` when ready.

**Stop** (keeps VM disk — tools stay installed):

```bash
./scripts/sandbox-stop.sh
```

**Stop + wipe** (full reset, next start re-provisions everything):

```bash
./scripts/sandbox-stop.sh --delete
```

**Manual test flow** (inside VM, without Claude):

```bash
./scripts/run-tests.sh
```

## Resource tuning

Override defaults via environment variables before starting:

```bash
SANDBOX_CPU=4 SANDBOX_MEMORY=8 SANDBOX_DISK=40 ./scripts/sandbox-start.sh
```

| Variable | Default | Description |
|----------|---------|-------------|
| `SANDBOX_CPU` | `2` | vCPU count |
| `SANDBOX_MEMORY` | `4` | RAM in GB |
| `SANDBOX_DISK` | `20` | Disk in GB |

## Project layout

```
src/
  main.py
tests/
  unit/
    test_greet.py
CLAUDE.md                  # agent rules (scripts only, no raw docker)
docker/
  Dockerfile               # app image — COPY project + uv sync
scripts/
  sandbox-start.sh         # host — create/start Colima VM, enter it
  sandbox-stop.sh          # host — stop or delete the VM
  run-tests.sh             # inside VM — build app image + pytest
  run-app.sh               # inside VM — build app image + server
```
