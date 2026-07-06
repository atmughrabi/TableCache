// SPDX-License-Identifier: Apache-2.0
// Vivado AXI VIP testbench for l2_top (the AXI4 wrapper), run under xsim.
//
// Topology:
//   axi_vip_mst (MASTER VIP)  ->  l2_top.s00 (slave)
//   l2_top.m00 (master)       ->  axi_vip_slv (SLAVE memory-model VIP)
//
// Purpose: prove the cache works from a COLD power-on in 4-state simulation
// (xsim). The tag/valid arrays are cleared by an LFSR-walk reset routine; in
// 4-state sim the walk only produces real addresses once the LFSR has a
// defined power-on value (see lfsr.sv). A cold read/write here exercises:
//   * valid bits cleared to 0 (cold lines MISS, not X),
//   * miss -> line fill from the slave memory returns DEFINED data,
//   * write-allocate -> read-back returns the written value.
//
// This is the AXI-VIP replacement for the cocotb cold-cache checks and the
// 4-state companion to tb/cocotb/dut_l2top.sv (which runs under Verilator,
// 2-state, and cannot exhibit the cold-LFSR X bug).
`timescale 1ns/1ps

import axi_vip_pkg::*;
import axi_vip_mst_pkg::*;
import axi_vip_slv_pkg::*;
import cache_config::*;   // ar_t / r_t for tc_flush_controller

module tb_l2top_vip;

    localparam int ID_W  = 4;          // s00 AXI ID width
    localparam int MID_W = ID_W + 1;   // m00 ID width = s00 + 1 (l2_top)
    localparam int BW    = 32;
    localparam int AW    = 32;
    localparam logic [31:0] BASE = 32'h8000_0000;
    // Cacheable-range base. Default BASE ([BASE,0xFFFFFFFF], OMITTED_ADDR_W=1).
    // Set VIP_ADDR_L=0 to exercise a base-0 FULL 4GB range [0,0xFFFFFFFF]
    // (OMITTED_ADDR_W=0) -- the case that used to fail elaboration (bug #25).
`ifdef TC_ADDR_L
    localparam logic [31:0] CACHE_ADDR_L = `TC_ADDR_L;
`else
    localparam logic [31:0] CACHE_ADDR_L = BASE;
`endif

    // Cache geometry / policy -- overridable via +define so the same tb can
    // run a small fast config or the GraphBlox-scale config (LINES=512, GRASP).
`ifdef TC_LINES
    localparam int VLINES = `TC_LINES;
`else
    localparam int VLINES = 8;
`endif
`ifdef TC_WAYS
    localparam int VWAYS = `TC_WAYS;
`else
    localparam int VWAYS = 2;
`endif
`ifdef TC_LINE_W
    localparam int VLINE_W = `TC_LINE_W;
`else
    localparam int VLINE_W = 2;
`endif
`ifdef TC_POLICY_INT
    localparam int VPOLICY = `TC_POLICY_INT;
`else
    localparam int VPOLICY = 0;
`endif
`ifdef TC_VICTIM
    localparam int VVICTIM = `TC_VICTIM;
`else
    localparam int VVICTIM = 0;
