"""Become the owner of a Ray-Ban Meta pair from a Linux box — no Android app.

This is the Meta half of the flow: log in once, trade the login for an AR token,
then get Meta to sign two ownership receipts. The glasses half lives in
``session.py`` (svc36) and the glue in ``provision.py``.

Every constant below was read out of the Visor APK / its source (AGPL-3.0), which
is the reference implementation of this same flow:

  core/identity/token/WebLogin.kt   app id, authorize + token-exchange endpoints
  core/identity/token/Frla.kt       ar.graph.meta.com/login, AR app token
  core/identity/provision/Provision.kt  graph.facebook-hardware.com pair_request/pair

Wire shapes:
  Receipt        {1: signature, 2: JSON body}          (svc36 0x2002/0x2003/0x2004)
  pair_request   form-urlencoded, gzip'd, HW app token + user AR token
  pair           same, plus the glasses' pending receipt

CLI:
  python -P meta_identity.py login --store DIR        # prints a URL, reads the redirect back
  python -P meta_identity.py whoami --store DIR
"""

from __future__ import annotations

import base64
import gzip
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

import airshield as A

# --- Meta app identities (public client ids baked into the Meta AI app) ------
META_APP_ID = "934401142814369"
REDIRECT_URI = "https://accounts.meta.com/native/oidc/redirect/metaai"
AUTHORIZE_URL = "https://accounts.meta.com/oidc/"
EXCHANGE_URL = "https://api.accounts.meta.com/native/oidc/token-exchange/"
AR_HOST = "ar.graph.meta.com"
AR_LOGIN_URL = f"https://{AR_HOST}/login"
HW_GRAPH = "https://graph.facebook-hardware.com"
PAIR_PROTOCOL_VERSION = "4"

# Client tokens shipped in the Meta AI app (BuildConfig.META_AR_TOKEN / _HW_TOKEN
# in Visor; the same strings are in the official APK).
AR_APP_TOKEN = os.environ.get("VISOR_META_AR_TOKEN", "AR|306760944872162")
HW_APP_TOKEN = os.environ.get("VISOR_META_HW_TOKEN", "HW|1312539125771114")

META_UA = ("Dalvik/2.1.0 (Linux; U; Android 15) "
           "[FBAN/Stella;FBAV/289.0.0.25.162;FBSN/Android;FBSV/15;FBLC/en_US]")

TIMEOUT = 45


class MetaError(RuntimeError):
    pass


# --------------------------------------------------------------------- http
def _post(url: str, fields: dict[str, str], *, gzipped: bool = False,
          authorization: str | None = None) -> dict:
    body = urllib.parse.urlencode(fields).encode("ascii")
    headers = {
        "Content-Type": "application/x-www-form-urlencoded",
        "User-Agent": META_UA,
        "Accept-Encoding": "gzip",
    }
    if authorization:
        headers["Authorization"] = authorization
    if gzipped:
        body = gzip.compress(body)
        headers["Content-Encoding"] = "gzip"
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            raw = r.read()
            status = r.status
    except urllib.error.HTTPError as e:
        raw, status = e.read(), e.code
    except Exception as e:                                    # noqa: BLE001
        raise MetaError(f"{url}: cannot reach Meta: {e}") from e
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        raise MetaError(f"{url}: HTTP {status}, not JSON: {raw[:200]!r}") from None


def _problem(payload: dict) -> str | None:
    err = payload.get("error")
    if isinstance(err, dict):
        return err.get("message") or json.dumps(err)[:300]
    if err:
        return str(err)[:300]
    for k in ("title", "detail", "message"):
        if payload.get(k):
            return f"{k}={payload[k]}"
    return None


# ------------------------------------------------------------- login (OIDC)
def authorize_url(state: str | None = None) -> str:
    """The URL to open in any browser, on any device. Log in, then copy where it lands."""
    state = state or base64.urlsafe_b64encode(secrets.token_bytes(16)).decode().rstrip("=")
    query = urllib.parse.urlencode({
        "app_id": META_APP_ID,
        "scope": "openid",
        "response_type": "code",
        "redirect_uri": REDIRECT_URI,
        "state": state,
    })
    return f"{AUTHORIZE_URL}?{query}"


def code_from_redirect(pasted: str) -> str:
    """Pull ``code`` out of the redirect URL (or accept a bare code)."""
    pasted = pasted.strip()
    if not pasted:
        raise MetaError("nothing pasted")
    if "code=" in pasted:
        q = urllib.parse.urlparse(pasted).query or pasted.split("?", 1)[-1]
        code = urllib.parse.parse_qs(q).get("code", [""])[0]
        if code:
            return code
    if "://" not in pasted and len(pasted) > 20:
        return pasted
    raise MetaError("no code= in what you pasted")


