# DooD sandbox

Isolated environment for running Claude CLI on a project — Docker-outside-of-Docker so the agent never sees host credentials or paths outside `/workspace`. Uses the host daemon directly (no nested daemon, no `--privileged` shell).

## How it works

```
Your Mac (host Docker)
  └── claude-sandbox-dood-cli    ← you + Claude CLI (+ docker client)
        └── ./scripts/run-tests.sh / run-app.sh
  └── claude-sandbox-dood-app   ← Python + uv (code COPY'd at build time)
        ├── uv run pytest
        └── uv run dood-app
```

**Two layers** (no privileged shell needed):

| Layer | Image / container | Role |
|-------|-------------------|------|
| **CLI** | `claude-sandbox-dood-cli` | Claude runs here; edits files in `/workspace` |
| **App** | `claude-sandbox-dood-app` | Tests and server run here — project is `COPY`'d in at build |

The CLI container only gets the host Docker socket and `/workspace`. It does not get your home directory, SSH keys, or any other host path.

## Setup

Make scripts executable (once):

```bash
chmod +x scripts/*.sh
```

## Usage

**Start** — builds the CLI image, locks secrets, drops you into `claude-sandbox-dood-cli`:

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
scripts/
  sandbox-start.sh        # host — build cli, enter it
  sandbox-stop.sh         # host — remove leftover containers
  run-tests.sh            # inside cli — build + pytest
  run-app.sh              # inside cli — build + server
```
