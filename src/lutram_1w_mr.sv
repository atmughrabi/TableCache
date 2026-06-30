/*
 * Copyright © 2021 Eric Matthews
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
 */

module lutram_1w_mr

    import cache_config::*;

    #(
        parameter int unsigned WIDTH = 1,
        parameter int unsigned DEPTH = 32,
        parameter int unsigned NUM_READ_PORTS = 2
    )
    (
        input logic clk,

        input logic[$clog2(DEPTH)-1:0] waddr,
        input logic[$clog2(DEPTH)-1:0] raddr[NUM_READ_PORTS],

        input logic ram_write,
        input logic[WIDTH-1:0] new_ram_data,
        output logic[WIDTH-1:0] ram_data_out[NUM_READ_PORTS]
    );

    ////////////////////////////////////////////////////
    //LUTRAM
    //Synchronous write port and parameterizable numbers of asynchronous read ports
    //Efficiently implemented using lookup tables
    //AMD can infer the structure directly, but Intel must use duplicated single-port memories

    genvar i;

    generate if (FPGA_VENDOR == AMD) begin : gen_amd
        // Declaration initializer (RAM INIT=0). A separate `initial` block
        // conflicts with the always_ff write port under strict 4-state
        // elaboration (xsim); the declaration initializer is the strict-clean
        // equivalent and synthesizes identically.
        logic[WIDTH-1:0] ram[DEPTH-1:0] = '{default: 0};

        always_ff @ (posedge clk) begin
            if (ram_write)
                ram[waddr] <= new_ram_data;
        end

        always_comb begin
            for (int j = 0; j < NUM_READ_PORTS; j++)
                ram_data_out[j] = ram[raddr[j]];
        end
    end
    else if (FPGA_VENDOR == INTEL) begin : gen_intel
        for (i = 0; i < NUM_READ_PORTS; i++) begin : lutrams
            lutram_1w_1r #(.WIDTH(WIDTH), .DEPTH(DEPTH))
            write_port (
                .clk(clk),
                .waddr(waddr),
                .raddr(raddr[i]),
                .ram_write(ram_write),
                .new_ram_data(new_ram_data),
                .ram_data_out(ram_data_out[i])
            );
        end
    end endgenerate

endmodule
