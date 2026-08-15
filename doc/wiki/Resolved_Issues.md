# Resolved Engineering Issues

This page records defect classes that materially changed the implementation or
verification strategy. It is organized by subsystem rather than discovery
order.

## Request and completion tracking

| Failure class | Resolution | Regression |
|---|---|---|
| Saved AR/AW handshake races | One-entry channel buffers with registered-ready semantics | directed request tests |
| Split read/write completion lost occupancy clears | Deferred per-ID clear state | burst and eviction liveness tests |
| Accept and finish toggled the same occupancy entry | Defer colliding accepts for one cycle | `test_inuse_race.py` |
| Same-ID reuse matched stale pipeline state | Per-read generation tags | flush and multiread tests |
| Duplicate completion clear | Track the cleared ID and line hash per finish entry | random and liveness tests |

## Addressing and AXI

| Failure class | Resolution | Regression |
|---|---|---|
| Full-range address-span overflow | Compute range span with one extra bit | range matrix and base-zero xsim |
| Address prefix omitted during reconstruction | Preserve the configured NAPOT prefix | eviction/flush range tests |
| GRASP received a compressed address | Reconstruct the full line-aligned system address | GRASP directed and performance tests |
| WRAP memory model treated bursts as INCR | Implement AXI WRAP address progression | WRAP matrix |
| Memory-side response errors hidden by victim path | Preserve response codes and assert the error-free backend contract | memory-error matrix |
| Reset leaked stale AXI VALID signals | Gate interface VALID signals during reset | reset-recovery and xsim tests |

## Databank and memory inference

| Failure class | Resolution | Regression |
|---|---|---|
| Wide partial non-blocking writes lost bytes in Verilator | Masked full-width simulation write | wide shim/cache tests |
| Vivado rejected TDP UltraRAM inference | Keep TDP storage on BRAM; use SDP for UltraRAM | OOC synthesis |
| Wide SDP simulation lost enabled bytes | Masked simulation write in `sdp_ram_uram` | SDP width matrix |
| Partial read emitted a trailing sibling block | Generation-qualified tail suppression | concurrent-hit protocol tests |
| One-line-per-bank generated a zero-width slice | Block-only bank address path | geometry and synthesis matrices |

## Replacement and maintenance

| Failure class | Resolution | Regression |
|---|---|---|
| Three- and four-way compressed LRU tables selected the wrong victim | Regenerated strict-LRU state tables | exact software-LRU oracle |
| CBOM hit used the policy-selected way instead of the hit way | Select resident metadata from the hit way | CBOM RMW test |
| Address-based flush missed arbitrary resident tags | By-index set-and-way traversal | flush matrix |
| Non-power-of-two victim capacity indexed beyond storage | Explicit wrap at the configured entry count | victim capacity matrix |

## Narrow interface

| Failure class | Resolution | Regression |
|---|---|---|
| Same-ID reads overwrote per-ID state | Serialize in the core; optional reorder buffer maps to distinct IDs | ID/depth matrix |
| Prefill arbitration changed a stalled AR payload | Hold the selected AR until handshake | prefill-race protocol test |
| A stalled buffered R response lost channel ownership | Hold the buffered response until handshake | buffered-response backpressure test |
| Concurrent fill and write merge mixed different lines | Merge only when the incoming fill tag matches | fill/write collision test |
| Depth-one AW FIFO used a zero-width index | Explicit constant index | minimum-depth tests |
| RATIO=1 selected an out-of-range lane | Force lane zero | strict xsim shim test |
| Buffered response referenced mutable line-buffer data | Snapshot the selected word on acceptance | buffer snapshot test |
| Downstream width converter wrapped at the wrong boundary | Require AXI burst-boundary wrapping | WRAP negative control |

## Verification infrastructure

| Failure class | Resolution | Regression |
|---|---|---|
| Verilator did not fully reset large unpacked checker arrays | Use packed active-ID vectors | wide-ID warm-reset test |
| Cocotb failures returned a successful make status | Parse JUnit results and fail on protocol counts | result-gate negative checks |
| Broken or surviving mutations still returned success | Fail the mutation runner on either condition | mutation baseline and exit checks |

Current tests and commands are listed in
[../VERIFICATION.md](../VERIFICATION.md).
