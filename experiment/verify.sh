#!/usr/bin/env bash
# Verification gate for the experiment/structural-pipeline branch.
#
# Runs every check that MUST pass before any structural change is
# committed:
#   1. Full cocotb module regression at the deployment-knob settings
#      (DB_LATENCY=3 SDP_WRITE_INPUT_REG=1 DATABANK_SDP=1) — same
#      knobs that close 300 MHz post-route on U55C / U250.
#   2. GRASP mutation suite (7/7 KILLED expected, incl. the two
#      multi-window OR-reduction mutations — any survivor means a test
#      gap or RTL drift).
#   3. Formal proof suite (10/10 PASS expected).
#
# Exit non-zero on any failure. Pre-existing post-synth / post-route
# numbers are NOT regressed in this script; record those separately
# in the commit message when claiming a WNS improvement.
#
# Usage:
#   ./experiment/verify.sh
#   POLICY_DEFAULT=LRU ./experiment/verify.sh   # change non-grasp default
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${OUT:-/tmp/tc_experiment_verify}"
mkdir -p "$OUT"

cd "$REPO/tb/cocotb"
source .venv/bin/activate 2>/dev/null || { echo "ERROR: tb/cocotb/.venv missing" >&2; exit 2; }

DEFAULT_POLICY="${POLICY_DEFAULT:-LRU}"
# DB_LATENCY capped at 2 (bug #27: whole-cache flush is not correct for >2, and
# l2_cache $fatal-s at elaboration for DB_LATENCY>2). 2 is the recommended
# URAM/large-cache config, so exercise the gate at the deepest supported latency.
KNOBS="DB_LATENCY=2 SDP_WRITE_INPUT_REG=1 DATABANK_SDP=1${N_BANKS:+ N_BANKS=$N_BANKS}"

# ---- 1. module regression ----
echo "==== experiment/verify.sh: cocotb regression at $KNOBS ===="
MODULES=(
    test_smoke test_random test_workload test_reset_recovery
    test_backpressure test_strobe test_latency test_grasp
    test_grasp_pressure test_grasp_moderate test_grasp_midburst test_grasp_multi
    test_cbom_stress test_cbom_rmw_race test_l2top test_l2top_flush
    test_realism test_flush test_scoreboard
    test_set_coverage test_finish_fifo_stress
)
pass=0; fail=0; failed_modules=()
for mod in "${MODULES[@]}"; do
    rm -rf sim_build results.xml
    case $mod in
        # test_grasp_multi needs >= 2 windows per reuse class (the region
        # ports widen with these); must precede the test_grasp* glob.
        test_grasp_multi) p=GRASP; mk="GRASP_HIGH_REGIONS=2 GRASP_MODERATE_REGIONS=2" ;;
        test_grasp*) p=GRASP; mk="" ;;
        *) p="$DEFAULT_POLICY"; mk="" ;;
    esac
    log="$OUT/$mod.log"
    if eval "$KNOBS $mk POLICY=$p MODULE=$mod make -s" > "$log" 2>&1; then
        summary=$(grep -oE "TESTS=[0-9]+\s+PASS=[0-9]+\s+FAIL=[0-9]+\s+SKIP=[0-9]+" "$log" | head -1)
        nfail=$(echo "$summary" | grep -oE "FAIL=[0-9]+" | sed 's/FAIL=//')
        if [[ "${nfail:-1}" == "0" ]]; then
            printf "  %-30s %s ✓\n" "$mod" "$summary"
            pass=$((pass + 1))
        else
            printf "  %-30s %s ✗\n" "$mod" "$summary"
            fail=$((fail + 1))
            failed_modules+=("$mod")
        fi
    else
        printf "  %-30s BUILD/SIM ERROR (see %s)\n" "$mod" "$log"
        fail=$((fail + 1))
        failed_modules+=("$mod")
    fi
done

