#!/usr/bin/env python3
"""BLE L2CAP CoC transport to the glasses (Linux / BlueZ).

The control link is LE L2CAP connection-oriented channel — the same socket family
BlueZ exposes as BTPROTO_L2CAP. No GATT, no Android, no Meta app.

    sudo apt install bluez python3-cryptography
    bluetoothctl   # pair/trust once, then this takes over

Requires kernel >= 4.5 for LE CoC (Raspberry Pi OS bookworm is fine).
"""
from __future__ import annotations

import os
import socket
import struct
import time

BDADDR_LE_PUBLIC = 0x01

try:
    BTPROTO_L2CAP = socket.BTPROTO_L2CAP  # type: ignore[attr-defined]
except AttributeError:  # non-Linux
    BTPROTO_L2CAP = 0


class TransportError(RuntimeError):
    pass


class LecocoTransport:
    """One LE CoC channel: connect, send frames, receive frames.

    sockaddr for LE CoC is (bdaddr_str, psm, cid, bdaddr_type); cid 0 = let the kernel pick.
    """

    def __init__(self, address: str, psm: int, timeout: float = 10.0,
                 bdaddr_type: int = BDADDR_LE_PUBLIC):
        self.address, self.psm, self.timeout = address, psm, timeout
        self.bdaddr_type = bdaddr_type
        self.sock: socket.socket | None = None
        self.buf = bytearray()

    # ---- lifecycle ----------------------------------------------------
    def open(self) -> None:
        if not BTPROTO_L2CAP:
            raise TransportError("BTPROTO_L2CAP unavailable — run this on Linux")
        s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, BTPROTO_L2CAP)
        s.settimeout(self.timeout)
        try:
            s.connect((self.address, self.psm, 0, self.bdaddr_type))
        except OSError as exc:
            s.close()
            raise TransportError(
                f"L2CAP connect to {self.address} psm 0x{self.psm:04x} failed: {exc}"
            ) from exc
        self.sock = s

    def close(self) -> None:
        if self.sock:
            try:
                self.sock.close()
            finally:
                self.sock = None

    def __enter__(self):
        self.open()
        return self

    def __exit__(self, *exc):
        self.close()

    # ---- io -----------------------------------------------------------
    def send(self, data: bytes) -> None:
        if not self.sock:
            raise TransportError("not connected")
        self.sock.sendall(data)

    def recv_frame(self) -> bytes:
        """Return one complete DataX frame (header + tags + payload)."""
        while True:
            frame = self._take_frame()
            if frame is not None:
                return frame
            self._fill()

    def _fill(self) -> None:
        if not self.sock:
            raise TransportError("not connected")
        chunk = self.sock.recv(65535)
        if not chunk:
            raise TransportError("peer closed the channel")
        self.buf += chunk

    def _take_frame(self) -> bytes | None:
        if len(self.buf) < 4:
            return None
        ln = struct.unpack(">H", self.buf[:2])[0]
        if ln & 0x8000:
            raise TransportError("extended header seen — extend dx_parse first")
        payload_len = ln & 0x7FFF
        i = 4
        while True:
            if len(self.buf) < i + 4:
                return None
            b = self.buf[i]
            i += 4
            if not b & 0x80:
                break
        end = i + payload_len
        if len(self.buf) < end:
            return None
        frame = bytes(self.buf[:end])
        del self.buf[:end]
        return frame


def chip_ready(address: str) -> bool:
    """Cheap liveness probe: can the kernel see the device in the LE scan cache?"""
    try:
        out = os.popen("bluetoothctl info " + address).read()
    except OSError:
        return False
    return "Connected: yes" in out or "Paired: yes" in out


if __name__ == "__main__":
    import sys
    if len(sys.argv) < 3:
        print("usage: transport_bluez.py <MAC> <PSM-hex>")
        raise SystemExit(2)
    mac, psm = sys.argv[1], int(sys.argv[2], 16)
    t0 = time.time()
    with LecocoTransport(mac, psm) as t:
        print(f"connected to {mac} psm 0x{psm:04x} in {time.time() - t0:.2f}s")
        f = t.recv_frame()
        print("first frame:", f[:32].hex())
