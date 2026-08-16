# TableCache Architecture

This document describes the internal request flow, state tracking, data and tag
paths, replacement policies, victim cache, maintenance operations, and narrow
interface. Boundary requirements are defined in
[INTERFACING.md](INTERFACING.md).

---

## 1. Source material

Academic references are linked from the repository
[README](../README.md). The diagrams below describe the current RTL.

---

## 2. Top-level block diagram

Architecture figures use the `1.x` sequence.

### Figure 1.1 — Request and memory paths

![AXI read and write addresses pass through input queues and tag lookup, while
W data bypasses tag lookup and enters the databank from its FIFO. Hit data comes
from the databank, while returned fill data feeds both the databank and ordered
response logic through an optional victim cache. The invariant panel states
that read/write IDs use separate domains, line hashes serialize conflicts,
queues absorb bounded overlap, responses remain ordered per ID, and dirty
writeback moves one full line.](fig/wiki/01_architecture/architecture-f01-request-memory-paths.svg)

**Figure 1.1.** Address context selects the tag and replacement path; W data
uses its ordered FIFO to reach the databank directly. Read and write ID domains
serialize independently, and the optional victim cache remains transparent to
the cache-side request and response contracts.

Key modules (each is its own `.sv`):

| Module | Purpose |
|---|---|
| `l2_cache.sv` | Top — ties everything together. |
| `l2_tagbank.sv` | Tag array, hit/way/dirty lookup, replacement policy hookup. |
| `l2_databank.sv` | Data array (2-port, parameterised pipeline). |
| `l2_hash.sv` | Line-address → inuse-line index hash. |
| `replacement_policy.sv` + `LRU.sv` / `FRQ.sv` / `second_chance.sv` / `random_replacement.sv` / `SRRIP.sv` | Eviction-way picker. |
| `victim_cache.sv` | Optional small fully-associative cache between L2 and mem. |
| `fifo.sv`, `lutram_*`, `sdp_ram*`, `tdp_ram`, `toggle_memory*`, `set_clear_memory.sv` | Building blocks. |

---

## 3. Per-request flow

### 3.1 Read flow (steady state)

```
 master AR ─► input arbiter ─► tagbank stage1/stage2 ─► hit?
                                                          │
                              ┌───────────yes─────────────┘
                              ▼
                       way_table writes lookup
                       set inuse_id / inuse_line
                       push req_fifo (rnw=1, evict=0)
                              │
                              ▼
                       databank READ (LATENCY cycles)
                              │
                              ▼
                       db_out → output_data mux → out_fifo → req_R beats
                              │
                              ▼
                       finish_fifo entry (rvalid=1) → finish_clear → release inuse
```

```
 (miss path branches in tagbank)
                                                          │
                              ┌───────────no──────────────┘
                              ▼
                       evict_set, needs_evict_set, push ar_fifo
                              │
                              ▼
                       victim_ar → mem_AR    │ (parallel) if dirty victim:
                       mem_R → fill          │  drain db evict port → victim_aw → mem_AW
                              │
                              ▼
                       fill_info_table lookup by victim_rid
                       db_fill (writes new line into the way)
                              │
                              ▼
                       fill_rvalid stream → req_R beats (critical-word-first)
                              │
                              ▼
                       finish_fifo entry → finish_clear → release inuse
```

### 3.2 Write flow

```
 master AW + W ─► input arbiter (prefer_read toggles) ─► tagbank
                                                            │
              ┌──────── hit OR full-line WriteEvict ────────┤
              ▼                                              ▼
        write hit: merge into existing way            full-line miss:
        write miss with snoop=101: install new way   issue mem AR (fill),
        (no fill needed, in_full_write=1)            evict if dirty,
                                                     RMW merge new bytes
              │
              ▼
        databank WRITE (per-block, wbe from wstrb)
        req_b.bvalid fires once wdata FIFO drains and
        finish_fifo has room → master sees BVALID
              │
              ▼
        finish_fifo entry (wvalid=1) → finish_clear → release inuse
```

### 3.3 CBOM flow (when `INCLUDE_CBOM=1`)

