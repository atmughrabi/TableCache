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
    logic[WAY_W-1:0] finish_index;

    always_comb begin
        hit_chance = second_chance;
        hit_chance[cache_way_used_int] = 1;

        finish_index = start_index;
        finish_chance = second_chance;
        //Iterate over second chance array starting at the previous index
        for (int i = 0; i <= WAYS; i++) begin
            finish_chance[finish_index] = 0;
            if (~second_chance[finish_index]) //Return the first entry without a second chance
                break;
            if (finish_index == WAY_W'(WAYS-1)) //For non power of 2
                finish_index = 0;
            else
                finish_index = finish_index+1;
        end
    end

    assign cache_new_status = cache_eviction ? {finish_index, finish_chance} : {start_index, hit_chance};
    assign cache_replacement_way_int = finish_index;
    assign cache_replacement_way = 1 << finish_index;

endmodule
