// SPDX-License-Identifier: Apache-2.0
// Cocotbext-axi compatible wrapper around l2_top.
// Exposes the s00_axi_*/m00_axi_* AXI4 buses as s_*/m_* (matching the
// dut_cocotb.sv convention used by the rest of the cocotb regression),
// so existing helpers (attach_master / attach_mem in tb_common.py)
// work without code changes.
//
// Used by test_l2top.py to cover the l2_top wrapper directly --
// before this, every cocotb test went through dut_*.sv wrappers that
// instantiate l2_cache, so l2_top's parameter casting + port
// forwarding + .* connection were only validated at synth time.
`timescale 1ns/1ps

module dut_l2top
    #(
`ifdef TC_LINES
        parameter int LINES   = `TC_LINES,
`else
        parameter int LINES   = 64,
`endif
`ifdef TC_LINE_W
        parameter int LINE_W  = `TC_LINE_W,
`else
        parameter int LINE_W  = 8,
`endif
`ifdef TC_WAYS
        parameter int WAYS    = `TC_WAYS,
`else
        parameter int WAYS    = 4,
`endif
`ifdef TC_BLOCK_W
        parameter int BLOCK_W = `TC_BLOCK_W,
`else
        parameter int BLOCK_W = 32,
`endif
`ifdef TC_ID_W
        parameter int READ_ID_WIDTH  = `TC_ID_W,
        parameter int WRITE_ID_WIDTH = `TC_ID_W,
`else
        parameter int READ_ID_WIDTH  = 4,
        parameter int WRITE_ID_WIDTH = 4,
`endif
`ifdef TC_M_ID_W
        parameter int M_ID_WIDTH = `TC_M_ID_W,
`else
        parameter int M_ID_WIDTH = READ_ID_WIDTH + 1,
`endif
`ifdef TC_ADDR_W
        parameter int ADDR_W = `TC_ADDR_W,
`else
        parameter int ADDR_W = 32,
`endif
`ifdef TC_ADDR_L
        parameter logic [ADDR_W-1:0] ADDR_RANGE_L = `TC_ADDR_L,
`else
        parameter logic [ADDR_W-1:0] ADDR_RANGE_L = ADDR_W'(64'h8000_0000),
`endif
`ifdef TC_ADDR_H
        parameter logic [ADDR_W-1:0] ADDR_RANGE_H = `TC_ADDR_H,
`else
        parameter logic [ADDR_W-1:0] ADDR_RANGE_H = ADDR_W'(64'hFFFF_FFFF),
`endif
`ifdef TC_POLICY_INT
        parameter int REPLACEMENT_POLICY = `TC_POLICY_INT,
`else
        parameter int REPLACEMENT_POLICY = 0,
`endif
        parameter logic INCLUDE_VICTIM = 0,
`ifdef TC_VICTIM_LINES
        parameter int VICTIM_LINES = `TC_VICTIM_LINES,
`else
        parameter int VICTIM_LINES = 8,
`endif
`ifdef TC_CASCADE_DEPTH
        parameter int CASCADE_DEPTH = `TC_CASCADE_DEPTH,
`else
        parameter int CASCADE_DEPTH = 8,
`endif
`ifdef TC_DATABANK_SDP
        parameter logic DATABANK_SDP = `TC_DATABANK_SDP,
`else
        parameter logic DATABANK_SDP = 0,
`endif
`ifdef TC_SDP_WRITE_INPUT_REG
        parameter logic SDP_WRITE_INPUT_REG = `TC_SDP_WRITE_INPUT_REG,
`else
        parameter logic SDP_WRITE_INPUT_REG = 0,
`endif
`ifdef TC_N_BANKS
        parameter int N_BANKS = `TC_N_BANKS,
`else
        parameter int N_BANKS = 1,
`endif
`ifdef TC_DB_LATENCY
        parameter int DB_LATENCY = `TC_DB_LATENCY
