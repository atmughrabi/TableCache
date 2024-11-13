/*
 * Copyright © 2017 Eric Matthews
 *
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

module one_hot_to_integer

    #(
        parameter int unsigned WIDTH = 40
    )
    (
        input logic[WIDTH-1:0] one_hot,
        output logic[(WIDTH == 1) ? 0 : ($clog2(WIDTH)-1) : 0] int_out
    );

    ////////////////////////////////////////////////////
    //One hot to integer
    //Must be one-hot because all possible conditions are ORed together
  
    generate if (WIDTH == 1) begin : gen_width_one
        assign int_out = 0;
    end
    else begin : gen_width_two_plus
        always_comb begin
            int_out = 0;
            for (int i = 0; i < WIDTH; i++)
                int_out |= one_hot[i] ? $clog2(WIDTH)'(i) : 0;
        end
    end endgenerate

    //No assertions here because we cannot know when the inputs are valid; this is checked in the replacement policy

endmodule
