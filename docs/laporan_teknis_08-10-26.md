
# LAPORAN TEKNIS AKSELERATOR ML-KEM TERPADU

## Implementasi FPGA SoC Intel Cyclone V (Terasic DE10-Nano)

**Kompetisi:** PERURI Chip Design Hackathon 2026 — Kategori *IC Chip Design & FPGA Implementation*
**Proyek:** `ML-KEM_Unified_Accelerator_DE10Nano`
**Dokumen:** Laporan Teknis Arsitektur, Sintesis Fisik, dan Analisis Performa
**Tanggal:** 8 Oktober 2026
**Status Desain:** *Proof-of-Concept (PoC) Verified & Synthesized*

---

## 1. Ringkasan Eksekutif (Executive Summary)

Laporan teknis ini mendokumentasikan hasil perancangan, verifikasi, sintesis logika, dan analisis pewaktuan (*Static Timing Analysis*) dari IP Core Akselerator Kriptografi Pasca-Kuantum ML-KEM (FIPS 203 / Kyber) berbasis FPGA fabric Intel Cyclone V pada board Terasic DE10-Nano.

Akselerator ini dirancang untuk mengatasi permasalahan *bus-choking* pada sistem komputasi heterogen SoC, di mana transfer data polinomial bolak-balik antara CPU (ARM Cortex-A9) dan akselerator sering kali memakan waktu lebih lama daripada komputasi aritmetika itu sendiri. Dengan memadukan **4 Processing Element (PE) terpadu** dan **4 bank memori scratchpad lokal bebas-konflik (*conflict-free bank interleaving*)**, seluruh rantai transformasi $FNTT \rightarrow PWM \rightarrow ADD \rightarrow INTT$ dapat diselesaikan secara internal di dalam akselerator.

### Rangkuman Pencapaian Utama:

1. **Akurasi 100% (*Bit Error Rate* = 0%):** Terverifikasi penuh terhadap *Golden Model* matematis standar FIPS 203 melalui pengujian eksaustif 11,08 juta perkalian modular serta 34 rangkaian pengujian end-to-end.
2. **Pencapaian Target Latensi PWM:** Arsitektur *Dual-Multiplier per PE* berhasil memangkas latensi *Pointwise Multiplication* (PWM) dari **172 siklus** menjadi **140 siklus**, melampaui target proposal ($\le 150$ siklus).
3. **Efisiensi Sumber Daya Ekstrem:** Utilisasi logika hanya **2.381 ALM (5,7%)**, **9 blok RAM M10K (1,6%)**, dan **16 blok DSP (14,2%)** dari kapasitas total DE10-Nano, menyisakan >85% sumber daya FPGA untuk modul sistem lainnya.
4. **Integritas Bus Avalon-MM:** Dilengkapi proteksi register konfigurasi saat sibuk (*busy guard*) dan dekode alamat memori eksak untuk integrasi stabil dengan Linux kernel driver pada HPS ARM.

---

## 2. Spesifikasi & Arsitektur Sistem

### 2.1 Parameter Algoritma ML-KEM (FIPS 203)

- **Ring Polinomial:** $R_q = \mathbb{Z}_q[X] / (X^{256} + 1)$
- **Modulus Prima:** $q = 3329$ (12-bit unsigned)
- **Derajat Polinomial:** $n = 256$ koefisien
- **Konstanta Twiddle Primitive:** $\zeta = 17 \pmod{3329}$
- **Faktor Skala Invers:** $128^{-1} \equiv 3303 \pmod{3329}$

### 2.2 Dekomposisi Hierarki Modul RTL

```
mlkem_top (Top-Level SoC Wrapper)
├── mlkem_csr         : Avalon-MM 32-bit Slave Interface, CSR & Memory Window
├── mlkem_ctrl        : Top-Level FSM, Operation Scheduler & Crossbar Steering
├── mlkem_scratchpad  : 4-Bank Memory Controller (Host & Core Port Muxing)
│   └── mlkem_bank_mem [x4] : M10K Simple Dual-Port SRAM (128 x 32-bit per bank)
├── mlkem_arith_core  : 4-Lane SIMD Computational Unit
│   └── mlkem_pe [x4] : Unified Arithmetic PE (CT/GS Butterfly, PWM, ADD, SUB, SCALE)
│       ├── mlkem_modmul (u_mm)  : 3-Stage Barrett Modular Multiplier 0
│       └── mlkem_modmul (u_mm1) : 3-Stage Barrett Modular Multiplier 1
└── mlkem_zeta_rom    : Twiddle Factor ROM (128 x 12-bit, Dual Read Port)
```

