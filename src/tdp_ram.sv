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

module tdp_ram

    import cache_config::*;

    #(
        parameter int unsigned ADDR_WIDTH = 10,
        parameter int unsigned NUM_COL = 4, //Number of independently writeable components
        parameter int unsigned COL_WIDTH = 8, //Width the "byte" enable controls
        parameter int unsigned PIPELINE_DEPTH = 1, //Depth of the output pipeline, is latency in clock cycles
        parameter int unsigned CASCADE_DEPTH = 4 //Maximum depth of the memory block cascade on AMD FPGAs
    )
    (
        input logic clk,

        //Port A
        input logic a_en,
        input logic[NUM_COL-1:0] a_wbe,
        input logic[COL_WIDTH*NUM_COL-1:0] a_wdata,
        input logic[ADDR_WIDTH-1:0] a_addr,
        output logic[COL_WIDTH*NUM_COL-1:0] a_rdata,

        //Port B
        input logic b_en,
        input logic[NUM_COL-1:0] b_wbe,
        input logic[COL_WIDTH*NUM_COL-1:0] b_wdata,
        input logic[ADDR_WIDTH-1:0] b_addr,
        output logic[COL_WIDTH*NUM_COL-1:0] b_rdata
    );

    ////////////////////////////////////////////////////
    //True dual port RAM
    //Two synchronous ports that can either read or write
    //Configurable latency pipeline
    //Different templates are required for AMD and Intel FPGA tooling

    localparam DATA_WIDTH = COL_WIDTH*NUM_COL;
    genvar i;
    logic[DATA_WIDTH-1:0] a_raw;
    logic[DATA_WIDTH-1:0] b_raw;

    ////////////////////////////////////////////////////
    //Implementation

    ////////////////////////////////////////////////////
    //Output pipeline
    //Improves operating frequency by increasing read latency
    //These registers can be absorbed by the block memories, but this currently doesn't work in Quartus
    generate if (PIPELINE_DEPTH > 0) begin : gen_pipeline
        logic[DATA_WIDTH-1:0] a_data_pipeline[PIPELINE_DEPTH-1:0];
        logic[PIPELINE_DEPTH-1:0] a_en_pipeline;
        logic[DATA_WIDTH-1:0] b_data_pipeline[PIPELINE_DEPTH-1:0];
        logic[PIPELINE_DEPTH-1:0] b_en_pipeline;

        always_ff @(posedge clk) begin
            for (int j = 0; j < PIPELINE_DEPTH; j++) begin
                a_en_pipeline[j] <= j == 0 ? a_en : a_en_pipeline[j-1];
                b_en_pipeline[j] <= j == 0 ? b_en : b_en_pipeline[j-1];

                if (a_en_pipeline[j])
                    a_data_pipeline[j] <= j == 0 ? a_raw : a_data_pipeline[j-1];
                if (b_en_pipeline[j])
                    b_data_pipeline[j] <= j == 0 ? b_raw : b_data_pipeline[j-1];
            end
        end
        assign a_rdata = a_data_pipeline[PIPELINE_DEPTH-1];
        assign b_rdata = b_data_pipeline[PIPELINE_DEPTH-1];
    end
    else begin : gen_transparent
        assign a_rdata = a_raw;
        assign b_rdata = b_raw;
    end endgenerate

    //RAM itself
    generate if (FPGA_VENDOR == AMD) begin : gen_amd_tdp
        // ram_style = "block" rather than "ultra": this memory uses true
        // dual-port + per-byte write enables, which is supported by BRAM
        // (RAMB36/18) but NOT by UltraRAM (UltraRAM is SDP/word-only).
        // Vivado 2025.x errors out with "Unsupported RAM template" when
        // it tries to map this pattern to UltraRAM. cascade_height stays
        // for BRAM block cascading. Bug found via syn/vivado/run_synth.sh
        // on U250 -- see syn/vivado/README.md.
        (* cascade_height = CASCADE_DEPTH, ram_style = "block" *)
        logic[DATA_WIDTH-1:0] mem[(1<<ADDR_WIDTH)-1:0] = '{default: '0};

        // Expand per-byte write enables (a_wbe, b_wbe) to per-bit masks so the
        // memory update can be expressed as a single full-width non-blocking
        // assignment:  mem <= (mem & ~mask) | (data & mask).
        //
        // The original Eric Matthews implementation used a for-loop of partial
        // NBAs (`mem[addr][j*8 +: 8] <= data[...]`). That synthesises fine on
        // AMD/Intel but in Verilator the partial-NBA pattern silently fails
        // for wide column counts: when WAYS*WBE_W approaches the hundreds
        // (e.g. BLOCK_W=512 × WAYS=8 ⇒ NUM_COL=512), only the highest-indexed
        // active byte commits and the rest of the masked bytes are dropped.
        // This single-NBA form is functionally identical (and the synthesis
        // tools still infer per-byte write enables from it).
        logic[DATA_WIDTH-1:0] a_wmask;
        logic[DATA_WIDTH-1:0] b_wmask;
        always_comb begin
            for (int j = 0; j < NUM_COL; j++) begin
                for (int b = 0; b < COL_WIDTH; b++) begin
                    a_wmask[j*COL_WIDTH + b] = a_wbe[j];
                    b_wmask[j*COL_WIDTH + b] = b_wbe[j];
                end
            end
        end

        //A read/write
        // Bug #7 history: the original per-byte NBA loop is the canonical
        // Vivado TDP-with-byte-enable template and synthesises to BRAM
        // cleanly. Verilator silently DROPS bytes from that pattern when
        // NUM_COL grows past ~100 (BLOCK_W=512 * WAYS=8 = 512 cols), so
        // simulation needs the equivalent masked single-NBA form below.
        // Vivado rejects the masked form as "Unsupported RAM template",
        // so we ifdef on COCOTB_SIM (set by Verilator/cocotb) to pick.
