#!/usr/bin/env python3
"""
render_waveform.py -- Automated waveform generator and GTKWave config builder.
Extracts simulation events from sim/tb_top.vcd and generates:
  1. docs/waveform_mlkem_full_chain.png  (Overview of FNTT -> PWM -> INTT chain)
  2. docs/waveform_pwm_zoom.png          (Zoomed view of accelerated PWM execution)
  3. sim/mlkem_waveform.gtkw             (GTKWave savefile for interactive inspection)
"""

import os
import sys
import matplotlib.pyplot as plt
import matplotlib.patches as patches
import numpy as np

BASE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
VCD_FILE = os.path.join(BASE_DIR, "sim", "tb_top.vcd")
DOCS_DIR = os.path.abspath(os.path.join(BASE_DIR, "..", "docs"))
os.makedirs(DOCS_DIR, exist_ok=True)

# Parse VCD symbol mapping
def parse_vcd_symbols(vcd_path):
    sym_map = {}
    current_scope = []
    with open(vcd_path, "r") as f:
        for line in f:
            line = line.strip()
            if line.startswith("$scope"):
                current_scope.append(line.split()[2])
            elif line.startswith("$upscope"):
                if current_scope:
                    current_scope.pop()
            elif line.startswith("$var"):
                parts = line.split()
                var_type = parts[1]
                var_width = int(parts[2])
                var_sym = parts[3]
                var_name = parts[4]
                full_name = ".".join(current_scope + [var_name])
                sym_map[var_sym] = {
                    "name": var_name,
                    "full_name": full_name,
                    "width": var_width,
                    "type": var_type
                }
            elif "$enddefinitions" in line:
                break
    return sym_map

def extract_signals(vcd_path, target_names, t_start_ps, t_end_ps):
    sym_map = parse_vcd_symbols(vcd_path)
    tracked_syms = {}
    for sym, info in sym_map.items():
        if info["full_name"] in target_names:
            tracked_syms[sym] = info["full_name"]

    # History: name -> list of (time_ps, val)
    signal_history = {name: [] for name in target_names.values()}
    current_vals = {name: 0 for name in target_names.values()}

    with open(vcd_path, "r") as f:
        t = 0
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("#"):
                t = int(line[1:])
                if t > t_end_ps:
                    break
            elif line.startswith("b") or line.startswith("B"):
                # Multi-bit bus: e.g. b1010 K%
                parts = line.split()
                if len(parts) >= 2:
                    val_str = parts[0][1:]
                    sym = parts[1]
                    if sym in tracked_syms:
                        name = tracked_syms[sym]
                        try:
                            val = int(val_str, 2)
                        except ValueError:
                            val = 0
                        current_vals[name] = val
                        if t >= t_start_ps:
                            signal_history[name].append((t, val))
            else:
                # 1-bit signal: e.g. 1B or 0B
                if len(line) >= 2:
                    val_char = line[0]
                    sym = line[1:]
                    if sym in tracked_syms:
                        name = tracked_syms[sym]
                        val = 1 if val_char == '1' else 0
                        current_vals[name] = val
                        if t >= t_start_ps:
                            signal_history[name].append((t, val))

    return signal_history

