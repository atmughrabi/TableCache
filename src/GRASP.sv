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

module GRASP

    #(
        parameter int unsigned POLICY_W,
        parameter int unsigned WAYS,
        parameter int unsigned ADDR_W = 32,
        // Number of independently-configurable address windows in each reuse
        // class.  Each window is one [_l, _h] pair packed into the flattened
        // region ports below: window i occupies bits [i*ADDR_W +: ADDR_W].
        // Default 1 reproduces the original single-window high/moderate ports
        // bit-for-bit (a 1*ADDR_W bus is just an ADDR_W bus).  Raise these to
        // pin several disjoint buffers in the same reuse class.
        parameter int unsigned HIGH_REGIONS = 1,
        parameter int unsigned MODERATE_REGIONS = 1
    )
    (
        input logic clk,
        input logic rst,

        // Runtime-configurable address region bounds, packed as
        // HIGH_REGIONS (resp. MODERATE_REGIONS) consecutive [_l, _h] windows.
        // Window i lives in bits [i*ADDR_W +: ADDR_W].  An individual window is
        // DISABLED when its _h field is 0 ("not in use").  When EVERY window is
        // disabled the policy reduces to SRRIP-FP: cold (MAX_RRPV) insertion,
        // decrement on hit.
        input logic[HIGH_REGIONS*ADDR_W-1:0] grasp_high_addr_l,
        input logic[HIGH_REGIONS*ADDR_W-1:0] grasp_high_addr_h,
        input logic[MODERATE_REGIONS*ADDR_W-1:0] grasp_moderate_addr_l,
        input logic[MODERATE_REGIONS*ADDR_W-1:0] grasp_moderate_addr_h,

        input logic cache_eviction,
        input logic[WAYS-1:0] cache_way_used_one_hot,
        input logic[POLICY_W-1:0] cache_original_status,
        input logic[ADDR_W-1:0] cache_addr,
        output logic[POLICY_W-1:0] cache_new_status,
        output logic[WAYS-1:0] cache_replacement_way,
        output logic[$clog2(WAYS)-1:0] cache_replacement_way_int
    );

    ////////////////////////////////////////////////////
    //Graph-aware RRIP inspired by the HPCA'20 GRASP simulator.
    //This hardware form uses static address windows to classify accesses as
    //high-, moderate-, or default-reuse and applies distinct insertion/hit
    //promotion positions on top of a 3-bit RRIP state.

    localparam int unsigned RRPV_WIDTH = 3;
    localparam int unsigned WAY_W = $clog2(WAYS);
    localparam logic[RRPV_WIDTH-1:0] MAX_RRPV = '1;
    localparam logic[RRPV_WIDTH-1:0] HOT_INSERT_RRPV = '0;
    localparam logic[RRPV_WIDTH-1:0] MODERATE_INSERT_RRPV = RRPV_WIDTH'(1);
    localparam logic[RRPV_WIDTH-1:0] HOT_HIT_RRPV = '0;
    genvar i;

    logic[RRPV_WIDTH-1:0] current_RRPV[WAYS-1:0];
    logic[RRPV_WIDTH-1:0] updated_RRPV[WAYS-1:0];
    logic high_reuse;
    logic moderate_reuse;
    logic[HIGH_REGIONS-1:0] high_hit;
    logic[MODERATE_REGIONS-1:0] moderate_hit;
    int victim_index;
    logic[RRPV_WIDTH-1:0] min_RRPV;

    generate for (i = 0; i < WAYS; i++) begin : array_parsing
        assign current_RRPV[i] = cache_original_status[(i+1)*RRPV_WIDTH -1 : i*RRPV_WIDTH];
        assign cache_new_status[(i+1)*RRPV_WIDTH -1 : i*RRPV_WIDTH] = updated_RRPV[i];
    end endgenerate

    // Each reuse class is the OR of its independently-configured windows.  A
    // window matches only when its _h field != 0 AND _h >= _l AND the address
    // falls inside [_l, _h]; driving _h to 0 (the "not in use" convention)
    // cleanly disables that window.  With every window disabled both classes
    // are 0 and GRASP behaves exactly like SRRIP-FP.
    generate
        for (i = 0; i < HIGH_REGIONS; i++) begin : gen_high_window
            assign high_hit[i] = (grasp_high_addr_h[i*ADDR_W +: ADDR_W] != 0) &
                (grasp_high_addr_h[i*ADDR_W +: ADDR_W] >= grasp_high_addr_l[i*ADDR_W +: ADDR_W]) &
                (cache_addr >= grasp_high_addr_l[i*ADDR_W +: ADDR_W]) &
                (cache_addr <= grasp_high_addr_h[i*ADDR_W +: ADDR_W]);
        end
        for (i = 0; i < MODERATE_REGIONS; i++) begin : gen_moderate_window
            assign moderate_hit[i] = (grasp_moderate_addr_h[i*ADDR_W +: ADDR_W] != 0) &
                (grasp_moderate_addr_h[i*ADDR_W +: ADDR_W] >= grasp_moderate_addr_l[i*ADDR_W +: ADDR_W]) &
                (cache_addr >= grasp_moderate_addr_l[i*ADDR_W +: ADDR_W]) &
                (cache_addr <= grasp_moderate_addr_h[i*ADDR_W +: ADDR_W]);
        end
    endgenerate

    assign high_reuse = |high_hit;
    // High precedence wins on overlap: a moderate window only takes effect
    // where no high window matched.
    assign moderate_reuse = (|moderate_hit) & ~high_reuse;

    rrip_tree #(.BLOCK_WIDTH(RRPV_WIDTH), .NUM_BLOCKS(WAYS)) min_tree (
        .blocks(current_RRPV),
        .lowest_index(victim_index),
        .smallest_value(min_RRPV)
    );

    always_comb begin
        updated_RRPV = current_RRPV;
        for (int j = 0; j < WAYS; j++) begin
            if (cache_way_used_one_hot[j] & ~cache_eviction) begin
                if (high_reuse)
                    updated_RRPV[j] = HOT_HIT_RRPV;
                else if (updated_RRPV[j] != 0)
                    updated_RRPV[j] -= 1'b1;
            end
            else if (cache_eviction) begin
                updated_RRPV[j] += min_RRPV;
                if (j == victim_index) begin
                    if (high_reuse)
                        updated_RRPV[j] = HOT_INSERT_RRPV;
                    else if (moderate_reuse)
                        updated_RRPV[j] = MODERATE_INSERT_RRPV;
                    else
                        updated_RRPV[j] = MAX_RRPV;
                end
            end
        end
    end

    assign cache_replacement_way_int = WAY_W'(victim_index);
    assign cache_replacement_way = WAYS'(1 << victim_index);

`ifndef ASSERT_OFF
    // Each reuse class needs at least one window; a count of 0 would make the
    // packed region ports [-1:0].  Reuse the codebase's elaboration-guard
    // convention (see l2_cache.sv N_BANKS guard).
    initial begin
        assert (HIGH_REGIONS >= 1)
        else $fatal(1, "GRASP: GRASP_HIGH_REGIONS=%0d invalid (must be >= 1).", HIGH_REGIONS);
        assert (MODERATE_REGIONS >= 1)
        else $fatal(1, "GRASP: GRASP_MODERATE_REGIONS=%0d invalid (must be >= 1).", MODERATE_REGIONS);
    end
`endif

endmodule
