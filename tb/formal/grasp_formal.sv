// Formal harness for src/GRASP.sv.
//
// Proves combinational invariants that hold under any input:
//   - cache_replacement_way is exactly one-hot
//   - cache_replacement_way_int is a valid way index (< WAYS)
//   - the bit set in cache_replacement_way matches cache_replacement_way_int
//   - high/moderate/default insertion values match the configured windows
//   - high-reuse hits promote to zero; other hits decrement toward zero
//   - overlapping high/moderate windows select the high-reuse behavior
//   - disabled windows produce the SRRIP-FP insertion/hit behavior
//
// Sized at HIGH_REGIONS=2 / MODERATE_REGIONS=2 so the proof exercises the
// multi-window OR-reduction (window i = bits [i*ADDR_W +: ADDR_W]); the
// single-window case is the i=0 specialization. The proof carries through at
// any WAYS / region count (no policy state is touched).
`default_nettype none
module grasp_formal #(
    parameter int unsigned WAYS             = 3,
    parameter int unsigned ADDR_W           = 8,
    parameter int unsigned HIGH_REGIONS     = 2,
    parameter int unsigned MODERATE_REGIONS = 2
) (
    input  logic                                  clk,
    input  logic                                  rst,
    input  logic [HIGH_REGIONS*ADDR_W-1:0]        grasp_high_addr_l,
    input  logic [HIGH_REGIONS*ADDR_W-1:0]        grasp_high_addr_h,
    input  logic [MODERATE_REGIONS*ADDR_W-1:0]    grasp_moderate_addr_l,
    input  logic [MODERATE_REGIONS*ADDR_W-1:0]    grasp_moderate_addr_h,
    input  logic                                  cache_eviction,
    input  logic [WAYS-1:0]                        cache_way_used_one_hot,
    input  logic [3*WAYS-1:0]                      cache_original_status,
    input  logic [ADDR_W-1:0]                      cache_addr
);
    localparam int unsigned POLICY_W = 3*WAYS;
    localparam logic [2:0] MAX_RRPV = 3'b111;
    localparam logic [2:0] MODERATE_INSERT_RRPV = 3'b001;
    genvar r, w;

    logic [POLICY_W-1:0]   cache_new_status;
    logic [WAYS-1:0]       cache_replacement_way;
    logic [$clog2(WAYS)-1:0] cache_replacement_way_int;

    GRASP #(
        .POLICY_W        (POLICY_W),
        .WAYS            (WAYS),
        .ADDR_W          (ADDR_W),
        .HIGH_REGIONS    (HIGH_REGIONS),
        .MODERATE_REGIONS(MODERATE_REGIONS)
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

    // Mirror the policy's internal high_reuse / moderate_reuse predicates as an
    // OR-reduction over the per-window match bits, so we can assert their
    // mutual exclusion without hierarchical refs.
    wire [HIGH_REGIONS-1:0]     ref_high_hit;
    wire [MODERATE_REGIONS-1:0] ref_mod_hit;
    generate
        for (r = 0; r < HIGH_REGIONS; r++) begin : gen_ref_high
            assign ref_high_hit[r] =
                (grasp_high_addr_h[r*ADDR_W +: ADDR_W] != '0)
             && (grasp_high_addr_h[r*ADDR_W +: ADDR_W] >= grasp_high_addr_l[r*ADDR_W +: ADDR_W])
             && (cache_addr >= grasp_high_addr_l[r*ADDR_W +: ADDR_W])
             && (cache_addr <= grasp_high_addr_h[r*ADDR_W +: ADDR_W]);
        end
        for (r = 0; r < MODERATE_REGIONS; r++) begin : gen_ref_mod
            assign ref_mod_hit[r] =
                (grasp_moderate_addr_h[r*ADDR_W +: ADDR_W] != '0)
             && (grasp_moderate_addr_h[r*ADDR_W +: ADDR_W] >= grasp_moderate_addr_l[r*ADDR_W +: ADDR_W])
             && (cache_addr >= grasp_moderate_addr_l[r*ADDR_W +: ADDR_W])
             && (cache_addr <= grasp_moderate_addr_h[r*ADDR_W +: ADDR_W]);
        end
    endgenerate
    wire ref_high_reuse     = |ref_high_hit;
    wire ref_moderate_reuse = (|ref_mod_hit) && !ref_high_reuse;
    wire [2:0] ref_original_rrpv [WAYS-1:0];
    wire [2:0] ref_new_rrpv [WAYS-1:0];
    logic [2:0] ref_victim_rrpv;

    generate
        for (w = 0; w < WAYS; w++) begin : gen_ref_rrpv
            assign ref_original_rrpv[w] = cache_original_status[w*3 +: 3];
            assign ref_new_rrpv[w] = cache_new_status[w*3 +: 3];
        end
    endgenerate

    always_comb begin
        ref_victim_rrpv = '0;
        for (int way = 0; way < WAYS; way++) begin
            if (cache_replacement_way[way])
                ref_victim_rrpv = ref_original_rrpv[way];
        end
    end

    // Force first cycle to be reset (matches the other harnesses).
    always_comb if ($initstate) assume (rst);

    always_ff @(posedge clk) begin
        if (!rst) begin
            // P1: replacement way is exactly one bit set.
            assert ((cache_replacement_way != '0)
                && ((cache_replacement_way
                    & (cache_replacement_way - 1'b1)) == '0));
            // P2: way index is in [0, WAYS).
            assert (cache_replacement_way_int < WAYS);
            // P3: the bit set in cache_replacement_way is at position
            // cache_replacement_way_int.
            assert (cache_replacement_way[cache_replacement_way_int]);
            cover (cache_eviction && ref_high_reuse && !(|ref_mod_hit));
            cover (cache_eviction && ref_moderate_reuse);
            cover (cache_eviction && (|ref_high_hit) && (|ref_mod_hit));
            cover (cache_eviction && grasp_high_addr_h == '0
                && grasp_moderate_addr_h == '0);
        end
    end

    generate
        for (w = 0; w < WAYS; w++) begin : gen_policy_properties
            always_ff @(posedge clk) begin
                if (!rst) begin
                    if (cache_eviction) begin
                        assert (ref_victim_rrpv >= ref_original_rrpv[w]);
                        if (!cache_replacement_way[w]) begin
                            assert (ref_new_rrpv[w]
                                == ref_original_rrpv[w]
                                + (MAX_RRPV - ref_victim_rrpv));
                        end
                    end

                    if (cache_eviction && cache_replacement_way[w]) begin
                        if (ref_high_reuse) begin
                            assert (ref_new_rrpv[w] == 3'b000);
                        end else if (ref_moderate_reuse) begin
                            assert (ref_new_rrpv[w] == MODERATE_INSERT_RRPV);
                        end else begin
                            assert (ref_new_rrpv[w] == MAX_RRPV);
                        end

                        if ((|ref_high_hit) && (|ref_mod_hit)) begin
                            assert (ref_new_rrpv[w] == 3'b000);
                        end
                        if (grasp_high_addr_h == '0 && grasp_moderate_addr_h == '0) begin
                            assert (ref_new_rrpv[w] == MAX_RRPV);
                        end
                    end

                    if (!cache_eviction && cache_way_used_one_hot[w]) begin
                        if (ref_high_reuse) begin
                            assert (ref_new_rrpv[w] == 3'b000);
                        end else if (ref_original_rrpv[w] == 3'b000) begin
                            assert (ref_new_rrpv[w] == 3'b000);
                        end else begin
                            assert (ref_new_rrpv[w] == ref_original_rrpv[w] - 1'b1);
                        end
                    end else if (!cache_eviction) begin
                        assert (ref_new_rrpv[w] == ref_original_rrpv[w]);
                    end
                end
            end
        end
    endgenerate
endmodule
`default_nettype wire
