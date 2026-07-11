# GRASP Replacement Policy

GRASP is an address-aware RRIP policy for graph workloads. Runtime address
windows classify cache lines as high, moderate, or default reuse.

RTL source: [`src/GRASP.sv`](../../src/GRASP.sv)

Architecture: [`doc/ARCHITECTURE.md`](../ARCHITECTURE.md)

## Configuration

```sv
l2_cache #(
    .POLICY                   (GRASP),
    .GRASP_HIGH_REGIONS       (2),
    .GRASP_MODERATE_REGIONS   (1)
) cache (
    .grasp_high_addr_l        ({32'h9000_0000, 32'h8000_0000}),
    .grasp_high_addr_h        ({32'h9000_0fff, 32'h8000_0fff}),
    .grasp_moderate_addr_l    (32'h8001_0000),
    .grasp_moderate_addr_h    (32'h8001_ffff),
    /* cache ports */
);
```

Each region count is at least one. Region `i` occupies
`[i*ADDR_W +: ADDR_W]` in the flattened port.

## Region rules

A region is enabled when:

```text
high != 0
high >= low
low <= line_address <= high
```

Driving a region's high bound to zero disables that region.

If an address matches both classes, high reuse takes precedence.

## RRPV behavior

GRASP uses 3-bit RRPV metadata.

| Event | High | Moderate | Outside |
|---|---:|---:|---:|
| Insert | 0 | 1 | 7 |
| Hit | 0 | decrement, saturating at 0 | decrement, saturating at 0 |
| Miss aging | add the minimum increment required to expose a victim | same | same |

With all regions disabled, GRASP reduces to SRRIP frequency-priority behavior.

## Multiple windows

`GRASP_HIGH_REGIONS` and `GRASP_MODERATE_REGIONS` allow disjoint buffers to be
classified independently. Match signals are OR reductions across each class.
This avoids defining one large region that also retains cold addresses between
hot buffers.

The region counts and packed ports are threaded through:

```text
l2_top
  -> l2_cache
    -> l2_tagbank
      -> replacement_policy
        -> GRASP
```

The policy receives the reconstructed line-aligned system address, including
the configured address-range base.

## Design guidance

- Use high regions for data that should remain resident under cold streaming.
- Use moderate regions for data with useful but weaker reuse.
- Align bounds to cache lines.
- Disable unused windows by writing zero to the high bound.
- Re-run post-route timing when increasing the number of windows; each window
  adds address comparators and routing.

## Verification

| Property | Coverage |
|---|---|
| High/moderate/default behavior | `test_grasp.py`, `test_grasp_moderate.py` |
| Set-conflict pressure | `test_grasp_pressure.py` |
| Runtime reconfiguration | `test_grasp_midburst.py` |
| Multiple disjoint windows | `test_grasp_multi.py` |
| Multi-window retention benefit | `test_grasp_multi_perf.py` |
| Configuration sweep | `grasp_multi_matrix.sh` |
| Mutation testing | `mutation_test.sh FILE=src/GRASP.sv` |
| Formal invariants | `tb/formal/grasp_formal.sv` |

Current commands and results are listed in
[`doc/VERIFICATION.md`](../VERIFICATION.md). Synthesis and timing data are in
[`syn/vivado/`](../../syn/vivado/).
