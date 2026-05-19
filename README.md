# TableCache (fork)

[![regression](https://github.com/atmughrabi/TableCache/actions/workflows/regression.yml/badge.svg?branch=verification-and-shim)](https://github.com/atmughrabi/TableCache/actions/workflows/regression.yml)

Fork of [`sfu-rcl/tablecache`](https://gitlab.com/sfu-rcl/tablecache) (Chris
Keilbart, SFU RCL). This fork adds a cocotb regression, an AXI4 protocol
checker, a narrow-port shim, a whole-cache flush controller, a
yosys+z3 formal proof harness, and six RTL bug fixes.

Original RTL by upstream; modifications licensed under Apache-2.0 WITH
SHL-2.1 (see [LICENSE](LICENSE)). For background on the cache itself see
the [SFU thesis](https://summit.sfu.ca/item/39095) and the FPT 2024 paper.

---

## TL;DR

A configurable, ACE-Lite-snoopable L2 data cache for FPGA accelerators,
with a narrow-port shim, a flush sequencer, and a verification campaign
that pins it at:

- **20 cocotb modules / 62 tests** all PASS, AXI4 protocol-checker clean
- **88% Verilator** line+toggle coverage (98.7% on `l2_cache.sv`)
- **100% of reachable** functional coverage (covergroups + crosses)
- **100%** mutation score on **all 18** mutation-instrumented RTL files
  (3 documented no-op sets: `l2_hash`, `sdp_ram_rst`, `l2_top` -- mutations
  in those are either unreachable or out-of-test-scope)
- **k-induction formal proofs** on `fifo.sv` (DEPTH=1 and =4) and
  `set_clear_memory.sv` (DEPTH=4) -- 6 targets, all PASS
- **500-seed nightly stress** sweep, **26-config matrix** sweep (3 of
  them VICTIM=1: LRU/4, LRU/8, SRRIP/4), X-prop sweep, **200k-op
  workload** -- all clean.

## Quick navigation

| If you want to … | Read |
|---|---|
| **Use TableCache in your FPGA design** | [doc/FPGA_INTEGRATION.md](doc/FPGA_INTEGRATION.md) |
| Understand the AXI / snoop / flush contract | [doc/INTERFACING.md](doc/INTERFACING.md) |
| Understand how the cache works inside | [doc/ARCHITECTURE.md](doc/ARCHITECTURE.md) |
| Re-run / extend the verification | [doc/VERIFICATION.md](doc/VERIFICATION.md) |
| **Apply the methodology to your own RTL** | [doc/VERIFICATION_GUIDELINES.md](doc/VERIFICATION_GUIDELINES.md) |
| See residual risk + Xilinx VIP transition | [doc/VERIFICATION_XILINX_VIP_ROADMAP.md](doc/VERIFICATION_XILINX_VIP_ROADMAP.md) |
| Run a test right now | [Run tests](#run-tests) below |

## Contents

- [Layout](#whats-in-here)
- [Requirements](#requirements)
- [Run tests](#run-tests)
- [Coverage and seed sweep](#coverage-and-seed-sweep)
- [Lint and X-prop](#lint-and-x-prop)
- [Functional coverage](#functional-coverage)
- [Mutation testing](#mutation-testing)
- [Formal proofs](#formal-proofs)
- [Performance benchmark](#performance-benchmark)
- [Overnight stress run](#overnight-stress-run)
- [Test inventory](#test-inventory)
- [How to add a test](#how-to-add-a-test)
- [AXI4 limitations](#axi4-limitations)
- [Documentation](#documentation)
- [Bug fixes in this fork](#bug-fixes-in-this-fork)
- [Syncing from upstream](#syncing-from-upstream)

---

## What's in here

```
src/                  RTL (cache + narrow-port shim + flush controller)
tb/cocotb/            cocotb regression (19 modules, 60 tests)
tb/formal/            yosys+z3 SMTBMC harnesses (fifo.sv proofs)
tb/{Makefile,*.sv}    legacy SV directed TB (upstream)
doc/                  architecture, interfacing, integration, verification docs
```

## Requirements

| Tool          | Version       |
|---------------|---------------|
| Verilator     | >= 5.020      |
| Python        | >= 3.10       |
| cocotb        | 1.9.x (2.x needs Verilator 5.036) |
| cocotb-bus    | any           |
| cocotbext-axi | 0.1.28        |
| cocotb-coverage | < 2.0 (optional, for functional coverage; pins to cocotb 1.9.x) |
| pytest        | any           |

```bash
# one-time setup
cd tb/cocotb
python3 -m venv .venv && source .venv/bin/activate
pip install 'cocotb>=1.9,<2.0' cocotb-bus cocotbext-axi 'cocotb-coverage<2.0' pytest
```

## Run tests

```bash
cd tb/cocotb && source .venv/bin/activate

# single test
make MODULE=test_smoke

# full regression (19 modules)
for mod in test_smoke test_random test_scoreboard test_strobe test_latency \
           test_lru_sanity test_workload test_cbom test_reset_recovery \
           test_graph_patterns test_backpressure test_realism \
           test_finish_fifo_stress test_shim_prefill_race test_flush \
           test_shim_cache test_narrow_shim test_shim_latency test_shim_throughput; do
  rm -rf sim_build sim_build_shim
  timeout 600 make MODULE=$mod
done

# config-matrix sweep (22 combos: policy x ways x DB latency x victim x CBOM)
pytest -q test_matrix.py
```

A test passes when (a) cocotb reports `FAIL=0`, and (b) the log contains
zero `AXI_PC_VIOLATION` lines. The protocol checker output is summed into
`dut.pc_violations_total`; tests assert it stays at 0.

Knobs (set on the `make` command line): `POLICY={LRU,SRRIP,FRQ,SECOND_CHANCE,RANDOM}`,
`LINES`, `LINE_W`, `WAYS`, `DB_LATENCY`, `VICTIM={0,1}`, `CBOM={0,1}`.
The bare-cocotb path only supports `BLOCK_W=32`; use `MODULE=test_shim_cache`
for `BLOCK_W=512`.

## Coverage and seed sweep

```bash
# Line + toggle coverage (one test)
cd tb/cocotb && source .venv/bin/activate
rm -rf sim_build coverage.dat
COV=1 make MODULE=test_random NTXN=200
verilator_coverage --annotate /tmp/cov coverage.dat   # writes /tmp/cov/<file>.sv

# Merge across the regression
for mod in test_smoke test_random test_workload ...; do
  rm -rf sim_build coverage.dat
  COV=1 make MODULE=$mod >/dev/null && cp coverage.dat /tmp/$mod.dat
done
verilator_coverage --write /tmp/merged.dat /tmp/*.dat
verilator_coverage --annotate /tmp/cov /tmp/merged.dat
```

Baseline (Apr 2025): l2_cache.sv 98.7%, l2_databank.sv 99.7%,
LRU/fifo 99%, overall Verilator-coverage 88.0%.

```bash
# Random seed sweep (fails the whole sweep if any seed has PC>0 or FAIL>0)
cd tb/cocotb
N=32 NTXN=200 ./seed_sweep.sh                     # 32 seeds, 200 txns each
MODULE=test_workload N=8 NTXN=2000 ./seed_sweep.sh
```

## Lint and X-prop

```bash
cd tb/cocotb

# Strict-lint gate (production CI gate). Exits non-zero on any new latch,
# multi-driver, or unhandled width truncation.
make lint                                         # currently clean

# X-propagation: re-runs the regression with --x-assign unique --x-initial
# unique. Catches reset-then-read-before-fill bugs that Verilator's default
# (drive 0 on uninit) hides.
rm -rf sim_build && XPROP=1 make MODULE=test_random NTXN=200
```

Last XPROP run (12 modules / 31 tests): all PASS, 0 PC violations -- no
test depends on uninit / pre-fill data.

## Functional coverage

```bash
cd tb/cocotb
NTXN=300 ./cov_functional.sh           # runs instrumented tests + prints summary
```

Covergroups in [tb_coverage.py](tb/cocotb/tb_coverage.py); instrumented
by `test_random`, `test_cbom`, and `test_strobe`. Per-test XML at
`/tmp/tc_cov_<mod>.xml`. Architecturally unreachable cells (CBOM
snoops are 1-beat by ACE spec; WriteEvict is full-line only) are
excluded via `ign_bins`. **All per-channel coverpoints AND all crosses
hit 100%** of reachable cells.

## Mutation testing

```bash
cd tb/cocotb
./mutation_test.sh                                 # 12 mutations, ~5 min
TESTS="test_smoke test_random test_reset_recovery test_backpressure" ./mutation_test.sh
```

Applies per-file mutation sets to the RTL; reports KILLED / SURVIVED per
mutation. Current per-file scores:

| File | Score | Notes |
|---|---:|---|
| `l2_cache.sv` | **100%** | 10/10 mutations killed (one equivalent mutation excluded; see `mutation_test.sh`) |
| `tc_narrow_shim.sv` | **100%** | 7/7 killed; `drop_prefill_check` killed by `test_shim_prefill_race` under `TC_PROMOTE_WMISS=1` |
| `tc_flush_controller.sv` | **100%** | 6/6 killed by `test_flush` (3 scenarios) |
| `l2_databank.sv` | **100%** | 5/5 killed |
| `replacement_policy.sv` | 100% | 1/1 killed (`break_init_policy`) |
| `fifo.sv` | **100%** | 3/3 reachable killed (DEPTH=1 branch unused in design, mutations on it are equivalent and excluded); plus k-induction formal proof in `tb/formal/` |
| `toggle_memory.sv` | **100%** | 3/3 killed (covers `set_clear_memory` and cache inuse tables) || `lutram_1w_1r.sv` | **100%** | 2/2 killed (`drop_write_enable` excluded as equivalent) |
| `lfsr.sv` | **100%** | 1/1 killed |
| `sdp_ram.sv` | **100%** | 2/2 killed (tagbank + databank BRAM) |
| `victim_cache.sv` | **100%** | 4/4 killed (was 2/4 then 3/4). Required dirty-line eviction + multi-entry observation; see `test_victim` in tb/cocotb/. Requires `VICTIM=1` build |
| `LRU.sv` | **100%** | 2/2 killed (gen_4 branch, killed by `test_lru_sanity`) |
| `l2_tagbank.sv` | **100%** | 2/2 killed (one equivalent mutation `drop_tb_wen_gate` excluded) |
| `SRRIP.sv` | **100%** | 1/1 killed under POLICY=SRRIP (equivalent dead-branch mutation excluded) |
| `FRQ.sv` | **100%** | 1/1 killed under POLICY=FRQ |
| `second_chance.sv` | **100%** | 1/1 killed under POLICY=SECOND_CHANCE |
| `random_replacement.sv` | **100%** | 1/1 killed under POLICY=RANDOM |
| `tdp_ram.sv` | **100%** | 2/2 killed (contains bug #7 fix) |
| `one_hot_to_integer.sv` | **100%** | 1/1 killed |
## Formal proofs

```bash
make -C tb/formal all   # deps: yosys, z3, sv2v
```

Four targets covering both `fifo.sv` implementation branches:

| Target | Path | BMC depth | Induction |
|---|---|---:|---|
| `bmc` | DEPTH=1 (register) | 32 | PASS (k=14) |
| `induct` | DEPTH=1 | -- | PASS (k=14) |
| `bmc-deep` | DEPTH=4 (LFSR + LUTRAM, via `sv2v`) | 32 | PASS (k=24) |
| `induct-deep` | DEPTH=4 | -- | PASS (k=24) |
| `bmc-scm` | `set_clear_memory.sv` (DEPTH=4) | 16 | PASS (k=16) |
| `induct-scm` | `set_clear_memory.sv` | -- | PASS (k=16) |

Proven invariants (under a well-formed no-overflow / no-underflow
environment): `count <= DEPTH`, `valid == (count != 0)`,
`full == (count == DEPTH)`.

## Performance benchmark

```bash
cd tb/cocotb && source .venv/bin/activate
NTXN=5000 python3 perf.py            # ~4 min, all 5 policies
make perf                            # same, default NTXN
NTXN=3000 python3 perf_sweep.py      # ~12 min, 5 policies x 3 ways
POLICIES=LRU,SRRIP NTXN=10000 python3 perf.py
```

Hit-rate ranking on a 5000-op hot/cold graph-shaped workload
(`LINES=64 WAYS=4 LINE_W=8 SEED=1`):

| Policy | Hit rate | p50 hit (cyc) | p95 hit |
|---|---:|---:|---:|
| **`SRRIP`** | **74.3%** | 7 | 14 |
| `SECOND_CHANCE` | 70.4% | 7 | 14 |
| `FRQ` | 67.2% | 7 | 14 |
| `RANDOM` | 62.1% | 7 | 15 |
| `LRU` | 56.6% | 8 | 15 |

Detailed table + tuning notes in [doc/FPGA_INTEGRATION.md §10](doc/FPGA_INTEGRATION.md#10-performance-tuning-knobs).

## Overnight stress run

```bash
cd tb/cocotb
nohup ./night_run.sh > /tmp/tc_night/main.log 2>&1 &
tail -f /tmp/tc_night/summary.txt
```

4-phase pipeline (~4-8 hours total): 500-seed sweep on `test_random`,
200k-op `test_workload`, full pytest config matrix, and a mutation
re-baseline across all instrumented files. Per-seed sim_build is reused,
so the seed-sweep phase is dominated by simulation time not build time.

## Test inventory

Each test is one Python file under `tb/cocotb/`. Click for the full per-test
spec including what bug class it was designed to catch.

| Module | What it does |
|---|---|
| `test_smoke` | single full-line read miss; smallest viable build sanity |
| `test_random` | random R/W mix with golden scoreboard + per-line inuse-leak sweep |
| `test_scoreboard` | shadow tag model; observed mem AR count within +/-10% of prediction |
| `test_strobe` | hand-driven partial-WSTRB writes; checks unmasked bytes preserved |
| `test_latency` | first-beat hit / miss / RMW cycle counts vs numeric bounds |
| `test_lru_sanity` | strict-LRU eviction + thrash pattern (`WAYS+N` lines, same set) |
| `test_workload` | hot/cold graph-shaped 5 000-op stress; data + hit-rate + latency scoreboards |
| `test_cbom` | ACE-CBOM snoops: `CleanShared` / `CleanInvalid` / `MakeInvalid` |
| `test_reset_recovery` | 5 mid-burst-reset scenarios; verifies clean recovery + AXI4 B1 |
| `test_graph_patterns` | 5 graph kernels: pointer-chase, frontier-merge, CSR scan, vertex scatter, RMW contention |
| `test_backpressure` | 6 scenarios pausing each AXI READY independently and combined |
| `test_realism` | DDR-style sustained mem-R inter-beat latency (20/40/80) + long-idle reset recover |
| `test_finish_fifo_stress` | hot-set + heavy response back-pressure (drives `cp_*` cover points) |
| `test_shim_prefill_race` | direct-driven shim test targeting `drop_prefill_check` mutation; marked `expect_fail` (artifactual under default `PROMOTE_WMISS_TO_RW=0`) |
| `test_flush` | flush controller (4 scenarios): clean / dirty-writeback / idempotent / **cold-cache** (no pre-warm required) |
| `test_shim_cache` | shim + cache at `BLOCK_W=512`; RMW preservation tests for bug #7 |
| `test_narrow_shim` | shim alone against `AxiRam`; 10 directed + 1 random pass |
| `test_shim_latency` | shim cold/hot/write/merge cycle counts |
| `test_shim_throughput` | sustained 1 beat/cycle hit rate proof |
| `test_matrix` | pytest sweep: 5 policies x ways {2,4,8} x DB latency x victim x CBOM |

See [`doc/VERIFICATION.md`](doc/VERIFICATION.md) for the full spec of every
test.

## How to add a test

1. Create `tb/cocotb/test_<name>.py`:

```python
import cocotb
from cocotb.triggers import with_timeout
from tb_common import reset_dut, attach_master, attach_mem, golden

@cocotb.test()
async def test_my_case(dut):
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)
    op = await with_timeout(master.read(0x80001000, 4), 5_000, "ns")
    assert int.from_bytes(op.data, "little") == golden(0x80001000)
    assert int(dut.pc_violations_total.value) == 0
```

2. Run it: `make MODULE=test_my_case`.

3. If it's worth running in every regression, add the module name to the
   `for mod in ...` loop above and (optionally) to `test_matrix.py`'s
   parameter sweep.

Fixtures available from `tb_common`:
- `reset_dut(dut, cycles=None)` &mdash; drives reset, auto-sizes hold to LFSR-init window.
- `attach_master(dut)` &mdash; `cocotbext-axi` `AxiMaster` on `s_*`.
- `attach_mem(dut, size_bytes, seed_window_bytes)` &mdash; `AxiRam` on `m_*`, seeded with `golden()`.
- `golden(addr) = ((addr & 0xFFFF) << 16) | 0xCAFE`.

For back-pressure: `master.read_if.r_channel.set_pause_generator(gen)`
(or `b_channel`, or `ram.read_if.ar_channel`, etc. &mdash; see
`test_backpressure.py`).

For mid-burst reset / DDR latency: see `test_reset_recovery.py` and
`test_realism.py`.

## AXI4 limitations

- One outstanding request per ID.
- Bursts must stay within a cache line.
- `INCR` and `WRAP` only; `FIXED` is not supported.
- `AxLOCK` (EXCLUSIVE) is not supported.
- `arsnoop`: `CleanInvalid` (`4'b1001`), `CleanShared` (`4'b1000`), `MakeInvalid` (`4'b1101`); other encodings treated as regular reads.
- `awsnoop`: `WriteEvict` (`3'b101`) for full-line writes; others trigger RMW.

## Documentation

| File | Contents |
|---|---|
| [`doc/FPGA_INTEGRATION.md`](doc/FPGA_INTEGRATION.md) | end-to-end integration: param selection, topology choices, instantiation template, AXI compliance, bring-up checklist, debug aids |
| [`doc/INTERFACING.md`](doc/INTERFACING.md) | port spec, snoop encodings, reset semantics, shim ports, flush controller |
| [`doc/ARCHITECTURE.md`](doc/ARCHITECTURE.md) | cache internals, data flow, state-tracker table, bug history |
| [`doc/VERIFICATION.md`](doc/VERIFICATION.md) | per-test specification, AXI4 PC rule list, coverage matrix, mutation table, formal table |
| [`doc/VERIFICATION_GUIDELINES.md`](doc/VERIFICATION_GUIDELINES.md) | generic 8-layer methodology applicable to any RTL unit (cache, FIFO, FSM, accelerator) |
| [`doc/VERIFICATION_XILINX_VIP_ROADMAP.md`](doc/VERIFICATION_XILINX_VIP_ROADMAP.md) | residual-risk analysis + Xilinx VIP transition plan |

## Bug fixes in this fork

Each is one focused commit; see [`doc/ARCHITECTURE.md` &sect;7.5](doc/ARCHITECTURE.md#75-bug-history-already-fixed)
for details.

| # | File | One-liner |
|---|---|---|
| 4 | `l2_databank.sv` | reset `past_original_last` on READY->READING |
| 7 | `tdp_ram.sv` | per-byte NBA loop drops bytes at wide `BLOCK_W` on Verilator |
| 8 | `replacement_policy.sv` | `policy_t` zero-width when `POLICY=RANDOM` under Verilator 5.x |
| 10 | `l2_cache.sv` | slave-port VALIDs held one cycle into reset |
| 12 | `l2_cache.sv` | mem-port VALIDs held one cycle into reset (sibling of #10) |
| 13 | `l2_cache.sv` | CBOM-on-absent-line hung the response path; ar_fifo_push now gates out CBOMs (enables cold-cache flush) |

A self-bug #11 in `axi_protocol_checker.sv` (`vcount` multi-driver race
masking #10) was also fixed; see same section.

## Syncing from upstream

```bash
git fetch upstream
git checkout main && git merge --ff-only upstream/main && git push origin main
git checkout <feature-branch> && git rebase main
```
