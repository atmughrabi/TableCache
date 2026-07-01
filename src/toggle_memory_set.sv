/*
 * Copyright © 2020 Eric Matthews
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

module toggle_memory_set

    #(
        parameter DEPTH = 64,
        parameter NUM_WRITE_PORTS = 3,
        parameter NUM_READ_PORTS = 2
    )
    (
        input logic clk,
        input logic init_clear,

        input logic toggle[NUM_WRITE_PORTS],
        input logic[$clog2(DEPTH)-1:0] toggle_addr[NUM_WRITE_PORTS],

        input logic[$clog2(DEPTH)-1:0] read_addr[NUM_READ_PORTS],
        output logic in_use[NUM_READ_PORTS]
    );

    ////////////////////////////////////////////////////
    //Toggle memory set
    //Multiple synchronous write ports that flip the bit
    //Multiple asynchronous reset ports
    //Includes a reset routine

    localparam int unsigned WIDTH = $clog2(DEPTH);
    genvar k;

    ////////////////////////////////////////////////////
    //Implementation
    logic[WIDTH-1:0] _toggle_addr[NUM_WRITE_PORTS+1];
    logic _toggle[NUM_WRITE_PORTS+1];
    logic _wen[NUM_WRITE_PORTS+1];
    logic[WIDTH-1:0] _read_addr[NUM_READ_PORTS+1];
    logic read_data[NUM_WRITE_PORTS+1][NUM_READ_PORTS+1];
    logic _in_use[NUM_READ_PORTS+1];
    logic[WIDTH-1:0] clear_index;

    //Counter for indexing through memories for post-reset clearing/initialization
    lfsr #(.WIDTH(WIDTH)) lfsr_counter (
        .rst(~init_clear),
        .en(1'b1),
        .value(clear_index),
    .*);

    //Muxing of read and write ports to support post-reset clearing/initialization
    always_comb begin
        _toggle_addr[0:NUM_WRITE_PORTS-1] = toggle_addr;
        _toggle[0:NUM_WRITE_PORTS-1] = toggle;
        _read_addr[0:NUM_READ_PORTS-1] = read_addr;

        // Reset (init_clear) 4-state robustness: gate the EXTERNAL toggle
        // ports' WRITE ENABLE off during the clear walk. Their toggle_id is a
        // cache-supplied address (e.g. finish_id / set_addr) that can be X
        // during reset; because toggle_memory writes every cycle, an X address
        // otherwise corrupts the lutram -- defeating its power-on 0 init in
        // 4-state sim -- and that X feeds back into the clear-walk's in_use.
        // With the external writes gated, the external banks keep their 0 init,
        // in_use stays defined, and the clear-walk (below) still clears any
        // genuinely-set entries (warm reset) since it now reads a defined
        // in_use. (Masking the toggle value alone -- the prior approach -- was
        // insufficient: the write to the X address still happened.)
        for (int unsigned k = 0; k < NUM_WRITE_PORTS; k++)
            _wen[k] = ~init_clear;

        _toggle_addr[NUM_WRITE_PORTS] = clear_index;
        _toggle[NUM_WRITE_PORTS] = init_clear & _in_use[NUM_READ_PORTS];
        _read_addr[NUM_READ_PORTS] = clear_index;
        _wen[NUM_WRITE_PORTS] = 1'b1;   // clear-walk always writes (addr = LFSR)
    end

    //Instantiation of NUM_READ_PORTS*NUM_WRITE_PORTS dual-ported single-bit wide toggle memories
    generate for (k = 0; k < NUM_WRITE_PORTS+1; k++) begin : write_port_gen
        toggle_memory #(.DEPTH(DEPTH), .NUM_READ_PORTS(NUM_READ_PORTS+1)) mem (
            .wen(_wen[k]),
            .toggle(_toggle[k]),
            .toggle_id(_toggle_addr[k]),
            .read_id(_read_addr),
            .read_data(read_data[k]),
        .*);
    end endgenerate

    //In-use determination.  XOR of all write blocks for each read address
    always_comb begin
        _in_use = '{default: 0};
        for (int i = 0;  i < NUM_READ_PORTS+1; i++) begin
            for (int j = 0; j < NUM_WRITE_PORTS+1; j++)
                _in_use[i] ^= read_data[j][i];
        end
        for (int i = 0; i < NUM_READ_PORTS; i++)
            in_use[i] = _in_use[i];
    end

endmodule
