// Copyright 2024 Chris Keilbart
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may
// not use this file except in compliance with the License, or, at your option,
// the Apache License version 2.0. You may obtain a copy of the License at
// https://solderpad.org/licenses/SHL-2.1/. Unless required by applicable law
// or agreed to in writing, any work distributed under the License is
// distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied. See the License for the specific language
// governing permissions and limitations under the License.

module l2_cache

    import cache_config::*;

    #(
        parameter replacement_policy_t POLICY = LRU,
        parameter int unsigned LINES = 512, //Lines per way
        parameter int unsigned LINE_W = 8, //Number of blocks per line
        parameter logic[CACHE_ADDR_MAX_W-1:0] ADDR_RANGE_H = 64'h0000_0000_FFFF_FFFF, //Cache address space
        parameter logic[CACHE_ADDR_MAX_W-1:0] ADDR_RANGE_L = 64'h0000_0000_8000_0000, //Must be NAPOT
        parameter int unsigned WAYS = 4, //Also known as sets
        parameter logic RANDOM_USE_EVICT = 1,
        parameter logic RRIP_HP = 1,
        parameter int unsigned RRPV_WIDTH = 2,
        parameter int unsigned ADDR_W = 32,
        parameter logic INCLUDE_CBOM = 1, //Whether ACE cache block management operations (CleanInvalid, CleanShared, MakeInvalid) are supported
        parameter logic INCLUDE_VICTIM = 1, //Victim cache
        parameter int unsigned VICTIM_LINES = 8, //Victim cache capacity
        parameter int unsigned DB_LATENCY = 1, //Latency in cycles of databank, must be >= 1
        parameter int unsigned BLOCK_W = 32, //Data width
        parameter int unsigned READ_ID_WIDTH = 4, //AXI read ID width
        parameter int unsigned WRITE_ID_WIDTH = 4, //AXI write ID width
        parameter logic DATABANK_SDP = 0, //1=SDP databank (URAM-friendly, ~1-3% throughput cost); 0=TDP (default)
        //1 = register SDP URAM write-port inputs (+1 cycle write commit
        //latency; only meaningful with DATABANK_SDP=1). See sdp_ram_uram.sv.
        parameter logic SDP_WRITE_INPUT_REG = 0,
        //Length of the URAM/BRAM cascade in the databank. Vivado-default
        //is 8; shorter values produce more parallel cascades at the cost
        //of additional inter-cascade muxing. Range: 1..8 (URAM288 cap).
        parameter int unsigned CASCADE_DEPTH = 8,
        // Number of SDP data banks. Must be a power of two dividing LINES.
        parameter int unsigned N_BANKS = 1,
        // GRASP: number of independent address windows per reuse class
        // (default 1 = original single-window high/moderate behaviour).
        parameter int unsigned GRASP_HIGH_REGIONS = 1,
        parameter int unsigned GRASP_MODERATE_REGIONS = 1
    )
    (
        input logic clk,
        input logic rst,

        // Runtime-configurable GRASP address region bounds (0 = disabled).
        // Packed as GRASP_HIGH_REGIONS / GRASP_MODERATE_REGIONS windows;
        // window i = bits [i*ADDR_W +: ADDR_W].
        input logic[GRASP_HIGH_REGIONS*ADDR_W-1:0] grasp_high_addr_l,
        input logic[GRASP_HIGH_REGIONS*ADDR_W-1:0] grasp_high_addr_h,
        input logic[GRASP_MODERATE_REGIONS*ADDR_W-1:0] grasp_moderate_addr_l,
        input logic[GRASP_MODERATE_REGIONS*ADDR_W-1:0] grasp_moderate_addr_h,

        input ar_t req_ar,
        input logic[READ_ID_WIDTH-1:0] req_arid,
        output logic req_arready,
        output r_t req_r,
        output logic[BLOCK_W-1:0] req_rdata,
        output logic[READ_ID_WIDTH-1:0] req_rid,
        input req_rready,
        input aw_t req_aw,
        input logic[WRITE_ID_WIDTH-1:0] req_awid,
        output logic req_awready,
        input w_t req_w,
        input logic[BLOCK_W-1:0] req_wdata,
        input logic[(BLOCK_W/8)-1:0] req_wstrb,
        output logic req_wready,
        output b_t req_b,
        output logic[WRITE_ID_WIDTH-1:0] req_bid,
        input logic req_bready,

        output ar_t mem_ar,
        output logic[READ_ID_WIDTH:0] mem_arid,
        input logic mem_arready,
        input r_t mem_r,
        input logic[BLOCK_W-1:0] mem_rdata,
        input logic[READ_ID_WIDTH:0] mem_rid,
        output mem_rready,
        output aw_t mem_aw,
        output logic[WRITE_ID_WIDTH:0] mem_awid,
        input logic mem_awready,
        output w_t mem_w,
        output logic[BLOCK_W-1:0] mem_wdata,
        output logic[(BLOCK_W/8)-1:0] mem_wstrb,
        input logic mem_wready,
        input b_t mem_b,
        input logic[WRITE_ID_WIDTH:0] mem_bid,
        output logic mem_bready
    );

    ////////////////////////////////////////////////////
    //L2 cache
    //This is a write back allocating cache and has the following limitations:
    //Only supports addresses within the specified range
    //No requests that cross cache lines
    //No fixed bursts
    //No support for shareablility domains
    //For arsnoop, only supports CleanInvalid, CleanShared, MakeInvalid ACE transactions; everything else is treated as a regular request
    //For awsnoop, only supports WriteEvict; everything else treated as a regular (i.e. possibly narrow) write
    //For performance, WriteEvict should be signalled if the request updates an entire cache line

    //These parameters can be customized
    localparam int unsigned REQ_FIFO_DEPTH = 8; //For input to DB and AR channel
    localparam int unsigned WDATA_FIFO_DEPTH = 32;
    localparam int unsigned AWID_FIFO_DEPTH = 8;
    localparam int unsigned FINISH_FIFO_DEPTH = 4;
    localparam int unsigned CBOM_FIFO_DEPTH = 4;
    localparam int unsigned OUT_FIFO_DEPTH = 2; //Should be >1 for performance
    localparam int unsigned MAX_ADDR_HASH_WIDTH = 8; //Line addresses are hashed to at most this width

    // The extra span bit keeps a base-0 full-width range from overflowing:
    // [0, 2^ADDR_W-1] has span 2^ADDR_W.
    localparam logic[ADDR_W-1:0] ADDR_RANGE_H_USED = ADDR_RANGE_H[ADDR_W-1:0];
    localparam logic[ADDR_W-1:0] ADDR_RANGE_L_USED = ADDR_RANGE_L[ADDR_W-1:0];
    localparam logic[ADDR_W:0] RANGE_ONE = {{ADDR_W{1'b0}}, 1'b1};
    localparam logic[ADDR_W:0] RANGE_SPAN =
        ({1'b0, ADDR_RANGE_H_USED} - {1'b0, ADDR_RANGE_L_USED}) + RANGE_ONE;
    localparam int unsigned RANGE_SPAN_LOG2 = $clog2(RANGE_SPAN);
    localparam int unsigned BLOCK_ADDR_W = $clog2(LINE_W);
    localparam int unsigned LINE_ADDR_W = $clog2(LINES);
    localparam int signed TAG_W_CALC = int'(RANGE_SPAN_LOG2)
        - int'($clog2(LINES)) - int'($clog2(LINE_W))
        - int'($clog2(BLOCK_W/8));
    localparam int unsigned TAG_W = TAG_W_CALC > 0 ? TAG_W_CALC : 1;

    // Address reconstruction requires a naturally aligned power-of-two range.
    if (ADDR_W < 32 || ADDR_W > CACHE_ADDR_MAX_W) begin : gen_addr_width_guard
        $fatal(1, "l2_cache: ADDR_W=%0d unsupported; must be 32..%0d.", ADDR_W, CACHE_ADDR_MAX_W);
    end
    if ((ADDR_RANGE_H >> ADDR_W) != '0 || (ADDR_RANGE_L >> ADDR_W) != '0) begin : gen_range_width_guard
        $fatal(1, "l2_cache: ADDR_RANGE_L/H set bits above ADDR_W=%0d.", ADDR_W);
    end
    if (ADDR_RANGE_H_USED < ADDR_RANGE_L_USED) begin : gen_range_order_guard
        $fatal(1, "l2_cache: ADDR_RANGE_H=0x%0h is below ADDR_RANGE_L=0x%0h.", ADDR_RANGE_H_USED, ADDR_RANGE_L_USED);
    end
    if ((RANGE_SPAN & (RANGE_SPAN - RANGE_ONE)) != '0) begin : gen_range_size_guard
        $fatal(1, "l2_cache: cacheable range [0x%0h,0x%0h] span 0x%0h is not a power of two; ADDR_RANGE must be NAPOT.", ADDR_RANGE_L_USED, ADDR_RANGE_H_USED, RANGE_SPAN);
    end
    if (({1'b0, ADDR_RANGE_L_USED} & (RANGE_SPAN - RANGE_ONE)) != '0) begin : gen_range_alignment_guard
        $fatal(1, "l2_cache: ADDR_RANGE_L=0x%0h not aligned to span 0x%0h; ADDR_RANGE must be NAPOT (base aligned to size).", ADDR_RANGE_L_USED, RANGE_SPAN);
    end

    // AXI WRAP legality and the modulo block counter require these line lengths.
    if (!(LINE_W == 2 || LINE_W == 4 || LINE_W == 8 || LINE_W == 16)) begin : gen_line_width_guard
        $fatal(1, "l2_cache: LINE_W=%0d unsupported; must be one of {2,4,8,16} (AXI WRAP length and databank modulo counter requirement).", LINE_W);
    end
    if (LINES < 2 || (LINES & (LINES-1)) != 0) begin : gen_lines_guard
        $fatal(1, "l2_cache: LINES=%0d unsupported; must be a power of two >= 2.", LINES);
    end
    if (WAYS < 1) begin : gen_ways_guard
        $fatal(1, "l2_cache: WAYS=%0d unsupported; must be >= 1.", WAYS);
    end
    if (BLOCK_W < 8 || BLOCK_W > 1024 || (BLOCK_W % 8) != 0
        || (((BLOCK_W/8) & ((BLOCK_W/8)-1)) != 0)) begin : gen_block_width_guard
        $fatal(1, "l2_cache: BLOCK_W=%0d unsupported; must be 8..1024 bits with power-of-two bytes/block.", BLOCK_W);
    end
    if (READ_ID_WIDTH < 1 || WRITE_ID_WIDTH < 1) begin : gen_id_width_guard
        $fatal(1, "l2_cache: READ_ID_WIDTH=%0d WRITE_ID_WIDTH=%0d unsupported; both must be >= 1.", READ_ID_WIDTH, WRITE_ID_WIDTH);
    end
    if (READ_ID_WIDTH != WRITE_ID_WIDTH) begin : gen_id_width_match_guard
        $fatal(1, "l2_cache: READ_ID_WIDTH=%0d must equal WRITE_ID_WIDTH=%0d; merged memory IDs use one shared width.", READ_ID_WIDTH, WRITE_ID_WIDTH);
    end
    if (TAG_W_CALC < 1) begin : gen_tag_width_guard
        $fatal(1, "l2_cache: cache geometry consumes the entire address range (TAG_W=%0d); reduce LINES/LINE_W/BLOCK_W or enlarge ADDR_RANGE.", TAG_W_CALC);
    end
    if (INCLUDE_CBOM && TAG_W_CALC < int'($clog2(WAYS))) begin : gen_cbom_way_width_guard
        $fatal(1, "l2_cache: TAG_W=%0d cannot encode WAYS=%0d for CleanInvalidByIndex.", TAG_W_CALC, WAYS);
    end

    // Whole-cache flush is not correct beyond two databank stages.
    if (DB_LATENCY < 1 || DB_LATENCY > 2) begin : gen_db_latency_guard
        $fatal(1, "l2_cache: DB_LATENCY=%0d unsupported; whole-cache flush requires 1..2.", DB_LATENCY);
    end

    // A valid NAPOT base already has every variable low bit cleared, so the
    // base itself is the fixed address prefix. It is zero for a full range.
    localparam logic[ADDR_W-1:0] OMITTED_CONSTANT = ADDR_RANGE_L_USED;
    localparam int unsigned LOG2_BLOCK_BYTES = $clog2(BLOCK_W/8);
    localparam int unsigned HASH_WIDTH = LINE_ADDR_W > MAX_ADDR_HASH_WIDTH ? MAX_ADDR_HASH_WIDTH : LINE_ADDR_W;

    typedef struct packed {
        logic rnw;
        logic[(READ_ID_WIDTH > WRITE_ID_WIDTH ? READ_ID_WIDTH : WRITE_ID_WIDTH)-1:0] id;
    } cache_id_t;
    typedef logic[READ_ID_WIDTH-1:0] rid_t;
    typedef logic[WRITE_ID_WIDTH-1:0] wid_t;
    localparam int unsigned ID_W = $bits(cache_id_t);

    typedef logic[TAG_W-1:0] tag_t;
    typedef logic[LINE_ADDR_W-1:0] line_t;
    typedef logic[BLOCK_ADDR_W-1:0] block_t;
    typedef logic[($clog2(WAYS) == 0 ? 0 : $clog2(WAYS)-1):0] way_t;
    typedef logic[BLOCK_W-1:0] block_data_t;
    typedef logic[BLOCK_W/8-1:0] wbe_t;
    typedef logic[$clog2(REQ_FIFO_DEPTH):0] fifo_count_t;
    typedef logic[HASH_WIDTH-1:0] hash_t;

    genvar i;

    //Input to victim cache (or external, if not present)
    ar_t victim_ar;
    logic[READ_ID_WIDTH:0] victim_arid;
    logic victim_arready;
    r_t victim_r;
    logic[BLOCK_W-1:0] victim_rdata;
    logic[READ_ID_WIDTH:0] victim_rid;
    logic victim_rready;
    aw_t victim_aw;
    logic[ID_W-1:0] victim_awid;
    logic victim_awready;
    w_t victim_w;
    logic[BLOCK_W-1:0] victim_wdata;
    logic[(BLOCK_W/8)-1:0] victim_wstrb;
    logic victim_wready;
    b_t victim_b;
    logic[ID_W-1:0] victim_bid;
    logic victim_bready;

    typedef struct packed {
        logic rnw;
        logic evict; //If set on a read, indicates that the read is followed by a write
        line_t line;
        block_t block;
        cache_id_t id; //Read only
        block_t len; //Original request length
        way_t way; //Write only
        logic fill; //Write only, distinguishes between writes and fills
    } databank_request_t;

    //Tagbank output
    cache_id_t tb_out_id;
    tag_t tb_out_tag;
    line_t tb_out_line;
    block_t tb_out_block;
    block_t tb_out_len;
    logic tb_out_inval;
    logic tb_out_clean;
    logic tb_out_by_index;
    logic tb_out_full_write;

    //Input request
    ar_t chosen_ar;
    logic chosen_arready;
    logic[READ_ID_WIDTH-1:0] chosen_arid;
    aw_t chosen_aw;
    logic chosen_awready;
    logic[WRITE_ID_WIDTH-1:0] chosen_awid;

    ////////////////////////////////////////////////////
    //Implementation

    ////////////////////////////////////////////////////
    //Inuse storage
    //Multiple requests to the same line are not supported (complications with hitting evict data)
    //Multiple requests from the same ID are not supported (difficulty in ordering responses)
    typedef struct packed {
        rid_t rid;
        logic rlast;
        block_data_t rdata;
    } output_data_t;
    output_data_t output_data;

    typedef struct packed {
        logic bvalid;
        cache_id_t bid;
        logic rvalid;
        cache_id_t rid;
        logic wvalid;
        cache_id_t wid;
    } finish_t;
    finish_t finish_input;
    finish_t finish_output;

    logic finish_pop;
    logic finish_valid;
    logic finish_full;

    logic will_hit;
    logic hitting;
    logic out_cbom_valid;
    logic read_filling;
    logic filling;
    logic out_valid;
    logic out_ready;
    logic tb_advance;
    logic tb_pushing_write;
    logic ext_returning_last_w;

    logic bvalid_invalid;
    logic rvalid_invalid;
    logic bvalid_handled;
    logic rvalid_handled;

    //Buffer and serialize finishes, otherwise multiple requests can finish on the same cycle, which would require too many LUTRAM ports
    //The alternative is blocking finishes so that only one can occur in a single cycle, though this degrades performance
    //Finish priority order (all with respect to requests): bvalid > rvalid > wvalid 

    always_ff @(posedge clk) begin
        if (rst) begin
            // Cold-init: without a reset these are X for the first cycle and
            // bleed into bvalid_invalid -> finish_id -> the inuse/CBOM clear
            // path in 4-state sim (they self-clear once finish_valid settles,
            // but X during that window is not simulator-portable).
            bvalid_handled <= 1'b0;
            rvalid_handled <= 1'b0;
        end else begin
            bvalid_handled <= ~finish_pop & finish_valid; //Always set after first cycle of valid
            rvalid_handled <= ~finish_pop & finish_valid & bvalid_invalid;
        end
    end

    assign bvalid_invalid = ~finish_output.bvalid | bvalid_handled;
    assign rvalid_invalid = ~finish_output.rvalid | rvalid_handled;

    cache_id_t finish_id;
    always_comb begin
        finish_id.id = '0;
        if (bvalid_invalid & rvalid_invalid) //Write finished
            finish_id = finish_output.wid;
        else if (bvalid_invalid) //Read (or write miss) finished
            finish_id = finish_output.rid;
        else //Write response finished
            finish_id = finish_output.bid;
    end

    cache_id_t packed_wid;
    always_comb begin
        packed_wid.rnw = 0;
        packed_wid.id = '0;
        packed_wid.id[WRITE_ID_WIDTH-1:0] = req_bid;
    end

    //Note that verilator has an issue where the b/rid will bleed over here to b/rvalid if b/rid is ~0 in C++
    assign finish_input = '{
        bvalid : victim_b.bvalid & victim_bready,
        bid : victim_bid,
        rvalid : (victim_r.rvalid & victim_rready & victim_r.rlast) | ((will_hit | hitting | (out_cbom_valid & ~read_filling)) & out_ready & out_valid & output_data.rlast),
        rid : (ext_returning_last_w | read_filling) ? victim_rid : {1'b1, output_data.rid},
        wvalid : req_b.bvalid & req_bready,
        wid : packed_wid
    };

    assign victim_bready = ~finish_full;
    assign finish_pop = (~finish_output.rvalid & ~finish_output.wvalid) |
        (bvalid_invalid & ~finish_output.wvalid) |
        (bvalid_invalid & rvalid_invalid);
    fifo #(.WIDTH($bits(finish_t)), .FIFO_DEPTH(FINISH_FIFO_DEPTH)) finish_fifo_inst (
        .fifo_push(finish_input.bvalid | finish_input.rvalid | finish_input.wvalid),
        .fifo_pop(finish_valid & finish_pop),
        .fifo_data_in(finish_input),
        .fifo_data_out(finish_output),
        .fifo_valid(finish_valid),
        .fifo_full(finish_full),
    .*);

    //Eviction tracking storage
    logic tb_valid;
    logic tb_hit;
    logic tb_dirty;
    cache_id_t evict_raddr;
    logic evict_set;
    logic evict_clear;
    logic evict_rdata;

    assign evict_raddr = rvalid_invalid ? finish_output.wid : finish_output.rid;
    assign evict_set = tb_valid & ((~tb_hit & tb_dirty & ~(INCLUDE_CBOM & (tb_out_clean | tb_out_inval))) | (INCLUDE_CBOM & tb_hit & tb_out_clean));
    assign evict_clear = finish_valid & ~bvalid_invalid;
    set_clear_memory #(.DEPTH(2**ID_W)) evict_table (
        .set(evict_set),
        .set_addr(tb_out_id),
        .clear(evict_clear),
        .clear_addr(finish_output.bid),
        .read_addr(evict_raddr),
        .in_use(evict_rdata),
    .*);

    //Needs rdata storage
    logic rdata_rdata;
    logic rdata_set;
    cache_id_t rdata_set_addr;
    cache_id_t rdata_raddr;
    logic rdata_clear;
    // Set the toggle on arbitrated advance, not skid acceptance: a stalled
    // same-ID request may occupy the skid while the prior read is still active.
    assign rdata_set = tb_pushing_write ? ~tb_hit & ~tb_out_full_write : chosen_arready & chosen_ar.arvalid;
    assign rdata_set_addr = tb_pushing_write ? tb_out_id : {1'b1, chosen_arid};
    assign rdata_raddr = bvalid_invalid ? finish_output.wid : finish_output.bid;
    assign rdata_clear = finish_valid & bvalid_invalid & ~rvalid_invalid;
    set_clear_memory #(.DEPTH(2**ID_W)) needs_rdata_table (
        .set(rdata_set),
        .set_addr(rdata_set_addr),
        .clear(rdata_clear),
        .clear_addr(finish_output.rid),
        .read_addr(rdata_raddr),
        .in_use(rdata_rdata),
    .*);


    //Needs wdata storage
    //Set on 0, clear on 1
    logic wdata_table_toggle[2];
    wid_t wdata_table_toggle_addr[2];
    wid_t wdata_table_raddr[2];
    logic wdata_table_rdata[2];
    logic wdata_rdata;
    logic ext_needs_rdata;

    assign wdata_table_toggle[0] = chosen_awready & chosen_aw.awvalid;
    assign wdata_table_toggle[1] = finish_valid & bvalid_invalid & rvalid_invalid;
    assign wdata_table_toggle_addr[0] = chosen_awid;
    assign wdata_table_toggle_addr[1] = finish_output.wid[WRITE_ID_WIDTH-1:0];

    assign wdata_table_raddr[0] = bvalid_invalid ? finish_output.rid[WRITE_ID_WIDTH-1:0] : finish_output.bid[WRITE_ID_WIDTH-1:0];
    assign wdata_table_raddr[1] = victim_rid[WRITE_ID_WIDTH-1:0];
    assign wdata_rdata = wdata_table_rdata[0];
    assign ext_needs_rdata = wdata_table_rdata[1];

    toggle_memory_set #(
        .DEPTH(2**$bits(wid_t)),
        .NUM_WRITE_PORTS(2),
        .NUM_READ_PORTS(2)
    ) needs_wdata_table (
        .init_clear(rst),
        .toggle(wdata_table_toggle),
        .toggle_addr(wdata_table_toggle_addr),
        .read_addr(wdata_table_raddr),
        .in_use(wdata_table_rdata),
    .*);

    // Split read/eviction finishes may defer the occupancy clear from R to B.
    // Store that pending clear in flops; this path must not use toggle memory.
    logic[(2**ID_W)-1:0] deferred_inuse_clear;
    logic                deferred_inuse_set_pulse;
    logic                deferred_inuse_rdata;
    logic                deferred_inuse_clear_pulse;

    assign deferred_inuse_set_pulse = finish_valid & finish_pop & finish_output.rvalid &
        ~rvalid_handled & bvalid_invalid & evict_rdata;
    assign deferred_inuse_rdata       = deferred_inuse_clear[finish_output.bid];
    assign deferred_inuse_clear_pulse = finish_valid & ~bvalid_invalid & deferred_inuse_rdata;

    always_ff @(posedge clk) begin
        if (rst)
            deferred_inuse_clear <= '0;
        else begin
            if (deferred_inuse_set_pulse)
                deferred_inuse_clear[finish_output.rid] <= 1'b1;
            if (deferred_inuse_clear_pulse)
                deferred_inuse_clear[finish_output.bid] <= 1'b0;
        end
    end

    // Each finish-FIFO head may toggle occupancy at most once.
    logic finish_clear;
    logic finish_clear_raw;
    logic clear_done_for_head;
    cache_id_t  cleared_id;     // (id, hash) most recently cleared for this entry
    logic [HASH_WIDTH-1:0] cleared_hash;
    logic       same_target;    // current clear target matches the last fire
    // Declared here (used by same_target below); driven by id_to_line_table.
    hash_t finish_hash;

    assign finish_clear_raw = finish_valid & (
        (~bvalid_invalid & ~(rdata_rdata | (~finish_output.bid.rnw & wdata_rdata))) |
        (~bvalid_invalid & deferred_inuse_rdata) |
        (finish_output.rvalid & ~rvalid_handled & bvalid_invalid & ~evict_rdata & ~(~finish_output.rid.rnw & wdata_rdata)) |
        (bvalid_invalid & rvalid_invalid & ~evict_rdata & ~rdata_rdata)
    );
    // Suppress only a repeated clear of the same ID and line hash.
    assign same_target = clear_done_for_head &
                         (finish_id == cleared_id) &
                         (finish_hash == cleared_hash);
    assign finish_clear = finish_clear_raw & ~same_target;

    always_ff @(posedge clk) begin
        if (rst) begin
            clear_done_for_head <= 1'b0;
            cleared_id          <= '0;
            cleared_hash        <= '0;
        end else if (finish_pop) begin
            clear_done_for_head <= 1'b0;
        end else if (finish_clear) begin
            clear_done_for_head <= 1'b1;
            cleared_id          <= finish_id;
            cleared_hash        <= finish_hash;
        end
    end

`ifdef DIAG_FINISH
    always @(posedge clk) begin
        if (!rst) begin
            if (finish_valid)
                $display("[%0t] FIN valid b=%b r=%b w=%b bid=%h rid=%h wid=%h bvi=%b rvi=%b pop=%b clr=%b raw=%b cdh=%b clrid=%h fhash=%h rdata=%b evict=%b wdata=%b defrd=%b",
                    $time,
                    finish_output.bvalid, finish_output.rvalid, finish_output.wvalid,
                    finish_output.bid, finish_output.rid, finish_output.wid,
                    bvalid_invalid, rvalid_invalid, finish_pop, finish_clear, finish_clear_raw, clear_done_for_head,
                    finish_id, finish_hash,
                    rdata_rdata, evict_rdata, wdata_rdata, deferred_inuse_rdata);
        end
    end
`endif

`ifdef DIAG_STALL
    // Per-cycle dump of stall signals when an AR is pending but not advancing.
    always @(posedge clk) begin
        if (!rst && chosen_ar.arvalid && !chosen_arready)
            $display("[%0t] STALL ar arid=%h araddr=%h | try_read=%b tb_pw=%b cbom_full=%b prefer_r=%b aw_v=%b inuse_id=%b inuse_line=%b req_fifo_full=%b ar_fifo_full=%b in_id=%h in_hash=%h",
                $time, chosen_arid, chosen_ar.araddr,
                try_read, tb_pushing_write, cbom_fifo_full, prefer_read, chosen_aw.awvalid,
                inuse_id_rdata, inuse_line_rdata, req_fifo_full, ar_fifo_full,
                in_id, in_hash);
    end
`endif

`ifdef DIAG_STALL2
    // Broader per-cycle probe across the request and mem-AR path.
    always @(posedge clk) begin
        if (!rst) begin
            $display("[%0t] CYC req_ar_v=%b req_arrdy=%b sav_ar=%b ch_arv=%b ch_arrdy=%b try_rd=%b tb_pw=%b tb_adv=%b | tb_valid=%b tb_hit=%b tb_full_wr=%b | ar_fifo_full=%b ar_fifo_v=%b req_fifo_full=%b | mem_ar_v=%b mem_arrdy=%b mem_arid=%h | in_id=%h in_hash=%h iir=%b ilr=%b | dbV=%b%b dbE=%b%b dbL=%b%b hit=%b will_hit=%b out_v=%b out_r=%b fin_full=%b fill=%b rdfill=%b",
                $time,
                req_ar.arvalid, req_arready, saved_arvalid,
                chosen_ar.arvalid, chosen_arready, try_read, tb_pushing_write, tb_advance,
                tb_valid, tb_hit, tb_out_full_write,
                ar_fifo_full, ar_fifo_valid, req_fifo_full,
                victim_ar.arvalid, victim_arready, mem_arid,
                in_id, in_hash, inuse_id_rdata, inuse_line_rdata,
                db_out_valid[1], db_out_valid[0],
                db_out_evict[1], db_out_evict[0],
                db_out_last[1], db_out_last[0],
                hitting, will_hit, out_valid, out_ready, finish_full, filling, read_filling);
        end
    end
`endif

`ifdef DIAG_STALL3
    always @(posedge clk) begin
        if (!rst) begin
            $display("[%0t] DB req_fifo_v=%b req_fifo_pop=%b prem_disc=%b db_req_v=%b db_ready=%b try_fill=%b fill_req_v=%b db_out_rdy=%b%b req_id=%h req_rnw=%b req_evict=%b req_line=%h",
                $time,
                req_fifo_valid, req_fifo_pop, premature_discard,
                db_req_valid, db_ready, try_fill, fill_request_valid,
                db_out_ready[1], db_out_ready[0],
                req_fifo_data_out.id, req_fifo_data_out.rnw, req_fifo_data_out.evict, req_fifo_data_out.line);
        end
    end
`endif

    //ID level storage
    logic inuse_id_rdata;
    cache_id_t in_id;
    set_clear_memory #(.DEPTH(2**ID_W)) inuse_id_table (
        .set(tb_advance),
        .set_addr(in_id),
        .clear(finish_clear),
        .clear_addr(finish_id),
        .read_addr(in_id),
        .in_use(inuse_id_rdata),
    .*);

    //Line hashing
    hash_t in_hash;
    line_t in_line;
    l2_hash #(.IN_WIDTH(LINE_ADDR_W), .OUT_WIDTH(HASH_WIDTH)) hash_inst (
        .addr(in_line),
        .hash(in_hash)
    );

    //Line level storage
    logic inuse_line_rdata;
    set_clear_memory #(.DEPTH(2**HASH_WIDTH)) inuse_line_table (
        .set(tb_advance),
        .set_addr(in_hash),
        .clear(finish_clear),
        .clear_addr(finish_hash),
        .read_addr(in_hash),
        .in_use(inuse_line_rdata),
    .*);

    //ID to LINE
    lutram_1w_1r #(
        .WIDTH($bits(hash_t)),
        .DEPTH(2**ID_W)
    ) id_to_line_table (
        .waddr(in_id),
        .raddr(finish_id),
        .ram_write(tb_advance),
        .new_ram_data(in_hash),
        .ram_data_out(finish_hash),
    .*);


    ////////////////////////////////////////////////////
    //Input requests
    //Equal priority to reads and writes
    //Requests are accepted only if there is room and it does not conflict with anything inflight
    logic prefer_read; //If two simultaneous requests, choose based on this
    logic try_read; //If we will try to accept a read request
    tag_t in_tag;
    block_t in_block;
    block_t in_len;
    logic cbom_fifo_full;

    assign try_read = chosen_ar.arvalid & ~tb_pushing_write & ~cbom_fifo_full & (prefer_read | ~chosen_aw.awvalid);
    
    assign {in_tag, in_line, in_block} = try_read
        ? chosen_ar.araddr[LOG2_BLOCK_BYTES +: TAG_W+LINE_ADDR_W+BLOCK_ADDR_W]
        : chosen_aw.awaddr[LOG2_BLOCK_BYTES +: TAG_W+LINE_ADDR_W+BLOCK_ADDR_W];
    assign in_len = try_read ? chosen_ar.arlen[BLOCK_ADDR_W-1:0] : chosen_aw.awlen[BLOCK_ADDR_W-1:0];

    always_comb begin
        in_id.rnw = try_read;
        in_id.id = '0;
        if (try_read)
            in_id[READ_ID_WIDTH-1:0] = chosen_arid;
        else
            in_id[WRITE_ID_WIDTH-1:0] = chosen_awid;
    end

    always_ff @(posedge clk) begin
        if (rst)
            prefer_read <= 0;
        else
            prefer_read <= ~prefer_read;
    end

    //Ready signals must be registered as an AXI requirement, so we buffer up to one request internally and mux it
    logic saved_arvalid;
    ar_t saved_ar;
    logic[READ_ID_WIDTH-1:0] saved_arid;
    logic saved_awvalid;
    aw_t saved_aw;
    logic[WRITE_ID_WIDTH-1:0] saved_awid;

    always_ff @(posedge clk) begin
        if (req_arready) begin
            saved_ar <= req_ar;
            saved_arid <= req_arid;
        end
        if (req_awready) begin
            saved_aw <= req_aw;
            saved_awid <= req_awid;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            saved_arvalid <= 0;
            saved_awvalid <= 0;
        end
        else begin
            saved_arvalid <= saved_arvalid ? ~chosen_arready : req_ar.arvalid & ~chosen_arready;
            saved_awvalid <= saved_awvalid ? ~chosen_awready : req_aw.awvalid & ~chosen_awready;
        end
    end

    always_comb begin
        chosen_ar = req_ar;
        chosen_arid = req_arid;
        if (saved_arvalid) begin
            chosen_ar = saved_ar;
            chosen_ar.arvalid = 1;
            chosen_arid = saved_arid;
        end
        
        chosen_aw = req_aw;
        chosen_awid = req_awid;
        if (saved_awvalid) begin
            chosen_aw = saved_aw;
            chosen_aw.awvalid = 1;
            chosen_awid = saved_awid;
        end
    end

    logic inuse_stall; //If the attempted request is denied by virtue of ID or line
    logic fifo_stall;
    logic req_fifo_full;
    logic ar_fifo_full;
    logic awid_fifo_full;
    logic accept_conflict;
    assign inuse_stall = inuse_id_rdata | inuse_line_rdata;
    assign fifo_stall = req_fifo_full | ar_fifo_full;

    // Toggle-based occupancy cannot accept and clear the same ID/set in one
    // cycle; defer the accept until the finish has retired.
    assign accept_conflict = finish_clear & ((in_id == finish_id) | (in_hash == finish_hash));

    assign chosen_awready = ~try_read & ~inuse_stall & ~fifo_stall & ~awid_fifo_full & ~accept_conflict;
    assign chosen_arready = try_read & ~inuse_stall & ~fifo_stall & ~accept_conflict;
    assign req_awready = ~saved_awvalid;
    assign req_arready = ~saved_arvalid;

    assign tb_advance = (chosen_awready & chosen_aw.awvalid) | (chosen_arready & chosen_ar.arvalid);

    logic in_full_write;
    logic in_inval;
    logic in_clean;
    logic in_by_index;
    assign in_full_write = chosen_aw.awsnoop == 3'b101; //WriteEvict
    //By-index whole-set clean (reserved ACE arsnoop 4'b1011): behaves like
    //CleanInvalid but the tagbank selects the way from the tag field's low bits
    //instead of matching the tag, so a flush cleans every way of a set
    //regardless of the resident tag. Per-line CleanInvalid (4'b1001) unchanged.
    assign in_by_index = INCLUDE_CBOM & try_read & (chosen_ar.arsnoop == 4'b1011);
    assign in_inval = INCLUDE_CBOM & try_read & (chosen_ar.arsnoop == 4'b1001 | chosen_ar.arsnoop == 4'b1101 | chosen_ar.arsnoop == 4'b1011); //CleanInvalid, MakeInvalid, CleanInvalidByIndex
    assign in_clean = INCLUDE_CBOM & try_read & (chosen_ar.arsnoop == 4'b1001 | chosen_ar.arsnoop ==  4'b1000 | chosen_ar.arsnoop == 4'b1011); //CleanInvalid, CleanShared, CleanInvalidByIndex


    ////////////////////////////////////////////////////
    //Tagbank
    //Never stalls because inputs are only submitted if the DB fifo has room
    logic[TAG_W-1:0] tb_tag;
    way_t tb_way;

    l2_tagbank #(
        .POLICY(POLICY),
        .WAYS(WAYS),
        .BLOCK_W(BLOCK_W),
        .ID_W(ID_W),
        .TAG_W(TAG_W),
        .LINES(LINES),
        .LINE_W(LINE_W),
        .RANDOM_USE_EVICT(RANDOM_USE_EVICT),
        .RRIP_HP(RRIP_HP),
        .RRIP_WIDTH(RRPV_WIDTH),
        .ADDR_W(ADDR_W),
        .ADDR_BASE(ADDR_RANGE_L_USED),
        .GRASP_HIGH_REGIONS(GRASP_HIGH_REGIONS),
        .GRASP_MODERATE_REGIONS(GRASP_MODERATE_REGIONS)
    ) tb_inst (
        .in_valid(tb_advance),
        .in_request_id(in_id),
        .in_request_tag(in_tag),
        .in_request_line(in_line),
        .in_request_block(in_block),
        .in_request_len(in_len),
        .in_request_inval(in_inval),
        .in_request_clean(in_clean),
        .in_request_by_index(in_by_index),
        .in_request_full_write(in_full_write),
        .out_valid(tb_valid),
        .out_request_id(tb_out_id),
        .out_request_tag(tb_out_tag),
        .out_request_line(tb_out_line),
        .out_request_block(tb_out_block),
        .out_request_len(tb_out_len),
        .out_request_inval(tb_out_inval),
        .out_request_clean(tb_out_clean),
        .out_request_by_index(tb_out_by_index),
        .out_request_full_write(tb_out_full_write),
        .out_hit(tb_hit),
        .out_dirty(tb_dirty),
        .out_tag(tb_tag),
        .out_way(tb_way),
    .*);

    ////////////////////////////////////////////////////
    //Write data and responses
    //Lines of write data are buffered until they are needed
    //Write responses are submitted once the tagbank accepts the last of a line
    typedef struct packed {
        block_data_t data;
        wbe_t wbe;
        logic last;
    } wdata_t;
    logic db_wdata_ready;
    wdata_t wdata_fifo_data_in;
    wdata_t wdata_fifo_data_out;
    logic wdata_fifo_push;
    logic wdata_fifo_pop;
    logic wdata_fifo_valid;
    logic db_wdata_valid;
    logic wdata_fifo_full;

    assign wdata_fifo_push = req_w.wvalid & req_wready;
    // The FIFO reset is synchronous; gate VALID in the reset cycle.
    assign req_b.bvalid = wdata_fifo_valid & db_wdata_ready & wdata_fifo_data_out.last & ~finish_full & ~rst;
    assign req_b.bresp = 2'b00; //OKAY
    assign wdata_fifo_pop = wdata_fifo_valid & db_wdata_ready & ~(wdata_fifo_data_out.last & (~req_bready | finish_full));
    assign db_wdata_valid = wdata_fifo_valid & ~(wdata_fifo_data_out.last & (~req_bready | finish_full));
    assign wdata_fifo_data_in = '{
        data : req_wdata,
        wbe : req_wstrb,
        last : req_w.wlast
    };
    assign req_wready = ~wdata_fifo_full;
    fifo #(.WIDTH($bits(wdata_t)), .FIFO_DEPTH(WDATA_FIFO_DEPTH)) wdata_fifo_inst (
        .fifo_push(wdata_fifo_push),
        .fifo_pop(wdata_fifo_pop),
        .fifo_data_in(wdata_fifo_data_in),
        .fifo_data_out(wdata_fifo_data_out),
        .fifo_valid(wdata_fifo_valid),
        .fifo_full(wdata_fifo_full),
    .*);

    //Pending write ID storage
    fifo #(.WIDTH($bits(wid_t)), .FIFO_DEPTH(AWID_FIFO_DEPTH)) awid_fifo_inst (
        .fifo_push(chosen_awready & chosen_aw.awvalid),
        .fifo_pop(req_b.bvalid & req_bready),
        .fifo_data_in(chosen_awid),
        .fifo_data_out(req_bid),
        .fifo_valid(),
        .fifo_full(awid_fifo_full),
    .*);


    ////////////////////////////////////////////////////
    //External read requests
    //Caused by all read (and some write) misses
    typedef struct packed {
        tag_t tag;
        line_t line;
        block_t block;
        cache_id_t id;
        logic cbom;
    } ar_request_t;
    logic ar_fifo_push;
    logic ar_fifo_pop;
    logic ar_fifo_valid;
    ar_request_t ar_fifo_data_in;
    ar_request_t ar_fifo_data_out;
    logic victim_invalidate;

    assign ar_fifo_push = tb_valid & ((~tb_hit & (tb_out_id.rnw | ~tb_out_full_write) & ~(INCLUDE_CBOM & (tb_out_inval | tb_out_clean))) | (INCLUDE_VICTIM & INCLUDE_CBOM & (tb_out_inval | tb_out_clean)));
    assign ar_fifo_pop = (victim_ar.arvalid & victim_arready) | victim_invalidate;
    assign ar_fifo_data_in = '{
        tag : tb_out_tag,
        line : tb_out_line,
        block : tb_out_block,
        id : tb_out_id,
        cbom : INCLUDE_VICTIM & INCLUDE_CBOM & (tb_out_inval | tb_out_clean)
    };
    fifo #(.WIDTH($bits(ar_request_t)), .FIFO_DEPTH(REQ_FIFO_DEPTH)) ar_fifo_inst (
        .fifo_push(ar_fifo_push),
        .fifo_pop(ar_fifo_pop),
        .fifo_data_in(ar_fifo_data_in),
        .fifo_data_out(ar_fifo_data_out),
        .fifo_valid(ar_fifo_valid),
        .fifo_full(),
    .*);
    fifo_count_t ar_fifo_count;
    logic ar_no_push;
    assign ar_fifo_full = ar_fifo_count[$clog2(REQ_FIFO_DEPTH)];
    assign ar_no_push = tb_valid & ~ar_fifo_push;
    always_ff @(posedge clk) begin
        if (rst)
            ar_fifo_count <= '0;
        else
            ar_fifo_count <= ar_fifo_count + fifo_count_t'(tb_advance) - fifo_count_t'(ar_fifo_pop) - fifo_count_t'(ar_no_push);
    end

    assign victim_invalidate = ar_fifo_valid & ar_fifo_data_out.cbom;
    assign victim_ar.arvalid = ar_fifo_valid & ~ar_fifo_data_out.cbom;
    assign victim_arid = ar_fifo_data_out.id;
    assign victim_ar.araddr = OMITTED_CONSTANT | ADDR_W'({
        ar_fifo_data_out.tag, ar_fifo_data_out.line, ar_fifo_data_out.block,
        {LOG2_BLOCK_BYTES{1'b0}}
    });
    assign victim_ar.arlen = 8'(LINE_W-1);
    assign victim_ar.arburst = |ar_fifo_data_out.block ? 2'b10 : 2'b01; //Incr when aligned
    assign victim_ar.arsize = 3'(LOG2_BLOCK_BYTES);
    assign victim_ar.arlock = 0;
    assign victim_ar.arcache = '1;
    assign victim_ar.arprot = '0;
    assign victim_ar.arqos = '0;
    assign victim_ar.arregion = '0;
    assign victim_ar.arsnoop = '0;


    ////////////////////////////////////////////////////
    //Databank requests
    //FIFO of read hit, write hit, and eviction requests
    //Misse data bypasses this FIFO and has priority
    logic db_ready;
    logic premature_discard;
    logic fill_request_valid;
    assign tb_pushing_write = tb_valid & ~tb_out_id.rnw;

    databank_request_t req_fifo_data_in;
    databank_request_t req_fifo_data_out;
    logic req_fifo_pop;
    logic req_fifo_valid;
    cache_id_t padded_arid;

    always_comb begin
        padded_arid.rnw = 1;
        padded_arid.id = '0;
        padded_arid.id[READ_ID_WIDTH-1:0] = chosen_arid;
    end

    assign req_fifo_pop = req_fifo_valid & ((~fill_request_valid & db_ready) | premature_discard);
    assign req_fifo_data_in = '{
        rnw : ~tb_pushing_write | (~tb_hit & tb_dirty),
        evict : tb_pushing_write ? ~tb_hit & tb_dirty : 0,
        line : tb_pushing_write ? tb_out_line : chosen_ar.araddr[LOG2_BLOCK_BYTES+BLOCK_ADDR_W+:LINE_ADDR_W],
        block : tb_pushing_write ? tb_out_block : chosen_ar.araddr[LOG2_BLOCK_BYTES+:BLOCK_ADDR_W],
        id : tb_pushing_write ? tb_out_id : padded_arid,
        len : tb_pushing_write ? tb_out_len : chosen_ar.arlen[BLOCK_ADDR_W-1:0],
        way : tb_way,
        fill : 0
    };

    fifo #(.WIDTH($bits(databank_request_t)), .FIFO_DEPTH(REQ_FIFO_DEPTH)) req_fifo_inst (
        .fifo_push((chosen_ar.arvalid & chosen_arready) | tb_pushing_write),//
        .fifo_pop(req_fifo_pop),
        .fifo_data_in(req_fifo_data_in),
        .fifo_data_out(req_fifo_data_out),
        .fifo_valid(req_fifo_valid),
        .fifo_full(),
    .*);

    fifo_count_t req_fifo_count;
    assign req_fifo_full = req_fifo_count[$clog2(REQ_FIFO_DEPTH)];
    always_ff @(posedge clk) begin
        if (rst)
            req_fifo_count <= '0;
        else
            req_fifo_count <= req_fifo_count + fifo_count_t'(tb_advance) - fifo_count_t'(req_fifo_pop);
    end

    ////////////////////////////////////////////////////
    //Premature discard
    //Discards read requests before they can even be passed to the databank
    //Separate tables track valid + discard signals
    logic premature_toggle[2];
    rid_t premature_toggle_addr[2];
    rid_t premature_raddr[1];
    logic premature_valid[1];
    logic premature_value;
    logic tb_will_discard;

    assign premature_discard = premature_valid[0] & premature_value & req_fifo_data_out.id.rnw;
    assign premature_raddr[0] = req_fifo_data_out.id[READ_ID_WIDTH-1:0];
    assign premature_toggle_addr[0] = tb_out_id[READ_ID_WIDTH-1:0];
    assign premature_toggle_addr[1] = premature_raddr[0];
    assign premature_toggle[0] = tb_valid & tb_out_id.rnw;
    assign premature_toggle[1] = req_fifo_pop & req_fifo_data_out.id.rnw;

    toggle_memory_set #(
        .DEPTH(2**READ_ID_WIDTH),
        .NUM_WRITE_PORTS(2),
        .NUM_READ_PORTS(1)
    ) premature_valid_table (
        .init_clear(rst),
        .toggle(premature_toggle),
        .toggle_addr(premature_toggle_addr),
        .read_addr(premature_raddr),
        .in_use(premature_valid),
    .*);

    lutram_1w_1r #(
        .WIDTH(1),
        .DEPTH(2**READ_ID_WIDTH)
    ) premature_discard_table (
        .waddr(premature_toggle_addr[0]),
        .raddr(premature_raddr[0]),
        .ram_write(premature_toggle[0]),
        .new_ram_data(tb_will_discard),
        .ram_data_out(premature_value),
    .*);

    ////////////////////////////////////////////////////
    //Databanks
    //Two output ports for read data
    //One request port shared by reads and writes, two data sources
    typedef struct packed {
        tag_t tag;
        line_t line;
        block_t block;
        logic clean;
    } saved_t;
    logic db_req_valid;
    databank_request_t db_req;
    logic db_fill_valid;
    logic db_fill_ready;
    cache_id_t db_lookup_id[2];
    way_t db_lookup_way[2];
    logic db_lookup_discard[2];
    logic db_lookup_evict[2];
    saved_t db_lookup_saved[2];
    cache_id_t db_out_id[2];
    logic db_out_valid[2];
    logic db_out_last[2];
    logic db_out_ready[2];
    logic db_out_evict[2];
    saved_t db_out_saved[2];
    block_data_t db_out_data[2];
    databank_request_t fill_req;
    wbe_t fill_wbe;
    logic try_fill;

    typedef struct packed {
        saved_t saved;
        way_t way;
        logic discard;
        logic evict;
    } lookup_t;
    lookup_t lookup_in;
    lookup_t lookup_out[2];

    assign db_req_valid = fill_request_valid | (req_fifo_valid & ~premature_discard);
    assign db_req = try_fill ? fill_req : req_fifo_data_out;

    generate for (i = 0; i < 2; i++) begin : gen_db_extract
        assign db_lookup_way[i] = lookup_out[i].way;
        assign db_lookup_discard[i] = lookup_out[i].discard;
        assign db_lookup_evict[i] = lookup_out[i].evict;
        assign db_lookup_saved[i] = lookup_out[i].saved;
    end endgenerate

    if (N_BANKS < 1) begin : gen_bank_count_guard
        $fatal(1, "l2_cache: N_BANKS=%0d unsupported; must be >= 1.", N_BANKS);
    end
    else if ((N_BANKS & (N_BANKS-1)) != 0
             || N_BANKS > LINES || (LINES % N_BANKS) != 0) begin : gen_bank_geometry_guard
        $fatal(1, "l2_cache: N_BANKS=%0d must be a power of two that divides LINES=%0d.", N_BANKS, LINES);
    end

    l2_databank #(
        .WAYS(WAYS),
        .DATA_W(BLOCK_W),
        .ID_W(ID_W),
        .LINE_ADDR_W(LINE_ADDR_W),
        .BLOCK_ADDR_W(BLOCK_ADDR_W),
        .LATENCY(DB_LATENCY),
        .SAVED_LEN($bits(saved_t)),
        .DATABANK_SDP(DATABANK_SDP),
        .SDP_WRITE_INPUT_REG(SDP_WRITE_INPUT_REG),
        .CASCADE_DEPTH(CASCADE_DEPTH),
        .N_BANKS(N_BANKS)
    ) db_inst (
        .request_valid(db_req_valid),
        .request_rnw(db_req.rnw),
        .request_evict(db_req.evict),
        .request_line(db_req.line),
        .request_block(db_req.block),
        .request_id(db_req.id),
        .request_len(db_req.len),
        .request_way(db_req.way),
        .request_fill(db_req.fill),
        .ready(db_ready),
        .write_valid(db_wdata_valid),
        .write_data(wdata_fifo_data_out.data),
        .write_wbe(wdata_fifo_data_out.wbe),
        .write_data_ready(db_wdata_ready),
        .fill_valid(db_fill_valid),
        .fill_data(victim_rdata),
        .fill_wbe(fill_wbe),
        .fill_data_ready(db_fill_ready),
        .lookup_id(db_lookup_id),
        .lookup_way(db_lookup_way),
        .lookup_discard(db_lookup_discard),
        .lookup_evict(db_lookup_evict),
        .lookup_saved(db_lookup_saved),
        .out_ready(db_out_ready),
        .out_valid(db_out_valid),
        .out_last(db_out_last),
        .out_id(db_out_id),
        .out_evict(db_out_evict),
        .out_saved(db_out_saved),
        .out_data(db_out_data),
    .*);


    ////////////////////////////////////////////////////
    //Fill tracking
    //Ensure that an eviction request has completed before
    //the corresponding fill from main memory is accepted
    logic needs_evict_set;
    logic needs_evict_clear;
    logic needs_evict_rdata;
    logic next_evict_port;
    logic start_evict;

    //Set on read evictions or CBOMs that cause eviction
    assign needs_evict_set = tb_valid & tb_out_id.rnw & ((~tb_hit & tb_dirty & ~(INCLUDE_CBOM & (tb_out_clean | tb_out_inval))) | (INCLUDE_CBOM & tb_hit & tb_out_clean));

    //Clear once the evict data is ready
    //Full line is guaranteed to have been read because of the output FIFOs in the db
    assign needs_evict_clear = start_evict & db_out_id[next_evict_port].rnw;

    set_clear_memory #(.DEPTH(2**READ_ID_WIDTH)) needs_evict_table (
        .set(needs_evict_set),
        .set_addr(tb_out_id[READ_ID_WIDTH-1:0]),
        .clear(needs_evict_clear),
        .clear_addr(db_out_id[next_evict_port].id[READ_ID_WIDTH-1:0]),
        .read_addr(victim_rid[READ_ID_WIDTH-1:0]),
        .in_use(needs_evict_rdata),
    .*);

    //Writes causing evictions are tracked using the needs_wdata table

    ////////////////////////////////////////////////////
    //Fill logic
    //Fills have priority over regular requests for performance reasons and to prevent starvation
    //Specifically, fills are misses (older requests), and they block the memory bus
    logic ext_is_read;
    typedef struct packed {
        line_t line;
        block_t block;
        way_t way;
        block_t len;
    } fill_info_t;
    fill_info_t read_fill_info;
    fill_info_t write_fill_info;
    assign write_fill_info = '{
        line : tb_out_line,
        block : tb_out_block,
        way : tb_way,
        len : tb_out_len
    };

    assign fill_req = '{
        rnw : 0,
        evict : 0,
        line : read_fill_info.line,
        block : read_fill_info.block,
        id : 'x, //Not used by writes
        len : '1,
        way : read_fill_info.way,
        fill : 1
    };

    assign ext_is_read = victim_rid[ID_W-1];

    lutram_1w_1r #(
        .WIDTH($bits(fill_info_t)),
        .DEPTH(2**ID_W)
    ) fill_info_table (
        .waddr(tb_out_id),
        .raddr(victim_rid),
        .ram_write(tb_valid),
        .new_ram_data(write_fill_info),
        .ram_data_out(read_fill_info),
    .*);

    //Fills have lower priority than read hits
    //This is because the DB might block requests because it is waiting to be drained
    block_t fill_count;
    logic fill_rvalid;
    logic req_ready_for_fill;

    assign fill_rvalid = ext_is_read & victim_r.rvalid & db_fill_ready & fill_count <= read_fill_info.len & ~(victim_r.rlast & finish_full) & ~needs_evict_rdata;
    assign fill_request_valid = try_fill & db_fill_ready; //Only submit if external request is guaranteed to be accepted
    assign try_fill = ~filling & victim_r.rvalid & (ext_is_read ? req_ready_for_fill & ~needs_evict_rdata : ~ext_needs_rdata);
    assign db_fill_valid = victim_r.rvalid & ~(victim_r.rlast & finish_full) & (ext_is_read ? (fill_count > read_fill_info.len | req_ready_for_fill) & ~needs_evict_rdata : ~ext_needs_rdata);
    assign victim_rready = db_fill_ready & ~(victim_r.rlast & finish_full) & (ext_is_read ? (fill_count > read_fill_info.len | req_ready_for_fill) & ~needs_evict_rdata : ~ext_needs_rdata);

    assign ext_returning_last_w = filling & ~read_filling & victim_r.rvalid & victim_r.rlast & db_fill_ready;

    //Could use a shallow FIFO for external data for frequency

    always_ff @(posedge clk) begin
        if (rst) begin
            read_filling <= 0;
            filling <= 0;
            fill_count <= '0;
        end
        else begin
            if (victim_r.rvalid & victim_rready)
                fill_count <= fill_count + 1;
            if (fill_request_valid & db_ready) begin
                read_filling <= ext_is_read;
                filling <= 1;
            end
            if (victim_r.rvalid & victim_rready & victim_r.rlast) begin
                read_filling <= 0;
                filling <= 0;
            end
        end
    end

    //Write byte enable storage
    block_t wbe_counter;
    wbe_t ext_wbe;
    assign fill_wbe = ext_is_read | (fill_count > read_fill_info.len) ? '1 : ext_wbe;

    always_ff @(posedge clk) begin
        if (rst)
            wbe_counter <= '0;
        else if (wdata_fifo_pop)
            wbe_counter <= wdata_fifo_data_out.last ? '0 : wbe_counter+1;
    end

    lutram_1w_1r #(
        .WIDTH(BLOCK_W/8),
        .DEPTH((2**WRITE_ID_WIDTH)*LINE_W)
    ) wbe_table (
        .waddr({req_bid, wbe_counter}),
        .raddr({victim_rid[WRITE_ID_WIDTH-1:0], fill_count}),
        .ram_write(wdata_fifo_pop),
        .new_ram_data(~wdata_fifo_data_out.wbe),
        .ram_data_out(ext_wbe),
    .*);


    ////////////////////////////////////////////////////
    //DB ID lookup table
    //Written by tagbank, read inside the databank to mux ways and discard speculative clean read misses
    //Also saves info that will be used at the output of the databank

    assign tb_will_discard = (~tb_hit & ((INCLUDE_CBOM & tb_out_clean) | ~tb_dirty)) | (INCLUDE_CBOM & tb_out_inval & ~tb_out_clean);
    assign lookup_in = '{
        saved : '{
            //Writeback address tag. Normally a CleanInvalid's request tag equals
            //the resident tag (it matched), so tb_out_tag is used with a victim
            //cache. A by-index clean carries the WAY (not a tag) in the tag
            //field, so it must fall back to the tagbank's stored tag (tb_tag) to
            //write the dirty line back to its real {tag,set} address.
            tag : INCLUDE_CBOM & INCLUDE_VICTIM & tb_out_clean & tb_out_inval & ~tb_out_by_index ? tb_out_tag : tb_tag,
            line : tb_out_line,
            block : tb_out_block,
            clean : INCLUDE_CBOM & INCLUDE_VICTIM & tb_out_clean & tb_out_inval
        },
        way : tb_way,
        discard : tb_will_discard,
        evict : (~tb_hit & tb_dirty) | (INCLUDE_CBOM & tb_hit & tb_out_clean)
    };

    lutram_1w_mr #(
        .WIDTH($bits(lookup_t)),
        .DEPTH(2**ID_W),
        .NUM_READ_PORTS(2)
    ) way_table (
        .waddr(tb_out_id),
        .raddr(db_lookup_id),
        .ram_write(tb_valid),
        .new_ram_data(lookup_in),
        .ram_data_out(lookup_out),
    .*);

    ////////////////////////////////////////////////////
    //Databank output management
    //Output to interconnect on a hit, memory on an eviction
    //Read data from memory is also be routed to the interconnect
    logic hit_port;
    logic hit_port_r;
    rid_t out_cbom_rid;

    assign req_ready_for_fill = ~will_hit & ~hitting & ~(out_cbom_valid & ~read_filling) & out_ready;
    assign will_hit = ~hitting & ~read_filling & ((~db_out_evict[0] & db_out_valid[0]) | (~db_out_evict[1] & db_out_valid[1])) & ~(db_out_last[hit_port] & (finish_full | (victim_r.rvalid & victim_r.rlast)));
    assign hit_port = ~db_out_evict[1] & db_out_valid[1];

    always_comb begin
        if (will_hit) begin
            out_valid = 1;
            output_data.rdata = db_out_data[hit_port];
            output_data.rid = db_out_id[hit_port].id[READ_ID_WIDTH-1:0];
            output_data.rlast = db_out_last[hit_port];
        end
        else if (hitting) begin
            out_valid = db_out_valid[hit_port_r] & ~(db_out_last[hit_port_r] & (finish_full | ext_returning_last_w));
            output_data.rdata = db_out_data[hit_port_r];
            output_data.rid = db_out_id[hit_port_r].id[READ_ID_WIDTH-1:0];
            output_data.rlast = db_out_last[hit_port_r];
        end
        else if (out_cbom_valid & ~read_filling) begin
            out_valid = ~(finish_full | ext_returning_last_w);
            output_data.rdata = 'x;
            output_data.rid = out_cbom_rid;
            output_data.rlast = 1;
        end
        else begin
            out_valid = fill_rvalid;
            output_data.rdata = victim_rdata;
            output_data.rid = victim_rid[READ_ID_WIDTH-1:0];
            output_data.rlast = fill_count == read_fill_info.len;
        end
    end

    always_ff @(posedge clk) begin
        if (rst)
            hitting <= 0;
        else begin
            if (will_hit)
                hitting <= 1;
            if (output_data.rlast & out_ready)
                hitting <= 0;
        end
        if (will_hit)
            hit_port_r <= hit_port;
    end


    ////////////////////////////////////////////////////
    //Write requests
    //Evict data from databank
    //Evict info from lookup
    logic uncacheable_write;
    logic last_evict;
    logic evict_port;
    logic evicting;
    logic victim_awvalid;
    logic[ADDR_W-1:0] victim_awaddr;

    assign db_out_ready[0] = db_out_valid[0] & ((evicting & ~evict_port & victim_wready) | (out_ready & ((hitting & ~hit_port_r) | (will_hit & ~hit_port)) & ~(db_out_last[0] & (finish_full | ext_returning_last_w))));
    assign db_out_ready[1] = db_out_valid[1] & ((evicting & evict_port & victim_wready) | (out_ready & ((hitting & hit_port_r) | (will_hit & hit_port)) & ~(db_out_last[1] & (finish_full | ext_returning_last_w))));

    assign next_evict_port = db_out_valid[1] & db_out_evict[1];
    assign start_evict = ~evicting & ~victim_aw.awvalid & ((db_out_valid[0] & db_out_evict[0]) | (db_out_valid[1] & db_out_evict[1]));
    assign last_evict = victim_w.wvalid & victim_wready & victim_w.wlast;

    assign victim_aw.awvalid = victim_awvalid;
    assign victim_aw.awaddr = victim_awaddr;
    assign victim_aw.awlen = 8'(LINE_W-1);
    assign victim_aw.awburst = |victim_awaddr[LOG2_BLOCK_BYTES+:BLOCK_ADDR_W] ? 2'b10 : 2'b01; //Incr if aligned, else wrap
    assign victim_aw.awsize = 3'(LOG2_BLOCK_BYTES);
    assign victim_aw.awlock = 0;
    assign victim_aw.awcache = '1;
    assign victim_aw.awprot = '0;
    assign victim_aw.awqos = '0;
    assign victim_aw.awregion = '0;
    assign victim_aw.awsnoop = 3'b101;

    assign victim_w.wvalid = evicting & db_out_valid[evict_port];
    assign victim_wdata = db_out_data[evict_port];
    assign victim_w.wlast = db_out_last[evict_port];
    assign victim_wstrb = '1;

    always_ff @(posedge clk) begin
        if (rst) begin
            evicting <= 0;
            victim_awvalid <= 0;
        end
        else begin
            if (victim_awready)
                victim_awvalid <= 0;
            if (start_evict) begin
                victim_awvalid <= 1;
                evicting <= 1;
            end
            if (last_evict)
                evicting <= 0;
        end
        if (start_evict) begin
            evict_port <= next_evict_port;
            victim_awid <= db_out_id[next_evict_port];
            victim_awaddr <= OMITTED_CONSTANT | ADDR_W'({
                db_out_saved[next_evict_port].tag,
                db_out_saved[next_evict_port].line,
                db_out_saved[next_evict_port].block,
                {LOG2_BLOCK_BYTES{1'b0}}
            });
            uncacheable_write <= db_out_saved[next_evict_port].clean;
        end
    end

    ////////////////////////////////////////////////////
    //CBOM FIFO
    //Holds ARIDs of CBOM requests for returning
    generate if (INCLUDE_CBOM) begin : gen_cbom_fifo
        logic cbom_fifo_push;
        logic cbom_fifo_pop;
        rid_t cbom_fifo_data_in;

        typedef logic[$clog2(CBOM_FIFO_DEPTH):0] cbom_fifo_count_t;
        cbom_fifo_count_t cbom_fifo_count;
        logic cbom_increment;

        assign cbom_fifo_full = cbom_fifo_count[$clog2(CBOM_FIFO_DEPTH)];
        assign cbom_increment = chosen_ar.arvalid & chosen_arready & (in_inval | in_clean);

        always_ff @(posedge clk) begin
            if (rst)
                cbom_fifo_count <= '0;
            else
                cbom_fifo_count <= cbom_fifo_count + cbom_fifo_count_t'(cbom_increment) - cbom_fifo_count_t'(cbom_fifo_pop);
        end

        assign cbom_fifo_push = INCLUDE_VICTIM ? victim_invalidate : (tb_out_inval | tb_out_clean) & tb_valid;
        assign cbom_fifo_pop = out_cbom_valid & out_ready & ~(will_hit | hitting) & ~read_filling & ~(finish_full | ext_returning_last_w);
        assign cbom_fifo_data_in = INCLUDE_VICTIM ? ar_fifo_data_out.id[READ_ID_WIDTH-1:0] : tb_out_id[READ_ID_WIDTH-1:0];

        fifo #(.WIDTH($bits(rid_t)), .FIFO_DEPTH(CBOM_FIFO_DEPTH)) cbom_fifo_inst (
            .fifo_push(cbom_fifo_push),
            .fifo_pop(cbom_fifo_pop),
            .fifo_data_in(cbom_fifo_data_in),
            .fifo_data_out(out_cbom_rid),
            .fifo_valid(out_cbom_valid),
            .fifo_full(),
        .*);
    end else begin : gen_no_cbom
        assign cbom_fifo_full = 0;
        assign out_cbom_valid = 0;
        assign out_cbom_rid = 'x;
    end endgenerate


    ////////////////////////////////////////////////////
    //Output FIFO
    //Buffers output read data
    //Mostly to break timing paths at the output of this component
    output_data_t out_fifo_data_out;
    logic out_fifo_full;
    // The FIFO reset is synchronous; gate VALID in the reset cycle.
    logic out_fifo_valid;

    assign out_ready = ~out_fifo_full;
    assign req_rid = out_fifo_data_out.rid;
    assign req_r.rlast = out_fifo_data_out.rlast;
    assign req_r.rresp = '0;
    assign req_rdata = out_fifo_data_out.rdata;
    assign req_r.rvalid = out_fifo_valid & ~rst;
    fifo #(.WIDTH($bits(output_data_t)), .FIFO_DEPTH(OUT_FIFO_DEPTH)) out_fifo_inst (
        .fifo_push(out_valid & out_ready),
        .fifo_pop(req_r.rvalid & req_rready),
        .fifo_data_in(output_data),
        .fifo_data_out(out_fifo_data_out),
        .fifo_valid(out_fifo_valid),
        .fifo_full(out_fifo_full),
    .*);


    ////////////////////////////////////////////////////
    //Victim cache
    //Holds evicted lines
    //Optional
    //
    // Generate internal memory signals; gate VALID at the module boundary.
    ar_t mem_ar_int; logic[READ_ID_WIDTH:0]  mem_arid_int; logic mem_rready_int;
    aw_t mem_aw_int; logic[WRITE_ID_WIDTH:0] mem_awid_int; logic mem_bready_int;
    w_t  mem_w_int;  logic[BLOCK_W-1:0] mem_wdata_int; logic[(BLOCK_W/8)-1:0] mem_wstrb_int;
    generate if (INCLUDE_VICTIM) begin : gen_victim
        victim_cache #(
            .LINES(VICTIM_LINES),
            .ADDR_W(ADDR_W),
            .ADDR_RANGE_H(ADDR_RANGE_H),
            .ADDR_RANGE_L(ADDR_RANGE_L),
            .LINE_W(LINE_W),
            .BLOCK_W(BLOCK_W),
            .READ_ID_WIDTH(ID_W),
            .WRITE_ID_WIDTH(ID_W)
        ) vic_inst (
            .invalidate(victim_invalidate),
            .uncacheable_write(uncacheable_write),
            .cache_ar(victim_ar),
            .cache_arid(victim_arid),
            .cache_arready(victim_arready),
            .cache_r(victim_r),
            .cache_rdata(victim_rdata),
            .cache_rid(victim_rid),
            .cache_rready(victim_rready),
            .cache_aw(victim_aw),
            .cache_awid(victim_awid),
            .cache_awready(victim_awready),
            .cache_w(victim_w),
            .cache_wdata(victim_wdata),
            .cache_wstrb(victim_wstrb),
            .cache_wready(victim_wready),
            .cache_b(victim_b),
            .cache_bid(victim_bid),
            .cache_bready(victim_bready),
            // Mem maps to internal signals; the top-level mem_* ports are
            // driven below with VALID gating.
            .mem_ar(mem_ar_int), .mem_arid(mem_arid_int), .mem_arready(mem_arready),
            .mem_r(mem_r), .mem_rid(mem_rid), .mem_rdata(mem_rdata), .mem_rready(mem_rready_int),
            .mem_aw(mem_aw_int), .mem_awid(mem_awid_int), .mem_awready(mem_awready),
            .mem_w(mem_w_int), .mem_wdata(mem_wdata_int), .mem_wstrb(mem_wstrb_int), .mem_wready(mem_wready),
            .mem_b(mem_b), .mem_bid(mem_bid), .mem_bready(mem_bready_int),
            .clk(clk), .rst(rst)
        );
    end else begin : gen_no_victim
        assign mem_ar_int = victim_ar;
        assign mem_arid_int = victim_arid;
        assign victim_arready = mem_arready;
        assign victim_r = mem_r;
        assign victim_rid = mem_rid;
        assign victim_rdata = mem_rdata;
        assign mem_rready_int = victim_rready;
        assign mem_aw_int = victim_aw;
        assign mem_awid_int = victim_awid;
        assign victim_awready = mem_awready;
        assign mem_w_int = victim_w;
        assign mem_wdata_int = victim_wdata;
        assign mem_wstrb_int = victim_wstrb;
        assign victim_wready = mem_wready;
        assign victim_b = mem_b;
        assign victim_bid = mem_bid;
        assign mem_bready_int = victim_bready;
    end endgenerate

    // Drop memory-side VALID signals immediately during reset.
    always_comb begin
        mem_ar         = mem_ar_int;
        mem_ar.arvalid = mem_ar_int.arvalid & ~rst;
        mem_aw         = mem_aw_int;
        mem_aw.awvalid = mem_aw_int.awvalid & ~rst;
        mem_w          = mem_w_int;
        mem_w.wvalid   = mem_w_int.wvalid   & ~rst;
    end
    assign mem_arid   = mem_arid_int;
    assign mem_awid   = mem_awid_int;
    assign mem_wdata  = mem_wdata_int;
    assign mem_wstrb  = mem_wstrb_int;
    assign mem_rready = mem_rready_int;
    assign mem_bready = mem_bready_int;

    //Assertions check cache limitations, not AXI correctness
