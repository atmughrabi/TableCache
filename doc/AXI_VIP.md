# Vivado AXI VIP Verification

TableCache uses Vivado AXI Verification IP under xsim for strict 4-state
protocol and reset testing. This complements the faster Verilator/cocotb
regression.

## Scope

The VIP testbench covers:

- cold reset and initialization
- read miss and line fill
- write and read-back
- dirty eviction and writeback
- whole-cache flush
- by-index flush across multiple ways
- base-zero address ranges
- non-default ID widths and associativity
- victim-cache and SDP/UltraRAM configurations

Entry point:

```bash
./tb/vip/run_vip.sh
```

Configuration is controlled with environment variables:

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

## Verification levels

| Level | Entry point | Purpose |
|---|---|---|
| Behavioral xsim | `tb/vip/run_vip.sh` | protocol, reset, and 4-state behavior |
| OOC synthesis | `syn/vivado/run_synth.sh` | inference, utilization, and timing |
| Generic synthesis matrix | `syn/vivado/generic_config_matrix.sh` | representative parameter corners |
| Post-route simulation | `syn/post_pnr_sim.sh` | routed-netlist functional or SDF simulation |

## Residual coverage

The current VIP suite does not model:

- AXI exclusive accesses
- multiple independent upstream masters
- clock-domain crossings
- recoverable memory errors

TableCache requires an error-free memory backend and a single clock domain.
Unsupported transactions are constrained or asserted at the cache boundary.

Current results and nightly configurations are maintained in
[VERIFICATION.md](VERIFICATION.md).
