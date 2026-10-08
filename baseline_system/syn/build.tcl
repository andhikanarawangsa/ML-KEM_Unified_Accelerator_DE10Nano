# build.tcl -- Quartus flow: quartus_sh -t syn/build.tcl [period_ns]
# Run from baseline_system/.  Produces syn/out/ with reports.
set period 6.667
if {$argc > 0} { set period [lindex $quartus(args) 0] }

load_package project
load_package flow

# Resolve every path BEFORE project_new (it changes the working directory).
set root   [pwd]
set outdir [file join $root syn out]
file mkdir $outdir
set rtl_files [glob -directory [file join $root rtl] *.v]
set sdc_src   [file join $root syn mlkem_top.sdc]

# Wrapper SDC so the clock period can be swept from the command line.
set fh [open [file join $outdir period.sdc] w]
puts $fh "set CLK_PERIOD $period"
puts $fh "source \"$sdc_src\""
close $fh

project_new -overwrite -revision mlkem_top [file join $outdir mlkem_top]

set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSEBA6U23I7
set_global_assignment -name TOP_LEVEL_ENTITY mlkem_top
set_global_assignment -name SEARCH_PATH [file join $root rtl]
foreach f $rtl_files { set_global_assignment -name VERILOG_FILE $f }
set_global_assignment -name SDC_FILE [file join $outdir period.sdc]
set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"

execute_flow -compile
project_close
