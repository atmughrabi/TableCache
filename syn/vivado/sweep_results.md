# TableCache OOC sweep — U250, SDP vs TDP databank

Vivado 2025.2, `xcu250-figd2104-2L-e`, 250 MHz target (4.0 ns clock),
`AreaOptimized_high` directive. Out-of-context (no IO ring, no PnR).

Per-run reports under `sweep_logs/`. Re-run with `./sweep.sh` from this
directory.

## Headline table

| Config        | Mode | LUT  | FF   | BRAM tile | URAM | WNS (ns) | Effective MHz* |
|---------------|------|-----:|-----:|----------:|-----:|---------:|---------------:|
| 256 KB / 4-way | TDP | 1913 | 1155 |      18   |   0  |  -1.018  |  ~199 |
| 256 KB / 4-way | SDP | 1676 | 1109 |       2   |   2  |  -1.000  |  ~200 |
| 256 KB / 8-way | TDP | 2277 | 1237 |      35.5 |   0  |  -1.390  |  ~186 |
| 256 KB / 8-way | SDP | 1756 | 1194 |       3.5 |   4  |  -1.740  |  ~175 |
| 512 KB / 8-way | TDP | 3194 | 1223 |     133   |   0  |  -2.016  |  ~166 |
| 512 KB / 8-way | SDP | 1919 | 1180 |       5   |  16  |  -2.543  |  ~153 |
| 1 MB / 8-way   | TDP | 3359 | 1219 |     258   |   2  |  -2.042  |  ~166 |
| 1 MB / 8-way   | SDP | 1914 | 1176 |       2   |  34  |  -3.321  |  ~136 |

\*Effective MHz = 1000 / (4.0 ns + |WNS|). Post-synth, before PnR
optimization which typically recovers some slack.

All configs: `REPLACEMENT_POLICY=4` (SRRIP), `INCLUDE_VICTIM=1`,
`VICTIM_LINES=16`, `DB_LATENCY=1`. 64-byte line at 512 KB+
(LINE_W=16, BLOCK_W=32); 32-byte line at 256 KB (LINE_W=8).

## Cross-config trends

### SDP saves BRAM dramatically, costs URAM
At 1 MB / 8-way: TDP uses **258 BRAM tiles + 2 URAM**; SDP uses
**2 BRAM + 34 URAM**. The URAM is the natural home for large data
arrays — the paper's "two ways per URAM" packing finally happens.

### LUT count drops in SDP mode
SDP routinely uses fewer LUTs than TDP at the same size. Reason: in SDP
mode databank port 1 is disabled, eliminating one full state machine
+ associated arbitration. LUT savings: 20–43 % across configs. The
arbiter/mux savings outweigh the small overhead of the URAM-style
storage.

### SDP is worse for timing at large configs
| Size           | TDP WNS   | SDP WNS   | Δ                              |
|----------------|----------:|----------:|--------------------------------|
| 256 KB         | -1.018 ns | -1.000 ns | +0.018 (SDP slightly better)   |
| 512 KB         | -2.016 ns | -2.543 ns | -0.527 (SDP worse)             |
| 1 MB           | -2.042 ns | -3.321 ns | -1.279 (SDP much worse)        |

UltraRAM access time is fixed at the primitive level; longer cascade
chains for wide data arrays accumulate fixed delay. BRAM also cascades
but scales with clock frequency more gracefully. At 1 MB / 8-way the
SDP design cascades 34 URAMs — the cascade chain itself is the
critical path.

**Mitigation if SDP timing is binding**: bump `DB_LATENCY` from 1 to
2 or 3. Each extra pipeline stage absorbs a cascade delay. Vivado
already printed *"UltraRAM ... under-pipelined and may not meet
performance target: recommended pipeline stages = 2"* on this synth —
confirming the diagnosis.

## Per-CU × 16 (Alveo U250 capacity)

For the 16-CU GraphBlox-style integration target:

| Config         | Mode | 16 × BRAM     | 16 × URAM     | Fits on U250?\* |
|----------------|------|--------------:|--------------:|-----------------|
| 256 KB / 8-way | TDP  | 568 (21 %)    | 0 (0 %)       | yes             |
| 256 KB / 8-way | SDP  | 56 (2 %)      | 64 (5 %)      | yes             |
| 512 KB / 8-way | TDP  | **2112 (79 %)** | 0 (0 %)     | barely          |
| 512 KB / 8-way | SDP  | 80 (3 %)      | **256 (20 %)** | comfortable    |
| 1 MB / 8-way   | TDP  | **4128 (>100 %)** | 32 (3 %) | **no**          |
| 1 MB / 8-way   | SDP  | 32 (1 %)      | **544 (43 %)** | yes             |

\*U250 has 2688 BRAM tiles and 1280 URAM.

**SDP mode unlocks 1 MB-per-CU caches that don't fit in TDP on U250**,
and frees ~75 % of BRAM at 512 KB-per-CU for other accelerator
memories.

## Recommended deployment matrix

| Target board | Per-CU size | Mode | Reason |
|---|---|---|---|
| U250, 16 CUs | 256 KB     | either                  | TDP simpler; SDP frees BRAM for accelerator |
| U250, 16 CUs | 512 KB     | **SDP+URAM**            | TDP tight at 79 % BRAM; SDP comfortable     |
| U250, 16 CUs | 1 MB       | **SDP+URAM mandatory**  | TDP exceeds BRAM budget                     |
| U280, 16 CUs | 256–512 KB | **SDP+URAM**            | Fewer BRAM tiles than U250; URAM mandatory  |
| V80, 16 CUs  | up to 1 MB | **SDP+URAM**            | URAM-rich; use full 1 MB if hit rate justifies |

## Open follow-ups (not addressed by this sweep)

- **PnR-closed timing**: WNS shown is post-synth only. Full PnR
  typically recovers 0.5–1.5 ns of slack via placement / replication.
  Run `place_design ; route_design` before claiming the cache misses
  250 MHz on real silicon.
- **DB_LATENCY sweep**: bumping latency 1 → 2 should recover URAM
  timing at 1 MB. Verify, then make this the recommended config for
  the largest SDP caches.
- **U280 / V80 ports**: `PART=xcu280-fsvh2892-2L-e ./sweep.sh` should
  produce a comparable table on U280. V80 needs Vivado 2024.x+ with
  Versal support.
- **Bank-balanced SDP**: see
  [doc/DESIGN_BANKED_SDP_DATABANK.md](../../doc/DESIGN_BANKED_SDP_DATABANK.md)
  for a proposal to recover the 6.3 % SDP throughput cost at ~2 weeks
  of engineering. Defer until measured to be binding.
