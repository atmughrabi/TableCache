// Formal harness for src/fifo.sv (FIFO_DEPTH=2 path).
`default_nettype none
module fifo_formal_deep #(
    parameter int unsigned WIDTH = 4,
    parameter int unsigned FIFO_DEPTH = 4
) (
    input  logic              clk,
    input  logic              rst,
    input  logic              push,
    input  logic              pop,
    input  logic [WIDTH-1:0]  din
);
    logic [WIDTH-1:0] dout;
    logic             valid;
    logic             full;

    fifo #(.WIDTH(WIDTH), .FIFO_DEPTH(FIFO_DEPTH)) dut (
        .clk(clk), .rst(rst),
        .fifo_push(push), .fifo_pop(pop),
        .fifo_data_in(din), .fifo_data_out(dout),
        .fifo_valid(valid), .fifo_full(full)
    );

    logic [2:0] ref_count = '0;
    always_ff @(posedge clk) begin
        if (rst) ref_count <= '0;
        else     ref_count <= ref_count + push - pop;
    end

    // Force reset in the first cycle so DUT and ref_count both initialise to 0.
    always_comb if ($initstate) assume (rst);

    always_ff @(posedge clk) begin
        if (!rst) begin
            if (push) assume (!full || pop);
            if (pop)  assume (valid);
            assert (ref_count <= FIFO_DEPTH);
            assert (valid == (ref_count != 0));
            assert (full  == (ref_count == FIFO_DEPTH));
        end
    end
endmodule
`default_nettype wire
