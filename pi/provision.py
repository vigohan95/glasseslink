"""Change owner of a Ray-Ban Meta pair from this box: the whole flow in one call.

    transport  (L2CAP CoC on BlueZ, or the loopback pipe in the selftest)
        |
        +-- handshake WITHOUT trust      session.py, PSM 128
        +-- svc36 IDENTITY_REQUEST       cert + serial from the glasses
        +-- svc36 SKIP_CHALLENGE         device nonce
        +-- Meta pair_request            meta_identity.py, HW graph, gzip form
        +-- svc36 START_CHANGE_OWNER     glasses answer their pending receipt
        +-- Meta pair                    final receipt
        +-- svc36 FINISH_CHANGE_OWNER    ack
        +-- identity/owner-export.json   written: key + final receipt

After this, `gateway.py` connects with `handshake(trust=True)` and the glasses
accept the key, so no Android phone is involved again.

    python -P provision.py --address 80:AA:1C:98:18:0B --store identity

The glasses must be awake (legs open, near the box) for the whole run; some pairs
also wait for one press of the capture button in the middle, which the log says.
"""
from __future__ import annotations

import argparse
import os
import sys

from cryptography.hazmat.primitives import serialization

import meta_identity as MI
import session as S
from ownerkey import OwnerKey


def log(msg: str) -> None:
    print(msg, flush=True)


def run_provision(transport, owner: OwnerKey, *,
                  store: str = "identity",
                  backend=None,
                  on_step=log,
                  timeout: float = 20.0,
                  press_timeout: float = 120.0) -> dict:
    """Run change owner over an already-connected transport. Returns what was saved."""
    backend = backend or MI
    sess = S.GlassesSession(transport, owner, log=lambda *_: None)
    try:
        on_step("link: handshake (no trust yet)")
        sess.handshake(timeout=timeout, trust=False)

        on_step("svc36: asking the glasses who they are")
        sess.open_identity()
        ident = sess.identity(timeout=timeout)
        serial = ident["serial"]
        if not ident["cert"]:
            raise S.LinkError(
                "the glasses sent no device certificate: Meta never registered this "
                f"pair (registration blob {len(ident['registration'])} B)")
        on_step(f"      serial {serial}, cert {len(ident['cert'])} B")

        on_step("svc36: skip_challenge -> device nonce")
        nonce = sess.skip_challenge(timeout=timeout)
        on_step(f"      nonce {nonce.hex()}")

        on_step("meta: pair_request (graph.facebook-hardware.com)")
        token = MI.ar_token(store) if backend is MI else getattr(backend, "ar_token", None)
        if backend is MI:
            pending = MI.pair_request(
                token, cert_der=ident["cert"], serial=serial, device_nonce=nonce,
                app_pubkey=owner.public_xy, secondary_cert=ident["secondary_cert"])
        else:
            pending = backend.pair_request(
                cert_der=ident["cert"], serial=serial, device_nonce=nonce,
                app_pubkey=owner.public_xy, secondary_cert=ident["secondary_cert"])
        on_step(f"      pending receipt {len(pending.signature)} B sig, {len(pending.body)} B body")

        on_step("svc36: start_change_owner (press the capture button if the log says so)")
        raw = sess.start_change_owner(
            pending.encode(), timeout=press_timeout,
            on_press=lambda: on_step("      >>> the glasses are waiting: PRESS THE CAPTURE BUTTON"))
        device_pending = MI.Receipt.decode(raw)
        on_step(f"      device pending {len(device_pending.signature)} B sig, "
                f"{len(device_pending.body)} B body")

        on_step("meta: pair (final_ownership_receipt)")
        final = (MI.pair(token, device_pending) if backend is MI
                 else backend.pair(device_pending))
        on_step(f"      final receipt {len(final.signature)} B sig, {len(final.body)} B body")

        on_step("svc36: finish_change_owner")
        sess.finish_change_owner(final.encode(), timeout=timeout)

        pem = owner.key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption()).decode("ascii")
        path = MI.save_bundle(
            store, serial=serial, owner_pem=pem, public_xy=owner.public_xy,
            final=final, device_cert=ident["cert"])
        on_step(f"saved: {os.path.abspath(path)}")
        return {"serial": serial, "path": path, "receipt": final}
    finally:
        sess.close()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="become the owner of a Meta Ray-Ban pair")
    ap.add_argument("--address", required=True, help="glasses Bluetooth address, e.g. 80:AA:1C:98:18:0B")
    ap.add_argument("--store", default=os.environ.get("GLASSES_STORE", "identity"),
                    help="folder holding meta-login.json / owner-export.json")
    ap.add_argument("--pem", help="reuse an existing owner key (PEM) instead of making one")
    ap.add_argument("--psm", type=int, default=128, help="L2CAP PSM (Ray-Ban Meta = 128)")
    ap.add_argument("--timeout", type=float, default=20.0)
    args = ap.parse_args(argv)

    from transport_bluez import LecocoTransport           # only needed on a real box

    owner = (OwnerKey.load(args.pem) if args.pem else OwnerKey.generate())
    if not MI.load_login(args.store):
        log(f"no Meta login in {os.path.abspath(args.store)}: "
            f"run `python -P meta_identity.py login --store {args.store}` first")
        return 2

    transport = LecocoTransport(args.address, args.psm)
    try:
        transport.connect()
        result = run_provision(transport, owner, store=args.store,
                               timeout=args.timeout)
    finally:
        try:
            transport.close()
        except Exception:                                  # noqa: BLE001
            pass
    log("")
    log(f"done. this box now owns {result['serial']}.")
    log("next: python -P gateway.py --address %s --store %s --port 8799"
        % (args.address, args.store))
    return 0


if __name__ == "__main__":
    sys.exit(main())
