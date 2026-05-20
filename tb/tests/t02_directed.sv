// Tier-2 directed tests D1..D5 (canonical hot-path coverage).
// Top-level module = test runner; instantiates tb_harness, drives BFM tasks.
`timescale 1ns/1ps

module t02_directed
    import cache_config::*;
();
    tb_harness tb();

    // Convenience aliases
    `define BFM   tb.bfm
    `define MEM   tb.mem
    `define LINE_BYTES tb.LINE_BYTES
    `define BLOCK_W    tb.BLOCK_W
    `define BYTES_PER_BLOCK tb.BYTES_PER_BLOCK

    int local_err;

    // Build a full-line write payload (all-ones strobe), pattern = ~golden
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

    initial begin
        // Wait for reset deassertion
        @(negedge tb.rst);
        repeat (5) @(posedge tb.clk);

        $display("\n========== D1: read miss, 8-beat INCR burst ==========");
        local_err = tb.errors;
        `BFM.issue_read(32'h8000_1000, 8'd7, 2'b01, 4'h1);
        `BFM.wait_read_done(4'h1, 500);
        tb.check_read_burst("D1", 4'h1, 32'h8000_1000, 8);
        $display("D1: %s", (tb.errors == local_err) ? "PASS" : "FAIL");

        $display("\n========== D2: read hit (same line as D1) ==========");
        local_err = tb.errors;
        `BFM.issue_read(32'h8000_1000, 8'd7, 2'b01, 4'h2);
        `BFM.wait_read_done(4'h2, 200);
        tb.check_read_burst("D2", 4'h2, 32'h8000_1000, 8);
        $display("D2: %s", (tb.errors == local_err) ? "PASS" : "FAIL");

        $display("\n========== D2b: read miss, different line ==========");
        local_err = tb.errors;
        `BFM.issue_read(32'h8000_5000, 8'd7, 2'b01, 4'hF);
        `BFM.wait_read_done(4'hF, 200);
        tb.check_read_burst("D2b", 4'hF, 32'h8000_5000, 8);
        $display("D2b: %s", (tb.errors == local_err) ? "PASS" : "FAIL");

        $display("\n========== D3: write miss, full-line WriteBack snoop ==========");
        begin
            automatic logic [31:0] data []; automatic logic [3:0] strb [];
            automatic logic [31:0] base = 32'h8000_2000;
            local_err = tb.errors;
            build_full_line(base, data, strb);
            // awsnoop=3'b001 in this RTL means WriteBack (per l2_cache header)
            `BFM.issue_write(base, 8'd7, 2'b01, 4'h3, data, strb, 3'b001);
            `BFM.wait_write_done(4'h3, 500);
            // Read back via new ID; should hit cache (data is now resident)
            `BFM.issue_read(base, 8'd7, 2'b01, 4'h4);
            `BFM.wait_read_done(4'h4, 500);
            for (int i = 0; i < 8; i++)
                tb.check_eq($sformatf("D3 readback beat%0d", i),
                            `BFM.read_log[4'h4].data[i],
                            data[i]);
            $display("D3: %s", (tb.errors == local_err) ? "PASS" : "FAIL");
        end

        $display("\n========== D4: write miss, partial-line (RMW) ==========");
        begin
            automatic logic [31:0] data []; automatic logic [3:0] strb [];
            automatic logic [31:0] base = 32'h8000_3000;
            local_err = tb.errors;
            data = new[1];
            strb = new[1];
            data[0] = 32'hDEADBEEF;
            strb[0] = 4'b1111;
            // Single-beat write, no snoop -> forces read-modify-write fill
            `BFM.issue_write(base, 8'd0, 2'b01, 4'h5, data, strb, 3'b000);
            `BFM.wait_write_done(4'h5, 500);
            // Read full line; beat 0 = DEADBEEF, beats 1..7 = golden init
            `BFM.issue_read(base, 8'd7, 2'b01, 4'h6);
            `BFM.wait_read_done(4'h6, 500);
            tb.check_eq("D4 beat0 (written)",
                        `BFM.read_log[4'h6].data[0], 32'hDEADBEEF);
            for (int i = 1; i < 8; i++)
                tb.check_eq($sformatf("D4 beat%0d (untouched)", i),
                            `BFM.read_log[4'h6].data[i],
                            tb.golden(base + i*`BYTES_PER_BLOCK));
            $display("D4: %s", (tb.errors == local_err) ? "PASS" : "FAIL");
        end

        $display("\n========== D5: read miss with dirty eviction ==========");
        // Full coverage: 4 fills to same set, 5th read causes LRU eviction
        // of base[0] (writeback to memory), then re-read of base[0] with a
        // new id must miss, fetch the evicted writeback from mem, and
        // return correct data without hanging.
        begin
            automatic logic [31:0] set_offset = 5 * `LINE_BYTES;
            automatic logic [31:0] tag_stride = tb.LINES * `LINE_BYTES;
            automatic logic [31:0] base[5];
            automatic logic [31:0] wd [];
            automatic logic [3:0]  ws [];
            local_err = tb.errors;
            for (int t = 0; t < 5; t++)
                base[t] = 32'h8000_0000 + t*tag_stride + set_offset;

            for (int t = 0; t < 4; t++) begin
                build_full_line(base[t], wd, ws);
                `BFM.issue_write(base[t], 8'd7, 2'b01,
                                 4'h7 + t[3:0], wd, ws, 3'b001);
                `BFM.wait_write_done(4'h7 + t[3:0], 1000);
            end

            `BFM.issue_read(base[4], 8'd7, 2'b01, 4'hC);
            `BFM.wait_read_done(4'hC, 1000);
            tb.check_read_burst("D5 fifth-line", 4'hC, base[4], 8);

            // Eviction writeback time
            repeat (50) @(posedge tb.clk);

            // Verify LRU victim (base[0]) was actually written back to mem
            build_full_line(base[0], wd, ws);
            for (int i = 0; i < 8; i++) begin
                automatic logic [31:0] a = base[0] + i*`BYTES_PER_BLOCK;
                tb.check_eq($sformatf("D5 evict base[0] mem beat%0d", i),
                            `MEM.mem_read(a), wd[i]);
            end

            // Post-eviction re-read of base[0] (RTL bug #2 regression).
            // Must miss in cache, fetch from mem, return the writeback data.
            `BFM.issue_read(base[0], 8'd7, 2'b01, 4'hD);
            `BFM.wait_read_done(4'hD, 1000);
            for (int i = 0; i < 8; i++)
                tb.check_eq($sformatf("D5 re-read base[0] beat%0d", i),
                            `BFM.read_log[4'hD].data[i], wd[i]);

            $display("D5 (5th read + evict-to-mem + re-read): %s",
                     (tb.errors == local_err) ? "PASS" : "FAIL");
        end

        $display("\n========== D6: multi-outstanding reads (4 lines, 4 IDs) ==========");
        // Pipeline check: issue 4 read misses to 4 different (and previously
        // unused) lines back-to-back with 4 different IDs. The BFM's
        // issue_read returns once AR is accepted, so the next AR is offered
        // while prior reads are still in flight. All 4 must complete with
        // correct data. Stresses the FIFO arbiter and inuse_id / inuse_line
        // tables under sustained AR pressure.
        begin
            automatic logic [31:0] addrs[4];
            automatic logic [3:0]  ids[4]   = '{4'h0, 4'h1, 4'h2, 4'h3};
            local_err = tb.errors;
            // Use a fresh region (not overlapping with D1..D5)
            for (int i = 0; i < 4; i++)
                addrs[i] = 32'h8000_8000 + i*`LINE_BYTES;

            for (int i = 0; i < 4; i++)
                `BFM.issue_read(addrs[i], 8'd7, 2'b01, ids[i]);
            for (int i = 0; i < 4; i++)
                `BFM.wait_read_done(ids[i], 2000);
            for (int i = 0; i < 4; i++)
                tb.check_read_burst($sformatf("D6 line%0d", i),
                                    ids[i], addrs[i], 8);
            $display("D6: %s", (tb.errors == local_err) ? "PASS" : "FAIL");
        end

        $display("\n========== D7: same-line stall (2 reads, different IDs) ==========");
        // Two reads to the SAME line addr issued back-to-back. The BFM
        // issue_read returns once AR is accepted, so the second issue_read
        // attempts to push its AR while the first is still in flight.
        // chosen_arready for the second must be back-pressured by
        // inuse_line_table until the first finishes; then the second hits
        // the just-filled line. Both must return correct data.
        // (Sequential, not fork — fork would race on req_ar.* drivers.)
        begin
            automatic logic [31:0] base = 32'h8000_9000;
            local_err = tb.errors;
            `BFM.issue_read(base, 8'd7, 2'b01, 4'h8);  // miss; in flight
            `BFM.issue_read(base, 8'd7, 2'b01, 4'h9);  // stalled, then hit
            `BFM.wait_read_done(4'h8, 2000);
            `BFM.wait_read_done(4'h9, 2000);
            tb.check_read_burst("D7 first",  4'h8, base, 8);
            tb.check_read_burst("D7 second", 4'h9, base, 8);
            $display("D7: %s", (tb.errors == local_err) ? "PASS" : "FAIL");
        end

        $display("\n========== D8: same-ID recycle (sequential reads, same ARID) ==========");
        // Recycle the same ARID across two distinct reads. After the first
        // completes the inuse_id slot must be cleared so the second can be
        // accepted. (The BFM's read_log is keyed by ID, so we wait for the
        // first to finish before re-issuing.)  This is the same path that
        // RTL bug #2 broke; D8 is a focused regression for that fix.
        begin
            automatic logic [31:0] a0 = 32'h8000_A000;
            automatic logic [31:0] a1 = 32'h8000_B000;
            local_err = tb.errors;
            `BFM.issue_read(a0, 8'd7, 2'b01, 4'hE);
            `BFM.wait_read_done(4'hE, 2000);
            tb.check_read_burst("D8 first", 4'hE, a0, 8);
            // Re-use the SAME ID immediately
            `BFM.issue_read(a1, 8'd7, 2'b01, 4'hE);
            `BFM.wait_read_done(4'hE, 2000);
            tb.check_read_burst("D8 second (recycled ID)", 4'hE, a1, 8);
            $display("D8: %s", (tb.errors == local_err) ? "PASS" : "FAIL");
        end

        $display("\n========== D9: write-read-write-read coherency (same addr) ==========");
        // Overwrite coherency: full-line write A, read A (must see write A),
        // full-line write A' (different data), read A (must see write A').
        // Catches stale-cache bugs where a re-write doesn't invalidate the
        // already-cached line, or where the second read serves data from
        // the first fill rather than the updated line.
        begin
            automatic logic [31:0] data1 []; automatic logic [3:0] strb1 [];
            automatic logic [31:0] data2 []; automatic logic [3:0] strb2 [];
            automatic logic [31:0] base = 32'h8000_C000;
            local_err = tb.errors;
            // First write: pattern = ~golden  (uses build_full_line)
            build_full_line(base, data1, strb1);
            `BFM.issue_write(base, 8'd7, 2'b01, 4'h0, data1, strb1, 3'b001);
            `BFM.wait_write_done(4'h0, 1000);
            // Read back, must see data1
            `BFM.issue_read(base, 8'd7, 2'b01, 4'h1);
            `BFM.wait_read_done(4'h1, 1000);
            for (int i = 0; i < 8; i++)
                tb.check_eq($sformatf("D9 after-write-1 beat%0d", i),
                            `BFM.read_log[4'h1].data[i], data1[i]);
            // Second write: distinct pattern (rotate bits + 1)
            data2 = new[tb.LINE_W]; strb2 = new[tb.LINE_W];
            for (int i = 0; i < tb.LINE_W; i++) begin
                data2[i] = {data1[i][30:0], data1[i][31]} ^ 32'hA5A5_5A5A;
                strb2[i] = 4'b1111;
            end
            `BFM.issue_write(base, 8'd7, 2'b01, 4'h2, data2, strb2, 3'b001);
            `BFM.wait_write_done(4'h2, 1000);
            // Read back, must see data2 (NOT data1)
            `BFM.issue_read(base, 8'd7, 2'b01, 4'h3);
            `BFM.wait_read_done(4'h3, 1000);
            for (int i = 0; i < 8; i++)
                tb.check_eq($sformatf("D9 after-write-2 beat%0d", i),
                            `BFM.read_log[4'h3].data[i], data2[i]);
            $display("D9: %s", (tb.errors == local_err) ? "PASS" : "FAIL");
        end

        repeat (100) @(posedge tb.clk);
        if (tb.errors == 0) $display("\n==== ALL DIRECTED TESTS PASSED ====");
        else                $display("\n==== %0d FAILURES ====", tb.errors);
        $finish;
    end

endmodule
