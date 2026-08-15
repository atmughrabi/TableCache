# FPGA Integration

This document defines the minimum integration requirements for TableCache.
Signal-level details are in [INTERFACING.md](INTERFACING.md).

## Source files

Compile `src/cache_config.sv` before the remaining SystemVerilog files.
The simplest integration includes all files under `src/`.

Primary modules:

| Module | Use |
|---|---|
| `l2_cache` | packed request/response structs |
| `l2_top` | flat AXI4 ports |
| `tc_narrow_shim` | single-beat narrow master to wider cache block |
| `tc_flush_controller` | whole-cache clean/invalidate sequence |

## Configuration

| Parameter | Constraint |
|---|---|
| `ADDR_W` | 32–64 |
| `ADDR_RANGE_L/H` | naturally aligned power-of-two window |
| `LINES` | power of two, 2–65,536 |
| `WAYS` | at least 1 |
| `LINE_W` | 2, 4, 8, or 16 |
| `BLOCK_W` | 8–1024 bits; power-of-two byte count |
| `READ_ID_WIDTH`, `WRITE_ID_WIDTH` | equal, 1–15 |
| `DB_LATENCY` | 1 or 2 |
| `VICTIM_LINES` | at least 2 |
| `N_BANKS` | power of two dividing `LINES` |
| `CASCADE_DEPTH` | 1–8 |

Invalid combinations fail during elaboration.

## Clock and reset

TableCache is single-clock RTL. All request, response, memory, flush, and shim
interfaces use the same clock.

Reset is synchronous and active high in `l2_cache`. `l2_top` exposes an
active-low AXI reset and converts it internally.

Metadata initialization walks the configured storage. The minimum reset length
is the deepest line- or ID-indexed table:

```text
max(LINES, 2 ** (max(READ_ID_WIDTH, WRITE_ID_WIDTH) + 1)) cycles
```

Additional margin is recommended at integration boundaries.
No request VALID signal may remain asserted during reset.

## Request interface

The request side is write-back, read/write-allocate AXI4 with ACE-style cache
maintenance sidebands.

Required transaction properties:

- INCR or WRAP bursts only
- no cache-line crossing
- full data-bus width
- unlocked accesses
- `AxCACHE=4'b1111`
- VALID and payload must remain stable until handshake; the cache applies
  backpressure after four accepted reads or two accepted writes per ID

The all-ones read ID is reserved while flush or prefill logic is active.

## Memory interface

The memory side uses the same data width as the cache block and one additional
ID namespace bit.

The memory system must:

- preserve memory-side IDs, or serialize and restore them without truncation
- implement AXI WRAP correctly
- accept full-line writebacks
- preserve request order required by each ID
- return `OKAY` for R and B responses

TableCache does not recover from failed fills or writebacks.

## Narrow interface

`tc_narrow_shim` accepts aligned, full-width, single-beat narrow accesses. It
aligns requests to `BLOCK_W`, selects one lane, and optionally buffers the most
recent wide line.

`READ_REORDER_DEPTH>1` maps one upstream read ID onto multiple cache IDs and
restores response order. The depth must not exceed `2**ID_W - 1`.

Bursting narrow masters require a standard upstream width converter.

## Cache maintenance

`tc_flush_controller` issues `CleanInvalidByIndex` requests for every set and
way. Its all-ones ID must be reserved during flush.

Assert `flush_req` only after all normal AR, AW, and W traffic has drained.
Keep the slave port idle until `flush_done`.

`l2_top` must be instantiated with `INCLUDE_CBOM=1`, and AR/AW snoop signals
must be connected end-to-end.

Flush completion means:

- every set and way has been visited
- the flush controller has received the final response

`flush_done` is not a memory-persistence barrier. Dirty writeback B responses
may still be draining. Systems that require persistence must also observe the
memory/interconnect outstanding-write state.

## Replacement and storage

Available policies:

- LRU
- FRQ
- second chance
- random
- SRRIP
- GRASP

GRASP configuration is documented in
[wiki/GRASP_Policy.md](wiki/GRASP_Policy.md).

For BRAM-limited designs, `DATABANK_SDP=1` maps the data array to UltraRAM.
Banking and cascade controls are documented in
[wiki/URAM_Mode.md](wiki/URAM_Mode.md).

## Synthesis and timing

Out-of-context synthesis:

```bash
./syn/vivado/run_synth.sh
```

Representative parameter corners:

```bash
./syn/vivado/generic_config_matrix.sh
```

Board references are under [deployment/](deployment/README.md).
Final timing must be measured in the complete design.

## Verification

Required checks after integration:

```bash
cd tb/cocotb
source .venv/bin/activate
make MODULE=test_smoke
pytest -q test_matrix.py
pytest -q test_shim_wrap_matrix.py
pytest -q test_id_depth_matrix.py
pytest -q test_geometry_matrix.py
```

Strict 4-state AXI verification:

```bash
./tb/vip/run_vip.sh
```

See [VERIFICATION.md](VERIFICATION.md) for the complete regression inventory.
