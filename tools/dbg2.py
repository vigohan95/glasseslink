import sys
sys.path.insert(0, r"C:\Users\lokla\Documents\deepseek-harness\default-workspace\meta-gen2\tools")
from p256_mirror import *
k = 0x1112131415161718191A1B1C1D1E1F202122232425262728292A2B2C2D2E2F30
p = mul_g(limbs(k))
x = toint(from_mont(p[0], Pw, N0P)); y = toint(from_mont(p[1], Pw, N0P))
print("kG.x =", "%064x" % x)
print("kG.y =", "%064x" % y)
print("x mod n =", "%064x" % (x % N))
# inverse sanity
one_m = to_mont(limbs(1), Nw, N0N, R2Nw)
inv = from_mont(inv_n(one_m), Nw, N0N)
print("invN(1) =", "%064x" % toint(inv))