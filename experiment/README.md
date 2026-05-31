# Experimental: structural-pipeline timing push

**Branch:** `experiment/structural-pipeline`
**Status:** EXPERIMENTAL — do NOT merge to `main` without ALL gates green AND user sign-off.

## Why this branch exists

`main` closes 250 MHz baseline + 300 MHz with the documented knob combo
(`DB_LATENCY=3` + `SDP_WRITE_INPUT_REG=1` + aggressive PnR directives).
Pushing past that is structurally bound by:

- 1 MB / 8w on U55C tops out at ~288 MHz post-route (URAM cascade depth).
- 2 MB / 8w on V80 hits ~213 MHz wall; 350 MHz target is strictly worse
  than 300 MHz (66-URAM cascade as binding path).
- Tagbank BRAM enable path (`saved_arvalid` → 13 LUTs → BRAM ENARDEN)
  appears as the second binding path on the 512 KB tuned closure.

To go further requires RTL-structural changes (new pipeline stages,
control-flow restructuring) — the work that was deferred from the
sprint that took bugs #5–#13 to stabilize. These changes carry real
regression risk; this branch isolates them.

## Charter

Every commit on this branch MUST:

1. **Be a single structural change** (one pipeline boundary, one
   FSM rewrite, etc.) with a clear, written hypothesis about what
   path it breaks.
2. **Show measurable WNS improvement** at the target frequency on at
   least one of the validated post-route configurations (U250 512KB,
   U250 1MB, U55C 512KB, U55C 1MB).
3. **Pass full verification BEFORE the commit lands**:
   - `tb/cocotb/`: full module regression at the new pipeline knobs
   - `tb/cocotb/mutation_test.sh FILE=src/GRASP.sv`: 5/5 mutations
     KILLED
   - `tb/formal/`: 10/10 proofs PASS
   - `tb/cocotb/perf_300mhz.sh`: throughput at the new structure must
     not regress vs the main-branch 300 MHz baseline (+0 % minimum)
4. **Be reproducible**: the script in `experiment/verify.sh` runs all
   gates; commit message records the WNS delta and the verification
   output.

The gates are mechanical — `experiment/verify.sh` runs them all and
exits non-zero if any fail.

## Attack log

### Attack 1 — CASCADE_DEPTH as a tunable parameter — **LANDED**

Commit `7461357`. Promotes `CASCADE_DEPTH` from a `localparam = 8`
in `l2_databank.sv` to a `parameter` plumbed through `l2_cache.sv`
and `l2_top.sv`, with env-var forwarding in `run_synth.tcl`,
`u55c_synth_pnr.tcl`, `v80_synth_pnr.tcl`. Default unchanged (8).

Measured impact on the 300 MHz target (U55C 1 MB / 8w / GRASP /
SDP+URAM, DBL=3, WIR=1, aggressive PnR directives):

| `CASCADE_DEPTH` | WNS post-route | MHz | Δ vs CD=8 |
|---:|---:|---:|---:|
| 1 (no cascade) | -0.045 | ~296 | **+0.095 ns** |
| 2              | -0.282 | ~276 | -0.142 ns |
| 4              | -0.074 | ~293 | +0.066 ns |
| 8 (default)    | -0.140 | ~287 | — |

