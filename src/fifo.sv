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

module fifo

    #(
        parameter int unsigned WIDTH = 1,
        parameter int unsigned FIFO_DEPTH = 4
    )
    (
        input logic clk,
        input logic rst,

        input logic fifo_push,
        input logic fifo_pop,
        input logic[WIDTH-1:0] fifo_data_in,
        output logic[WIDTH-1:0] fifo_data_out,
        output logic fifo_valid,
        output logic fifo_full
    );

    ////////////////////////////////////////////////////
    //FIFO
    //Intended for small depths
    //Not underflow/overflow safe
    //For continuous operation when full, enqueing side must inspect pop signal

    localparam int unsigned LOG2_FIFO_DEPTH = $clog2(FIFO_DEPTH);

    ////////////////////////////////////////////////////
    //Implementation

    //If depth is one, the FIFO can be implemented with a single register
    generate if (FIFO_DEPTH == 1) begin : gen_width_one
        always_ff @ (posedge clk) begin
            if (rst)
                fifo_valid <= 0;
            else
                fifo_valid <= fifo_push | (fifo_valid & ~fifo_pop);
        end
        assign fifo_full = fifo_valid;

        always_ff @ (posedge clk) begin
            if (fifo_push)
                fifo_data_out <= fifo_data_in;
        end
    end
    //If depth is two, the FIFO can be implemented with two registers as a shift register
    //for the same resources as a LUTRAM FIFO but with better timing
    else if (FIFO_DEPTH == 2) begin : gen_width_two
        logic[WIDTH-1:0] shift_reg[FIFO_DEPTH];
        logic[LOG2_FIFO_DEPTH:0] inflight_count;

        always_ff @ (posedge clk) begin
            if (rst)
                inflight_count <= 0;
            else
                inflight_count <= inflight_count + (LOG2_FIFO_DEPTH+1)'(fifo_pop) - (LOG2_FIFO_DEPTH+1)'(fifo_push);
        end

        assign fifo_valid = inflight_count[LOG2_FIFO_DEPTH];
        assign fifo_full = fifo_valid & ~|inflight_count[LOG2_FIFO_DEPTH-1:0];

        always_ff @ (posedge clk) begin
            if (fifo_push) begin
                shift_reg[0] <= fifo_data_in;
                shift_reg[1] <= shift_reg[0];
            end
        end

        assign fifo_data_out = shift_reg[~inflight_count[0]];
    end
    else begin : gen_width_3_plus
        logic[LOG2_FIFO_DEPTH-1:0] write_index;
        logic[LOG2_FIFO_DEPTH-1:0] read_index;
        logic[LOG2_FIFO_DEPTH:0] inflight_count;

        always_ff @ (posedge clk) begin
            if (rst)
                inflight_count <= 0;
            else
                inflight_count <= inflight_count + (LOG2_FIFO_DEPTH+1)'(fifo_pop) - (LOG2_FIFO_DEPTH+1)'(fifo_push);
        end

        assign fifo_valid = inflight_count[LOG2_FIFO_DEPTH];
        assign fifo_full = inflight_count == (LOG2_FIFO_DEPTH+1)'(-FIFO_DEPTH);

        lfsr #(.WIDTH(LOG2_FIFO_DEPTH))
        lfsr_read_index (
            .en(fifo_pop),
            .value(read_index),
        .*);
        lfsr #(.WIDTH(LOG2_FIFO_DEPTH))
        lfsr_write_index (
            .en(fifo_push),
            .value(write_index),
        .*);

        //Force FIFO depth to next power of 2
        lutram_1w_1r #(.WIDTH(WIDTH), .DEPTH(2**LOG2_FIFO_DEPTH))
        write_port (
            .waddr(write_index),
            .raddr(read_index),
            .ram_write(fifo_push),
            .new_ram_data(fifo_data_in),
            .ram_data_out(fifo_data_out),
        .*);
    end endgenerate


`ifndef ASSERT_OFF
    fifo_overflow_assertion:
        assert property (@(posedge clk) disable iff (rst) fifo_push |-> (~fifo_full | fifo_pop)) else $error("FIFO overflow");
    fifo_underflow_assertion:
        assert property (@(posedge clk) disable iff (rst) fifo_pop |-> fifo_valid) else $error("FIFO underflow");
`endif

endmodule
