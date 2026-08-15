// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Single-beat narrow-to-wide AXI shim. Reads align and slice a BLOCK_W word;
// writes place NARROW_W data/strb in one lane and force narrow WriteEvict to
// normal RMW semantics. An optional one-line buffer serves repeated reads.
// Narrow requests must be aligned, full-width, and single-beat.
//
// tc_narrow_shim_core remains one-outstanding-per-ID. The public wrapper can
// insert tc_read_reorder to map one engine ID onto multiple core IDs.
module tc_narrow_shim_core
    #(
        parameter int unsigned NARROW_W           = 32,
        parameter int unsigned BLOCK_W            = 512,
        parameter int unsigned ID_W               = 4,
        parameter int unsigned ADDR_W             = 32,
        parameter int unsigned MAX_OUTSTANDING_W  = 16,   // = 2^WRITE_ID_WIDTH at cache
        parameter bit          ENABLE_LINE_BUFFER = 1'b1,
        // Optional write-miss prefill; adds a wide read when the line is absent.
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
    // Keep a 1-bit signal at RATIO=1, but force its value to zero at capture:
    // there is no sub-block lane in that configuration.
    localparam int unsigned OFF_W     = (RATIO == 1) ? 1 : $clog2(RATIO);
    localparam int unsigned ALIGN_LSB = $clog2(BLOCK_B);
    localparam int unsigned NUM_IDS   = 1 << ID_W;
    localparam int unsigned FIFO_AW   = $clog2(MAX_OUTSTANDING_W);

    if (ID_W < 1) begin : gen_id_width_guard
        $fatal(1, "tc_narrow_shim: ID_W=%0d unsupported; must be >= 1.", ID_W);
    end
    if (NARROW_W < 8 || NARROW_W > 1024 || (NARROW_W % 8) != 0
        || (((NARROW_W/8) & ((NARROW_W/8)-1)) != 0)) begin : gen_narrow_width_guard
        $fatal(1, "tc_narrow_shim: NARROW_W=%0d unsupported; must be 8..1024 bits with power-of-two bytes/beat.", NARROW_W);
    end
    if (BLOCK_W < NARROW_W || BLOCK_W > 1024
        || (BLOCK_W % NARROW_W) != 0) begin : gen_block_width_guard
        $fatal(1, "tc_narrow_shim: BLOCK_W=%0d must be an integer multiple of NARROW_W=%0d and <=1024 bits.", BLOCK_W, NARROW_W);
    end
    if (RATIO < 1 || (RATIO & (RATIO-1)) != 0) begin : gen_ratio_guard
        $fatal(1, "tc_narrow_shim: RATIO=%0d unsupported; must be a power of two.", RATIO);
    end
    if (MAX_OUTSTANDING_W < 1
        || (MAX_OUTSTANDING_W & (MAX_OUTSTANDING_W-1)) != 0) begin : gen_write_depth_guard
        $fatal(1, "tc_narrow_shim: MAX_OUTSTANDING_W=%0d unsupported; must be a power of two >= 1.", MAX_OUTSTANDING_W);
    end
    if (ADDR_W <= ALIGN_LSB) begin : gen_addr_width_guard
        $fatal(1, "tc_narrow_shim: ADDR_W=%0d must exceed wide-block offset bits ALIGN_LSB=%0d.", ADDR_W, ALIGN_LSB);
    end
    if (PROMOTE_WMISS_TO_RW && !ENABLE_LINE_BUFFER) begin : gen_prefill_buffer_guard
        $fatal(1, "tc_narrow_shim: PROMOTE_WMISS_TO_RW requires ENABLE_LINE_BUFFER=1.");
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
    logic [NARROW_W-1:0] buf_pend_data_q;
    logic               r_buf_own_q;
    logic               buf_r_present;
    logic               buf_r_handshake;
    logic [NARROW_W-1:0] lb_selected_word;
    generate if (RATIO == 1) begin : gen_lb_word_ratio1
        assign lb_selected_word = lb_data[NARROW_W-1:0];
    end else begin : gen_lb_word_ratio_n
        assign lb_selected_word = lb_data[
            s_araddr[OFF_LSB +: OFF_W]*NARROW_W +: NARROW_W];
    end endgenerate

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
    logic ar_hold_valid_q;
    logic ar_hold_prefill_q;
    logic [ADDR_W-1:0] ar_hold_addr_q;
    logic [3:0] ar_hold_snoop_q;
    logic [ID_W-1:0] ar_hold_id_q;
    logic user_ar_candidate;
    logic user_ar_commit;
    logic ar_select_prefill;
    logic prefill_ar_handshake;
    logic aw_stall_q;

    assign ar_buf_drain_this_cycle = buf_r_handshake;
    assign ar_buf_accept  =  ar_hits_buffer  & (~buf_pend_valid_q | ar_buf_drain_this_cycle)
                           & ~rid_outstanding_q[s_arid]
                           & ~prefill_active
                           & ~ar_hold_valid_q;
    assign s_arready = ar_buf_accept | ar_miss_accept;

    // Optional write-miss prefill using the highest ID as a reserved ID.
    localparam logic [ID_W-1:0] PREFILL_ID = '1;
    logic                            prefill_resp_pending; // m_r with this id is mine
    logic [ADDR_W-1:ALIGN_LSB]       prefill_tag_q;

    wire aw_line_in_buf = lb_valid & ENABLE_LINE_BUFFER
                        & (s_awaddr[ADDR_W-1:ALIGN_LSB] == lb_tag);
    wire aw_requires_prefill = PROMOTE_WMISS_TO_RW & s_awvalid
                             & ~aw_line_in_buf;
    wire aw_start_prefill = aw_requires_prefill & ~prefill_active
                          & ~aw_stall_q
                          & ~rid_outstanding_q[PREFILL_ID]
                          & ~(s_arvalid & s_arready & (s_arid == PREFILL_ID));
    // Only a response for an issued prefill is consumed internally.
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
            if (aw_start_prefill) begin
                prefill_active     <= 1'b1;
                prefill_ar_pending <= 1'b1;
                prefill_tag_q      <= s_awaddr[ADDR_W-1:ALIGN_LSB];
            end
            if (prefill_ar_handshake) begin
                prefill_ar_pending   <= 1'b0;
                prefill_resp_pending <= 1'b1;
            end
            if (prefill_r_done) begin
                prefill_active       <= 1'b0;
                prefill_resp_pending <= 1'b0;
            end
        end
    end

    // Hold the selected AR payload while the downstream interface is stalled.
    assign user_ar_candidate = s_arvalid & ~ar_hits_buffer & ~prefill_active
                             & ~rid_outstanding_q[s_arid];
    assign user_ar_commit = user_ar_candidate
                          & ~prefill_ar_pending
                          & ~ar_hold_valid_q;
    wire prefill_ar_candidate = prefill_ar_pending
                              & ~rid_outstanding_q[PREFILL_ID];
    wire ar_candidate_valid = prefill_ar_candidate | user_ar_commit;
    wire ar_candidate_prefill = prefill_ar_candidate;
    wire [ADDR_W-1:0] ar_candidate_addr = ar_candidate_prefill
        ? {prefill_tag_q, {ALIGN_LSB{1'b0}}}
        : {s_araddr[ADDR_W-1:ALIGN_LSB], {ALIGN_LSB{1'b0}}};
    wire [3:0] ar_candidate_snoop = ar_candidate_prefill ? 4'd0 : s_arsnoop;
    wire [ID_W-1:0] ar_candidate_id = ar_candidate_prefill
        ? PREFILL_ID : s_arid;

    assign ar_select_prefill = ar_hold_valid_q
        ? ar_hold_prefill_q : ar_candidate_prefill;
    assign m_arvalid = ~rst & (ar_hold_valid_q | ar_candidate_valid);
    assign m_araddr  = ar_hold_valid_q ? ar_hold_addr_q : ar_candidate_addr;
    assign m_arlen   = 8'd0;
    assign m_arsize  = 3'($clog2(BLOCK_B));
    assign m_arburst = 2'b01;
    assign m_arsnoop = ar_hold_valid_q ? ar_hold_snoop_q : ar_candidate_snoop;
    assign m_arid    = ar_hold_valid_q ? ar_hold_id_q : ar_candidate_id;

    wire m_ar_handshake = m_arvalid & m_arready;
    assign prefill_ar_handshake = m_ar_handshake & ar_select_prefill;
    assign ar_miss_accept = user_ar_commit;

    always_ff @(posedge clk) begin
        if (rst) begin
            ar_hold_valid_q <= 1'b0;
        end else if (ar_hold_valid_q) begin
            if (m_arready)
                ar_hold_valid_q <= 1'b0;
        end else if (ar_candidate_valid & ~m_arready) begin
            ar_hold_valid_q   <= 1'b1;
            ar_hold_prefill_q <= ar_candidate_prefill;
            ar_hold_addr_q    <= ar_candidate_addr;
            ar_hold_snoop_q   <= ar_candidate_snoop;
            ar_hold_id_q      <= ar_candidate_id;
        end
    end

    // Latch per-id offset + aligned address on miss-accept and on prefill
    // AR fire (so the response fill knows the line tag).
    always_ff @(posedge clk) begin
        if (prefill_ar_handshake) begin
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
            if (prefill_ar_handshake)
                rid_outstanding_q[PREFILL_ID] <= 1'b1;
            if (m_rvalid & m_rready & m_rlast)
                rid_outstanding_q[m_rid] <= 1'b0;
            // Buffer-served R drain also frees the id.
            if (buf_r_handshake)
                rid_outstanding_q[buf_pend_id_q] <= 1'b0;
        end
    end

    // Buffer-served R slot.
    always_ff @(posedge clk) begin
        if (rst) begin
            buf_pend_valid_q <= 1'b0;
        end else begin
            if (buf_r_handshake)
                buf_pend_valid_q <= 1'b0;
            // Push on buffer-hit AR
            if (s_arvalid & ar_buf_accept) begin
                buf_pend_valid_q <= 1'b1;
                buf_pend_id_q    <= s_arid;
                // Snapshot the selected word NOW. Holding only the offset and
                // slicing live lb_data later is unsafe: cache responses can
                // delay this buffered response while a different miss refills
                // the line buffer, changing lb_data underneath it.
                buf_pend_data_q <= lb_selected_word;
            end
        end
    end

    // A stalled buffered response retains R-channel ownership until accepted.
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
    assign buf_r_word   = buf_pend_data_q;

    // Only RLAST completes the single-beat narrow request; drain other beats.
    wire cache_r_resp  = m_rvalid & ~m_r_is_prefill & m_rlast;   // real response
    wire cache_r_extra = m_rvalid & ~m_rlast;                    // trailing beat: drain only
    assign buf_r_present = r_buf_own_q | (buf_pend_valid_q & ~m_rvalid);
    assign buf_r_handshake = buf_r_present & s_rready;

    always_ff @(posedge clk) begin
        if (rst) begin
            r_buf_own_q <= 1'b0;
        end else if (r_buf_own_q) begin
            if (s_rready)
                r_buf_own_q <= 1'b0;
        end else if (buf_pend_valid_q & ~m_rvalid & ~s_rready) begin
            r_buf_own_q <= 1'b1;
        end
    end

    always_comb begin
        if (rst) begin
            s_rdata  = '0;
            s_rresp  = 2'b00;
            s_rlast  = 1'b0;
            s_rid    = '0;
            s_rvalid = 1'b0;
        end else if (buf_r_present) begin
            s_rdata  = buf_r_word;
            s_rresp  = 2'b00;
            s_rlast  = 1'b1;
            s_rid    = buf_pend_id_q;
            s_rvalid = 1'b1;
        end else if (cache_r_resp) begin
            s_rdata  = cache_r_word;
            s_rresp  = m_rresp;
            s_rlast  = 1'b1;                       // single-beat
            s_rid    = m_rid;
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
    assign m_rready = ~rst & ((s_rready & ~r_buf_own_q)
                    | m_r_is_prefill | cache_r_extra);

    // Write-side state used by the read-side line-buffer merge.
    localparam int unsigned TAG_W = ADDR_W - ALIGN_LSB;
    localparam int unsigned AW_IDX_W = (FIFO_AW == 0) ? 1 : FIFO_AW;
    logic [OFF_W-1:0] aw_fifo_mem [MAX_OUTSTANDING_W-1:0];
    logic [TAG_W-1:0] aw_fifo_tag [MAX_OUTSTANDING_W-1:0];
    logic [FIFO_AW:0] aw_fifo_wptr, aw_fifo_rptr;
    logic aw_fifo_full, aw_fifo_empty;
    logic [AW_IDX_W-1:0] aw_wr_idx, aw_rd_idx;
    logic [NUM_IDS-1:0] cbom_outstanding_q;
    logic [OFF_W-1:0] w_sel;

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
        wire lb_fill = m_rvalid & m_rready & m_rlast
                     & ~cbom_outstanding_q[m_rid];
        wire w_merge_enable = s_wvalid & s_wready
                            & ((lb_fill & (w_aligned_tag == r_resp_tag))
                               | (~lb_fill & w_merge_match));

        always_ff @(posedge clk) begin
            if (rst) begin
                lb_valid <= 1'b0;
            end else begin
                // Fill only from the requested RLAST beat of a non-CBOM read.
                if (lb_fill) begin
                    lb_valid <= 1'b1;
                    lb_tag   <= r_resp_tag;
                    lb_data  <= m_rdata;
                end
                // Merge enabled write bytes when the queued AW tag matches.
                if (w_merge_enable) begin
                    for (int b = 0; b < NARROW_B; b++) begin
                        if (s_wstrb[b])
                            lb_data[(w_sel*NARROW_W) + b*8 +: 8] <= s_wdata[b*8 +: 8];
                    end
                end
                // A matching CBOM read invalidates the buffer.
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
    always_ff @(posedge clk) begin
        if (rst) begin
            cbom_outstanding_q <= '0;
        end else begin
            if (s_arvalid & ar_miss_accept)
                cbom_outstanding_q[s_arid] <= (s_arsnoop != 4'd0);
            if (prefill_ar_handshake)
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
    // Low FIFO_AW pointer bits index the depth-MAX_OUTSTANDING_W FIFO memory.
    // A degenerate depth-1 FIFO has FIFO_AW=0 and a single entry always at
    // index 0; ptr[FIFO_AW-1:0] would be an ILLEGAL zero-width part-select
    // (it reads X and silently drops the W-beat byte-lane select -> lost write
    // data), so degrade it to a constant 0. The power-of-two guard above
    // accepts MAX_OUTSTANDING_W=1, so depth-1 must actually work.
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
    // Hold forwarding eligibility once AWVALID has been presented downstream.
    // Per-awid outstanding cap (~awid_outstanding_q[s_awid]) mirrors the read
    // path's rid_outstanding_q: the cache permits one in-flight request per id,
    // so a 2nd same-awid write is stalled at the shim until the 1st write's B
    // returns. Without this the shim forwards overlapping same-id writes and the
    // cache sees >1 outstanding for that id (an AXI protocol violation that a
    // strict checker treats as fatal).
    wire aw_forward_allowed = aw_stall_q
        | (~aw_fifo_full & ~prefill_active & ~aw_requires_prefill
           & ~awid_outstanding_q[s_awid]);
    assign m_awvalid = ~rst & s_awvalid & aw_forward_allowed;
    assign s_awready = m_awready & s_awvalid & aw_forward_allowed;

    always_ff @(posedge clk) begin
        if (rst) begin
            aw_stall_q <= 1'b0;
        end else if (s_awvalid & s_awready) begin
            aw_stall_q <= 1'b0;
        end else if (m_awvalid & ~m_awready) begin
            aw_stall_q <= 1'b1;
        end else if (!s_awvalid) begin
            aw_stall_q <= 1'b0;
        end
    end

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

    assign w_sel = aw_fifo_mem[aw_rd_idx];

    always_comb begin
        m_wdata = '0;
        m_wstrb = '0;
        m_wdata[w_sel*NARROW_W +: NARROW_W] = s_wdata;
        m_wstrb[w_sel*NARROW_B +: NARROW_B] = s_wstrb;
    end
    assign m_wlast  = 1'b1;
    assign m_wvalid  = ~rst & s_wvalid & ~aw_fifo_empty;
    assign s_wready = m_wready & ~aw_fifo_empty;

    // B passthrough
    assign s_bresp  = m_bresp;
    assign s_bid    = m_bid;
    assign s_bvalid = m_bvalid & ~rst;
    assign m_bready = s_bready & ~rst;

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
            if (prefill_ar_pending)
                assert (!rid_outstanding_q[PREFILL_ID])
                    else $error("tc_narrow_shim: pending prefill ID is already outstanding");
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

    if (ID_W < 1) begin : gen_id_width_guard
        $fatal(1, "tc_read_reorder: ID_W=%0d unsupported; must be >= 1.", ID_W);
    end
    if (DEPTH < 1 || DEPTH > (1 << ID_W)-1) begin : gen_depth_guard
        $fatal(1, "tc_read_reorder: DEPTH=%0d unsupported for ID_W=%0d; must be 1..%0d.", DEPTH, ID_W, (1 << ID_W)-1);
    end

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
    assign c_arvalid = ~rst & e_arvalid & ~full;
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
    wire [PW-1:0] cap_slot = PW'(c_rid);

    // Present the engine response from the head slot, strictly in issue order.
    assign e_rvalid  = ~rst & slot_valid[head] & slot_ready[head];
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
// Public wrapper. READ_REORDER_DEPTH=1 is direct; larger values insert the
// read reorder buffer.
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

    if (ID_W < 1) begin : gen_id_width_guard
        $fatal(1, "tc_narrow_shim: ID_W=%0d unsupported; must be >= 1.", ID_W);
    end
    // Slots use core ids 0..DEPTH-1; the all-ones id remains reserved for
    // the optional write-miss prefill path.
    if (READ_REORDER_DEPTH < 1 || READ_REORDER_DEPTH > NUM_IDS_W - 1) begin : gen_reorder_depth_guard
        $fatal(1, "tc_narrow_shim: READ_REORDER_DEPTH=%0d unsupported for ID_W=%0d; must be 1..%0d.", READ_REORDER_DEPTH, ID_W, NUM_IDS_W - 1);
    end

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
