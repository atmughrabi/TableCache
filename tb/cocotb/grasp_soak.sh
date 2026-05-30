#!/usr/bin/env bash
# GRASP+SDP soak: N seeds of test_random under POLICY=GRASP DATABANK_SDP=1.
# Reuses sim_build across seeds (build once, only SEED env changes) like
# night_run.sh phase 1. Drops a per-seed log + summary.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
N_SEEDS="${N_SEEDS:-5000}"
NTXN="${NTXN:-200}"
OUT="${OUT:-/tmp/tc_grasp_soak}"
mkdir -p "$OUT"
SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"

cd "$HERE"
source .venv/bin/activate

log() { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*" | tee -a "$SUMMARY"; }

log "GRASP+SDP soak: $N_SEEDS seeds x NTXN=$NTXN, POLICY=GRASP +TC_DATABANK_SDP=1"

# Build once
rm -rf sim_build
log "build seed 1 (cold)"
EXTRA_ARGS="+define+TC_DATABANK_SDP=1" POLICY=GRASP SEED=1 NTXN=$NTXN \
    timeout 600 make MODULE=test_random > "$OUT/seed_1.log" 2>&1 || {
        log "  initial build FAILED"; exit 1; }
log "  build done"

pass=0; fail=0; first_fail=""
for seed in $(seq 1 $N_SEEDS); do
    [[ $seed -eq 1 ]] && continue   # already built+ran above
    EXTRA_ARGS="+define+TC_DATABANK_SDP=1" POLICY=GRASP SEED=$seed NTXN=$NTXN \
        timeout 90 make MODULE=test_random > "$OUT/seed_${seed}.log" 2>&1
    rc=$?
    pc=$(grep -c AXI_PC_VIOLATION "$OUT/seed_${seed}.log" 2>/dev/null)
    pc=${pc:-0}
    fail_n=$(grep -oE 'FAIL=[0-9]+' "$OUT/seed_${seed}.log" 2>/dev/null | head -1 | grep -oE '[0-9]+')
    fail_n=${fail_n:-0}
    if [[ $rc -ne 0 || $fail_n -ne 0 || $pc -ne 0 ]]; then
        fail=$((fail+1))
        log "  seed $seed FAIL rc=$rc fail=$fail_n pc=$pc"
        [[ -z $first_fail ]] && first_fail=$seed
    else
        pass=$((pass+1))
    fi
    if (( seed % 50 == 0 )); then
        log "  progress $seed/$N_SEEDS  pass=$pass fail=$fail"
    fi
done

log "DONE  pass=$pass fail=$fail"
[[ -n $first_fail ]] && log "first failing seed: $first_fail"
