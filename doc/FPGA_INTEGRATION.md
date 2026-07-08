# FPGA Integration Guide — TableCache

End-to-end checklist for dropping `l2_cache` (plus optional shim and
flush controller) into an FPGA design. Assumes Vivado / Xilinx UltraScale
or 7-series; SystemVerilog 2017; AXI4 / ACE-Lite for snoops.

This document is the **integrator's quick reference**. Architectural
detail lives in [ARCHITECTURE.md](ARCHITECTURE.md); signal-level
contracts live in [INTERFACING.md](INTERFACING.md); the verification
campaign is in [VERIFICATION.md](VERIFICATION.md).

---

## 0. Drop-in copy guide

TableCache RTL lives entirely under [`src/`](../src/) — flat, no
sub-folders, no external `include` paths, no per-file build order
required. Drop the whole folder into your project, point your synthesis
tool at all the `.sv` files, and you're done.

### What to copy

```
your_project/
└── rtl/                       (or whatever you call it)
    └── tablecache/            ← new folder, copy src/*.sv here
        ├── cache_config.sv    ← package; compile FIRST (other files import it)
        ├── l2_cache.sv        ← MAIN MODULE to instantiate
        ├── l2_top.sv          ← thin AXI-port wrapper around l2_cache
        ├── l2_databank.sv     │
        ├── l2_tagbank.sv      │
        ├── l2_hash.sv         │
        ├── replacement_policy.sv │
        ├── LRU.sv             │ pulled in automatically
        ├── SRRIP.sv           │ by l2_cache; no manual
        ├── FRQ.sv             │ instantiation needed
        ├── second_chance.sv   │
        ├── random_replacement.sv │
        ├── rrip_tree.sv       │
        ├── victim_cache.sv    │
        ├── fifo.sv            │
        ├── lfsr.sv            │
        ├── lutram_1w_1r.sv    │
        ├── lutram_1w_mr.sv    │
        ├── sdp_ram.sv         │
        ├── sdp_ram_rst.sv     │
        ├── sdp_ram_padded_rst.sv │
        ├── sdp_ram_uram.sv    ← URAM variant (only used if DATABANK_SDP=1)
        ├── tdp_ram.sv         │
        ├── set_clear_memory.sv │
        ├── toggle_memory.sv   │
        ├── toggle_memory_set.sv │
        ├── one_hot_to_integer.sv │
        ├── tc_narrow_shim.sv  ← OPTIONAL — 4-byte master <-> wide cache
        └── tc_flush_controller.sv ← OPTIONAL — whole-cache flush sequencer
```

29 files, ~5900 lines, MIT-class licence (Apache-2.0 / SHL-2.1 — see
[LICENSE](../LICENSE)).

### Which module do I instantiate?

| Your situation | Instantiate | Notes |
|---|---|---|
| You speak AXI4 with `cache_config::ar_t` / `aw_t` / etc. struct ports natively | **`l2_cache`** | smallest wrapper; struct-typed ports |
| You speak vanilla AXI4 with flat signals (most common) | **`l2_top`** | wraps `l2_cache`, flat AXI4 ports on both slave (`s00_axi_*`) and master (`m00_axi_*`) sides — drop-in compatible with Vivado IP Integrator |
| You have a 32-bit master and want to talk to a wider cache | **`tc_narrow_shim` + `l2_cache`** | shim widens / RMW-promotes, then talks to the cache |
| You need a software-visible "flush everything to memory" | add **`tc_flush_controller`** + a 2:1 arbiter on the cache's slave port | see §2c |

### What you do NOT copy

- `tb/` — testbench, simulator-only
- `doc/` — documentation (this file)
- `syn/` — example Vivado OOC synth scripts (useful as reference but not part of your design)
- `research/` — reference papers (not in the repo)

### Compile order

