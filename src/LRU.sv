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

module LRU

    #(
        parameter int unsigned POLICY_W = 6,
        parameter int unsigned WAYS = 4
    )
    (
        input logic clk,
        input logic rst,

        input logic cache_eviction,
        input logic[$clog2(WAYS)-1:0] cache_way_used_int,
        input logic[POLICY_W-1:0] cache_original_status,
        output logic[POLICY_W-1:0] cache_new_status,
        output logic[WAYS-1:0] cache_replacement_way,
        output logic[$clog2(WAYS)-1:0] cache_replacement_way_int
    );

    ////////////////////////////////////////////////////
    //Least recently used cache replacement policy
    //For n bits, LRU requires log2(n!) bits to store all permutations
    //However, decoding this becomes computationally prohibitive for large n
    //Therefore, for n >= 5 a compuationally inexpensive encoding is used requiring nlog2(n) bits

    //The Python code to generate the lookup tables for case 3 and 4 is as follows:
    /*
    arr = list(range(n))
    permutations =[list(i) for i in itertools.permutations(arr)]
    out_length = n.bit_length()-1
    for (i, entry) in enumerate(itertools.permutations(arr)):
        print(i, ": begin evict = ", entry[n-1], sep="", end="")
        entry = list(entry)
        entry.append(entry.pop(0))
        print("; miss = ", permutations.index(entry), "; end", sep="")
    for (i, entry) in enumerate(itertools.permutations(arr)):
        entry = list(entry)
        for j in range(n):
            dup = entry.copy()
            dup.remove(j)
            dup.append(j)
            cat = i << out_length
            cat = cat | j
            print(cat, ": hit = ", permutations.index(dup), ";", sep="")
    */

    localparam int unsigned WAY_W = $clog2(WAYS);
    genvar i;

    ////////////////////////////////////////////////////
    //Implementation
    generate if (WAYS == 2) begin : gen_2
        //Uses 1 bit representing the LRU
        assign cache_new_status = cache_eviction | cache_original_status == cache_way_used_int ? ~cache_original_status : cache_original_status;
        assign cache_replacement_way_int = cache_original_status;
        assign cache_replacement_way = 1 << cache_original_status;
    end
    else if (WAYS == 3) begin : gen_3
        //Uses 3 bit encoded LRU
        logic[1:0] evict; //Evicted way
        logic[2:0] miss; //New state on miss
        logic[2:0] hit; //New state on hit
        always_comb begin
            unique case (cache_original_status)
                0: begin evict = 2; miss = 3; end
                1: begin evict = 1; miss = 5; end
                2: begin evict = 2; miss = 1; end
                3: begin evict = 0; miss = 4; end
                4: begin evict = 1; miss = 0; end
                5: begin evict = 0; miss = 2; end
                default: begin evict = 'x; miss = 'x; end
            endcase
            unique case ({cache_original_status, cache_way_used_int})
                0: hit = 3;
                1: hit = 1;
                2: hit = 0;
                2: hit = 5;
                3: hit = 1;
                2: hit = 0;
                4: hit = 3;
                5: hit = 1;
                6: hit = 2;
                6: hit = 3;
                7: hit = 4;
                6: hit = 2;
                8: hit = 5;
                9: hit = 4;
                10: hit = 0;
                10: hit = 5;
                11: hit = 4;
                10: hit = 2;
                default: hit = 'x;
            endcase
        end
        assign cache_new_status = cache_eviction ? miss : hit;
        assign cache_replacement_way_int = evict;
        assign cache_replacement_way = 1 << evict;
    end
    else if (WAYS == 4) begin : gen_4
        //Uses 5 bit encoded LRU
        logic[1:0] evict; //Evicted way
        logic[4:0] miss; //New state on miss
        logic[4:0] hit; //New state on hit
        always_comb begin
            case (cache_original_status)
                0: begin evict = 3; miss = 9; end
                1: begin evict = 2; miss = 11; end
                2: begin evict = 3; miss = 15; end
                3: begin evict = 1; miss = 17; end
                4: begin evict = 2; miss = 21; end
                5: begin evict = 1; miss = 23; end
                6: begin evict = 3; miss = 3; end
                7: begin evict = 2; miss = 5; end
                8: begin evict = 3; miss = 13; end
                9: begin evict = 0; miss = 16; end
                10: begin evict = 2; miss = 19; end
                11: begin evict = 0; miss = 22; end
                12: begin evict = 3; miss = 1; end
                13: begin evict = 1; miss = 4; end
                14: begin evict = 3; miss = 7; end
                15: begin evict = 0; miss = 10; end
                16: begin evict = 1; miss = 18; end
                17: begin evict = 0; miss = 20; end
                18: begin evict = 2; miss = 0; end
                19: begin evict = 1; miss = 2; end
                20: begin evict = 2; miss = 6; end
                21: begin evict = 0; miss = 8; end
                22: begin evict = 1; miss = 12; end
                23: begin evict = 0; miss = 14; end
                default: begin evict = 'x; miss = 'x; end
            endcase
            case ({cache_original_status, cache_way_used_int})
                0: hit = 9;
                1: hit = 3;
                2: hit = 1;
                3: hit = 0;
                4: hit = 11;
                5: hit = 5;
                6: hit = 1;
                7: hit = 0;
                8: hit = 15;
                9: hit = 3;
                10: hit = 1;
                11: hit = 2;
                12: hit = 17;
                13: hit = 3;
                14: hit = 4;
                15: hit = 2;
                16: hit = 21;
                17: hit = 5;
                18: hit = 4;
                19: hit = 0;
                20: hit = 23;
                21: hit = 5;
                22: hit = 4;
                23: hit = 2;
                24: hit = 9;
                25: hit = 3;
                26: hit = 7;
                27: hit = 6;
                28: hit = 11;
                29: hit = 5;
                30: hit = 7;
                31: hit = 6;
                32: hit = 9;
                33: hit = 13;
                34: hit = 7;
                35: hit = 8;
                36: hit = 9;
                37: hit = 16;
                38: hit = 10;
                39: hit = 8;
                40: hit = 11;
                41: hit = 19;
                42: hit = 10;
                43: hit = 6;
                44: hit = 11;
                45: hit = 22;
                46: hit = 10;
                47: hit = 8;
                48: hit = 15;
                49: hit = 13;
                50: hit = 1;
                51: hit = 12;
                52: hit = 17;
                53: hit = 13;
                54: hit = 4;
                55: hit = 12;
                56: hit = 15;
                57: hit = 13;
                58: hit = 7;
                59: hit = 14;
                60: hit = 15;
                61: hit = 16;
                62: hit = 10;
                63: hit = 14;
                64: hit = 17;
                65: hit = 16;
                66: hit = 18;
                67: hit = 12;
                68: hit = 17;
                69: hit = 16;
                70: hit = 20;
                71: hit = 14;
                72: hit = 21;
                73: hit = 19;
                74: hit = 18;
                75: hit = 0;
                76: hit = 23;
                77: hit = 19;
                78: hit = 18;
                79: hit = 2;
                80: hit = 21;
                81: hit = 19;
                82: hit = 20;
                83: hit = 6;
                84: hit = 21;
                85: hit = 22;
                86: hit = 20;
                87: hit = 8;
                88: hit = 23;
                89: hit = 22;
                90: hit = 18;
                91: hit = 12;
                92: hit = 23;
                93: hit = 22;
                94: hit = 20;
                95: hit = 14;
                default: hit = 'x;
            endcase
        end
        assign cache_new_status = cache_eviction ? miss : hit;
        assign cache_replacement_way_int = evict;
        assign cache_replacement_way = 1 << evict;
    end
    else begin : gen_more_than_4
        //Use n*log2(n) bits of storage, too large for compressed encoding

        //Indexes represents position in the LRU queue, value is the way in that position
        logic[WAY_W-1:0] current_LRU[WAYS-1:0];
        logic[WAY_W-1:0] updated_LRU[WAYS-1:0];

        for (i = 0; i < WAYS; i++) begin : gen_unpacking
            assign current_LRU[i] = cache_original_status[(i+1)*WAY_W-1 : i*WAY_W];
            assign cache_new_status[(i+1)*WAY_W-1 : i*WAY_W] = updated_LRU[i];
        end

        //Update Least Recently Used tracking
        //First determine where the hit way is
        //Then shuffle everything
        logic[WAY_W-1:0] shift_starting_index;
        always_comb begin
            shift_starting_index = 0;
            for (int j = 1; j < WAYS; j++) begin
                if (current_LRU[j] == cache_way_used_int)
                    shift_starting_index = WAY_W'(j);
            end
        end

        for (i = 0; i < WAYS-1; i++) begin : update_LRU_values
            always_comb begin
                if (cache_eviction)
                    updated_LRU[i] = current_LRU[i+1]; //Everything shifts down
                else if (i >= shift_starting_index)
                    updated_LRU[i] = current_LRU[i+1]; //Shift until the element is found
                else
                    updated_LRU[i] = current_LRU[i];
            end
        end

        //WAYS-1 is a special case
        always_comb begin
            if (cache_eviction)
                updated_LRU[WAYS-1] = current_LRU[0]; //This way is evicted and becomes the most recently used
            else
                updated_LRU[WAYS-1] = cache_way_used_int;
        end

        //Trivially assign the output according to the LRU way
        assign cache_replacement_way_int = current_LRU[0];
        assign cache_replacement_way = 1 << current_LRU[0];
    end endgenerate

endmodule