### 2.3 Rincian Subsistem Utama

#### A. Bank-Centered Scratchpad Memory (`mlkem_scratchpad.v`)

- **Organisasi Memori:** 4 bank fisik independen, masing-masing berkapasitas 128 kata $\times$ 32-bit (total kapasitas 512 kata 32-bit $\equiv$ 1.024 koefisien 16-bit).
- **Format Data `Pack32`:** Dua koefisien 12-bit dikemas dalam satu kata 32-bit:
  $$
  \text{Word}[31:0] = \{4'\text{b}0, \text{Koefisien}_{\text{ganjil}}[11:0], 4'\text{b}0, \text{Koefisien}_{\text{genap}}[11:0]\}
  $$
- **Fungsi Pemetaan Bebas-Konflik (*Conflict-Free Bijection*):**
  Untuk slot polinomial $p \in \{0, 1, 2, 3\}$ dan indeks kata $w \in \{0, \dots, 127\}$:
  $$
  \text{bank}(p, w) = (p + w[1:0] + w[3:2] + w[5:4] + w[6]) \bmod 4, \quad \text{addr} = w
  $$

  *Sifat Matematis:*1. Dua kata yang indeksnya berbeda tepat 1 bit selalu berada pada bank memori yang berbeda ($\Delta \equiv 1$ atau $\Delta \equiv 2 \pmod 4$), menjamin kupu-kupu NTT bebas tabrakan bank.
  2. Dua slot berbeda ($p_a \ne p_b$) pada indeks kata $w$ yang sama selalu berada pada bank berbeda, menjamin operasi inter-slot PWM/ADD/SUB bebas tabrakan.
  3. Pemetaan ini merupakan bijeksi sempurna: 4 slot polinomial dipadatkan ke dalam 4 bank fisik tanpa pemborosan kapasitas.

#### B. Unified Processing Element (`mlkem_pe.v` & `mlkem_modmul.v`)

Setiap PE mendukung 6 mode operasi terpadu:

1. **FNTT (Cooley-Tukey):** $y_0 = a + \zeta b, \quad y_1 = a - \zeta b$ (Throughput: 1 kupu-kupu / siklus).
2. **INTT (Gentleman-Sande):** $y_0 = a + b, \quad y_1 = \zeta(b - a)$ (Throughput: 1 kupu-kupu / siklus).
3. **PWM (Base-Case Multiplication):** Perkalian dua elemen pada ring $\mathbb{Z}_q[X]/(X^2 - \zeta)$. Menggunakan **2 pengali modular paralel** dengan penjadwalan 4 fase ($II = 4$):
   - Fase 0: $d \cdot \gamma$ (Mult 0) dan $a_0 \cdot b_0$ (Mult 1).
   - Fase 1: $a_0 \cdot b_1$ (Mult 0) dan $a_1 \cdot b_0$ (Mult 1).
   - Fase 2: Idle pipeline.
   - Fase 3: $a_1 \cdot (d \cdot \gamma)$ (Mult 0) memanfaatkan hasil Fase 0 yang selesai di siklus ke-3.
   - Output: $y_0 = a_0 b_0 + a_1 b_1 \gamma, \quad y_1 = a_0 b_1 + a_1 b_0$.
4. **ADD:** $y_0 = (a + b) \bmod q$.
5. **SUB:** $y_0 = (a - b) \bmod q$.
6. **SCALE:** $y_0 = (a \cdot 128^{-1}) \bmod q$.

#### C. Modular Multiplier & Barrett Reducer (`mlkem_modmul.v`)

- Menghitung $r = (x \times y) \bmod 3329$ dalam 3 siklus *constant-time pipeline* (throughput 1 operasi/siklus):
  - Stage 1: $p_1 = x \times y$ ($12 \times 12$ unsigned multiply).
  - Stage 2: Estimasi kuosien Barrett $q_e = \lfloor (p_1 \times 5039) / 2^{24} \rfloor$ dengan $5039 = \lfloor 2^{24}/3329 \rfloor$.
  - Stage 3: Rekonstruksi residu $rr = p_2 - q_e \times 3329$, diikuti satu subtraksi kondisional konstan-waktu `r = (rr >= 3329) ? (rr - 3329) : rr`.

#### D. Antarmuka Bus Avalon-MM & CSR (`mlkem_csr.v`)

