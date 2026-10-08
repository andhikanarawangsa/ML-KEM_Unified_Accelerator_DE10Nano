# Model cycle & bandwidth memori untuk akselerator polinomial ML-KEM (q=3329, n=256) pada Cyclone V (DE10-Nano)
# Chip Hackaton - Peruri Digital Summit 2026

# Tim NamTIMAPAWOY:
#   - Andhika Narawangsa Susilo – Institut Teknologi Bandung – 13222036@mahasiswa.itb.ac.id 
#   - Rafi Ananta Alden – Institut Teknologi Bandung – 13222087@mahasiswa.itb.ac.id
#   - Didan Attaric – Institut Teknologi Bandung – 13222105@mahasiswa.itb.ac.id
#   - Ibrahim Hanif Mulyana – Institut Teknologi Bandung – 13222111@mahasiswa.itb.ac.id

# Note:
# Calculated directly from the algorithm structure:
#   - NTT/INTT: 7 layers x 128 butterflies = 896 butterflies, each coefficient read & written 1x per layer
#   - PWM (basemul): 128 pairs, 4-5 multiplications per pair
#   - Number of polynomials transferred via bus per ML-KEM operation

import sys
from dataclasses import dataclass
from math import ceil

N = 256
LAYERS = [128, 64, 32, 16, 8, 4, 2]
F_FABRIC_MHZ = 150.0
F_A9_MHZ = 800.0

# ----------------------------------------------------------------- PARAMETER
D_PIPE = 6                                              # Kedalaman pipa hardware
FSM_OVERHEAD = 10                                       # Jeda transisi state machine
BASEMUL_MULTS = 5                                       # Jumlah perkalian basis PWM/schoolbook
SW_CYCLES = {"ntt": 15000, "intt": 17000, "pwm": 4000}

# Nilai: 6–8 siklus | Rincian: read(1) + mult(1) + reduksi 2 siklus(2) + add/sub(1) + write reg(1) | [Ref: Botros dkk., "Area-Time Efficient FPGA Implementation of Kyber", IEEE Transactions on Circuits and Systems, 2022]
# Nilai: 10–15 siklus | Rincian: siklus transisi state machine dari IDLE ke COMPUTE hingga DONE | [Ref: Kannwischer dkk., "High-Performance Kyber on FPGA", CHES]
# Nilai: 4–5 perkalian | Rincian: perkalian per pasangan pada PWM/basecase ring X^2 - zeta (schoolbook) | [Ref: PQCrypto / CRYSTALS-Kyber Specification v3.02]
# Nilai: 15.000–30.000 siklus | Rincian: baseline software C murni pada ARM Cortex-A9 tanpa akselerator | [Ref: PQClean Baseline Benchmarks for ARM Cortex-A]


@dataclass
class Cfg:
    name: str
    n_pe: int                   # butterfly/cycle (batas komputasi)
    mults_per_pe: int           # perkalian 12x12 per PE per cycle (1 blok DSP = 2x 18x19)
    coef_per_word: int          # 1 = word 16-bit, 2 = dua koefisien dikemas di word 32-bit
    banks_per_poly: int         # jumlah bank M10K tempat SATU polinomial di-interleave
    mem_mode: str               # "TDP" = 2 port, masing-masing R atau W | "SDP" = 1R + 1W dedicated
    inv_scale: str = "merged"   # "merged": f dilipat ke layer terakhir | "separate": pass 256 perkalian

    @property
    def mults(self):            # perkalian per cycle total
        return self.n_pe * self.mults_per_pe

    @property
    def dsp_blocks(self):
        return ceil(self.mults / 2)

    @property
    def m10k(self):             # 4 ruang polinomial (A, B, ACC, cadangan) + 1 ROM twiddle
        return 4 * self.banks_per_poly + 1


def mem_cycles(rd_words, wr_words, c: Cfg):
    """cycle minimum agar rd/wr word bisa dilayani oleh banks_per_poly bank (asumsi conflict-free)."""
    b = c.banks_per_poly
    if c.mem_mode == "SDP":                                 # 1 read + 1 write per bank per cycle
        return max(ceil(rd_words / b), ceil(wr_words / b))
    return ceil((rd_words + wr_words) / (2 * b))            # TDP: 2 port per bank, dipakai bergantian R/W


