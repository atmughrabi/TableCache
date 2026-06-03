# Vivado OOC Synthesis

Out-of-context synthesis driver for the TableCache tops. Used to track
post-synth utilization, timing feasibility, and primitive inference
without committing to a full IO ring / shell context.

## Tools
- Vivado 2025.2 (`VIVADO=/opt/xilinx/2025.2/Vivado/bin/vivado` by default)
- Target parts (override with `PART=<name>`):
  - Alveo U250: `xcu250-figd2104-2L-e` (speed grade `-2L`) — the default
  - Alveo U280: `xcu280-fsvh2892-2L-e`
  - Alveo U55C: `xcu55c-fsvh2892-2L-e` — see [`u55c_synth.sh`](u55c_synth.sh)
    for the deployment preset (production silicon; HBM2-backed)
  - Alveo V80: `xcv80-lsva4737-2MHP-e-S` (engineering sample — see
    [`v80_synth.sh`](v80_synth.sh) for the deployment preset, and note
    that the `-S` speed file reports `clock uncertainty = 0.300 ns`
    vs ~0.035 ns on production UltraScale+ parts, costing ~0.25 ns of
    WNS purely from characterisation conservatism)
- Target clock: 250 MHz (`PERIOD_NS=4.0` default; override for other targets)
- Directive: `default` (the `AreaOptimized_high` variant costs ~1.3 ns of
  WNS on the big SDP+URAM databank critical path; set
  `DIRECTIVE=AreaOptimized_high` to opt into it.)

## Usage

```bash
cd syn/vivado

# Default: l2_cache, default parameters
./run_synth.sh

# Pick a different top
TOP=tc_narrow_shim ./run_synth.sh
TOP=tc_flush_controller ./run_synth.sh

# Sweep all three user-facing tops
ALL=1 ./run_synth.sh

# Override RTL parameters (l2_cache / l2_top only)
WAYS=8 LINES=1024 LINE_W=16 POLICY=4 \
    INCLUDE_VICTIM=1 VICTIM_LINES=16 ./run_synth.sh

# Force URAM-packed databank (see "URAM mode" below)
DATABANK_SDP=1 WAYS=8 LINES=1024 LINE_W=16 ./run_synth.sh

# Target 300 MHz with the SDP+URAM databank fix on
PERIOD_NS=3.333 DATABANK_SDP=1 DB_LATENCY=2 SDP_WRITE_INPUT_REG=1 \
    WAYS=8 LINES=1024 LINE_W=16 POLICY=5 INCLUDE_VICTIM=0 ./run_synth.sh
```

Supported env-var parameter overrides:

- `POLICY` — enum index passed to `l2_cache.POLICY`
  (0=LRU, 1=FRQ, 2=SECOND_CHANCE, 3=RANDOM, 4=SRRIP, 5=GRASP).
- `REPLACEMENT_POLICY` — equivalent name for `l2_top` (which has an
  integer wrapper parameter cast to `POLICY` internally). **Setting
  `REPLACEMENT_POLICY` on `TOP=l2_cache` is a no-op** and silently
  defaults to LRU. Use `POLICY` for `l2_cache`.
- `WAYS`, `LINES`, `LINE_W`, `INCLUDE_VICTIM`, `VICTIM_LINES`,
  `DATABANK_SDP`, `DB_LATENCY`, `SDP_WRITE_INPUT_REG`.
- `DIRECTIVE` (default `default`; alternatives `AreaOptimized_high`,
  `PerformanceOptimized`).
- `PERIOD_NS` (default `4.0` ns for 250 MHz; `3.333` for 300 MHz).

## Outputs (per top)
```
build/<TOP>/utilization.rpt        flat resource report
build/<TOP>/utilization_hier.rpt   hierarchical breakdown
build/<TOP>/timing_summary.rpt     WNS/TNS/WHS
build/<TOP>/methodology.rpt
build/<TOP>/synth.log              full stdout (Vivado warnings + INFO)
```

## Headline results on U250 @ 250 MHz target (`default` directive)

### `l2_cache` defaults (4-way / 512 sets / 8-block line, victim cache on, LRU)
| Resource    | Used | %device |
|-------------|------|---------|
| CLB LUTs    | 1681 | 0.10 %  |
| CLB FFs     | 930  | 0.03 %  |
| BRAM tiles  | 18   | 0.67 %  |
| URAM        | 0    | 0.00 %  |

### `l2_cache` 512 KB / 8-way / 16-block line / **GRASP** / **SDP+URAM** databank / no victim / DB_LATENCY=2
| Resource    | Used  | %device |
|-------------|-------|---------|
| CLB LUTs    | 1493  | 0.09 %  |
| CLB FFs     | 716   | 0.02 %  |
| BRAM tiles  | 5     | 0.19 %  |
| **URAM**    | **16**| **1.25 %** |
| **WNS (post-synth)** | **+0.186 ns @ 4.0 ns target (250 MHz met)**     |
| **WNS (post-PnR)**   | **+0.088 ns post-route, ~255 MHz on Alveo U250 silicon**  |

