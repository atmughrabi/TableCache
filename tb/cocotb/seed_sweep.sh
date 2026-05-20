#!/usr/bin/env bash
# Seed sweep on a randomized cocotb test.
#
# Usage:
#   ./seed_sweep.sh                          # defaults: test_random, seeds 1..32, NTXN=200
#   MODULE=test_workload ./seed_sweep.sh     # different test
#   N=128 NTXN=500 ./seed_sweep.sh           # 128 seeds, 500 txns each
#
# Fails any seed that returns non-zero, reports PC violations or shows FAIL>0.
# Output: one line per seed, plus a summary.
set -u
cd "$(dirname "$0")"
source .venv/bin/activate

MODULE=${MODULE:-test_random}
N=${N:-32}
NTXN=${NTXN:-200}
LOGDIR=${LOGDIR:-/tmp/tc_seedsweep_$MODULE}
mkdir -p "$LOGDIR"

fail_seeds=()
pc_seeds=()
ok_seeds=()

for seed in $(seq 1 "$N"); do
    rm -rf sim_build coverage.dat
    NTXN=$NTXN SEED=$seed timeout 600 make MODULE="$MODULE" > "$LOGDIR/seed_$seed.log" 2>&1
    rc=$?
    pc=$(grep -c AXI_PC_VIOLATION "$LOGDIR/seed_$seed.log" 2>/dev/null)
    pc=${pc:-0}
    summary=$(grep -E '\*\* TESTS=' "$LOGDIR/seed_$seed.log" | tail -1)
    fail_n=$(echo "$summary" | grep -oE 'FAIL=[0-9]+' | grep -oE '[0-9]+')
    fail_n=${fail_n:-0}

    if [[ "$rc" -ne 0 || "$fail_n" -ne 0 ]]; then
        fail_seeds+=("$seed")
        printf "  seed=%4d rc=%d  PC=%-3s  FAIL=%s    !!! FAIL !!!\n" "$seed" "$rc" "$pc" "$fail_n"
    elif [[ "$pc" -ne 0 ]]; then
        pc_seeds+=("$seed")
        printf "  seed=%4d rc=%d  PC=%-3s  FAIL=%s    !! PC violation !!\n" "$seed" "$rc" "$pc" "$fail_n"
    else
        ok_seeds+=("$seed")
        printf "  seed=%4d rc=%d  PC=%-3s  FAIL=%s\n" "$seed" "$rc" "$pc" "$fail_n"
    fi
done

echo
echo "=== SUMMARY ($MODULE, $N seeds, NTXN=$NTXN) ==="
echo "  OK:           ${#ok_seeds[@]}"
echo "  PC-violation: ${#pc_seeds[@]} (seeds: ${pc_seeds[*]:-none})"
echo "  Functional:   ${#fail_seeds[@]} (seeds: ${fail_seeds[*]:-none})"
[[ ${#fail_seeds[@]} -gt 0 || ${#pc_seeds[@]} -gt 0 ]] && exit 1
exit 0
