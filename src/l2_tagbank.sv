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

module l2_tagbank

    import cache_config::*;

    #(
        parameter replacement_policy_t POLICY,
        parameter int unsigned WAYS,
        parameter int unsigned BLOCK_W,
        parameter int unsigned ID_W,
        parameter int unsigned TAG_W,
        parameter int unsigned LINES,
        parameter int unsigned LINE_W,
        parameter logic RANDOM_USE_EVICT = 1,
        parameter logic RRIP_HP = 1,
        parameter int unsigned RRIP_WIDTH = 2,
        parameter int unsigned ADDR_W = 32,
        // Upper-bit constant that the cache strips out of every address before
        // tagging.  We OR it back into policy_addr so address-aware policies
        // (GRASP) see real addresses, not the tag-projected view.
        parameter logic[ADDR_W-1:0] ADDR_BASE = '0
    )
    (
        input logic clk,
        input logic rst,

        // Runtime-configurable GRASP address region bounds (0 = disabled)
        input logic[ADDR_W-1:0] grasp_high_addr_l,
        input logic[ADDR_W-1:0] grasp_high_addr_h,
        input logic[ADDR_W-1:0] grasp_moderate_addr_l,
        input logic[ADDR_W-1:0] grasp_moderate_addr_h,

        //Request port
        input logic in_valid,
        input logic[ID_W-1:0] in_request_id,
        input logic[TAG_W-1:0] in_request_tag,
        input logic[$clog2(LINES)-1:0] in_request_line,
        input logic[$clog2(LINE_W)-1:0] in_request_block,
        input logic[$clog2(LINE_W)-1:0] in_request_len,
        input logic in_request_inval,
        input logic in_request_clean,
        input logic in_request_full_write,

        output logic out_valid,
        output logic[ID_W-1:0] out_request_id,
        output logic[TAG_W-1:0] out_request_tag,
        output logic[$clog2(LINES)-1:0] out_request_line,
        output logic[$clog2(LINE_W)-1:0] out_request_block,
        output logic[$clog2(LINE_W)-1:0] out_request_len,
        output logic out_request_inval,
        output logic out_request_clean,
        output logic out_request_full_write,
        output logic out_hit,
        output logic out_dirty,
        output logic[TAG_W-1:0] out_tag,
        output logic[$clog2(WAYS)-1:0] out_way //Either replacement or hit way
    );

    ////////////////////////////////////////////////////
    //L2 tagbank
    //Simple pipeline takes in requests and determines if there is a hit or miss
    //Divided into stage 0 (request), stage 1 (determine if hit), and stage 2 (output, determine replacement)

    localparam int unsigned LOG2_BLOCK_BYTES = $clog2(BLOCK_W/8);

    typedef logic[TAG_W-1:0] tag_t;
    typedef logic[$clog2(LINES)-1:0] line_t;
    typedef logic[$clog2(LINE_W)-1:0] block_t;
    typedef logic[$clog2(WAYS)-1:0] way_t;

    typedef struct packed {
        logic valid;
        logic dirty;
        tag_t tag;
    } way_entry_t;

    typedef struct packed {
        logic[ID_W-1:0] id;
        tag_t tag;
        line_t line;
        block_t block;
        block_t len;
        logic inval;
        logic clean;
        logic full_write;
    } request_t;


    ////////////////////////////////////////////////////
    //Implementation

    ////////////////////////////////////////////////////
    //Pipeline control
    //No stall conditions
    logic stage1_valid;
    logic stage2_valid;
    request_t in_request;
    request_t stage1;
    request_t stage2;

    assign in_request = '{
        id : in_request_id,
        tag : in_request_tag,
        line : in_request_line,
        block : in_request_block,
        len : in_request_len,
        inval : in_request_inval,
        clean : in_request_clean,
        full_write : in_request_full_write
    };

    always_ff @(posedge clk) begin
        if (rst) begin
            stage1_valid <= 0;
            stage2_valid <= 0;
        end
        else begin
            stage1_valid <= in_valid;
            stage2_valid <= stage1_valid;
        end
        stage1 <= in_request;
        stage2 <= stage1;
    end


    ////////////////////////////////////////////////////
    //Tagbank
    //Read on stage 0, written on stage 2
    way_entry_t[WAYS-1:0] tb_rdata;
    way_entry_t rst_value;
    assign rst_value = '{
        valid : 0,
        dirty : 'x,
        tag : 'x
    };

    logic[WAYS-1:0] tb_wbe;
    logic tb_wen;
    way_entry_t tb_wdata;
    way_entry_t[WAYS-1:0] tb_rdata_r;
    logic hit;
    way_t hit_index;
    logic[WAYS-1:0] hit_one_hot;
    logic[WAYS-1:0] hit_one_hot_r;

    always_ff @(posedge clk) begin
        hit_one_hot_r <= hit_one_hot;
        tb_rdata_r <= tb_rdata;
    end

    assign hit = |hit_one_hot_r;
    always_comb begin
        for (int i = 0; i < WAYS; i++)
            hit_one_hot[i] = tb_rdata[i].valid & stage1.tag == tb_rdata[i].tag;
    end

    one_hot_to_integer #(.WIDTH(WAYS)) ohot (
        .one_hot(hit_one_hot_r),
        .int_out(hit_index)
    );

    sdp_ram_padded_rst #(
        .ADDR_WIDTH($clog2(LINES)),
        .NUM_COL(WAYS),
        .COL_WIDTH($bits(way_entry_t)),
        .PIPELINE_DEPTH(0),
        .CASCADE_DEPTH(4)
    ) tagbank (
        .rst_value({WAYS{rst_value}}),
        .a_en(tb_wen),
        .a_wbe(tb_wbe),
        .a_wdata({WAYS{tb_wdata}}),
        .a_addr(stage2.line),
        .b_en(in_valid),
        .b_addr(in_request.line),
        .b_rdata(tb_rdata),
    .*);

    ////////////////////////////////////////////////////
    //Replacement policy
    //Determines which way should be evicted on a miss
    way_entry_t evict_entry;
    way_t policy_replacement_way_int;
    logic[WAYS-1:0] policy_replacement_way;
    logic[ADDR_W-1:0] policy_addr;

    assign policy_addr = ADDR_BASE | ADDR_W'({stage2.tag, stage2.line, {LOG2_BLOCK_BYTES{1'b0}}});
    assign evict_entry = tb_rdata_r[policy_replacement_way_int];

    replacement_policy #(
        .POLICY(POLICY),
        .WAYS(WAYS),
        .LINES(LINES),
        .RANDOM_USE_EVICT(RANDOM_USE_EVICT),
        .RRIP_HP(RRIP_HP),
        .RRIP_WIDTH(RRIP_WIDTH),
        .ADDR_W(ADDR_W)
    ) policy_inst (
        .init_lookup(in_valid),
        .lookup_line_addr(in_request.line),
        .cache_valid(stage2_valid),
        .cache_line_addr(stage2.line),
        .cache_way_used_one_hot(hit_one_hot_r),
        .cache_way_used_int(hit_index),
        .cache_eviction(~hit),
        .cache_addr(policy_addr),
        .cache_replacement_way(policy_replacement_way),
        .cache_replacement_way_int(policy_replacement_way_int),
    .*);

    ////////////////////////////////////////////////////
    //Stage 2 logic
    //Output and writing back to tagbank

    //The entry that will be evicted from this set: for a normal miss
    //it's the policy-chosen replacement way; for a CBOM hit-evict
    //(CleanInvalid / CleanShared on a cached line) it's the hit way
    //itself. Before the 2026-05 bug #16 fix both `out_dirty` and
    //`out_tag` always read from the policy way, so a CBOM that hit a
    //dirty line in a different way got out_tag from an arbitrary
    //(usually invalid, tag=0) way -> writeback went to the wrong mem
    //address. See doc/ARCHITECTURE.md §7.5 entry #16.
    way_entry_t evicted_entry;
    assign evicted_entry = hit ? tb_rdata_r[hit_index] : evict_entry;

    assign out_valid = stage2_valid;
    assign out_request_id = stage2.id;
    assign out_request_tag = stage2.tag;
    assign out_request_line = stage2.line;
    assign out_request_block = stage2.block;
    assign out_request_len = stage2.len;
    assign out_request_inval = stage2.inval;
    assign out_request_clean = stage2.clean;
    assign out_request_full_write = stage2.full_write;
    assign out_hit = hit;
    assign out_dirty = evicted_entry.valid & evicted_entry.dirty;
    assign out_way = hit ? hit_index : policy_replacement_way_int;
    assign out_tag = evicted_entry.tag;

    assign tb_wen = stage2_valid & ~(~hit & (stage2.inval | stage2.clean));
    assign tb_wbe = hit ? hit_one_hot_r : policy_replacement_way;
    assign tb_wdata = '{
        valid : ~stage2.inval,
        dirty : (hit & tb_rdata_r[hit_index].dirty & ~stage2.clean) | ~stage2.id[ID_W-1],
        tag : stage2.tag
    };

endmodule
