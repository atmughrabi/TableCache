# TableCache Interfacing Guide

How to drop `l2_cache` into a design, what to wire on the front and back
ports, and what latency to budget for in your system.

---

## 1. Block diagram

```
                 ┌──────────────────────────────────┐
   master ─AR/R─▶│      Front-end (req_* port)      │─AR/R─▶ memory
   master ─AW/W▶│   AXI4 + ACE snoop sidebands     │─AW/W─▶ memory
   master ◀─B───│           l2_cache                │◀─B──── memory
                 │     (write-back, write-allocate) │
                 └──────────────────────────────────┘
                         clk, rst
```

* **Front end (`req_*`)**: standard AXI4 read/write channels, plus ACE
  `arsnoop` (4-bit) and `awsnoop` (3-bit) sidebands. Drives ONE master.
* **Back end (`mem_*`)**: standard AXI4 (no snoop). Connects to main
  memory, an interconnect, or another cache level.
* Same `clk` for both, single sync reset (`rst`).
* The memory backend must return `OKAY` for R and B responses. TableCache has
  no architectural recovery path for fill or writeback errors; simulation
  assertions reject non-OKAY responses.

---

## 2. Port list

All widths use these parameters: `BLOCK_W` (data, default 32 bits),
`READ_ID_WIDTH` (4), `WRITE_ID_WIDTH` (4).

### Front end – `req_*` (slave, you drive this)

| Channel | Direction | Signal(s) | Width |
|---|---|---|---|
| AR | in/out | `req_ar` (ar_t packed), `req_arid` / `req_arready` | struct / `READ_ID_WIDTH` / 1 |
| R  | out/in | `req_r` (r_t), `req_rdata`, `req_rid` / `req_rready` | struct / `BLOCK_W` / `READ_ID_WIDTH` / 1 |
| AW | in/out | `req_aw` (aw_t), `req_awid` / `req_awready` | struct / `WRITE_ID_WIDTH` / 1 |
| W  | in/out | `req_w` (w_t), `req_wdata`, `req_wstrb` / `req_wready` | struct / `BLOCK_W` / `BLOCK_W/8` / 1 |
| B  | out/in | `req_b` (b_t), `req_bid` / `req_bready` | struct / `WRITE_ID_WIDTH` / 1 |

`ar_t` / `aw_t` definitions are in [src/cache_config.sv](src/cache_config.sv).
Notable embedded fields:
- `ar_t.arsnoop[3:0]` — ACE snoop on reads (CBOM ops).
- `aw_t.awsnoop[2:0]` — ACE snoop on writes (WriteEvict shortcut).
- `r_t.rresp[3:0]`, `b_t.bresp[1:0]` — standard AXI rresp (top 2 bits are
  ACE coherency state, returned as `'0` here).

### GRASP region ports (only meaningful when `POLICY=GRASP`)

| Signal | Direction | Width | Meaning |
|---|---|---|---|
| `grasp_high_addr_l` / `grasp_high_addr_h` | in | `GRASP_HIGH_REGIONS * ADDR_W` | "hot" windows, packed low→high (window `i` = bits `[i*ADDR_W +: ADDR_W]`). Insert/promote at RRPV=0. |
| `grasp_moderate_addr_l` / `grasp_moderate_addr_h` | in | `GRASP_MODERATE_REGIONS * ADDR_W` | "moderate" windows, same packing. Insert at RRPV=1. |

Each window matches a **real, line-aligned bus address** in `[_l, _h]`.
Drive a window's `_h` field to `0` to disable just that window; with
every window disabled GRASP behaves exactly like SRRIP-FP. At the
default counts of 1 these are single `[ADDR_W-1:0]` ports. For any other
policy, tie all four to `0`. See
[doc/wiki/GRASP_Policy.md](wiki/GRASP_Policy.md) for the full spec.

### Back end – `mem_*` (master, you wire to RAM/interconnect)

Same shape as the front end, with **no snoop** (the cache forces
`mem_ar.arsnoop = '0`, `mem_aw.awsnoop = 3'b101` for WriteBack).
IDs are 1 bit wider (`READ_ID_WIDTH+1`, `WRITE_ID_WIDTH+1`) so the cache
can mux read vs. write IDs on the same channel.

