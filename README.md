<p align="center">
  <img src="doc/assets/logo.png" alt="TableCache logo" width="240">
</p>

# TableCache

[![regression](https://github.com/atmughrabi/TableCache/actions/workflows/regression.yml/badge.svg?branch=main)](https://github.com/atmughrabi/TableCache/actions/workflows/regression.yml)

Configurable FPGA L2 cache with cache maintenance, width adaptation,
deployment flows, and systematic verification.

TableCache is based on
[RTL by Chris Keilbart and SFU RCL](https://gitlab.com/sfu-rcl/tablecache).
See [LICENSE](LICENSE), the [SFU thesis](https://summit.sfu.ca/item/39095),
and the [FPT 2024 paper](https://doi.org/10.1109/ICFPT64416.2024.11113454).

## Capabilities

- AXI4 read/write interface with ACE-style cache-maintenance sidebands.
- Write-back, write-allocate data cache with configurable geometry.
- LRU, FRQ, second-chance, random, SRRIP, and GRASP replacement policies.
- Multi-window GRASP address regions for disjoint hot buffers.
- Optional victim cache.
- Whole-cache by-index clean/invalidate controller.
- Narrow-port shim with line buffering and optional read reordering.
- BRAM TDP and UltraRAM-oriented SDP databanks, including banking.
- Cocotb, formal, strict xsim AXI VIP, and Vivado OOC synthesis flows.

## Documentation

| Topic | Document |
|---|---|
| Documentation index | [doc/wiki/README.md](doc/wiki/README.md) |
| Integration and board deployment | [doc/FPGA_INTEGRATION.md](doc/FPGA_INTEGRATION.md) |
| AXI, snoop, parameters, and latency | [doc/INTERFACING.md](doc/INTERFACING.md) |
| Internal architecture and invariants | [doc/ARCHITECTURE.md](doc/ARCHITECTURE.md) |
| Verification methods and test inventory | [doc/VERIFICATION.md](doc/VERIFICATION.md) |
| GRASP policy | [doc/wiki/GRASP_Policy.md](doc/wiki/GRASP_Policy.md) |
| UltraRAM mode | [doc/wiki/URAM_Mode.md](doc/wiki/URAM_Mode.md) |
| Board-specific results | [doc/deployment/README.md](doc/deployment/README.md) |

## Repository layout

```text
src/            synthesizable SystemVerilog
tb/cocotb/      functional, protocol, matrix, and stress tests
tb/formal/      Yosys/SMTBMC proofs
tb/vip/         strict 4-state Vivado AXI VIP testbench
syn/vivado/     OOC synthesis, timing, and deployment scripts
doc/            architecture, integration, verification, and wiki pages
```

## Requirements

- Verilator 5.020 or newer
- Python 3.10 or newer
- cocotb 1.9.x
- cocotbext-axi 0.1.28
- pytest
- Optional: Verible, Yosys/Z3, Vivado 2025.2

```bash
cd tb/cocotb
python3 -m venv .venv
source .venv/bin/activate
pip install 'cocotb>=1.9,<2.0' cocotb-bus cocotbext-axi pytest
```

## Quick start

```bash
cd tb/cocotb
source .venv/bin/activate

# Functional smoke test
make MODULE=test_smoke

# Core configuration matrix
pytest -q test_matrix.py

# Generic width, ID, and geometry matrices
pytest -q test_shim_wrap_matrix.py
pytest -q test_id_depth_matrix.py
pytest -q test_geometry_matrix.py

# Static checks
make lint
make vlint

# Full overnight flow
./night_run.sh
```

Formal proofs:

```bash
make -C tb/formal
```

Strict 4-state AXI VIP:

```bash
./tb/vip/run_vip.sh
```

Vivado OOC synthesis:

```bash
./syn/vivado/run_synth.sh
./syn/vivado/generic_config_matrix.sh
```

## Core configuration

| Parameter | Supported values |
|---|---|
| `POLICY` | `LRU`, `FRQ`, `SECOND_CHANCE`, `RANDOM`, `SRRIP`, `GRASP` |
| `LINES` | power of two, 2–65,536 |
| `WAYS` | any integer at least 1 |
| `LINE_W` | 2, 4, 8, or 16 blocks |
| `BLOCK_W` | 8–1024 bits; power-of-two bytes |
| `DB_LATENCY` | 1 or 2 |
| `READ_ID_WIDTH`, `WRITE_ID_WIDTH` | equal, 1–15 |
| `ADDR_W` | 32–64 bits (geometry must leave at least one tag bit) |
| `ADDR_RANGE_L/H` | naturally aligned power-of-two range |
| `VICTIM_LINES` | at least 2 |
| `N_BANKS` | power of two that divides `LINES` |
| `CASCADE_DEPTH` | 1–8 |

The `l2_top` wrapper supports matched slave/master address widths from 32 to
64 bits, matched slave/master data widths, and a memory-side ID width equal
to the slave ID width plus one. The default remains 32-bit addresses.

Example: cache a 4 GiB window immediately above the 32-bit address space:

```systemverilog
l2_top #(
    .C_S00_AXI_ADDR_WIDTH (64),
    .C_M00_AXI_ADDR_WIDTH (64),
    .ADDR_L                (64'h0000_0001_0000_0000),
    .ADDR_H                (64'h0000_0001_FFFF_FFFF)
) cache (/* AXI ports */);
```

See [doc/INTERFACING.md](doc/INTERFACING.md) for ports, snoop encodings,
reserved IDs, burst rules, and integration constraints.

## Status

The supported parameter domains are enforced at elaboration. CI and nightly
flows cover functional matrices, long stress, protocol checks, mutation tests,
formal proofs, strict xsim configurations, and representative Vivado synthesis
corners. Current results and commands are maintained in
[doc/VERIFICATION.md](doc/VERIFICATION.md).
