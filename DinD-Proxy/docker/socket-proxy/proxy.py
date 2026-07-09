#!/usr/bin/env python3
"""
Docker socket proxy — blocks --privileged and dangerous container flags.

Each TCP connection carries exactly one request/response pair. We force
Connection: close so the daemon closes after each response, which means
we never need to parse Content-Length, chunked encoding, or keep-alive
state. Just pipe daemon→client until the daemon closes; done.
"""
import json
import re
import socket
import threading

DOCKER_SOCKET = "/var/run/docker.sock"
LISTEN_PORT   = 2375

BLOCKED_CAPS = {
    "SYS_ADMIN", "SYS_PTRACE", "SYS_MODULE", "SYS_RAWIO",
    "SYS_TIME",  "NET_ADMIN",  "DAC_READ_SEARCH", "MKNOD", "AUDIT_WRITE",
}


# ── policy ────────────────────────────────────────────────────────────────────

def check_create(body_bytes: bytes):
    """Return an error string if the request must be blocked, else None."""
    try:
        body = json.loads(body_bytes)
    except Exception:
        return None
    hc = body.get("HostConfig") or {}
    if hc.get("Privileged"):
        return "privileged containers are not allowed"
    bad_caps = set(hc.get("CapAdd") or []) & BLOCKED_CAPS
    if bad_caps:
        return f"dangerous capabilities not allowed: {sorted(bad_caps)}"
    if hc.get("NetworkMode") == "host":
        return "host network mode is not allowed"
    if hc.get("PidMode") == "host":
        return "host PID mode is not allowed"
    if hc.get("IpcMode") == "host":
        return "host IPC mode is not allowed"
    return None


# ── helpers ───────────────────────────────────────────────────────────────────

def _deny(sock: socket.socket, reason: str):
    msg  = json.dumps({"message": reason})
    resp = (
        f"HTTP/1.1 403 Forbidden\r\n"
        f"Content-Type: application/json\r\n"
        f"Content-Length: {len(msg)}\r\n"
        f"Connection: close\r\n"
        f"\r\n{msg}"
    ).encode()
    try:
        sock.sendall(resp)
    except Exception:
        pass


def _pipe(src: socket.socket, dst: socket.socket):
    """Copy src→dst until src closes or an error occurs."""
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass


# ── per-connection handler ────────────────────────────────────────────────────

def handle(client: socket.socket):
    ds = None
    try:
        # ── read request headers ──────────────────────────────────────────
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = client.recv(4096)
            if not chunk:
                return
            buf += chunk
            if len(buf) > 1 << 20:   # 1 MB sanity cap
                return

        sep      = buf.index(b"\r\n\r\n") + 4
        req_head = buf[:sep]
        leftover = buf[sep:]

        first_line = req_head.split(b"\r\n")[0].decode("utf-8", errors="replace")
        parts  = first_line.split()
        method = parts[0] if parts else ""
        path   = parts[1] if len(parts) > 1 else ""

        is_create = method == "POST" and "/containers/create" in path

        # ── read request body (needed for policy check on create) ─────────
        req_body = leftover
        cl_m = re.search(rb"(?i)content-length:\s*(\d+)", req_head)
        if cl_m:
            needed = int(cl_m.group(1)) - len(leftover)
            while needed > 0:
                chunk = client.recv(min(65536, needed))
                if not chunk:
                    break
                req_body += chunk
                needed -= len(chunk)

        # ── policy check ──────────────────────────────────────────────────
        if is_create:
            reason = check_create(req_body)
            if reason:
                print(f"[BLOCKED] {path} — {reason}", flush=True)
                _deny(client, reason)
                return
            print(f"[ALLOWED] {path}", flush=True)

        # ── rewrite Connection header → close ─────────────────────────────
        # Forces the daemon to close after this response, so we never need
        # to parse Content-Length, chunked encoding, or keep-alive state.
        req_head = re.sub(rb"(?im)^connection:[ \t]*[^\r\n]*\r\n", b"", req_head)
        req_head = req_head[:-2] + b"connection: close\r\n\r\n"

        # ── connect to Docker and forward request ─────────────────────────
        ds = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        ds.connect(DOCKER_SOCKET)
        ds.sendall(req_head + req_body)

        # ── stream response back to client ────────────────────────────────
        # client→daemon in a background thread (needed for 101 upgrades /
        # interactive exec); daemon→client in this thread — blocks until
        # the daemon closes the connection (response complete, or container
        # exited for streaming attach/logs).
        threading.Thread(target=_pipe, args=(client, ds), daemon=True).start()
        _pipe(ds, client)

    except Exception:
        pass
    finally:
        if ds:
            try:
                ds.close()
            except Exception:
                pass
        try:
            client.close()
        except Exception:
            pass


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", LISTEN_PORT))
    srv.listen(64)
    print(f"[socket-proxy] listening on :{LISTEN_PORT} → {DOCKER_SOCKET}", flush=True)
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
