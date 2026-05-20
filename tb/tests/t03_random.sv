// Tier-3 random scoreboard test.
// Generates a configurable mix of random read/write transactions against a
// constrained address pool that forces eviction pressure (8 sets x 16 tags),
// maintains a SystemVerilog golden memory model, and checks every read
// against the model.  All transactions are sequential (issue + wait done)
// so the BFM's per-ID logs stay coherent.
//
// Plusargs (all optional):
//   +seed=N         seed for $urandom (default 1)
//   +ntxn=N         number of random transactions (default 200)
//   +ratio_rd=N     percent of txns that are reads (default 60)
//   +ratio_full=N   percent of txns that are full-line (8-beat) (default 70)
//   +verbose        print every txn
//   +timeout_ns=N   global watchdog (default in tb_harness; bump here)
//
// Default coverage: 200 txns hammer ~128 unique lines across 8 sets each
// with 4 ways. Expect ~12 evictions per set in steady state. ID space is
// 4 bits, round-robin per txn => no in-flight ID collision.

`timescale 1ns/1ps

module t03_random
    import cache_config::*;
();
    tb_harness tb();

    `define BFM tb.bfm
    `define MEM tb.mem
    `define LINE_BYTES tb.LINE_BYTES
    `define BYTES_PER_BLOCK tb.BYTES_PER_BLOCK

    // ---- Config (from plusargs) ----
    int  seed_val      = 1;
    int  n_txn         = 200;
    int  ratio_rd_pct  = 60;
    int  ratio_full_pct= 70;
    bit  verbose;

    // ---- Address pool ----
    // Set bits live at addr[10:5]; tag bits at addr[30:11].
    // 8 sets x 16 tags = 128 unique lines, 4 ways/set => heavy eviction.
    localparam int           NSETS     = 8;
    localparam int           NTAGS     = 16;
    localparam logic [31:0]  ADDR_BASE = 32'h8000_0000;

    function automatic logic [31:0] line_addr_of(input int s, input int t);
        line_addr_of = ADDR_BASE + (32'(t) << 11) + (32'(s) << 5);
    endfunction

    // ---- Golden memory ----
    // golden[addr] = expected 32-bit block at byte-address `addr` (always
    // BYTES_PER_BLOCK-aligned). If absent, defaults to {addr[15:0], 16'hCAFE}
    // matching the mem-model's init function.
    logic [31:0] golden [logic [31:0]];

    function automatic logic [31:0] get_golden(input logic [31:0] addr);
        if (golden.exists(addr)) get_golden = golden[addr];
        else                     get_golden = tb.golden(addr);
    endfunction

    // ---- Statistics ----
    int n_reads  = 0;
    int n_writes = 0;
    int n_full   = 0;
    int n_single = 0;
    int n_beats_checked = 0;

    // ---- Helper: parse plusargs once ----
    task automatic parse_plusargs();
        void'($value$plusargs("seed=%d",       seed_val));
        void'($value$plusargs("ntxn=%d",       n_txn));
        void'($value$plusargs("ratio_rd=%d",   ratio_rd_pct));
        void'($value$plusargs("ratio_full=%d", ratio_full_pct));
        verbose = $test$plusargs("verbose");
        $display("[t03] cfg: seed=%0d ntxn=%0d ratio_rd=%0d%% ratio_full=%0d%% verbose=%0d",
                 seed_val, n_txn, ratio_rd_pct, ratio_full_pct, verbose);
    endtask

    // ---- One random transaction ----
    task automatic do_random_txn(input int idx);
        automatic int           roll_op   = $urandom_range(0, 99);
        automatic bit           is_read   = (roll_op < ratio_rd_pct);
        automatic int           roll_full = $urandom_range(0, 99);
        automatic bit           is_full   = (roll_full < ratio_full_pct);
        automatic int           s         = $urandom_range(0, NSETS-1);
        automatic int           tg        = $urandom_range(0, NTAGS-1);
        automatic logic [31:0]  la        = line_addr_of(s, tg);
        automatic logic [31:0]  txn_addr;
        automatic logic [7:0]   len;
        automatic logic [3:0]   id        = idx[3:0];

        if (is_full) begin
            txn_addr = la;
            len      = 8'd7;
            n_full++;
        end else begin
            automatic int beat = $urandom_range(0, 7);
            txn_addr = la + beat*`BYTES_PER_BLOCK;
            len      = 8'd0;
            n_single++;
        end

        if (verbose)
            $display("[t03][%0d] %s addr=%h len=%0d id=%0h set=%0d tag=%0d",
                     idx, is_read?"RD":"WR", txn_addr, len, id, s, tg);

        if (is_read) begin
            n_reads++;
            `BFM.issue_read(txn_addr, len, 2'b01, id);
            `BFM.wait_read_done(id, 5000);
            if (!`BFM.read_log[id].done) begin
                $display("[t03][%0d] FAIL: read id=%0h addr=%h TIMEOUT",
                         idx, id, txn_addr);
                tb.errors++;
                return;
            end
            if (`BFM.read_log[id].data.size() != int'(len) + 1) begin
                $display("[t03][%0d] FAIL: read id=%0h got %0d beats exp %0d",
                         idx, id, `BFM.read_log[id].data.size(), int'(len)+1);
                tb.errors++;
                return;
            end
            for (int i = 0; i <= int'(len); i++) begin
                automatic logic [31:0] a   = txn_addr + i*`BYTES_PER_BLOCK;
                automatic logic [31:0] exp = get_golden(a);
                automatic logic [31:0] got = `BFM.read_log[id].data[i];
                n_beats_checked++;
                if (got !== exp) begin
                    $display("[t03][%0d] FAIL: rd addr=%h beat%0d got=%h exp=%h",
                             idx, txn_addr, i, got, exp);
                    tb.errors++;
                end
            end
        end else begin
            automatic logic [31:0]  data [];
            automatic logic [3:0]   strb [];
            automatic int           beats = int'(len) + 1;
            automatic logic [2:0]   snoop = is_full ? 3'b001 : 3'b000;
            n_writes++;
            data = new[beats];
            strb = new[beats];
            for (int i = 0; i < beats; i++) begin
                automatic logic [31:0] a = txn_addr + i*`BYTES_PER_BLOCK;
                automatic logic [31:0] d = $urandom();
                data[i]   = d;
                strb[i]   = 4'b1111;       // always full-byte writes
                golden[a] = d;             // update model
            end
            `BFM.issue_write(txn_addr, len, 2'b01, id, data, strb, snoop);
            `BFM.wait_write_done(id, 5000);
            if (!`BFM.write_log[id].done) begin
                $display("[t03][%0d] FAIL: write id=%0h addr=%h TIMEOUT",
                         idx, id, txn_addr);
                tb.errors++;
            end
        end
    endtask

    // ---- Final readback: every address we've written, verify cache state ----
    task automatic final_readback();
        automatic int idx = 0;
        $display("[t03] final readback of %0d unique addrs", golden.num());
        foreach (golden[a]) begin
            automatic logic [3:0]  id  = idx[3:0];
            automatic logic [31:0] exp = golden[a];
            automatic logic [31:0] got;
            `BFM.issue_read(a, 8'd0, 2'b01, id);
            `BFM.wait_read_done(id, 5000);
            if (!`BFM.read_log[id].done) begin
                $display("[t03] FAIL: final read addr=%h TIMEOUT", a);
                tb.errors++;
            end else begin
                got = `BFM.read_log[id].data[0];
                n_beats_checked++;
                if (got !== exp) begin
                    $display("[t03] FAIL: final addr=%h got=%h exp=%h",
                             a, got, exp);
                    tb.errors++;
                end
            end
            idx++;
        end
    endtask

    initial begin
        parse_plusargs();
        void'($urandom(seed_val));    // seed once for this process

        @(negedge tb.rst);
        repeat (5) @(posedge tb.clk);

        for (int t = 0; t < n_txn; t++) begin
            do_random_txn(t);
        end

        repeat (50) @(posedge tb.clk);
        final_readback();
        repeat (50) @(posedge tb.clk);

        $display("[t03] stats: reads=%0d writes=%0d full=%0d single=%0d beats_checked=%0d",
                 n_reads, n_writes, n_full, n_single, n_beats_checked);

        if (tb.errors == 0)
            $display("\n==== t03 PASS (seed=%0d ntxn=%0d) ====",
                     seed_val, n_txn);
        else
            $display("\n==== t03 FAIL: %0d errors (seed=%0d) ====",
                     tb.errors, seed_val);
        $finish;
    end

endmodule
