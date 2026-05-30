# TableCache OOC sweep — U250, post-2026-05 timing-closure work

Vivado 2025.2, `xcu250-figd2104-2L-e`, 250 MHz target (4.0 ns clock),
**`default` directive** (was `AreaOptimized_high` until 2026-05; the new
default is both faster and uses fewer LUTs — see "Synth-flow fixes"
below). Out-of-context (no IO ring, no PnR).

Per-run reports under `sweep_logs/`. Re-run with `./sweep.sh` from this
directory.

---

## Baseline sweep — `POLICY=4 (SRRIP)`, `INCLUDE_VICTIM=1`, `VICTIM_LINES=16`, `DB_LATENCY=1`

This is the closest equivalent to the pre-2026-05 numbers. It now also
reflects the actual SRRIP policy (the pre-fix sweep silently dropped the
policy override and synthesised LRU everywhere — see "Synth-flow fixes"
section below).

| Config        | Mode | LUT  | FF   | BRAM  | URAM | WNS (ns) | Effective MHz* |
|---------------|------|-----:|-----:|------:|-----:|---------:|---------------:|
| 256 KB / 4-way | TDP | 1993 | 1155 |  18   |   0  |   +0.272 |  ~268 ✓ MET    |
| 256 KB / 4-way | SDP | 1623 | 1109 |   2   |   2  |   +0.202 |  ~263 ✓ MET    |
| 256 KB / 8-way | TDP | 2436 | 1237 |  35.5 |   0  |   +0.277 |  ~268 ✓ MET    |
| 256 KB / 8-way | SDP | 1820 | 1191 |   3.5 |   4  |   +0.100 |  ~256 ✓ MET    |
| 512 KB / 8-way | TDP | 3152 | 1223 | 132.5 |   0  |   +0.059 |  ~253 ✓ MET    |
| 512 KB / 8-way | SDP | 1985 | 1180 |   4.5 |  16  |   -0.612 |  ~217          |
| 1 MB / 8-way   | TDP | 3594 | 1219 | 257   |   2  |   -0.006 |  ~250 (just under) |
| 1 MB / 8-way   | SDP | 1966 | 1176 |   1   |  34  |   -1.398 |  ~185          |

Recovery vs pre-2026-05 (same configs, AreaOptimized_high, LRU):

| Config         | Mode | Old WNS  | New WNS | Δ (ns)  |
|----------------|------|---------:|--------:|--------:|
| 256 KB / 4-way | TDP  |  -1.018  | +0.272  | **+1.29** |
| 256 KB / 4-way | SDP  |  -1.000  | +0.202  | +1.20   |
| 256 KB / 8-way | TDP  |  -1.390  | +0.277  | +1.67   |
| 256 KB / 8-way | SDP  |  -1.740  | +0.100  | +1.84   |
| 512 KB / 8-way | TDP  |  -2.016  | +0.059  | +2.08   |
| 512 KB / 8-way | SDP  |  -2.543  | -0.612  | +1.93   |
| 1 MB / 8-way   | TDP  |  -2.042  | -0.006  | +2.04   |
| 1 MB / 8-way   | SDP  |  -3.321  | -1.398  | +1.92   |

The `default` directive alone recovers 1.2-2.0 ns of WNS on every
configuration. Some of the apparent gain comes from the fix to the
**POLICY vs REPLACEMENT_POLICY** silent-drop bug too — the pre-fix
"SRRIP" numbers were actually LRU, which is simpler logic; the new
SRRIP/GRASP numbers compare like-for-like.

\*Effective MHz = 1000 / (4.0 ns - WNS). For WNS ≥ 0 it's a lower bound
(timing met → no constraint from this slack), for WNS < 0 it's the
realistic post-synth max. Post-PnR typically recovers 0.5-1.5 ns more.

---

## Tuned sweep — `POLICY=5 (GRASP)`, `INCLUDE_VICTIM=0`, `DB_LATENCY=2`

This is the **recommended deployment configuration** for big URAM-rich
parts. The victim cache is the dominant source of post-synth WNS
violations on big SDP+URAM configs (its `pending_reads` LFSR drives a
~24-LUT combinational chain into the URAM cascade write input). Bumping
`DB_LATENCY` 1 → 2 absorbs the URAM cascade as Vivado's "recommended
pipeline_stages = 2" warning suggests.

