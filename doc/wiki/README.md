# TableCache Documentation

This directory contains concise topic pages suitable for the GitHub Wiki.
In-tree documents remain the source of truth.

## Start here

| Need | Document |
|---|---|
| Integrate the cache | [../FPGA_INTEGRATION.md](../FPGA_INTEGRATION.md) |
| AXI and parameter contract | [../INTERFACING.md](../INTERFACING.md) |
| Internal architecture | [../ARCHITECTURE.md](../ARCHITECTURE.md) |
| Verification and test inventory | [../VERIFICATION.md](../VERIFICATION.md) |
| Board selection and timing | [../deployment/README.md](../deployment/README.md) |
| GRASP policy | [GRASP_Policy.md](GRASP_Policy.md) |
| UltraRAM databank | [URAM_Mode.md](URAM_Mode.md) |

## Supported configuration envelope

| Parameter | Constraint |
|---|---|
| `LINES` | power of two, at least 2 |
| `WAYS` | at least 1 |
| `LINE_W` | 2, 4, 8, or 16 |
| `BLOCK_W` | 8–1024 bits; power-of-two bytes |
| `DB_LATENCY` | 1 or 2 |
| Read/write ID widths | equal, at least 1 |
| Address range | naturally aligned power of two |
| Victim entries | at least 2 |
| SDP banks | power of two dividing `LINES` |
| Cascade depth | 1–8 |

Invalid configurations fail during elaboration.

## Verification layers

| Layer | Entry point |
|---|---|
| Directed and random simulation | `tb/cocotb/` |
| Configuration matrices | `test_matrix.py`, `test_shim_wrap_matrix.py`, `test_id_depth_matrix.py`, `test_geometry_matrix.py` |
| Formal | `tb/formal/` |
| Strict 4-state AXI VIP | `tb/vip/run_vip.sh` |
| Vivado synthesis | `syn/vivado/run_synth.sh` |
| Generic synthesis corners | `syn/vivado/generic_config_matrix.sh` |
| Full nightly flow | `tb/cocotb/night_run.sh` |

Detailed results, current test counts, and reproduction commands are maintained
in [../VERIFICATION.md](../VERIFICATION.md).
