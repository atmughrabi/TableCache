// Copyright 2026 Abdullah Mughrabi
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tc_flush_controller: whole-cache flush sequencer for l2_cache.sv.
//
// Acts as an AXI master at the cache's slave port. On `flush_req`, walks
// every line of the configured cache and issues a single-beat AR with
// `arsnoop = flush_mode` (default CleanInvalid = 4'b1001). The cache's
// existing ACE-CBOM path then writes back dirty lines and drops them.
//
// The accelerator's master must be muxed onto the cache's slave port
// alongside this controller; see INTERFACING.md §11 for the example
// arbiter. The controller asserts `flush_active` from `flush_req` until
// the last R beat is drained; integrators gate accelerator AR/AW on
// `~flush_active`.
//
// Reserved id: `FLUSH_ID = (1<<ID_W)-1`. The accelerator must avoid
// issuing this id while `flush_active=1`.
//
// One outstanding AR at a time (matches the cache's 1-outstanding-per-id
// invariant). Total cycles per flush ~= LINES * (DB_LATENCY + 4) plus
// drain time.

module tc_flush_controller

    import cache_config::*;

    #(
        parameter int unsigned LINES        = 64,
        parameter int unsigned LINE_W       = 8,
        parameter int unsigned BLOCK_W      = 32,
        parameter int unsigned ID_W         = 4,
        parameter logic[31:0]  ADDR_BASE    = 32'h80000000,
        parameter logic[3:0]   DEFAULT_MODE = 4'b1001   // CleanInvalid
    )
    (
        input  logic clk,
        input  logic rst,

        // control
        input  logic        flush_req,        // single-cycle pulse
        input  logic[3:0]   flush_mode,       // overrides DEFAULT_MODE when nonzero
        output logic        flush_active,     // high while sequencing
        output logic        flush_done,       // single-cycle pulse on completion

        // master-style AXI4 port to cache slave (mux externally with accelerator)
        output ar_t                       m_ar,
        output logic[ID_W-1:0]            m_arid,
        input  logic                      m_arready,
        input  r_t                        m_r,
        input  logic[BLOCK_W-1:0]         m_rdata,
        input  logic[ID_W-1:0]            m_rid,
        output logic                      m_rready
    );

    localparam int unsigned LOG2_LINES   = $clog2(LINES);
    localparam int unsigned BLOCK_BYTES  = BLOCK_W / 8;
    localparam int unsigned LINE_STRIDE  = LINE_W * BLOCK_BYTES;
    localparam int unsigned LOG2_STRIDE  = $clog2(LINE_STRIDE);
    localparam logic[ID_W-1:0] FLUSH_ID  = '1;

    typedef enum logic[1:0] {
        IDLE     = 2'd0,
        ISSUE    = 2'd1,
        DRAIN    = 2'd2,
        FINISH   = 2'd3
    } state_t;

    state_t                 state, state_n;
    logic[LOG2_LINES:0]     line_idx;          // 0..LINES
    logic[LOG2_LINES:0]     inflight;          // outstanding R count
    logic[3:0]              mode_q;

    // --------------------------------------------------------------
    // FSM
    // --------------------------------------------------------------
    always_comb begin
        state_n = state;
        case (state)
            IDLE:    if (flush_req)               state_n = ISSUE;
            ISSUE:   if (line_idx == LINES[LOG2_LINES:0]) state_n = DRAIN;
            DRAIN:   if (inflight == '0)          state_n = FINISH;
            FINISH:                                state_n = IDLE;
            default:                               state_n = IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state    <= IDLE;
            line_idx <= '0;
            inflight <= '0;
            mode_q   <= DEFAULT_MODE;
        end else begin
            state <= state_n;

            // Latch mode on request edge
            if (state == IDLE && flush_req)
                mode_q <= (|flush_mode) ? flush_mode : DEFAULT_MODE;

            // Reset line counter on state entry
            if (state == IDLE && state_n == ISSUE)
                line_idx <= '0;
            else if (state == ISSUE && m_ar.arvalid && m_arready)
                line_idx <= line_idx + 1'b1;

            // Track outstanding ARs: +1 on AR handshake, -1 on R rlast handshake
            if (m_ar.arvalid && m_arready && m_r.rvalid && m_rready && m_r.rlast && (m_rid == FLUSH_ID)) begin
                inflight <= inflight; // simultaneous +1/-1
            end else if (m_ar.arvalid && m_arready) begin
                inflight <= inflight + 1'b1;
            end else if (m_r.rvalid && m_rready && m_r.rlast && (m_rid == FLUSH_ID)) begin
                inflight <= inflight - 1'b1;
            end
        end
    end

    // --------------------------------------------------------------
    // AR drive
    // --------------------------------------------------------------
    always_comb begin
        m_ar           = '0;
        // Issue at most one AR per cycle. Hold valid until handshake.
        // Limit outstanding to 1 to match the cache's 1-outstanding-per-id.
        m_ar.arvalid   = (state == ISSUE) && (line_idx != LINES[LOG2_LINES:0]) && (inflight == '0);
        m_ar.araddr    = ADDR_BASE + ({{(32-LOG2_LINES-1){1'b0}}, line_idx} << LOG2_STRIDE);
        m_ar.arlen     = 8'(LINE_W-1);
        m_ar.arsize    = 3'($clog2(BLOCK_BYTES));
        m_ar.arburst   = 2'b01;             // INCR (cache also accepts WRAP; INCR simpler)
        m_ar.arlock    = 1'b0;
        m_ar.arcache   = 4'b1111;
        m_ar.arprot    = 3'b000;
        m_ar.arqos     = 4'b0000;
        m_ar.arregion  = 4'b0000;
        m_ar.arsnoop   = mode_q;
    end
    assign m_arid = FLUSH_ID;

    // --------------------------------------------------------------
    // R drain
    // --------------------------------------------------------------
    // Always ready to consume our own R beats. The external arbiter must
    // route R beats with rid == FLUSH_ID to this consumer.
    assign m_rready = (m_rid == FLUSH_ID);

    // --------------------------------------------------------------
    // Status outputs
    // --------------------------------------------------------------
    assign flush_active = (state != IDLE);
    assign flush_done   = (state == FINISH);

`ifndef ASSERT_OFF
    // The accelerator must not issue FLUSH_ID while flush is active.
    // This is enforced externally; the controller assumes it.
    flush_id_reserved:
        assert property (@(posedge clk) disable iff (rst)
            flush_active |-> (m_rid == FLUSH_ID || !(m_r.rvalid && m_rready))
        ) else $error("flush controller saw R with non-FLUSH_ID while active");
`endif

endmodule
