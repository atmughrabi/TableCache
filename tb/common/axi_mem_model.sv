// Behavioural backing memory model for TableCache's mem_* AXI port.
// Always accepts ar/aw/w; emits linear-INCR read bursts; collects writes
// into a sparse assoc-array.  Deterministic init: data = {addr[15:0], 16'hCAFE}.
`timescale 1ns/1ps

module axi_mem_model
    import cache_config::*;
    #(
        parameter int BLOCK_W        = 32,
        parameter int READ_ID_WIDTH  = 5,    // L2 master side = req+1
        parameter int WRITE_ID_WIDTH = 5
    )(
        input  logic                       clk,
        input  logic                       rst,

        input  ar_t                        mem_ar,
        input  logic [READ_ID_WIDTH-1:0]   mem_arid,
        output logic                       mem_arready,
        output r_t                         mem_r,
        output logic [BLOCK_W-1:0]         mem_rdata,
        output logic [READ_ID_WIDTH-1:0]   mem_rid,
        input  logic                       mem_rready,

        input  aw_t                        mem_aw,
        input  logic [WRITE_ID_WIDTH-1:0]  mem_awid,
        output logic                       mem_awready,
        input  w_t                         mem_w,
        input  logic [BLOCK_W-1:0]         mem_wdata,
        input  logic [(BLOCK_W/8)-1:0]     mem_wstrb,
        output logic                       mem_wready,
        output b_t                         mem_b,
        output logic [WRITE_ID_WIDTH-1:0]  mem_bid,
        input  logic                       mem_bready
    );

    localparam int BYTES_PER_BLOCK = BLOCK_W/8;

    // Sparse backing store. Accessed by scoreboard via hierarchical reference.
    logic [BLOCK_W-1:0] backing [logic [31:0]];

    function automatic logic [BLOCK_W-1:0] mem_init(input logic [31:0] addr);
        mem_init = {addr[15:0], 16'hCAFE};
    endfunction

    function automatic logic [BLOCK_W-1:0] mem_read(input logic [31:0] addr);
        if (backing.exists(addr)) mem_read = backing[addr];
        else                      mem_read = mem_init(addr);
    endfunction

    // ---- AR/R channel: queue ARs so multiple outstanding fills are OK ----
    // Previously mem_arready was hardwired to 1 and ARs accepted while
    // r_busy were silently dropped, so the cache could only ever see one
    // mem read response complete per "outstanding read" group. This broke
    // every multi-outstanding test. Fix: real FIFO of ARs, with arready
    // tied to "queue not full" (16-deep, more than the cache ever has in
    // flight at the default config).
    localparam int AR_Q_DEPTH = 16;

    typedef struct packed {
        logic [31:0]              addr;
        logic [7:0]               len;
        logic [1:0]               burst;
        logic [READ_ID_WIDTH-1:0] id;
    } pending_ar_t;

    pending_ar_t ar_q [$];

    assign mem_arready = (ar_q.size() < AR_Q_DEPTH);

    logic [31:0]                  r_addr;
    logic [31:0]                  r_wrap_lo;   // wrap-region lower bound
    logic [31:0]                  r_wrap_hi_p1;// wrap-region upper bound + 1
    logic [1:0]                   r_burst;
    int                           r_left;
    logic [READ_ID_WIDTH-1:0]     r_id;
    logic                         r_busy;

    always_ff @(posedge clk) begin
        if (rst) begin
            r_busy    <= 1'b0;
            mem_r     <= '0;
            mem_rdata <= '0;
            mem_rid   <= '0;
            r_addr    <= '0;
            r_left    <= 0;
            r_id      <= '0;
            r_burst   <= '0;
            r_wrap_lo <= '0;
            r_wrap_hi_p1 <= '0;
            ar_q.delete();
        end else begin
            // Push newly-accepted AR onto the queue
            if (mem_ar.arvalid && mem_arready) begin
                pending_ar_t e;
                e.addr  = mem_ar.araddr;
                e.len   = mem_ar.arlen;
                e.burst = mem_ar.arburst;
                e.id    = mem_arid;
                ar_q.push_back(e);
            end

            if (mem_r.rvalid && mem_rready)
                mem_r.rvalid <= 1'b0;

            if (r_busy && (!mem_r.rvalid || mem_rready)) begin
                logic [31:0] next_addr;
                mem_r.rvalid <= 1'b1;
                mem_r.rresp  <= '0;
                mem_r.rlast  <= (r_left == 1);
                mem_rid      <= r_id;
                mem_rdata    <= mem_read(r_addr);
                // WRAP (2'b10): bounded ring within [r_wrap_lo, r_wrap_hi_p1).
                // INCR (2'b01) / FIXED: linear (FIXED unused by cache).
                next_addr = r_addr + BYTES_PER_BLOCK;
                if (r_burst == 2'b10 && next_addr >= r_wrap_hi_p1)
                    next_addr = r_wrap_lo;
                r_addr <= next_addr;
                r_left <= r_left - 1;
                if (r_left == 1) r_busy <= 1'b0;
            end else if (!r_busy && ar_q.size() > 0) begin
                pending_ar_t nxt = ar_q.pop_front();
                int unsigned burst_bytes = (int'(nxt.len) + 1) * BYTES_PER_BLOCK;
                r_busy  <= 1'b1;
                r_addr  <= nxt.addr;
                r_left  <= int'(nxt.len) + 1;
                r_id    <= nxt.id;
                r_burst <= nxt.burst;
                // Wrap region aligned to burst_bytes (AXI WRAP requirement).
                r_wrap_lo    <= nxt.addr & ~(burst_bytes - 1);
                r_wrap_hi_p1 <= (nxt.addr & ~(burst_bytes - 1)) + burst_bytes;
            end
        end
    end

    // ---- AW/W/B channel ----
    // Both AW and W can arrive in the same cycle (the DUT often does this).
    // Compute the address to use for each W beat combinationally: it's the
    // freshly-handshaken AW address when a new burst starts, or the
    // registered/incremented address for subsequent beats.
    assign mem_awready = 1'b1;
    assign mem_wready  = 1'b1;

    logic [31:0]                  w_addr_q;
    logic                         w_active;
    logic [WRITE_ID_WIDTH-1:0]    w_id_q;

    wire aw_handshake = mem_aw.awvalid & mem_awready;
    wire w_handshake  = mem_w.wvalid   & mem_wready;
    wire [31:0]               w_addr_now = (!w_active && aw_handshake)
                                           ? mem_aw.awaddr : w_addr_q;
    wire [WRITE_ID_WIDTH-1:0] w_id_now   = (!w_active && aw_handshake)
                                           ? mem_awid     : w_id_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            w_active <= 1'b0;
            w_addr_q <= '0;
            w_id_q   <= '0;
            mem_b    <= '0;
            mem_bid  <= '0;
        end else begin
            if (mem_b.bvalid && mem_bready)
                mem_b.bvalid <= 1'b0;

            // Latch state from AW (if new burst) or continue current
            if (aw_handshake && !w_active) begin
                w_addr_q <= mem_aw.awaddr;
                w_id_q   <= mem_awid;
                w_active <= 1'b1;
            end

            // Apply W beat (using w_addr_now so AW+W same cycle works)
            if (w_handshake && (w_active || aw_handshake)) begin
                automatic logic [BLOCK_W-1:0] cur = mem_read(w_addr_now);
                for (int b = 0; b < BYTES_PER_BLOCK; b++)
                    if (mem_wstrb[b])
                        cur[b*8 +: 8] = mem_wdata[b*8 +: 8];
                backing[w_addr_now] = cur;
                w_addr_q <= w_addr_now + BYTES_PER_BLOCK;
                if (mem_w.wlast) begin
                    w_active     <= 1'b0;
                    mem_b.bvalid <= 1'b1;
                    mem_b.bresp  <= '0;
                    mem_bid      <= w_id_now;
                end
            end
        end
    end

endmodule
