#!/usr/bin/env python3
"""Scan a jadx dump of the Meta AI APK for the wearable link-layer constants.

  jadx -d out meta-ai.apk
  python dat_recon.py out -o dat-report.md

What it looks for (all of it is what you need to fill in the iOS client):
  * CBUUIDs / 16-bit service UUIDs          -> which GATT service is the glasses link
  * L2CAP / PSM / openL2CAPChannel mentions -> the CoC PSM (iOS App.swift `var psm`)
  * protobuf write/read call sites around   -> the svc36 trust message field numbers
    classes named Trust/Owner/Pairing/Receipt/Encryption
  * strings that look like client tokens     -> HW| / AR| / FRL| (for a self-built Visor)

Pure stdlib. Read-only. Works on Windows.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from collections import Counter, defaultdict

UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
SHORT_UUID_RE = re.compile(r"0000([0-9a-fA-F]{4})-0000-1000-8000-00805f9b34fb", re.I)
TOKEN_RE = re.compile(r'"(HW\|[^"]{8,200}|AR\|[^"]{8,200}|FRL\|[^"]{8,200})"')
PB_WRITE_RE = re.compile(r"\bwrite(?:Bytes|String|Int32|Int64|UInt32|UInt64|Enum|Bool|Message|Fixed32)\(\s*(\d+)\s*,")
PB_READ_RE = re.compile(r"\bread(?:Bytes|String|Int32|Int64|UInt32|UInt64|Enum|Bool|Message|Fixed32)\(\)")
KEYWORDS = {
    "L2CAP": re.compile(r"L2CAP|l2cap", re.I),
    "PSM": re.compile(r"\bPSM\b|psm\s*[=:]"),
    "GATT": re.compile(r"BluetoothGatt|connectGatt|ParcelUuid|BluetoothUuid", re.I),
    "Wearables": re.compile(r"wearables|dat_?sdk|meta_?wearables", re.I),
    "Trust": re.compile(r"\btrust\b|ownership|owner[_ ]?key|receipt", re.I),
}


def walk(root: str):
    for dirpath, _, files in os.walk(root):
        for f in files:
            if f.endswith((".java", ".kt", ".smali", ".xml", ".json", ".txt")):
                yield os.path.join(dirpath, f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root", help="jadx output directory (the one with sources/)")
    ap.add_argument("-o", "--out", default="dat-report.md")
    ap.add_argument("--max-hits", type=int, default=6)
    args = ap.parse_args()

    uuids: Counter = Counter()
    short_uuids: Counter = Counter()
    hits: dict[str, list[tuple[str, int, str]]] = defaultdict(list)
    tokens: set[str] = set()
    pb_classes: dict[str, dict[int, int]] = defaultdict(lambda: defaultdict(int))
    pb_reads: Counter = Counter()
    n_files = 0

    for path in walk(args.root):
        n_files += 1
        try:
            text = open(path, "r", encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        rel = os.path.relpath(path, args.root)

        for m in UUID_RE.finditer(text):
            uuids[m.group(0).lower()] += 1
        for m in SHORT_UUID_RE.finditer(text):
            short_uuids[m.group(1).lower()] += 1
        for m in TOKEN_RE.finditer(text):
            tokens.add(m.group(1)[:120])
        for m in PB_READ_RE.finditer(text):
            pb_reads[rel] += 1

        for name, rx in KEYWORDS.items():
            for i, line in enumerate(text.splitlines(), 1):
                if rx.search(line) and len(hits[name]) < args.max_hits * 40:
                    hits[name].append((rel, i, line.strip()[:200]))

        # protobuf field numbers, only inside plausibly interesting classes
        if any(k in rel.lower() for k in ("trust", "owner", "pair", "receipt", "encrypt", "link", "handshake")):
            nums = [int(m.group(1)) for m in PB_WRITE_RE.finditer(text)]
            if nums:
                for n in nums:
                    pb_classes[rel][n] += 1

    def top(counter, n=40):
        return counter.most_common(n)

    lines = ["# Meta AI APK recon", "", f"files scanned: {n_files}", ""]

    lines += ["## Service UUIDs (full)", ""]
    for u, c in top(uuids):
        lines.append(f"- `{u}` ×{c}")
    lines += ["", "## 16-bit vendor UUIDs (Meta base 0000fd5a / FD5B …)", ""]
    for u, c in top(short_uuids):
        lines.append(f"- `0x{u}` ×{c}")

    lines += ["", "## Client tokens found (feed these to a self-built Visor)", ""]
    for t in sorted(tokens)[:20]:
        lines.append(f"- `{t[:40]}…`")
    if not tokens:
        lines.append("- none (tokens are usually fetched at runtime, not hardcoded)")

    lines += ["", "## protobuf field numbers per candidate class", ""]
    for cls, nums in sorted(pb_classes.items(), key=lambda kv: -sum(kv[1].values()))[:25]:
        ordered = sorted(nums.items())
        lines.append(f"- `{cls}`: " + ", ".join(f"f{n}×{c}" for n, c in ordered))

    lines += ["", "## Keyword hits", ""]
    for name in KEYWORDS:
        lines.append(f"### {name}")
        seen = 0
        for rel, line_no, line in hits[name]:
            if seen >= args.max_hits:
                break
            lines.append(f"- `{rel}:{line_no}` {line}")
            seen += 1
        if not hits[name]:
            lines.append("- none")
        lines.append("")

    report = "\n".join(lines)
    open(args.out, "w", encoding="utf-8").write(report)
    print(report[:4000])
    print(f"\n[+] full report -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
