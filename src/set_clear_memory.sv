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

module set_clear_memory
    
    #(
        parameter int unsigned DEPTH = 64
    )
    (
        input logic clk,
        input logic rst,

        input logic set,
        input logic[$clog2(DEPTH)-1:0] set_addr,
        input logic clear,
        input logic[$clog2(DEPTH)-1:0] clear_addr,

        input logic[$clog2(DEPTH)-1:0] read_addr,
        output logic in_use
    );

    ////////////////////////////////////////////////////
    //Set-clear memory
    //Small RAM with synchronous set and clear ports, and an asynchronous read port
    //Includes a reset routine

    //Merely a convenience wrapper around the toggle memory
    logic toggle_arr[2];
    logic[$clog2(DEPTH)-1:0] toggle_addr_arr[2];
    logic[$clog2(DEPTH)-1:0] read_addr_arr[1];
    logic in_use_arr[1];

    assign toggle_arr[0] = set;
    assign toggle_arr[1] = clear;
    assign toggle_addr_arr[0] = set_addr;
    assign toggle_addr_arr[1] = clear_addr;
    assign read_addr_arr[0] = read_addr;
    assign in_use = in_use_arr[0];

    toggle_memory_set #(
        .DEPTH(DEPTH),
        .NUM_WRITE_PORTS(2),
        .NUM_READ_PORTS(1)
    ) toggle_mem (
        .init_clear(rst),
        .toggle(toggle_arr),
        .toggle_addr(toggle_addr_arr),
        .read_addr(read_addr_arr),
        .in_use(in_use_arr),
    .*);

    // synthesis translate_off
`ifndef ASSERT_OFF
    logic [DEPTH-1:0] ownership_shadow = '0;
    always_ff @(posedge clk) begin
        if (rst) begin
            ownership_shadow <= '0;
        end else begin
            if (set && ownership_shadow[set_addr])
                $error("set_clear_memory: redundant set at address %0d", set_addr);
            if (clear && !ownership_shadow[clear_addr])
                $error("set_clear_memory: clear of unset address %0d", clear_addr);
            if (set)
                ownership_shadow[set_addr] <= 1'b1;
            if (clear)
                ownership_shadow[clear_addr] <= 1'b0;
        end
    end
`endif
    // synthesis translate_on

endmodule
