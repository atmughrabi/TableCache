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

 module rrip_tree
    #(
        parameter int unsigned BLOCK_WIDTH = 2,
        parameter int unsigned NUM_BLOCKS = 8
    )
    (
        input logic[BLOCK_WIDTH-1:0] blocks[NUM_BLOCKS-1:0],
        output int lowest_index,
        output logic[BLOCK_WIDTH-1:0] smallest_value
    );

    ////////////////////////////////////////////////////
    //Re-reference interval prediction metadata tree
    //Each way gets incremented until one of the ways is '1; that is the way that gets evicted
    //The amount to increment is then min('1 - way), or equivalently min(~way)

    localparam int unsigned DEPTH = $clog2(NUM_BLOCKS);
    localparam int unsigned PADDED_WIDTH = 2**DEPTH;

    ////////////////////////////////////////////////////
    //Implementation

    //Pad to power of two; makes the loop easier
    logic[PADDED_WIDTH-1:0][BLOCK_WIDTH-1:0] padded_tree[DEPTH:0];
    logic[PADDED_WIDTH-1:0][DEPTH-1:0] padded_int[DEPTH:0];
    always_comb begin
        padded_tree[DEPTH] = '{default : '1}; //Highest possible value; will not be selected because ties choose the right
        for (int i = 0; i < NUM_BLOCKS; i++) 
            padded_tree[DEPTH][i] = ~blocks[i];
        for (int i = 0; i < PADDED_WIDTH; i++)
            padded_int[DEPTH][i] = DEPTH'(i);
    end

    always_comb begin
        for (int i = DEPTH-1; i >= 0; i--) begin
            for (int j = 0; j < 2**i; j++) begin
                if (padded_tree[i+1][2*j+1] < padded_tree[i+1][2*j]) begin
                    padded_tree[i][j] = padded_tree[i+1][2*j+1];
                    padded_int[i][j] = padded_int[i+1][2*j+1];
                end
                else begin
                    padded_tree[i][j] = padded_tree[i+1][2*j];
                    padded_int[i][j] = padded_int[i+1][2*j];
                end
            end
        end
    end

    assign smallest_value = padded_tree[0][0];
    assign lowest_index = padded_int[0][0];

endmodule
