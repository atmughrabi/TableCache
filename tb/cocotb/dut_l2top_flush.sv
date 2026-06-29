// SPDX-License-Identifier: Apache-2.0
// Test wrapper: accelerator-side AXI master <- 2:1 priority mux ->
//   { tc_flush_controller, accelerator } -> l2_top (AXI4 wrapper) -> AxiRam.
//
// This is the dut_flush.sv harness routed through l2_top instead of
// l2_cache directly. It exists to verify that a CBOM-based whole-cache
// flush (tc_flush_controller, CleanInvalid) actually reaches the cache
// core through the l2_top AXI wrapper -- i.e. that l2_top forwards the
// s00_axi_arsnoop sideband and is built with INCLUDE_CBOM=1.
//
// With INCLUDE_CBOM=0 (or arsnoop dropped) every flush CBOM is demoted to
// a plain read, the cold-line "read" never gets a fill, and the flush
// controller wedges in WAIT_R -- the exact GraphBlox integration hang.
`timescale 1ns/1ps

module dut_l2top_flush
    import cache_config::*;
    #(
`ifdef TC_POLICY_INT
        parameter int REPLACEMENT_POLICY = `TC_POLICY_INT,
`else
        parameter int REPLACEMENT_POLICY = 0,
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

        // ---- flush control ----
        input  logic       flush_req,
        input  logic[3:0]  flush_mode,
        output logic       flush_active,
        output logic       flush_done,

        // ---- accelerator-side AXI4/ACE slave (flat for cocotb) ----
        input  logic [31:0]                 s_araddr,
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

        input  logic [31:0]                 s_awaddr,
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
        output logic [31:0]                 m_araddr,
        output logic [7:0]                  m_arlen,
        output logic [2:0]                  m_arsize,
        output logic [1:0]                  m_arburst,
        output logic                        m_arlock,
        output logic [3:0]                  m_arcache,
        output logic [2:0]                  m_arprot,
        output logic [3:0]                  m_arqos,
        output logic                        m_arvalid,
        input  logic                        m_arready,
        output logic [READ_ID_WIDTH:0]      m_arid,

        input  logic                        m_rvalid,
        input  logic                        m_rlast,
        input  logic [1:0]                  m_rresp,
        input  logic [BLOCK_W-1:0]          m_rdata,
        input  logic [READ_ID_WIDTH:0]      m_rid,
        output logic                        m_rready,

        output logic [31:0]                 m_awaddr,
        output logic [7:0]                  m_awlen,
        output logic [2:0]                  m_awsize,
        output logic [1:0]                  m_awburst,
        output logic                        m_awlock,
        output logic [3:0]                  m_awcache,
        output logic [2:0]                  m_awprot,
        output logic [3:0]                  m_awqos,
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
        output logic                        m_bready
    );

    localparam logic[READ_ID_WIDTH-1:0] FLUSH_ID = '1;
    localparam logic [31:0] MEM_MASK = 32'h07FF_FFFF;

    // -- Flush controller AR output (struct) --
    ar_t                       flush_ar;
    logic[READ_ID_WIDTH-1:0]   flush_arid;
    logic                      flush_arready;
    r_t                        flush_r;
    logic                      flush_rready;

    tc_flush_controller #(
        .LINES   (LINES),
        .LINE_W  (LINE_W),
        .BLOCK_W (BLOCK_W),
        .ID_W    (READ_ID_WIDTH),
        .ADDR_BASE(32'h80000000)
    ) flush_ctrl (
        .clk(clk), .rst(rst),
        .flush_req(flush_req), .flush_mode(flush_mode),
        .flush_active(flush_active), .flush_done(flush_done),
        .m_ar(flush_ar), .m_arid(flush_arid), .m_arready(flush_arready),
        .m_r(flush_r), .m_rdata(c_rdata), .m_rid(c_rid), .m_rready(flush_rready)
    );

    // -- 2:1 priority AR mux (flat into l2_top S00). While flush_active the
    //    flush controller owns AR; the accelerator AR is gated. --
    logic [READ_ID_WIDTH-1:0] c_arid;
    logic [31:0]              c_araddr;
    logic [7:0]               c_arlen;
    logic [2:0]               c_arsize;
    logic [1:0]               c_arburst;
    logic                     c_arlock;
    logic [3:0]               c_arcache;
    logic [2:0]               c_arprot;
    logic [3:0]               c_arqos;
    logic [3:0]               c_arregion;
    logic [3:0]               c_arsnoop;
    logic                     c_arvalid;
    logic                     c_arready;

    always_comb begin
        if (flush_active) begin
            c_arid       = flush_arid;
            c_araddr     = flush_ar.araddr;
            c_arlen      = flush_ar.arlen;
            c_arsize     = flush_ar.arsize;
            c_arburst    = flush_ar.arburst;
            c_arlock     = flush_ar.arlock;
            c_arcache    = flush_ar.arcache;
            c_arprot     = flush_ar.arprot;
            c_arqos      = flush_ar.arqos;
            c_arregion   = flush_ar.arregion;
            c_arsnoop    = flush_ar.arsnoop;
            c_arvalid    = flush_ar.arvalid;
            flush_arready = c_arready;
            s_arready     = 1'b0;
        end else begin
            c_arid       = s_arid;
            c_araddr     = s_araddr;
            c_arlen      = s_arlen;
            c_arsize     = s_arsize;
            c_arburst    = s_arburst;
            c_arlock     = s_arlock;
            c_arcache    = s_arcache;
            c_arprot     = s_arprot;
            c_arqos      = s_arqos;
            c_arregion   = s_arregion;
            c_arsnoop    = s_arsnoop;
            c_arvalid    = s_arvalid;
            flush_arready = 1'b0;
            s_arready     = c_arready;
        end
    end

    // -- l2_top R outputs (flat) --
    logic [READ_ID_WIDTH-1:0] c_rid;
    logic [BLOCK_W-1:0]       c_rdata;
    logic [1:0]               c_rresp;
    logic                     c_rlast;
    logic                     c_rvalid;
    logic                     c_rready;

    // R demux by id: route FLUSH_ID responses to the controller while
    // flushing, everything else to the accelerator.
    wire route_to_flush = flush_active & (c_rid == FLUSH_ID);
    assign flush_r   = '{ rvalid: c_rvalid & route_to_flush,
                          rlast:  c_rlast,
                          rresp:  {2'b00, c_rresp} };
    assign s_rvalid  = c_rvalid & ~route_to_flush;
    assign s_rlast   = c_rlast;
    assign s_rresp   = c_rresp;
    assign s_rdata   = c_rdata;
    assign s_rid     = c_rid;
    assign c_rready  = route_to_flush ? flush_rready : s_rready;

    // AW/W/B: accelerator only (flush is CBOM-via-AR). Gated while flushing.
    logic c_awready;
    logic c_wready;
    logic c_bvalid;
    logic [1:0] c_bresp;
    logic [WRITE_ID_WIDTH-1:0] c_bid;
    assign s_awready = c_awready & ~flush_active;
    assign s_wready  = c_wready  & ~flush_active;
    assign s_bvalid  = c_bvalid;
    assign s_bresp   = c_bresp;
    assign s_bid     = c_bid;

    // mem-side address masking so the small AxiRam image is addressable.
    logic [31:0] m_araddr_raw, m_awaddr_raw;
    assign m_araddr = m_araddr_raw & MEM_MASK;
    assign m_awaddr = m_awaddr_raw & MEM_MASK;

    l2_top #(
        .ADDR_L              (32'h80000000),
        .ADDR_H              (32'hFFFFFFFF),
        .WAYS                (WAYS),
        .LINES               (LINES),
        .LINE_W              (LINE_W),
        .DB_LATENCY          (DB_LATENCY),
        .REPLACEMENT_POLICY  (REPLACEMENT_POLICY),
        .INCLUDE_VICTIM      (INCLUDE_VICTIM),
        .VICTIM_LINES        (VICTIM_LINES),
        .INCLUDE_CBOM        (INCLUDE_CBOM),
        .C_S00_AXI_ID_WIDTH  (READ_ID_WIDTH),
        .C_S00_AXI_DATA_WIDTH(BLOCK_W),
        .C_S00_AXI_ADDR_WIDTH(32)
    ) inst (
        .s00_axi_aclk     (clk),
        .s00_axi_aresetn  (~rst),
        .m00_axi_aclk     (clk),
        .m00_axi_aresetn  (~rst),

        .grasp_high_addr_l    (32'h0),
        .grasp_high_addr_h    (32'h0),
        .grasp_moderate_addr_l(32'h0),
        .grasp_moderate_addr_h(32'h0),

        // AR (muxed flush/accelerator)
        .s00_axi_arid     (c_arid),
        .s00_axi_araddr   (c_araddr),
        .s00_axi_arlen    (c_arlen),
        .s00_axi_arsize   (c_arsize),
        .s00_axi_arburst  (c_arburst),
        .s00_axi_arlock   (c_arlock),
        .s00_axi_arcache  (c_arcache),
        .s00_axi_arprot   (c_arprot),
        .s00_axi_arqos    (c_arqos),
        .s00_axi_arregion (c_arregion),
        .s00_axi_arsnoop  (c_arsnoop),
        .s00_axi_arvalid  (c_arvalid),
        .s00_axi_arready  (c_arready),
        // R
        .s00_axi_rid      (c_rid),
        .s00_axi_rdata    (c_rdata),
        .s00_axi_rresp    (c_rresp),
        .s00_axi_rlast    (c_rlast),
        .s00_axi_rvalid   (c_rvalid),
        .s00_axi_rready   (c_rready),
        // AW (accelerator only, gated while flushing)
        .s00_axi_awid     (s_awid),
        .s00_axi_awaddr   (s_awaddr),
        .s00_axi_awlen    (s_awlen),
        .s00_axi_awsize   (s_awsize),
        .s00_axi_awburst  (s_awburst),
        .s00_axi_awlock   (s_awlock),
        .s00_axi_awcache  (s_awcache),
        .s00_axi_awprot   (s_awprot),
        .s00_axi_awqos    (s_awqos),
        .s00_axi_awregion (s_awregion),
        .s00_axi_awsnoop  (s_awsnoop),
        .s00_axi_awvalid  (s_awvalid & ~flush_active),
        .s00_axi_awready  (c_awready),
        // W
        .s00_axi_wlast    (s_wlast),
        .s00_axi_wdata    (s_wdata),
        .s00_axi_wstrb    (s_wstrb),
        .s00_axi_wvalid   (s_wvalid & ~flush_active),
        .s00_axi_wready   (c_wready),
        // B
        .s00_axi_bresp    (c_bresp),
        .s00_axi_bvalid   (c_bvalid),
        .s00_axi_bid      (c_bid),
        .s00_axi_bready   (s_bready),

        // Master AXI -> AxiRam (addr masked above)
        .m00_axi_araddr   (m_araddr_raw),
        .m00_axi_arlen    (m_arlen),
        .m00_axi_arsize   (m_arsize),
        .m00_axi_arburst  (m_arburst),
        .m00_axi_arlock   (m_arlock),
        .m00_axi_arcache  (m_arcache),
        .m00_axi_arprot   (m_arprot),
        .m00_axi_arqos    (m_arqos),
        .m00_axi_arvalid  (m_arvalid),
        .m00_axi_arready  (m_arready),
        .m00_axi_arid     (m_arid),
        .m00_axi_rvalid   (m_rvalid),
        .m00_axi_rlast    (m_rlast),
        .m00_axi_rresp    (m_rresp),
        .m00_axi_rdata    (m_rdata),
        .m00_axi_rid      (m_rid),
        .m00_axi_rready   (m_rready),
        .m00_axi_awaddr   (m_awaddr_raw),
        .m00_axi_awlen    (m_awlen),
        .m00_axi_awsize   (m_awsize),
        .m00_axi_awburst  (m_awburst),
        .m00_axi_awlock   (m_awlock),
        .m00_axi_awcache  (m_awcache),
        .m00_axi_awprot   (m_awprot),
        .m00_axi_awqos    (m_awqos),
        .m00_axi_awvalid  (m_awvalid),
        .m00_axi_awready  (m_awready),
        .m00_axi_awid     (m_awid),
        .m00_axi_wlast    (m_wlast),
        .m00_axi_wdata    (m_wdata),
        .m00_axi_wstrb    (m_wstrb),
        .m00_axi_wvalid   (m_wvalid),
        .m00_axi_wready   (m_wready),
        .m00_axi_bvalid   (m_bvalid),
        .m00_axi_bresp    (m_bresp),
        .m00_axi_bid      (m_bid),
        .m00_axi_bready   (m_bready)
    );

endmodule
