# claude-sandbox — Plan

## What is the problem?

**Claude CLI runs with shell, filesystem, and network access on your machine.** That makes it useful — and dangerous. An agent can read, write, execute, and exfiltrate autonomously, not just suggest code.

On a typical developer laptop, unsandboxed Claude CLI can reach:

| Risk | What goes wrong |
|---|---|
| **Secret keys** | Read `~/.aws`, `.env`, npm/pypi tokens, keychain secrets — Anthropic's red-team exfiltrated AWS creds **24/25 times**; model defenses didn't catch it. |
| **SSH access** | Use `~/.ssh` keys or ssh-agent to reach prod servers, bastions, and internal git hosts. |
| **Code poisoning** | Malicious repo files (`.claude/settings.json` hooks, `CLAUDE.md`, README injections) steer or execute before trust is established. |
| **CI/CD compromise** | Use local `gh`/git tokens, kubeconfig, or Terraform creds to push malicious workflows and pivot into production pipelines. |
| **Network exfiltration** | POST stolen data to any endpoint — including through allowlisted domains if egress isn't capability-aware. |

Permission prompts help but don't hold: users auto-approve ~93% of them, and model-based auto-mode still misses ~17% of risky actions.

**The fix is environment containment** — hard filesystem and network boundaries so the agent only sees a scoped workspace, never host credentials or SSH keys, and can't reach the open internet by default.

More context: **[How we contain Claude](https://www.anthropic.com/engineering/how-we-contain-claude)** — Anthropic Engineering, May 2026

---

## Goal

Build **claude-sandbox** — a secure sandbox for running Claude CLI on macOS/Linux with:

- Scoped workspace mount only (no `~/.ssh`, `~/.aws`, full `$HOME`)
- Default-deny network egress
- Host credentials stay on host; sandbox gets scoped tokens only
- Low enough friction for daily dev use

Architecture deep-dives (DinD, DooD, Colima VM, egress proxy tradeoffs) will live in **Doc.md** — not here.

---

## Build plan

### Phase 1 — Spike isolation approach

Pick and validate one isolation strategy. Candidates to compare in Doc.md:

- DinD / DinD + egress proxy
- DooD / DooD + egress proxy
- Colima VM isolation

**Deliverable:** working proof-of-concept — Claude CLI runs inside sandbox, cannot read a dummy `~/.aws` file on host.

### Phase 2 — Core sandbox

- VM/container lifecycle (`start`, `stop`, `status`)
- Workspace mount (single project dir, symlink-safe)
- Claude CLI runner image
- Host orchestrator CLI

**Deliverable:** `claude-sandbox start ./my-project` opens an isolated Claude CLI session.

### Phase 3 — Network lockdown

- Default-deny egress
- Allowlist for required endpoints (Anthropic API, package registries as needed)
- Proxy env vars wired into Claude CLI container

**Deliverable:** `curl https://example.com` fails inside sandbox; Claude API calls succeed.

### Phase 4 — Credentials and trust

- Scoped session token injection (no host secrets copied in)
- Trust gate: defer `.claude/` config and hooks until user confirms

**Deliverable:** sandbox runs without host API keys; untrusted repo config doesn't execute on open.

### Phase 5 — Polish

- Mount modes (ro / rw)
- Logs / audit trail from inside sandbox
- README + Doc.md with architecture decisions

---

## Must-haves (non-negotiable)

1. Agent never sees host Docker socket
2. Agent never sees host SSH keys or cloud credentials
3. Network is deny-by-default
4. Only the project workspace is mounted
5. Resolve symlinks before path validation
