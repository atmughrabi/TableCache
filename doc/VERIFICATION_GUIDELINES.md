# Verification Methodology — Generic Guideline

Distilled from the TableCache verification campaign. Applies equally to
caches, FIFOs, AXI bridges, FSMs, accelerators — any synthesisable
RTL unit. The same eight layers, in the same order, with the same exit
criteria.

For the concrete TableCache application of this template, see
[VERIFICATION.md](VERIFICATION.md). For RTL-style and Makefile-target
conventions, see the rest of the `doc/` tree.

---

## Layered approach

| # | Layer | What it answers | Cost | Run on every PR? |
|--:|---|---|---|---|
| 0 | **Lint & static** | "Is the RTL well-formed?" | seconds | yes |
| 1 | **Unit smoke tests** | "Does it boot, reset, and not hang?" | seconds | yes |
| 2 | **Directed scenario tests** | "Does each documented feature work in isolation?" | minutes | yes |
| 3 | **Protocol checker** (assertions on interface) | "Is every transaction legal?" | free (runs alongside) | yes |
| 4 | **Random / constrained-random** | "Does it survive a stream of legal traffic?" | minutes | yes |
| 5 | **Functional coverage** | "Did the random stream actually touch every interesting state?" | free (runs alongside) | yes |
| 6 | **Stress / soak** (long seed sweep) | "Does it survive 10⁴ different inputs?" | hours | nightly |
| 7 | **Mutation testing** | "Are my tests strong enough to catch a one-line bug?" | hours | weekly |
| 8 | **Formal proof** (SMTBMC / k-induction) | "Is the spec mathematically guaranteed?" | minutes (per harness) | weekly |

A unit is **considered verified** when layers 0-5 pass, layer 6 is clean
for the most recent nightly, and the layer-7 mutation score is ≥ 85% on
every hand-written file.

---

## 0. Lint & static checks

Tools: `verilator --lint-only`, `verible-verilog-lint`, optional `slang`.

- Treat **all warnings as errors** in CI. The cost of fixing a warning
  is always cheaper than the cost of debugging the bug it predicts.
- Lint independently of testbenches. The unit must lint clean against
  its own RTL, not just against the harness.
- Keep a `make lint` target. If the user runs nothing else before
  committing, they will at least run this.

## 1. Unit smoke tests

One test per top-level module. Each test:
- Asserts reset
- Drives ≤ 10 transactions
- Confirms the response handshake completes
- Tears down without hanging

Goal: catch resets that don't reach all flops, signal-direction typos
in instantiation, and missing module ports. Cost: <1 second per module.

## 2. Directed scenario tests

