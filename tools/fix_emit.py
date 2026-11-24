import io

p = "ios/Session.swift"
s = io.open(p, encoding="utf-8").read()
old = '                emit("resync: header claimed \\(need)B, dropping a byte")'
new = '                print("[sdu] resync: header claimed \\(need)B, dropping a byte")'
assert old in s, "pattern not found"
s = s.replace(old, new, 1)
io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("ok")
