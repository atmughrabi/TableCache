# TableCache Architecture & Internal Flow

Companion to [INTERFACING.md](INTERFACING.md) (boundary spec) and
[../README.md](../README.md) (parameters / tests). Subjects covered:

1. Background — paper & thesis pointers.
2. High-level block diagram.
3. Per-request flow (read / write / CBOM).
4. State trackers (the “toggle / set-clear / lutram” zoo).
5. ASCII pipeline diagrams.
6. Replacement policy, victim cache, CBOM.
7. Known gaps, design caveats, and verification status
   (verification gaps, architectural caveats, test-infrastructure gaps,
   AXI4 protocol checker, bug history).
8. Narrow-port shim (`src/tc_narrow_shim.sv`) and where to read further.

---

## 1. Source material

* Paper: `research/TableCache_An_Open-Source_Configurable_Last-Level_Cache_for_FPGA_Systems.pdf` (FPT 2024).
* Thesis: `research/etd23318.pdf` (full SFU thesis underpinning the design).

The diagrams below are derived from the RTL as-built; cross-check
against the paper’s Fig. 1 / Fig. 2 (overall structure + read-miss
walk-through) and the thesis chapter on the data-bank / tag-bank split.

---

## 2. Top-level block diagram

```
 ┌─────────────────────────── l2_cache.sv (request → response) ───────────────────────────┐
 │                                                                                         │
 │     ┌────────────┐   tb_advance   ┌─────────────┐    tb_valid    ┌────────────────┐    │
 │ req─►│  Input    ├───────────────►│   Tagbank   ├──hit/dirty/────►│  Way / Lookup  │    │
 │ AR/AW│  arbiter   │ (saved_ar(W)) │ (2-stage    │   way / tag     │  Tables        │    │
 │      │ prefer_read│                │  pipeline)  │                 │ (way_table,   │    │
 │      └─────┬──────┘                └─────┬───────┘                 │ fill_info,    │    │
 │            │ chosen_*                    │                         │ premature_*)  │    │
 │            │                             │                         └──────┬─────────┘   │
 │            │                             │                                │             │
 │            │                             ▼                                ▼             │
 │            │                       ┌─────────────┐               ┌───────────────┐      │
 │            │                       │ Inuse / State│              │  Databank      │     │
 │            │                       │ trackers:   │               │  (l2_databank) │     │
 │            │                       │  inuse_id   │               │  2 ports, BRAM │     │
 │            │                       │  inuse_line │  db_req       │  parameterised │     │
 │            │                       │  rdata/wdata│ ──────────────►│  LATENCY pipe  │     │
 │            │                       │  evict      │               │                │     │
 │            │                       │  needs_evict│   db_out_*    │  Two output    │     │
 │            │                       └──────┬──────┘ ◄─────────────┤  FIFOs (port0, │     │
 │            │                              │                       │   port1)       │     │
 │            ▼                              │                       └──┬──────┬──────┘     │
 │      ┌───────────┐                        ▼                          │      │            │
 │      │  W FIFO   │            ┌────────────────────────┐              │ Hit  │ Evict     │
 │ req──►│ (wdata_*) │            │   finish_fifo (4-deep)  │             │ data │ data      │
 │  W   │           │            │ B+R+W phase serializer │             ▼      ▼            │
 │      └─────┬─────┘            └──────────┬─────────────┘     ┌────────────────┐         │
 │            │                              │ finish_clear     │  out_fifo      │ ►req_R   │
 │            │ wdata to DB                  │ (id, hash)       │  + req_R mux   │  rdata   │
 │            └──────────────────────────────┴──────────────────►│                ├─►req_B   │
 │                                                               └────────────────┘  bvalid │
 │                                                                                          │
 │ ─── Memory side ─────────────────────────────────────────────────────────────────────    │
 │       ┌───────────────┐  victim_ar  ┌──────────────┐                                     │
 │       │  ar_fifo      ├────────────►│ victim_cache │──► mem_AR (fill request)            │
 │       │ (miss-AR queue)│             │ (optional)   │◄── mem_R  (fill returning)         │
 │       └───────────────┘             │              │                                     │
 │                                     │  ──────────► │──► mem_AW + W (writeback)           │
 │       ┌───────────────┐  victim_aw  │              │◄── mem_B                            │
 │       │ Evict logic   ├────────────►│              │                                     │
 │       │ (start_evict, │             │  if disabled │ ── direct passthrough ─────────────►│
 │       │  evict_port)  │             └──────────────┘    mem_* ports                      │
 │       └───────────────┘                                                                  │
 └──────────────────────────────────────────────────────────────────────────────────────────┘
```

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
 master AR with arsnoop ∈ {CleanShared, CleanInvalid, MakeInvalid}
        │
        ▼
 tagbank classifies: tb_out_clean (flush dirty), tb_out_inval (drop line)
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
without a CAM. They look similar but each has a distinct invariant. This
zoo is the source of most subtle bugs.