Cross-config at CD=1:
- U55C 512 KB: regresses from +0.127 → -0.072 (smaller URAM array
  doesn't need the cascading help; inter-URAM mux fanout dominates).
- U250 1 MB: marginal (+0.007 ns); already MET at baseline.
- U55C 1 MB: +0.095 ns improvement (the best case on UltraScale+).
- **V80 ES 512 KB**: +0.094 ns (-0.090 → **+0.004 ns post-route**,
  finally closes 250 MHz on the previously laggard ES silicon).
- **V80 ES 1 MB**: +0.521 ns (-1.370 → -0.849, 213 → 239 MHz).
- **V80 ES 2 MB**: +0.249 ns (-1.350 → -1.101, 214 → 226 MHz).

The V80 family responds far more strongly to CD=1 than UltraScale+
HBM. Reason: V80 uses the URAM288**E5** (Versal) primitive, which
has different CAS_OUT propagation characteristics than the URAM288
(UltraScale+) used on U55C / U250. The cascade is the dominant
binding path on V80 even at small sizes, so reducing CD always helps.

Per-board × per-size recommendation:

| Board | 512 KB / 8w     | 1 MB / 8w        | 2 MB / 8w        |
|---|---|---|---|
| U250 | `CD=8` (default) | `CD=1` (marginal +0.007 ns)   | not measured     |
| U55C | `CD=8` (default) | **`CD=1` (+0.095 ns, +8 MHz)** | not measured     |
| V80  | **`CD=1` (+0.094 ns, closes 250)** | **`CD=1` (+0.521 ns, +26 MHz)** | **`CD=1` (+0.249 ns, +12 MHz)** |

V80 gets the largest benefit from this attack — `CD=1` is the right
default for any V80 deployment regardless of size.

Verification: 19 / 19 modules, 5 / 5 GRASP mutations, 10 / 10 formal
all PASS.

### Attack 2 — Banked-SDP databank — **DEFERRED**

The design proposal already exists at
`doc/DESIGN_BANKED_SDP_DATABANK.md`. It scopes the work at ~2 weeks
(7 days RTL + 5 days verification + docs) and includes explicit
trigger conditions for when to implement: "a real production workload
shows the 6.3 % SDP throughput cost is binding". That trigger has not
fired. The throughput measurement on the 300 MHz tuned knobs (this
branch's perf reference) is +14–17 % vs the 250 MHz baseline, which
is much larger than the 6.3 % the banking would recover.

**Decision**: do not implement on this branch. Leaving the design
note as the future reference.

### Attack 3 — Tagbank output pipeline (`PIPELINE_DEPTH=0 → 1`) — **FAILED VERIFY, NOT LANDED**

Hypothesis: adding 1 register on the tagbank read output breaks the
`saved_arvalid → tagbank BRAM enable` binding path (the post-tuned
critical path on U55C 512 KB at 3.333 ns).

Result: the cache controller's `stage1 → stage2 → policy_update`
pipeline does not absorb the extra cycle without surgery. Smoke
tests + GRASP directed tests + flush + scoreboard all PASS (9/19),
but tests with realistic concurrency / backpressure / bursts FAIL:

  test_random              FAIL
  test_workload            FAIL
  test_reset_recovery      FAIL
  test_backpressure        FAIL
  test_strobe              FAIL
  test_cbom_stress         FAIL
  test_cbom_rmw_race       FAIL
  test_l2top               FAIL
  test_realism             FAIL
  test_finish_fifo_stress  FAIL

The single-line change (`PIPELINE_DEPTH(0) → PIPELINE_DEPTH(1)`) in
`src/l2_tagbank.sv:172` is reverted. Landing this attack requires
adding a matching pipeline stage to the cache controller — that is
Attack 4 territory.

### Attack 4 — Cache-controller FSM re-pipelining — **NOT ATTEMPTED**

Scope: insert one or more pipeline registers in the FSM's combinational
reductions across FIFO LFSRs that feed the data-bank write port mux,
absorbing the side effects on the `WRITING → READY → READING`
serialisation. Realistic estimate: multi-week, comparable to the work
that took bugs #5–#13 to stabilise.

**Decision**: out of scope for this session. The right path is a
dedicated effort with a separate verification protocol (re-derive the
formal invariants for the new FSM, extend the directed-stress matrix
for the new pipeline depth). This branch will not attempt it.

## What this branch ships if merged

Only Attack 1 is shippable today. Its merge value is small but real:
- New `CASCADE_DEPTH` parameter on `l2_cache` / `l2_top` / `l2_databank`.
- Default unchanged (no regression on existing deployments).
- Documented per-size recommendation (use CD=1 for 1 MB+, keep CD=8
  for ≤512 KB).
- Lifts U55C 1 MB from 288 to 296 MHz post-route on the 300 MHz target.

Attacks 2-4 remain documented as known follow-ups; Attack 2's design
note is in `doc/DESIGN_BANKED_SDP_DATABANK.md`, and the Attack 3
failure is reproducible (single-line revert) for any future attempt
at fixing the cache controller alongside the pipeline insertion.

## Merge criteria

This branch merges to `main` only when:

- All chosen attacks are landed AND functional
- Full gates green at every commit (no skipped tests)
- Post-route WNS improvement is reproducible on at least 2 of the
  validated configurations (not a single-config artifact)
- User sign-off on the verification output

Until then it lives at `origin/experiment/structural-pipeline` and is
explicitly NOT recommended for production deployment.
