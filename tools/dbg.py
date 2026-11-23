import sys
sys.path.insert(0, r"C:\Users\lokla\Documents\deepseek-harness\default-workspace\meta-gen2\tools")
from p256_mirror import *

def plain_mul(a, b):
    return from_mont(mul_p(to_mont(limbs(a), Pw, N0P, R2Pw), to_mont(limbs(b), Pw, N0P, R2Pw)), Pw, N0P)

for a, b in [(3,5),(123456789, 987654321), (2**200+7, 2**130+11)]:
    got = toint(plain_mul(a,b)); exp = a*b % P
    print(a, b, "ok" if got == exp else "MISMATCH got=%x exp=%x" % (got, exp))

def ref_add(p1,p2):
    if p1 is None: return p2
    if p2 is None: return p1
    if p1[0]==p2[0] and (p1[1]+p2[1])%P==0: return None
    if p1==p2:
        lam=(3*p1[0]*p1[0]+A)*pow(2*p1[1],P-2,P)%P
    else:
        lam=(p2[1]-p1[1])*pow((p2[0]-p1[0])%P,P-2,P)%P
    x3=(lam*lam-p1[0]-p2[0])%P
    return (x3,(lam*(p1[0]-x3)-p1[1])%P)

G=(GX,GY)
print("2G ref x:", "%064x" % ref_add(G,G)[0])
p2 = mul_g(limbs(2))
print("2G got x:", "%064x" % toint(from_mont(p2[0],Pw,N0P)))