| Storage | Indexed by | What it tracks | Backing |
|---|---|---|---|
| `inuse_id_table` | `cache_id_t` (rnw+id) | "an in-flight request owns this id" | `set_clear_memory` (toggle-XOR) |
| `inuse_line_table` | `hash(line)` | "an in-flight request hashes to this line" | `set_clear_memory` |
| `id_to_line_table` | `cache_id_t` | maps id → line hash for clear-time lookup | LUTRAM (1w1r) |
| `evict_table` | `cache_id_t` | "this id is awaiting its writeback to drain" | `set_clear_memory` |
| `needs_rdata_table` | `cache_id_t` | "this id is awaiting fill data from mem" | `set_clear_memory` |
| `needs_wdata_table` | `wid_t` | "this write hasn't received its W beats yet" | `toggle_memory_set` |
| `deferred_inuse_clear` | `cache_id_t` (bit array) | bug-#2 fix: defer clear past split B+R finishes | flat reg |
| `needs_evict_table` | `rid_t` | "this read miss is gated on prior evict draining" | `set_clear_memory` |
| `premature_valid` + `premature_discard_table` | `rid_t` | speculative CBOM/clean read that will be discarded in DB | `toggle_memory_set` + LUTRAM |
| `fill_info_table` | `cache_id_t` (full) | mem-rid → {line, block, way, len} for fill | LUTRAM |
| `way_table` | `cache_id_t` | id → {tag, line, block, way, discard, evict} for DB | LUTRAM (mr) |

