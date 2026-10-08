# Rancangan Akselerator ML-KEM Berbasis Unit Komputasi Terpadu dan Bank Memori Lokal via Antarmuka Avalon-MM pada SoC FPGA Intel Cyclone V DE10-Nano

## Chip Hackathon – PERURI Digital Summit 2026
**Kategori:** IC Chip Design & FPGA Implementation

## Tim NamTIMAPAWOY
- Andhika Narawangsa Susilo – Institut Teknologi Bandung – 13222036@mahasiswa.itb.ac.id 
- Rafi Ananta Alden – Institut Teknologi Bandung – 13222087@mahasiswa.itb.ac.id
- Didan Attaric – Institut Teknologi Bandung – 13222105@mahasiswa.itb.ac.id
- Ibrahim Hanif Mulyana – Institut Teknologi Bandung – 13222111@mahasiswa.itb.ac.id

**Dosen Pembimbing:** Dr. Yusuf Kurniawan, S.T., M.T. – Program Studi Teknik Elektro, Institut Teknologi Bandung

---

## Chip Design Architecture

![Chip Design Architecture](./docs/Architecture.png)

*Gambar 1 – Diagram blok rancangan akselerator.*

![Data Flow Diagram](./docs/DFD.png)

*Gambar 2 – Data Flow Diagram.*

Dokumentasi arsitektur lengkap tersedia di folder [`docs/`](./docs).

---

## Ringkasan Ide

### Masalah yang Diangkat
Standardisasi *Post-Quantum Cryptography* (PQC) oleh NIST, khususnya **FIPS 203 (ML-KEM)**, menandai
pentingnya keamanan data nasional yang tidak terbatas pada dokumen elektronik dan identitas digital.
Pada skema berbasis *module-lattice*, perkalian vektor-kolom di atas cincin polinomial menjadi salah satu
*computational bottleneck*, dan implementasi perangkat lunak membutuhkan ratusan ribu siklus clock.
Sebagian besar akselerator konvensional hanya mempercepat *Number Theoretic Transform* (NTT) secara
terisolasi tanpa memitigasi latensi pemindahan data, sehingga terjadi **bus-choking**: waktu transfer data
CPU–akselerator melalui bus sistem melampaui waktu komputasi itu sendiri.

### Solusi yang Ditawarkan
IP core kriptografi perangkat keras yang memadukan **empat PE serbaguna** dan **empat bank memori lokal**
untuk mengeksekusi seluruh siklus kalkulasi ML-KEM **FNTT → PWM → ADD → INTT** secara internal, tanpa
membebani bus sistem dengan transfer data perantara.

### Implementasi pada DE10-Nano
Rancangan diimplementasikan pada FPGA fabric Intel Cyclone V SoC (board Terasic DE10-Nano) dan terhubung ke
*Hard Processor System* (HPS) ARM Cortex-A9 melalui bus interkoneksi Avalon-MM 32-bit.

### Kebaruan dan Keunggulan
- **Area-Time Efficiency:** berbagai mode komputasi polinomial digabung dalam satu datapath terpadu untuk
  menghilangkan redundansi logika dan mengoptimalkan *Area-Time Product* (ATP).
- **Amdahl-Optimized Bus Interfacing:** data perantara dilokalisasi di memori internal akselerator untuk
  meminimalkan bottleneck transfer pada bus sistem.
- **Constant-Time Side-Channel Resilience:** datapath *constant-time* yang independen dari variasi data
  untuk mencegah kebocoran informasi melalui *timing attack*.

---

## Latar Belakang & Rumusan Masalah

Algoritma kunci publik klasik (RSA, ECC) rentan terhadap algoritma Shor pada komputer kuantum. Operasi dasar
ML-KEM berlangsung di cincin polinomial

    R_q = Z_q[x] / (x^256 + 1),   q = 3329,   n = 256

Pendekatan domain waktu berkompleksitas O(n²); NTT menurunkannya menjadi O(n log n). Selama KeyGen,
Encapsulation, dan Decapsulation, operasi FNTT, INTT, dan PWM dipanggil berulang kali dan menyerap lebih dari
60% waktu eksekusi total.

**Rumusan masalah:**
1. Bagaimana merancang unit komputasi terpadu yang kompak untuk mengeksekusi FNTT, INTT, PWM, dan ADD secara
   bergantian dengan efisiensi sumber daya yang baik pada FPGA DE10-Nano?
2. Bagaimana merancang struktur bank memori lokal yang *conflict-free* sehingga seluruh rantai kalkulasi
   polinomial selesai di dalam akselerator tanpa bottleneck transfer data?
