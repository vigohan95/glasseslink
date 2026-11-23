"""Visor network-door client: JSON-RPC 2.0 over WebSocket, stdlib only.

Door: ws://<phone-ip>:7333/rpc  with  Authorization: Bearer <token>
Framing: one JSON object per WebSocket text message (see VDK JSON-RPC docs).
"""
from __future__ import annotations

import base64
import json
import os
import socket
import struct
import threading
import time
from urllib.parse import urlparse

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class VisorError(RuntimeError):
    def __init__(self, code, message, data=None):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message
        self.data = data or {}


class _WS:
    def __init__(self, url: str, token: str | None, timeout: float = 10.0):
        u = urlparse(url)
        self.host = u.hostname or "127.0.0.1"
        self.port = u.port or 7333
        self.path = u.path or "/rpc"
        self.token = token
        self.sock = socket.create_connection((self.host, self.port), timeout=timeout)
        self.sock.settimeout(None)
        self._handshake()
        self._send_lock = threading.Lock()
        self._buf = b""

    def _handshake(self):
        key = base64.b64encode(os.urandom(16)).decode()
        lines = [
            f"GET {self.path} HTTP/1.1",
            f"Host: {self.host}:{self.port}",
            "Upgrade: websocket",
            "Connection: Upgrade",
            f"Sec-WebSocket-Key: {key}",
            "Sec-WebSocket-Version: 13",
            "User-Agent: visor-bridge/0.1",
        ]
        if self.token:
            lines.append(f"Authorization: Bearer {self.token}")
        self.sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise VisorError("ws_closed", "closed during handshake")
            head += chunk
        head, _, rest = head.partition(b"\r\n\r\n")
        status = head.split(b"\r\n", 1)[0].decode(errors="replace")
        if "101" not in status:
            raise VisorError("ws_handshake", status)
        self._buf = rest

    # ---- framing -----------------------------------------------------
    def send_text(self, text: str):
        payload = text.encode()
        header = bytearray([0x81])
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        mask = os.urandom(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        with self._send_lock:
            self.sock.sendall(bytes(header) + masked)

    def _read_exact(self, n: int) -> bytes:
        while len(self._buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise VisorError("ws_closed", "connection closed")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def recv_message(self) -> str | None:
        fragments = []
        while True:
            b1, b2 = self._read_exact(2)
            fin = b1 & 0x80
            opcode = b1 & 0x0F
            masked = b2 & 0x80
            n = b2 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read_exact(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read_exact(8))[0]
            mask = self._read_exact(4) if masked else None
            data = self._read_exact(n)
            if mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if opcode == 0x8:
                raise VisorError("ws_closed", "server sent close")
            if opcode == 0x9:
                self._pong(data)
                continue
            if opcode == 0xA:
                continue
            if opcode in (0x1, 0x2, 0x0):
                fragments.append(data)
                if fin:
                    return b"".join(fragments).decode(errors="replace")

    def _pong(self, data: bytes):
        header = bytearray([0x8A])
        n = len(data)
        header.append(0x80 | n)
        mask = os.urandom(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        with self._send_lock:
            self.sock.sendall(bytes(header) + masked)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class VisorClient:
    """Thread-safe JSON-RPC client with a reader thread and a topic ring buffer."""

    def __init__(self, url: str, token: str | None = None, timeout: float = 10.0):
        self.url = url
        self.token = token
        self.timeout = timeout
        self._ws = None
        self._id = 0
        self._lock = threading.Lock()
        self._pending: dict[int, list] = {}
        self._events: list[dict] = []
        self._subs: dict[int, str] = {}
        self.hello: dict = {}
        self._running = False

    # ---- lifecycle ---------------------------------------------------
    def start(self) -> dict:
        self._ws = _WS(self.url, self.token, self.timeout)
        self._running = True
        threading.Thread(target=self._reader, daemon=True).start()
        self.hello = self.call("kit.hello", {"protocol": 1, "kit": "visor-bridge 0.1"}, timeout=8)
        return self.hello

    def close(self):
        self._running = False
        if self._ws:
            self._ws.close()

    # ---- io ----------------------------------------------------------
    def _reader(self):
        try:
            while self._running:
                raw = self._ws.recv_message()
                if raw is None:
                    continue
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                mid = msg.get("id")
                if mid is not None and mid in self._pending:
                    self._pending[mid][1] = msg
                    self._pending[mid][0].set()
                elif msg.get("method") == "kit.event":
                    p = msg.get("params", {})
                    item = {
                        "topic": self._subs.get(p.get("subscription"), "?"),
                        "event": p.get("event"),
                        "t": time.time(),
                    }
                    self._events.append(item)
                    del self._events[:-200]
                elif msg.get("method") == "kit.ended":
                    p = msg.get("params", {})
                    self._events.append({
                        "topic": self._subs.get(p.get("subscription"), "?"),
                        "event": {"ended": True, "failure": p.get("failure")},
                        "t": time.time(),
                    })
        except Exception as exc:  # noqa: BLE001
            self._running = False
            err = VisorError("ws_closed", str(exc))
            for ev, slot in list(self._pending.values()):
                slot[1] = {"error": {"message": str(err)}}
                ev.set()

    def call(self, method: str, params: dict | None = None, timeout: float | None = None):
        if not self._running:
            raise VisorError("not_connected", "visor door is not connected")
        with self._lock:
            self._id += 1
            mid = self._id
        ev = threading.Event()
        slot = [ev, None]
        self._pending[mid] = slot
        body = {"jsonrpc": "2.0", "id": mid, "method": method, "params": params or {}}
        self._ws.send_text(json.dumps(body, separators=(",", ":")))
        if not ev.wait(timeout or self.timeout):
            self._pending.pop(mid, None)
            raise VisorError("timeout", f"{method} timed out")
        self._pending.pop(mid, None)
        msg = slot[1] or {}
        if "error" in msg:
            e = msg["error"] or {}
            raise VisorError(e.get("code", -32000), e.get("message", "call failed"), e.get("data"))
        return msg.get("result")

    def subscribe(self, topic: str, params: dict | None = None) -> int:
        res = self.call("kit.subscribe", {"topic": topic, "params": params or {}})
        sub = int(res["subscription"])
        self._subs[sub] = topic
        return sub

    def events(self, topic: str | None = None, since: float | None = None) -> list[dict]:
        out = [e for e in self._events if topic is None or e["topic"] == topic]
        if since is not None:
            out = [e for e in out if e["t"] >= since]
        return out
