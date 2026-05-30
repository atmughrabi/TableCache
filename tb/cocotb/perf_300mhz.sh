#!/usr/bin/env bash
# Throughput comparison: 250 MHz baseline vs 300 MHz config.
#
# Runs test_workload at the URAM-deployment cache config for two knob
# combinations, captures the in-sim cycle count, then translates to
# effective throughput at the corresponding closed-timing frequency:
#
#   txn/sec = (NTXN * MHz) / cycles
#
# The interesting question: does the +1 cycle on the data-bank read
# pipeline (DB_LATENCY=3) outweigh the 50 MHz frequency gain? If so,
# the 300 MHz target is a net loss on graph workloads.
#
# Runs both LRU and GRASP because they have different miss-fill rates
# and the +1 cycle cost is felt mostly on fill cycles.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
source .venv/bin/activate 2>/dev/null

# Locked cache config: 512KB / 8w / SDP+URAM / GRASP-or-LRU; matches the
# synth+PnR sweep that produced the 312 MHz post-route result.
export LINES="${LINES:-1024}"
export LINE_W="${LINE_W:-16}"
export WAYS="${WAYS:-8}"
export DATABANK_SDP="${DATABANK_SDP:-1}"
export NTXN="${NTXN:-5000}"
export SEED="${SEED:-1}"

# (knob_combo_label, knob_combo_env, freq_mhz)
COMBOS=(
    "baseline_250mhz|DB_LATENCY=2 SDP_WRITE_INPUT_REG=0|250"
    "tuned_300mhz|DB_LATENCY=3 SDP_WRITE_INPUT_REG=1|300"
)
POLICIES=("${POLICIES:-LRU,GRASP}")
IFS=',' read -ra POLICY_LIST <<< "${POLICIES[*]}"

OUT="/tmp/tc_300mhz_perf"
mkdir -p "$OUT"
SUMMARY="$OUT/summary.md"
{
    echo "# 300 MHz vs 250 MHz throughput comparison"
    echo ""
    echo "Config: LINES=$LINES LINE_W=$LINE_W WAYS=$WAYS DATABANK_SDP=$DATABANK_SDP"
    echo "        NTXN=$NTXN SEED=$SEED"
    echo ""
    echo "| Combo | POLICY | cycles | cyc/txn | reads | writes | full_writes | MHz | txn/s |"
    echo "|---|---|---:|---:|---:|---:|---:|---:|---:|"
} > "$SUMMARY"

run_combo() {
    local label="$1" env="$2" mhz="$3" policy="$4"
    local tag="${label}_${policy}"
    local log="$OUT/$tag.log"
    rm -rf sim_build results.xml
    if eval "POLICY=$policy MODULE=test_workload $env make -s" > "$log" 2>&1; then
        :
    else
        echo "[$tag] BUILD/SIM FAIL — see $log" >&2
        return 1
    fi
    # Parse the workload-DONE line + the cocotb summary line for sim time.
    local n_rd=$(grep -m1 "^.*\[wl\] DONE" "$log" | sed -E 's/.*n_rd=([0-9]+).*/\1/')
    local n_wr=$(grep -m1 "^.*\[wl\] DONE" "$log" | sed -E 's/.*n_wr=([0-9]+).*/\1/')
    local n_full=$(grep -m1 "^.*\[wl\] DONE" "$log" | sed -E 's/.*\(full=([0-9]+)\).*/\1/')
    # Cocotb summary: "** TESTS=1 PASS=1 FAIL=0 SKIP=0   <SIM_TIME_NS> <real_s> <ratio> **"
    local sim_ns=$(grep -m1 "TESTS=1 PASS=1" "$log" | awk '{for(i=1;i<=NF;i++) if($i~/^[0-9]+\.[0-9]+$/){print $i; exit}}')
    if [[ -z "$sim_ns" || -z "$n_rd" ]]; then
        echo "[$tag] could not parse sim_ns/n_rd from $log" >&2
        return 1
    fi
    # Convert: cycles = sim_ns / CLK_PERIOD_NS (CLK_PERIOD_NS=10 by default).
    local cycles=$(awk -v t="$sim_ns" 'BEGIN{ printf "%.0f", t / 10.0 }')
    local txn_per_s=$(awk -v t="$NTXN" -v c="$cycles" -v m="$mhz" \
        'BEGIN { printf "%.0f", (t * m * 1e6) / c }')
    local cyc_per_txn=$(awk -v c="$cycles" -v t="$NTXN" \
        'BEGIN { printf "%.2f", c / t }')
    echo "| $label | $policy | $cycles | $cyc_per_txn | $n_rd | $n_wr | $n_full | $mhz | $txn_per_s |" >> "$SUMMARY"
    echo "[$tag] sim_ns=$sim_ns cycles=$cycles cyc/txn=$cyc_per_txn rd=$n_rd wr=$n_wr fwr=$n_full mhz=$mhz txn/s=$txn_per_s"
}

for combo in "${COMBOS[@]}"; do
    IFS='|' read -r label env mhz <<< "$combo"
    for policy in "${POLICY_LIST[@]}"; do
        run_combo "$label" "$env" "$mhz" "$policy"
    done
done

echo ""
echo "Summary: $SUMMARY"
cat "$SUMMARY"
