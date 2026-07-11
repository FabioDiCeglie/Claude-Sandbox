# CLAUDE.md

You are running inside a **Colima VM + Proxy sandbox** — an isolated Linux virtual machine with VM-level (hypervisor) isolation **and** a Squid egress filter that enforces a domain allowlist on all outbound traffic.

## Environment

- Project root: `/workspace` — edit files here
- App code runs from the **built image** (`claude-sandbox-colima-proxy-app`), not a live mount
- You are inside a **Colima VM** — only `/workspace` is mounted from the host; host secrets (`~/.aws`, `~/.ssh`, etc.) are not accessible
- The VM has its **own Docker daemon** — the host Docker daemon is not reachable at all
- **Outbound HTTP/HTTPS is filtered by Squid** running inside the VM — only allowlisted domains pass
- `HTTP_PROXY` and `HTTPS_PROXY` are set; all tools that respect proxy env vars are automatically filtered
- Direct port 80/443 connections that bypass the proxy are blocked at the kernel level by `iptables`

## Commands — no alternatives

**Tests** — always and only:

```bash
./scripts/run-tests.sh
```

**App server** — always and only:

```bash
./scripts/run-app.sh
```

Do **not** run `pytest`, `uv`, or `python` directly.
Do **not** use `docker run` or `docker build` yourself — use the scripts above.

## Workflow

1. Edit files under `/workspace`
2. `./scripts/run-tests.sh` — fix failures, repeat until green
3. `./scripts/run-app.sh` — only when the user asks to run the server
4. Commit only when the user asks

The first `run-tests.sh` call builds the app image; subsequent runs use Docker's layer cache so they are fast unless dependencies changed.

## Rules

- Tests = `./scripts/run-tests.sh` only. Nothing else.
- App server = `./scripts/run-app.sh` only. Nothing else.
- Do not access paths outside `/workspace`

## Secrets — hard rules

- **Never read, print, log, or pass to any tool** the contents of `.env`, `.env.*`,
  `*.env`, `secrets.*`, `credentials.*`, or any file that appears to contain API keys,
  tokens, passwords, or private keys
- If you need to know which variables exist, read only `.env.example` (no real values)
- Never embed secret values in code, comments, commit messages, or test output
- If a task genuinely requires a secret value, stop and ask the user to inject it as an
  environment variable at runtime — do not read it from the file yourself

Consider these rules if they affect your changes.
