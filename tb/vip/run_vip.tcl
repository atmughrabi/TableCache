# SPDX-License-Identifier: Apache-2.0
# Vivado AXI VIP simulation for l2_top, run under xsim.
#
#   vivado -mode batch -source tb/vip/run_vip.tcl
#
# Builds a throwaway project (tb/vip/build by default) containing two AXI VIP
# IPs (a MASTER driving l2_top.s00 and a SLAVE memory-model backing l2_top.m00)
# plus the TableCache RTL and tb/vip/tb_l2top_vip.sv, then runs the simulation.
#
# Env overrides: VIP_BUILD (build dir), VIP_PART (FPGA part).
#
# The RTL carries no per-file `timescale (same as the Verilator flow); a default
# is supplied to xelab via -timescale rather than editing every source file.
# No --relax: the RTL compiles under strict xsim ordering rules.

set THIS  [file normalize [info script]]
set REPO  [file normalize [file dirname $THIS]/../..]
set BUILD [expr {[info exists ::env(VIP_BUILD)] ? $::env(VIP_BUILD) : "$REPO/tb/vip/build"}]
set PART  [expr {[info exists ::env(VIP_PART)]  ? $::env(VIP_PART)  : "xcu55c-fsvh2892-2L-e"}]

file delete -force $BUILD
create_project vip_l2top $BUILD -part $PART -force
set_property target_simulator XSim [current_project]

# --- TableCache RTL (cache_config.sv is the package; update_compile_order
#     resolves dependency order automatically) ---
add_files -norecurse [glob $REPO/src/*.sv]
add_files -fileset sim_1 -norecurse $REPO/tb/vip/tb_l2top_vip.sv

# --- AXI VIP master (drives l2_top.s00) ---
create_ip -name axi_vip -vendor xilinx.com -library ip -module_name axi_vip_mst
set_property -dict [list CONFIG.PROTOCOL {AXI4} CONFIG.INTERFACE_MODE {MASTER} \
  CONFIG.ADDR_WIDTH {32} CONFIG.DATA_WIDTH {32} CONFIG.ID_WIDTH {4} CONFIG.SUPPORTS_NARROW {1} \
  CONFIG.AWUSER_WIDTH {0} CONFIG.ARUSER_WIDTH {0} CONFIG.RUSER_WIDTH {0} \
  CONFIG.WUSER_WIDTH {0} CONFIG.BUSER_WIDTH {0}] [get_ips axi_vip_mst]

# --- AXI VIP slave memory (backs l2_top.m00; m00 ID width = s00 + 1) ---
create_ip -name axi_vip -vendor xilinx.com -library ip -module_name axi_vip_slv
set_property -dict [list CONFIG.PROTOCOL {AXI4} CONFIG.INTERFACE_MODE {SLAVE} \
  CONFIG.ADDR_WIDTH {32} CONFIG.DATA_WIDTH {32} CONFIG.ID_WIDTH {5} CONFIG.SUPPORTS_NARROW {1} \
  CONFIG.AWUSER_WIDTH {0} CONFIG.ARUSER_WIDTH {0} CONFIG.RUSER_WIDTH {0} \
  CONFIG.WUSER_WIDTH {0} CONFIG.BUSER_WIDTH {0}] [get_ips axi_vip_slv]

generate_target simulation [get_ips axi_vip_mst axi_vip_slv]

set_property top tb_l2top_vip [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Optional cache config overrides via env (VIP_LINES / VIP_WAYS / VIP_LINE_W /
# VIP_POLICY name). Default = the small fast config baked into the tb. Passed
# as xvlog -d defines that only the tb reads (the RTL ignores them).
set defs {}
if {[info exists ::env(VIP_LINES)]}  { lappend defs "TC_LINES=$::env(VIP_LINES)" }
if {[info exists ::env(VIP_WAYS)]}   { lappend defs "TC_WAYS=$::env(VIP_WAYS)" }
if {[info exists ::env(VIP_LINE_W)]} { lappend defs "TC_LINE_W=$::env(VIP_LINE_W)" }
if {[info exists ::env(VIP_POLICY)]} {
    array set pmap {LRU 0 FRQ 1 SECOND_CHANCE 2 RANDOM 3 SRRIP 4 GRASP 5}
    if {[info exists pmap($::env(VIP_POLICY))]} {
        lappend defs "TC_POLICY_INT=$pmap($::env(VIP_POLICY))"
    }
}
if {[llength $defs] > 0} {
    set xvopts ""
    foreach d $defs { append xvopts "-d $d " }
    set_property -name {xsim.compile.xvlog.more_options} -value [string trim $xvopts] -objects [get_filesets sim_1]
    puts "=== VIP config: $defs ==="
}

# Supply a default timescale for the timescale-less RTL; run to $finish.
set_property -name {xsim.elaborate.xelab.more_options} -value {-timescale 1ns/1ps} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

# Generate the compile/elaborate/simulate scripts only. The wrapper
# (run_vip.sh) strips the flow's default --relax from elaborate.sh and runs
# them, proving the RTL elaborates under strict xsim ordering rules.
launch_simulation -scripts_only -simset sim_1 -mode behavioral
puts "=== run_vip.tcl scripts generated ==="
