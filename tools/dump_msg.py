import sys, struct
sys.path.insert(0, "pi")
import airshield as A

sdu = bytes.fromhex(sys.argv[1])
ch, tags, payload, used = A.dx_parse(sdu)
print("channel=%#x tags=%s used=%d payload=%dB" % (ch, tags, used, len(payload)))
fields = A.pb_parse(payload)
for k in sorted(fields):
    v = fields[k]
    for item in v:
        if isinstance(item, (bytes, bytearray)):
            print("  f%d bytes(%d) %s" % (k, len(item), item.hex()))
        else:
            print("  f%d varint %d" % (k, item))
