// Copyright 2024 Chris Keilbart
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// sdp_ram_uram: identical to sdp_ram but with `(* ram_style = "ultra" *)`
// pinned on the storage array. Used by l2_databank.sv when DATABANK_SDP=1
// to force the data-bank storage into UltraRAM on AMD UltraScale+ parts.
//
// Why a separate module: Vivado synth rejects parameter-expression
// attributes (`ram_style = RAM_STYLE` triggers Synth 8-281). A dedicated
// wrapper keeps the attribute literal while leaving the general-purpose
// sdp_ram untouched (the tagbank still wants BRAM auto-inference).
//
// URAM caveats:
//   * Underutilises capacity when ADDR_WIDTH < 12 (< 4096 entries). At
//     1024 entries × 512 bits Vivado will cascade 8 URAMs in parallel
//     for width and waste 75% of each URAM's depth -- you trade BRAM
//     pressure for URAM headroom, which is exactly the point for the
//     16-CU build.
//   * Initialises to zero only (no arbitrary init), matches sdp_ram.
//   * Per-byte writes valid only on the write port (this module is SDP),
//     same restriction as BRAM SDP.

module sdp_ram_uram

    #(
        parameter int unsigned ADDR_WIDTH = 10,
        parameter int unsigned NUM_COL = 4,
        parameter int unsigned COL_WIDTH = 16,
        parameter int unsigned PIPELINE_DEPTH = 1,
        parameter CASCADE_DEPTH = 8,
        // 1 = register port-A inputs one cycle. Cuts the URAM cascade
        // write-port path at the cost of +1 cycle of write commit
        // latency. Safe under the cache FSM (WRITING -> READY -> READING
        // serialisation absorbs the extra latency).
        parameter logic WRITE_INPUT_REG = 1'b0
    )
    (
        input logic clk,
        //Port A (write only)
        input logic a_en,
        input logic[NUM_COL-1:0] a_wbe,
        input logic[COL_WIDTH*NUM_COL-1:0] a_wdata,
        input logic[ADDR_WIDTH-1:0] a_addr,

        //Port B (read only)
        input logic b_en,
        input logic[ADDR_WIDTH-1:0] b_addr,
        output logic[COL_WIDTH*NUM_COL-1:0] b_rdata
    );

    localparam DATA_WIDTH = COL_WIDTH*NUM_COL;

    (* cascade_height = CASCADE_DEPTH, ramstyle = "no_rw_check", ram_style = "ultra" *)
    // NOTE: not given a declaration initializer -- Vivado does not initialize
    // UltraRAM. On silicon URAM powers up to 0; a DATABANK_SDP=1 build may show
    // X in 4-state sim until first written (correct on HW). DATABANK_SDP=0
    // (tdp_ram, the default and GraphBlox's config) is 0-init'd and 4-state clean.
    logic[DATA_WIDTH-1:0] mem[(1<<ADDR_WIDTH)-1:0];

    //Optional 1-cycle write-input register (passthrough when WRITE_INPUT_REG=0)
    logic                        a_en_q;
    logic[NUM_COL-1:0]           a_wbe_q;
    logic[DATA_WIDTH-1:0]        a_wdata_q;
    logic[ADDR_WIDTH-1:0]        a_addr_q;
    generate if (WRITE_INPUT_REG) begin : gen_a_reg
        always_ff @(posedge clk) begin
            a_en_q    <= a_en;
            a_wbe_q   <= a_wbe;
            a_wdata_q <= a_wdata;
            a_addr_q  <= a_addr;
        end
    end
    else begin : gen_a_combo
        assign a_en_q    = a_en;
        assign a_wbe_q   = a_wbe;
        assign a_wdata_q = a_wdata;
        assign a_addr_q  = a_addr;
    end endgenerate

    // Expand per-column enables to a per-bit mask. Verilator silently drops
    // partial non-blocking assignments from wide for-loops once NUM_COL grows
    // into the hundreds (the same bug #7 class fixed in tdp_ram.sv). Use one
    // full-width masked NBA in cocotb simulation; keep the canonical per-column
    // template for synthesis so Vivado still infers byte-enabled UltraRAM.
    logic[DATA_WIDTH-1:0] a_wmask;
    always_comb begin
        for (int i = 0; i < NUM_COL; i++) begin
            for (int b = 0; b < COL_WIDTH; b++)
                a_wmask[i*COL_WIDTH + b] = a_wbe_q[i];
        end
    end

`ifdef COCOTB_SIM
    always_ff @(posedge clk) begin
        if (a_en_q & |a_wbe_q)
            mem[a_addr_q] <= (mem[a_addr_q] & ~a_wmask)
                           | (a_wdata_q & a_wmask);
    end
`else
    // Synthesis path: canonical per-column write-enable template.
    always_ff @(posedge clk) begin
        for (int i = 0; i < NUM_COL; i++) begin
            if (a_en_q & a_wbe_q[i])
                mem[a_addr_q][i*COL_WIDTH +: COL_WIDTH] <= a_wdata_q[i*COL_WIDTH +: COL_WIDTH];
        end
    end
`endif

    //B read
    logic[DATA_WIDTH-1:0] b_ram_output;
    always_ff @(posedge clk) begin
        if (b_en)
            b_ram_output <= mem[b_addr];
    end

    //B output pipeline
    generate if (PIPELINE_DEPTH > 0) begin : gen_b_pipeline
        logic[DATA_WIDTH-1:0] b_data_pipeline[PIPELINE_DEPTH-1:0];
        logic[PIPELINE_DEPTH-1:0] b_en_pipeline;

        always_ff @(posedge clk) begin
            for (int i = 0; i < PIPELINE_DEPTH; i++) begin
                b_en_pipeline[i] <= i == 0 ? b_en : b_en_pipeline[i-1];
                if (b_en_pipeline[i])
                    b_data_pipeline[i] <= i == 0 ? b_ram_output : b_data_pipeline[i-1];
            end
        end
        assign b_rdata = b_data_pipeline[PIPELINE_DEPTH-1];
    end
    else begin : gen_b_transparent_output
        assign b_rdata = b_ram_output;
    end endgenerate

endmodule
