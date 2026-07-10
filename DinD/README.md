# DinD sandbox

Isolated environment for running Claude CLI on a project — nested Docker (DinD) so the agent never sees host Docker, credentials, or paths outside `/workspace`.

## How it works

```
Your Mac (host Docker)
  └── claude-sandbox-shell          ← nested Docker daemon, only /workspace mounted
        ├── claude-sandbox-cli      ← you + Claude CLI (+ docker client)
        │     └── ./scripts/run-tests.sh / run-app.sh
        └── claude-sandbox-app      ← Python + uv (code COPY'd at build time)
              ├── uv run pytest
              └── uv run dind-app
```

**Three layers:**

| Layer | Image / container | Role |
|-------|-------------------|------|
| **Shell** | `claude-sandbox-shell` | Isolation — inner Docker daemon, separate from your Mac |
| **CLI** | `claude-sandbox-cli` | Claude runs here; edits files in `/workspace` |
| **App** | `claude-sandbox-app` | Tests and server run here — project is `COPY`'d in at build |

The CLI container only gets the inner Docker socket and `/workspace`. It does not get your home directory, SSH keys, or host Docker.

## Setup

Make scripts executable (once):

```bash
chmod +x scripts/*.sh
```

## Usage

**Start** — boots the shell, builds the CLI image inside it, checks daemon isolation, drops you into `claude-sandbox-cli`:

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
  docker-compose.yaml     # shell container
scripts/
  sandbox-start.sh        # host — start shell, enter cli
  sandbox-stop.sh         # host — stop shell
  run-tests.sh            # inside cli — build + pytest
  run-app.sh              # inside cli — build + server
```