def render_overview(signal_history, out_png):
    # Time window: 0 to 22 us (0 to 22,000,000 ps)
    t_max_us = 22.0
    
    fig, ax = plt.subplots(figsize=(16, 10), dpi=300)
    plt.subplots_adjust(left=0.18, right=0.96, top=0.90, bottom=0.08)

    signals_to_plot = [
        ("tb_top.clk", "CLK (150 MHz)", "digital", "#34495e"),
        ("tb_top.rst_n", "RESET_N", "digital", "#2980b9"),
        ("tb_top.avs_write", "AVS_WRITE", "digital", "#e67e22"),
        ("tb_top.avs_read", "AVS_READ", "digital", "#d35400"),
        ("tb_top.dut.start", "CSR START", "digital", "#27ae60"),
        ("tb_top.dut.busy", "COPROCESSOR BUSY", "digital", "#c0392b"),
        ("tb_top.dut.done_pulse", "DONE_PULSE", "digital", "#16a085"),
        ("tb_top.irq", "HOST IRQ", "digital", "#8e44ad"),
        ("tb_top.dut.c_re", "SPM READ (c_re[3:0])", "bus", "#2c3e50"),
        ("tb_top.dut.c_we", "SPM WRITE (c_we[3:0])", "bus", "#7f8c8d"),
        ("tb_top.dut.core_valid", "PE CORE_VALID", "digital", "#1abc9c"),
        ("tb_top.dut.core_out_valid", "PE CORE_OUT_VALID", "digital", "#16a085"),
        ("tb_top.dut.u_ctrl.layer", "NTT LAYER [2:0]", "bus", "#2980b9"),
        ("tb_top.dut.op", "OPERATION MODE", "bus_label", "#8e44ad"),
    ]

    op_names = {0: "FNTT", 1: "INTT", 2: "PWM", 3: "ADD", 4: "SUB", 5: "SCALE"}

    y_spacing = 1.4
    y_base = len(signals_to_plot) * y_spacing

    for i, (sig_name, label, sig_type, color) in enumerate(signals_to_plot):
        y = y_base - i * y_spacing
        events = signal_history.get(sig_name, [])
        if not events:
            continue

        # Convert events to step series
        times = [0.0]
        vals = [events[0][1] if events else 0]
        for t_ps, v in events:
            t_us = t_ps / 1e6
            if t_us > t_max_us:
                break
            times.append(t_us)
            vals.append(v)
        times.append(t_max_us)
        vals.append(vals[-1])

        # Plot based on type
        if sig_type == "digital":
            # Normalize 0..1
            step_y = [y + (0.8 if v != 0 else 0.0) for v in vals]
            ax.step(times, step_y, where="post", color=color, lw=1.6)
            # Fill under high
            for j in range(len(times) - 1):
                if vals[j] != 0:
                    ax.fill_between([times[j], times[j+1]], y, y + 0.8, color=color, alpha=0.15)
        elif sig_type == "bus":
            # Bus representation (high when non-zero, low when zero)
            step_y = [y + (0.8 if v != 0 else 0.0) for v in vals]
            ax.step(times, step_y, where="post", color=color, lw=1.4)
            for j in range(len(times) - 1):
                if vals[j] != 0 and (times[j+1] - times[j]) > 0.05:
                    ax.fill_between([times[j], times[j+1]], y, y + 0.8, color=color, alpha=0.2)
                    mid_t = (times[j] + times[j+1]) / 2.0
                    if (times[j+1] - times[j]) > 0.4:
                        ax.text(mid_t, y + 0.4, f"0x{vals[j]:X}", ha="center", va="center", fontsize=7, color="#2c3e50")
        elif sig_type == "bus_label":
            step_y = [y + 0.8 for _ in vals]
            for j in range(len(times) - 1):
                ax.plot([times[j], times[j+1]], [y + 0.8, y + 0.8], color=color, lw=1.4)
                ax.plot([times[j], times[j+1]], [y, y], color=color, lw=1.4)
                ax.plot([times[j], times[j]], [y, y + 0.8], color=color, lw=1.4)
                lbl = op_names.get(vals[j], f"OP_{vals[j]}")
                if (times[j+1] - times[j]) > 0.5:
                    mid_t = (times[j] + times[j+1]) / 2.0
                    ax.fill_between([times[j], times[j+1]], y, y + 0.8, color=color, alpha=0.18)
                    ax.text(mid_t, y + 0.4, lbl, ha="center", va="center", fontsize=8, fontweight="bold", color=color)

        ax.text(-0.3, y + 0.4, label, ha="right", va="center", fontsize=9, fontweight="bold", color="#2c3e50")

    # Major operational phase markers
    phases = [
        (0.0, 3.53, "Phase 1: Host Load Poly A & B\n(Avalon-MM 32-bit)", "#3498db"),
        (3.53, 5.36, "Phase 2: FNTT(a)\n(274 cyc, 1.83 μs)", "#e74c3c"),
        (5.36, 8.87, "Host Read\nNTT(a)", "#95a5a6"),
        (8.87, 10.71, "Phase 3: FNTT(b)\n(274 cyc, 1.83 μs)", "#e74c3c"),
        (10.71, 14.22, "Host Read\nNTT(b)", "#95a5a6"),
        (14.22, 15.16, "Phase 4: PWM(a,b)\n(140 cyc, 0.94 μs)", "#9b59b6"),
        (15.16, 18.69, "Host Read\nPWM(a,b)", "#95a5a6"),
        (18.69, 21.00, "Phase 5: INTT+Scale\n(345 cyc, 2.31 μs)", "#27ae60"),
        (21.00, 22.00, "Phase 6: Verify Result\na·b mod (x^256+1)", "#f39c12"),
    ]

    y_banner = y_base + y_spacing * 0.8
    for t_s, t_e, title, p_color in phases:
        rect = patches.Rectangle((t_s, y_banner), t_e - t_s, 1.0, linewidth=1, edgecolor=p_color, facecolor=p_color, alpha=0.25)
        ax.add_patch(rect)
        mid_x = (t_s + t_e) / 2.0
        ax.text(mid_x, y_banner + 0.5, title, ha="center", va="center", fontsize=7.5, fontweight="bold", color="#1a252f")
        ax.axvline(x=t_s, color=p_color, linestyle="--", alpha=0.5, lw=1)

    ax.set_xlim(0, t_max_us)
    ax.set_ylim(0, y_base + y_spacing * 2.2)
    ax.set_xlabel("Waktu Simulasi (Microseconds / μs) [Clock: 150 MHz, Periode: 6.666 ns]", fontsize=11, fontweight="bold", labelpad=10)
    ax.set_title("DIAGRAM GELOMBANG EKSEKUSI PENUH AKSELERATOR ML-KEM\nSiklus Komputasi Mandiri: FNTT(a) → FNTT(b) → PWM → INTT+Scale (DE10-Nano SoC)", fontsize=13, fontweight="bold", pad=25)
    
    ax.grid(True, axis="x", linestyle=":", alpha=0.6)
    ax.set_yticks([])
    for spine in ["top", "left", "right"]:
        ax.spines[spine].set_visible(False)

    plt.savefig(out_png, dpi=300, bbox_inches="tight")
    plt.close()
    print(f"[OK] Full chain waveform saved: {out_png}")

