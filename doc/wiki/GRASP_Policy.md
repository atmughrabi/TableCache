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

Each reuse class — **high** (hot) and **moderate** — is a configurable
set of **N independent address windows** (`GRASP_HIGH_REGIONS` /
`GRASP_MODERATE_REGIONS`, both default 1). This lets you pin several
disjoint buffers as hot at once, instead of a single contiguous range.

## TL;DR

```sv
l2_cache #(
    .POLICY              (GRASP),    // enum from cache_config::policy_t
    .LINES               (1024),
    .LINE_W              (16),
    .WAYS                (8),
    .BLOCK_W             (32),
    .DATABANK_SDP        (1),
    .DB_LATENCY          (2),
    // One window per reuse class is the default; raise to pin N buffers.
    .GRASP_HIGH_REGIONS     (2),
    .GRASP_MODERATE_REGIONS (1)
    // ADDR_RANGE_L / ADDR_RANGE_H per system map
) u_cache (
    .clk(clk), .rst(rst),

    // Runtime GRASP region windows, packed LOW->HIGH: window i occupies
    // bits [i*ADDR_W +: ADDR_W]. Drive a window's _h field to 0 to disable
    // just that window. Here: two hot buffers + one moderate buffer.
    .grasp_high_addr_l    ({32'h9000_0000, 32'h8000_0000}),  // [win1, win0]
    .grasp_high_addr_h    ({32'h9000_0FFF, 32'h8000_0FFF}),
    .grasp_moderate_addr_l(32'h8001_0000),                   // single window
    .grasp_moderate_addr_h(32'h8001_FFFF),

    /* AXI ports */
);
```

At the default `GRASP_HIGH_REGIONS = GRASP_MODERATE_REGIONS = 1` the
ports are a single `[ADDR_W-1:0]` window each (bit-identical to the
original interface). Set **every** window's `_h` port to `0` and GRASP
becomes a no-op, identical to SRRIP-FP.

## How the policy works

3-bit RRPV (range 0..7), `'0 = sticky`, `'1 = MAX_RRPV = victim`:

| Access | High region (addr ∈ any high window) | Moderate region (addr ∈ any moderate window) | Outside all windows |
|---|---|---|---|
| Cold miss (insert) | RRPV = `HOT_INSERT_RRPV = 0`  | RRPV = `MODERATE_INSERT_RRPV = 1` | RRPV = `MAX_RRPV = 7` (SRRIP-FP) |
| Hit promotion     | RRPV = `HOT_HIT_RRPV = 0`     | `RRPV -= 1` (saturate at 0)        | `RRPV -= 1` (saturate at 0)    |
| Aging on miss     | `RRPV += min_RRPV`            | `RRPV += min_RRPV`                  | `RRPV += min_RRPV`             |

`high_reuse` is the OR of all high windows; `moderate_reuse` is the OR
of all moderate windows masked by `~high_reuse`. A window matches when
its `_h != 0`, `_h >= _l`, and the address is in `[_l, _h]`; `_h = 0`
disables that window.

Precedence: if a line's address matches BOTH a high and a moderate
window, the high-region rules win (the `if (high_reuse) ... else if
(moderate_reuse)` chain in `src/GRASP.sv`).

### Multiple windows per class

Set `GRASP_HIGH_REGIONS` / `GRASP_MODERATE_REGIONS` (default 1) to pin
several disjoint buffers. The four runtime ports widen to flattened
packed buses; window `i` lives in bits `[i*ADDR_W +: ADDR_W]`, so an
external register bank maps one address-sized register per window. The
counts thread `l2_top -> l2_cache -> l2_tagbank -> replacement_policy
-> GRASP`. Match is a parallel comparator per window followed by an
OR-reduction, so it stays off the critical path (re-measure WNS for
very large counts). Minimum count is 1; disable individual windows at
runtime by driving their `_h` field to 0.

The high-region path is what makes GRASP useful for graph workloads
— pin the frequent-reuse address ranges to RRPV=0 and the policy
holds them through arbitrary cold thrash.

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

