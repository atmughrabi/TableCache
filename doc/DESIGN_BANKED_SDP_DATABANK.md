# Banked-SDP Databank — Design Note

**Status**: design proposal, not implemented. Intended successor to the
`DATABANK_SDP=1` "disable port 1" mode when the measured 6.3 %
throughput cost becomes the binding constraint.

## Motivation

The current SDP-mode databank (`l2_databank.sv` + `sdp_ram_uram.sv`)
serialises all traffic through databank port 0 to guarantee a single
SDP storage primitive is enough. Measured throughput cost:

| Workload                | TDP cycles | SDP cycles | Δ      |
|-------------------------|-----------:|-----------:|-------:|
| `test_workload` 5000 tx | 64 250     | 68 284     | -6.3 % |

The 6.3 % comes from two sources, in roughly equal proportion:

1. **Lost R+W concurrency**: a fill (write port) cannot overlap with
   a read hit (read port). In TDP both can fire simultaneously on
   different physical ports.
2. **Lost port-1 backup acceptance**: when port 0 is mid-burst, the
   TDP databank accepts a fresh request on port 1; SDP mode stalls
   the upstream until port 0 returns to READY.

Both are recoverable with a banked storage that preserves
URAM-eligibility (each bank stays SDP) while restoring two physical
read paths in aggregate.

## Architecture

```
                ┌──────────────────────────────────────────┐
                │ l2_databank                              │
                │                                          │
   req in ──────┼─► [FSM/arbiter]                          │
                │   pick bank by line_addr[BANK_SEL]       │
                │                                          │
                │       ┌────────────────────────┐         │
                │       │ bank 0 (SDP+URAM)      │         │
                │       │  ↑ 1 read + 1 write    │         │
                │       └────────────────────────┘         │
                │       ┌────────────────────────┐         │
                │       │ bank 1 (SDP+URAM)      │         │
                │       │  ↑ 1 read + 1 write    │         │
                │       └────────────────────────┘         │
                │                                          │
                └──────────────────────────────────────────┘
```

**Banking key**: a fixed slice of the line address (`line_addr[0]` for
N_BANKS=2). The slice MUST be the LSB (or similarly hash-spread) so
adjacent lines map to different banks — graph workloads stream through
neighbouring lines.

**Per-bank storage**: each bank is one `sdp_ram_uram` instance with
half the line count. Cache size is unchanged; only the per-bank depth
halves.

**Port routing**:
- Requests from port 0 / port 1 of the FSM are mapped to one of
  N_BANKS using the bank-select bits of the line address.
- Two requests on the same cycle to **different banks** proceed in
  parallel — both ports of the cache fire, both URAM banks service.
- Two requests on the same cycle to the **same bank** force the
  second to stall one cycle (the SDP storage can do at most one
  read + one write per cycle).

## Conflict probability (back-of-envelope)

With N_BANKS = 2 and a uniformly distributed line-address LSB:
- Probability two concurrent requests collide on the same bank:
  **50 %**
- Of those collisions, only ~half are "bad" (both want the read port,
  or both want the write port — the other 50 % are 1R + 1W which the
  SDP bank handles)
- So expected stall rate ≈ 25 % of concurrent-port cycles

From the TDP perf measurement on `test_workload`:
- `both_active` = 6.84 % of total cycles
- Of those, the bad combinations (RR or WW) were 1.32 %
- The remaining 5.52 % was R+W, which N_BANKS=2 SDP handles natively

Banked-SDP expected cost ≈ 25 % × 1.32 % = **0.33 % cycles stalled**.
Including the second-order effects (slightly increased decode latency),
target throughput cost is **~1-2 %**, vs the current 6.3 %.

With N_BANKS = 4:
- Same-bank collision probability drops to ~25 %
- Expected stall ≈ 12.5 % × 1.32 % = 0.17 %
- Diminishing returns; not worth the area increase from 4× the address
  decoders / output muxes

**Recommendation**: 2 banks. Most of the gain, half the complexity.

## Resource estimate

Each SDP+URAM bank at 256 KB / 8-way / 64 B line / 32-bit word needs:
- Per-way depth = 512 sets
- 8 ways × 32-bit data = 256-bit row → 4 URAMs at 4096×72b (still
  under-utilised at 12.5 %, same as full 1024-row instance with 25 %
  utilisation — URAM count actually *increases* per bank but TOTAL URAM
  count stays the same because we halved per-bank depth)

Net URAM count for 512 KB / 8-way: identical to the current SDP mode
(16 URAMs). The banking does NOT cost extra URAM.

LUT/FF overhead from the bank arbiter:
- 1 bank-select decoder (2 comparators, ~10 LUTs)
- 2 output muxes for read data routing (~50 LUTs each)
- Estimated total: +150-200 LUTs per cache (~10 % over current SDP's
  1919 LUTs)
- Negligible at U250 scale (1.73M LUTs total)

## Implementation effort

| Task | Estimate |
|---|---|
| New `l2_databank_banked.sv` module | 2-3 days |
| Per-bank request multiplexing + stall detection | 1-2 days |
| Output read-data routing pipeline (track which bank+port served) | 1 day |
| Cross-bank ordering preservation (or relax the contract) | 1 day |
| Verilator + Vivado debug | 2-3 days |
| Re-verify full regression at SDP_BANKED=1 | 2 days |
| Mutation suite extension | 1 day |
| Synth sweep + perf comparison | 1 day |
| Documentation | 1 day |
| **Total** | **~2 weeks** |

## Open design questions

1. **Per-port state machines**: keep the existing 2-port FSM or
   collapse to a single FSM with bank-aware request routing? The
   current FSM has port-0/port-1 fairness baked in — bank fairness
   is orthogonal. Likely keep both layers, with the bank arbiter as
   a thin intermediate.

2. **Ordering**: if a read to bank 0 follows a read to bank 1 from
   the same upstream ID, does the read-data pipeline need to
   re-order? Current cache uses ID to disambiguate, so out-of-order
   completion is fine as long as `rid` matches. Verify.

3. **Bank-balance under non-uniform workloads**: graph workloads
   may exhibit bank skew if the partition aligns with the bank-LSB.
   Consider XOR-hashing the line address (1 LUT) to spread.

4. **CBOM and flush**: flush controller emits sequential line
   addresses → guarantees bank-imbalanced bursts. Acceptable; flush
   is rare and serial by design.

## Out of scope for this design note

- Implementation. This is a design proposal.
- Cross-clock-domain extension. Both banks run on the kernel clock.
- More than 2 banks. Diminishing returns at current cache sizes.

## Alternative considered (rejected)

**Double-pumped URAM**: run the URAM at 2× kernel clock to simulate
true 2R + 2W. Provides perfect throughput recovery but introduces a
clock-domain boundary inside the cache. CDC is unforgiving on a
performance-critical path; the risk/reward did not justify the
complexity over the simpler banking approach.

## When to implement

Trigger conditions (any one):
- A real production workload shows the 6.3 % cost is binding
- A bigger device target where BRAM is not the constraint (V80)
  removes the URAM motivation entirely — defer indefinitely
- A 16-CU integration measurement on real hardware shows the cache
  bottleneck and not memory bandwidth or compute

Until then, the "disable port 1" implementation in
`src/l2_databank.sv` is sufficient and verified.