That is the production URAM-deployment config: hits 250 MHz post-synth,
PnR typically recovers another 0.5–1.5 ns of headroom. **GRASP adds 0 ns
of WNS overhead vs SRRIP** (the policy logic is not on the critical path).

### `l2_cache` 1 MB / 8-way / 16-block line / GRASP / SDP+URAM / no victim / DB_LATENCY=2
| Resource    | Used  | %device |
|-------------|-------|---------|
| CLB LUTs    | 1493  | 0.09 %  |
| CLB FFs     | 792   | 0.02 %  |
| BRAM tiles  | 2     | 0.07 %  |
| **URAM**    | **34**| **2.66 %** |
| WNS (post-synth) | -0.101 ns @ 4.0 ns (~243 MHz post-synth) |
| WNS (post-PnR)   | -0.122 ns post-route, ~242 MHz on Alveo U250 silicon |

### `tc_narrow_shim` defaults
| Resource    | Used  | %device |
|-------------|-------|---------|
| CLB LUTs    | 1770  | 0.10 %  |
| CLB FFs     | 1070  | 0.03 %  |
| BRAM tiles  | 0     | 0.00 %  |
| WNS         | +1.936 ns @ 4.0 ns target (250 MHz met)        |

### `tc_flush_controller`
| Resource    | Used  |
|-------------|-------|
| CLB LUTs    | 16    |
| CLB FFs     | 13    |

## URAM mode (`DATABANK_SDP=1`)

By default the data array is a true-dual-port memory with byte-enables
on both ports (`tdp_ram`). Vivado will only ever map that to BRAM
(RAMB36/18) on UltraScale+ parts -- UltraRAM cannot service TDP byte
writes on both ports simultaneously.

To unlock UltraRAM inference, set `DATABANK_SDP=1`. This swaps the
databank for a simple-dual-port (1R+1W) wrapper (`sdp_ram_uram`,
hard-coded `ram_style="ultra"`) and disables the cache's port-1
databank pipeline so the FSM serializes all traffic through port 0.

Trade-off (measured on `test_workload`, 5000 transactions,
512 KB / 8-way / 16-block / SRRIP):

| Mode  | Cycle count | Cycles/txn | Throughput |
|-------|-------------|------------|------------|
| TDP   | 64 250      | 12.85      | baseline   |
| SDP   | 68 284      | 13.66      | -6.3 %     |

For a 16-CU system on U250 the resource arithmetic flips entirely:

| 16 caches    | TDP                    | SDP+URAM            |
|--------------|------------------------|---------------------|
| BRAM tiles   | 2112 / 2688 (79 %)     | **80 / 2688 (3 %)** |
| URAM         | 0 / 1280 (0 %)         | **256 / 1280 (20 %)** |

TDP is BRAM-tight at 16 caches; SDP+URAM leaves headroom for both
primitives, matching the paper's "2 ways per URAM" packing strategy
(thesis §5; release `etd23318.pdf`).

See `doc/ARCHITECTURE.md` §7.5 bug #14 for the design history and
the two failed earlier approaches.

## SDP write-input register (`SDP_WRITE_INPUT_REG=1`)

Optional 1-cycle register on the SDP URAM write port (en / wbe / data /
addr). Targets the post-synth critical path observed on big SDP+URAM
configs under the legacy `AreaOptimized_high` directive: an 18–24 LUT
deep combinational chain from cache-FSM/FIFO control LFSRs into the
URAM cascade write-data input (`CAS_IN_DIN_B[*]`).

- **Latency cost**: writes commit at cycle N+2 instead of N+1.
- **Safety**: the cache FSM transitions WRITING → READY → READING for
  any same-port write/read sequence, which provides a 1-cycle slack
  cycle that absorbs the extra latency. Verified functionally on
  test_smoke / test_random / test_scoreboard / test_workload /
  test_reset_recovery / test_backpressure / test_strobe / test_latency
  × {LRU, GRASP} with `+define+TC_SDP_WRITE_INPUT_REG=1`.
- **WNS impact at 4.0 ns**: ~0 ns under the `default` directive (the
  path is already broken by smarter synth).
- **WNS impact at 3.333 ns (300 MHz)**: +0.070 ns on U55C
  512KB / 8w / GRASP / SDP+URAM. Kept as a knob for any configuration
  where the chain re-emerges (wider WAYS, alternative synthesis tools).

## Tag / data RAM-primitive split

The cache uses different RAM primitives for the tag and data arrays.
This is automatic — set `DATABANK_SDP=1` for URAM-rich deployments
and the topology is:

| Array       | Module                  | Primitive    | Rationale                              |
|-------------|-------------------------|--------------|----------------------------------------|
| **Tag**     | `l2_tagbank.sv`         | **BRAM**     | Small (`LINES × WAYS × ~30b`); auto-inferred by Vivado via `sdp_ram_padded_rst`. Padding aligns to 8/9-bit boundaries to reduce BRAM count. |
| **Data**    | `l2_databank.sv`        | **URAM**     | Large (`LINES × LINE_W × WAYS × BLOCK_W` ≥ 256 KB); forced via `sdp_ram_uram` (hardcoded `ram_style="ultra"`). |
| Output FIFO | `l2_cache.sv`           | LUTRAM       | Small, deep ~16-32 entries. |
| Victim cache (if enabled) | `victim_cache.sv` | LUTRAM | Small fully-associative; LUTs only. |

