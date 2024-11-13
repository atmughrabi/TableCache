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

module FRQ

    #(
        parameter int unsigned POLICY_W = 2,
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
    //Least frequently used cache replacement policy
    //A more accurate name would be "not most recently used"

    localparam int unsigned WAY_W = $clog2(WAYS);

    ////////////////////////////////////////////////////
    //Implementation
    logic increment;
    assign increment = cache_eviction | cache_original_status == cache_way_used_int; 

    assign cache_new_status = (cache_original_status == WAY_W'(WAYS-1) & increment) ? '0 : cache_original_status + increment;
    assign cache_replacement_way_int = cache_original_status;
    assign cache_replacement_way = 1 << cache_original_status;

endmodule