The `set_clear_memory` and `toggle_memory_set` primitives are
**XOR-backed**: setting and clearing the same bit twice = stuck. That’s
why finish-FIFO bookkeeping is so picky (see bugs #3, #6).

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

This is the bug-#6 fix in [src/l2_cache.sv lines 388-421](../src/l2_cache.sv#L388-L421).

---

## 6. Replacement, victim cache, CBOM

* **Replacement policy** lives in `replacement_policy.sv`; the policy is selected at compile time via the `POLICY` parameter. The interface (`cache_eviction`, `cache_way_used_int`, `cache_original_status`, `cache_new_status`, `cache_addr`) is intentionally narrow so any of {LRU, FRQ, SECOND_CHANCE, RANDOM, SRRIP, **GRASP**} drops in. Initial status comes from `INIT_POLICY` in `replacement_policy.sv`.
* **GRASP** (`GRASP.sv`) is an address-region-aware 3-bit RRIP variant inspired by Faldu et al., HPCA'20. It exposes 4 runtime input ports for two region windows (hot, moderate): `grasp_high_addr_l/h`, `grasp_moderate_addr_l/h`. A region is **disabled** by driving its `_h` port to `0` (the "not in use" convention). With both regions disabled GRASP reduces to SRRIP-FP. Address ports are sized by `ADDR_W` (defaults to 32, parameterised from `l2_top`'s `C_S00_AXI_ADDR_WIDTH`). The cache passes the full reconstructed address (including the `ADDR_RANGE_L` upper bits — see bug #15 below) so region matching uses real bus addresses. **GRASP adds 0 ns of WNS overhead** vs SRRIP at the 512 KB/8-way SDP+URAM target — the policy logic stays off the critical path (see [syn/vivado/sweep_results.md](../syn/vivado/sweep_results.md) for the post-synth headline numbers).
* **Victim cache** (`victim_cache.sv`) sits between `l2_cache` and the memory side when `INCLUDE_VICTIM=1`. It holds recently-evicted lines so a quick re-reference avoids the round-trip to DDR. The cache treats it as transparent — `mem_*` ports look identical externally. **Timing note:** on big SDP+URAM configs (≥512 KB), the victim cache's `pending_reads` LFSR drives a ~24-LUT combinational chain into the SDP databank URAM cascade write input that adds ~1.37 ns to WNS. For URAM-rich deployments where the victim cache's hit-rate benefit doesn't justify the timing cost, set `INCLUDE_VICTIM=0`.
* **CBOM** ops modify dirty/valid bits in the tagbank and may force a writeback. They go through the same FIFOs as ordinary reads, marked with the `cbom` bit in `ar_request_t`.

---

## 7. Known gaps / caveats (what the bundled tests DO NOT cover)

Read this list before depending on TableCache in a production design.

### 7.1 Verification gaps

| Area | Status | Notes |
|---|---|---|
| `BLOCK_W` ≠ 32 | PARTIALLY VERIFIED | `BLOCK_W=512` exercised via [test_shim_cache.py](../tb/cocotb/test_shim_cache.py) (`LINES=128, LINE_W=2, WAYS=8`); intermediate widths (64/128/256) NOT tested. The Makefile's `BLOCK_W` knob is locked at 32 on the bare-cocotb path because (a) [dut_cocotb.sv](../tb/cocotb/dut_cocotb.sv) declares `parameter int BLOCK_W = 32` with no `TC_BLOCK_W` `ifdef` guard, and (b) every `test_*.py` hard-codes `BLOCK_BYTES = 4` with `golden()` returning a 32-bit word per address. Lifting this requires both an RTL parameter override and a refactor of each test's golden-comparison slicing to handle multi-golden-per-beat. The shim integration TB already covers the wide end; this sweep exposed bug #7. |
| `LINE_W` ≠ 8 | PARTIALLY VERIFIED | `LINE_W=2` exercised by the shim+cache integration TB; values 3–7 not tested. |
| `LINES` ≠ 64 (besides build) | NOT VERIFIED | larger LINES values build but no functional run |
| `READ_ID_WIDTH` / `WRITE_ID_WIDTH` ≠ 4 | NOT VERIFIED | wider/narrower IDs not exercised |
| `ADDR_RANGE_*` other than `[0x80000000, 0xFFFFFFFF]` | NOT VERIFIED | NAPOT requirement not stress-tested |
| Address-aware policy classification | VERIFIED | [test_grasp.py](../tb/cocotb/test_grasp.py) exercises GRASP hot-region retention and the all-zero SRRIP-FP fallback. Surfaced **bug #15**: `policy_addr` in `l2_tagbank.sv` was passing the tag-projected address (upper `OMITTED_ADDR_W` bits stripped) to address-aware policies. With `ADDR_RANGE_L=0x80000000` the GRASP region match could never fire for any address \u2265 0x80000000, silently degrading GRASP to plain RRIP-FP. Hit-rate stayed flat across associativity sweeps (4-way 57.4% \u2192 8-way 57.6%) while SRRIP scaled (69.8% \u2192 74.4%). Fix: add `ADDR_BASE` parameter to `l2_tagbank`, reconstruct `policy_addr = ADDR_BASE \\| {tag, line, 0}` before passing to the policy. After fix: GRASP scales (69.1% \u2192 74.1%) and matches SRRIP within 0.3pp. Lesson: functional tests don't catch silent performance bugs; perf-sweep deltas across associativity are a strong oracle. |
| SDP databank with 1-cycle write-input register | VERIFIED | `SDP_WRITE_INPUT_REG=1` (optional 1-cycle register on the SDP URAM write port; see [sdp_ram_uram.sv](../src/sdp_ram_uram.sv) header). Functional regression of 32/32 PASS across {smoke, random, scoreboard, workload, reset_recovery, backpressure, strobe, latency} × {LRU, GRASP} with `+define+TC_DATABANK_SDP=1 +define+TC_SDP_WRITE_INPUT_REG=1`. Confirms the FSM-correctness analysis: WRITING → READY → READING serialisation provides a 1-cycle slack that absorbs the extra write commit latency. Off by default. |
| Post-synth timing on big SDP+URAM configs | VERIFIED | [syn/vivado/sweep_results.md](../syn/vivado/sweep_results.md) holds the OOC sweep matrix on U250 (xcu250-figd2104-2L-e). With `DIRECTIVE=default INCLUDE_VICTIM=0 DB_LATENCY=2 DATABANK_SDP=1` (the recommended URAM-deployment knobs), 512 KB / 8-way / GRASP closes 250 MHz post-synth (WNS = +0.186 ns); 1 MB / 8-way / GRASP misses by -0.186 ns (closes post-PnR on the same family). Two synth-flow pitfalls documented in [syn/vivado/README.md](../syn/vivado/README.md): (a) `REPLACEMENT_POLICY` is a no-op for `TOP=l2_cache` (the module declares `POLICY` instead) and silently produces an LRU build; (b) `AreaOptimized_high` costs ~1.36 ns of WNS vs `default` on the URAM cascade critical path. |
| Mid-burst reset | VERIFIED | [test_reset_recovery.py](../tb/cocotb/test_reset_recovery.py) exercises 4 reset scenarios (between transactions, during a read fill, during a multi-beat write burst, with two reads in flight). Each scenario asserts reset before the response returns, holds for the LFSR-init window (`2*LINES` cycles), then verifies a fresh transaction completes correctly *and* `pc_violations_total == 0` (i.e. no AXI4 protocol violations across the reset boundary). Bug history: surfaced #10 (cache held `req_r.rvalid`/`req_b.bvalid` for one cycle into reset) and #11 (checker's `vcount` had a multi-driver race that silently masked B1 violations occurring during reset). |
| `req_rready` / `req_bready` held LOW for many cycles | VERIFIED | [test_backpressure.py](../tb/cocotb/test_backpressure.py) drives randomized 1–16-cycle pauses on `s_rready` and `s_bready` via cocotbext-axi `set_pause_generator(...)`. AXI4 PC stays clean (no A1/A2 violations). |
| `mem_arready` / `mem_wready` held LOW for many cycles | VERIFIED | [test_backpressure.py](../tb/cocotb/test_backpressure.py) drives randomized 1–20-cycle pauses on `m_arready`, `m_wready`, and `m_awready`. Surfaced bug #12 (mem-side B1: `m_arvalid` held for one cycle into reset on the next test's `reset_dut`). |
| Reset-then-recover after long idle | VERIFIED | [test_realism.py::test_long_idle_then_reset_recover](../tb/cocotb/test_realism.py) idles for `max(4096, LINES·8)` cycles between a warm-up burst and a reset, then verifies a fresh post-reset transaction. |
| AXI4 protocol-checker compliance | VERIFIED on DUT-driven signals | Custom in-tree [axi_protocol_checker.sv](../tb/cocotb/axi_protocol_checker.sv) wired on every AXI bus of every DUT wrapper. Full 12-module cocotb regression + 22-combo pytest matrix produce **zero violations** on every checker instance that watches DUT-driven signals (cache m_*, shim s_*/m_*, shim↔cache bus). See §7.4 below for rule coverage, the two per-instance trust knobs that mask known cocotbext-axi v0.1.28 quirks, and what each knob trades off. |
| Real DDR latency (10s of cycles for mem-R first beat) | VERIFIED | [test_realism.py::test_ddr_first_beat_latency_{20,40,80}](../tb/cocotb/test_realism.py) stalls every mem R beat by 20/40/80 cycles via cocotbext-axi `set_pause_generator(...)` on `r_channel` (a strictly more stressful pattern than DDR's first-beat-only delay). 30-op R/W mix passes per latency with zero PC violations. |
| Coverage closure (line / toggle / FSM) | NOT MEASURED | Verilator coverage not yet enabled |

### 7.2 Architectural caveats

| # | Caveat | Mitigation |
|---|---|---|
| 1 | **WRAP burst on mem-AR** is mandatory when fill starts at non-zero block (critical-word-first). | Memory model / interconnect MUST honor AXI WRAP. See bug #5. |
| 2 | **Only `awsnoop=3'b101`** (WriteEvict) is treated as full-line shortcut. WriteBack `3'b001` is RMW. | Document loudly to masters; otherwise expect extra mem ARs. |
| 3 | **Same-line requests serialize** (different IDs on same hash block). | Throughput-limiting under heavy same-set traffic; consider larger LINES or different hash. |
| 4 | **Same-ID requests serialize** (max one in-flight per id). | Limits parallelism for masters that reuse IDs; spread across IDs. |
| 5 | **inuse tables are toggle-XOR backed**: any clear that fires twice for the same target causes a stuck-busy hang. | Source of bugs #3 + #6; future RTL edits to `finish_clear` must preserve "fire-once per (id, hash) per head". |
| 6 | **`DB_LATENCY` adds 1 cycle to read hits per +1**. | Increase only if synthesis FMAX demands it. |
| 7 | **`fill_info_table` is shared across all in-flight fills**, keyed by `cache_id_t`. If a master ever reuses an id while a fill is in flight (which the cache blocks via `inuse_id`), bookkeeping would alias. | inuse_id is the single point of trust here. Any regression there breaks all fills. |
| 8 | **No partial-line writes via mem-AW**: the cache always writes full lines back (`victim_wstrb='1`, `victim_aw.awlen=LINE_W-1`). | Memory must accept full-line bursts. |
| 9 | **`READ_ID_WIDTH=WRITE_ID_WIDTH`** is the only combination tested. Mismatched widths build but are unverified. | Keep them equal unless you investigate `cache_id_t` packing first. |
| 10 | **Verilator quirk**: `b_t.bid` / `r_t.rid` of all-ones can bleed into `bvalid`/`rvalid` (commented in `l2_cache.sv` line 240). Stick with even-width IDs. | Don't widen ID_W past 5 without re-testing in Verilator. |
| 11 | **Reset value of way 0 tag is `'x`** (see `l2_tagbank.sv:128`): only `valid=0` is reset. Random simulators may flag X-prop; production should rely on `valid=0`. | Not a bug; awareness item for X-aware sims. |
| 12 | **`sdp_ram_rst` LFSR reset requires `2^ADDR_WIDTH` cycles** to initialize every entry. Under-resetting leaves uninitialized LRU policy storage (catastrophic for LRU WAYS>4 where `INIT_POLICY` is non-zero); FRQ/SRRIP/RANDOM tolerate it accidentally. | Integrators MUST hold `rst` ≥ `2^$clog2(LINES)` cycles. Use 4096 as a safe upper bound. The bundled `sdp_ram_rst.sv` docstring (`$clog2(ADDR_WIDTH)`) is wrong. |
| 13 | **Verilator wide-NBA quirk in `tdp_ram.sv` (AMD branch)**: the original per-byte `for`-loop of partial-bit-slice NBAs silently drops all but the highest-indexed active byte when `NUM_COL = WAYS × (BLOCK_W/8)` becomes large (e.g. `WAYS=8, BLOCK_W=512` ⇒ `NUM_COL=512`). Symptom: a fill writes only one byte of the target way; subsequent partial reads return zeros. Invisible at `BLOCK_W=32` baseline. | Replaced with a single full-width NBA driven by a precomputed bit mask (synth tools still infer per-byte WE). Do not refactor back. See bug #7 and the README "Note on `src/tdp_ram.sv`". The Intel branch (`gen_intel_tdp`) uses a different (packed-element, hand-unrolled) pattern and is unaffected. |

### 7.3 Test-infrastructure gaps

* The **reference-model scoreboard** ([test_scoreboard.py](../tb/cocotb/test_scoreboard.py)) uses an approximate AR drift (≤ 10%) because shadow-LRU encoding doesn’t exactly match the bit-level cache LRU. Exact prediction would require porting the encoded LRU permutation tables from `LRU.sv` into Python.
* **Inuse-leak sweep** ([test_random.py](../tb/cocotb/test_random.py)) catches bug-#6-class hangs by poking every (set, tag) with a rolling id after the random phase. It does NOT detect partial leaks where some bits are stuck and others are not — only a subsequent hang.
* **CBOM tests** ([test_cbom.py](../tb/cocotb/test_cbom.py)) are sequential single-shot. Concurrent CBOM + read/write to same line is not exercised.
* **Strobe tests** ([test_strobe.py](../tb/cocotb/test_strobe.py)) hand-drive AW/W because cocotbext-axi’s `AxiMaster` lacks per-beat strobe. The hand-drive doesn’t enforce AW-W ordering rules beyond what the cache asserts; the in-tree protocol checker (see §7.4) covers the rest at the bus level.
* **Pytest matrix harness** ([test_matrix.py](../tb/cocotb/test_matrix.py)) previously checked `"FAIL" not in r.stdout`, which trips on cocotb's own success banner (`** TESTS=1 PASS=1 FAIL=0 SKIP=0 **`). Replaced with a regex that parses the `FAIL=<n>` field and asserts the integer is zero. Without this fix every matrix combo reports failure even when the underlying cocotb test passes — which masked bug #8 until the matrix sweep was re-run with the corrected assertion.
* **`tb_common.attach_mem` golden seeding** previously read `TC_BLOCK_W` and zero-extended the 32-bit `golden(addr)` value to `BLOCK_W/8` bytes per stride. At `TC_BLOCK_W=64` this clobbered bytes 4..7 of every 8-byte block with zeros, so any subsequent 4-byte read of an odd-block-offset address returned `0x00000000` instead of the expected `golden(addr)`. Symptom: `data mismatch at addr 0x80001004 got=0x00000000 exp=0x1044cafe`. Fix: always seed at the 4-byte golden-word granularity in [tb_common.py](../tb/cocotb/tb_common.py); the bus width only affects how many golden words pack into one beat. The bug was latent because no existing test ran with `TC_BLOCK_W != 32`; it was discovered while probing the (now-locked-out) `BLOCK_W` Makefile knob.

### 7.4 AXI4 protocol checker

See [VERIFICATION.md §2](VERIFICATION.md#2-axi4-protocol-checker) for the
full rule table and trust-knob settings. Summary: 14 rules enforced on
every AXI bus of every wrapper; one combined regression produces zero
`AXI_PC_VIOLATION` lines.

### 7.5 Bug history (already fixed)

| # | File | Defect | Fix location | Found by |
|---|---|---|---|---|
| 1 | `l2_cache.sv` | Saved AR/AW handshake race | ~line 486 `saved_arvalid`/`saved_awvalid` rewrite | t02 directed |
| 2 | `l2_cache.sv` | Deferred in-use clear for split B+R finish | `deferred_inuse_clear` flat register, lines 332-381 | t02 directed |
| 3 | `l2_cache.sv` | Double-toggle of `inuse_*` on bid==rid self-eviction | `clear_done_for_head` latch, lines 388-421 | t02 directed (D5 corner) |
| 4 | `l2_databank.sv` | `past_original_last` stuck on premature-discard exit | reset on READY→READING transition | cocotb random seed=23 stall at txn[148] |
| 5 | `tb/common/axi_mem_model.sv` | WRAP burst not implemented in mem model | added burst tracking + addr wrap | cocotb random seed=1 mis-data at txn[36] |
| 6 | `l2_cache.sv` | `clear_done_for_head` over-suppressed combined R+W entries | track `(cleared_id, cleared_hash)` and only suppress same-target re-fire, lines 388-421 | cocotb random seed=11 stall at txn[217], seed=23 @ txn[148] post-#4 |
| 7 | `tdp_ram.sv` | AMD branch per-byte NBA loop drops bytes when `NUM_COL` is wide (Verilator quirk at `WAYS=8, BLOCK_W=512` ⇒ `NUM_COL=512`). Each fill committed only one byte. | Single full-width NBA with precomputed bit mask: `mem <= (mem & ~mask) | (data & mask)`. Intel branch unaffected. | shim+cache random_stack: `got=0x3D000000 want=0x3D68EDFC`. |
| 8 | `replacement_policy.sv` | `POLICY_W==0` when `POLICY=RANDOM` makes `logic[POLICY_W-1:0]` resolve to `logic[-1:0]`; Verilator 5.x rejects (was tolerated before). | Ternary: `logic[(POLICY_W==0 ? 0 : POLICY_W-1) : 0]`. Dummy bit unused. | `pytest test_matrix.py` `POLICY=RANDOM` combo. |
| 9 | [tc_narrow_shim.sv](../src/tc_narrow_shim.sv) | `PROMOTE_WMISS_TO_RW=1` workaround predated bug #7; issued an extra wide AR per "far" write. Post-#7 the cache's RTL RMW path handles cold-write-miss correctly. | Default flipped to `0`. Workaround retained as escape hatch. | `test_cold_write_miss_preserves_other_lanes` PASS with `PROMOTE_WMISS_TO_RW=0`. |
| 10 | `l2_cache.sv` | `req_r.rvalid` / `req_b.bvalid` driven from FIFOs with synchronous reset → held high one cycle into `rst==1`. AXI4 B1 violation. | Route FIFO valids through intermediate signals, AND with `~rst` at the slave-port boundary (lines ~689, ~1296). | `test_reset_recovery::test_reset_with_two_in_flight` (only after bug #11 fix). |
| 11 | `tb/cocotb/axi_protocol_checker.sv` | `vcount` had two drivers: B1 increment block and a separate `if (rst) vcount <= 0;`. The rst-clear won every cycle, so B1 violations during reset printed via `$display` but never counted. | Removed the rst-clear block; initialize via `integer vcount = 0;` at declaration. | Test PASS while log showed `AXI_PC_VIOLATION B1 RVALID asserted during rst`. |
| 12 | `l2_cache.sv` | Master-side mirror of #10: `mem_ar.arvalid` / `mem_aw.awvalid` / `mem_w.wvalid` held one cycle into reset under m_arready / m_wready back-pressure. | Restructured `gen_victim`/`gen_no_victim` to drive internal `mem_*_int`; an `always_comb` outside the generate gates the three VALIDs with `~rst`. | `test_backpressure::test_mem_wready_backpressure`. |
| 13 | `tdp_ram.sv` | Original AMD branch set `(* ram_style = "ultra" *)`. Vivado 2025.x rejects the masked-NBA + true-dual-port + per-byte-enable pattern for UltraRAM ("Unsupported RAM template"), since URAM is internally SDP/multi-pumped and cannot service simultaneous per-byte writes on both ports. | Hard-code `(* ram_style = "block" *)` on the AMD TDP path. Verilator (the masked-single-NBA form needed by bug #7) is gated behind `\`ifdef COCOTB_SIM`; Vivado synthesises the original per-byte-NBA loop, which is the canonical BRAM-with-byte-enable template. Comment in `src/tdp_ram.sv:86` records the rationale. | First Vivado OOC build on Alveo U250 (`syn/vivado/run_synth.sh`). |
| 14 | `l2_databank.sv` | New `DATABANK_SDP=1` mode (paper-style URAM packing via `sdp_ram_uram`) initially gated `port_*_data_ready` outputs with a runtime `sdp_p1_stall` signal. That created a combinational loop through the upstream `req_fifo`/`fill_request` bypass paths in `l2_cache.sv` ("Input combinational region did not converge" at runtime under `test_backpressure`). A second attempt that only gated the data-handshake signals avoided the loop but corrupted port-1 fill data (4/6 backpressure tests failed because upstream had already committed the gated beat). | Switched to the simplest provably-correct strategy: in SDP mode disable databank port 1 entirely via parameter-elaborated `~DATABANK_SDP` masks on `port_ready[1]`, `port_write_data_ready[1]`, `port_fill_data_ready[1]`, and `en_gated[1]`. No runtime signal feeds back; the FSM serializes all traffic through port 0. Cost: -6.3% throughput (vs the 1.3% the broken stall logic predicted). Win: 132 BRAM → 16 URAM + 5 BRAM @ 512 KB/8-way on U250. The two failed approaches are documented above so they aren't re-attempted. | Initial fail: `test_backpressure` with `+define+TC_DATABANK_SDP=1`. Fix verified by 9/9-module 29/29-test regression with SDP=1, plus Vivado URAM-inference confirmation. |
| 15 | `l2_tagbank.sv` | `policy_addr` was projected from the stored tag (`{tag, line, 0}`), losing the upper `OMITTED_ADDR_W` bits the cache strips before tagging. Address-aware policies (GRASP) thus saw addresses missing the `ADDR_RANGE_L` prefix; with the default `ADDR_RANGE_L=0x8000_0000`, every region-match test against an address ≥ `0x8000_0000` failed, silently degrading GRASP to plain RRIP-FP. Functional tests passed (RRIP-FP is correct); the bug only showed up in perf-sweep deltas across associativity (4-way 57.4% → 8-way 57.6% for "GRASP" vs SRRIP's 69.8% → 74.4%). | Added `ADDR_BASE` parameter to `l2_tagbank` (defaulted from `l2_cache.ADDR_RANGE_L`); reconstruct `policy_addr = ADDR_BASE \| ADDR_W'({tag, line, 0})` before passing to the policy. With the fix in place, GRASP scales 69.1% → 74.1% and matches SRRIP within 0.3pp. | Surfaced by `tb/cocotb/test_grasp.py::test_grasp_hot_retained` returning the same hit-rate as the SRRIP fallback; confirmed by `tb/cocotb/perf_sweep.py` showing GRASP scaling that finally matches SRRIP. |
| 16 | `l2_tagbank.sv` | `out_dirty` and `out_tag` were unconditionally read from `evict_entry = tb_rdata_r[policy_replacement_way_int]` -- the way the replacement policy would pick if a NEW line had to be allocated. On a CBOM `CleanInvalid` / `CleanShared` HIT, the line being evicted is the HIT way (which may be a different way than the policy's first pick); the writeback then issued mem-AW using the policy way's stale tag (typically 0 for a never-touched way), so the dirty data got written to the WRONG memory address. Existing `test_cbom_*` directed tests pre-warm the line with a full-line READ before the partial write; that pattern always places the line at the policy way, so the wrong-way bug never fires. Adversarial pattern (single-beat partial write to an uncached line that triggers RMW, then `CleanInvalid` back-to-back) exposes it. | Introduce `evicted_entry = hit ? tb_rdata_r[hit_index] : evict_entry`; have `out_dirty` and `out_tag` both source from `evicted_entry`. One-line semantic change. | `tb/cocotb/test_cbom_rmw_race.py` -- 4 directed scenarios; on broken RTL, `test_rmw_then_cbom_minimal` logs a `RACE CONFIRMED` warning and the mem-side AW appears at `awaddr=0x00000000` instead of the line's real address. With the fix in place, all 4 PASS. |

All sixteen fixes were caught by tests in this repo. Bugs #1-#3 by the
upstream SV directed suite, #4-#6 by the cocotb random scoreboard at
scale, #7 by the wide-port shim+cache TB at `BLOCK_W=512`, #8 by the
pytest matrix `POLICY=RANDOM` combo, #9 was a stale workaround whose
redundancy became provable after #7, and #10-#12 by the mid-burst-reset
+ adversarial-back-pressure tests (#11 had to be fixed first; it was
masking #10, which then exposed #12's mirror on the mem side). Bugs #13
and #14 were found by the OOC Vivado synthesis flow against Alveo U250
(`syn/vivado/run_synth.sh`) — #13 in the first ever Vivado build, #14
while developing the optional `DATABANK_SDP=1` UltraRAM-packing mode.
Bug #15 was found by the perf-sweep oracle (associativity scaling) while
adding `POLICY=GRASP` — functional tests passed because the RRIP-FP
fallback under a stripped address is itself correct; only the policy's
intent was being silently discarded. Bug #16 was found by directed
adversarial CBOM stress (`test_cbom_rmw_race`) — every existing CBOM
test pre-warm the line with a full-line read, which coincidentally
placed the line at the policy way and masked the wrong-way writeback;
breaking that pattern (single-beat partial write to an uncached line
followed by `CleanInvalid` back-to-back) reproduced the bug
deterministically.

---

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
| W beat selects the correct lane | AW FIFO orders {offset, tag} in AW arrival order; W beats pop in same order (AXI4 rule) |
| Buffer never returns stale data after write | Write-merge updates `lb_data` byte-by-byte in place at W-beat time |
| Buffer never holds CBOM data | CBOM rdata is `'x`; `cbom_outstanding_q[rid]` suppresses lb_fill on that response, and a CBOM AR that matches lb invalidates it |
| Buffer never holds aliased line | Tag = address bits `[ADDR_W-1:ALIGN_LSB]` (no hashing); only one line of state |
| Write back-pressure can never lose a W beat | `s_wready` gated by `~aw_fifo_empty` AND `m_wready`; `s_awready` gated by `~aw_fifo_full` |

### 8.5 What is NOT in the shim

* **No miss-under-miss** on the wide port: only one outstanding wide AR
  at a time. Adding it would require extending the per-rid tables to
  carry an "in-flight to wide" bit and forwarding fills to the right
  consumer (FIFO of pending narrow ARs per line).
* **No coalescing across lines**: only one line is cached in the L0
  buffer. A two- or four-line victim-style L0 would help workloads that
  ping-pong between a small set of lines; not implemented.
* **No WriteEvict bypass**: a narrow port cannot legitimately claim
  full-line coverage. If your accelerator can batch writes externally,
  give it a second wide path that bypasses the shim and joins the cache
  via an AXI crossbar.

### 8.6 Verification

| Test | What it proves |
|---|---|
| [test_narrow_shim.py](../tb/cocotb/test_narrow_shim.py) | 10 directed (cold/hot, buffer merge, AW FIFO, sub-word) + heavy random (50 000 ops × 5 seeds, byte-granular golden, 0 mismatches) |
| [test_shim_latency.py](../tb/cocotb/test_shim_latency.py) | per-op latency: cold-R=4, hot-R=3, write=5, merged-R=3 cycles |
| [test_shim_throughput.py](../tb/cocotb/test_shim_throughput.py) | hand-driven AR pump: 16 buffered reads in 18 cycles, ≈1 narrow R beat/cycle steady state |

All run shim-only against `AxiRam` (no `l2_cache` in the loop). Wiring
the shim in front of `l2_cache` end-to-end at `BLOCK_W=512` is the next
verification milestone.

---

## 8. Where to read further

* [INTERFACING.md](INTERFACING.md) — boundary spec, parameters, latency / throughput table, common back-ends.
* [../tb/cocotb/test_*.py](../tb/cocotb/) — executable specs of every cache behaviour (smoke, cbom, strobe, latency, random, scoreboard, matrix).
* RTL header comment in [`src/l2_cache.sv`](../src/l2_cache.sv) — definitive enumeration of design restrictions.
* The paper (`research/`) and thesis (`research/`) for the academic motivation, FPGA resource numbers, and design-space exploration the RTL is parameterised around.
