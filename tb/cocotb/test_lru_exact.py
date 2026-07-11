"""Exact strict-LRU oracle for arbitrary associativity.

All addresses map to one set. A software LRU queue predicts every hit/miss;
the memory-side AR count is the independent oracle. This catches replacement
tables that retain the right working set under simple fit/thrash patterns but
evict the wrong line after a recency-changing hit.
"""
from __future__ import annotations

import os
import random

import cocotb
from cocotb.triggers import RisingEdge

from tb_common import BASE, attach_master, attach_mem, reset_dut

BLOCK_BYTES = 4
LINE_W = int(os.environ.get("TC_LINE_W", "8"))
LINE_BYTES = LINE_W * BLOCK_BYTES
WAYS = int(os.environ.get("TC_WAYS", "4"))
LINES = int(os.environ.get("TC_LINES", "32"))
WB_ALLOC = 0xF


class MemReadCounter:
    def __init__(self, dut):
        self.dut = dut
        self.count = 0

    async def run(self):
        while True:
            await RisingEdge(self.dut.clk)
            if int(self.dut.m_arvalid) and int(self.dut.m_arready):
                self.count += 1


@cocotb.test()
async def test_exact_lru_sequence(dut):
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)
    monitor = MemReadCounter(dut)
    cocotb.start_soon(monitor.run())

    stride = LINES * LINE_BYTES
    pool = [BASE + index * stride for index in range(WAYS + 3)]

    # Warm all ways, then mix recency-changing hits with new lines. The random
    # tail is deterministic and biased toward resident lines so every possible
    # queue position is promoted/evicted repeatedly.
    sequence = list(range(WAYS))
    sequence += [0, max(0, WAYS - 2), 0, WAYS, 1, WAYS + 1, 0, WAYS - 1]
    rng = random.Random(0x1_2_3_4)
    sequence += [rng.randrange(len(pool)) for _ in range(160)]

    lru = []  # least-recent -> most-recent
    for operation, line_index in enumerate(sequence):
        expected_miss = line_index not in lru
        before = monitor.count
        await master.read(pool[line_index], BLOCK_BYTES, cache=WB_ALLOC)
        observed_miss = (monitor.count - before) == 1
        assert observed_miss == expected_miss, (
            f"LRU mismatch op={operation} line={line_index}: "
            f"expected {'MISS' if expected_miss else 'HIT'}, "
            f"observed {'MISS' if observed_miss else 'HIT'}, "
            f"shadow_lru={lru}")

        if not expected_miss:
            lru.remove(line_index)
        elif len(lru) == WAYS:
            lru.pop(0)
        lru.append(line_index)

    dut._log.info(
        f"[lru-exact] WAYS={WAYS}: {len(sequence)} accesses matched strict "
        "software LRU hit/miss decisions")
