# mlkem_top.sdc -- timing constraints for the ML-KEM coprocessor (Cyclone V 5CSEBA6U23I7)
# Override the period from the build script:  set CLK_PERIOD 5.000 before sourcing.
if {![info exists CLK_PERIOD]} { set CLK_PERIOD 6.667 }   ;# 150 MHz default

create_clock -name clk -period $CLK_PERIOD [get_ports clk]
derive_clock_uncertainty

create_clock -name virt_clk -period $CLK_PERIOD

# Avalon-MM slave ports interface with HPS Lightweight Bridge in SoC
set_input_delay  -clock virt_clk -max 1.0 [get_ports {avs_* rst_n}]
set_input_delay  -clock virt_clk -min 0.0 [get_ports {avs_* rst_n}]
set_output_delay -clock virt_clk -max 1.0 [get_ports {avs_readdata* avs_readdatavalid irq}]
set_output_delay -clock virt_clk -min 0.0 [get_ports {avs_readdata* avs_readdatavalid irq}]
set_false_path -from [get_ports rst_n]
