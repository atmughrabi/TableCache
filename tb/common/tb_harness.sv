// TB harness: clk/rst + DUT (l2_cache) + mem model + master BFM.
// Parameters mirror l2_cache's defaults.  Configurable via cfg_*.svh include.
`timescale 1ns/1ps

module tb_harness
    import cache_config::*;
();
    // ---- Config (overridable by `define before include) ----
`ifndef TC_POLICY
    `define TC_POLICY LRU
`endif
`ifndef TC_LINES
    `define TC_LINES 64
`endif
`ifndef TC_LINE_W
    `define TC_LINE_W 8
`endif
`ifndef TC_WAYS
    `define TC_WAYS 4
`endif
`ifndef TC_BLOCK_W
    `define TC_BLOCK_W 32
`endif
`ifndef TC_DB_LATENCY
    `define TC_DB_LATENCY 1
`endif
`ifndef TC_VICTIM
    `define TC_VICTIM 0
`endif
`ifndef TC_VICTIM_LINES
    `define TC_VICTIM_LINES 8
`endif
`ifndef TC_CBOM
    `define TC_CBOM 1
`endif

    localparam int BLOCK_W         = `TC_BLOCK_W;
    localparam int LINE_W          = `TC_LINE_W;
    localparam int WAYS            = `TC_WAYS;
    localparam int LINES           = `TC_LINES;
    localparam int READ_ID_WIDTH   = 4;
    localparam int WRITE_ID_WIDTH  = 4;
    localparam int BYTES_PER_BLOCK = BLOCK_W/8;
    localparam int LINE_BYTES      = LINE_W * BYTES_PER_BLOCK;

    logic clk = 0;
    logic rst = 1;
    always #5 clk = ~clk;     // 100 MHz

    // ---- Signals: req side ----
    ar_t                            req_ar;
    logic [READ_ID_WIDTH-1:0]       req_arid;
    logic                           req_arready;
    r_t                             req_r;
    logic [BLOCK_W-1:0]             req_rdata;
    logic [READ_ID_WIDTH-1:0]       req_rid;
    logic                           req_rready;
    aw_t                            req_aw;
    logic [WRITE_ID_WIDTH-1:0]      req_awid;
    logic                           req_awready;
    w_t                             req_w;
    logic [BLOCK_W-1:0]             req_wdata;
    logic [(BLOCK_W/8)-1:0]         req_wstrb;
    logic                           req_wready;
    b_t                             req_b;
    logic [WRITE_ID_WIDTH-1:0]      req_bid;
    logic                           req_bready;

    // ---- Signals: mem side (note +1 ID width) ----
    ar_t                            mem_ar;
    logic [READ_ID_WIDTH:0]         mem_arid;
    logic                           mem_arready;
    r_t                             mem_r;
    logic [BLOCK_W-1:0]             mem_rdata;
    logic [READ_ID_WIDTH:0]         mem_rid;
    logic                           mem_rready;
    aw_t                            mem_aw;
    logic [WRITE_ID_WIDTH:0]        mem_awid;
    logic                           mem_awready;
    w_t                             mem_w;
    logic [BLOCK_W-1:0]             mem_wdata;
    logic [(BLOCK_W/8)-1:0]         mem_wstrb;
    logic                           mem_wready;
    b_t                             mem_b;
    logic [WRITE_ID_WIDTH:0]        mem_bid;
    logic                           mem_bready;

    // ---- DUT ----
    l2_cache #(
        .POLICY(`TC_POLICY),
        .LINES(LINES),
        .LINE_W(LINE_W),
        .ADDR_RANGE_H(32'hFFFF_FFFF),
        .ADDR_RANGE_L(32'h8000_0000),
        .WAYS(WAYS),
        .INCLUDE_CBOM(`TC_CBOM),
        .INCLUDE_VICTIM(`TC_VICTIM),
        .VICTIM_LINES(`TC_VICTIM_LINES),
        .DB_LATENCY(`TC_DB_LATENCY),
        .BLOCK_W(BLOCK_W),
        .READ_ID_WIDTH(READ_ID_WIDTH),
        .WRITE_ID_WIDTH(WRITE_ID_WIDTH)
    ) dut (.*);

    // ---- Backing memory ----
    axi_mem_model #(
        .BLOCK_W(BLOCK_W),
        .READ_ID_WIDTH (READ_ID_WIDTH+1),
        .WRITE_ID_WIDTH(WRITE_ID_WIDTH+1)
    ) mem (
        .clk(clk), .rst(rst),
        .mem_ar(mem_ar), .mem_arid(mem_arid), .mem_arready(mem_arready),
        .mem_r(mem_r),   .mem_rdata(mem_rdata), .mem_rid(mem_rid),
        .mem_rready(mem_rready),
        .mem_aw(mem_aw), .mem_awid(mem_awid), .mem_awready(mem_awready),
        .mem_w(mem_w),   .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_wready(mem_wready),
        .mem_b(mem_b),   .mem_bid(mem_bid),    .mem_bready(mem_bready)
    );

    // ---- Master BFM ----
    axi_master_bfm #(
        .BLOCK_W(BLOCK_W),
        .READ_ID_WIDTH(READ_ID_WIDTH),
        .WRITE_ID_WIDTH(WRITE_ID_WIDTH)
    ) bfm (
        .clk(clk), .rst(rst),
        .req_ar(req_ar), .req_arid(req_arid), .req_arready(req_arready),
        .req_r(req_r),   .req_rdata(req_rdata), .req_rid(req_rid),
        .req_rready(req_rready),
        .req_aw(req_aw), .req_awid(req_awid), .req_awready(req_awready),
        .req_w(req_w),   .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .req_wready(req_wready),
        .req_b(req_b),   .req_bid(req_bid),    .req_bready(req_bready)
    );

    // ---- Reset ----
    initial begin
        repeat (10) @(posedge clk);
        rst = 1'b0;
        repeat (5)  @(posedge clk);
    end

    // ---- Global timeout (overridable via +timeout_ns=N) ----
    initial begin
        longint timeout_ns;
        timeout_ns = 100000;    // 100us default — fine for directed tests
        void'($value$plusargs("timeout_ns=%d", timeout_ns));
        #(timeout_ns);
        $display("==== GLOBAL TIMEOUT (%0d ns) ====", timeout_ns);
        $fatal;
    end

    // ---- Optional waveform ----
    initial begin
        if ($test$plusargs("waves")) begin
            $dumpfile("dump.vcd");
            $dumpvars(0, tb_harness);
        end
    end

    // ---- Helpers used by tests ----
    int errors = 0;

    // Golden data pattern matches axi_mem_model.mem_init
    function automatic logic [BLOCK_W-1:0] golden(input logic [31:0] addr);
        golden = {addr[15:0], 16'hCAFE};
    endfunction

    task automatic check_eq(input string label,
                            input logic [BLOCK_W-1:0] got,
                            input logic [BLOCK_W-1:0] exp);
        if (got !== exp) begin
            $display("  FAIL %s: got %h exp %h", label, got, exp);
            errors++;
        end
    endtask

    task automatic check_read_burst(input string             label,
                                    input logic [READ_ID_WIDTH-1:0] id,
                                    input logic [31:0]       base_addr,
                                    input int                beats);
        if (!bfm.read_log.exists(id) || !bfm.read_log[id].done) begin
            $display("  FAIL %s: read id=%0h not done", label, id);
            errors++;
            return;
        end
        if (bfm.read_log[id].data.size() != beats) begin
            $display("  FAIL %s: got %0d beats exp %0d",
                     label, bfm.read_log[id].data.size(), beats);
            errors++;
            return;
        end
        for (int i = 0; i < beats; i++) begin
            automatic logic [31:0] a = base_addr + i*BYTES_PER_BLOCK;
            check_eq($sformatf("%s beat%0d", label, i),
                     bfm.read_log[id].data[i],
                     mem.mem_read(a));
        end
    endtask

endmodule
