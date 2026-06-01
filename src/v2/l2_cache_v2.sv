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
        output logic[READ_ID_WIDTH:0] mem_arid,
        input logic mem_arready,
        input r_t mem_r,
        input logic[BLOCK_W-1:0] mem_rdata,
        input logic[READ_ID_WIDTH:0] mem_rid,
        output mem_rready,
        output aw_t mem_aw,
        output logic[WRITE_ID_WIDTH:0] mem_awid,
        input logic mem_awready,
        output w_t mem_w,
        output logic[BLOCK_W-1:0] mem_wdata,
        output logic[(BLOCK_W/8)-1:0] mem_wstrb,
        input logic mem_wready,
        input b_t mem_b,
        input logic[WRITE_ID_WIDTH:0] mem_bid,
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
        // v2 at N>1: parameter-rejected for now. Phase 2.0's deliverable
        // is the v2 module structure + passthrough; multi-bank is
        // Phase 2.1+. See experiment/v2/README.md.
        initial $fatal(1, "l2_cache_v2: N_BANKS_V2>1 multi-bank path not yet implemented (Phase 2.1). See experiment/v2/README.md.");
        // Tie outputs to safe values so elaboration doesn't crash on
        // undriven nets (Verilator x-propagates otherwise).
        assign req_arready = 1'b0;
        assign req_r       = '0;
        assign req_rdata   = '0;
        assign req_rid     = '0;
        assign req_awready = 1'b0;
        assign req_wready  = 1'b0;
        assign req_b       = '0;
        assign req_bid     = '0;
        assign mem_ar      = '0;
        assign mem_arid    = '0;
        assign mem_aw      = '0;
        assign mem_awid    = '0;
        assign mem_w       = '0;
        assign mem_wdata   = '0;
        assign mem_wstrb   = '0;
        assign mem_rready  = 1'b0;
        assign mem_bready  = 1'b0;
    end endgenerate

endmodule
