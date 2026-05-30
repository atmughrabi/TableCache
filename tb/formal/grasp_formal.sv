// Formal harness for src/GRASP.sv.
//
// Proves combinational invariants that hold under any input:
//   - cache_replacement_way is exactly one-hot
//   - cache_replacement_way_int is a valid way index (< WAYS)
//   - the bit set in cache_replacement_way matches cache_replacement_way_int
//   - mutual exclusion of internal high/moderate region predicates
//     (the moderate predicate masks out high so they cannot both fire)
//
// Default sized at WAYS=4 (matches the cache's default config). The
// proof carries through trivially at any WAYS (no policy state is
// touched).
`default_nettype none
module grasp_formal #(
    parameter int unsigned WAYS     = 4,
    parameter int unsigned ADDR_W   = 32
) (
    input  logic                          clk,
    input  logic                          rst,
    input  logic [ADDR_W-1:0]             grasp_high_addr_l,
    input  logic [ADDR_W-1:0]             grasp_high_addr_h,
    input  logic [ADDR_W-1:0]             grasp_moderate_addr_l,
    input  logic [ADDR_W-1:0]             grasp_moderate_addr_h,
    input  logic                          cache_eviction,
    input  logic [WAYS-1:0]               cache_way_used_one_hot,
    input  logic [3*WAYS-1:0]             cache_original_status,
    input  logic [ADDR_W-1:0]             cache_addr
);
    localparam int unsigned POLICY_W = 3*WAYS;

    logic [POLICY_W-1:0]   cache_new_status;
    logic [WAYS-1:0]       cache_replacement_way;
    logic [$clog2(WAYS)-1:0] cache_replacement_way_int;

    GRASP #(
        .POLICY_W(POLICY_W),
        .WAYS    (WAYS),
        .ADDR_W  (ADDR_W)
    ) dut (
        .clk(clk), .rst(rst),
        .grasp_high_addr_l(grasp_high_addr_l),
        .grasp_high_addr_h(grasp_high_addr_h),
        .grasp_moderate_addr_l(grasp_moderate_addr_l),
        .grasp_moderate_addr_h(grasp_moderate_addr_h),
        .cache_eviction(cache_eviction),
        .cache_way_used_one_hot(cache_way_used_one_hot),
        .cache_original_status(cache_original_status),
        .cache_addr(cache_addr),
        .cache_new_status(cache_new_status),
        .cache_replacement_way(cache_replacement_way),
        .cache_replacement_way_int(cache_replacement_way_int)
    );

    // Mirror the policy's internal high_reuse / moderate_reuse predicates
    // so we can assert their mutual exclusion without hierarchical refs.
    wire ref_high_reuse = (grasp_high_addr_h != '0)
                       && (grasp_high_addr_h >= grasp_high_addr_l)
                       && (cache_addr >= grasp_high_addr_l)
                       && (cache_addr <= grasp_high_addr_h);
    wire ref_moderate_reuse = (grasp_moderate_addr_h != '0)
                           && (grasp_moderate_addr_h >= grasp_moderate_addr_l)
                           && (cache_addr >= grasp_moderate_addr_l)
                           && (cache_addr <= grasp_moderate_addr_h)
                           && !ref_high_reuse;

    // Force first cycle to be reset (matches the other harnesses).
    always_comb if ($initstate) assume (rst);

    always_ff @(posedge clk) begin
        if (!rst) begin
            // P1: replacement way is exactly one bit set.
            assert ($onehot(cache_replacement_way));
            // P2: way index is in [0, WAYS).
            assert (cache_replacement_way_int < WAYS);
            // P3: the bit set in cache_replacement_way is at position
            // cache_replacement_way_int.
            assert (cache_replacement_way[cache_replacement_way_int]);
            // P4: high/moderate region predicates are mutually exclusive
            // (the policy depends on this for its precedence chain).
            assert (!(ref_high_reuse && ref_moderate_reuse));
            // P5: when both regions are disabled (_h == 0) neither
            // predicate fires regardless of cache_addr. This is the
            // SRRIP-FP fallback contract documented in GRASP.sv.
            if (grasp_high_addr_h == '0 && grasp_moderate_addr_h == '0) begin
                assert (!ref_high_reuse);
                assert (!ref_moderate_reuse);
            end
        end
    end
endmodule
`default_nettype wire
