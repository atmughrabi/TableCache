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
        parameter CASCADE_DEPTH = 8
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
    logic[DATA_WIDTH-1:0] mem[(1<<ADDR_WIDTH)-1:0];

    //A write (per-byte enables)
    always_ff @(posedge clk) begin
        for (int i = 0; i < NUM_COL; i++) begin
            if (a_en & a_wbe[i])
                mem[a_addr][i*COL_WIDTH +: COL_WIDTH] <= a_wdata[i*COL_WIDTH +: COL_WIDTH];
        end
    end

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
