# TableCache v2 architecture roadmap

v2 is a **sibling RTL family** at `src/v2/` that explores breaking
TableCache's structural ceilings (the 300+ MHz wall at 1 MB+, the
6.3% SDP throughput cost). v1 at `src/l2_cache.sv` ships unchanged
on `main`.

## Status

| Phase | Status | Outcome |
|---|---|---|
| **v2.0** skeleton | LANDED (`530656e`) | wrapper at N_BANKS_V2=1 == v1 passthrough; 19/19+5/5+10/10 PASS |
| **v2.1** multi-bank | LANDED (`82a3cbd`) | per-bank v1 instances + router/merger; 19/19+5/5+10/10 PASS at N=1,2,4; ~15-32 MHz SLOWER than v1 |
| **v2.2** per-bank FSM redesign | NOT STARTED | the actual frequency-win phase |
| **v2.3** pipelined banks | NOT STARTED | 350 MHz target |
| **v2.4** perf + deployment | NOT STARTED | merge to main as opt-in |

## v2.1 honest result

**Verified correct** at N=1, N=2, N=4: 19/19 cocotb regression +
5/5 GRASP mutation + 10/10 formal proofs, identical to v1.

**Throughput** (`perf_v2_vs_v1.py`; cyc/txn @ LRU, LINES=256, NTXN=2000):
- v1:        12.82 cyc/txn (baseline)
- v2 N=1:    12.82 cyc/txn  (+0.00%, byte-identical -- passthrough)
- v2 N=2:    12.87 cyc/txn  (+0.43%)
- v2 N=4:    13.06 cyc/txn  (+1.94%)

**Post-route frequency** (Vivado 2025.2, 1 MB / 8-way / GRASP):

| Board | Target | Config | WNS | MHz | delta vs v1 |
|---|---|---|---|---|---|
| U55C | 300 MHz | v1 baseline N=2 | -0.310 ns | 274 | -- |
| U55C | 300 MHz | v2 N=2 cascade=1 | -0.612 ns | 253 | **-21 MHz** |
| U55C | 300 MHz | v2 N=2 cascade=8 | -0.523 ns | 259 | **-15 MHz** |
| U55C | 300 MHz | v2 N=4 cascade=8 | -0.949 ns | 233 | **-41 MHz** |
| V80  | 250 MHz | v1 baseline N=2 | -0.145 ns | 241 | -- |
| V80  | 250 MHz | v2 N=2 cascade=1 | -0.772 ns | 209 | **-32 MHz** |

**Why v2.1 is slower**: critical path is *inside* a bank's v1 cache
(`fill_count_reg -> wbe_table -> req_fifo -> URAM BWE`, 9 logic
levels, ~74% routing). Banking halves LINES per bank but doesn't
shorten this internal logic chain. v1's Phase 2a `gen_banked_sdp`
keeps ONE FSM + splits only storage -- still the smarter choice
for frequency. v2.1's per-bank-full-v1-cache wraps add arbiter
combinational depth without breaking the bank-internal binding path.

**Conclusion**: v2.1 is correctness-complete but a frequency
regression. **DO NOT MERGE v2.1 to main as-is.** Keep branch open
for v2.2 (actual per-bank FSM redesign that shortens the internal
critical path).

## Design pillars (v2.0+v2.1 landed; v2.2+ pending)

1. **Per-bank dispatcher** (v2.1 ✓): N_BANKS_V2 v1 caches in parallel
   with address-bit router on slave side, bank-tagged ID widening
   on mem side.
2. **Pipelined request router** (v2.2): 1-cycle skid to break the
   combinational arbiter path. Expected +20-30 MHz at N=2.
3. **Native banked URAM/hybrid BRAM-tag** (v2.3): rebuild each bank
   without the v1 fill_count/wbe_table indirection; route directly
   to URAM BWE. Targets shortening the 9-LL path to 5-6 LL.
4. **ID-routed merge** (v2.2): replace at-most-1-outstanding-per-ID
   with a per-ID FIFO for in-flight tracking (recovers per-ID
   pipelining for high-throughput AXI masters).
5. **Unchanged GRASP/SRRIP/LRU policies**: v2 instantiates the same
   `replacement_policy.sv` per bank; no policy changes.

