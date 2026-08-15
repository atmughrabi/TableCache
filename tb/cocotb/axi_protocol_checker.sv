// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// axi4_protocol_checker
// -----------------------------------------------------------------------------
// Simulation-only AXI4 protocol checker. Synthesizable-style RTL so Verilator
// can compile it without UVM / non-synthesizable concurrent assertions.
//
// Bind one instance per AXI4 bus you want to monitor. The checker has no
// effect on functional behaviour; it just emits
// $display("AXI_PC_VIOLATION ...") on detected rule violations and counts
// them in `violations` (an output port for testbench-side accumulation).
//
// We use $display (not $error) because Verilator's $error implicitly calls
// $stop, which would abort the sim on the first violation. With $display
// the sim continues and a single run surfaces ALL violations from ALL
// checker instances. The regression bash loop greps the log for the
// "AXI_PC_VIOLATION" prefix to count and bucket them per rule.
//
// Checked rules
//   B1   xVALID must be 0 during rst (all 5 channels)
//   A1   xVALID, once asserted, must remain asserted until xREADY
//        (cannot withdraw a request mid-flight)
//   A2   payload bits must remain stable while xVALID && !xREADY
//        (AR/AW: addr/len/size/burst/id ; W: data/strb/last ; R: data/last/id ;
//         B: id/resp)
//   C1   AxLEN <= 255 (AXI4 max burst length)
//   C2   AxSIZE <= $clog2(DATA_BYTES) (narrow / oversized AxSIZE)
//   C3   AxBURST != 2'b11 (reserved)
//   C4   WRAP bursts: AxLEN+1 in {2,4,8,16} and addr aligned to (LEN+1)*SIZE
//   C5   INCR bursts must not cross a 4 KiB boundary (AXI4 §A3.4.1)
//   C6   WLAST timing: WLAST=1 iff this is the (AWLEN+1)-th W beat of the
//        oldest outstanding AW
//   C7   RLAST timing per ID: RLAST=1 iff this is the (ARLEN+1)-th R beat
//        of the oldest outstanding AR for `rid`
//   D1   BVALID with no outstanding AW on `bid` (per ID)
//   D2   RVALID with no outstanding AR on `rid` (per ID)
//   D3   Accepted AR exceeds READ_ID_DEPTH for its ID
//   D4   Accepted AW exceeds WRITE_ID_DEPTH for its ID
//
// Not checked
//   Response ordering across IDs, EXCLUSIVE accesses, four-state propagation,
//   same-line read/write hazards, and per-ID response ordering when configured
//   depth exceeds one. Directed data tests cover the ordering contract.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module axi4_protocol_checker
    #(
        parameter int  ADDR_W = 32,
        parameter int  DATA_W = 32,
        parameter int  ID_W   = 4,

        // Per-instance trust knobs for testbench-driven interfaces.
        // CHECK_C6 disables WLAST timing checks.
        // CHECK_B1_RESPONSE_VALID disables reset-time RVALID/BVALID checks.
        // CHECK_RESPONSE_STABILITY disables R/B A1 and A2 checks.
        // CHECK_READ_ID_TRACKING disables C7/D2/D3 per-ID read tracking.
        parameter bit CHECK_C6                = 1'b1,
        parameter bit CHECK_B1_RESPONSE_VALID = 1'b1,
        parameter bit CHECK_RESPONSE_STABILITY = 1'b1,
        parameter bit CHECK_READ_ID_TRACKING  = 1'b1,
        parameter int unsigned READ_ID_DEPTH  = 1,
        parameter int unsigned WRITE_ID_DEPTH = 1
    )
    (
        input  logic                clk,
        input  logic                rst,

        // ---- AR ----
        input  logic [ADDR_W-1:0]   araddr,
        input  logic [7:0]          arlen,
        input  logic [2:0]          arsize,
        input  logic [1:0]          arburst,
        input  logic [ID_W-1:0]     arid,
        input  logic                arvalid,
        input  logic                arready,

        // ---- R ----
        input  logic [DATA_W-1:0]   rdata,
        input  logic [1:0]          rresp,
        input  logic                rlast,
        input  logic [ID_W-1:0]     rid,
        input  logic                rvalid,
        input  logic                rready,

        // ---- AW ----
        input  logic [ADDR_W-1:0]   awaddr,
        input  logic [7:0]          awlen,
        input  logic [2:0]          awsize,
        input  logic [1:0]          awburst,
        input  logic [ID_W-1:0]     awid,
        input  logic                awvalid,
        input  logic                awready,

        // ---- W ----
        input  logic [DATA_W-1:0]   wdata,
        input  logic [DATA_W/8-1:0] wstrb,
        input  logic                wlast,
        input  logic                wvalid,
        input  logic                wready,

        // ---- B ----
        input  logic [1:0]          bresp,
        input  logic [ID_W-1:0]     bid,
        input  logic                bvalid,
        input  logic                bready,

        // ---- diag ----
        output logic [31:0]         violations
    );

    localparam int DATA_BYTES = DATA_W / 8;
    localparam int MAX_AxSIZE = $clog2(DATA_BYTES);
    localparam int NUM_IDS    = 1 << ID_W;
    localparam int READ_ID_DEPTH_SAFE = READ_ID_DEPTH < 1 ? 1 : READ_ID_DEPTH;
    localparam int WRITE_ID_DEPTH_SAFE = WRITE_ID_DEPTH < 1 ? 1 : WRITE_ID_DEPTH;
    // Outstanding AW depth for WLAST tracking. AXI4 allows arbitrary AW
    // outstanding; the cache/shim cap at MAX_OUTSTANDING_W=16, AxiMaster
    // uses similar bounds. 64 is generous and cheap.
    localparam int AWFIFO_DEPTH = 64;
    localparam int AWFIFO_AW    = $clog2(AWFIFO_DEPTH);

    generate if (READ_ID_DEPTH < 1) begin : gen_read_depth_guard
        initial
            $fatal(1, "axi4_protocol_checker: READ_ID_DEPTH must be >= 1");
    end endgenerate
    generate if (WRITE_ID_DEPTH < 1) begin : gen_write_depth_guard
        initial
            $fatal(1, "axi4_protocol_checker: WRITE_ID_DEPTH must be >= 1");
    end endgenerate

    // Do not clear the counter during reset; reset-active B1 violations must
    // remain visible.
    integer vcount = 0;
    assign violations = vcount[31:0];

    final begin
        if (vcount != 0)
            $error("AXI protocol checker recorded %0d violation(s)", vcount);
    end

    // ------------------------------------------------------------------
    // B1: VALID must be 0 during reset
    //
    // Dedup: each channel fires at most once per reset assertion. Without
    // this, a stuck-high VALID during a long reset (e.g. 256 cycles in
    // shim_cache) would spam 256 violations per checker per channel and
    // drown the real signal. The per-channel "already reported" flag is
    // cleared when reset is deasserted so the next reset assertion can
    // re-detect violations.
    // ------------------------------------------------------------------
    logic b1_ar_reported, b1_aw_reported, b1_w_reported, b1_r_reported, b1_b_reported;
    always_ff @(posedge clk) begin
        if (!rst) begin
            b1_ar_reported <= 1'b0;
            b1_aw_reported <= 1'b0;
            b1_w_reported  <= 1'b0;
            b1_r_reported  <= 1'b0;
            b1_b_reported  <= 1'b0;
        end else begin
            if (arvalid & ~b1_ar_reported) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION B1 [%m @ %0t]: ARVALID asserted during rst", $time); b1_ar_reported <= 1'b1; end
            if (awvalid & ~b1_aw_reported) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION B1 [%m @ %0t]: AWVALID asserted during rst", $time); b1_aw_reported <= 1'b1; end
            if (wvalid  & ~b1_w_reported ) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION B1 [%m @ %0t]: WVALID asserted during rst", $time);  b1_w_reported  <= 1'b1; end
            if (CHECK_B1_RESPONSE_VALID && (rvalid  & ~b1_r_reported)) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION B1 [%m @ %0t]: RVALID asserted during rst",  $time); b1_r_reported  <= 1'b1; end
            if (CHECK_B1_RESPONSE_VALID && (bvalid  & ~b1_b_reported)) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION B1 [%m @ %0t]: BVALID asserted during rst",  $time); b1_b_reported  <= 1'b1; end
        end
    end

    // No rst-clear of `vcount` here; see header comment for why.

    // ------------------------------------------------------------------
    // A1 + A2: VALID stability and payload stability between cycles
    // ------------------------------------------------------------------
    // Sample channel state on each cycle.
    logic                arvalid_d, arready_d;
    logic [ADDR_W-1:0]   araddr_d;
    logic [7:0]          arlen_d;
    logic [2:0]          arsize_d;
    logic [1:0]          arburst_d;
    logic [ID_W-1:0]     arid_d;

    logic                awvalid_d, awready_d;
    logic [ADDR_W-1:0]   awaddr_d;
    logic [7:0]          awlen_d;
    logic [2:0]          awsize_d;
    logic [1:0]          awburst_d;
    logic [ID_W-1:0]     awid_d;

    logic                wvalid_d, wready_d, wlast_d;
    logic [DATA_W-1:0]   wdata_d;
    logic [DATA_W/8-1:0] wstrb_d;

    logic                rvalid_d, rready_d, rlast_d;
    logic [DATA_W-1:0]   rdata_d;
    logic [1:0]          rresp_d;
    logic [ID_W-1:0]     rid_d;

    logic                bvalid_d, bready_d;
    logic [1:0]          bresp_d;
    logic [ID_W-1:0]     bid_d;

    always_ff @(posedge clk) begin
        arvalid_d <= arvalid; arready_d <= arready;
        araddr_d  <= araddr;  arlen_d   <= arlen;
        arsize_d  <= arsize;  arburst_d <= arburst;
        arid_d    <= arid;

        awvalid_d <= awvalid; awready_d <= awready;
        awaddr_d  <= awaddr;  awlen_d   <= awlen;
        awsize_d  <= awsize;  awburst_d <= awburst;
        awid_d    <= awid;

        wvalid_d <= wvalid; wready_d <= wready; wlast_d <= wlast;
        wdata_d  <= wdata;  wstrb_d  <= wstrb;

        rvalid_d <= rvalid; rready_d <= rready; rlast_d <= rlast;
        rdata_d  <= rdata;  rresp_d  <= rresp;  rid_d   <= rid;

        bvalid_d <= bvalid; bready_d <= bready;
        bresp_d  <= bresp;  bid_d    <= bid;
    end

    always_ff @(posedge clk) begin
        if (!rst) begin
            // ---- A1: VALID may not be withdrawn before READY ----
            if (arvalid_d & !arready_d & !arvalid) begin
                vcount <= vcount + 1;
                $display("AXI_PC_VIOLATION A1 [%m @ %0t]: ARVALID withdrawn before ARREADY", $time);
            end
            if (awvalid_d & !awready_d & !awvalid) begin
                vcount <= vcount + 1;
                $display("AXI_PC_VIOLATION A1 [%m @ %0t]: AWVALID withdrawn before AWREADY", $time);
            end
            if (wvalid_d & !wready_d & !wvalid) begin
                vcount <= vcount + 1;
                $display("AXI_PC_VIOLATION A1 [%m @ %0t]: WVALID withdrawn before WREADY", $time);
            end
            if (CHECK_RESPONSE_STABILITY && rvalid_d & !rready_d & !rvalid) begin
                vcount <= vcount + 1;
                $display("AXI_PC_VIOLATION A1 [%m @ %0t]: RVALID withdrawn before RREADY", $time);
            end
            if (CHECK_RESPONSE_STABILITY && bvalid_d & !bready_d & !bvalid) begin
                vcount <= vcount + 1;
                $display("AXI_PC_VIOLATION A1 [%m @ %0t]: BVALID withdrawn before BREADY", $time);
            end

            // ---- A2: payload stability while VALID && !READY ----
            if (arvalid_d & !arready_d & arvalid) begin
                if (araddr  !== araddr_d ) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION A2 [%m @ %0t]: ARADDR changed while held (was %h now %h)", $time,  araddr_d, araddr); end
                if (arlen   !== arlen_d  ) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION A2 [%m @ %0t]: ARLEN changed while held", $time);  end
                if (arsize  !== arsize_d ) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION A2 [%m @ %0t]: ARSIZE changed while held", $time); end
                if (arburst !== arburst_d) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION A2 [%m @ %0t]: ARBURST changed while held", $time);end
                if (arid    !== arid_d   ) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION A2 [%m @ %0t]: ARID changed while held", $time);   end
            end
            if (awvalid_d & !awready_d & awvalid) begin
                if (awaddr  !== awaddr_d ) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION A2 [%m @ %0t]: AWADDR changed while held (was %h now %h)", $time,  awaddr_d, awaddr); end
                if (awlen   !== awlen_d  ) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION A2 [%m @ %0t]: AWLEN changed while held", $time);  end
                if (awsize  !== awsize_d ) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION A2 [%m @ %0t]: AWSIZE changed while held", $time); end
                if (awburst !== awburst_d) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION A2 [%m @ %0t]: AWBURST changed while held", $time);end
                if (awid    !== awid_d   ) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION A2 [%m @ %0t]: AWID changed while held", $time);   end
            end
            if (wvalid_d & !wready_d & wvalid) begin
                if (wdata !== wdata_d) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION A2 [%m @ %0t]: WDATA changed while held", $time); end
                if (wstrb !== wstrb_d) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION A2 [%m @ %0t]: WSTRB changed while held", $time); end
                if (wlast !== wlast_d) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION A2 [%m @ %0t]: WLAST changed while held", $time); end
            end
            if (CHECK_RESPONSE_STABILITY && rvalid_d & !rready_d & rvalid) begin
                if (rdata !== rdata_d) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION A2 [%m @ %0t]: RDATA changed while held", $time); end
                if (rresp !== rresp_d) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION A2 [%m @ %0t]: RRESP changed while held", $time); end
                if (rlast !== rlast_d) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION A2 [%m @ %0t]: RLAST changed while held", $time); end
                if (rid   !== rid_d  ) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION A2 [%m @ %0t]: RID changed while held", $time);   end
            end
            if (CHECK_RESPONSE_STABILITY && bvalid_d & !bready_d & bvalid) begin
                if (bresp !== bresp_d) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION A2 [%m @ %0t]: BRESP changed while held", $time); end
                if (bid   !== bid_d  ) begin vcount <= vcount + 1; $display("AXI_PC_VIOLATION A2 [%m @ %0t]: BID changed while held", $time);   end
            end
        end
    end

    // ------------------------------------------------------------------
    // C1-C5: AR/AW burst encoding + 4 KiB boundary
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst & arvalid & arready) begin
            // C2: AxSIZE ≤ log2(DATA_BYTES)
            if (arsize > MAX_AxSIZE[2:0]) begin
                vcount <= vcount + 1;
                $display("AXI_PC_VIOLATION C2 [%m @ %0t]: ARSIZE=%0d exceeds bus max %0d", $time, arsize, MAX_AxSIZE);
            end
            // C3: AxBURST != reserved
            if (arburst == 2'b11) begin
                vcount <= vcount + 1;
                $display("AXI_PC_VIOLATION C3 [%m @ %0t]: ARBURST reserved encoding 2'b11", $time);
            end
            // C4: WRAP length and alignment
            if (arburst == 2'b10) begin
                if (!(arlen == 1 || arlen == 3 || arlen == 7 || arlen == 15)) begin
                    vcount <= vcount + 1;
                    $display("AXI_PC_VIOLATION C4 [%m @ %0t]: WRAP ARLEN+1 must be {2,4,8,16}, got %0d", $time, arlen + 1);
                end
                if ((araddr & ((1 << arsize) - 1)) != 0) begin
                    vcount <= vcount + 1;
                    $display("AXI_PC_VIOLATION C4 [%m @ %0t]: WRAP ARADDR not aligned to ARSIZE", $time);
                end
            end
            // C5: INCR must not cross 4 KiB boundary
            if (arburst == 2'b01) begin
                automatic logic [ADDR_W-1:0] last_byte;
                last_byte = araddr + (({24'd0, arlen} + 1) << arsize) - 1;
                if (araddr[ADDR_W-1:12] != last_byte[ADDR_W-1:12]) begin
                    vcount <= vcount + 1;
                    $display("AXI_PC_VIOLATION C5 [%m @ %0t]: AR INCR crosses 4KB: start=%h end=%h len=%0d size=%0d", $time,
                           araddr, last_byte, arlen, arsize);
                end
            end
        end
        if (!rst & awvalid & awready) begin
            if (awsize > MAX_AxSIZE[2:0]) begin
                vcount <= vcount + 1;
                $display("AXI_PC_VIOLATION C2 [%m @ %0t]: AWSIZE=%0d exceeds bus max %0d", $time, awsize, MAX_AxSIZE);
            end
            if (awburst == 2'b11) begin
                vcount <= vcount + 1;
                $display("AXI_PC_VIOLATION C3 [%m @ %0t]: AWBURST reserved encoding 2'b11", $time);
            end
            if (awburst == 2'b10) begin
                if (!(awlen == 1 || awlen == 3 || awlen == 7 || awlen == 15)) begin
                    vcount <= vcount + 1;
                    $display("AXI_PC_VIOLATION C4 [%m @ %0t]: WRAP AWLEN+1 must be {2,4,8,16}, got %0d", $time, awlen + 1);
                end
                if ((awaddr & ((1 << awsize) - 1)) != 0) begin
                    vcount <= vcount + 1;
                    $display("AXI_PC_VIOLATION C4 [%m @ %0t]: WRAP AWADDR not aligned to AWSIZE", $time);
                end
            end
            if (awburst == 2'b01) begin
                automatic logic [ADDR_W-1:0] last_byte;
                last_byte = awaddr + (({24'd0, awlen} + 1) << awsize) - 1;
                if (awaddr[ADDR_W-1:12] != last_byte[ADDR_W-1:12]) begin
                    vcount <= vcount + 1;
                    $display("AXI_PC_VIOLATION C5 [%m @ %0t]: AW INCR crosses 4KB: start=%h end=%h len=%0d size=%0d", $time,
                           awaddr, last_byte, awlen, awsize);
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // C6: WLAST timing — single FIFO of AWLEN entries (per AXI4, W beats
    // are in AW arrival order across all IDs)
    //
    // Wrapped in generate-if so the FIFO and tracking FSM are entirely
    // omitted when CHECK_C6 = 0 (no FIFO maintenance overhead in the
    // simulation, no spurious violations on cocotbext-axi instances).
    // ------------------------------------------------------------------
    generate if (CHECK_C6) begin : c6_gen
    logic [7:0]              aw_len_fifo [0:AWFIFO_DEPTH-1];
    logic [AWFIFO_AW:0]      aw_wr, aw_rd; // extra bit for wrap detection
    logic [7:0]              w_remaining;
    logic                    w_burst_active;
    wire                     aw_fifo_empty = (aw_wr == aw_rd);
    wire [AWFIFO_AW-1:0]     aw_wr_idx = aw_wr[AWFIFO_AW-1:0];
    wire [AWFIFO_AW-1:0]     aw_rd_idx = aw_rd[AWFIFO_AW-1:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            aw_wr          <= '0;
            aw_rd          <= '0;
            w_remaining    <= '0;
            w_burst_active <= 1'b0;
        end else begin
            // Push AWLEN on every AW handshake
            if (awvalid & awready) begin
                aw_len_fifo[aw_wr_idx] <= awlen;
                aw_wr <= aw_wr + 1'b1;
                // overflow check
                if ((aw_wr + 1'b1) == aw_rd) begin
                    vcount <= vcount + 1;
                    $display("AXI_PC_VIOLATION INT [%m @ %0t]: AW FIFO overflow in checker (raise AWFIFO_DEPTH)", $time);
                end
            end
            // W beat: track WLAST
            if (wvalid & wready) begin
                if (!w_burst_active) begin
                    // First beat of a new burst
                    if (aw_fifo_empty & !(awvalid & awready)) begin
                        vcount <= vcount + 1;
                        $display("AXI_PC_VIOLATION C6 [%m @ %0t]: W beat with no outstanding AW", $time);
                    end else begin
                        automatic logic [7:0] this_len;
                        this_len = (aw_fifo_empty) ? awlen : aw_len_fifo[aw_rd_idx];
                        if (this_len == 0) begin
                            // single-beat burst
                            if (!wlast) begin
                                vcount <= vcount + 1;
                                $display("AXI_PC_VIOLATION C6 [%m @ %0t]: WLAST=0 on single-beat W (AWLEN=0)", $time);
                            end
                            if (!aw_fifo_empty) aw_rd <= aw_rd + 1'b1;
                        end else begin
                            if (wlast) begin
                                vcount <= vcount + 1;
                                $display("AXI_PC_VIOLATION C6 [%m @ %0t]: WLAST asserted on beat 1 of %0d-beat burst", $time, this_len + 1);
                            end
                            w_remaining    <= this_len; // beats remaining AFTER this one
                            w_burst_active <= 1'b1;
                        end
                    end
                end else begin
                    // Continuing burst
                    if (w_remaining == 1) begin
                        if (!wlast) begin
                            vcount <= vcount + 1;
                            $display("AXI_PC_VIOLATION C6 [%m @ %0t]: WLAST=0 on final beat of W burst", $time);
                        end
                        w_burst_active <= 1'b0;
                        aw_rd <= aw_rd + 1'b1;
                    end else begin
                        if (wlast) begin
                            vcount <= vcount + 1;
                            $display("AXI_PC_VIOLATION C6 [%m @ %0t]: WLAST asserted with %0d beats remaining", $time, w_remaining);
                        end
                        w_remaining <= w_remaining - 1'b1;
                    end
                end
            end
        end
    end
    end endgenerate

    // ------------------------------------------------------------------
    // ------------------------------------------------------------------
    // C7 + D2 + D3: ordered per-ID read transaction tracking
    // ------------------------------------------------------------------
    generate if (CHECK_READ_ID_TRACKING) begin : gen_read_id_tracking
        localparam int READ_PTR_W = READ_ID_DEPTH_SAFE <= 1
                                  ? 1 : $clog2(READ_ID_DEPTH_SAFE);
        localparam int READ_COUNT_W = $clog2(READ_ID_DEPTH_SAFE + 1);

        logic [8:0] r_beats [0:NUM_IDS-1][0:READ_ID_DEPTH_SAFE-1];
        logic [NUM_IDS-1:0][READ_PTR_W-1:0] r_head, r_tail;
        logic [NUM_IDS-1:0][READ_COUNT_W-1:0] r_count;

        function automatic logic [READ_PTR_W-1:0] read_ptr_next(
            input logic [READ_PTR_W-1:0] ptr
        );
            if (READ_ID_DEPTH_SAFE <= 1
                || ptr == READ_PTR_W'(READ_ID_DEPTH_SAFE-1))
                read_ptr_next = '0;
            else
                read_ptr_next = ptr + 1'b1;
        endfunction

        wire read_ar_hs = arvalid & arready;
        wire read_r_hs = rvalid & rready;
        wire read_has_transaction = r_count[rid] != '0;
        wire [8:0] read_head_beats = r_beats[rid][r_head[rid]];
        wire read_expected_final = read_has_transaction
                                 & (read_head_beats == 9'd1);
        wire read_pop = read_r_hs & read_expected_final;
        wire read_push_room =
            (r_count[arid] < READ_COUNT_W'(READ_ID_DEPTH_SAFE))
            | (read_pop & (rid == arid));
        wire read_push = read_ar_hs & read_push_room;

        always_ff @(posedge clk) begin
            if (rst) begin
                r_head <= '0;
                r_tail <= '0;
                r_count <= '0;
            end else begin
                if (read_ar_hs & ~read_push_room) begin
                    vcount <= vcount + 1;
                    $display("AXI_PC_VIOLATION D3 [%m @ %0t]: AR ID %0d exceeds configured depth %0d",
                             $time, arid, READ_ID_DEPTH);
                end

                if (read_r_hs) begin
                    if (!read_has_transaction) begin
                        vcount <= vcount + 1;
                        $display("AXI_PC_VIOLATION D2 [%m @ %0t]: RVALID for ID %0d with no outstanding AR",
                                 $time, rid);
                    end else if (read_expected_final) begin
                        if (!rlast) begin
                            vcount <= vcount + 1;
                            $display("AXI_PC_VIOLATION C7 [%m @ %0t]: RLAST=0 on final R beat for ID %0d",
                                     $time, rid);
                        end
                    end else begin
                        if (rlast) begin
                            vcount <= vcount + 1;
                            $display("AXI_PC_VIOLATION C7 [%m @ %0t]: RLAST asserted early for ID %0d (%0d beats remaining)",
                                     $time, rid, read_head_beats);
                        end
                        r_beats[rid][r_head[rid]] <= read_head_beats - 9'd1;
                    end
                end

                if (read_push) begin
                    r_beats[arid][r_tail[arid]] <= {1'b0, arlen} + 9'd1;
                    r_tail[arid] <= read_ptr_next(r_tail[arid]);
                end
                if (read_pop)
                    r_head[rid] <= read_ptr_next(r_head[rid]);

                if (read_push && read_pop && arid == rid) begin
                    r_count[arid] <= r_count[arid];
                end else begin
                    if (read_push)
                        r_count[arid] <= r_count[arid] + 1'b1;
                    if (read_pop)
                        r_count[rid] <= r_count[rid] - 1'b1;
                end
            end
        end
    end endgenerate

    // ------------------------------------------------------------------
    // D1 + D4: per-ID write response tracking
    // ------------------------------------------------------------------
    localparam int WRITE_COUNT_W = $clog2(WRITE_ID_DEPTH_SAFE + 1);
    logic [NUM_IDS-1:0][WRITE_COUNT_W-1:0] b_count;

    wire write_aw_hs = awvalid & awready;
    wire write_b_hs = bvalid & bready;
    wire write_has_transaction = b_count[bid] != '0;
    wire write_pop = write_b_hs & write_has_transaction;
    wire write_push_room =
        (b_count[awid] < WRITE_COUNT_W'(WRITE_ID_DEPTH_SAFE))
        | (write_pop & (bid == awid));
    wire write_push = write_aw_hs & write_push_room;

    always_ff @(posedge clk) begin
        if (rst) begin
            b_count <= '0;
        end else begin
            if (write_aw_hs & ~write_push_room) begin
                vcount <= vcount + 1;
                $display("AXI_PC_VIOLATION D4 [%m @ %0t]: AW ID %0d exceeds configured depth %0d",
                         $time, awid, WRITE_ID_DEPTH);
            end
            if (write_b_hs & ~write_has_transaction) begin
                vcount <= vcount + 1;
                $display("AXI_PC_VIOLATION D1 [%m @ %0t]: BVALID for ID %0d with no outstanding AW",
                         $time, bid);
            end

            if (write_push && write_pop && awid == bid) begin
                b_count[awid] <= b_count[awid];
            end else begin
                if (write_push)
                    b_count[awid] <= b_count[awid] + 1'b1;
                if (write_pop)
                    b_count[bid] <= b_count[bid] - 1'b1;
            end
        end
    end

endmodule
