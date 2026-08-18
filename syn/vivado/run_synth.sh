#!/usr/bin/env bash
# Wrapper around run_synth.tcl. Sweeps top modules or just one.
#
#   ./run_synth.sh                                  # default: l2_cache
#   TOP=tc_narrow_shim ./run_synth.sh
#   ALL=1 ./run_synth.sh                            # all 3 user-facing tops
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

VIVADO=${VIVADO:-/opt/xilinx/2025.2/Vivado/bin/vivado}
if [[ ! -x "$VIVADO" ]]; then
    echo "Vivado not found at $VIVADO. Set VIVADO=/path/to/vivado." >&2
    exit 2
fi

if [[ "${ALL:-0}" == "1" ]]; then
    TOPS="l2_cache tc_narrow_shim tc_flush_controller"
else
    TOPS="${TOP:-l2_cache}"
fi

for top in $TOPS; do
    OUT="$HERE/build/$top"
    mkdir -p "$OUT"
    rm -f "$OUT/utilization.rpt" "$OUT/timing_summary.rpt" "$OUT/methodology.rpt"
    echo "==== synth: $top -> $OUT ===="
    cd "$OUT"
    set +e
    "$VIVADO" -mode batch -source "$HERE/run_synth.tcl" \
              -tclargs "$top" "$REPO" "$OUT" \
              -log "$OUT/vivado.log" -journal "$OUT/vivado.jou" \
              -notrace 2>&1 | tee "$OUT/synth.log" \
        | grep -E "^(====|WARNING|CRITICAL|ERROR|UTIL|TIMING|METHOD|Worst|Total|generic value|top ')"
    vivado_rc=${PIPESTATUS[0]}
    set -e
    if (( vivado_rc != 0 )); then
        echo "Vivado failed for top=$top (rc=$vivado_rc); see $OUT/synth.log." >&2
        exit "$vivado_rc"
    fi
    if ! grep -Fq "==== synthesis complete: $top ====" "$OUT/synth.log"; then
        echo "Vivado did not complete run_synth.tcl for top=$top." >&2
        exit 1
    fi
    for report in utilization.rpt timing_summary.rpt methodology.rpt; do
        if [[ ! -s "$OUT/$report" ]]; then
            echo "Vivado did not produce $OUT/$report for top=$top." >&2
            exit 1
        fi
    done

    # Headline numbers for the table.
    echo "---- $top headline ----"
    grep -E "(CLB LUTs|CLB Registers|Block RAM Tile|LUT as Memory|DSPs)" \
         "$OUT/utilization.rpt" | head -10 || true
    grep -E "(WNS|WHS|TNS|THS)" "$OUT/timing_summary.rpt" | head -8 || true
done
