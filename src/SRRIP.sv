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

 module SRRIP

    #(
        parameter logic RRPV_HP,
        parameter int unsigned RRPV_WIDTH,
        parameter int unsigned POLICY_W,
        parameter int unsigned WAYS
    )
    (
        input logic clk,
        input logic rst,

        input logic cache_eviction,
        input logic[WAYS-1:0] cache_way_used_one_hot,
        input logic[POLICY_W-1:0] cache_original_status,
        output logic[POLICY_W-1:0] cache_new_status,
        output logic[WAYS-1:0] cache_replacement_way,
        output logic[$clog2(WAYS)-1:0] cache_replacement_way_int
    );

    ////////////////////////////////////////////////////
    //Static re-reference interval prediction cache replacement policy

    localparam int unsigned WAY_W = $clog2(WAYS);
    genvar i;

    ////////////////////////////////////////////////////
    //Implementation

    //Casting input and output
    //Index represents way, value represents prediction
    logic[RRPV_WIDTH-1:0] current_RRPV[WAYS-1:0];
    logic[RRPV_WIDTH-1:0] updated_RRPV[WAYS-1:0];
    generate for (i = 0; i < WAYS; i++) begin : array_parsing
        assign current_RRPV[i] = cache_original_status[(i+1)*RRPV_WIDTH -1 : i*RRPV_WIDTH];
        assign cache_new_status[(i+1)*RRPV_WIDTH -1 : i*RRPV_WIDTH] = updated_RRPV[i];
    end endgenerate


    int victim_index; //Keep track of which way was lowest, will be evicted
    logic[RRPV_WIDTH-1:0] min_RRPV; //The amount to increase each entry by in case of a miss
    rrip_tree #(.BLOCK_WIDTH(RRPV_WIDTH), .NUM_BLOCKS(WAYS)) min_tree (
        .blocks(current_RRPV),
        .lowest_index(victim_index),
        .smallest_value(min_RRPV)
    );

    always_comb begin
        updated_RRPV = current_RRPV;
        for (int j = 0; j < WAYS; j++) begin
            if (cache_way_used_one_hot[j] & ~cache_eviction) begin
                if (~RRPV_HP & updated_RRPV[j] != 0) //FP decrements on hit
                    updated_RRPV[j] -= 1;
                else //HP sets to 0
                    updated_RRPV[j] = 0;
            end
            else if (cache_eviction) begin
                updated_RRPV[j] += min_RRPV;
                if (j == victim_index)
                    updated_RRPV[j][0] = 0; //Insert at 2^RRPV-1 - a 'long' prediction
            end
        end
    end

    assign cache_replacement_way_int = WAY_W'(victim_index);
    assign cache_replacement_way = 1 << victim_index;

endmodule
