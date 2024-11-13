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

module victim_cache

    import cache_config::*;

    #(
        //For victim
        parameter int unsigned LINES = 8,
        //From primary cache
        parameter logic[31:0] ADDR_RANGE_H = 32'hFFFFFFFF,
        parameter logic[31:0] ADDR_RANGE_L = 32'h80000000,
        parameter int unsigned LINE_W = 8,
        parameter int unsigned BLOCK_W = 32,
        parameter int unsigned READ_ID_WIDTH = 5,
        parameter int unsigned WRITE_ID_WIDTH = 5
    )
    (
        input logic clk,
        input logic rst,

        input logic invalidate, //When signalled, invalidate ARADDR
        input logic uncacheable_write, //Signalled with AWVALID

        input ar_t cache_ar,
        input logic[READ_ID_WIDTH-1:0] cache_arid,
        output logic cache_arready,
        output r_t cache_r,
        output logic[BLOCK_W-1:0] cache_rdata,
        output logic[READ_ID_WIDTH-1:0] cache_rid,
        input logic cache_rready,
        input aw_t cache_aw,
        input logic[WRITE_ID_WIDTH-1:0] cache_awid,
        output logic cache_awready,
        input w_t cache_w,
        input logic[BLOCK_W-1:0] cache_wdata,
        input logic[(BLOCK_W/8)-1:0] cache_wstrb,
        output logic cache_wready,
        output b_t cache_b,
        output logic[WRITE_ID_WIDTH-1:0] cache_bid,
        input logic cache_bready,

        output ar_t mem_ar,
        output logic[READ_ID_WIDTH-1:0] mem_arid,
        input logic mem_arready,
        input r_t mem_r,
        input logic[BLOCK_W-1:0] mem_rdata,
        input logic[READ_ID_WIDTH-1:0] mem_rid,
        output logic mem_rready,
        output aw_t mem_aw,
        output logic[WRITE_ID_WIDTH-1:0] mem_awid,
        input logic mem_awready,
        output w_t mem_w,
        output logic[BLOCK_W-1:0] mem_wdata,
        output logic[(BLOCK_W/8)-1:0] mem_wstrb,
        input logic mem_wready,
        input b_t mem_b,
        input logic[WRITE_ID_WIDTH-1:0] mem_bid,
        output logic mem_bready
    );

    ////////////////////////////////////////////////////
    //Victim cache
    //Small write-through fully-associative write-through cache
    //Does not increase latency on misses

    //This component cannot handle ordering for requests with the same ARID

    //These parameters can be customized
    localparam int unsigned MAX_READ_PENDING = 8; //Number of hit requests that can be outstanding at a given time
    localparam int unsigned MAX_WRITE_PENDING = 8; //Max number of AW transactions that can be outstanding before the corresponding W

    //Constants
    localparam int unsigned BLOCK_ADDR_W = $clog2(LINE_W);
    localparam int unsigned OMITTED_ADDR_W = 32-$clog2(ADDR_RANGE_H-ADDR_RANGE_L+1);
    localparam int unsigned CONSTANT_LOWER_W = $clog2(BLOCK_W/8);
    localparam int unsigned TAG_W = 32-OMITTED_ADDR_W-BLOCK_ADDR_W-CONSTANT_LOWER_W;

    typedef logic[TAG_W-1:0] tag_t;
    typedef logic[BLOCK_ADDR_W-1:0] block_t;
    typedef logic[BLOCK_W-1:0] block_data_t;
    typedef logic[READ_ID_WIDTH-1:0] rid_t;

    typedef struct packed {
        logic[OMITTED_ADDR_W-1:0] upper_constant;
        tag_t tag;
        block_t block;
        logic[CONSTANT_LOWER_W-1:0] lower_constant;
    } addr_t;

    typedef logic[$clog2(LINES)-1:0] line_t;
    typedef logic[$bits(line_t)+$bits(block_t)-1:0] index_t;

    typedef struct packed {
        rid_t id;
        line_t line;
        block_t block;
    } pending_hit_t;
    pending_hit_t pending_reads_data_out;

    logic[LINES-1:0] reservations;
    logic hit;
    logic[LINES-1:0] hit_one_hot;
    logic[LINES-1:0] write_hit_one_hot;
    line_t hit_index;

    ////////////////////////////////////////////////////
    //Implementation
    addr_t r_addr;
    addr_t w_addr;
    assign r_addr = cache_ar.araddr;
    assign w_addr = cache_aw.awaddr;

    ////////////////////////////////////////////////////
    //Replacement
    //Uses a FIFO scheme to decide which way should be overwritten on an eviction
    line_t replacement_index;
    always_ff @(posedge clk) begin
        if (rst)
            replacement_index <= '0;
        else if (cache_aw.awvalid & cache_awready) //Regardless of whether we are storing the request, increment the replacement index
            replacement_index <= replacement_index+1;
    end

    ////////////////////////////////////////////////////
    //Tag storage
    //Uses a CAM
    tag_t[LINES-1:0] tags;
    logic[LINES-1:0] tags_valid;
    line_t write_line;
    logic buffer_tag;

    assign buffer_tag = ~reservations[replacement_index] & ~uncacheable_write & ~(cache_ar.arvalid & hit & hit_index == replacement_index);

    always_ff @(posedge clk) begin
        if (rst)
            tags_valid <= '0;
        else begin
            if (invalidate)
                tags_valid <= tags_valid & ~hit_one_hot;
            if (cache_aw.awvalid & cache_awready) begin
                tags_valid <= tags_valid & ~write_hit_one_hot;
                if (buffer_tag)
                    tags_valid[replacement_index] <= 1;
            end
        end
        if (cache_aw.awvalid & cache_awready & buffer_tag)
            tags[replacement_index] <= w_addr.tag;
    end

    //Hit detection
    assign hit = |hit_one_hot;
    always_comb begin
        hit_one_hot = '0;
        write_hit_one_hot = '0;
        hit_index = 'x;
        for (int i = 0; i < LINES; i++) begin
            write_hit_one_hot[i] = tags[i] == w_addr.tag;
            if (tags_valid[i] & tags[i] == r_addr.tag) begin
                hit_one_hot[i] = 1;
                hit_index = line_t'(i);
            end
        end
    end

    ////////////////////////////////////////////////////
    //Write info buffering
    typedef struct packed {
        logic buffer;
        line_t line;
        block_t block;
    } pending_write_t;
    pending_write_t pending_writes_data_out;
    pending_write_t pending_writes_data_in;
    logic pending_writes_pop;
    logic pending_writes_push;
    logic pending_writes_valid;
    logic pending_writes_full;

    assign pending_writes_pop = cache_w.wvalid & cache_wready & cache_w.wlast;
    assign pending_writes_push = cache_aw.awvalid & cache_awready;
    assign pending_writes_data_in = '{
        buffer : buffer_tag,
        line : replacement_index,
        block : w_addr.block
    };
    assign write_line = pending_writes_data_out.line;

    fifo #(.WIDTH($bits(pending_write_t)), .FIFO_DEPTH(MAX_WRITE_PENDING)) pending_writes_inst (
        .fifo_push(pending_writes_push),
        .fifo_pop(pending_writes_pop),
        .fifo_data_in(pending_writes_data_in),
        .fifo_data_out(pending_writes_data_out),
        .fifo_valid(pending_writes_valid),
        .fifo_full(pending_writes_full),
    .*);

    ////////////////////////////////////////////////////
    //Line storage
    //Holds multiple evicted lines of fixed length
    block_data_t hit_data;
    block_t read_block;
    block_t write_block;
    block_t saved_write_block;
    block_t next_write_block;
    logic first_write_cycle;

    assign write_block = first_write_cycle ? pending_writes_data_out.block : saved_write_block;
    assign next_write_block = write_block+1;

    always_ff @(posedge clk) begin
        if (rst)
            first_write_cycle <= 1;
        else if (cache_w.wvalid & cache_wready)
            first_write_cycle <= cache_w.wlast;
        if (cache_w.wvalid & cache_wready)
            saved_write_block <= next_write_block;
    end

    lutram_1w_1r #(.WIDTH($bits(block_data_t)), .DEPTH(LINES*LINE_W)) line_storage (
        .waddr({write_line, write_block}),
        .raddr({pending_reads_data_out.line, read_block}),
        .ram_write(cache_w.wvalid & cache_wready & pending_writes_data_out.buffer),
        .new_ram_data(cache_wdata),
        .ram_data_out(hit_data),
    .*);

    ////////////////////////////////////////////////////
    //Pending storage
    //Hits are buffered until they can be returned
    logic last_read;
    pending_hit_t pending_reads_data_in;
    logic pending_reads_pop;
    logic pending_reads_push;
    logic pending_reads_valid;
    logic pending_reads_full;

    assign pending_reads_push = cache_ar.arvalid & cache_arready & hit;
    assign pending_reads_pop = last_read;
    assign pending_reads_data_in = '{
        id : cache_arid,
        line : hit_index,
        block : r_addr.block
    };

    fifo #(.WIDTH($bits(pending_hit_t)), .FIFO_DEPTH(MAX_READ_PENDING)) pending_reads_inst (
        .fifo_push(pending_reads_push),
        .fifo_pop(pending_reads_pop),
        .fifo_data_in(pending_reads_data_in),
        .fifo_data_out(pending_reads_data_out),
        .fifo_valid(pending_reads_valid),
        .fifo_full(pending_reads_full),
    .*);

    ////////////////////////////////////////////////////
    //Read response management
    //Implemented as a state machine
    //Returns hit data by draining the pending fifo and reading from the line ban
    block_t saved_read_block;
    block_t next_read_block;

    typedef enum {
        IDLE,
        BLOCKED,
        RETURNING
    } return_state_t;
    return_state_t current_state;
    return_state_t next_state;

    always_ff @(posedge clk) begin
        if (rst)
            current_state <= IDLE;
        else
            current_state <= next_state;
    end

    always_comb begin
        unique case (current_state)
            IDLE : begin
                //Tie goes to external
                cache_r.rvalid = mem_r.rvalid | pending_reads_valid;
                cache_r.rlast = 0;
                cache_rdata = mem_r.rvalid ? mem_rdata : hit_data;
                cache_rid = mem_r.rvalid ? mem_rid : pending_reads_data_out.id;
                mem_rready = cache_rready;

                if (mem_r.rvalid)
                    next_state = BLOCKED;
                else if (pending_reads_valid & cache_rready)
                    next_state = RETURNING;
                else
                    next_state = IDLE;
            end
            BLOCKED : begin
                cache_r.rvalid = mem_r.rvalid;
                cache_r.rlast = mem_r.rlast;
                cache_rdata = mem_rdata;
                cache_rid = mem_rid;
                mem_rready = cache_rready;
                next_state = mem_r.rlast & mem_r.rvalid & cache_rready ? IDLE : BLOCKED;
            end
            RETURNING : begin
                cache_r.rvalid = 1;
                cache_r.rlast = next_read_block == pending_reads_data_out.block;
                cache_rdata = hit_data;
                cache_rid = pending_reads_data_out.id;
                mem_rready = 0;
                next_state = cache_rready & next_read_block == pending_reads_data_out.block ? IDLE : RETURNING;
            end
        endcase
    end

    assign last_read = current_state == RETURNING & next_state == IDLE;
    assign read_block = current_state == IDLE ? pending_reads_data_out.block : saved_read_block;
    assign next_read_block = read_block+1;

    always_ff @(posedge clk) begin
        if (cache_rready)
            saved_read_block <= next_read_block;
    end

    ////////////////////////////////////////////////////
    //Reservation tracking
    //On a hit, the line is saved and the request is saved in the response FIFO
    //Keep track of which lines have reservations so we never evict them
    always_ff @(posedge clk) begin
        if (rst)
            reservations <= '0;
        else begin
            if (last_read)
                reservations[pending_reads_data_out.line] <= 0;
            if (cache_arready & cache_ar.arvalid & hit)
                reservations[hit_index] <= 1;
        end
    end

    ////////////////////////////////////////////////////
    //AXI passthrough
    //Transparent AW, W, and B
    //Opaque R and AR
    assign mem_ar.arvalid = cache_ar.arvalid & ~hit;
    assign mem_ar.araddr = cache_ar.araddr;
    assign mem_ar.arlen = cache_ar.arlen;
    assign mem_ar.arburst = cache_ar.arburst;
    assign mem_ar.arsize = cache_ar.arsize;
    assign mem_ar.arlock = cache_ar.arlock;
    assign mem_ar.arcache = cache_ar.arcache;
    assign mem_ar.arqos = cache_ar.arqos;
    assign mem_ar.arregion = cache_ar.arregion;
    assign mem_ar.arsnoop = cache_ar.arsnoop;
    assign mem_arid = cache_arid;
    assign mem_ar.arprot = cache_ar.arprot;
    assign cache_arready = mem_arready & ~pending_reads_full;

    assign cache_r.rresp = '0; //OK

    assign mem_aw.awvalid = cache_aw.awvalid & ~pending_writes_full;
    assign mem_aw.awaddr = cache_aw.awaddr;
    assign mem_aw.awlen = cache_aw.awlen;
    assign mem_aw.awburst = cache_aw.awburst;
    assign mem_aw.awsize = cache_aw.awsize;
    assign mem_aw.awlock = cache_aw.awlock;
    assign mem_aw.awcache = cache_aw.awcache;
    assign mem_aw.awprot = cache_aw.awprot;
    assign mem_aw.awqos = cache_aw.awqos;
    assign mem_aw.awregion = cache_aw.awregion;
    assign mem_aw.awsnoop = cache_aw.awsnoop;
    assign mem_awid = cache_awid;
    assign cache_awready = mem_awready & ~pending_writes_full;

    assign mem_w.wvalid = cache_w.wvalid & pending_writes_valid;
    assign mem_wdata = cache_wdata;
    assign mem_wstrb = cache_wstrb;
    assign mem_w.wlast = cache_w.wlast;
    assign cache_wready = mem_wready & pending_writes_valid;

    assign cache_b.bvalid = mem_b.bvalid;
    assign cache_bid = mem_bid;
    assign cache_b.bresp = '0; //OK
    assign mem_bready = cache_bready;

endmodule
