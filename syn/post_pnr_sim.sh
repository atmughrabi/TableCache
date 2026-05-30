#!/usr/bin/env bash
# Post-PnR functional simulation driver.
#
# Consumes the routed netlist + SDF dropped by v80_synth_pnr.tcl
# (write_verilog -mode timesim + write_sdf in the PnR target) and
# runs a smoke cocotb test against it. Catches PnR bugs that pass
# both synth + timing-met but corrupt data at runtime (e.g.,
# phys_opt_design retiming that breaks an FSM assumption, hold-time
# violations the Slow corner missed, etc.).
#
# CURRENT STATUS: scaffolding only. The simulator backend has to be
# Vivado xsim, VCS, or ModelSim -- Verilator does not handle UNISIM
# primitives (URAM288E5, RAMB36E2, etc.) that the routed netlist
# references. Cocotb supports xsim out of the box but the tb wiring
# requires:
#   1. include glbl.v from the Vivado install (handles GSR pulse)
#   2. compile the UNISIM library (`unisim`/`unisims_ver`) with the
#      simulator
#   3. SDF back-annotation: $sdf_annotate("routed_netlist.sdf", DUT)
#   4. rename the top-level instance so cocotb's TOPLEVEL matches
#      what's in the netlist
#
# Usage (once the xsim flow is wired):
#   PNR_BUILD=syn/vivado/build/v80_512K_w8_p5_period4.0_pnr1 \
#     ./post_pnr_sim.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PNR_BUILD="${PNR_BUILD:-$REPO/syn/vivado/build/v80_512K_w8_p5_period4.0_pnr1}"
NETLIST="$PNR_BUILD/routed_netlist.v"
SDF="$PNR_BUILD/routed_netlist.sdf"

if [[ ! -f "$NETLIST" ]]; then
    echo "ERROR: no routed netlist at $NETLIST" >&2
    echo "Run the PnR step first:" >&2
    echo "  cd syn/vivado && PNR=1 SIZE=512K ./v80_synth.sh" >&2
    exit 2
fi

echo "==== Post-PnR netlist + SDF found ===="
echo "  netlist: $NETLIST  ($(wc -l < "$NETLIST") lines)"
echo "  sdf:     $SDF"

# TODO(D2): wire cocotb + xsim. Skeleton:
#   1. find Vivado xsim binary
#   2. compile UNISIM lib if needed:
#        xelab -L unisims_ver work.dut_cocotb work.glbl -snapshot dut_sim
#   3. run with cocotb VPI:
#        xsim --vpi cocotbvpi_xsim.so dut_sim ...
#   4. drive the same cocotb test modules
#
# Until that's wired the script just confirms the netlist exists and
# bails. This keeps the dependency on Vivado xsim explicit -- it's
# not a Verilator-portable flow.

cat <<'EOF'

==== Post-PnR cocotb run is not yet implemented ====
This is verification gap A18 (see doc/VERIFICATION_XILINX_VIP_ROADMAP.md).
The flow needs:
  - cocotb 1.9.x XSIM_BIN env var
  - glbl.v + unisims_ver compiled
  - SDF back-annotation
Setting up xsim under cocotb is ~1 day of work and shares infra with
the Xilinx AXI VIP integration (D1 in the same roadmap), so they
should land together.
EOF
exit 0
