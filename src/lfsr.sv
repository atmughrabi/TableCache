/*
 * Copyright © 2021 Eric Matthews

 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Initial code developed under the supervision of Dr. Lesley Shannon,
 * Reconfigurable Computing Lab, Simon Fraser University.
 *
 * Author(s):
 *             Eric Matthews <ematthew@sfu.ca>
 *             Chris Keilbart <ckeilbar@sfu.ca>
 */

module lfsr

    #(
        parameter int unsigned WIDTH = 3
    )
    (
        input logic clk,
        input logic rst,
        input logic en,
        // FPGA INIT value; keeps reset walkers defined in four-state simulation.
        output logic[WIDTH-1:0] value = '0
    );

    ////////////////////////////////////////////////////
    //Linear feedback shift register
    //Inexpensively iterates over all possible bit patterns
    //Supports 1-16 bits

    //XNOR taps for lfsr from 3-16 bits wide (source: Xilinx xapp052)
    //Dummy entries for widths 0-2
    localparam int unsigned NUMS[17] = '{1, 1, 1, 2, 2, 2, 2, 2, 4, 2, 2, 2, 4, 4, 4, 2, 4};
    localparam logic[3:0][31:0] INDICIES[17] = '{
        '{0,0,0,0},
        '{0,0,0,0},
        '{0,0,0,0},
        '{0,0,1,2}, //3
        '{0,0,2,3}, //4
        '{0,0,2,4},
        '{0,0,4,5},
        '{0,0,5,6},
        '{3,4,5,7}, //8
        '{0,0,4,8},
        '{0,0,6,9},
        '{0,0,8,10},
        '{0,3,5,11}, //12
        '{0,2,3,12},
        '{0,2,4,13},
        '{0,0,13,14}, //15
        '{3,12,14,15} //16
    };

    localparam int unsigned NUM = NUMS[WIDTH];
    localparam logic[3:0][31:0] INDEX = INDICIES[WIDTH];

    logic[NUM-1:0] feedback_input;
    logic feedback;
    genvar i;

    ////////////////////////////////////////////////////
    //Implementation

    generate if (WIDTH <= 2) begin : gen_width_one_or_two
        assign feedback = ~value[WIDTH-1];
    end
    else begin : gen_width_three_plus
        for (i = 0; i < NUM; i++) begin : gen_taps
            assign feedback_input[i] = value[int'(INDEX[i])];
        end
        //XNOR of taps and range extension to include all ones
        assign feedback = (~^feedback_input) ^ |value[WIDTH-2:0];
    end endgenerate

    always_ff @ (posedge clk) begin
        if (rst)
            value <= '0;
        else if (en) begin
            value <= value << 1;
            value[0] <= feedback;
        end
    end

`ifndef ASSERT_OFF
    initial assert(WIDTH <= 16) else $fatal(1, "LFSR width too large");
`endif

endmodule