Measured on U55C `xcu55c-fsvh2892-2L-e`, 512 KB / 8w / SDP+URAM
(see `build/u55c_512K_w8_p5_period4.0_pnr1/utilization_hier.rpt`):

```
tb_inst  (l2_tagbank):  4 × RAMB36E2 + 2 × RAMB18E2 + 0 × URAM   (BRAM)
db_inst  (l2_databank): 0 × RAMB36E2 + 0 × RAMB18E2 + 16 × URAM  (URAM)
```

### Is the hybrid worth it? (all-BRAM vs hybrid vs all-URAM)

Measured side-by-side on U55C 512 KB / 8w / GRASP @ 4 ns target
(post-synth):

| Topology                                | LUT  | BRAM | URAM | WNS (ns) | MHz post-synth | How to reproduce |
|---|---:|---:|---:|---:|---:|---|
| **All-BRAM** (TDP, `DATABANK_SDP=0`)    | 2654 | 133  |   0  | +0.348   | ~273 | `DATABANK_SDP=0 ./u55c_synth.sh` |
| **Hybrid** (BRAM tag + URAM data, SDP=1, default) | 1543 |  5   |  16  | +0.186   | ~262 | `./u55c_synth.sh` |
| All-URAM (force tag → URAM via `ram_style="ultra"` on `sdp_ram`)¹ | 1530 |  0   |  19  | +0.186   | ~262 | source-edit only; not exposed as a knob |

¹ Force-URAM is a one-line experimental hack to `src/sdp_ram.sv`:
adding `, ram_style = "ultra"` to the `(* cascade_height = ... *)`
attribute on line 46. Not shipped as a parameter because URAM is
intrinsically a poor fit for the tag aspect ratio (1024-deep × 240-wide
fills ~16 % of 4 URAM blocks).

**Per-CU device-utilization arithmetic for 32 caches on U55C**
(1936 URAM / 2016 BRAM):

| Topology   | Total LUT | URAM (% of 1936) | BRAM (% of 2016) | Verdict |
|---|---:|---:|---:|---|
| All-BRAM   | 84 928 |   0 ( 0 %)  | **4 256 (211 %)** | ✗ INFEASIBLE — BRAM-bound past ~6 caches |
| **Hybrid** | 49 376 | 512 (26 %)  | **160 (8 %)**     | ✓ comfortable; uses BOTH memory pools |
| All-URAM   | 48 960 | 608 (31 %)  |   0 ( 0 %)        | ✓ works; concentrates pressure on URAM only |

**Recommendation**: hybrid is the default for multi-CU deployments
because it spreads memory pressure across both pools (leaving budget
for other accelerator memories — interconnect FIFOs, scratchpads,
weight tables, etc.). All-URAM is acceptable if BRAM is needed elsewhere
and URAM is plentiful. All-BRAM is only viable for single-cache
designs on BRAM-rich parts (e.g., U250 at 256-512 KB).

The post-synth timing is **identical between hybrid and all-URAM**
(+0.186 ns at 4 ns target on U55C). The LUT/FF count is also within
~1 %. So the choice is purely a question of which memory pool you
want to draw from.

### TDP+BRAM is faster, but doesn't scale

| Mode | LUT  | BRAM | URAM | WNS (4 ns) | MHz | Scales to 32 CUs? |
|---|---:|---:|---:|---:|---:|---|
| SDP+URAM (recommended) | 1543 |   5 | 16 | +0.186 | ~262 | yes |
| TDP+BRAM | 2654 | 133 |  0 | +0.348 | ~273 | **no** (BRAM-bound) |

TDP+BRAM has slightly better post-synth WNS because the BRAM cascade
is shorter than URAM288, but the BRAM budget binds at 16+ caches.
The +0.162 ns of slack is not worth the 27× BRAM expansion.

## 300 MHz push (`PERIOD_NS=3.333`)

The default deployment closes 250 MHz comfortably. Pushing to 300 MHz
needs the knobs below.

### What the knobs change (and what they DON'T)

These are existing-pipeline-depth knobs, not new RTL structure:

| Knob | Default | 300 MHz value | Effect | Functional cost |
|---|---:|---:|---|---|
| `DB_LATENCY` | 2 | **3** | +1 stage on data-bank READ pipeline | Every miss-fill + every data read takes 1 more cycle |
| `SDP_WRITE_INPUT_REG` | 0 | **1** | +1 register on the URAM write port | Writes commit at cycle N+2 instead of N+1; FSM `WRITING → READY → READING` absorbs it |
| `PLACE_DIRECTIVE` | `Default` | `ExtraNetDelay_high` | timing-driven placer | none (PnR-only) |
| `PHYS_DIRECTIVE` | `Default` | `AggressiveExplore` | post-place / post-route opt | none (PnR-only) |
| `ROUTE_DIRECTIVE` | `Default` | `AggressiveExplore` | aggressive route exploration | none (PnR-only) |

