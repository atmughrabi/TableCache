// Diagnostic variant of D5 — re-enables the post-eviction re-read
// and prints every finish-FIFO event (push, head-update, pop, clears).
`timescale 1ns/1ps

module t02_diag
    import cache_config::*;
();
    tb_harness tb();

    `define BFM   tb.bfm
    `define MEM   tb.mem
    `define LINE_BYTES tb.LINE_BYTES
    `define BLOCK_W    tb.BLOCK_W
    `define BYTES_PER_BLOCK tb.BYTES_PER_BLOCK

    int local_err;

    task automatic build_full_line(input logic [31:0] base_addr,
                                   output logic [31:0] data [],
                                   output logic [3:0]  strb []);
        data = new[tb.LINE_W];
        strb = new[tb.LINE_W];
        for (int i = 0; i < tb.LINE_W; i++) begin
            data[i] = ~tb.golden(base_addr + i*`BYTES_PER_BLOCK);
            strb[i] = 4'b1111;
        end
    endtask

    // -----------------------------------------------------------------
    // Diagnostic monitor of the finish path
    // -----------------------------------------------------------------
    logic diag_on = 0;

    // Track previous values for edge detection
    logic prev_finish_valid;
    logic [17:0] prev_finish_output;

    always @(posedge tb.clk) begin
        if (diag_on) begin
            // Push?
            if (tb.dut.finish_input.bvalid | tb.dut.finish_input.rvalid | tb.dut.finish_input.wvalid) begin
                $display("  [%0t] PUSH      b=%b r=%b w=%b bid=%h rid=%h wid=%h",
                         $time,
                         tb.dut.finish_input.bvalid, tb.dut.finish_input.rvalid, tb.dut.finish_input.wvalid,
                         tb.dut.finish_input.bid, tb.dut.finish_input.rid, tb.dut.finish_input.wid);
            end
            // Head reporting on every cycle finish_valid is set (changing or not)
            if (tb.dut.finish_valid) begin
                $display("  [%0t] HEAD      b=%b r=%b w=%b bid=%h rid=%h wid=%h | b_inv=%b r_inv=%b b_hdl=%b r_hdl=%b | evict_r=%b rdata_r=%b wdata_r=%b | f_clear=%b f_pop=%b | f_id=%h f_hash=%h",
                         $time,
                         tb.dut.finish_output.bvalid, tb.dut.finish_output.rvalid, tb.dut.finish_output.wvalid,
                         tb.dut.finish_output.bid, tb.dut.finish_output.rid, tb.dut.finish_output.wid,
                         tb.dut.bvalid_invalid, tb.dut.rvalid_invalid,
                         tb.dut.bvalid_handled, tb.dut.rvalid_handled,
                         tb.dut.evict_rdata, tb.dut.rdata_rdata, tb.dut.wdata_rdata,
                         tb.dut.finish_clear, tb.dut.finish_pop,
                         tb.dut.finish_id, tb.dut.finish_hash);
            end
            // Eviction set
            if (tb.dut.evict_set)
                $display("  [%0t] EVICT_SET id=%h", $time, tb.dut.tb_out_id);
            // Inuse table changes
            if (tb.dut.tb_advance)
                $display("  [%0t] INUSE_SET  id=%h hash=%h", $time, tb.dut.in_id, tb.dut.in_hash);
        end
    end
    // Negedge probe: settled values mid-cycle
    always @(negedge tb.clk) begin
        if (diag_on && tb.dut.finish_valid) begin
            $display("  [%0t] (neg) HEAD b=%b r=%b w=%b bid=%h rid=%h wid=%h | b_inv=%b r_inv=%b | evict_r=%b rdata_r=%b wdata_r=%b | f_clear=%b f_pop=%b | f_id=%h f_hash=%h | inuse_id=%b inuse_line=%b",
                     $time,
                     tb.dut.finish_output.bvalid, tb.dut.finish_output.rvalid, tb.dut.finish_output.wvalid,
                     tb.dut.finish_output.bid, tb.dut.finish_output.rid, tb.dut.finish_output.wid,
                     tb.dut.bvalid_invalid, tb.dut.rvalid_invalid,
                     tb.dut.evict_rdata, tb.dut.rdata_rdata, tb.dut.wdata_rdata,
                     tb.dut.finish_clear, tb.dut.finish_pop,
                     tb.dut.finish_id, tb.dut.finish_hash,
                     tb.dut.inuse_id_rdata, tb.dut.inuse_line_rdata);
        end
    end

    initial begin
        @(negedge tb.rst);
        repeat (5) @(posedge tb.clk);

        $display("\n========== DIAG: read miss with dirty eviction + re-read ==========");
        begin
            automatic logic [31:0] set_offset = 5 * `LINE_BYTES;
            automatic logic [31:0] tag_stride = tb.LINES * `LINE_BYTES;
            automatic logic [31:0] base[5];
            automatic logic [31:0] wd [];
            automatic logic [3:0]  ws [];
            for (int t = 0; t < 5; t++)
                base[t] = 32'h8000_0000 + t*tag_stride + set_offset;

            // Fill 4 ways with dirty data, IDs 0x7..0xA
            for (int t = 0; t < 4; t++) begin
                build_full_line(base[t], wd, ws);
                `BFM.issue_write(base[t], 8'd7, 2'b01,
                                 4'h7 + t[3:0], wd, ws, 3'b001);
                `BFM.wait_write_done(4'h7 + t[3:0], 1000);
            end

            // Turn on diagnostics for the 5th read + eviction
            $display("\n--- enabling diag (5th read + evict) ---");
            diag_on = 1;

            `BFM.issue_read(base[4], 8'd7, 2'b01, 4'hC);
            `BFM.wait_read_done(4'hC, 1000);
            $display("--- 5th-line read DONE ---");

            // Allow eviction to retire
            repeat (30) @(posedge tb.clk);
            $display("--- 30 cycles after fill ---");

            // Now try to re-read base[0] — this is what hangs
            $display("--- re-read base[0]=%h with id=0xD ---", base[0]);
            `BFM.issue_read(base[0], 8'd7, 2'b01, 4'hD);
            `BFM.wait_read_done(4'hD, 600);
            $display("--- re-read DONE ---");

            diag_on = 0;
            $display("DIAG complete");
        end

        repeat (50) @(posedge tb.clk);
        $finish;
    end

endmodule