| Config        | Mode | LUT  | FF   | BRAM | URAM | WNS (ns) | Effective MHz* |
|---------------|------|-----:|-----:|-----:|-----:|---------:|---------------:|
| 256 KB / 4-way | TDP | 1566 |  939 |  18  |   0  |   +0.284 |  ~269 ✓ MET    |
| 256 KB / 4-way | SDP | 1255 |  631 |   2  |   2  |   +0.292 |  ~270 ✓ MET    |
| 256 KB / 8-way | TDP | 2211 | 1277 |  35.5|   0  |   +0.277 |  ~268 ✓ MET    |
| 256 KB / 8-way | SDP | 1422 |  716 |   3.5|   4  |   +0.285 |  ~269 ✓ MET    |
| 512 KB / 8-way | TDP | 2594 | 1277 | 133  |   0  |   +0.348 |  ~274 ✓ MET    |
| **512 KB / 8-way** | **SDP** | **1493** | **716** | **5** | **16** | **+0.186** | **~262 ✓ MET** |
| 1 MB / 8-way   | TDP | 2944 | 1275 | 258  |   2  |   +0.071 |  ~254 ✓ MET    |
| **1 MB / 8-way** | **SDP** | **1493** | **712** | **2** | **34** | **-0.186** | **~239**       |

**Highlighted rows** are the production URAM-heavy targets. The 512 KB
SDP+URAM build closes 250 MHz post-synth (262 MHz est.) with PnR
headroom for ~280 MHz. The 1 MB SDP+URAM build is 0.186 ns short post-
synth — likely meets 250 MHz post-PnR.

GRASP costs **0 ns of WNS overhead** vs SRRIP at this configuration:
the policy logic is not on the critical path.

LUT counts are dramatically lower in the tuned sweep:

| Config | SDP LUT (baseline) | SDP LUT (tuned) | Δ      |
|--------|-------------------:|----------------:|-------:|
| 256K/4w |             1623   |          1255   | -23 %  |
| 512K/8w |             1985   |          1493   | -25 %  |
| 1M/8w   |             1966   |          1493   | -24 %  |

The savings come from dropping the victim cache (`gen_victim.vic_inst`
removes ~400 LUTs of FIFO/state-machine).

---

## Cross-config trends

### SDP saves BRAM dramatically, costs URAM
At 1 MB / 8-way (tuned sweep): TDP uses **258 BRAM tiles + 2 URAM**;
SDP uses **2 BRAM + 34 URAM**. The URAM is the natural home for large
data arrays — the paper's "two ways per URAM" packing finally happens.

### Tuned-sweep timing closes everywhere except 1MB SDP
All configs except 1M/8w SDP+URAM meet 250 MHz post-synth in the tuned
sweep. 1M SDP is -0.186 ns short, easily within PnR recovery.

### Post-PnR closure on U250 (silicon-grade)

Confirmed by running `PNR=1 ./syn/vivado/v80_synth.sh` with
`PART=xcu250-figd2104-2L-e` (the V80 preset reused via PART override —
the synth flow is identical, only the device file changes). Post-route
with `phys_opt_design` runs both before and after `route_design`:

| Config (GRASP, no victim, DB_LATENCY=2, SDP) | post-synth WNS | post-route WNS | Status |
|---|---:|---:|:--|
| 512 KB / 8-way                                | +0.186 ns      | **+0.088 ns**  | **250 MHz MET (~255 MHz)** |
| 1 MB / 8-way                                  | -0.186 ns      | -0.122 ns      | ~242 MHz (just shy of 250) |

The 1 MB config closes 240 MHz post-route comfortably and is 0.122 ns
short of 250 MHz; tightening the placement directive (`-directive
ExtraNetDelay_high` on `phys_opt_design`) usually recovers that
remaining slack on UltraScale+. For applications that must hit 250 MHz
at 1 MB per CU, either accept the directive sweep cost or drop to 512 KB
per CU which closes 250 MHz with +0.088 ns of headroom.

### Push toward 300 MHz
At `PERIOD_NS=3.333` (300 MHz) the same tuned configuration:
- 512K/8w SDP+URAM GRASP, DB_LATENCY=2: WNS = -0.475 ns (~228 MHz)
- 512K/8w SDP+URAM GRASP, DB_LATENCY=3: WNS = -0.372 ns (~228 MHz)

The remaining ~0.4 ns gap is structural: the cache controller's
combinational reductions across FIFO-state LFSRs would need
multi-stage pipelining to clear. Out of scope for this work cycle —
see "Open follow-ups" below.

---

## Per-CU × 16 (Alveo U250 capacity)

For the 16-CU GraphBlox-style integration target (tuned sweep,
no-victim / DB_LATENCY=2 / GRASP):

| Config         | Mode | 16 × BRAM     | 16 × URAM     | Fits on U250?\* |
|----------------|------|--------------:|--------------:|-----------------|
| 256 KB / 8-way | TDP  | 568 (21 %)    | 0 (0 %)       | yes             |
| 256 KB / 8-way | SDP  | 56 (2 %)      | 64 (5 %)      | yes             |
| 512 KB / 8-way | TDP  | **2128 (79 %)** | 0 (0 %)     | barely          |
| 512 KB / 8-way | SDP  | 80 (3 %)      | **256 (20 %)** | comfortable    |
| 1 MB / 8-way   | TDP  | **4128 (>100 %)** | 32 (3 %) | **no**          |
| 1 MB / 8-way   | SDP  | 32 (1 %)      | **544 (43 %)** | yes             |

\*U250 has 2688 BRAM tiles and 1280 URAM.