`cache_config.sv` is a SystemVerilog `package`. Make sure your tool
sees it first. Vivado / Verilator / xsim usually figure this out
automatically from `import cache_config::*;` statements, but if you
get "Module not found" errors for `ar_t` / `aw_t` etc., add an
explicit `-y` / file-list rule that compiles `cache_config.sv` ahead
of the rest.

### No external dependencies

- No external IP — every memory is inferred (BRAM or URAM automatically).
- No `define` files outside the package; everything that needs to be
  user-settable is a module parameter.
- No vendor primitives instantiated directly. The attributes
  (`ram_style`, `cascade_height`, `ramstyle`) are inert on non-Xilinx
  tools and your synthesiser will just ignore them.

### One-time wiring sanity check

After copy + first-time elaboration, confirm in your tool's report:
- `l2_cache` (or `l2_top`) is the top of the cache hierarchy
- `sdp_ram_uram` is **only** elaborated when `DATABANK_SDP=1`
  (otherwise `tdp_ram` is elaborated instead)
- The replacement-policy module matching your `POLICY` parameter
  is elaborated, the others are stripped (generate-based selection)

---

## 1. Decide your configuration

Pin the major parameters before instantiation. Defaults that have
been swept and proven in the cocotb config matrix:

### Cache-shape parameters (these determine total size)

| Param | Meaning | Tested values | Default | Notes |
|---|---|---|---|---|
| `LINES` | Sets per way (must be power of 2) | 32, 64, 128, 256, 512, 1024, 2048 | 512 | More sets = lower conflict-miss rate |
| `WAYS` | Set-associativity | 2, 4, 8 | 4 | More ways = better hit rate, more LUTs |
| `LINE_W` | Blocks (words) per cache line | 4, 8, 16 | 8 | Line size in bytes = `LINE_W × BLOCK_W/8` |
| `BLOCK_W` | Data bus width in bits (= 1 block) | 32, 64, 128 (32 tested by every test) | 32 | Slave + master AXI data width |
| `DB_LATENCY` | Databank RAM read-pipeline depth | 1, 2, 3 | 1 | Bump to 2 if URAM cascade depth >= 8 (see §10.1) |

**Total cache size in bytes** = `WAYS × LINES × LINE_W × (BLOCK_W/8)`.
Example: 8 × 1024 × 16 × 4 = **512 KB** at default 32-bit word, 64-byte
line. Sweep table at [`syn/vivado/sweep_results.md`](../syn/vivado/sweep_results.md).

### Feature toggles

| Param | Meaning | Tested values | Default |
|---|---|---|---|
| `POLICY` | Replacement | `LRU`, `RR` (RANDOM), `SRRIP`, `GRASP`, `2ND` (SECOND_CHANCE), `FRQ`, `RRIP_TREE` | `LRU` |
| `INCLUDE_CBOM` | ACE snoop support (CleanShared/Inval, MakeInval) | 0/1 | 1 |
| `INCLUDE_VICTIM` | Small fully-associative victim cache between L2 and mem | 0/1 | 1 |
| `VICTIM_LINES` | Capacity of the victim cache | 4, 8, 16 | 8 |
| `DATABANK_SDP` | UltraRAM-packed databank (see §10.1) | 0/1 | 0 |
| `READ_ID_WIDTH`, `WRITE_ID_WIDTH` | Slave AXI ID widths | 3-5 | 4 |
| `ADDR_RANGE_L/H` | Bounding address window (NAPOT); base-0 full `[0,0xFFFFFFFF]` supported | 0x80000000-0xFFFFFFFF | per design |

### Recommended configs by use case

| Use case | LINES | WAYS | LINE_W | POLICY | INCLUDE_VICTIM | DATABANK_SDP | Total |
|---|---|---|---|---|---|---|---|
| Single small cache, embedded CPU | 64 | 4 | 8 | `LRU` | 0 | 0 | 8 KB |
| Single mid cache, accelerator | 512 | 4 | 8 | `SRRIP` | 1 | 0 | 64 KB |
| **16-CU graph accelerator on U250** | **1024** | **8** | **16** | **`SRRIP`** | **1** | **1** | **512 KB / CU** |
| Single big cache for streaming graph | 2048 | 8 | 16 | `SRRIP` | 1 | 1 | 1 MB |

