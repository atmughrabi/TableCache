// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tc_narrow_shim
// -----------------------------------------------------------------------------
// Narrow-port AXI shim in front of TableCache.
//
//   accelerator (NARROW_W bits)
//        │ AR/R, AW/W/B  single-beat narrow transactions
//        ▼
//   ┌─────────────────┐
//   │ tc_narrow_shim  │  widens / aligns / slices  (+ optional L0 line buffer)
//   └─────────────────┘
//        │ AR/R, AW/W/B  single-beat wide (BLOCK_W) transactions
//        ▼
//   TableCache (BLOCK_W bits)
//
// Functional spec
//   * READ : align narrow araddr to BLOCK_W boundary, issue ONE-beat wide AR.
//            On the wide R beat, slice the NARROW_W-wide word indicated by
//            the original byte offset.
//   * If ENABLE_LINE_BUFFER=1 the shim caches the most recently returned wide
//     line. Subsequent narrow reads to the same aligned line are served from
//     the buffer without touching the cache. This is the bottleneck-killer
//     for sequential 4-B / 8-B scans.
//   * The line buffer is invalidated on (a) reset, (b) any accepted AW whose
//     aligned address matches, (c) any CBOM read passed through to the cache.
//   * WRITE: align narrow awaddr, issue ONE-beat wide AW. awsnoop=3'b101
//     (WriteEvict) is REWRITTEN to 3'b000 because a narrow write cannot
//     legitimately claim full-line coverage — let the cache RMW. Drive
//     m_wdata with narrow s_wdata in the selected lane, m_wstrb=0 elsewhere
//     so only the requested bytes mutate after the RMW merge.
//   * AW offset is captured into an ordered FIFO on AW handshake and popped
//     on each W beat. AXI4 guarantees W beat order follows AW arrival order
//     across IDs, so one ordered FIFO is correct (independent of awid).
//   * arsnoop passes through unchanged (cache_b will treat as CBOM on the
//     full aligned line). awsnoop other than 3'b101 passes through unchanged.
//
// Narrow-side requirements (asserted)
//   * Single beat per request:  arlen = awlen = 0
//   * Full narrow bus per beat: arsize = awsize = $clog2(NARROW_W/8)
//   * Address NARROW_W/8-aligned
//   * NARROW_W divides BLOCK_W; both powers of two; MAX_OUTSTANDING_W is PoT
//
// Hard restrictions (cannot do through this shim)
//   * Bursting narrow masters → put a Xilinx AXI Data Width Converter in front.
//   * True full-line WriteEvict from a narrow port. If the accelerator needs
//     to bypass RMW, give it a second wide path that joins the cache via an
//     AXI crossbar (then this shim handles only the scalar accesses).
//
// FMAX notes
//   * Combinational mux selects 1 of RATIO words from BLOCK_W. At BLOCK_W=1024
//     RATIO=32 a 32→1 mux × NARROW_W bits may be the critical path. Register
//     downstream of the mux in your top if FMAX bites.
// -----------------------------------------------------------------------------

