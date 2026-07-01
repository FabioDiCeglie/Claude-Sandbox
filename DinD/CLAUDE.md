# CLAUDE.md

You are running inside **claude-sandbox-cli** — an isolated sandbox container.

## Environment

- Project root: `/workspace` — edit files here
- App code runs from the **built image** (`claude-sandbox-app`), not a live mount
- You have the **inner** Docker socket mounted (not the host's)
- Only `/workspace` is visible; host secrets (`~/.aws`, `~/.ssh`, etc.) are not mounted

## Commands — no alternatives

**Tests** — always and only:

```bash
./scripts/run-tests.sh
```

**App server** — always and only:

```bash
./scripts/run-app.sh
```

**Rebuild app image** — after any code or dependency change:

```bash
./scripts/build-app.sh
```

Do **not** run `pytest`, `uv`, `python`, or `dind-app` directly.
Do **not** use `docker run` or `docker build` yourself — use the scripts above.

## Workflow

1. Edit files under `/workspace`
2. `./scripts/build-app.sh` — copies changes into the app image
3. `./scripts/run-tests.sh` — fix failures, repeat until green
4. `./scripts/run-app.sh` — only when the user asks to run the server
5. Commit only when the user asks

## Rules

- Tests = `./scripts/run-tests.sh` only. Nothing else.
- App server = `./scripts/run-app.sh` only. Nothing else.
- Always `./scripts/build-app.sh` before tests or app after editing files
- Do not access paths outside `/workspace`
