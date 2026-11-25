#!/usr/bin/env python3
"""Regression gate for bugs that already shipped once.

Each rule is a bug class that cost real debugging time on a real device. The rules are
deliberately narrow: a gate that cries wolf gets switched off, and then it protects nothing.
Anything that only looks suspicious belongs in a review, not here.

Exit code 1 = a known bug class is back.
"""
import os
import re
import sys

SKIP = ("//", "///", "#")


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def lines_of(path):
    return read(path).splitlines()


def fires(rid, path, text, lineno, line):
    """Return (bool, why). `text` is the whole file, for context checks."""
    stripped = line.strip()

    if rid == "R1-log-in-viewmodel":
        return bool(re.search(r"@Published\s+var\s+log\b", line)), \
            "log must live in LogStore; publishing it from the view model re-diffs every view per line"

    if rid == "R2-blocking-on-main":
        if "try sess.handshake(" not in line:
            return False, ""
        # Legal only inside a detached task: that is how the freeze was fixed.
        window = "\n".join(lines_of(path)[max(0, lineno - 6):lineno])
        if "Task.detached" in window:
            return False, ""
        return True, "handshake() blocks up to 12 s; run it in Task.detached, never on the main actor"

    if rid == "R3-data-removeFirst":
        if "buf.removeFirst(" not in line:
            return False, ""
        if "var buf: Data" not in text:
            return False, ""   # [UInt8] is a value-semantics array; removing is safe
        return True, "Data.removeFirst only moves startIndex; the next b[0] read traps (SIGTRAP)"

    if rid == "R4-raw-index":
        if not re.search(r"\bb\[\s*\d+\s*\]", line):
            return False, ""
        # Look at the enclosing signature: `[UInt8]` is bounds-checked and correct; `Data` is not.
        enclosing = ""
        for prev in reversed(lines_of(path)[max(0, lineno - 20):lineno]):
            if "func " in prev:
                enclosing = prev
                break
        # a local Array conversion on the same or a nearby line makes the index safe
        nearby = "\n".join(lines_of(path)[max(0, lineno - 4):lineno])
        if "[UInt8](" in nearby:
            return False, ""
        if "[UInt8]" in enclosing or "Data)" not in enclosing:
            return False, ""
        return True, "indexing a Data slice from 0 is out of bounds when startIndex != 0"

    if rid == "R5-success-code":
        if not re.search(r"==\s*(Int\()?\s*AirShield\.stOK\b", line):
            return False, ""
        if "stSuccess" in line:
            return False, ""
        return True, "0x1000 is the glasses' success code; accepting only 0x0000 rejects a valid reply"

    if rid == "R6-empty-binding":
        return bool(re.search(r"isPresented:\s*[),]", line)), \
            "a sheet with an empty binding does not compile"

    if rid == "R7-setting-label":
        return bool(re.search(r"writeSetting\([^)]*,\s*value:", line)), \
            "writeSetting takes an unlabelled second argument"

    if rid == "R8-yaml-indent":
        return bool(re.match(r"^\s{4}- \w+\.swift\s*$", line)), \
            "project.yml sources entries need 6 spaces of indentation or xcodegen fails"

    if rid == "R9-runloop-in-frame":
        return "RunLoop.current.run" in line, \
            "pumping the run loop inside nextFrame() re-enters the handshake and two readers steal frames"

    if rid == "R10-swift-keyword":
        return bool(re.search(r"func\s+struct\s*\(", line)), "'struct' is a Swift keyword"

    if rid == "R11-sleep-on-main":
        if "/Tests/" in path.replace("\\", "/"):
            return False, ""
        return "Thread.sleep" in line, "Thread.sleep on the app target stalls every animation and tap"

    return False, ""


RULES = ["R1-log-in-viewmodel", "R2-blocking-on-main", "R3-data-removeFirst", "R4-raw-index",
         "R5-success-code", "R6-empty-binding", "R7-setting-label", "R8-yaml-indent",
         "R9-runloop-in-frame", "R10-swift-keyword", "R11-sleep-on-main"]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "ios"
    hits = []
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if not name.endswith((".swift", ".yml")):
                continue
            path = os.path.join(dirpath, name)
            text = read(path)
            for lineno, line in enumerate(text.splitlines(), 1):
                if line.strip().startswith(SKIP):
                    continue
                for rid in RULES:
                    if rid == "R8-yaml-indent" and not name.endswith(".yml"):
                        continue
                    hit, why = fires(rid, path, text, lineno, line)
                    if hit:
                        hits.append((rid, why, path, lineno, line.strip()))
    if not hits:
        print("audit: clean ({} rules checked)".format(len(RULES)))
        return 0
    for rid, why, path, lineno, line in hits:
        print("{} {}:{}".format(rid, path, lineno))
        print("   {}".format(line))
        print("   -> {}".format(why))
    print("\naudit: {} violation(s)".format(len(hits)))
    return 1


if __name__ == "__main__":
    sys.exit(main())