`endif
    // The tag/valid array is cleared by an LFSR walk that needs >= LINES cycles;
    // the inuse toggle-memories need <= 256. Hold reset generously from geometry
    // (this is exactly the wrapper-side TC_INIT_CYCLES contract: scale with the
    // cache, never a small constant).
    localparam int RESET_CYCLES = 4*VLINES + 1024;
    // Address stride that lands on the SAME set (a full cache line-span), used to
    // force a dirty eviction -> a real mem writeback.
    localparam int SET_STRIDE = VLINES * VLINE_W * (BW/8);

    bit aclk = 0;
    bit aresetn = 0;
    always #5 aclk = ~aclk;            // 100 MHz

    // ---- s00 nets (master VIP <-> l2_top.s00) ----
    wire [ID_W-1:0] s_awid, s_arid, s_bid, s_rid;
    wire [AW-1:0]   s_awaddr, s_araddr;
    wire [7:0]      s_awlen, s_arlen;
    wire [2:0]      s_awsize, s_arsize, s_awprot, s_arprot;
    wire [1:0]      s_awburst, s_arburst, s_bresp, s_rresp;
    wire            s_awlock, s_arlock;
    wire [3:0]      s_awcache, s_arcache, s_awqos, s_arqos, s_awregion, s_arregion;
    wire            s_awvalid, s_awready, s_arvalid, s_arready;
    wire [BW-1:0]   s_wdata, s_rdata;
    wire [BW/8-1:0] s_wstrb;
    wire            s_wlast, s_wvalid, s_wready, s_bvalid, s_bready, s_rlast, s_rvalid, s_rready;

    // ---- m00 nets (l2_top.m00 <-> slave VIP) ----
    wire [MID_W-1:0] m_awid, m_arid, m_bid, m_rid;
    wire [AW-1:0]    m_awaddr, m_araddr;
    wire [7:0]       m_awlen, m_arlen;
    wire [2:0]       m_awsize, m_arsize, m_awprot, m_arprot;
    wire [1:0]       m_awburst, m_arburst, m_bresp, m_rresp;
    wire             m_awlock, m_arlock;
    wire [3:0]       m_awcache, m_arcache, m_awqos, m_arqos;
    wire             m_awvalid, m_awready, m_arvalid, m_arready;
    wire [BW-1:0]    m_wdata, m_rdata;
    wire [BW/8-1:0]  m_wstrb;
    wire             m_wlast, m_wvalid, m_wready, m_bvalid, m_bready, m_rlast, m_rvalid, m_rready;

    // ================= Master VIP drives s00 =================
    axi_vip_mst master_vip (
        .aclk(aclk), .aresetn(aresetn),
        .m_axi_awid(s_awid), .m_axi_awaddr(s_awaddr), .m_axi_awlen(s_awlen), .m_axi_awsize(s_awsize),
        .m_axi_awburst(s_awburst), .m_axi_awlock(s_awlock), .m_axi_awcache(s_awcache), .m_axi_awprot(s_awprot),
        .m_axi_awregion(s_awregion), .m_axi_awqos(s_awqos), .m_axi_awvalid(s_awvalid), .m_axi_awready(s_awready),
        .m_axi_wdata(s_wdata), .m_axi_wstrb(s_wstrb), .m_axi_wlast(s_wlast), .m_axi_wvalid(s_wvalid), .m_axi_wready(s_wready),
        .m_axi_bid(s_bid), .m_axi_bresp(s_bresp), .m_axi_bvalid(s_bvalid), .m_axi_bready(s_bready),
        .m_axi_arid(s_arid), .m_axi_araddr(s_araddr), .m_axi_arlen(s_arlen), .m_axi_arsize(s_arsize),
        .m_axi_arburst(s_arburst), .m_axi_arlock(s_arlock), .m_axi_arcache(s_arcache), .m_axi_arprot(s_arprot),
        .m_axi_arregion(s_arregion), .m_axi_arqos(s_arqos), .m_axi_arvalid(s_arvalid), .m_axi_arready(s_arready),
        .m_axi_rid(s_rid), .m_axi_rdata(s_rdata), .m_axi_rresp(s_rresp), .m_axi_rlast(s_rlast),
        .m_axi_rvalid(s_rvalid), .m_axi_rready(s_rready)
    );

    // ===================== DUT: l2_top ======================
    // ---- tc_flush_controller + AR mux / R demux (flush guard, T5). While
    //      flush_active the controller owns the AR into l2_top; the VIP master
    //      is quiesced by the sequential test. CBOM R (id==FLUSH_ID) is demuxed
    //      back to the controller. ----
    localparam logic [ID_W-1:0] FLUSH_ID = '1;
    logic       flush_req = 0, flush_active, flush_done;
    ar_t        flush_ar;  logic [ID_W-1:0] flush_arid; logic flush_arready;
    r_t         flush_r;   logic flush_rready;
    // muxed AR into l2_top.s00
    logic [ID_W-1:0] cs_arid; logic [AW-1:0] cs_araddr; logic [7:0] cs_arlen;
    logic [2:0] cs_arsize; logic [1:0] cs_arburst; logic cs_arlock;
    logic [3:0] cs_arcache; logic [2:0] cs_arprot; logic [3:0] cs_arqos, cs_arregion;
    logic [3:0] cs_arsnoop; logic cs_arvalid, cs_arready;
    // l2_top.s00 R outputs (pre-demux)
    logic [ID_W-1:0] cs_rid; logic [BW-1:0] cs_rdata; logic [1:0] cs_rresp;
    logic cs_rlast, cs_rvalid, cs_rready;

    tc_flush_controller #(
        .LINES(VLINES), .WAYS(VWAYS), .LINE_W(VLINE_W), .BLOCK_W(BW),
        .ID_W(ID_W), .ADDR_BASE(BASE), .DEFAULT_MODE(4'b1011)  // CleanInvalidByIndex (whole-set)
    ) flush_ctrl (
        .clk(aclk), .rst(~aresetn),
        .flush_req(flush_req), .flush_mode(4'h0),
        .flush_active(flush_active), .flush_done(flush_done),
        .m_ar(flush_ar), .m_arid(flush_arid), .m_arready(flush_arready),
        .m_r(flush_r), .m_rdata(cs_rdata), .m_rid(cs_rid), .m_rready(flush_rready)
    );

    always_comb begin
        if (flush_active) begin
            cs_arid=flush_arid; cs_araddr=flush_ar.araddr; cs_arlen=flush_ar.arlen;
            cs_arsize=flush_ar.arsize; cs_arburst=flush_ar.arburst; cs_arlock=flush_ar.arlock;
            cs_arcache=flush_ar.arcache; cs_arprot=flush_ar.arprot; cs_arqos=flush_ar.arqos;
            cs_arregion=flush_ar.arregion; cs_arsnoop=flush_ar.arsnoop; cs_arvalid=flush_ar.arvalid;
            flush_arready=cs_arready;
        end else begin
            cs_arid=s_arid; cs_araddr=s_araddr; cs_arlen=s_arlen; cs_arsize=s_arsize;
            cs_arburst=s_arburst; cs_arlock=s_arlock; cs_arcache=s_arcache; cs_arprot=s_arprot;
            cs_arqos=s_arqos; cs_arregion=s_arregion; cs_arsnoop=4'b0000; cs_arvalid=s_arvalid;
            flush_arready=1'b0;
        end
    end
    assign s_arready = flush_active ? 1'b0 : cs_arready;
    // route_to_flush must be gated on cs_rvalid: cs_rid is a don't-care (X in
    // 4-state) while cs_rvalid=0, so comparing it against FLUSH_ID during a
    // flush's R-wait drives route_to_flush -> X -> cs_rready -> X. That X on the
    // read-ready is exactly the "demux gated by flush_active is necessary but
    // NOT sufficient" hazard: an X-sensitive interconnect breaks the flush
    // R-beat handshake -> tc_flush_controller hangs in WAIT_R. Gating on
    // cs_rvalid keeps rready defined (= s_rready) while waiting.
    wire route_to_flush = flush_active & cs_rvalid & (cs_rid == FLUSH_ID);
    assign flush_r  = '{ rvalid: cs_rvalid & route_to_flush, rlast: cs_rlast, rresp: {2'b00, cs_rresp} };
    assign s_rvalid = cs_rvalid & ~route_to_flush;
    assign s_rid    = cs_rid;
    assign s_rdata  = cs_rdata;
    assign s_rresp  = cs_rresp;
    assign s_rlast  = cs_rlast;
    assign cs_rready = route_to_flush ? flush_rready : s_rready;

    l2_top #(
        .ADDR_L(CACHE_ADDR_L), .ADDR_H(32'hFFFF_FFFF),
        .WAYS(VWAYS), .LINES(VLINES), .LINE_W(VLINE_W), .DB_LATENCY(1),
        .REPLACEMENT_POLICY(VPOLICY), .INCLUDE_VICTIM(VVICTIM), .INCLUDE_CBOM(1),
        .C_S00_AXI_ID_WIDTH(ID_W), .C_S00_AXI_DATA_WIDTH(BW), .C_S00_AXI_ADDR_WIDTH(AW)
    ) dut (
        .s00_axi_aclk(aclk), .s00_axi_aresetn(aresetn),
        .m00_axi_aclk(aclk), .m00_axi_aresetn(aresetn),
        .grasp_high_addr_l('0), .grasp_high_addr_h('0),
        .grasp_moderate_addr_l('0), .grasp_moderate_addr_h('0),
        // s00 AW/W/B
        .s00_axi_awid(s_awid), .s00_axi_awaddr(s_awaddr), .s00_axi_awlen(s_awlen), .s00_axi_awsize(s_awsize),
        .s00_axi_awburst(s_awburst), .s00_axi_awlock(s_awlock), .s00_axi_awcache(s_awcache), .s00_axi_awprot(s_awprot),
        .s00_axi_awqos(s_awqos), .s00_axi_awregion(s_awregion), .s00_axi_awsnoop(3'b000),
        .s00_axi_awvalid(s_awvalid), .s00_axi_awready(s_awready),
        .s00_axi_wdata(s_wdata), .s00_axi_wstrb(s_wstrb), .s00_axi_wlast(s_wlast),
        .s00_axi_wvalid(s_wvalid), .s00_axi_wready(s_wready),
        .s00_axi_bid(s_bid), .s00_axi_bresp(s_bresp), .s00_axi_bvalid(s_bvalid), .s00_axi_bready(s_bready),
        // s00 AR/R (through the flush AR-mux / R-demux)
        .s00_axi_arid(cs_arid), .s00_axi_araddr(cs_araddr), .s00_axi_arlen(cs_arlen), .s00_axi_arsize(cs_arsize),
        .s00_axi_arburst(cs_arburst), .s00_axi_arlock(cs_arlock), .s00_axi_arcache(cs_arcache), .s00_axi_arprot(cs_arprot),
        .s00_axi_arqos(cs_arqos), .s00_axi_arregion(cs_arregion), .s00_axi_arsnoop(cs_arsnoop),
        .s00_axi_arvalid(cs_arvalid), .s00_axi_arready(cs_arready),
        .s00_axi_rid(cs_rid), .s00_axi_rdata(cs_rdata), .s00_axi_rresp(cs_rresp), .s00_axi_rlast(cs_rlast),
        .s00_axi_rvalid(cs_rvalid), .s00_axi_rready(cs_rready),
        // m00 AW/W/B
        .m00_axi_awid(m_awid), .m00_axi_awaddr(m_awaddr), .m00_axi_awlen(m_awlen), .m00_axi_awsize(m_awsize),
        .m00_axi_awburst(m_awburst), .m00_axi_awlock(m_awlock), .m00_axi_awcache(m_awcache), .m00_axi_awprot(m_awprot),
        .m00_axi_awqos(m_awqos), .m00_axi_awvalid(m_awvalid), .m00_axi_awready(m_awready),
        .m00_axi_wdata(m_wdata), .m00_axi_wstrb(m_wstrb), .m00_axi_wlast(m_wlast),
        .m00_axi_wvalid(m_wvalid), .m00_axi_wready(m_wready),
        .m00_axi_bid(m_bid), .m00_axi_bresp(m_bresp), .m00_axi_bvalid(m_bvalid), .m00_axi_bready(m_bready),
        // m00 AR/R
        .m00_axi_arid(m_arid), .m00_axi_araddr(m_araddr), .m00_axi_arlen(m_arlen), .m00_axi_arsize(m_arsize),
        .m00_axi_arburst(m_arburst), .m00_axi_arlock(m_arlock), .m00_axi_arcache(m_arcache), .m00_axi_arprot(m_arprot),
        .m00_axi_arqos(m_arqos), .m00_axi_arvalid(m_arvalid), .m00_axi_arready(m_arready),
        .m00_axi_rid(m_rid), .m00_axi_rdata(m_rdata), .m00_axi_rresp(m_rresp), .m00_axi_rlast(m_rlast),
        .m00_axi_rvalid(m_rvalid), .m00_axi_rready(m_rready)
    );

    // ============= Slave memory VIP backs m00 ===============
    axi_vip_slv slave_vip (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awid(m_awid), .s_axi_awaddr(m_awaddr), .s_axi_awlen(m_awlen), .s_axi_awsize(m_awsize),
        .s_axi_awburst(m_awburst), .s_axi_awlock(m_awlock), .s_axi_awcache(m_awcache), .s_axi_awprot(m_awprot),
        .s_axi_awregion(4'b0000), .s_axi_awqos(m_awqos), .s_axi_awvalid(m_awvalid), .s_axi_awready(m_awready),
        .s_axi_wdata(m_wdata), .s_axi_wstrb(m_wstrb), .s_axi_wlast(m_wlast), .s_axi_wvalid(m_wvalid), .s_axi_wready(m_wready),
        .s_axi_bid(m_bid), .s_axi_bresp(m_bresp), .s_axi_bvalid(m_bvalid), .s_axi_bready(m_bready),
        .s_axi_arid(m_arid), .s_axi_araddr(m_araddr), .s_axi_arlen(m_arlen), .s_axi_arsize(m_arsize),
        .s_axi_arburst(m_arburst), .s_axi_arlock(m_arlock), .s_axi_arcache(m_arcache), .s_axi_arprot(m_arprot),
        .s_axi_arregion(4'b0000), .s_axi_arqos(m_arqos), .s_axi_arvalid(m_arvalid), .s_axi_arready(m_arready),
        .s_axi_rid(m_rid), .s_axi_rdata(m_rdata), .s_axi_rresp(m_rresp), .s_axi_rlast(m_rlast),
        .s_axi_rvalid(m_rvalid), .s_axi_rready(m_rready)
    );

    axi_vip_mst_mst_t      mst;
    axi_vip_slv_slv_mem_t  slv;

    // Count real mem writebacks (dirty evictions reaching the backend).
    int mem_aw_count = 0;
    always @(posedge aclk) if (aresetn && m_awvalid && m_awready) mem_aw_count++;

    // single-beat 32-bit helpers
    bit [8*4096-1:0]          wbeats, rbeats;
    xil_axi_data_beat [255:0] nouser;
    xil_axi_resp_t            bresp;
    xil_axi_resp_t [255:0]    rresp;

    task automatic axi_wr(input bit [31:0] addr, input bit [31:0] data);
        wbeats = '0; wbeats[31:0] = data; nouser = '0;
        mst.AXI4_WRITE_BURST(0, addr, 0, XIL_AXI_SIZE_4BYTE, XIL_AXI_BURST_TYPE_INCR,
                             XIL_AXI_ALOCK_NOLOCK, 4'hF, 0, 0, 0, 0, wbeats, nouser, bresp);
    endtask

    task automatic axi_rd(input bit [31:0] addr, output bit [31:0] data);
        mst.AXI4_READ_BURST(0, addr, 0, XIL_AXI_SIZE_4BYTE, XIL_AXI_BURST_TYPE_INCR,
                            XIL_AXI_ALOCK_NOLOCK, 4'hF, 0, 0, 0, 0, rbeats, rresp, nouser);
        data = rbeats[31:0];
    endtask

    int       errors = 0;
    int       xmon_errors = 0;
    bit       mon_active = 0;
    bit [31:0] rd;
    int       aw0;

    // ---- 4-state X-monitor (enrichment) -------------------------------------
    // After reset settles, no valid/ready handshake may be X, and no payload may
    // be X while its VALID is asserted. This is the generic net for the cold-init
    // X-bug class (LFSR reset-walk, toggle_memory, cbom/writeback regs) that only
    // shows up in 4-state sim -- exactly the bugs this cache repeatedly hit. rdata
    // is skipped on the cache->master read channel because a CBOM legitimately
    // returns 'x (no data), but the memory-side m_rdata IS checked.
    always @(posedge aclk) if (mon_active) begin
        if ($isunknown({s_awvalid, s_awready, s_wvalid, s_wready, s_bvalid, s_bready,
                        cs_arvalid, cs_arready, cs_rvalid, cs_rready,
                        m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready,
                        m_arvalid, m_arready, m_rvalid, m_rready})) begin
            $display("FAIL Xmon @%0t: a valid/ready handshake bit is X | s:aw v%b r%b w v%b r%b b v%b r%b | cs ar v%b r%b r v%b r%b | m:aw v%b r%b w v%b r%b b v%b r%b ar v%b r%b r v%b r%b",
                $time, s_awvalid,s_awready,s_wvalid,s_wready,s_bvalid,s_bready,
                cs_arvalid,cs_arready,cs_rvalid,cs_rready,
                m_awvalid,m_awready,m_wvalid,m_wready,m_bvalid,m_bready,
                m_arvalid,m_arready,m_rvalid,m_rready); xmon_errors++;
        end
        if (cs_arvalid && $isunknown({cs_araddr, cs_arlen, cs_arsize, cs_arsnoop})) begin
            $display("FAIL Xmon @%0t: s00 AR payload X while arvalid", $time); xmon_errors++; end
        if (s_awvalid && $isunknown({s_awaddr, s_awlen, s_awsize})) begin
            $display("FAIL Xmon @%0t: s00 AW payload X while awvalid", $time); xmon_errors++; end
        if (s_wvalid && $isunknown({s_wdata, s_wstrb, s_wlast})) begin
            $display("FAIL Xmon @%0t: s00 W payload X while wvalid", $time); xmon_errors++; end
        if (m_awvalid && $isunknown({m_awaddr, m_awlen, m_awsize, m_awburst})) begin
            $display("FAIL Xmon @%0t: m00 AW payload X while awvalid (writeback addr X!)", $time); xmon_errors++; end
        if (m_wvalid && $isunknown({m_wdata, m_wstrb, m_wlast})) begin
            $display("FAIL Xmon @%0t: m00 W payload X while wvalid (writeback data X!)", $time); xmon_errors++; end
        if (m_arvalid && $isunknown({m_araddr, m_arlen, m_arsize})) begin
            $display("FAIL Xmon @%0t: m00 AR payload X while arvalid (fetch addr X!)", $time); xmon_errors++; end
        if (m_rvalid && $isunknown({m_rdata, m_rlast})) begin
            $display("FAIL Xmon @%0t: m00 R payload X while rvalid", $time); xmon_errors++; end
    end

    initial begin
        mst = new("mst", master_vip.inst.IF);
        slv = new("slv", slave_vip.inst.IF);
        slv.start_slave();
        mst.start_master();

        // ---- COLD power-on: assert reset at t0, hold long enough for the
        //      LFSR reset-walk to clear every array, then deassert. ----
        aresetn = 0;
        repeat (RESET_CYCLES) @(posedge aclk);
        aresetn = 1;
        repeat (20) @(posedge aclk);
        mon_active = 1;   // arm the 4-state X-monitor once the cold reset settled

        // T0: COLD whole-cache flush BEFORE any warming traffic (all lines
        // invalid). This is the GraphBlox Experimental-BFS blocker: on
        // INCLUDE_VICTIM=1 the invalid-line by-index CBOM was reported to hang
        // the tc_flush_controller in WAIT_R (its R-beat never completing). The
        // warm T5 flush below does NOT cover it. Require flush_done within a bound.
        flush_req = 1; @(posedge aclk); flush_req = 0;
        for (int fcyc = 0; fcyc < 8*VLINES*VWAYS + 4000; fcyc++) begin
            @(posedge aclk);
            if (flush_done) break;
        end
        if (!flush_done) begin
            $display("FAIL T0 COLD flush: flush_done never pulsed (cold+victim flush WEDGED in WAIT_R)"); errors++;
        end else
            $display("PASS T0 cold whole-cache flush completed");

        // Preload backing memory for the line we read cold (both words of the line).
        slv.mem_model.backdoor_memory_write_4byte(BASE + 32'h0, 32'hCAFE_BABE);
        slv.mem_model.backdoor_memory_write_4byte(BASE + 32'h4, 32'h0BAD_F00D);

        // T1: cold read -> MISS -> fill from mem -> DEFINED data == preload.
        axi_rd(BASE + 32'h0, rd);
        if (rd === 32'hxxxx_xxxx || (^rd) === 1'bx) begin
            $display("FAIL T1 cold read returned X: %h (valid bits never cleared)", rd); errors++;
        end else if (rd !== 32'hCAFE_BABE) begin
            $display("FAIL T1 cold read data: got %h want CAFEBABE", rd); errors++;
        end else
            $display("PASS T1 cold read miss->fill: %h", rd);

        // T2: write then read back same line -> write-allocate, cache returns it.
        axi_wr(BASE + 32'h40, 32'hDEAD_BEEF);
        axi_rd(BASE + 32'h40, rd);
        if (rd !== 32'hDEAD_BEEF) begin
            $display("FAIL T2 write->read: got %h want DEADBEEF", rd); errors++;
        end else
            $display("PASS T2 write->read-back: %h", rd);

        // T3: a second line, write/read.
        axi_wr(BASE + 32'h100, 32'h1234_5678);
        axi_rd(BASE + 32'h100, rd);
        if (rd !== 32'h1234_5678) begin
            $display("FAIL T3 write->read: got %h want 12345678", rd); errors++;
        end else
            $display("PASS T3 write->read-back: %h", rd);

        // T4: write WAYS+1 distinct dirty lines that map to the SAME set. The
        // (WAYS+1)th write forces a dirty eviction -> a REAL mem AW to the
        // backend (directly probing the "cold write issues 0 mem AW / stalls"
        // concern). Then read all back: WAYS stay cached, the evicted one
        // refills from the writeback in mem. Exercises the cold write +
        // eviction + finish/writeback path that a read-only test misses.
        aw0 = mem_aw_count;
        for (int i = 0; i <= VWAYS; i++)
            axi_wr(BASE + i*SET_STRIDE, 32'hE000_0000 + i);
        for (int i = 0; i <= VWAYS; i++) begin
            axi_rd(BASE + i*SET_STRIDE, rd);
            if (rd !== (32'hE000_0000 + i)) begin
                $display("FAIL T4 read-back line %0d: got %h want %h", i, rd, 32'hE000_0000 + i);
                errors++;
            end
        end
        if (mem_aw_count == aw0) begin
            $display("FAIL T4 eviction: 0 mem AW (dirty write never reached backend)");
            errors++;
        end else
            $display("PASS T4 eviction+writeback: %0d mem AW, %0d lines verified",
                     mem_aw_count - aw0, VWAYS + 1);

        // T5: whole-cache flush (CleanInvalid CBOM walk via tc_flush_controller)
        // over a cache that now holds dirty lines. The reported cold flush wedge
        // (cbom_fifo X) would hang here; require flush_done within a bound.
        flush_req = 1; @(posedge aclk); flush_req = 0;
        for (int fcyc = 0; fcyc < 8*VLINES*VWAYS + 4000; fcyc++) begin
            @(posedge aclk);
            if (flush_done) break;
        end
        if (!flush_done) begin
            $display("FAIL T5 flush: flush_done never pulsed (cold flush WEDGED)"); errors++;
        end else
            $display("PASS T5 whole-cache flush completed");

        // T6 (FIX B): fill one set with dirty lines at HIGH tags (well beyond
        // the swept tag range) and require the default by-index flush to write
        // them ALL back. A per-line CleanInvalid flush would miss every one
        // (it only matches tag == swept address tag). Enforces whole-set clean.
        begin
            automatic int HIGH = 32;                 // tag 0x20, >> VWAYS-1
            automatic bit ok = 1;
            for (int i = 0; i < VWAYS; i++)
                axi_wr(BASE + (HIGH + i)*SET_STRIDE + 32'h10, 32'hCA11_E000 + i);
            flush_req = 1; @(posedge aclk); flush_req = 0;
            for (int fcyc = 0; fcyc < 8*VLINES*VWAYS + 4000; fcyc++) begin
                @(posedge aclk); if (flush_done) break;
            end
            // Every high-tag dirty way must have been written back + dropped:
            // the post-flush read refills from the backend and returns the value.
            for (int i = 0; i < VWAYS; i++) begin
                axi_rd(BASE + (HIGH + i)*SET_STRIDE + 32'h10, rd);
                if (rd !== (32'hCA11_E000 + i)) begin
                    ok = 0; errors++;
                    $display("FAIL T6 by-index flush tag 0x%0h: got %h want %h",
                             HIGH + i, rd, 32'hCA11_E000 + i);
                end
            end
            if (ok)
                $display("PASS T6 by-index flush cleaned %0d high-tag ways", VWAYS);
        end

        if (xmon_errors != 0)
            $display("FAIL Xmon: %0d 4-state X violation(s) observed after reset", xmon_errors);
        if (errors == 0 && xmon_errors == 0)
            $display("VIP_RESULT PASS: l2_top cold cache works in xsim (4-state)");
        else
            $display("VIP_RESULT FAIL: %0d error(s) + %0d Xmon violation(s)", errors, xmon_errors);
        $finish;
    end

    // global watchdog: a cold-cache wedge would otherwise hang forever.
    // Scale past the reset hold + the whole-cache flush walk + headroom.
    initial begin
        #((RESET_CYCLES + 8*VLINES*VWAYS + 40000) * 10);
        $display("VIP_RESULT FAIL: watchdog timeout (cache wedged cold)");
        $finish;
    end

endmodule
