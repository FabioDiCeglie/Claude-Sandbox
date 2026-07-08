#!/usr/bin/env python3
"""
Docker socket proxy — blocks dangerous container-creation flags.

Listens on TCP :2375, proxies to /var/run/docker.sock.
Handles HTTP/1.1 keep-alive properly: inspects EVERY request on a
connection, not just the first one.
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


# ── buffered socket ───────────────────────────────────────────────────────────

class BufSock:
    """Socket with a read buffer so we can do framed HTTP reads."""

    def __init__(self, sock: socket.socket):
        self._s   = sock
        self._buf = b""

    # ── reads ──────────────────────────────────────────────────────────────

    def read_until(self, delim: bytes, limit: int = 131072):
        while delim not in self._buf:
            chunk = self._s.recv(4096)
            if not chunk:
                return None
            self._buf += chunk
            if len(self._buf) > limit:
                break
        idx = self._buf.find(delim)
        if idx == -1:
            out, self._buf = self._buf, b""
            return out
        end = idx + len(delim)
        out, self._buf = self._buf[:end], self._buf[end:]
        return out

    def read_exactly(self, n: int) -> bytes:
        while len(self._buf) < n:
            chunk = self._s.recv(min(65536, n - len(self._buf)))
            if not chunk:
                break
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def read_chunked(self) -> bytes:
        """Read a complete HTTP chunked body; return raw wire bytes (for requests)."""
        raw = b""
        while True:
            size_line = self.read_until(b"\r\n")
            if not size_line:
                break
            raw += size_line
            size = int(size_line.strip().split(b";")[0], 16)
            if size == 0:
                trailer = self.read_until(b"\r\n")
                raw += trailer or b""
                break
            raw += self.read_exactly(size)
            raw += self.read_exactly(2)   # CRLF after chunk
        return raw

    def stream_chunked_to(self, dst: "BufSock"):
        """Stream chunked response body to dst as chunks arrive (no buffering)."""
        while True:
            size_line = self.read_until(b"\r\n")
            if not size_line:
                break
            dst.sendall(size_line)
            size = int(size_line.strip().split(b";")[0], 16)
            if size == 0:
                trailer = self.read_until(b"\r\n")
                dst.sendall(trailer or b"")
                break
            dst.sendall(self.read_exactly(size))
            dst.sendall(self.read_exactly(2))

    # ── writes / misc ──────────────────────────────────────────────────────

    def sendall(self, data: bytes):
        self._s.sendall(data)

    def flush_buf(self) -> bytes:
        """Return and clear any internally buffered data."""
        out, self._buf = self._buf, b""
        return out

    def raw(self) -> socket.socket:
        return self._s

    def close(self):
        try:
            self._s.close()
        except Exception:
            pass


# ── helpers ───────────────────────────────────────────────────────────────────

def _get_header(raw: bytes, name: str) -> bytes:
    m = re.search(rb"(?i)" + name.encode() + rb":\s*([^\r\n]+)", raw)
    return m.group(1).strip() if m else b""


def _pipe(src: socket.socket, dst: socket.socket, done: threading.Event):
    try:
        while not done.is_set():
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        done.set()


def _pipe_both(a: socket.socket, b: socket.socket):
    done = threading.Event()
    threading.Thread(target=_pipe, args=(a, b, done), daemon=True).start()
    threading.Thread(target=_pipe, args=(b, a, done), daemon=True).start()
    done.wait()


def _deny(sock: BufSock, reason: str):
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


# ── per-connection handler ────────────────────────────────────────────────────

def handle(client_raw: socket.socket):
    client = BufSock(client_raw)

    ds_raw = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        ds_raw.connect(DOCKER_SOCKET)
    except Exception as exc:
        _deny(client, f"cannot reach Docker daemon: {exc}")
        client.close()
        return
    ds = BufSock(ds_raw)

    try:
        while True:
            # ── request headers ───────────────────────────────────────────
            req_head = client.read_until(b"\r\n\r\n")
            if not req_head:
                break

            first_line = req_head.split(b"\r\n")[0].decode("utf-8", errors="replace")
            parts  = first_line.split(" ")
            method = parts[0] if parts else ""
            path   = parts[1] if len(parts) > 1 else ""

            is_create = method == "POST" and bool(re.search(r"/containers/create", path))

            # ── request body ──────────────────────────────────────────────
            req_body = b""
            cl = _get_header(req_head, "Content-Length")
            te = _get_header(req_head, "Transfer-Encoding")

            if cl:
                req_body = client.read_exactly(int(cl))
            elif b"chunked" in te.lower():
                req_body = client.read_chunked()

            # ── policy check ──────────────────────────────────────────────
            if is_create:
                reason = check_create(req_body)
                if reason:
                    print(f"[BLOCKED] {path} — {reason}", flush=True)
                    _deny(client, reason)
                    break
                print(f"[ALLOWED] {path}", flush=True)

            # ── forward request to Docker ─────────────────────────────────
            ds.sendall(req_head + req_body)

            # ── response headers ──────────────────────────────────────────
            resp_head = ds.read_until(b"\r\n\r\n")
            if not resp_head:
                break

            first_resp   = resp_head.split(b"\r\n")[0].decode("utf-8", errors="replace")
            status_parts = first_resp.split(" ")
            status_code  = int(status_parts[1]) if len(status_parts) > 1 else 0

            client.sendall(resp_head)

            # ── response body ─────────────────────────────────────────────
            if status_code == 101:
                # Protocol upgrade (docker exec -it, attach) → raw pipe
                leftover = ds.flush_buf()
                if leftover:
                    client.sendall(leftover)
                _pipe_both(client.raw(), ds.raw())
                return

            if status_code not in (204, 304) and method != "HEAD":
                resp_cl = _get_header(resp_head, "Content-Length")
                resp_te = _get_header(resp_head, "Transfer-Encoding")

                if resp_cl:
                    remaining = int(resp_cl)
                    while remaining > 0:
                        chunk = ds.read_exactly(min(65536, remaining))
                        if not chunk:
                            break
                        client.sendall(chunk)
                        remaining -= len(chunk)

                elif b"chunked" in resp_te.lower():
                    ds.stream_chunked_to(client)

                else:
                    # No Content-Length and not chunked → streaming response
                    # (build output, logs, wait, raw-stream attach, …)
                    leftover = ds.flush_buf()
                    if leftover:
                        client.sendall(leftover)
                    _pipe_both(client.raw(), ds.raw())
                    return

            # ── keep-alive decision ───────────────────────────────────────
            resp_conn = _get_header(resp_head, "Connection").lower()
            req_conn  = _get_header(req_head,  "Connection").lower()
            if b"close" in resp_conn or b"close" in req_conn:
                break
            if first_line.upper().endswith("HTTP/1.0") and b"keep-alive" not in req_conn:
                break

    except Exception:
        pass
    finally:
        ds.close()
        client.close()


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
