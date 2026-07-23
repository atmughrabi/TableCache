// SPDX-License-Identifier: Apache-2.0
// Standalone DUT wrapper for tc_narrow_shim verification.
//   slave  port s_*  : narrow AXI4 (NARROW_W bits)  <- cocotb AxiMaster
//   master port m_*  : wide   AXI4 (BLOCK_W bits)   <- cocotb AxiRam
// l2_cache is NOT in the loop here; this is shim-only sanity. Once
// BLOCK_W=BLOCK_W is verified end-to-end in l2_cache, swap AxiRam for the
// cache + memory chain.
`timescale 1ns/1ps

module dut_shim_only
    #(
`ifdef TC_NARROW_W
        parameter int NARROW_W           = `TC_NARROW_W,
`else
        parameter int NARROW_W           = 32,
`endif
`ifdef TC_BLOCK_W
        parameter int BLOCK_W            = `TC_BLOCK_W,
`else
        parameter int BLOCK_W            = 512,
`endif
`ifdef TC_ID_W
        parameter int ID_W               = `TC_ID_W,
`else
        parameter int ID_W               = 4,
`endif
`ifdef TC_ADDR_W
        parameter int ADDR_W             = `TC_ADDR_W,
`else
        parameter int ADDR_W             = 32,
`endif
`ifdef TC_MAX_OUTSTANDING_W
        parameter int MAX_OUTSTANDING_W  = `TC_MAX_OUTSTANDING_W,
`else
        parameter int MAX_OUTSTANDING_W  = 16,
`endif
`ifdef TC_DISABLE_LINE_BUFFER
        parameter bit ENABLE_LINE_BUFFER = 1'b0,
`else
        parameter bit ENABLE_LINE_BUFFER = 1'b1,
`endif
`ifdef TC_PROMOTE_WMISS
        parameter bit PROMOTE_WMISS_TO_RW = 1'b1
`else
        parameter bit PROMOTE_WMISS_TO_RW = 1'b0
