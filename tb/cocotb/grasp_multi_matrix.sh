#!/usr/bin/env bash
# Config-matrix regression for the GRASP multi-window feature
# (test_grasp_multi). Sweeps window counts, associativity, DB latency, and
# the SDP+URAM databank to prove the N-region path holds across the
# deployment matrix. Each cell must report PASS=4 FAIL=0.
#
# Knobs: OUT (default /tmp/tc_grasp_multi_matrix)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-/tmp/tc_grasp_multi_matrix}"
mkdir -p "$OUT"
SUMMARY="$OUT/summary.md"
cd "$HERE"
source .venv/bin/activate

ts() { date +%H:%M:%S; }
: > "$SUMMARY"
echo "# GRASP multi-window config matrix ($(date -u +%FT%TZ))" >> "$SUMMARY"
echo "" >> "$SUMMARY"
echo "| # | Config | Result |" >> "$SUMMARY"
echo "|--:|--------|--------|" >> "$SUMMARY"

fails=0; n=0
run() {  # label  make-args...
    local label="$1"; shift
    n=$((n+1))
    rm -rf sim_build
    local log="$OUT/cell_${n}.log"
    if timeout 400 make MODULE=test_grasp_multi POLICY=GRASP "$@" > "$log" 2>&1 \
       && grep -qE '\*\* TESTS=[0-9]+ PASS=[0-9]+ FAIL=0 ' "$log"; then
        printf "[%s] %-58s PASS\n" "$(ts)" "$label"
        echo "| $n | \`$label\` | PASS |" >> "$SUMMARY"
    else
        printf "[%s] %-58s FAIL  (see %s)\n" "$(ts)" "$label" "$log"
        echo "| $n | \`$label\` | **FAIL** |" >> "$SUMMARY"
        fails=$((fails+1))
    fi
}

# --- window-count sweep (default WAYS=4 LINES=64 LINE_W=8) ---
run "HR=2 MR=2"                      GRASP_HIGH_REGIONS=2 GRASP_MODERATE_REGIONS=2
run "HR=3 MR=2"                      GRASP_HIGH_REGIONS=3 GRASP_MODERATE_REGIONS=2
run "HR=4 MR=4"                      GRASP_HIGH_REGIONS=4 GRASP_MODERATE_REGIONS=4
run "HR=8 MR=2 (exercises top window slot 7)" GRASP_HIGH_REGIONS=8 GRASP_MODERATE_REGIONS=2

# --- associativity sweep (HR=2 MR=2) ---
run "WAYS=2 HR=2 MR=2"               WAYS=2 GRASP_HIGH_REGIONS=2 GRASP_MODERATE_REGIONS=2
run "WAYS=8 HR=2 MR=2"               WAYS=8 GRASP_HIGH_REGIONS=2 GRASP_MODERATE_REGIONS=2

# --- DB latency + larger geometry ---
run "DB_LATENCY=3 HR=2 MR=2"         DB_LATENCY=3 GRASP_HIGH_REGIONS=2 GRASP_MODERATE_REGIONS=2
run "LINES=256 LINE_W=16 HR=2 MR=2"  LINES=256 LINE_W=16 GRASP_HIGH_REGIONS=2 GRASP_MODERATE_REGIONS=2

# --- SDP + URAM deployment databank ---
run "SDP+URAM WAYS=8 LINES=1024 LW=16 DB=2 HR=2 MR=2" \
    WAYS=8 LINES=1024 LINE_W=16 DB_LATENCY=2 DATABANK_SDP=1 \
    GRASP_HIGH_REGIONS=2 GRASP_MODERATE_REGIONS=2

echo "" >> "$SUMMARY"
echo "**$((n-fails))/$n cells PASS.**" >> "$SUMMARY"
echo ""
echo "=== $((n-fails))/$n cells PASS  (summary: $SUMMARY) ==="
exit $(( fails > 0 ? 1 : 0 ))