Notes:
- `INCLUDE_CBOM=1` is required if you use the flush controller.
- The `(1 << READ_ID_WIDTH) - 1` slave ID is reserved as `FLUSH_ID` /
  `PREFILL_ID` when those features are enabled — do not issue master
  traffic with that ID.
- `BLOCK_W` is the **cache word** and equals the AXI slave data width.
  If your accelerator drives a narrower port (e.g. 32-bit master into
  a 256-bit cache), use the `tc_narrow_shim` adapter (§2b).
- `BLOCK_W` is *also* the master (memory-side) data width. The cache fills a
  line with `LINE_W` beats of `arsize = log2(BLOCK_W/8)` (critical-word-first
  `WRAP` mid-line, else `INCR`). A **wider** backend (e.g. a 512-bit
  HBM/DDR/interconnect) behind a narrower mem port is fine through a standard AXI
  width converter — ordinary AXI, not a corruption source. `tc_narrow_shim` supports
  both `BLOCK_W = NARROW_W` (1:1, `RATIO=1`, e.g. a 32-bit FE straight through — the
  historical odd-4-byte-offset-X bug at this geometry was a shim slice bug, #32, now
  fixed and covered by strict-xsim `tb/vip/tb_shim_ratio1.sv`) and `BLOCK_W > NARROW_W`
  (the shim narrows, e.g. `BLOCK_W=512, NARROW_W=32`, the `test_shim_cache` regime).

## 2. Choose your topology

### 2a. Cache only
```
[ accelerator ]  --AXI4 slave-->  [ l2_cache ]  --AXI4 master-->  [ HBM/DDR/AXI-IC ]
```
Use when your accelerator natively speaks the cache's full BLOCK width.

### 2b. Cache + narrow shim
```
[ narrow master (32b) ]  -->  [ tc_narrow_shim ]  -->  [ l2_cache ]  -->  [ memory ]
```
Use when the accelerator AXI is narrower than the cache block width.
The shim handles RMW for partial writes and prefill for write-miss
promotion (default `PROMOTE_WMISS_TO_RW=0`).

### 2c. Cache + flush controller
```
                       flush_req --> [ tc_flush_controller ]
                                              |
                                              v
[ accelerator ]  --2:1 arb-->  [ l2_cache ]  -->  [ memory ]
```
Drop in when you need a software-visible "flush everything to memory"
button (e.g. before DMA hand-off, before reset of downstream device, or
at the end of a kernel). See INTERFACING.md §11.

### 2d. Full stack
```
[ narrow master ] -> [ shim ] -> [ arb ] -> [ l2_cache ] -> [ memory ]
                                     ^
                                     |
                          [ flush_controller ]
```

## 3. Instantiate in your top-level

