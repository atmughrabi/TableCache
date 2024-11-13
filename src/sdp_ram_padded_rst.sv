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

module sdp_ram_padded_rst

    #(
        parameter int unsigned ADDR_WIDTH = 10,
        parameter int unsigned NUM_COL = 4, //Number of independently writeable components
        parameter int unsigned COL_WIDTH = 16, //Width the "byte" enable controls
        parameter int unsigned PIPELINE_DEPTH = 1, //Depth of the output pipeline, is latency in clock cycles
        parameter int unsigned CASCADE_DEPTH = 4 //Maximum depth of the memory block cascade on AMD FPGAs
    )
    (
        input logic clk,
        input logic rst,    
        input logic[COL_WIDTH*NUM_COL-1:0] rst_value,

        //Port A
        input logic a_en,
        input logic[NUM_COL-1:0] a_wbe,
        input logic[COL_WIDTH*NUM_COL-1:0] a_wdata,
        input logic[ADDR_WIDTH-1:0] a_addr,

        //Port B
        input logic b_en,
        input logic[ADDR_WIDTH-1:0] b_addr,
        output logic[COL_WIDTH*NUM_COL-1:0] b_rdata
    );

    ////////////////////////////////////////////////////
    //Simple dual port RAM with field padding
    //Aligns fields to "byte" (8 or 9 bit) boundaries by inserting padding
    //This can sometimes reduce the number of block memories needed
    //This should work in Quartus but doesn't because their inference capabilities aren't the greatest

    localparam int unsigned PAD_WIDTH8 = (8 - (COL_WIDTH % 8)) % 8;
    localparam int unsigned PAD_WIDTH9 = (9 - (COL_WIDTH % 9)) % 9;
    localparam int unsigned PAD_WIDTH = PAD_WIDTH8 <= PAD_WIDTH9 ? PAD_WIDTH8 : PAD_WIDTH9;
    localparam int unsigned PADDED_WIDTH = COL_WIDTH + PAD_WIDTH;
    localparam int unsigned TOTAL_WIDTH = NUM_COL * PADDED_WIDTH;

    ////////////////////////////////////////////////////
    //Implementation

    generate if (PAD_WIDTH == 0 || NUM_COL == 1) begin : gen_no_padding
        sdp_ram_rst #(
            .ADDR_WIDTH(ADDR_WIDTH),
            .NUM_COL(NUM_COL),
            .COL_WIDTH(COL_WIDTH),
            .PIPELINE_DEPTH(PIPELINE_DEPTH),
            .CASCADE_DEPTH(CASCADE_DEPTH)
        ) mem (.*);
    end else begin : gen_padded
        logic[TOTAL_WIDTH-1:0] rst_padded;
        logic[TOTAL_WIDTH-1:0] a_padded;
        logic[TOTAL_WIDTH-1:0] b_padded;

        always_comb begin
            rst_padded = 'x;
            a_padded = 'x;
            for (int i = 0; i < NUM_COL; i++) begin
                rst_padded[i*PADDED_WIDTH+:COL_WIDTH] = rst_value[i*COL_WIDTH+:COL_WIDTH];
                a_padded[i*PADDED_WIDTH+:COL_WIDTH] = a_wdata[i*COL_WIDTH+:COL_WIDTH];
                b_rdata[i*COL_WIDTH+:COL_WIDTH] = b_padded[i*PADDED_WIDTH+:COL_WIDTH];
            end
        end

        sdp_ram_rst #(
            .ADDR_WIDTH(ADDR_WIDTH),
            .NUM_COL(NUM_COL),
            .COL_WIDTH(PADDED_WIDTH),
            .PIPELINE_DEPTH(PIPELINE_DEPTH),
            .CASCADE_DEPTH(CASCADE_DEPTH)
        ) mem (
            .rst_value(rst_padded),
            .a_wdata(a_padded),
            .b_rdata(b_padded),
        .*);
    end endgenerate

endmodule
