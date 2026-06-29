# Vivado OOC (out-of-context) synthesis for TableCache.
#
# Targets Alveo U250 (Virtex UltraScale+ XCU250-FIGD2104-2L-E).
#
# Usage:
#   cd syn/vivado
#   ./run_synth.sh                 # default: l2_cache
#   TOP=tc_narrow_shim ./run_synth.sh
#   TOP=tc_flush_controller ./run_synth.sh
#
# Outputs:
#   syn/vivado/build/<TOP>/utilization.rpt
#   syn/vivado/build/<TOP>/timing_summary.rpt
#   syn/vivado/build/<TOP>/methodology.rpt
#   syn/vivado/build/<TOP>/synth.log

set top      [lindex $argv 0]
set repo_root [lindex $argv 1]
set out      [lindex $argv 2]

# Alveo U250 part. Speed grade -2L (low power) matches the public board.
# Override via env: PART=xcu280-fsvh2892-2L-e (or any other UltraScale+/Versal part).
set part [expr {[info exists ::env(PART)] ? $::env(PART) : "xcu250-figd2104-2L-e"}]
puts "==== part = $part ===="

create_project -in_memory -part $part

# RTL sources (-sv enables SystemVerilog).
set rtl_files [glob -nocomplain $repo_root/src/*.sv]
foreach f $rtl_files {
    read_verilog -sv $f
}

# Top-module selection.
puts "==== synthesizing top=$top on $part ===="
set_property top $top [current_fileset]

# Out-of-context: no IO buffer insertion, no pad-pin assignment. We're
# checking inferences, area, timing-feasibility -- not driving pins.
#
# Optional parameter overrides via env vars (e.g. WAYS=8 LINES=1024 LINE_W=16).
# Only applied for l2_cache / l2_top so the shim/flush tops aren't disturbed.
#
# IMPORTANT param-name mapping:
#   * l2_top  declares REPLACEMENT_POLICY (int) and casts it to POLICY for
#     its internal l2_cache instance.
#   * l2_cache itself declares POLICY (replacement_policy_t).
# We accept both names. Setting REPLACEMENT_POLICY when TOP=l2_cache used
# to silently default to LRU (Vivado emits "Unused top level parameter"
# but exits 0), corrupting every "policy sweep" run targeting l2_cache.
# The matching POLICY env var now works for both tops.
#
# Also accepts SDP_WRITE_INPUT_REG (1-cycle URAM write-port input reg,
# default 0, only meaningful with DATABANK_SDP=1) and DB_LATENCY.
set generics [list]
if {$top eq "l2_cache" || $top eq "l2_top"} {
    foreach v {WAYS LINES LINE_W POLICY REPLACEMENT_POLICY INCLUDE_VICTIM \
               VICTIM_LINES DATABANK_SDP DB_LATENCY SDP_WRITE_INPUT_REG CASCADE_DEPTH N_BANKS \
               GRASP_HIGH_REGIONS GRASP_MODERATE_REGIONS} {
        if {[info exists ::env($v)]} {
            lappend generics "$v=$::env($v)"
            puts "==== override $v=$::env($v)"
        }
    }
}
# Synthesis directive: AreaOptimized_high prioritises LUT count over WNS
# and costs ~1.3 ns of slack on the SDP+URAM databank critical path
# (cache controller -> URAM cascade write input). 'default' produces
# fewer LUTs AND better timing on big SDP+URAM configs. Override with
# DIRECTIVE=AreaOptimized_high if you really want the old behaviour.
set dir [expr {[info exists ::env(DIRECTIVE)] ? $::env(DIRECTIVE) : "default"}]
puts "==== directive = $dir"
if {[llength $generics] > 0} {
    synth_design -top $top -part $part -mode out_of_context \
        -directive $dir -generic $generics
} else {
    synth_design -top $top -part $part -mode out_of_context \
        -directive $dir
}

# Clock constraint: 250 MHz target (typical Alveo U250 acceleration
# kernel clock). Override via env: PERIOD_NS=3.33 ./run_synth.sh for 300 MHz.
set period_ns [expr {[info exists ::env(PERIOD_NS)] ? $::env(PERIOD_NS) : "4.0"}]
puts "==== clock period = $period_ns ns"
create_clock -name clk -period $period_ns [get_ports clk]

# Run timing / methodology / utilization reports after synth (no PnR).
report_utilization -file $out/utilization.rpt
report_utilization -hierarchical -file $out/utilization_hier.rpt
report_timing_summary -file $out/timing_summary.rpt -no_header -no_detailed_paths
report_methodology -file $out/methodology.rpt

# Detailed report on the worst 3 paths for binding-path analysis.
report_timing -delay_type max -nworst 3 -path_type full -input_pins \
    -file $out/timing_detailed.rpt

# A short stdout summary so the wrapper script can grep it.
puts "==== UTILIZATION SUMMARY ===="
puts [exec grep -E "(CLB LUTs|CLB Registers|Block RAM Tile|LUT as Memory|DSPs)" $out/utilization.rpt]
puts "==== TIMING SUMMARY ===="
puts [exec grep -E "(WNS|WHS|TNS|THS|Total Negative Slack|Worst Negative Slack)" $out/timing_summary.rpt | head -20]
puts "==== METHODOLOGY VIOLATIONS ===="
puts [exec grep -cE "^WARNING|^CRITICAL" $out/methodology.rpt]

exit 0
