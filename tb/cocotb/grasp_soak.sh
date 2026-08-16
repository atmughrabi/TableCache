#!/usr/bin/env bash
# GRASP+SDP soak: N seeds of test_random under POLICY=GRASP DATABANK_SDP=1.
# Reuses sim_build across seeds and writes a per-seed log plus summary.
set -uo pipefail
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

if (( N_SEEDS < 1 )); then
    log "N_SEEDS must be at least 1"
    exit 2
fi

pass=0; fail=0; first_fail=""

score_seed() {
    local seed=$1 rc=$2
    local logfile="$OUT/seed_${seed}.log"
    local pc fail_n
    pc=$(grep -c AXI_PC_VIOLATION "$logfile" 2>/dev/null || true)
    fail_n=$(grep -oE 'FAIL=[0-9]+' "$logfile" 2>/dev/null \
        | tail -1 | grep -oE '[0-9]+' || true)
    pc=${pc:-0}
    fail_n=${fail_n:-0}
    if [[ $rc -ne 0 || $fail_n -ne 0 || $pc -ne 0 ]]; then
        fail=$((fail + 1))
        log "  seed $seed FAIL rc=$rc fail=$fail_n pc=$pc"
        [[ -z $first_fail ]] && first_fail=$seed
        return 1
    fi
    pass=$((pass + 1))
    return 0
}

# Build once
rm -rf sim_build
log "build seed 1 (cold)"
EXTRA_ARGS="+define+TC_DATABANK_SDP=1" POLICY=GRASP SEED=1 NTXN=$NTXN \
    timeout 600 make MODULE=test_random > "$OUT/seed_1.log" 2>&1
seed_rc=$?
score_seed 1 "$seed_rc" || {
    [[ $seed_rc -eq 0 ]] || exit 1
}
log "  build done"

for seed in $(seq 1 $N_SEEDS); do
    [[ $seed -eq 1 ]] && continue   # already built+ran above
    EXTRA_ARGS="+define+TC_DATABANK_SDP=1" POLICY=GRASP SEED=$seed NTXN=$NTXN \
        timeout 90 make MODULE=test_random > "$OUT/seed_${seed}.log" 2>&1
    rc=$?
    score_seed "$seed" "$rc" || true
    if (( seed % 50 == 0 )); then
        log "  progress $seed/$N_SEEDS  pass=$pass fail=$fail"
    fi
done

log "DONE  pass=$pass fail=$fail"
[[ -n $first_fail ]] && log "first failing seed: $first_fail"
(( fail == 0 ))
