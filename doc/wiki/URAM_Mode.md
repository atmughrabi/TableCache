# UltraRAM Databank

`DATABANK_SDP=1` selects a simple-dual-port data array implemented by
[`sdp_ram_uram.sv`](../../src/sdp_ram_uram.sv). It trades databank concurrency
for UltraRAM inference on AMD UltraScale+ devices.

Integration details: [`doc/FPGA_INTEGRATION.md`](../FPGA_INTEGRATION.md)

Synthesis flow: [`syn/vivado/README.md`](../../syn/vivado/README.md)

## Configuration

```sv
l2_cache #(
    .DATABANK_SDP          (1),
    .DB_LATENCY            (2),
    .SDP_WRITE_INPUT_REG   (1),
    .N_BANKS               (2),
    .CASCADE_DEPTH         (4)
) cache ( /* ports */ );
```

| Parameter | Meaning |
|---|---|
| `DATABANK_SDP` | `0`: TDP/BRAM, `1`: SDP/UltraRAM |
| `DB_LATENCY` | Databank read pipeline; supported values are 1–2 |
| `SDP_WRITE_INPUT_REG` | Optional write-input register |
| `N_BANKS` | Power-of-two bank count dividing `LINES` |
| `CASCADE_DEPTH` | Primitive cascade depth, 1–8 |

## Architectural effect

| Property | TDP mode | SDP mode |
|---|---|---|
| Storage primitive | BRAM | UltraRAM |
| Databank ports | two read/write ports | one read + one write port |
| Port-1 request acceptance | enabled | disabled |
| Read/write overlap | supported | constrained by the single SDP datapath |
| External AXI contract | unchanged | unchanged |
| Tagbank | BRAM | BRAM |

SDP mode changes storage topology only. Replacement policy, CBOM, victim cache,
flush control, and external interfaces are unchanged.

## Banking

`N_BANKS>1` partitions the data array by line-index low bits. Banking reduces
per-bank depth and URAM cascade length. Supported bank counts:

```text
N_BANKS >= 1
N_BANKS is a power of two
N_BANKS divides LINES
```

One line per bank is supported.

## Selection guidance

Use TDP mode when:

- BRAM capacity is sufficient.
- Databank concurrency is performance-critical.
- The target device has no UltraRAM.

Use SDP mode when:

- Multiple cache instances create BRAM pressure.
- The target provides UltraRAM.
- The measured throughput cost is acceptable.

Measure both modes with the target geometry and workload. Do not extrapolate
throughput or timing from a different cache size.

## Synthesis checks

```bash
cd syn/vivado
DATABANK_SDP=1 DB_LATENCY=2 SDP_WRITE_INPUT_REG=1 \
N_BANKS=2 CASCADE_DEPTH=4 \
WAYS=8 LINES=1024 LINE_W=16 POLICY=4 \
./run_synth.sh
```

Confirm:

1. `report_utilization` contains UltraRAM instances.
2. No RAM-template synthesis error is reported.
3. Timing closes at the target clock.
4. The inferred bank and cascade counts match the selected parameters.

Representative sweeps are recorded in
[`syn/vivado/sweep_results.md`](../../syn/vivado/sweep_results.md).

## Verification

| Layer | Entry point |
|---|---|
| Functional SDP tests | `test_matrix.py`, `test_geometry_matrix.py` |
| Width and WRAP tests | `test_shim_wrap_matrix.py` |
| Reset and 4-state tests | `tb/vip/run_vip.sh` |
| Banking/cascade stress | `test_geometry_matrix.py` |
| OOC synthesis corners | `syn/vivado/generic_config_matrix.sh` |

Current results and exact commands are maintained in
[`doc/VERIFICATION.md`](../VERIFICATION.md).

## Constraints

- The UltraRAM template targets AMD Vivado.
- `DB_LATENCY>2` is unsupported.
- `N_BANKS` and `CASCADE_DEPTH` are elaboration-time parameters.
- The tagbank remains separate from the SDP data array.
