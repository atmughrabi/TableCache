// SPDX-License-Identifier: Apache-2.0
// Test wrapper: accelerator-side AXI master <- 2:1 priority mux ->
//   { tc_flush_controller, accelerator } -> l2_cache slave port.
//
// While flush_active=1 the flush controller owns the cache's slave port;
// otherwise the accelerator passes through. R responses are demuxed by
// rid (FLUSH_ID = '1 goes to controller, all others to accelerator).
`timescale 1ns/1ps

module dut_flush
    import cache_config::*;
    #(
`ifdef TC_POLICY
        parameter replacement_policy_t POLICY = `TC_POLICY,
`else
        parameter replacement_policy_t POLICY = LRU,
`endif
`ifdef TC_LINES
        parameter int LINES     = `TC_LINES,
`else
        parameter int LINES     = 64,
`endif
`ifdef TC_LINE_W
        parameter int LINE_W    = `TC_LINE_W,
`else
        parameter int LINE_W    = 8,
`endif
`ifdef TC_WAYS
        parameter int WAYS      = `TC_WAYS,
`else
        parameter int WAYS      = 4,
`endif
`ifdef TC_BLOCK_W
        parameter int BLOCK_W   = `TC_BLOCK_W,
`else
        parameter int BLOCK_W   = 32,
`endif
        parameter int READ_ID_WIDTH  = 4,
        parameter int WRITE_ID_WIDTH = 4,
`ifdef TC_ADDR_W
        parameter int ADDR_W = `TC_ADDR_W,
`else
        parameter int ADDR_W = 32,
`endif
`ifdef TC_DB_LATENCY
        parameter int DB_LATENCY     = `TC_DB_LATENCY,
`else
        parameter int DB_LATENCY     = 1,
`endif
`ifdef TC_CBOM
        parameter logic INCLUDE_CBOM   = `TC_CBOM,
`else
        parameter logic INCLUDE_CBOM   = 1,
`endif
`ifdef TC_VICTIM
        parameter logic INCLUDE_VICTIM = `TC_VICTIM,
`else
        parameter logic INCLUDE_VICTIM = 0,
`endif
        parameter int VICTIM_LINES = 8,
`ifdef TC_ADDR_L
        parameter logic [ADDR_W-1:0] ADDR_RANGE_L = `TC_ADDR_L,
`else
        parameter logic [ADDR_W-1:0] ADDR_RANGE_L = ADDR_W'(64'h8000_0000),
`endif
`ifdef TC_ADDR_H
        parameter logic [ADDR_W-1:0] ADDR_RANGE_H = `TC_ADDR_H
`else
        parameter logic [ADDR_W-1:0] ADDR_RANGE_H = ADDR_W'(64'hFFFF_FFFF)
