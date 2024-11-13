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

 module random_replacement

    #(
        parameter logic USE_EVICT = 1,
        parameter int unsigned WAYS = 4
    )
    (
        input logic clk,
        input logic rst,

        input logic cache_valid,
        input logic cache_eviction,
        output logic[WAYS-1:0] cache_replacement_way,
        output logic[$clog2(WAYS)-1:0] cache_replacement_way_int
    );

    ////////////////////////////////////////////////////
    //Random cache replacement policy
    //Target way either updates every cycle, or on every eviction (for determinism)

    always_ff @(posedge clk) begin
        if (rst)
            cache_replacement_way <= 1;
        else if (USE_EVICT ? cache_valid & cache_eviction : 1'b1)
            cache_replacement_way <= {cache_replacement_way[WAYS-2:0], cache_replacement_way[WAYS-1]}; 
    end 

    one_hot_to_integer #(.WIDTH(WAYS)) way_conv (
        .one_hot(cache_replacement_way),
        .int_out(cache_replacement_way_int),
    .*);

endmodule
