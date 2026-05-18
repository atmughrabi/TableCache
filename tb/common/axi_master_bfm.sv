// AXI master BFM for TableCache req_* port.
// Provides task-based API: do_read(), do_write_wb(), do_write_partial(),
// plus background acceptors for r/b channels that always assert ready.
// Read data is captured into `read_log` (assoc by ID) for the scoreboard.
`timescale 1ns/1ps

module axi_master_bfm
    import cache_config::*;
    #(
        parameter int BLOCK_W         = 32,
        parameter int READ_ID_WIDTH   = 4,
        parameter int WRITE_ID_WIDTH  = 4
    )(
        input  logic                          clk,
        input  logic                          rst,

        output ar_t                           req_ar,
        output logic [READ_ID_WIDTH-1:0]      req_arid,
        input  logic                          req_arready,
        input  r_t                            req_r,
        input  logic [BLOCK_W-1:0]            req_rdata,
        input  logic [READ_ID_WIDTH-1:0]      req_rid,
        output logic                          req_rready,

        output aw_t                           req_aw,
        output logic [WRITE_ID_WIDTH-1:0]     req_awid,
        input  logic                          req_awready,
        output w_t                            req_w,
        output logic [BLOCK_W-1:0]            req_wdata,
        output logic [(BLOCK_W/8)-1:0]        req_wstrb,
        input  logic                          req_wready,
        input  b_t                            req_b,
        input  logic [WRITE_ID_WIDTH-1:0]     req_bid,
        output logic                          req_bready
    );

    localparam int BYTES_PER_BLOCK = BLOCK_W/8;

    // ---- Captured responses ----
    typedef struct {
        logic [BLOCK_W-1:0] data [$];
        int                 expected_beats;
        logic               done;
    } read_record_t;
    read_record_t read_log [logic [READ_ID_WIDTH-1:0]];

    typedef struct {
        logic [1:0] resp;
        logic       done;
    } write_record_t;
    write_record_t write_log [logic [WRITE_ID_WIDTH-1:0]];

    // ---- Always ready for R and B ----
    assign req_rready = 1'b1;
    assign req_bready = 1'b1;

    // Init outputs
    initial begin
        req_ar    = '0;
        req_arid  = '0;
        req_aw    = '0;
        req_awid  = '0;
        req_w     = '0;
        req_wdata = '0;
        req_wstrb = '0;
    end

    // ---- Read response collector ----
    always @(posedge clk) begin
        if (!rst && req_r.rvalid && req_rready) begin
            if (!read_log.exists(req_rid)) begin
                $display("[%0t] BFM ERROR: rvalid for unknown rid=%0h",
                         $time, req_rid);
            end else begin
                read_log[req_rid].data.push_back(req_rdata);
                if (req_r.rlast) read_log[req_rid].done = 1;
                $display("[%0t] BFM rx: id=%0h beat#%0d data=%h last=%b",
                         $time, req_rid, read_log[req_rid].data.size()-1,
                         req_rdata, req_r.rlast);
            end
        end
    end

    // ---- Write response collector ----
    always @(posedge clk) begin
        if (!rst && req_b.bvalid && req_bready) begin
            if (!write_log.exists(req_bid)) begin
                $display("[%0t] BFM ERROR: bvalid for unknown bid=%0h",
                         $time, req_bid);
            end else begin
                write_log[req_bid].resp = req_b.bresp;
                write_log[req_bid].done = 1;
                $display("[%0t] BFM bx: id=%0h resp=%0d", $time, req_bid, req_b.bresp);
            end
        end
    end

    // ---- Debug: log AR/AW handshakes ----
    always @(posedge clk) begin
        if (!rst && req_ar.arvalid && req_arready)
            $display("[%0t] BFM ar accept: id=%0h addr=%h len=%0d",
                     $time, req_arid, req_ar.araddr, req_ar.arlen);
        if (!rst && req_aw.awvalid && req_awready)
            $display("[%0t] BFM aw accept: id=%0h addr=%h len=%0d snoop=%b",
                     $time, req_awid, req_aw.awaddr, req_aw.awlen, req_aw.awsnoop);
    end

    // -------- API --------

    // Issue a read burst.  Drives at negedge so DUT samples cleanly at posedge.
    task automatic issue_read(input logic [31:0] addr,
                              input logic [7:0]  len,         // arlen (beats-1)
                              input logic [1:0]  burst,       // 01=INCR 10=WRAP
                              input logic [READ_ID_WIDTH-1:0] id,
                              input logic [3:0]  snoop = 4'd0);
        read_record_t rec;
        rec.data.delete();
        rec.expected_beats = int'(len) + 1;
        rec.done           = 0;
        read_log[id]       = rec;

        @(negedge clk);
        req_ar.araddr  = addr;
        req_ar.arlen   = len;
        req_ar.arsize  = 3'd2;       // 4 bytes per beat
        req_ar.arburst = burst;
        req_ar.arsnoop = snoop;
        req_ar.arvalid = 1'b1;
        req_arid       = id;
        @(posedge clk iff req_arready);
        @(negedge clk);
        req_ar.arvalid = 1'b0;
        req_ar.arsnoop = 4'd0;
    endtask

    // Issue a write burst.  data[]/strb[] length must equal len+1.
    task automatic issue_write(input logic [31:0] addr,
                               input logic [7:0]  len,
                               input logic [1:0]  burst,
                               input logic [WRITE_ID_WIDTH-1:0] id,
                               input logic [BLOCK_W-1:0] data [],
                               input logic [(BLOCK_W/8)-1:0] strb [],
                               input logic [2:0]  snoop = 3'd0);
        write_record_t rec;
        rec.resp = 2'b00;
        rec.done = 0;
        write_log[id] = rec;

        // AW
        @(negedge clk);
        req_aw.awaddr  = addr;
        req_aw.awlen   = len;
        req_aw.awsize  = 3'd2;
        req_aw.awburst = burst;
        req_aw.awsnoop = snoop;
        req_aw.awvalid = 1'b1;
        req_awid       = id;
        @(posedge clk iff req_awready);
        @(negedge clk);
        req_aw.awvalid = 1'b0;
        req_aw.awsnoop = 3'd0;

        // W — keep wvalid high through entire burst, advance data per beat
        for (int i = 0; i <= int'(len); i++) begin
            @(negedge clk);
            req_wdata    = data[i];
            req_wstrb    = strb[i];
            req_w.wvalid = 1'b1;
            req_w.wlast  = (i == int'(len));
            @(posedge clk iff req_wready);
        end
        @(negedge clk);
        req_w.wvalid = 1'b0;
        req_w.wlast  = 1'b0;
    endtask

    // Convenience: blocking helpers that wait for completion + timeout
    task automatic wait_read_done(input logic [READ_ID_WIDTH-1:0] id,
                                  input int max_cycles = 1000);
        int c = 0;
        while (!read_log[id].done && c < max_cycles) begin
            @(posedge clk); c++;
        end
        if (!read_log[id].done)
            $display("[%0t] BFM TIMEOUT waiting for read id=%0h", $time, id);
    endtask

    task automatic wait_write_done(input logic [WRITE_ID_WIDTH-1:0] id,
                                   input int max_cycles = 1000);
        int c = 0;
        while (!write_log[id].done && c < max_cycles) begin
            @(posedge clk); c++;
        end
        if (!write_log[id].done)
            $display("[%0t] BFM TIMEOUT waiting for write id=%0h", $time, id);
    endtask

endmodule