`else
        parameter int DB_LATENCY = 1
`endif
    ) (
        input  logic clk,
        input  logic rst,

        // Slave (request) port -- s_* mirror of s00_axi_*
        input  logic [ADDR_W-1:0]            s_araddr,
        input  logic [7:0]                   s_arlen,
        input  logic [2:0]                   s_arsize,
        input  logic [1:0]                   s_arburst,
        input  logic                         s_arlock,
        input  logic [3:0]                   s_arcache,
        input  logic [2:0]                   s_arprot,
        input  logic [3:0]                   s_arqos,
        input  logic [3:0]                   s_arregion,
        input  logic [3:0]                   s_arsnoop,
        input  logic                         s_arvalid,
        output logic                         s_arready,
        input  logic [READ_ID_WIDTH-1:0]     s_arid,
        output logic                         s_rvalid,
        output logic                         s_rlast,
        output logic [1:0]                   s_rresp,
        output logic [BLOCK_W-1:0]           s_rdata,
        output logic [READ_ID_WIDTH-1:0]     s_rid,
        input  logic                         s_rready,
        input  logic [ADDR_W-1:0]            s_awaddr,
        input  logic [7:0]                   s_awlen,
        input  logic [2:0]                   s_awsize,
        input  logic [1:0]                   s_awburst,
        input  logic                         s_awlock,
        input  logic [3:0]                   s_awcache,
        input  logic [2:0]                   s_awprot,
        input  logic [3:0]                   s_awqos,
        input  logic [3:0]                   s_awregion,
        input  logic [2:0]                   s_awsnoop,
        input  logic                         s_awvalid,
        output logic                         s_awready,
        input  logic [WRITE_ID_WIDTH-1:0]    s_awid,
        input  logic                         s_wlast,
        input  logic [BLOCK_W-1:0]           s_wdata,
        input  logic [BLOCK_W/8-1:0]         s_wstrb,
        input  logic                         s_wvalid,
        output logic                         s_wready,
        output logic [1:0]                   s_bresp,
        output logic                         s_bvalid,
        output logic [WRITE_ID_WIDTH-1:0]    s_bid,
        input  logic                         s_bready,

        // Master (memory) port -- m_* mirror of m00_axi_*
        output logic [ADDR_W-1:0]            m_araddr,
        output logic [7:0]                   m_arlen,
        output logic [2:0]                   m_arsize,
        output logic [1:0]                   m_arburst,
        output logic                         m_arlock,
        output logic [3:0]                   m_arcache,
        output logic [2:0]                   m_arprot,
        output logic [3:0]                   m_arqos,
        output logic                         m_arvalid,
        input  logic                         m_arready,
        output logic [M_ID_WIDTH-1:0]        m_arid,
        input  logic                         m_rvalid,
        input  logic                         m_rlast,
        input  logic [1:0]                   m_rresp,
        input  logic [BLOCK_W-1:0]           m_rdata,
        input  logic [M_ID_WIDTH-1:0]        m_rid,
        output logic                         m_rready,
        output logic [ADDR_W-1:0]            m_awaddr,
        output logic [7:0]                   m_awlen,
        output logic [2:0]                   m_awsize,
        output logic [1:0]                   m_awburst,
        output logic                         m_awlock,
        output logic [3:0]                   m_awcache,
        output logic [2:0]                   m_awprot,
        output logic [3:0]                   m_awqos,
        output logic                         m_awvalid,
        input  logic                         m_awready,
        output logic [M_ID_WIDTH-1:0]        m_awid,
        output logic                         m_wlast,
        output logic [BLOCK_W-1:0]           m_wdata,
        output logic [BLOCK_W/8-1:0]         m_wstrb,
        output logic                         m_wvalid,
        input  logic                         m_wready,
        input  logic                         m_bvalid,
        input  logic [1:0]                   m_bresp,
        input  logic [M_ID_WIDTH-1:0]        m_bid,
        output logic                         m_bready
    );

    // GRASP region ports tied off (SRRIP-FP fallback; integration smoke).
    wire [ADDR_W-1:0] grasp_high_addr_l     = '0;
    wire [ADDR_W-1:0] grasp_high_addr_h     = '0;
    wire [ADDR_W-1:0] grasp_moderate_addr_l = '0;
    wire [ADDR_W-1:0] grasp_moderate_addr_h = '0;

    l2_top #(
        .ADDR_L              (ADDR_RANGE_L),
        .ADDR_H              (ADDR_RANGE_H),
        .WAYS                (WAYS),
        .LINES               (LINES),
        .LINE_W              (LINE_W),
        .DB_LATENCY          (DB_LATENCY),
        .REPLACEMENT_POLICY  (REPLACEMENT_POLICY),
        .INCLUDE_VICTIM      (INCLUDE_VICTIM),
        .VICTIM_LINES        (VICTIM_LINES),
        .CASCADE_DEPTH       (CASCADE_DEPTH),
        .DATABANK_SDP        (DATABANK_SDP),
        .SDP_WRITE_INPUT_REG (SDP_WRITE_INPUT_REG),
        .N_BANKS             (N_BANKS),
        .C_S00_AXI_ID_WIDTH  (READ_ID_WIDTH),
        .C_M00_AXI_ID_WIDTH  (M_ID_WIDTH),
        .C_S00_AXI_DATA_WIDTH(BLOCK_W),
        .C_S00_AXI_ADDR_WIDTH(ADDR_W),
        .C_M00_AXI_ADDR_WIDTH(ADDR_W)
    ) inst (
        // Clock + active-low reset (l2_top expects aresetn)
        .s00_axi_aclk     (clk),
        .s00_axi_aresetn  (~rst),
        .m00_axi_aclk     (clk),
        .m00_axi_aresetn  (~rst),

        .grasp_high_addr_l    (grasp_high_addr_l),
        .grasp_high_addr_h    (grasp_high_addr_h),
        .grasp_moderate_addr_l(grasp_moderate_addr_l),
        .grasp_moderate_addr_h(grasp_moderate_addr_h),

        // ACE snoop sidebands are top-level signals so directed tests can
        // exercise CBOM and WriteEvict; reset_dut ties them to zero by default.
        .s00_axi_arsnoop  (s_arsnoop),
        .s00_axi_awsnoop  (s_awsnoop),
        .s00_axi_araddr   (s_araddr),
        .s00_axi_arlen    (s_arlen),
        .s00_axi_arsize   (s_arsize),
        .s00_axi_arburst  (s_arburst),
        .s00_axi_arlock   (s_arlock),
        .s00_axi_arcache  (s_arcache),
        .s00_axi_arprot   (s_arprot),
        .s00_axi_arqos    (s_arqos),
        .s00_axi_arregion (s_arregion),
        .s00_axi_arvalid  (s_arvalid),
        .s00_axi_arready  (s_arready),
        .s00_axi_arid     (s_arid),
        .s00_axi_rvalid   (s_rvalid),
        .s00_axi_rlast    (s_rlast),
        .s00_axi_rresp    (s_rresp),
        .s00_axi_rdata    (s_rdata),
        .s00_axi_rid      (s_rid),
        .s00_axi_rready   (s_rready),
        .s00_axi_awaddr   (s_awaddr),
        .s00_axi_awlen    (s_awlen),
        .s00_axi_awsize   (s_awsize),
        .s00_axi_awburst  (s_awburst),
        .s00_axi_awlock   (s_awlock),
        .s00_axi_awcache  (s_awcache),
        .s00_axi_awprot   (s_awprot),
        .s00_axi_awqos    (s_awqos),
        .s00_axi_awregion (s_awregion),
        .s00_axi_awvalid  (s_awvalid),
        .s00_axi_awready  (s_awready),
        .s00_axi_awid     (s_awid),
        .s00_axi_wlast    (s_wlast),
        .s00_axi_wdata    (s_wdata),
        .s00_axi_wstrb    (s_wstrb),
        .s00_axi_wvalid   (s_wvalid),
        .s00_axi_wready   (s_wready),
        .s00_axi_bresp    (s_bresp),
        .s00_axi_bvalid   (s_bvalid),
        .s00_axi_bid      (s_bid),
        .s00_axi_bready   (s_bready),

        // Master AXI
        .m00_axi_araddr   (m_araddr),
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
        .m00_axi_awaddr   (m_awaddr),
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

    axi4_protocol_checker #(
        .ADDR_W                  (ADDR_W),
        .DATA_W                  (BLOCK_W),
        .ID_W                    (M_ID_WIDTH),
        .CHECK_B1_RESPONSE_VALID (1'b0),
        .CHECK_RESPONSE_STABILITY(1'b0)
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