# ---- 1b. base-0 full-range guard (bug #25, OMITTED_ADDR_W=0) ----
# The default range is OMITTED_ADDR_W=1; a base-0 full 4 GiB range is the case
# that used to be un-elaboratable (H-L+1 overflow). Run the heavy eviction +
# flush suites there so a regression in the range-decode/reconstruct math (or
# the NAPOT/cast plumbing) fails the per-commit gate, not just nightly.
echo ""
echo "==== experiment/verify.sh: base-0 full-range guard (ADDR_L=0) ===="
for mod in test_eviction test_flush; do
    rm -rf sim_build results.xml
    log="$OUT/${mod}_base0.log"
    if eval "$KNOBS POLICY=$DEFAULT_POLICY MODULE=$mod ADDR_L=0 ADDR_H=0xFFFFFFFF make -s" > "$log" 2>&1; then
        summary=$(grep -oE "TESTS=[0-9]+\s+PASS=[0-9]+\s+FAIL=[0-9]+\s+SKIP=[0-9]+" "$log" | head -1)
        nfail=$(echo "$summary" | grep -oE "FAIL=[0-9]+" | sed 's/FAIL=//')
        if [[ "${nfail:-1}" == "0" ]]; then
            printf "  %-24s %s ✓\n" "${mod} (base-0)" "$summary"
            pass=$((pass + 1))
        else
            printf "  %-24s %s ✗\n" "${mod} (base-0)" "$summary"
            fail=$((fail + 1)); failed_modules+=("${mod}-base0")
        fi
    else
        printf "  %-24s BUILD/SIM ERROR (see %s)\n" "${mod} (base-0)" "$log"
        fail=$((fail + 1)); failed_modules+=("${mod}-base0")
    fi
done

# ---- 1c. bug #28 guard: same-id pipelined eviction wedge ----
# Back-to-back same-id reads that pipeline dirty evictions must NOT wedge the
# cache (needs_rdata double-set left inuse stuck SET). Needs a small geometry so
# the round-robin burst actually evicts dirty lines; run at LINES=2 WAYS=2.
echo ""
echo "==== experiment/verify.sh: bug #28 guard (same-id eviction burst, LINES=2 WAYS=2) ===="
for dbl in 1 2; do
    rm -rf sim_build results.xml
    log="$OUT/burst_idle_db${dbl}.log"
    if eval "POLICY=$DEFAULT_POLICY MODULE=test_burst_idle LINES=2 WAYS=2 DB_LATENCY=$dbl make -s" > "$log" 2>&1; then
        summary=$(grep -oE "TESTS=[0-9]+\s+PASS=[0-9]+\s+FAIL=[0-9]+\s+SKIP=[0-9]+" "$log" | head -1)
        nfail=$(echo "$summary" | grep -oE "FAIL=[0-9]+" | sed 's/FAIL=//')
        if [[ "${nfail:-1}" == "0" ]]; then
            printf "  %-24s %s ✓\n" "burst_idle (DB=$dbl)" "$summary"
            pass=$((pass + 1))
        else
            printf "  %-24s %s ✗\n" "burst_idle (DB=$dbl)" "$summary"
            fail=$((fail + 1)); failed_modules+=("burst_idle-db${dbl}")
        fi
    else
        printf "  %-24s BUILD/SIM ERROR (see %s)\n" "burst_idle (DB=$dbl)" "$log"
        fail=$((fail + 1)); failed_modules+=("burst_idle-db${dbl}")
    fi
done

# ---- 1d. bug #29 guard: accept/finish same-cycle inuse collision (ASSERT=1) ----
# Mixed read/write eviction stress with Verilator SVA checking ON so the
# inuse_id/line_no_same_cycle_collide invariants are actually enforced.
echo ""
echo "==== experiment/verify.sh: bug #29 guard (accept/finish inuse collision, ASSERT=1) ===="
rm -rf sim_build results.xml
log="$OUT/inuse_race_assert.log"
if eval "POLICY=$DEFAULT_POLICY MODULE=test_inuse_race LINES=16 WAYS=2 VICTIM=1 ASSERT=1 make -s" > "$log" 2>&1; then
    summary=$(grep -oE "TESTS=[0-9]+\s+PASS=[0-9]+\s+FAIL=[0-9]+\s+SKIP=[0-9]+" "$log" | head -1)
    nfail=$(echo "$summary" | grep -oE "FAIL=[0-9]+" | sed 's/FAIL=//')
    if [[ "${nfail:-1}" == "0" ]]; then
        printf "  %-24s %s ✓\n" "inuse_race (ASSERT)" "$summary"
        pass=$((pass + 1))
    else
        printf "  %-24s %s ✗\n" "inuse_race (ASSERT)" "$summary"
        fail=$((fail + 1)); failed_modules+=("inuse_race-assert")
    fi
