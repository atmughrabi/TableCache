# Banked Memory Architecture — Design Note (data + tag)

**Status**: WIP design on `experiment/banked-memory`. Extends
`doc/DESIGN_BANKED_SDP_DATABANK.md` (data-only proposal) with the
matching tag-bank banking.

## Why bank both

Current `main` post-route timing on big SDP+URAM configs:

| Cache | Board | WNS @ 300 MHz | Achievable MHz | Binding path |
|---|---|---:|---:|---|
| 1 MB / 8w | U55C | -0.045 ns | ~296 | URAM cascade (CAS_OUT depth on the 34-URAM array) |
| 2 MB / 8w | V80 ES | -1.101 ns | ~226 | URAM cascade (66-URAM array) |
| 2 MB / 8w | V80 production projection | -1.099 ns | ~227 | structurally bound, ~2 MHz from silicon |

The URAM-cascade depth is the binding path on every 1 MB+ configuration.
Banking the URAM array into N=2 banks halves the cascade depth per bank
and recovers concurrent R+W throughput that the current SDP-disable-
port-1 hack costs (~6.3 % per `tb/cocotb/perf_300mhz.sh` measurement).

The tag bank has a smaller URAM/BRAM footprint (~5 BRAM tiles at
512 KB / 8w) but is on the same critical path family — `stage2_reg[id]`
→ tagbank BRAM enable appeared as the V80 ES 512 KB / 250 MHz binding
path. Banking the tag side too halves its fanout and lets the tag /
data banks share the same banking key (so a request only touches one
tag bank + one data bank, not all of them).

Combined target: lift the structural ceiling on 2 MB / 8w / V80 from
~228 MHz today to ≥250 MHz on ES silicon (and proportionally higher
on production U55C / U250).

## Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│ l2_cache                                                          │
│                                                                   │
│  request (line_addr, ...)                                         │
│         │                                                         │
│         ▼                                                         │
│   ┌───────────────┐                                               │
│   │ Bank selector │  bank_id = line_addr[BANK_SEL]                │
│   │ (1 LUT)       │  (or XOR-hash for adversarial workloads)      │
│   └───────────────┘                                               │
│         │ │                                                       │
│   ┌─────┘ └─────┐                                                 │
│   ▼             ▼                                                 │
│ ┌─────────┐   ┌─────────┐  (N=2 banks shown; N parameterizable)   │
│ │ Bank 0  │   │ Bank 1  │                                         │
│ │ ┌─────┐ │   │ ┌─────┐ │                                         │
│ │ │ Tag │ │   │ │ Tag │ │  ← l2_tagbank_banked: N tag banks        │
│ │ └─────┘ │   │ └─────┘ │     (BRAM each; per-bank stage1/stage2) │
│ │ ┌─────┐ │   │ ┌─────┐ │                                         │
│ │ │Data │ │   │ │Data │ │  ← l2_databank_banked: N data banks      │
│ │ └─────┘ │   │ └─────┘ │     (URAM each; per-bank SDP)           │
│ └─────────┘   └─────────┘                                         │
│         │             │                                           │
│         ▼             ▼                                           │
│   ┌──────────────────────┐                                        │
│   │ Output muxing +      │                                        │
│   │ in-flight tag for    │                                        │
│   │ which-bank-served    │                                        │
│   └──────────────────────┘                                        │
└───────────────────────────────────────────────────────────────────┘
```

## Banking key

`bank_id = line_addr[BANK_SEL]` where `BANK_SEL = $clog2(N_BANKS)`
bits taken from the LSBs of the line address.

Lower bits of the line address change most rapidly in graph workloads
(streaming through neighbouring lines), so adjacent lines map to
different banks — maximum concurrency.

For adversarial workloads (e.g., stride-N traffic where N is a power
of two ≥ banks count), an optional XOR-hash on the line address
spreads concentrated traffic across banks. Implementation: 1 LUT per
bank-select bit; off by default, enabled via `BANK_HASH=1`.

## Per-bank concurrency model

Each bank is internally SDP (1R + 1W). Concurrent requests:

| Bank 0 request | Bank 1 request | Outcome |
|---|---|---|
| R | (idle) | bank 0 serves, no contention |
| (idle) | R | bank 1 serves |
| R (bank 0) | R (bank 1) | both serve, parallel |
| R (bank 0) | W (bank 1) | both serve, parallel |
| R | R (same bank) | 2nd request stalls 1 cycle |
| W | W (same bank) | 2nd request stalls 1 cycle |
| R | W (same bank) | both serve (SDP natively handles 1R + 1W) |

Expected stall rate (uniform-random banking, 2 banks):
- P(both ports active concurrently): 6.84 % (from `test_workload` perf)
- P(same-bank given both active): 50 %
- P(bad combination given same-bank — i.e., RR or WW): 50 %
- Expected stall: 6.84 % × 50 % × 50 % = **0.17 % of cycles**

vs the current SDP-mode cost of 6.3 % from disabling port 1
entirely. Net throughput recovery: **~6.1 %** at N_BANKS=2.

## Parameters

| Parameter | Default | Range | Notes |
|---|---:|---|---|
| `N_BANKS` | 1 | 1, 2, 4 | 1 = unchanged (current main RTL passthrough); 2 = recommended; 4 = diminishing returns |
| `BANK_HASH` | 0 | 0, 1 | XOR-hash the bank-select bits; defends against stride-N adversarial workloads |
| existing knobs | — | — | `DATABANK_SDP`, `DB_LATENCY`, `SDP_WRITE_INPUT_REG`, `CASCADE_DEPTH` unchanged |

`N_BANKS=1` MUST produce bit-identical RTL behavior to current main
(skeleton phase verification). `N_BANKS=2` adds the bank arbiter +
parallel storage instances.

## Implementation plan

| Phase | What | Verification gate | Effort |
|---|---|---|---|
| 1 | RTL skeleton: `N_BANKS` parameter, banking-key derivation, `N_BANKS=1` passthrough (no behavior change) | full module regression at `N_BANKS=1` = current behavior; GRASP mutation + formal still pass | 1 day |
| 2 | `l2_databank_banked.sv`: N instances of `sdp_ram_uram` with per-bank request muxing | regression at `N_BANKS=2`; perf_300mhz.sh shows throughput recovery | 3 days |
| 3 | `l2_tagbank_banked.sv`: matching banked tag bank | regression at `N_BANKS=2` with `DATABANK_SDP=1` (tag + data both banked) | 2 days |
| 4 | Output muxing + which-bank-served tag propagation | full regression + 5000-seed soak | 2 days |
| 5 | Same-bank collision arbiter (stall logic) | adversarial test: all-same-bank traffic, no overflow | 2 days |
| 6 | Synth sweep at `N_BANKS={1, 2, 4}` × {U55C 1 MB, U55C 2 MB, V80 1 MB, V80 2 MB} | post-route WNS improvement on at least 2 configs | 1 day |
| 7 | Mutation suite extension for the new banked modules | all mutations KILLED | 1 day |
| 8 | Documentation + per-board deployment-report updates | doc review | 1 day |
| **Total** | | | **~2 weeks** |

## Merge criteria

This branch merges to `main` only when ALL of:

1. `experiment/verify.sh` PASS at `N_BANKS=1` (no-regression check)
2. `experiment/verify.sh` PASS at `N_BANKS=2` (new behavior)
3. New mutation suite for `l2_{tag,data}bank_banked.sv` PASS (100 % score)
4. Post-route WNS improvement ≥ +0.05 ns on at least 2 of the
   validated configurations vs main at the same knob settings
5. `tb/cocotb/perf_300mhz.sh` throughput at `N_BANKS=2` ≥ throughput
   on `main` (i.e., no regression on cyc/txn)
6. User sign-off on the verification output

Each commit on this branch MUST pass at least gates 1 + 3 (the
no-regression check + mutation). Gates 4-5 only apply when claiming
a frequency or throughput win.

## What this branch will NOT attempt

- CDC: both banks run on the same kernel clock. No double-pumping.
- N_BANKS > 4: diminishing returns from the per-bank-collision math;
  more URAMs needed for the wider mux without proportional MHz gain.
- Per-bank policy: all banks share the same replacement policy
  state (GRASP / SRRIP / LRU). Splitting policy state per bank
  would distort hit-rate measurements vs the single-bank reference.
- FSM re-pipelining (the deferred Attack 4 from
  `experiment/aggressive-pipeline`): keeps the cache controller
  intact, only the storage layer is restructured.

## Inheritance from existing design notes

This document supersedes the data-only proposal in
`doc/DESIGN_BANKED_SDP_DATABANK.md` once Phase 1 lands. Until then,
the older note is the canonical reference for the data-bank-only
banking story.
