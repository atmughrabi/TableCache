// SPDX-License-Identifier: Apache-2.0
// Wrapper that exposes the routed-netlist l2_cache's flattened
// struct-field ports (\req_ar[araddr] etc., produced by Vivado synth
// because OOC flattens packed structs) as struct-typed ports compatible
// with the source-level testbench infrastructure.
//
// Used by tb/post_pnr_smoke_tb.sv to drive the routed netlist with a
// minimum of new code on the testbench side.
`timescale 1ns/1ps

module post_pnr_l2cache_wrap
    import cache_config::*;
  (
    input  logic clk,
    input  logic rst,
    input  logic [31:0] grasp_high_addr_l,
    input  logic [31:0] grasp_high_addr_h,
    input  logic [31:0] grasp_moderate_addr_l,
    input  logic [31:0] grasp_moderate_addr_h,

    input  ar_t        req_ar,
    input  logic [3:0] req_arid,
    output logic       req_arready,
    output r_t         req_r,
    output logic [31:0] req_rdata,
    output logic [3:0]  req_rid,
    input  logic        req_rready,

    input  aw_t        req_aw,
    input  logic [3:0] req_awid,
    output logic       req_awready,
    input  w_t         req_w,
    input  logic [31:0] req_wdata,
    input  logic [3:0]  req_wstrb,
    output logic        req_wready,
    output b_t          req_b,
    output logic [3:0]  req_bid,
    input  logic        req_bready,

    output ar_t        mem_ar,
    output logic [4:0] mem_arid,
    input  logic       mem_arready,
    input  r_t         mem_r,
    input  logic [31:0] mem_rdata,
    input  logic [4:0]  mem_rid,
    output logic        mem_rready,

    output aw_t        mem_aw,
    output logic [4:0] mem_awid,
    input  logic       mem_awready,
    output w_t         mem_w,
    output logic [31:0] mem_wdata,
    output logic [3:0]  mem_wstrb,
    input  logic        mem_wready,
    input  b_t          mem_b,
    input  logic [4:0]  mem_bid,
    output logic        mem_bready
  );

    // Note the escaped-identifier port names below: Vivado flattens
    // packed-struct ports during OOC synth, producing `\req_ar[araddr]`
    // etc. The trailing space after the bracket is part of the escaped
    // name's terminator (SV LRM 5.6.1).
    l2_cache dut (
        .clk(clk),
        .rst(rst),
        .grasp_high_addr_l    (grasp_high_addr_l),
        .grasp_high_addr_h    (grasp_high_addr_h),
        .grasp_moderate_addr_l(grasp_moderate_addr_l),
        .grasp_moderate_addr_h(grasp_moderate_addr_h),

        .\req_ar[araddr]   (req_ar.araddr),
        .\req_ar[arlen]    (req_ar.arlen),
        .\req_ar[arsize]   (req_ar.arsize),
        .\req_ar[arburst]  (req_ar.arburst),
        .\req_ar[arlock]   (req_ar.arlock),
        .\req_ar[arcache]  (req_ar.arcache),
        .\req_ar[arprot]   (req_ar.arprot),
        .\req_ar[arqos]    (req_ar.arqos),
        .\req_ar[arregion] (req_ar.arregion),
        .\req_ar[arvalid]  (req_ar.arvalid),
        .\req_ar[arsnoop]  (req_ar.arsnoop),
        .req_arid          (req_arid),
        .req_arready       (req_arready),

        .\req_r[rvalid]    (req_r.rvalid),
        .\req_r[rlast]     (req_r.rlast),
        .\req_r[rresp]     (req_r.rresp),
        .req_rdata         (req_rdata),
        .req_rid           (req_rid),
        .req_rready        (req_rready),

        .\req_aw[awaddr]   (req_aw.awaddr),
        .\req_aw[awlen]    (req_aw.awlen),
        .\req_aw[awsize]   (req_aw.awsize),
        .\req_aw[awburst]  (req_aw.awburst),
        .\req_aw[awlock]   (req_aw.awlock),
        .\req_aw[awcache]  (req_aw.awcache),
        .\req_aw[awprot]   (req_aw.awprot),
        .\req_aw[awqos]    (req_aw.awqos),
        .\req_aw[awregion] (req_aw.awregion),
        .\req_aw[awsnoop]  (req_aw.awsnoop),
        .\req_aw[awvalid]  (req_aw.awvalid),
        .req_awid          (req_awid),
        .req_awready       (req_awready),

        .\req_w[wlast]     (req_w.wlast),
        .\req_w[wvalid]    (req_w.wvalid),
        .req_wdata         (req_wdata),
        .req_wstrb         (req_wstrb),
        .req_wready        (req_wready),

        .\req_b[bresp]     (req_b.bresp),
        .\req_b[bvalid]    (req_b.bvalid),
        .req_bid           (req_bid),
        .req_bready        (req_bready),

        .\mem_ar[araddr]   (mem_ar.araddr),
        .\mem_ar[arlen]    (mem_ar.arlen),
        .\mem_ar[arsize]   (mem_ar.arsize),
        .\mem_ar[arburst]  (mem_ar.arburst),
        .\mem_ar[arlock]   (mem_ar.arlock),
        .\mem_ar[arcache]  (mem_ar.arcache),
        .\mem_ar[arprot]   (mem_ar.arprot),
        .\mem_ar[arqos]    (mem_ar.arqos),
        .\mem_ar[arregion] (mem_ar.arregion),
        .\mem_ar[arvalid]  (mem_ar.arvalid),
        .\mem_ar[arsnoop]  (mem_ar.arsnoop),
        .mem_arid          (mem_arid),
        .mem_arready       (mem_arready),

        .\mem_r[rvalid]    (mem_r.rvalid),
        .\mem_r[rlast]     (mem_r.rlast),
        .\mem_r[rresp]     (mem_r.rresp),
        .mem_rdata         (mem_rdata),
        .mem_rid           (mem_rid),
        .mem_rready        (mem_rready),

        .\mem_aw[awaddr]   (mem_aw.awaddr),
        .\mem_aw[awlen]    (mem_aw.awlen),
        .\mem_aw[awsize]   (mem_aw.awsize),
        .\mem_aw[awburst]  (mem_aw.awburst),
        .\mem_aw[awlock]   (mem_aw.awlock),
        .\mem_aw[awcache]  (mem_aw.awcache),
        .\mem_aw[awprot]   (mem_aw.awprot),
        .\mem_aw[awqos]    (mem_aw.awqos),
        .\mem_aw[awregion] (mem_aw.awregion),
        .\mem_aw[awsnoop]  (mem_aw.awsnoop),
        .\mem_aw[awvalid]  (mem_aw.awvalid),
        .mem_awid          (mem_awid),
        .mem_awready       (mem_awready),

        .\mem_w[wlast]     (mem_w.wlast),
        .\mem_w[wvalid]    (mem_w.wvalid),
        .mem_wdata         (mem_wdata),
        .mem_wstrb         (mem_wstrb),
        .mem_wready        (mem_wready),

        .\mem_b[bresp]     (mem_b.bresp),
        .\mem_b[bvalid]    (mem_b.bvalid),
        .mem_bid           (mem_bid),
        .mem_bready        (mem_bready)
    );
endmodule
