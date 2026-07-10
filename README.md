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

### DooD (Docker-outside-of-Docker)

Same idea as DinD — Claude runs in an isolated CLI container — but the CLI uses the **host Docker daemon** directly instead of a nested one. No privileged shell container required.

```
┌────── Host Docker (Your Laptop) ──────┐
│                                       │
│  ┌── claude-sandbox-dood-cli ───────┐ │
│  │  Claude edits here               │ │
│  └───────────┬───────────────────── ┘ │
│              │ scripts                │
│  ┌── claude-sandbox-dood-app ───────┐ │
│  │  tests · server                  │ │
│  └──────────────────────────────────┘ │
│                                       │
│  /var/run/docker.sock (host daemon)   │
└───────────────────────────────────────┘
```

Setup: [`DooD/README.md`](./DooD/README.md)

### DooD + Proxy

Same DooD approach — no privileged shell, host daemon — plus Squid egress-filter and a Docker socket proxy. All HTTP/HTTPS is forced through Squid; all Docker API calls go through a filter that blocks `--privileged` and dangerous capabilities.

```
┌────── Host Docker (Your Laptop) ──────────────────────┐
│                                                       │
│  proxy-egress ── claude-sandbox-dood-proxy (Squid) ── internet
│                          │                            │
│  sandbox-net (internal, no direct web)                │
│    ├── claude-sandbox-dood-proxy                      │
│    ├── claude-sandbox-dood-socket-proxy               │
│    └── claude-sandbox-dood-cli                        │
│          └── claude-sandbox-dood-proxy-app            │
│                                                       │
│  /var/run/docker.sock (filtered via socket-proxy)     │
└───────────────────────────────────────────────────────┘
```

Setup: [`DooD-Proxy/README.md`](./DooD-Proxy/README.md)

## What each solution covers

| Problem | DinD | DinD + Proxy | DooD | DooD + Proxy |
|---------|:----:|:------------:|:----:|:------------:|
| Secret keys on host (`~/.aws`, home `.env`, npm tokens) | ✅ | ✅ | ✅ | ✅ |
| SSH / prod access | ✅ | ✅ | ✅ | ✅ |
| Slack / chat tokens outside workspace | ✅ | ✅ | ✅ | ✅ |
| Active session hijack (host cookies, ssh-agent, keychain) | ✅ | ✅ | ✅ | ✅ |
| CI/CD host tokens (`gh`, git, kubeconfig, Terraform) | ✅ | ✅ | ✅ | ✅ |
| Host Docker abuse | ✅ | ✅ | ❌ Full host socket | ⚠️ Socket proxy |
| Unscoped filesystem (outside `/workspace`) | ✅ | ✅ | ✅ | ✅ |
| Network exfiltration | ❌ | ✅ | ❌ | ✅ |
| VPN / internal network via host | ❌ | ✅ | ❌ | ✅ |
| Daemon isolation (separate from host) | ✅ | ✅ | ❌ Shares host daemon | ❌ Shares host daemon |
| `docker run --privileged` and dangerous containers | ❌ | ✅ Socket proxy | ❌ | ✅ Socket proxy |
| Requires `--privileged` host container | ⚠️ Yes | ⚠️ Yes | ✅ No | ✅ No |
| Secrets inside `/workspace` (project `.env`) | ⚠️ CLAUDE.md + `chmod 000` | ⚠️ CLAUDE.md + `chmod 000` | ⚠️ CLAUDE.md + `chmod 000` | ⚠️ CLAUDE.md + `chmod 000` |
| CI/CD repo poisoning (bad workflows in the project) | ⚠️ Branch protection | ⚠️ Branch protection | ⚠️ Branch protection | ⚠️ Branch protection |
| Code poisoning (malicious hooks, `CLAUDE.md`) | ⚠️ Branch protection | ⚠️ Branch protection | ⚠️ Branch protection | ⚠️ Branch protection |
