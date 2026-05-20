// Formal harness for src/set_clear_memory.sv.
//
// Proves: under a well-formed environment (no concurrent set+clear on
// the same address; no clear of an unset bit), the `in_use` read port
// reads back exactly the symmetric difference of set and clear pulses
// observed on the target address.
`default_nettype none
module scm_formal #(
    parameter int unsigned DEPTH = 4
) (
    input  logic                        clk,
    input  logic                        rst,
    input  logic                        set,
    input  logic [$clog2(DEPTH)-1:0]    set_addr,
    input  logic                        clear,
    input  logic [$clog2(DEPTH)-1:0]    clear_addr,
    input  logic [$clog2(DEPTH)-1:0]    read_addr
);
    logic in_use;
    set_clear_memory #(.DEPTH(DEPTH)) dut (
        .clk(clk), .rst(rst),
        .set(set), .set_addr(set_addr),
        .clear(clear), .clear_addr(clear_addr),
        .read_addr(read_addr),
        .in_use(in_use)
    );

    // Reference: per-address shadow bit-vector.
    logic [DEPTH-1:0] ref_bits;
    always_ff @(posedge clk) begin
        if (rst) ref_bits <= '0;
        else begin
            if (set)   ref_bits[set_addr]   <= 1'b1;
            if (clear) ref_bits[clear_addr] <= 1'b0;
        end
    end

    // Force first cycle to be reset.
    always_comb if ($initstate) assume(rst);

    always_ff @(posedge clk) begin
        if (!rst) begin
            // Env: never set and clear the same address in the same cycle.
            if (set && clear) assume (set_addr != clear_addr);
            // Property: read returns shadow state for the read_addr.
            assert (in_use == ref_bits[read_addr]);
        end
    end
endmodule
`default_nettype wire
