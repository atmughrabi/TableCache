# Verification

TableCache verification combines directed simulation, randomized stress,
protocol checking, configuration matrices, mutation testing, formal proofs,
strict four-state simulation, and Vivado synthesis.

## Verification layers

| Layer | Entry point | Purpose |
|---|---|---|
| Verilator lint | `make lint` | elaboration, widths, drivers, and structural warnings |
| Verible lint | `make vlint` | selected semantic SystemVerilog rules |
| Cocotb | `make MODULE=<module>` | functional and protocol behavior |
| Pytest matrices | `pytest -q test_*_matrix.py` | parameter combinations and invalid configurations |
| Mutation | `mutation_test.sh` | sensitivity of directed regressions to RTL defects |
| Formal | `make -C tb/formal` | bounded and inductive invariants |
| Vivado AXI VIP | `tb/vip/run_vip.sh` | strict four-state reset and AXI behavior |
| Vivado synthesis | `syn/vivado/run_synth.sh` | FPGA inference, timing, and utilization |

## Running the tests

```bash
cd tb/cocotb
source .venv/bin/activate

make lint
make vlint
make MODULE=test_smoke

pytest -q test_matrix.py
pytest -q test_shim_wrap_matrix.py
pytest -q test_id_depth_matrix.py
pytest -q test_geometry_matrix.py
pytest -q test_mem_error_matrix.py

./l2top_matrix.sh
./grasp_multi_matrix.sh
```

The complete unattended flow is:

```bash
./tb/cocotb/night_run.sh
```

It runs random seeds, long workloads, parameter matrices, mutation suites,
GRASP checks, strict xsim configurations, and generic Vivado synthesis when
Vivado is available. Any failed section produces a nonzero exit status.

## Cocotb suites

### Core datapath and control

| Module | Invariant |
|---|---|
| `test_smoke` | cold read miss, fill, and response |
| `test_strobe` | partial-byte write merge |
| `test_random` | randomized read/write data integrity |
| `test_scoreboard` | tag-state model and bounded memory traffic |
| `test_workload` | locality, hit rate, and latency under mixed traffic |
| `test_latency` | hit, miss, and RMW latency bounds |
| `test_backpressure` | independent and combined READY stalls |
| `test_realism` | sustained memory latency and long idle intervals |
| `test_reset_recovery` | reset during active read and write traffic |
| `test_set_coverage` | set-index coverage |
| `test_line_allwords` | every word in a filled line |

### State, eviction, and maintenance

| Module | Invariant |
|---|---|
| `test_lru_sanity`, `test_lru_exact` | strict LRU selection |
| `test_victim` | victim hits, replacement, and dirty preservation |
| `test_eviction` | aligned and unaligned dirty writeback/refill |
| `test_flush` | by-index clean/invalidate across sets, ways, and tags |
| `test_cbom`, `test_cbom_rmw_race`, `test_cbom_stress` | maintenance semantics and serialization |
| `test_finish_fifo_stress` | completion pressure and occupancy release |
| `test_burst_idle` | same-ID eviction liveness across idle intervals |
| `test_inuse_race` | same-cycle occupancy set/clear protection |
| `test_mem_error_contract` | non-OKAY memory responses fail explicitly |

### Replacement policies

| Module | Invariant |
|---|---|
| `test_grasp`, `test_grasp_moderate` | GRASP reuse-class behavior |
| `test_grasp_multi` | multiple high and moderate windows |
| `test_grasp_midburst` | runtime region reconfiguration |
| `test_grasp_pressure`, `test_grasp_multi_perf` | retention under pressure |
| `test_graph_patterns` | pointer chase, frontier merge, scan, scatter, and RMW contention |

### Top-level and narrow-interface integration

| Module | Invariant |
|---|---|
| `test_l2top`, `test_l2top_flush`, `test_l2top_ids` | AXI wrapper, maintenance, and ID namespace |
| `test_narrow_shim` | lane selection, line buffer, AW FIFO, merge, and random traffic |
| `test_shim_cache` | end-to-end shim/cache fills, RMW, WRAP, and refill |
| `test_shim_latency`, `test_shim_throughput` | shim latency and sustained buffered reads |
| `test_shim_multiread` | distinct-ID overlap and same-ID serialization |
| `test_shim_reorder` | ordered delivery with multiple cache-side IDs |
| `test_shim_id_depth` | ID range, reserved ID, FIFO depth, and backpressure |
| `test_shim_buffer_snapshot` | delayed buffered response stability |
| `test_shim_prefill_race` | prefill arbitration |
| `test_shim_wrap_negative` | wrong WRAP-boundary negative control |

## Configuration matrices

