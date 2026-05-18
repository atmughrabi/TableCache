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

module l2_databank

    #(
        parameter WAYS = 4,
        parameter DATA_W = 128,
        parameter ID_W = 3,
        parameter LINE_ADDR_W = 8,
        parameter BLOCK_ADDR_W = 3,
        parameter LATENCY = 1,
        parameter SAVED_LEN = 24 //The length of the data passed in the lookup that will be preserved to the output
    )
    (
        input logic clk,
        input logic rst,

        //Request port
        input logic request_valid,
        input logic request_rnw,
        input logic request_evict,
        input logic[LINE_ADDR_W-1:0] request_line,
        input logic[BLOCK_ADDR_W-1:0] request_block,
        input logic[ID_W-1:0] request_id,
        input logic[BLOCK_ADDR_W-1:0] request_len,
        input logic[$clog2(WAYS)-1:0] request_way,
        input logic request_fill,
        
        output logic ready,

        //Input data port
        input logic write_valid,
        input logic[DATA_W-1:0] write_data,
        input logic[DATA_W/8-1:0] write_wbe,
        output logic write_data_ready,
        input logic fill_valid,
        input logic[DATA_W-1:0] fill_data,
        input logic[DATA_W/8-1:0] fill_wbe,
        output logic fill_data_ready,

        //Lookup ports when data is ready at entrance to output FIFOs
        output logic[ID_W-1:0] lookup_id[2],
        input logic[$clog2(WAYS)-1:0] lookup_way[2],
        input logic lookup_discard[2],
        input logic lookup_evict[2],
        input logic[SAVED_LEN-1:0] lookup_saved[2],

        //Output ports
        input logic out_ready[2],
        output logic out_valid[2],
        output logic out_last[2],
        output logic[ID_W-1:0] out_id[2],
        output logic out_evict[2],
        output logic[SAVED_LEN-1:0] out_saved[2],
        output logic[DATA_W-1:0] out_data[2]
    );

    ////////////////////////////////////////////////////
    //L2 databank
    //Dual ported; satisfies write fills, write hits, read hits, and read evictions
    //Looks up the target way externally

    //These parameters can be customized
    localparam int unsigned OUTPUT_FIFO_DEPTH = 32; //How many words to buffer per port
    localparam int unsigned CASCADE_DEPTH = 8; //Length of the memory cascade on AMD FPGAs
    
    localparam int unsigned WBE_W = DATA_W/8;
    typedef logic[LINE_ADDR_W-1:0] line_t;
    typedef logic[BLOCK_ADDR_W-1:0] block_t;
    typedef logic[DATA_W-1:0] block_data_t;
    typedef logic[ID_W-1:0] cache_id_t;

    typedef struct packed {
        line_t line;
        cache_id_t id;
        logic evict;
        logic fill;
        logic[$clog2(WAYS)-1:0] way;
        block_t last_block;
        block_t original_last_block;
    } saved_t;
    genvar i;

    typedef struct packed {
        logic last;
        logic original_last;
        cache_id_t id;
    } read_pipeline_t;

    ////////////////////////////////////////////////////
    //Implementation

    ////////////////////////////////////////////////////
    //Port state machines
    typedef enum {
        READY,
        READING,
        WRITING
    } state_t;
    state_t current_state[2];
    state_t next_state[2];

    //Pipeline signals
    logic out_full[2];
    saved_t saved_request[2];
    logic in_last[2];
    logic in_original_last[2];
    cache_id_t in_id[2];
    block_t saved_block[2];

    //External signals
    logic port_ready[2];
    logic port_write_data_ready[2];
    logic port_fill_data_ready[2];

    //DB signals
    logic out_fifo_push[2];
    logic[LATENCY:0] valid_pipeline[2];
    read_pipeline_t[LATENCY:0] info_pipeline[2];
    logic write_fifo_push;
    logic write_fifo_data_in;
    logic write_fifo_pop;
    logic write_fifo_data_out;
    logic en[2];
    logic[WAYS-1:0][WBE_W-1:0] wbe[2];
    block_data_t wdata[2];
    line_t line[2];
    block_t block[2];
    logic other_port_writing[2];
    block_t full_len;
    assign full_len = '1;

    ////////////////////////////////////////////////////
    //Accepting requests
    //Two state machines manage requests to the databank ports
    //Handles reads, line writes, evicts (line read followed by line write), and misses (line write)
    assign ready = port_ready[0] | port_ready[1];
    assign write_data_ready = port_write_data_ready[0] | port_write_data_ready[1];
    assign fill_data_ready = port_fill_data_ready[0] | port_fill_data_ready[1];

    //It is not possible for there to be simultaneous fill requests
    //The same is not true for writes or evictions, so use a FIFO to track which port is the most recent
    assign write_fifo_push = request_valid & ~request_fill & (request_rnw ? request_evict : ~(write_valid & write_data_ready & ~|request_len & ~other_port_writing[0] & ~other_port_writing[1])) & ready;
    assign write_fifo_data_in = current_state[0] != READY;
    assign write_fifo_pop = (current_state[0] == WRITING & next_state[0] == READY & ~saved_request[0].fill) | (current_state[1] == WRITING & next_state[1] == READY & ~saved_request[1].fill); //Pop is single write
    fifo #(.WIDTH(1), .FIFO_DEPTH(2)) write_fifo_inst (
        .fifo_push(write_fifo_push),
        .fifo_pop(write_fifo_pop),
        .fifo_data_in(write_fifo_data_in),
        .fifo_data_out(write_fifo_data_out),
        .fifo_valid(),
        .fifo_full(),
    .*);

    generate for (i = 0; i < 2; i++) begin : gen_states
        always_ff @(posedge clk) begin
            if (rst)
                current_state[i] <= READY;
            else
                current_state[i] <= next_state[i];
            
            if (current_state[i] == READY) begin
                saved_request[i].line <= request_line;
                saved_request[i].id <= request_id;
                saved_request[i].evict <= request_evict;
                saved_request[i].fill <= request_fill;
                saved_request[i].way <= request_way;
                saved_request[i].last_block <= request_block + full_len;
                saved_request[i].original_last_block <= request_block + request_len;
                saved_block[i] <= request_block + block_t'(en[i]);
            end
            else
                saved_block[i] <= saved_block[i] + block_t'(en[i]);
        end

        always_comb begin
            wbe[i] = '0;
            //Cannot write with the write data simultaneously
            other_port_writing[i] = (current_state[~i[0]] == WRITING & ~saved_request[~i[0]].fill) | (current_state[~i[0]] == READING & saved_request[~i[0]].evict);

            if (current_state[i] == READY) begin
                port_ready[i] = 1;
                in_original_last[i] = ~|request_len;
                in_last[i] = 0;
                line[i] = request_line;
                block[i] = request_block;
                in_id[i] = request_id;
            end
            else begin
                port_ready[i] = 0;
                in_original_last[i] = saved_block[i] == saved_request[i].original_last_block;
                in_last[i] = saved_block[i] == saved_request[i].last_block;
                line[i] = saved_request[i].line;
                block[i] = saved_block[i];
                in_id[i] = saved_request[i].id;
            end

            unique case (current_state[i])
                READY : begin //Priority goes to port 0
                    en[i] = (i == 0 | ~port_ready[0]) & request_valid & (request_rnw ? ~out_full[i] : ~(~request_fill & other_port_writing[i]) & (request_fill ? fill_valid : write_valid));
                    port_write_data_ready[i] = ~request_rnw & ~request_fill & request_valid & ~other_port_writing[i];
                    port_fill_data_ready[i] = ~request_rnw & request_fill;
                    wbe[i][request_way] = request_rnw ? '0 : (request_fill ? fill_wbe : write_wbe);
                    wdata[i] = request_fill ? fill_data : write_data;
                    if ((i == 0 | ~port_ready[0]) & request_valid & request_rnw)
                        next_state[i] = READING;
                    else if ((i == 0 | ~port_ready[0]) & request_valid & ~request_rnw & ~(~other_port_writing[i] & ~request_fill & write_valid & ~|request_len))
                        next_state[i] = WRITING;
                    else
                        next_state[i] = READY;
                end
                READING : begin
                    en[i] = ~out_full[i];
                    port_write_data_ready[i] = 0;
                    port_fill_data_ready[i] = 0;
                    wbe[i] = '0;
                    wdata[i] = 'x;
                    if (valid_pipeline[i][LATENCY] & ~out_fifo_push[i] & info_pipeline[i][LATENCY].id == saved_request[i].id)
                        next_state[i] = READY; //Read data was discarded; premature exit
                    else if (in_last[i] & en[i])
                        next_state[i] = saved_request[i].evict ? WRITING : READY;
                    else
                        next_state[i] = READING;
                end
                WRITING : begin
                    en[i] = saved_request[i].fill ? fill_valid : write_valid & write_fifo_data_out == i[0];
                    port_write_data_ready[i] = ~saved_request[i].fill & write_fifo_data_out == i[0];
                    port_fill_data_ready[i] = saved_request[i].fill;
                    wbe[i][saved_request[i].way] = saved_request[i].fill ? fill_wbe : write_wbe;
                    wdata[i] = saved_request[i].fill ? fill_data : write_data;
                    next_state[i] = in_original_last[i] & en[i] ? READY : WRITING;
                end
            endcase
        end
    end endgenerate


    ////////////////////////////////////////////////////
    //Databank
    //Implemented as individual banks of true dual port RAMs
    //Parameterizable pipeline depth that can be stalled
    logic[WAYS*WBE_W-1:0] unpacked_wbe[2];
    logic[WAYS*DATA_W-1:0] unpacked_rdata[2];
    block_data_t[WAYS-1:0] rdata[2];

    always_comb begin
        for (int j = 0; j < 2; j++) begin
            for (int k = 0; k < WAYS; k++) begin
                unpacked_wbe[j][WBE_W*k+:WBE_W] = wbe[j][k];
                rdata[j][k] = unpacked_rdata[j][DATA_W*k+:DATA_W];
            end
        end
    end

    tdp_ram #(
        .ADDR_WIDTH($bits(line_t)+$bits(block_t)),
        .NUM_COL(WAYS*WBE_W),
        .COL_WIDTH(8),
        .PIPELINE_DEPTH(LATENCY),
        .CASCADE_DEPTH(CASCADE_DEPTH)
    ) databank (
        .a_en(en[0]),
        .a_wbe(unpacked_wbe[0]),
        .a_wdata({WAYS{wdata[0]}}),
        .a_addr({line[0], block[0]}),
        .a_rdata(unpacked_rdata[0]),
        .b_en(en[1]),
        .b_wbe(unpacked_wbe[1]),
        .b_wdata({WAYS{wdata[1]}}),
        .b_addr({line[1], block[1]}),
        .b_rdata(unpacked_rdata[1]),
    .*);

    ////////////////////////////////////////////////////
    //Databank read info pipeline
    //Fixed length pipeline holding information about the current output data
    generate for (i = 0; i < 2; i++) begin : gen_pipeline
        always_ff @(posedge clk) begin
            if (rst)
                valid_pipeline[i] <= '0;
            else begin
                valid_pipeline[i][0] <= en[i] & (current_state[i] == READING | (current_state[i] == READY & request_rnw));
                for (int j = 1; j <= LATENCY; j++)
                    valid_pipeline[i][j] <= valid_pipeline[i][j-1];
            end

            //Does not need reset
            info_pipeline[i][0].last <= in_last[i];
            info_pipeline[i][0].original_last <= in_original_last[i];
            info_pipeline[i][0].id <= in_id[i];
            for (int j = 1; j <= LATENCY; j++)
                info_pipeline[i][j] <= info_pipeline[i][j-1];
        end
    end endgenerate


    ////////////////////////////////////////////////////
    //Output data FIFOs
    //Parameterizable pipeline depth that can be stalled
    typedef logic[$clog2(OUTPUT_FIFO_DEPTH):0] fifo_count_t;
    fifo_count_t out_counter[2];
    typedef struct packed {
        logic last;
        block_data_t data;
        cache_id_t id;
        logic evict;
        logic[SAVED_LEN-1:0] saved;
    } out_data_t;
    logic out_fifo_pop[2];
    out_data_t out_fifo_data_in[2];
    out_data_t out_fifo_data_out[2];
    logic out_fifo_valid[2];

    logic past_original_last[2];

    generate for (i = 0; i < 2; i++) begin : gen_output_fifos
        assign out_fifo_push[i] = valid_pipeline[i][LATENCY] & ~lookup_discard[i] & ~(~lookup_evict[i] & past_original_last[i]);
        assign out_fifo_pop[i] = out_ready[i] & out_fifo_valid[i];
        assign out_fifo_data_in[i] = '{
            last : lookup_evict[i] ? info_pipeline[i][LATENCY].last : info_pipeline[i][LATENCY].original_last,
            data : rdata[i][lookup_way[i]],
            id : info_pipeline[i][LATENCY].id,
            evict : lookup_evict[i],
            saved : lookup_saved[i]
        };
        assign lookup_id[i] = info_pipeline[i][LATENCY].id; //Used to determine which way the correct data is in
        assign out_valid[i] = out_fifo_valid[i];
        assign out_last[i] = out_fifo_data_out[i].last;
        assign out_id[i] = out_fifo_data_out[i].id;
        assign out_evict[i] = out_fifo_data_out[i].evict;
        assign out_saved[i] = out_fifo_data_out[i].saved;
        assign out_data[i] = out_fifo_data_out[i].data;
        fifo #(.WIDTH($bits(out_data_t)), .FIFO_DEPTH(OUTPUT_FIFO_DEPTH)) out_fifo_inst (
            .fifo_push(out_fifo_push[i]),
            .fifo_pop(out_fifo_pop[i]),
            .fifo_data_in(out_fifo_data_in[i]),
            .fifo_data_out(out_fifo_data_out[i]),
            .fifo_valid(out_fifo_valid[i]),
            .fifo_full(),
        .*);

        //This logic duplicates the logic inside the FIFO exactly and will be optimized into a single instance
        always_ff @(posedge clk) begin
            if (rst)
                out_counter[i] <= '0;
            else
                out_counter[i] <= out_counter[i] + fifo_count_t'(out_fifo_pop[i]) - fifo_count_t'(out_fifo_push[i]);
        end
        assign out_full[i] = out_counter[i] <= fifo_count_t'(-(OUTPUT_FIFO_DEPTH-LATENCY-1)) & |out_counter[i];

        always_ff @(posedge clk) begin
            if (rst)
                past_original_last[i] <= 0;
            else if (current_state[i] == READY & next_state[i] == READING)
                past_original_last[i] <= 0; //New READING request: reset stale flag from prior premature-exit
            else if (valid_pipeline[i][LATENCY] & info_pipeline[i][LATENCY].last)
                past_original_last[i] <= 0;
            else if (valid_pipeline[i][LATENCY] & info_pipeline[i][LATENCY].original_last)
                past_original_last[i] <= 1;
        end
    end endgenerate


`ifndef ASSERT_OFF
    initial assert(LATENCY >= 1) else $fatal("Latency must be at least one cycle");
    initial assert(OUTPUT_FIFO_DEPTH >= 2**BLOCK_ADDR_W) else $fatal("Output FIFOs must be able to store a full line");
`endif

endmodule
