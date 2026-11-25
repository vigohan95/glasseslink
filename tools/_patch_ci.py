import io
p = ".github/workflows/ios.yml"
s = io.open(p, encoding="utf-8").read()
if "Regression audit" not in s:
    s = s.replace("      - name: Install XcodeGen",
"""      - name: Regression audit (known bug classes)
        run: python3 tools/audit.py ios

      - name: Install XcodeGen""", 1)
io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("workflow patched")