```
 master AR with arsnoop ∈ {CleanShared, CleanInvalid, MakeInvalid, CleanInvalidByIndex}
        │
        ▼
 tagbank classifies: tb_out_clean (flush dirty), tb_out_inval (drop line)
   by-tag  (CleanShared/CleanInvalid/MakeInvalid): hit = tag compare in the set
   by-index (CleanInvalidByIndex, 4'b1011): hit = the WAY named by the tag
            field's low bits, ANY resident tag (writeback uses the stored tag).
            Lets tc_flush_controller clean every physical way of a set.
        │
        ▼
 If clean → flush dirty data via evict path (writeback to mem)
 If inval → drop line (no fill on subsequent miss until re-fetched)
        │
        ▼
 cbom_fifo holds the rid; output muxes a single R beat (rdata='x, rlast=1)
        │
        ▼
 finish_fifo entry → finish_clear → release inuse
```

---

## 4. State trackers

The cache uses a **family** of small memories to track in-flight requests
without a CAM. Each has a distinct ownership and update invariant.

| Storage | Indexed by | What it tracks | Backing |
|---|---|---|---|
| `inuse_id_table` | `cache_id_t` (rnw+id) | "an in-flight request owns this id" | `set_clear_memory` (toggle-XOR) |
| `inuse_line_table` | `hash(line)` | "an in-flight request hashes to this line" | `set_clear_memory` |
| `id_to_line_table` | `cache_id_t` | maps id → line hash for clear-time lookup | LUTRAM (1w1r) |
| `evict_table` | `cache_id_t` | "this id is awaiting its writeback to drain" | `set_clear_memory` |
| `needs_rdata_table` | `cache_id_t` | "this id is awaiting fill data from mem" | `set_clear_memory` |
| `needs_wdata_table` | `wid_t` | "this write hasn't received its W beats yet" | `toggle_memory_set` |
| `deferred_inuse_clear` | `cache_id_t` (bit array) | defer occupancy clear across split B/R finishes | flat register |
| `needs_evict_table` | `rid_t` | "this read miss is gated on prior evict draining" | `set_clear_memory` |
| `premature_valid` + `premature_discard_table` | `rid_t` | speculative CBOM/clean read that will be discarded in DB | `toggle_memory_set` + LUTRAM |
| `fill_info_table` | `cache_id_t` (full) | mem-rid → {line, block, way, len} for fill | LUTRAM |
| `way_table` | `cache_id_t` | id → {tag, line, block, way, discard, evict} for DB | LUTRAM (mr) |

The occupancy memories are XOR-backed. Each request must toggle its ID and
line-hash entries once on arbitrated acceptance and once on completion.
`accept_conflict` defers a request when its set operation would coincide with
a clear of the same entry.

---

## 5. ASCII pipeline / data-path

### 5.1 Read miss with dirty eviction (cycle-level sketch)

```
 t  | front-end (req_*)           | tagbank   | databank      | mem (mem_*)
 ───┼─────────────────────────────┼───────────┼───────────────┼────────────────────
 0  | AR fires (handshake)        |           |               |
 1  |                              | s1: read  |               |
 2  |                              | s2: hit?  |               |
 3  |                              | tb_valid  |               |
    |                              | miss+drty | req_fifo push |
 4  |                              |           | evict drain   | mem_AR (fill)
 5..|                              |           | victim_w[]    | mem_AW + W beats (writeback)
    |                              |           |               | mem_R beat 0  ─┐
 N  | req_R beat 0 (critical wd) ◄─────────────────────────────│ mem_R beat 1   │
    | req_R beat 1                                              │  ...           │
    | req_R beat 7 (rlast)                                      │ mem_R rlast    │
    |                              |           | finish_clear  | mem_B          │
    | inuse_id, inuse_line cleared                                              │
```

(In the bundled fast mem model, `mem_R beat 0` arrives ~5 cycles after
`mem_AR`; on real DDR, scale that up by the DDR RTT.)

### 5.2 Write-evict (full-line) hot path

```
 t  | front-end                    | tagbank   | databank      | mem
 ───┼─────────────────────────────┼───────────┼───────────────┼────
 0  | AW fires                    |           |               |
    | W beat 0..7 fires (1/cycle) |           |               |
 1  |                              | s1        |               |
 2  |                              | s2: hit?  |               |
 3  |                              | tb_valid  | wdata FIFO    |
    |                              | full_write|               |
 4  |                              |           | db_write * 8  |
    | BVALID (B handshake)        |           |               |
```

No `mem_AR` issued (full-line shortcut). If the prior occupant of the
selected way is dirty, a `mem_AW + W*8 + B` runs in parallel on the mem
side.

### 5.3 Finish-FIFO state-machine for a combined R + W entry

