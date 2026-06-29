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
            # LT_to_LE_arlen excluded: equivalent mutation under
            # Verilator + cocotb. Targets a $error advisory assertion
            # (not $fatal), so the test outcome is identical whether the
            # bound is < or <=, and cocotbext-axi never drives arlen >=
            # LINE_W. Killing it requires building the cache with the
            # assertion remapped to $fatal AND a direct-driven testbench
            # bypassing cocotbext-axi -- out of scope for the standard
            # mutation set.
            "negate_arready|0,/req_arready = /{s/req_arready = /req_arready = ~/}"
            "swap_evict_priority|0,/start_evict = /{s/~evicting & ~victim_aw\\.awvalid/evicting | victim_aw.awvalid/}"
            "off_by_one_arlen|0,/victim_ar\\.arlen = 8'(LINE_W-1)/{s/8'(LINE_W-1)/8'(LINE_W)/}"
            "drop_rst_gate_bvalid|0,/req_b\\.bvalid = .*~rst/{s/ & ~rst//}"
            "drop_rst_gate_rvalid|0,/req_r\\.rvalid = .*~rst/{s/ & ~rst//}"
            "drop_rst_gate_mem_arvalid|0,/mem_ar\\.arvalid = mem_ar_int\\.arvalid & ~rst/{s/ & ~rst//}"
            "constant_zero_bvalid_invalid|0,/assign bvalid_invalid = /{s/assign bvalid_invalid = .*;/assign bvalid_invalid = 1'b0;/}"
            # swap_in_id_assignment removed: stale regex targeting an
            # assignment that no longer exists in the post-refactor RTL.
            "drop_cbom_miss_gate|0,/& ~(INCLUDE_CBOM & (tb_out_inval | tb_out_clean))) | (INCLUDE_VICTIM/{s/ & ~(INCLUDE_CBOM & (tb_out_inval | tb_out_clean))//}"
        )
        ;;
    src/tc_narrow_shim.sv)
        DEFAULT_TESTS="test_narrow_shim test_shim_cache test_shim_throughput test_shim_prefill_race"
        MUTATIONS=(
            "negate_ar_hits_buffer|0,/ar_hits_buffer = lb_valid/{s/ar_hits_buffer = lb_valid/ar_hits_buffer = ~lb_valid/}"
            "drop_buf_drain_term|0,/ar_buf_drain_this_cycle = /{s/ar_buf_drain_this_cycle = .*;/ar_buf_drain_this_cycle = 1'b0;/}"
            "swap_arvalid_or|0,/m_arvalid = prefill_ar_fire | /{s/m_arvalid = prefill_ar_fire | /m_arvalid = prefill_ar_fire \\& /}"
            "negate_s_arready|0,/s_arready = ar_buf_accept/{s/s_arready = ar_buf_accept/s_arready = ~ar_buf_accept/}"
            "drop_prefill_check|/m_arvalid = prefill_ar_fire/,/;/{s/& ~prefill_active//}"
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
    src/l2_databank.sv:sdp)
        # SDP-mode (DATABANK_SDP=1) mutation set. The standard
        # l2_databank.sv mutations above exercise the TDP path; these
        # cover the SDP-specific port-1-disable gating that lives in
        # l2_databank.sv between the FSM and the storage. Each mutation
        # breaks one part of the "port 1 must stay inert in SDP mode"
        # invariant -- functional tests deadlock or corrupt data.
        FILE=src/l2_databank.sv  # real path for sed
        EXTRA_MAKE_ARGS='+define+TC_DATABANK_SDP=1'
        DEFAULT_TESTS="test_smoke test_random test_backpressure test_workload"
        MUTATIONS=(
            # Flip polarity: en_gated[1] = en[1] & DATABANK_SDP -> port 1
            # only fires in SDP mode (always 0 in TDP). In SDP mode this
            # un-stalls port 1 at the RAM boundary while the FSM still
            # thinks port 1 is operating normally, so RAM reads/writes
            # for port 1 fire when they shouldn't. Expected: data corruption.
            "sdp_flip_en_gated_p1|s/assign en_gated\\[1\\] = en\\[1\\] \\& ~DATABANK_SDP;/assign en_gated[1] = en[1] \\& DATABANK_SDP;/"
            # Drop the ~DATABANK_SDP mask on port_ready[1] output. Upstream
            # sees ready=1 when port 1 is in READY -> sends requests ->
            # port 1's state advances to READING/WRITING -> but
            # en_gated[1] stays 0 (other mask intact) -> saved_block[1]
            # stuck -> port 1 deadlocks indefinitely. Expected: timeout.
            "sdp_drop_ready_mask|s/(port_ready\\[1\\]            & ~DATABANK_SDP)/port_ready[1]/"
            # Drop the ~DATABANK_SDP mask on write_data_ready output.
            # With ready_mask intact, port 1 can still transition to
            # WRITING state via the priority logic (en[1] in READY uses
            # request_valid which can fire if port 0 just released).
            # The dropped wdata mask then causes port 1 to advertise
            # data-acceptance while en_gated[1]=0 -> dropped beat.
            # Expected: scoreboard mismatch under workload.
            "sdp_drop_wdata_ready_mask|s/(port_write_data_ready\\[1\\] & ~DATABANK_SDP)/port_write_data_ready[1]/"
            # Replace sdp_ram_uram with tdp_ram in the SDP generate.
            # The sdp_ram_uram interface is SDP (1R+1W) so plugging in
            # tdp_ram leaves b_wbe/b_wdata floating and a_rdata unused;
            # Verilator x-propagates into the read path.
            # Expected: read data corruption.
            "sdp_swap_uram_to_tdp|s/sdp_ram_uram #(/tdp_ram #(/"

            # ---- Documented equivalent mutations (excluded from score) ----
            # sdp_drop_fill_ready_mask: equivalent under current "port 1
            # disabled" implementation. Fill requests are issued by the
            # internal miss handler in l2_cache.sv, which only routes
            # fills to port 0 in practice (priority-based, port 0 always
            # available since port 1 is gated off). port_fill_data_ready[1]
            # is computed by the FSM but stays 0 throughout, so the gate
            # mask is dead. Would become live if a future change re-
            # enables port 1 or splits fills across both ports.
            #
            # sdp_invert_rdata_route: equivalent. With port 1 disabled,
            # read_was_p1_pipe[LATENCY] is always 0, so swapping the '0
            # and sdp_rdata branches produces the same output stream.
            # Would become live if port 1 ever issued a read.
        )
        ;;
    src/l2_databank.sv:banked)
        # Banked SDP (DATABANK_SDP=1, N_BANKS=2) mutation set. Covers
        # the gen_banked_sdp generate block added by Phase 2a of the
        # banked-memory experiment. Each mutation breaks one part of
        # the per-bank routing invariant ("a request to line[0]=B must
        # hit and read exactly bank B").
        FILE=src/l2_databank.sv  # real path for sed
        EXTRA_MAKE_ARGS='+define+TC_DATABANK_SDP=1 +define+TC_N_BANKS=2'
        DEFAULT_TESTS="test_smoke test_random test_workload test_scoreboard"
        MUTATIONS=(
            # Force all requests to bank 0: bank_sel always true ->
            # writes to bank 1 hit bank 0 instead (data corruption);
            # reads to bank 1 never fire (no read enable).
            # Expected: scoreboard mismatch on any cross-bank read.
            "banked_bank_sel_to_zero|s/wire bank_sel = (p0_bank == BANK_BITS'(b));/wire bank_sel = (BANK_BITS'(b) == 0);/"
            # Invert bank selection: bank b matches when line[0]!=b.
            # Writes go to wrong bank; reads return wrong bank's data.
            # Expected: scoreboard mismatch on every miss-fill cycle.
            "banked_bank_sel_invert|s/wire bank_sel = (p0_bank == BANK_BITS'(b));/wire bank_sel = (p0_bank != BANK_BITS'(b));/"
            # Drop the bank_id pipeline stage entirely: rdata
            # demux uses p0_bank (the CURRENT cycle's bank-id)
            # instead of the LATENCY-pipelined value -> demux
            # selects the wrong bank for in-flight reads.
            # Expected: read data corruption under load.
            "banked_pipe_to_zero|s/assign unpacked_rdata\\[0\\] = bank_rdata_arr\\[bank_pipe\\[LATENCY\\]\\];/assign unpacked_rdata[0] = bank_rdata_arr[BANK_BITS'(0)];/"
            # Drop the per-bank-line address shift: instead of routing
            # only the upper line bits to each bank, all bits go through
            # -- causing N=2's per-bank ADDR_WIDTH (LINE_ADDR_W-1) to
            # under-index the bank (bank 0 collides line[0]=0 and
            # line[0]=2, etc).
            # Expected: writes to different lines clobber each other
            # within a bank -> scoreboard mismatch.
            'banked_drop_addr_shift|s|line\[0\]\[$bits(line_t)-1:BANK_BITS\]|line[0][LINE_ADDR_W-1-BANK_BITS:0]|g'
        )
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
    src/lutram_1w_1r.sv)
        # Inferred dual-port LUTRAM used by fifo.sv (DEPTH>=3) and many
        # set/toggle memory wrappers.
        DEFAULT_TESTS="test_smoke test_random test_backpressure test_finish_fifo_stress"
        MUTATIONS=(
            "swap_waddr_raddr|s/ram\[waddr\] <= new_ram_data;/ram[raddr] <= new_ram_data;/"
            "negate_dout|s/assign ram_data_out = ram\[raddr\];/assign ram_data_out = ~ram[raddr];/"
            # drop_write_enable excluded: equivalent in practice. Writing
            # the held bus value on every cycle (vs only when ram_write=1)
            # is indistinguishable when the dispatcher never changes
            # new_ram_data between accepted writes -- which is the case
            # for every fifo / toggle_memory consumer.
        )
        ;;
    src/lfsr.sv)
        # LFSR used as FIFO read/write pointers (DEPTH>=3).
        DEFAULT_TESTS="test_smoke test_random test_finish_fifo_stress"
        MUTATIONS=(
            "drop_lfsr_advance|s/value <= value << 1;/value <= value;/"
            # negate_feedback_width2 excluded: equivalent. Both feedback
            # polarities walk through all DEPTH values; for a FIFO whose
            # consumer only checks data ordering (not address mapping),
            # both sequences observably round-trip the same data.
            # drop_rst_clear excluded: regex needs sed -z (multi-line);
            # the rst init is anyway covered by toggle_memory mutations.
        )
        ;;
    src/sdp_ram.sv)
        # Simple-dual-port BRAM used by tagbank + databank ways. Signals:
        # a_en/a_wbe/a_addr/a_wdata (write), b_en/b_addr/b_rdata (read).
        DEFAULT_TESTS="test_smoke test_random test_workload"
        MUTATIONS=(
            "drop_a_en_write|s/if (a_en & a_wbe\[i\])/if (a_wbe[i])/"
            "swap_a_b_addr|s/b_ram_output <= mem\[b_addr\];/b_ram_output <= mem[a_addr];/"
        )
        ;;
    src/LRU.sv)
        # LRU has per-WAYS generate branches. Default config is WAYS=4
        # which uses gen_4's case table. test_lru_sanity stress-tests
        # eviction patterns specifically against the LRU policy.
        DEFAULT_TESTS="test_smoke test_lru_sanity test_workload"
        MUTATIONS=(
            # Flip case 0's evict (was: evict=3 miss=9). Self-evict
            # corrupts the WAYS=4 LRU state and the thrash sequence
            # in test_lru_sanity catches the divergence.
            "gen4_flip_case0_evict|s/0: begin evict = 3; miss = 9; end/0: begin evict = 0; miss = 9; end/"
            # Flip case 0's miss-state to an unrelated value.
            "gen4_flip_case0_miss|s/0: begin evict = 3; miss = 9; end/0: begin evict = 3; miss = 0; end/"
        )
        ;;
    src/l2_hash.sv)
        # Hash function. Used only to index inuse_line_table (the
        # same-line serialisation tracker in l2_cache.sv around line 520),
        # NOT for the actual cache set index — that comes directly from
        # the address's line-index field, see l2_tagbank.sv.
        #
        # Consequence: any DETERMINISTIC hash is functionally correct.
        # A broken hash can only widen the same-line collision class
        # in inuse_line_table, causing extra request serialisation (a
        # throughput effect, not a correctness one). The data scoreboard
        # never catches it. The hit-rate-distribution test we initially
        # tried (test_hash_distribution.py touching LINES distinct
        # addresses) does NOT exercise this module at all because the
        # cache's line index comes from the address, not from l2_hash.
        #
        # Mutations remain empty; that test was instead kept as a
        # general cache-coverage sanity check (it exercises the
        # tagbank's tag-mismatch path across all 64 sets).
        DEFAULT_TESTS="test_smoke test_random test_workload"
        MUTATIONS=()
        ;;
    src/SRRIP.sv)
        # Runner sets POLICY=SRRIP. test_lru_sanity runs the thrash
        # pattern that distinguishes a working replacement from broken.
        DEFAULT_TESTS="test_smoke test_lru_sanity test_workload"
        MUTATIONS=(
            # force_HP_decrement excluded: equivalent. Default
            # RRIP_HP=1 (replacement_policy.sv:48), so the FP-decrement
            # gate `if (~RRPV_HP & ...)` is dead code. No observable
            # difference between original and mutated under default
            # config.
            "swap_insertion_bit|s/updated_RRPV\[j\]\[0\] = 0;/updated_RRPV[j][0] = 1;/"
        )
        ;;
    src/FRQ.sv)
        DEFAULT_TESTS="test_smoke test_lru_sanity test_workload"
        MUTATIONS=(
            "flip_increment_trigger|s/cache_eviction | cache_original_status == cache_way_used_int;/cache_eviction & cache_original_status == cache_way_used_int;/"
        )
        ;;
    src/second_chance.sv)
        DEFAULT_TESTS="test_smoke test_lru_sanity test_workload"
        MUTATIONS=(
            "swap_hit_bit_clear|s/hit_chance\[cache_way_used_int\] = 1;/hit_chance[cache_way_used_int] = 0;/"
        )
        ;;
    src/random_replacement.sv)
        DEFAULT_TESTS="test_smoke test_lru_sanity test_workload"
        MUTATIONS=(
            "drop_rotate|s/{cache_replacement_way\[WAYS-2:0\], cache_replacement_way\[WAYS-1\]}/cache_replacement_way/"
        )
        ;;
    src/rrip_tree.sv)
        DEFAULT_TESTS="test_smoke test_lru_sanity test_workload"
        MUTATIONS=()  # stub -- expand if/when needed; small policy file
        ;;
    src/GRASP.sv)
        # Address-region-aware RRIP. All 5 mutations killed by directed
        # tests. The matrix:
        #   - victim_idx_to_zero       -> data scoreboard (test_random)
        #   - way_onehot_invert        -> $onehot0 assertion + scoreboard
        #   - swap_hit_decrement       -> test_grasp_moderate (directed
        #     moderate-region 6x hit-promotion + cold-conflict eviction;
        #     correct keeps A, mutant climbs RRPV 1->7 then loses A)
        #   - swap_hot_insert_to_max   -> test_grasp_pressure (round 1
        #     hot pool re-warm)
        #   - swap_hot_hit_to_max      -> test_grasp_pressure (cumulative
        #     age across rounds)
        # test_grasp_pressure + test_grasp_moderate live in their own
        # modules so cocotb gives a fresh sim/cache state; isolation
        # within a single MODULE is imperfect because the sdp_ram_rst
        # LFSR sweep doesn't fully clear all cache state under back-
        # to-back tests. That contamination can mask hit-promotion
        # mutations whose discriminator is cumulative RRPV state.
        DEFAULT_TESTS="test_smoke test_grasp test_grasp_pressure test_grasp_moderate test_workload test_random test_grasp_multi"
        export POLICY=GRASP
        # Build with 2 windows/class so the multi-window OR-reduction is
        # non-trivial (test_grasp_multi needs >= 2; the single-window tests
        # are unaffected -- they drive only window 0, window 1 stays disabled).
        export GRASP_HIGH_REGIONS=2
        export GRASP_MODERATE_REGIONS=2
        MUTATIONS=(
            # Functional-correctness: victim index always 0 -> every miss
            # overwrites way 0 -> data scoreboard divergence.
            "victim_idx_to_zero|s/assign cache_replacement_way_int = WAY_W'(victim_index);/assign cache_replacement_way_int = WAY_W'(0);/"
            # Multi-hot replacement way: violates the one-hot invariant
            # the tagbank assertion catches; also corrupts the way write.
            "way_onehot_invert|s/assign cache_replacement_way = WAYS'(1 << victim_index);/assign cache_replacement_way = WAYS'(~(1 << victim_index));/"
            # On a (moderate or SRRIP-FP-fallback) hit, decrement ->
            # increment: line drifts toward MAX_RRPV instead of pinning
            # at 0. Killed by test_grasp_moderate_hit_promotion (6 hits
            # to climb 1 -> 7, then a cold conflict evicts A).
            "swap_hit_decrement|s/updated_RRPV\\[j\\] -= 1'b1;/updated_RRPV[j] += 1'b1;/"
            # Hot-region insert at MAX_RRPV instead of HOT_INSERT_RRPV='0:
            # hot misses are immediate re-evict candidates. Killed by
            # test_grasp_hot_under_pressure (round 1 hot pool re-warm).
            "swap_hot_insert_to_max|s/HOT_INSERT_RRPV = '0;/HOT_INSERT_RRPV = '1;/"
            # Hot-region hit promotion to MAX_RRPV instead of '0: even
            # repeated hits don't pin the line. Killed by
            # test_grasp_hot_under_pressure (cumulative age across rounds).
            "swap_hot_hit_to_max|s/HOT_HIT_RRPV = '0;/HOT_HIT_RRPV = '1;/"
            # Multi-window OR-reduction: collapse the high OR to window 0
            # only, so high windows i>0 stop pinning their buffer. EQUIVALENT
            # at GRASP_HIGH_REGIONS=1 (a 1-bit reduce), which is why this run
            # forces 2 windows. Killed by test_grasp_multi (buffer B, pinned
            # by high window 1, is wrongly evicted).
            "break_high_or_reduce|s/assign high_reuse = |high_hit;/assign high_reuse = high_hit[0];/"
            # Same for the moderate OR-reduction. Killed by test_grasp_multi
            # (buffer B, pinned by moderate window 1, is wrongly evicted).
            "break_moderate_or_reduce|s/assign moderate_reuse = (|moderate_hit) & ~high_reuse;/assign moderate_reuse = moderate_hit[0] \& ~high_reuse;/"
            # drop_moderate_exclusion (drop the `~high_reuse;` term in
            # moderate_reuse) excluded: equivalent. The if-elseif chain
            # in the eviction path already enforces precedence
            # (`if (high_reuse) ... else if (moderate_reuse) ...`), so
            # whether moderate_reuse is logically true OR false when high
            # also matches is observable nowhere. Confirmed by 4-test
            # SURVIVED run on the initial mutation matrix.
        )
        ;;
    src/tdp_ram.sv)
        # True dual-port RAM. The bug #7 fix lives here -- a per-byte
        # NBA loop was bytewise-dropping data at wide BLOCK_W on
        # Verilator. Targets the masked-write expressions on both ports.
        DEFAULT_TESTS="test_smoke test_random test_workload test_strobe"
        MUTATIONS=(
            "negate_a_wmask|s/(mem\[a_addr\] & ~a_wmask) | (a_wdata & a_wmask)/(mem[a_addr] \& a_wmask) | (a_wdata \& ~a_wmask)/"
            "drop_b_write_gate|s/if (|b_wbe)/if (1'b1)/"
        )
        ;;
    src/sdp_ram_rst.sv)
        # SDP RAM with reset-init routine via LFSR-driven address sweep.
        # No effective mutations under default Verilator: simulator
        # init-to-zero masks the lack of explicit reset-init. Under
        # XPROP=1 these mutations would fire (uninit data propagates
        # to x), but the standard mutation run uses Verilator defaults.
        # Documented as no-op set; XPROP regression sweep already
        # exercises the un-init path (see VERIFICATION.md).
        DEFAULT_TESTS="test_smoke test_random test_reset_recovery"
        MUTATIONS=()
        ;;
    src/one_hot_to_integer.sv)
        # Bit-OR encoder. Used by replacement_policy. Exercised by
        # every cache test.
        DEFAULT_TESTS="test_smoke test_random test_lru_sanity"
        MUTATIONS=(
            "drop_or_combine|s/int_out |= one_hot\[i\] ? \$clog2(WIDTH)'(i) : 0;/int_out = one_hot[i] ? \$clog2(WIDTH)'(i) : int_out;/"
        )
        ;;
    src/l2_top.sv)
        # Pure AXI-port adapter wrapping l2_cache. Not instantiated by
        # any cocotb test (the test harnesses talk to l2_cache or its
        # dut_*.sv wrappers directly). Documented as out-of-test-scope;
        # no-op mutation set.
        DEFAULT_TESTS="test_smoke"
        MUTATIONS=()
        ;;
    src/l2_tagbank.sv)
        # Tagbank: hit detection, dirty calc, write enable.
        DEFAULT_TESTS="test_smoke test_random test_cbom test_workload"
        MUTATIONS=(
            "negate_hit|s/assign hit = |hit_one_hot_r;/assign hit = ~|hit_one_hot_r;/"
            "swap_way_select|s/assign out_way = hit ? hit_index : policy_replacement_way_int;/assign out_way = hit ? policy_replacement_way_int : hit_index;/"
            # drop_tb_wen_gate excluded: equivalent. Without the gate,
            # tb_wen fires on CBOM-miss too, writing an entry whose
            # 'valid' bit is computed from ~stage2.inval -- which for
            # CleanInvalid/MakeInvalid on a miss line writes valid=0
            # over an already-invalid entry. No observable difference.
        )
        ;;
    src/victim_cache.sv)
        # victim_cache is only built when VICTIM=1. The mutation runner
        # exports VICTIM=1 for this file so each test_smoke/test_random
        # rebuild picks up the +define+TC_VICTIM=1. test_victim has the
        # directed scenarios that kill drop_invalidate_clear and
        # swap_write_hit_check (the general suite doesn't exercise them).
        DEFAULT_TESTS="test_smoke test_random test_cbom test_victim"
        MUTATIONS=(
            "negate_hit|s/assign hit = |hit_one_hot;/assign hit = ~|hit_one_hot;/"
            "drop_invalidate_clear|/if (invalidate)/{N;s|tags_valid & ~hit_one_hot|tags_valid|;}"
            "swap_write_hit_check|s/tags\[i\] == w_addr.tag;/tags[i] != w_addr.tag;/"
            "drop_buffer_tag_uncacheable|s/& ~uncacheable_write & ~(cache_ar.arvalid/\\& ~(cache_ar.arvalid/"
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

# victim_cache.sv is only built when VICTIM=1.
if [[ "$FILE" == "src/victim_cache.sv" ]]; then
    export VICTIM=1
fi

# Per-policy modules are only "wired" when POLICY matches; otherwise
# their outputs are unused (the replacement_policy.sv top mux selects
# only the chosen policy's signals).
case "$FILE" in
    src/SRRIP.sv)              export POLICY=SRRIP ;;
    src/FRQ.sv)                export POLICY=FRQ ;;
    src/second_chance.sv)      export POLICY=SECOND_CHANCE ;;
    src/random_replacement.sv) export POLICY=RANDOM ;;
    src/rrip_tree.sv)          export POLICY=RRIP_TREE ;;
esac

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
        # test_shim_prefill_race only fires under PROMOTE_WMISS_TO_RW=1;
        # under the default 0, it is expect_fail and trivially passes.
        if [[ $mod == "test_shim_prefill_race" ]]; then
            TC_PROMOTE_WMISS=1 EXTRA_ARGS="${EXTRA_MAKE_ARGS:-}" timeout 180 make MODULE=$mod > "$LOGDIR/${label}__${mod}.log" 2>&1
        elif [[ $mod == "test_random" ]]; then
            NTXN=$NTXN SEED=1 EXTRA_ARGS="${EXTRA_MAKE_ARGS:-}" timeout 180 make MODULE=$mod > "$LOGDIR/${label}__${mod}.log" 2>&1
        else
            EXTRA_ARGS="${EXTRA_MAKE_ARGS:-}" timeout 180 make MODULE=$mod > "$LOGDIR/${label}__${mod}.log" 2>&1
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
