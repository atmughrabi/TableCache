"""Minimal RMW-then-CBOM race repro.

A single write to an UNCACHED line triggers RMW (cache reads line from
mem, merges new bytes, stores dirty). A CleanInvalid CBOM issued in the
cycle immediately after the write's B response is supposed to flush the
dirty data, then drop the line. The cache has an inuse_line_table that
should serialise the CBOM behind the RMW writeback.

This test isolates the smallest failing pattern so a waveform trace
shows the exact FSM state when the writeback is dropped.
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


async def _cbom(dut, master, addr):
    await RisingEdge(dut.clk)
    dut.s_arsnoop.value = ARSNOOP_CLEAN_INVALID
    op = await master.read(addr, BLOCK_BYTES)
    await RisingEdge(dut.clk)
    dut.s_arsnoop.value = 0
    return op


@cocotb.test()
async def test_rmw_then_cbom_minimal(dut):
    """One write (uncached, RMW) + one CleanInvalid + verify mem holds the
    written data. This is the failing pattern the stress test exposed."""
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    addr = BASE | 0x1000
    written = b"\xDE\xAD\xBE\xEF"

    # Write to uncached line (triggers RMW because partial write)
    await master.write(addr, written)

    # CBOM CleanInvalid in the cycle right after the write's B response.
    await _cbom(dut, master, addr)

    # Allow writebacks to drain.
    await Timer(200 * CLK_PERIOD_NS, "ns")

    # Read mem directly. Expected: the written data, because CleanInvalid
    # is documented to flush dirty before dropping the line.
    ram_off = addr & 0x000F_FFFF
    got = bytes(ram.read(ram_off, BLOCK_BYTES))
    dut._log.info(f"mem@0x{addr:x} (-> ram_off 0x{ram_off:x}) = {got.hex()}")
    dut._log.info(f"written = {written.hex()}")

    # Also check what a fresh read returns (should hit mem since line was invalidated).
    rop = await master.read(addr, BLOCK_BYTES)
    cache_view = bytes(rop.data[:4])
    dut._log.info(f"post-CBOM read = {cache_view.hex()}")

    if got == written:
        dut._log.info("PASS: CBOM correctly flushed RMW dirty data")
    else:
        dut._log.warning(
            f"RACE CONFIRMED: mem={got.hex()} != written={written.hex()}. "
            f"CBOM dropped without writeback even though the write should "
            f"have dirtied the RMW'd line."
        )
        # Don't fail — this test is diagnostic. The assertion goes
        # elsewhere once we decide whether this is a bug or a contract.


@cocotb.test()
async def test_rmw_then_cbom_with_settle(dut):
    """Same pattern but with explicit settle cycles between write and
    CBOM. If this PASSES but the back-to-back version fails, the issue
    is a timing window the FSM doesn't close — i.e., a real RTL bug
    rather than a documented serialisation contract."""
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    addr = BASE | 0x2000
    written = b"\xCA\xFE\xBA\xBE"

    await master.write(addr, written)
    await Timer(100 * CLK_PERIOD_NS, "ns")   # quiesce
    await _cbom(dut, master, addr)
    await Timer(200 * CLK_PERIOD_NS, "ns")

    ram_off = addr & 0x000F_FFFF
    got = bytes(ram.read(ram_off, BLOCK_BYTES))
    dut._log.info(f"settled-pattern: mem@0x{addr:x} = {got.hex()} want {written.hex()}")
    if got != written:
        dut._log.warning("RACE STILL FIRES with 100-cycle settle — points to deeper RTL bug")


@cocotb.test()
async def test_rmw_write_alone(dut):
    """Diagnostic: write to uncached line, NO CBOM. Read it back via
    the cache. If the write reached cache it must HIT and return the
    written data. If we see mem-init pattern, the write was silently
    dropped (option C in the analysis)."""
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    addr = BASE | 0x3000
    written = b"\x12\x34\x56\x78"

    await master.write(addr, written)
    await Timer(50 * CLK_PERIOD_NS, "ns")

    # Read back via the cache. Expected: HIT, returns written data
    # (line dirty in cache; cache returns the merged data).
    rop = await master.read(addr, BLOCK_BYTES)
    got = bytes(rop.data[:4])
    dut._log.info(f"cache view: 0x{addr:x} = {got.hex()} want {written.hex()}")

    ram_off = addr & 0x000F_FFFF
    mem_got = bytes(ram.read(ram_off, BLOCK_BYTES))
    dut._log.info(f"mem view:   0x{addr:x} = {mem_got.hex()} init={ '%08x' % ((addr & 0xFFFF) << 16 | 0xCAFE)}")

    assert got == written, (
        f"WRITE TO UNCACHED LINE LOST: cache read returned {got.hex()} "
        f"instead of written {written.hex()} (mem has {mem_got.hex()})"
    )


@cocotb.test()
async def test_rmw_write_then_cbom_then_cache_read(dut):
    """Combine: write (RMW) -> CBOM CleanInvalid -> read via cache.
    Per the contract: CBOM should flush the dirty data to mem, then
    invalidate the line. So the post-CBOM cache read MUST MISS and
    fetch from mem, which MUST contain the written data.
    """
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    addr = BASE | 0x4000
    written = b"\xAA\xBB\xCC\xDD"

    await master.write(addr, written)
    await Timer(50 * CLK_PERIOD_NS, "ns")
    await _cbom(dut, master, addr)
    await Timer(200 * CLK_PERIOD_NS, "ns")

    ram_off = addr & 0x000F_FFFF
    mem_got = bytes(ram.read(ram_off, BLOCK_BYTES))

    rop = await master.read(addr, BLOCK_BYTES)
    cache_got = bytes(rop.data[:4])

    dut._log.info(f"post-CBOM mem:   {mem_got.hex()} want {written.hex()}")
    dut._log.info(f"post-CBOM cache: {cache_got.hex()} want {written.hex()}")
