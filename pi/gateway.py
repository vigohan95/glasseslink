"""Glasses gateway for a Linux box: glasses -> HTTP/PWA -> your phone.

This replaces the Android phone in the daily loop: the box speaks AirShield to
the glasses over BLE and serves the same tiny web UI the bridge served, so the
iPhone (or any browser) is the only thing you touch.

    sudo python3 gateway.py --address AA:BB:CC:DD:EE:FF
    # then open http://<box-ip>:8787/

Endpoints are the same five the Android bridge exposed, so `bridge/web/index.html`
works unchanged:

    GET  /                 the PWA
    GET  /api/status       link/session state
    GET  /api/captures     capture list from svc18
    POST /api/capture      pull the newest photo over svc20 (base64 in reply)
    POST /api/ask          {"question": "...", "capture": true} -> your model

Requires: python3-cryptography, BlueZ >= 5.55, kernel >= 5.10 (LE CoC).
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import session as S            # noqa: E402
from ownerkey import find_owner  # noqa: E402

WEB = os.path.join(HERE, "..", "bridge", "web", "index.html")
CAPTURE_DIR = os.path.join(HERE, "captures")


# ---------------------------------------------------------------- model call
def ask_model(cfg: dict, question: str, image_b64: str | None) -> dict:
    import urllib.request

    model = cfg.get("model", {})
    base = model.get("base_url", "http://127.0.0.1:11434/v1").rstrip("/")
    content: list[dict] = [{"type": "text", "text": question}]
    if image_b64 and model.get("vision", True):
        content.append({"type": "image_url", "image_url": {
            "url": f"data:image/jpeg;base64,{image_b64}"}})
    body = json.dumps({
        "model": model.get("model", "gemma3:4b"),
        "messages": [{"role": "user", "content": content}],
        "max_tokens": model.get("max_tokens", 500),
        "stream": False,
    }).encode()
    req = urllib.request.Request(
        base + "/chat/completions", data=body,
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {model.get('api_key', 'none')}"})
    with urllib.request.urlopen(req, timeout=model.get("timeout", 180)) as r:
        doc = json.loads(r.read().decode())
    return {"answer": doc["choices"][0]["message"]["content"].strip(),
            "model": doc.get("model", model.get("model"))}


def shrink(image: bytes, max_px: int = 1280) -> str:
    try:
        from PIL import Image
        import io
        im = Image.open(io.BytesIO(image))
        im.thumbnail((max_px, max_px))
        out = io.BytesIO()
        im.convert("RGB").save(out, "JPEG", quality=82)
        return base64.b64encode(out.getvalue()).decode()
    except Exception:
        return base64.b64encode(image).decode()


# ------------------------------------------------------------------- gateway
class Gateway:
    def __init__(self, address: str, owner_path: str | None, cfg: dict):
        self.address = address
        self.owner_path = owner_path
        self.cfg = cfg
        self.lock = threading.Lock()
        self.sess: S.GlassesSession | None = None
        self.last_error: str | None = None
        self.logs: list[str] = []
        self.battery = None
        os.makedirs(CAPTURE_DIR, exist_ok=True)

    # -- link management -------------------------------------------------
    def connect(self) -> S.GlassesSession:
        from transport_bluez import LecocoTransport

        owner = find_owner(self.owner_path)
        t = LecocoTransport(address=self.address, psm=128, timeout=8.0)
        sess = S.GlassesSession(t, owner, log=self._log)
        sess.handshake(timeout=12)
        self.sess = sess
        self.last_error = None
        return sess

    def ensure(self) -> S.GlassesSession:
        if self.sess is not None:
            return self.sess
        return self.connect()

    def _log(self, line: str):
        self.logs.append(line)
        del self.logs[:-400]

    def status(self) -> dict:
        """Shape matches bridge/web/index.html so the same PWA works unchanged."""
        try:
            owner = find_owner(self.owner_path)
            owner_id = owner.public_id.hex()[:16]
            owner_err = None
        except Exception as exc:                       # noqa: BLE001
            owner_id, owner_err = None, f"owner key: {exc}"
        connected = self.sess is not None
        model = self.cfg.get("model", {})
        return {
            "visor_ok": connected and owner_err is None,
            "visor_error": self.last_error or owner_err,
            "door": f"ble:{self.address or 'unset'}",
            "model": model.get("model", "gemma3:4b"),
            "provider": model.get("provider", "openai"),
            "owner_public_id": owner_id,
            "glasses": {
                "model": self.cfg.get("glasses_model", "Ray-Ban Meta (Gen 2)"),
                "link": "connected" if connected else "down",
                "battery": self.battery,
                "address": self.address,
            },
        }

    # -- captures --------------------------------------------------------
    def captures(self) -> list[dict]:
        with self.lock:
            sess = self.ensure()
            caps = sess.capture_list()
            return [{"handle": c.handle, "kind": c.kind,
                     "time_ns": c.timestamp_ns,
                     "assets": c.assets} for c in caps]

    def latest_photo(self) -> dict:
        with self.lock:
            sess = self.ensure()
            caps = [c for c in sess.capture_list() if c.is_photo and c.still_assets()]
            if not caps:
                return {"ok": False, "error": "no photo on the glasses"}
            cap = max(caps, key=lambda c: c.timestamp_ns or 0)
            asset = max(cap.still_assets(), key=lambda a: a.get("size", 0))
            sess.request_asset(cap.handle, asset["uuid"])
            offer, data = sess.receive_file(chunk_size_hint=1024)
            name = (offer or {}).get("name") or f"{cap.handle}.jpg"
            path = os.path.join(CAPTURE_DIR, name)
            with open(path, "wb") as fh:
                fh.write(data)
            return {"ok": True, "source": "ble", "mime": "image/jpeg",
                    "id": name, "path": path, "name": name, "bytes": len(data),
                    "b64": base64.b64encode(data).decode()}


# -------------------------------------------------------------------- server
def make_handler(gw: Gateway):
    class Handler(BaseHTTPRequestHandler):
        server_version = "GlassesGateway/1.0"

        def log_message(self, fmt, *args):
            pass

        def _json(self, obj, code=200):
            raw = json.dumps(obj, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def _body(self) -> dict:
            n = int(self.headers.get("Content-Length") or 0)
            if not n:
                return {}
            try:
                return json.loads(self.rfile.read(n).decode())
            except Exception:
                return {}

        def do_GET(self):
            if self.path in ("/", "/index.html"):
                try:
                    with open(WEB, "rb") as fh:
                        raw = fh.read()
                except OSError:
                    raw = b"<h1>index.html missing</h1>"
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
                return
            if self.path == "/api/status":
                return self._json(gw.status())
            if self.path == "/api/captures":
                try:
                    return self._json({"ok": True, "captures": gw.captures()})
                except Exception as exc:               # noqa: BLE001
                    gw.last_error = f"{type(exc).__name__}: {exc}"
                    return self._json({"ok": False, "error": gw.last_error}, 502)
            if self.path == "/api/logs":
                return self._json({"logs": gw.logs[-120:]})
            return self._json({"error": "not found"}, 404)

        def do_POST(self):
            body = self._body()
            if self.path == "/api/capture":
                try:
                    return self._json(gw.latest_photo())
                except Exception as exc:               # noqa: BLE001
                    gw.last_error = f"{type(exc).__name__}: {exc}"
                    return self._json({"ok": False, "error": gw.last_error}, 502)
            if self.path == "/api/ask":
                question = (body.get("question") or "").strip()
                if not question:
                    return self._json({"error": "question is empty"}, 400)
                image_b64 = None
                try:
                    if body.get("capture", True):
                        shot = gw.latest_photo()
                        if shot.get("ok"):
                            image_b64 = shrink(shot["b64"] and base64.b64decode(shot["b64"]))
                    t0 = time.time()
                    out = ask_model(gw.cfg, question, image_b64)
                    out["ms"] = int((time.time() - t0) * 1000)
                    return self._json(out)
                except Exception as exc:               # noqa: BLE001
                    gw.last_error = f"{type(exc).__name__}: {exc}"
                    return self._json({"error": gw.last_error}, 502)
            return self._json({"error": "not found"}, 404)

    return Handler


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--address", required=False, default="",
                    help="glasses BLE address, e.g. 80:AA:1C:98:18:0B")
    ap.add_argument("--owner", default=None, help="owner-export.json path")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--config", default=os.path.join(HERE, "..", "config.json"))
    args = ap.parse_args()

    cfg = {}
    try:
        with open(args.config, encoding="utf-8-sig") as fh:
            cfg = json.load(fh)
    except OSError:
        print(f"(no config at {args.config}; model calls will use defaults)")

    gw = Gateway(args.address, args.owner, cfg)
    srv = ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(gw))
    print(f"gateway on http://0.0.0.0:{args.port}/  glasses={args.address or 'unset'}")
    print("open /api/logs to watch the link; Ctrl+C to stop")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if gw.sess:
            gw.sess.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