```systemverilog
import cache_config::*;   // brings in ar_t, r_t, aw_t, w_t, b_t

logic core_areset_n;       // active-low to AXI; cache wants active-high `rst`
logic rst;
assign rst = ~core_areset_n;

l2_cache #(
    .LINE_W   (8),
    .WAYS     (4),
    .LINES    (64),
    .POLICY   (POLICY_LRU),
    .ID_W     (4),
    .INCLUDE_CBOM(1),
    .INCLUDE_VICTIM(0)
) u_cache (
    .clk(ap_clk), .rst(rst),
    .req_ar(s_ar), .req_arready(s_arready), .req_arid(s_arid),
    .req_r (s_r),  .req_rready (s_rready ), .req_rid (s_rid ), .req_rdata(s_rdata),
    .req_aw(s_aw), .req_awready(s_awready), .req_awid(s_awid),
    .req_w (s_w),  .req_wready (s_wready ), .req_wdata(s_wdata), .req_wstrb(s_wstrb),
    .req_b (s_b),  .req_bready (s_bready ), .req_bid (s_bid ),
    .mem_ar(m_ar), .mem_arready(m_arready), .mem_arid(m_arid),
    .mem_r (m_r),  .mem_rready (m_rready ), .mem_rid (m_rid ), .mem_rdata(m_rdata),
    .mem_aw(m_aw), .mem_awready(m_awready), .mem_awid(m_awid),
    .mem_w (m_w),  .mem_wready (m_wready ), .mem_wdata(m_wdata), .mem_wstrb(m_wstrb),
    .mem_b (m_b),  .mem_bready (m_bready ), .mem_bid (m_bid )
);
```
Reset: cache uses **active-high synchronous `rst`** (single-clock). Hold
for ≥ `8` cycles before deasserting; the SDP RAMs need that to clear
init state.

## 4. AXI compliance for your master

Required:
- `awsize` / `arsize` = log2(NARROW_BYTES) for shim path, or
  log2(BLOCK_BYTES) for direct path.
- INCR or WRAP burst (`burst = 2'b01` / `2'b10`). FIXED is not supported.
- `arlen + 1` beats fit within one cache line (no line-crossing
  bursts).
- WRAP: `arlen+1` must be a power of two and beats must be
  size-aligned.

Recommended:
- Keep `arcache`/`awcache` = `4'b1111` (modifiable, bufferable,
  read-allocate, write-allocate) for best hit rates.
- Use `arid`/`awid` to distinguish independent transactions; the cache
  preserves ordering only **per ID**.

CBOM snoop sideband (only if `INCLUDE_CBOM=1`):
- `arsnoop = 4'b1000` CleanShared (writeback if dirty, keep clean copy)
- `arsnoop = 4'b1001` CleanInvalid (writeback if present, evict — matches ONE tag per set)
- `arsnoop = 4'b1011` CleanInvalidByIndex (clean+invalidate the addressed WAY of a set, ANY tag — used by the whole-cache flush controller)
- `arsnoop = 4'b1101` MakeInvalid (drop without writeback)
- `awsnoop = 3'b101 ` WriteEvict (full-line write that bypasses RMW)

On `l2_top` these are the `s00_axi_arsnoop[3:0]` / `s00_axi_awsnoop[2:0]`
slave ports. They MUST be wired through from your master (and from the
`tc_flush_controller` AR mux) — `l2_top` no longer ties them off. Driving
a CBOM `arsnoop` while `l2_top` was built with `INCLUDE_CBOM=0` (or while
the sideband is tied to 0) silently demotes the CBOM to a plain read,
which on a cold line fetches from memory instead of completing in place —
the classic flush-wedges-in-WAIT_R symptom.

## 5. Memory-side AXI

Standard AXI4 master. Connect to:
- Xilinx MIG / HBM controller
- AXI Interconnect to off-chip DRAM
- AXI-BRAM for on-chip scratchpad (small designs)

The cache issues bursts up to `LINE_W` beats. Make sure the downstream
slave handles that burst length (Xilinx MIG accepts up to 256-beat).

## 6. Reset, clocks, CDC

- TableCache is **single-clock**. Cross domains externally with
  `axi_clock_converter` or your own async FIFO bridges.
- Reset must rise **before** clock starts toggling (or you need a
  separate reset synchroniser). The cocotb TB holds `rst=1` for 8
  cycles after the first clock edge — replicate that on FPGA.
- After `rst` deasserts, wait ≥ `2**ID_W` cycles before the first AXI
  request (the inuse tables initialise lazily). The cocotb TB does this
  implicitly via the AXI master idle period.

## 7. Constraints

- Set a **false-path** between `rst` and any state element you don't
  drive `rst` into directly (none in this design — every flop is reset).
