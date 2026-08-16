// Formal harness for src/tc_flush_controller.sv.
//
// Proves request framing, ordered traversal, exact request count, response
// gating, single-cycle completion, and bounded completion under a slave that
// accepts each request and returns its response on the following cycle.
//
// Environment assumes: arready/rvalid behave as a cooperating slave
// (won't drop rvalid mid-burst, etc.).
`default_nettype none
module flush_formal
    import cache_config::*;
    #(
        parameter int unsigned LINES   = 4,
        parameter int unsigned WAYS    = 2,
        parameter int unsigned LINE_W  = 4,
        parameter int unsigned BLOCK_W = 32,
        parameter int unsigned ID_W    = 4,
        parameter int unsigned ADDR_W  = 32
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
    localparam int unsigned TOTAL_LINES = LINES * WAYS;
    localparam int unsigned LINE_STRIDE = LINE_W * (BLOCK_W / 8);
    localparam int unsigned LOG2_STRIDE = $clog2(LINE_STRIDE);
    localparam int unsigned COUNT_W = $clog2(TOTAL_LINES + 1);
    localparam int unsigned MAX_ACTIVE_CYCLES = 2*TOTAL_LINES + 2;
    localparam int unsigned AGE_W = $clog2(MAX_ACTIVE_CYCLES + 1);
    localparam logic[ADDR_W-1:0] ADDR_BASE = ADDR_W'(32'h8000_0000);

    logic           flush_active;
    logic           flush_done;
    ar_t            m_ar;
    logic[ID_W-1:0] m_arid;
    logic           m_rready;
    logic           response_due;
    logic           tracking;
    logic           flush_done_d;
    logic[COUNT_W-1:0] accepted_count;
    logic[AGE_W-1:0] active_age;
    logic[3:0]       expected_mode;

    tc_flush_controller #(
        .LINES(LINES), .WAYS(WAYS), .LINE_W(LINE_W),
        .BLOCK_W(BLOCK_W), .ID_W(ID_W),
        .ADDR_W(ADDR_W), .ADDR_BASE(ADDR_BASE)
    ) dut (
        .clk(clk), .rst(rst),
        .flush_req(flush_req), .flush_mode(flush_mode),
        .flush_active(flush_active), .flush_done(flush_done),
        .m_ar(m_ar), .m_arid(m_arid), .m_arready(m_arready),
        .m_r(m_r), .m_rdata(m_rdata), .m_rid(m_rid), .m_rready(m_rready)
    );

    // Force first cycle to be reset.
    always_comb if ($initstate) assume(rst);

    always_ff @(posedge clk) begin
        if (rst) begin
            response_due   <= 1'b0;
            tracking       <= 1'b0;
            flush_done_d    <= 1'b0;
            accepted_count <= '0;
            active_age     <= '0;
            expected_mode  <= 4'b1011;
        end else begin
            if (m_ar.arvalid)
                assume (m_arready);
            if (response_due) begin
                assume (m_r.rvalid);
                assume (m_r.rlast);
                assume (m_rid == FLUSH_ID);
            end
            if (flush_active)
                assume (!flush_req);

            response_due <= m_ar.arvalid && m_arready;
            flush_done_d <= flush_done;

            assert (!flush_done || flush_active);
            assert (!(flush_done && flush_done_d));
            assert (tracking == flush_active);
            cover (flush_done && accepted_count == TOTAL_LINES);
            assert (!m_ar.arvalid || flush_active);
            assert (m_arid == FLUSH_ID);
            assert (!m_rready || (flush_active && (m_rid == FLUSH_ID)));
            assert (!flush_done || !m_ar.arvalid);

            if (!flush_active && flush_req) begin
                tracking       <= 1'b1;
                accepted_count <= '0;
                active_age     <= '0;
                expected_mode  <= (|flush_mode) ? flush_mode : 4'b1011;
            end else if (tracking) begin
                assert (accepted_count <= TOTAL_LINES);
                if (m_ar.arvalid && m_arready)
                    accepted_count <= accepted_count + 1'b1;

                if (flush_done) begin
                    assert (accepted_count == TOTAL_LINES);
                    tracking <= 1'b0;
                end else begin
                    assert (active_age < MAX_ACTIVE_CYCLES);
                    active_age <= active_age + 1'b1;
                end
            end

            if (m_ar.arvalid) begin
                assert (m_ar.arlen == 8'd0);
                assert (m_ar.arburst == 2'b01);
                assert (m_ar.arsnoop == expected_mode);
                assert (m_ar.araddr[ADDR_W-1:0]
                    == ADDR_BASE + (ADDR_W'(accepted_count) << LOG2_STRIDE));
            end
        end
    end
endmodule
`default_nettype wire
