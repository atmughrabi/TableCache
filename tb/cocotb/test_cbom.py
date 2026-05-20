"""Directed CBOM (Cache Block Maintenance Op) tests.

ACE arsnoop encodings the cache understands (when INCLUDE_CBOM=1):
  4'b1001 CleanInvalid : write back dirty data to mem, then drop line.
  4'b1000 CleanShared  : write back dirty data to mem, line stays present.
  4'b1101 MakeInvalid  : drop line without writing back.

Each CBOM completes with a single R beat (rlast=1, data don't-care) and the
line should no longer (Invalid variants) or should still (Clean) be cached.
We verify by:
  1. priming a dirty line via a partial write,
  2. issuing the CBOM with snoop sideband,
  3. for *Clean* variants: peek the AxiRam to confirm the dirty data flushed,
  4. for *Invalid* variants: read the line again and verify it MISSED to mem
     (we corrupt the mem-side bytes between flush and reread to make the
     miss visible).
"""
from __future__ import annotations
import cocotb
from cocotb.triggers import RisingEdge, Timer, with_timeout
from tb_common import reset_dut, attach_master, attach_mem, golden, CLK_PERIOD_NS
from tb_coverage import sample_read, sample_write, dump_coverage

BASE        = 0x80000000
BLOCK_BYTES = 4
LINE_W      = 8
LINE_BYTES  = LINE_W * BLOCK_BYTES

# Arsnoop CBOM encodings
ARSNOOP_CLEAN_INVALID = 0b1001
ARSNOOP_CLEAN_SHARED  = 0b1000
ARSNOOP_MAKE_INVALID  = 0b1101


def line_addr(s: int, t: int) -> int:
    return BASE | ((t & 0xFFFFF) << 11) | ((s & 0x3F) << 5)


async def _drive_cbom(dut, master, addr: int, snoop: int):
    """Issue a single-beat read with arsnoop=snoop. Returns the AxiReadResp."""
    await RisingEdge(dut.clk)
    dut.s_arsnoop.value = snoop
    op = await with_timeout(master.read(addr, BLOCK_BYTES), 5_000, "ns")
    sample_read(addr, 1, snoop)
    await RisingEdge(dut.clk)
    dut.s_arsnoop.value = 0
    return op


async def _write_dirty(master, addr: int, value_bytes: bytes):
    """Single-beat write (RMW path, snoop=0) to mark the line dirty."""
    await master.write(addr, value_bytes)
    sample_write(addr, 1, 0, True)


@cocotb.test()
async def test_clean_shared_flushes_dirty(dut):
    """CleanShared: dirty line must be written back to mem; line stays cached."""
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    addr = line_addr(s=2, t=7)
    new_word = 0xDEADBEEF
    # Prime: full-line read to install in cache, then partial write to dirty it.
    await master.read(addr, LINE_BYTES)
    await _write_dirty(master, addr, new_word.to_bytes(BLOCK_BYTES, "little"))

    # CleanShared
    await _drive_cbom(dut, master, addr, ARSNOOP_CLEAN_SHARED)
    # Give cache time to issue the WB to mem.
    await Timer(20 * CLK_PERIOD_NS, "ns")

    # Mem should now hold the dirty value (low addr bits = RAM offset).
    ram_off = addr & 0x000F_FFFF
    got = int.from_bytes(ram.read(ram_off, BLOCK_BYTES), "little")
    assert got == new_word, (
        f"CleanShared did not flush: ram[0x{ram_off:x}]=0x{got:08x} "
        f"expected 0x{new_word:08x}"
    )
    dut._log.info("CleanShared flushed dirty line OK")


@cocotb.test()
async def test_clean_invalid_flushes_and_drops(dut):
    """CleanInvalid: dirty line flushed AND dropped. Next read must miss."""
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    addr = line_addr(s=3, t=9)
    new_word = 0xCAFEBABE
    await master.read(addr, LINE_BYTES)
    await _write_dirty(master, addr, new_word.to_bytes(BLOCK_BYTES, "little"))

    await _drive_cbom(dut, master, addr, ARSNOOP_CLEAN_INVALID)
    await Timer(20 * CLK_PERIOD_NS, "ns")

    # Verify flush happened.
    ram_off = addr & 0x000F_FFFF
    got_flushed = int.from_bytes(ram.read(ram_off, BLOCK_BYTES), "little")
    assert got_flushed == new_word, (
        f"CleanInvalid did not flush: ram[0x{ram_off:x}]=0x{got_flushed:08x} "
        f"expected 0x{new_word:08x}"
    )

    # Corrupt RAM at this addr to detect miss-vs-hit on next read.
    sentinel = 0x5A5A_A5A5
    ram.write(ram_off, sentinel.to_bytes(BLOCK_BYTES, "little"))

    # Next read must MISS (line dropped) -> returns sentinel from RAM.
    op = await master.read(addr, BLOCK_BYTES)
    got = int.from_bytes(op.data, "little")
    assert got == sentinel, (
        f"CleanInvalid did NOT drop line: read returned 0x{got:08x} "
        f"(cache hit) instead of fresh-mem sentinel 0x{sentinel:08x}"
    )
    dut._log.info("CleanInvalid flushed AND dropped line OK")


@cocotb.test()
async def test_make_invalid_drops_without_flush(dut):
    """MakeInvalid: line dropped WITHOUT writeback. Dirty data lost (by design)."""
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    addr = line_addr(s=5, t=11)
    new_word = 0x12345678
    # Snapshot pre-write mem value (the seeded golden).
    ram_off = addr & 0x000F_FFFF
    pre_word = int.from_bytes(ram.read(ram_off, BLOCK_BYTES), "little")

    await master.read(addr, LINE_BYTES)
    await _write_dirty(master, addr, new_word.to_bytes(BLOCK_BYTES, "little"))

    await _drive_cbom(dut, master, addr, ARSNOOP_MAKE_INVALID)
    await Timer(20 * CLK_PERIOD_NS, "ns")

    # Mem should NOT have the new word (no writeback).
    got_mem = int.from_bytes(ram.read(ram_off, BLOCK_BYTES), "little")
    assert got_mem != new_word, (
        f"MakeInvalid wrongly flushed: ram[0x{ram_off:x}]=0x{got_mem:08x} "
        f"matches dirty value 0x{new_word:08x} (should have stayed 0x{pre_word:08x})"
    )

    # Corrupt mem with sentinel to confirm next read MISSES (line was dropped).
    sentinel = 0xA5A5_5A5A
    ram.write(ram_off, sentinel.to_bytes(BLOCK_BYTES, "little"))
    op = await master.read(addr, BLOCK_BYTES)
    got = int.from_bytes(op.data, "little")
    assert got == sentinel, (
        f"MakeInvalid did NOT drop line: read returned 0x{got:08x} "
        f"instead of sentinel 0x{sentinel:08x}"
    )
    dut._log.info("MakeInvalid dropped line WITHOUT flush OK")
    dump_coverage("test_cbom")