No new RTL pipeline stages are added; we use what's already parameterised.
The tag/data BRAM/URAM topology is unchanged — see "Tag/data RAM-primitive
split" above for its breakdown.

### Sweep on U55C (post-synth WNS @ 3.333 ns target)

| `DB_LATENCY` | `SDP_WRITE_INPUT_REG` | WNS @ 3.333 ns | Effective MHz |
|---:|---:|---:|---:|
| 2 | 0 | -0.481 | ~262 |
| 2 | 1 | -0.411 | ~267 (+5 MHz from WIR) |
| 3 | 0 | -0.372 | ~270 (+8 MHz from DBL=3) |
| **3** | **1** | **-0.372** | **~270 (post-synth)** |

At `DB_LATENCY=3 + SDP_WRITE_INPUT_REG=1` the binding path moves from
the databank URAM-input chain (broken by `WIR=1`) to the tagbank
BRAM-enable path: `saved_arvalid` → 13 LUTs → `tb_inst/tagbank BRAM
ENARDEN`. This path is 75 % route-bound at the post-synth stage, so
placement strategy recovers it during PnR.

### Post-route results across all three target boards

```bash
# Use ./u55c_synth.sh with PART= override for portability, or use the
# board-specific wrapper. Same RTL knobs apply.
PERIOD_NS=3.333 DB_LATENCY=3 SDP_WRITE_INPUT_REG=1 \
  PLACE_DIRECTIVE=ExtraNetDelay_high \
  PHYS_DIRECTIVE=AggressiveExplore \
  ROUTE_DIRECTIVE=AggressiveExplore \
  PNR=1 ./u55c_synth.sh
```

| Board | Part | Silicon | LUT  | BRAM | URAM | WNS (ns) | Effective MHz |
|---|---|---|---:|---:|---:|---:|---:|
| **U55C** | `xcu55c-fsvh2892-2L-e`     | production | 1543 | 5 | 16 | **+0.127** | **~312** ✓ |
| **U250** | `xcu250-figd2104-2L-e`     | production | 1567 | 5 | 16 | **+0.064** | **~305** ✓ |
| V80      | `xcv80-lsva4737-2MHP-e-S`  | ES         | 1666 | 5 | 16 | -0.524 | ~287 (clock-uncertainty bound; production silicon should close) |

Both production-silicon UltraScale+ HBM boards close 300 MHz with
margin. V80 misses by ~15 MHz because the ES speed file reports
`clock_uncertainty = 0.300 ns` (vs ~0.035 ns on UltraScale+) — the
same penalty seen at the 250 MHz target. Production V80 silicon
should close 300 MHz cleanly.

Functional regression at the 300 MHz knob combo (`POLICY=GRASP
DB_LATENCY=3 SDP_WRITE_INPUT_REG=1 DATABANK_SDP=1`): test_smoke +
test_random + test_grasp + test_workload all PASS (8 tests / 4
modules).


The PnR run takes ~10–15 minutes on a typical workstation. The
`ExtraNetDelay_high` placement directive and `AggressiveExplore`
route directive together recover ~0.5 ns by placing the
`saved_arvalid` register physically adjacent to the tagbank BRAM
column, reducing the 2.5 ns post-synth routing estimate to <0.5 ns
of actual track delay.



## 8-way deployment matrix (validated)

The cross-board, cross-size, cross-target reference for an 8-way
SDP+URAM/GRASP deployment. All numbers are **post-route** (place +
route + phys_opt), `WAYS=8`, `LINES=1024` (512 KB) or `LINES=2048`
(1 MB), `LINE_W=16`, `BLOCK_W=32`, `POLICY=GRASP`, `INCLUDE_VICTIM=0`,
`DATABANK_SDP=1`. The "tuned" rows add `DB_LATENCY=3 +
SDP_WRITE_INPUT_REG=1 + PLACE/PHYS/ROUTE_DIRECTIVE=ExtraNetDelay_high/
AggressiveExplore/AggressiveExplore`.

### 512 KB / 8-way (LINES=1024 LINE_W=16)

| Board | Silicon | Knobs | Target MHz | LUT | BRAM | URAM | WNS post-route (ns) | Achievable MHz | Status |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| U250    | production | baseline | 250 | 1493 | 5 | 16 | +0.088 |  256 | ✓ MET |
| **U250**| production | **tuned** | **300** | 1567 | 5 | 16 | **+0.064** |  **305** | **✓ MET** |
| U55C    | production | baseline | 250 | 1547 | 5 | 16 | -0.022 |  249 | ✓ (essentially MET; one route reseed closes) |
| **U55C**| production | **tuned** | **300** | 1563 | 5 | 16 | **+0.127** |  **312** | **✓ MET** |
| V80     | ES (-S)    | baseline | 200 | 1516 | 5 | 16 | +0.062 |  203 | ✓ MET |
| V80     | ES (-S)    | tuned   | 250 | 1596 | 5 | 16 | -0.090 |  244 | misses by ~6 MHz |
| V80     | ES (-S)    | tuned   | 300 | 1666 | 5 | 16 | -0.524 |  259 | ES clock-uncertainty bound; production silicon should lift this |