def render_pwm_zoom(signal_history, out_png):
    # Zoom on PWM: 14.15 us to 15.25 us
    t_min_us = 14.15
    t_max_us = 15.25

    fig, ax = plt.subplots(figsize=(15, 8), dpi=300)
    plt.subplots_adjust(left=0.20, right=0.96, top=0.90, bottom=0.10)

    signals_to_plot = [
        ("tb_top.clk", "CLK (150 MHz)", "digital", "#34495e"),
        ("tb_top.dut.start", "START PWM (OP=2)", "digital", "#27ae60"),
        ("tb_top.dut.busy", "BUSY", "digital", "#c0392b"),
        ("tb_top.dut.u_ctrl.st", "FSM STATE (1:ISSUE, 3:WAIT)", "bus", "#2980b9"),
        ("tb_top.dut.u_ctrl.grp", "PWM GROUP [5:0] (0..31)", "bus", "#8e44ad"),
        ("tb_top.dut.u_ctrl.beat", "PWM BEAT [2:0] (0..3)", "bus", "#e67e22"),
        ("tb_top.dut.c_re", "SCRATCHPAD READ (c_re)", "bus", "#2c3e50"),
        ("tb_top.dut.core_valid", "PE CORE_VALID (p_fire)", "digital", "#16a085"),
        ("tb_top.dut.core_out_valid", "PE CORE_OUT_VALID", "digital", "#1abc9c"),
        ("tb_top.dut.c_we", "SCRATCHPAD WRITE (c_we)", "bus", "#d35400"),
        ("tb_top.dut.done_pulse", "DONE PULSE (140 cyc)", "digital", "#27ae60"),
        ("tb_top.irq", "HOST IRQ", "digital", "#8e44ad"),
    ]

    y_spacing = 1.3
    y_base = len(signals_to_plot) * y_spacing

    for i, (sig_name, label, sig_type, color) in enumerate(signals_to_plot):
        y = y_base - i * y_spacing
        events = signal_history.get(sig_name, [])
        if not events:
            continue

        # Filter events in window
        filtered = [(t_ps / 1e6, v) for t_ps, v in events if t_min_us - 0.05 <= t_ps / 1e6 <= t_max_us + 0.05]
        if not filtered:
            continue

        times = [t_min_us]
        vals = [filtered[0][1]]
        for t_us, v in filtered:
            times.append(t_us)
            vals.append(v)
        times.append(t_max_us)
        vals.append(vals[-1])

        if sig_type == "digital":
            step_y = [y + (0.8 if v != 0 else 0.0) for v in vals]
            ax.step(times, step_y, where="post", color=color, lw=1.6)
            for j in range(len(times) - 1):
                if vals[j] != 0:
                    ax.fill_between([times[j], times[j+1]], y, y + 0.8, color=color, alpha=0.15)
        elif sig_type == "bus":
            step_y = [y + (0.8 if v != 0 else 0.0) for v in vals]
            ax.step(times, step_y, where="post", color=color, lw=1.4)
            for j in range(len(times) - 1):
                if vals[j] != 0 and (times[j+1] - times[j]) > 0.01:
                    ax.fill_between([times[j], times[j+1]], y, y + 0.8, color=color, alpha=0.2)
                    mid_t = (times[j] + times[j+1]) / 2.0
                    if (times[j+1] - times[j]) > 0.03:
                        ax.text(mid_t, y + 0.4, f"{vals[j]}", ha="center", va="center", fontsize=7, color="#2c3e50")

        ax.text(t_min_us - 0.015, y + 0.4, label, ha="right", va="center", fontsize=9, fontweight="bold", color="#2c3e50")

    # Annotate 140 cycles duration
    ax.annotate("", xy=(14.222, y_base + 0.8), xytext=(15.155, y_base + 0.8),
                arrowprops=dict(arrowstyle="<->", color="#c0392b", lw=2))
    ax.text(14.688, y_base + 1.1, "140 Siklus Clock (~933 ns @ 150 MHz)\n32 Groups x 4 Beats + Pipeline Latency",
            ha="center", va="center", fontsize=10, fontweight="bold", color="#c0392b")

    ax.set_xlim(t_min_us, t_max_us)
    ax.set_ylim(0, y_base + y_spacing * 2.0)
    ax.set_xlabel("Waktu Simulasi (Microseconds / μs) [Fokus Operasi PWM]", fontsize=11, fontweight="bold", labelpad=10)
    ax.set_title("DETAIL GELOMBANG OPERASI POINTWISE MULTIPLICATION (PWM)\nAkselerasi Dual-Multiplier per PE: Throughput 4 Beats per Grup, Total 140 Siklus", fontsize=12, fontweight="bold", pad=20)
    
    ax.grid(True, axis="x", linestyle=":", alpha=0.6)
    ax.set_yticks([])
    for spine in ["top", "left", "right"]:
        ax.spines[spine].set_visible(False)

    plt.savefig(out_png, dpi=300, bbox_inches="tight")
    plt.close()
    print(f"[OK] PWM zoom waveform saved: {out_png}")

