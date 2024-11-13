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

module replacement_policy

    import cache_config::*;

    #(
        parameter replacement_policy_t POLICY,
        parameter int unsigned WAYS,
        parameter int unsigned LINES
    )
    (
        input logic clk,
        input logic rst,

        //Initial metadata lookup
        input logic init_lookup,
        input logic[$clog2(LINES)-1:0] lookup_line_addr,

        //Determination; must occur on init_lookup_r_r
        input logic cache_valid, //If the inputs are valid and you would like an output
        input logic[$clog2(LINES)-1:0] cache_line_addr, //Policy write address
        input logic[WAYS-1:0] cache_way_used_one_hot, //Hit one hot
        input logic[WAYS == 1 ? 0 : $clog2(WAYS)-1 : 0] cache_way_used_int, //Hit way
        input logic cache_eviction, //Otherwise a hit and the accounting needs to be updated
        input logic[31:0] cache_addr, //Address of request, if needed by replacement policy

        output logic[WAYS-1:0] cache_replacement_way, //Which way will be evicted
        output logic[WAYS == 1 ? 0 : $clog2(WAYS)-1 : 0] cache_replacement_way_int //Integer of the replacement way
    );

    ////////////////////////////////////////////////////
    //Cache replacement policy
    //Instantiates the correct replacement policy
    //Also manages replacement policy metadata

    //These parameters can be customized
    localparam logic RANDOM_USE_EVICT = 1; //Whether the randomly evicted way should change after each eviction or constantly
    localparam logic RRIP_HP = 1; //1 for Hit Priority, 0 for Frequency Priority. The paper authors found HP to be superior in their tests
    localparam int unsigned RRIP_WIDTH = 2; //Number of bits per way. The paper authors found 2-3 to be optimal

    localparam int unsigned POLICY_W =
        POLICY == RANDOM ? 0 :
        POLICY == LRU ? (WAYS <= 4 ? 2*(WAYS-1)-1 : WAYS*$clog2(WAYS)) :
        POLICY == FRQ ? $clog2(WAYS) :
        POLICY == SECOND_CHANCE ? $clog2(WAYS)+WAYS :
        RRIP_WIDTH*WAYS; //RRIP

    typedef logic[POLICY_W-1:0] policy_t;

    ////////////////////////////////////////////////////
    //Implementation

    ////////////////////////////////////////////////////
    //Policy metadata initialization
    //Constant value, but determined at runtime
    //Required because Quartus doesn't support other methods
    policy_t INIT_POLICY;
    always_comb begin
        INIT_POLICY = '0;
        if (POLICY == LRU && WAYS > 4) begin
            for (int j = 0; j < WAYS; j++)
                INIT_POLICY = INIT_POLICY | policy_t'(j << (j*$clog2(WAYS)));
        end
        else if (POLICY == SRRIP)
            INIT_POLICY = 'x;
        //Technically only the pointer bits need to be set for second chance
    end

    ////////////////////////////////////////////////////
    //Replacement policy
    policy_t cache_original_status;
    policy_t cache_new_status;
    generate if (WAYS == 1) begin : gen_passthrough
        assign cache_replacement_way[0] = 1;
        assign cache_replacement_way_int = 0;
    end
    else begin : gen_policy
        if (POLICY == LRU) begin : gen_lru
            LRU #(.POLICY_W(POLICY_W), .WAYS(WAYS)) lru(.*);
        end
        else if (POLICY == FRQ) begin : gen_frq
            FRQ #(.POLICY_W(POLICY_W), .WAYS(WAYS)) frq(.*);
        end
        else if (POLICY == SECOND_CHANCE) begin : gen_second_chance
            second_chance #(.POLICY_W(POLICY_W), .WAYS(WAYS)) second_chance(.*);
        end
        else if (POLICY == RANDOM) begin : gen_rand
            random_replacement #(.USE_EVICT(RANDOM_USE_EVICT), .WAYS(WAYS)) random(.*);
        end
        else if (POLICY == SRRIP) begin : gen_srrip
            SRRIP #(.RRPV_HP(RRIP_HP), .RRPV_WIDTH(RRIP_WIDTH), .POLICY_W(POLICY_W), .WAYS(WAYS)) srrip(.*);
        end
    end endgenerate

    ////////////////////////////////////////////////////
    //Policy storage
    //Most policies store metadata to make eviction decisions
    generate if (POLICY_W > 0) begin : gen_policy_storage
        sdp_ram_rst #(
            .ADDR_WIDTH($clog2(LINES)),
            .NUM_COL(1),
            .COL_WIDTH(POLICY_W),
            .PIPELINE_DEPTH(1),
            .CASCADE_DEPTH(8)
        ) policy_storage (
            .rst_value(INIT_POLICY),
            .a_en(cache_valid),
            .a_wbe('1),
            .a_wdata(cache_new_status),
            .a_addr(cache_line_addr),
            .b_en(init_lookup), //Could be 1'b1, but this likely uses less power, only reading when needed
            .b_addr(lookup_line_addr),
            .b_rdata(cache_original_status),
        .*);
    end endgenerate

`ifndef ASSERT_OFF
    onehot_hit_assertion:
        assert property (@(posedge clk) disable iff (rst) cache_valid |-> $onehot0(cache_way_used_one_hot)) else $error("Tagbank hit multiple ways");
`endif

endmodule
