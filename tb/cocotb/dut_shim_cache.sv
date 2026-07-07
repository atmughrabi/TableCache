// SPDX-License-Identifier: Apache-2.0
// Integration wrapper: tc_narrow_shim -> l2_cache -> AxiRam
//
//   accelerator (NARROW_W)             ┌── AxiMaster (cocotb)
//        │                              ▼
//        ▼                       ┌─────────────┐
//   tc_narrow_shim ─► l2_cache ─►│  AxiRam     │
//        │  (NARROW)   (BLOCK_W) │   (cocotb)  │
//        ▼                       └─────────────┘
// Both s_* (NARROW) and mem_* (BLOCK_W) are flat AXI so cocotbext-axi can
// hook in. Snoop sidebands on the slave side are tied to 0 (CBOM not
// exercised through the shim integration path).
`timescale 1ns/1ps

module dut_shim_cache
    import cache_config::*;
    #(
`ifdef TC_NARROW_W
        parameter int NARROW_W = `TC_NARROW_W,
`else
        parameter int NARROW_W = 32,
`endif
`ifdef TC_BLOCK_W
        parameter int BLOCK_W  = `TC_BLOCK_W,
`else
        parameter int BLOCK_W  = 512,
`endif
`ifdef TC_POLICY
        parameter replacement_policy_t POLICY = `TC_POLICY,
`else
        parameter replacement_policy_t POLICY = LRU,
`endif
`ifdef TC_LINES
        parameter int LINES    = `TC_LINES,
`else
        parameter int LINES    = 128,
`endif
`ifdef TC_LINE_W
        parameter int LINE_W   = `TC_LINE_W,
`else
        parameter int LINE_W   = 1,        // 1 beat per line at BLOCK_W=512 → 64B line
`endif
`ifdef TC_WAYS
        parameter int WAYS     = `TC_WAYS,
`else
        parameter int WAYS     = 8,
