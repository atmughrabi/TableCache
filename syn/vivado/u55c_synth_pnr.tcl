# Vivado OOC synth + place + route + phys_opt for Alveo U55C.
# Driven by u55c_synth.sh with PNR=1. Reads the same env-var generics
# as run_synth.tcl (POLICY, WAYS, LINES, LINE_W, INCLUDE_VICTIM,
# DATABANK_SDP, DB_LATENCY, SDP_WRITE_INPUT_REG, DIRECTIVE, PERIOD_NS).
# Identical to v80_synth_pnr.tcl modulo the default PART -- kept as a
# separate file so the wrapper script names match and per-board PnR
# tweaks (e.g. SLR floorplan, HBM stack pinning) can land here.

set top       [lindex $argv 0]
set repo_root [lindex $argv 1]
set out       [lindex $argv 2]

set part [expr {[info exists ::env(PART)] ? $::env(PART) : "xcu55c-fsvh2892-2L-e"}]
set period_ns [expr {[info exists ::env(PERIOD_NS)] ? $::env(PERIOD_NS) : "4.0"}]
set dir [expr {[info exists ::env(DIRECTIVE)] ? $::env(DIRECTIVE) : "default"}]

puts "==== part=$part top=$top period=${period_ns}ns directive=$dir ===="

create_project -in_memory -part $part

foreach f [glob -nocomplain $repo_root/src/*.sv] {
    read_verilog -sv $f
}
set_property top $top [current_fileset]

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

if {[llength $generics] > 0} {
    synth_design -top $top -part $part -mode out_of_context \
        -directive $dir -generic $generics
} else {
    synth_design -top $top -part $part -mode out_of_context \
        -directive $dir
}
create_clock -name clk -period $period_ns [get_ports clk]
report_utilization        -file $out/utilization_postsynth.rpt
report_timing_summary     -file $out/timing_summary_postsynth.rpt

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

report_utilization        -file $out/utilization.rpt
report_utilization -hierarchical -file $out/utilization_hier.rpt
report_timing_summary     -file $out/timing_summary.rpt
report_methodology        -file $out/methodology.rpt
report_drc                -file $out/drc.rpt

# Routed netlist + SDF for post-PnR functional sim (see syn/post_pnr_sim.sh).
write_verilog -mode timesim -sdf_anno true -force $out/routed_netlist.v
write_sdf -force $out/routed_netlist.sdf

puts "==== POST-ROUTE TIMING SUMMARY ===="
puts [exec grep -E "(WNS|TNS|WHS|THS)" $out/timing_summary.rpt | head -10]

exit 0
