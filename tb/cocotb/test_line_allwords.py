"""Read EVERY word (block) of a cache line back, including odd blocks.

Locks in that the databank fill + per-block read return correct data for ALL
LINE_W blocks of a line, not just block 0 / even blocks. Runs on the bare
l2_cache path at BLOCK_W=32 (the block == the AXI beat, so "block i" is the
32-bit word at line_base + i*4). Two access patterns:

  A) one LINE_W-beat burst read of the whole line
  B) LINE_W separate single-beat reads, word by word (a front-end that reads a
     structure field-by-field after the line is warm)

Motivated by a GraphBlox report of "odd 32-bit words return X" at
BLOCK_W==NARROW_W==32 with a 512-bit backend. That symptom is a mem-side
32b<->512b WIDTH-CONVERSION bug (the cache's block width must equal its memory
port width; see README "AXI4 limitations"). With a matched-width backend the
cache is correct for every block, which this test proves across the reported
WAYS/VICTIM/DB_LATENCY sweep.
"""
from __future__ import annotations
import os
import cocotb
from cocotb.triggers import Timer
from tb_common import reset_dut, attach_master, attach_mem, golden

LINE_W      = int(os.environ.get("TC_LINE_W", "8"))
BLOCK_BYTES = 4                       # BLOCK_W=32 on the bare path
LINE_BYTES  = LINE_W * BLOCK_BYTES
BASE        = 0x80000000


def _assert_word(dut, addr, raw, bad):
    exp = golden(addr)
    got = int.from_bytes(raw, "little")
    if got != exp:
        bad.append((addr, got, exp))
        dut._log.error(
            f"  read 0x{addr:08x} -> 0x{got:08x} exp 0x{exp:08x} "
            f"({'ODD' if (addr & BLOCK_BYTES) else 'even'} block) <-- WRONG/X")


@cocotb.test()
async def test_line_allwords_burst(dut):
    """A) whole-line burst read after a cold fill: every block must be correct."""
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    addr = BASE | 0x00001000
    op = await master.read(addr, LINE_BYTES)
    bad = []
    for i in range(LINE_W):
        _assert_word(dut, addr + i * BLOCK_BYTES,
                     op.data[i * BLOCK_BYTES:(i + 1) * BLOCK_BYTES], bad)
    assert not bad, f"{len(bad)}/{LINE_W} blocks wrong/X: {[hex(a) for a, _, _ in bad]}"


@cocotb.test()
async def test_line_allwords_separate(dut):
    """B) LINE_W separate single-beat reads, word by word. Word 0 cold-fills the
    line; words 1..LINE_W-1 must HIT and return correct data (incl. odd blocks)."""
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    line = BASE | 0x00002000
    bad = []
    for i in range(LINE_W):
        a = line + i * BLOCK_BYTES
        op = await master.read(a, BLOCK_BYTES)   # single 32-bit beat
        _assert_word(dut, a, op.data, bad)
    await Timer(100, "ns")
    assert not bad, f"{len(bad)}/{LINE_W} blocks wrong/X: {[hex(a) for a, _, _ in bad]}"