`endif
        parameter int READ_ID_WIDTH  = 4,
        parameter int WRITE_ID_WIDTH = 4,
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
        parameter int VICTIM_LINES = 8
    ) (
        input  logic clk,
        input  logic rst,

        // narrow slave (accelerator)
        input  logic [31:0]                 s_araddr,
        input  logic [7:0]                  s_arlen,
        input  logic [2:0]                  s_arsize,
        input  logic [1:0]                  s_arburst,
        input  logic                        s_arlock,
        input  logic [3:0]                  s_arcache,
        input  logic [2:0]                  s_arprot,
        input  logic [3:0]                  s_arqos,
        input  logic [3:0]                  s_arregion,
        input  logic [READ_ID_WIDTH-1:0]    s_arid,
        input  logic                        s_arvalid,
        output logic                        s_arready,

        output logic [NARROW_W-1:0]         s_rdata,
        output logic [1:0]                  s_rresp,
        output logic                        s_rlast,
        output logic [READ_ID_WIDTH-1:0]    s_rid,
        output logic                        s_rvalid,
        input  logic                        s_rready,

        input  logic [31:0]                 s_awaddr,
        input  logic [7:0]                  s_awlen,
        input  logic [2:0]                  s_awsize,
        input  logic [1:0]                  s_awburst,
        input  logic                        s_awlock,
        input  logic [3:0]                  s_awcache,
        input  logic [2:0]                  s_awprot,
        input  logic [3:0]                  s_awqos,
        input  logic [3:0]                  s_awregion,
        input  logic [WRITE_ID_WIDTH-1:0]   s_awid,
        input  logic                        s_awvalid,
        output logic                        s_awready,

        input  logic [NARROW_W-1:0]         s_wdata,
        input  logic [NARROW_W/8-1:0]       s_wstrb,
        input  logic                        s_wlast,
        input  logic                        s_wvalid,
        output logic                        s_wready,

        output logic [1:0]                  s_bresp,
        output logic [WRITE_ID_WIDTH-1:0]   s_bid,
        output logic                        s_bvalid,
        input  logic                        s_bready,

        // wide master (AxiRam / DDR)
        output logic [31:0]                 m_araddr,
        output logic [7:0]                  m_arlen,
        output logic [2:0]                  m_arsize,
        output logic [1:0]                  m_arburst,
        output logic                        m_arlock,
        output logic [3:0]                  m_arcache,
        output logic [2:0]                  m_arprot,
        output logic [3:0]                  m_arqos,
        output logic [3:0]                  m_arregion,
        output logic [READ_ID_WIDTH:0]      m_arid,
        output logic                        m_arvalid,
        input  logic                        m_arready,

        input  logic [BLOCK_W-1:0]          m_rdata,
        input  logic [1:0]                  m_rresp,
        input  logic                        m_rlast,
        input  logic [READ_ID_WIDTH:0]      m_rid,
        input  logic                        m_rvalid,
        output logic                        m_rready,

        output logic [31:0]                 m_awaddr,
        output logic [7:0]                  m_awlen,
        output logic [2:0]                  m_awsize,
        output logic [1:0]                  m_awburst,
        output logic                        m_awlock,
        output logic [3:0]                  m_awcache,
        output logic [2:0]                  m_awprot,
        output logic [3:0]                  m_awqos,
        output logic [3:0]                  m_awregion,
        output logic [WRITE_ID_WIDTH:0]     m_awid,
        output logic                        m_awvalid,
        input  logic                        m_awready,

        output logic [BLOCK_W-1:0]          m_wdata,
        output logic [BLOCK_W/8-1:0]        m_wstrb,
        output logic                        m_wlast,
        output logic                        m_wvalid,
        input  logic                        m_wready,

        input  logic [1:0]                  m_bresp,
        input  logic [WRITE_ID_WIDTH:0]     m_bid,
        input  logic                        m_bvalid,
        output logic                        m_bready
    );

    // -------------------------------------------------------------
    // Wires between shim and cache (wide AXI)
    // -------------------------------------------------------------
    logic [31:0]                  c_araddr;
    logic [7:0]                   c_arlen;
    logic [2:0]                   c_arsize;
    logic [1:0]                   c_arburst;
    logic [3:0]                   c_arsnoop;
    logic [READ_ID_WIDTH-1:0]     c_arid;
    logic                         c_arvalid, c_arready;
    logic [BLOCK_W-1:0]           c_rdata;
    logic [1:0]                   c_rresp;
    logic                         c_rlast;
    logic [READ_ID_WIDTH-1:0]     c_rid;
    logic                         c_rvalid, c_rready;
    logic [31:0]                  c_awaddr;
    logic [7:0]                   c_awlen;
    logic [2:0]                   c_awsize;
    logic [1:0]                   c_awburst;
    logic [2:0]                   c_awsnoop;
    logic [WRITE_ID_WIDTH-1:0]    c_awid;
    logic                         c_awvalid, c_awready;
    logic [BLOCK_W-1:0]           c_wdata;
    logic [BLOCK_W/8-1:0]         c_wstrb;
    logic                         c_wlast, c_wvalid, c_wready;
    logic [1:0]                   c_bresp;
    logic [WRITE_ID_WIDTH-1:0]    c_bid;
    logic                         c_bvalid, c_bready;

    // -------------------------------------------------------------
    // Shim
    // -------------------------------------------------------------
    tc_narrow_shim #(
        .NARROW_W (NARROW_W),
        .BLOCK_W  (BLOCK_W),
        .ID_W     (READ_ID_WIDTH),
        .ADDR_W   (32),
        .MAX_OUTSTANDING_W (16),
        .ENABLE_LINE_BUFFER(1'b1)
`ifdef TC_READ_REORDER_DEPTH
        , .READ_REORDER_DEPTH(`TC_READ_REORDER_DEPTH)
`endif
    ) u_shim (
        .clk(clk), .rst(rst),
        // s_* from accelerator
        .s_araddr (s_araddr ), .s_arlen  (s_arlen ), .s_arsize (s_arsize),
        .s_arburst(s_arburst), .s_arsnoop(4'd0   ), .s_arid   (s_arid),
        .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata  (s_rdata  ), .s_rresp  (s_rresp ), .s_rlast  (s_rlast),
        .s_rid    (s_rid    ), .s_rvalid (s_rvalid), .s_rready (s_rready),
        .s_awaddr (s_awaddr ), .s_awlen  (s_awlen ), .s_awsize (s_awsize),
        .s_awburst(s_awburst), .s_awsnoop(3'd0   ), .s_awid   (s_awid),
        .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata  (s_wdata  ), .s_wstrb  (s_wstrb ), .s_wlast  (s_wlast),
        .s_wvalid (s_wvalid ), .s_wready (s_wready),
        .s_bresp  (s_bresp  ), .s_bid    (s_bid   ),
        .s_bvalid (s_bvalid ), .s_bready (s_bready),
        // m_* -> cache req side
        .m_araddr (c_araddr ), .m_arlen  (c_arlen ), .m_arsize (c_arsize),
        .m_arburst(c_arburst), .m_arsnoop(c_arsnoop), .m_arid  (c_arid),
        .m_arvalid(c_arvalid), .m_arready(c_arready),
        .m_rdata  (c_rdata  ), .m_rresp  (c_rresp ), .m_rlast  (c_rlast),
        .m_rid    (c_rid    ), .m_rvalid (c_rvalid), .m_rready (c_rready),
        .m_awaddr (c_awaddr ), .m_awlen  (c_awlen ), .m_awsize (c_awsize),
        .m_awburst(c_awburst), .m_awsnoop(c_awsnoop), .m_awid  (c_awid),
        .m_awvalid(c_awvalid), .m_awready(c_awready),
        .m_wdata  (c_wdata  ), .m_wstrb  (c_wstrb ), .m_wlast  (c_wlast),
        .m_wvalid (c_wvalid ), .m_wready (c_wready),
        .m_bresp  (c_bresp  ), .m_bid    (c_bid   ),
        .m_bvalid (c_bvalid ), .m_bready (c_bready)
    );

    // -------------------------------------------------------------
    // Pack the shim's wide signals into l2_cache's struct ports
    // -------------------------------------------------------------
    ar_t c_ar;
    aw_t c_aw;
    w_t  c_w;
    r_t  c_r;
    b_t  c_b;
    assign c_ar = '{
        araddr:c_araddr, arlen:c_arlen, arsize:c_arsize, arburst:c_arburst,
        arlock:1'b0, arcache:4'b1111, arprot:3'b000, arqos:'0, arregion:'0,
        arvalid:c_arvalid, arsnoop:c_arsnoop
    };
    assign c_aw = '{
        awaddr:c_awaddr, awlen:c_awlen, awsize:c_awsize, awburst:c_awburst,
        awlock:1'b0, awcache:4'b1111, awprot:3'b000, awqos:'0, awregion:'0,
        awsnoop:c_awsnoop, awvalid:c_awvalid
    };
    assign c_w  = '{ wlast:c_wlast, wvalid:c_wvalid };
    assign c_rvalid = c_r.rvalid;
    assign c_rlast  = c_r.rlast;
    assign c_rresp  = c_r.rresp[1:0];
    assign c_bvalid = c_b.bvalid;
    assign c_bresp  = c_b.bresp;

    // Mem-side (cache -> AxiRam)
    localparam logic [31:0] MEM_MASK = 32'h07FF_FFFF;
    ar_t mem_ar_s;
    aw_t mem_aw_s;
    w_t  mem_w_s;
    r_t  mem_r_s;
    b_t  mem_b_s;
    assign m_araddr   = mem_ar_s.araddr & MEM_MASK;
    assign m_arlen    = mem_ar_s.arlen;
    assign m_arsize   = mem_ar_s.arsize;
    assign m_arburst  = mem_ar_s.arburst;
    assign m_arlock   = mem_ar_s.arlock;
    assign m_arcache  = mem_ar_s.arcache;
    assign m_arprot   = mem_ar_s.arprot;
    assign m_arqos    = mem_ar_s.arqos;
    assign m_arregion = mem_ar_s.arregion;
    assign m_arvalid  = mem_ar_s.arvalid;
    assign m_awaddr   = mem_aw_s.awaddr & MEM_MASK;
    assign m_awlen    = mem_aw_s.awlen;
    assign m_awsize   = mem_aw_s.awsize;
    assign m_awburst  = mem_aw_s.awburst;
    assign m_awlock   = mem_aw_s.awlock;
    assign m_awcache  = mem_aw_s.awcache;
    assign m_awprot   = mem_aw_s.awprot;
    assign m_awqos    = mem_aw_s.awqos;
    assign m_awregion = mem_aw_s.awregion;
    assign m_awvalid  = mem_aw_s.awvalid;
    assign m_wvalid   = mem_w_s.wvalid;
    assign m_wlast    = mem_w_s.wlast;
    assign mem_r_s = '{ rvalid:m_rvalid, rlast:m_rlast, rresp:{2'b00, m_rresp} };
    assign mem_b_s = '{ bvalid:m_bvalid, bresp:m_bresp };

    l2_cache #(
        .POLICY        (POLICY),
        .LINES         (LINES),
        .LINE_W        (LINE_W),
        .WAYS          (WAYS),
        .BLOCK_W       (BLOCK_W),
        .READ_ID_WIDTH (READ_ID_WIDTH),
        .WRITE_ID_WIDTH(WRITE_ID_WIDTH),
        .DB_LATENCY    (DB_LATENCY),
        .INCLUDE_CBOM  (INCLUDE_CBOM),
        .INCLUDE_VICTIM(INCLUDE_VICTIM),
        .VICTIM_LINES  (VICTIM_LINES)
    ) u_cache (
        .clk(clk), .rst(rst),
        //GRASP region ports tied off (SRRIP-FP fallback; this TB doesn't exercise them).
        .grasp_high_addr_l(32'h0), .grasp_high_addr_h(32'h0),
        .grasp_moderate_addr_l(32'h0), .grasp_moderate_addr_h(32'h0),
        .req_ar(c_ar), .req_arid(c_arid), .req_arready(c_arready),
        .req_r (c_r ), .req_rdata(c_rdata), .req_rid(c_rid), .req_rready(c_rready),
        .req_aw(c_aw), .req_awid(c_awid), .req_awready(c_awready),
        .req_w (c_w ), .req_wdata(c_wdata), .req_wstrb(c_wstrb), .req_wready(c_wready),
        .req_b (c_b ), .req_bid(c_bid),    .req_bready(c_bready),
        .mem_ar(mem_ar_s), .mem_arid(m_arid), .mem_arready(m_arready),
        .mem_r (mem_r_s ), .mem_rdata(m_rdata), .mem_rid(m_rid), .mem_rready(m_rready),
        .mem_aw(mem_aw_s), .mem_awid(m_awid), .mem_awready(m_awready),
        .mem_w (mem_w_s ), .mem_wdata(m_wdata), .mem_wstrb(m_wstrb), .mem_wready(m_wready),
        .mem_b (mem_b_s ), .mem_bid(m_bid),    .mem_bready(m_bready)
    );

    // ------------------------------------------------------------------
    // AXI4 protocol checkers: narrow slave (s_*), shim-cache bus (c_*),
    // and wide mem (m_*).
    // ------------------------------------------------------------------
    logic [31:0] pc_violations_s, pc_violations_c, pc_violations_m;
    wire  [31:0] pc_violations_total =
        pc_violations_s + pc_violations_c + pc_violations_m;

    // pc_slave: narrow side driven by cocotbext-axi AxiMaster. Disable C6
    // (AxiMaster v0.1.28 WLAST timing) and B1_RESPONSE_VALID (shim's
    // s_rvalid is a combinational reflection of m_rvalid → AxiRam reset
    // quirk propagates here).
    axi4_protocol_checker #(
        .ADDR_W                  (32),
        .DATA_W                  (NARROW_W),
        .ID_W                    (READ_ID_WIDTH),
        .CHECK_C6                (1'b0),
        .CHECK_B1_RESPONSE_VALID (1'b0)
    ) pc_slave (
        .clk(clk), .rst(rst),
        .araddr(s_araddr), .arlen(s_arlen), .arsize(s_arsize), .arburst(s_arburst),
        .arid(s_arid), .arvalid(s_arvalid), .arready(s_arready),
        .rdata(s_rdata), .rresp(s_rresp), .rlast(s_rlast), .rid(s_rid),
        .rvalid(s_rvalid), .rready(s_rready),
        .awaddr(s_awaddr), .awlen(s_awlen), .awsize(s_awsize), .awburst(s_awburst),
        .awid(s_awid), .awvalid(s_awvalid), .awready(s_awready),
        .wdata(s_wdata), .wstrb(s_wstrb), .wlast(s_wlast),
        .wvalid(s_wvalid), .wready(s_wready),
        .bresp(s_bresp), .bid(s_bid), .bvalid(s_bvalid), .bready(s_bready),
        .violations(pc_violations_s)
    );

    // pc_cache: RTL↔RTL bus between the shim and the cache. Both endpoints
    // are DUT, so all rules stay enabled — this is the highest-value
    // checker instance and any violation here is a real bug.
    axi4_protocol_checker #(
        .ADDR_W (32),
        .DATA_W (BLOCK_W),
        .ID_W   (READ_ID_WIDTH)
    ) pc_cache (
        .clk(clk), .rst(rst),
        .araddr(c_araddr), .arlen(c_arlen), .arsize(c_arsize), .arburst(c_arburst),
        .arid(c_arid), .arvalid(c_arvalid), .arready(c_arready),
        .rdata(c_rdata), .rresp(c_rresp), .rlast(c_rlast), .rid(c_rid),
        .rvalid(c_rvalid), .rready(c_rready),
        .awaddr(c_awaddr), .awlen(c_awlen), .awsize(c_awsize), .awburst(c_awburst),
        .awid(c_awid), .awvalid(c_awvalid), .awready(c_awready),
        .wdata(c_wdata), .wstrb(c_wstrb), .wlast(c_wlast),
        .wvalid(c_wvalid), .wready(c_wready),
        .bresp(c_bresp), .bid(c_bid), .bvalid(c_bvalid), .bready(c_bready),
        .violations(pc_violations_c)
    );

    // pc_mem: cache's m_* output going to cocotbext-axi AxiRam. Disable
    // B1_RESPONSE_VALID (AxiRam reset quirk).
    axi4_protocol_checker #(
        .ADDR_W                  (32),
        .DATA_W                  (BLOCK_W),
        .ID_W                    (READ_ID_WIDTH + 1),
        .CHECK_B1_RESPONSE_VALID (1'b0)
    ) pc_mem (
        .clk(clk), .rst(rst),
        .araddr(m_araddr), .arlen(m_arlen), .arsize(m_arsize), .arburst(m_arburst),
        .arid(m_arid), .arvalid(m_arvalid), .arready(m_arready),
        .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast), .rid(m_rid),
        .rvalid(m_rvalid), .rready(m_rready),
        .awaddr(m_awaddr), .awlen(m_awlen), .awsize(m_awsize), .awburst(m_awburst),
        .awid(m_awid), .awvalid(m_awvalid), .awready(m_awready),
        .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast),
        .wvalid(m_wvalid), .wready(m_wready),
        .bresp(m_bresp), .bid(m_bid), .bvalid(m_bvalid), .bready(m_bready),
        .violations(pc_violations_m)
    );

endmodule