def exchange_code(code: str) -> str:
    """Auth code -> FRLA (a Meta login session token)."""
    payload = _post(EXCHANGE_URL, {
        "mt_app_id": META_APP_ID,
        "oidc_auth_code": code,
        "redirect_uri": REDIRECT_URI,
    })
    token = payload.get("access_token") or ""
    if not token or not payload.get("user_id"):
        raise MetaError(f"token-exchange refused: {_problem(payload) or sorted(payload)}")
    return token


def exchange_frla(frla: str) -> str:
    """FRLA -> AR access token, the one every AR Graph call authorizes with."""
    payload = _post(AR_LOGIN_URL, {
        "access_token": AR_APP_TOKEN,
        "frl_access_token": frla,
        "logging_session_id": str(uuid.uuid4()),
        "device_id": str(uuid.uuid4()),
        "format": "json",
        "generate_session_cookies": "1",
        "generate_analytics_claim": "1",
    })
    token = payload.get("access_token") or ""
    if not token:
        raise MetaError(f"ar login refused: {_problem(payload) or sorted(payload)}")
    return token


# ------------------------------------------------------- ownership receipts
class Receipt:
    """An ownership receipt as svc36 carries it: {1: signature, 2: JSON body}."""

    __slots__ = ("signature", "body")

    def __init__(self, signature: bytes, body: bytes):
        self.signature = signature
        self.body = body

    def encode(self) -> bytes:
        return A.pb_bytes(1, self.signature) + A.pb_bytes(2, self.body)

    @classmethod
    def decode(cls, data: bytes) -> "Receipt":
        f = A.pb_parse(data)
        return cls(signature=f.get(1, [b""])[0], body=f.get(2, [b""])[0])

    @property
    def info(self) -> dict:
        try:
            return json.loads(self.body.decode("utf-8"))
        except Exception:                                      # noqa: BLE001
            return {}

    def __repr__(self) -> str:
        return f"Receipt(sig={len(self.signature)}B, body={len(self.body)}B)"


def _receipt(payload: dict, key: str, what: str) -> Receipt:
    if (problem := _problem(payload)):
        raise MetaError(f"{what}: {problem}")
    value = payload.get(key)
    if value is None:
        raise MetaError(f"{what}: no {key} in the answer; keys {sorted(payload)}")
    signature = payload.get("receipt_signature")
    if not signature:
        raise MetaError(f"{what}: no receipt_signature in the answer")
    body = value if isinstance(value, str) else json.dumps(value, separators=(",", ":"))
    return Receipt(base64.b64decode(signature), body.encode("utf-8"))


def pair_request(ar_token: str, *, cert_der: bytes, serial: str,
                 device_nonce: bytes, app_pubkey: bytes,
                 secondary_cert: bytes = b"") -> Receipt:
    """Ask Meta for the pending receipt for this device + our owner key."""
    additional = {
        "device_nonce": base64.b64encode(device_nonce).decode(),
        "app_pubkey": base64.b64encode(app_pubkey).decode(),
        "secondary_cert": base64.b64encode(secondary_cert).decode(),
    }
    payload = _post(f"{HW_GRAPH}/pair_request", {
        "access_token": HW_APP_TOKEN,
        "user_access_token": ar_token,
        "user_token_universe": "ar",
        "pair_protocol_version": PAIR_PROTOCOL_VERSION,
        "device_cert": base64.b64encode(cert_der).decode(),
        "serial_number": serial,
        "additional_data": json.dumps(additional, separators=(",", ":")),
    }, gzipped=True)
    return _receipt(payload, "pending_ownership_receipt", "pair_request")


def pair(ar_token: str, device_pending: Receipt) -> Receipt:
    """Hand the glasses' pending receipt back; Meta answers the final one."""
    payload = _post(f"{HW_GRAPH}/pair", {
        "access_token": HW_APP_TOKEN,
        "user_access_token": ar_token,
        "user_token_universe": "ar",
        "pair_protocol_version": PAIR_PROTOCOL_VERSION,
        "device_pending_ownership_receipt": device_pending.body.decode("utf-8", "replace"),
        "device_pending_ownership_receipt_signature":
            base64.b64encode(device_pending.signature).decode(),
    }, gzipped=True)
    return _receipt(payload, "final_ownership_receipt", "pair")


# ------------------------------------------------------------------- store
def store_dir(root: str | None = None) -> str:
    return root or os.environ.get("GLASSES_STORE") or "identity"


