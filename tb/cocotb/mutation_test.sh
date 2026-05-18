#!/usr/bin/env bash
# Mutation testing for the RTL.
#
# Per-file mutation set + per-file default test list. Override either via
# env vars. Reports per-mutation KILLED / SURVIVED + total mutation score.
#
# Examples:
#   ./mutation_test.sh                              # default: src/l2_cache.sv
#   FILE=src/tc_narrow_shim.sv ./mutation_test.sh
#   FILE=src/l2_databank.sv ./mutation_test.sh
#   FILE=src/l2_cache.sv TESTS="test_smoke" ./mutation_test.sh
#
# Each mutation is "label|sed_expr" applied with `sed -i`. Sed addressing
# `0,/PATTERN/{s/.../.../}` patches only the FIRST match for a localised,
# attributable change.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
FILE=${FILE:-src/l2_cache.sv}
NTXN=${NTXN:-40}
LOGDIR=${LOGDIR:-/tmp/tc_mutation}
mkdir -p "$LOGDIR"

# ---- Per-file mutation sets ----
case "$FILE" in
    src/l2_cache.sv)
        DEFAULT_TESTS="test_smoke test_random test_reset_recovery test_backpressure test_flush"
        MUTATIONS=(
            "EQ_to_NEQ_first|0,/finish_output\\.bvalid/{s/finish_output\\.bvalid/!finish_output.bvalid/}"
            "AND_to_OR_finish|0,/bvalid_invalid & rvalid_invalid/{s/bvalid_invalid & rvalid_invalid/bvalid_invalid | rvalid_invalid/}"
            "LT_to_LE_arlen|0,/req_ar\\.arlen < LINE_W/{s/req_ar\\.arlen < LINE_W/req_ar.arlen <= LINE_W/}"
            "negate_arready|0,/req_arready = /{s/req_arready = /req_arready = ~/}"
            "swap_evict_priority|0,/start_evict = /{s/~evicting & ~victim_aw\\.awvalid/evicting | victim_aw.awvalid/}"
            "off_by_one_arlen|0,/victim_ar\\.arlen = 8'(LINE_W-1)/{s/8'(LINE_W-1)/8'(LINE_W)/}"
            "drop_rst_gate_bvalid|0,/req_b\\.bvalid = .*~rst/{s/ & ~rst//}"
            "drop_rst_gate_rvalid|0,/req_r\\.rvalid = .*~rst/{s/ & ~rst//}"
            "drop_rst_gate_mem_arvalid|0,/mem_ar\\.arvalid = mem_ar_int\\.arvalid & ~rst/{s/ & ~rst//}"
            "constant_zero_bvalid_invalid|0,/assign bvalid_invalid = /{s/assign bvalid_invalid = .*;/assign bvalid_invalid = 1'b0;/}"
            "swap_in_id_assignment|0,/in_id = chosen_arid/{s/in_id = chosen_arid/in_id = ~chosen_arid/}"
            "drop_cbom_miss_gate|0,/& ~(INCLUDE_CBOM & (tb_out_inval | tb_out_clean))) | (INCLUDE_VICTIM/{s/ & ~(INCLUDE_CBOM & (tb_out_inval | tb_out_clean))//}"
        )
        ;;
    src/tc_narrow_shim.sv)
        DEFAULT_TESTS="test_narrow_shim test_shim_cache test_shim_throughput"
        MUTATIONS=(
            "negate_ar_hits_buffer|0,/ar_hits_buffer = lb_valid/{s/ar_hits_buffer = lb_valid/ar_hits_buffer = ~lb_valid/}"
            "drop_buf_drain_term|0,/ar_buf_drain_this_cycle = /{s/ar_buf_drain_this_cycle = .*;/ar_buf_drain_this_cycle = 1'b0;/}"
            "swap_arvalid_or|0,/m_arvalid = prefill_ar_fire | /{s/m_arvalid = prefill_ar_fire | /m_arvalid = prefill_ar_fire \\& /}"
            "negate_s_arready|0,/s_arready = ar_buf_accept/{s/s_arready = ar_buf_accept/s_arready = ~ar_buf_accept/}"
            "drop_prefill_check|0,/& ~prefill_active/{s/& ~prefill_active//}"
            "swap_miss_to_hit_path|0,/ar_miss_accept = ~ar_hits_buffer/{s/~ar_hits_buffer/ar_hits_buffer/}"
            "drop_m_arready_dep|0,/ar_miss_accept = ~ar_hits_buffer  & m_arready/{s/& m_arready//}"
        )
        ;;
    src/l2_databank.sv)
        DEFAULT_TESTS="test_smoke test_random test_strobe test_workload"
        MUTATIONS=(
            "swap_state_idle|0,/READY\s*:/{s/READY\s*:/IDLE:/}"
            "negate_ready_combine|0,/assign ready = port_ready\[0\] | port_ready\[1\]/{s/port_ready\[0\] | port_ready\[1\]/port_ready[0] \& port_ready[1]/}"
            "flip_write_fifo_data|0,/assign write_fifo_data_in = current_state\[0\] != READY/{s/!= READY/== READY/}"
            "force_past_orig_keep|0,/past_original_last\[i\] <= 0; \/\/New READING/{s/<= 0; \/\/New READING/<= 1; \/\/MUT READING/}"
            "negate_out_fifo_push|0,/assign out_fifo_push\[i\] = valid_pipeline/{s/valid_pipeline\[i\]\[LATENCY\]/~valid_pipeline[i][LATENCY]/}"
        )
        ;;
    src/LRU.sv)
        # LRU.sv has a generate block per WAYS value (gen_2/gen_3/gen_4/gen_n);
        # writing per-line mutations that work across the default WAYS=4
        # without touching unsynthesised branches is brittle. The matrix
        # sweep already exercises LRU at WAYS=2,4,8; mutation testing on
        # LRU is deferred until a config-aware harness is in place.
        DEFAULT_TESTS="test_smoke test_lru_sanity"
        MUTATIONS=()
        ;;
    src/tc_flush_controller.sv)
        DEFAULT_TESTS="test_flush"
        MUTATIONS=(
            "drop_state_advance|0,/state <= state_n;/{s/state <= state_n;/state <= state;/}"
            "swap_finish_arrow|0,/FINISH\\s*:\\s*state_n = IDLE;/{s/state_n = IDLE/state_n = FINISH/}"
            "negate_arvalid_gate|0,/m_ar\\.arvalid  = (state == ISSUE)/{s/(state == ISSUE)/(state != ISSUE)/}"
            "constant_zero_rready|0,/m_rready = (state == WAIT_R)/{s/m_rready = .*;/m_rready = 1'b0;/}"
            "wrong_addr_stride|0,/m_ar\\.araddr   = ADDR_BASE/{s/<< LOG2_STRIDE/<< 0/}"
            "skip_line_idx_inc|0,/line_idx <= line_idx + 1'b1;/{s/line_idx <= line_idx + 1'b1;/line_idx <= line_idx;/}"
        )
        ;;
    src/replacement_policy.sv)
        DEFAULT_TESTS="test_smoke test_lru_sanity"
        MUTATIONS=(
            "break_init_policy|0,/INIT_POLICY = INIT_POLICY \| policy_t'/{s/INIT_POLICY = INIT_POLICY \| /INIT_POLICY = /}"
        )
        ;;
    src/fifo.sv)
        # fifo.sv has three generate branches: DEPTH==1, ==2, >=3.
        # No instance in the design uses DEPTH==1, so the gen_width_one
        # branch is unreachable dead code -- mutations on it are
        # equivalent and excluded. The DEPTH>=3 'fifo_full off-by-one'
        # is also excluded because every FIFO instance is over-provisioned
        # vs the worst-case backpressure in current tests; reproducing the
        # truly-full condition needs a custom directed test outside the
        # scope of this mutation set. fifo.sv is also covered by the
        # formal proof in tb/formal/ (k-induction PASS for DEPTH 1 and 4).
        DEFAULT_TESTS="test_smoke test_random test_backpressure test_finish_fifo_stress test_flush"
        MUTATIONS=(
            # DEPTH==2 and DEPTH>=3: swap pop/push in the count update
            "swap_count_pushpop|s/inflight_count + (LOG2_FIFO_DEPTH+1)'(fifo_pop) - (LOG2_FIFO_DEPTH+1)'(fifo_push)/inflight_count + (LOG2_FIFO_DEPTH+1)'(fifo_push) - (LOG2_FIFO_DEPTH+1)'(fifo_pop)/"
            # DEPTH>=3: lutram waddr swapped to read_index
            "depth3_swap_waddr|0,/\.waddr(write_index),/{s/\.waddr(write_index)/.waddr(read_index)/}"
            # DEPTH==2: shift_reg index inverted
            "depth2_swap_dout_index|s/shift_reg\[~inflight_count\[0\]\]/shift_reg[inflight_count[0]]/"
        )
        ;;
    src/toggle_memory.sv)
        # toggle_memory backs set_clear_memory + the cache's inuse tables.
        # Exercised by anything that uses cache_id_t / evict tables.
        DEFAULT_TESTS="test_smoke test_random test_reset_recovery test_finish_fifo_stress"
        MUTATIONS=(
            "drop_toggle_xor|s/assign new_ram_data = toggle \^ _read_data\[0\];/assign new_ram_data = _read_data[0];/"
            "force_toggle_always|s/assign new_ram_data = toggle \^ _read_data\[0\];/assign new_ram_data = ~_read_data[0];/"
            "swap_read_id_chain|s/assign _read_id\[1:NUM_READ_PORTS\] = read_id;/assign _read_id[0] = read_id[0]; assign _read_id[1:NUM_READ_PORTS] = '{default: '0};/"
        )
        ;;
    *)
        echo "ERROR: no mutation set defined for $FILE" >&2
        echo "Add an entry to the case block in $0" >&2
        exit 2
        ;;
