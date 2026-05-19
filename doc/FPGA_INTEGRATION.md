# FPGA Integration Guide — TableCache

End-to-end checklist for dropping `l2_cache` (plus optional shim and
flush controller) into an FPGA design. Assumes Vivado / Xilinx UltraScale
or 7-series; SystemVerilog 2017; AXI4 / ACE-Lite for snoops.

This document is the **integrator's quick reference**. Architectural
detail lives in [ARCHITECTURE.md](ARCHITECTURE.md); signal-level
contracts live in [INTERFACING.md](INTERFACING.md); the verification
campaign is in [VERIFICATION.md](VERIFICATION.md).

---

## 1. Decide your configuration

Pin the four major parameters before instantiation. Defaults that have
been swept and proven in the cocotb config matrix:

| Param | Meaning | Tested values | Default |
|---|---|---|---|
| `LINE_W` | Beats per cache line (block size = LINE_W × NARROW) | 4, 8, 16 | 8 |
| `WAYS` | Associativity | 2, 4, 8 | 4 |
| `LINES` | Sets (must be `2**LINE_BITS`) | 32, 64, 128, 256 | 64 |
| `POLICY` | Replacement | `LRU`, `RR`, `SRRIP`, `2ND`, `RRIP_TREE` | `LRU` |
| `ID_W` | AXI ID width (slave side) | 3-5 | 4 |
| `INCLUDE_CBOM` | ACE snoop support (CleanShared/Inval, MakeInval) | 0/1 | 1 |
| `INCLUDE_VICTIM` | Victim-cache layer | 0/1 | 0 |

Notes:
- `INCLUDE_CBOM=1` is required if you use the flush controller.
- The `(1 << ID_W) - 1` slave ID is reserved as `FLUSH_ID` / `PREFILL_ID`
  when those features are enabled — do not issue master traffic with
  that ID.

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
- `arsnoop = 4'b1001` CleanInvalid (writeback if present, evict)
- `arsnoop = 4'b1101` MakeInvalid (drop without writeback)
- `awsnoop = 3'b101 ` WriteEvict (full-line write that bypasses RMW)

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
- **`flush_done` never asserts** with `INCLUDE_CBOM=1`: confirm your
  arbiter isn't gating the cache's slave-side AR with the flush
  controller's `flush_active`. See
  [tb/cocotb/dut_flush.sv](../tb/cocotb/dut_flush.sv) for a worked
  2:1 priority-arb example.

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
