# TableCache Interfacing Guide

Interface, parameter, timing, and integration requirements for `l2_cache`.

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

### Front end – `req_*` (slave-facing)

| Channel | Direction | Signal(s) | Width |
|---|---|---|---|
| AR | in/out | `req_ar` (ar_t packed), `req_arid` / `req_arready` | struct / `READ_ID_WIDTH` / 1 |
| R  | out/in | `req_r` (r_t), `req_rdata`, `req_rid` / `req_rready` | struct / `BLOCK_W` / `READ_ID_WIDTH` / 1 |
| AW | in/out | `req_aw` (aw_t), `req_awid` / `req_awready` | struct / `WRITE_ID_WIDTH` / 1 |
| W  | in/out | `req_w` (w_t), `req_wdata`, `req_wstrb` / `req_wready` | struct / `BLOCK_W` / `BLOCK_W/8` / 1 |
| B  | out/in | `req_b` (b_t), `req_bid` / `req_bready` | struct / `WRITE_ID_WIDTH` / 1 |

`ar_t` / `aw_t` definitions are in [src/cache_config.sv](../src/cache_config.sv).
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
An `_h` field of `0` disables that window; with
every window disabled GRASP behaves exactly like SRRIP-FP. At the
default counts of 1 these are single `[ADDR_W-1:0]` ports. For any other
policy, tie all four to `0`. See
[doc/wiki/GRASP_Policy.md](wiki/GRASP_Policy.md) for the full spec.

### Back end – `mem_*` (master-facing)

Same shape as the front end, with **no snoop** (the cache forces
`mem_ar.arsnoop = '0`, `mem_aw.awsnoop = 3'b101` for WriteBack).
IDs are 1 bit wider (`READ_ID_WIDTH+1`, `WRITE_ID_WIDTH+1`) so the cache
can mux read vs. write IDs on the same channel.

---

## 3. AXI restrictions the cache enforces (asserted at boundary)

Violating any of these fires an `$error` in the
[l2_cache.sv assertion block](../src/l2_cache.sv):

1. **Address in range** `[ADDR_RANGE_L, ADDR_RANGE_H]` (default 0x80000000..0xFFFFFFFF). Range must be NAPOT (a non-NAPOT range fails loudly at elaboration with a clear `$fatal`, rather than silently mis-decoding).
2. **Single-line bursts only** — `arlen < LINE_W` and `awlen < LINE_W`. A request must NOT cross a cache-line boundary.
3. **No fixed bursts** — `arburst`/`awburst` ∈ {INCR=01, WRAP=10}.
4. **Full bus width** — `arsize`/`awsize` = `$clog2(BLOCK_W/8)`. No narrow transactions.
5. **No locks** — `arlock`/`awlock` = 0.
6. **All cacheable** — `arcache`/`awcache` = `4'b1111`.

For INCR bursts, `block + len < LINE_W` is also required.

---

## 4. Snoop encodings the cache understands

| `awsnoop` | Name | Meaning to TableCache |
|---|---|---|
| `3'b101` | **WriteEvict** | Full-line update. Skips read fill on miss. Use for complete-line writes. |
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
| `LINES` | 512 | Lines per way; power of two in the range 2–65,536. |
| `WAYS` | 4 | Set-associativity; any value >=1 is supported (including 3/5-way). |
| `LINE_W` | 8 | Blocks per line; supported values are `{2,4,8,16}` (AXI WRAP beat-count requirement). Line size = `LINE_W * BLOCK_W/8` bytes. |
| `BLOCK_W` | 32 | Data bus width; 8–1024 bits with a power-of-two byte count. |
| `DB_LATENCY` | 1 | Pipeline depth of the data-bank RAMs; supported values are 1–2. |
| `INCLUDE_VICTIM` | 1 | Adds a small fully-associative victim cache between L2 and mem. |
| `VICTIM_LINES` | 8 | Size of the victim cache; any value >=2 is supported. |
| `INCLUDE_CBOM` | 1 | Enables the ACE snoop opcodes above. |
| `READ_ID_WIDTH`, `WRITE_ID_WIDTH` | 4 | Must be equal and in the range 1–15. The memory-side ID adds one read/write namespace bit. |
| `ADDR_W` | 32 | Meaningful AXI address bits; supported range is 32–64, subject to the cache geometry leaving at least one tag bit. |
| `ADDR_RANGE_L/H` | 0x80000000 / 0xFFFFFFFF | Bounding address range; must be NAPOT and fit in `ADDR_W`. Base-0 full-width ranges are supported, including `[0, 0xFFFFFFFFFFFFFFFF]` at `ADDR_W=64`. |
| `DATABANK_SDP` | 0 | **0** = TDP databank (`tdp_ram`, BRAM only). **1** = SDP+URAM databank (`sdp_ram_uram`, AMD UltraRAM mapping). See §5.1. |
| `N_BANKS` | 1 | SDP bank count; must be a power of two that divides `LINES` (including one line per bank). |
| `CASCADE_DEPTH` | 8 | URAM/BRAM cascade depth, 1–8. |

