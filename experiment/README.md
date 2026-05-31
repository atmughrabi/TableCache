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

## Attack candidates (ordered lowest-risk → highest-risk)

1. **CASCADE_HEIGHT tuning** for `sdp_ram_uram` (parameter only, no
   RTL surgery). Shorter URAM cascade = faster propagation but more
   inter-URAM muxing. Quick experiment with no semantic change.

2. **Bank the SDP URAM array** (`doc/DESIGN_BANKED_SDP_DATABANK.md`
   proposal). Split the 16/34/66 URAM array into 2 banks with a port
   arbiter. Recovers the 6.3 % SDP throughput cost AND halves the
   cascade depth. ~2 weeks; significant FSM impact.

3. **Pipeline the tagbank output** (`PIPELINE_DEPTH=1` in
   `sdp_ram_padded_rst`). Adds 1 cycle to the tagbank read; the
   cache controller's `stage1 → stage2` pipeline needs to absorb the
   extra stage. Medium risk; touches the cache control flow.

4. **Cache controller FSM re-pipelining**. Break the combinational
   reductions across FIFO LFSRs that feed the data-bank write port
   mux. Highest risk — this is the surface that stabilized over bugs
   #5–#13.

Each attack lives in its own commit (or commit series), gated through
`experiment/verify.sh`.

## Merge criteria

This branch merges to `main` only when:

- All chosen attacks are landed AND functional
- Full gates green at every commit (no skipped tests)
- Post-route WNS improvement is reproducible on at least 2 of the
  validated configurations (not a single-config artifact)
- User sign-off on the verification output

Until then it lives at `origin/experiment/structural-pipeline` and is
explicitly NOT recommended for production deployment.