`ifndef ASSERT_OFF
    awaddr_assertion:
        assert property (@(posedge clk) disable iff (rst) req_aw.awvalid |-> (req_aw.awaddr >= ADDR_RANGE_L & req_aw.awaddr <= ADDR_RANGE_H)) else $error("Write out of address range");
    araddr_assertion:
        assert property (@(posedge clk) disable iff (rst) req_ar.arvalid |-> (req_ar.araddr >= ADDR_RANGE_L & req_ar.araddr <= ADDR_RANGE_H)) else $error("Read out of address range");
    awlen_assertion:
        assert property (@(posedge clk) disable iff (rst) req_aw.awvalid |-> (req_aw.awlen < LINE_W)) else $error("Write length greater than cache line");
    arlen_assertion:
        assert property (@(posedge clk) disable iff (rst) req_ar.arvalid |-> (req_ar.arlen < LINE_W)) else $error("Read length greater than cache line");
    awline_assertion:
        assert property (@(posedge clk) disable iff (rst) req_aw.awvalid |-> (~(req_aw.awburst == 2'b01 & (req_aw.awaddr[LOG2_BLOCK_BYTES+:BLOCK_ADDR_W] + req_aw.awlen >= LINE_W)))) else $error("Write reaches multiple cache lines");
    arline_assertion:
        assert property (@(posedge clk) disable iff (rst) req_ar.arvalid |-> (~(req_ar.arburst == 2'b01 & (req_ar.araddr[LOG2_BLOCK_BYTES+:BLOCK_ADDR_W] + req_ar.arlen >= LINE_W)))) else $error("Read reaches multiple cache lines");
    awsize_assertion:
        assert property (@(posedge clk) disable iff (rst) req_aw.awvalid |-> (req_aw.awsize == 3'(LOG2_BLOCK_BYTES))) else $error("No narrow writes");
    arsize_assertion:
        assert property (@(posedge clk) disable iff (rst) req_ar.arvalid |-> (req_ar.arsize == 3'(LOG2_BLOCK_BYTES))) else $error("No narrow reads");
    awburst_assertion:
        assert property (@(posedge clk) disable iff (rst) req_aw.awvalid |-> (req_aw.awburst != 2'b00)) else $error("Write fixed burst not supported");
    arburst_assertion:
        assert property (@(posedge clk) disable iff (rst) req_ar.arvalid |-> (req_ar.arburst != 2'b00)) else $error("Read fixed burst not supported");
    awlock_assertion:
        assert property (@(posedge clk) disable iff (rst) req_aw.awvalid |-> (~req_aw.awlock)) else $error("Write locked transactions not supported");
    arlock_assertion:
        assert property (@(posedge clk) disable iff (rst) req_ar.arvalid |-> (~req_ar.arlock)) else $error("Read locked transactions not supported");
    awcache_assertion:
        assert property (@(posedge clk) disable iff (rst) req_aw.awvalid |-> (&req_aw.awcache)) else $error("Writes must be write-back read and write allocate");
    arcache_assertion:
        assert property (@(posedge clk) disable iff (rst) req_ar.arvalid |-> (&req_ar.arcache)) else $error("Reads must be write-back read and write allocate");

    // Known-value accept/clear collisions are forbidden; ignore cold-reset Xs.
    inuse_id_no_same_cycle_collide:
        assert property (@(posedge clk) disable iff (rst)
            (finish_valid && finish_clear && tb_advance
             && !$isunknown({in_id, finish_id, in_hash, finish_hash}))
            |-> (in_id != finish_id)
        ) else $error("request accept and finish clear collide on one ID");
    inuse_line_no_same_cycle_collide:
        assert property (@(posedge clk) disable iff (rst)
            (finish_valid && finish_clear && tb_advance
             && !$isunknown({in_id, finish_id, in_hash, finish_hash}))
            |-> (in_hash != finish_hash)
        ) else $error("request accept and finish clear collide on one line hash");
    finish_clear_implies_valid:
        assert property (@(posedge clk) disable iff (rst)
            finish_clear |-> finish_valid
        ) else $error("finish_clear without finish_valid");
    memory_read_response_ok:
        assert property (@(posedge clk) disable iff (rst)
            victim_r.rvalid |-> (victim_r.rresp[1:0] == 2'b00)
        ) else $error("l2_cache: non-OKAY memory RRESP is unsupported");
    memory_write_response_ok:
        assert property (@(posedge clk) disable iff (rst)
            victim_b.bvalid |-> (victim_b.bresp == 2'b00)
        ) else $error("l2_cache: non-OKAY memory BRESP is unsupported");

    // Cover concurrent progress, stalls, finish pressure, and repeat suppression.
    cp_concurrent_issue_and_finish:
        cover property (@(posedge clk) disable iff (rst) tb_advance && finish_clear);
    cp_inuse_stall_seen:
        cover property (@(posedge clk) disable iff (rst) inuse_stall);
    cp_finish_fifo_full:
        cover property (@(posedge clk) disable iff (rst) finish_full);
    cp_same_target_suppression:
        cover property (@(posedge clk) disable iff (rst) finish_clear_raw && ~finish_clear);
`endif

endmodule
