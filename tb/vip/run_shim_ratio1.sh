#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Strict-xsim (4-state) regression for the tc_narrow_shim RATIO=1 (BLOCK_W==NARROW_W)
# offset bug (bug #32). At RATIO=1 a block IS one narrow word, so the sub-block word
# offset must be 0; a leaked address bit 2 indexes m_rdata/lb_data/m_wdata out of
# range -> X on odd 4-byte reads / dropped odd writes. Verilator MASKS the
# out-of-range part-select, so this can only be observed under xsim.
#
#   ./tb/vip/run_shim_ratio1.sh
#
# Exits non-zero (and prints FAIL) if any odd-offset read returns X or any odd
# write is dropped. Requires Vivado/xsim on PATH (source settings64.sh first).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BUILD="${SHIM_R1_BUILD:-$HERE/build_shim_ratio1}"

command -v xvlog >/dev/null 2>&1 || { echo "ERROR: xvlog not on PATH (source Vivado settings64.sh)"; exit 2; }

rm -rf "$BUILD"; mkdir -p "$BUILD"; cd "$BUILD"

xvlog -sv "$REPO/src/tc_narrow_shim.sv" "$HERE/tb_shim_ratio1.sv" >/dev/null

# Sweep RATIO=1 at several widths (BLOCK_W==NARROW_W) to prove the fix is
# width-independent, not tied to 32-bit. Override the TB params via -generic_top.
WIDTHS="${SHIM_R1_WIDTHS:-32 64 128}"
fails=0
for W in $WIDTHS; do
    OUT="$(xelab tb_shim_ratio1 -timescale 1ns/1ps \
              -generic_top "NARROW_W=$W" -generic_top "BLOCK_W=$W" -R 2>&1)"
    if echo "$OUT" | grep -q "TB_SHIM_RATIO1: PASS"; then
        echo "  NARROW_W=BLOCK_W=$W : PASS"
    else
        echo "  NARROW_W=BLOCK_W=$W : FAIL"
        echo "$OUT" | grep -iE "FAIL|TIMEOUT|read 0x|write 0x" | head
        fails=$((fails+1))
    fi
done

if [ "$fails" -eq 0 ]; then
    echo "run_shim_ratio1: PASS (widths: $WIDTHS)"
    exit 0
fi
echo "run_shim_ratio1: FAIL ($fails width(s) -- odd-offset read X or odd write dropped, bug #32)"
exit 1
