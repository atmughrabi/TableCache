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

module GRASP

    #(
        parameter int unsigned POLICY_W,
        parameter int unsigned WAYS,
        parameter int unsigned ADDR_W = 32
    )
    (
        input logic clk,
        input logic rst,

        // Runtime-configurable address region bounds.
        // A region is DISABLED when its _h bound is 0 (both ports driven to
        // 0 at runtime means "not in use").  When both regions are disabled the
        // policy reduces to SRRIP-FP: cold (MAX_RRPV) insertion, decrement on hit.
        input logic[ADDR_W-1:0] grasp_high_addr_l,
        input logic[ADDR_W-1:0] grasp_high_addr_h,
        input logic[ADDR_W-1:0] grasp_moderate_addr_l,
        input logic[ADDR_W-1:0] grasp_moderate_addr_h,

        input logic cache_eviction,
        input logic[WAYS-1:0] cache_way_used_one_hot,
        input logic[POLICY_W-1:0] cache_original_status,
        input logic[ADDR_W-1:0] cache_addr,
        output logic[POLICY_W-1:0] cache_new_status,
        output logic[WAYS-1:0] cache_replacement_way,
        output logic[$clog2(WAYS)-1:0] cache_replacement_way_int
    );

    ////////////////////////////////////////////////////
    //Graph-aware RRIP inspired by the HPCA'20 GRASP simulator.
    //This hardware form uses static address windows to classify accesses as
    //high-, moderate-, or default-reuse and applies distinct insertion/hit
    //promotion positions on top of a 3-bit RRIP state.

    localparam int unsigned RRPV_WIDTH = 3;
    localparam int unsigned WAY_W = $clog2(WAYS);
    localparam logic[RRPV_WIDTH-1:0] MAX_RRPV = '1;
    localparam logic[RRPV_WIDTH-1:0] HOT_INSERT_RRPV = '0;
    localparam logic[RRPV_WIDTH-1:0] MODERATE_INSERT_RRPV = RRPV_WIDTH'(1);
    localparam logic[RRPV_WIDTH-1:0] HOT_HIT_RRPV = '0;
    genvar i;

    logic[RRPV_WIDTH-1:0] current_RRPV[WAYS-1:0];
    logic[RRPV_WIDTH-1:0] updated_RRPV[WAYS-1:0];
    logic high_reuse;
    logic moderate_reuse;
    int victim_index;
    logic[RRPV_WIDTH-1:0] min_RRPV;

    generate for (i = 0; i < WAYS; i++) begin : array_parsing
        assign current_RRPV[i] = cache_original_status[(i+1)*RRPV_WIDTH -1 : i*RRPV_WIDTH];
        assign cache_new_status[(i+1)*RRPV_WIDTH -1 : i*RRPV_WIDTH] = updated_RRPV[i];
    end endgenerate

    // Region active only when _h != 0 AND _h >= _l.  Setting both ports to 0
    // (the "not in use" convention) cleanly disables the region.
    assign high_reuse = (grasp_high_addr_h != 0) &
        (grasp_high_addr_h >= grasp_high_addr_l) &
        (cache_addr >= grasp_high_addr_l) & (cache_addr <= grasp_high_addr_h);
    assign moderate_reuse = (grasp_moderate_addr_h != 0) &
        (grasp_moderate_addr_h >= grasp_moderate_addr_l) &
        (cache_addr >= grasp_moderate_addr_l) & (cache_addr <= grasp_moderate_addr_h) &
        ~high_reuse;

    rrip_tree #(.BLOCK_WIDTH(RRPV_WIDTH), .NUM_BLOCKS(WAYS)) min_tree (
        .blocks(current_RRPV),
        .lowest_index(victim_index),
        .smallest_value(min_RRPV)
    );

    always_comb begin
        updated_RRPV = current_RRPV;
        for (int j = 0; j < WAYS; j++) begin
            if (cache_way_used_one_hot[j] & ~cache_eviction) begin
                if (high_reuse)
                    updated_RRPV[j] = HOT_HIT_RRPV;
                else if (updated_RRPV[j] != 0)
                    updated_RRPV[j] -= 1'b1;
            end
            else if (cache_eviction) begin
                updated_RRPV[j] += min_RRPV;
                if (j == victim_index) begin
                    if (high_reuse)
                        updated_RRPV[j] = HOT_INSERT_RRPV;
                    else if (moderate_reuse)
                        updated_RRPV[j] = MODERATE_INSERT_RRPV;
                    else
                        updated_RRPV[j] = MAX_RRPV;
                end
            end
        end
    end

    assign cache_replacement_way_int = WAY_W'(victim_index);
    assign cache_replacement_way = WAYS'(1 << victim_index);

endmodule
