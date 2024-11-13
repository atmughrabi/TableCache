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

module sdp_ram_rst

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
    //Simple dual port RAM with synchronous reset routine
    //Holding reset high for $clog2(ADDR_WIDTH) cycles will set all entries to rst_value

    logic[ADDR_WIDTH-1:0] rst_addr;
    lfsr #(.WIDTH(ADDR_WIDTH)) reset_lfsr (
        .rst(~rst),
        .en(1'b1),
        .value(rst_addr),
    .*);

    sdp_ram #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_COL(NUM_COL),
        .COL_WIDTH(COL_WIDTH),
        .PIPELINE_DEPTH(PIPELINE_DEPTH),
        .CASCADE_DEPTH(CASCADE_DEPTH)
    ) ram (
        .a_en(rst | a_en),
        .a_wbe({NUM_COL{rst}} | a_wbe),
        .a_wdata(rst ? rst_value : a_wdata),
        .a_addr(rst ? rst_addr : a_addr),
    .*);

endmodule
