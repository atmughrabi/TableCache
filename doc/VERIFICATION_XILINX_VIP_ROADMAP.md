# Xilinx AXI VIP roadmap

What the current cocotb regression won't catch, and a phased plan for
covering it with Xilinx-supplied AXI4 Verification IP under Vivado xsim.

## Residual gaps (ranked P x I)

`P` = probability of latent bug today, `I` = deployment impact (both 1-5).

| # | Gap | P | I | Why cocotb misses it |
|---|---|---|---|---|
| A1 | same-line W↔R hazard (rule E5) | 4 | 5 | enforced 1-outstanding-per-ID hides the race; `test_rmw_contention` is serial-W then concurrent-R |
| A2 | response interleaving across IDs (E1/E2) | 3 | 5 | rule deferred; vacuous under 1-per-ID invariant but breaks if that invariant changes |
| A3 | master-issued WRAP burst into cache | 3 | 4 | cocotbext-axi defaults to INCR; no functional WRAP test |
| A4 | EXCLUSIVE (`AxLOCK`) | 4 | 3 | cache treats as normal AR; silently wrong for `LR/SC` masters |
| A5 | `AxCACHE` / `AxPROT` / `AxQOS` / `AxREGION` ignored | 2 | 4 | hard-wired by cache; no test inspects these |
| A6 | `FIXED` burst (`AxBURST=2'b00`) | 3 | 4 | rejected by spec but rejection path not asserted |
| A7 | N distinct IDs targeting same set | 3 | 5 | frontier_merge relies on cocotbext-axi ID rotation |
| A8 | per-policy correct-victim assertion (non-LRU) | 3 | 3 | only LRU has a directed correctness test |
| A9 | per-policy hit-rate floor | 4 | 2 | matrix asserts PASS, not performance |
| A10 | Verilator line/toggle/FSM coverage | 4 | 3 | no `--coverage` run today |
| A11 | CDC | 1 | 5 | single-clock RTL today |
| A12 | X-propagation | 3 | 3 | Verilator drives 0 on uninit |
| A13 | latches / Fmax regression at synth | 2 | 4 | no synth in CI |
| A14 | post-route SDF mismatch | 1 | 4 | no post-route sim |
| A15 | `{AxSIZE, AWLEN, WSTRB}` cross product (bug #7 was in this class) | 3 | 4 | only sparse points tested |
| ~~A16~~ | ~~`l2_top` AXI wrapper not directly exercised~~ | -- | -- | **CLOSED** in 2026-05 by `tb/cocotb/dut_l2top.sv` + `test_l2top.py` (2 smoke cases, both PASS). `l2_top` parameter forwarding + active-low reset adapter + GRASP-port tie-off all execute under sim. Broader coverage matrix (per-policy, per-WAYS) is a follow-up but the wrapper integration path is now live. |
| ~~A17~~ | ~~RMW-then-CBOM race window~~ | -- | -- | **CLOSED** in 2026-05. Root cause was RTL bug #16 (`l2_tagbank.sv`: `out_dirty`/`out_tag` always indexed by `policy_replacement_way_int` instead of the hit way on a CBOM-HIT path). Fix landed in commit `1e5a440`. `test_cbom_rmw_race.py` (4 diagnostic cases) reproduces deterministically on broken RTL and passes post-fix. Full regression 24/24 + 5000-seed soak both green. |
| ~~A18~~ | ~~post-PnR functional sim against the routed netlist~~ | -- | -- | **CLOSED** in 2026-05. `syn/post_pnr_sim.sh` runs the routed V80 netlist (`build/v80_512K_w8_p5_period4.0_pnr1/routed_netlist.v`, WAYS=8/LINES=1024/LINE_W=16/POLICY=GRASP/DB_LATENCY=2) through Vivado xsim with the `simprims_ver` library bound. `tb/post_pnr_smoke_tb.sv` + `tb/post_pnr_l2cache_wrap.sv` drive a single read-miss burst (16 beats) and assert the data matches the deterministic backing-mem pattern. Both functional (`SDF_ANNOTATE=0`, default) and SDF-back-annotated (`SDF_ANNOTATE=1`) modes pass with all 16 beats returning the expected data. The pure SV approach (not cocotb) was forced by cocotb 1.9.x having no xsim backend. |

Highest yield to address: A1, A7, A8, A9 (graph-accelerator critical),
A10 (mechanical), A12-A14 (need non-Verilator sim).

## Why Xilinx VIP

| Want | cocotb today | Xilinx VIP |
|---|---|---|
| AXI4 rules E1-E5 + AxCACHE/AxLOCK | not covered | covered by `axi_protocol_checker` IP |
| Coverage closure | none | `xsim -cov_db` + SV covergroups |
| Post-synth / post-route sim | no (Verilator) | yes (same TB) |
| X-propagation | no | yes (xsim default) |
| Speed | fast | ~10-50x slower |
| Vendor support | community | Xilinx AR support |

Use VIP as a complement to cocotb, not a replacement. Cocotb stays the
pre-commit gate; VIP runs nightly + weekly + pre-release.

## Phases

### Phase 0 — environment

Vivado >= 2024.1 (free WebPACK is enough for xsim and the VIP). Add
`tb/vivado/` with Tcl scripts that create the IP, generate output products,
and launch `xsim`.

### Phase 1 — topology

Three new wrappers mirroring the cocotb DUT wrappers:

| Cocotb wrapper | VIP wrapper | VIP roles |
|---|---|---|
| `dut_cocotb.sv` | `dut_vip_cache.sv` | master VIP on `s_*`, slave-mem VIP on `m_*` |
| `dut_shim_only.sv` | `dut_vip_shim_only.sv` | master VIP on narrow `s_*`, slave-mem VIP on wide `m_*` |
| `dut_shim_cache.sv` | `dut_vip_shim_cache.sv` | master + slave-mem + passthrough VIP between shim and cache |

The passthrough VIP replaces the existing `pc_cache` instance and gives a
per-transaction trace plus automatic protocol checking.

### Phase 2 — port existing tests

Each `test_*.py` becomes an SV class extending `axi_mst_agent` with a
constrained-random or directed sequence. Effort: ~0.5-2 days per port.

| cocotb test | VIP equivalent uses |
|---|---|
| `test_smoke`, `test_lru_sanity`, `test_cbom` | directed sequences |
| `test_random`, `test_workload` | constrained-random with `randomize() with {...}` |
| `test_strobe` | first-class per-beat WSTRB (cocotbext-axi can't do this) |
| `test_backpressure` | `set_ready_delay_pattern(...)` |
| `test_realism` | `slv_mem_agent.set_read_latency_min/max(N)` |
| `test_reset_recovery` | mid-burst reset; xsim X-prop surfaces bugs cocotb hides |
| `test_matrix` | shell wrapper that loops `launch_simulation` |

### Phase 3 — drop in vendor checker

Replace `axi_protocol_checker.sv` with `xilinx.com:ip:axi_protocol_checker`.
Automatically closes A1, A2, A4, A5, A6, A12. Trust-knob equivalents exist
as IP parameters.

### Phase 4 — coverage closure

`xsim -cov_db` + per-test `covergroup` over the AXI fields. Aggregate with
`xcrg -merge`. Target >= 90% functional cross coverage. Closes A9, A10, A15.

### Phase 5 — synth + post-route regression

Same TB at three abstraction levels:

| Level | Vivado mode | Cost | Catches |
|---|---|---|---|
| behavioral | `-mode behavioral` | minutes | functional |
| post-synth | `-mode post-synthesis -type functional` | ~5x | latches, X-prop |
| post-route | `-mode post-implementation -type timing` | ~50-100x | clock-skew, glitches |

Cadence: behavioral every commit, post-synth nightly, post-route pre-release.
Closes A13, A14.

### Phase 6 — performance instrumentation

`axi_perf_mon` IP on every bus. Independent confirmation of `test_latency`
numbers, outstanding-AR/AW occupancy over time, bandwidth.

### Phase 7 — explicit residual-risk tests

| Gap | New SV class |
|---|---|
| A1 | `tc_hazard_wr_during_r` |
| A3 | `tc_wrap_master` directed with `arburst=2'b10` |
| A5 | `tc_axcache_propagation` |
| A7 | `tc_multi_id_same_set` with constrained `arid` |
| A8 | `tc_<policy>_directed` for SRRIP / FRQ / SECOND_CHANCE / RANDOM |

### Phase 8 — CI

GitHub Actions with self-hosted runner that has a Vivado install. Matrix:
`{behavioral, post-synth} x {default, victim-on, srrip}`. Coverage badge
from `xcrg` summary.

## Effort estimate

| Phase | SV-engineer days |
|---|---:|
| 0 environment | 2 |
| 1 topology | 3 |
| 2 port tests | 15 |
| 3 checker swap | 1 |
| 4 coverage | 5 |
| 5 synth + post-route | 3 |
| 6 perf monitors | 1 |
| 7 residual tests | 8 |
| 8 CI | 3 |
| **total** | **~6 weeks** |

Result: closes everything in the residual-gaps table except A11 (CDC,
out of scope for single-clock RTL).
