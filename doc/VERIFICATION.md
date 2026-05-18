# Verification

What the cocotb regression in `tb/cocotb/` covers, and how it's organized.
Companion to [ARCHITECTURE.md §7](ARCHITECTURE.md), which lists gaps and
bug history.

## 1. Test inventory

16 modules, 50 individual tests. Listed in roughly the order you'd add
them when verifying from scratch.

| Module | Tests | Purpose |
|---|---:|---|
| `test_smoke` | 1 | single full-line read miss; build sanity |
| `test_strobe` | 2 | partial WSTRB merge (hand-driven; cocotbext-axi lacks per-beat strobe) |
| `test_lru_sanity` | 2 | strict-LRU eviction + thrash (`WAYS+N` lines same set) |
| `test_cbom` | 3 | `CleanShared` / `CleanInvalid` / `MakeInvalid` snoops |
| `test_latency` | 1 | hit / miss / RMW first-beat cycle bounds |
| `test_random` | 1 | uniform R/W mix + golden + per-line inuse-leak sweep |
| `test_scoreboard` | 1 | shadow tag model; mem AR count within +/-10% of prediction |
| `test_workload` | 1 | 5 000-op hot/cold stress; data + hit-rate + latency scoreboards |
| `test_reset_recovery` | 4 | mid-burst reset (4 scenarios) |
| `test_graph_patterns` | 5 | pointer-chase, frontier-merge, CSR scan, scatter, RMW contention |
| `test_backpressure` | 6 | each AXI READY paused independently + combined |
| `test_realism` | 4 | sustained mem-R latency (20/40/80) + long-idle reset |
| `test_finish_fifo_stress` | 2 | hot-set + heavy response back-pressure targeting `cp_finish_fifo_full` / `cp_same_target_suppression` |
| `test_shim_cache` | 7 | shim + cache at `BLOCK_W=512` (regression for bug #7) |
| `test_narrow_shim` | 10 | shim alone against `AxiRam` |
| `test_shim_latency` | 1 | shim cold/hot/write/merge cycle counts |
| `test_shim_throughput` | 1 | sustained 1 beat/cycle hit rate |
| `test_matrix` (pytest) | 22 | 5 policies x ways x DB-latency x victim x CBOM |

Each test file's module docstring explains what bug class it catches.
Read the file directly; the source is the spec.

## 2. AXI4 protocol checker

[`tb/cocotb/axi_protocol_checker.sv`](../tb/cocotb/axi_protocol_checker.sv)
is bound on every AXI bus of every DUT wrapper. Violations print
`AXI_PC_VIOLATION <rule> [%m @ %0t]: <msg>` and increment a counter
exposed as `dut.pc_violations_total`. Tests gate on
`int(dut.pc_violations_total.value) == 0`.

### Rules enforced

| ID | Rule |
|---|---|
| `B1` | `xVALID == 0` during `rst==1` (all 5 channels, deduped per reset) |
| `A1` | `xVALID` may not withdraw before `xREADY` |
| `A2` | payload stable while `xVALID && !xREADY` |
| `C1`-`C5` | burst encoding (`AxLEN`, `AxSIZE`, `AxBURST`, `WRAP` length+alignment, INCR 4 KiB boundary) |
| `C6` | `WLAST` on the `AWLEN+1`-th W beat of the oldest outstanding AW |
| `C7` | `RLAST` per ID on the `ARLEN+1`-th R beat |
| `D1`-`D4` | no response without matching outstanding request; no duplicate in-flight IDs |

Deferred: `E1/E2` response interleaving (vacuous under 1-outstanding-per-ID),
`E3` EXCLUSIVE (cache does not implement), `E4` X-prop (Verilator drives 0
on uninit), `E5` same-line R/W hazard.

### Per-instance trust knobs

| Knob | Default | Disable on | Reason |
|---|---|---|---|
| `CHECK_C6` | 1 | `pc_slave` (all wrappers) | cocotbext-axi 0.1.28 `AxiMaster` asserts `WLAST` on beat 1 of narrow multi-beat bursts |
| `CHECK_B1_RESPONSE_VALID` | 1 | `pc_mem` (all wrappers), `pc_slave` (shim wrappers) | cocotbext-axi `AxiRam` does not gate `rvalid`/`bvalid` through reset; shim combinationally reflects it |

Current wrapper settings are documented inline in each `dut_*.sv` file.

## 3. Running the regression

```bash
cd tb/cocotb && source .venv/bin/activate

for mod in test_smoke test_random test_scoreboard test_strobe test_latency \
           test_lru_sanity test_workload test_cbom test_reset_recovery \
           test_graph_patterns test_backpressure test_realism \
           test_shim_cache test_narrow_shim test_shim_latency test_shim_throughput; do
  rm -rf sim_build sim_build_shim
  if [[ $mod == test_random ]]; then
    NTXN=80 SEED=1 timeout 360 make MODULE=$mod > /tmp/pc_$mod.log 2>&1
  else
    timeout 600 make MODULE=$mod > /tmp/pc_$mod.log 2>&1
  fi
  pc=$(grep -c AXI_PC_VIOLATION /tmp/pc_$mod.log || true)
  tests=$(grep '\*\* TESTS=' /tmp/pc_$mod.log | tail -1)
  printf "%-26s PC=%s | %s\n" "$mod" "$pc" "$tests"
done
rm -rf sim_build .pytest_cache && pytest -q test_matrix.py
```

Pass criteria:
1. every module reports `FAIL=0`
2. every module reports `PC=0`
3. `pytest test_matrix.py` reports `22 passed`

## 3.1 Coverage

`COV=1` enables `--coverage --coverage-line --coverage-toggle`. Verilator
writes `coverage.dat` to the cocotb cwd. Merge across the regression and
annotate:

```bash
for mod in test_smoke test_random test_workload ...; do
  rm -rf sim_build coverage.dat
  COV=1 make MODULE=$mod >/dev/null && cp coverage.dat /tmp/$mod.dat
done
verilator_coverage --write /tmp/merged.dat /tmp/*.dat
verilator_coverage --annotate /tmp/cov /tmp/merged.dat
```

Baseline (12 tests, default config):

| File | Lines | Covered | % |
|---|---:|---:|---:|
| l2_cache.sv | 1425 | 1406 | 98.7 |
| l2_databank.sv | 379 | 378 | 99.7 |
| LRU.sv | 295 | 293 | 99.3 |
| fifo.sv | 139 | 138 | 99.3 |
| lfsr.sv | 99 | 98 | 99.0 |
| l2_tagbank.sv | 229 | 222 | 96.9 |
| sdp_ram*.sv | 238 | 229 | ~96 |
| replacement_policy.sv | 138 | 133 | 96.4 |
| dut_cocotb.sv | 296 | 264 | 89.2 |
| axi_protocol_checker.sv | 519 | 444 | 85.5 |
| **total** | 1296 | 1144 | **88.0** |

The uncovered residue in `l2_cache.sv` is largely error-path branches
(`assert property` else-blocks) and the unreachable `INCLUDE_VICTIM=0`
side of the gen-block when the matrix runs.

## 3.2 Random seed sweep

```bash
N=32 NTXN=200 ./seed_sweep.sh                     # default: test_random
MODULE=test_workload N=8 NTXN=2000 ./seed_sweep.sh
```

Fails (exits non-zero) if any seed reports `PC > 0` or `FAIL > 0`.
Per-seed logs go to `/tmp/tc_seedsweep_<module>/seed_<N>.log`.
Last run: `test_random N=32 NTXN=200` -- 32/32 OK, 0 PC, 0 FAIL.

## 3.3 Lint gate

```bash
make lint            # Verilator --lint-only -Wall with build-equivalent suppressions
```

Exits 0 only when there are no new latches, multi-drivers, or unhandled
bit-width truncations. The suppression list mirrors the build's
`EXTRA_ARGS` so any newly-introduced warning class fails the gate.
Current status: **clean**.

## 3.4 X-propagation

```bash
rm -rf sim_build && XPROP=1 make MODULE=test_random NTXN=200
```

`XPROP=1` adds `--x-assign unique --x-initial unique`. Verilator's default
drives 0 on uninit signals; this knob randomises them, so any test that
reads pre-fill / pre-reset data fails.

Last run (12 modules / 31 individual tests): all PASS -- no test path
depends on uninit data.

## 3.5 Functional coverage (cocotb-coverage)

Covergroups defined in [tb_coverage.py](../tb/cocotb/tb_coverage.py). Tests
instrument by calling `sample_read(addr, nbeat, snoop)` /
`sample_write(addr, nbeat, snoop, partial)` per AXI transaction.
Currently instrumented: `test_random`, `test_cbom`, `test_strobe`.

```bash
NTXN=300 ./cov_functional.sh
```

Writes per-test XML to `/tmp/tc_cov_<mod>.xml` and prints a merged
per-coverpoint hit summary. Latest baseline:

| Coverpoint | Hit/Total | % |
|---|---:|---:|
| `axi.r.nbeat` | 4/4 | 100 |
| `axi.r.snoop` | 4/4 | 100 |
| `axi.w.nbeat` | 4/4 | 100 |
| `axi.w.snoop` | 2/2 | 100 |
| `axi.w.partial` | 2/2 | 100 |
| `axi.r.beat_x_snoop` (cross) | 7/7 | **100** |
| `axi.w.beat_x_snoop` (cross) | 5/5 | **100** |
| `axi.w.beat_x_partial` (cross) | 8/8 | **100** |

All coverpoints AND crosses hit 100% of reachable cells. Architecturally
unreachable combinations (CBOM snoops are 1-beat by ACE spec;
WriteEvict is full-line only) are marked via `ign_bins` in
[tb/cocotb/tb_coverage.py](../tb/cocotb/tb_coverage.py).

## 3.6 SVA assertions + cover properties

Block at the bottom of [src/l2_cache.sv](../src/l2_cache.sv) (inside the
existing `ifndef ASSERT_OFF`). Three asserts catch the bug #2/#3/#6 class
at the cycle it occurs:

| Assertion | Catches |
|---|---|
| `inuse_id_no_same_cycle_collide` | tb_advance + finish_clear on the same `id` same cycle (bug #3 root cause) |
| `inuse_line_no_same_cycle_collide` | same, on the same `hash` (bug #6 root cause) |
| `finish_clear_implies_valid` | guards a future refactor that decouples `finish_clear` from `finish_valid` |

Four cover points report whether interesting traffic patterns are exercised.
Last hits (across `test_random` NTXN=200, `test_workload` NTXN=1000, and
`test_reset_recovery`):

| Cover | Hits | Note |
|---|---:|---|
| `cp_concurrent_issue_and_finish` | 62 | issue + finish overlap |
| `cp_inuse_stall_seen` | 4865 | inuse_stall path exercised |
| `cp_finish_fifo_full` | **0** | appears structurally unreachable under current config |
| `cp_same_target_suppression` | **0** | same |

Both zero-hit cover points were targeted by
[test_finish_fifo_stress.py](../tb/cocotb/test_finish_fifo_stress.py)
(16 distinct lines concurrent + 40-cycle pauses on s_rready/s_bready; also
alternating W/R on a hot line). Neither pattern moved the counters. The
conclusion is that upstream throttling (`inuse_stall` + request-FIFO
depth) keeps in-flight finishes below the FIFO depth of 4 -- the bug #6
fix path is structurally enforced rather than dynamically reached. The
cover properties remain as a regression net in case a future RTL change
relaxes the upstream throttle.

## 3.7 Mutation testing

```bash
./mutation_test.sh                                            # default: src/l2_cache.sv
FILE=src/tc_narrow_shim.sv ./mutation_test.sh
FILE=src/l2_databank.sv ./mutation_test.sh
```

Applies a per-file mutation set to the RTL (operator swaps, dropped
rst-gates, off-by-one on burst lengths, etc.), runs a subset of cocotb
tests against each mutation, and reports KILLED / SURVIVED. Survived
mutations are coverage gaps.

### Per-file scores

| File | Score | Killed | Survived | Notes |
|---|---:|---:|---:|---|
| `l2_cache.sv` | **100%** | 10 | 0 | One mutation (`LT_to_LE_arlen`) excluded as equivalent: targets a `$error` assertion not promoted to test failure under Verilator+cocotb; cocotbext-axi never drives the trigger condition. See comment in `mutation_test.sh` |
| `tc_narrow_shim.sv` | **100%** | 7 | 0 | `drop_prefill_check` killed by `test_shim_prefill_race` under `TC_PROMOTE_WMISS=1`; mutation regex now targets the `m_arvalid` line (not the first `s_arready` occurrence) |
| `tc_flush_controller.sv` | **100%** | 6 | 0 | drop_state_advance, swap_finish_arrow, negate_arvalid_gate, constant_zero_rready, wrong_addr_stride, skip_line_idx_inc |
| `l2_databank.sv` | **100%** | 5 | 0 | swap_state_idle, negate_ready_combine, flip_write_fifo_data, force_past_orig_keep, negate_out_fifo_push |
| `replacement_policy.sv` | 100% | 1 | 0 | `break_init_policy` killed by `test_lru_sanity` |
| `fifo.sv` | **100%** | 3 | 0 | `swap_count_pushpop`, `depth3_swap_waddr`, `depth2_swap_dout_index`. DEPTH=1 generate branch unused in this design (equivalent mutations excluded); also covered by formal proof in `tb/formal/` |
| `toggle_memory.sv` | **100%** | 3 | 0 | `drop_toggle_xor`, `force_toggle_always`, `swap_read_id_chain` |
| `lutram_1w_1r.sv` | **100%** | 2 | 0 | `swap_waddr_raddr`, `negate_dout`. `drop_write_enable` excluded as equivalent (held bus value identical to gated write under all consumers) |
| `lfsr.sv` | **100%** | 1 | 0 | `drop_lfsr_advance`. Other mutations excluded as equivalent (both feedback polarities walk all values; rst-clear covered by toggle_memory) |
| `sdp_ram.sv` | **100%** | 2 | 0 | `drop_a_en_write`, `swap_a_b_addr` |
| `victim_cache.sv` | 50% | 2 | 2 | `negate_hit` + `drop_buffer_tag_uncacheable` killed; `drop_invalidate_clear` + `swap_write_hit_check` survive even with directed `test_victim` scenarios -- need deeper investigation of the L1↔victim interaction protocol. VICTIM=1 path now reaches the file (was zero coverage before this iteration). Also covered in 3 matrix combos: LRU/4, LRU/8, SRRIP/4 |
| `LRU.sv` | **100%** | 2 | 0 | `gen4_flip_case0_evict` + `gen4_flip_case0_miss` killed by `test_lru_sanity`. Only gen_4 branch instrumented (default WAYS=4); other generates implicitly exercised by matrix |
| `l2_tagbank.sv` | **100%** | 2 | 0 | `negate_hit` + `swap_way_select` killed. `drop_tb_wen_gate` excluded as equivalent (CBOM-miss writes invalid over already-invalid entry) |
| `l2_hash.sv` | n/a | 0 | 0 | No effective mutations: hash quality affects performance, not correctness. `add_drop_plus1` (drop `+1` in bit sum) and `xor_fold_skip` (unreachable gen_full_hash branch) both equivalent under any functional check |
| `SRRIP.sv` | **100%** | 1 | 0 | `swap_insertion_bit` killed by test_lru_sanity (POLICY=SRRIP). `force_HP_decrement` excluded as equivalent (RRIP_HP=1 default makes FP branch dead) |
| `FRQ.sv` | **100%** | 1 | 0 | `flip_increment_trigger` killed (POLICY=FRQ) |
| `second_chance.sv` | **100%** | 1 | 0 | `swap_hit_bit_clear` killed (POLICY=SECOND_CHANCE) |
| `random_replacement.sv` | **100%** | 1 | 0 | `drop_rotate` killed (POLICY=RANDOM) |
| `LRU.sv` | deferred | 0 | 0 | per-WAYS generate branches make portable mutations hard; matrix sweep already exercises WAYS=2,4,8 |

## Formal proofs (yosys + z3 SMTBMC)

Location: `tb/formal/`. Run with `make -C tb/formal all` (deps: `yosys`, `z3`, `sv2v`).

| Module | Harness | BMC depth | Induction | Properties proven |
|---|---|---:|---|---|
| `fifo.sv` (FIFO_DEPTH=1, register path) | `tb/formal/fifo_formal.sv` | 32 | **k=14 PASS** | `count <= DEPTH`, `valid == (count != 0)`, `full == (count == DEPTH)` under well-formed (no-overflow, no-underflow) environment |
| `fifo.sv` (FIFO_DEPTH=4, `gen_width_3_plus`: lfsr + lutram) | `tb/formal/fifo_formal_deep.sv` (lowered via sv2v) | 32 | **k=24 PASS** | same invariants on the LFSR-pointer + LUTRAM implementation |

### l2_cache.sv mutation set (11 mutations)

| Mutation | Result |
|---|---|
| `EQ_to_NEQ_first` | KILLED |
| `AND_to_OR_finish` | KILLED |
| `LT_to_LE_arlen` | SURVIVED (assertion-only, unreachable) |
| `negate_arready` | KILLED |
| `swap_evict_priority` | KILLED |
| `off_by_one_arlen` | KILLED |
| `drop_rst_gate_bvalid` | KILLED (by `test_reset_with_bvalid_pending`) |
| `drop_rst_gate_rvalid` | KILLED |
| `drop_rst_gate_mem_arvalid` | KILLED |
| `constant_zero_bvalid_invalid` | KILLED |
| `swap_in_id_assignment` | NO-MATCH (refactor changed the pattern) |

### tc_narrow_shim.sv mutation set (7 mutations)

| Mutation | Result | Caught by |
|---|---|---|
| `negate_ar_hits_buffer` | KILLED | functional correctness (any test) |
| `drop_buf_drain_term` | KILLED | `test_shim_throughput` cycle-count check |
| `swap_arvalid_or` | KILLED | functional correctness |
| `negate_s_arready` | KILLED | functional correctness |
| `drop_prefill_check` | SURVIVED | needs pipelined W+R-to-different-line with mem stall |
| `swap_miss_to_hit_path` | KILLED | functional correctness |
| `drop_m_arready_dep` | KILLED | `test_mem_arready_backpressure` |

The remaining survivor `drop_prefill_check` removes the `& ~prefill_active`
guard from `m_arvalid`. cocotbext-axi serialises master operations, so a
W followed by an R complete sequentially and the race never triggers. A
hand-driven test that pipelines an AR for a different line while the
shim's prefill is in flight would close this. Tracked as TODO.

**Update (pending validation):**
[test_shim_prefill_race.py](../tb/cocotb/test_shim_prefill_race.py) drafts
the test (direct-driven s_aw*/s_w* then s_ar*, snoops m_arvalid handshakes
during prefill_active=1, asserts only PREFILL_ID survives). **Validation
result (overnight DEFERRED PHASE 5):**

* Functional: FAIL on clean RTL -- the test issues 1 AW + 1 R but the
  cache never produces a prefill AR because
  `PROMOTE_WMISS_TO_RW=1'b0` is the default (bug #9 fix). The mutation
  `drop_prefill_check` removes a guard on a feature that is OFF by
  default; the guard is **structurally unreachable** under the current
  default shim configuration.
* Mutation: the test was killing the mutation only because the test
  itself fails on clean RTL (any failing test "kills" everything). The
  100% score reported in the night-run summary is an artefact; the
  honest shim mutation score remains **85.7%**.
* Action: keep the test as a regression net for whoever flips
  `PROMOTE_WMISS_TO_RW=1` in the shim instantiation; do NOT add it to
  the default mutation set.

### Closing gaps surfaced by mutation testing

**l2_cache.sv: `drop_rst_gate_bvalid`** -- first mutation run flagged this
as surviving even with `test_reset_recovery` + `test_backpressure`. Root
cause: `test_reset_mid_write_burst` resets after AW + 1 W beat, before
`wdata_fifo_valid` rises. The fix was a one-test addition,
`test_reset_with_bvalid_pending`: pauses `s_bready` indefinitely via
`master.write_if.b_channel.set_pause_generator(always_pause())`, waits
for `s_bvalid` to rise, then asserts reset. Score 72.7% -> 90.0%.

**tc_narrow_shim.sv: `drop_buf_drain_term`** -- forcing
`ar_buf_drain_this_cycle = 1'b0` only stalls back-to-back buffered ARs
by 1 cycle each (data is still correct, only throughput drops). Closed
by adding `test_shim_throughput` to the shim's mutation test list:
`test_shim_throughput` already asserts `cycles <= RATIO + 8` (= 24 for
RATIO=16), and the mutation pushes it to ~2*RATIO. No new test needed.
Score 57.1% -> 71.4%.

**tc_narrow_shim.sv: `drop_m_arready_dep`** -- removing `& m_arready`
from `ar_miss_accept` lets the shim accept a slave AR before the wide
mem AR can fire. Closed by `test_mem_arready_backpressure` in
[test_narrow_shim.py](../tb/cocotb/test_narrow_shim.py): pauses
`m_arready` aggressively via
`ram.read_if.ar_channel.set_pause_generator(burst_pause())` and runs
8 W/R/R sequences across the back-pressure. Score 71.4% -> 85.7%.

## 4. Adding a test

Skeleton:

```python
import cocotb
from cocotb.triggers import with_timeout
from tb_common import reset_dut, attach_master, attach_mem, golden

@cocotb.test()
async def test_something(dut):
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)
    op = await with_timeout(master.read(0x80001000, 4), 5_000, "ns")
    assert int.from_bytes(op.data, "little") == golden(0x80001000)
    assert int(dut.pc_violations_total.value) == 0
```

Save as `tb/cocotb/test_<name>.py`. Run with `make MODULE=test_<name>`.
For matrix coverage add the module to `test_matrix.py`'s `MATRIX` list.

Useful fixtures and patterns:
- back-pressure: `master.read_if.r_channel.set_pause_generator(gen)` &mdash; see `test_backpressure.py`
- mid-burst reset: see helper `reassert_reset` in `test_reset_recovery.py`
- DDR-style mem latency: `ram.read_if.r_channel.set_pause_generator(fixed_latency_pause(N))` &mdash; see `test_realism.py`
- graph patterns / multi-ID concurrency: see `test_graph_patterns.py`

## 5. Coverage by feature

| Feature | Tests |
|---|---|
| read miss / read hit / write miss / write hit | smoke, random, scoreboard, latency, workload, matrix |
| partial WSTRB | strobe, shim-cache |
| `WriteEvict` (snoop=0b101) | random, workload, cbom |
| ACE-CBOM snoops | cbom, scoreboard, workload |
| multiple IDs (=4) | random, graph_patterns, reset_recovery, shim-* |
| back-pressure (default randomized) | random, scoreboard, workload, shim-* |
| back-pressure (adversarial pause) | backpressure |
| mid-burst reset | reset_recovery |
| long-idle reset | realism |
| sustained mem-R latency 20/40/80 cyc | realism |
| pointer-chase / dep-read chain | graph_patterns |
| same-set frontier merge | graph_patterns |
| CSR-style scan | graph_patterns |
| write-heavy scatter | graph_patterns |
| same-line RMW contention | graph_patterns |
| wide bus (`BLOCK_W=512`) | shim-cache, narrow-shim, shim-latency, shim-throughput |
| replacement policy sweep | matrix |
| victim cache on/off, CBOM on/off | matrix |
| DB latency 1/2/3 | matrix |

## 6. What is not covered

See [ARCHITECTURE.md §7.1](ARCHITECTURE.md#71-verification-gaps) for the gap
list and [VERIFICATION_XILINX_VIP_ROADMAP.md](VERIFICATION_XILINX_VIP_ROADMAP.md)
for the residual-risk analysis and proposed Xilinx VIP plan. Headline gaps:

- same-line write↔read hazard (rule E5)
- multiple distinct IDs targeting the same set
- EXCLUSIVE / FIXED-burst / AxCACHE / AxPROT semantics
- per-policy hit-rate floors (matrix asserts PASS, not performance)
- X-propagation (Verilator drives 0 on uninit)
- post-synth / post-route gate-level mismatches
- multi-master arbitration shim
- intermediate `BLOCK_W` (only 32 and 512 verified end-to-end)
- `LINES`, `ID_W`, `ADDR_RANGE` sweeps beyond defaults
