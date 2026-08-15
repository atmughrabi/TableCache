# Representative Vivado Results

These measurements are out-of-context reference points. Re-run the current RTL,
Vivado version, part, and directives before using them for deployment.

## Reference geometry

```text
POLICY=GRASP
WAYS=8
LINES=1024
LINE_W=16
BLOCK_W=32
DB_LATENCY=2
DATABANK_SDP=1
INCLUDE_VICTIM=0
```

## Post-route timing

| Part | Cache | Target | WNS | Notes |
|---|---:|---:|---:|---|
| U250 `xcu250-figd2104-2L-e` | 512 KiB | 250 MHz | +0.088 ns | baseline supported configuration |
| U250 `xcu250-figd2104-2L-e` | 1 MiB | 250 MHz | -0.122 ns | requires additional tuning |
| U55C `xcu55c-fsvh2892-2L-e` | 512 KiB | 250 MHz | -0.022 ns | near closure |
| V80 ES `xcv80-lsva4737-2MHP-e-S` | 512 KiB | 200 MHz | +0.062 ns | `CASCADE_DEPTH=1` |

## Resource scale

Representative SDP/UltraRAM usage:

| Cache | Ways | UltraRAM | BRAM |
|---|---:|---:|---:|
| 512 KiB | 8 | 16 | about 5 |
| 1 MiB | 8 | 34 | about 2 |
| 2 MiB | 8 | 66 | about 4 |

The exact count depends on banking, cascade depth, policy metadata, and tool
mapping.

## Interpretation

- SDP mode substantially reduces BRAM pressure.
- Large arrays are commonly limited by UltraRAM cascade and routing delay.
- `CASCADE_DEPTH` is device- and size-dependent.
- Victim caching adds area and may reduce timing margin.
- OOC timing excludes platform interconnect, memory-controller, and floorplan
  effects.

Reproduction commands are in [README.md](README.md).
