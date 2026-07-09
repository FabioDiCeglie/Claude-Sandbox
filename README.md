# Claude-sandbox

## The problem

Claude CLI has shell, filesystem, and network access on your machine. A compromised or tricked agent can read secrets, use SSH keys, abuse Docker, and exfiltrate data — not just edit your repo.

## Solutions

### DinD (Docker-in-Docker)

Claude runs in nested containers — not on your host.

```
┌────── Host Docker (Your Laptop) ──────┐
│  ┌── claude-sandbox-shell ───────────┐ │
│  │                                   │ │
│  │  ┌ claude-sandbox-cli ──────────┐ │ │
│  │  │  Claude edits here           │ │ │
│  │  └───────────┬──────────────────┘ │ │
│  │              │ scripts            │ │
│  │  ┌ claude-sandbox-app ──────────┐ │ │
│  │  │  tests · server              │ │ │
│  │  └──────────────────────────────┘ │ │
│  └───────────────────────────────────┘ │
└────────────────────────────────────────┘
```

Setup: [`DinD/README.md`](./DinD/README.md)

### DinD + Proxy

Same Docker-in-Docker isolation, plus a Squid egress-filter sitting between every container and the internet. Only allowlisted domains pass — everything else is blocked at the kernel level.

```
┌────── Host Docker (Your Laptop) ──────────────┐
│  ┌── claude-sandbox-proxy-shell ─────────────┐ │
│  │                                           │ │
│  │  proxy-egress ── sandbox-proxy (Squid) ── internet
│  │                        │                  │ │
│  │  sandbox-net (internal, no direct web)    │ │
│  │    ├── sandbox-proxy                      │ │
│  │    └── claude-sandbox-cli                 │ │
│  │          └── claude-sandbox-app           │ │
│  └───────────────────────────────────────────┘ │
└────────────────────────────────────────────────┘
```

Setup: [`DinD-Proxy/README.md`](./DinD-Proxy/README.md)

## What each solution covers

| Problem | DinD | DinD + Proxy |
|---------|:----:|:------------:|
| Secret keys on host (`~/.aws`, home `.env`, npm tokens) | ✅ | ✅ |
| SSH / prod access | ✅ | ✅ |
| Slack / chat tokens outside workspace | ✅ | ✅ |
| Active session hijack (host cookies, ssh-agent, keychain) | ✅ | ✅ |
| CI/CD host tokens (`gh`, git, kubeconfig, Terraform) | ✅ | ✅ |
| Host Docker abuse | ✅ | ✅ |
| Unscoped filesystem (outside `/workspace`) | ✅ | ✅ |
| Network exfiltration | ❌ | ✅ |
| VPN / internal network via host | ❌ | ✅ |
| Secrets inside `/workspace` (project `.env`) | ⚠️ CLAUDE.md + `chmod 000` at startup | ⚠️ CLAUDE.md + `chmod 000` at startup |
| CI/CD repo poisoning (bad workflows in the project) | ⚠️ Branch protection + required review | ⚠️ Branch protection + required review |
| Code poisoning (malicious hooks, `CLAUDE.md`) | ⚠️ Branch protection + required review | ⚠️ Branch protection + required review |
| `docker run --privileged` and dangerous containers | ❌ | ✅ Socket proxy (Docker API filter) |
