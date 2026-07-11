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

module l2_hash

    #(
        parameter int unsigned IN_WIDTH = 16,
        parameter int unsigned OUT_WIDTH = 4
    )
    (
        input logic[IN_WIDTH-1:0] addr,
        output logic[OUT_WIDTH-1:0] hash
    );

    ////////////////////////////////////////////////////
    //Address hash
    //Hashes the address to the specified output width
    //Specific hash function depends on widths

    generate if (IN_WIDTH <= OUT_WIDTH) begin : gen_identity_hash
        always_comb begin
            hash = '0;
            hash[IN_WIDTH-1:0] = addr;
        end
    end
    else if (IN_WIDTH <= 6) begin : gen_add_hash
        //Narrow enough to fit in one 6-LUT
        logic[5:0] padded;
        logic[5:0] sum;

        always_comb begin
            padded = '0;
            padded[IN_WIDTH-1:0] = addr;
        end

        assign sum = {padded[4], padded[2], padded[0]} + {padded[5], padded[3], padded[1]} + 3'b1;
        assign hash = sum[OUT_WIDTH-1:0];
    end
    else begin : gen_full_hash
        // XOR-fold all address bits into the fixed-width occupancy index.
        always_comb begin
            hash = '0;
            for (int i = 0; i < IN_WIDTH; i++)
                hash[i % OUT_WIDTH] ^= addr[i];
        end
    end endgenerate

endmodule
