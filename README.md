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

- **30 cocotb modules / 86 tests** all PASS, AXI4 protocol-checker clean
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
- **Address-aware GRASP** replacement policy with a configurable number
  of runtime hot/moderate region windows (`GRASP_HIGH_REGIONS` /
  `GRASP_MODERATE_REGIONS`, default 1) so multiple disjoint buffers can be
  pinned at once (12 directed cases incl. multi-window + 32/32 SDP
  cross-product PASS; 2-window formal proof).
- **Vivado OOC closure on U250** at 250 MHz for 512 KB/8-way SDP+URAM
  GRASP (WNS = +0.186 ns post-synth); U55C + V80 deployment presets at
  [`syn/vivado/u55c_synth.sh`](syn/vivado/u55c_synth.sh) and
  [`syn/vivado/v80_synth.sh`](syn/vivado/v80_synth.sh).

## Quick navigation

| If you want to … | Read |
|---|---|
| **Use TableCache in your FPGA design** | [doc/FPGA_INTEGRATION.md](doc/FPGA_INTEGRATION.md) |
| **Pick the right Alveo board + config** | [doc/deployment/](doc/deployment/README.md) — per-board reports (U250, U55C, V80) with validated post-route timing + multi-CU arithmetic |
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
- [Make targets cheat-sheet](#make-targets-cheat-sheet)
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
tb/cocotb/            cocotb regression (30 modules, 86 tests)
tb/formal/            yosys+z3 SMTBMC harnesses (fifo.sv proofs)
tb/{Makefile,*.sv}    legacy SV directed TB (upstream)
syn/vivado/           OOC synthesis flow (U250 default; U55C + V80 presets)
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

# full regression (30 modules)
for mod in test_smoke test_random test_scoreboard test_strobe test_latency \
           test_lru_sanity test_workload test_cbom test_reset_recovery \
           test_graph_patterns test_backpressure test_realism \
           test_finish_fifo_stress test_shim_prefill_race test_flush \
           test_grasp test_victim \
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

Knobs (set on the `make` command line): `POLICY={LRU,SRRIP,FRQ,SECOND_CHANCE,RANDOM,GRASP}`,
`LINES`, `LINE_W`, `WAYS`, `DB_LATENCY`, `VICTIM={0,1}`, `CBOM={0,1}`.
The bare-cocotb path only supports `BLOCK_W=32`; use `MODULE=test_shim_cache`
for `BLOCK_W=512`. `GRASP` uses runtime address-window ports
(`grasp_high_addr_l/h`, `grasp_moderate_addr_l/h`) driven from the test;
see [`tb/cocotb/test_grasp.py`](tb/cocotb/test_grasp.py). Each reuse class
can hold **N windows** via `GRASP_HIGH_REGIONS` / `GRASP_MODERATE_REGIONS`
(default 1); the multi-window suite needs them set at build time:

```bash
make MODULE=test_grasp_multi POLICY=GRASP \
     GRASP_HIGH_REGIONS=2 GRASP_MODERATE_REGIONS=2
```

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
make lint                                         # Verilator -Wall, ~1s

# Verible bug-class lint (curated rule set in .rules.verible_lint).
# Disables stylistic rules (line length, naming, etc.) on the upstream
# RTL; enables only the bug-finders.
make vlint                                        # ~1s, currently clean

# X-propagation: re-runs the regression with --x-assign unique --x-initial
# unique. Catches reset-then-read-before-fill bugs that Verilator's default
# (drive 0 on uninit) hides.
rm -rf sim_build && XPROP=1 make MODULE=test_random NTXN=200
```

Last XPROP run (12 modules / 31 tests): all PASS, 0 PC violations -- no
test depends on uninit / pre-fill data.

## Make targets cheat-sheet

| Target | What it does |
|---|---|
| `make MODULE=<test>` | Run a single cocotb test |
| `make lint` | Verilator strict lint, all RTL |
| `make vlint` | Verible bug-class lint (needs `verible-verilog-lint` in PATH or `~/.local/bin/`) |
| `make perf` | Run policy hit-rate benchmark (`tb/cocotb/perf.py`; default sweep includes GRASP) |
| `make wave` | Open the latest `dump.vcd` in GTKWave (re-run with `TRACE=1` first) |
| `make -C tb/formal all` | Run all 6 formal proof targets (yosys+z3, sv2v) |
| `./tb/cocotb/grasp_stress.sh` | GRASP-path hardening sweep (vlint + perf + XPROP + WAYS + seed sweep + SDP cross-product); `QUICK=1` for ~5 min subset |
| `./tb/cocotb/sdp_stress.sh` | DATABANK_SDP=1 random stress; default 100 seeds |
| `./syn/vivado/run_synth.sh` | OOC synth on U250 default; env vars override target, period, directive, policy |
| `./syn/vivado/sweep.sh` | 4-size × {TDP,SDP} U250 sweep; refreshes `sweep_results.md` |
| `./syn/vivado/u55c_synth.sh` | U55C (Alveo HBM) preset; `PNR=1` for full place+route closure |
| `./syn/vivado/v80_synth.sh` | V80 (Versal Premium) preset; `PNR=1` for full place+route closure |

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
| `bmc-flush` | `tc_flush_controller.sv` (LINES=4) | 32 | PASS |
| `induct-flush` | `tc_flush_controller.sv` FSM | -- | PASS (k=16) |

Proven invariants (under a well-formed no-overflow / no-underflow
environment): `count <= DEPTH`, `valid == (count != 0)`,
`full == (count == DEPTH)`.

## Performance benchmark

```bash
cd tb/cocotb && source .venv/bin/activate
NTXN=5000 python3 perf.py            # ~4 min, 6 policies (LRU,SRRIP,GRASP,FRQ,SECOND_CHANCE,RANDOM)
make perf                            # same, default NTXN
NTXN=3000 python3 perf_sweep.py      # ~15 min, 6 policies x 3 ways
POLICIES=LRU,SRRIP,GRASP NTXN=10000 python3 perf.py
```

Hit-rate ranking on a 5000-op hot/cold graph-shaped workload
(`LINES=64 WAYS=4 LINE_W=8 SEED=1`, GRASP region ports tied to 0 so
it runs in its SRRIP-FP fallback mode — `test_workload.py` is what
exercises the configured-hot-region case):

| Policy | Hit rate | p50 hit (cyc) | p95 hit |
|---|---:|---:|---:|
| **`SRRIP`** | **74.3%** | 7 | 14 |
| `GRASP` (regions=0) | 73.7% | 7 | 14 |
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

5-phase pipeline (~4-8 hours total): 500-seed sweep on `test_random`,
200k-op `test_workload`, full pytest config matrix, a mutation
re-baseline across all instrumented files (incl. `src/GRASP.sv`), and
the GRASP multi-window config matrix (`grasp_multi_matrix.sh`) + hit-rate
perf demo. Per-seed sim_build is reused, so the seed-sweep phase is
dominated by simulation time not build time. The heavy deterministic
GRASP sweeps (config matrix, mutation) live here in the local nightly
rather than per-PR CI, which runs the directed `test_grasp_multi` suite
(default + SDP+URAM) on every push.

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
| `test_flush` | flush controller (7 scenarios): clean / dirty-writeback / idempotent / **cold-cache** (no pre-warm) / **cold-cache CleanInvalid** / **multi-tag all-ways** / **scattered multi-tag** (whole-set by-index flush writes back + invalidates every way at any tag) |
| `test_grasp` | GRASP address-region policy (5 cases): hot-retention, SRRIP-FP fallback (regions=0), invalid region (`_h<_l`), runtime reconfig, hot/moderate overlap precedence |
| `test_grasp_multi` | GRASP with **N>1 windows** (5 cases): two disjoint buffers each pinned by their own high window; disabled (`_h=0`) window must not match; high+moderate windows coexist; top window slot (index N-1) effective; all-disabled SRRIP-FP fallback evicts. Build with `POLICY=GRASP GRASP_HIGH_REGIONS=2 GRASP_MODERATE_REGIONS=2`. Config matrix: `./grasp_multi_matrix.sh` (9 cells) |
| `test_grasp_multi_perf` | GRASP multi-window hit-rate demo: 4 disjoint buffers, fallback 0% vs single-window 25% vs 4-window 100%. Build with `POLICY=GRASP GRASP_HIGH_REGIONS=4` |
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
- `arsnoop`: `CleanInvalid` (`4'b1001`), `CleanShared` (`4'b1000`), `MakeInvalid` (`4'b1101`), `CleanInvalidByIndex` (`4'b1011`, whole-set/all-tags clean used by the flush controller); other encodings treated as regular reads.
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
| [`doc/DESIGN_BANKED_SDP_DATABANK.md`](doc/DESIGN_BANKED_SDP_DATABANK.md) | design proposal: 2-bank SDP databank successor to recover the 6.3 % throughput cost of `DATABANK_SDP=1` |
| [`doc/wiki/URAM_Mode.md`](doc/wiki/URAM_Mode.md) | **wiki-ready page** on the `DATABANK_SDP=1` UltraRAM mode — when to use it, what it costs, how to verify it fired |
| [`doc/wiki/GRASP_Policy.md`](doc/wiki/GRASP_Policy.md) | **wiki-ready page** on the GRASP address-region-aware replacement policy — usage, hit-rate stats, timing impact, verification (8 directed cases / 5-5 mutation / 5 formal proofs), bug history |
| [`doc/deployment/`](doc/deployment/README.md) | **per-Alveo deployment reports** (U250, U55C, V80) with validated post-route timing, multi-CU device-utilization arithmetic, recommended parameter values, and reproduction commands |
| [`syn/vivado/README.md`](syn/vivado/README.md) | out-of-context synthesis driver, headline U250 / U55C / V80 numbers, URAM mode usage, deployment presets, 8-way deployment matrix |
| [`syn/vivado/sweep_results.md`](syn/vivado/sweep_results.md) | full multi-config TDP-vs-SDP synth comparison (4 sizes × 2 modes, LUT/FF/BRAM/URAM/WNS); baseline + tuned sweeps; per-CU capacity for 16/32 CU deployments |

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
| 13 | `tdp_ram.sv` | `ram_style="ultra"` rejected by Vivado for TDP+byte-enable pattern; hard-coded to `"block"` |
| 14 | `l2_databank.sv` | new `DATABANK_SDP=1` UltraRAM mode initially closed a combinational loop and lost write data; chosen fix disables databank port 1 in SDP mode |
| 15 | `l2_tagbank.sv` | `policy_addr` projected from the tag-only view, hiding the `ADDR_RANGE_L` prefix from address-aware policies; GRASP silently degraded to RRIP-FP for every address ≥ `0x8000_0000`. Added `ADDR_BASE` parameter and OR it back in before passing to the policy. |
| 16 | `l2_tagbank.sv` | `out_dirty` and `out_tag` were unconditionally read from the policy-chosen replacement way's entry, so a CBOM `CleanInvalid`/`CleanShared` HIT on a line that lived in a different way issued the writeback using the wrong way's (typically zero) tag, sending the dirty data to mem address 0 instead of the actual line address. Introduced `evicted_entry = hit ? tb_rdata_r[hit_index] : evict_entry`. Surfaced by `test_cbom_rmw_race` -- the existing CBOM tests pre-warmed the line with a full-line read which masked the wrong-way path. |
| 18 | `l2_top.sv` | AXI wrapper tied `s00_axi_arsnoop`/`awsnoop` to 0 and forced `INCLUDE_CBOM=0`, so no CBOM or whole-cache flush worked through the wrapper. Forward the snoop sidebands and parameterize `INCLUDE_CBOM`. |
| 19 | `lfsr.sv`, `toggle_memory_set.sv` | 4-state (xsim) cold-init: the reset-walk LFSR powered up X, so `X<<1`/`XNOR(X)` stayed X and the tag/valid arrays never cleared. Declaration initializer `value='0` + mask external toggles during `init_clear`. (No-op on real HW where flops power to 0.) |
| 20 | `l2_cache.sv`, `sdp_ram.sv`/`tdp_ram.sv` | 4-state cold-init: unreset `bvalid_handled`/`rvalid_handled` + uninitialized databank BRAM data read X cold. Add resets + `= '{default:0}` INIT. |
| 21 | `toggle_memory.sv`, `toggle_memory_set.sv` | `toggle_memory` hard-tied `ram_write=1'b1`, so during reset the external ports wrote at X addresses and defeated the lutram 0-init. Added a `wen` port; gate external writes off during `init_clear` (clear-walk keeps writing). |
| 22 | `tc_narrow_shim.sv` | At `MAX_OUTSTANDING_W=1` (`FIFO_AW=$clog2(1)=0`) the AW-lane index `ptr[FIFO_AW-1:0]` was an illegal zero-width `[-1:0]` select, so write data was dropped. Derive `aw_wr_idx`/`aw_rd_idx` = const 0 at depth-1. The power-of-two guard advertised depth-1 as supported, so it was a real bug. |
| 23 | `l2_cache.sv`, `l2_tagbank.sv`, `tc_flush_controller.sv` | **Whole-cache flush could not flush a set-associative cache.** The controller drove per-line `CleanInvalid` whose tag came from the swept address (`tag = line_idx/num_sets`), so only tags `0..(walk/sets-1)` were cleaned; dirty lines with any other tag were silently never written back or invalidated. Added `CleanInvalidByIndex` (arsnoop `4'b1011`): the tagbank selects the WAY from the tag field's low bits (writeback uses the stored tag), and the controller walks `LINES*WAYS` (set x way). Per-line `CleanInvalid` unchanged. Regression: `test_flush_multitag_all_ways` (negative control with old mode fails). |
| 24 | `fifo.sv` | The over/underflow SVAs fired spuriously (~724x) during flush: the databank output-FIFO pop = `ready & valid` where `ready` depends combinationally on that FIFO's own valid, so xsim sampled `fifo_valid=X` in the assertion Preponed region even though the occupancy counter is provably never X. Guard both assertions with `~$isunknown(...)`; a genuine over/underflow drives full/valid to a known 1/0, so detection is preserved. |
| 25 | `l2_cache.sv`, `victim_cache.sv` | A base-0 full 32-bit cacheable range `[0,0xFFFFFFFF]` (the natural config when memory starts at 0, and the wrapper's own default) was un-elaboratable: `OMITTED_ADDR_W = 32-$clog2(ADDR_RANGE_H-ADDR_RANGE_L+1)` computes the span in 32-bit, so `0xFFFFFFFF-0+1` overflows to 0 → `OMITTED_ADDR_W=32` → `araddr[-1:2]` (VRFC 10-1219). Compute the span in 33-bit; make `OMITTED_CONSTANT` a full 32-bit value and reconstruct addresses via OR so `OMITTED_ADDR_W=0` works (zero-width-safe, like the `FIFO_AW=0` fix). Verified full-range T1-T6 in xsim + no regression at the default range. |
| 26 | `tc_narrow_shim.sv` | **Same-id pipelined reads returned the previous read's line ("one line off").** l2_cache is strictly 1-outstanding-per-id (a 2nd same-id read is stalled by `inuse_stall`), but the shim's wide-side `m_arvalid` lacked the `~rid_outstanding_q[s_arid]` gate that `s_arready`/`ar_miss_accept` carry. While a same-id read was in flight the shim kept asserting `m_arvalid`; if the cache's `m_arready` was high it accepted a *second* same-id AR (even though `s_arready` was held low), clobbering the cache's per-id line slot → the fill returned the previous read's line. Distinct-id multi-outstanding was always correct. Fix: gate `m_arvalid` on `~rid_outstanding_q[s_arid]`, and add `~prefill_active` to `ar_miss_accept` (it only had the 1-cycle `~prefill_ar_fire`) so accept and wide-AR-issue stay consistent (else a read accepted mid-prefill sets `rid_outstanding` without issuing an AR and wedges). Regression: `test_shim_multiread` (distinct-id overlap + same-id serialize, both data-checked). |
| 27 | `l2_databank.sv`, `l2_cache.sv` | **Whole-cache by-index flush hung at `DB_LATENCY>=2`** when a set had multiple dirty ways. The flush issues every CBOM with one reserved `FLUSH_ID`; the databank's READING premature-exit (aborts a discarded speculative clean read-miss) matched a discarded pipeline beat to the current read by **id alone**, so at a deeper read pipeline a stale prior same-`FLUSH_ID` discarded beat falsely aborted the current dirty-eviction read → incomplete writeback burst → hang. Uncaught because the flush matrix only ran `DB_LATENCY=1`; regular eviction works at higher latency. **Fix (`DB_LATENCY<=2`):** tag every databank read with a per-port **generation** (carried through the read info pipeline) and match the premature-exit on `{id, gen}`, so consecutive same-id reads are distinguishable. `DB_LATENCY=2` is the recommended URAM/large-cache config. **`DB_LATENCY>2` capped** (elaboration `$fatal` in `l2_cache`): a deeper pipeline also clobbers the id-keyed `way_table` lookup, whose fix needs gen-threading through the 3-stage tagbank — deferred; the flush is unsupported there, so fail the build loudly. Regression: `test_matrix` `ENRICH_MATRIX` `DB_LATENCY=2` cells (eviction + flush); verified no regression at `DB_LATENCY=1` (28/28). |

A self-bug #11 in `axi_protocol_checker.sv` (`vcount` multi-driver race
masking #10) was also fixed; see same section.

## Syncing from upstream

```bash
git fetch upstream
git checkout main && git merge --ff-only upstream/main && git push origin main
git checkout <feature-branch> && git rebase main
```
