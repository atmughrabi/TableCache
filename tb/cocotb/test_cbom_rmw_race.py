"""Verify RMW serialization against an immediate CleanInvalid operation.

The maintenance request follows the write response without an idle cycle. It
must wait for the line transaction, write back the merged data, and invalidate
the line.
"""
from __future__ import annotations
import cocotb
from cocotb.triggers import RisingEdge, Timer
from tb_common import reset_dut, attach_master, attach_mem, golden, CLK_PERIOD_NS

BASE        = 0x80000000
BLOCK_BYTES = 4
LINE_W      = 8
LINE_BYTES  = LINE_W * BLOCK_BYTES

ARSNOOP_CLEAN_INVALID = 0b1001


def _merged_line(addr, written):
    line_base = addr & ~(LINE_BYTES - 1)
    expected = bytearray()
    for offset in range(0, LINE_BYTES, BLOCK_BYTES):
        expected.extend(golden(line_base + offset).to_bytes(BLOCK_BYTES, "little"))
    word_offset = addr - line_base
    expected[word_offset:word_offset + len(written)] = written
    return line_base, bytes(expected)


async def _cbom(dut, master, addr):
    await RisingEdge(dut.clk)
    dut.s_arsnoop.value = ARSNOOP_CLEAN_INVALID
    op = await master.read(addr, BLOCK_BYTES)
    await RisingEdge(dut.clk)
    dut.s_arsnoop.value = 0
    return op


@cocotb.test()
async def test_rmw_then_cbom_minimal(dut):
    """Back-to-back RMW and CleanInvalid preserve the merged data."""
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    addr = BASE | 0x1000
    written = b"\xDE\xAD\xBE\xEF"
    line_base, expected_line = _merged_line(addr, written)

    # Write to uncached line (triggers RMW because partial write)
    await master.write(addr, written)

    # CBOM CleanInvalid in the cycle right after the write's B response.
    await _cbom(dut, master, addr)

    # Allow writebacks to drain.
    await Timer(200 * CLK_PERIOD_NS, "ns")

    # Read mem directly. Expected: the written data, because CleanInvalid
    # is documented to flush dirty before dropping the line.
    ram_off = line_base & 0x000F_FFFF
    got = bytes(ram.read(ram_off, LINE_BYTES))
    dut._log.info(f"mem@0x{addr:x} (-> ram_off 0x{ram_off:x}) = {got.hex()}")
    dut._log.info(f"written = {written.hex()}")

    # Also check what a fresh read returns (should hit mem since line was invalidated).
    rop = await master.read(line_base, LINE_BYTES)
    cache_view = bytes(rop.data)
    dut._log.info(f"post-CBOM read = {cache_view.hex()}")

    assert got == expected_line, (
        f"CleanInvalid corrupted RMW line: memory={got.hex()} "
        f"expected={expected_line.hex()}"
    )
    assert cache_view == expected_line, (
        f"post-CBOM refill returned {cache_view.hex()} "
        f"expected={expected_line.hex()}"
    )


@cocotb.test()
async def test_rmw_then_cbom_with_settle(dut):
    """The settled form preserves the same maintenance contract."""
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    addr = BASE | 0x2000
    written = b"\xCA\xFE\xBA\xBE"
    line_base, expected_line = _merged_line(addr, written)

    await master.write(addr, written)
    await Timer(100 * CLK_PERIOD_NS, "ns")   # quiesce
    await _cbom(dut, master, addr)
    await Timer(200 * CLK_PERIOD_NS, "ns")

    ram_off = line_base & 0x000F_FFFF
    got = bytes(ram.read(ram_off, LINE_BYTES))
    dut._log.info(f"settled-pattern: mem@0x{addr:x} = {got.hex()} want {written.hex()}")
    assert got == expected_line, (
        f"settled CleanInvalid corrupted RMW line: memory={got.hex()} "
        f"expected={expected_line.hex()}"
    )


@cocotb.test()
async def test_rmw_write_alone(dut):
    """An RMW write remains visible in the cache before maintenance."""
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    addr = BASE | 0x3000
    written = b"\x12\x34\x56\x78"
    line_base, expected_line = _merged_line(addr, written)

    await master.write(addr, written)
    await Timer(50 * CLK_PERIOD_NS, "ns")

    # Read back via the cache. Expected: HIT, returns written data
    # (line dirty in cache; cache returns the merged data).
    rop = await master.read(line_base, LINE_BYTES)
    got = bytes(rop.data)
    dut._log.info(f"cache view: 0x{addr:x} = {got.hex()} want {written.hex()}")

    ram_off = addr & 0x000F_FFFF
    mem_got = bytes(ram.read(ram_off, BLOCK_BYTES))
    dut._log.info(f"mem view:   0x{addr:x} = {mem_got.hex()} init={ '%08x' % ((addr & 0xFFFF) << 16 | 0xCAFE)}")

    assert got == expected_line, (
        f"RMW merge corrupted cache line: cache={got.hex()} "
        f"expected={expected_line.hex()} (memory word={mem_got.hex()})"
    )


@cocotb.test()
async def test_rmw_write_then_cbom_then_cache_read(dut):
    """Combine: write (RMW) -> CBOM CleanInvalid -> read via cache.
    Per the contract: CBOM should flush the dirty data to mem, then
    invalidate the line. The post-CBOM read must miss and refill the written
    data from memory.
    """
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    addr = BASE | 0x4000
    written = b"\xAA\xBB\xCC\xDD"
    line_base, expected_line = _merged_line(addr, written)

    await master.write(addr, written)
    await Timer(50 * CLK_PERIOD_NS, "ns")
    await _cbom(dut, master, addr)
    await Timer(200 * CLK_PERIOD_NS, "ns")

    ram_off = line_base & 0x000F_FFFF
    mem_got = bytes(ram.read(ram_off, LINE_BYTES))

    rop = await master.read(line_base, LINE_BYTES)
    cache_got = bytes(rop.data)

    dut._log.info(f"post-CBOM mem:   {mem_got.hex()} want {written.hex()}")
    dut._log.info(f"post-CBOM cache: {cache_got.hex()} want {written.hex()}")
    assert mem_got == expected_line, (
        f"CleanInvalid writeback returned {mem_got.hex()} "
        f"expected={expected_line.hex()}"
    )
    assert cache_got == expected_line, (
        f"post-CBOM refill returned {cache_got.hex()} "
        f"expected={expected_line.hex()}"
    )