esac

TESTS=${TESTS:-$DEFAULT_TESTS}
src="$REPO/$FILE"
[[ -f "$src" ]] || { echo "ERROR: $src not found"; exit 1; }
backup="$LOGDIR/$(basename "$FILE").orig"
cp -f "$src" "$backup"
trap 'cp -f "$backup" "$src"; echo "(restored $FILE)"' EXIT

cd "$HERE"
source .venv/bin/activate

killed=0; survived=0; broken=0
total=${#MUTATIONS[@]}
fail_list=""

echo "=== mutation testing $FILE ($total mutations, tests: $TESTS) ==="
for entry in "${MUTATIONS[@]}"; do
    label="${entry%%|*}"
    expr="${entry#*|}"

    cp -f "$backup" "$src"
    if ! sed -i "$expr" "$src" 2>"$LOGDIR/sed_$label.err"; then
        printf "  %-30s BROKEN  (sed failed)\n" "$label"
        broken=$((broken+1)); continue
    fi
    if cmp -s "$backup" "$src"; then
        printf "  %-30s NO-MATCH (mutation didn't apply)\n" "$label"
        broken=$((broken+1)); continue
    fi

    fail_seen=0
    for mod in $TESTS; do
        rm -rf sim_build sim_build_shim
        if [[ $mod == "test_random" ]]; then
            NTXN=$NTXN SEED=1 timeout 180 make MODULE=$mod > "$LOGDIR/${label}__${mod}.log" 2>&1
        else
            timeout 180 make MODULE=$mod > "$LOGDIR/${label}__${mod}.log" 2>&1
        fi
        rc=$?
        if [[ $rc -ne 0 ]] || ! grep -qE '\*\* TESTS=.*FAIL=0 ' "$LOGDIR/${label}__${mod}.log"; then
            fail_seen=1; break
        fi
    done

    if [[ $fail_seen -eq 1 ]]; then
        printf "  %-30s KILLED\n" "$label"
        killed=$((killed+1))
    else
        printf "  %-30s SURVIVED   <- coverage gap\n" "$label"
        survived=$((survived+1))
        fail_list="$fail_list $label"
    fi
done

cp -f "$backup" "$src"
trap - EXIT
rm -rf sim_build sim_build_shim

echo
echo "=== SUMMARY ($FILE) ==="
echo "  total:    $total"
echo "  killed:   $killed"
echo "  survived: $survived  (${fail_list:-none})"
echo "  broken:   $broken"
if [[ $((killed + survived)) -gt 0 ]]; then
    score=$(awk "BEGIN{printf \"%.1f\", 100*$killed/($killed+$survived)}")
    echo "  mutation score: $score%"
fi