### 1 MB / 8-way (LINES=2048 LINE_W=16)

| Board | Silicon | Knobs | Target MHz | LUT | BRAM | URAM | WNS post-route (ns) | Achievable MHz | Status |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| U250    | production | baseline | 250 | 1493 | 2 | 34 | -0.122 |  243 | misses by ~7 MHz; baseline route reseed expected to close |
| **U250**| production | **tuned** | **300** | 1578 | 2 | 34 | **+0.028** |  **302** | **✓ MET** |
| U55C    | production | tuned    | 300 | 1585 | 2 | 34 | -0.140 |  288 | misses by 12 MHz; the 34-URAM cascade lengthens the critical path |

### Per-cache resource scaling (8-way / SDP+URAM, post-route)

| Cache size | LINES | LINE_W | BRAM | URAM | LUT  | FF  |
|---|---:|---:|---:|---:|---:|---:|
| 256 KB | 512  |  8 |  3 |   4 | ~1255 | ~640 |
| 512 KB | 1024 | 16 |  5 |  16 | ~1547 | ~720 |
| 1 MB   | 2048 | 16 |  2 |  34 | ~1585 | ~800 |
| 2 MB   | 4096 | 16 |  2 |  66 | ~1577 | ~880 |

### Multi-CU deployment arithmetic

| Board | URAM budget | BRAM budget | LUT budget | 8-way / 512 KB × 16 CU | × 32 CU |
|---|---:|---:|---:|---|---|
| U250 | 1280 | 2688 | 1.7 M  |  80 BRAM (3 %) +  256 URAM (20 %) | 160 BRAM (6 %) + **512 URAM (40 %)** |
| U55C | 1936 | 2016 | 1.3 M  |  80 BRAM (4 %) +  256 URAM (13 %) | 160 BRAM (8 %) +  512 URAM (26 %) |
| V80  | 1925 | 3741 | 2.6 M  |  80 BRAM (2 %) +  256 URAM (13 %) | 160 BRAM (4 %) +  512 URAM (27 %) |

| Board | URAM budget | 1 MB × 16 CU | 1 MB × 32 CU | 2 MB × 16 CU |
|---|---:|---|---|---|
| U250 | 1280 |  32 BRAM (1 %) + 544 URAM (43 %) |  64 BRAM (2 %) + **1088 URAM (85 %)** | infeasible (1056 URAM × 2 = 2112) |
| U55C | 1936 |  32 BRAM (2 %) + 544 URAM (28 %) |  64 BRAM (3 %) + 1088 URAM (56 %)  | 32 BRAM (2 %) + 1056 URAM (55 %) |
| V80  | 1925 |  32 BRAM (1 %) + 544 URAM (28 %) |  64 BRAM (2 %) + 1088 URAM (57 %)  | 32 BRAM (1 %) + 1056 URAM (55 %) |

### Recommendation matrix

| If you want | Use this board × config |
|---|---|
| **16-32 CU × 512 KB at 300 MHz**         | U250 or U55C, tuned knobs |
| **16-32 CU × 1 MB at 300 MHz**           | U250 (just MET); U55C (288 MHz; PnR reseed may close) |
| **16 CU × 2 MB at 250 MHz**              | U55C or V80 (production); U250 infeasible at this scale |
| **HBM-backed multi-cache deployment**    | U55C — HBM2 @ 460 GB/s sits behind the L2 array |
| **Production silicon, 300 MHz today**    | U250 |
| **Versal target with production silicon**| V80 production (when AMD ships non-`-S` speed file); ES limits to ~200 MHz |
| **Maximum CU count**                     | V80 (largest LUT + URAM budget); U55C close second |

Reproduce any cell with:

```bash
# 512 KB / 8w / GRASP @ 300 MHz, post-route:
PERIOD_NS=3.333 DB_LATENCY=3 SDP_WRITE_INPUT_REG=1 \
  PLACE_DIRECTIVE=ExtraNetDelay_high \
  PHYS_DIRECTIVE=AggressiveExplore \
  ROUTE_DIRECTIVE=AggressiveExplore \
  PNR=1 ./u55c_synth.sh                       # or ./v80_synth.sh

# 1 MB variant: add SIZE=1M
SIZE=1M PERIOD_NS=3.333 DB_LATENCY=3 SDP_WRITE_INPUT_REG=1 \
  PLACE_DIRECTIVE=ExtraNetDelay_high \
  PHYS_DIRECTIVE=AggressiveExplore \
  ROUTE_DIRECTIVE=AggressiveExplore \
  PNR=1 ./u55c_synth.sh

# Cross-port to U250 (the U55C wrapper accepts PART override)
PART=xcu250-figd2104-2L-e PERIOD_NS=3.333 ... PNR=1 ./u55c_synth.sh
```

