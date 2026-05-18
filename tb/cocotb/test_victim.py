"""Directed victim_cache.sv coverage. Only meaningful when built with
VICTIM=1 (i.e. `VICTIM=1 make MODULE=test_victim`).

Targets two victim_cache mutations that survive the general suite:
  - drop_invalidate_clear:  removes `tags_valid <= tags_valid & ~hit_one_hot`
                            in the invalidate path. Killed by issuing a
                            MakeInvalid CBOM after victim has a hit-able
                            line, then re-reading and observing fresh data
                            (mem updated between flush and re-read).
  - swap_write_hit_check:   inverts `tags[i] == w_addr.tag`. Killed by
                            writing N+1 distinct lines that evict, then
                            re-writing one of the evicted lines (write
                            hit in victim) and reading it back; under the
                            mutation, the wrong tag invalidates and a
                            stale read is returned.

Skipped (passes trivially) when VICTIM=0.
"""
from __future__ import annotations
import os
import cocotb
from cocotb.triggers import RisingEdge, Timer, with_timeout
from tb_common import reset_dut, attach_master, attach_mem, CLK_PERIOD_NS

BASE        = 0x80000000
BLOCK_BYTES = 4
LINE_W      = int(os.environ.get("TC_LINE_W", "8"))
WAYS        = int(os.environ.get("TC_WAYS", "4"))
LINES       = int(os.environ.get("TC_LINES", "64"))
LINE_BYTES  = LINE_W * BLOCK_BYTES
NUM_SETS    = LINES
VICTIM_ON   = os.environ.get("TC_VICTIM", "0") == "1" or \
              os.environ.get("VICTIM", "0") == "1"

ARSNOOP_MAKE_INVALID  = 0b1101


def line_addr(s: int, t: int) -> int:
    return BASE | ((t & 0xFFFFF) << 11) | ((s & (NUM_SETS - 1)) << 5)


async def _read_block(master, addr):
    op = await with_timeout(master.read(addr, BLOCK_BYTES), 5_000, "ns")
    return int.from_bytes(op.data, "little")


async def _write_block(master, addr, val):
    await with_timeout(
        master.write(addr, val.to_bytes(BLOCK_BYTES, "little")),
        5_000, "ns"
    )


async def _cbom(dut, master, addr, snoop):
    await RisingEdge(dut.clk)
    dut.s_arsnoop.value = snoop
    await with_timeout(master.read(addr, BLOCK_BYTES), 5_000, "ns")
    await RisingEdge(dut.clk)
    dut.s_arsnoop.value = 0


@cocotb.test(skip=not VICTIM_ON)
async def test_victim_invalidate_clears_tag(dut):
    """Drive a sequence that lands a line in the victim, MakeInvalidates
    it (must clear the victim tag), then re-reads to confirm a fresh mem
    fetch. Kills drop_invalidate_clear: with that mutation, the victim
    tag stays valid and the re-read returns the stale victim copy."""
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    # Fill set 0 with WAYS lines via reads (occupies all ways of set 0).
    set_id = 0
    addrs = [line_addr(s=set_id, t=t) for t in range(WAYS)]
    for a in addrs:
        await _read_block(master, a)
    # Force eviction: read WAYS+1th tag in same set; oldest gets evicted
    # to victim cache (since VICTIM=1).
    extra = line_addr(s=set_id, t=WAYS + 100)
    await _read_block(master, extra)

    # The evicted line should now live in victim. Re-read addrs[0] -- it
    # should hit in the victim and return original (memory-backed) data.
    victim_addr = addrs[0]
    first_read = await _read_block(master, victim_addr)
    expected   = int.from_bytes(ram.read(victim_addr & 0x000F_FFFF, BLOCK_BYTES), "little")
    assert first_read == expected, \
        f"victim hit pre-invalidate: got 0x{first_read:08x} exp 0x{expected:08x}"

    # Mutate mem behind the cache's back so a fresh fetch yields a known sentinel.
    sentinel = 0xC0FFEE00
    ram.write(victim_addr & 0x000F_FFFF,
              sentinel.to_bytes(BLOCK_BYTES, "little"))

    # MakeInvalid -- victim_cache.invalidate must fire and clear victim's
    # tag. Drop the L1 copy too via the cache's CBOM path.
    await _cbom(dut, master, victim_addr, ARSNOOP_MAKE_INVALID)
    await Timer(20 * CLK_PERIOD_NS, "ns")

    # Re-read: must MISS in victim (tag cleared) and refetch from mem.
    second_read = await _read_block(master, victim_addr)
    assert second_read == sentinel, (
        f"victim invalidate failed: re-read returned 0x{second_read:08x}, "
        f"expected fresh mem sentinel 0x{sentinel:08x} "
        f"(victim tag was not cleared)"
    )
    dut._log.info(f"[victim_invalidate] re-read returned fresh sentinel 0x{sentinel:08x} OK")


@cocotb.test(skip=not VICTIM_ON)
async def test_victim_write_hit_invalidates_correct_tag(dut):
    """Write to a line that lives in victim; victim_cache write-through
    invalidates that tag and writes through to mem. Re-read should miss
    in victim (tag cleared) and return the freshly-written value.
    Kills swap_write_hit_check: under the mutation, the WRONG tag is
    invalidated (everything except the matching one) and the line we
    just wrote keeps its old tag in victim -- subsequent read returns
    stale victim copy."""
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    # Fill set 0 + force one line into victim.
    set_id = 0
    addrs = [line_addr(s=set_id, t=t) for t in range(WAYS)]
    for a in addrs:
        await _read_block(master, a)
    extra = line_addr(s=set_id, t=WAYS + 200)
    await _read_block(master, extra)

    victim_addr = addrs[0]

    # Write a NEW value to victim_addr. The L1 cache may re-cache it on
    # write-allocate; the victim_cache sees the write-through and must
    # invalidate its copy via write_hit_one_hot.
    new_val = 0xDEAD0001
    await _write_block(master, victim_addr, new_val)
    await Timer(20 * CLK_PERIOD_NS, "ns")

    # Mutate mem to a different sentinel so we can detect whether the
    # read comes from victim (stale) or from L1/mem (fresh = new_val).
    sentinel = 0xBEEF0002
    ram.write(victim_addr & 0x000F_FFFF,
              sentinel.to_bytes(BLOCK_BYTES, "little"))

    # Force L1 to drop the line so any re-read goes through victim/mem.
    # Use MakeInvalid: drops L1 without writeback, but should NOT touch
    # victim's already-up-to-date line (write_hit handled tags above).
    await _cbom(dut, master, victim_addr, ARSNOOP_MAKE_INVALID)
    await Timer(20 * CLK_PERIOD_NS, "ns")

    # Re-read: since L1 dropped + victim had the line invalidated by the
    # write-through, this should refetch from mem and return sentinel.
    # (If the mutation kept the wrong tag valid, the victim hit returns
    # the pre-write old value.)
    second = await _read_block(master, victim_addr)
    assert second == sentinel, (
        f"write-hit mishandled: re-read returned 0x{second:08x}, "
        f"expected mem sentinel 0x{sentinel:08x}. "
        f"(write_hit_one_hot may have invalidated the wrong tag)"
    )
    dut._log.info(f"[victim_write_hit] re-read returned fresh sentinel 0x{sentinel:08x} OK")