def main():
    target_names = {
        "tb_top.clk": "tb_top.clk",
        "tb_top.rst_n": "tb_top.rst_n",
        "tb_top.avs_write": "tb_top.avs_write",
        "tb_top.avs_read": "tb_top.avs_read",
        "tb_top.dut.start": "tb_top.dut.start",
        "tb_top.dut.busy": "tb_top.dut.busy",
        "tb_top.dut.done_pulse": "tb_top.dut.done_pulse",
        "tb_top.irq": "tb_top.irq",
        "tb_top.dut.c_re": "tb_top.dut.c_re",
        "tb_top.dut.c_we": "tb_top.dut.c_we",
        "tb_top.dut.core_valid": "tb_top.dut.core_valid",
        "tb_top.dut.core_out_valid": "tb_top.dut.core_out_valid",
        "tb_top.dut.u_ctrl.layer": "tb_top.dut.u_ctrl.layer",
        "tb_top.dut.u_ctrl.st": "tb_top.dut.u_ctrl.st",
        "tb_top.dut.u_ctrl.grp": "tb_top.dut.u_ctrl.grp",
        "tb_top.dut.u_ctrl.beat": "tb_top.dut.u_ctrl.beat",
        "tb_top.dut.op": "tb_top.dut.op",
    }

    print("Extracting signals from VCD...")
    history = extract_signals(VCD_FILE, target_names, 0, 23_000_000)

    out_full = os.path.join(DOCS_DIR, "waveform_mlkem_full_chain.png")
    out_pwm = os.path.join(DOCS_DIR, "waveform_pwm_zoom.png")

    render_overview(history, out_full)
    render_pwm_zoom(history, out_pwm)
    print("Waveform rendering complete!")

if __name__ == "__main__":
    main()
