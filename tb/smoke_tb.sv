// Smoke testbench for l2_cache: single read-miss burst + verify fill data.
// Behavioural backing memory on the mem_* side; deterministic init pattern.
`timescale 1ns/1ps

module smoke_tb
    import cache_config::*;
();
    localparam int BLOCK_W         = 32;
    localparam int LINE_W          = 8;
    localparam int WAYS            = 4;
    localparam int LINES           = 64;
    localparam int READ_ID_WIDTH   = 4;
    localparam int WRITE_ID_WIDTH  = 4;
    localparam int BYTES_PER_BLOCK = BLOCK_W/8;

    logic clk = 0;
    logic rst = 1;
    always #5 clk = ~clk;

    // Request-side signals
    ar_t                              req_ar;
    logic [READ_ID_WIDTH-1:0]         req_arid;
    logic                             req_arready;
    r_t                               req_r;
    logic [BLOCK_W-1:0]               req_rdata;
    logic [READ_ID_WIDTH-1:0]         req_rid;
    logic                             req_rready;
    aw_t                              req_aw;
    logic [WRITE_ID_WIDTH-1:0]        req_awid;
    logic                             req_awready;
    w_t                               req_w;
    logic [BLOCK_W-1:0]               req_wdata;
    logic [(BLOCK_W/8)-1:0]           req_wstrb;
    logic                             req_wready;
    b_t                               req_b;
    logic [WRITE_ID_WIDTH-1:0]        req_bid;
    logic                             req_bready;

    // ---- Mem-side signals (cache -> backing memory) ----
    ar_t                              mem_ar;
    logic [READ_ID_WIDTH:0]           mem_arid;
    logic                             mem_arready;
    r_t                               mem_r;
    logic [BLOCK_W-1:0]               mem_rdata;
    logic [READ_ID_WIDTH:0]           mem_rid;
    logic                             mem_rready;
    aw_t                              mem_aw;
    logic [WRITE_ID_WIDTH:0]          mem_awid;
    logic                             mem_awready;
    w_t                               mem_w;
    logic [BLOCK_W-1:0]               mem_wdata;
    logic [(BLOCK_W/8)-1:0]           mem_wstrb;
    logic                             mem_wready;
    b_t                               mem_b;
    logic [WRITE_ID_WIDTH:0]          mem_bid;
    logic                             mem_bready;

    // ---- DUT ----
    //GRASP region ports tied off (SRRIP-FP fallback); picked up via .* below.
    wire [31:0] grasp_high_addr_l     = 32'h0;
    wire [31:0] grasp_high_addr_h     = 32'h0;
    wire [31:0] grasp_moderate_addr_l = 32'h0;
    wire [31:0] grasp_moderate_addr_h = 32'h0;
    l2_cache #(
        .POLICY(LRU),
        .LINES(LINES),
        .LINE_W(LINE_W),
        .ADDR_RANGE_H(32'hFFFF_FFFF),
        .ADDR_RANGE_L(32'h8000_0000),
        .WAYS(WAYS),
        .INCLUDE_CBOM(1'b0),
        .INCLUDE_VICTIM(1'b0),
        .VICTIM_LINES(8),
        .DB_LATENCY(1),
        .BLOCK_W(BLOCK_W),
        .READ_ID_WIDTH(READ_ID_WIDTH),
        .WRITE_ID_WIDTH(WRITE_ID_WIDTH)
    ) dut (.*);

    // ---- Behavioural backing memory ----
    // Deterministic init: data = {addr[15:0], 16'hCAFE}
    function automatic logic [BLOCK_W-1:0] mem_init(input logic [31:0] addr);
        mem_init = {addr[15:0], 16'hCAFE};
    endfunction

    logic [BLOCK_W-1:0] backing [logic [31:0]];

    function automatic logic [BLOCK_W-1:0] mem_read(input logic [31:0] addr);
        if (backing.exists(addr)) mem_read = backing[addr];
        else                      mem_read = mem_init(addr);
    endfunction

    // -- AR/R channel (memory side): always accept; emit linear-incr burst
    assign mem_arready = 1'b1;

    logic [31:0]                 r_burst_addr;
    int                          r_burst_left;
    logic [READ_ID_WIDTH:0]      r_burst_id;
    logic                        r_busy;

    always_ff @(posedge clk) begin
        if (rst) begin
            r_busy        <= 1'b0;
            mem_r         <= '0;
            mem_rdata     <= '0;
            mem_rid       <= '0;
            r_burst_addr  <= '0;
            r_burst_left  <= 0;
            r_burst_id    <= '0;
        end else begin
            // Clear rvalid once accepted, unless re-asserting same cycle
            if (mem_r.rvalid && mem_rready)
                mem_r.rvalid <= 1'b0;

            if (r_busy && (!mem_r.rvalid || mem_rready)) begin
                mem_r.rvalid <= 1'b1;
                mem_r.rresp  <= '0;
                mem_r.rlast  <= (r_burst_left == 1);
                mem_rid      <= r_burst_id;
                mem_rdata    <= mem_read(r_burst_addr);
                r_burst_addr <= r_burst_addr + BYTES_PER_BLOCK;
                r_burst_left <= r_burst_left - 1;
                if (r_burst_left == 1) r_busy <= 1'b0;
            end else if (!r_busy && mem_ar.arvalid && mem_arready) begin
                r_busy       <= 1'b1;
                r_burst_addr <= mem_ar.araddr;
                r_burst_left <= int'(mem_ar.arlen) + 1;
                r_burst_id   <= mem_arid;
            end
        end
    end

    // -- AW/W/B channel (memory side): always accept; emit b after wlast
    assign mem_awready = 1'b1;
    assign mem_wready  = 1'b1;

    logic [31:0]                 w_addr;
    logic                        w_active;
    logic [WRITE_ID_WIDTH:0]     w_id;

    always_ff @(posedge clk) begin
        if (rst) begin
            w_active <= 1'b0;
            w_addr   <= '0;
            w_id     <= '0;
            mem_b    <= '0;
            mem_bid  <= '0;
        end else begin
            if (mem_b.bvalid && mem_bready)
                mem_b.bvalid <= 1'b0;

            if (!w_active && mem_aw.awvalid && mem_awready) begin
                w_addr   <= mem_aw.awaddr;
                w_id     <= mem_awid;
                w_active <= 1'b1;
            end

            if (w_active && mem_w.wvalid && mem_wready) begin
                automatic logic [BLOCK_W-1:0] cur = mem_read(w_addr);
                for (int b = 0; b < BYTES_PER_BLOCK; b++)
                    if (mem_wstrb[b])
                        cur[b*8 +: 8] = mem_wdata[b*8 +: 8];
                backing[w_addr] = cur;
                w_addr <= w_addr + BYTES_PER_BLOCK;
                if (mem_w.wlast) begin
                    w_active     <= 1'b0;
                    mem_b.bvalid <= 1'b1;
                    mem_b.bresp  <= '0;
                    mem_bid      <= w_id;
                end
            end
        end
    end

    // ---- Stimulus ----
    int errors     = 0;
    int beats_seen = 0;
    logic [BLOCK_W-1:0] expected;

    initial begin
        req_ar      = '0; req_arid = '0;
        req_aw      = '0; req_awid = '0;
        req_w       = '0; req_wdata = '0; req_wstrb = '0;
        req_rready  = 1'b1;
        req_bready  = 1'b1;

        repeat (10) @(posedge clk);
        rst <= 1'b0;
        repeat (5)  @(posedge clk);

        // -- Test 1: read miss, 8-beat burst at 0x80001000 --
        @(posedge clk);
        req_ar.araddr  <= 32'h8000_1000;
        req_ar.arlen   <= 8'd7;        // 8 beats
        req_ar.arsize  <= 3'b010;      // 4 bytes per beat
        req_ar.arburst <= 2'b01;       // INCR
        req_ar.arvalid <= 1'b1;
        req_arid       <= 4'h5;

        // Wait for accept
        do @(posedge clk); while (!req_arready);
        req_ar.arvalid <= 1'b0;

        // Collect 8 read beats
        beats_seen = 0;
        while (beats_seen < 8) begin
            @(posedge clk);
            if (req_r.rvalid && req_rready) begin
                // Burst is INCR linear starting at 0x1000
                expected = mem_init(32'h8000_1000 + beats_seen*BYTES_PER_BLOCK);
                $display("[%0t] R beat %0d: id=%0h data=%h exp=%h last=%b",
                         $time, beats_seen, req_rid, req_rdata, expected, req_r.rlast);
                if (req_rdata !== expected) begin
                    $display("  MISMATCH");
                    errors++;
                end
                if (req_rid !== 4'h5) begin
                    $display("  ID MISMATCH (got %0h, exp 5)", req_rid);
                    errors++;
                end
                if (beats_seen == 7 && !req_r.rlast) begin
                    $display("  RLAST not asserted on last beat");
                    errors++;
                end
                beats_seen++;
            end
        end

        repeat (50) @(posedge clk);

        if (errors == 0) $display("\n==== TEST PASSED ====");
        else             $display("\n==== TEST FAILED: %0d errors ====", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("==== TIMEOUT ====");
        $finish;
    end

    // Optional waveform dump
    initial begin
        if ($test$plusargs("waves")) begin
            $dumpfile("smoke.vcd");
            $dumpvars(0, smoke_tb);
        end
    end

endmodule