### V80 ES at extreme frequencies (1 MB and 2 MB, 300 / 350 MHz targets)

V80 engineering-sample silicon (the `-S` speed file) limits achievable
frequency for the large 1 MB / 2 MB / 8w configs regardless of how
aggressive we push the synth target. Useful as the boundary number
for production-silicon planning.

| Cache | Target MHz | LUT | BRAM | URAM | WNS post-route (ns) | Achievable MHz |
|---|---:|---:|---:|---:|---:|---:|
| 1 MB | 300 (3.333 ns) | 1634 | 2 | 34 | -1.370 | ~213 |
| 1 MB | 350 (2.857 ns) | 1679 | 2 | 34 | -1.584 | ~225 |
| 2 MB | 300 (3.333 ns) | 1769 | 4 | 66 | -1.350 | ~214 |
| 2 MB | 350 (2.857 ns) | 1818 | 4 | 66 | -1.931 | ~209 |

All four with `DB_LATENCY=3 SDP_WRITE_INPUT_REG=1 PLACE/PHYS/
ROUTE_DIRECTIVE=ExtraNetDelay_high/AggressiveExplore/AggressiveExplore`.
Achievable MHz = `1000 / (period - WNS)` so it's the longest-path
period after route, NOT the closed clock.

**Reading the data**: at 1 MB / 8w on V80 ES the design hits the
~213 MHz wall and pushing the target higher just yields larger
negative slack without raising achievable MHz. At 2 MB the 66-URAM
cascade adds enough delay that 350 MHz makes the result strictly
WORSE (~209 MHz) than 300 MHz (~214 MHz) — diminishing returns
from aggressive optimization on a structurally-bound path.

Production V80 silicon should remove the 0.265 ns ES clock-
uncertainty penalty, lifting 1 MB to ~250 MHz and 2 MB to ~230 MHz
(rough projection, not measured). The ~300 MHz wall on V80 1MB+
is a structural URAM-cascade-depth issue that the ES penalty hides
slightly — clearing the penalty exposes the cascade as the next
binding path.

**Conclusion for V80 large-cache deployments**:
- 200 MHz: comfortable today on ES silicon
- 250 MHz: needs production silicon (and likely closes 1 MB)
- 300+ MHz: not achievable on 1 MB / 2 MB without FSM pipelining
  (multi-week structural work)
- Use U250 or U55C if you need 1 MB or 2 MB at 300 MHz today

## V80 (Versal Premium) preset — `v80_synth.sh`

Wraps `run_synth.sh` with the V80 PART and the URAM-deployment knobs
we validated for this target (`POLICY=GRASP`, `INCLUDE_VICTIM=0`,
`DATABANK_SDP=1`, `DB_LATENCY=2`, `DIRECTIVE=default`).

```bash
cd syn/vivado

# 512 KB / 8-way V80 synth (default)
./v80_synth.sh

# 1 MB or 2 MB build
SIZE=1M ./v80_synth.sh
SIZE=2M ./v80_synth.sh

# 300 MHz target (3.333 ns clock)
PERIOD_NS=3.333 ./v80_synth.sh

# Full place + route closure (uses v80_synth_pnr.tcl)
PNR=1 ./v80_synth.sh                  # post-route WNS, ~15-30 min
PNR=1 SIZE=1M ./v80_synth.sh

# SRRIP instead of GRASP
POLICY=4 ./v80_synth.sh
```

**V80 vs U250 headline** (512 KB / 8-way / SDP+URAM / GRASP, post-synth):

| Part | LUT | URAM | Data delay | Clock uncertainty | WNS (4 ns) |
|---|---:|---:|---:|---:|---:|
| U250 (`-2L`)          | 1493 | 16 | 4.872 ns | 0.035 ns | **+0.186 ns** |
| V80 (`-2MHP-e-S` ES)  | 1458 | 16 | **3.528 ns** | **0.300 ns** | -0.321 ns |

V80's combinational logic is actually 1.34 ns faster than U250's (Versal's
`URAM288E5` cascade is shorter than `URAM288`; only 11 LUT levels vs 18).
The post-synth WNS deficit comes entirely from the engineering-sample
silicon's conservative 0.300 ns clock uncertainty — production V80 speed
files will likely cut this to ~0.05 ns. PnR-closed numbers are the
deciding data; run `PNR=1 ./v80_synth.sh` to measure.

**V80 capacity** (`lsva4737`: 1925 URAMs, 3741 BRAM tiles):

| Cache size | URAM / cache | 16 CUs | 32 CUs | V80 budget |
|---|---:|---:|---:|---:|
| 512 KB | 16 |  256 (13 %) |  512 (27 %) | 1925 |
| 1 MB   | 34 |  544 (28 %) | 1088 (57 %) | 1925 |
| 2 MB   | 66 | 1056 (55 %) | --          | 1925 |

