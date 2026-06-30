#!/usr/bin/env bash
# Overnight stress runner.
#
# Phase 1: huge seed sweep on test_random (build once, reuse sim_build).
# Phase 2: extra-long test_workload (200k ops).
# Phase 3: matrix sweep across all policies / ways.
# Phase 4: mutation re-baselines (incl. src/GRASP.sv -> 7 mutations).
# Phase 5: GRASP multi-window config matrix + hit-rate perf demo.
# Phase 6: Vivado AXI VIP cold-reset (xsim, 4-state) -- small + LINES=512/GRASP.
#          Auto-skipped when Vivado is not on PATH.
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
         src/GRASP.sv \
         src/tdp_ram.sv src/victim_cache.sv; do
    FILE=$f ./mutation_test.sh > "$OUT/phase4_${f//\//_}.log" 2>&1
    score=$(grep -E '^  mutation score:' "$OUT/phase4_${f//\//_}.log" | tail -1)
    log "  $f -- $score"
    # All instrumented files score 100% (documented-equivalent mutations are
    # excluded from the matrix). Anything less is a coverage regression.
    if ! echo "$score" | grep -q '100.0%'; then
        log "    WARNING: mutation score regressed for $f"
        fail=$((fail+1))
    fi
done
log "PHASE 4 done"

# ----------------------------------------------------------------------
# Phase 5 -- GRASP multi-window (N-region) config matrix + perf demo
# Covers test_grasp_multi across window counts / WAYS / DB latency /
# SDP+URAM, plus the fallback-vs-single-vs-multi hit-rate demonstration.
# ----------------------------------------------------------------------
log "PHASE 5: GRASP multi-window config matrix + perf demo"
rm -rf sim_build
OUT="$OUT/grasp_multi_matrix" timeout 3600 ./grasp_multi_matrix.sh > "$OUT/phase5_matrix.log" 2>&1
rc=$?
log "PHASE 5 matrix done: rc=$rc | $(grep -E 'cells PASS' "$OUT/phase5_matrix.log" | tail -1)"
[[ $rc -eq 0 ]] || fail=$((fail+1))
rm -rf sim_build
POLICY=GRASP GRASP_HIGH_REGIONS=4 timeout 600 make MODULE=test_grasp_multi_perf \
    > "$OUT/phase5_perf.log" 2>&1
rc=$?
perf=$(grep -E 'multi vs fallback' "$OUT/phase5_perf.log" | tail -1)
log "PHASE 5 perf done: rc=$rc | ${perf:-no perf line}"
if [[ $rc -ne 0 ]] || ! grep -qE '\*\* TESTS=[0-9]+ PASS=[0-9]+ FAIL=0 ' "$OUT/phase5_perf.log"; then
    fail=$((fail+1))
fi
log "PHASE 5 done"

# ----------------------------------------------------------------------
# Phase 6 -- Vivado AXI VIP cold-reset check (4-state / xsim). The cocotb
# phases above run under Verilator (2-state) and cannot observe the cold
# power-on X bug this guards. Skipped automatically when Vivado is absent.
# ----------------------------------------------------------------------
log "PHASE 6: AXI VIP cold-reset (xsim)"
if command -v vivado >/dev/null 2>&1; then
    rc=0
    VIP_BUILD="$OUT/vip_build_small" timeout 1200 "$HERE/../vip/run_vip.sh" \
        > "$OUT/phase6_vip_small.log" 2>&1 || rc=$?
    log "PHASE 6 small: rc=$rc | $(grep -E 'VIP_RESULT' "$OUT/phase6_vip_small.log" | tail -1)"
    [[ $rc -eq 0 ]] || fail=$((fail+1))
    rc=0
    VIP_BUILD="$OUT/vip_build_512" VIP_LINES=512 VIP_WAYS=4 VIP_LINE_W=8 VIP_POLICY=GRASP \
        timeout 1800 "$HERE/../vip/run_vip.sh" > "$OUT/phase6_vip_512.log" 2>&1 || rc=$?
    log "PHASE 6 512/GRASP: rc=$rc | $(grep -E 'VIP_RESULT' "$OUT/phase6_vip_512.log" | tail -1)"
    [[ $rc -eq 0 ]] || fail=$((fail+1))
else
    log "PHASE 6 SKIPPED: vivado not on PATH"
fi
log "PHASE 6 done"

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
