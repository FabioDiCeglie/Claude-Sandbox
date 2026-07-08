# Claude-sandbox

## The problem

Claude CLI has shell, filesystem, and network access on your machine. A compromised or tricked agent can read secrets, use SSH keys, abuse Docker, and exfiltrate data — not just edit your repo.

## Solutions

### DinD (Docker-in-Docker)

Claude runs in nested containers — not on your host.

```
┌────── Host Docker (Your Laptop) ──────┐
│  ┌── claude-sandbox-shell-docker ────┐ │
│  │                                   │ │
│  │  ┌ claude-sandbox-cli ──────────┐ │ │
│  │  │  Claude edits here           │ │ │
│  │  └───────────┬──────────────────┘ │ │
│  │              │ scripts            │ │
│  │  ┌ claude-sandbox-app ──────────┐ │ │
│  │  │  ┌ docker-tests · docker-app ┐│ │ │
│  │  │  │  same container           ││ │ │
│  │  │  └───────────────────────────┘│ │ │
│  │  └──────────────────────────────┘ │ │
│  └───────────────────────────────────┘ │
└────────────────────────────────────────┘
```

Setup: [`DinD/README.md`](./DinD/README.md)

| Problem | DinD |
|---------|------|
| Secret keys on host (`~/.aws`, home `.env`, npm tokens) | ✅ Solved |
| SSH / prod access | ✅ Solved |
| Slack / chat tokens outside workspace | ✅ Solved |
| Active session hijack (host cookies, ssh-agent, keychain) | ✅ Solved |
| CI/CD host tokens (`gh`, git, kubeconfig, Terraform) | ✅ Solved |
| Host Docker abuse | ✅ Solved |
| Unscoped filesystem (outside `/workspace`) | ✅ Solved |
| Secrets inside `/workspace` (project `.env`) | ❌ Not solved |
| CI/CD repo poisoning (bad workflows in the project) | ❌ Not solved |
| Code poisoning (malicious hooks, `CLAUDE.md`) | ❌ Not solved |
| Network exfiltration | ❌ Not solved |
| VPN / internal network via host | ❌ Not solved |
| `docker run --privileged` and dangerous containers | ❌ Not solved |
