# Dataflow & FIFO Verification Checklist

A prescriptive, project-agnostic checklist for verifying dataflow designs
built out of engines, FIFOs, and topology-driven graphs of handshaked
streams (e.g. GraphBlox-style accelerators).

Distilled from the TableCache campaign (see
[VERIFICATION_GUIDELINES.md](VERIFICATION_GUIDELINES.md) for the
layered methodology this builds on) and from a parallel GraphBlox
campaign whose root-cause bugs are recorded in user memory
(`done_out_semantics`, `cu_setup_response_counter`,
`csr_index_trigger_gating`, `axi4_valid_reset_gating`,
`multi_driver_always_ff_silent_mask`).

Use it as a **gating checklist**: every item must be physically
verified (test exists, runs in CI, coverage point closed) before the
design is declared complete. "Reasoning that it must be correct" is
not verification.

---

## 0. Pre-flight: design inventory

Before any test is written, enumerate the system on paper:

- [ ] **Engine list** — every named state machine. Each has: parameters,
      inputs, outputs, reset behaviour, `done_out` definition, expected
      throughput, and trigger source (self / upstream packet / CSR).
- [ ] **FIFO list** — every FIFO instance. For each: width, depth,
      reset style (sync/async), `valid`/`ready` semantics, who pushes,
      who pops, expected backpressure source.
- [ ] **Edge list** — every handshaked stream between two engines.
      For each: producer, consumer, payload struct, max in-flight,
      ordering guarantee (ordered / unordered), backpressure path.
- [ ] **Topology graph** — nodes = engines; edges = streams. Mark which
      edges form **feedback loops** (highest deadlock risk) and which
      cross a **clock or reset domain**.
- [ ] **External-port inventory** — every boundary signal. Protocol
      (AXI4 / AXI-Stream / Avalon / custom). Width. Whether it has a
      protocol checker available.

If you cannot draw this on one page, the design is too coupled and
verification will be incomplete by construction. **Split it.**

---

## 1. Per-FIFO checklist

For every FIFO instance — not every FIFO module, every **instance**:

### Reset & init
- [ ] FIFO is empty after reset (`fifo_valid == 0`, `fifo_full == 0`,
      occupancy == 0). Smoke test asserts this in cycle 1 after reset.
- [ ] FIFO accepts no pushes during reset (push asserted with `rst=1`
      does not advance state).
- [ ] FIFO outputs **0 on every `valid`** during reset, not 1 cycle
      late. See `/memories/axi4_valid_reset_gating.md`. If the FIFO
      drives an AXI VALID directly, gate it combinationally with `~rst`.

### Single-producer / single-consumer
- [ ] Fill to capacity-1, capacity, capacity+1 — `full` asserts at the
      right occupancy; the +1 push is dropped or asserted-against.
- [ ] Drain to 0 — `empty` / `~valid` asserts at the right point;
      reading past empty is asserted-against or returns deterministic
      data.
- [ ] **Concurrent push+pop at full** — push and pop in the same cycle
      when occupancy == depth. Occupancy stays at depth.
- [ ] **Concurrent push+pop at empty** — should be impossible if
      consumer respects `valid`; assert it is.

### Backpressure
- [ ] Producer stalls indefinitely when FIFO is full and consumer is
      not popping. No silent data loss.
- [ ] Consumer stalls indefinitely when FIFO is empty. No phantom
      pops.
- [ ] Resume after stall — producer/consumer makes progress on the
      first cycle backpressure releases (no off-by-one).

### Ordering
- [ ] FIFO preserves order: write a 256-entry counting stream, drain
      it, check sequence matches.
- [ ] Width-preservation: pattern with every bit toggling — no bit
      slips, no struct-field permutation.

### Concurrency with reset
- [ ] Mid-burst reset: assert reset while half-full and being
      both pushed and popped. After deassertion: occupancy 0, no
      garbage on next pop.
- [ ] **Inter-test reset** (cocotb-style `reset_dut()`): same as above,
      because per-test resets within a single sim do NOT reset the BFM
      state on the other side. This is where `axi4_valid_reset_gating`
      bugs bite.

### Formal (when feasible)
- [ ] BMC ≥ depth+4 cycles: occupancy never wraps, `valid` never
      asserts when empty, `ready` never asserts when full.
