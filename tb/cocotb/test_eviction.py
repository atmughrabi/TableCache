"""Enrichment: heavy eviction + writeback + refill round-trip.

Deterministic-RNG single-word writes over a working set MUCH larger than the
cache capacity, so most writes trigger a dirty eviction (writeback) and a later
read refills from the backend. Two flavours:

  * test_evict_roundtrip_aligned      -- writes at the LINE base (block 0).
  * test_evict_roundtrip_nonaligned   -- writes at random NON-line-aligned word
                                         offsets (the FIX-A class: the writeback
                                         must still land the whole line correctly).

Both run the backend WritebackMonitor, which asserts every writeback burst
covers exactly one cache line (never "spans two lines"), and cross-check every
written word by reading it back through the cache. This is the regression the
prior suite lacked: reads-through-the-cache alone passed even when the writeback
was a bus pattern a stricter backend would mishandle.

Run:  make MODULE=test_eviction [VICTIM=1] [TC_LINES=.. TC_WAYS=.. TC_LINE_W=..]
"""
from __future__ import annotations
import os
import random
import cocotb
from cocotb.triggers import RisingEdge, with_timeout
from tb_common import reset_dut, attach_master, attach_mem, golden, WritebackMonitor

BASE        = 0x80000000
BLOCK_BYTES = 4
LINE_W      = int(os.environ.get("TC_LINE_W", "8"))
LINE_BYTES  = LINE_W * BLOCK_BYTES
LINES       = int(os.environ.get("TC_LINES", "64"))
WAYS        = int(os.environ.get("TC_WAYS", "4"))
MEM_MASK    = 0x07FF_FFFF          # matches dut_cocotb MEM_MASK

LOG2_LINE   = LINE_BYTES.bit_length() - 1
LOG2_SETS   = LINES.bit_length() - 1

# Working set: touch a slice of sets, each with more tags than ways -> eviction.
NSET = min(LINES, 16)
NTAG = WAYS * 3                    # 3x over-subscribe every set
NTXN = int(os.environ.get("TC_EVICT_NTXN", str(NSET * NTAG)))
SEED = int(os.environ.get("TC_SEED", "1"))


def _addr(set_i: int, tag_i: int, block: int) -> int:
    return (BASE | (tag_i << (LOG2_LINE + LOG2_SETS))
                 | (set_i << LOG2_LINE) | (block * BLOCK_BYTES))


async def _run(dut, aligned: bool):
    rng = random.Random(SEED + (0 if aligned else 1))
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 21)
    master = attach_master(dut)
    mon = WritebackMonitor(dut, line_w=LINE_W, mem_mask=MEM_MASK)
    cocotb.start_soon(mon.run())

    ref: dict[int, int] = {}
    targets = [(rng.randrange(NSET), rng.randrange(NTAG)) for _ in range(NTXN)]
    for s, t in targets:
        blk = 0 if aligned else rng.randrange(LINE_W)
        addr = _addr(s, t, blk)
        w = rng.randrange(1, 1 << 32)
        ref[addr] = w
        await RisingEdge(dut.clk)
        if hasattr(dut, "s_awsnoop"):
            dut.s_awsnoop.value = 0        # plain single-word write (RMW path)
        await with_timeout(master.write(addr, w.to_bytes(BLOCK_BYTES, "little")),
                           20_000, "ns")

    miss = 0
    for addr, exp in sorted(ref.items()):
        op = await with_timeout(master.read(addr, BLOCK_BYTES), 20_000, "ns")
        got = int.from_bytes(op.data, "little")
        if got != exp:
            miss += 1
            dut._log.error(f"stale @0x{addr:08x} got=0x{got:08x} exp=0x{exp:08x}")

    mon.check()          # every writeback burst covered exactly one line
    dut._log.info(f"[evict {'aligned' if aligned else 'nonaligned'}] "
                  f"txns={NTXN} uniq={len(ref)} writeback_bursts={mon.bursts} "
                  f"beats={mon.beats} miss={miss}")
    assert mon.bursts > 0, "no evictions observed -- working set too small to test writeback"
    assert miss == 0, f"{miss}/{len(ref)} read-backs stale after heavy eviction"


@cocotb.test()
async def test_evict_roundtrip_aligned(dut):
    await _run(dut, aligned=True)


@cocotb.test()
async def test_evict_roundtrip_nonaligned(dut):
    await _run(dut, aligned=False)