`ifdef COCOTB_SIM
        always_ff @(posedge clk) begin
            if (a_en) begin
                if (|a_wbe)
                    mem[a_addr] <= (mem[a_addr] & ~a_wmask) | (a_wdata & a_wmask);
                else
                    a_raw <= mem[a_addr];
            end
        end

        //B read/write
        logic[DATA_WIDTH-1:0] b_ram_output;
        always_ff @(posedge clk) begin
            if (b_en) begin
                if (|b_wbe)
                    mem[b_addr] <= (mem[b_addr] & ~b_wmask) | (b_wdata & b_wmask);
                else
                    b_raw <= mem[b_addr];
            end
        end
`else
        // Synthesis path: per-byte NBA loop. Vivado infers BRAM with
        // per-byte write enables. DO NOT collapse into a single masked
        // NBA -- Vivado does not recognise that template.
        always_ff @(posedge clk) begin
            if (a_en) begin
                for (int j = 0; j < NUM_COL; j++) begin
                    if (a_wbe[j])
                        mem[a_addr][j*COL_WIDTH +: COL_WIDTH] <= a_wdata[j*COL_WIDTH +: COL_WIDTH];
                end
                if (~|a_wbe)
                    a_raw <= mem[a_addr];
            end
        end

        logic[DATA_WIDTH-1:0] b_ram_output;
        always_ff @(posedge clk) begin
            if (b_en) begin
                for (int j = 0; j < NUM_COL; j++) begin
                    if (b_wbe[j])
                        mem[b_addr][j*COL_WIDTH +: COL_WIDTH] <= b_wdata[j*COL_WIDTH +: COL_WIDTH];
                end
                if (~|b_wbe)
                    b_raw <= mem[b_addr];
            end
        end
