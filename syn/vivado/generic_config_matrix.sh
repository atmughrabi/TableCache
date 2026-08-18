#!/usr/bin/env bash
# Vivado OOC synthesis corners for generic parameter deployment.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/build/generic_config_matrix"
rm -rf "$OUT"
mkdir -p "$OUT"
tclsh "$HERE/test_generic_literals.tcl"

run_cell() {
    local tag=$1 top=$2
    shift 2
    echo "==== generic synth: $tag ===="
    rm -rf "$HERE/build/$top"
    if ! env TOP="$top" "$@" "$HERE/run_synth.sh" > "$OUT/$tag.log" 2>&1; then
        tail -80 "$OUT/$tag.log"
        return 1
    fi
    if grep -q '^ERROR:' "$OUT/$tag.log" ||
       [[ ! -f "$HERE/build/$top/utilization.rpt" ]]; then
        tail -80 "$OUT/$tag.log"
        echo "FAIL: $tag synthesis did not produce reports" >&2
        return 1
    fi
    mv "$HERE/build/$top" "$OUT/$tag"
    echo "PASS: $tag"
}

run_cell lru_w3_id2 l2_cache \
    WAYS=3 LINES=64 LINE_W=8 POLICY=0 \
    READ_ID_WIDTH=2 WRITE_ID_WIDTH=2 DB_LATENCY=2

run_cell sdp_one_line_per_bank l2_cache \
    WAYS=4 LINES=4 LINE_W=8 POLICY=0 \
    READ_ID_WIDTH=3 WRITE_ID_WIDTH=3 DB_LATENCY=2 \
    DATABANK_SDP=1 SDP_WRITE_INPUT_REG=1 N_BANKS=4 CASCADE_DEPTH=1

run_cell shim_id3_depth7 tc_narrow_shim \
    NARROW_W=32 BLOCK_W=512 ID_W=3 \
    MAX_OUTSTANDING_W=8 READ_REORDER_DEPTH=7

run_cell addr32_full l2_cache \
    WAYS=2 LINES=64 LINE_W=8 POLICY=0 \
    ADDR_W=32 ADDR_RANGE_L=0 ADDR_RANGE_H=0xFFFFFFFF

run_cell addr33_full l2_cache \
    WAYS=2 LINES=64 LINE_W=8 POLICY=0 \
    ADDR_W=33 ADDR_RANGE_L=0 ADDR_RANGE_H=0x1FFFFFFFF

run_cell addr34_full l2_cache \
    WAYS=2 LINES=64 LINE_W=8 POLICY=0 \
    ADDR_W=34 ADDR_RANGE_L=0 ADDR_RANGE_H=0x3FFFFFFFF

run_cell addr64_full l2_cache \
    WAYS=2 LINES=64 LINE_W=8 POLICY=0 \
    ADDR_W=64 ADDR_RANGE_L=0 ADDR_RANGE_H=0xFFFFFFFFFFFFFFFF

run_cell l2top_addr64_full l2_top \
    WAYS=2 LINES=64 LINE_W=8 REPLACEMENT_POLICY=0 \
    C_S00_AXI_ADDR_WIDTH=64 C_M00_AXI_ADDR_WIDTH=64 \
    ADDR_L=0 ADDR_H=0xFFFFFFFFFFFFFFFF

run_cell l2top_addr32_full l2_top \
    WAYS=2 LINES=64 LINE_W=8 REPLACEMENT_POLICY=0 \
    C_S00_AXI_ADDR_WIDTH=32 C_M00_AXI_ADDR_WIDTH=32 \
    ADDR_L=0 ADDR_H=0xFFFFFFFF

run_cell l2top_addr33_full l2_top \
    WAYS=2 LINES=64 LINE_W=8 REPLACEMENT_POLICY=0 \
    C_S00_AXI_ADDR_WIDTH=33 C_M00_AXI_ADDR_WIDTH=33 \
    ADDR_L=0 ADDR_H=0x1FFFFFFFF

run_cell l2top_addr34_full l2_top \
    WAYS=2 LINES=64 LINE_W=8 REPLACEMENT_POLICY=0 \
    C_S00_AXI_ADDR_WIDTH=34 C_M00_AXI_ADDR_WIDTH=34 \
    ADDR_L=0 ADDR_H=0x3FFFFFFFF

run_cell flush_addr32_full tc_flush_controller \
    LINES=64 WAYS=2 LINE_W=8 BLOCK_W=32 ID_W=4 \
    ADDR_W=32 ADDR_BASE=0 ADDR_RANGE_H=0xFFFFFFFF

run_cell flush_addr33_full tc_flush_controller \
    LINES=64 WAYS=2 LINE_W=8 BLOCK_W=32 ID_W=4 \
    ADDR_W=33 ADDR_BASE=0 ADDR_RANGE_H=0x1FFFFFFFF

run_cell flush_addr34_full tc_flush_controller \
    LINES=64 WAYS=2 LINE_W=8 BLOCK_W=32 ID_W=4 \
    ADDR_W=34 ADDR_BASE=0 ADDR_RANGE_H=0x3FFFFFFFF

run_cell flush_addr64_full tc_flush_controller \
    LINES=64 WAYS=2 LINE_W=8 BLOCK_W=32 ID_W=4 \
    ADDR_W=64 ADDR_BASE=0 ADDR_RANGE_H=0xFFFFFFFFFFFFFFFF

echo "generic_config_matrix: 15/15 PASS"