- [ ] k-induction: same properties unbounded.
- [ ] Worked example: `tb/formal/fifo_formal*.sv`.

---

## 2. Per-engine checklist (state machines)

### State graph
- [ ] Enumerate every state. For each, document: entry condition, exit
      conditions (with priority), outputs asserted, expected duration.
- [ ] **No unreachable states** in synthesis (Verilator lint + formal
      reachability check).
- [ ] **No unintentional sticky states** — every non-terminal state
      has a guaranteed exit edge given expected inputs.

### Reset
- [ ] State at reset == documented IDLE state. Cycle-1 check after
      reset deassertion.
- [ ] All output signals from the engine are at their reset value
      while `rst=1`. Especially VALIDs, especially `done_out` (see §3).

### `done_out` semantics — the deadlock zone
This is the single biggest source of dataflow bugs. See
`/memories/done_out_semantics.md`. The checklist:

- [ ] `done_out` is **not** permanently `1'b0` anywhere in the engine
      hierarchy. (Wrapper passthrough, generator-level definition.)
- [ ] `done_out` is **not** a sticky-OR (`done_reg <= done_reg | x`).
      Sticky-OR causes false completion during stall.
- [ ] Generator-level `done_out = done_reg & ~response_in.valid &
      ~pipe_busy` — gated on in-flight traffic, not just FSM state.
- [ ] Wrapper-level `done_out` is a **direct flop pass-through** of
      generator `done_out`, never a sticky-OR.
- [ ] Per-engine smoke: assert reset → check `done_out==1` after one
      clock. Inject one trigger → check `done_out==0` while processing.
      Wait for finish → check `done_out==1` reasserts within bounded
      cycles.
- [ ] Kernel-level: AND of all engine `done_out` reaches 1 within
      bounded cycles after the last input is consumed. This is the
      single most important assertion in the system.

### Pipeline bookkeeping
- [ ] Counter that decrements on response receipt does **not**
      use level-sensitive `valid`. Counter pattern must be
      "pulse-on-meta-change with last-pulsed-offset tracking" (see
      `/memories/cu_setup_response_counter.md`).
- [ ] Counter resets to its load value on `counter_load`; the
      last-pulsed-offset tracker resets too.
- [ ] Counter cannot wrap below zero in any scenario. Assert
      `counter >= 0` (or that the underflow flag never asserts).

### Trigger sources
- [ ] If the engine is **source-capable**, document and test its
      self-trigger path.
- [ ] If the engine is **sink-only** (e.g. `CSR_INDEX` —
      `/memories/csr_index_trigger_gating.md`), document the required
      upstream trigger and write an integration test that drives that
      trigger from a real source.
- [ ] Topology check (run in CI from `topology.json`): every sink-only
      engine in a chain has at least one source-capable predecessor.
      Standalone sink-only engines flagged as **architecturally
      invalid**.

### `(P:N)` / `cu_vector` (or equivalent activation mask)
- [ ] At least one engine per algo carries the activation annotation.
      Missing annotation → `cu_vector = 0` → silent no-op (engine never
      receives cfg). See `/memories/csr_index_trigger_gating.md`.
- [ ] Integration test asserts `cu_vector != 0` before claiming success.

---

## 3. Per-edge checklist (handshaked streams)

For every engine-to-engine stream:

### Handshake legality
- [ ] `valid` is never asserted when payload contents are X (verilator
      `--x-assign unique` + assertion).
- [ ] `valid` held until `ready` (AXI-Stream rule). Protocol checker on
      every edge.
- [ ] `valid` drops to 0 the cycle reset asserts (same-cycle, not
      next-cycle). See `/memories/axi4_valid_reset_gating.md`.
- [ ] `ready` may withdraw freely before `valid` — assert there is no
      `ready` that depends on `valid` of the same edge (combinational
      loop risk).

### Throughput
- [ ] Maximum sustained throughput matches spec (every cycle, or
      every Nth cycle). Coverage point: `valid & ready` density over a
      long window.
- [ ] **Backpressure injection**: random-stall `ready` (50% drop) →
      payload integrity unchanged, only timing slower.

### Ordering & uniqueness
- [ ] If edge guarantees order: scoreboard with FIFO compare on
      ingress/egress over the entire random test.
- [ ] If edge carries a tag (ID, offset, request-id): no two beats
      with the same tag in flight; tag returns are unique.

