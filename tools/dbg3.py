import sys
sys.path.insert(0, r"C:\Users\lokla\Documents\deepseek-harness\default-workspace\meta-gen2\tools")
from p256_mirror import *
for k in (3, 15, 255, 65535):
    p = mul_g(limbs(k))
    print(k, "x=", "%064x" % toint(from_mont(p[0], Pw, N0P)), "y=", "%064x" % toint(from_mont(p[1], Pw, N0P)))