| Matrix | Coverage |
|---|---|
| `test_matrix.py` | policies, associativity, databank latency, victim cache, CBOM, eviction, flush, and address ranges |
| `test_shim_wrap_matrix.py` | legal line lengths, block/narrow widths, ratios, TDP/SDP, latency, ways, reorder depth, and invalid line lengths |
| `test_id_depth_matrix.py` | ID widths, reorder depths, write FIFO depths, reserved IDs, and top-level ID mapping |
| `test_geometry_matrix.py` | line counts, odd and direct-mapped ways, policies, victim capacities, SDP banks, cascade depth, and invalid geometry |
| `test_mem_error_matrix.py` | read and write response errors with victim cache disabled and enabled |
| `l2top_matrix.sh` | top-level policy and associativity combinations |
| `grasp_multi_matrix.sh` | GRASP region counts and storage configurations |

Positive cells must report zero cocotb failures and zero
`AXI_PC_VIOLATION` messages. Negative cells must fail elaboration or simulation
with the expected parameter or response-contract diagnostic.

## AXI protocol checker

[`tb/cocotb/axi_protocol_checker.sv`](../tb/cocotb/axi_protocol_checker.sv)
is instantiated on each testbench AXI interface. It increments
`pc_violations_total` and emits `AXI_PC_VIOLATION` for:

| Rule group | Checks |
|---|---|
| `B1` | VALID low during reset |
| `A1` | VALID held until READY |
| `A2` | payload stable while stalled |
| `C1`–`C5` | burst length, size, encoding, WRAP alignment, and 4 KiB boundary |
| `C6`, `C7` | WLAST and RLAST framing |
| `D1`–`D4` | response/request matching and configured per-ID depth limits |

Cross-ID response ordering, EXCLUSIVE accesses, four-state propagation, and
same-line read/write semantics are verified outside this checker.

Response reset/stability checks are disabled only on interfaces driven by
`cocotbext-axi` `AxiRam`; every DUT-driven response interface remains strict.

At end of simulation, any nonzero protocol count raises a simulator error.
`check_results.py` also rejects failed cocotb JUnit results, so direct
`make MODULE=...` commands return nonzero on either functional or protocol
failure.

## Functional oracles

- Byte-accurate golden memories check returned and persisted data.
- `WritebackMonitor` verifies that every writeback covers exactly one line and
  follows INCR or WRAP addressing correctly.
- `MemRangeMonitor` verifies reconstructed memory addresses before testbench
  address masking.
- The strict-LRU oracle compares every hit, miss, and victim choice with a
  software queue.
- Response-framing checks require exactly one RLAST-terminated response per
  narrow request.
- The xsim monitor rejects unknown handshake signals and valid-qualified
  payloads after reset.

## Stress and coverage

```bash
cd tb/cocotb

N=32 NTXN=200 ./seed_sweep.sh
N_SEEDS=100 NTXN=100 ./sdp_stress.sh
./grasp_stress.sh
./grasp_soak.sh

COV=1 make MODULE=test_random
NTXN=300 ./cov_functional.sh
```

Verilator source coverage is emitted as `coverage.dat`. Functional coverpoints
sample burst length, snoop type, partial writes, and their reachable crosses.

## Mutation testing

`mutation_test.sh` applies file-specific mutations and runs the smallest suite
that must detect each change:

```bash
cd tb/cocotb
FILE=src/l2_cache.sv ./mutation_test.sh
FILE=src/tc_narrow_shim.sv ./mutation_test.sh
FILE=src/l2_databank.sv:sdp ./mutation_test.sh
```

The nightly flow requires a 100% score for each instrumented target.
Equivalent or unreachable mutations are excluded with a local rationale.

## Formal verification

```bash
make -C tb/formal all
```

| Harness | Proven properties |
|---|---|
| `fifo.sv` | occupancy bounds and VALID/FULL consistency |
| `set_clear_memory.sv` | state matches a reference occupancy model |
| `tc_flush_controller.sv` | request framing, response gating, index bounds, and completion |
| `GRASP.sv` | replacement range, one-hot choice, region precedence, and disabled-region fallback |

The formal environment constrains protocol violations such as overflow,
underflow, and simultaneous set/clear of one entry.

## Strict xsim and synthesis

```bash
./tb/vip/run_vip.sh
./tb/vip/run_shim_ratio1.sh
./syn/vivado/run_synth.sh
./syn/vivado/generic_config_matrix.sh
```

The AXI VIP testbench covers cold reset, cold and warm flush, fills, writes,
dirty eviction, victim caching, SDP banking, non-default ID widths, odd
associativity, and base-zero address ranges. The RATIO=1 shim test is kept
separate because out-of-range part-selects can be masked by two-state
simulation.

## Residual scope

The repository does not model:

- AXI EXCLUSIVE accesses
- multiple independent upstream masters
- clock-domain crossings
- recoverable memory errors
- exhaustive post-route coverage of every legal parameter combination

TableCache requires one clock domain and an error-free memory backend. Exact
performance remains workload-, memory-, board-, and floorplan-dependent.
