// SPDX-License-Identifier: Apache-2.0
// Flat-signal wrapper around l2_cache for cocotbext-axi compatibility.
// Slave port (s_*): cocotb AxiMaster drives requests INTO the cache.
// Master port (m_*): cocotb AxiRam responds to memory traffic FROM the cache.
// Snoop sidebands (s_arsnoop, s_awsnoop) are top-level inputs driven by the test.
`timescale 1ns/1ps

module dut_cocotb
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
        parameter int BLOCK_W   = 32,
`ifdef TC_READ_ID_W
        parameter int READ_ID_WIDTH  = `TC_READ_ID_W,
`elsif TC_ID_W
        parameter int READ_ID_WIDTH  = `TC_ID_W,
`else
        parameter int READ_ID_WIDTH  = 4,
`endif
`ifdef TC_WRITE_ID_W
        parameter int WRITE_ID_WIDTH = `TC_WRITE_ID_W,
`elsif TC_ID_W
        parameter int WRITE_ID_WIDTH = `TC_ID_W,
`else
        parameter int WRITE_ID_WIDTH = 4,
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
`ifdef TC_VICTIM_LINES
        parameter int VICTIM_LINES = `TC_VICTIM_LINES,
`else
        parameter int VICTIM_LINES = 8,
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
        parameter int unsigned N_BANKS = `TC_N_BANKS,
`else
        parameter int unsigned N_BANKS = 1,
`endif
`ifdef TC_CASCADE_DEPTH
        parameter int unsigned CASCADE_DEPTH = `TC_CASCADE_DEPTH,
`else
        parameter int unsigned CASCADE_DEPTH = 8,
`endif
`ifdef TC_GRASP_HIGH_REGIONS
        parameter int unsigned GRASP_HIGH_REGIONS = `TC_GRASP_HIGH_REGIONS,
`else
        parameter int unsigned GRASP_HIGH_REGIONS = 1,
`endif
`ifdef TC_GRASP_MODERATE_REGIONS
        parameter int unsigned GRASP_MODERATE_REGIONS = `TC_GRASP_MODERATE_REGIONS