### Replay / duplication hazard
- [ ] If multiple consumers share one producer's `valid` line through a
      FIFO, **do NOT edge-detect** the shared valid in any consumer.
      That breaks under bubble+replay. Each consumer must
      pulse-on-meta-change against its own tracked state
      (`/memories/cu_setup_response_counter.md` v3→v4 history).

### Cross-edge interactions
- [ ] **Feedback loops** in the topology: include a directed test that
      exercises the smallest loop at maximum traffic. Watch for fairness
      starvation.
- [ ] **Many-to-one merges** (arbiters): per-source fairness test —
      each source eventually wins.
- [ ] **One-to-many splits** (broadcasts): each consumer sees every
      beat, no losses, no duplications.

---

## 4. Dataflow / topology global properties

Properties that must hold across the entire engine graph:

- [ ] **Quiescence**: After the last input is presented and processed,
      every FIFO in the system reaches occupancy 0, every engine
      `done_out=1`, every in-flight counter == 0, and the kernel
      asserts global DONE. Assert all four in a single
      `test_quiescence_check`.
- [ ] **No deadlock under random backpressure**: random-stall every
      consumer `ready` (5-50% drop, per consumer) for the full random
      test. Quiescence must still be reached when stalls release.
- [ ] **No livelock**: progress metric (e.g. total bytes consumed,
      total kernel cycles since last accept) must monotonically advance
      on a rolling-window basis. Stall ≥ N cycles with non-zero
      pending → fail.
- [ ] **No silent vacuous pass**: a test that exercises 0 transactions
      MUST fail loudly. Concrete check: assert ≥1 trigger consumed by
      every engine the topology claims to use, before declaring PASS.
      See `/memories/csr_index_trigger_gating.md` "Vacuous-pass
      detection".
- [ ] **Reset recovery mid-flow**: assert reset with traffic in flight,
      deassert, run a fresh workload, expect identical output as a
      clean start.

---

## 5. External boundary checklist

For every external port (master & slave, every protocol):

- [ ] **Protocol checker** instantiated on the interface (AXI →
      cocotbext-axi PC, custom → hand-written SVA module on the iface
      port). Layer-3 of the methodology.
- [ ] Checker active during every layer-4/5/6 test, not just dedicated
      protocol tests.
- [ ] Boundary `valid` gated with `~rst` (combinational AND). Per
      `/memories/axi4_valid_reset_gating.md`.
- [ ] Reset compliance: master drops all VALIDs the cycle ARESETn
      drops, even mid-burst. Test: pause `ready` mid-burst, assert
      reset, check VALID==0 same cycle.
- [ ] Per-test reset (in cocotb regressions) does not violate
      protocol on the other side — known cocotbext-axi 0.1.28 issue
      with `b_valid`/`r_valid` requires the trust-knob pattern.

---

## 6. Anti-patterns — refuse at code review

Each of these has fired and cost ≥1 day to debug. They are not
hypothetical.

| Pattern | Failure mode | Replace with |
|---|---|---|
| `assign done_out = 1'b0;` | Permanent kernel-hang | Generator-level `done_reg & ~pipe_busy & ~valid_in` |
| `done_reg <= done_reg \| x;` (sticky-OR) | False completion under stall | Wrapper passthrough flop of generator `done_out` |
| Counter pulse from level `valid` | Counter wraps below 0 under bubble | Pulse-on-meta-change with last-pulsed-offset tracker |
| Counter pulse from `valid & ~valid_d1` (edge) | Undercount in bursts | Same — pulse-on-meta-change |
| Counter pulse from `valid & (~valid_d1 \| offset != offset_d1)` (v3) | Overcounts on bubble+replay | v4 with last-pulsed-offset latched separately |
| Same-edge driven from two `always_ff` (multi-driver) | Silent X masking, can hide adjacent bugs | Single always_ff per register, lint with verilator `--Wall` |
| AXI VALID = FIFO `valid` direct tie | VALID stays 1 cycle into reset → B1 violation | Gate combinationally: `axi_valid = fifo_valid & ~rst` |
| Two engines sharing one FIFO valid with edge-detect in each | Replay miscount on backpressure | Per-consumer pulse-on-meta-change |
| Sink-only engine standalone in a chain | Never consumes anything; vacuous PASS | Topology check + cu_vector>0 assertion |
| No `(P:N)` / activation annotation | `cu_vector=0`, engine never gets cfg | Assert at integration entry |
| `assert(condition)` in production RTL | Synth strips it; ⇒ false reassurance | Move to formal harness or SVA |
| Per-test `reset_dut()` without restarting sim | Stale BFM state crosses tests | Either restart sim per test, or rigorously gate VALIDs |
| Random test prints no seed | Failure not reproducible | Print `COCOTB_RANDOM_SEED` at every run start |
| "It compiles, ship it" | Synth ≠ correct | Lint + smoke + protocol checker |
| Test count as quality metric | 1000 tests can cover the same thing | Coverage + mutation score |