```
  finish-fifo head holds: {bvalid=0, rvalid=1, rid=A, wvalid=1, wid=B}

  cycle 0  bvalid_invalid=1 rvalid_invalid=0 → R-phase
                 clrid = rid (A), fhash = hash(A)
                 finish_clear = raw & ~same_target          (cdh=0)
                 clears inuse_id[A], inuse_line[hash(A)]
                 latches cleared_id=A, cleared_hash=hash(A), cdh=1
                 pop = 0  (still has W)
  cycle 1  bvalid_invalid=1 rvalid_invalid=1 → W-phase
                 clrid = wid (B), fhash = hash(B)
                 same_target = cdh & (A==B) & (hash(A)==hash(B))
                                  → 0  for different A,B
                 finish_clear = raw & ~0 = 1
                 clears inuse_id[B], inuse_line[hash(B)]
                 pop = 1  → cdh resets, next entry advances
```

The implementation is in
[src/l2_cache.sv](../src/l2_cache.sv).

---

## 6. Replacement, victim cache, CBOM

* **Replacement policy** lives in `replacement_policy.sv`; the policy is selected at compile time via the `POLICY` parameter. The interface (`cache_eviction`, `cache_way_used_int`, `cache_original_status`, `cache_new_status`, `cache_addr`) is intentionally narrow so any of {LRU, FRQ, SECOND_CHANCE, RANDOM, SRRIP, **GRASP**} drops in. Initial status comes from `INIT_POLICY` in `replacement_policy.sv`.
* **GRASP** (`GRASP.sv`) is an address-aware 3-bit RRIP policy. High and moderate reuse classes each accept a configurable number of packed address windows. High reuse takes precedence on overlap; disabling all windows reduces the policy to SRRIP frequency-priority behavior. See [wiki/GRASP_Policy.md](wiki/GRASP_Policy.md).
* **Victim cache** (`victim_cache.sv`) sits between `l2_cache` and the memory side when `INCLUDE_VICTIM=1`. It holds recently-evicted lines so a quick re-reference avoids the round-trip to DDR. The cache treats it as transparent — `mem_*` ports look identical externally. **Timing note:** on big SDP+URAM configs (≥512 KB), the victim cache's `pending_reads` LFSR drives a ~24-LUT combinational chain into the SDP databank URAM cascade write input that adds ~1.37 ns to WNS. For URAM-rich deployments where the victim cache's hit-rate benefit doesn't justify the timing cost, set `INCLUDE_VICTIM=0`.
* **CBOM** ops modify dirty/valid bits in the tagbank and may force a writeback. They go through the same FIFOs as ordinary reads, marked with the `cbom` bit in `ar_request_t`.

---

## 7. Supported envelope and caveats

### 7.1 Supported parameter envelope

| Area | Supported values |
|---|---|
| Address width | 32–64 bits |
| Cacheable range | naturally aligned power-of-two window |
| `LINES` | power of two, 2–65,536 |
| `WAYS` | integer at least 1 |
| `LINE_W` | 2, 4, 8, or 16 blocks |
| `BLOCK_W` | 8–1024 bits with a power-of-two byte count |
| ID widths | equal read/write widths, 1–15 |
| `DB_LATENCY` | 1 or 2 |
| Victim entries | at least 2 |
| SDP banks | power of two dividing `LINES` |
| Cascade depth | 1–8 |

Invalid combinations fail during elaboration. Functional coverage spans direct
cache, flat AXI wrapper, narrow shim, victim cache, TDP/SDP storage, banking,
multiple policies, reset, backpressure, and address-range variations.

### 7.2 Architectural constraints

| Constraint | Consequence |
|---|---|
| Memory fills and writebacks may use AXI WRAP | Every backend component must implement WRAP correctly |
| One request per ID and line hash in the cache core | Reused IDs and same-line traffic serialize |
| Occupancy tables are toggle-backed | Each tracked request must set and clear exactly once |
| Whole-cache flush reuses one reserved ID | The reserved all-ones ID cannot be used concurrently by normal traffic |
| Writebacks are full-line bursts | The memory backend must accept complete cache-line writes |
| Memory responses must be `OKAY` | Recoverable fill and writeback errors are not implemented |
| Reset initializes metadata by walking storage | Hold reset for at least `max(LINES, 2**(max(READ_ID_WIDTH,WRITE_ID_WIDTH)+1))` cycles |
| Narrow shim accepts single-beat aligned accesses | Bursting narrow masters require an upstream width converter |

