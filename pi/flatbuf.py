"""Minimal FlatBuffers reader — just enough to walk the svc18 capture records.

The capture list has no schema to link against, so this reads vtables directly:
every table is `soffset_to_vtable` at its start, and the vtable holds a u16 offset
per field slot. A slot missing from the vtable reads as absent.
"""
from __future__ import annotations

import struct


class FBError(ValueError):
    pass


def _u16(buf: bytes, pos: int) -> int:
    _need(buf, pos, 2)
    return struct.unpack_from("<H", buf, pos)[0]


def _u32(buf: bytes, pos: int) -> int:
    _need(buf, pos, 4)
    return struct.unpack_from("<I", buf, pos)[0]


def _i32(buf: bytes, pos: int) -> int:
    _need(buf, pos, 4)
    return struct.unpack_from("<i", buf, pos)[0]


def _need(buf: bytes, pos: int, n: int) -> None:
    if pos < 0 or pos + n > len(buf):
        raise FBError(f"read past end at {pos}+{n} of {len(buf)}")


def root(buf: bytes) -> int:
    return _u32(buf, 0)


def field_offset(buf: bytes, table: int, slot: int) -> int:
    """Byte offset from `table` to the field, or 0 when the slot is absent."""
    vt = table - _i32(buf, table)
    vt_size = _u16(buf, vt)
    idx = 4 + slot * 2
    if idx + 2 > vt_size:
        return 0
    return _u16(buf, vt + idx)


def scalar(buf: bytes, table: int, slot: int, default: int = 0) -> int:
    off = field_offset(buf, table, slot)
    return default if not off else _u32(buf, table + off)


def string(buf: bytes, table: int, slot: int) -> str | None:
    off = field_offset(buf, table, slot)
    if not off:
        return None
    p = table + off
    s = p + _u32(buf, p)
    n = _u32(buf, s)
    _need(buf, s + 4, n)
    return buf[s + 4:s + 4 + n].decode("utf-8", "replace")


def table(buf: bytes, table_pos: int, slot: int) -> int | None:
    off = field_offset(buf, table_pos, slot)
    if not off:
        return None
    p = table_pos + off
    return p + _u32(buf, p)


def table_vector(buf: bytes, table_pos: int, slot: int) -> list[int]:
    off = field_offset(buf, table_pos, slot)
    if not off:
        return []
    p = table_pos + off
    v = p + _u32(buf, p)
    n = _u32(buf, v)
    out = []
    for i in range(n):
        elem = v + 4 + 4 * i
        out.append(elem + _u32(buf, elem))
    return out


if __name__ == "__main__":  # tiny smoke test on a hand-built record
    pass