`endif
    end
    else if (FPGA_VENDOR == INTEL) begin : gen_intel_tdp
        typedef logic[NUM_COL-1:0][COL_WIDTH-1:0] word_t;

        (* ramstyle = "no_rw_check" *) //Higher depths use less resources but are slower
        word_t mem[(1<<ADDR_WIDTH)-1:0] = '{default: '0};

        word_t a_raw_w;
        word_t a_raw_r;
        word_t b_raw_w;
        word_t b_raw_r;

        for (i = 0; i < NUM_COL; i++) begin : gen_unpack
            assign a_raw[COL_WIDTH*i+:COL_WIDTH] = a_raw_r[i];
            assign b_raw[COL_WIDTH*i+:COL_WIDTH] = b_raw_r[i];
            assign a_raw_w[i] = a_wdata[COL_WIDTH*i+:COL_WIDTH];
            assign b_raw_w[i] = b_wdata[COL_WIDTH*i+:COL_WIDTH];
        end

        //Quartus cannot handle a loop for the byte enables
        //So we unroll this loop manually
        `define ENTRY(i, port) if (NUM_COL > i) begin if (port``_wbe[i]) mem[port``_addr][i] <= port``_raw_w[i]; end

        `define UNROLL(n, port) \
            `ENTRY(0, port) \
            `ENTRY(1, port) \
            `ENTRY(2, port) \
            `ENTRY(3, port) \
            `ENTRY(4, port) \
            `ENTRY(5, port) \
            `ENTRY(6, port) \
            `ENTRY(7, port) \
            `ENTRY(8, port) \
            `ENTRY(9, port) \
            `ENTRY(10, port) \
            `ENTRY(11, port) \
            `ENTRY(12, port) \
            `ENTRY(13, port) \
            `ENTRY(14, port) \
            `ENTRY(15, port) \
            `ENTRY(16, port) \
            `ENTRY(17, port) \
            `ENTRY(18, port) \
            `ENTRY(19, port) \
            `ENTRY(20, port) \
            `ENTRY(21, port) \
            `ENTRY(22, port) \
            `ENTRY(23, port) \
            `ENTRY(24, port) \
            `ENTRY(25, port) \
            `ENTRY(26, port) \
            `ENTRY(27, port) \
            `ENTRY(28, port) \
            `ENTRY(29, port) \
            `ENTRY(30, port) \
            `ENTRY(31, port) \
            `ENTRY(32, port) \
            `ENTRY(33, port) \
            `ENTRY(34, port) \
            `ENTRY(35, port) \
            `ENTRY(36, port) \
            `ENTRY(37, port) \
            `ENTRY(38, port) \
            `ENTRY(39, port) \
            `ENTRY(40, port) \
            `ENTRY(41, port) \
            `ENTRY(42, port) \
            `ENTRY(43, port) \
            `ENTRY(44, port) \
            `ENTRY(45, port) \
            `ENTRY(46, port) \
            `ENTRY(47, port) \
            `ENTRY(48, port) \
            `ENTRY(49, port) \
            `ENTRY(50, port) \
            `ENTRY(51, port) \
            `ENTRY(52, port) \
            `ENTRY(53, port) \
            `ENTRY(54, port) \
            `ENTRY(55, port) \
            `ENTRY(56, port) \
            `ENTRY(57, port) \
            `ENTRY(58, port) \
            `ENTRY(59, port) \
            `ENTRY(60, port) \
            `ENTRY(61, port) \
            `ENTRY(62, port) \
            `ENTRY(63, port) \
            `ENTRY(64, port) \
            `ENTRY(65, port) \
            `ENTRY(66, port) \
            `ENTRY(67, port) \
            `ENTRY(68, port) \
            `ENTRY(69, port) \
            `ENTRY(70, port) \
            `ENTRY(71, port) \
            `ENTRY(72, port) \
            `ENTRY(73, port) \
            `ENTRY(74, port) \
            `ENTRY(75, port) \
            `ENTRY(76, port) \
            `ENTRY(77, port) \
            `ENTRY(78, port) \
            `ENTRY(79, port) \
            `ENTRY(80, port) \
            `ENTRY(81, port) \
            `ENTRY(82, port) \
            `ENTRY(83, port) \
            `ENTRY(84, port) \
            `ENTRY(85, port) \
            `ENTRY(86, port) \
            `ENTRY(87, port) \
            `ENTRY(88, port) \
            `ENTRY(89, port) \
            `ENTRY(90, port) \
            `ENTRY(91, port) \
            `ENTRY(92, port) \
            `ENTRY(93, port) \
            `ENTRY(94, port) \
            `ENTRY(95, port) \
            `ENTRY(96, port) \
            `ENTRY(97, port) \
            `ENTRY(98, port) \
            `ENTRY(99, port) \
            `ENTRY(100, port) \
            `ENTRY(101, port) \
            `ENTRY(102, port) \
            `ENTRY(103, port) \
            `ENTRY(104, port) \
            `ENTRY(105, port) \
            `ENTRY(106, port) \
            `ENTRY(107, port) \
            `ENTRY(108, port) \
            `ENTRY(109, port) \
            `ENTRY(110, port) \
            `ENTRY(111, port) \
            `ENTRY(112, port) \
            `ENTRY(113, port) \
            `ENTRY(114, port) \
            `ENTRY(115, port) \
            `ENTRY(116, port) \
            `ENTRY(117, port) \
            `ENTRY(118, port) \
            `ENTRY(119, port) \
            `ENTRY(120, port) \
            `ENTRY(121, port) \
            `ENTRY(122, port) \
            `ENTRY(123, port) \
            `ENTRY(124, port) \
            `ENTRY(125, port) \
            `ENTRY(126, port) \
            `ENTRY(127, port) \
            `ENTRY(128, port) \
            `ENTRY(129, port) \
            `ENTRY(130, port) \
            `ENTRY(131, port) \
            `ENTRY(132, port) \
            `ENTRY(133, port) \
            `ENTRY(134, port) \
            `ENTRY(135, port) \
            `ENTRY(136, port) \
            `ENTRY(137, port) \
            `ENTRY(138, port) \
            `ENTRY(139, port) \
            `ENTRY(140, port) \
            `ENTRY(141, port) \
            `ENTRY(142, port) \
            `ENTRY(143, port) \
            `ENTRY(144, port) \
            `ENTRY(145, port) \
            `ENTRY(146, port) \
            `ENTRY(147, port) \
            `ENTRY(148, port) \
            `ENTRY(149, port) \
            `ENTRY(150, port) \
            `ENTRY(151, port) \
            `ENTRY(152, port) \
            `ENTRY(153, port) \
            `ENTRY(154, port) \
            `ENTRY(155, port) \
            `ENTRY(156, port) \
            `ENTRY(157, port) \
            `ENTRY(158, port) \
            `ENTRY(159, port) \
            `ENTRY(160, port) \
            `ENTRY(161, port) \
            `ENTRY(162, port) \
            `ENTRY(163, port) \
            `ENTRY(164, port) \
            `ENTRY(165, port) \
            `ENTRY(166, port) \
            `ENTRY(167, port) \
            `ENTRY(168, port) \
            `ENTRY(169, port) \
            `ENTRY(170, port) \
            `ENTRY(171, port) \
            `ENTRY(172, port) \
            `ENTRY(173, port) \
            `ENTRY(174, port) \
            `ENTRY(175, port) \
            `ENTRY(176, port) \
            `ENTRY(177, port) \
            `ENTRY(178, port) \
            `ENTRY(179, port) \
            `ENTRY(180, port) \
            `ENTRY(181, port) \
            `ENTRY(182, port) \
            `ENTRY(183, port) \
            `ENTRY(184, port) \
            `ENTRY(185, port) \
            `ENTRY(186, port) \
            `ENTRY(187, port) \
            `ENTRY(188, port) \
            `ENTRY(189, port) \
            `ENTRY(190, port) \
            `ENTRY(191, port) \
            `ENTRY(192, port) \
            `ENTRY(193, port) \
            `ENTRY(194, port) \
            `ENTRY(195, port) \
            `ENTRY(196, port) \
            `ENTRY(197, port) \
            `ENTRY(198, port) \
            `ENTRY(199, port) \
            `ENTRY(200, port) \
            `ENTRY(201, port) \
            `ENTRY(202, port) \
            `ENTRY(203, port) \
            `ENTRY(204, port) \
            `ENTRY(205, port) \
            `ENTRY(206, port) \
            `ENTRY(207, port) \
            `ENTRY(208, port) \
            `ENTRY(209, port) \
            `ENTRY(210, port) \
            `ENTRY(211, port) \
            `ENTRY(212, port) \
            `ENTRY(213, port) \
            `ENTRY(214, port) \
            `ENTRY(215, port) \
            `ENTRY(216, port) \
            `ENTRY(217, port) \
            `ENTRY(218, port) \
            `ENTRY(219, port) \
            `ENTRY(220, port) \
            `ENTRY(221, port) \
            `ENTRY(222, port) \
            `ENTRY(223, port) \
            `ENTRY(224, port) \
            `ENTRY(225, port) \
            `ENTRY(226, port) \
            `ENTRY(227, port) \
            `ENTRY(228, port) \
            `ENTRY(229, port) \
            `ENTRY(230, port) \
            `ENTRY(231, port) \
            `ENTRY(232, port) \
            `ENTRY(233, port) \
            `ENTRY(234, port) \
            `ENTRY(235, port) \
            `ENTRY(236, port) \
            `ENTRY(237, port) \
            `ENTRY(238, port) \
            `ENTRY(239, port) \
            `ENTRY(240, port) \
            `ENTRY(241, port) \
            `ENTRY(242, port) \
            `ENTRY(243, port) \
            `ENTRY(244, port) \
            `ENTRY(245, port) \
            `ENTRY(246, port) \
            `ENTRY(247, port) \
            `ENTRY(248, port) \
            `ENTRY(249, port) \
            `ENTRY(250, port) \
            `ENTRY(251, port) \
            `ENTRY(252, port) \
            `ENTRY(253, port) \
            `ENTRY(254, port) \
            `ENTRY(255, port)

        //A read/write
        always_ff @(posedge clk) begin
            if (a_en) begin
                `UNROLL(NUM_COL, a)
            end
            a_raw_r <= mem[a_addr];
        end

        //B read/write
        always_ff @(posedge clk) begin
            if (b_en) begin
                `UNROLL(NUM_COL, b)
            end
            b_raw_r <= mem[b_addr];
        end

    `ifndef ASSERT_OFF
        initial assert(NUM_COL <= 255) else $fatal("Number of TDP columns is too large for the unroll macro");
    `endif

    end endgenerate

`ifndef ASSERT_OFF
    simul_assertion:
        assert property (@(posedge clk) (~(a_en & b_en & a_addr == b_addr & |(a_wbe & b_wbe)))) else $error("TDP RAM simultaneous write to same bytes");
`endif

endmodule