3. Bagaimana mempertahankan karakteristik *Constant-Time Execution* sekaligus mencapai *timing closure* pada
   frekuensi target?

---

## Arsitektur Sistem

Sistem terdiri dari dua domain: **Host Processor System (HPS)** ARM Cortex-A9 dan **FPGA Fabric** yang
menjalankan komputasi inti (Gambar 1).

| Blok | Modul | Deskripsi |
|---|---|---|
| **a** | Bus Interface & Control Unit | *Control/Status Registers* (CSR) dan port data antarmuka bus sistem (Avalon-MM Slave untuk Start/Reset dari HPS, Avalon-MM Master & DMA untuk burst read/write DDR3), serta *Top-Level Operation FSM* |
| **b** | Bank-Centered Scratchpad Memory | 4 bank SRAM *simple dual-port* independen berukuran **128 × 32 bit**, *interleaved* (Pack32: 2 koefisien per kata) |
| **c** | Unified Arithmetic Core (KDA Computational Unit) | 4 PE paralel (butterfly CT/GS, PWM, atau ADD/SUB vektor), masing-masing dengan *Unified Modular Multiplier*, *Pipeline 2-Cycle Modular Reducer* (Barrett/KRED), dan *Accumulator* |
| **d** | Twiddle Factor Memory | ROM internal penyimpan tabel konstanta transformasi (ζ⁺) untuk FNTT/INTT |

### Estimasi Penggunaan Sumber Daya FPGA

| Komponen | Estimasi | Kapasitas DE10-Nano | Utilisasi |
|---|---|---|---|
| Adaptive Logic Modules (ALMs) | 3.850 | 41.910 | ~9,18% |
| Logic Elements (LEs) | ~10.200 | 110.000 | ~9,27% |
| Flip-Flops (FFs) | 3.200 | 167.640 (dalam ALM) | ~1,90% |
| Blok DSP | 4 | 112 | ~3,57% |
| Block RAM (M10K) | 5 | 557 blok (5.570 Kbit) | ~0,89% |
| Target Fmax | 150 – 200 MHz | – | – |

> Angka di atas masih berupa **estimasi**; nilai aktual akan diperbarui setelah sintesis di Quartus Prime.

---

## Penentuan Arsitektur: Cycle Model

Pemilihan konfigurasi arsitektur didasarkan pada model siklus di
[`model/mlkem_cycle_model.py`](./model/mlkem_cycle_model.py), yang membandingkan tujuh konfigurasi memori dan
jumlah PE pada NTT/INTT dan PWM, serta menghitung *break-even* latensi bus agar akselerator tidak menjadi
bottleneck.

```bash
python model/mlkem_cycle_model.py
```

### Perbandingan konfigurasi (siklus @ 150 MHz)

| Konfigurasi | NTT | INTT | PWM | Batas PWM | DSP | M10K | BW (koef/siklus R+W) |
|---|---|---|---|---|---|---|---|
| C0 – 1 poli/bank, TDP16 | 1849 | 1849 | 277 | MEM | 2 | 5 | 2 |
| C1 – 4 bank interleave, TDP16 | 505 | 505 | 181 | CMP | 2 | 17 | 8 |
| C2 – pack32, 2 bank/poli, 4 PE | 505 | 505 | 101 | CMP | 4 | 9 | 8 |
| **C3 – pack32, 4 bank/poli, 4 PE** ✅ | **281** | **281** | **101** | CMP | **4** | **17** | **16** |
| C4 – pack32, 4 bank/poli, 8 PE | 281 | 281 | 61 | CMP | 8 | 17 | 16 |
| C5 – pack32, 2 bank/poli, 2 PE (*area-eff.*) | 505 | 505 | 181 | CMP | 2 | 9 | 8 |
| C6 – pack32, 8 bank/poli, 8 PE | 169 | 169 | 61 | CMP | 8 | 33 | 32 |

Batas bawah teoretis NTT dari struktur algoritma: 896 butterfly / n_PE → 2 PE: 448, **4 PE: 224**, 8 PE: 112 siklus.

### Mengapa C3 (pack32, 4 bank/poli, 4 PE)?
- **Seimbang:** pada C3 setiap layer NTT berstatus *BALANCED* (bandwidth memori = kapasitas komputasi) dengan
  utilisasi PE **100%**. Pada C2 dan C1 PE hanya terpakai 50% karena terbatas memori (*MEM-bound*).
