#!/usr/bin/env python3
"""lan_scan.py — 在局域网里找跑着 Visor 网络门的手机（默认扫 7333 端口）。

用法:
  python lan_scan.py                    # 自动取本机 /24 网段
  python lan_scan.py 192.168.3          # 指定前缀
  python lan_scan.py 192.168.3 7333
"""
from __future__ import annotations

import asyncio
import ipaddress
import socket
import sys


def local_prefixes() -> list[str]:
    """返回本机所有 IPv4 的 /24 前缀（去掉回环与链路本地）。"""
    out: list[str] = []
    try:
        host = socket.gethostname()
        for info in socket.getaddrinfo(host, None, socket.AF_INET):
            ip = info[4][0]
            if ip.startswith(("127.", "169.254.")):
                continue
            p = ".".join(ip.split(".")[:3])
            if p not in out:
                out.append(p)
    except OSError:
        pass
    if not out:
        # 兜底：连一个外部地址看出口源 IP
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("8.8.8.8", 53))
            out.append(".".join(s.getsockname()[0].split(".")[:3]))
        finally:
            s.close()
    return out


async def probe(ip: str, port: int, timeout: float = 1.2) -> bool:
    try:
        fut = asyncio.open_connection(ip, port)
        reader, writer = await asyncio.wait_for(fut, timeout)
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass
        return True
    except Exception:
        return False


async def scan(prefix: str, port: int, conc: int = 128) -> list[str]:
    sem = asyncio.Semaphore(conc)
    hits: list[str] = []

    async def one(ip: str) -> None:
        async with sem:
            if await probe(ip, port):
                hits.append(ip)

    await asyncio.gather(*(one(str(ipaddress.ip_address(f"{prefix}.{i}"))) for i in range(1, 255)))
    return hits


async def main() -> int:
    args = sys.argv[1:]
    port = int(args[1]) if len(args) > 1 else 7333
    prefixes = [args[0]] if args else local_prefixes()
    for p in prefixes:
        print(f"[scan] {p}.1-254 :{port} ...", flush=True)
        hits = await scan(p, port)
        if hits:
            for h in hits:
                print(f"[hit] ws://{h}:{port}/rpc", flush=True)
            return 0
    print("[scan] 没找到。确认手机和电脑在同一 WiFi，且 Visor 里已打开网络门（Visor Kit）", flush=True)
    return 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