`else
        parameter int unsigned GRASP_MODERATE_REGIONS = 1
`endif
    ) (
        input  logic clk,
        input  logic rst,

        // ===== Slave AXI/ACE port (cocotb master drives the cache) =====
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

        // ===== Master AXI port (cache talks to memory, cocotb AxiRam responds) =====
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

        // Runtime-configurable GRASP address region bounds.
        // Drive to zero when not in use (SRRIP-FP fallback). Window i
        // occupies bits [i*ADDR_W +: ADDR_W].
        input  logic [GRASP_HIGH_REGIONS*ADDR_W-1:0]      grasp_high_addr_l,
        input  logic [GRASP_HIGH_REGIONS*ADDR_W-1:0]      grasp_high_addr_h,
        input  logic [GRASP_MODERATE_REGIONS*ADDR_W-1:0]  grasp_moderate_addr_l,
        input  logic [GRASP_MODERATE_REGIONS*ADDR_W-1:0]  grasp_moderate_addr_h,

        // Debug: the FULL reconstructed mem-side addresses BEFORE the MEM_MASK
        // fold below. Exposed so a testbench monitor can verify absolute address
        // reconstruction (OMITTED_CONSTANT high bits) that MEM_MASK would hide.
        output logic [ADDR_W-1:0]                     dbg_m_araddr_full,
        output logic [ADDR_W-1:0]                     dbg_m_awaddr_full
    );

    // -- Slave-side: pack flat signals into ar_t/aw_t/w_t structs --
    ar_t s_ar;
    aw_t s_aw;
    w_t  s_w;
    r_t  s_r;
    b_t  s_b;
    assign s_ar = '{
        araddr:   s_araddr, arlen:   s_arlen, arsize:  s_arsize,
        arburst:  s_arburst, arlock: s_arlock, arcache: s_arcache,
        arprot:   s_arprot, arqos:   s_arqos, arregion: s_arregion,
        arvalid:  s_arvalid, arsnoop: s_arsnoop
    };
    assign s_aw = '{
        awaddr:   s_awaddr, awlen:   s_awlen, awsize:  s_awsize,
        awburst:  s_awburst, awlock: s_awlock, awcache: s_awcache,
        awprot:   s_awprot, awqos:   s_awqos, awregion: s_awregion,
        awsnoop:  s_awsnoop, awvalid: s_awvalid
    };
    assign s_w = '{ wlast: s_wlast, wvalid: s_wvalid };
    assign s_rvalid = s_r.rvalid;
    assign s_rlast  = s_r.rlast;
    assign s_rresp  = s_r.rresp[1:0];   // expose AXI4 portion (drop ACE bits)
    assign s_bvalid = s_b.bvalid;
    assign s_bresp  = s_b.bresp;

    // -- Master-side: unpack ar_t/aw_t/w_t into flat outputs --
    // Mask mem addresses to a 128 MiB window so AxiRam can be small but big
    // enough for realistic graph-style workloads (50-100 MB hot/cold pool).
    // Cache's address space is [0x80000000, 0xFFFFFFFF]; we map low 27 bits to RAM.
    localparam logic [ADDR_W-1:0] MEM_MASK = ADDR_W'(32'h07FF_FFFF);
    ar_t m_ar;
    aw_t m_aw;
    w_t  m_w;
    r_t  m_r;
    b_t  m_b;
    assign m_araddr   = m_ar.araddr[ADDR_W-1:0] & MEM_MASK;
    assign dbg_m_araddr_full = m_ar.araddr[ADDR_W-1:0]; // pre-mask
    assign dbg_m_awaddr_full = m_aw.awaddr[ADDR_W-1:0]; // pre-mask
    assign m_arlen    = m_ar.arlen;
    assign m_arsize   = m_ar.arsize;
    assign m_arburst  = m_ar.arburst;
    assign m_arlock   = m_ar.arlock;
    assign m_arcache  = m_ar.arcache;
    assign m_arprot   = m_ar.arprot;
    assign m_arqos    = m_ar.arqos;
    assign m_arregion = m_ar.arregion;
    assign m_arvalid  = m_ar.arvalid;
    assign m_awaddr   = m_aw.awaddr[ADDR_W-1:0] & MEM_MASK;
    assign m_awlen    = m_aw.awlen;
    assign m_awsize   = m_aw.awsize;
    assign m_awburst  = m_aw.awburst;
    assign m_awlock   = m_aw.awlock;
    assign m_awcache  = m_aw.awcache;
    assign m_awprot   = m_aw.awprot;
    assign m_awqos    = m_aw.awqos;
    assign m_awregion = m_aw.awregion;
    assign m_awvalid  = m_aw.awvalid;
    assign m_wvalid   = m_w.wvalid;
    assign m_wlast    = m_w.wlast;
    assign m_r = '{ rvalid: m_rvalid, rlast: m_rlast, rresp: {2'b00, m_rresp} };
    assign m_b = '{ bvalid: m_bvalid, bresp: m_bresp };

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
        .VICTIM_LINES   (VICTIM_LINES),
        .DATABANK_SDP   (DATABANK_SDP),
        .SDP_WRITE_INPUT_REG (SDP_WRITE_INPUT_REG),
        .CASCADE_DEPTH  (CASCADE_DEPTH),
        .N_BANKS        (N_BANKS),
        .GRASP_HIGH_REGIONS     (GRASP_HIGH_REGIONS),
        .GRASP_MODERATE_REGIONS (GRASP_MODERATE_REGIONS)
    ) dut (
        .clk(clk), .rst(rst),
        .grasp_high_addr_l(grasp_high_addr_l),
        .grasp_high_addr_h(grasp_high_addr_h),
        .grasp_moderate_addr_l(grasp_moderate_addr_l),
        .grasp_moderate_addr_h(grasp_moderate_addr_h),
        .req_ar(s_ar), .req_arid(s_arid), .req_arready(s_arready),
        .req_r(s_r),  .req_rdata(s_rdata), .req_rid(s_rid), .req_rready(s_rready),
        .req_aw(s_aw), .req_awid(s_awid), .req_awready(s_awready),
        .req_w(s_w),  .req_wdata(s_wdata), .req_wstrb(s_wstrb), .req_wready(s_wready),
        .req_b(s_b),  .req_bid(s_bid),    .req_bready(s_bready),

        .mem_ar(m_ar), .mem_arid(m_arid), .mem_arready(m_arready),
        .mem_r(m_r),   .mem_rdata(m_rdata), .mem_rid(m_rid), .mem_rready(m_rready),
        .mem_aw(m_aw), .mem_awid(m_awid), .mem_awready(m_awready),
        .mem_w(m_w),   .mem_wdata(m_wdata), .mem_wstrb(m_wstrb), .mem_wready(m_wready),
        .mem_b(m_b),   .mem_bid(m_bid),    .mem_bready(m_bready)
    );

    // ------------------------------------------------------------------
    // AXI4 protocol checkers (sim-only). One on each side of the cache.
    // Violations emit $error("AXI_PC_VIOLATION ...") which Verilator
    // prefixes with %Error so the regression bash grep catches them.
    // ------------------------------------------------------------------
    logic [31:0] pc_violations_s, pc_violations_m;
    wire  [31:0] pc_violations_total = pc_violations_s + pc_violations_m;

    // Master side is driven by cocotbext-axi AxiMaster (v0.1.28). Two known
    // quirks shifted false positives during the first PC run:
    //   * AxiMaster asserts WLAST on beat 1 of multi-beat narrow-data bursts
    //     instead of the final beat (the cache correctly ignores WLAST and
    //     uses AWLEN to count beats, so functional tests still pass).
    // Disable C6 here so the regression baseline is clean; C6 stays active on
    // pc_mem to catch any cache-driven WLAST regression.
    // Per ID: one active request, one input skid, and l2_cache's two-slot
    // output FIFO. Writes have no corresponding output FIFO.
    axi4_protocol_checker #(
        .ADDR_W        (ADDR_W),
        .DATA_W        (BLOCK_W),
        .ID_W          (READ_ID_WIDTH),   // = WRITE_ID_WIDTH on this DUT
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

    // Mem-side ID width is READ_ID_WIDTH+1 (cache extends by 1 bit). Use a
    // single ID_W large enough for both AR and AW IDs.
    //
    // pc_mem watches the cache's m_* output going to cocotbext-axi AxiRam.
    // AxiRam does not synchronously gate r_valid/b_valid through reset,
    // which produces B1 false positives on the response channels. Keep B1
    // on the master-driven AR/AW/W channels (where it would catch a real
    // cache RTL regression) but suppress B1 on RVALID/BVALID.
    axi4_protocol_checker #(
        .ADDR_W                  (ADDR_W),
        .DATA_W                  (BLOCK_W),
        .ID_W                    (READ_ID_WIDTH + 1),
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
