#!/usr/bin/env python3
"""Pull Visor's private data off a one-time Android phone and find the owner key.

  python adb_export_owner.py                 # auto-discover package, try every method
  python adb_export_owner.py --pkg com.x.visor --out owner-export

Tries, in order:
  1. root shell  (adb shell su -c "tar -cf - /data/data/<pkg>")
  2. run-as      (only if the APK is debuggable)
  3. adb backup  (legacy .ab container, zlib + tar)

Writes everything it can read into <out>/, then prints a candidate report:
32-byte-looking blobs, PEM/PKCS#8/DER files, and JSON receipts.
Nothing here needs the internet.
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import zlib

ADB = os.environ.get("ADB", "adb")


def run(args: list[str], binary: bool = False, timeout: int = 120):
    p = subprocess.run([ADB] + args, capture_output=True, timeout=timeout)
    if p.returncode != 0:
        raise RuntimeError(f"adb {' '.join(args)} -> {p.returncode}: {p.stderr.decode(errors='replace')[:300]}")
    return p.stdout if binary else p.stdout.decode(errors="replace")


def find_pkg() -> str | None:
    out = run(["shell", "pm", "list", "packages", "-3"])
    hits = [l.split(":", 1)[1].strip() for l in out.splitlines() if "visor" in l.lower()]
    return hits[0] if hits else None


def unpack_tar(blob: bytes, dest: str) -> int:
    n = 0
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:") as tf:
        for m in tf.getmembers():
            if not m.isfile() or m.size > 8 * 1024 * 1024:
                continue
            name = os.path.normpath(m.name).lstrip("./\\").replace("..", "_")
            path = os.path.join(dest, name)
            os.makedirs(os.path.dirname(path) or dest, exist_ok=True)
            fh = tf.extractfile(m)
            if not fh:
                continue
            with open(path, "wb") as out:
                shutil.copyfileobj(fh, out)
            n += 1
    return n


def pull_root(pkg: str, dest: str) -> int:
    blob = run(["exec-out", "su", "-c", f"tar -cf - /data/data/{pkg}"], binary=True)
    return unpack_tar(blob, dest)


def pull_runas(pkg: str, dest: str) -> int:
    blob = run(["exec-out", "run-as", pkg, "tar", "-cf", "-", "."], binary=True)
    return unpack_tar(blob, dest)


def pull_backup(pkg: str, dest: str) -> int:
    ab = os.path.join(dest, "_backup.ab")
    subprocess.run([ADB, "backup", "-f", ab, "-noapk", pkg], check=True,
                   capture_output=True, timeout=300)
    raw = open(ab, "rb").read()
    if not raw.startswith(b"ANDROID BACKUP"):
        raise RuntimeError("not an .ab container")
    parts = raw.split(b"\n", 4)
    compressed = parts[3] == b"1"
    payload = parts[4] if len(parts) > 4 else b""
    if compressed:
        payload = zlib.decompress(payload)
    return unpack_tar(payload, dest)


PEM = re.compile(rb"-----BEGIN [A-Z ]+-----")
HEX32 = re.compile(rb"(?i)(?:[0-9a-f]{64})")


def analyse(dest: str) -> dict:
    report = {"files": 0, "der_or_pem": [], "hex64": [], "json_like": [], "bytes": 0}
    for root, _, files in os.walk(dest):
        for f in files:
            path = os.path.join(root, f)
            rel = os.path.relpath(path, dest)
            try:
                data = open(path, "rb").read()
            except OSError:
                continue
            report["files"] += 1
            report["bytes"] += len(data)
            if PEM.search(data):
                report["der_or_pem"].append(rel)
            if data[:1] == b"\x30" and b"\x06\x03\x2b\x65\x6e" in data[:200]:
                report["der_or_pem"].append(rel + " (PKCS#8 P-256)")
            if HEX32.search(data):
                report["hex64"].append(rel)
            if f.endswith((".json", ".receipt", ".cert")) or data[:1] in (b"{", b"["):
                report["json_like"].append(rel)
    return report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pkg")
    ap.add_argument("--out", default="owner-export")
    args = ap.parse_args()

    pkg = args.pkg or find_pkg()
    if not pkg:
        print("could not find a visor package; pass --pkg (adb shell pm list packages | findstr visor)")
        return 1
    print(f"[*] package: {pkg}")

    dest = os.path.join(os.getcwd(), args.out)
    os.makedirs(dest, exist_ok=True)

    for name, fn in (("root", pull_root), ("run-as", pull_runas), ("backup", pull_backup)):
        try:
            n = fn(pkg, dest)
            print(f"[+] {name}: {n} files -> {dest}")
            break
        except Exception as exc:  # noqa: BLE001
            print(f"[-] {name}: {exc}")
    else:
        print("[!] every extraction method failed. Options: use a rooted phone, "
              "or build Visor with OwnerExport.kt (see visor-patch/).")
        return 2

    rep = analyse(dest)
    print(json.dumps(rep, indent=2, ensure_ascii=False))

    # Wrap the likely key material into one portable file for the iOS side.
    bundle = {"package": pkg, "host": os.uname().nodename if hasattr(os, "uname") else "windows",
              "files": {}}
    for rel in rep["der_or_pem"] + rep["json_like"]:
        p = os.path.join(dest, rel.split(" (")[0])
        if os.path.isfile(p) and os.path.getsize(p) < 64 * 1024:
            bundle["files"][rel] = base64.b64encode(open(p, "rb").read()).decode()
    out = os.path.join(dest, "owner-bundle.json")
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(bundle, fh, indent=2)
    print(f"[+] wrote {out} ({len(bundle['files'])} candidates) — feed this to the iOS app")
    print("[i] If the private key lives in the Android Keystore it is NOT in these files.")
    print("    In that case rebuild Visor with visor-patch/OwnerExport.kt (software key).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