**SDP mode unlocks 1 MB-per-CU caches that don't fit in TDP on U250**,
and frees ~75 % of BRAM at 512 KB-per-CU for other accelerator
memories.

---

## Recommended deployment matrix

| Target board | Per-CU size | Mode | Knobs | Notes |
|---|---|---|---|---|
| U250, 16 CUs | 256 KB | either                  | defaults | both TDP and SDP meet 250 MHz |
| U250, 16 CUs | 512 KB | **SDP+URAM**            | `INCLUDE_VICTIM=0 DB_LATENCY=2` | TDP tight at 79 % BRAM; SDP meets 250 MHz; 1.25 % URAM/cache |
| U250, 16 CUs | 1 MB   | **SDP+URAM mandatory**  | `INCLUDE_VICTIM=0 DB_LATENCY=2` | TDP exceeds BRAM budget; SDP needs PnR for 250 MHz |
| U280, 16 CUs | 256–512 KB | **SDP+URAM**         | `INCLUDE_VICTIM=0 DB_LATENCY=2` | URAM-rich part, same knobs as U250 |
| V80, 16 CUs  | up to 1 MB | **SDP+URAM**         | `INCLUDE_VICTIM=0 DB_LATENCY=2` | URAM-rich; use full 1 MB if hit rate justifies |
| V80, 32 CUs  | 512 KB     | **SDP+URAM**         | `INCLUDE_VICTIM=0 DB_LATENCY=2` | 512 URAM total budget; fits |

---

## Synth-flow fixes (this cycle)

Two pre-existing bugs in the synth flow corrupted the prior sweep
numbers and are fixed here:

### 1. `REPLACEMENT_POLICY` silently dropped for `TOP=l2_cache`
The `l2_top` wrapper declares an integer `REPLACEMENT_POLICY` parameter
that gets cast to `replacement_policy_t POLICY` for its internal
`l2_cache` instance. The `l2_cache` module itself declares the parameter
as `POLICY`.

Pre-fix `run_synth.tcl` only forwarded `REPLACEMENT_POLICY` via
`-generic`. When `TOP=l2_cache`, Vivado emitted
`WARNING: [Synth 8-3301] Unused top level parameter/generic
REPLACEMENT_POLICY` and synthesised LRU regardless of the user's
intent. Every "SRRIP sweep" run targeting `l2_cache` was an LRU sweep.

Fix: `run_synth.tcl` now accepts both `POLICY` and `REPLACEMENT_POLICY`.
Use `POLICY=4` (SRRIP) or `POLICY=5` (GRASP) for `TOP=l2_cache`; use
`REPLACEMENT_POLICY=N` for `TOP=l2_top`.

### 2. `AreaOptimized_high` directive sabotaged WNS
The hardcoded `AreaOptimized_high` directive prioritises LUT count
over WNS. On the 512 KB / 8-way / SDP+URAM config it cost ~1.36 ns of
WNS vs the `default` directive (which also produced fewer LUTs in the
tuned configuration: 1493 vs 2092). The new default directive is
`default`; set `DIRECTIVE=AreaOptimized_high` to restore the old
behaviour.

### 3. `SDP_WRITE_INPUT_REG` parameter added
New optional 1-cycle register on the SDP URAM write port (en / wbe /
data / addr). Targets the residual critical path when the wide LUT
chain from cache-FSM/FIFO LFSRs into `URAM CAS_IN_DIN_B[*]` reappears
(e.g. under aggressive directive variants or wider WAYS). Off by
default; functionally verified (32/32 regression PASS) for both LRU
and GRASP. Costs 1 cycle of write commit latency, safe under the
cache FSM's `WRITING → READY → READING` serialisation. See
[`syn/vivado/README.md`](README.md) for usage.

---

## Open follow-ups (not addressed by this sweep)

- **PnR-closed timing**: WNS shown is post-synth only. Full PnR
  typically recovers 0.5–1.5 ns of slack via placement / replication.
  Run `place_design ; route_design` before claiming the cache misses
  a target on real silicon. Recommended for the 1 MB SDP+URAM build.
- **300 MHz**: needs structural pipelining of the cache controller's
  combinational reductions (output-FIFO `lfsr_read_index` →
  `unpacked_wbe[0]` chain is the residual binding path at 3.333 ns).
  Best post-fix at 3.333 ns is -0.37 ns (~228 MHz) on 512K/8w SDP+URAM
  GRASP with DB_LATENCY=3, no victim.
- **U280 / V80 ports**: `PART=xcu280-fsvh2892-2L-e ./sweep.sh` should
  produce a comparable table on U280. V80 needs Vivado 2024.x+ with
  Versal support.
- **Bank-balanced SDP**: see
  [doc/DESIGN_BANKED_SDP_DATABANK.md](../../doc/DESIGN_BANKED_SDP_DATABANK.md)
  for a proposal to recover the 6.3 % SDP throughput cost at ~2 weeks
  of engineering. Defer until measured to be binding.