// NOTE: this is the shim CORE (the original tc_narrow_shim logic, unchanged).
// The public `tc_narrow_shim` module lives at the bottom of this file: it is a
// thin wrapper that, by default (READ_REORDER_DEPTH=1), instantiates this core
// straight through, and when READ_REORDER_DEPTH>1 inserts a read-only in-order
// reorder buffer (tc_read_reorder) in front of it so a single-id, in-order
// engine can have >1 read outstanding. The core still sees 1-outstanding-per-id;
// the reorder buffer spreads reads across distinct core ids and restores order.
module tc_narrow_shim_core
    #(
        parameter int unsigned NARROW_W           = 32,
        parameter int unsigned BLOCK_W            = 512,
        parameter int unsigned ID_W               = 4,
        parameter int unsigned ADDR_W             = 32,
        parameter int unsigned MAX_OUTSTANDING_W  = 16,   // = 2^WRITE_ID_WIDTH at cache
        parameter bit          ENABLE_LINE_BUFFER = 1'b1,
        // ----------------------------------------------------------------
        // Legacy workaround for an l2_cache cold-write-miss byte-merge bug
        // observed at BLOCK_W=512 LINE_W=8 (only the high byte of the lane
        // survived). Root cause was bug #7 in tdp_ram.sv (Verilator wide-NBA
        // quirk) which has since been fixed. The cache's design already
        // RMWs correctly via parallel `wbe`-masked write (lane bytes) + fill
        // (fill_wbe = ~stored_wbe, the OTHER bytes); the workaround is now
        // redundant and is left at 0 by default.
        //
        // Set this to 1 ONLY if a new byte-merge regression resurfaces. The
        // workaround issues a wide AR whenever the L0 line buffer does not
        // hold the AW's line — including the common case where the line is
        // already in L2 (just not in L0), which costs a full mem round-trip
        // for every "far" write.
        // ----------------------------------------------------------------
        parameter bit          PROMOTE_WMISS_TO_RW = 1'b0
    )
    (
        input  logic                      clk,
        input  logic                      rst,

        // ---------------- narrow slave (accelerator) ----------------
        input  logic [ADDR_W-1:0]         s_araddr,
        input  logic [7:0]                s_arlen,
        input  logic [2:0]                s_arsize,
        input  logic [1:0]                s_arburst,
        input  logic [3:0]                s_arsnoop,
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
        input  logic [2:0]                s_awsnoop,
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

        // ---------------- wide master (TableCache front end) ----------------
        output logic [ADDR_W-1:0]         m_araddr,
        output logic [7:0]                m_arlen,
        output logic [2:0]                m_arsize,
        output logic [1:0]                m_arburst,
        output logic [3:0]                m_arsnoop,
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
        output logic [2:0]                m_awsnoop,
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

    // ------------------------------------------------------------------
    // Local parameters
    // ------------------------------------------------------------------
    localparam int unsigned NARROW_B  = NARROW_W / 8;
    localparam int unsigned BLOCK_B   = BLOCK_W  / 8;
    localparam int unsigned RATIO     = BLOCK_W  / NARROW_W;
    localparam int unsigned OFF_LSB   = $clog2(NARROW_B);
    // Width of the sub-block word offset. At RATIO==1 (BLOCK_W==NARROW_W) a block
    // IS one narrow word: there is NO sub-block offset ($clog2(1)=0 address bits
    // select it). OFF_W is held at 1 only to keep the offset signals from becoming
    // an illegal zero-width [-1:0]; the VALUE must be forced to 0 at every capture
    // (see OFF_ZERO uses) — otherwise s_araddr[OFF_LSB +: 1] = s_araddr[2] leaks in
    // and indexes m_rdata/lb_data/m_wdata[1*NARROW_W +: NARROW_W] = bits[63:32] of a
    // BLOCK_W(=32)-wide word → OUT OF RANGE → X on odd 4-byte reads / lost odd
    // writes. xsim (4-state) returns X here; Verilator masks it, so this needs the
    // xsim shim TB to catch. (RATIO>1: the slice is in range and OFF_W=$clog2(RATIO).)
    localparam int unsigned OFF_W     = (RATIO == 1) ? 1 : $clog2(RATIO);
    localparam int unsigned ALIGN_LSB = $clog2(BLOCK_B);
    localparam int unsigned NUM_IDS   = 1 << ID_W;
    localparam int unsigned FIFO_AW   = $clog2(MAX_OUTSTANDING_W);

    initial begin
        assert (BLOCK_W % NARROW_W == 0)
            else $error("tc_narrow_shim: BLOCK_W (%0d) must be a multiple of NARROW_W (%0d)",
                        BLOCK_W, NARROW_W);
        assert ((1 << $clog2(RATIO)) == RATIO)
            else $error("tc_narrow_shim: RATIO (%0d) must be a power of two", RATIO);
        assert ((1 << FIFO_AW) == MAX_OUTSTANDING_W)
            else $error("tc_narrow_shim: MAX_OUTSTANDING_W must be a power of two");
    end

    // ==================================================================
    // READ PATH
    // ==================================================================

    // Per-ID outstanding-read offset + aligned address.
    // Same-ID serialization: a new AR sharing an in-flight rid is stalled here
    // so the per-id table cannot be clobbered. This matches l2_cache's same-id
    // ordering rule and keeps the shim safe against backends that don't enforce
    // it (e.g. plain AxiRam in test benches).
    logic [OFF_W-1:0]  rid_offset_q   [NUM_IDS-1:0];
    logic [ADDR_W-1:0] rid_alignaddr_q[NUM_IDS-1:0];
    logic [NUM_IDS-1:0] rid_outstanding_q;

    // ---- line buffer state ----
    logic                           lb_valid;
    logic [ADDR_W-1:ALIGN_LSB]      lb_tag;       // aligned high bits
    logic [BLOCK_W-1:0]             lb_data;

    // ---- 1-deep pending buffer-served read slot ----
    logic               buf_pend_valid_q;
    logic [ID_W-1:0]    buf_pend_id_q;
    logic [OFF_W-1:0]   buf_pend_off_q;

    // Does the incoming AR hit the buffer?
    logic ar_hits_buffer;
    generate if (ENABLE_LINE_BUFFER) begin : gen_lb_hit
        assign ar_hits_buffer = lb_valid
                              & (s_arsnoop == 4'd0)
                              & (s_araddr[ADDR_W-1:ALIGN_LSB] == lb_tag);
    end else begin : gen_no_lb_hit
        assign ar_hits_buffer = 1'b0;
    end endgenerate

    // Accept an AR if either:
    //   (a) it hits the buffer AND the pending-buffered-R slot is free
    //       (or being drained this cycle by a successful s_r handshake
    //        with no cache R competing), OR
    //   (b) it misses and the wide AR handshakes downstream.
    logic ar_buf_drain_this_cycle;
    logic ar_buf_accept;
    logic ar_miss_accept;

    // Prefill (RMW cold-write-miss) signals are defined in the block further
    // below, but the AR-accept logic immediately following references them.
    // Declare/define them here so strict elaborators (xsim) see them in order.
    logic prefill_active;
    logic prefill_ar_pending;
    wire  prefill_ar_fire = prefill_ar_pending;

    assign ar_buf_drain_this_cycle = buf_pend_valid_q & s_rready & ~m_rvalid;
    assign ar_buf_accept  =  ar_hits_buffer  & (~buf_pend_valid_q | ar_buf_drain_this_cycle)
                           & ~rid_outstanding_q[s_arid]
                           & ~prefill_active;        // hold AR while prefill owns the bus
    assign ar_miss_accept = ~ar_hits_buffer  & m_arready
                           & ~rid_outstanding_q[s_arid]
                           & ~prefill_ar_fire         // prefill wins the wide AR slot
                           & ~prefill_active;         // and holds the miss AR for the whole prefill

    assign s_arready = ar_buf_accept | ar_miss_accept;

    // ----------------------------------------------------------------
    // Cold-write-miss workaround (PROMOTE_WMISS_TO_RW)
    // Detect AW to a line that the L0 buffer does NOT hold; issue an
    // internal wide AR first to populate the cache (and the L0). Then
    // release the AW so it lands as a hit-write in the cache, which is the
    // verified path. One in-flight prefill at a time.
    // Uses the highest ID (NUM_IDS-1) as a reserved prefill id.
    // ----------------------------------------------------------------
    localparam logic [ID_W-1:0] PREFILL_ID = '1;
    logic                            prefill_resp_pending; // m_r with this id is mine
    logic [ADDR_W-1:ALIGN_LSB]       prefill_tag_q;

    wire aw_line_in_buf = lb_valid & ENABLE_LINE_BUFFER
                        & (s_awaddr[ADDR_W-1:ALIGN_LSB] == lb_tag);
    wire aw_needs_prefill = PROMOTE_WMISS_TO_RW & s_awvalid
                          & ~aw_line_in_buf & ~prefill_active
                          & ~rid_outstanding_q[PREFILL_ID]  // can't reuse PREFILL_ID id slot
                          // ...nor launch the SAME cycle a read on PREFILL_ID is
                          // accepted: rid_outstanding_q[PREFILL_ID] is set next edge,
                          // but this cycle it still reads 0, so without this term a
                          // prefill would start alongside a buffered/miss PREFILL_ID
                          // read and the prefill's R would clear that read's
                          // outstanding slot early (a master must not use PREFILL_ID,
                          // but guard it so the 1-per-id invariant holds regardless).
                          & ~(s_arvalid & s_arready & (s_arid == PREFILL_ID));
    // A prefill R must (a) be tagged with PREFILL_ID AND (b) actually be the
    // one we issued. Otherwise a master that uses arid==PREFILL_ID would have
    // its responses silently drained. The shim already gates outgoing prefill
    // on `~rid_outstanding_q[PREFILL_ID]` (via the s_arid path), so a master
    // read with arid=PREFILL_ID can never coexist with a prefill in flight.
    wire prefill_r_done   = m_rvalid & m_rready
                          & prefill_resp_pending
                          & (m_rid == PREFILL_ID);

    always_ff @(posedge clk) begin
        if (rst) begin
            prefill_active       <= 1'b0;
            prefill_ar_pending   <= 1'b0;
            prefill_resp_pending <= 1'b0;
            prefill_tag_q        <= '0;
        end else begin
            if (aw_needs_prefill) begin
                prefill_active     <= 1'b1;
                prefill_ar_pending <= 1'b1;
                prefill_tag_q      <= s_awaddr[ADDR_W-1:ALIGN_LSB];
            end
            if (prefill_ar_pending & m_arready & prefill_ar_fire) begin
                prefill_ar_pending   <= 1'b0;
                prefill_resp_pending <= 1'b1;
            end
            if (prefill_r_done) begin
                prefill_active       <= 1'b0;
                prefill_resp_pending <= 1'b0;
            end
        end
    end

    // Wide AR mux: prefill takes priority over the narrow miss path.
    // The narrow-miss term must carry the SAME `~rid_outstanding_q[s_arid]` gate
    // as `ar_miss_accept`/`s_arready` below: otherwise, while a same-id read is
    // still in flight, the shim would keep asserting m_arvalid and the cache
    // (which is 1-outstanding-per-id) could accept a SECOND same-id AR even
    // though s_arready is held low -- clobbering the cache's per-id slot and
    // returning the previous line's data ("one line off"). Gating here makes the
    // wide AR and the narrow accept consistent so same-id reads truly serialize.
    assign m_arvalid = prefill_ar_fire
                     | (s_arvalid & ~ar_hits_buffer & ~prefill_active
                        & ~rid_outstanding_q[s_arid]);
    assign m_araddr  = prefill_ar_fire
                     ? {prefill_tag_q, {ALIGN_LSB{1'b0}}}
                     : {s_araddr[ADDR_W-1:ALIGN_LSB], {ALIGN_LSB{1'b0}}};
    assign m_arlen   = 8'd0;
    assign m_arsize  = 3'($clog2(BLOCK_B));
    assign m_arburst = 2'b01;
    assign m_arsnoop = prefill_ar_fire ? 4'd0 : s_arsnoop;
    assign m_arid    = prefill_ar_fire ? PREFILL_ID : s_arid;

    // Latch per-id offset + aligned address on miss-accept and on prefill
    // AR fire (so the response fill knows the line tag).
    always_ff @(posedge clk) begin
        if (prefill_ar_fire & m_arready) begin
            rid_alignaddr_q[PREFILL_ID] <= {prefill_tag_q, {ALIGN_LSB{1'b0}}};
            rid_offset_q   [PREFILL_ID] <= '0;
        end else if (s_arvalid & ar_miss_accept) begin
            // RATIO==1: no sub-block offset — force 0 (see OFF_W note) so the read
            // slice m_rdata[sel*NARROW_W +: NARROW_W] stays in range.
            rid_offset_q   [s_arid] <= (RATIO == 1) ? '0 : s_araddr[OFF_LSB +: OFF_W];
            rid_alignaddr_q[s_arid] <= m_araddr;
        end
    end

    // Per-ID outstanding tracking: set on accept (miss OR buffer-hit), clear on
    // R handshake to that id. Single-cycle update OK because cache enforces
    // 1 in-flight per id; AxiRam test backends now also see it gated.
    always_ff @(posedge clk) begin
        if (rst) begin
            rid_outstanding_q <= '0;
        end else begin
            if (s_arvalid & (ar_buf_accept | ar_miss_accept))
                rid_outstanding_q[s_arid] <= 1'b1;
            if (prefill_ar_fire & m_arready)
                rid_outstanding_q[PREFILL_ID] <= 1'b1;
            if (m_rvalid & m_rready & m_rlast)
                rid_outstanding_q[m_rid] <= 1'b0;
            // Buffer-served R drain also frees the id.
            if (buf_pend_valid_q & s_rready & ~m_rvalid)
                rid_outstanding_q[buf_pend_id_q] <= 1'b0;
        end
    end

    // Buffer-served R slot.
    always_ff @(posedge clk) begin
        if (rst) begin
            buf_pend_valid_q <= 1'b0;
        end else begin
            // Drain (master accepts our buffered word; cache R didn't compete)
            if (buf_pend_valid_q & s_rready & ~m_rvalid)
                buf_pend_valid_q <= 1'b0;
            // Push on buffer-hit AR
            if (s_arvalid & ar_buf_accept) begin
                buf_pend_valid_q <= 1'b1;
                buf_pend_id_q    <= s_arid;
                // RATIO==1: no sub-block offset — force 0 (buf_r_word slice in range).
                buf_pend_off_q   <= (RATIO == 1) ? '0 : s_araddr[OFF_LSB +: OFF_W];
            end
        end
    end

    // R output mux: cache R wins; buffered R drains when cache is idle.
    // For prefill responses (m_rid == PREFILL_ID) we drain at m_rready=1 but
    // do NOT raise s_rvalid — they're internal to the shim.
    logic [OFF_W-1:0]    cache_r_sel;
    logic [NARROW_W-1:0] cache_r_word;
    logic [NARROW_W-1:0] buf_r_word;
    wire                 m_r_is_prefill = prefill_resp_pending
                                        & (m_rid == PREFILL_ID)
                                        & PROMOTE_WMISS_TO_RW;

    assign cache_r_sel  = rid_offset_q[m_rid];
    assign cache_r_word = m_rdata[cache_r_sel*NARROW_W +: NARROW_W];
    assign buf_r_word   = lb_data  [buf_pend_off_q*NARROW_W +: NARROW_W];

    // The shim issues arlen=0, so exactly ONE data beat completes a read: the
    // requested block, which the cache marks with rlast=1. Older cache revisions
    // could emit a trailing sibling-block beat (rlast=0) after paired concurrent
    // hits (bug #31; fixed at the databank generation boundary). Keep the shim's
    // defensive drain/drop: it never forwards or latches an unrequested rlast=0
    // beat and is a no-op for the normal single-beat response.
    wire cache_r_resp  = m_rvalid & ~m_r_is_prefill & m_rlast;   // real response
    wire cache_r_extra = m_rvalid & ~m_rlast;                    // trailing beat: drain only

    always_comb begin
        if (cache_r_resp) begin
            s_rdata  = cache_r_word;
            s_rresp  = m_rresp;
            s_rlast  = 1'b1;                       // single-beat
            s_rid    = m_rid;
            s_rvalid = 1'b1;
        end else if (buf_pend_valid_q & ~m_rvalid) begin
            s_rdata  = buf_r_word;
            s_rresp  = 2'b00;
            s_rlast  = 1'b1;
            s_rid    = buf_pend_id_q;
            s_rvalid = 1'b1;
        end else begin
            s_rdata  = '0;
            s_rresp  = 2'b00;
            s_rlast  = 1'b0;
            s_rid    = '0;
            s_rvalid = 1'b0;
        end
    end
    // Drain wide R always: a real response (rlast=1) is gated by s_rready; prefill
    // R is consumed internally; a trailing extra beat (rlast=0) is drained
    // unconditionally so the cache advances even while the master backpressures.
    assign m_rready = s_rready | m_r_is_prefill | cache_r_extra;

    // ---- line buffer update ----
    // The buffer is filled from a wide R completion AND from a same-line W
    // beat (write-merge). The write-merge avoids a wide re-fetch when a
    // master reads bytes from a line it has just written.
    // Safety: a stale read between AW and W is undefined per AXI4 unless the
    // master waits for B; we mirror the cache's same-line ordering rules.
    generate if (ENABLE_LINE_BUFFER) begin : gen_lb_update
        wire [ADDR_W-1:ALIGN_LSB] r_resp_tag = rid_alignaddr_q[m_rid][ADDR_W-1:ALIGN_LSB];
        wire                      cbom_match = lb_valid
                                             & (s_arsnoop != 4'd0)
                                             & (s_araddr[ADDR_W-1:ALIGN_LSB] == lb_tag);

        // W-beat side: pull the aligned tag stored at AW time, check match.
        wire [ADDR_W-1:ALIGN_LSB] w_aligned_tag = aw_fifo_tag[aw_rd_idx];
        wire                      w_merge_match = lb_valid
                                                & (w_aligned_tag == lb_tag);

        always_ff @(posedge clk) begin
            if (rst) begin
                lb_valid <= 1'b0;
            end else begin
                // 1) Fill on wide R handshake (non-CBOM only). Only the real
                //    response beat (rlast=1) carries the requested block for
                //    r_resp_tag; a trailing extra beat (rlast=0) is the sibling
                //    block and must NOT be latched under the requested tag.
                if (m_rvalid & m_rready & m_rlast & ~cbom_outstanding_q[m_rid]) begin
                    lb_valid <= 1'b1;
                    lb_tag   <= r_resp_tag;
                    lb_data  <= m_rdata;
                end
                // 2) Merge on W beat when the FIFO-stored AW tag matches lb.
                //    Only the bytes enabled by s_wstrb mutate; rest preserved.
                if (s_wvalid & s_wready & w_merge_match) begin
                    for (int b = 0; b < NARROW_B; b++) begin
                        if (s_wstrb[b])
                            lb_data[(w_sel*NARROW_W) + b*8 +: 8] <= s_wdata[b*8 +: 8];
                    end
                end
                // 3) CBOM read invalidates the buffer (may drop the line at cache).
                if (lb_valid & s_arvalid & ar_miss_accept & cbom_match)
                    lb_valid <= 1'b0;
            end
        end
    end else begin : gen_lb_tieoff
        always_comb begin
            lb_valid = 1'b0;
            lb_tag   = '0;
            lb_data  = '0;
        end
    end endgenerate

    // ---- per-awid outstanding cap (mirrors rid_outstanding_q for writes) ----
    logic [NUM_IDS-1:0] awid_outstanding_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            awid_outstanding_q <= '0;
        end else begin
            // Set when this shim accepts a write AW for s_awid; clear when its
            // B beat drains. Cache enforces 1 in-flight per id, so this holds a
            // 2nd same-awid write at s_awready until the 1st completes.
            if (s_awvalid & s_awready)
                awid_outstanding_q[s_awid] <= 1'b1;
            if (m_bvalid & m_bready)
                awid_outstanding_q[m_bid]  <= 1'b0;
        end
    end

    // ---- track which outstanding rids are CBOM (rdata is 'x, don't cache) ----
    logic [NUM_IDS-1:0] cbom_outstanding_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            cbom_outstanding_q <= '0;
        end else begin
            if (s_arvalid & ar_miss_accept)
                cbom_outstanding_q[s_arid] <= (s_arsnoop != 4'd0);
            if (prefill_ar_fire & m_arready)
                cbom_outstanding_q[PREFILL_ID] <= 1'b0;
            if (m_rvalid & m_rready & m_rlast)
                cbom_outstanding_q[m_rid]  <= 1'b0;
        end
    end

    // ==================================================================
    // WRITE PATH
    // ==================================================================
    // Ordered FIFO of {offset, aligned_tag} (depth = MAX_OUTSTANDING_W).
    // The aligned_tag travels with the offset so the W beat can decide whether
    // to merge the bytes back into the line buffer.
    localparam int unsigned TAG_W = ADDR_W - ALIGN_LSB;
    logic [OFF_W-1:0]      aw_fifo_mem [MAX_OUTSTANDING_W-1:0];
    logic [TAG_W-1:0]      aw_fifo_tag [MAX_OUTSTANDING_W-1:0];
    logic [FIFO_AW:0]   aw_fifo_wptr, aw_fifo_rptr;
    logic               aw_fifo_full, aw_fifo_empty;

    // Low FIFO_AW pointer bits index the depth-MAX_OUTSTANDING_W FIFO memory.
    // A degenerate depth-1 FIFO has FIFO_AW=0 and a single entry always at
    // index 0; ptr[FIFO_AW-1:0] would be an ILLEGAL zero-width part-select
    // (it reads X and silently drops the W-beat byte-lane select -> lost write
    // data), so degrade it to a constant 0. The power-of-two guard above
    // accepts MAX_OUTSTANDING_W=1, so depth-1 must actually work.
    localparam int unsigned AW_IDX_W = (FIFO_AW == 0) ? 1 : FIFO_AW;
    logic [AW_IDX_W-1:0] aw_wr_idx, aw_rd_idx;
    generate
        if (FIFO_AW == 0) begin : gen_aw_idx_depth1
            assign aw_wr_idx = '0;
            assign aw_rd_idx = '0;
        end else begin : gen_aw_idx_depthn
            assign aw_wr_idx = aw_fifo_wptr[FIFO_AW-1:0];
            assign aw_rd_idx = aw_fifo_rptr[FIFO_AW-1:0];
        end
    endgenerate

    assign aw_fifo_empty = (aw_fifo_wptr == aw_fifo_rptr);
    assign aw_fifo_full  = (aw_wr_idx == aw_rd_idx)
                         & (aw_fifo_wptr[FIFO_AW]     != aw_fifo_rptr[FIFO_AW]);

    assign m_awaddr  = {s_awaddr[ADDR_W-1:ALIGN_LSB], {ALIGN_LSB{1'b0}}};
    assign m_awlen   = 8'd0;
    assign m_awsize  = 3'($clog2(BLOCK_B));
    assign m_awburst = 2'b01;
    assign m_awsnoop = (s_awsnoop == 3'b101) ? 3'b000 : s_awsnoop;
    assign m_awid    = s_awid;
    // Hold AW on the cycle that decides a prefill is needed (combinational
    // ~aw_needs_prefill) as well as while prefill is in flight (~prefill_active).
    // Per-awid outstanding cap (~awid_outstanding_q[s_awid]) mirrors the read
    // path's rid_outstanding_q: the cache permits one in-flight request per id,
    // so a 2nd same-awid write is stalled at the shim until the 1st write's B
    // returns. Without this the shim forwards overlapping same-id writes and the
    // cache sees >1 outstanding for that id (an AXI protocol violation that a
    // strict checker treats as fatal).
    assign m_awvalid = s_awvalid & ~aw_fifo_full & ~prefill_active & ~aw_needs_prefill & ~awid_outstanding_q[s_awid];
    assign s_awready = m_awready & ~aw_fifo_full & ~prefill_active & ~aw_needs_prefill & ~awid_outstanding_q[s_awid];

    always_ff @(posedge clk) begin
        if (rst) begin
            aw_fifo_wptr <= '0;
            aw_fifo_rptr <= '0;
        end else begin
            if (s_awvalid & s_awready) begin
                // RATIO==1: no sub-block offset — force 0 so the write lane select
                // m_wdata/m_wstrb[sel*NARROW_W +: NARROW_W] and the lb write-merge
                // stay in range (else odd 4-byte writes are silently dropped).
                aw_fifo_mem[aw_wr_idx] <= (RATIO == 1) ? '0 : s_awaddr[OFF_LSB +: OFF_W];
                aw_fifo_tag[aw_wr_idx] <= s_awaddr[ADDR_W-1:ALIGN_LSB];
                aw_fifo_wptr <= aw_fifo_wptr + 1'b1;
            end
            if (s_wvalid & s_wready)
                aw_fifo_rptr <= aw_fifo_rptr + 1'b1;
        end
    end

    logic [OFF_W-1:0] w_sel;
    assign w_sel = aw_fifo_mem[aw_rd_idx];

    always_comb begin
        m_wdata = '0;
        m_wstrb = '0;
        m_wdata[w_sel*NARROW_W +: NARROW_W] = s_wdata;
        m_wstrb[w_sel*NARROW_B +: NARROW_B] = s_wstrb;
    end
    assign m_wlast  = 1'b1;
    assign m_wvalid = s_wvalid & ~aw_fifo_empty;
    assign s_wready = m_wready & ~aw_fifo_empty;

    // B passthrough
    assign s_bresp  = m_bresp;
    assign s_bid    = m_bid;
    assign s_bvalid = m_bvalid;
    assign m_bready = s_bready;

`ifndef ASSERT_OFF
    // ---------- narrow-side input contract ----------
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (s_arvalid) begin
                assert (s_arlen == 8'd0)
                    else $error("tc_narrow_shim: bursty AR not supported (arlen=%0d)", s_arlen);
                assert (s_arsize == 3'($clog2(NARROW_B)))
                    else $error("tc_narrow_shim: arsize=%0d must match NARROW_W", s_arsize);
                assert ((s_araddr & (NARROW_B-1)) == '0)
                    else $error("tc_narrow_shim: AR address not NARROW_W-aligned (%h)", s_araddr);
            end
            if (s_awvalid) begin
                assert (s_awlen == 8'd0)
                    else $error("tc_narrow_shim: bursty AW not supported (awlen=%0d)", s_awlen);
                assert (s_awsize == 3'($clog2(NARROW_B)))
                    else $error("tc_narrow_shim: awsize=%0d must match NARROW_W", s_awsize);
                assert ((s_awaddr & (NARROW_B-1)) == '0)
                    else $error("tc_narrow_shim: AW address not NARROW_W-aligned (%h)", s_awaddr);
            end
            if (s_wvalid)
                assert (s_wlast)
                    else $error("tc_narrow_shim: single-beat write expected, wlast=0");
        end
    end
`endif

endmodule


// ============================================================================
// tc_read_reorder — in-order read expansion + completion-reorder buffer.
// Lets a single-id, in-order engine keep up to DEPTH reads outstanding: it
// allocates a distinct core-side id (the ROB slot index) per accepted read so
// the 1-outstanding-per-id core/cache serves them concurrently, then restores
// the engine's issue order on the response channel. READ ONLY -- writes/AW/W/B
// bypass it. Reads are single-beat (the shim issues one wide AR per narrow
// read and the core returns one already-sliced NARROW_W word), so each slot
// holds exactly one narrow word.
// ============================================================================
module tc_read_reorder
    #(
        parameter int unsigned DEPTH    = 8,
        parameter int unsigned NARROW_W = 32,
        parameter int unsigned ADDR_W   = 32,
        parameter int unsigned ID_W     = 4
    )
    (
        input  logic                clk,
        input  logic                rst,
        // ---- engine side (single-id, in-order) ----
        input  logic [ADDR_W-1:0]   e_araddr,
        input  logic [7:0]          e_arlen,
        input  logic [2:0]          e_arsize,
        input  logic [1:0]          e_arburst,
        input  logic [3:0]          e_arsnoop,
        input  logic [ID_W-1:0]     e_arid,
        input  logic                e_arvalid,
        output logic                e_arready,
        output logic [NARROW_W-1:0] e_rdata,
        output logic [1:0]          e_rresp,
        output logic                e_rlast,
        output logic [ID_W-1:0]     e_rid,
        output logic                e_rvalid,
        input  logic                e_rready,
        // ---- core side (distinct ids 0..DEPTH-1) ----
        output logic [ADDR_W-1:0]   c_araddr,
        output logic [7:0]          c_arlen,
        output logic [2:0]          c_arsize,
        output logic [1:0]          c_arburst,
        output logic [3:0]          c_arsnoop,
        output logic [ID_W-1:0]     c_arid,
        output logic                c_arvalid,
        input  logic                c_arready,
        input  logic [NARROW_W-1:0] c_rdata,
        input  logic [1:0]          c_rresp,
        input  logic                c_rlast,   // always 1 (single-beat); unused
        input  logic [ID_W-1:0]     c_rid,
        input  logic                c_rvalid,
        output logic                c_rready
    );

    localparam int unsigned PW = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    logic [DEPTH-1:0]    slot_valid;   // allocated, not yet retired
    logic [DEPTH-1:0]    slot_ready;   // response captured
    logic [NARROW_W-1:0] slot_data [DEPTH];
    logic [1:0]          slot_rresp[DEPTH];
    logic [ID_W-1:0]     slot_eid  [DEPTH];

    logic [PW-1:0]       head, tail;
    logic [PW:0]         count;
    wire                 full = (count == (PW+1)'(DEPTH));

    // Accept an engine AR when a slot is free AND the core will take it; issue
    // it to the core tagged with the slot index (a distinct core id).
    assign e_arready = c_arready & ~full;
    assign c_arvalid = e_arvalid & ~full;
    assign c_araddr  = e_araddr;
    assign c_arlen   = e_arlen;
    assign c_arsize  = e_arsize;
    assign c_arburst = e_arburst;
    assign c_arsnoop = e_arsnoop;
    assign c_arid    = ID_W'(tail);
    wire   alloc     = e_arvalid & e_arready;

    // Always accept the core response (its slot is guaranteed allocated).
    assign c_rready  = 1'b1;
    wire   cap       = c_rvalid & c_rready;
    wire [PW-1:0] cap_slot = c_rid[PW-1:0];

    // Present the engine response from the head slot, strictly in issue order.
    assign e_rvalid  = slot_valid[head] & slot_ready[head];
    assign e_rdata   = slot_data [head];
    assign e_rresp   = slot_rresp[head];
    assign e_rid     = slot_eid  [head];
    assign e_rlast   = 1'b1;
    wire   retire    = e_rvalid & e_rready;

    always_ff @(posedge clk) begin
        if (rst) begin
            slot_valid <= '0;
            slot_ready <= '0;
            head       <= '0;
            tail       <= '0;
            count      <= '0;
        end else begin
            if (alloc) begin
                slot_valid[tail] <= 1'b1;
                slot_ready[tail] <= 1'b0;
                slot_eid  [tail] <= e_arid;
                tail <= (tail == PW'(DEPTH-1)) ? '0 : (tail + 1'b1);
            end
            if (cap) begin
                slot_ready[cap_slot] <= 1'b1;
                slot_data [cap_slot] <= c_rdata;
                slot_rresp[cap_slot] <= c_rresp;
            end
            if (retire) begin
                slot_valid[head] <= 1'b0;
                slot_ready[head] <= 1'b0;
                head <= (head == PW'(DEPTH-1)) ? '0 : (head + 1'b1);
            end
            unique case ({alloc, retire})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule


// ============================================================================
// tc_narrow_shim — public shim. Thin wrapper over tc_narrow_shim_core. Default
// (READ_REORDER_DEPTH=1) instantiates the core straight through (identical to
// the historical shim). READ_REORDER_DEPTH>1 inserts tc_read_reorder on the
// read path so a single-id, in-order engine can keep >1 read outstanding while
// still seeing strict in-order, single-id completion.
// ============================================================================
module tc_narrow_shim
    #(
        parameter int unsigned NARROW_W           = 32,
        parameter int unsigned BLOCK_W            = 512,
        parameter int unsigned ID_W               = 4,
        parameter int unsigned ADDR_W             = 32,
        parameter int unsigned MAX_OUTSTANDING_W  = 16,
        parameter bit          ENABLE_LINE_BUFFER = 1'b1,
        parameter bit          PROMOTE_WMISS_TO_RW = 1'b0,
        // 1 = original 1-outstanding-per-id behavior (no reorder buffer).
        // N>1 = up to N reads outstanding on a single engine id, spread across N
        // distinct core ids (0..N-1) and reordered back to issue order. Must be
        // <= 2**ID_W-1 (the top id is reserved for the PROMOTE_WMISS prefill).
        parameter int unsigned READ_REORDER_DEPTH = 1
    )
    (
        input  logic                      clk,
        input  logic                      rst,

        // ---------------- narrow slave (accelerator) ----------------
        input  logic [ADDR_W-1:0]         s_araddr,
        input  logic [7:0]                s_arlen,
        input  logic [2:0]                s_arsize,
        input  logic [1:0]                s_arburst,
        input  logic [3:0]                s_arsnoop,
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
        input  logic [2:0]                s_awsnoop,
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

        // ---------------- wide master (TableCache front end) ----------------
        output logic [ADDR_W-1:0]         m_araddr,
        output logic [7:0]                m_arlen,
        output logic [2:0]                m_arsize,
        output logic [1:0]                m_arburst,
        output logic [3:0]                m_arsnoop,
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
        output logic [2:0]                m_awsnoop,
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

    localparam int unsigned NUM_IDS_W = 1 << ID_W;

`ifndef ASSERT_OFF
    initial begin
        assert (READ_REORDER_DEPTH >= 1)
            else $error("tc_narrow_shim: READ_REORDER_DEPTH must be >= 1");
        // Slots use core ids 0..DEPTH-1; the top id (all-ones) is the prefill id.
        assert (READ_REORDER_DEPTH <= NUM_IDS_W - 1)
            else $error("tc_narrow_shim: READ_REORDER_DEPTH (%0d) must be <= 2**ID_W-1 (%0d); widen ID_W",
                        READ_REORDER_DEPTH, NUM_IDS_W - 1);
    end
`endif

    generate
    if (READ_REORDER_DEPTH <= 1) begin : gen_passthrough
        // Original behavior: the core drives the engine ports directly.
        tc_narrow_shim_core #(
            .NARROW_W(NARROW_W), .BLOCK_W(BLOCK_W), .ID_W(ID_W), .ADDR_W(ADDR_W),
            .MAX_OUTSTANDING_W(MAX_OUTSTANDING_W), .ENABLE_LINE_BUFFER(ENABLE_LINE_BUFFER),
            .PROMOTE_WMISS_TO_RW(PROMOTE_WMISS_TO_RW)
        ) core_i (.*);
    end else begin : gen_reorder
        // Reorder buffer on the read path; write/AW/W/B bypass straight to core.
        logic [ADDR_W-1:0] r2c_araddr;  logic [7:0] r2c_arlen;  logic [2:0] r2c_arsize;
        logic [1:0]        r2c_arburst; logic [3:0] r2c_arsnoop; logic [ID_W-1:0] r2c_arid;
        logic              r2c_arvalid, r2c_arready;
        logic [NARROW_W-1:0] c2r_rdata; logic [1:0] c2r_rresp; logic c2r_rlast;
        logic [ID_W-1:0]     c2r_rid;   logic c2r_rvalid, c2r_rready;

        tc_read_reorder #(
            .DEPTH(READ_REORDER_DEPTH), .NARROW_W(NARROW_W), .ADDR_W(ADDR_W), .ID_W(ID_W)
        ) rob_i (
            .clk(clk), .rst(rst),
            .e_araddr(s_araddr), .e_arlen(s_arlen), .e_arsize(s_arsize), .e_arburst(s_arburst),
            .e_arsnoop(s_arsnoop), .e_arid(s_arid), .e_arvalid(s_arvalid), .e_arready(s_arready),
            .e_rdata(s_rdata), .e_rresp(s_rresp), .e_rlast(s_rlast), .e_rid(s_rid),
            .e_rvalid(s_rvalid), .e_rready(s_rready),
            .c_araddr(r2c_araddr), .c_arlen(r2c_arlen), .c_arsize(r2c_arsize), .c_arburst(r2c_arburst),
            .c_arsnoop(r2c_arsnoop), .c_arid(r2c_arid), .c_arvalid(r2c_arvalid), .c_arready(r2c_arready),
            .c_rdata(c2r_rdata), .c_rresp(c2r_rresp), .c_rlast(c2r_rlast), .c_rid(c2r_rid),
            .c_rvalid(c2r_rvalid), .c_rready(c2r_rready)
        );

        tc_narrow_shim_core #(
            .NARROW_W(NARROW_W), .BLOCK_W(BLOCK_W), .ID_W(ID_W), .ADDR_W(ADDR_W),
            .MAX_OUTSTANDING_W(MAX_OUTSTANDING_W), .ENABLE_LINE_BUFFER(ENABLE_LINE_BUFFER),
            .PROMOTE_WMISS_TO_RW(PROMOTE_WMISS_TO_RW)
        ) core_i (
            // read AR/R go through the reorder buffer
            .s_araddr(r2c_araddr), .s_arlen(r2c_arlen), .s_arsize(r2c_arsize), .s_arburst(r2c_arburst),
            .s_arsnoop(r2c_arsnoop), .s_arid(r2c_arid), .s_arvalid(r2c_arvalid), .s_arready(r2c_arready),
            .s_rdata(c2r_rdata), .s_rresp(c2r_rresp), .s_rlast(c2r_rlast), .s_rid(c2r_rid),
            .s_rvalid(c2r_rvalid), .s_rready(c2r_rready),
            // everything else (clk/rst, write path, wide master) straight through
            .*
        );
    end
    endgenerate
endmodule
