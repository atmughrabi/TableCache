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

module sdp_ram

    #(
        parameter int unsigned ADDR_WIDTH = 10,
        parameter int unsigned NUM_COL = 4, //Number of independently writeable components
        parameter int unsigned COL_WIDTH = 16, //Width the "byte" enable controls
        parameter int unsigned PIPELINE_DEPTH = 1, //Depth of the output pipeline, is latency in clock cycles
        parameter CASCADE_DEPTH = 4 //Maximum depth of the memory block cascade
    )
    (
        input logic clk,
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
    //Simple dual port RAM
    //Synchronous read and write ports
    //Configurable latency

    localparam DATA_WIDTH = COL_WIDTH*NUM_COL;

    ////////////////////////////////////////////////////
    //Implementation


    (* cascade_height = CASCADE_DEPTH, ramstyle = "no_rw_check" *) //Higher depths use less resources but are slower
    logic[DATA_WIDTH-1:0] mem[(1<<ADDR_WIDTH)-1:0];

    //initial mem = '{default: '0};

    //A write
    always_ff @(posedge clk) begin
        for (int i = 0; i < NUM_COL; i++) begin
            if (a_en & a_wbe[i])
                mem[a_addr][i*COL_WIDTH +: COL_WIDTH] <= a_wdata[i*COL_WIDTH +: COL_WIDTH];
        end
    end

    //B read
    logic[DATA_WIDTH-1:0] b_ram_output;
    always_ff @(posedge clk) begin
        if (b_en)
            b_ram_output <= mem[b_addr];
    end

    //B pipeline
    generate if (PIPELINE_DEPTH > 0) begin : gen_b_pipeline
        logic[DATA_WIDTH-1:0] b_data_pipeline[PIPELINE_DEPTH-1:0];
        logic[PIPELINE_DEPTH-1:0] b_en_pipeline;

        always_ff @(posedge clk) begin
            for (int i = 0; i < PIPELINE_DEPTH; i++) begin
                b_en_pipeline[i] <= i == 0 ? b_en : b_en_pipeline[i-1];
                if (b_en_pipeline[i])
                    b_data_pipeline[i] <= i == 0 ? b_ram_output : b_data_pipeline[i-1];
            end
        end
        assign b_rdata = b_data_pipeline[PIPELINE_DEPTH-1];
    end
    else begin : gen_b_transparent_output
        assign b_rdata = b_ram_output;
    end endgenerate

endmodule
