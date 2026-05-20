# UltraRAM Mode (`DATABANK_SDP=1`)

> Copy-pasteable single page for GitHub Wiki. Source of truth for the
> in-tree integration guide is `doc/FPGA_INTEGRATION.md` §10.1. This
> page is a self-contained summary aimed at users coming from the wiki
> sidebar.

TableCache's data array defaults to a true-dual-port (TDP) topology
that maps cleanly to BRAM but cannot be inferred as UltraRAM on AMD
UltraScale+ parts. Setting `DATABANK_SDP=1` swaps the storage to a
simple-dual-port (SDP) topology backed by `sdp_ram_uram` with
`(* ram_style = "ultra" *)` pinned, freeing BRAM for the rest of your
design.

## TL;DR

```sv
l2_cache #(
    .LINES       (1024),
    .LINE_W      (16),       // 64-byte line
    .WAYS        (8),
    .BLOCK_W     (32),
    .DB_LATENCY  (2),        // recommended for URAM cascade depth ≥ 8
    .DATABANK_SDP(1)         // ← enable UltraRAM packing
) cache ( /* ports unchanged */ );
```

## What it costs you

- **~6.3 % throughput** on graph-style workloads (`test_workload` 5000
  transactions). The cost comes from disabling databank port 1 so the
  storage stays single-port: fills and reads can no longer overlap.
- A bit more **timing pressure** at large sizes (512 KB+): UltraRAM
  has a fixed primitive access time. Long cascade chains accumulate.
  Bump `DB_LATENCY` to 2 (or 3 at 1 MB) — Vivado will tell you when
  this is needed.

## What it buys you

| 16 caches on U250 | TDP (default) | SDP+URAM |
|---|---:|---:|
| 256 KB each | 568 BRAM (21 %) | 64 URAM (5 %) |
| 512 KB each | **2112 BRAM (79 %)** | 256 URAM (20 %), 80 BRAM (3 %) |
| 1 MB each   | **4128 BRAM (won't fit)** | 544 URAM (43 %), 32 BRAM |

Without SDP mode, **1 MB/CU at 16 CUs is impossible** on U250
(exceeds 2688 BRAM). With SDP mode, it fits comfortably.

## What it does NOT change

- AXI4 / AXI4-ACE-lite contract on the slave port — unchanged.
- AXI4 master-side contract — unchanged.
- CBOM, victim cache, flush controller, narrow-port shim — all
  unaffected (`DATABANK_SDP` only touches the data array).
- Functional behaviour — verified bit-for-bit against the TDP path
  by the full 29-test cocotb regression at every PR.

## Decision tree

```
Are you deploying multiple caches on one die?
├─ No → leave DATABANK_SDP=0 (default). TDP is faster and uses BRAM well.
└─ Yes
   └─ Does your part have UltraRAM (Alveo U250/U280, Versal V80, etc.)?
      ├─ No  → DATABANK_SDP=0. The SDP path requires UltraRAM.
      └─ Yes
         └─ Is BRAM tight at your per-CU size × CU count?
            ├─ No  → DATABANK_SDP=0. Save the 6.3 % throughput.
            └─ Yes → DATABANK_SDP=1. Trade throughput for fitting on-die.
```

## Verifying it worked

After Vivado synth, check `report_utilization` for a non-zero **URAM**
row in section "2. BLOCKRAM". At `WAYS=8 LINES=1024 LINE_W=16` you
should see:

```
| URAM           |   16 |     0 |          0 |      1280 |  1.25 |
```

Vivado also prints per-RAM "automatically implemented using URAM" INFO
lines during synth.

For a worked sweep across four sizes and both modes, see
`syn/vivado/sweep_results.md` in the repo (8 configs, full LUT/FF/
BRAM/URAM/WNS table).

## Performance bench commands

```bash
# Compare TDP vs SDP cycle count on the same workload
cd tb/cocotb && source .venv/bin/activate

# TDP baseline
rm -rf sim_build
EXTRA_ARGS="+define+DATABANK_PERF=1" \
    NTXN=5000 LINES=1024 WAYS=8 LINE_W=16 POLICY=SRRIP \
    make MODULE=test_workload

# SDP+URAM
rm -rf sim_build
EXTRA_ARGS="+define+TC_DATABANK_SDP=1 +define+DATABANK_PERF=1" \
    NTXN=5000 LINES=1024 WAYS=8 LINE_W=16 POLICY=SRRIP \
    make MODULE=test_workload
```

Both runs print `[DATABANK_PERF] cycles_total = ...` at simulation
end. Divide to get the throughput ratio.

## CI coverage

Every PR runs the SDP path on five representative test modules
(`test_smoke`, `test_cbom`, `test_strobe`, `test_backpressure`,
`test_flush`) — see `.github/workflows/regression.yml`.

Mutation score on the SDP gating logic: **100 %** (4/4 effective
mutations killed, 2 documented as equivalent).

100-seed `test_random` stress sweep: **100/100 PASS**.

## Known limitations

- **Throughput ceiling** at -6.3 % vs TDP for graph-style workloads.
  Recoverable with a 2-bank line-LSB split — design proposal in
  `doc/DESIGN_BANKED_SDP_DATABANK.md` (~2 weeks engineering effort,
  defer until measured as binding).
- **Tagbank is still BRAM** under SDP mode. The tagbank is small
  enough that URAM would waste capacity; Vivado picks BRAM via auto-
  inference.
- **Vivado-only**. The SDP path uses Xilinx `ram_style="ultra"`.
  Other vendors / tools may need a different storage wrapper.

## See also

- `doc/INTERFACING.md` §5 / §5.1 — full parameter reference + the
  SDP table
- `doc/FPGA_INTEGRATION.md` §10.1 — integration-side how-to
- `doc/ARCHITECTURE.md` §7.5 — bug history (bugs #13/#14 are the
  UltraRAM ones)
- `doc/DESIGN_BANKED_SDP_DATABANK.md` — proposed bank-2 successor
- `syn/vivado/sweep_results.md` — full per-config synth table
- `syn/vivado/README.md` — synth flow + per-top headline numbers