- The SDP RAMs synthesise as **BRAM** (not LUTRAM) on UltraScale because
  they're > 1024 entries with a registered output. Confirm with
  `report_utilization -hierarchical` after synth.
- LUTRAM-backed `lutram_1w_1r` / `lutram_1w_mr` are inferred for small
  associative tables (set_clear_memory, inuse tables).
- The **TDP databank** (default) is **BRAM-only** by primitive
  constraint — UltraRAM cannot service per-byte writes on both ports
  simultaneously. To reach UltraRAM for the data array, enable
  `DATABANK_SDP=1` (see §10.1).

## 8. Bring-up checklist (on-board)

1. **Loopback smoke**: drive a single 1-beat write then 1-beat read at
   the same address from MicroBlaze/Zynq PS. Expect identical data.
2. **Linear burst**: 8-beat write to address 0, 8-beat read back.
   Validates BLOCK<->NARROW packing if shim is present.
3. **Eviction**: write `LINES + 1` distinct lines (any one line per
   set + one extra in same set), read back the first one. Validates
   replacement and eviction-track.
4. **CBOM (if enabled)**: warm a line via read, issue
   `arsnoop=4'b1001` (CleanInvalid), confirm R completes; re-read the
   line and confirm a fresh memory fetch (use ILA on `mem_arvalid`).
5. **Flush (if enabled)**: pulse `flush_req`, wait for `flush_done`,
   confirm `flush_active` deasserts. Count `mem_awvalid` handshakes
   during flush against your expected dirty-line count.

## 9. Debug aids

- **ILA on mem AXI**: `mem_arvalid`, `mem_arid`, `mem_araddr`,
  `mem_rvalid`, `mem_rlast`, `mem_rid` is usually enough to triage
  hangs.
- **`req_arready` low and never rising** typically means the inuse
  tables flagged a stuck (id, line_hash). Check the `inuse_id` and
  `inuse_line` debug `$display` block in [src/l2_cache.sv](../src/l2_cache.sv)
  (enable with `+define+CACHE_DEBUG`).
- **`flush_done` never asserts** with `INCLUDE_CBOM=1`: two common causes.
  (a) Your arbiter is gating the cache's slave-side AR with the flush
  controller's `flush_active` — see
  [tb/cocotb/dut_flush.sv](../tb/cocotb/dut_flush.sv) for a worked 2:1
  priority-arb example. (b) Through `l2_top`, the `s00_axi_arsnoop`
  sideband isn't wired from the flush controller (or `l2_top` was built
  with `INCLUDE_CBOM=0`): the flush CBOMs are demoted to plain reads, each
  cold line issues a bogus `mem_arvalid` line-fetch (`arid==FLUSH_ID`)
  instead of completing in place, and the controller wedges in `WAIT_R`.
  See [tb/cocotb/dut_l2top_flush.sv](../tb/cocotb/dut_l2top_flush.sv) for
  the correct l2_top wiring (`make MODULE=test_l2top_flush`).

## 10. Performance tuning knobs

| Symptom | Try |
|---|---|
| Low hit rate on streaming workload | Increase `WAYS` to 8 or switch `POLICY` to `SRRIP` (see policy benchmark below) |
| Stalls on bursty writes | Increase `WDATA_FIFO_DEPTH` and `AWID_FIFO_DEPTH` |
| Frequent eviction-track full | Increase `FINISH_FIFO_DEPTH` and `REQ_FIFO_DEPTH` |
| Long flush latency | Use `MakeInvalid` (no writebacks) when data is reclaimable |
| Shim AR backpressure | Set `PROMOTE_WMISS_TO_RW=1` (but read INTERFACING.md §10 first) |

### Replacement-policy benchmark

5000-op hot/cold graph-shaped workload (`tb/cocotb/test_workload.py`)
at `LINES=64 WAYS=4 LINE_W=8 SEED=1`, run via
`python3 tb/cocotb/perf.py`:

| Policy | Hit rate | p50 hit (cyc) | p95 hit | p50 miss | p95 miss |
|---|---:|---:|---:|---:|---:|
| **`SRRIP`**          | **74.3%** | 7 | 14 | 8 | 15 |
| `SECOND_CHANCE` | 70.4% | 7 | 14 | 8 | 15 |
| `FRQ`           | 67.2% | 7 | 14 | 8 | 17 |
| `RANDOM`        | 62.1% | 7 | 15 | 8 | 17 |
| `LRU`           | 56.6% | 8 | 15 | 8 | 17 |

Workload assumptions skew toward graph-traversal access patterns
(hot-set + occasional cold misses). For your own workload, rerun
`perf.py` with representative stimulus before committing to a policy.

`SRRIP` is the recommended default for graph-like workloads.
`LRU` remains the default-parameter pick for clarity and lowest area;
upgrade to `SRRIP` if hit rate is the bottleneck.

### 10.1 UltraRAM packing mode (`DATABANK_SDP=1`)

For BRAM-constrained, URAM-rich deployments — typically multi-cache
designs on Alveo U250 / U280 / U55C / Versal V80 — set `DATABANK_SDP=1`
on the `l2_cache` (or `l2_top`) instantiation to map the data array to
UltraRAM instead of BRAM. This is the only way the data bank reaches
UltraRAM; the default (TDP) topology is BRAM-only by primitive
constraint.

```sv
l2_cache #(
    .POLICY         (SRRIP),
    .LINES          (1024),
    .LINE_W         (16),       // 64-byte line at 32-bit word
    .WAYS           (8),
    .BLOCK_W        (32),
    .DB_LATENCY     (2),        // recommended for URAM cascade depth >=8
    .INCLUDE_VICTIM (1),
    .VICTIM_LINES   (16),
    .DATABANK_SDP   (1)         // <-- enable UltraRAM packing
) cache_inst ( ... );
```

What this changes:

| | TDP (`DATABANK_SDP=0`, default) | SDP (`DATABANK_SDP=1`) |
|---|---|---|
| Data array primitive | BRAM via `tdp_ram` | **UltraRAM via `sdp_ram_uram`** |
| Internal databank ports | 2 (true dual-port) | 1 (port 1 of the databank FSM is disabled, all traffic serialised through port 0) |
| Throughput cost | baseline | ~6.3 % slower on graph workloads (`test_workload` 5000 txn) |
| 512 KB / 8-way / 64 B line on U250 | 132 BRAM tiles, 0 URAM, 3194 LUT | 5 BRAM, **16 URAM**, 1919 LUT |
| 1 MB / 8-way on U250 | 258 BRAM, 2 URAM (doesn't fit 16×) | 2 BRAM, **34 URAM** (fits 16×) |
| Recommended `DB_LATENCY` | 1 | **2** for sizes ≥ 512 KB (URAM cascade depth) |
| Slave port AXI behaviour | unchanged | unchanged |
| Verification status | layer 0-7 clean | layer 0-7 clean (100-seed stress + mutation 100 %) |

**When to enable**: multi-cache deployments where the per-CU BRAM
budget binds first. For the 16-CU GraphBlox-style target on U250:

| Per-CU size | TDP (16×)        | SDP (16×)            | Recommendation        |
|-------------|------------------|----------------------|-----------------------|
| 256 KB      | 568 BRAM (21 %) | 64 URAM (5 %)        | either fits           |
| 512 KB      | 2112 BRAM (79 %)| 256 URAM (20 %)      | **SDP** (BRAM tight)  |
| 1 MB        | 4128 BRAM (>100 %, won't fit) | 544 URAM (43 %) | **SDP mandatory** |

For single-cache designs the TDP default is faster and uses BRAM
more naturally — leave `DATABANK_SDP=0`.

**When NOT to enable**:
- Single-cache designs where 6.3 % throughput matters more than freeing
  ~130 BRAM tiles
- FPGA fabrics without UltraRAM (Intel, older Xilinx 7-series)
- Configurations under 128 KB where BRAM auto-inference is already
  efficient and the URAM cascade-depth penalty isn't worth paying

**Verify the URAM inference fires**: after Vivado synth, look in
`utilization.rpt` for a non-zero `URAM` row in section "2. BLOCKRAM".
On U250 with `WAYS=8 LINES=1024 LINE_W=16 DATABANK_SDP=1` you should
see 16 URAMs and ~5 BRAM tiles (the BRAMs are for the tagbank / FIFOs;
the SDP databank is fully URAM). Vivado will also print a
"automatically implemented using URAM" INFO line per inferred
primitive.

For a worked sweep across configs and modes, see
[`syn/vivado/sweep_results.md`](../syn/vivado/sweep_results.md).
For the design history of why this is `DATABANK_SDP=1` and not, say,
`USE_URAM=1`, see `doc/ARCHITECTURE.md` §7.5 bug #14 and the
banked-SDP follow-on proposal in
[`doc/DESIGN_BANKED_SDP_DATABANK.md`](DESIGN_BANKED_SDP_DATABANK.md).

### WAYS × POLICY sweep (smaller workload, NTXN=3000)

Same workload at three associativities (`python3 tb/cocotb/perf_sweep.py`):

| Policy | 2 ways | 4 ways | 8 ways |
|---|---:|---:|---:|
| `LRU` | 44.6% | 55.1% | 77.4% |
| **`SRRIP`** | **46.0%** | **72.1%** | **77.7%** |
| `FRQ` | 44.6% | 66.0% | 75.4% |
| `SECOND_CHANCE` | 45.3% | 64.1% | 65.0% |
| `RANDOM` | 42.7% | 60.8% | 69.3% |

Highlights:
- **`SRRIP` at 4 ways (72.1%) gets within 5pp of `LRU` at 8 ways (77.4%)**
  -- half the associativity area, near-equal hit rate.
- `LRU` benefits the most from going 2→8 ways (+33pp); other policies
  asymptote earlier.
- `SECOND_CHANCE` saturates at 4 ways; adding more ways gains <1pp.
- At 2 ways, policy choice barely matters (43-46% across all five).

### LINES sweep (SRRIP vs LRU)

WAYS=4 LINE_W=8 NTXN=3000:

| LINES | SRRIP hit rate | LRU hit rate |
|---:|---:|---:|
| 32  | 46.0% | 40.2% |
| 64  | **72.1%** | 55.1% |
| 128 | 77.6% | 64.8% |
| 256 | 78.1% | 70.4% |

Two patterns worth noting:
- **`SRRIP` saturates at LINES=128** for this workload (working-set
  fits). Doubling LINES from 128→256 buys only +0.5pp.
- **`LRU` keeps scaling linearly with capacity** (40→55→65→70). It
  needs ~4× more capacity than `SRRIP` to reach the same hit rate:
  `SRRIP@LINES=64 (72.1%) ≈ LRU@LINES=256 (70.4%)`.

Implication: on small-capacity FPGAs, `SRRIP` is significantly more
area-efficient. On large-capacity FPGAs (>=256 lines), the gap shrinks.

## 11. What to expect on Xilinx UltraScale+ (zcu102 ballpark)

`LINE_W=8, WAYS=4, LINES=64, ID_W=4, INCLUDE_CBOM=1, INCLUDE_VICTIM=0`:

| Resource | Estimate |
|---|---|
| LUTs | ~6-8 k |
| FFs | ~5-7 k |
| BRAM18 | 4-8 (tagbank + databank) |
| LUTRAM | 1-2 k |
| Fmax (UltraScale+ -2) | ~300-350 MHz |

Numbers are guidance only. Run your own `report_utilization` and
`report_timing_summary` after place-and-route.