One test per **documented feature**. The features come from the
interface contract (`INTERFACING.md` in TableCache's case). For each:

- Construct the minimal stimulus that exercises the feature.
- Assert the externally observable response.
- Name the test after the feature so a failure points at the spec.

Examples from this campaign:
- `test_cbom_clean_shared`, `test_cbom_make_invalid` — one per snoop
  encoding.
- `test_flush_clean_state`, `test_flush_writes_back_dirty`,
  `test_flush_cold_cache` — one per flush scenario.

If you have to write a "miscellaneous" or "general" test, the feature
list is wrong, not the test list.

## 3. Protocol-level assertions

Assertions belong on the **interface**, not inside the implementation.
Implementation assertions catch only what the author thought to assert;
interface assertions catch every implementation that violates the
contract.

For AXI: use a pre-built protocol checker (e.g. cocotbext-axi's PC,
ARM AXI VIP, OpenIP `axi_pc`). For custom interfaces: write a small
SVA module that takes the interface as a port and asserts the handshake
rules (`valid` held until `ready`, `last` exactly once per burst, etc.).

The protocol checker runs **for free** alongside every other test —
adopt it once, get coverage on every layer-4/5/6 run forever.

## 4. Random / constrained-random

One module-level `test_random.py` (or SV `class my_seq extends
uvm_sequence`). Constraints:

- Bias toward **legal but varied** traffic. Random does not mean
  malicious; the protocol checker should never fire under random.
- Re-seed deterministically (`COCOTB_RANDOM_SEED`, or an explicit
  `--seed` arg). Every failure must be reproducible from a single
  integer.
- Run for **wall-clock time, not transaction count**. Wall-clock scales
  with simulator speed; transaction count distorts results when the
  RTL changes.

Goal: stack-rank bugs by how few transactions they take to surface.
The first bug found by random is almost always the next one to fix.

## 5. Functional coverage

Without functional coverage, "we ran 10⁶ random transactions" is
meaningless — they might have all been the same easy case.

For each random test:
- Define **per-channel** coverpoints: what was the size, the burst
  length, the snoop, the strobe pattern?
- Define **cross** coverpoints for combinations that matter (e.g.
  burst-length × snoop, ID × line, …).
- Mark **architecturally unreachable** combinations with `ign_bins`
  (e.g. ACE CBOMs are 1-beat by spec; document the constraint inline).
- A unit ships when coverage is 100% **of reachable cells**, not 100%
  of all cells.

Coverage is the test for the test. If a coverpoint is at 0%, your
constraints are wrong, not the RTL.

## 6. Stress / soak

A nightly run that:
- Cycles through 100-1000 distinct seeds of the random test.
- Cycles through every supported configuration in the parameter
  matrix.
- Targets a fixed wall-clock budget (e.g. 2-4 hours total).
- Logs the seed that produced any failure.

The first stress regression after a feature lands flushes out the
"works on my desk" class of bugs that no smaller test would have hit.

## 7. Mutation testing

Run a small set of **systematic source mutations** (`AND→OR`,
`EQ→NEQ`, `<→<=`, drop guard, swap state, …) against the RTL, then
re-run the test suite against each mutant. A test suite that catches a
mutation **kills** it. A surviving mutation is a verification gap:
either the test stimulus doesn't exercise that line, or no assertion
checks the affected behaviour.

Best practice:
- **Mutate one line at a time**. Larger mutations are equivalent to
  multi-bug scenarios that are uninteresting in isolation.
- **Six to twelve mutations per file** is enough. The goal is to
  measure test strength, not to enumerate every possible bug.
- **Score ≥ 85%** for any non-trivial RTL file. Anything less and the
  unit is under-verified, regardless of how many tests exist.
- **Equivalent mutations** (mutations that don't change observable
  behaviour) should be documented and excluded, not papered over.

A working script: `tb/cocotb/mutation_test.sh` in this repo — copy as a
template.

## 8. Formal proof

For invariants that **must always hold**, prove rather than test.
SMTBMC + k-induction with `yosys` and a free solver (`z3`,
`boolector`) is enough for most RTL units up to ~1k flops.

Best practice:
- Wrap the DUT in a small `_formal.sv` harness that:
  - Constrains inputs via `assume` to legal stimulus only.
  - Adds a reference counter / shadow state for the property.
  - Asserts the invariant on every cycle outside reset.
- Force the first cycle to be reset (`always_comb if ($initstate)
  assume(rst)`).
- Try **BMC first** (cheap; 32-64 cycles). If it passes, try
  **temporal induction** (`yosys-smtbmc -i`). Induction is an unbounded
  proof.
- If SV constructs trip yosys, lower the harness through `sv2v` to
  plain Verilog.

Worked example: `tb/formal/fifo_formal*.sv` + `tb/formal/Makefile`.

---

## Bug-life-cycle workflow

When you find a bug, do **all four** in this order:

1. **Reproduce** — add the failing transaction sequence as a directed
   test. Confirm it fails before any fix.
2. **Fix** — make the minimal RTL change. Re-run the directed test
   plus the full regression.
3. **Mutate** — add a mutation that reverts the fix (e.g.
   `drop_cbom_miss_gate`). Confirm the mutation is killed by your new
   directed test. This proves the fix is **load-bearing** and not
   accidentally redundant.
4. **Document** — one line in the project's bug log
   (`VERIFICATION.md` "Bug history" section). Future-you will thank
   present-you.

If you skip step 3, the next refactor will silently re-introduce the
bug.

---

## Anti-patterns to avoid

| Anti-pattern | Why it fails | Replace with |
|---|---|---|
| "It compiles, ship it" | Synth ≠ correct | Lint + smoke (layers 0-1) |
| "All my tests pass" | Tests might cover nothing | Coverage + mutation (layers 5+7) |
| "We use random, it's comprehensive" | Random without coverage is theatre | Coverage measurement |
| "We have 1000 tests" | Quantity ≠ quality | Mutation score |
| "I'll add tests later" | Later means never | Test-with-fix loop (workflow §3) |
| "Just rerun until it passes" | Hides flaky bugs | Always investigate first failure |
| Sticky-OR done signals | False completion under stall | Gate `done` on in-flight traffic, not just FSM state |
| Edge-detect on shared FIFO valid | Replay on backpressure | Pulse-on-meta-change per consumer |
| Random test with no seed log | Failure not reproducible | Print seed on every run |

---

## Tool stack used by this campaign

| Layer | Tool | Notes |
|---|---|---|
| Lint | `verilator --lint-only` | free, fast, strict |
| Simulator | `verilator 5.020` | with cocotb 1.9.x (cocotb 2.x needs Verilator 5.036) |
| TB framework | `cocotb 1.9.x` | Python-driven, no SV TB knowledge required |
| AXI BFM | `cocotbext-axi 0.1.28` | master + slave + PC |
| Coverage | `cocotb-coverage < 2.0` | covergroup-style; XML export merges across runs |
| Mutation | bash + sed (`tb/cocotb/mutation_test.sh`) | per-file mutation sets |
| Formal | `yosys 0.33` + `z3 4.8.12` + `sv2v 0.0.13` | SMTBMC + k-induction |
| Optional | `verible-verilog-format` / `verible-verilog-lint` | style enforcement |

All of the above are open-source and `apt`-installable on Ubuntu 22.04
(except sv2v — download the prebuilt Linux release binary).

---

## When to stop verifying

Diminishing returns are real. A unit is **done** when:

- Layer 0-5 are clean **and** are gating CI.
- Layer 6 ran clean against ≥ 500 seeds with no escapes for ≥ 1 week.
- Layer 7 score ≥ 85% on every hand-written file; all surviving
  mutations are either documented unreachable or have a tracking
  issue.
- Layer 8 proves the small set of "must-be-true" invariants you care
  about.

After that, additional tests have diminishing return; spend the budget
on the **next** unit or on integration verification instead.