### 7.3 Residual verification scope

The regression does not model AXI exclusive accesses, multiple independent
upstream masters, clock-domain crossings, or recoverable memory errors. Exact
performance depends on workload, board, floorplan, and memory system.

See [VERIFICATION.md](VERIFICATION.md) for the current test inventory and
[AXI_VIP.md](AXI_VIP.md) for strict 4-state coverage.

### 7.4 AXI protocol checker

The in-tree checker verifies reset behavior, VALID stability, payload stability,
burst legality, response framing, and per-ID outstanding constraints. See
[VERIFICATION.md](VERIFICATION.md#axi-protocol-checker).

### 7.5 Resolved issue classes

Implementation changes that established current invariants are summarized in
[wiki/Resolved_Issues.md](wiki/Resolved_Issues.md). The source and regression
tests are authoritative for current behavior.

## 8. Narrow-port shim ([`src/tc_narrow_shim.sv`](../src/tc_narrow_shim.sv))

Companion module that sits between a narrow-bus accelerator and a wide
TableCache instance. Lives outside `l2_cache` and is independently
parameterised; the cache RTL is unchanged.

### 8.1 Block diagram

```
 narrow AR ─► ┌──────────────────────────────────────────────┐ ─► wide AR
              │  per-id outstanding tracker (rid_outstanding) │
              │  per-id offset table (rid_offset_q)           │
              │  per-id aligned-addr table (rid_alignaddr_q)  │
              │  ┌──────────────────────────────────────────┐ │
              │  │  L0 line buffer                          │ │
 narrow R ◄── │  │  {lb_valid, lb_tag, lb_data[BLOCK_W-1:0]}│ │ ◄─ wide R
              │  └──────────────────────────────────────────┘ │
              │                                                │
 narrow AW ─► │  AW→W FIFO  [{offset, aligned_tag}; depth=N]   │ ─► wide AW
 narrow W  ─► │     │                                          │ ─► wide W
              │     └─► lane mux into m_wdata + wstrb          │
              │     └─► write-merge into lb_data on tag match  │
              │                                                │
 narrow B  ◄─ │  passthrough                                   │ ◄─ wide B
              └──────────────────────────────────────────────┘
```

### 8.2 Read path (cycle level)

```
 narrow_ar = miss?  ─► wide_ar fires (single-beat, aligned)
              ▼
        cache returns wide_r (after cache hit/miss + DDR RTT)
              ▼
        slice narrow word using rid_offset_q[m_rid]
              ▼
        register full wide line into {lb_valid, lb_tag, lb_data}

 narrow_ar = hit ─► ar_buf_accept (combinational), lane mux drives s_rdata
                    next cycle. Cache untouched.
```

### 8.3 Write path

```
 narrow_aw fires ──► push {offset, aligned_tag} into AW FIFO
                     issue wide_aw to cache (awsnoop forced ≠ 3'b101)
 narrow_w fires  ──► pop FIFO head
                     place s_wdata in lane, s_wstrb in mask
                     drive wide_w
                     if (lb_valid && aligned_tag == lb_tag):
                         for each wstrb byte: lb_data[lane.byte] <= s_wdata
                     ── this is the WRITE-MERGE — no wide re-fetch needed
 wide_b ◄── pass through to narrow_b
```

### 8.4 Invariants

| Invariant | How enforced |
|---|---|
| Same-id reads serialise | `rid_outstanding_q[NUM_IDS]`; new AR with in-flight id is stalled |
| Stalled wide AR payload is stable | Selected user or prefill AR is held until handshake |
| W beat selects the correct lane | AW FIFO orders {offset, tag} in AW arrival order; W beats pop in same order (AXI4 rule) |
| Buffer never returns stale data after write | Write-merge updates `lb_data` byte-by-byte in place at W-beat time |
| Buffered R payload is stable under backpressure | A sticky owner holds the buffered response until handshake |
| Concurrent fill and write affect one line only | Fill replaces a different tag; same-tag writes merge into the incoming fill |
| Buffer never holds CBOM data | CBOM rdata is `'x`; `cbom_outstanding_q[rid]` suppresses lb_fill on that response, and a CBOM AR that matches lb invalidates it |
| Buffer never holds aliased line | Tag = address bits `[ADDR_W-1:ALIGN_LSB]` (no hashing); only one line of state |
| Write back-pressure can never lose a W beat | `s_wready` gated by `~aw_fifo_empty` AND `m_wready`; `s_awready` gated by `~aw_fifo_full` |
| Exactly one narrow response per read | The shim forwards only the completing `rlast=1` beat and drains any other cache beat. |

### 8.5 What is NOT in the shim

* **One outstanding read per ID**: distinct IDs may overlap on the wide port,
  while same-ID reads serialize. The line buffer and narrow R output remain
  shared across all IDs.
* **No coalescing across lines**: only one line is cached in the L0
  buffer. A two- or four-line victim-style L0 would help workloads that
  ping-pong between a small set of lines; not implemented.
* **No WriteEvict bypass**: a narrow port cannot claim full-line coverage.
  Full-line producers require a separate wide path.

### 8.6 Verification

| Test | What it proves |
|---|---|
| [test_narrow_shim.py](../tb/cocotb/test_narrow_shim.py) | 10 directed (cold/hot, buffer merge, AW FIFO, sub-word) + heavy random (50 000 ops × 5 seeds, byte-granular golden, 0 mismatches) |
| [test_shim_latency.py](../tb/cocotb/test_shim_latency.py) | per-op latency: cold-R=4, hot-R=3, write=5, merged-R=3 cycles |
| [test_shim_throughput.py](../tb/cocotb/test_shim_throughput.py) | hand-driven AR pump: 16 buffered reads in 18 cycles, ≈1 narrow R beat/cycle steady state |
| [test_shim_multiread.py](../tb/cocotb/test_shim_multiread.py) | distinct-ID overlap, same-ID serialization, concurrent hits, generation wrap, and protocol framing |
| [test_shim_reorder.py](../tb/cocotb/test_shim_reorder.py) | `READ_REORDER_DEPTH>1`: a single engine id keeps N reads outstanding (engine + cache concurrency proven), delivered strictly in issue order; out-of-order cache completion (head miss + warm hits) reordered correctly |
| [test_shim_wrap_matrix.py](../tb/cocotb/test_shim_wrap_matrix.py) | critical-word-first fill contract across every legal `LINE_W`, bus widths 32–512, ratios 1–16, TDP/SDP, DB latency 1/2, backpressure/ROB/refill; invalid line lengths rejected |
| [test_shim_wrap_negative.py](../tb/cocotb/test_shim_wrap_negative.py) | isolated wrong-boundary mutation produces sparse WRAP-tail corruption |

`test_narrow_shim`/latency/throughput run shim-only. The multiread, reorder,
shim-cache, and WRAP suites run the shim in front of `l2_cache` end-to-end.

### 8.7 Optional read reorder buffer (`READ_REORDER_DEPTH`)

`tc_narrow_shim` is a thin wrapper. At the default `READ_REORDER_DEPTH=1` it
instantiates `tc_narrow_shim_core` directly, with one read outstanding per ID.
At `READ_REORDER_DEPTH=N` (>1) it
inserts `tc_read_reorder` on the read path so a **single-id, in-order engine**
(one that cannot rotate `arid`) can still keep `N` reads outstanding:

* Each engine AR is allocated a ROB slot; the slot index becomes a **distinct
  core id** (`0..N-1`), so the cache — which serves one outstanding read per id —
  overlaps up to `N` of them. The engine id is recorded per slot.
* The ROB always accepts the core response (`c_rready=1`); it captures the narrow
  word into the slot and marks it ready. Responses are presented to the engine
  strictly from the **head** slot, in issue order, tagged with the recorded
  engine id — so a cache that completes reads out of order (e.g. a warm hit behind
  a cold miss) is reordered back to in-order, single-id completion.
* Constraint: `READ_REORDER_DEPTH <= 2**ID_W - 1` (the top id is reserved for the
  RMW prefill). An elaboration assert enforces it. Write/AW/W/B and CBOM paths are
  unchanged (bypass straight to the core).

## 9. Where to read further

* [INTERFACING.md](INTERFACING.md) — boundary spec, parameters, latency / throughput table, common back-ends.
* [../tb/cocotb/test_*.py](../tb/cocotb/) — executable specs of every cache behaviour (smoke, cbom, strobe, latency, random, scoreboard, matrix).
* RTL header comment in [`src/l2_cache.sv`](../src/l2_cache.sv) — definitive enumeration of design restrictions.
* The cited paper and thesis for the academic motivation and design space.
