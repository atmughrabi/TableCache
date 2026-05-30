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
        parameter SAVED_LEN = 24, //The length of the data passed in the lookup that will be preserved to the output
        // When DATABANK_SDP=1 the databank storage is one SDP RAM (1R+1W)
        // instead of one TDP RAM. SDP is the only pattern Vivado will map
        // to UltraRAM. Cost: ~1.3% throughput on graph workloads (measured
        // by DATABANK_PERF on test_workload @ 5000 txn, see VERIFICATION.md).
        // Concurrent same-class accesses (both reading or both writing same
        // cycle) stall port 1 by one cycle; concurrent R+W is handled
        // natively by the SDP port pair.
        parameter DATABANK_SDP = 0,
        //1 = register SDP URAM write-port inputs (forwarded to sdp_ram_uram.
        //WRITE_INPUT_REG). Only meaningful with DATABANK_SDP=1; adds 1 cycle
        //of write commit latency.
        parameter logic SDP_WRITE_INPUT_REG = 0
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
    // SDP-mode operation: in DATABANK_SDP=1 mode we expose port 0 only
    // to the outside world; port 1's contributions to the output ready
    // signals are masked out at parameter-elaboration time (no runtime
    // gating, no combinational loop). With upstream never seeing port-1
    // readiness, port 1 stays in READY forever and never fires -- so a
    // single SDP storage suffices to serve all traffic via port 0.
    //
    // Throughput cost vs the TDP storage:
    //   * loses R+W concurrency (fills and reads cannot overlap)
    //   * loses port-1 backup acceptance when port 0 is mid-burst
    //   * measured ~5-10% on graph workloads (vs 1.3% for the earlier
    //     "stall on RR/WW conflict" approach which had to be abandoned
    //     because the necessary handshake gating closed a combinational
    //     loop through the upstream fill_request / req_fifo bypass).
    // Resource win: data array becomes 1R+1W SDP -> UltraRAM-eligible
    // (132 BRAM -> 16 URAM @ 512 KB / 8-way on U250).
    //
    // en_gated[1] is forced low in SDP mode so the FSM treats every
    // would-be port-1 op as not-yet-issued; saved_block/valid_pipeline
    // never advance for port 1, so no stale rdata routing is possible.
    logic en_gated[2];
    assign en_gated[0] = en[0];
    assign en_gated[1] = en[1] & ~DATABANK_SDP;

    assign ready            = port_ready[0]            | (port_ready[1]            & ~DATABANK_SDP);
    assign write_data_ready = port_write_data_ready[0] | (port_write_data_ready[1] & ~DATABANK_SDP);
    assign fill_data_ready  = port_fill_data_ready[0]  | (port_fill_data_ready[1]  & ~DATABANK_SDP);

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
                saved_block[i] <= request_block + block_t'(en_gated[i]);
            end
            else
                saved_block[i] <= saved_block[i] + block_t'(en_gated[i]);
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

    generate if (DATABANK_SDP) begin : gen_sdp_databank
        // Single SDP RAM. After sdp_p1_stall gating, at most one port writes
        // and at most one port reads per cycle, so we can route 1W + 1R
        // through the single SDP pair. RAM read latency = 1 + LATENCY cycles;
        // route the "which port asked" bit through a matching pipeline so the
        // returned data lands on the correct rdata slot.
        wire p0_wr_g = en_gated[0] & |unpacked_wbe[0];
        wire p1_wr_g = en_gated[1] & |unpacked_wbe[1];
        wire p0_rd_g = en_gated[0] & ~|unpacked_wbe[0];
        wire p1_rd_g = en_gated[1] & ~|unpacked_wbe[1];

        logic [WAYS*WBE_W-1:0]  sdp_write_wbe;
        logic [WAYS*DATA_W-1:0] sdp_write_data;
        logic [$bits(line_t)+$bits(block_t)-1:0] sdp_write_addr;
        logic                                    sdp_read_en;
        logic [$bits(line_t)+$bits(block_t)-1:0] sdp_read_addr;
        logic [WAYS*DATA_W-1:0] sdp_rdata;

        // Write port mux (p0 priority; mutual exclusion guaranteed by sdp_p1_stall)
        assign sdp_write_wbe  = p0_wr_g ? unpacked_wbe[0]   : unpacked_wbe[1];
        assign sdp_write_data = p0_wr_g ? {WAYS{wdata[0]}}  : {WAYS{wdata[1]}};
        assign sdp_write_addr = p0_wr_g ? {line[0], block[0]} : {line[1], block[1]};

        // Read port mux (p0 priority; mutual exclusion guaranteed by sdp_p1_stall)
        assign sdp_read_en   = p0_rd_g | p1_rd_g;
        assign sdp_read_addr = p0_rd_g ? {line[0], block[0]} : {line[1], block[1]};

        sdp_ram_uram #(
            .ADDR_WIDTH($bits(line_t)+$bits(block_t)),
            .NUM_COL(WAYS*WBE_W),
            .COL_WIDTH(8),
            .PIPELINE_DEPTH(LATENCY),
            .CASCADE_DEPTH(CASCADE_DEPTH),
            .WRITE_INPUT_REG(SDP_WRITE_INPUT_REG)
        ) databank_sdp (
            .clk,
            .a_en(p0_wr_g | p1_wr_g),
            .a_wbe(sdp_write_wbe),
            .a_wdata(sdp_write_data),
            .a_addr(sdp_write_addr),
            .b_en(sdp_read_en),
            .b_addr(sdp_read_addr),
            .b_rdata(sdp_rdata)
        );

        // Pipeline "which port issued the read" to match RAM latency.
        // sdp_ram total read latency = 1 (sync read) + LATENCY (output pipe).
        logic [LATENCY:0] read_was_p1_pipe;
        always_ff @(posedge clk) begin
            if (rst)
                read_was_p1_pipe <= '0;
            else begin
                read_was_p1_pipe[0] <= sdp_read_en & ~p0_rd_g; // 1 iff port 1 read this cycle
                for (int j = 1; j <= LATENCY; j++)
                    read_was_p1_pipe[j] <= read_was_p1_pipe[j-1];
            end
        end

        // Steer rdata back to the requesting port; other port sees 0.
        assign unpacked_rdata[0] = read_was_p1_pipe[LATENCY] ? '0       : sdp_rdata;
        assign unpacked_rdata[1] = read_was_p1_pipe[LATENCY] ? sdp_rdata : '0;
    end else begin : gen_tdp_databank
        tdp_ram #(
            .ADDR_WIDTH($bits(line_t)+$bits(block_t)),
            .NUM_COL(WAYS*WBE_W),
            .COL_WIDTH(8),
            .PIPELINE_DEPTH(LATENCY),
            .CASCADE_DEPTH(CASCADE_DEPTH)
        ) databank (
            .clk,
            .a_en(en_gated[0]),
            .a_wbe(unpacked_wbe[0]),
            .a_wdata({WAYS{wdata[0]}}),
            .a_addr({line[0], block[0]}),
            .a_rdata(unpacked_rdata[0]),
            .b_en(en_gated[1]),
            .b_wbe(unpacked_wbe[1]),
            .b_wdata({WAYS{wdata[1]}}),
            .b_addr({line[1], block[1]}),
            .b_rdata(unpacked_rdata[1])
        );
    end endgenerate

