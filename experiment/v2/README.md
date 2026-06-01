# TableCache v2 — Architecture Plan

**Status**: design + RTL-skeleton phase on `experiment/v2-architecture`.

v2 is a from-the-v1-baseline rearchitecture targeting the structural
ceiling that the Phase 2b attempts hit on v1. v1 (current `main`,
`src/l2_cache.sv`) is the stable production cache and stays
untouched in the tree. v2 lives at `src/v2/l2_cache_v2.sv` (and
sibling files) and is a drop-in alternative at the AXI boundary.

## Why v2 (not just keep optimizing v1)

v1 hit the architectural ceiling on three axes during the
experiment/banked-memory work:

1. **300 MHz wall on 1 MB+ caches** (U55C 1 MB closes at ~304;
   V80 1 MB caps at ~245). The binding paths are the cache
   controller's combinational reductions across FIFO LFSRs that
   feed the data-bank write mux + the tagbank BRAM enable.
2. **6.3 % SDP throughput cost** from port-1 disable. Cannot be
   recovered without FSM surgery (see Phase 2b post-mortem in
   `experiment/DESIGN_BANKED_MEMORY.md`).
3. **2 MB cache structurally bound to ~244 MHz** even with
   CASCADE_DEPTH=1 + bank=2 because of the 66-URAM cascade depth.

v1 was optimized for AMD's original TDP-DDR target. Modern URAM /
HBM deployments invert the assumptions; a clean redesign is
worthwhile.

## v2 design pillars

### 1. Per-bank FSM (replaces v1's single FSM with masked ports)

v1's FSM treats port 0 and port 1 as logically-equivalent ports of
ONE storage. v2 splits the storage into N independent banks, each
with its own SDP URAM and its own FSM. A request-router at the front
dispatches each AXI request to one bank-FSM by line-address LSB.

Win:
- Two concurrent requests on different banks serve in parallel
  natively — no arbiter needed, no stall logic, no replay buffer.
- Same-bank back-to-back requests serialize naturally through one
  bank-FSM (which is allowed to look like v1's FSM).
- Frequency: each bank-FSM is smaller (depth/N) so the per-bank
  cascade and tag/way fanout shrink with N. The cross-bank
  arbitration is only on the request-router (1 cycle).

### 2. Pipelined request-router

Front of the cache: AXI ar/aw is decoded and routed to the chosen
bank in a single cycle, with the bank-id added to the request
metadata. AXI response merges across banks at the back with a
round-robin / oldest-first arbiter.

Win:
- Cache controller's tightest combinational paths (the FIFO-LFSR
  to write-mux chain that was the binding path on v1 at 300 MHz)
  disappear because each bank's write-mux only sees its own
  bank's requests.
- The full-cache combinational fanout splits N-ways.

### 3. Native banked URAM / hybrid BRAM-tag

Each bank owns:
- Its own tag bank (BRAM, depth = LINES / N_BANKS)
- Its own data bank (URAM, depth = LINES / N_BANKS)
- Its own replacement-policy state (LRU/SRRIP/GRASP RRPV table)

Win:
- URAM/BRAM scalability: linear with N_BANKS (4 banks at 1 MB
  total = 4 × 8 URAM cascades of depth 2; vs v1's 1 × 32 URAM
  cascade of depth 4). Cascade depth becomes a tuning knob per
  deployment.
- BRAM tag footprint: 5 × N_BANKS small tag arrays instead of
  one large array. The aspect-ratio padding (Phase 1 of
  `sdp_ram_padded_rst`) optimises per bank.

### 4. ID-routed merge at the back

Read responses from banks are tagged with the originating
AXI ARID + bank-id. A small reorder buffer (1 entry per
in-flight ID, size = bound by `READ_ID_WIDTH`) merges them
back into AXI-spec order. Writes use AWID similarly.

### 5. Keep GRASP / SRRIP / LRU / FRQ / SECOND_CHANCE / RANDOM
unchanged

Replacement policy is per-bank but each bank still uses one of the
existing `replacement_policy.sv` instances. No policy logic change.

## What v2 does NOT do

- **Coherency**: still single-master AXI. ACE / CHI is out of scope.
- **Multi-clock**: single kernel clock. No CDC inside the cache.
- **New AXI features**: same AxLOCK/AxCACHE/AxQOS behavior as v1.
- **CBOM extensions**: same `CleanInvalid` / `CleanShared` semantics.
- **Victim cache integration**: out of v2 v1.0; add later if needed.

## Implementation plan

| Phase | What | Verification gate | Effort |
|---|---|---|---|
| **v2.0** | Skeleton: `l2_cache_v2.sv` that wraps v1's `l2_cache` 1× per bank with a request-router + response-merger. AXI-compatible at the boundary. | full module regression PASSES on `dut_v2_cocotb.sv`; throughput equals v1 at N_BANKS=1 (since one-bank v2 == v1) | 3-5 days |
| v2.1 | Replace v1's wrapped FSM with a v2-native per-bank FSM that doesn't need port-1-disable hacks | regression + mutation + formal | 1 week |
| v2.2 | Optimize the request-router for 350 MHz target on U55C 512 KB | post-synth + post-route sweep | 3 days |
| v2.3 | Add per-bank pipelined tagbank + databank for further frequency | binding-path analysis loop | 1 week |
| v2.4 | Full perf comparison vs v1 + per-board deployment-report updates | `perf_v2_vs_v1.sh` | 2 days |

**Total realistic effort**: ~3-4 weeks of focused engineering.

## Verification strategy

- `experiment/verify.sh` extended with `V2=1` mode that runs the
  v2 test wrapper (`dut_v2_cocotb.sv`) through the full module
  regression
- `mutation_test.sh` adds `src/v2/l2_cache_v2.sv:*` entries
- `tb/formal/` extends GRASP invariants to per-bank instances
- New `perf_v2_vs_v1.sh` runs `test_workload` on both wrappers
  and compares cyc/txn + projected throughput at each version's
  closing MHz

## Coexistence with v1

| Aspect | v1 (current) | v2 (this branch's target) |
|---|---|---|
| Top module | `src/l2_cache.sv` | `src/v2/l2_cache_v2.sv` |
| AXI wrapper | `src/l2_top.sv` | `src/v2/l2_top_v2.sv` |
| Cocotb DUT | `tb/cocotb/dut_cocotb.sv` | `tb/cocotb/dut_v2_cocotb.sv` |
| Synth preset | `syn/vivado/u55c_synth.sh` | `syn/vivado/u55c_synth_v2.sh` |
| Per-board defaults | unchanged | tuned for v2's expanded knob surface |
| User-facing module name | `l2_cache` | `l2_cache_v2` |

Both ship in the same release. Users explicitly pick `_v2`; default
references in docs continue to point at v1 until v2 graduates from
`experiment/`.

## Graduation criteria from `experiment/v2-architecture` to `main`

1. All v1 verification surfaces have v2 equivalents passing
2. v2 closes ≥ 350 MHz post-route on U55C 512 KB (vs v1's 312)
3. v2 throughput on `test_workload` ≥ v1 throughput at the same
   target MHz (any cycle-overhead is overcome by the MHz gain)
4. v2 deployment matrix documented in `doc/deployment/V2_*.md`
5. User sign-off on v2 vs v1 trade-off summary
