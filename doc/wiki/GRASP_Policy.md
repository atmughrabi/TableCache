# GRASP Replacement Policy

> Copy-pasteable single page for GitHub Wiki. Source of truth for the
> architectural description is `doc/ARCHITECTURE.md` §6, and for the
> RTL is `src/GRASP.sv`. This page is a self-contained summary aimed
> at users coming from the wiki sidebar.

GRASP is an address-region-aware variant of SRRIP-FP, adapted for
graph workloads where a small "hot" working set should be retained
even when streaming through a much larger "cold" pool. The policy
takes the line address into account when deciding insert and hit
promotion RRPV values.

## TL;DR

```sv
l2_cache #(
    .POLICY              (GRASP),    // enum from cache_config::policy_t
    .LINES               (1024),
    .LINE_W              (16),
    .WAYS                (8),
    .BLOCK_W             (32),
    .DATABANK_SDP        (1),
    .DB_LATENCY          (2)
    // ADDR_RANGE_L / ADDR_RANGE_H per system map
) u_cache (
    .clk(clk), .rst(rst),

    // Runtime GRASP region windows. Drive _h = 0 to disable a region.
    .grasp_high_addr_l    (32'h8000_0000),  // hot region: [_l, _h]
    .grasp_high_addr_h    (32'h8000_0FFF),
    .grasp_moderate_addr_l(32'h8001_0000),  // moderate region: [_l, _h]
    .grasp_moderate_addr_h(32'h8001_FFFF),

    /* AXI ports */
);
```

Set both region `_h` ports to `0` and GRASP becomes a no-op,
identical to SRRIP-FP.

## How the policy works

3-bit RRPV (range 0..7), `'0 = sticky`, `'1 = MAX_RRPV = victim`:

| Access | High region (hit_addr ∈ [hi_l, hi_h]) | Moderate region (hit_addr ∈ [mod_l, mod_h]) | Outside both regions |
|---|---|---|---|
| Cold miss (insert) | RRPV = `HOT_INSERT_RRPV = 0`  | RRPV = `MODERATE_INSERT_RRPV = 1` | RRPV = `MAX_RRPV = 7` (SRRIP-FP) |
| Hit promotion     | RRPV = `HOT_HIT_RRPV = 0`     | `RRPV -= 1` (saturate at 0)        | `RRPV -= 1` (saturate at 0)    |
| Aging on miss     | `RRPV += min_RRPV`            | `RRPV += min_RRPV`                  | `RRPV += min_RRPV`             |

Precedence: if a line's address matches BOTH the high and moderate
regions, the high-region rules win (the `if (high_reuse) ... else if
(moderate_reuse)` chain in `src/GRASP.sv:87-100`).

The high-region path is what makes GRASP useful for graph workloads
— pin the frequent-reuse address range to RRPV=0 and the policy
holds it through arbitrary cold thrash.

## Stats

### Hit-rate (perf_sweep.py)

Measured on the synthetic graph-traversal workload at `WAYS={4,8}`,
1024 lines, 16-block line:

| Policy | 4-way hit rate | 8-way hit rate | Δ (way scaling) |
|---|---:|---:|---:|
| LRU    | 65.8 % | 71.2 % | +5.4 pp |
| SRRIP  | 69.8 % | 74.4 % | +4.6 pp |
| GRASP  | 69.1 % | 74.1 % | +5.0 pp |

GRASP scales like SRRIP on the synthetic sweep (within 0.3 pp);
the win comes on real graph workloads where the hot region carries
the working set's hub vertices. See `tb/cocotb/perf_sweep.py` for
the harness.

### Throughput

`tb/cocotb/perf_300mhz.sh` measures cycle-count parity vs LRU on
`test_workload` (NTXN=5000): GRASP within 0.3 % of LRU at 512 KB / 8w,
identical reads/writes/full_writes counts. The policy logic is not on
the throughput-binding path; the win is hit-rate, not cycles-per-txn.

### Timing impact

| Config | LRU WNS post-synth | GRASP WNS post-synth | Δ |
|---|---:|---:|---:|
| 512 KB / 8w / SDP+URAM / U250 / 4 ns | +0.186 ns | +0.186 ns | **0 ns** |

GRASP adds 0 ns of WNS overhead vs SRRIP — the address-region
predicates land off the critical path in PnR. Same headline on
U55C and V80 (see [`syn/vivado/sweep_results.md`](../../syn/vivado/sweep_results.md)
and per-board reports in [`doc/deployment/`](../../doc/deployment/README.md)).

