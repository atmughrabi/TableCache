# AXI VIP simulation (Vivado xsim)

A Vivado **AXI Verification IP** testbench for `l2_top` (the AXI4 wrapper),
run under **xsim**. This is the 4-state companion to the Verilator/cocotb
suites: it is the only flow that exercises the cache from a genuine **cold
power-on** in 4-state (`X`) simulation, which is where the reset/init
behaviour of an FPGA cache must be correct.

## What it checks

`tb_l2top_vip.sv` wires:

```
axi_vip_mst (MASTER VIP)  ->  l2_top.s00 (slave)
l2_top.m00 (master)       ->  axi_vip_slv (SLAVE memory-model VIP)
```

and, from a cold reset, runs self-checking transactions:

- **T1** cold read of a preloaded line → MISS → line fill from the slave
  memory returns the expected, **defined** data (not `X`).
- **T2** write then read-back of the same line → write-allocate, the cache
  returns the written value.
- **T3** a second line write/read.
- **T4** write `WAYS+1` dirty lines mapping to the same set → forces a dirty
  eviction → a **real mem AW** (writeback) to the backend; then reads all
  back (the evicted one refills from mem). Guards the cold write + eviction +
  writeback path that a read-only test misses.
- **T5** whole-cache **flush** (a `tc_flush_controller` CleanInvalid CBOM walk,
  muxed onto the s00 AR) over the now-dirty cache → `flush_done` must pulse.
  Guards the cold CBOM / cbom-FIFO path.

A cold cache only behaves here if the tag/valid arrays were actually cleared
to 0 by the LFSR-walk reset routine — which only works in 4-state once the
reset LFSR has a defined power-on value and the inuse toggle-memories are
immunised against `X` during reset (see `src/lfsr.sv`,
`src/toggle_memory_set.sv`, `src/lutram_1w_*.sv`).

## Running

```bash
./tb/vip/run_vip.sh
```

Requires Vivado 2025.2 (xsim + the AXI VIP IP) on `PATH`. The script:

1. builds a throwaway project (`tb/vip/build/`, git-ignored) with a master
   AXI VIP, a slave memory AXI VIP, and the TableCache RTL;
2. generates the compile/elaborate/simulate scripts;
3. **strips the flow's default `--relax`** and elaborates strictly — the RTL
   compiles under strict xsim ordering rules (no forward references, no
   `initial`/`always` procedural-driver conflicts) with no relaxation;
4. runs the simulation and prints `VIP_RESULT PASS`/`FAIL`.

Env overrides: `VIP_BUILD` (build dir), `VIP_PART` (FPGA part, default
`xcu55c-fsvh2892-2L-e`), and cache config: `VIP_LINES`, `VIP_WAYS`,
`VIP_LINE_W`, `VIP_POLICY` (e.g. `GRASP`). Defaults to a small fast config;
the GraphBlox-scale config is verified with:

```bash
VIP_LINES=512 VIP_WAYS=4 VIP_LINE_W=8 VIP_POLICY=GRASP ./tb/vip/run_vip.sh
```

The reset hold scales automatically from `LINES` (the tag/valid LFSR walk
needs >= LINES cycles), mirroring the wrapper-side `TC_INIT_CYCLES` contract.

## Files

- `tb_l2top_vip.sv` — the AXI VIP testbench.
- `run_vip.tcl` — builds the project + IPs and emits the sim scripts.
- `run_vip.sh` — strips `--relax` and runs compile → elaborate → simulate.
