#!/usr/bin/env bash
# Vivado OOC synthesis corners for generic parameter deployment.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/build/generic_config_matrix"
rm -rf "$OUT"
mkdir -p "$OUT"

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

echo "generic_config_matrix: 3/3 PASS"