- **Lebih murah dari C4:** menambah PE menjadi 8 (C4) tidak mempercepat NTT (tetap 281 siklus, utilisasi turun
  ke 50%, karena kembali *MEM-bound*) dan hanya menurunkan PWM, dengan DSP dua kali lipat.
- **Memenuhi target latensi:** NTT/INTT 281 siklus (≤ 300) dan PWM 101 siklus (≤ 150).
- Parameter C3 pada model: PE = 4, mult/cycle = 8, word = 2 koefisien, bank/poli = 4, mode SDP.

### Break-even bus (pencegahan bottleneck)
Model menghitung batas latensi bus per kata agar akselerasi end-to-end tetap menguntungkan. Untuk C3, satu NTT
(masukan + keluaran = 256 kata) harus memiliki latensi bus **< 66 ns/kata** (SW 18,8 µs vs HW 1,87 µs). Di atas
batas ini transfer data melampaui keuntungan komputasi, itulah alasan seluruh rantai FNTT → PWM → ADD → INTT
dijalankan secara internal dan hanya masukan awal serta hasil akhir yang melewati bus.

---

## Rencana Pengujian (Multi-Tier Verification)

1. **Validasi Golden Model:** PQClean (C) sebagai referensi resmi NIST untuk membangkitkan vektor uji
   deterministik / *Known Answer Test* (KAT) bagi seluruh operasi polinomial.
2. **Simulasi Fungsional:** *self-checking testbench* (QuestaSim) yang membandingkan luaran bit-demi-bit terhadap
   data KAT secara otomatis.
3. **Simulasi Pewaktuan:** kompilasi penuh Quartus Prime dan TimeQuest Timing Analyzer; target *timing closure*
   (WNS > 0) pada kondisi *worst-case slow-corner*, 150–200 MHz.
4. **Hardware-in-the-Loop:** bitstream diunggah ke DE10-Nano untuk mengukur latensi riil via CPU ARM serta
   memverifikasi integritas bus Avalon-MM dan *in-system debugging* via SignalTap II.

## Metrik Keberhasilan

| Metrik | Target |
|---|---|
| Akurasi | 100% (Bit Error Rate = 0%) |
| Latensi | FNTT/INTT ≤ 300 siklus; PWM ≤ 150 siklus; ADD/SUB ≤ 100 siklus |
| Speedup dibanding baseline CPU | > 25× |
| Utilisasi sumber daya (DE10-Nano) | < 10% |
| Eliminasi latensi bus HPS–FPGA | > 85% |

---

## Struktur Repositori

```
ML-KEM_Unified_Accelerator_DE10Nano/
├── README.md
├── docs/                    Architecture.png, DFD, dokumentasi arsitektur
├── model/
│   └── mlkem_cycle_model.py model siklus (dasar penentuan arsitektur C3)
└── baseline_system/         PoC RTL + testbench (baseline)
    ├── rtl/                 mlkem_modmul, mlkem_pe, mlkem_arith_core      (blok c)
    │                        mlkem_bank_mem, mlkem_scratchpad              (blok b)
    │                        mlkem_zeta_rom (di-generate)                  (blok d)
    │                        mlkem_csr, mlkem_ctrl, mlkem_top              (blok a + integrasi)
    ├── tb/                  tb_modmul, tb_pe, tb_scratchpad, tb_top, vectors/
    ├── scripts/             golden_mlkem.py, gen_rom.py, gen_vectors.py
    ├── sw/                  mlkem_regs.h (peta register untuk driver HPS)
    ├── quartus/             constraint awal (mlkem_poc.sdc)
    └── Makefile
```

## Cara Menjalankan