`endif
    ) (
        input  logic clk,
        input  logic rst,

        // ----- narrow slave (cocotb AxiMaster) -----
        input  logic [ADDR_W-1:0]         s_araddr,
        input  logic [7:0]                s_arlen,
        input  logic [2:0]                s_arsize,
        input  logic [1:0]                s_arburst,
        input  logic                      s_arlock,
        input  logic [3:0]                s_arcache,
        input  logic [2:0]                s_arprot,
        input  logic [3:0]                s_arqos,
        input  logic [3:0]                s_arregion,
        input  logic [ID_W-1:0]           s_arid,
        input  logic                      s_arvalid,
        output logic                      s_arready,

        output logic [NARROW_W-1:0]       s_rdata,
        output logic [1:0]                s_rresp,
        output logic                      s_rlast,
        output logic [ID_W-1:0]           s_rid,
        output logic                      s_rvalid,
        input  logic                      s_rready,

        input  logic [ADDR_W-1:0]         s_awaddr,
        input  logic [7:0]                s_awlen,
        input  logic [2:0]                s_awsize,
        input  logic [1:0]                s_awburst,
        input  logic                      s_awlock,
        input  logic [3:0]                s_awcache,
        input  logic [2:0]                s_awprot,
        input  logic [3:0]                s_awqos,
        input  logic [3:0]                s_awregion,
        input  logic [ID_W-1:0]           s_awid,
        input  logic                      s_awvalid,
        output logic                      s_awready,

        input  logic [NARROW_W-1:0]       s_wdata,
        input  logic [NARROW_W/8-1:0]     s_wstrb,
        input  logic                      s_wlast,
        input  logic                      s_wvalid,
        output logic                      s_wready,

        output logic [1:0]                s_bresp,
        output logic [ID_W-1:0]           s_bid,
        output logic                      s_bvalid,
        input  logic                      s_bready,

        // ----- wide master (cocotb AxiRam) -----
        output logic [ADDR_W-1:0]         m_araddr,
        output logic [7:0]                m_arlen,
        output logic [2:0]                m_arsize,
        output logic [1:0]                m_arburst,
        output logic                      m_arlock,
        output logic [3:0]                m_arcache,
        output logic [2:0]                m_arprot,
        output logic [3:0]                m_arqos,
        output logic [3:0]                m_arregion,
        output logic [ID_W-1:0]           m_arid,
        output logic                      m_arvalid,
        input  logic                      m_arready,

        input  logic [BLOCK_W-1:0]        m_rdata,
        input  logic [1:0]                m_rresp,
        input  logic                      m_rlast,
        input  logic [ID_W-1:0]           m_rid,
        input  logic                      m_rvalid,
        output logic                      m_rready,

        output logic [ADDR_W-1:0]         m_awaddr,
        output logic [7:0]                m_awlen,
        output logic [2:0]                m_awsize,
        output logic [1:0]                m_awburst,
        output logic                      m_awlock,
        output logic [3:0]                m_awcache,
        output logic [2:0]                m_awprot,
        output logic [3:0]                m_awqos,
        output logic [3:0]                m_awregion,
        output logic [ID_W-1:0]           m_awid,
        output logic                      m_awvalid,
        input  logic                      m_awready,

        output logic [BLOCK_W-1:0]        m_wdata,
        output logic [BLOCK_W/8-1:0]      m_wstrb,
        output logic                      m_wlast,
        output logic                      m_wvalid,
        input  logic                      m_wready,

        input  logic [1:0]                m_bresp,
        input  logic [ID_W-1:0]           m_bid,
        input  logic                      m_bvalid,
        output logic                      m_bready
    );

    // Static AXI sidebands the shim doesn't touch
    assign m_arlock   = 1'b0;
    assign m_arcache  = 4'b1111;
    assign m_arprot   = 3'b000;
    assign m_arqos    = 4'b0000;
    assign m_arregion = 4'b0000;
    assign m_awlock   = 1'b0;
    assign m_awcache  = 4'b1111;
    assign m_awprot   = 3'b000;
    assign m_awqos    = 4'b0000;
    assign m_awregion = 4'b0000;

    // snoop pins are not exposed on AxiRam, so we just don't propagate them
    // to the master (shim does its own snoop munging on the slave side).
    // For shim-only testing the test should drive s_arsnoop=0, s_awsnoop=0.
    tc_narrow_shim #(
        .NARROW_W           (NARROW_W),
        .BLOCK_W            (BLOCK_W),
        .ID_W               (ID_W),
        .ADDR_W             (ADDR_W),
        .MAX_OUTSTANDING_W  (MAX_OUTSTANDING_W),
        .ENABLE_LINE_BUFFER (ENABLE_LINE_BUFFER),
        .PROMOTE_WMISS_TO_RW(PROMOTE_WMISS_TO_RW)
    ) shim (
        .clk(clk), .rst(rst),

        .s_araddr(s_araddr), .s_arlen(s_arlen), .s_arsize(s_arsize),
        .s_arburst(s_arburst), .s_arsnoop(4'd0), .s_arid(s_arid),
        .s_arvalid(s_arvalid), .s_arready(s_arready),

        .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rlast(s_rlast),
        .s_rid(s_rid), .s_rvalid(s_rvalid), .s_rready(s_rready),

        .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awsize(s_awsize),
        .s_awburst(s_awburst), .s_awsnoop(3'd0), .s_awid(s_awid),
        .s_awvalid(s_awvalid), .s_awready(s_awready),

        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
        .s_wvalid(s_wvalid), .s_wready(s_wready),

        .s_bresp(s_bresp), .s_bid(s_bid), .s_bvalid(s_bvalid),
        .s_bready(s_bready),

        .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize),
        .m_arburst(m_arburst), .m_arsnoop(), .m_arid(m_arid),
        .m_arvalid(m_arvalid), .m_arready(m_arready),

        .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast),
        .m_rid(m_rid), .m_rvalid(m_rvalid), .m_rready(m_rready),

        .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize),
        .m_awburst(m_awburst), .m_awsnoop(), .m_awid(m_awid),
        .m_awvalid(m_awvalid), .m_awready(m_awready),

        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast),
        .m_wvalid(m_wvalid), .m_wready(m_wready),

        .m_bresp(m_bresp), .m_bid(m_bid), .m_bvalid(m_bvalid),
        .m_bready(m_bready)
    );

    // ------------------------------------------------------------------
    // AXI4 protocol checkers on narrow + wide sides of the shim.
    // ------------------------------------------------------------------
    logic [31:0] pc_violations_s, pc_violations_m;
    wire  [31:0] pc_violations_total = pc_violations_s + pc_violations_m;

    // pc_slave watches the narrow side of the shim, driven by cocotbext-axi
    // AxiMaster. Disable C6 (AxiMaster v0.1.28 WLAST timing quirk on narrow
    // bursts) and B1_RESPONSE_VALID (the shim's s_rvalid is a combinational
    // reflection of m_rvalid, which is in turn driven by AxiRam — AxiRam does
    // not synchronously gate r_valid during reset, so this would fire on the
    // shim's pass-through path even though the shim's RTL is correct).
    axi4_protocol_checker #(
        .ADDR_W                  (ADDR_W),
        .DATA_W                  (NARROW_W),
        .ID_W                    (ID_W),
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

    // pc_mem watches the shim's wide-side output going to cocotbext-axi
    // AxiRam. Disable B1_RESPONSE_VALID (AxiRam reset quirk) — every other
    // rule still fires on this checker.
    axi4_protocol_checker #(
        .ADDR_W                  (ADDR_W),
        .DATA_W                  (BLOCK_W),
        .ID_W                    (ID_W),
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