### 5.1 `DATABANK_SDP` — UltraRAM packing mode

| | TDP (default) | SDP + URAM |
|---|---|---|
| Data-array primitive | `tdp_ram` → BRAM | `sdp_ram_uram` → UltraRAM |
| Storage ports | True dual-port (R/W each) | 1 read + 1 write port; port 1 disabled in FSM |
| Concurrency | two databank ports | requests serialize through port 0 |
| Primary use | maximum databank concurrency | reduced BRAM pressure |

Use SDP mode when replicated caches make BRAM capacity the limiting resource.
Use TDP mode when databank concurrency is more important. Banking and cascade
controls are described in [wiki/URAM_Mode.md](wiki/URAM_Mode.md).

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
    // request-side master
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

A flat-signal reference wrapper is available in
[tb/cocotb/dut_cocotb.sv](../tb/cocotb/dut_cocotb.sv).

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

Latency budget adjustments:
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
| Mixed RMW writes | Bounded by the RMW path: each write triggers a mem AR (≥ `LINE_W` cycles of mem traffic). Complete-line writes should use WriteEvict. |

The internal FIFOs are sized so a single in-flight burst rarely back-pressures
the master. ID widths determine the available ID namespace.

---

## 9. Pipelining / ordering rules

1. The cache supports multiple outstanding requests across the configured ID
   namespace.
2. **Same-ID execution is serialized**, but the slave boundary may have up to
   four accepted reads or two accepted writes per ID before applying
   backpressure. Responses remain ordered within each ID.
3. **Same-line requests are serialized** (the cache blocks any new request that hashes to the same line as one in flight, regardless of ID). This avoids data hazards in the data bank.
4. Reads may return in any order across IDs and remain ordered within one ID.
5. Writes return B **in AW-acceptance order** per the AXI ID rule.

---

## 10. Reset

* Active-high synchronous `rst`.
* Hold reset for at least
  `max(LINES, 2**(max(READ_ID_WIDTH,WRITE_ID_WIDTH)+1))` cycles. Line metadata and occupancy
  tables use LFSR-driven reset walks; shorter resets leave entries uncleared.
* The cocotb harness applies a two-times margin to this minimum.
* All in-flight state is dropped. Memory contents survive.
* `test_reset_recovery.py` covers reset during active read and write traffic.

---

## 11. Connecting to common back-ends

### Xilinx AXI4 SmartConnect / interconnect
`mem_*` is standard AXI4. Strip the snoop signals (the cache drives
`mem_ar.arsnoop = '0`, `mem_aw.awsnoop = 3'b101`). ID width is
`READ_ID_WIDTH+1` and `WRITE_ID_WIDTH+1`; the interconnect must allow at
least that many in-flight transactions.

If a backend exposes fewer ID bits, do not truncate cache IDs. Either preserve
the full width or serialize AR/R and AW/B onto a single external ID, recording
the full IDs in separate in-order shadow FIFOs and restoring them on R-last/B.
The backend must preserve order for the flattened ID, and the shadow queues
must cover the configured outstanding depth.

