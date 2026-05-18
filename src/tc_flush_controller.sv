// Copyright 2026 Abdullah Mughrabi
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// tc_flush_controller: whole-cache flush sequencer for l2_cache.sv.
//
// Acts as an AXI master at the cache's slave port. On `flush_req`, walks
// every line of the configured cache and issues a single-beat CBOM AR
// (default arsnoop = CleanInvalid = 4'b1001). The cache's existing
// ACE-CBOM path writes back dirty lines and drops them.
//
// Strictly sequential: one AR in flight at a time. Waits for the R last
// handshake before issuing the next AR. This is the simplest possible
// FSM and avoids any subtle race on multi-cycle rvalid behaviour the
// cache might exhibit.
//
// Reserved id: FLUSH_ID = (1<<ID_W)-1. The accelerator must not issue
// this id while flush_active=1 (gated externally by the arbiter mux).

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

        // ---- control ----
        input  logic        flush_req,        // single-cycle pulse
        input  logic[3:0]   flush_mode,       // override DEFAULT_MODE if nonzero
        output logic        flush_active,     // high while sequencing
        output logic        flush_done,       // single-cycle pulse on completion

        // ---- master-style AXI4 to the cache slave port ----
        output ar_t                       m_ar,
        output logic[ID_W-1:0]            m_arid,
        input  logic                      m_arready,
        input  r_t                        m_r,
        input  logic[BLOCK_W-1:0]         m_rdata,    // unused, here for port symmetry
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
        ISSUE    = 2'd1,   // drive AR, wait for arready
        WAIT_R   = 2'd2,   // wait for R last
        FINISH   = 2'd3
    } state_t;

    state_t                 state, state_n;
    logic[LOG2_LINES:0]     line_idx;          // 0..LINES (LINES = done)
    logic[3:0]              mode_q;

    // Suppress unused warnings for ports kept for symmetry
    logic _unused;
    assign _unused = ^m_rdata;

    // --------------------------------------------------------------
    // FSM
    // --------------------------------------------------------------
    always_comb begin
        state_n = state;
        case (state)
            IDLE:   if (flush_req)                                              state_n = ISSUE;
            ISSUE:  if (line_idx == LINES[LOG2_LINES:0])                        state_n = FINISH;
                    else if (m_ar.arvalid && m_arready)                         state_n = WAIT_R;
            WAIT_R: if (m_r.rvalid && m_rready && m_r.rlast && (m_rid == FLUSH_ID))  state_n = ISSUE;
            FINISH:                                                              state_n = IDLE;
            default:                                                             state_n = IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state    <= IDLE;
            line_idx <= '0;
            mode_q   <= DEFAULT_MODE;
        end else begin
            state <= state_n;
            if (state == IDLE && flush_req) begin
                mode_q   <= (|flush_mode) ? flush_mode : DEFAULT_MODE;
                line_idx <= '0;
            end else if (state == WAIT_R && state_n == ISSUE) begin
                // Advance to next line on R last handshake
                line_idx <= line_idx + 1'b1;
            end
        end
    end

    // --------------------------------------------------------------
    // AR drive (only in ISSUE state, only when more lines to flush)
    // --------------------------------------------------------------
    always_comb begin
        m_ar          = '0;
        m_ar.arvalid  = (state == ISSUE) && (line_idx != LINES[LOG2_LINES:0]);
        m_ar.araddr   = ADDR_BASE + ({{(32-LOG2_LINES-1){1'b0}}, line_idx} << LOG2_STRIDE);
        m_ar.arlen    = 8'd0;              // CBOM single-beat (matches test_cbom._drive_cbom)
        m_ar.arsize   = 3'($clog2(BLOCK_BYTES));
        m_ar.arburst  = 2'b01;             // INCR
        m_ar.arlock   = 1'b0;
        m_ar.arcache  = 4'b1111;
        m_ar.arprot   = 3'b000;
        m_ar.arqos    = 4'b0000;
        m_ar.arregion = 4'b0000;
        m_ar.arsnoop  = mode_q;
    end
    assign m_arid = FLUSH_ID;

    // --------------------------------------------------------------
    // R drain: only ready in WAIT_R, only for our id
    // --------------------------------------------------------------
    assign m_rready = (state == WAIT_R) && (m_rid == FLUSH_ID);

    assign flush_active = (state != IDLE);
    assign flush_done   = (state == FINISH);

endmodule
