#!/usr/bin/env bash
# Overnight stress runner.
#
# Phase 1: huge seed sweep on test_random (build once, reuse sim_build).
# Phase 2: extra-long test_workload (200k ops).
# Phase 3: matrix sweep across all policies / ways.
#
# Each phase writes its own log under /tmp/tc_night/<phase>.log and an
# entry to /tmp/tc_night/summary.txt. Designed to finish in 4-8 hours.
#
# Launch:
#   nohup ./night_run.sh > /tmp/tc_night/main.log 2>&1 &
#
# Inspect progress:
#   tail -f /tmp/tc_night/summary.txt

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT=${OUT:-/tmp/tc_night}
mkdir -p "$OUT"
cd "$HERE"
source .venv/bin/activate

SUMMARY="$OUT/summary.txt"
: > "$SUMMARY"

log() { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*" | tee -a "$SUMMARY"; }
fail=0

# ----------------------------------------------------------------------
# Phase 1 -- seed sweep test_random, 500 seeds x NTXN=300
# Reuses sim_build across seeds (only TC_SEED env changes between runs)
# ----------------------------------------------------------------------
log "PHASE 1: test_random seed sweep, 500 seeds x NTXN=300"
rm -rf sim_build
NTXN=300 SEED=1 timeout 600 make MODULE=test_random > "$OUT/phase1_build.log" 2>&1 || { log "  build failed"; fail=$((fail+1)); }
log "  phase 1 build done"

p1_pass=0; p1_fail=0; p1_pc=0
for seed in $(seq 1 500); do
    NTXN=300 SEED=$seed timeout 60 make MODULE=test_random > "$OUT/p1_seed_$seed.log" 2>&1
    rc=$?
    pc=$(grep -c AXI_PC_VIOLATION "$OUT/p1_seed_$seed.log" 2>/dev/null); pc=${pc:-0}
    fail_n=$(grep -oE 'FAIL=[0-9]+' "$OUT/p1_seed_$seed.log" | head -1 | grep -oE '[0-9]+'); fail_n=${fail_n:-0}
    if [[ $rc -ne 0 || $fail_n -ne 0 ]]; then
        p1_fail=$((p1_fail+1))
        log "  seed $seed FAIL rc=$rc fail=$fail_n"
    else
        p1_pass=$((p1_pass+1))
    fi
    p1_pc=$((p1_pc + pc))
    # Keep only the failing logs to save space
    [[ $rc -eq 0 && $fail_n -eq 0 && $pc -eq 0 ]] && rm -f "$OUT/p1_seed_$seed.log"
    # Periodic progress
    (( seed % 50 == 0 )) && log "  ... seed $seed/500 (pass=$p1_pass fail=$p1_fail pc=$p1_pc)"
done
log "PHASE 1 done: pass=$p1_pass fail=$p1_fail pc_violations_total=$p1_pc"
[[ $p1_fail -eq 0 && $p1_pc -eq 0 ]] || fail=$((fail+1))

# ----------------------------------------------------------------------
# Phase 2 -- one giant test_workload run (200k ops)
# ----------------------------------------------------------------------
log "PHASE 2: test_workload NTXN=200000"
rm -rf sim_build
NTXN=200000 SEED=1 timeout 7200 make MODULE=test_workload > "$OUT/phase2.log" 2>&1
rc=$?
pc=$(grep -c AXI_PC_VIOLATION "$OUT/phase2.log" 2>/dev/null); pc=${pc:-0}
fail_n=$(grep -oE 'FAIL=[0-9]+' "$OUT/phase2.log" | head -1 | grep -oE '[0-9]+'); fail_n=${fail_n:-0}
log "PHASE 2 done: rc=$rc fail=$fail_n pc=$pc"
[[ $rc -eq 0 && $fail_n -eq 0 && $pc -eq 0 ]] || fail=$((fail+1))

# ----------------------------------------------------------------------
# Phase 3 -- pytest matrix sweep with 4 seeds per combo
# ----------------------------------------------------------------------
log "PHASE 3: test_matrix.py sweep"
rm -rf sim_build .pytest_cache
timeout 3600 pytest -q test_matrix.py > "$OUT/phase3.log" 2>&1
rc=$?
log "PHASE 3 done: rc=$rc | $(grep -E 'passed|failed' "$OUT/phase3.log" | tail -1)"
[[ $rc -eq 0 ]] || fail=$((fail+1))

# ----------------------------------------------------------------------
# Phase 4 -- mutation re-baselines (sanity check that scores haven't drifted)
# ----------------------------------------------------------------------
log "PHASE 4: mutation re-baselines"
for f in src/l2_cache.sv src/tc_narrow_shim.sv src/tc_flush_controller.sv \
         src/l2_databank.sv src/replacement_policy.sv \
         src/fifo.sv src/toggle_memory.sv \
         src/lutram_1w_1r.sv src/lfsr.sv src/sdp_ram.sv \
         src/l2_tagbank.sv src/LRU.sv \
         src/SRRIP.sv src/FRQ.sv src/second_chance.sv src/random_replacement.sv \
         src/tdp_ram.sv src/victim_cache.sv; do
    FILE=$f ./mutation_test.sh > "$OUT/phase4_${f//\//_}.log" 2>&1
    score=$(grep -E '^  mutation score:' "$OUT/phase4_${f//\//_}.log" | tail -1)
    log "  $f -- $score"
done
log "PHASE 4 done"

# ----------------------------------------------------------------------
# Final summary
# ----------------------------------------------------------------------
log "============================================="
if [[ $fail -eq 0 ]]; then
    log "OVERNIGHT RUN: ALL PHASES CLEAN"
else
    log "OVERNIGHT RUN: $fail phase(s) had failures -- check $OUT/"
fi
log "============================================="
