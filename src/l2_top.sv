// Copyright 2024 Chris Keilbart
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may
// not use this file except in compliance with the License, or, at your option,
// the Apache License version 2.0. You may obtain a copy of the License at
// https://solderpad.org/licenses/SHL-2.1/. Unless required by applicable law
// or agreed to in writing, any work distributed under the License is
// distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied. See the License for the specific language
// governing permissions and limitations under the License.

module l2_top

    import cache_config::*;

    #(
        //Cache configuration
        parameter logic[31:0] ADDR_L = 32'h80000000,
        parameter logic[31:0] ADDR_H = 32'hFFFFFFFF,
        parameter int WAYS = 4,
        parameter int LINES = 512, //Per way
        parameter int LINE_W = 8, //In blocks
        parameter int DB_LATENCY = 1,
        //Replacement policy
        parameter int REPLACEMENT_POLICY = 0,
        parameter logic RRIP_HP = 1, //1 for Hit Priority, 0 for Frequency Priority. The paper authors found HP to be superior in their tests
        parameter int RRPV_WIDTH = 2, //Number of bits per way. The paper authors found 2-3 to be optimal
        parameter logic RANDOM_USE_EVICT = 1, //Whether the randomly evicted way should change after each eviction or constantly
        //Victim cache
        parameter logic INCLUDE_VICTIM = 1,
        parameter int VICTIM_LINES = 8,
        //1=SDP databank (URAM-friendly, ~1-3% throughput cost); 0=TDP (default)
        parameter logic DATABANK_SDP = 0,
        //1 = register SDP URAM write-port inputs (+1 cycle write commit;
        //only meaningful with DATABANK_SDP=1).
        parameter logic SDP_WRITE_INPUT_REG = 0,
        //Length of the URAM/BRAM cascade in the databank (1..8; default 8).
        parameter int unsigned CASCADE_DEPTH = 8,

        // Parameters of Axi Slave Bus Interface S00_AXI
        parameter integer C_S00_AXI_ID_WIDTH = 4,
        parameter integer C_S00_AXI_DATA_WIDTH = 32,
        //!!!DO NOT TOUCH BEYOND THIS POINT!!!
        parameter integer C_S00_AXI_ADDR_WIDTH = 32,

        // Parameters of Axi Master Bus Interface M00_AXI
        parameter integer C_M00_AXI_ID_WIDTH = C_S00_AXI_ID_WIDTH+1,
        parameter integer C_M00_AXI_ADDR_WIDTH = C_S00_AXI_ADDR_WIDTH,
        parameter integer C_M00_AXI_DATA_WIDTH = C_S00_AXI_DATA_WIDTH,

        //User parameters required
        parameter integer C_S00_AXI_ARUSER_WIDTH = 0,
        parameter integer C_S00_AXI_AWUSER_WIDTH = 0,
        parameter integer C_S00_AXI_WUSER_WIDTH = 0,
        parameter integer C_S00_AXI_RUSER_WIDTH = 0,
        parameter integer C_S00_AXI_BUSER_WIDTH = 0
    )
    (
        input logic s00_axi_aclk,
        input logic s00_axi_aresetn,
        input logic[C_S00_AXI_ID_WIDTH-1:0] s00_axi_awid,
        input logic[C_S00_AXI_ADDR_WIDTH-1:0] s00_axi_awaddr,
        input logic[7:0] s00_axi_awlen,
        input logic[2:0] s00_axi_awsize,
        input logic[1:0] s00_axi_awburst,
        input logic s00_axi_awlock,
        input logic[3:0] s00_axi_awcache,
        input logic[2:0] s00_axi_awprot,
        input logic[3:0] s00_axi_awqos,
        input logic[3:0] s00_axi_awregion,
        input logic s00_axi_awvalid,
        output logic s00_axi_awready,
        input logic[C_S00_AXI_DATA_WIDTH-1:0] s00_axi_wdata,
        input logic[(C_S00_AXI_DATA_WIDTH/8)-1:0] s00_axi_wstrb,
        input logic s00_axi_wlast,
        input logic s00_axi_wvalid,
        output logic s00_axi_wready,
        output logic[C_S00_AXI_ID_WIDTH-1:0] s00_axi_bid,
        output logic[1:0] s00_axi_bresp,
        output logic s00_axi_bvalid,
        input logic s00_axi_bready,
        input logic[C_S00_AXI_ID_WIDTH-1:0] s00_axi_arid,
        input logic[C_S00_AXI_ADDR_WIDTH-1:0] s00_axi_araddr,
        input logic[7:0] s00_axi_arlen,
        input logic[2:0] s00_axi_arsize,
        input logic[1:0] s00_axi_arburst,
        input logic s00_axi_arlock,
        input logic[3:0] s00_axi_arcache,
        input logic[2:0] s00_axi_arprot,
        input logic[3:0] s00_axi_arqos,
        input logic[3:0] s00_axi_arregion,
        input logic s00_axi_arvalid,
        output logic s00_axi_arready,
        output logic[C_S00_AXI_ID_WIDTH-1:0] s00_axi_rid,
        output logic[C_S00_AXI_DATA_WIDTH-1:0] s00_axi_rdata,
        output logic[1:0] s00_axi_rresp,
        output logic s00_axi_rlast,
        output logic s00_axi_rvalid,
        input logic s00_axi_rready,

        // Ports of Axi Master Bus Interface M00_AXI
        input logic m00_axi_aclk, //Not used
        input logic m00_axi_aresetn, //Not used
        output logic[C_M00_AXI_ID_WIDTH-1:0] m00_axi_awid,
        output logic[C_M00_AXI_ADDR_WIDTH-1:0] m00_axi_awaddr,
        output logic[7:0] m00_axi_awlen,
        output logic[2:0] m00_axi_awsize,
        output logic[1:0] m00_axi_awburst,
        output logic m00_axi_awlock,
        output logic[3:0] m00_axi_awcache,
        output logic[2:0] m00_axi_awprot,
        output logic[3:0] m00_axi_awqos,
        output logic m00_axi_awvalid,
        input logic m00_axi_awready,
        output logic[C_M00_AXI_DATA_WIDTH-1:0] m00_axi_wdata,
        output logic[C_M00_AXI_DATA_WIDTH/8-1:0] m00_axi_wstrb,
        output logic m00_axi_wlast,
        output logic m00_axi_wvalid,
        input logic m00_axi_wready,
        input logic[C_M00_AXI_ID_WIDTH-1:0] m00_axi_bid,
        input logic[1:0] m00_axi_bresp,
        input logic m00_axi_bvalid,
        output logic m00_axi_bready,
        output logic[C_M00_AXI_ID_WIDTH-1:0] m00_axi_arid,
        output logic[C_M00_AXI_ADDR_WIDTH-1:0] m00_axi_araddr,
        output logic[7:0] m00_axi_arlen,
        output logic[2:0] m00_axi_arsize,
        output logic[1:0] m00_axi_arburst,
        output logic m00_axi_arlock,
        output logic[3:0] m00_axi_arcache,
        output logic[2:0] m00_axi_arprot,
        output logic[3:0] m00_axi_arqos,
        output logic m00_axi_arvalid,
        input logic m00_axi_arready,
        input logic[C_M00_AXI_ID_WIDTH-1:0] m00_axi_rid,
        input logic[C_M00_AXI_DATA_WIDTH-1:0] m00_axi_rdata,
        input logic[1:0] m00_axi_rresp,
        input logic m00_axi_rlast,
        input logic m00_axi_rvalid,
        output logic m00_axi_rready,

        // Runtime-configurable GRASP address region bounds (all-zero = disabled).
        // Width follows the cache address bus so external register banks size cleanly.
        input logic[C_S00_AXI_ADDR_WIDTH-1:0] grasp_high_addr_l,
        input logic[C_S00_AXI_ADDR_WIDTH-1:0] grasp_high_addr_h,
        input logic[C_S00_AXI_ADDR_WIDTH-1:0] grasp_moderate_addr_l,
        input logic[C_S00_AXI_ADDR_WIDTH-1:0] grasp_moderate_addr_h
    );

    //Input packing
    ar_t req_ar;
    logic[C_S00_AXI_ID_WIDTH-1:0] req_arid;
    logic req_arready;
    r_t req_r;
    logic[C_S00_AXI_DATA_WIDTH-1:0] req_rdata;
    logic[C_S00_AXI_ID_WIDTH-1:0] req_rid;
    logic req_rready;
    aw_t req_aw;
    logic[C_S00_AXI_ID_WIDTH-1:0] req_awid;
    logic req_awready;
    w_t req_w;
    logic[C_S00_AXI_DATA_WIDTH-1:0] req_wdata;
    logic[(C_S00_AXI_DATA_WIDTH/8)-1:0] req_wstrb;
    logic req_wready;
    b_t req_b;
    logic[C_S00_AXI_ID_WIDTH-1:0] req_bid;
    logic req_bready;

    ar_t mem_ar;
    logic[C_S00_AXI_ID_WIDTH:0] mem_arid;
    logic mem_arready;
    r_t mem_r;
    logic[C_S00_AXI_DATA_WIDTH-1:0] mem_rdata;
    logic[C_S00_AXI_ID_WIDTH:0] mem_rid;
    logic mem_rready;
    aw_t mem_aw;
    logic[C_S00_AXI_ID_WIDTH:0] mem_awid;
    logic mem_awready;
    w_t mem_w;
    logic[C_S00_AXI_DATA_WIDTH-1:0] mem_wdata;
    logic[(C_S00_AXI_DATA_WIDTH/8)-1:0] mem_wstrb;
    logic mem_wready;
    b_t mem_b;
    logic[C_S00_AXI_ID_WIDTH:0] mem_bid;
    logic mem_bready;


    //AW
    assign req_awid = s00_axi_awid;
    assign req_aw = '{
        awaddr : s00_axi_awaddr,
        awlen : s00_axi_awlen,
        awburst : s00_axi_awburst,
        awsize : s00_axi_awsize,
        awlock : s00_axi_awlock,
        awcache : s00_axi_awcache,
        awprot : s00_axi_awprot,
        awqos : s00_axi_awqos,
        awregion : s00_axi_awregion,
        awsnoop : '0,
        awvalid : s00_axi_awvalid
    };
    assign s00_axi_awready = req_awready;

    //W
    assign req_wdata = s00_axi_wdata;
    assign req_wstrb = s00_axi_wstrb;
    assign req_w.wlast = s00_axi_wlast;
    assign req_w.wvalid = s00_axi_wvalid;
    assign s00_axi_wready = req_wready;

    //B
    assign s00_axi_bid = req_bid;
    assign s00_axi_bresp = req_b.bresp;
    assign s00_axi_bvalid = req_b.bvalid;
    assign req_bready = s00_axi_bready;

    //AR
    assign req_arid = s00_axi_arid;
    assign req_ar = '{
        araddr : s00_axi_araddr,
        arlen : s00_axi_arlen,
        arburst : s00_axi_arburst,
        arsize : s00_axi_arsize,
        arlock : s00_axi_arlock,
        arcache : s00_axi_arcache,
        arprot : s00_axi_arprot,
        arqos : s00_axi_arqos,
        arregion : s00_axi_arregion,
        arvalid : s00_axi_arvalid,
        arsnoop : '0
    };
    assign s00_axi_arready = req_arready;

    //R
    assign s00_axi_rid = req_rid;
    assign s00_axi_rdata = req_rdata;
    assign s00_axi_rresp = req_r.rresp[1:0];
    assign s00_axi_rlast = req_r.rlast;
    assign s00_axi_rvalid = req_r.rvalid;
    assign req_rready = s00_axi_rready;


    //AW
    assign m00_axi_awid = mem_awid;
    assign m00_axi_awaddr = mem_aw.awaddr;
    assign m00_axi_awlen = mem_aw.awlen;
    assign m00_axi_awburst = mem_aw.awburst;
    assign m00_axi_awprot = mem_aw.awprot;
    assign m00_axi_awvalid = mem_aw.awvalid;
    assign mem_awready = m00_axi_awready;
    assign m00_axi_awlock = mem_aw.awlock;
    assign m00_axi_awqos = mem_aw.awqos;
    assign m00_axi_awcache = mem_aw.awcache;
    assign m00_axi_awsize = mem_aw.awsize;

    //W
    assign m00_axi_wdata = mem_wdata;
    assign m00_axi_wstrb = mem_wstrb;
    assign m00_axi_wlast = mem_w.wlast;
    assign m00_axi_wvalid = mem_w.wvalid;
    assign mem_wready = m00_axi_wready;

    //B
    assign mem_bid = m00_axi_bid;
    assign mem_b.bresp = m00_axi_bresp;
    assign mem_b.bvalid = m00_axi_bvalid;
    assign m00_axi_bready = mem_bready;

    //AR
    assign m00_axi_arid = mem_arid;
    assign m00_axi_araddr = mem_ar.araddr;
    assign m00_axi_arlen = mem_ar.arlen;
    assign m00_axi_arburst = mem_ar.arburst;
    assign m00_axi_arprot = mem_ar.arprot;
    assign m00_axi_arvalid = mem_ar.arvalid;
    assign mem_arready = m00_axi_arready;
    assign m00_axi_arlock = mem_ar.arlock;
    assign m00_axi_arqos = mem_ar.arqos;
    assign m00_axi_arcache = mem_ar.arcache;
    assign m00_axi_arsize = mem_ar.arsize;

    //R
    assign mem_rid = m00_axi_rid;
    assign mem_rdata = m00_axi_rdata;
    assign mem_r.rresp[1:0] = m00_axi_rresp;
    assign mem_r.rlast = m00_axi_rlast;
    assign mem_r.rvalid = m00_axi_rvalid;
    assign m00_axi_rready = mem_rready;

    l2_cache #(
        .POLICY(replacement_policy_t'(REPLACEMENT_POLICY)),
        .LINES(LINES),
        .LINE_W(LINE_W),
        .ADDR_RANGE_H(ADDR_H),
        .ADDR_RANGE_L(ADDR_L),
        .WAYS(WAYS),
        .RANDOM_USE_EVICT(RANDOM_USE_EVICT),
        .RRIP_HP(RRIP_HP),
        .RRPV_WIDTH(RRPV_WIDTH),
        .ADDR_W(C_S00_AXI_ADDR_WIDTH),
        .INCLUDE_CBOM(0),
        .INCLUDE_VICTIM(INCLUDE_VICTIM),
        .VICTIM_LINES(VICTIM_LINES),
        .DB_LATENCY(DB_LATENCY),
        .BLOCK_W(C_S00_AXI_DATA_WIDTH),
        .READ_ID_WIDTH(C_S00_AXI_ID_WIDTH),
        .WRITE_ID_WIDTH(C_S00_AXI_ID_WIDTH),
        .DATABANK_SDP(DATABANK_SDP),
        .SDP_WRITE_INPUT_REG(SDP_WRITE_INPUT_REG),
        .CASCADE_DEPTH(CASCADE_DEPTH)
    ) inst (
        .clk(s00_axi_aclk),
        .rst(~s00_axi_aresetn),
        //The AXI ports match
    .*);

endmodule