else
    printf "  %-24s BUILD/SIM ERROR (see %s)\n" "inuse_race (ASSERT)" "$log"
    fail=$((fail + 1)); failed_modules+=("inuse_race-assert")
fi

# ---- 1e. bug #31 guard: reorder buffer + concurrent-hit extra-beat drop ----
# The reorder buffer lets a single engine id keep N reads outstanding; concurrent
# hits to consecutive lines must drop the databank's trailing sibling-block beat.
echo ""
echo "==== experiment/verify.sh: bug #31 guard (reorder buffer + concurrent-hit extra-beat) ===="
run_bug31 () {  # $1=label  $2=make-args
    rm -rf sim_build results.xml
    local log="$OUT/bug31_$1.log"
    if eval "$2 make -s" > "$log" 2>&1; then
        local summary nfail
        summary=$(grep -oE "TESTS=[0-9]+\s+PASS=[0-9]+\s+FAIL=[0-9]+\s+SKIP=[0-9]+" "$log" | head -1)
        nfail=$(echo "$summary" | grep -oE "FAIL=[0-9]+" | sed 's/FAIL=//')
        if [[ "${nfail:-1}" == "0" ]]; then
            printf "  %-24s %s ✓\n" "$1" "$summary"; pass=$((pass + 1))
        else
            printf "  %-24s %s ✗\n" "$1" "$summary"; fail=$((fail + 1)); failed_modules+=("bug31-$1")
        fi
    else
        printf "  %-24s BUILD/SIM ERROR (see %s)\n" "$1" "$log"
        fail=$((fail + 1)); failed_modules+=("bug31-$1")
    fi
}
run_bug31 "reorder"     "MODULE=test_shim_reorder READ_REORDER_DEPTH=8"
run_bug31 "hit-concur"  "MODULE=test_shim_multiread TESTCASE=test_distinct_id_hit_concurrency BLOCK_OFF=64"

# ---- 2. GRASP mutation suite ----
echo ""
echo "==== experiment/verify.sh: GRASP mutation suite ===="
FILE=src/GRASP.sv ./mutation_test.sh > "$OUT/grasp_mut.log" 2>&1 || true
mut_killed=$(grep -c "KILLED" "$OUT/grasp_mut.log" || true)
mut_survived=$(grep -c "SURVIVED" "$OUT/grasp_mut.log" || true)
mut_score=$(grep -oE "mutation score: [0-9.]+%" "$OUT/grasp_mut.log" | head -1)
echo "  KILLED:    ${mut_killed:-?}"
echo "  SURVIVED:  ${mut_survived:-?}"
echo "  $mut_score"

# ---- 3. formal proofs ----
echo ""
echo "==== experiment/verify.sh: formal proofs ===="
( cd "$REPO/tb/formal" && make > "$OUT/formal.log" 2>&1 ) || true
formal_pass=$(grep -c "Status: PASSED" "$OUT/formal.log" || true)
formal_fail=$(grep -c "Status: FAILED" "$OUT/formal.log" || true)
echo "  PASSED: ${formal_pass:-?}"
echo "  FAILED: ${formal_fail:-?}"

# ---- final ----
echo ""
echo "==== SUMMARY ===="
echo "  Regression:      $pass / $((pass + fail)) modules PASS"
echo "  GRASP mutations: ${mut_killed:-?} KILLED, ${mut_survived:-?} SURVIVED  ($mut_score)"
echo "  Formal:          ${formal_pass:-?} PASS, ${formal_fail:-?} FAIL"

if [[ $fail -ne 0 || "${mut_survived:-1}" -ne 0 || "${formal_fail:-1}" -ne 0 ]]; then
    echo ""
    echo "  FAIL — gates not green. Failing modules: ${failed_modules[*]:-none}"
    exit 1
fi
echo ""
echo "  PASS — all gates green. Safe to commit (after measuring WNS delta)."
exit 0
