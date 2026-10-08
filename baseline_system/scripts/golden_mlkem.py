#!/usr/bin/env python3
"""Golden model ML-KEM (FIPS 203) polynomial ops: NTT, INTT, base-case PWM.
Independent check: INTT(NTT(a) o NTT(b)) == schoolbook negacyclic product."""
Q = 3329
N = 256
ZETA = 17
INV128 = 3303  # 128^-1 mod q


def bitrev7(x):
    return int(f"{x:07b}"[::-1], 2)


ZETAS = [pow(ZETA, bitrev7(i), Q) for i in range(128)]
# gamma_i = zeta^(2*BitRev7(i)+1)
GAMMAS = [pow(ZETA, 2 * bitrev7(i) + 1, Q) for i in range(128)]


def ntt(f):
    f = list(f)
    i, ln = 1, 128
    while ln >= 2:
        for start in range(0, N, 2 * ln):
            z = ZETAS[i]; i += 1
            for j in range(start, start + ln):
                t = (z * f[j + ln]) % Q
                f[j + ln] = (f[j] - t) % Q
                f[j] = (f[j] + t) % Q
        ln >>= 1
    return f


def intt(f, scale=True):
    f = list(f)
    i, ln = 127, 2
    while ln <= 128:
        for start in range(0, N, 2 * ln):
            z = ZETAS[i]; i -= 1
            for j in range(start, start + ln):
                t = f[j]
                f[j] = (t + f[j + ln]) % Q
                f[j + ln] = (z * (f[j + ln] - t)) % Q
        ln <<= 1
    if scale:
        f = [(x * INV128) % Q for x in f]
    return f


def pwm(a, b):
    c = [0] * N
    for i in range(128):
        a0, a1, b0, b1 = a[2*i], a[2*i+1], b[2*i], b[2*i+1]
        c[2*i] = (a0 * b0 + a1 * b1 % Q * GAMMAS[i]) % Q
        c[2*i+1] = (a0 * b1 + a1 * b0) % Q
    return c


def padd(a, b): return [(x + y) % Q for x, y in zip(a, b)]
def psub(a, b): return [(x - y) % Q for x, y in zip(a, b)]


def schoolbook(a, b):
    c = [0] * N
    for i in range(N):
        for j in range(N):
            k = i + j
            if k < N: c[k] = (c[k] + a[i] * b[j]) % Q
            else:     c[k - N] = (c[k - N] - a[i] * b[j]) % Q
    return c


if __name__ == "__main__":
    import random
    assert ZETAS[:8] == [1, 1729, 2580, 3289, 2642, 630, 1897, 848], ZETAS[:8]
    random.seed(1)
    a = [random.randrange(Q) for _ in range(N)]
    b = [random.randrange(Q) for _ in range(N)]
    assert intt(ntt(a)) == a
    assert intt(pwm(ntt(a), ntt(b))) == schoolbook(a, b)
    for i in range(128):
        z = ZETAS[64 + (i >> 1)]
        assert GAMMAS[i] == ((Q - z) % Q if i & 1 else z), i
    print("golden model self-checks PASSED")
