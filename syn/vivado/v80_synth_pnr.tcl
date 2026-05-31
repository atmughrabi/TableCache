# Vivado OOC synth + place + route + phys_opt for V80.
# Driven by v80_synth.sh with PNR=1. Reads the same env-var generics as
# run_synth.tcl (POLICY, WAYS, LINES, LINE_W, INCLUDE_VICTIM, DATABANK_SDP,
# DB_LATENCY, SDP_WRITE_INPUT_REG, DIRECTIVE, PERIOD_NS). Reports the
# post-route timing summary under the canonical filenames so the wrapper
# parser picks them up.

set top       [lindex $argv 0]
set repo_root [lindex $argv 1]
set out       [lindex $argv 2]

set part [expr {[info exists ::env(PART)] ? $::env(PART) : "xcv80-lsva4737-2MHP-e-S"}]
set period_ns [expr {[info exists ::env(PERIOD_NS)] ? $::env(PERIOD_NS) : "4.0"}]
set dir [expr {[info exists ::env(DIRECTIVE)] ? $::env(DIRECTIVE) : "default"}]

puts "==== part=$part top=$top period=${period_ns}ns directive=$dir ===="

create_project -in_memory -part $part

foreach f [glob -nocomplain $repo_root/src/*.sv] {
    read_verilog -sv $f
}
set_property top $top [current_fileset]

# Match the env-var generic plumbing in run_synth.tcl.
set generics [list]
if {$top eq "l2_cache" || $top eq "l2_top"} {
    foreach v {WAYS LINES LINE_W POLICY REPLACEMENT_POLICY INCLUDE_VICTIM \
               VICTIM_LINES DATABANK_SDP DB_LATENCY SDP_WRITE_INPUT_REG CASCADE_DEPTH N_BANKS} {
        if {[info exists ::env($v)]} {
            lappend generics "$v=$::env($v)"
            puts "==== override $v=$::env($v)"
        }
    }
}

# Synthesis
if {[llength $generics] > 0} {
    synth_design -top $top -part $part -mode out_of_context \
        -directive $dir -generic $generics
} else {
    synth_design -top $top -part $part -mode out_of_context \
        -directive $dir
}
create_clock -name clk -period $period_ns [get_ports clk]
# V80 ES silicon defaults clock_uncertainty to 0.300 ns; production
# UltraScale+ HBM is ~0.035 ns. Allow override via env var to project
# what production V80 silicon will deliver before AMD ships the
# non-ES speed file. Default: leave the part's silicon model untouched.
if {[info exists ::env(CLOCK_UNCERTAINTY_NS)]} {
    set unc $::env(CLOCK_UNCERTAINTY_NS)
    puts "==== overriding clock_uncertainty to ${unc} ns (was Vivado default) ===="
    set_clock_uncertainty $unc [get_clocks clk]
}
report_utilization        -file $out/utilization_postsynth.rpt
report_timing_summary     -file $out/timing_summary_postsynth.rpt

# Place + route. Use 'Default' directives at first to keep the run
# bounded; flip to ExtraNetDelay_high or AggressiveExplore if timing
# is binding.
puts "==== place_design ===="
set place_dir [expr {[info exists ::env(PLACE_DIRECTIVE)] ? $::env(PLACE_DIRECTIVE) : "Default"}]
place_design -directive $place_dir

puts "==== phys_opt_design (post-place) ===="
set phys_dir [expr {[info exists ::env(PHYS_DIRECTIVE)] ? $::env(PHYS_DIRECTIVE) : "Default"}]
phys_opt_design -directive $phys_dir

puts "==== route_design ===="
set route_dir [expr {[info exists ::env(ROUTE_DIRECTIVE)] ? $::env(ROUTE_DIRECTIVE) : "Default"}]
route_design -directive $route_dir

puts "==== phys_opt_design (post-route) ===="
phys_opt_design -directive $phys_dir

# Final reports under the canonical names so v80_synth.sh's parser
# picks them up. Keep the post-synth snapshots for delta inspection.
report_utilization        -file $out/utilization.rpt
report_utilization -hierarchical -file $out/utilization_hier.rpt
report_timing_summary     -file $out/timing_summary.rpt
report_methodology        -file $out/methodology.rpt
report_drc                -file $out/drc.rpt

# Detailed binding-path report (top-3 worst paths, full topology)
# for V80-focused timing analysis. See experiment/v80-focus branch.
report_timing -delay_type max -nworst 3 -path_type full -input_pins \
    -file $out/timing_detailed.rpt

# Routed netlist for post-PnR functional sim. The Verilog form keeps
# UNISIM primitives (LUT6, FDRE, URAM288E5, ...) and references the
# implicit `glbl` module; downstream consumers need a UNISIM-aware
# simulator (Vivado xsim, VCS, ModelSim with the Xilinx libs) -- this
# is OUT OF REACH of Verilator. The SDF gives back-annotated delays
# for timing-aware sim. See post_pnr_sim.sh for the consumer skeleton.
write_verilog -mode timesim -sdf_anno true -force $out/routed_netlist.v
write_sdf -force $out/routed_netlist.sdf

puts "==== POST-ROUTE TIMING SUMMARY ===="
puts [exec grep -E "(WNS|TNS|WHS|THS)" $out/timing_summary.rpt | head -10]

exit 0
