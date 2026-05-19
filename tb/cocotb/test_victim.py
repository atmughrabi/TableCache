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
    """Drive a sequence that lands a DIRTY line in victim, then
    MakeInvalidates it. Must clear the victim tag so the re-read
    refetches from mem. Kills drop_invalidate_clear: under the
    mutation, the victim tag stays valid and the re-read returns
    the stale (dirty) victim copy.

    KEY: the line must be dirty before eviction, otherwise the L1
    evicts without issuing victim_aw/victim_w and the victim's
    line_storage never receives data -- only a tag-only entry. With
    no data in victim, the L1 always falls through to mem and the
    test cannot distinguish the mutation."""
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    # Fill set 0 with WAYS lines via reads.
    set_id = 0
    addrs = [line_addr(s=set_id, t=t) for t in range(WAYS)]
    for a in addrs:
        await _read_block(master, a)

    # DIRTY addrs[0] so the eviction triggers a write-through to victim's
    # line_storage. The dirty value `dirty_val` is what victim will hold.
    dirty_val = 0xDEADC0DE
    await _write_block(master, addrs[0], dirty_val)
    await Timer(20 * CLK_PERIOD_NS, "ns")

    # Force eviction: read WAYS+1th tag in same set; oldest dirty line
    # gets evicted to victim with its dirty data.
    extra = line_addr(s=set_id, t=WAYS + 100)
    await _read_block(master, extra)
    await Timer(40 * CLK_PERIOD_NS, "ns")

    # Re-read addrs[0]: must hit in victim (tag valid + data buffered)
    # and return the dirty value we just wrote.
    victim_addr = addrs[0]
    first_read = await _read_block(master, victim_addr)
    assert first_read == dirty_val, (
        f"victim hit pre-invalidate: got 0x{first_read:08x} "
        f"expected dirty value 0x{dirty_val:08x} -- did the dirty line "
        f"actually reach victim's line_storage?"
    )

    # Mutate mem behind the cache's back so a fresh fetch yields a known
    # sentinel that's distinct from both the original and the dirty value.
    sentinel = 0xC0FFEE00
    ram.write(victim_addr & 0x000F_FFFF,
              sentinel.to_bytes(BLOCK_BYTES, "little"))

    # MakeInvalid -- victim_cache.invalidate must fire and clear victim's
    # tag. Drop the L1 copy too via the cache's CBOM path.
    await _cbom(dut, master, victim_addr, ARSNOOP_MAKE_INVALID)
    await Timer(40 * CLK_PERIOD_NS, "ns")

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
    """Sequence:
      1. Dirty addrs[0] with dirty_val.
      2. Evict addrs[0] to victim (line_storage gets dirty_val).
      3. Write NEW value new_val to addrs[0] via cache. Eventually L1
         evicts addrs[0] again with new_val; victim_aw fires; write_hit
         logic should clear the matching tag in victim (so victim no
         longer has stale dirty_val).
      4. Force eviction of addrs[0] from L1 by reading enough new lines.
      5. Re-read addrs[0]: under correct RTL, victim missed (tag was
         cleared by write_hit), so the read sees the post-write mem
         contents (new_val). Under swap_write_hit_check, the wrong
         tags were invalidated and the matching addrs[0] tag stayed
         valid pointing at OLD dirty_val -- the re-read returns
         dirty_val.

    Crucially: this test does NOT issue MakeInvalid on victim_addr,
    because that would use the (separately-mutated) `hit_one_hot`
    path and clear the tag through a different mechanism, masking the
    write_hit mutation."""
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    set_id = 0
    addrs = [line_addr(s=set_id, t=t) for t in range(WAYS)]
    for a in addrs:
        await _read_block(master, a)

    victim_addr = addrs[0]
    dirty_val   = 0xC0DEC0DE
    await _write_block(master, victim_addr, dirty_val)
    await Timer(20 * CLK_PERIOD_NS, "ns")

    # Evict to victim with dirty_val
    extra1 = line_addr(s=set_id, t=WAYS + 300)
    await _read_block(master, extra1)
    await Timer(40 * CLK_PERIOD_NS, "ns")

    # Sanity: addrs[0] should now hit in victim with dirty_val
    sanity = await _read_block(master, victim_addr)
    assert sanity == dirty_val, (
        f"pre-write sanity: addrs[0] in victim should return dirty_val "
        f"0x{dirty_val:08x}, got 0x{sanity:08x}"
    )

    # Re-cache addrs[0] in L1 (the sanity read brought it back), then
    # write a NEW value. Eventually we evict addrs[0] again to force
    # victim_aw with the new value -- triggering write_hit_one_hot.
    new_val = 0xABCD1234
    await _write_block(master, victim_addr, new_val)
    await Timer(40 * CLK_PERIOD_NS, "ns")

    # Force L1 to evict addrs[0] by reading 2*WAYS more distinct tags
    # in the same set. This pushes addrs[0] out of L1 again, and the
    # write_hit_one_hot path inside victim runs as the new line is
    # buffered.
    for k in range(WAYS * 2):
        await _read_block(master, line_addr(s=set_id, t=WAYS + 400 + k))
    await Timer(40 * CLK_PERIOD_NS, "ns")

    # Mutate mem so we can tell whether the re-read came from victim
    # or from a fresh mem fetch.
    sentinel = 0xBEEF0099
    ram.write(victim_addr & 0x000F_FFFF,
              sentinel.to_bytes(BLOCK_BYTES, "little"))

    # Re-read addrs[0]: correct RTL -> victim miss (write_hit cleared the
    # tag) -> mem fetch returns sentinel (or new_val if mem was updated
    # by the write-through; we mutated mem so it's sentinel). Mutated
    # RTL -> victim still has dirty_val with the wrong tag invalidations.
    final = await _read_block(master, victim_addr)
    assert final != dirty_val, (
        f"victim returned stale dirty_val 0x{dirty_val:08x} -- "
        f"write_hit_one_hot did not invalidate the correct tag "
        f"(swap_write_hit_check mutation footprint)"
    )
    dut._log.info(f"[victim_write_hit] final read 0x{final:08x} != dirty 0x{dirty_val:08x} OK")