- **Peta Alamat Register (Word Offset 32-bit):**
  - `0x000` (`ID`): Read-Only `32'h4D4C4B31` ("MLK1").
  - `0x001` (`CTRL`): Bit 0 = `START` (self-clearing), Bit 1 = `IRQ_EN`.
  - `0x002` (`STATUS`): Bit 0 = `BUSY`, Bit 1 = `DONE` (W1C), Bit 2 = `ERR` (W1C).
  - `0x003` (`OP`): Mode operasi (0=FNTT, 1=INTT, 2=PWM, 3=ADD, 4=SUB, Bit 3=INTT Scale Enable).
  - `0x004` (`SLOT`): `[1:0]` Slot A, `[3:2]` Slot B, `[5:4]` Slot Destinasi.
  - `0x005` (`CYCLES`): Jumlah siklus eksekusi operasi terakhir.
  - `0x400`–`0x5FF`: Jendela memori 512 kata (4 slot $\times$ 128 kata).
- **Mekanisme Proteksi:**
  - Penulisan ke `CTRL`, `OP`, dan `SLOT` saat `BUSY=1` otomatis diblokir dan menyalakan flag `ERR`.
  - Dekode memori scratchpad dibatasi secara eksak pada bit `[10:9] == 2'b10` guna meniadakan aliasing alamat.
  - Jalur baca `avs_readdata` diregisterkan dengan latensi 2 siklus yang disinkronkan via sinyal `avs_readdatavalid`.

---

## 3. Hasil Sintesis & Place & Route Fisik

Sintesis logika dan *Fitting* (Place & Route) dilakukan menggunakan **Intel Quartus Prime 18.1.0 Lite Edition** dengan target FPGA SoC **Cyclone V 5CSEBA6U23I7** (spesifikasi papan Terasic DE10-Nano).

### 3.1 Tabel Utilisasi Sumber Daya Perangkat Keras

| Komponen Sumber Daya                      | Estimasi Awal Proposal |      Realisasi Quartus Riil      | Kapasitas Tersedia DE10-Nano | Persentase Utilisasi |                   Status                   |
| :---------------------------------------- | :--------------------: | :-------------------------------: | :--------------------------: | :------------------: | :-----------------------------------------: |
| **Adaptive Logic Modules (ALMs)**   |       3.850 ALMs       |       **2.381 ALMs**       |         41.910 ALMs         |   **5,68%**   | **Sangat Hemat** (-38% dari estimasi) |
| **Dedicated Logic Registers (FFs)** |       3.200 FFs       |        **1.341 FFs**        |         167.640 FFs         |   **0,80%**   | **Sangat Hemat** (-58% dari estimasi) |
| **Block RAM (M10K / RAM Blocks)**   |      17 blok M10K      | **9 blok RAM** (17.378 bit) |           553 blok           |   **1,63%**   | **Sangat Hemat** (-47% dari estimasi) |
| **Blok DSP Fisik (18x19)**          |       4 blok DSP       |       **16 blok DSP**       |         112 blok DSP         |   **14,28%**   | **Aman & Longgar** (Tersedia 96 blok) |
| **I/O Pins (Interkoneksi Avalon)**  |           —           |         **81 pin**         |           314 pin           |   **25,80%**   |        **Sesuai Standar Qsys**        |

### 3.2 Analisis Pemanfaatan Sumber Daya

1. **Penghematan Signifikan pada Logika & BRAM:**
   - Estimasi awal proposal mengasumsikan 17 blok M10K karena memperhitungkan pemisahan fisik bank per slot polinomial. Implementasi aktual hanya menggunakan **9 blok RAM** (4 bank scratchpad M10K + 1 Twiddle ROM + blok penunjang internal), membuktikan keunggulan fungsi hashing bijektif `bank_of`.
   - Jumlah ALM (2.381 ALM) jauh di bawah batas toleransi 10% yang disyaratkan dalam panduan kompetisi PERURI Chip Hackathon 2026.
2. **Karakteristik Alokasi Blok DSP:**
   - Desain mengimplementasikan 8 unit pengali modular fisik (4 PE $\times$ 2 multiplier per PE).
   - Quartus mengalokasikan 16 blok DSP karena menginferensikan perkalian primer ($x \times y$) dan perkalian konstanta Barrett ($p_1 \times 5039$) ke dalam blok DSP hardware. Alokasi 16 dari 112 blok DSP (~14%) masih sangat aman dan memberikan kecepatan komputasi aritmetika yang maksimal.

---

## 4. Analisis Kinerja, Latensi, dan Pewaktuan (Timing)

### 4.1 Latensi Eksekusi Siklus Komputasi

Pengukuran latensi dilakukan secara siklus-akurat (*cycle-accurate*) menggunakan register `CYCLES` pada testbench sistem:

| Operasi Polinomial ML-KEM               |  Target Proposal  | Hasil Baseline (1 Mult) | Hasil Optimasi Terkini (Dual Mult) |           Margin terhadap Target           |
| :-------------------------------------- | :----------------: | :---------------------: | :--------------------------------: | :-----------------------------------------: |
| **Forward NTT (FNTT)**            | $\le 300$ siklus |       274 siklus       |        **274 siklus**        |        **+8,67% Lebih Cepat**        |
| **Inverse NTT (INTT, raw)**       | $\le 300$ siklus |       274 siklus       |        **274 siklus**        |        **+8,67% Lebih Cepat**        |
| **INTT + Scaling ($128^{-1}$)** |         —         |       345 siklus       |        **345 siklus**        |                     —                     |
| **Pointwise Multiply (PWM)**      | $\le 150$ siklus |       172 siklus       |        **140 siklus**        | **+6,67% Lebih Cepat (Target Lolos)** |
| **Polynomial Addition (ADD)**     | $\le 100$ siklus |        72 siklus        |        **72 siklus**        |        **+28,00% Lebih Cepat**        |
| **Polynomial Subtraction (SUB)**  | $\le 100$ siklus |        72 siklus        |        **72 siklus**        |        **+28,00% Lebih Cepat**        |
| **Standalone Scaling (SCALE)**    |         —         |        72 siklus        |        **72 siklus**        |                     —                     |

#### Analisis Peningkatan Latensi PWM:

- Pada arsitektur awal (1 multiplier per PE), setiap pasangan koefisien membutuhkan 5 slot waktu ($II = 5$), menghasilkan:
  $$
  \text{Latensi Awal} = (32\text{ grup} \times 5) + 12 = 172\text{ siklus}
  $$
- Dengan penambahan pengali kedua dan restrukturisasi urutan $a_1 \cdot (b_1 \cdot \gamma)$, interval inisiasi turun menjadi $II = 4$:
  $$
  \text{Latensi Teroptimasi} = (32\text{ grup} \times 4) + 12 = \mathbf{140\text{ siklus}}
  $$
- Hasil ini berhasil mengembalikan metrik PWM ke bawah target proposal ($\le 150$ siklus) tanpa menimbulkan tabrakan akses memori bank.

### 4.2 Analisis Pewaktuan Statis (TimeQuest STA)

- **Model Pewaktuan:** Slow 1100mV 100°C / Slow 1100mV -40°C.
- **Frekuensi Kerja Terukur ($F_{max}$):**
  - Model Slow 100°C: **78,12 MHz** (Restricted $F_{max}$).
  - Model Slow -40°C: **80,46 MHz**.
  - Jalur Register-to-Register internal bersih: **93,12 MHz**.

#### Diagnostik Jalur Kritis (*Critical Path Diagnostic*):

Analisis mendalam pada laporan `worst_paths.txt` menunjukkan jalur dengan slack negatif terbesar ($-6,13\text{ ns}$ pada constraint $150\text{ MHz} / 6,667\text{ ns}$) berasal dari:

$$
\text{Register FSM } (\texttt{layer}, \texttt{grp}) \longrightarrow \text{Logic Shifter & Indexing NTT} \longrightarrow \text{Hash Function } \texttt{bank\_of} \longrightarrow \text{Port Address M10K}
$$

- **Data Delay:** $12,431\text{ ns}$ (kombinatorial murni dalam Stage R).
- **Akar Masalah:** Di dalam `mlkem_ctrl.v`, parameter layer ($k, kk, sh, hh, dd$) dihitung ulang setiap siklus menggunakan dynamic variable barrel shifter (`g5 >> sh`), kemudian dijumlahkan dan dimasukkan ke 4-level adder pada fungsi `bank_of`, lalu di-demux ke alamat M10K sebelum clock edge berikutnya.
- **Solusi Lanjutan yang Direkomendasikan:**
  Memisahkan kalkulasi parameter layer ke dalam register terpisah saat pergantian layer (`S_WAIT_LAYER`), serta menyisipkan satu tingkat register pipeline pada alamat memori (`c_raddr`). Ini akan memangkas delay $12,4\text{ ns}$ menjadi $\approx 4,5\text{ ns}$, mendongkrak $F_{max}$ langsung ke **150–200 MHz**.

---

## 5. Metodologi dan Hasil Verifikasi

Verifikasi fungsional mengadopsi prinsip *multi-tier verification* secara komprehensif:

```
                      [ FIPS 203 Reference C (PQClean) ]
                                       │
                                       ▼
                     [ Python Golden Model (golden_mlkem.py) ]
                                       │
                  ┌────────────────────┴────────────────────┐
                  ▼                                         ▼
         [ Unit Testbenches ]                      [ System-Level KAT ]
         - tb_modmul (11,08M ops)                  - tb_top (Avalon-MM)
         - tb_pe (24.000 ops)                      - Vektor Uji Acak & Corner
         - tb_scratchpad (Parallel R/W)            - 34 Test Cases (Self-Checking)
```

### Rangkuman Hasil Pengujian:

1. **`tb_modmul.v` (Exhaustive Test):**
   - Menguji seluruh $3.329 \times 3.329 = \mathbf{11.082.241}$ kombinasi input perkalian modular.
   - Hasil: **0 Error (100% Pass)**.
2. **`tb_pe.v` (Unit Test Arithmetic Core):**
   - Menjalankan **24.000 operasi** acak dan corner-case mencakup seluruh mode (FNTT, INTT, PWM, ADD, SUB, SCALE).
   - Hasil: **0 Error**, latensi non-PWM tepat 5 siklus, latensi PWM tepat 8 siklus.
3. **`tb_scratchpad.v` (Memory Interleaving Test):**
   - Memverifikasi sifat bijeksi, kebebasan konflik satu-bit, serta pembacaan/penulisan paralel 4-way simultan pada 512 kata memori.
   - Hasil: **0 Collision, 0 Error**.
4. **`tb_top.v` (End-to-End System Test):**
   - Memverifikasi transaksi baca/tulis bus Avalon-MM, eksekusi rantai penuh $FNTT(a) \rightarrow FNTT(b) \rightarrow PWM(A,B) \rightarrow INTT(C) \equiv a \times b \pmod{X^{256}+1}$.
   - Memverifikasi kasus sudut (*corner polynomial*: koefisien $0, 1, q-1, q-2, 1664$).
   - Memverifikasi penanganan error register saat konfigurasi tidak valid atau akses saat busy.
   - Hasil: **ALL 34 TESTS PASSED (Bit Error Rate = 0%)**.

---

## 6. Rekomendasi Penyelarasan Draf Proposal

Berdasarkan hasil nyata yang dicapai pada RTL dan Quartus Prime, bagian-bagian berikut pada draf proposal disarankan untuk disesuaikan:

1. **Tabel 1 (Estimasi Sumber Daya):**
   - Ubah estimasi Block RAM (M10K) dari **17 blok** menjadi **9 blok RAM (~1,6%)**. Tonjolkan penghematan 47% ini sebagai hasil efisiensi arsitektur *shared conflict-free mapping*.
   - Perbarui jumlah DSP dari **4 blok** menjadi **16 blok DSP (~14,2%)**, dengan penjelasan bahwa akselerator memanfaatkan arsitektur *dual-multiplier per PE* untuk memangkas latensi PWM.
   - Perbarui utilisasi ALM dari **3.850 ALMs** menjadi **2.381 ALMs (~5,7%)**.
2. **Tabel Metrik Keberhasilan:**
   - Ubah spesifikasi PWM dari $\le 150$ siklus menjadi **140 siklus**.
   - Berikan catatan pemisahan pada INTT: **INTT raw = 274 siklus**, **INTT terintegrasi scaling = 345 siklus**.
3. **Deskripsi Memori Scratchpad:**
   - Perjelas kalimat deskripsi: *"Scratchpad memory berkapasitas logis $256 \times 16\text{-bit}$ per slot yang diimplementasikan secara fisik sebagai arsitektur 4-bank interleaved Pack32 ($128 \times 32\text{-bit}$) guna memaksimalkan throughput data pada bus Avalon-MM 32-bit."*

---

## 7. Kesimpulan

Codebase Proof-of-Concept (PoC) akselerator ML-KEM pada repositori ini telah berhasil membuktikan seluruh konsep inovasi yang diajukan dalam proposal:

- Rantai komputasi polinomial FNTT, INTT, PWM, dan ADD terbukti dapat diselesaikan secara terpadu di dalam memori lokal tanpa membebani bus prosesor.
- Pengoptimalan unit PE dengan pengali ganda berhasil melampaui target latensi PWM menjadi 140 siklus.
- Penggunaan sumber daya sangat hemat (<6% logika FPGA Cyclone V) dengan akurasi 100% bit-akurat terhadap standar NIST FIPS 203.
- Jalur kritis telah teridentifikasi secara presisi pada Stage R address generation, memberikan roadmap teknis yang jelas untuk mencapai target frekuensi 150–200 MHz pada iterasi berikutnya.

Rancangan ini berada dalam status **sangat siap dan solid** untuk dipresentasikan dan diimplementasikan pada tahap selanjutnya dalam PERURI Chip Design Hackathon 2026.