---

## 3. AXI restrictions the cache enforces (asserted at boundary)

Violating any of these will fire an `$error` in [l2_cache.sv assertion block](src/l2_cache.sv):

1. **Address in range** `[ADDR_RANGE_L, ADDR_RANGE_H]` (default 0x80000000..0xFFFFFFFF). Range must be NAPOT (a non-NAPOT range fails loudly at elaboration with a clear `$fatal`, rather than silently mis-decoding).
2. **Single-line bursts only** — `arlen < LINE_W` and `awlen < LINE_W`. A request must NOT cross a cache-line boundary.
3. **No fixed bursts** — `arburst`/`awburst` ∈ {INCR=01, WRAP=10}.
4. **Full bus width** — `arsize`/`awsize` = `$clog2(BLOCK_W/8)`. No narrow transactions.
5. **No locks** — `arlock`/`awlock` = 0.
6. **All cacheable** — `arcache`/`awcache` = `4'b1111`.

For INCR bursts you must additionally ensure that `block + len < LINE_W` so the burst fits within the line.

---

## 4. Snoop encodings the cache understands

| `awsnoop` | Name | Meaning to TableCache |
|---|---|---|
| `3'b101` | **WriteEvict** | Full-line update. Skips read fill on miss. **Use whenever you write all bytes of a line.** |
| anything else | regular write | RMW: cache fetches the line first, merges, marks dirty. |