## U55C (Alveo HBM, Virtex UltraScale+) preset — `u55c_synth.sh`

Same wrapper pattern as `v80_synth.sh`, with `PART=xcu55c-fsvh2892-2L-e`
(production silicon: 2 SLRs, 1936 URAM blocks, 16 GB HBM2). U55C is a
sister part to U250 in the same UltraScale+ HBM family, so the timing
profile matches U250 closely — the V80 ES clock-uncertainty pessimism
does NOT apply here.

```bash
cd syn/vivado

# 512 KB / 8-way U55C synth (default)
./u55c_synth.sh

# 1 MB or 2 MB build
SIZE=1M ./u55c_synth.sh
SIZE=2M ./u55c_synth.sh

# 300 MHz target (3.333 ns clock)
PERIOD_NS=3.333 ./u55c_synth.sh

# Full place + route closure (uses u55c_synth_pnr.tcl)
PNR=1 ./u55c_synth.sh                  # post-route WNS, ~15-30 min
PNR=1 SIZE=1M ./u55c_synth.sh

# SRRIP instead of GRASP
POLICY=4 ./u55c_synth.sh
```

**U55C headline** (GRASP / DB_LATENCY=2 / default directive, 4 ns clock):

| Cache size | Mode | LUT  | BRAM | URAM | Phase      | WNS (ns) | Effective MHz |
|---|---|---:|---:|---:|---|---:|---:|
| 512 KB / 8-way | **SDP+URAM** | 1543 |   5 | 16 | post-synth | **+0.186** | **~262** ✓ MET |
| 512 KB / 8-way |  SDP+URAM    | 1547 |   5 | 16 | post-route |  -0.022    | ~248 (one reseed closes 250) |
| 512 KB / 8-way |  TDP+BRAM    | 2654 | 133 |  0 | post-synth | **+0.348** | **~273** ✓ MET |
| 1 MB   / 8-way |  SDP+URAM    | 1540 |   2 | 34 | post-synth |  -0.186    | ~238 (PnR pending) |
| 1 MB   / 8-way |  TDP+BRAM    | 3001 | 258 |  2 | post-synth | **+0.071** | **~254** ✓ MET |

**Mode trade-off** (U55C, 1936 URAM / 2016 BRAM, GRASP, 32 caches):

| Cache | Mode | URAM / cache | BRAM / cache | 32-CU URAM | 32-CU BRAM | Verdict |
|---|---|---:|---:|---:|---:|---|
| 512 KB | TDP+BRAM |  0 | 133 |   0 ( 0 %) | 4256 (211 %) | ✗ BRAM-bound |
| 512 KB | SDP+URAM | 16 |   5 | 512 (26 %) |  160 (  8 %) | ✓ fits comfortably |
| 1 MB   | TDP+BRAM |  2 | 258 |  64 ( 3 %) | 8256 (410 %) | ✗ BRAM-bound |
| 1 MB   | SDP+URAM | 34 |   2 | 1088 (56 %) |  64 (  3 %) | ✓ fits |

TDP+BRAM has slightly better post-synth WNS (BRAM cascade is shorter than
URAM288, so the data-bank critical path has fewer LUT levels), but BRAM
budget binds first for any 16+ CU deployment. URAM mode is the only
practical option for multi-cache HBM accelerators; the WNS gap closes
in PnR. Use `DATABANK_SDP=0 ./u55c_synth.sh` to reproduce the BRAM
numbers above.

U55C 512 KB matches U250 to the picosecond on the binding path (both are
xcvu13p-family). The 0.022 ns deficit at post-route is in seed-variance
territory.

**U55C capacity** (`xcu55c-fsvh2892`: 1936 URAMs, 2016 BRAM tiles, 16 GB HBM2 @ 460 GB/s):

| Cache size | URAM / cache | 16 CUs | 32 CUs | U55C budget |
|---|---:|---:|---:|---:|
| 512 KB | 16 |  256 (13 %) |  512 (26 %) | 1936 |
| 1 MB   | 34 |  544 (28 %) | 1088 (56 %) | 1936 |
| 2 MB   | 66 | 1056 (55 %) | --          | 1936 |

The HBM2 backing makes U55C a particularly good target for the L2 cache —
the in-fabric L2 sits in front of high-bandwidth memory that can sustain
the worst-case miss stream without becoming the bottleneck.

## Known issues

### `tdp_ram` UltraRAM rejection
The AMD branch's `tdp_ram.sv` defaulted to `ram_style = "ultra"`.
Vivado synth fails with "Unsupported RAM template" because TDP +
per-byte-enable is not URAM-inferrable. `tdp_ram.sv` hardcodes
`ram_style = "block"` on the TDP path; `#ifdef COCOTB_SIM` selects a
masked single-NBA variant for Verilator.

### Vivado attribute parameter expressions
Vivado synth rejects `(* ram_style = RAM_STYLE *)` even when `RAM_STYLE`
is a string parameter (`Synth 8-281: expression must be of a packed
type`). Workaround: dedicated `sdp_ram_uram` wrapper that hardcodes the
attribute literal. Documented inline in `src/sdp_ram_uram.sv`.

