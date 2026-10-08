# ML-KEM polynomial coprocessor PoC -- simulation flow (Icarus Verilog; QuestaSim notes in README)
IVFLAGS = -g2005 -Irtl
RTL     = $(filter-out rtl/mlkem_zeta_rom.v, $(wildcard rtl/*.v)) rtl/mlkem_zeta_rom.v
SIM     = sim

.PHONY: all gen sim unit regress clean
all: regress

gen:                              ## golden model, twiddle ROM, test vectors
	python3 scripts/golden_mlkem.py
	python3 scripts/gen_rom.py
	python3 scripts/gen_vectors.py

$(SIM)/%.vvp: tb/%.v $(RTL)
	@mkdir -p $(SIM)
	iverilog $(IVFLAGS) -o $@ $(RTL) $<

unit: $(SIM)/tb_modmul.vvp $(SIM)/tb_pe.vvp $(SIM)/tb_scratchpad.vvp
	vvp $(SIM)/tb_modmul.vvp
	vvp $(SIM)/tb_pe.vvp
	vvp $(SIM)/tb_scratchpad.vvp

sim: $(SIM)/tb_top.vvp
	vvp $(SIM)/tb_top.vvp

regress: gen unit sim

clean:
	rm -rf $(SIM)/*.vvp $(SIM)/*.vcd
