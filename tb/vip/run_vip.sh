#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build + run the Vivado AXI VIP simulation for l2_top under xsim, WITHOUT
# --relax. Vivado's launch_simulation injects --relax into the generated
# elaborate.sh by default; we strip it to prove the RTL elaborates under
# strict xsim ordering rules (no forward references, no initial/always
# procedural-driver conflicts).
#
#   ./tb/vip/run_vip.sh
#
# Env: VIP_BUILD (build dir), VIP_PART (FPGA part), plus cache-config knobs
# VIP_WAYS / VIP_LINES / VIP_LINE_W / VIP_POLICY / VIP_VICTIM / VIP_ID_W /
# VIP_DB_LATENCY / VIP_DATABANK_SDP / VIP_SDP_WRITE_INPUT_REG / VIP_N_BANKS /
# VIP_CASCADE_DEPTH (see run_vip.tcl).
# Direct-mapped cold-flush and victim-cache example:
#   VIP_VICTIM=1 VIP_WAYS=1 VIP_LINE_W=8 VIP_LINES=16 ./tb/vip/run_vip.sh
# The cold whole-cache flush and X monitor cover reset-state victim-cache paths.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BUILD="${VIP_BUILD:-$REPO/tb/vip/build}"

vivado -mode batch -nojournal -nolog -source "$HERE/run_vip.tcl" >/dev/null

SIMDIR="$BUILD/vip_l2top.sim/sim_1/behav/xsim"
[ -d "$SIMDIR" ] || { echo "ERROR: sim scripts not generated at $SIMDIR"; exit 2; }

sed -i 's/ --relax//g' "$SIMDIR/elaborate.sh"
if grep -q -- '--relax' "$SIMDIR/elaborate.sh"; then
    echo "ERROR: --relax still present in elaborate.sh"; exit 2
fi
echo "Stripped --relax; elaborating strictly."

cd "$SIMDIR"
bash compile.sh   > compile.out  2>&1
bash elaborate.sh > elaborate.out 2>&1
bash simulate.sh  > simulate.out  2>&1 || true

echo "==== AXI VIP result ===="
grep -E 'VIP_RESULT|PASS T|FAIL T' simulate.log 2>/dev/null || {
    echo "No result line found; tail of elaborate/simulate:";
    tail -15 elaborate.out; tail -15 simulate.out;
}
grep -E 'VIP_RESULT PASS' simulate.log >/dev/null 2>&1