**Prasyarat:** Python 3, [Icarus Verilog](https://github.com/steveicarus/iverilog) (`sudo apt install iverilog`).
Untuk melihat gelombang: GTKWave.

```bash
# 1. Model siklus (penentuan arsitektur)
python model/mlkem_cycle_model.py

# 2. PoC baseline: golden model + ROM + vektor + unit test + tes sistem
cd baseline_system
make regress        # keluaran akhir yang diharapkan: "ALL 34 TESTS PASSED"
```

| Target `make` | Fungsi |
|---|---|
| `gen` | Menjalankan golden model, membangkitkan ROM twiddle dan vektor uji |
| `unit` | Unit test: modular multiplier, PE, peta bank scratchpad |
| `sim` | Tes sistem *self-checking* melalui bus Avalon-MM |
| `regress` | `gen` + `unit` + `sim` |
| `clean` | Menghapus artefak simulasi |

## Status Proyek

| Tahap | Status |
|---|---|
| Penentuan arsitektur (cycle model) | ✅ Selesai – konfigurasi C3 |
| Golden model Python (NTT/INTT/PWM, FIPS 203) | ✅ Selesai |
| PoC RTL + testbench (simulasi fungsional) | ✅ Lulus (`make regress`) |
| Cross-check golden model ke PQClean (KAT) | ⬜ Belum |
| Sintesis Quartus, STA, laporan sumber daya | ⬜ Belum |
| Integrasi HPS via Platform Designer (Qsys), DMA/Avalon-MM Master | ⬜ Belum |
| Driver Linux ARM, benchmark, SignalTap II | ⬜ Belum |

> Hasil dan analisis teknis (latensi terukur, sumber daya hasil sintesis, timing) akan ditambahkan setelah
> tahap sintesis dan Hardware-in-the-Loop selesai.

## Rencana Bootcamp Tiga Hari

| Hari | Fokus | Target luaran |
|---|---|---|
| 1 | Integrasi bus Avalon-MM & verifikasi board: menghubungkan RTL dengan HPS ARM via Platform Designer (Qsys), verifikasi transfer data dan handshake register | Bitstream lengkap terunduh di DE10-Nano; komunikasi HPS–FPGA tervalidasi bebas galat pada 150 MHz |
| 2 | Benchmarking beban riil & uji daya: vektor uji skala penuh, ukur siklus riil dan estimasi daya | Data empiris latensi per stage; verifikasi peningkatan performa ≥ 15×–40× terhadap baseline CPU |
| 3 | Finalisasi purwarupa & persiapan presentasi: konsol GUI interaktif pemantau latensi pada HPS, pitching | Purwarupa siap didemonstrasikan; slide presentasi final |

## Perangkat Lunak & Tools

- **Intel Quartus Prime & TimeQuest** – sintesis RTL, place & route, bitstream (.sof/.rbf), STA
- **Intel Platform Designer (Qsys)** – interkoneksi HPS ↔ akselerator via Lightweight HPS-to-FPGA bridge dan IRQ
- **Siemens QuestaSim & SignalTap II** – simulasi RTL siklus-akurat dan debugging in-system
- **Python 3 & PQClean** – generator tabel twiddle/stimulus uji dan golden software model
- **GNU Arm Embedded Toolchain & Embedded Linux** – driver C pada HPS via pemetaan memori kernel

## Referensi

1. PERURI, *Panduan & Format Proposal PERURI Chip Hackathon 2026: Kategori IC Chip Design & FPGA Implementation*, PERURI Digital Summit, Sep. 2026. https://summit.peruri.co.id/hackathon
2. J. Kim, J. Kang, S. Baek, J. Choi, "A Configurable ML-KEM (Kyber) Key-Encapsulation Hardware Accelerator Architecture," *IEEE TCAS-II*, 2024.
3. Z. Ni et al., "A Highly Hardware Efficient ML-KEM Accelerator with Optimised Architectural Layers," *ACM TECS*, vol. 24, no. 2, Art. 25, Jan. 2025.
4. T.-H. Nguyen et al., "A Low-Latency Polynomial Arithmetic Unit for ML-KEM and ML-DSA Standards," *IEEE TCAS-II*, 2026.
5. NUDT PQC Research Group, "A One-Bitstream KV260 Accelerator for ML-KEM-512 and ML-DSA-44 with Split KEM Datapaths and Sign-Path Early Rejection," *IEEE TVLSI*, 2026.
6. S. Xu, M. Liu, Z. Pu, "A Unified Dual-Architecture Methodology for FPGA Acceleration of ML-KEM and ML-DSA," *IEEE Trans. Computers*, 2026.
7. W. Mo et al., "An FPGA-Based ML-KEM/ML-DSA Accelerator with Shared Engines and Rejection-Aware Signing Scheduling," *IEEE Embedded Systems Letters*, 2026.
8. Y.-C. Tsai, Y.-H. Lin, W.-J. Hwang, "An Open-Hardware ML-KEM Polynomial Ring Accelerator on Chipyard RISC-V SoC: System-Level Integration and Evaluation," *Preprints.org*, Mei 2026, doi: 10.20944/preprints202605.1405.v1.
9. D. E. S. Kundi, J. M. B. Mera, P.-Y. Strub, M. Hutter, "High-Performance NTT Hardware Accelerator to Support ML-KEM and ML-DSA," *ASHES '24*, ACM, Okt. 2024, pp. 1–11.
10. T. Korycki, "kyber-ntt-fpga," GitHub, 2024. https://github.com/tonykorycki/kyber-ntt-fpga
