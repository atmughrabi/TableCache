// SPDX-License-Identifier: Apache-2.0
// TableCache v2.0 -- skeleton wrapper that places N_BANKS_V2 v1
// l2_cache instances in parallel with a request-router on the
// slave (req_*) side and a response-merger on the master (mem_*)
// side. AXI-compatible at both boundaries; drop-in replacement
// for l2_cache.
//
// At N_BANKS_V2=1 this is a thin passthrough (one v1 cache, the
// router/merger are identity). The N_BANKS_V2=1 no-regression
// check is the gate that the v2 architecture works at all.
//
// At N_BANKS_V2=2 the cache splits into 2 v1 caches, each owning
// half the address space (banked by line-address LSB). Concurrent
// requests on different banks serve in parallel natively (separate
// v1 instances, separate URAM/BRAM storage), no arbiter needed.
//
// What v2.0 does NOT yet do (deferred to v2.1+):
// - Native per-bank FSM (still uses v1's FSM per instance)
// - Pipelined request router for 350 MHz target
// - ID-routed strict-order merge (current merger is bank-priority)
//
// See experiment/v2/README.md for the full architecture plan.
module l2_cache_v2

    import cache_config::*;

    #(
        parameter replacement_policy_t POLICY = LRU,
        parameter int unsigned LINES = 512, //Lines per way (TOTAL across banks)
        parameter int unsigned LINE_W = 8,
        parameter logic[31:0] ADDR_RANGE_H = 32'hFFFFFFFF,
        parameter logic[31:0] ADDR_RANGE_L = 32'h80000000,
        parameter int unsigned WAYS = 4,
        parameter logic RANDOM_USE_EVICT = 1,
        parameter logic RRIP_HP = 1,
        parameter int unsigned RRPV_WIDTH = 2,
        parameter int unsigned ADDR_W = 32,
        parameter logic INCLUDE_CBOM = 1,
        parameter logic INCLUDE_VICTIM = 1,
        parameter int unsigned VICTIM_LINES = 8,
        parameter int unsigned DB_LATENCY = 1,
        parameter int unsigned BLOCK_W = 32,
        parameter int unsigned READ_ID_WIDTH = 4,
        parameter int unsigned WRITE_ID_WIDTH = 4,
        parameter logic DATABANK_SDP = 0,
        parameter logic SDP_WRITE_INPUT_REG = 0,
        parameter int unsigned CASCADE_DEPTH = 8,
        // v2-specific: number of v1-cache banks in parallel. Each
        // bank gets LINES/N_BANKS_V2 lines. N_BANKS_V2 must be a
        // power of two; LINES must be divisible by it.
        parameter int unsigned N_BANKS_V2 = 1
    )
    (
        input logic clk,
        input logic rst,

        input logic[ADDR_W-1:0] grasp_high_addr_l,
        input logic[ADDR_W-1:0] grasp_high_addr_h,
        input logic[ADDR_W-1:0] grasp_moderate_addr_l,
        input logic[ADDR_W-1:0] grasp_moderate_addr_h,

        input ar_t req_ar,
        input logic[READ_ID_WIDTH-1:0] req_arid,
        output logic req_arready,
        output r_t req_r,
        output logic[BLOCK_W-1:0] req_rdata,
        output logic[READ_ID_WIDTH-1:0] req_rid,
        input req_rready,
        input aw_t req_aw,
        input logic[WRITE_ID_WIDTH-1:0] req_awid,
        output logic req_awready,
        input w_t req_w,
        input logic[BLOCK_W-1:0] req_wdata,
        input logic[(BLOCK_W/8)-1:0] req_wstrb,
        output logic req_wready,
        output b_t req_b,
        output logic[WRITE_ID_WIDTH-1:0] req_bid,
        input logic req_bready,

        output ar_t mem_ar,
        // Mem-side IDs are widened by $clog2(N_BANKS_V2) bits to carry the
        // originating bank so the cross-bank arbiter can demux responses.
        // At N_BANKS_V2=1 this collapses to v1's width (READ_ID_WIDTH+1).
        output logic[READ_ID_WIDTH + ((N_BANKS_V2>1) ? $clog2(N_BANKS_V2) : 0):0] mem_arid,
        input logic mem_arready,
        input r_t mem_r,
        input logic[BLOCK_W-1:0] mem_rdata,
        input logic[READ_ID_WIDTH + ((N_BANKS_V2>1) ? $clog2(N_BANKS_V2) : 0):0] mem_rid,
        output logic mem_rready,
        output aw_t mem_aw,
        output logic[WRITE_ID_WIDTH + ((N_BANKS_V2>1) ? $clog2(N_BANKS_V2) : 0):0] mem_awid,
        input logic mem_awready,
        output w_t mem_w,
        output logic[BLOCK_W-1:0] mem_wdata,
        output logic[(BLOCK_W/8)-1:0] mem_wstrb,
        input logic mem_wready,
        input b_t mem_b,
        input logic[WRITE_ID_WIDTH + ((N_BANKS_V2>1) ? $clog2(N_BANKS_V2) : 0):0] mem_bid,
        output logic mem_bready
    );

    // Elaboration-time guards.
    initial begin
        assert (N_BANKS_V2 == 1 || N_BANKS_V2 == 2 || N_BANKS_V2 == 4)
        else $fatal(1, "l2_cache_v2: N_BANKS_V2=%0d unsupported (1,2,4 only in v2.0).", N_BANKS_V2);
        assert ((LINES % N_BANKS_V2) == 0)
        else $fatal(1, "l2_cache_v2: LINES=%0d not divisible by N_BANKS_V2=%0d.", LINES, N_BANKS_V2);
    end

    generate if (N_BANKS_V2 == 1) begin : gen_passthrough
        // v2 at N=1 is structurally identical to v1 -- just instantiate
        // l2_cache directly. The no-regression check.
        l2_cache #(
            .POLICY              (POLICY),
            .LINES               (LINES),
            .LINE_W              (LINE_W),
            .ADDR_RANGE_H        (ADDR_RANGE_H),
            .ADDR_RANGE_L        (ADDR_RANGE_L),
            .WAYS                (WAYS),
            .RANDOM_USE_EVICT    (RANDOM_USE_EVICT),
            .RRIP_HP             (RRIP_HP),
            .RRPV_WIDTH          (RRPV_WIDTH),
            .ADDR_W              (ADDR_W),
            .INCLUDE_CBOM        (INCLUDE_CBOM),
            .INCLUDE_VICTIM      (INCLUDE_VICTIM),
            .VICTIM_LINES        (VICTIM_LINES),
            .DB_LATENCY          (DB_LATENCY),
            .BLOCK_W             (BLOCK_W),
            .READ_ID_WIDTH       (READ_ID_WIDTH),
            .WRITE_ID_WIDTH      (WRITE_ID_WIDTH),
            .DATABANK_SDP        (DATABANK_SDP),
            .SDP_WRITE_INPUT_REG (SDP_WRITE_INPUT_REG),
            .CASCADE_DEPTH       (CASCADE_DEPTH),
            .N_BANKS             (1)
        ) v1_inst (.*);
    end else begin : gen_multibank
        // ---------------------------------------------------------------
        // v2.1: native multi-bank dispatcher
        // ---------------------------------------------------------------
        // Architecture:
        //   * Address-bit router demuxes AR/AW/W to N_BANKS_V2 v1
        //     l2_cache instances. Bank-select bit = address[LINE_BYTES_W
        //     +: BANK_BITS] so consecutive cache lines alternate banks
        //     (good load balance for sequential workloads).
        //   * AXI per-ID ordering preserved by at-most-1-outstanding-AR
        //     and at-most-1-outstanding-AW per ID. Trivial state (one
        //     flip-flop per ID). Cost: same-ID back-to-back stalls
        //     until the previous response completes; OK because real
        //     AXI masters typically spread across IDs.
        //   * W beats follow AW order via a small "next-W-bank" FIFO.
        //   * Cross-bank R/B merger uses fixed-priority (bank 0 wins
        //     on tie). Per-ID ordering is already guaranteed by the
        //     1-outstanding rule so any fair scheme works.
        //   * Mem-side AR/AW/W arbiter is round-robin; mem responses
        //     demuxed by the bank-tag bits prepended to mem_arid/mem_awid.
        //
        // What this DOES NOT do (deferred to v2.2+):
        //   * Pipelined router (current router is purely combinational
        //     on the req-side; fine at 250-300 MHz, the 350 MHz target
        //     needs a 1-cycle skid).
        //   * Bursts crossing bank boundaries (the address-bit hash is
        //     line-aligned, so cache-line-sized bursts never cross --
        //     same-line beats stay in one bank by construction).
        //
        localparam int unsigned BANK_BITS     = $clog2(N_BANKS_V2);
        localparam int unsigned LINE_BYTES_W  = $clog2(LINE_W * (BLOCK_W/8));
        localparam int unsigned LINES_PER_BANK = LINES / N_BANKS_V2;
        localparam int unsigned NUM_R_IDS     = 1 << READ_ID_WIDTH;
        localparam int unsigned NUM_W_IDS     = 1 << WRITE_ID_WIDTH;
        localparam int unsigned W_FIFO_DEPTH  = NUM_W_IDS; // worst-case outstanding AWs
        localparam int unsigned W_FIFO_AW     = $clog2(W_FIFO_DEPTH + 1);

        // ----- per-bank cache <-> wrapper wires -----
        ar_t  b_req_ar    [N_BANKS_V2];
        logic [READ_ID_WIDTH-1:0]   b_req_arid    [N_BANKS_V2];
        logic                       b_req_arready [N_BANKS_V2];
        r_t   b_req_r     [N_BANKS_V2];
        logic [BLOCK_W-1:0]         b_req_rdata   [N_BANKS_V2];
        logic [READ_ID_WIDTH-1:0]   b_req_rid     [N_BANKS_V2];
        logic                       b_req_rready  [N_BANKS_V2];
        aw_t  b_req_aw    [N_BANKS_V2];
        logic [WRITE_ID_WIDTH-1:0]  b_req_awid    [N_BANKS_V2];
        logic                       b_req_awready [N_BANKS_V2];
        w_t   b_req_w     [N_BANKS_V2];
        logic [BLOCK_W-1:0]         b_req_wdata   [N_BANKS_V2];
        logic [(BLOCK_W/8)-1:0]     b_req_wstrb   [N_BANKS_V2];
        logic                       b_req_wready  [N_BANKS_V2];
        b_t   b_req_b     [N_BANKS_V2];
        logic [WRITE_ID_WIDTH-1:0]  b_req_bid     [N_BANKS_V2];
        logic                       b_req_bready  [N_BANKS_V2];

        ar_t  b_mem_ar    [N_BANKS_V2];
        logic [READ_ID_WIDTH:0]     b_mem_arid    [N_BANKS_V2];
        logic                       b_mem_arready [N_BANKS_V2];
        r_t   b_mem_r     [N_BANKS_V2];
        logic [BLOCK_W-1:0]         b_mem_rdata   [N_BANKS_V2];
        logic [READ_ID_WIDTH:0]     b_mem_rid     [N_BANKS_V2];
        logic                       b_mem_rready  [N_BANKS_V2];
        aw_t  b_mem_aw    [N_BANKS_V2];
        logic [WRITE_ID_WIDTH:0]    b_mem_awid    [N_BANKS_V2];
        logic                       b_mem_awready [N_BANKS_V2];
        w_t   b_mem_w     [N_BANKS_V2];
        logic [BLOCK_W-1:0]         b_mem_wdata   [N_BANKS_V2];
        logic [(BLOCK_W/8)-1:0]     b_mem_wstrb   [N_BANKS_V2];
        logic                       b_mem_wready  [N_BANKS_V2];
        b_t   b_mem_b     [N_BANKS_V2];
        logic [WRITE_ID_WIDTH:0]    b_mem_bid     [N_BANKS_V2];
        logic                       b_mem_bready  [N_BANKS_V2];

        // -----------------------------------------------------------
        // Per-bank l2_cache instances (each owns LINES/N_BANKS_V2 lines)
        // -----------------------------------------------------------
        // Note on KEEP_HIERARCHY: we tried (* keep_hierarchy = "yes" *)
        // on bank_inst in v2.2a to force Vivado to keep each bank a
        // contiguous placement cluster. Measured outcome on U55C 1MB
        // N=2 @ 300 MHz: WNS -1.224 ns (v2.1 was -0.523 ns), i.e.
        // -0.7 ns regression. The cross-bank "fusion" path visible in
        // v2.1 timing reports is Vivado's optimizer co-optimizing
        // shared LFSR / URAM control logic across banks -- forbidding
        // it forces longer per-bank routes. Decision: NO keep_hierarchy.
        // See experiment/v2/README.md "v2.2a result" section.
        for (genvar B = 0; B < N_BANKS_V2; B++) begin : gen_bank
            l2_cache #(
                .POLICY              (POLICY),
                .LINES               (LINES_PER_BANK),
                .LINE_W              (LINE_W),
                .ADDR_RANGE_H        (ADDR_RANGE_H),
                .ADDR_RANGE_L        (ADDR_RANGE_L),
                .WAYS                (WAYS),
                .RANDOM_USE_EVICT    (RANDOM_USE_EVICT),
                .RRIP_HP             (RRIP_HP),
                .RRPV_WIDTH          (RRPV_WIDTH),
                .ADDR_W              (ADDR_W),
                .INCLUDE_CBOM        (INCLUDE_CBOM),
                .INCLUDE_VICTIM      (INCLUDE_VICTIM),
                .VICTIM_LINES        (VICTIM_LINES),
                .DB_LATENCY          (DB_LATENCY),
                .BLOCK_W             (BLOCK_W),
                .READ_ID_WIDTH       (READ_ID_WIDTH),
                .WRITE_ID_WIDTH      (WRITE_ID_WIDTH),
                .DATABANK_SDP        (DATABANK_SDP),
                .SDP_WRITE_INPUT_REG (SDP_WRITE_INPUT_REG),
                .CASCADE_DEPTH       (CASCADE_DEPTH),
                .N_BANKS             (1)
            ) bank_inst (
                .clk(clk), .rst(rst),
                .grasp_high_addr_l(grasp_high_addr_l),
                .grasp_high_addr_h(grasp_high_addr_h),
                .grasp_moderate_addr_l(grasp_moderate_addr_l),
                .grasp_moderate_addr_h(grasp_moderate_addr_h),
                .req_ar(b_req_ar[B]), .req_arid(b_req_arid[B]), .req_arready(b_req_arready[B]),
                .req_r(b_req_r[B]),   .req_rdata(b_req_rdata[B]), .req_rid(b_req_rid[B]), .req_rready(b_req_rready[B]),
                .req_aw(b_req_aw[B]), .req_awid(b_req_awid[B]), .req_awready(b_req_awready[B]),
                .req_w(b_req_w[B]),   .req_wdata(b_req_wdata[B]), .req_wstrb(b_req_wstrb[B]), .req_wready(b_req_wready[B]),
                .req_b(b_req_b[B]),   .req_bid(b_req_bid[B]), .req_bready(b_req_bready[B]),
                .mem_ar(b_mem_ar[B]), .mem_arid(b_mem_arid[B]), .mem_arready(b_mem_arready[B]),
                .mem_r(b_mem_r[B]),   .mem_rdata(b_mem_rdata[B]), .mem_rid(b_mem_rid[B]), .mem_rready(b_mem_rready[B]),
                .mem_aw(b_mem_aw[B]), .mem_awid(b_mem_awid[B]), .mem_awready(b_mem_awready[B]),
                .mem_w(b_mem_w[B]),   .mem_wdata(b_mem_wdata[B]), .mem_wstrb(b_mem_wstrb[B]), .mem_wready(b_mem_wready[B]),
                .mem_b(b_mem_b[B]),   .mem_bid(b_mem_bid[B]), .mem_bready(b_mem_bready[B])
            );
        end

        // -----------------------------------------------------------
        // Slave-side router: AR / AW / W demux + per-ID inflight track
        // -----------------------------------------------------------
        logic [NUM_R_IDS-1:0] ar_inflight;
        logic [NUM_W_IDS-1:0] aw_inflight;

        logic [BANK_BITS-1:0] ar_bank_sel;
        logic [BANK_BITS-1:0] aw_bank_sel;
        assign ar_bank_sel = req_ar.araddr[LINE_BYTES_W +: BANK_BITS];
        assign aw_bank_sel = req_aw.awaddr[LINE_BYTES_W +: BANK_BITS];

        logic ar_can_dispatch;
        logic aw_can_dispatch;
        assign ar_can_dispatch = !ar_inflight[req_arid];
        assign aw_can_dispatch = !aw_inflight[req_awid];

        // AR demux + arready feedback
        always_comb begin
            req_arready = ar_can_dispatch & b_req_arready[ar_bank_sel] & req_ar.arvalid;
            for (int b = 0; b < N_BANKS_V2; b++) begin
                b_req_ar[b]   = req_ar;
                b_req_ar[b].arvalid = req_ar.arvalid & ar_can_dispatch & ({{(32-BANK_BITS){1'b0}}, ar_bank_sel} == b);
                b_req_arid[b] = req_arid;
            end
        end

        // AW demux + awready feedback
        always_comb begin
            req_awready = aw_can_dispatch & b_req_awready[aw_bank_sel] & req_aw.awvalid;
            for (int b = 0; b < N_BANKS_V2; b++) begin
                b_req_aw[b]   = req_aw;
                b_req_aw[b].awvalid = req_aw.awvalid & aw_can_dispatch & ({{(32-BANK_BITS){1'b0}}, aw_bank_sel} == b);
                b_req_awid[b] = req_awid;
            end
        end

        // W routing: AXI4 requires W beats follow AW issue order, so a small
        // FIFO tracks "the bank that will receive the next W burst". Push
        // when an AW handshake fires; pop when W.wlast handshakes.
        logic [BANK_BITS-1:0] w_fifo [W_FIFO_DEPTH];
        logic [W_FIFO_AW-1:0] w_fifo_head, w_fifo_tail, w_fifo_count;
        logic w_fifo_push, w_fifo_pop;
        logic [BANK_BITS-1:0] w_dest_bank;
        logic w_can_route;

        assign w_can_route = (w_fifo_count != '0);
        assign w_dest_bank = w_fifo[w_fifo_head[W_FIFO_AW-2:0]]; // wraparound safe at depth=NUM_W_IDS power-of-2
        assign w_fifo_push = req_aw.awvalid & req_awready;
        assign w_fifo_pop  = req_w.wvalid  & req_wready & req_w.wlast;

        always_ff @(posedge clk) begin
            if (rst) begin
                w_fifo_head  <= '0;
                w_fifo_tail  <= '0;
                w_fifo_count <= '0;
            end else begin
                if (w_fifo_push) begin
                    w_fifo[w_fifo_tail[W_FIFO_AW-2:0]] <= aw_bank_sel;
                    w_fifo_tail <= w_fifo_tail + 1'b1;
                end
                if (w_fifo_pop) begin
                    w_fifo_head <= w_fifo_head + 1'b1;
                end
                w_fifo_count <= w_fifo_count + (w_fifo_push ? 1'b1 : 1'b0) - (w_fifo_pop ? 1'b1 : 1'b0);
            end
        end

        // W demux from FIFO head
        always_comb begin
            req_wready = w_can_route & b_req_wready[w_dest_bank];
            for (int b = 0; b < N_BANKS_V2; b++) begin
                b_req_w[b]   = req_w;
                b_req_w[b].wvalid = req_w.wvalid & w_can_route & ({{(32-BANK_BITS){1'b0}}, w_dest_bank} == b);
                b_req_wdata[b] = req_wdata;
                b_req_wstrb[b] = req_wstrb;
            end
        end

        // -----------------------------------------------------------
        // Slave-side merger: R / B locked priority arb
        // -----------------------------------------------------------
        // Per-ID 1-outstanding rule guarantees no per-ID reordering hazard,
        // so fixed-priority (low bank wins) is correct + simple. But the
        // picker MUST lock its choice once a transfer is in-flight,
        // otherwise a later-asserting lower-index bank would re-steer the
        // bus mid-cycle, violating AXI's "data stable while valid" rule
        // (caught by test_backpressure's AXI_PC monitor).
        logic r_pick_raw_valid;
        logic [BANK_BITS-1:0] r_pick_raw;
        always_comb begin
            r_pick_raw_valid = 1'b0;
            r_pick_raw       = '0;
            for (int b = 0; b < N_BANKS_V2; b++) begin
                if (!r_pick_raw_valid && b_req_r[b].rvalid) begin
                    r_pick_raw_valid = 1'b1;
                    r_pick_raw       = b[BANK_BITS-1:0];
                end
            end
        end
        logic r_locked;
        logic [BANK_BITS-1:0] r_locked_idx;
        always_ff @(posedge clk) begin
            if (rst) begin
                r_locked     <= 1'b0;
                r_locked_idx <= '0;
            end else begin
                if (r_locked) begin
                    if (req_r.rvalid && req_rready && req_r.rlast)
                        r_locked <= 1'b0;
                end else if (r_pick_raw_valid &&
                             !(req_r.rvalid && req_rready && req_r.rlast)) begin
                    // Skip the latch if the very first cycle of arvalid
                    // also completes a single-beat burst (handshake+rlast).
                    // Otherwise the lock would survive the burst.
                    r_locked     <= 1'b1;
                    r_locked_idx <= r_pick_raw;
                end
            end
        end
        logic [BANK_BITS-1:0] r_pick;
        logic r_pick_valid;
        assign r_pick       = r_locked ? r_locked_idx : r_pick_raw;
        assign r_pick_valid = r_locked || r_pick_raw_valid;
        always_comb begin
            req_r       = b_req_r[r_pick];
            req_rdata   = b_req_rdata[r_pick];
            req_rid     = b_req_rid[r_pick];
            req_r.rvalid = r_pick_valid & b_req_r[r_pick].rvalid;
            for (int b = 0; b < N_BANKS_V2; b++) begin
                b_req_rready[b] = ({{(32-BANK_BITS){1'b0}}, r_pick} == b) & req_rready & r_pick_valid;
            end
        end

        logic b_pick_raw_valid;
        logic [BANK_BITS-1:0] b_pick_raw;
        always_comb begin
            b_pick_raw_valid = 1'b0;
            b_pick_raw       = '0;
            for (int b = 0; b < N_BANKS_V2; b++) begin
                if (!b_pick_raw_valid && b_req_b[b].bvalid) begin
                    b_pick_raw_valid = 1'b1;
                    b_pick_raw       = b[BANK_BITS-1:0];
                end
            end
        end
        // B is single-beat: lock at picker, release at handshake.
        logic b_locked;
        logic [BANK_BITS-1:0] b_locked_idx;
        always_ff @(posedge clk) begin
            if (rst) begin
                b_locked     <= 1'b0;
                b_locked_idx <= '0;
            end else begin
                if (b_locked) begin
                    if (req_b.bvalid && req_bready)
                        b_locked <= 1'b0;
                end else if (b_pick_raw_valid &&
                             !(req_b.bvalid && req_bready)) begin
                    b_locked     <= 1'b1;
                    b_locked_idx <= b_pick_raw;
                end
            end
        end
        logic [BANK_BITS-1:0] b_pick;
        logic b_pick_valid;
        assign b_pick       = b_locked ? b_locked_idx : b_pick_raw;
        assign b_pick_valid = b_locked || b_pick_raw_valid;
        always_comb begin
            req_b       = b_req_b[b_pick];
            req_bid     = b_req_bid[b_pick];
            req_b.bvalid = b_pick_valid & b_req_b[b_pick].bvalid;
            for (int b = 0; b < N_BANKS_V2; b++) begin
                b_req_bready[b] = ({{(32-BANK_BITS){1'b0}}, b_pick} == b) & req_bready & b_pick_valid;
            end
        end

        // -----------------------------------------------------------
        // Per-ID inflight tracking (update on handshakes seen above)
        // -----------------------------------------------------------
        always_ff @(posedge clk) begin
            if (rst) begin
                ar_inflight <= '0;
                aw_inflight <= '0;
            end else begin
                if (req_ar.arvalid & req_arready)
                    ar_inflight[req_arid] <= 1'b1;
                if (req_r.rvalid & req_rready & req_r.rlast)
                    ar_inflight[req_rid] <= 1'b0;
                if (req_aw.awvalid & req_awready)
                    aw_inflight[req_awid] <= 1'b1;
                if (req_b.bvalid & req_bready)
                    aw_inflight[req_bid] <= 1'b0;
            end
        end

        // -----------------------------------------------------------
        // Mem-side arbiter: AR / AW / W round-robin, R / B demux by
        // bank-tag in the upper BANK_BITS of mem_*id
        // -----------------------------------------------------------
        // The mem-side ID is widened: mem_arid = {bank_id, bank's_mem_arid}.
        // When a mem response comes back, the top BANK_BITS select which
        // bank receives it.

        // AR arbiter: pick lowest bank with mem_ar.arvalid; LOCK the
        // pick until handshake completes (otherwise a late-asserting
        // lower-index bank would re-steer ARADDR mid-hold).
        logic mar_raw_valid;
        logic [BANK_BITS-1:0] mar_raw;
        always_comb begin
            mar_raw_valid = 1'b0;
            mar_raw       = '0;
            for (int b = 0; b < N_BANKS_V2; b++) begin
                if (!mar_raw_valid && b_mem_ar[b].arvalid) begin
                    mar_raw_valid = 1'b1;
                    mar_raw       = b[BANK_BITS-1:0];
                end
            end
        end
        logic mar_locked;
        logic [BANK_BITS-1:0] mar_locked_idx;
        always_ff @(posedge clk) begin
            if (rst) begin
                mar_locked     <= 1'b0;
                mar_locked_idx <= '0;
            end else begin
                if (mar_locked) begin
                    if (mem_ar.arvalid && mem_arready)
                        mar_locked <= 1'b0;
                end else if (mar_raw_valid &&
                             !(mem_ar.arvalid && mem_arready)) begin
                    mar_locked     <= 1'b1;
                    mar_locked_idx <= mar_raw;
                end
            end
        end
        logic [BANK_BITS-1:0] mar_pick;
        logic mar_pick_valid;
        assign mar_pick       = mar_locked ? mar_locked_idx : mar_raw;
        assign mar_pick_valid = mar_locked || mar_raw_valid;
        always_comb begin
            mem_ar       = b_mem_ar[mar_pick];
            mem_ar.arvalid = mar_pick_valid & b_mem_ar[mar_pick].arvalid;
            mem_arid     = {mar_pick, b_mem_arid[mar_pick]};
            for (int b = 0; b < N_BANKS_V2; b++) begin
                b_mem_arready[b] = ({{(32-BANK_BITS){1'b0}}, mar_pick} == b) & mem_arready & mar_pick_valid;
            end
        end

        // AW arbiter (same lock pattern)
        logic maw_raw_valid;
        logic [BANK_BITS-1:0] maw_raw;
        always_comb begin
            maw_raw_valid = 1'b0;
            maw_raw       = '0;
            for (int b = 0; b < N_BANKS_V2; b++) begin
                if (!maw_raw_valid && b_mem_aw[b].awvalid) begin
                    maw_raw_valid = 1'b1;
                    maw_raw       = b[BANK_BITS-1:0];
                end
            end
        end
        logic maw_locked;
        logic [BANK_BITS-1:0] maw_locked_idx;
        always_ff @(posedge clk) begin
            if (rst) begin
                maw_locked     <= 1'b0;
                maw_locked_idx <= '0;
            end else begin
                if (maw_locked) begin
                    if (mem_aw.awvalid && mem_awready)
                        maw_locked <= 1'b0;
                end else if (maw_raw_valid &&
                             !(mem_aw.awvalid && mem_awready)) begin
                    maw_locked     <= 1'b1;
                    maw_locked_idx <= maw_raw;
                end
            end
        end
        logic [BANK_BITS-1:0] maw_pick;
        logic maw_pick_valid;
        assign maw_pick       = maw_locked ? maw_locked_idx : maw_raw;
        assign maw_pick_valid = maw_locked || maw_raw_valid;
        always_comb begin
            mem_aw       = b_mem_aw[maw_pick];
            mem_aw.awvalid = maw_pick_valid & b_mem_aw[maw_pick].awvalid;
            mem_awid     = {maw_pick, b_mem_awid[maw_pick]};
            for (int b = 0; b < N_BANKS_V2; b++) begin
                b_mem_awready[b] = ({{(32-BANK_BITS){1'b0}}, maw_pick} == b) & mem_awready & maw_pick_valid;
            end
        end

        // Mem-side W tracking FIFO (mirrors slave-side W FIFO)
        logic [BANK_BITS-1:0] mw_fifo [W_FIFO_DEPTH];
        logic [W_FIFO_AW-1:0] mw_fifo_head, mw_fifo_tail, mw_fifo_count;
        logic mw_fifo_push, mw_fifo_pop;
        logic [BANK_BITS-1:0] mw_dest_bank;
        logic mw_can_route;
        assign mw_can_route = (mw_fifo_count != '0);
        assign mw_dest_bank = mw_fifo[mw_fifo_head[W_FIFO_AW-2:0]];
        assign mw_fifo_push = mem_aw.awvalid & mem_awready;
        assign mw_fifo_pop  = mem_w.wvalid  & mem_wready & mem_w.wlast;
        always_ff @(posedge clk) begin
            if (rst) begin
                mw_fifo_head  <= '0;
                mw_fifo_tail  <= '0;
                mw_fifo_count <= '0;
            end else begin
                if (mw_fifo_push) begin
                    mw_fifo[mw_fifo_tail[W_FIFO_AW-2:0]] <= maw_pick;
                    mw_fifo_tail <= mw_fifo_tail + 1'b1;
                end
                if (mw_fifo_pop) begin
                    mw_fifo_head <= mw_fifo_head + 1'b1;
                end
                mw_fifo_count <= mw_fifo_count + (mw_fifo_push ? 1'b1 : 1'b0) - (mw_fifo_pop ? 1'b1 : 1'b0);
            end
        end
        always_comb begin
            mem_w       = b_mem_w[mw_dest_bank];
            mem_w.wvalid = b_mem_w[mw_dest_bank].wvalid & mw_can_route;
            mem_wdata   = b_mem_wdata[mw_dest_bank];
            mem_wstrb   = b_mem_wstrb[mw_dest_bank];
            for (int b = 0; b < N_BANKS_V2; b++) begin
                b_mem_wready[b] = mw_can_route & ({{(32-BANK_BITS){1'b0}}, mw_dest_bank} == b) & mem_wready;
            end
        end

        // Mem-side R demux: top BANK_BITS of mem_rid select the bank
        logic [BANK_BITS-1:0] mr_dest;
        assign mr_dest = mem_rid[READ_ID_WIDTH + BANK_BITS : READ_ID_WIDTH + 1];
        always_comb begin
            for (int b = 0; b < N_BANKS_V2; b++) begin
                b_mem_r[b]      = mem_r;
                b_mem_r[b].rvalid = mem_r.rvalid & ({{(32-BANK_BITS){1'b0}}, mr_dest} == b);
                b_mem_rdata[b]  = mem_rdata;
                b_mem_rid[b]    = mem_rid[READ_ID_WIDTH:0];
            end
            mem_rready = b_mem_rready[mr_dest];
        end

        // Mem-side B demux: top BANK_BITS of mem_bid select the bank
        logic [BANK_BITS-1:0] mb_dest;
        assign mb_dest = mem_bid[WRITE_ID_WIDTH + BANK_BITS : WRITE_ID_WIDTH + 1];
        always_comb begin
            for (int b = 0; b < N_BANKS_V2; b++) begin
                b_mem_b[b]      = mem_b;
                b_mem_b[b].bvalid = mem_b.bvalid & ({{(32-BANK_BITS){1'b0}}, mb_dest} == b);
                b_mem_bid[b]    = mem_bid[WRITE_ID_WIDTH:0];
            end
            mem_bready = b_mem_bready[mb_dest];
        end

    end endgenerate

endmodule
