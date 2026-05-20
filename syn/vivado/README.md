# Vivado OOC Synthesis

Out-of-context synthesis driver for the TableCache tops. Used to track
post-synth utilization, timing feasibility, and primitive inference
without committing to a full IO ring / shell context.

## Tools
- Vivado 2025.2 (`VIVADO=/opt/xilinx/2025.2/Vivado/bin/vivado` by default)
- Target part: Alveo U250 (`xcu250-figd2104-2L-e`, speed grade -2L)
- Target clock: 250 MHz (`create_clock -period 4.0`)
- Directive: `AreaOptimized_high`

## Usage

```bash
cd syn/vivado

# Default: l2_cache, default parameters
./run_synth.sh

# Pick a different top
TOP=tc_narrow_shim ./run_synth.sh
TOP=tc_flush_controller ./run_synth.sh

# Sweep all three user-facing tops
ALL=1 ./run_synth.sh

# Override RTL parameters (l2_cache / l2_top only)
WAYS=8 LINES=1024 LINE_W=16 REPLACEMENT_POLICY=4 \
    INCLUDE_VICTIM=1 VICTIM_LINES=16 ./run_synth.sh

# Force URAM-packed databank (see "URAM mode" below)
DATABANK_SDP=1 WAYS=8 LINES=1024 LINE_W=16 ./run_synth.sh
```

Supported env-var parameter overrides: `WAYS`, `LINES`, `LINE_W`,
`REPLACEMENT_POLICY`, `INCLUDE_VICTIM`, `VICTIM_LINES`, `DATABANK_SDP`.

## Outputs (per top)
```
build/<TOP>/utilization.rpt        flat resource report
build/<TOP>/utilization_hier.rpt   hierarchical breakdown
build/<TOP>/timing_summary.rpt     WNS/TNS/WHS
build/<TOP>/methodology.rpt
build/<TOP>/synth.log              full stdout (Vivado warnings + INFO)
```

## Headline results on U250 @ 250 MHz target

### `l2_cache` defaults (4-way / 512 sets / 8-block line, victim cache on)
| Resource    | Used | %device |
|-------------|------|---------|
| CLB LUTs    | 1681 | 0.10 %  |
| CLB FFs     | 930  | 0.03 %  |
| BRAM tiles  | 18   | 0.67 %  |
| URAM        | 0    | 0.00 %  |
| WNS         | -0.974 ns @ 4.0 ns target → ~201 MHz post-synth |

### `l2_cache` 512 KB / 8-way / 16-block line / SRRIP / TDP databank
| Resource    | Used  | %device |
|-------------|-------|---------|
| CLB LUTs    | 3194  | 0.18 %  |
| CLB FFs     | 1223  | 0.04 %  |
| BRAM tiles  | 132   | 4.91 %  |
| URAM        | 0     | 0.00 %  |

### `l2_cache` 512 KB / 8-way / 16-block line / SRRIP / **SDP+URAM** databank
| Resource    | Used  | %device |
|-------------|-------|---------|
| CLB LUTs    | 1919  | 0.11 %  |
| CLB FFs     | 1180  | 0.03 %  |
| BRAM tiles  | 5     | 0.19 %  |
| **URAM**    | **16**| **1.25 %** |

That last row is the configuration to use for multi-cache deployment
on URAM-rich parts (Alveo U250 / U280 / V80). See "URAM mode" below.

### `tc_narrow_shim` defaults
| Resource    | Used  | %device |
|-------------|-------|---------|
| CLB LUTs    | 1770  | 0.10 %  |
| CLB FFs     | 1070  | 0.03 %  |
| BRAM tiles  | 0     | 0.00 %  |
| WNS         | +1.936 ns @ 4.0 ns target (250 MHz met)        |

### `tc_flush_controller`
| Resource    | Used  |
|-------------|-------|
| CLB LUTs    | 16    |
| CLB FFs     | 13    |

## URAM mode (`DATABANK_SDP=1`)

By default the data array is a true-dual-port memory with byte-enables
on both ports (`tdp_ram`). Vivado will only ever map that to BRAM
(RAMB36/18) on UltraScale+ parts -- UltraRAM cannot service TDP byte
writes on both ports simultaneously.

To unlock UltraRAM inference, set `DATABANK_SDP=1`. This swaps the
databank for a simple-dual-port (1R+1W) wrapper (`sdp_ram_uram`,
hard-coded `ram_style="ultra"`) and disables the cache's port-1
databank pipeline so the FSM serializes all traffic through port 0.

Trade-off (measured on `test_workload`, 5000 transactions,
512 KB / 8-way / 16-block / SRRIP):

| Mode  | Cycle count | Cycles/txn | Throughput |
|-------|-------------|------------|------------|
| TDP   | 64 250      | 12.85      | baseline   |
| SDP   | 68 284      | 13.66      | -6.3 %     |

For a 16-CU system on U250 the resource arithmetic flips entirely:

| 16 caches    | TDP                    | SDP+URAM            |
|--------------|------------------------|---------------------|
| BRAM tiles   | 2112 / 2688 (79 %)     | **80 / 2688 (3 %)** |
| URAM         | 0 / 1280 (0 %)         | **256 / 1280 (20 %)** |

TDP is BRAM-tight at 16 caches; SDP+URAM leaves headroom for both
primitives, matching the paper's "2 ways per URAM" packing strategy
(thesis §5; release `etd23318.pdf`).

See `/memories/repo/tablecache_databank_sdp_uram.md` (Copilot memory)
for the design history and the two failed earlier approaches.

## Known issues

### `tdp_ram` UltraRAM rejection
Bug history (see VERIFICATION.md): originally `tdp_ram.sv` had the
default `ram_style = "ultra"`. Vivado synth fails with
"Unsupported RAM template" because TDP + per-byte-enable is not URAM-
inferrable. Fixed by hard-coding `ram_style = "block"` on the TDP path
(`#ifdef COCOTB_SIM` selects a masked single-NBA variant for Verilator).

### Vivado attribute parameter expressions
Vivado synth rejects `(* ram_style = RAM_STYLE *)` even when `RAM_STYLE`
is a string parameter (`Synth 8-281: expression must be of a packed
type`). Workaround: dedicated `sdp_ram_uram` wrapper that hardcodes the
attribute literal. Documented inline in `src/sdp_ram_uram.sv`.

### `DATABANK_PERF` counters in SDP mode
The `DATABANK_PERF` instrumentation counts `en[i]` not `en_gated[i]`.
In SDP mode port 1's FSM still computes en[1]=1 (the gating happens at
the RAM boundary), so the "p1 active" stat overstates port-1 demand.
Conflict-class stats are still meaningful, but the active-cycle
absolute number in SDP mode reflects demand-as-if-TDP, not actual port
usage. The throughput delta is most reliably measured by sim cycle
count, not by the in-RTL counters.
