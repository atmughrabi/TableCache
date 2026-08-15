#!/usr/bin/env bash
# Full regression, stress, mutation, xsim, and synthesis verification.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT=${OUT:-/tmp/tc_night}
SUMMARY="$OUT/summary.txt"
mkdir -p "$OUT"
cd "$HERE"
source .venv/bin/activate
: > "$SUMMARY"

fail=0
log() { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*" | tee -a "$SUMMARY"; }

run_logged() {
    local label=$1 logfile=$2
    shift 2
    log "$label"
    "$@" > "$OUT/$logfile" 2>&1
    local rc=$?
    if grep -q 'AXI_PC_VIOLATION' "$OUT/$logfile"; then
        rc=1
    fi
    if grep -qE '\*\* TESTS=[0-9]+ PASS=[0-9]+ FAIL=[1-9][0-9]* ' \
        "$OUT/$logfile"; then
        rc=1
    fi
    local result
    result=$(grep -E 'passed|failed|TESTS=|VIP_RESULT|generic_config_matrix' \
        "$OUT/$logfile" | tail -1)
    log "$label: rc=$rc${result:+ | $result}"
    [[ $rc -eq 0 ]] || fail=$((fail + 1))
}

run_cocotb() {
    local label=$1 logfile=$2
    shift 2
    run_logged "$label" "$logfile" "$@"
    if ! grep -qE '\*\* TESTS=' "$OUT/$logfile"; then
        log "$label: missing cocotb summary"
        fail=$((fail + 1))
    fi
}

log "random seed sweep: 500 seeds, 300 transactions each"
rm -rf sim_build
NTXN=300 SEED=1 timeout 600 make MODULE=test_random \
    > "$OUT/random_build.log" 2>&1
build_rc=$?
if [[ $build_rc -ne 0 ]]; then
    log "random seed sweep build failed"
    fail=$((fail + 1))
else
    seed_pass=0
    seed_fail=0
    seed_pc=0
    for seed in $(seq 1 500); do
        logfile="$OUT/random_seed_$seed.log"
        NTXN=300 SEED=$seed timeout 60 make MODULE=test_random > "$logfile" 2>&1
        rc=$?
        pc=$(grep -c AXI_PC_VIOLATION "$logfile" 2>/dev/null); pc=${pc:-0}
        test_fail=$(grep -oE 'FAIL=[0-9]+' "$logfile" | head -1 | grep -oE '[0-9]+')
        test_fail=${test_fail:-0}
        if [[ $rc -eq 0 && $test_fail -eq 0 && $pc -eq 0 ]]; then
            seed_pass=$((seed_pass + 1))
            rm -f "$logfile"
        else
            seed_fail=$((seed_fail + 1))
            log "seed $seed failed: rc=$rc tests=$test_fail protocol=$pc"
        fi
        seed_pc=$((seed_pc + pc))
        (( seed % 50 == 0 )) &&
            log "seed progress: $seed/500 pass=$seed_pass fail=$seed_fail protocol=$seed_pc"
    done
    log "random seed sweep: pass=$seed_pass fail=$seed_fail protocol=$seed_pc"
    [[ $seed_fail -eq 0 && $seed_pc -eq 0 ]] || fail=$((fail + 1))
fi

rm -rf sim_build
run_cocotb "long graph workload" workload.log \
    env NTXN=200000 SEED=1 timeout 7200 make MODULE=test_workload

for entry in \
    "core matrix|matrix.log|3600|test_matrix.py" \
    "WRAP matrix|wrap.log|1800|test_shim_wrap_matrix.py" \
    "ID and reorder matrix|ids.log|2400|test_id_depth_matrix.py" \
    "geometry and stress matrix|geometry.log|5400|test_geometry_matrix.py" \
    "memory-error contract|memory_errors.log|1200|test_mem_error_matrix.py"; do
    IFS='|' read -r label logfile limit testfile <<< "$entry"
    rm -rf sim_build* .pytest_cache
    run_logged "$label" "$logfile" timeout "$limit" pytest -q "$testfile"
done

run_logged "l2_top policy and associativity matrix" l2top.log \
    timeout 2400 ./l2top_matrix.sh

log "mutation suites"
for file in \
    src/l2_cache.sv src/tc_narrow_shim.sv src/tc_flush_controller.sv \
    src/l2_databank.sv src/replacement_policy.sv src/fifo.sv \
    src/toggle_memory.sv src/lutram_1w_1r.sv src/lfsr.sv src/sdp_ram.sv \
    src/l2_tagbank.sv src/LRU.sv src/SRRIP.sv src/FRQ.sv \
    src/second_chance.sv src/random_replacement.sv src/GRASP.sv \
    src/tdp_ram.sv src/victim_cache.sv; do
    logfile="mutation_${file//\//_}.log"
    FILE=$file ./mutation_test.sh > "$OUT/$logfile" 2>&1
    rc=$?
    score=$(grep -E '^  mutation score:' "$OUT/$logfile" | tail -1)
    log "$file: rc=$rc ${score:-no score}"
    if [[ $rc -ne 0 ]] || ! grep -q '100.0%' <<< "$score"; then
        fail=$((fail + 1))
    fi
done

rm -rf sim_build
run_logged "GRASP configuration matrix" grasp_matrix.log \
    env OUT="$OUT/grasp_matrix" timeout 3600 ./grasp_multi_matrix.sh

rm -rf sim_build
run_cocotb "GRASP multi-window retention" grasp_retention.log \
    env POLICY=GRASP GRASP_HIGH_REGIONS=4 timeout 600 \
    make MODULE=test_grasp_multi_perf

if command -v vivado >/dev/null 2>&1; then
    run_logged "xsim default" vip_default.log \
        env VIP_BUILD="$OUT/vip_default" timeout 1200 "$HERE/../vip/run_vip.sh"
    run_logged "xsim large GRASP cache" vip_large.log \
        env VIP_BUILD="$OUT/vip_large" VIP_LINES=512 VIP_WAYS=4 \
        VIP_LINE_W=8 VIP_POLICY=GRASP timeout 1800 "$HERE/../vip/run_vip.sh"
    run_logged "xsim base-zero range" vip_base0.log \
        env VIP_BUILD="$OUT/vip_base0" VIP_ADDR_L=0 VIP_LINES=8 \
        VIP_WAYS=4 VIP_LINE_W=8 VIP_POLICY=GRASP \
        timeout 1200 "$HERE/../vip/run_vip.sh"
    run_logged "xsim narrow ID" vip_id2.log \
        env VIP_BUILD="$OUT/vip_id2" VIP_ID_W=2 VIP_LINES=16 \
        VIP_WAYS=3 VIP_LINE_W=8 VIP_POLICY=LRU \
        timeout 1500 "$HERE/../vip/run_vip.sh"
    run_logged "xsim banked SDP" vip_sdp.log \
        env VIP_BUILD="$OUT/vip_sdp" VIP_ID_W=3 VIP_LINES=64 \
        VIP_WAYS=3 VIP_LINE_W=8 VIP_POLICY=GRASP VIP_DB_LATENCY=2 \
        VIP_DATABANK_SDP=1 VIP_SDP_WRITE_INPUT_REG=1 VIP_N_BANKS=2 \
        VIP_CASCADE_DEPTH=1 timeout 1800 "$HERE/../vip/run_vip.sh"
    run_logged "xsim combined corner" vip_combined.log \
        env VIP_BUILD="$OUT/vip_combined" VIP_ADDR_L=0 VIP_ID_W=3 \
        VIP_LINES=16 VIP_WAYS=3 VIP_LINE_W=8 VIP_POLICY=GRASP \
        VIP_VICTIM=1 VIP_DB_LATENCY=2 VIP_DATABANK_SDP=1 \
        VIP_SDP_WRITE_INPUT_REG=1 VIP_N_BANKS=2 VIP_CASCADE_DEPTH=1 \
        timeout 1800 "$HERE/../vip/run_vip.sh"
    run_logged "Vivado generic synthesis matrix" synthesis.log \
        timeout 3600 "$HERE/../../syn/vivado/generic_config_matrix.sh"
else
    log "Vivado checks skipped: executable not found"
fi

log "============================================="
if [[ $fail -eq 0 ]]; then
    log "OVERNIGHT RUN: CLEAN"
    exit 0
fi

log "OVERNIGHT RUN: $fail verification section(s) failed"
exit 1
