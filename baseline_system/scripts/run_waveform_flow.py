#!/usr/bin/env python3
"""
run_waveform_flow.py -- Full automated simulation, VCD waveform generation,
GTKWave configuration setup, and high-resolution image rendering flow.

Usage:
  python baseline_system/scripts/run_waveform_flow.py          # Compile, simulate & render PNGs
  python baseline_system/scripts/run_waveform_flow.py --view   # Also launch GTKWave GUI
"""

import os
import sys
import subprocess
import shutil

BASE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SIM_DIR = os.path.join(BASE_DIR, "sim")
RTL_DIR = os.path.join(BASE_DIR, "rtl")
TB_DIR = os.path.join(BASE_DIR, "tb")
SCRIPTS_DIR = os.path.join(BASE_DIR, "scripts")
DOCS_DIR = os.path.abspath(os.path.join(BASE_DIR, "..", "docs"))

os.makedirs(SIM_DIR, exist_ok=True)
os.makedirs(DOCS_DIR, exist_ok=True)

VVP_FILE = os.path.join(SIM_DIR, "tb_top.vvp")
VCD_FILE = os.path.join(SIM_DIR, "tb_top.vcd")
GTKW_FILE = os.path.join(SIM_DIR, "mlkem_waveform.gtkw")
GTKW_DOCS = os.path.join(DOCS_DIR, "mlkem_waveform.gtkw")

def run_cmd(cmd, cwd=BASE_DIR):
    print(f"[EXEC] {' '.join(cmd) if isinstance(cmd, list) else cmd}")
    res = subprocess.run(cmd, cwd=cwd, shell=isinstance(cmd, str))
    if res.returncode != 0:
        print(f"[ERROR] Command failed with code {res.returncode}")
        sys.exit(res.returncode)

def main():
    print("=" * 70)
    print(" AUTOMATED TESTBENCH & WAVEFORM VISUALIZATION FLOW")
    print(" ML-KEM Unified Accelerator (Intel Cyclone V / DE10-Nano)")
    print("=" * 70)

    # 1. Regenerate vectors if missing
    vectors_dir = os.path.join(TB_DIR, "vectors")
    if not os.path.exists(os.path.join(vectors_dir, "a.hex")):
        print("\n[STEP 1/4] Generating test vectors and ROM...")
        run_cmd([sys.executable, os.path.join(SCRIPTS_DIR, "gen_rom.py")])
        run_cmd([sys.executable, os.path.join(SCRIPTS_DIR, "gen_vectors.py")])
    else:
        print("\n[STEP 1/4] Test vectors already present.")

    # 2. Compile RTL + Testbench
    print("\n[STEP 2/4] Compiling RTL and tb_top with Icarus Verilog...")
    rtl_files = [os.path.join(RTL_DIR, f) for f in os.listdir(RTL_DIR) if f.endswith(".v")]
    tb_file = os.path.join(TB_DIR, "tb_top.v")
    iv_cmd = ["iverilog", "-g2005", f"-I{RTL_DIR}", "-o", VVP_FILE] + rtl_files + [tb_file]
    run_cmd(iv_cmd)

    # 3. Execute simulation
    print("\n[STEP 3/4] Running simulation to generate VCD waveform...")
    run_cmd(["vvp", VVP_FILE])

    # 4. Render high-resolution PNG waveforms
    print("\n[STEP 4/4] Rendering high-resolution waveform graphics for proposal...")
    run_cmd([sys.executable, os.path.join(SCRIPTS_DIR, "render_waveform.py")])

    # Synchronize GTKWave file to docs/
    if os.path.exists(GTKW_FILE):
        shutil.copy2(GTKW_FILE, GTKW_DOCS)

    print("\n" + "=" * 70)
    print(" FLOW COMPLETED SUCCESSFULLY!")
    print(f" - VCD Waveform    : {os.path.relpath(VCD_FILE)}")
    print(f" - GTKWave Config  : {os.path.relpath(GTKW_FILE)}")
    print(f" - Main PNG Figure : docs/waveform_mlkem_full_chain.png")
    print(f" - PWM Zoom Figure : docs/waveform_pwm_zoom.png")
    print("=" * 70)

    # Optional: Open GTKWave if requested
    if "--view" in sys.argv:
        gtkwave_path = shutil.which("gtkwave") or r"D:\iverilog\gtkwave\bin\gtkwave.exe"
        if os.path.exists(gtkwave_path):
            print(f"\n[LAUNCH] Opening GTKWave GUI ({gtkwave_path})...")
            subprocess.Popen([gtkwave_path, VCD_FILE, GTKW_FILE], cwd=SIM_DIR)
        else:
            print("\n[WARN] gtkwave executable not found on PATH.")

if __name__ == "__main__":
    main()
