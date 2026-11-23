#!/usr/bin/env python3
"""visor-bridge: expose a Visor network door (phone) as a tiny HTTP API for iPhone.

Chain:  iPhone Safari (PWA)  ->  this bridge (PC / NAS)  ->  Visor (Android)  ->  glasses
Nothing here talks to Meta. The only Meta touch is Visor's one-time login/link setup.

  python server.py                 # use ../config.json
  python server.py --mock          # self-test with a fake door, no phone needed
  python server.py --port 8787 --url ws://192.168.1.50:7333/rpc --token ABC
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from visor_client import VisorClient, VisorError  # noqa: E402

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG_PATH = os.path.join(BASE, "config.json")

CFG = {
    "visor": {"url": "ws://PHONE_IP:7333/rpc", "token": ""},
    "model": {
        "provider": "demo",
        "base_url": "http://127.0.0.1:11434/v1",
        "api_key": "",
        "model": "qwen2.5vl:7b",
        "vision": True,
        "system": "你是戴在用户脸上的智能眼镜助手。回答简短、直接、口语化。",
    },
    "server": {"port": 8787, "access_key": ""},
}

VISOR: VisorClient | None = None
VISOR_ERR: str | None = None
LOCK = threading.Lock()


def load_cfg():
    if os.path.exists(CFG_PATH):
        with open(CFG_PATH, encoding="utf-8-sig") as fh:
            user = json.load(fh)
        for k, v in user.items():
            if isinstance(v, dict):
                CFG.setdefault(k, {}).update(v)
            else:
                CFG[k] = v


def connect(url: str, token: str, timeout: float = 15.0) -> tuple[VisorClient | None, str | None]:
    cli = VisorClient(url, token or None, timeout=timeout)
    try:
        cli.start()
        return cli, None
    except Exception as exc:  # noqa: BLE001
        try:
            cli.close()
        except Exception:  # noqa: BLE001
            pass
        return None, f"{type(exc).__name__}: {exc}"


def door() -> VisorClient:
    if VISOR is None:
        raise VisorError("not_connected", VISOR_ERR or "door closed")
    return VISOR


def adb_pull_latest(serial: str | None = None) -> dict | None:
    """Pull the newest Visor photo off the phone with adb (used because
    captures.import hands back a content:// uri, not bytes)."""
    adb = CFG["visor"].get("adb") or "adb"
    serial = serial or CFG["visor"].get("serial")
    if not os.path.exists(adb) and not shutil.which(adb):
        return None
    base = [adb] + (["-s", serial] if serial else [])
    try:
        out = subprocess.run(base + ["shell", "ls -t /sdcard/Pictures/Visor | head -1"],
                             capture_output=True, text=True, timeout=20).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    if not out:
        return None
    local = os.path.join(tempfile.gettempdir(), "visor_%s.jpg" % time.strftime("%Y%m%d_%H%M%S"))
    try:
        subprocess.run(base + ["pull", "/sdcard/Pictures/Visor/" + out, local],
                       capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if not os.path.exists(local):
        return None
    with open(local, "rb") as fh:
        raw = fh.read()
    if len(raw) < 1024:
        return None
    return {"id": out, "mime": "image/jpeg", "data": base64.b64encode(raw).decode(),
            "source": "adb", "bytes": len(raw)}


def ensure_door() -> VisorClient:
    """Reconnect once if the door dropped (phone reboot, wifi flap, USB unplug)."""
    global VISOR, VISOR_ERR
    if VISOR is not None:
        return VISOR
    cli, err = connect(CFG["visor"]["url"], CFG["visor"].get("token", ""), timeout=6)
    VISOR, VISOR_ERR = cli, err
    if cli is None:
        raise VisorError("not_connected", err or "door closed")
    return cli


def capture(mode: str = "auto") -> dict:
    """One still image. Live-view frame is the fast path; else shoot + import."""
    cli = door()
    errors = []
    if mode in ("auto", "live"):
        try:
            r = cli.call("camera.live.photo", timeout=20)
            if r and r.get("data"):
                return {"id": None, "mime": r.get("mime", "image/jpeg"),
                        "data": r["data"], "source": "live"}
        except VisorError as exc:
            errors.append(f"live: {exc}")
    if mode in ("auto", "photo"):
        cap = cli.call("camera.photo", {"import": False}, timeout=45)
        cid = cap.get("id")
        time.sleep(1.2)
        try:
            imp = cli.call("captures.import", {"id": cid}, timeout=120)
            items = imp if isinstance(imp, list) else [imp]
            for it in items:
                if isinstance(it, dict) and it.get("data"):
                    return {"id": cid, "mime": it.get("mime", "image/jpeg"),
                            "data": it["data"], "source": "import"}
            errors.append("import: uri only (%s)" % (items[0].get("uri") if items and isinstance(items[0], dict) else imp))
        except VisorError as exc:
            errors.append(f"import: {exc}")
        pulled = adb_pull_latest()
        if pulled:
            pulled["id"] = cid or pulled.get("id")
            return pulled
        raise VisorError("failed", "capture produced no bytes", {"id": cid, "errors": errors})
    raise VisorError("failed", f"bad mode {mode}", {"errors": errors})


def _shrink(data_b64: str, mime: str, max_px: int = 1280) -> tuple[str, str]:
    """Downscale a base64 image so local vision models don't eat 300k tokens."""
    if not max_px:
        return data_b64, mime
    try:
        from PIL import Image  # optional
        import io
        raw = base64.b64decode(data_b64)
        im = Image.open(io.BytesIO(raw))
        im = im.convert("RGB")
        w, h = im.size
        if max(w, h) > max_px:
            k = max_px / float(max(w, h))
            im = im.resize((max(1, int(w * k)), max(1, int(h * k))), Image.LANCZOS)
        buf = io.BytesIO()
        im.save(buf, format="JPEG", quality=82, optimize=True)
        return base64.b64encode(buf.getvalue()).decode(), "image/jpeg"
    except Exception:  # noqa: BLE001
        return data_b64, mime


def ask_model(question: str, img: dict | None = None) -> dict:
    m = CFG["model"]
    started = time.time()
    if img:
        data, mime = _shrink(img["data"], img.get("mime", "image/jpeg"),
                             int(m.get("max_px", 1280)))
        img = {"mime": mime, "data": data}
    if m.get("provider") == "demo" or not m.get("base_url"):
        n = len(img["data"]) if img else 0
        return {"answer": f"[demo] 收到问题：{question!r}；附带图像 {n} 字符 base64。"
                          f"在 config.json 里把 model.provider 改成 openai 并填 base_url 即接真模型。",
                "model": "demo", "ms": int((time.time() - started) * 1000)}
    url = m["base_url"].rstrip("/") + "/chat/completions"
    if img:
        content = [{"type": "text", "text": question},
                   {"type": "image_url",
                    "image_url": {"url": f"data:{img['mime']};base64,{img['data']}"}}]
    else:
        content = question
    payload = {
        "model": m["model"],
        "messages": [{"role": "system", "content": m.get("system", "")},
                     {"role": "user", "content": content}],
        "temperature": 0.3,
        "max_tokens": m.get("max_tokens", 800),
        "stream": False,
    }
    headers = {"Content-Type": "application/json"}
    if m.get("api_key"):
        headers["Authorization"] = f"Bearer {m['api_key']}"
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=m.get("timeout", 120)) as r:
            data = json.loads(r.read().decode())
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")[:400]
        raise VisorError("model_http", f"{exc.code} {body}") from exc
    except urllib.error.URLError as exc:
        raise VisorError("model_unreachable", str(exc.reason)) from exc
    try:
        answer = data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        raise VisorError("model_shape", str(data)[:400]) from exc
    if isinstance(answer, list):
        answer = "".join(p.get("text", "") for p in answer if isinstance(p, dict))
    return {"answer": answer.strip(), "model": m["model"],
            "usage": data.get("usage"), "ms": int((time.time() - started) * 1000)}


class H(BaseHTTPRequestHandler):
    server_version = "visor-bridge/0.1"

    def log_message(self, fmt, *a):
        print("[http] " + (fmt % a), flush=True)

    # ---- helpers -----------------------------------------------------
    def _authed(self) -> bool:
        key = CFG["server"].get("access_key") or ""
        if not key:
            return True
        q = parse_qs(urlparse(self.path).query)
        if q.get("k", [""])[0] == key:
            return True
        return self.headers.get("X-Access-Key", "") == key

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _err(self, exc: Exception, code=502):
        if isinstance(exc, VisorError):
            self._json({"error": exc.message, "code": exc.code, "data": exc.data}, code)
        else:
            self._json({"error": f"{type(exc).__name__}: {exc}"}, code)

    def _body(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode() or "{}")
        except json.JSONDecodeError:
            return {}

    # ---- routes ------------------------------------------------------
    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            fp = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web", "index.html")
            with open(fp, "rb") as fh:
                body = fh.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if not self._authed():
            self._json({"error": "bad access_key"}, 401)
            return
        if path == "/api/status":
            st = {"visor_ok": VISOR is not None, "visor_error": VISOR_ERR,
                  "door": CFG["visor"]["url"], "model": CFG["model"].get("model"),
                  "provider": CFG["model"].get("provider")}
            try:
                cli = ensure_door()
                st["visor_ok"], st["visor_error"] = True, None
                st["glasses"] = cli.call("glasses.status", timeout=8)
            except VisorError as exc:
                st["visor_ok"], st["visor_error"] = False, exc.message
                st["glasses"] = {"error": exc.message}
            self._json(st)
            return
        if path == "/api/captures":
            try:
                self._json({"captures": door().call("captures.list", timeout=30)})
            except Exception as exc:  # noqa: BLE001
                self._err(exc)
            return
        if path == "/health":
            self._json({"ok": VISOR is not None})
            return
        self._json({"error": "not found", "path": path}, 404)

    def do_POST(self):
        if not self._authed():
            self._json({"error": "bad access_key"}, 401)
            return
        path = urlparse(self.path).path
        body = self._body()
        try:
            if path == "/api/capture":
                self._json(capture(body.get("mode") or "auto"))
            elif path == "/api/ask":
                q = (body.get("question") or "").strip() or "你看到了什么？"
                img = capture(body.get("mode") or "auto") if body.get("capture", True) else None
                out = ask_model(q, img)
                out["capture"] = {"id": img["id"], "mime": img["mime"], "source": img["source"]} if img else None
                self._json(out)
            elif path == "/api/video":
                act = body.get("action") or "start"
                if act == "start":
                    self._json(door().call("camera.video.start",
                                           {"kind": body.get("kind") or "video"}, timeout=30))
                else:
                    self._json(door().call("camera.video.stop", timeout=60))
            else:
                self._json({"error": "not found", "path": path}, 404)
        except Exception as exc:  # noqa: BLE001
            self._err(exc)


def lan_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int)
    ap.add_argument("--url")
    ap.add_argument("--token")
    ap.add_argument("--mock", action="store_true", help="self-test against a fake door")
    ap.add_argument("--no-connect", action="store_true")
    args = ap.parse_args()

    load_cfg()
    port = args.port or CFG["server"].get("port", 8787)

    global VISOR, VISOR_ERR
    if args.mock:
        from mock_visor import run as run_mock
        threading.Thread(target=run_mock, args=(7334,), daemon=True).start()
        time.sleep(0.4)
        url, token = "ws://127.0.0.1:7334/rpc", ""
        CFG["model"]["provider"] = "demo"
        print("[bridge] mock mode: fake door on 7334, model=demo", flush=True)
    else:
        url = args.url or CFG["visor"]["url"]
        token = args.token if args.token is not None else CFG["visor"].get("token", "")

    if not args.no_connect:
        VISOR, VISOR_ERR = connect(url, token)
        if VISOR:
            print(f"[bridge] door ok: {url} scopes={VISOR.hello.get('granted')}", flush=True)
        else:
            print(f"[bridge] door failed: {VISOR_ERR}", flush=True)

    srv = ThreadingHTTPServer(("0.0.0.0", port), H)
    print(f"[bridge] http://127.0.0.1:{port}/   iPhone: http://{lan_ip()}:{port}/", flush=True)
    if CFG["server"].get("access_key"):
        print("[bridge] access_key required (?k=...)", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if VISOR:
            VISOR.close()


if __name__ == "__main__":
    main()
