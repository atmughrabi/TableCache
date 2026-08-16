# Vivado Out-of-Context Synthesis

The scripts in this directory synthesize TableCache modules without board-level
I/O. They report utilization, primitive inference, and timing feasibility.

## Requirements

- Vivado 2025.2
- Default part: `xcu250-figd2104-2L-e`
- Default period: 4.0 ns

Override the executable with `VIVADO=/path/to/vivado`.

## Basic usage

```bash
cd syn/vivado

# l2_cache, default parameters
./run_synth.sh

# another top
TOP=tc_narrow_shim ./run_synth.sh
TOP=l2_top ./run_synth.sh

# representative generic corners
./generic_config_matrix.sh
```

## Cache parameters

```bash
TOP=l2_cache \
WAYS=8 LINES=1024 LINE_W=16 BLOCK_W=32 POLICY=5 \
READ_ID_WIDTH=4 WRITE_ID_WIDTH=4 \
DATABANK_SDP=1 DB_LATENCY=2 SDP_WRITE_INPUT_REG=1 \
CASCADE_DEPTH=4 N_BANKS=2 INCLUDE_VICTIM=0 \
./run_synth.sh
```

Supported overrides:

- geometry: `WAYS`, `LINES`, `LINE_W`, `BLOCK_W`
- policy: `POLICY`, `GRASP_HIGH_REGIONS`, `GRASP_MODERATE_REGIONS`
- IDs and address: `READ_ID_WIDTH`, `WRITE_ID_WIDTH`, `ADDR_W`
- storage: `DATABANK_SDP`, `SDP_WRITE_INPUT_REG`, `CASCADE_DEPTH`, `N_BANKS`
- optional structures: `INCLUDE_VICTIM`, `VICTIM_LINES`

For `TOP=l2_top`, use `REPLACEMENT_POLICY`,
`C_S00_AXI_ID_WIDTH`, `C_M00_AXI_ID_WIDTH`,
`C_S00_AXI_DATA_WIDTH`, and `C_M00_AXI_DATA_WIDTH`.

For `TOP=tc_narrow_shim`, use `NARROW_W`, `BLOCK_W`, `ID_W`,
`MAX_OUTSTANDING_W`, and `READ_REORDER_DEPTH`.

## Timing controls

| Variable | Default | Meaning |
|---|---:|---|
| `PART` | U250 part | target device |
| `PERIOD_NS` | 4.0 | clock period |
| `DIRECTIVE` | `default` | synthesis directive |
| `CASCADE_DEPTH` | 8 | RAM cascade height |
| `DB_LATENCY` | 1 | databank read latency; supported values are 1–2 |
| `SDP_WRITE_INPUT_REG` | 0 | register SDP write inputs |

Use post-route scripts for final timing:

```bash
PNR=1 ./u55c_synth.sh
PNR=1 ./v80_synth.sh
```

Tune `CASCADE_DEPTH` per device and cache size. Smaller cascade depth may
improve large UltraRAM arrays but increase muxing and routing for small arrays.

## Outputs

Each top writes under `syn/vivado/build/<top>/`:

- `utilization.rpt`
- `timing_summary.rpt`
- `synth.log`
- `vivado.log`
- `vivado.jou`

Post-route scripts additionally emit routed checkpoints, netlists, and SDF when
enabled.

## Memory inference

- TDP databank: BRAM
- SDP databank: UltraRAM
- tagbank: BRAM
- metadata and small queues: LUTRAM or registers

The simulation and synthesis RAM templates intentionally differ where required
by Verilator and Vivado inference. Validate both the regression and synthesis
flow after changing memory code.

## Reference configurations

[`sweep_results.md`](sweep_results.md) is the curated historical reference with
tool, date, and repository provenance. `sweep.sh` never modifies it; fresh
synthesis-only tables are written to `sweep_logs/sweep_summary.md`.

See also:

- [../../doc/deployment/README.md](../../doc/deployment/README.md)
- [../../doc/wiki/URAM_Mode.md](../../doc/wiki/URAM_Mode.md)
