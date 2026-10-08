#!/usr/bin/env python3
"""Generate test vectors (hex, packed 2 coeff / 32-bit word: [15:0]=even, [31:16]=odd)
into tb/vectors/. Each file has 128 words = one polynomial."""
import os, sys, random
sys.path.insert(0, os.path.dirname(__file__))
import golden_mlkem as g

out = os.path.join(os.path.dirname(__file__), "..", "tb", "vectors")
os.makedirs(out, exist_ok=True)


def dump(name, poly):
    with open(os.path.join(out, name + ".hex"), "w") as f:
        for w in range(128):
            f.write(f"{poly[2*w] | (poly[2*w+1] << 16):08x}\n")


random.seed(2026)
Q = g.Q
a = [random.randrange(Q) for _ in range(256)]
b = [random.randrange(Q) for _ in range(256)]
# corner-heavy polynomial: 0, 1, q-1 mix
c = [random.choice([0, 1, Q - 1, Q - 2, 1664]) for _ in range(256)]

A, B = g.ntt(a), g.ntt(b)
dump("a", a); dump("b", b); dump("c", c)
dump("ntt_a", A); dump("ntt_b", B); dump("ntt_c", g.ntt(c))
dump("pwm_ab", g.pwm(A, B))
dump("add_ab", g.padd(a, b))
dump("sub_ab", g.psub(a, b))
dump("intt_ntt_a", g.intt(A))                 # == a
dump("intt_raw_a", g.intt(A, scale=False))   # unscaled
dump("mul_ab", g.schoolbook(a, b))            # INTT(PWM(NTT a, NTT b))
dump("scale_a", [(x * g.INV128) % Q for x in a])
print("vectors written to", os.path.abspath(out))