`endif
    ) (
        input  logic clk,
        input  logic rst,

        // ---- flush control ----
        input  logic       flush_req,
        input  logic[3:0]  flush_mode,
        output logic       flush_active,
        output logic       flush_done,

        // ---- accelerator-side AXI4/ACE slave (flat for cocotb) ----
        input  logic [ADDR_W-1:0]           s_araddr,
        input  logic [7:0]                  s_arlen,
        input  logic [2:0]                  s_arsize,
        input  logic [1:0]                  s_arburst,
        input  logic                        s_arlock,
        input  logic [3:0]                  s_arcache,
        input  logic [2:0]                  s_arprot,
        input  logic [3:0]                  s_arqos,
        input  logic [3:0]                  s_arregion,
        input  logic [3:0]                  s_arsnoop,
        input  logic                        s_arvalid,
        output logic                        s_arready,
        input  logic [READ_ID_WIDTH-1:0]    s_arid,

        output logic                        s_rvalid,
        output logic                        s_rlast,
        output logic [1:0]                  s_rresp,
        output logic [BLOCK_W-1:0]          s_rdata,
        output logic [READ_ID_WIDTH-1:0]    s_rid,
        input  logic                        s_rready,

        input  logic [ADDR_W-1:0]           s_awaddr,
        input  logic [7:0]                  s_awlen,
        input  logic [2:0]                  s_awsize,
        input  logic [1:0]                  s_awburst,
        input  logic                        s_awlock,
        input  logic [3:0]                  s_awcache,
        input  logic [2:0]                  s_awprot,
        input  logic [3:0]                  s_awqos,
        input  logic [3:0]                  s_awregion,
        input  logic [2:0]                  s_awsnoop,
        input  logic                        s_awvalid,
        output logic                        s_awready,
        input  logic [WRITE_ID_WIDTH-1:0]   s_awid,

        input  logic                        s_wvalid,
        input  logic                        s_wlast,
        input  logic [BLOCK_W-1:0]          s_wdata,
        input  logic [(BLOCK_W/8)-1:0]      s_wstrb,
        output logic                        s_wready,

        output logic                        s_bvalid,
        output logic [1:0]                  s_bresp,
        output logic [WRITE_ID_WIDTH-1:0]   s_bid,
        input  logic                        s_bready,

        // ---- mem-side AXI4 to AxiRam (flat) ----
        output logic [ADDR_W-1:0]           m_araddr,
        output logic [7:0]                  m_arlen,
        output logic [2:0]                  m_arsize,
        output logic [1:0]                  m_arburst,
        output logic                        m_arlock,
        output logic [3:0]                  m_arcache,
        output logic [2:0]                  m_arprot,
        output logic [3:0]                  m_arqos,
        output logic [3:0]                  m_arregion,
        output logic                        m_arvalid,
        input  logic                        m_arready,
        output logic [READ_ID_WIDTH:0]      m_arid,

        input  logic                        m_rvalid,
        input  logic                        m_rlast,
        input  logic [1:0]                  m_rresp,
        input  logic [BLOCK_W-1:0]          m_rdata,
        input  logic [READ_ID_WIDTH:0]      m_rid,
        output logic                        m_rready,

        output logic [ADDR_W-1:0]           m_awaddr,
        output logic [7:0]                  m_awlen,
        output logic [2:0]                  m_awsize,
        output logic [1:0]                  m_awburst,
        output logic                        m_awlock,
        output logic [3:0]                  m_awcache,
        output logic [2:0]                  m_awprot,
        output logic [3:0]                  m_awqos,
        output logic [3:0]                  m_awregion,
        output logic                        m_awvalid,
        input  logic                        m_awready,
        output logic [WRITE_ID_WIDTH:0]     m_awid,

        output logic                        m_wvalid,
        output logic                        m_wlast,
        output logic [BLOCK_W-1:0]          m_wdata,
        output logic [(BLOCK_W/8)-1:0]      m_wstrb,
        input  logic                        m_wready,

        input  logic                        m_bvalid,
        input  logic [1:0]                  m_bresp,
        input  logic [WRITE_ID_WIDTH:0]     m_bid,
        output logic                        m_bready,

        // Debug: FULL reconstructed mem-side addresses BEFORE the MEM_MASK fold.
        output logic [ADDR_W-1:0]           dbg_m_araddr_full,
        output logic [ADDR_W-1:0]           dbg_m_awaddr_full
    );

    localparam logic[READ_ID_WIDTH-1:0] FLUSH_ID = '1;

    // -- Flush controller AR output --
    ar_t                       flush_ar;
    logic[READ_ID_WIDTH-1:0]   flush_arid;
    logic                      flush_arready;
    r_t                        flush_r;
    logic                      flush_rready;

    tc_flush_controller #(
        .LINES   (LINES),
        .WAYS    (WAYS),
        .LINE_W  (LINE_W),
        .BLOCK_W (BLOCK_W),
        .ID_W    (READ_ID_WIDTH),
        .ADDR_W  (ADDR_W),
        .ADDR_BASE(ADDR_RANGE_L),
        .ADDR_RANGE_H(ADDR_RANGE_H)
    ) flush_ctrl (
        .clk(clk), .rst(rst),
        .flush_req(flush_req), .flush_mode(flush_mode),
        .flush_active(flush_active), .flush_done(flush_done),
        .m_ar(flush_ar), .m_arid(flush_arid), .m_arready(flush_arready),
        .m_r(flush_r), .m_rdata(cache_rdata), .m_rid(cache_rid), .m_rready(flush_rready)
    );

    always_ff @(posedge clk) begin
        if (!rst && (flush_req || flush_active)
            && (s_arvalid || s_awvalid || s_wvalid))
            $fatal(1, "dut_flush: flush requested while an accelerator request is active");
    end

    // -- Repack accelerator-side flat signals into struct types --
    ar_t s_ar;  aw_t s_aw;  w_t s_w;  r_t s_r;  b_t s_b;
    assign s_ar = '{
        araddr: s_araddr, arlen: s_arlen, arsize: s_arsize, arburst: s_arburst,
        arlock: s_arlock, arcache: s_arcache, arprot: s_arprot,
        arqos: s_arqos, arregion: s_arregion, arvalid: s_arvalid, arsnoop: s_arsnoop
    };
    assign s_aw = '{
        awaddr: s_awaddr, awlen: s_awlen, awsize: s_awsize,
        awburst: s_awburst, awlock: s_awlock, awcache: s_awcache,
        awprot: s_awprot, awqos: s_awqos, awregion: s_awregion,
        awsnoop: s_awsnoop, awvalid: s_awvalid
    };
    assign s_w = '{ wlast: s_wlast, wvalid: s_wvalid };
    assign s_rvalid = s_r.rvalid;
    assign s_rlast  = s_r.rlast;
    assign s_rresp  = s_r.rresp[1:0];
    assign s_bvalid = s_b.bvalid;
    assign s_bresp  = s_b.bresp;

    // -- 2:1 priority mux: while flush_active, flush controller owns AR --
    ar_t                       cache_ar;
    logic[READ_ID_WIDTH-1:0]   cache_arid;
    logic                      cache_arready;
    r_t                        cache_r;
    logic[BLOCK_W-1:0]         cache_rdata;
    logic[READ_ID_WIDTH-1:0]   cache_rid;
    logic                      cache_rready;

    // Tests request a flush only after accelerator traffic is quiescent.
    // The mux therefore never changes owner while an AR is stalled.
    always_comb begin
        if (flush_active) begin
            cache_ar           = flush_ar;
            cache_arid         = flush_arid;
            flush_arready      = cache_arready;
            s_arready          = 1'b0;
        end else begin
            cache_ar           = s_ar;
            cache_arid         = s_arid;
            flush_arready      = 1'b0;
            s_arready          = cache_arready;
        end
    end

    // Route the reserved ID only while a flush response is valid.
    wire route_to_flush = flush_active & cache_r.rvalid & (cache_rid == FLUSH_ID);
    assign flush_r        = '{ rvalid: cache_r.rvalid & route_to_flush,
                                rlast:  cache_r.rlast,
                                rresp:  cache_r.rresp };
    assign s_r            = '{ rvalid: cache_r.rvalid & ~route_to_flush,
                                rlast:  cache_r.rlast,
                                rresp:  cache_r.rresp };
    assign s_rdata        = cache_rdata;
    assign s_rid          = cache_rid;
    // cache_rready = whichever side is consuming this beat
    assign cache_rready   = route_to_flush ? flush_rready : s_rready;

    // AW/W/B: accelerator only. Flush is CBOM-via-AR; never issues AW/W.
    // Gate accelerator AW while flushing so the cache sees no new writes.
    aw_t cache_aw;
    logic cache_awready;
    w_t  cache_w;
    logic cache_wready;
    b_t cache_b;
    logic cache_bready;
    logic[WRITE_ID_WIDTH-1:0] cache_awid;
    logic[WRITE_ID_WIDTH-1:0] cache_bid;
    assign cache_aw   = '{ awaddr: s_aw.awaddr, awlen: s_aw.awlen, awsize: s_aw.awsize,
                            awburst: s_aw.awburst, awlock: s_aw.awlock, awcache: s_aw.awcache,
                            awprot: s_aw.awprot, awqos: s_aw.awqos, awregion: s_aw.awregion,
                            awsnoop: s_aw.awsnoop,
                            awvalid: s_aw.awvalid & ~flush_active };
    assign s_awready  = cache_awready & ~flush_active;
    assign cache_awid = s_awid;
    assign cache_w    = '{ wlast: s_w.wlast,
                            wvalid: s_w.wvalid & ~flush_active };
    assign s_wready   = cache_wready & ~flush_active;
    assign s_b        = cache_b;
    assign s_bid      = cache_bid;
    assign cache_bready = s_bready;

    // -- Master-side flat unpack (same as dut_cocotb) --
    localparam logic [ADDR_W-1:0] MEM_MASK = ADDR_W'(32'h07FF_FFFF);
    ar_t m_ar_struct;  aw_t m_aw_struct;  w_t m_w_struct;  r_t m_r_struct;  b_t m_b_struct;
    assign m_araddr   = m_ar_struct.araddr[ADDR_W-1:0] & MEM_MASK;
    assign dbg_m_araddr_full = m_ar_struct.araddr[ADDR_W-1:0];
    assign dbg_m_awaddr_full = m_aw_struct.awaddr[ADDR_W-1:0];
    assign m_arlen    = m_ar_struct.arlen;
    assign m_arsize   = m_ar_struct.arsize;
    assign m_arburst  = m_ar_struct.arburst;
    assign m_arlock   = m_ar_struct.arlock;
    assign m_arcache  = m_ar_struct.arcache;
    assign m_arprot   = m_ar_struct.arprot;
    assign m_arqos    = m_ar_struct.arqos;
    assign m_arregion = m_ar_struct.arregion;
    assign m_arvalid  = m_ar_struct.arvalid;
    assign m_awaddr   = m_aw_struct.awaddr[ADDR_W-1:0] & MEM_MASK;
    assign m_awlen    = m_aw_struct.awlen;
    assign m_awsize   = m_aw_struct.awsize;
    assign m_awburst  = m_aw_struct.awburst;
    assign m_awlock   = m_aw_struct.awlock;
    assign m_awcache  = m_aw_struct.awcache;
    assign m_awprot   = m_aw_struct.awprot;
    assign m_awqos    = m_aw_struct.awqos;
    assign m_awregion = m_aw_struct.awregion;
    assign m_awvalid  = m_aw_struct.awvalid;
    assign m_wvalid   = m_w_struct.wvalid;
    assign m_wlast    = m_w_struct.wlast;
    assign m_r_struct = '{ rvalid: m_rvalid, rlast: m_rlast, rresp: {2'b00, m_rresp} };
    assign m_b_struct = '{ bvalid: m_bvalid, bresp: m_bresp };

    l2_cache #(
        .POLICY         (POLICY),
        .LINES          (LINES),
        .LINE_W         (LINE_W),
        .WAYS           (WAYS),
        .BLOCK_W        (BLOCK_W),
        .READ_ID_WIDTH  (READ_ID_WIDTH),
        .WRITE_ID_WIDTH (WRITE_ID_WIDTH),
        .ADDR_W         (ADDR_W),
        .ADDR_RANGE_L   (ADDR_RANGE_L),
        .ADDR_RANGE_H   (ADDR_RANGE_H),
        .DB_LATENCY     (DB_LATENCY),
        .INCLUDE_CBOM   (INCLUDE_CBOM),
        .INCLUDE_VICTIM (INCLUDE_VICTIM),
        .VICTIM_LINES   (VICTIM_LINES)
    ) cache (
        .clk(clk), .rst(rst),
        //GRASP region ports tied off (SRRIP-FP fallback; this TB doesn't exercise them).
        .grasp_high_addr_l('0), .grasp_high_addr_h('0),
        .grasp_moderate_addr_l('0), .grasp_moderate_addr_h('0),
        .req_ar(cache_ar), .req_arid(cache_arid), .req_arready(cache_arready),
        .req_r(cache_r), .req_rdata(cache_rdata), .req_rid(cache_rid), .req_rready(cache_rready),
        .req_aw(cache_aw), .req_awid(cache_awid), .req_awready(cache_awready),
        .req_w(cache_w), .req_wdata(s_wdata), .req_wstrb(s_wstrb), .req_wready(cache_wready),
        .req_b(cache_b), .req_bid(cache_bid), .req_bready(cache_bready),

        .mem_ar(m_ar_struct), .mem_arid(m_arid), .mem_arready(m_arready),
        .mem_r(m_r_struct),   .mem_rdata(m_rdata), .mem_rid(m_rid), .mem_rready(m_rready),
        .mem_aw(m_aw_struct), .mem_awid(m_awid), .mem_awready(m_awready),
        .mem_w(m_w_struct),   .mem_wdata(m_wdata), .mem_wstrb(m_wstrb), .mem_wready(m_wready),
        .mem_b(m_b_struct),   .mem_bid(m_bid), .mem_bready(m_bready)
    );

    logic [31:0] pc_violations_s, pc_violations_m;
    wire [31:0] pc_violations_total = pc_violations_s + pc_violations_m;

    axi4_protocol_checker #(
        .ADDR_W        (ADDR_W),
        .DATA_W        (BLOCK_W),
        .ID_W          (READ_ID_WIDTH),
        .CHECK_C6      (1'b0),
        .READ_ID_DEPTH (4),
        .WRITE_ID_DEPTH(2)
    ) pc_slave (
        .clk(clk), .rst(rst),
        .araddr(cache_ar.araddr[ADDR_W-1:0]), .arlen(cache_ar.arlen),
        .arsize(cache_ar.arsize), .arburst(cache_ar.arburst),
        .arid(cache_arid), .arvalid(cache_ar.arvalid), .arready(cache_arready),
        .rdata(cache_rdata), .rresp(cache_r.rresp[1:0]), .rlast(cache_r.rlast),
        .rid(cache_rid), .rvalid(cache_r.rvalid), .rready(cache_rready),
        .awaddr(cache_aw.awaddr[ADDR_W-1:0]), .awlen(cache_aw.awlen),
        .awsize(cache_aw.awsize), .awburst(cache_aw.awburst),
        .awid(cache_awid), .awvalid(cache_aw.awvalid), .awready(cache_awready),
        .wdata(s_wdata), .wstrb(s_wstrb), .wlast(cache_w.wlast),
        .wvalid(cache_w.wvalid), .wready(cache_wready),
        .bresp(cache_b.bresp), .bid(cache_bid), .bvalid(cache_b.bvalid),
        .bready(cache_bready), .violations(pc_violations_s)
    );

    axi4_protocol_checker #(
        .ADDR_W                  (ADDR_W),
        .DATA_W                  (BLOCK_W),
        .ID_W                    (READ_ID_WIDTH + 1),
        .CHECK_B1_RESPONSE_VALID (1'b0),
        .CHECK_RESPONSE_STABILITY(1'b0)
    ) pc_mem (
        .clk(clk), .rst(rst),
        .araddr(m_ar_struct.araddr[ADDR_W-1:0]), .arlen(m_arlen),
        .arsize(m_arsize), .arburst(m_arburst),
        .arid(m_arid), .arvalid(m_arvalid), .arready(m_arready),
        .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast), .rid(m_rid),
        .rvalid(m_rvalid), .rready(m_rready),
        .awaddr(m_aw_struct.awaddr[ADDR_W-1:0]), .awlen(m_awlen),
        .awsize(m_awsize), .awburst(m_awburst),
        .awid(m_awid), .awvalid(m_awvalid), .awready(m_awready),
        .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast),
        .wvalid(m_wvalid), .wready(m_wready),
        .bresp(m_bresp), .bid(m_bid), .bvalid(m_bvalid), .bready(m_bready),
        .violations(pc_violations_m)
    );

endmodule
