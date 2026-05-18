# TableCache (fork)

Fork of [`sfu-rcl/tablecache`](https://gitlab.com/sfu-rcl/tablecache) (Chris
Keilbart, SFU RCL). This fork adds a cocotb regression, an AXI4 protocol
checker, a narrow-port shim, and five RTL bug fixes.

Original RTL by upstream; modifications licensed under Apache-2.0 WITH
SHL-2.1 (see [LICENSE](LICENSE)). For background on the cache itself see
the [SFU thesis](https://summit.sfu.ca/item/39095) and the FPT 2024 paper.

## What's in here

```
src/                  RTL (cache + narrow-port shim)
tb/cocotb/            cocotb regression (18 modules, 60 tests)
tb/{Makefile,*.sv}    legacy SV directed TB (upstream)
doc/                  architecture, interfacing, verification docs
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

# full regression (18 modules)
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

Covergroups in [tb_coverage.py](tb/cocotb/tb_coverage.py); currently
instrumented by `test_random` and `test_cbom`. Per-test XML at
`/tmp/tc_cov_<mod>.xml`. Last run hits 100% on snoop / partial cover-
points, 50% on burst-length (2/4-beat bins unfilled).

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
| `l2_cache.sv` | **90.0%** | 9/10 mutations killed; 1 survivor is an unreachable assertion bin |
| `tc_narrow_shim.sv` | **85.7%** | 6/7 killed; last gap (`drop_prefill_check`) needs cycle-accurate pipelined W+R stimulus |
| `l2_databank.sv` | **100%** | 5/5 killed |
| `replacement_policy.sv` | 100% | 1/1 killed (`break_init_policy`) |

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
| `test_shim_prefill_race` | direct-driven shim test targeting `drop_prefill_check` mutation (pending validation) |
| `test_flush` | flush controller integration test (clean / dirty / idempotent; pending validation) |
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
| [`doc/INTERFACING.md`](doc/INTERFACING.md) | port spec, snoop encodings, reset semantics, shim ports |
| [`doc/ARCHITECTURE.md`](doc/ARCHITECTURE.md) | cache internals, data flow, state-tracker table, bug history |
| [`doc/VERIFICATION.md`](doc/VERIFICATION.md) | per-test specification, AXI4 PC rule list, coverage matrix |
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

A self-bug #11 in `axi_protocol_checker.sv` (`vcount` multi-driver race
masking #10) was also fixed; see same section.

## Syncing from upstream

```bash
git fetch upstream
git checkout main && git merge --ff-only upstream/main && git push origin main
git checkout <feature-branch> && git rebase main
```
