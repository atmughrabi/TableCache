"""Hash-distribution test for src/l2_hash.sv.

Touches LINES unique line-aligned addresses (one per cache set under a
working hash) and re-classifies each on a second pass. With a healthy
hash the cache holds all LINES lines (1 per set, WAYS-1 way per set
spare); with a degenerate hash (e.g., collapsed to a single set) only
WAYS distinct addresses can fit and the re-classified hit-rate drops
to ~WAYS/LINES.

This is the test that kills l2_hash mutations the rest of the cocotb
regression cannot -- the data scoreboard in test_random checks
correctness, not hit-rate distribution, so a broken hash that still
maps deterministically passes every other test.
"""
from __future__ import annotations
import os
import cocotb
from cocotb.triggers import RisingEdge
from tb_common import reset_dut, attach_mem
from test_grasp import _drive_read, _read_and_classify

BASE        = 0x80000000
LINE_W      = 8
BLOCK_BYTES = 4
LINE_BYTES  = LINE_W * BLOCK_BYTES


@cocotb.test()
async def test_hash_set_coverage(dut):
    """Touch LINES line-aligned addresses; expect re-classify hit-rate
    >= 95% under a healthy hash. A mutated hash that collapses sets
    will not retain enough lines to clear the threshold."""
    await reset_dut(dut, cycles=4096)
    attach_mem(dut, size_bytes=1 << 22)

    lines = int(os.environ.get("TC_LINES", "64"))
    addrs = [BASE + i * LINE_BYTES for i in range(lines)]

    for a in addrs:
        await _drive_read(dut, a)

    hits = 0
    for a in addrs:
        if await _read_and_classify(dut, a):
            hits += 1
    dut._log.info(f"hash set coverage: {hits}/{lines} hits")

    min_hits = (lines * 95) // 100
    assert hits >= min_hits, (
        f"hash distribution insufficient: {hits}/{lines} hits, "
        f"expected >= {min_hits}. Likely cause: hash collapses too "
        f"many distinct addresses to the same cache set."
    )