## Verification

### Directed cocotb tests (`test_grasp*.py`)

| Module | Cases | What it exercises |
|---|---:|---|
| `test_grasp.py`             | 5 | hot retention under cold thrash; SRRIP-FP fallback; invalid-region handling; runtime reconfiguration; hot/moderate overlap precedence; cumulative aging under multi-round re-reads |
| `test_grasp_pressure.py`    | 1 | set-aliased thrash; isolates the hot-insert and hot-hit promotion paths |
| `test_grasp_midburst.py`    | 1 | mid-burst region reconfiguration; verifies region ports are sampled per-access |
| `test_grasp_moderate.py`    | 1 | moderate-region 6x hit-promotion + cold-conflict eviction (the test that flushes the `swap_hit_decrement` mutation) |

All 8 test cases PASS at the deployment knobs (`DATABANK_SDP=1
DB_LATENCY=3 SDP_WRITE_INPUT_REG=1`).

### Mutation testing (`tb/cocotb/mutation_test.sh FILE=src/GRASP.sv`)

5 mutations, **5 / 5 KILLED (100 % score)**:

| Mutation | Killed by |
|---|---|
| `victim_idx_to_zero` (every miss picks way 0) | `test_random` data scoreboard |
| `way_onehot_invert` (multi-hot replacement way) | `$onehot` assertion + scoreboard |
| `swap_hit_decrement` (hit promotion `-=` → `+=`) | `test_grasp_moderate` (the directed 6-hit moderate-region cold-conflict pattern) |
| `swap_hot_insert_to_max` (cold hot-insert at MAX RRPV) | `test_grasp_pressure` round-1 hot pool re-warm |
| `swap_hot_hit_to_max` (hot hit promotion to MAX RRPV) | `test_grasp_pressure` cumulative age across rounds |

One mutation (`drop_moderate_exclusion`) was excluded as a provably
equivalent change — the `if (high_reuse) ... else if (moderate_reuse)`
precedence chain in the eviction path masks the difference.

### Formal proofs (`tb/formal/grasp_formal.sv`)

5 combinational invariants proven via Yosys + SMTBMC (`bmc-grasp` and
`induct-grasp` targets in `tb/formal/Makefile`):

| Invariant | What it asserts |
|---|---|
| One-hot replacement | `$onehot(cache_replacement_way)` always |
| Replacement-way range | `cache_replacement_way_int < WAYS` |
| One-hot consistency | `cache_replacement_way[cache_replacement_way_int]` always |
| Region exclusion | `!(ref_high_reuse && ref_moderate_reuse)` (high wins on overlap) |
| Disabled-region predicates | with both `_h` ports = 0, neither region matches anything |

All 5 PASS under BMC (combinational logic; BMC alone is sufficient).
The branch's `experiment/verify.sh` gate runs them on every commit
(latest gate: 10 / 10 proofs PASS overall).

## Bug history

| # | Bug | What broke | Fix | Discovered by |
|---:|---|---|---|---|
| 15 | `policy_addr` in `l2_tagbank.sv` was tag-projected, losing the upper `OMITTED_ADDR_W` bits | GRASP region match could never fire for any address ≥ `ADDR_RANGE_L` → silent degradation to plain RRIP-FP | Added `ADDR_BASE` parameter; reconstruct `policy_addr = ADDR_BASE \| {tag, line, 0}` before the policy | hit-rate flat across way sweep (`perf_sweep.py`) |
| 16 | `out_dirty`/`out_tag` always indexed by `policy_replacement_way_int` | CBOM-HIT writeback used wrong way's stale tag (typically tag=0) → mem-AW to wrong address | `evicted_entry = hit ? tb_rdata_r[hit_index] : evict_entry` | `test_cbom_rmw_race.py` adversarial pattern |

Both fixed on main and verified by the gates above.

## Files

- `src/GRASP.sv` — the policy logic (110 lines)
- `src/cache_config.sv` — `policy_t` enum (line 23-28)
- `src/replacement_policy.sv` — dispatcher to the chosen policy
- `src/l2_tagbank.sv` — feeds `policy_addr` to the policy
- `tb/cocotb/test_grasp*.py` — 4 directed test modules (8 cases)
- `tb/cocotb/mutation_test.sh` — GRASP entry around line 281
- `tb/formal/grasp_formal.sv` — formal invariant harness
- `doc/ARCHITECTURE.md` §6 — full policy description and rationale
