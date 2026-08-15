# Vivado AXI VIP Simulation

This directory contains strict four-state xsim tests for `l2_top` and the
RATIO=1 narrow shim. The flow complements the faster two-state
Verilator/cocotb regression.

## Scope

`tb_l2top_vip.sv` connects an AXI VIP master to `l2_top` and an AXI VIP
memory slave to the cache memory port. It checks:

- cold reset and metadata initialization
- cold read and line fill
- write and read-back
- dirty eviction and writeback
- cold and warm whole-cache flush
- by-index flush across all ways
- victim-cache and SDP configurations
- non-default ID widths and associativity
- base-zero cacheable ranges

After reset, an `$isunknown` monitor rejects unknown handshake signals and
valid-qualified payloads. Cache-side read data is excluded because CBOM
responses carry no data.

## Running

```bash
./tb/vip/run_vip.sh
```

Vivado 2025.2 must be available on `PATH`. The runner generates the VIP
project, removes xsim's default `--relax`, compiles, elaborates, and reports
`VIP_RESULT PASS` or `VIP_RESULT FAIL`.

Configuration uses environment variables:

```bash
VIP_ID_W=3 \
VIP_LINES=64 \
VIP_WAYS=3 \
VIP_LINE_W=8 \
VIP_POLICY=GRASP \
VIP_VICTIM=1 \
VIP_DB_LATENCY=2 \
VIP_DATABANK_SDP=1 \
VIP_SDP_WRITE_INPUT_REG=1 \
VIP_N_BANKS=2 \
VIP_CASCADE_DEPTH=1 \
./tb/vip/run_vip.sh
```

The reset hold is derived from the larger of the line count and ID occupancy
table depth, with additional simulation margin.

## RATIO=1 shim check

```bash
./tb/vip/run_shim_ratio1.sh
```

This standalone xsim test sweeps equal narrow and block widths. It verifies
that every access selects lane zero and that odd word addresses neither return
unknown data nor drop writes.

## Files

- `tb_l2top_vip.sv`: AXI VIP testbench
- `run_vip.tcl`: project and IP generation
- `run_vip.sh`: strict compile, elaborate, and simulation runner
- `tb_shim_ratio1.sv`: standalone RATIO=1 testbench
- `run_shim_ratio1.sh`: RATIO=1 runner