With a **configured** hot region matching the workload's hot pool
(`test_workload.py` drives `grasp_high_addr_l/h` to the hot lines),
`perf.py` (NTXN=5000, `LINES=64 WAYS=4`) measures **GRASP 77.6 %** vs
SRRIP 74.3 %, RANDOM 62.1 %, LRU 56.6 % — GRASP now beats SRRIP. This
case is only effective because of the `policy_addr` real-address fix
(bug #17): before it, the region matched the wrong (compressed) lines
and GRASP collapsed to its SRRIP-FP fallback (~73.7 %).

### Multi-window benefit (`test_grasp_multi_perf.py`)

Directed demonstration of the N-window value proposition: a workload
with `NBUF=4` disjoint hot buffers (one per set), each round preceded by
a same-set conflict storm that evicts anything unpinned, re-referenced
over 8 rounds. Hit-rate measured under three configs (build with
`GRASP_HIGH_REGIONS=4`):

| Config | Hit rate | Note |
|---|---:|---|
| fallback (0 windows)     |   0.0 % | every hot buffer thrashed (SRRIP-FP) |
| single window (buffer 0) |  25.0 % | only 1 of 4 buffers survives (≈ 1/NBUF) |
| **all 4 windows**        | **100.0 %** | every buffer pinned |

`+100 pp` vs fallback and `+75 pp` vs a single window. A single contiguous
window cannot pin 4 disjoint buffers without also pinning the cold span
between them — that is exactly what `GRASP_HIGH_REGIONS=N` enables.

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
predicates land off the critical path (the binding path is the URAM
cascade write input, not the policy).

**N-window cost (measured, Vivado 2025.2, U250 `xcu250-figd2104-2L-e`,
512 KB / 8w / SDP+URAM / GRASP @ 250 MHz, DB_LATENCY=2):**

Post-synth (OOC):

| `GRASP_HIGH_REGIONS = GRASP_MODERATE_REGIONS` | WNS | CLB LUTs | FF / BRAM / URAM |
|---:|---:|---:|---|
| 1 (default) | +0.186 ns | 1543 | 716 / 5 / 16 |
| 2 | +0.186 ns | 1658 | 716 / 5 / 16 |
| 4 | +0.186 ns | 1886 | 716 / 5 / 16 |

Post-route (full PnR, same flow):

| N | WNS | ~Fmax | CLB LUTs |
|---:|---:|---:|---:|
| 1 | +0.104 ns | 256 MHz | 1555 |
| 2 | +0.029 ns | 251 MHz | 1682 |

Post-synth WNS is **identical** at all N — the per-window comparators +
OR-reduction are not on the *logical* critical path (which is the URAM
cascade write input). Post-route, the extra ~127 LUTs for the second
window add a small placement/routing cost (~0.075 ns N=1→2, which
includes placement-seed variance) — **N=2 still closes 250 MHz
(+0.029 ns)**, but the slack margin is finite. Budget for it (re-run the
standard PnR closure) at larger window counts or tighter targets
(300 MHz). FF, BRAM, and URAM are unchanged — the windows are pure
combinational logic. The deployment synth/PnR scripts accept
`GRASP_HIGH_REGIONS` / `GRASP_MODERATE_REGIONS` as generics.

## Verification

### Directed cocotb tests (`test_grasp*.py`)

| Module | Cases | What it exercises |
|---|---:|---|
| `test_grasp.py`             | 5 | hot retention under cold thrash; SRRIP-FP fallback; invalid-region handling; runtime reconfiguration; hot/moderate overlap precedence; cumulative aging under multi-round re-reads |
| `test_grasp_pressure.py`    | 1 | set-aliased thrash; isolates the hot-insert and hot-hit promotion paths |
| `test_grasp_midburst.py`    | 1 | mid-burst region reconfiguration; verifies region ports are sampled per-access |
| `test_grasp_moderate.py`    | 1 | moderate-region 6x hit-promotion + cold-conflict eviction (the test that flushes the `swap_hit_decrement` mutation) |
| `test_grasp_multi.py`       | 5 | **N>1 windows**: two disjoint buffers each pinned by their own high window both survive; a disabled (`_h=0`) window must not match; high+moderate windows coexist; the *top* window slot (index N-1) is effective; all-windows-disabled SRRIP-FP fallback genuinely evicts. Build with `GRASP_HIGH_REGIONS=2 GRASP_MODERATE_REGIONS=2` (the top-slot case scales to larger counts). |
| `test_grasp_multi_perf.py`  | 1 | **multi-window hit-rate demo**: 4 disjoint buffers, fallback 0 % vs single-window 25 % vs 4-window 100 %. Build with `GRASP_HIGH_REGIONS=4`. |

All 13 test cases PASS. The single-window cases run at the deployment
knobs (`DATABANK_SDP=1 DB_LATENCY=3 SDP_WRITE_INPUT_REG=1`); the
multi-window module builds with `GRASP_HIGH_REGIONS=2
GRASP_MODERATE_REGIONS=2`. A config matrix
(`tb/cocotb/grasp_multi_matrix.sh`, 9 cells) re-runs `test_grasp_multi`
across window counts {2/2, 3/2, 4/4, 8/2}, WAYS {2,4,8}, DB latency, and
the SDP+URAM deployment databank — all PASS.

### Mutation testing (`tb/cocotb/mutation_test.sh FILE=src/GRASP.sv`)

7 mutations, **7 / 7 KILLED (100 % score)** — the GRASP entry builds with
`GRASP_HIGH_REGIONS=2 GRASP_MODERATE_REGIONS=2` so the multi-window
OR-reduction is non-trivial:

| Mutation | Killed by |
|---|---|
| `victim_idx_to_zero` (every miss picks way 0) | `test_random` data scoreboard |
| `way_onehot_invert` (multi-hot replacement way) | `$onehot` assertion + scoreboard |
| `swap_hit_decrement` (hit promotion `-=` → `+=`) | `test_grasp_moderate` (the directed 6-hit moderate-region cold-conflict pattern) |
| `swap_hot_insert_to_max` (cold hot-insert at MAX RRPV) | `test_grasp_pressure` round-1 hot pool re-warm |
| `swap_hot_hit_to_max` (hot hit promotion to MAX RRPV) | `test_grasp_pressure` cumulative age across rounds |
| `break_high_or_reduce` (`\|high_hit` → `high_hit[0]`, ignore high windows i>0) | `test_grasp_multi` (buffer pinned by high window 1 wrongly evicted) |
| `break_moderate_or_reduce` (`\|moderate_hit` → `moderate_hit[0]`) | `test_grasp_multi` (buffer pinned by moderate window 1 wrongly evicted) |

The two OR-reduction mutations are equivalent at `GRASP_HIGH_REGIONS=1`
(a 1-bit reduce), which is why the GRASP mutation run forces 2 windows.
One mutation (`drop_moderate_exclusion`) was excluded as a provably
equivalent change — the `if (high_reuse) ... else if (moderate_reuse)`
precedence chain in the eviction path masks the difference.

### Formal proofs (`tb/formal/grasp_formal.sv`)

5 combinational invariants proven via Yosys + SMTBMC (`bmc-grasp` and
`induct-grasp` targets in `tb/formal/Makefile`). The harness is sized
at `HIGH_REGIONS=2 / MODERATE_REGIONS=2` so the proof covers the
multi-window OR-reduction (the single-window case is the `i=0`
specialization):

| Invariant | What it asserts |
|---|---|
| One-hot replacement | `$onehot(cache_replacement_way)` always |
| Replacement-way range | `cache_replacement_way_int < WAYS` |
| One-hot consistency | `cache_replacement_way[cache_replacement_way_int]` always |
| Region exclusion | `!(ref_high_reuse && ref_moderate_reuse)` (any high window wins over any moderate window on overlap) |
| Disabled-region predicates | with every window's `_h` field = 0, neither class matches anything |

All 5 PASS under BMC (combinational logic; BMC alone is sufficient).
The branch's `experiment/verify.sh` gate runs them on every commit
(latest gate: 10 / 10 proofs PASS overall).

## Bug history

| # | Bug | What broke | Fix | Discovered by |
|---:|---|---|---|---|
| 15 | `policy_addr` in `l2_tagbank.sv` was tag-projected, losing the upper `OMITTED_ADDR_W` bits | GRASP region match could never fire for any address ≥ `ADDR_RANGE_L` → silent degradation to plain RRIP-FP | Added `ADDR_BASE` parameter; reconstruct `policy_addr = ADDR_BASE \| {tag, line, 0}` before the policy | hit-rate flat across way sweep (`perf_sweep.py`) |
| 16 | `out_dirty`/`out_tag` always indexed by `policy_replacement_way_int` | CBOM-HIT writeback used wrong way's stale tag (typically tag=0) → mem-AW to wrong address | `evicted_entry = hit ? tb_rdata_r[hit_index] : evict_entry` | `test_cbom_rmw_race.py` adversarial pattern |
| 17 | `policy_addr` zeroed only `LOG2_BLOCK_BYTES` low bits, omitting the `BLOCK_ADDR_W = $clog2(LINE_W)` block-offset bits (sibling of #15) | the reconstructed address was compressed `2^BLOCK_ADDR_W`-fold, so the line index sat at the wrong bit position. Coarse/wide windows still worked, but **tight per-line/per-buffer windows matched the wrong lines** (an adjacent line could alias into a window) | zero `BLOCK_ADDR_W + LOG2_BLOCK_BYTES` low bits so the line index lands at its real address position; `policy_addr` now equals the real line-aligned address | `test_grasp_multi.py` (a disabled window appeared to pin a line in a different set) |

All three fixed on main and verified by the gates above.

## Files

- `src/GRASP.sv` — the policy logic (N-window OR-reduction)
- `src/cache_config.sv` — `policy_t` enum (line 23-28)
- `src/replacement_policy.sv` — dispatcher; threads `GRASP_HIGH_REGIONS` / `GRASP_MODERATE_REGIONS`
- `src/l2_tagbank.sv` — feeds the reconstructed `policy_addr` to the policy
- `src/l2_cache.sv`, `src/l2_top.sv` — widen + forward the region ports/params
- `tb/cocotb/test_grasp*.py` — 6 directed modules (13 cases): `test_grasp`, `test_grasp_pressure`, `test_grasp_midburst`, `test_grasp_moderate`, `test_grasp_multi` (N>1), `test_grasp_multi_perf` (hit-rate demo)
- `tb/cocotb/grasp_multi_matrix.sh` — 9-cell config matrix for the N-window path
- `tb/cocotb/mutation_test.sh` — GRASP entry (7 mutations, built at 2 windows/class)
- `tb/formal/grasp_formal.sv` — formal invariant harness (sized at 2 windows/class)
- `doc/ARCHITECTURE.md` §6 — full policy description and rationale
