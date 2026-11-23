import re, zipfile, sys
apk = r"C:\Users\lokla\Documents\deepseek-harness\default-workspace\meta-gen2\apk\visor-3.1.0.apk"
pat = re.compile(rb"(?:AR|HW|FRL)\|[!-~]{6,120}")
seen = set()
with zipfile.ZipFile(apk) as z:
    for n in z.namelist():
        if not n.endswith(".dex"):
            continue
        data = z.read(n)
        for m in pat.findall(data):
            s = m.decode("utf-8", "replace")
            if s not in seen:
                seen.add(s)
for s in sorted(seen):
    print(len(s), s)