# TableCache v2 architecture roadmap

v2 is a **sibling RTL family** at `src/v2/` that explores breaking
TableCache's structural ceilings (the 300+ MHz wall at 1 MB+, the
6.3% SDP throughput cost). v1 at `src/l2_cache.sv` ships unchanged
on `main`.

## Status

| Phase | Status | Outcome |
|---|---|---|
| **v2.0** skeleton | LANDED (`530656e`) | wrapper at N_BANKS_V2=1 == v1 passthrough |
| **v2.1** multi-bank | LANDED (`82a3cbd`) | per-bank v1 instances + router/merger; 17/19+10/10 verify (2 pre-existing main GRASP fails); ~15-30 MHz SLOWER than v1 at every freq target tested |
| **v2.2a** KEEP_HIERARCHY experiment | TRIED + REVERTED | `(* keep_hierarchy = "yes" *)` on bank_inst made U55C 1MB N=2 @ 300 MHz **worse** (-1.224 ns vs v2.1 -0.523 ns). Cross-bank "fusion" is Vivado optimizing; forbidding it forces longer per-bank routes. |
| **v2.2b** clean re-measurement at 250 MHz | DONE | v2 N=2/N=4 close to but DO NOT MEET 250 MHz on U55C; v2 fails by ~30 MHz on V80. v1 baseline MEETS 250 MHz on both boards. |
| **v2.2c** infra hardening | DONE | LOGDIR + flock around mutation_test.sh in verify.sh (prevents parallel-verify races that silently corrupted src/GRASP.sv); OUT override on synth scripts. |
| **v2.3** per-bank FSM redesign | NOT STARTED | the *only* remaining lever for a 300 MHz win on v2 (requires modifying v1's databank/FIFO internals) |
| **v2.4** perf + deployment | NOT STARTED | merge to main as opt-in if v2.3 delivers ≥ v1 freq |

## v2.2 honest result (current state)

### v2.2a — KEEP_HIERARCHY directive (reverted)

Hypothesis: v2.1's worst path crossing bank boundaries (`gen_bank[0]/.../lfsr_read_index → gen_bank[1]/.../mem_uram/CAS_IN`) is a placer fusion artifact; KEEP_HIERARCHY will keep banks isolated and improve timing.

Measured (U55C 1MB N=2 @ 300 MHz, CASCADE_DEPTH=8, DB_LATENCY=2):

| Build | WNS (ns) | MHz | Worst path LL | Notes |
|---|---|---|---|---|
| v1 N=2 baseline (v2.1 report) | -0.310 | 274 | 7 | single bank, in-cluster placement |
| v2.1 (no keep_hier) | -0.523 | 259 | 11 | cross-bank fused path |
| **v2.2a (keep_hier)** | **-1.224** | **219** | **12** | intra-bank, longer routes |

KEEP_HIERARCHY actually **regressed timing by 0.7 ns**. Conclusion: Vivado's
cross-bank fusion in v2.1 is *optimizing* shared LFSR / URAM control logic
across banks (legal because each bank's I/O is functionally independent but
many control signals have identical structure). Forbidding fusion forces
Vivado to route each bank's signals separately, lengthening the worst route.
Reverted. The bank_inst attribute is now a documentary comment in the RTL.

### v2.2b — clean re-measurement at 250 MHz

A bug in `experiment/verify.sh` left `src/GRASP.sv` in a mutated state when
multiple `verify.sh` runs landed in parallel (they all shared
`/tmp/tc_mutation` as backup dir; one run's mutated source was backed up
by another and "restored" to the mutated state on EXIT). The persistent
mutation silently corrupted in-flight synth runs. Fixed in `verify.sh`:
per-invocation `LOGDIR` + `flock` around the mutation phase. See
`.mutation_test.lock` and `$OUT/mutation_scratch/`.

All numbers below are **post-fix, on confirmed-clean `src/GRASP.sv`**.
The v2.1 commit's reported numbers are reproduced exactly at 300 MHz,
confirming the v2.1 measurements were clean.

| Board / Config | Target | WNS (ns) | MHz | vs target | vs v1 |
|---|---|---|---|---|---|
| U55C 1MB v1 N=2 | 300 MHz | -0.310 | 274 | fails | (baseline) |
| U55C 1MB v1 N=2 | **250 MHz** | **+0.071** | **254** | **MET** | (baseline) |
| U55C 1MB v2 N=2 cd=8 | 300 MHz | -0.523 | 259 | fails | **-15 MHz** |
| U55C 1MB v2 N=2 cd=8 | 250 MHz | -0.048 | 247 | close | **-7 MHz** |
| U55C 1MB v2 N=4 cd=8 | 250 MHz | -0.026 | 248 | close | -6 MHz |
| V80 512K v1 N=2 cd=1 | **250 MHz** | **+0.024** | **251** | **MET** | (baseline) |
| V80 512K v2 N=2 cd=1 | 250 MHz | -0.523 | 221 | fails | **-30 MHz** |

**v2 lags v1 by 3-30 MHz at every operating point measured.** At 250 MHz
on U55C v2 is *close* (within 3 MHz of MET, within 7 MHz of v1) but still
not deployment-grade. On V80 the gap is much larger (V80 ES silicon is
already tighter on routing/timing).

### Why v2 is slower than v1 (root cause)

Critical path is *inside* a bank's v1 cache (`out_fifo's lfsr_read_index →
URAM CAS_IN`, 11-12 logic levels, ~70% routing). Banking halves LINES per
bank but does NOT shorten this internal logic chain. v2's per-bank-full-v1-
cache wrapper additionally prevents v1's single-bank optimizer from compactly
placing one large cache. v1's Phase 2a `gen_banked_sdp` keeps ONE FSM +
splits only storage — still the smarter choice for max frequency on
small/medium deployments.

**Conclusion**: v2.1+v2.2 are correctness-complete but a frequency
regression at every operating point. **DO NOT MERGE v2 to main.** Branch
stays open as a documented exploration. The path to a frequency win
remains v2.3 — modify v1's `fifo.sv` / `l2_databank.sv` internals to
break the lfsr→URAM chain. That work is out of scope for the v2-wrapper
sprint.

## Design pillars (v2.0–v2.2 landed; v2.3+ pending)

1. **Per-bank dispatcher** (v2.1 ✓): N_BANKS_V2 v1 caches in parallel
   with address-bit router on slave side, bank-tagged ID widening
   on mem side.
2. **Pipelined request router** (v2.2 — investigated, no win): the
   diagnosis showed router/arbiter combinational depth is NOT on the
   critical path -- the worst path is fully inside a single bank's
   v1 databank. Skid buffers in the wrapper would add latency without
   recovering frequency. SKIPPED.
3. **KEEP_HIERARCHY isolation** (v2.2a — tried, REVERTED): see above.
4. **Native banked URAM/hybrid BRAM-tag** (v2.3): rebuild each bank
   without the v1 fill_count/wbe_table indirection; route directly
   to URAM BWE. Targets shortening the 9-LL path to 5-6 LL.
5. **ID-routed merge** (v2.3): replace at-most-1-outstanding-per-ID
   with a per-ID FIFO for in-flight tracking (recovers per-ID
   pipelining for high-throughput AXI masters).
6. **Unchanged GRASP/SRRIP/LRU policies**: v2 instantiates the same
   `replacement_policy.sv` per bank; no policy changes.

## What v2 explicitly does NOT do

- Coherency between banks (each bank is independent; same address
  always maps to ONE bank by design)
- Multi-clock domains (single `clk`/`rst` like v1)
- Wider mem-side AXI features (no AXI4/5 deltas; same channels as v1)

## How to use v2 (development only; not yet shipped)

Verification:
```bash
# Passthrough proof (must equal v1)
V2=1 N_BANKS_V2=1 ./experiment/verify.sh
# Recommended multi-bank
V2=1 N_BANKS_V2=2 ./experiment/verify.sh
# Max banking
V2=1 N_BANKS_V2=4 ./experiment/verify.sh
```

Perf comparison:
```bash
cd tb/cocotb
source .venv/bin/activate
python3 perf_v2_vs_v1.py
```

Synthesis (post-route, on confirmed-clean `src/GRASP.sv`):
```bash
cd syn/vivado
# 300 MHz target (v1 wins; v2 lags ~15 MHz)
TOP=l2_cache_v2 SIZE=1M N_BANKS_V2=2 PERIOD_NS=3.333 \
    CASCADE_DEPTH=8 DB_LATENCY=2 INCLUDE_VICTIM=0 PNR=1 \
    OUT="$PWD/build/u55c_v2_1m_n2_p300" ./u55c_synth.sh
# 250 MHz target (v1 MET +0.071 ns; v2 close, -0.048 ns ≈ 247 MHz)
TOP=l2_cache_v2 SIZE=1M N_BANKS_V2=2 PERIOD_NS=4.0 \
    CASCADE_DEPTH=8 DB_LATENCY=2 INCLUDE_VICTIM=0 PNR=1 \
    OUT="$PWD/build/u55c_v2_1m_n2_p250" ./u55c_synth.sh
# V80 ES (v1 MET +0.024 ns; v2 fails -0.523 ns ≈ 221 MHz)
TOP=l2_cache_v2 SIZE=512K N_BANKS_V2=2 PERIOD_NS=4.0 \
    CASCADE_DEPTH=1 DB_LATENCY=2 INCLUDE_VICTIM=0 PNR=1 \
    OUT="$PWD/build/v80_v2_512k_n2_p250" ./v80_synth.sh
```
The `OUT` env var on `u55c_synth.sh` / `v80_synth.sh` overrides the
default `build/<auto-tag>/` so multiple v2 measurements stay
distinguishable from each other and from v1 builds.

## Coexistence with v1

| Layer | v1 path | v2 path |
|---|---|---|
| Top-level | `src/l2_cache.sv` | `src/v2/l2_cache_v2.sv` (sibling) |
| AXI wrapper | `src/l2_top.sv` (uses l2_cache) | `src/v2/l2_top_v2.sv` (planned; uses l2_cache_v2) |
| cocotb testbench | `tb/cocotb/dut_cocotb.sv` | `tb/cocotb/dut_v2_cocotb.sv` |
| Per-board synth | `syn/vivado/{u55c,v80}_synth.sh` | same scripts with `TOP=l2_cache_v2 N_BANKS_V2=N` |
| User opt-in | `l2_cache` instance | `l2_cache_v2` instance (when v2 ships) |

Both v1 and v2 will ship together in the same release once v2 graduates.

## Graduation criteria (when to merge to main)

v2 may merge as an opt-in alongside v1 only when ALL of:
1. `V2=1 N_BANKS_V2={1,2,4} ./experiment/verify.sh` are GREEN
   (modulo any pre-existing main failures shared with v1)
2. `perf_v2_vs_v1.py` shows v2 cyc/txn >= v1 cyc/txn at the same
   workload (within +-5% variance)
3. Post-route MHz on U55C 1MB AND V80 1MB at the same target is
   >= v1 main (no frequency regression)
4. Documentation (root README, wiki, this file) updated

**v2.2 status**:
- Criterion 1: GREEN (same 17/19 as v1 main; the 2 failing GRASP
  tests `test_grasp_pressure` + `test_grasp_moderate` are pre-existing
  on main and NOT introduced by v2 — verified by running verify.sh
  at v1 baseline)
- Criterion 2: GREEN (within ±2% cyc/txn — see v2.1 commit)
- Criterion 3: FAILED at every operating point measured:
  - U55C 1MB @ 300 MHz: v2 N=2 −15 MHz vs v1
  - U55C 1MB @ 250 MHz: v2 N=2 −7 MHz vs v1 (MET but trailing)
  - V80 512K @ 250 MHz: v2 N=2 −30 MHz vs v1
- Criterion 4: done.

**Merge decision**: v2.1+v2.2 are **correctness-complete but DO NOT
MERGE as default or opt-in**. v1 wins on frequency at every target.
v2 stays on branch as a documented exploration pending v2.3 (per-bank
databank redesign that shortens the internal `lfsr_read_index → URAM
CAS_IN` chain). v2.3 is the only remaining lever for the v2-family.

## Implementation plan

| Step | File(s) | Effort | Status |
|---|---|---|---|
| v2.0 skeleton + N=1 passthrough | `src/v2/l2_cache_v2.sv` | 1 day | DONE |
| v2.1 router + merger + N>=2 | `src/v2/l2_cache_v2.sv` (inline) | 3 days | DONE |
| v2.1 cocotb harness | `tb/cocotb/dut_v2_cocotb.sv` + Makefile | 0.5 day | DONE |
| v2.1 verify.sh integration | `experiment/verify.sh` | 0.5 day | DONE |
| v2.1 perf comparison | `tb/cocotb/perf_v2_vs_v1.py` | 0.5 day | DONE |
| v2.1 PnR on U55C + V80 | `syn/vivado/*` (extended for TOP/N_BANKS_V2) | 0.5 day | DONE |
| v2.2a KEEP_HIERARCHY experiment | `src/v2/l2_cache_v2.sv` | 0.5 day | DONE (reverted) |
| v2.2b lower-freq measurement | (no RTL change) | 0.5 day | DONE |
| v2.2 OUT override in synth scripts | `syn/vivado/{u55c,v80}_synth.sh` | <0.1 day | DONE |
| **v2.3 per-bank databank redesign** | `src/v2/l2_databank_v2.sv` (NEW) | 5-7 days | TODO |
| v2.3 throughput recovery (ID-FIFO) | `src/v2/l2_cache_v2.sv` | 2-3 days | TODO |
| v2.4 perf + deployment reports | `experiment/v2/` | 2 days | TODO |