def _path(root: str, name: str) -> str:
    os.makedirs(root, exist_ok=True)
    return os.path.join(root, name)


def save_login(root: str, frla: str) -> None:
    p = _path(root, "meta-login.json")
    with open(p, "w", encoding="utf-8") as f:
        json.dump({"frla": frla, "saved_at": int(time.time())}, f)
    try:
        os.chmod(p, 0o600)
    except OSError:
        pass


def load_login(root: str) -> str | None:
    p = os.path.join(root, "meta-login.json")
    if not os.path.exists(p):
        return None
    with open(p, encoding="utf-8") as f:
        return json.load(f).get("frla")


def ar_token(root: str, refresh: bool = False) -> str:
    """AR token for this machine, cached so a re-run does not end the old session."""
    p = os.path.join(root, "ar-token.json")
    if not refresh and os.path.exists(p):
        with open(p, encoding="utf-8") as f:
            blob = json.load(f)
        if blob.get("token") and time.time() - blob.get("saved_at", 0) < 12 * 3600:
            return blob["token"]
    frla = load_login(root)
    if not frla:
        raise MetaError(f"not logged in: run `meta_identity.py login --store {root}` first")
    token = exchange_frla(frla)
    with open(_path(root, "ar-token.json"), "w", encoding="utf-8") as f:
        json.dump({"token": token, "saved_at": int(time.time())}, f)
    try:
        os.chmod(p, 0o600)
    except OSError:
        pass
    return token


def save_bundle(root: str, *, serial: str, owner_pem: bytes, public_xy: bytes,
                final: Receipt, device_cert: bytes = b"") -> str:
    """Write what future connects need: the owner key plus Meta's final receipt.

    Same file name and fields as ``tools/adb_export_owner.py`` so ``ownerkey.py``
    and the phone-side exporter stay interchangeable.
    """
    pem = owner_pem.decode("ascii") if isinstance(owner_pem, bytes) else owner_pem
    der = "".join(line for line in pem.splitlines() if "-----" not in line)
    bundle = {
        "serial": serial,
        "publicKeyXy": base64.b64encode(public_xy).decode(),
        "privateKeyPkcs8": der,
        "receipt": {
            "signature": base64.b64encode(final.signature).decode(),
            "body": base64.b64encode(final.body).decode(),
        },
        "deviceCert": base64.b64encode(device_cert).decode(),
        "source": "meta_identity.py",
        "createdAt": int(time.time()),
    }
    p = _path(root, "owner-export.json")
    with open(p, "w", encoding="utf-8") as f:
        json.dump(bundle, f, indent=2)
    try:
        os.chmod(p, 0o600)
    except OSError:
        pass
    return p


def load_receipt(root: str) -> Receipt | None:
    p = os.path.join(root, "owner-export.json")
    if not os.path.exists(p):
        return None
    with open(p, encoding="utf-8") as f:
        blob = json.load(f)
    r = blob.get("receipt")
    if not r:
        return None
    return Receipt(base64.b64decode(r["signature"]), base64.b64decode(r["body"]))


# --------------------------------------------------------------------- cli
def _login_cli(root: str) -> int:
    url = authorize_url()
    print("1) open this on the iPhone or this machine, log in to the SAME Meta account")
    print("   that owns (or will own) the glasses:\n")
    print(url + "\n")
    print("2) after login the browser lands on accounts.meta.com/native/oidc/redirect/metaai")
    print("   copy the WHOLE address bar (it has code=...) and paste it here.\n")
    try:
        pasted = input("redirect URL (or the code alone): ")
    except EOFError:
        print("no input", file=sys.stderr)
        return 2
    code = code_from_redirect(pasted)
    frla = exchange_code(code)
    save_login(root, frla)
    print(f"\nlogged in; FRLA cached in {os.path.join(root, 'meta-login.json')}")
    token = exchange_frla(frla)
    masked = token[:6] + "..." + token[-4:]
    print(f"AR token OK ({masked}) — Meta accepted the login")
    return 0


def _whoami_cli(root: str) -> int:
    token = ar_token(root)
    print(f"AR token: {token[:6]}...{token[-4:]}  (cached)")
    print(f"store:    {os.path.abspath(root)}")
    r = load_receipt(root)
    print(f"receipt: {r if r else 'none yet (glasses not provisioned from this box)'}")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    root = "identity"
    if "--store" in argv:
        root = argv[argv.index("--store") + 1]
    if cmd == "login":
        return _login_cli(root)
    if cmd == "whoami":
        return _whoami_cli(root)
    if cmd == "authorize-url":
        print(authorize_url())
        return 0
    print(f"unknown command {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
