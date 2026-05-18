#!/usr/bin/env bash
# Deferred validation script -- waits for the in-flight night_run.sh
# (PID file or auto-detected) to finish, then runs the validations that
# depend on sim_build/: test_flush, test_shim_prefill_race, mutation
# re-baselines for cache + shim.
#
# Launch:
#   nohup ./validate_pending.sh > /tmp/tc_night/validate.log 2>&1 &
#
# Output appended to /tmp/tc_night/summary.txt under a "DEFERRED PHASE 5"
# header.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT=${OUT:-/tmp/tc_night}
mkdir -p "$OUT"
cd "$HERE"
source .venv/bin/activate

SUMMARY="$OUT/summary.txt"
log() { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*" | tee -a "$SUMMARY"; }

# Wait for the night_run.sh process to exit (poll every 30s).
log "DEFERRED PHASE 5: waiting for night_run.sh to finish before validating new tests..."
while pgrep -f "night_run\\.sh" >/dev/null 2>&1; do
    sleep 30
done
log "  night_run.sh has exited; sim_build/ is now free"

fail=0

# Test 1: test_shim_prefill_race (drafted last session)
log "  running test_shim_prefill_race ..."
rm -rf sim_build sim_build_shim
timeout 300 make MODULE=test_shim_prefill_race > "$OUT/p5_shim_prefill_race.log" 2>&1
rc=$?
pc=$(grep -c AXI_PC_VIOLATION "$OUT/p5_shim_prefill_race.log" 2>/dev/null); pc=${pc:-0}
fail_n=$(grep -oE 'FAIL=[0-9]+' "$OUT/p5_shim_prefill_race.log" | head -1 | grep -oE '[0-9]+'); fail_n=${fail_n:-0}
log "    test_shim_prefill_race: rc=$rc PC=$pc FAIL=$fail_n"
[[ $rc -eq 0 && $pc -eq 0 && $fail_n -eq 0 ]] || fail=$((fail+1))

# Test 2: test_flush (new this session)
log "  running test_flush ..."
rm -rf sim_build sim_build_shim
timeout 600 make MODULE=test_flush > "$OUT/p5_test_flush.log" 2>&1
rc=$?
pc=$(grep -c AXI_PC_VIOLATION "$OUT/p5_test_flush.log" 2>/dev/null); pc=${pc:-0}
fail_n=$(grep -oE 'FAIL=[0-9]+' "$OUT/p5_test_flush.log" | head -1 | grep -oE '[0-9]+'); fail_n=${fail_n:-0}
log "    test_flush: rc=$rc PC=$pc FAIL=$fail_n"
[[ $rc -eq 0 && $pc -eq 0 && $fail_n -eq 0 ]] || fail=$((fail+1))

# Mutation re-baseline on shim (test_shim_prefill_race should kill drop_prefill_check)
log "  re-running shim mutation set ..."
FILE=src/tc_narrow_shim.sv ./mutation_test.sh > "$OUT/p5_mutation_shim.log" 2>&1
score=$(grep -E '^  mutation score:' "$OUT/p5_mutation_shim.log" | tail -1)
killed=$(grep -E '^  killed:' "$OUT/p5_mutation_shim.log" | tail -1)
log "    shim mutation $killed | $score"

# Note: prefill mutation is only killed if test_shim_prefill_race is in the
# test list. Add it on the fly via TESTS override:
log "  re-running shim mutation set with test_shim_prefill_race included ..."
TESTS="test_narrow_shim test_shim_cache test_shim_throughput test_shim_prefill_race" \
    FILE=src/tc_narrow_shim.sv ./mutation_test.sh > "$OUT/p5_mutation_shim_full.log" 2>&1
score=$(grep -E '^  mutation score:' "$OUT/p5_mutation_shim_full.log" | tail -1)
killed=$(grep -E '^  killed:' "$OUT/p5_mutation_shim_full.log" | tail -1)
log "    shim mutation (with prefill test) $killed | $score"

log "============================================="
if [[ $fail -eq 0 ]]; then
    log "DEFERRED PHASE 5: ALL CLEAN (test_flush + test_shim_prefill_race PASS)"
else
    log "DEFERRED PHASE 5: $fail failure(s) -- check $OUT/p5_*.log"
fi
log "============================================="
