"""A fake Visor network door, for testing the bridge without glasses or a phone.

Implements the documented JSON-RPC methods used by server.py:
  kit.hello, glasses.status, camera.photo, captures.list, captures.import,
  camera.live.photo, camera.video.start, camera.video.stop, captures.available (topic)

Run:  python mock_visor.py [port]
"""
from __future__ import annotations

import base64
import hashlib
import json
import socket
import struct
import threading
import time
import zlib

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def make_png(w: int = 320, h: int = 240, label: bytes = b"") -> bytes:
    rows = []
    for y in range(h):
        row = bytearray([0])
        for x in range(w):
            row += bytes(((x * 255) // w, (y * 255) // h, 150))
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    body = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
    if label:
        body += chunk(b"tEXt", b"Note\x00" + label)
    body += chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
    return body


class MockState:
    def __init__(self):
        self.captures = []
        self.seq = 0

    def new_capture(self, kind="photo"):
        self.seq += 1
        png = make_png(label=f"mock-{self.seq}".encode())
        cap = {
            "id": f"cap{self.seq}",
            "type": kind,
            "time": int(time.time() * 1000),
            "size": len(png),
            "uri": None,
        }
        self.captures.append((cap, png))
        return cap


STATE = MockState()


def handle(method: str, params: dict):
    if method == "kit.hello":
        return {
            "protocol": 1,
            "visor": "mock-0.1",
            "granted": ["state", "camera", "captures"],
            "methods": ["glasses.status", "camera.photo", "captures.list", "captures.import",
                        "camera.live.photo", "camera.video.start", "camera.video.stop"],
            "topics": ["captures.available"],
        }
    if method == "glasses.status":
        return {"paired": True, "link": "connected", "battery": 87, "worn": True,
                "firmware": "mock", "model": "Ray-Ban Meta Gen 2 (mock)"}
    if method == "camera.photo":
        cap = STATE.new_capture()
        if params.get("import"):
            cap["uri"] = f"file:///sdcard/Pictures/Visor/{cap['id']}.png"
        return cap
    if method == "captures.list":
        return [c for c, _ in STATE.captures]
    if method == "captures.import":
        cid = params.get("id")
        for cap, png in STATE.captures:
            if cap["id"] == cid:
                out = dict(cap)
                out["mime"] = "image/png"
                out.pop("uri", None)
                out["data"] = base64.b64encode(png).decode()
                return out
        raise KeyError(cid)
    if method == "camera.live.photo":
        png = make_png(label=b"live")
        return {"mime": "image/png", "data": base64.b64encode(png).decode()}
    if method in ("camera.video.start", "camera.video.stop"):
        return {}
    if method == "kit.subscribe":
        return {"subscription": params.get("_id", 1)}
    raise KeyError(method)


def recv_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError
        buf += chunk
    return buf


def read_frame(conn):
    b1, b2 = recv_exact(conn, 2)
    opcode = b1 & 0x0F
    masked = b2 & 0x80
    n = b2 & 0x7F
    if n == 126:
        n = struct.unpack(">H", recv_exact(conn, 2))[0]
    elif n == 127:
        n = struct.unpack(">Q", recv_exact(conn, 8))[0]
    mask = recv_exact(conn, 4) if masked else None
    data = recv_exact(conn, n)
    if mask:
        data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    return opcode, data


def send_text(conn, text: str):
    payload = text.encode()
    n = len(payload)
    head = bytearray([0x81])
    if n < 126:
        head.append(n)
    elif n < 65536:
        head.append(126)
        head += struct.pack(">H", n)
    else:
        head.append(127)
        head += struct.pack(">Q", n)
    conn.sendall(bytes(head) + payload)


def serve_client(conn, addr):
    try:
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = conn.recv(4096)
            if not chunk:
                return
            head += chunk
        text = head.decode(errors="replace")
        key = ""
        for line in text.split("\r\n"):
            if line.lower().startswith("sec-websocket-key:"):
                key = line.split(":", 1)[1].strip()
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        conn.sendall((
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
        ).encode())
        while True:
            opcode, data = read_frame(conn)
            if opcode == 0x8:
                return
            if opcode == 0x9:
                continue
            try:
                req = json.loads(data.decode())
            except json.JSONDecodeError:
                continue
            mid = req.get("id")
            try:
                result = handle(req.get("method", ""), req.get("params") or {})
                resp = {"jsonrpc": "2.0", "id": mid, "result": result}
            except KeyError as exc:
                resp = {"jsonrpc": "2.0", "id": mid,
                        "error": {"code": -32601, "message": f"unknown method {exc}"}}
            send_text(conn, json.dumps(resp))
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def run(port: int = 7334):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(8)
    print(f"[mock] visor network door on ws://0.0.0.0:{port}/rpc", flush=True)
    while True:
        conn, addr = srv.accept()
        threading.Thread(target=serve_client, args=(conn, addr), daemon=True).start()


if __name__ == "__main__":
    import sys
    run(int(sys.argv[1]) if len(sys.argv) > 1 else 7334)