def ntt_layer_rows(c: Cfg, inverse=False):
    rows = []
    lens = LAYERS[::-1] if inverse else LAYERS
    for i, ln in enumerate(lens):
        bf = N // 2
        rd_w = N // c.coef_per_word
        wr_w = N // c.coef_per_word
        mults_needed = bf
        last_inv = inverse and i == len(lens) - 1
        if last_inv and c.inv_scale == "merged":
            mults_needed = 2 * bf                  # keluaran jumlah juga dikali f
        cmp_c = ceil(mults_needed / c.mults)
        cmp_c = max(cmp_c, ceil(bf / c.n_pe))      # 1 butterfly/PE/cycle
        mem_c = mem_cycles(rd_w, wr_w, c)
        cyc = max(cmp_c, mem_c)
        rows.append(dict(layer=i + 1, ln=ln, bf=bf, rd_w=rd_w, wr_w=wr_w,
                         mem=mem_c, cmp=cmp_c, cyc=cyc,
                         bound="MEM" if mem_c > cmp_c else ("CMP" if cmp_c > mem_c else "BALANCED"),
                         util=100.0 * cmp_c / cyc))
    return rows


def ntt_total(c: Cfg, inverse=False, stall_per_layer=True):
    rows = ntt_layer_rows(c, inverse)
    issue = sum(r["cyc"] for r in rows)
    extra = 0
    if inverse and c.inv_scale == "separate":
        extra = max(ceil(N / c.mults), mem_cycles(N // c.coef_per_word, N // c.coef_per_word, c))
    stalls = D_PIPE * (len(rows) if stall_per_layer else 1)
    return issue + extra + stalls + FSM_OVERHEAD


def pwm_total(c: Cfg, mac=True):
    pairs = N // 2
    cmp_c = ceil(pairs * BASEMUL_MULTS / c.mults)
    wpp = 2 / c.coef_per_word
    rdA = ceil(pairs * wpp); rdB = ceil(pairs * wpp)
    mA = mem_cycles(rdA, 0, c)
    mB = mem_cycles(rdB, 0, c)
    mC = mem_cycles(rdA if mac else 0, rdA, c)
    mem_c = max(mA, mB, mC)
    return max(cmp_c, mem_c) + D_PIPE + FSM_OVERHEAD, cmp_c, mem_c


# ----------------------------------------------------------------- CONFLICT-FREE CHECK
def bank_map(w, b, scheme):
    if scheme == "low":
        return w % b
    k = b.bit_length() - 1                      
    m, x = b - 1, 0
    while w:
        x ^= w & m
        w >>= k
    return x

# ----------------------------------------------------------------- konfigurasi
CONFIGS = [
    Cfg("C0 (1 poli/bank, TDP16)", 4, 1, 1, 1, "TDP"),
    Cfg("C1 (4 bank interleave, TDP16)", 4, 1, 1, 4, "TDP"),
    Cfg("C2 (pack32, 2 bank/poli, 4 PE)", 4, 2, 2, 2, "SDP"),
    Cfg("C3 (pack32, 4 bank/poli, 4 PE)", 4, 2, 2, 4, "SDP"),
    Cfg("C4 (pack32, 4 bank/poli, 8 PE)", 8, 2, 2, 4, "SDP"),
    Cfg("C5 (pack32, 2 bank/poli, 2 PE)  [Area Eff.]", 2, 2, 2, 2, "SDP"),
    Cfg("C6 (pack32, 8 bank/poli, 8 PE)", 8, 2, 2, 8, "SDP"),
]


def print_layer_table(c: Cfg, inverse=False):
    print(f"\n[{c.name}]  {'INTT' if inverse else 'NTT'}  | PE={c.n_pe} mult/cycle={c.mults} "
          f"word={c.coef_per_word}coeff banks/poli={c.banks_per_poly} mode={c.mem_mode}")
    print(f"{'Lyr':>3} {'len':>4} {'#BF':>4} {'rd word':>8} {'wr word':>8} {'mem cyc':>8} {'cmp cyc':>8} "
          f"{'cyc':>5} {'bound':>9} {'util PE':>8}")
    for r in ntt_layer_rows(c, inverse):
        print(f"{r['layer']:>3} {r['ln']:>4} {r['bf']:>4} {r['rd_w']:>8} {r['wr_w']:>8} {r['mem']:>8} "
              f"{r['cmp']:>8} {r['cyc']:>5} {r['bound']:>9} {r['util']:>7.0f}%")
    print(f"    total = {ntt_total(c, inverse)} cycle (include {D_PIPE}x7 stall layer + {FSM_OVERHEAD} FSM)")


def summary():
    print("\n=== LATENCY SUMMARY (cycle @ %.0f MHz) ===" % F_FABRIC_MHZ)
    print(f"{'Konfigurasi':<46} {'NTT':>5} {'INTT':>5} {'PWM':>5} {'PWM bound':>9} "
          f"{'DSP':>4} {'M10K':>5} {'BW (coeff/cycle R+W)':>21}")
    for c in CONFIGS:
        n, i = ntt_total(c), ntt_total(c, True)
        p, cp, mp = pwm_total(c)
        bw = (c.banks_per_poly * (2 if c.mem_mode == "SDP" else 2)) * c.coef_per_word
        print(f"{c.name:<46} {n:>5} {i:>5} {p:>5} {('MEM' if mp > cp else 'CMP'):>9} "
              f"{c.dsp_blocks:>4} {c.m10k:>5} {bw:>21}")
    print("\nBatas bawah teoretis NTT dari struktur algoritma: 896 BF / n_pe  ->  "
          + ", ".join(f"{k} PE: {ceil(896 / k)}" for k in (2, 4, 8)))


# operasi ML-KEM-768 (k=3) dalam jumlah operasi polinomial
def ops(k=3):
    return {
        "KeyGen": dict(ntt=2 * k, pwm=k * k, intt=0, p_in=k + k + k * k, p_out=2 * k),
        "Encaps": dict(ntt=k, pwm=k * k + k, intt=k + 1, p_in=k + k * k + k, p_out=k + 1),
        "Decaps": dict(ntt=2 * k, pwm=k * k + 2 * k, intt=k + 2, p_in=2 * k + (k + k * k + k), p_out=1 + k + 1),
    }


def system_level(c: Cfg, ns_per_word_list=(10, 25, 50, 100, 250)):
    wpp = N // c.coef_per_word     # 128 word 32-bit per polinomial (pack2) / 256 (1 koef/word)
    wpp32 = N // 2                 # bus selalu 32-bit membawa 2 koefisien -> 128 word per polinomial
    n, i = ntt_total(c), ntt_total(c, True)
    p = pwm_total(c)[0]
    print(f"\n=== END-TO-END ML-KEM-768, {c.name} ===")
    print("Accelerator computation time vs. software baseline, including 32-bit PIO bus transfer overhead")
    hdr = f"{'Operasi':<8} {'HW cyc':>7} {'HW us':>7} {'SW us':>7} {'word bus':>9} | " + \
          " ".join(f"{x:>3}ns/w" for x in ns_per_word_list)
    print(hdr + "   <- speedup end-to-end (polinomial compute only)")
    for name, o in ops().items():
        hw = o["ntt"] * n + o["intt"] * i + o["pwm"] * p
        sw = (o["ntt"] * SW_CYCLES["ntt"] + o["intt"] * SW_CYCLES["intt"] + o["pwm"] * SW_CYCLES["pwm"]) / F_A9_MHZ
        hw_us = hw / F_FABRIC_MHZ
        words = (o["p_in"] + o["p_out"]) * wpp32
        cells = []
        for t in ns_per_word_list:
            tot = hw_us + words * t / 1000.0
            cells.append(f"{sw / tot:>6.2f}x")
        print(f"{name:<8} {hw:>7} {hw_us:>7.1f} {sw:>7.1f} {words:>9} | " + " ".join(cells))
    # break-even per NTT tunggal
    sw1 = SW_CYCLES["ntt"] / F_A9_MHZ
    hw1 = n / F_FABRIC_MHZ
    words1 = 2 * wpp32
    print(f"\nBreak-even for a single NTT (input + output: {words1} words): "f"bus latency must be < {(sw1 - hw1) * 1000 / words1:.0f} ns/word "f"(SW: {sw1:.1f} us vs HW: {hw1:.2f} us)"f"(SW {sw1:.1f} us vs HW {hw1:.2f} us)")


if __name__ == "__main__":
    show = CONFIGS
    for c in show:
        print_layer_table(c)
    summary()
    for c in CONFIGS:
        system_level(c)
    