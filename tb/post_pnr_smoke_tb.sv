// SPDX-License-Identifier: Apache-2.0
// Post-PnR smoke testbench: drives one cold read-miss burst through the
// routed netlist (via post_pnr_l2cache_wrap) and asserts the response
// matches the deterministic backing-memory pattern.
//
// Run from syn/post_pnr_sim.sh, which wires up xelab + xsim with the
// UNISIM library and (optionally) SDF back-annotation.
//
// Localparams MUST match the synth-baked config; the routed netlist's
// parameters are not overridable at instantiation time.
`timescale 1ns/1ps

module post_pnr_smoke_tb
    import cache_config::*;
();
    // Tied to the syn config of v80_512K_w8_p5_period4.0_pnr1
    // (WAYS=8 LINES=1024 LINE_W=16 POLICY=GRASP DB_LATENCY=2)
    localparam int BLOCK_W         = 32;
    localparam int LINE_W          = 16;
    localparam int WAYS            = 8;
    localparam int LINES           = 1024;
    localparam int READ_ID_WIDTH   = 4;
    localparam int WRITE_ID_WIDTH  = 4;
    localparam int BYTES_PER_BLOCK = BLOCK_W/8;

    logic clk = 0;
    logic rst = 1;
    // 100 MHz clock. Real silicon is 200-250 MHz; we use 100 here so
    // SDF-backannotated runs (which slow ns/cycle dramatically) finish.
    always #5 clk = ~clk;

    ar_t req_ar, mem_ar;
    aw_t req_aw, mem_aw;
    w_t  req_w,  mem_w;
    r_t  req_r,  mem_r;
    b_t  req_b,  mem_b;
    logic [READ_ID_WIDTH-1:0]  req_arid, req_rid;
    logic [WRITE_ID_WIDTH-1:0] req_awid, req_bid;
    logic [READ_ID_WIDTH:0]    mem_arid, mem_rid;
    logic [WRITE_ID_WIDTH:0]   mem_awid, mem_bid;
    logic [BLOCK_W-1:0]        req_rdata, req_wdata, mem_rdata, mem_wdata;
    logic [BLOCK_W/8-1:0]      req_wstrb, mem_wstrb;
    logic req_arready, req_rready, req_awready, req_wready, req_bready;
    logic mem_arready, mem_rready, mem_awready, mem_wready, mem_bready;

    wire [31:0] grasp_high_addr_l     = 32'h0;
    wire [31:0] grasp_high_addr_h     = 32'h0;
    wire [31:0] grasp_moderate_addr_l = 32'h0;
    wire [31:0] grasp_moderate_addr_h = 32'h0;

    post_pnr_l2cache_wrap dut (.*);

    // Deterministic mem: returns {addr[15:0], 16'hCAFE}.
    function automatic logic [BLOCK_W-1:0] mem_init(input logic [31:0] addr);
        mem_init = {addr[15:0], 16'hCAFE};
    endfunction
    assign mem_arready = 1'b1;
    assign mem_awready = 1'b1;
    assign mem_wready  = 1'b1;
    logic [31:0] r_burst_addr;
    int          r_burst_left;
    logic        r_busy;
    always_ff @(posedge clk) begin
        if (rst) begin
            r_busy        <= 1'b0;
            mem_r.rvalid  <= 1'b0;
            mem_r.rlast   <= 1'b0;
            mem_r.rresp   <= '0;
            mem_rdata     <= '0;
            mem_rid       <= '0;
        end else begin
            if (mem_r.rvalid && mem_rready) mem_r.rvalid <= 1'b0;
            if (r_busy && (!mem_r.rvalid || mem_rready)) begin
                mem_r.rvalid <= 1'b1;
                mem_r.rresp  <= '0;
                mem_r.rlast  <= (r_burst_left == 1);
                mem_rdata    <= mem_init(r_burst_addr);
                r_burst_addr <= r_burst_addr + BYTES_PER_BLOCK;
                r_burst_left <= r_burst_left - 1;
                if (r_burst_left == 1) r_busy <= 1'b0;
            end else if (!r_busy && mem_ar.arvalid && mem_arready) begin
                r_busy       <= 1'b1;
                r_burst_addr <= mem_ar.araddr;
                r_burst_left <= int'(mem_ar.arlen) + 1;
                mem_rid      <= mem_arid;
            end
        end
    end
    assign mem_b.bvalid = 1'b0;
    assign mem_b.bresp  = 2'd0;
    assign mem_bid      = '0;

    int errors = 0;
    initial begin
        req_ar         = '0;
        req_arid       = '0;
        req_rready     = 1'b1;
        req_aw         = '0;
        req_awid       = '0;
        req_w          = '0;
        req_wdata      = '0;
        req_wstrb      = '0;
        req_bready     = 1'b1;
        rst            = 1'b1;
        #500;
        rst = 1'b0;
        #2000;

        @(posedge clk);
        req_ar.araddr  = 32'h8000_1000;
        req_ar.arlen   = 8'(LINE_W - 1);
        req_ar.arsize  = $clog2(BYTES_PER_BLOCK);
        req_ar.arburst = 2'b01;
        req_arid       = 4'h3;
        req_ar.arvalid = 1'b1;
        do @(posedge clk); while (!req_arready);
        req_ar.arvalid = 1'b0;

        fork
            begin
                int beats = 0;
                forever begin
                    @(posedge clk);
                    if (req_r.rvalid && req_rready) begin
                        $display("[%0t] beat=%0d rdata=%h rlast=%0b",
                                 $time, beats, req_rdata, req_r.rlast);
                        if (beats == 0 && req_rdata !== {16'h1000, 16'hCAFE}) begin
                            $display("ERROR: beat 0 mismatch: %h != %h",
                                     req_rdata, {16'h1000, 16'hCAFE});
                            errors++;
                        end
                        beats++;
                        if (req_r.rlast) break;
                    end
                end
                if (beats != LINE_W) begin
                    $display("ERROR: expected %0d beats, got %0d", LINE_W, beats);
                    errors++;
                end else begin
                    $display("post_pnr_smoke: burst completed in %0d beats", beats);
                end
            end
            begin
                #1_000_000;
                $display("ERROR: timeout waiting for burst");
                errors++;
            end
        join_any
        disable fork;

        #100;
        if (errors == 0) $display("post_pnr_smoke: PASS");
        else             $display("post_pnr_smoke: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
