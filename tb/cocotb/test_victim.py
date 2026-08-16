"""Directed victim-cache invalidation and write-hit coverage."""
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
VICTIM_LINES = int(os.environ.get("TC_VICTIM_LINES", "8"))
LINE_BYTES  = LINE_W * BLOCK_BYTES
NUM_SETS    = LINES
VICTIM_ON   = os.environ.get("TC_VICTIM", "0") == "1" or \
              os.environ.get("VICTIM", "0") == "1"

ARSNOOP_MAKE_INVALID  = 0b1101
WB_ALLOC = 0xF


def line_addr(s: int, t: int) -> int:
    return BASE | ((t & 0xFFFFF) << 11) | ((s & (NUM_SETS - 1)) << 5)


def victim_valid_mask(dut) -> int:
    return int(
        dut._id("dut.gen_victim.vic_inst.tags_valid", extended=False).value
    )


async def _read_block(master, addr):
    op = await with_timeout(
        master.read(addr, BLOCK_BYTES, cache=WB_ALLOC), 5_000, "ns")
    return int.from_bytes(op.data, "little")


async def _write_block(master, addr, val):
    await with_timeout(
        master.write(
            addr, val.to_bytes(BLOCK_BYTES, "little"), cache=WB_ALLOC),
        5_000, "ns"
    )


async def _cbom(dut, master, addr, snoop):
    await RisingEdge(dut.clk)
    dut.s_arsnoop.value = snoop
    await with_timeout(
        master.read(addr, BLOCK_BYTES, cache=WB_ALLOC), 5_000, "ns")
    await RisingEdge(dut.clk)
    dut.s_arsnoop.value = 0


@cocotb.test(skip=not VICTIM_ON)
async def test_victim_invalidate_clears_tag(dut):
    """MakeInvalid clears the matching victim tag."""
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
    for addr in addrs[1:]:
        await _read_block(master, addr)
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
    valid_before = victim_valid_mask(dut)
    assert valid_before

    # Mutate mem behind the cache's back so a fresh fetch yields a known
    # sentinel that's distinct from both the original and the dirty value.
    sentinel = 0xC0FFEE00
    ram.write(victim_addr & 0x000F_FFFF,
              sentinel.to_bytes(BLOCK_BYTES, "little"))

    # MakeInvalid -- victim_cache.invalidate must fire and clear victim's
    # tag. Drop the L1 copy too via the cache's CBOM path.
    await _cbom(dut, master, victim_addr, ARSNOOP_MAKE_INVALID)
    await Timer(40 * CLK_PERIOD_NS, "ns")
    valid_after = victim_valid_mask(dut)
    assert (valid_before & ~valid_after).bit_count() == 1, (
        f"victim invalidate did not clear exactly one tag: "
        f"before=0x{valid_before:x} after=0x{valid_after:x}"
    )

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


@cocotb.test(skip=not VICTIM_ON)
async def test_victim_write_hit_preserves_others(dut):
    """Targets swap_write_hit_check via multi-entry observation.

    Under the mutation, write_hit_one_hot fires on tags that DON'T
    match w_addr.tag, so any concurrent victim entries get incorrectly
    invalidated while only the matching one survives.

    Stimulus:
      1. Dirty addrs[0..3] with distinct dirty_vals.
      2. Evict each to victim (4 dirty entries land in victim).
      3. Sanity: re-read each addrs[i] returns its dirty_val.
      4. Re-cache addrs[0] in L1, write a NEW value, force eviction.
         This triggers write_hit_one_hot processing in victim.
      5. Re-read addrs[1..3]: clean RTL preserves them (dirty_val_i),
         mutated RTL invalidated them so the read goes through to mem.

    We mutate mem under those addrs between steps 4 and 5 so a mem
    fetch is observable as the sentinel rather than the dirty value."""
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    # Keep one victim slot free for the line displaced while re-caching
    # bases[0]. One unrelated entry is sufficient to expose the mutation.
    n_targets = min(4, VICTIM_LINES - 1)
    assert n_targets >= 2
    bases = [line_addr(s=s, t=10 + s) for s in range(n_targets)]
    dirties = [0xD17710A0 | (i << 4) for i in range(n_targets)]

    # Fill each set, dirty its target, make that target LRU, then evict it.
    for i, (a, d) in enumerate(zip(bases, dirties)):
        fillers = [line_addr(s=i, t=100 + i * 16 + k)
                   for k in range(WAYS - 1)]
        for addr in [a, *fillers]:
            await _read_block(master, addr)
        await _write_block(master, a, d)
        for addr in fillers:
            await _read_block(master, addr)
        await Timer(10 * CLK_PERIOD_NS, "ns")
        extra = line_addr(s=i, t=200 + i)
        await _read_block(master, extra)
        await Timer(30 * CLK_PERIOD_NS, "ns")

    valid_before = victim_valid_mask(dut)
    assert valid_before.bit_count() >= len(bases)

    # Re-cache bases[0] and verify its victim data before overwriting it.
    first = await _read_block(master, bases[0])
    assert first == dirties[0]

    # Re-cache addrs[0] in L1, write a new value,
    #    then force re-eviction to trigger write_hit_one_hot.
    new0 = 0xACCE5500
    await _write_block(master, bases[0], new0)
    await Timer(20 * CLK_PERIOD_NS, "ns")
    # Evict addrs[0] from L1 (its set is set 0; fill set 0 with WAYS other tags).
    for k in range(WAYS + 1):
        await _read_block(master, line_addr(s=0, t=500 + k))
    await Timer(40 * CLK_PERIOD_NS, "ns")
    valid_after = victim_valid_mask(dut)
    assert valid_after.bit_count() >= len(bases) - 1, (
        f"write hit cleared unrelated victim tags: "
        f"before=0x{valid_before:x} after=0x{valid_after:x}"
    )

    # Mutate mem for the unrelated entries so a fresh mem fetch is observable as
    # a value distinct from both the dirty and the original mem contents.
    sentinels = [0xBEEF1100 | (i << 4) for i in range(1, n_targets)]
    for a, s in zip(bases[1:], sentinels):
        ram.write(a & 0x000F_FFFF, s.to_bytes(BLOCK_BYTES, "little"))

    # Evict unrelated targets from L1 by reading WAYS+1 distinct tags in their
    # respective sets. Otherwise the re-reads hit L1 and never reach
    # victim, masking the mutation.
    for i in range(1, n_targets):
        for k in range(WAYS + 1):
            await _read_block(master, line_addr(s=i, t=700 + 10*i + k))
    await Timer(40 * CLK_PERIOD_NS, "ns")

    # Re-read the remaining victim entries; all must retain their dirty values.
    #    Mutated RTL -> invalidated by step 4's write_hit, mem fetch returns sentinel.
    for i, a in enumerate(bases[1:], start=1):
        v = await _read_block(master, a)
        assert v == dirties[i], (
            f"victim entry for {hex(a)} was incorrectly invalidated by "
            f"write to addrs[0]: got 0x{v:08x}, expected dirty 0x{dirties[i]:08x} "
            f"(swap_write_hit_check mutation footprint -- write_hit_one_hot "
            f"fired on non-matching tags)"
        )
    dut._log.info(
        f"[victim_write_hit_preserves_others] "
        f"all {n_targets - 1} unrelated entries survived"
    )