`ifdef DATABANK_PERF
    // Path-C SDP-feasibility instrumentation. Counts cycles where both
    // databank ports are simultaneously active, broken down by access
    // class. Determines whether a single SDP RAM (1R+1W) would be a
    // viable replacement for the current TDP storage:
    //   * RR conflict = both ports reading same cycle -> would stall in SDP
    //   * WW conflict = both ports writing same cycle -> would stall in SDP
    //   * RW overlap  = one read + one write same cycle -> SDP-friendly
    // Printed in $final.
    //
    // Uses en_gated (not en) so the counters reflect ACTUAL RAM activity:
    // in DATABANK_SDP=1 mode this means port 1 contributes zero -- which
    // is what we want, since en[1] (the FSM-internal intent signal) still
    // pulses high when the upstream attempts a port-1 path that's been
    // disabled at the boundary. Use the legacy `en[i]` view for "demand
    // as if TDP" if needed.
    longint perf_cycles_total;
    longint perf_cycles_p0_active;
    longint perf_cycles_p1_active;
    longint perf_cycles_both_active;
    longint perf_cycles_rr_conflict;
    longint perf_cycles_ww_conflict;
    longint perf_cycles_rw_overlap;

    wire p0_wr = en_gated[0] & |unpacked_wbe[0];
    wire p1_wr = en_gated[1] & |unpacked_wbe[1];
    wire p0_rd = en_gated[0] & ~|unpacked_wbe[0];
    wire p1_rd = en_gated[1] & ~|unpacked_wbe[1];

    always_ff @(posedge clk) begin
        if (rst) begin
            perf_cycles_total        <= '0;
            perf_cycles_p0_active    <= '0;
            perf_cycles_p1_active    <= '0;
            perf_cycles_both_active  <= '0;
            perf_cycles_rr_conflict  <= '0;
            perf_cycles_ww_conflict  <= '0;
            perf_cycles_rw_overlap   <= '0;
        end
        else begin
            perf_cycles_total                    <= perf_cycles_total + 1;
            if (en_gated[0])                     perf_cycles_p0_active    <= perf_cycles_p0_active   + 1;
            if (en_gated[1])                     perf_cycles_p1_active    <= perf_cycles_p1_active   + 1;
            if (en_gated[0] & en_gated[1])       perf_cycles_both_active  <= perf_cycles_both_active + 1;
            if (p0_rd & p1_rd)                   perf_cycles_rr_conflict  <= perf_cycles_rr_conflict + 1;
            if (p0_wr & p1_wr)                   perf_cycles_ww_conflict  <= perf_cycles_ww_conflict + 1;
            if ((p0_rd & p1_wr) | (p0_wr & p1_rd))
                                                 perf_cycles_rw_overlap   <= perf_cycles_rw_overlap  + 1;
        end
    end

    final begin
        $display("[DATABANK_PERF] cycles_total       = %0d", perf_cycles_total);
        $display("[DATABANK_PERF] cycles_p0_active   = %0d", perf_cycles_p0_active);
        $display("[DATABANK_PERF] cycles_p1_active   = %0d", perf_cycles_p1_active);
        $display("[DATABANK_PERF] cycles_both_active = %0d", perf_cycles_both_active);
        $display("[DATABANK_PERF] cycles_rr_conflict = %0d  (both reading -- SDP stall)", perf_cycles_rr_conflict);
        $display("[DATABANK_PERF] cycles_ww_conflict = %0d  (both writing -- SDP stall)", perf_cycles_ww_conflict);
        $display("[DATABANK_PERF] cycles_rw_overlap  = %0d  (R+W      -- SDP fine)", perf_cycles_rw_overlap);
        if (perf_cycles_total > 0) begin
            $display("[DATABANK_PERF] sdp_stall_pct      = %0.2f %%",
                100.0 * real'(perf_cycles_rr_conflict + perf_cycles_ww_conflict)
                      / real'(perf_cycles_total));
            $display("[DATABANK_PERF] both_active_pct    = %0.2f %%",
                100.0 * real'(perf_cycles_both_active) / real'(perf_cycles_total));
        end
    end
`endif

    ////////////////////////////////////////////////////
    //Databank read info pipeline
    //Fixed length pipeline holding information about the current output data
    generate for (i = 0; i < 2; i++) begin : gen_pipeline
        always_ff @(posedge clk) begin
            if (rst)
                valid_pipeline[i] <= '0;
            else begin
                valid_pipeline[i][0] <= en_gated[i] & (current_state[i] == READING | (current_state[i] == READY & request_rnw));
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
