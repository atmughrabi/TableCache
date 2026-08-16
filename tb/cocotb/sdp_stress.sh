#!/usr/bin/env bash
# 100-seed test_random stress sweep for DATABANK_SDP=1.
# Drops summary at /tmp/tc_sdp_stress/summary.md
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-/tmp/tc_sdp_stress}"
N_SEEDS="${N_SEEDS:-100}"
NTXN="${NTXN:-100}"
mkdir -p "$OUT"
SUMMARY="$OUT/summary.md"

cd "$HERE"
source .venv/bin/activate

{
    echo "# DATABANK_SDP=1 stress sweep"
    echo
    echo "Config: ${N_SEEDS} seeds, NTXN=${NTXN}, +define+TC_DATABANK_SDP=1"
    echo
    echo "| Seed | Result | Wall(s) | Notes |"
    echo "|------|--------|--------:|-------|"
} > "$SUMMARY"

passed=0; failed=0; first_fail=""
for ((seed=1; seed<=N_SEEDS; seed++)); do
    rm -rf sim_build
    t0=$(date +%s)
    EXTRA_ARGS="+define+TC_DATABANK_SDP=1" NTXN=$NTXN SEED=$seed \
        timeout 180 make MODULE=test_random > "$OUT/seed_${seed}.log" 2>&1
    rc=$?
    dt=$(( $(date +%s) - t0 ))
    pc=$(grep -c AXI_PC_VIOLATION "$OUT/seed_${seed}.log" 2>/dev/null || true)
    pc=${pc:-0}
    if [[ $rc -eq 0 && $pc -eq 0 ]] \
        && grep -qE '\*\* TESTS=.*FAIL=0 ' "$OUT/seed_${seed}.log"; then
        echo "| $seed | PASS | $dt | - |" >> "$SUMMARY"
        passed=$((passed+1))
    else
        note=$(grep -oE '%Error[^"]*|FAIL[^[]*' "$OUT/seed_${seed}.log" | head -1 | tr '|' ' ' | cut -c1-60)
        echo "| $seed | **FAIL** | $dt | $note |" >> "$SUMMARY"
        failed=$((failed+1))
        [[ -z $first_fail ]] && first_fail=$seed
    fi
    # Progress tick
    if (( seed % 10 == 0 )); then
        echo "[stress] $seed/$N_SEEDS  pass=$passed fail=$failed  $(date +%H:%M:%S)" >&2
    fi
done

{
    echo
    echo "## Summary"
    echo "- Total seeds: $N_SEEDS"
    echo "- Passed: $passed"
    echo "- Failed: $failed"
    [[ -n $first_fail ]] && echo "- First failing seed: $first_fail"
} >> "$SUMMARY"

cat "$SUMMARY"
(( failed == 0 ))
