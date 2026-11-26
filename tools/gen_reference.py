#!/usr/bin/env python3
"""Generate the reference appendices straight from the Kotlin reference tree.

Two outputs, both mechanical (no hand-editing), so nothing can be "forgotten":

  docs/REFERENCE/A1-source-index.md      every .kt file, grouped by module, with its
                                         first doc comment + a count of what it declares
  docs/REFERENCE/A2-constants.md         every `const val` and every enum constant, grouped

Usage:  python -P tools/gen_reference.py [--src visor-src] [--out docs/REFERENCE]
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from collections import defaultdict

CONST_RE = re.compile(r"^\s*(?:private\s+|internal\s+|public\s+)?const\s+val\s+(\w+)\s*(?::\s*([\w<>?.]+))?\s*=\s*(.+?)\s*$")
ENUM_RE = re.compile(r"^\s*(?:private\s+|internal\s+|public\s+)?enum\s+class\s+(\w+)")
OBJ_RE = re.compile(r"^\s*(?:private\s+|internal\s+|public\s+)?object\s+(\w+)")
FUN_RE = re.compile(r"^\s*(?:private\s+|internal\s+|public\s+|override\s+|suspend\s+)*fun\s+(?:<[^>]+>\s*)?(\w+)")
DOC_OPEN = re.compile(r"^\s*/\*\*")


def first_doc(lines: list[str]) -> str:
    """First sentence of the file's leading KDoc, collapsed to one line."""
    buf: list[str] = []
    started = False
    for raw in lines[:80]:
        line = raw.strip()
        if not started:
            if DOC_OPEN.match(raw) or line.startswith("///") or line.startswith("//"):
                started = True
            else:
                continue
        if line.startswith("*/"):
            break
        cleaned = line.lstrip("/*").lstrip("*").lstrip("/").strip()
        if cleaned:
            buf.append(cleaned)
        if len(" ".join(buf)) > 160:
            break
    text = " ".join(buf).strip()
    if not text:
        return ""
    # keep the first sentence
    m = re.search(r"[.。](?:\s|$)", text)
    if m:
        text = text[: m.start() + 1]
    return text


def scan(root: str) -> tuple[dict[str, list[dict]], dict[str, list[tuple[str, str]]]]:
    files: dict[str, list[dict]] = defaultdict(list)
    constants: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for dirpath, _dirnames, names in os.walk(root):
        for name in sorted(names):
            if not name.endswith(".kt"):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root).replace("\\", "/")
            parts = rel.split("/")
            module = "/".join(parts[:2]) if parts[0] == "core" else parts[0]
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    lines = fh.readlines()
            except OSError:
                continue
            info = {
                "path": rel,
                "lines": len(lines),
                "doc": first_doc(lines),
                "consts": 0,
                "enums": 0,
                "objects": 0,
                "funs": 0,
            }
            in_enum = None
            for raw in lines:
                m = CONST_RE.match(raw)
                if m:
                    info["consts"] += 1
                    constants[module].append((f"{rel}:{m.group(1)}", m.group(3)[:90]))
                m = ENUM_RE.match(raw)
                if m:
                    info["enums"] += 1
                    in_enum = m.group(1)
                    constants[module].append((f"{rel}:enum {m.group(1)}", ""))
                    continue
                if in_enum and raw.strip().startswith("}"):
                    in_enum = None
                elif in_enum:
                    em = re.match(r"^\s*([A-Z][A-Z0-9_]*)\s*(?:\(([^)]*)\))?", raw)
                    if em:
                        constants[module].append(
                            (f"{rel}:enum {in_enum}.{em.group(1)}", (em.group(2) or "").strip()[:60])
                        )
                if OBJ_RE.match(raw):
                    info["objects"] += 1
                if FUN_RE.match(raw):
                    info["funs"] += 1
            files[module].append(info)
    return files, constants


def write_index(files: dict[str, list[dict]], dest: str) -> int:
    total = sum(len(v) for v in files.values())
    lines = [
        "# A1 · 源码索引（自动生成）",
        "",
        f"由 `tools/gen_reference.py` 直接扫描参考实现生成，共 **{total} 个 Kotlin 文件**、{len(files)} 个模块。",
        "用途：证明「没有遗漏」——任何一份协议行为都能在这张表里找到实现位置；文档改动后重跑脚本即可刷新。",
        "",
        "列说明：**行** 文件行数；**常量/枚举/对象/函数** 是该文件声明的数量，用来判断它是不是协议关键文件。",
        "",
    ]
    for module in sorted(files, key=lambda m: (-sum(f["lines"] for f in files[m]), m)):
        items = sorted(files[module], key=lambda f: f["path"])
        lines.append(f"## `{module}` · {len(items)} 个文件 · {sum(f['lines'] for f in items):,} 行")
        lines.append("")
        lines.append("| 文件 | 行 | 常量 | 枚举 | 对象 | 函数 | 说明 |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: | --- |")
        for f in items:
            doc = f["doc"].replace("|", "\\|") if f["doc"] else ""
            lines.append(
                f"| `{f['path'].split('/', 2)[-1]}` | {f['lines']:,} | {f['consts']} | "
                f"{f['enums']} | {f['objects']} | {f['funs']} | {doc} |"
            )
        lines.append("")
    with open(dest, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    return total


def write_constants(constants: dict[str, list[tuple[str, str]]], dest: str) -> int:
    total = sum(len(v) for v in constants.values())
    lines = [
        "# A2 · 常量与枚举（自动生成）",
        "",
        f"同样是 `tools/gen_reference.py` 扫出来的，共 **{total} 条**，按模块分组。",
        "带 `enum X.Y` 的是枚举常量，右侧括号里是它携带的值（协议编号）。",
        "",
    ]
    for module in sorted(constants):
        rows = constants[module]
        if not rows:
            continue
        lines.append(f"## `{module}` · {len(rows)} 条")
        lines.append("")
        lines.append("| 位置 | 值 |")
        lines.append("| --- | --- |")
        for where, value in rows:
            v = value.replace("|", "\\|")
            lines.append(f"| `{where.split('/', 2)[-1]}` | `{v}` |" if v else f"| `{where.split('/', 2)[-1]}` | — |")
        lines.append("")
    with open(dest, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    return total


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="visor-src")
    ap.add_argument("--out", default=os.path.join("docs", "REFERENCE"))
    args = ap.parse_args()
    if not os.path.isdir(args.src):
        print(f"no such source tree: {args.src}")
        return 2
    os.makedirs(args.out, exist_ok=True)
    files, constants = scan(args.src)
    n_files = write_index(files, os.path.join(args.out, "A1-source-index.md"))
    n_consts = write_constants(constants, os.path.join(args.out, "A2-constants.md"))
    print(f"A1: {n_files} files")
    print(f"A2: {n_consts} entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
