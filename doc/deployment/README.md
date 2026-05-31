# TableCache — Alveo Deployment Reports

Per-target deployment guides with validated post-route timing, multi-CU
device-utilization arithmetic, recommended parameter values, and the
Vivado knobs that reproduce each number.

| Board | Family | Silicon | 512 KB / 8w at 250 MHz | 512 KB / 8w at 300 MHz | Notes |
|---|---|---|---:|---:|---|
| [**U250**](U250.md) | Virtex UltraScale+ (no HBM) | production | ✓ MET (+0.088 ns)  | **✓ MET (+0.064 ns, ~305 MHz)** | best for hard 300 MHz lock on 1 MB caches |
| [**U55C**](U55C.md) | Virtex UltraScale+ HBM | production | ✓ essentially MET (-0.022 ns) | **✓ MET (+0.127 ns, ~312 MHz, best)** | HBM2 @ 460 GB/s; best URAM headroom |
| [**V80**](V80.md)   | Versal Premium  | ES (`-S`)  | misses on ES (production should close) | ES clock-uncertainty bound (~259 MHz)  | mandatory for Versal NoC + AIE-ML integration |

All measurements: 8-way / GRASP / SDP+URAM (BRAM tag + URAM data) /
`INCLUDE_VICTIM=0` / `DATABANK_SDP=1`.

## Quick-pick decision table

| If you need... | Use this board |
|---|---|
| Highest single-cache frequency on production silicon | U55C (312 MHz at 512 KB) |
| Hardest 300 MHz lock for 1 MB caches | U250 (302 MHz at 1 MB) |
| HBM-backed L2 array | U55C |
| Versal-only target | V80 |
| Maximum CU density with URAM headroom | U55C or V80 (~45 % URAM free at 32 × 1 MB) |
| 250 MHz deployment, conservative knobs | U250 or U55C (both close baseline at 250) |
| 200 MHz deployment on ES silicon | V80 (validated at +0.062 ns post-route) |

## Tuned knob set (300 MHz)

All "tuned" rows use the same combination:

```bash
DB_LATENCY=3 SDP_WRITE_INPUT_REG=1 \
  PLACE_DIRECTIVE=ExtraNetDelay_high \
  PHYS_DIRECTIVE=AggressiveExplore \
  ROUTE_DIRECTIVE=AggressiveExplore
```

`DB_LATENCY=3` adds 1 cycle on the data-bank READ pipeline.
`SDP_WRITE_INPUT_REG=1` adds 1 cycle on the URAM WRITE port (absorbed
by the cache's WRITING → READY → READING FSM serialisation). PnR
directives are pure tool-level; no RTL change.

Throughput at the tuned knobs is **+14 % to +17 %** vs baseline 250 MHz
across measured workloads (`tb/cocotb/perf_300mhz.sh`), so the +1 cycle
read overhead is much smaller than the +20 % frequency gain.

## Related documents

- [`doc/wiki/GRASP_Policy.md`](../wiki/GRASP_Policy.md) — GRASP
  address-region-aware policy: usage, hit-rate, timing, verification.
- [`doc/wiki/URAM_Mode.md`](../wiki/URAM_Mode.md) — `DATABANK_SDP=1`
  UltraRAM mode: when to use it, what it costs, how to verify.
- [`syn/vivado/README.md`](../../syn/vivado/README.md) — full Vivado OOC
  synth driver, knob reference, headline timing tables.
- [`syn/vivado/sweep_results.md`](../../syn/vivado/sweep_results.md) —
  U250 sweep matrix across 4 × {TDP, SDP} configurations.
- [`doc/FPGA_INTEGRATION.md`](../FPGA_INTEGRATION.md) — RTL integration
  guide and parameter reference.
- [`doc/ARCHITECTURE.md`](../ARCHITECTURE.md) — module-level overview
  and bug history.
