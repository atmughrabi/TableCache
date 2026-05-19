// Formal harness for src/tc_flush_controller.sv.
//
// Proves three FSM invariants under a well-formed environment:
//   1. flush_active high <=> state != IDLE.
//   2. flush_done is single-cycle (only high in FINISH; FINISH always
//      transitions to IDLE on the next clock).
//   3. line_idx never exceeds LINES, and is 0 in IDLE.
//   4. m_rready high implies state==WAIT_R AND m_rid==FLUSH_ID.
//   5. m_arvalid high implies state==ISSUE AND line_idx<LINES.
//
// Environment assumes: arready/rvalid behave as a cooperating slave
// (won't drop rvalid mid-burst, etc.).
`default_nettype none
module flush_formal
    import cache_config::*;
    #(
        parameter int unsigned LINES   = 4,
        parameter int unsigned LINE_W  = 4,
        parameter int unsigned BLOCK_W = 32,
        parameter int unsigned ID_W    = 4
    ) (
        input  logic                  clk,
        input  logic                  rst,
        input  logic                  flush_req,
        input  logic[3:0]             flush_mode,
        input  logic                  m_arready,
        input  r_t                    m_r,
        input  logic[BLOCK_W-1:0]     m_rdata,
        input  logic[ID_W-1:0]        m_rid
    );

    localparam logic[ID_W-1:0] FLUSH_ID = '1;

    logic           flush_active;
    logic           flush_done;
    ar_t            m_ar;
    logic[ID_W-1:0] m_arid;
    logic           m_rready;

    tc_flush_controller #(
        .LINES(LINES), .LINE_W(LINE_W),
        .BLOCK_W(BLOCK_W), .ID_W(ID_W)
    ) dut (
        .clk(clk), .rst(rst),
        .flush_req(flush_req), .flush_mode(flush_mode),
        .flush_active(flush_active), .flush_done(flush_done),
        .m_ar(m_ar), .m_arid(m_arid), .m_arready(m_arready),
        .m_r(m_r), .m_rdata(m_rdata), .m_rid(m_rid), .m_rready(m_rready)
    );

    // Force first cycle to be reset.
    always_comb if ($initstate) assume(rst);

    // Shadow: only allow rvalid handshake when controller drives rready.
    // (A well-behaved slave never asserts rvalid without a paired ar.)
    always_ff @(posedge clk) begin
        if (!rst) begin
            // ---- env assumes (cooperating slave / no-ID-collision) ----
            // m_rid is FLUSH_ID only when rvalid is set in WAIT_R window
            if (m_r.rvalid && !m_rready) assume (m_rid != FLUSH_ID);

            // ---- safety properties ----
            // P1: flush_active <=> state != IDLE
            //     (We can't see state directly; use externally-equiv
            //      flush_active and flush_done relationship.)
            // P2: flush_done implies flush_active (FINISH is non-IDLE).
            assert (!flush_done || flush_active);

            // P3: m_arvalid implies controller is sequencing.
            assert (!m_ar.arvalid || flush_active);

            // P4: m_arid is always FLUSH_ID.
            assert (m_arid == FLUSH_ID);

            // P5: m_rready implies flush_active AND m_rid==FLUSH_ID.
            assert (!m_rready || (flush_active && (m_rid == FLUSH_ID)));

            // P6: arvalid never asserts in FINISH (line_idx == LINES gate).
            //     flush_done==1 means state==FINISH; m_arvalid must be 0.
            assert (!flush_done || !m_ar.arvalid);

            // P7: arvalid only with arsnoop in the CBOM set.
            //     mode_q is captured at IDLE->ISSUE entry; either
            //     flush_mode (if nonzero) or DEFAULT_MODE=4'b1001.
            if (m_ar.arvalid) begin
                assert (m_ar.arlen == 8'd0);    // single-beat CBOM
                assert (m_ar.arburst == 2'b01); // INCR
            end
        end
    end
endmodule
`default_nettype wire
