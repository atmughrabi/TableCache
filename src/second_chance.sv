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

module second_chance

    #(
        parameter int unsigned POLICY_W = 6,
        parameter int unsigned WAYS = 4
    )
    (
        input logic clk,
        input logic rst,
        
        input logic cache_eviction,
        input logic[$clog2(WAYS)-1:0] cache_way_used_int,
        input logic[POLICY_W-1:0] cache_original_status,
        output logic[POLICY_W-1:0] cache_new_status,
        output logic[WAYS-1:0] cache_replacement_way,
        output logic[$clog2(WAYS)-1:0] cache_replacement_way_int
    );

    ////////////////////////////////////////////////////
    //Second chance (clock) cache replacement policy

    localparam int unsigned WAY_W = $clog2(WAYS);

    ////////////////////////////////////////////////////
    //Implementation
    logic[WAYS-1:0] second_chance;
    logic[WAY_W-1:0] start_index;
    assign {start_index, second_chance} = cache_original_status;

    logic[WAYS-1:0] hit_chance;
    logic[WAYS-1:0] finish_chance;
    logic[WAY_W-1:0] scan_index;
    logic[WAY_W-1:0] victim_index;
    logic[WAY_W-1:0] next_index;
    logic victim_found;

    function automatic logic[WAY_W-1:0] increment_way(
        input logic[WAY_W-1:0] index
    );
        if (index == WAY_W'(WAYS-1))
            increment_way = '0;
        else
            increment_way = index + 1'b1;
    endfunction

    always_comb begin
        hit_chance = second_chance;
        hit_chance[cache_way_used_int] = 1;

        finish_chance = second_chance;
        scan_index = start_index;
        victim_index = start_index;
        victim_found = 1'b0;
        for (int i = 0; i < WAYS; i++) begin
            if (!victim_found) begin
                if (!second_chance[scan_index]) begin
                    victim_index = scan_index;
                    victim_found = 1'b1;
                end else begin
                    finish_chance[scan_index] = 1'b0;
                    scan_index = increment_way(scan_index);
                end
            end
        end
        if (!victim_found)
            victim_index = scan_index;
        finish_chance[victim_index] = 1'b0;
        next_index = increment_way(victim_index);
    end

    assign cache_new_status = cache_eviction
        ? {next_index, finish_chance}
        : {start_index, hit_chance};
    assign cache_replacement_way_int = victim_index;
    assign cache_replacement_way = WAYS'(1 << victim_index);

endmodule