---

## 7. Coverage closure — the only meaningful "done" signal

A test count is meaningless. The completion criterion is:

- [ ] **Per-edge coverpoint**: `valid & ready` density buckets
      (0-25%, 25-75%, 75-100%) all hit.
- [ ] **Per-edge backpressure coverpoint**: `valid & ~ready` bursts of
      length 1, 2-5, 6-20, 20+ all hit.
- [ ] **Per-FIFO occupancy coverpoint**: 0, 1, depth/2, depth-1, depth
      all hit.
- [ ] **Per-engine state coverpoint**: every state entered ≥ 100×.
- [ ] **Per-engine transition coverpoint**: every legal transition
      taken ≥ 10×.
- [ ] **Topology cross-coverpoint**: for every feedback loop, the
      `(producer.state × consumer.state)` cross with non-trivial bins
      reaches ≥ 80% of legal cells.
- [ ] **Quiescence reached** at end of every random test (binary
      cover).
- [ ] **Architecturally unreachable** cells documented inline with
      `ign_bins` and a one-line justification each. No silent
      exclusions.

Coverage is the test for the test. A coverpoint at 0% means the
constraints are wrong, not the RTL.

---

## 8. Mutation suite — proves the tests are load-bearing

For every hand-written engine RTL file, ship 8–12 mutations covering:

- [ ] Drop a `done_out` gate term (`& ~pipe_busy` → ``)
- [ ] Flip an FSM transition condition (`==` → `!=`)
- [ ] Swap two FSM next-state assignments
- [ ] Drop a FIFO `full` check on a push
- [ ] Flip a `valid` gating polarity
- [ ] Replace `pulse-on-meta-change` with `level` on a counter
- [ ] Drop a reset clause from a register's `always_ff`
- [ ] Replace a `<=` with `<` (or vice versa) on a boundary check

A test suite is **strong** when it kills ≥ 85% of these. Surviving
mutants are unverified behaviours — either add a directed test or
document the mutant as equivalent.

See `tb/cocotb/mutation_test.sh` (TableCache) for a working template.

---

## 9. Pre-merge gating CI

A change does not land unless:

- [ ] `make lint` clean (lint as errors, not warnings)
- [ ] All smoke tests pass (one per module)
- [ ] All directed scenario tests pass (one per documented feature)
- [ ] Random test passes with ≥ 3 seeds × every supported config
- [ ] Coverage report shows no regression (per-edge, per-FIFO, per-state)
- [ ] Mutation score on changed files is ≥ 85%
- [ ] Protocol checkers fired zero violations
- [ ] If formal harness exists for the touched module, BMC re-runs
      clean

Nightly extends this with the full seed sweep (≥ 500 seeds) and the
mutation suite over the full RTL tree.

---

## 10. Bug discovery → bug closure workflow

Every bug, no exceptions:

1. **Reproduce**: minimal failing test added to the suite. Confirmed
   to fail against the unfixed RTL.
2. **Fix**: minimal RTL change. Full regression re-runs clean.
3. **Mutate**: add a mutation that reverts the fix. Confirm the new
   directed test kills it. This is the only proof the fix is
   load-bearing.
4. **Document**: one line in the project bug log (file location,
   trigger, fix, killing test).
5. **Memorise**: if the failure mode could plausibly recur in a
   different file or project, add it to `/memories/` so the next
   engineer (or LLM session) does not re-pay the debugging cost.

Skipping step 3 is the single most common verification anti-pattern;
refactors silently reintroduce bugs because no test ever proved the
fix was the load-bearing change.

---

## 11. Simulator & tool-stack choice

Verification methodology is simulator-independent, but the **tooling
trade-offs** affect what's cheap to check. Pick deliberately.