### `DATABANK_PERF` counters in SDP mode
The `DATABANK_PERF` instrumentation counts `en[i]` not `en_gated[i]`.
In SDP mode port 1's FSM still computes en[1]=1 (the gating happens at
the RAM boundary), so the "p1 active" stat overstates port-1 demand.
Conflict-class stats are still meaningful, but the active-cycle
absolute number in SDP mode reflects demand-as-if-TDP, not actual port
usage. The throughput delta is most reliably measured by sim cycle
count, not by the in-RTL counters.

### `REPLACEMENT_POLICY` vs `POLICY`
`l2_cache` declares the parameter as `POLICY` (typed
`replacement_policy_t`); `l2_top` declares an integer
`REPLACEMENT_POLICY` that it casts. Setting `REPLACEMENT_POLICY` when
`TOP=l2_cache` produces `WARNING: [Synth 8-3301] Unused top level
parameter/generic REPLACEMENT_POLICY` and silently falls back to LRU.
`run_synth.tcl` accepts both names; use `POLICY` for `l2_cache`.

### `AreaOptimized_high` directive
The `AreaOptimized_high` directive prioritises LUT count over WNS. On
the 512 KB / 8-way / SDP+URAM config it costs ~1.36 ns of WNS vs the
`default` directive (which also produces fewer LUTs in this case:
1493 vs 2092). `default` is the recommended directive; set
`DIRECTIVE=AreaOptimized_high` to opt into the older behaviour.

## 300 MHz vs 250 MHz throughput comparison (measured)

Reproduce with `tb/cocotb/perf_300mhz.sh` (optional `LINES=N WAYS=N LINE_W=N`
overrides). All numbers from `test_workload` at NTXN=5000 SEED=1; cycles are
the cocotb sim time / `CLK_PERIOD_NS=10`. Throughput translates to the
silicon clock that the synthesis-flow knob combination closes at.

### Deployment config: 512 KB / 8w / SDP+URAM (matches the 312 MHz post-route U55C build)

| Combo | POLICY | cycles | cyc/txn | reads | writes | full_writes | MHz | M txn/s | Δ throughput |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline (DBL=2, WIR=0) | LRU   | 73362 | 14.67 | 3527 | 1473 | 432 | 250 | 17.04 | —      |
| baseline                | GRASP | 73546 | 14.71 | 3527 | 1473 | 432 | 250 | 17.00 | —      |
| **tuned (DBL=3, WIR=1)**| LRU   | 76946 | 15.39 | 3527 | 1473 | 432 | 300 | 19.49 | **+14.4 %** |
| **tuned (DBL=3, WIR=1)**| GRASP | 77124 | 15.42 | 3527 | 1473 | 432 | 300 | 19.45 | **+14.4 %** |

### Medium cache: 16 KB (LINES=64, LINE_W=8, WAYS=4)

| Combo | POLICY | cycles | cyc/txn | MHz | M txn/s | Δ throughput |
|---|---|---:|---:|---:|---:|---:|
| baseline                | LRU   | 62047 | 12.41 | 250 | 20.15 | —      |
| baseline                | GRASP | 57332 | 11.47 | 250 | 21.80 | —      |
| tuned                   | LRU   | 64721 | 12.94 | 300 | 23.18 | **+15.0 %** |
| tuned                   | GRASP | 60533 | 12.11 | 300 | 24.78 | **+13.7 %** |

### Tiny / high-miss cache: 2 KB (LINES=32, LINE_W=8, WAYS=2)

| Combo | POLICY | cycles | cyc/txn | MHz | M txn/s | Δ throughput |
|---|---|---:|---:|---:|---:|---:|
| baseline                | LRU   | 64931 | 12.99 | 250 | 19.25 | —      |
| baseline                | GRASP | 64758 | 12.95 | 250 | 19.30 | —      |
| tuned                   | LRU   | 66614 | 13.32 | 300 | 22.52 | **+17.0 %** |
| tuned                   | GRASP | 66465 | 13.29 | 300 | 22.57 | **+16.9 %** |

### Interpretation

- `DB_LATENCY=3` (+1 cycle on data-bank READ pipeline) adds **0.33–0.72 cyc/txn**
  in measured workloads (3–5 % more cycles).
- The 250 → 300 MHz frequency gain is +20 %.
- Net: **+13.7 % to +17.0 % throughput** across cache sizes / policies tested.
- Counter-intuitive but correct: the **high-miss configuration gains the most**
  because the +1 cycle on the data-bank read pipeline is absorbed into the
  miss-fill cycle (which already waits 10s of cycles for DDR), so the
  proportional overhead shrinks while the frequency gain stays at +20 %.

**Conclusion**: the 300 MHz target is a net win on all measured workloads.
The DB_LATENCY=3 + SDP_WRITE_INPUT_REG=1 knob combination is the recommended
configuration for any deployment where the surrounding AXI infrastructure
runs at 300 MHz.