| `arsnoop` | Name | Effect (requires `INCLUDE_CBOM=1`) |
|---|---|---|
| `4'b1000` | CleanShared  | Flush dirty line to mem, KEEP it cached, mark clean. |
| `4'b1001` | CleanInvalid | Flush dirty line to mem, DROP it from cache. Matches by ADDRESS (tag), so it acts on the one line whose tag == `araddr`'s tag in the addressed set. |
| `4'b1101` | MakeInvalid  | DROP line WITHOUT writeback. Dirty data is lost (intentional). |
| `4'b1011` | CleanInvalidByIndex | Clean+invalidate the WAY selected by the low `$clog2(WAYS)` bits of the tag field, regardless of the resident tag (writeback uses the tagbank's STORED tag). Lets a flush clean every physical way of a set; a by-address `CleanInvalid` cannot flush a set-associative cache (it only matches one tag per set). Used by `tc_flush_controller`. |
| anything else | regular read | Normal cache lookup. |

CBOM ops return one R beat with `rdata = 'x` and `rlast = 1`.

---

## 5. Parameters worth knowing

| Param | Default | Effect |
|---|---|---|
| `POLICY` | `LRU` | Replacement policy. Also: FRQ, SECOND_CHANCE, RANDOM, SRRIP, **GRASP** (address-region-aware; see below). |
| `GRASP_HIGH_REGIONS` | 1 | GRASP only: number of independent "hot" address windows (each pins a buffer at RRPV=0). |
| `GRASP_MODERATE_REGIONS` | 1 | GRASP only: number of independent "moderate" address windows (insert at RRPV=1). |
| `LINES` | 512 | Lines per way; must be a power of two and at least 2. |
| `WAYS` | 4 | Set-associativity; any value >=1 is supported (including 3/5-way). |
| `LINE_W` | 8 | Blocks per line; supported values are `{2,4,8,16}` (AXI WRAP beat-count requirement). Line size = `LINE_W * BLOCK_W/8` bytes. |
| `BLOCK_W` | 32 | Data bus width; 8–1024 bits with a power-of-two byte count. |
| `DB_LATENCY` | 1 | Pipeline depth of the data-bank RAMs; supported values are 1–2. |
| `INCLUDE_VICTIM` | 1 | Adds a small fully-associative victim cache between L2 and mem. |
| `VICTIM_LINES` | 8 | Size of the victim cache; any value >=2 is supported. |
| `INCLUDE_CBOM` | 1 | Enables the ACE snoop opcodes above. |
| `READ_ID_WIDTH`, `WRITE_ID_WIDTH` | 4 | Must be equal and >=1. The memory-side ID adds one read/write namespace bit. |
| `ADDR_RANGE_L/H` | 0x80000000 / 0xFFFFFFFF | Bounding address range; must be NAPOT. A base-0 full range `[0, 0xFFFFFFFF]` is supported (the whole 32-bit space is cached; `OMITTED_ADDR_W=0`). |
| `DATABANK_SDP` | 0 | **0** = TDP databank (`tdp_ram`, BRAM only). **1** = SDP+URAM databank (`sdp_ram_uram`, AMD UltraRAM mapping). See §5.1. |
| `N_BANKS` | 1 | SDP bank count; must be a power of two that divides `LINES` (including one line per bank). |
| `CASCADE_DEPTH` | 8 | URAM/BRAM cascade depth, 1–8. |

### 5.1 `DATABANK_SDP` — UltraRAM packing mode

| | TDP (default) | SDP + URAM |
|---|---|---|
| Data-array primitive | `tdp_ram` → BRAM | `sdp_ram_uram` → UltraRAM |
| Storage ports | True dual-port (R/W each) | 1 read + 1 write port; port 1 disabled in FSM |
| 512 KB / 8-way / 64 B line on U250 | 132 BRAM, 0 URAM, 3194 LUT | 5 BRAM, **16 URAM**, 1919 LUT |
| Sustained throughput | baseline | **-6.3 %** (measured on `test_workload`, 5000 txn) |
| 16-cache fit on U250 (2688 BRAM / 1280 URAM) | 2112 BRAM (79 %), 0 URAM | 80 BRAM (3 %), 256 URAM (20 %) |
| Vivado synth target | any UltraScale+ | UltraScale+ with URAM (U250/U280/V80/…) |
| Throughput cost source | n/a | port 1 of the databank is disabled (`port_ready[1] & ~DATABANK_SDP`); all R/W serialise through port 0, so fills and reads cannot overlap |

**When to enable**: multi-cache deployments on URAM-rich parts where
BRAM is the binding constraint (the 16-CU GraphBlox-style scenario was
the original driver). For single-cache designs the TDP default has
better throughput and uses BRAM more naturally.

**Verified**: 9/9 cocotb test modules pass with `DATABANK_SDP=1`
(29/29 tests including the full back-pressure suite). Mutation score
100 % on the SDP gating logic (4/4 effective mutations killed, 2
documented equivalent). Vivado synth (Vivado 2025.2 on
`xcu250-figd2104-2L-e`) infers UltraRAM cleanly with cascade height 8.

**History**: the chosen "disable port 1 entirely" implementation is the
third attempt — two earlier approaches (runtime conflict-stall with
output `ready` gating, then with only data-handshake gating) closed a
combinational loop through the upstream `req_fifo`/`fill_request`
paths in `l2_cache.sv` and caused write-data loss respectively. See
`doc/ARCHITECTURE.md` §7.5 bug #14 for the full failure-modes and
fix rationale.

---

## 6. SystemVerilog instantiation skeleton

```systemverilog
import cache_config::*;

l2_cache #(
    .POLICY         (LRU),
    .LINES          (64),
    .WAYS           (4),
    .LINE_W         (8),
    .BLOCK_W        (32),
    .DB_LATENCY     (1),
    .INCLUDE_VICTIM (1),
    .VICTIM_LINES   (8),
    .INCLUDE_CBOM   (1),
    .READ_ID_WIDTH  (4),
    .WRITE_ID_WIDTH (4),
    .ADDR_RANGE_L   (32'h8000_0000),
    .ADDR_RANGE_H   (32'hFFFF_FFFF)
) u_l2 (
    .clk(clk), .rst(rst),
    // master-side (request port from your CPU/DMA)
    .req_ar (m_ar),  .req_arid (m_arid),  .req_arready (m_arready),
    .req_r  (m_r),   .req_rdata(m_rdata), .req_rid (m_rid),
    .req_rdata(m_rdata), .req_rready(m_rready),
    .req_aw (m_aw),  .req_awid (m_awid),  .req_awready (m_awready),
    .req_w  (m_w),   .req_wdata(m_wdata), .req_wstrb(m_wstrb),
    .req_wready(m_wready),
    .req_b  (m_b),   .req_bid  (m_bid),   .req_bready (m_bready),
    // memory-side (drive DDR / interconnect)
    .mem_ar (s_ar),  .mem_arid (s_arid),  .mem_arready (s_arready),
    .mem_r  (s_r),   .mem_rdata(s_rdata), .mem_rid (s_rid),
    .mem_rready(s_rready),
    .mem_aw (s_aw),  .mem_awid (s_awid),  .mem_awready (s_awready),
    .mem_w  (s_w),   .mem_wdata(s_wdata), .mem_wstrb(s_wstrb),
    .mem_wready(s_wready),
    .mem_b  (s_b),   .mem_bid  (s_bid),   .mem_bready (s_bready)
);
```

A wrapper with **flat AXI signals** (no `ar_t`/`aw_t` structs) is
available in [tb/cocotb/dut_cocotb.sv](tb/cocotb/dut_cocotb.sv) — useful
if your interconnect doesn't speak the packed types.

---

## 7. Latency table (measured)

Default config (`LRU LINES=64 WAYS=4 LINE_W=8 BLOCK_W=32 DB_LATENCY=1 INCLUDE_VICTIM=0`). Cycles are counted from the **handshake** on the request channel to the **first beat** of the response. Memory model in the test has effectively 1-cycle read turnaround; real DDR will shift the miss numbers up by its RTT.

| Operation | Cycles to first response | Cycles to last response |
|---|---|---|
| Read hit (line cached) | **5** | hit returns 1 beat per cycle once started |
| Read miss (8-beat line fill) | **6** (critical-word-first) | **13** (full line) |
| Read miss (1-beat single read, cold) | ~6 | ~6 |
| Full-line WriteEvict, AW→B | **4** | — |
| Partial / RMW single-beat write, AW→B | **2** (B fires when wdata buffered; fill continues async) | — |

Adjustments to make in your budget:
* Each additional `DB_LATENCY` cycle adds **+1** to read hit and read fill.
* Real memory RTT adds to miss latency only (hit unaffected).
* A dirty victim adds `LINE_W + ~3` cycles of mem-side write traffic; the
  master may still see fast response if its read isn't ready-blocked.

Reproduce with:
```bash
cd tb/cocotb && source .venv/bin/activate
make MODULE=test_latency POLICY=LRU DB_LATENCY=1
```

---

## 8. Throughput

| Workload | Sustained throughput |
|---|---|
| Streaming reads, all hits (same line repeatedly) | **1 beat / cycle** on the front-end R channel |
| Streaming reads, all misses, no contention | mem-AR-rate-limited (typically 1 fill burst per `LINE_W + small overhead` cycles) |
| Streaming WriteEvict, hits or misses | **1 W beat / cycle** sustained, B fires every `LINE_W` cycles |
| Mixed RMW writes | Bounded by the RMW path: each write triggers a mem AR (≥ `LINE_W` cycles of mem traffic). Use WriteEvict whenever you cover the full line. |

The internal FIFOs are sized so a single in-flight burst rarely back-pressures the master. The `READ_ID_WIDTH`/`WRITE_ID_WIDTH` limit the **number of unique IDs** in flight — repeating the same ID serializes naturally.

---

## 9. Pipelining / ordering rules

1. The cache supports **multiple outstanding requests** up to `2^READ_ID_WIDTH` reads and `2^WRITE_ID_WIDTH` writes, each with a unique ID.
2. **Same-ID requests are serialized** (the cache blocks a new request whose `arid` or `awid` matches one already in flight).
3. **Same-line requests are serialized** (the cache blocks any new request that hashes to the same line as one in flight, regardless of ID). This avoids data hazards in the data bank.
4. Reads return **in any order across IDs**; within a single ID they are in order (single ID = single in-flight request anyway).
5. Writes return B **in AW-acceptance order** per the AXI ID rule.

---

## 10. Reset

* Active-high synchronous `rst`.
* **Hold for at LEAST `2^ADDR_WIDTH` cycles**, where `ADDR_WIDTH = $clog2(LINES)`. The tag-bank and replacement-policy storage (`sdp_ram_rst`) use an LFSR-driven reset that walks every entry; under-resetting leaves uninitialized lines that silently corrupt the LRU WAYS>4 path (the `INIT_POLICY` is non-zero there).
  * `LINES=128` → ≥128 cycles. `LINES=2048` → ≥2048 cycles.
  * **Recommended floor: 4096 cycles**, which covers every `LINES` value the cache supports. The bundled cocotb harness uses 4096.
  * The `sdp_ram_rst.sv` header comment says `$clog2(ADDR_WIDTH)` cycles — that comment is incorrect; trust this section.
* All in-flight state is dropped. Memory contents survive.
* Mid-burst reset is **not verified** by the current testbench.

---

## 11. Connecting to common back-ends

### Xilinx AXI4 SmartConnect / interconnect
`mem_*` is standard AXI4. Strip the snoop signals (the cache drives
`mem_ar.arsnoop = '0`, `mem_aw.awsnoop = 3'b101`). ID width is
`READ_ID_WIDTH+1` and `WRITE_ID_WIDTH+1`; the interconnect must allow at
least that many in-flight transactions.

### DDR controller via AXI
Wire `mem_*` to the DDR controller's S_AXI port. Set
`ADDR_RANGE_L/H` to the DDR address window. The cache's WRAP bursts will
need to be supported by the controller (most modern controllers do).

### Local BRAM / scratchpad
Use `cocotbext-axi`'s `AxiRam` (Python) or any simple AXI memory model
in SV. Mask high address bits if the local memory window is smaller than
the cache's address range — see [tb/cocotb/dut_cocotb.sv](tb/cocotb/dut_cocotb.sv)
which uses `MEM_MASK = 32'h000F_FFFF` for a 1 MiB shadow.

### Caveat for AXI memories
The cache uses **WRAP bursts** on mem-AR when starting block is non-zero
(critical-word-first fill). Your memory MUST honor WRAP semantics. The
bundled SV test memory model historically did not, leading to bug #5;
see [tb/common/axi_mem_model.sv](tb/common/axi_mem_model.sv) for a
correct WRAP implementation.

### Whole-cache flush controller ([`src/tc_flush_controller.sv`](../src/tc_flush_controller.sv))

> **Status: working.** Validated by
> [tb/cocotb/test_flush.py](../tb/cocotb/test_flush.py) (7 tests, all
> PASS), including `test_flush_cold_cache` (flushes an unwarmed cache: 0
> mem ARs, 0 mem AWs), `test_flush_multitag_all_ways` and
> `test_flush_scattered_multitag` (dirty every way of a set at high/
> scattered tags — writeback + invalidation enforced).

Optional drop-in sequencer that walks every physical line (`LINES × WAYS`)
of the cache and issues a single-beat CBOM per line. Use when the
accelerator needs an atomic "drain everything to memory" handshake rather
than per-line snoops.

**Default snoop is `CleanInvalidByIndex` (`4'b1011`).** For each line the
sequencer presents `araddr = ADDR_BASE + line_idx * LINE_STRIDE`, where
`line_idx` encodes `{way, set}`: the set index lands in the address set
bits and the way rides the tag position. The cache cleans+invalidates that
physical WAY of that SET regardless of the resident tag, so dirty lines
with ANY tag are written back and dropped.

> **Why not plain `CleanInvalid` (`4'b1001`)?** A by-address CBOM matches a
> single `(set, tag)`. Sweeping addresses only ever presents tags
> `0 .. (walk/num_sets − 1)`, so dirty lines whose tag falls outside that
> range are never written back or invalidated — a by-address sweep cannot
> flush a set-associative cache. `flush_mode = 4'b1001` remains available
> for a targeted per-tag clean, but is NOT a whole-cache flush.

Ports and params:

| Signal / param | Direction | Description |
|---|---|---|
| `LINES` / `WAYS` params | — | sets and associativity; the controller walks `LINES × WAYS` lines |
| `DEFAULT_MODE[3:0]` param | — | snoop when `flush_mode==0`; defaults to `4'b1011` (CleanInvalidByIndex) |
| `flush_req` | input | single-cycle pulse to start |
| `flush_mode[3:0]` | input | overrides `DEFAULT_MODE`; `0` keeps default. `4'b1011` (whole-set, all tags), `4'b1101` (MakeInvalid, no writeback), or `4'b1001`/`4'b1000` (per-tag). |
| `flush_active` | output | high from `flush_req` until the last R beat drains |
| `flush_done` | output | single-cycle pulse on completion |

Reserved ID: `FLUSH_ID = (1<<ID_W)-1`. The accelerator must not issue
this ID while `flush_active=1`. (The narrow-port shim already reserves
the same ID for its own prefill traffic.)

Integration with the cache requires a 2:1 priority mux on the cache's
slave port:

```sv
// Pseudocode -- see tb/cocotb/dut_flush.sv for a working version
tc_flush_controller #(
    .LINES(LINES), .WAYS(WAYS),   // walks LINES*WAYS lines; WAYS defaults to 1
    .LINE_W(LINE_W), .BLOCK_W(BLOCK_W), .ID_W(ID_W), .ADDR_BASE(ADDR_RANGE_L)
    // DEFAULT_MODE defaults to 4'b1011 (CleanInvalidByIndex)
) flush_ctrl (
    .clk(clk), .rst(rst),
    .flush_req(flush_req), .flush_mode(flush_mode),
    .flush_active(flush_active), .flush_done(flush_done),
    .m_ar(flush_ar), .m_arid(flush_arid), .m_arready(flush_arready),
    .m_r(flush_r), .m_rid(flush_rid), .m_rdata(flush_rdata),
    .m_rready(flush_rready)
);

// AR mux: flush has priority
assign cache_ar     = flush_active ? flush_ar     : acc_ar;
assign cache_arid   = flush_active ? flush_arid   : acc_arid;
assign acc_arready  = flush_active ? 1'b0         : cache_arready;
assign flush_arready= flush_active ? cache_arready: 1'b0;

// R demux by id: FLUSH_ID -> controller, else -> accelerator
assign flush_rready = (cache_rid == FLUSH_ID) ? acc_rready_or_1 : 1'b0;
assign acc_rready_visible = (cache_rid != FLUSH_ID) & cache_rvalid;

// AW gated during flush so no new writes land mid-sweep
assign cache_aw.awvalid = acc_aw.awvalid & ~flush_active;
assign acc_awready      = cache_awready  & ~flush_active;
```

Estimated latency: ~`LINES * (DB_LATENCY + 4)` cycles for a fully-empty
cache, plus the mem writeback time for every dirty line. Default
config (LINES=64, DB_LATENCY=1) flushes a fully-dirty cache in ~5000-
10000 cycles depending on mem latency.

---

## 12. What is verified / not verified

See [VERIFICATION.md](VERIFICATION.md) for supported matrices, stress tests,
formal proofs, strict xsim coverage, synthesis checks, and residual gaps.

---

## 13. Narrow-port shim ([`src/tc_narrow_shim.sv`](../src/tc_narrow_shim.sv))

Drop-in AXI4 wrapper so a narrow accelerator (`NARROW_W` bits, e.g. 32)
can drive a wide TableCache instance (`BLOCK_W` bits, e.g. 512) without
hand-rolling a width converter.

### 13.1 Topology

```
 accel (NARROW_W) ─► tc_narrow_shim ─► TableCache (BLOCK_W) ─► DDR/HBM
                          │
                          ├─ L0 line buffer (1 wide line, fully associative)
                          ├─ AW→W ordered FIFO (depth = MAX_OUTSTANDING_W)
                          └─ per-id outstanding-AR tracker
```

### 13.2 Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `NARROW_W` | 32 | accelerator data width (bits) |
| `BLOCK_W`  | 512 | cache data width (bits); must be a power-of-two multiple of `NARROW_W` |
| `ID_W`     | 4 | AXI id width on both ports |
| `ADDR_W`   | 32 | address width |
| `MAX_OUTSTANDING_W` | 16 | depth of AW→W FIFO; should match `2^WRITE_ID_WIDTH` at the cache |
| `ENABLE_LINE_BUFFER` | 1 | set 0 to disable the L0 line buffer (every narrow request becomes a wide round-trip) |

### 13.3 Narrow-side request contract (asserted)

* `arlen = awlen = 0` (single beat only).
* `arsize = awsize = log2(NARROW_W/8)`.
* `araddr`/`awaddr` aligned to `NARROW_W/8`.
* For full-line WriteEvict you **cannot** use the shim — the narrow port
  can never claim full-line coverage. `awsnoop = 3'b101` is rewritten to
  `3'b000` on the way out (cache will RMW). If you need WriteEvict, route
  it through a separate wide path.

### 13.4 What the shim does to each transaction

| Phase | Action |
|---|---|
| Narrow AR | If buffer-hit: serve from `lb_data` in 1 cycle, no wide AR. Else align to `BLOCK_W` boundary and issue single-beat wide AR. Capture `{lane offset, aligned addr}` per id. |
| Wide R | Slice the requested narrow word with the latched offset for that rid; fill the line buffer with the full wide beat (skipped for CBOM responses, whose data is `'x`). |
| Narrow AW | Align to `BLOCK_W`, push `{lane offset, aligned addr}` into the FIFO, issue single-beat wide AW. |
| Narrow W | Place narrow data in the FIFO-selected lane, zero elsewhere; drive `wstrb` for only the requested bytes (cache then does the byte-merge RMW). |
| Wide W | Same beat as narrow W. If the FIFO-stored aligned addr matches the current `lb_tag`, merge the bytes into `lb_data` in place. |
| CBOM AR | Always sent to cache; invalidates the line buffer if the aligned tag matches. |

### 13.5 Latency / throughput (measured against `AxiRam`)

| Operation | Cycles (round-trip, one in-flight) |
|---|---|
| Cold narrow read (miss → wide AR → wide R → slice) | **4** |
| Hot narrow read (buffer hit) | **3** observed; combinational mux + 1 cycle R = **1 beat/cycle when pipelined** |
| Narrow write (AW + W + B through `AxiRam`) | **5** |
| Merged read (read after write to same lane in buffer) | **3** (no wide re-fetch) |

Pipelined throughput proof: 16 ARs to one line completed in 18 cycles
(`tb/cocotb/test_shim_throughput.py`).

Real `l2_cache` + DDR will add the cache hit/miss latency table from
§7 to the cold path; the hot/merge paths remain shim-local and unchanged.

### 13.6 Wiring example

```systemverilog
tc_narrow_shim #(
    .NARROW_W(32), .BLOCK_W(512), .ID_W(4),
    .MAX_OUTSTANDING_W(16), .ENABLE_LINE_BUFFER(1'b1)
) u_shim (
    .clk(clk), .rst(rst),
    // accel <-> shim (narrow)
    .s_araddr(acc_araddr), .s_arlen(acc_arlen), .s_arsize(acc_arsize),
    .s_arburst(acc_arburst), .s_arsnoop(acc_arsnoop), .s_arid(acc_arid),
    .s_arvalid(acc_arvalid), .s_arready(acc_arready),
    .s_rdata(acc_rdata), .s_rresp(acc_rresp), .s_rlast(acc_rlast),
    .s_rid(acc_rid), .s_rvalid(acc_rvalid), .s_rready(acc_rready),
    .s_awaddr(acc_awaddr), .s_awlen(acc_awlen), .s_awsize(acc_awsize),
    .s_awburst(acc_awburst), .s_awsnoop(acc_awsnoop), .s_awid(acc_awid),
    .s_awvalid(acc_awvalid), .s_awready(acc_awready),
    .s_wdata(acc_wdata), .s_wstrb(acc_wstrb), .s_wlast(acc_wlast),
    .s_wvalid(acc_wvalid), .s_wready(acc_wready),
    .s_bresp(acc_bresp), .s_bid(acc_bid),
    .s_bvalid(acc_bvalid), .s_bready(acc_bready),
    // shim <-> cache (wide)
    .m_araddr(c_araddr), /* ... */ .m_bready(c_bready)
);
```

### 13.7 Tests

* `tb/cocotb/test_narrow_shim.py` — 10 directed + random campaign (50 000-op heavy random).
* `tb/cocotb/test_shim_latency.py` — per-operation cycle counts.
* `tb/cocotb/test_shim_throughput.py` — hand-driven AR pump proving 1 beat/cycle steady state.

Run with `cd tb/cocotb && make MODULE=test_narrow_shim` (or `test_shim_latency` / `test_shim_throughput`).