### Option A — Verilator + cocotb (TableCache baseline)
- Fastest sim (5-20× xsim). Critical for layer-6 seed sweeps.
- Free, no licence.
- Python-driven BFMs (cocotbext-axi). Good enough protocol checker for
  most rules; **misses some AXI4 corner cases** (e.g. cocotbext-axi
  0.1.28 has known `r_valid`/`b_valid` reset-gating bugs; see
  `/memories/axi4_valid_reset_gating.md`).
- Limited SVA support — most assertions live in cocotb Python or in
  small SVA wrappers `verilator` can parse.
- VHDL: not supported.
- **Recommended default** for layers 1-5 and the nightly seed sweep.

### Option B — Xilinx xsim + UVM + AXI VIP (strict path)
- Full SystemVerilog + UVM-1.2 + Xilinx AXI VIP (protocol checker is
  strictly spec-compliant, catches the corners cocotbext-axi misses).
- Native SV covergroups + `xcrg` for cross-run merge → richer coverage
  than cocotb-coverage.
- Mixed-language (VHDL + SV) native.
- 5-20× slower than Verilator. Vivado licence required on every CI
  runner.
- **Recommended** for once-per-PR VIP-strict run + as the gating tool
  for protocol compliance.
- See `doc/VERIFICATION_XILINX_VIP_ROADMAP.md`.

### Option C — xsim + cocotb (`SIM=xsim`)
- Reuse all existing Python tests.
- Loses Verilator's speed; gains nothing on protocol checking unless
  combined with AXI VIP.
- Useful only as a sanity escape hatch when a bug reproduces on xsim
  but not Verilator (or vice versa).

### Option D — formal (yosys + smtbmc + sv2v)
- Orthogonal to all the above. xsim does **not** replace formal.
- Use for must-be-true invariants: FIFO occupancy never wraps, global
  quiescence, deadlock freedom on critical loops.
- See `tb/formal/`.

### Recommended split

| Layer | Tool |
|---|---|
| 0 Lint | `verilator --lint-only` + `verible-verilog-lint` (free, fast) |
| 1 Smoke | Verilator+cocotb |
| 2 Directed | Verilator+cocotb |
| 3 Protocol | cocotbext-axi PC under Verilator, **+ AXI VIP on xsim per PR** |
| 4 Random | Verilator+cocotb |
| 5 Coverage | cocotb-coverage under Verilator, **+ SV covergroups + xcrg on xsim per PR** |
| 6 Stress | Verilator+cocotb (nightly, hundreds of seeds) |
| 7 Mutation | Verilator+cocotb (mutation_test.sh template) |
| 8 Formal | yosys + smtbmc + sv2v |

### Anti-pattern: single-tool dependence
Do not bet the entire campaign on a single simulator. Verilator silently
miscompiles patterns Vivado accepts (see bug #7 in TableCache:
`tdp_ram.sv` masked NBA drops bytes in Verilator at large NUM_COL).
Vivado/xsim silently accepts patterns Verilator rejects (lint warnings
that turn out to be real bugs in xsim). Running both, even at different
cadences, is cheap insurance.

### Tool-version pins that matter
- `verilator 5.020` ↔ `cocotb 1.9.x`. `cocotb 2.x` needs Verilator ≥5.036.
- `cocotbext-axi 0.1.28` has reset-gating bugs in `AxiRam`. Workaround:
  per-instance trust knob (see TableCache `CHECK_B1_RESPONSE_VALID`).
- `cocotb-coverage < 2.0` — the 2.x API differs.
- `yosys 0.33` + `z3 4.8.12` + `sv2v 0.0.13` for the formal stack.
- Vivado / xsim: pin to one version per release branch — `xsim` output
  format (.wdb, coverage DB) changes silently across versions.

---

## Appendix: When a dataflow design is "done"

Layer 0-5 (lint, smoke, directed, protocol, random, coverage) clean
**and gating CI**.
Layer 6 (≥ 500-seed nightly) clean for ≥ 1 week.
Layer 7 (mutation) ≥ 85% on every hand-written file; surviving mutants
documented as equivalent or tracked as gaps.
Layer 8 (formal) proves the must-be-true invariants — at minimum the
per-FIFO and the global quiescence properties.

Below that bar the design is **not** verified, regardless of how many
hours have been spent or how many tests have been written.
