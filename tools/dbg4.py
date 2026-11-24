import sys
sys.path.insert(0, r"C:\Users\lokla\Documents\deepseek-harness\default-workspace\meta-gen2\tools")
from p256_mirror import *
target = 0x16b4220d9e37f46cfee72234ad4cbc96ac05d2ff6d247e9cc62d5dd4803029ec
cands = {
 "as-is": 0x1112131415161718191A1B1C1D1E1F202122232425262728292A2B2C2D2E2F30,
 "byte-reversed": int.from_bytes(bytes.fromhex("1112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f30")[::-1], "big"),
 "limbs-reversed": int.from_bytes(bytes.fromhex("1112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f30")[:16][::-1]+bytes.fromhex("1112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f30")[16:][::-1], "big"),
}
for name, k in cands.items():
    p = mul_g(limbs(k))
    x = toint(from_mont(p[0], Pw, N0P))
    print(name, "%064x" % x, "MATCH" if x == target else "")