## What v2 explicitly does NOT do

- Coherency between banks (each bank is independent; same address
  always maps to ONE bank by design)
- Multi-clock domains (single `clk`/`rst` like v1)
- Wider mem-side AXI features (no AXI4/5 deltas; same channels as v1)

## How to use v2 (development only; not yet shipped)

Verification:
```bash
# Passthrough proof (must equal v1)
V2=1 N_BANKS_V2=1 ./experiment/verify.sh
# Recommended multi-bank
V2=1 N_BANKS_V2=2 ./experiment/verify.sh
# Max banking
V2=1 N_BANKS_V2=4 ./experiment/verify.sh
```

Perf comparison:
```bash
cd tb/cocotb
source .venv/bin/activate
python3 perf_v2_vs_v1.py
```

Synthesis (post-route):
```bash
cd syn/vivado
TOP=l2_cache_v2 SIZE=1M N_BANKS_V2=2 PERIOD_NS=3.333 \
    CASCADE_DEPTH=8 PNR=1 ./u55c_synth.sh
TOP=l2_cache_v2 SIZE=1M N_BANKS_V2=2 PERIOD_NS=4.0 \
    CASCADE_DEPTH=1 PNR=1 ./v80_synth.sh
```

## Coexistence with v1

| Layer | v1 path | v2 path |
|---|---|---|
| Top-level | `src/l2_cache.sv` | `src/v2/l2_cache_v2.sv` (sibling) |
| AXI wrapper | `src/l2_top.sv` (uses l2_cache) | `src/v2/l2_top_v2.sv` (planned; uses l2_cache_v2) |
| cocotb testbench | `tb/cocotb/dut_cocotb.sv` | `tb/cocotb/dut_v2_cocotb.sv` |
| Per-board synth | `syn/vivado/{u55c,v80}_synth.sh` | same scripts with `TOP=l2_cache_v2 N_BANKS_V2=N` |
| User opt-in | `l2_cache` instance | `l2_cache_v2` instance (when v2 ships) |

Both v1 and v2 will ship together in the same release once v2 graduates.

## Graduation criteria (when to merge to main)

v2 may merge as an opt-in alongside v1 only when ALL of:
1. `V2=1 N_BANKS_V2={1,2,4} ./experiment/verify.sh` are GREEN
2. `perf_v2_vs_v1.py` shows v2 cyc/txn >= v1 cyc/txn at the same
   workload (within +-5% variance)
3. Post-route MHz on U55C 1MB AND V80 1MB at the same target is
   >= v1 main (no frequency regression)
4. Documentation (root README, wiki, this file) updated

**v2.1 status**: criteria 1+2 GREEN, criterion 3 FAILED (-15..-32 MHz),
criterion 4 done. v2.1 does not merge. v2.2 must address criterion 3.

## Implementation plan

| Step | File(s) | Effort | Status |
|---|---|---|---|
| v2.0 skeleton + N=1 passthrough | `src/v2/l2_cache_v2.sv` | 1 day | DONE |
| v2.1 router + merger + N>=2 | `src/v2/l2_cache_v2.sv` (inline) | 3 days | DONE |
| v2.1 cocotb harness | `tb/cocotb/dut_v2_cocotb.sv` + Makefile | 0.5 day | DONE |
| v2.1 verify.sh integration | `experiment/verify.sh` | 0.5 day | DONE |
| v2.1 perf comparison | `tb/cocotb/perf_v2_vs_v1.py` | 0.5 day | DONE |
| v2.1 PnR on U55C + V80 | `syn/vivado/*` (extended for TOP/N_BANKS_V2) | 0.5 day | DONE |
| **v2.2 pipelined router** | `src/v2/l2_cache_v2.sv` (+ pipelined arb) | 3-5 days | TODO |
| v2.2 throughput recovery (ID-FIFO) | `src/v2/l2_cache_v2.sv` | 2-3 days | TODO |
| v2.3 per-bank logic redesign | `src/v2/l2_databank_v2.sv` (NEW) | 5-7 days | TODO |
| v2.4 perf + deployment reports | `experiment/v2/` | 2 days | TODO |