### DDR controller via AXI
Wire `mem_*` to the DDR controller's S_AXI port. Set
`ADDR_RANGE_L/H` to the DDR address window. The cache's WRAP bursts will
need to be supported by the controller (most modern controllers do).

### Local BRAM / scratchpad
Use `cocotbext-axi`'s `AxiRam` (Python) or any simple AXI memory model
in SV. Mask high address bits if the local memory window is smaller than
the cache's address range — see
[tb/cocotb/dut_cocotb.sv](../tb/cocotb/dut_cocotb.sv)
which uses `MEM_MASK = 32'h000F_FFFF` for a 1 MiB shadow.

### Caveat for AXI memories
The cache uses **WRAP bursts** on mem-AR when starting block is non-zero
(critical-word-first fill). The memory system must honor WRAP semantics.
See [tb/common/axi_mem_model.sv](../tb/common/axi_mem_model.sv) for the
reference implementation.

### Whole-cache flush controller ([`src/tc_flush_controller.sv`](../src/tc_flush_controller.sv))

Optional drop-in sequencer that walks every physical line (`LINES × WAYS`)
of the cache and issues a single-beat CBOM per line. Use when the
accelerator needs a whole-cache clean/invalidate sequence rather than
per-line snoops.

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

`flush_done` marks completion of the CBOM walk, not completion of all
memory-side B responses. A persistence barrier must also observe downstream
outstanding writes.

Reserved ID: `FLUSH_ID = (1<<ID_W)-1`. Assert `flush_req` only when the
slave port is quiescent: no outstanding AR, AW, or W traffic, including a
pending response for `FLUSH_ID`. Keep normal traffic idle until `flush_done`.

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

// R demux. RID is meaningful only while RVALID is asserted.
wire route_to_flush = flush_active & cache_rvalid & (cache_rid == FLUSH_ID);
assign flush_r.rvalid = route_to_flush;
assign acc_rvalid = cache_rvalid & ~route_to_flush;
assign cache_rready = route_to_flush ? flush_rready : acc_rready;

// AW gated during flush so no new writes land mid-sweep
assign cache_aw.awvalid = acc_aw.awvalid & ~flush_active;
assign acc_awready      = cache_awready  & ~flush_active;
assign cache_w.wvalid   = acc_w.wvalid   & ~flush_active;
assign acc_wready       = cache_wready   & ~flush_active;
```

Flush latency scales with `LINES × WAYS`, databank latency, and the number and
duration of dirty writebacks.

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
| `PROMOTE_WMISS_TO_RW` | 0 | prefill a missing write line before forwarding AW; requires `ENABLE_LINE_BUFFER=1` and reserves the all-ones read ID |
| `READ_REORDER_DEPTH` | 1 | map one upstream read ID onto multiple cache IDs and restore issue order; maximum `2**ID_W-1` |

`l2_cache`, `l2_top`, `tc_flush_controller`, and `tc_narrow_shim` accept
address widths from 32 through 64 bits. Internally, the packed AXI request structs use
a 64-bit carrier; `ADDR_W` selects the meaningful low bits, and synthesis
removes unused upper bits in narrower configurations.

### 13.3 Narrow-side request contract (asserted)

* `arlen = awlen = 0` (single beat only).
* `arsize = awsize = log2(NARROW_W/8)`.
* `araddr`/`awaddr` aligned to `NARROW_W/8`.
* The shim cannot carry full-line WriteEvict traffic because the narrow port
  can never claim full-line coverage. `awsnoop = 3'b101` is rewritten to
  `3'b000` on the way out, selecting RMW. WriteEvict requires a separate
  wide path.

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

* `tb/cocotb/test_narrow_shim.py` — directed and randomized shim behavior.
* `tb/cocotb/test_shim_latency.py` — per-operation cycle counts.
* `tb/cocotb/test_shim_throughput.py` — buffered-read throughput.

Run with `cd tb/cocotb && make MODULE=test_narrow_shim` (or `test_shim_latency` / `test_shim_throughput`).
