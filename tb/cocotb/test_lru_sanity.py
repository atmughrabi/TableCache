"""LRU sanity at WAYS=8: streaming reads to N unique lines, where N = WAYS
exactly. After warmup, every access should hit because all N lines fit in
one set (and the cache as a whole). If LRU is correct, this is 100% hit
after the first N misses.
"""
from __future__ import annotations
import os
import cocotb
from cocotb.triggers import RisingEdge, Timer
from tb_common import reset_dut, attach_master, attach_mem

BASE        = 0x80000000
BLOCK_BYTES = 4
LINE_W      = 8
LINE_BYTES  = LINE_W * BLOCK_BYTES
WAYS        = int(os.environ.get("TC_WAYS", "4"))
LINES       = int(os.environ.get("TC_LINES", "64"))


class MemAR:
    def __init__(self, dut):
        self.dut, self.n, self._stop = dut, 0, False

    async def run(self):
        d = self.dut
        while not self._stop:
            await RisingEdge(d.clk)
            if int(d.m_arvalid.value) == 1 and int(d.m_arready.value) == 1:
                self.n += 1


@cocotb.test()
async def test_lru_sanity(dut):
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 27)
    master = attach_master(dut)
    mon = MemAR(dut)
    cocotb.start_soon(mon.run())

    # Pick N=WAYS distinct lines that all map to the SAME cache set.
    set0_stride = LINES * LINE_BYTES
    addrs = [BASE | (i * set0_stride) for i in range(WAYS)]

    # Warmup phase: each line first-touched is a miss.
    for a in addrs:
        await master.read(a, BLOCK_BYTES)
    warmup_misses = mon.n
    dut._log.info(f"[lru] warmup_misses={warmup_misses} (expected {WAYS})")

    # Stress: round-robin reads. With correct strict LRU, EVERY read hits.
    n_rounds = 30
    for _ in range(n_rounds):
        for a in addrs:
            await master.read(a, BLOCK_BYTES)
    await Timer(200, "ns")

    extra_misses = mon.n - warmup_misses
    total_accesses = n_rounds * len(addrs)
    dut._log.info(
        f"[lru] WAYS={WAYS} LINES={LINES} N_addrs={len(addrs)} rounds={n_rounds} "
        f"-- warmup_misses={warmup_misses} stress_misses={extra_misses} / {total_accesses}"
    )
    assert warmup_misses == WAYS, (
        f"cold-miss count wrong: got {warmup_misses}, expected {WAYS}"
    )
    assert extra_misses == 0, (
        f"LRU BUG: {extra_misses} unexpected misses during stress phase "
        f"({total_accesses} accesses to {WAYS} resident lines in a "
        f"{WAYS}-way set should ALL hit if LRU is strict)"
    )


@cocotb.test()
async def test_lru_thrash(dut):
    """Cyclic access pattern over WAYS+1 lines in one set.

    Strict LRU has predictable behaviour here: each round evicts the line we
    just touched longest ago, which is the line we're about to need next.
    Steady-state miss rate = 100%, so over `n_rounds` rounds each touching
    WAYS+1 lines we expect WAYS+1 misses per round (= total_accesses misses).
    A misbehaving LRU may show LOWER OR HIGHER miss count.
    """
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 27)
    master = attach_master(dut)
    mon = MemAR(dut)
    cocotb.start_soon(mon.run())

    n = WAYS + 1
    set0_stride = LINES * LINE_BYTES
    addrs = [BASE | (i * set0_stride) for i in range(n)]

    n_rounds = 20
    for _ in range(n_rounds):
        for a in addrs:
            await master.read(a, BLOCK_BYTES)
    await Timer(200, "ns")

    total_accesses = n_rounds * n
    misses = mon.n
    miss_rate = 100.0 * misses / total_accesses
    dut._log.info(
        f"[lru-thrash] WAYS={WAYS} n_addrs={n} rounds={n_rounds} "
        f"misses={misses}/{total_accesses} ({miss_rate:.1f}%) -- expect ~100% for strict LRU"
    )
    # Strict LRU should miss every access in steady state (after first round).
    # Allow first round to be all-cold misses too -> total miss rate ~ 100%.
    assert miss_rate >= 95.0, (
        f"LRU THRASH BUG: only {misses}/{total_accesses} ({miss_rate:.1f}%) misses; "
        f"strict LRU with N=WAYS+1 cyclic should miss nearly every access. "
        f"Lower miss rate => replacement is NOT strict LRU."
    )

