"""Whole-cache flush integration tests."""
from __future__ import annotations

import os
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, Timer, with_timeout
from tb_common import (
    WritebackMonitor, MemRangeMonitor, BASE, cacheable_master,
    high_address_test_base, reset_cycle_count,
)
from cocotbext.axi import AxiBus, AxiMaster, AxiRam

CLK_NS      = 10
BLOCK_BYTES = 4
TEST_BASE = high_address_test_base()
TAG_TEST_BASE = BASE
LINE_W      = int(os.environ.get("TC_LINE_W", "8"))
LINE_BYTES  = LINE_W * BLOCK_BYTES
LINES       = int(os.environ.get("TC_LINES", "64"))
MEM_MASK    = 0x07FF_FFFF   # matches dut_flush.sv


def golden(addr: int) -> int:
    return ((addr & 0xFFFF) << 16) | 0xCAFE


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    dut.rst.value         = 1
    dut.flush_req.value   = 0
    dut.flush_mode.value  = 0
    for sig, v in [("s_arvalid", 0), ("s_awvalid", 0), ("s_wvalid", 0),
                   ("s_rready", 1), ("s_bready", 1),
                   ("s_arsnoop", 0), ("s_awsnoop", 0)]:
        if hasattr(dut, sig):
            getattr(dut, sig).value = v
    for _ in range(reset_cycle_count()):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


def attach(dut, mem_size=1 << 21):
    master = cacheable_master(
        AxiMaster(AxiBus.from_prefix(dut, "s"), dut.clk, dut.rst,
                  reset_active_level=True)
    )
    ram = AxiRam(AxiBus.from_prefix(dut, "m"), dut.clk, dut.rst,
                 size=mem_size, reset_active_level=True)
    # Seed with golden at the dut_flush MEM_MASK image of every addr the cache might fetch.
    seed = bytearray(mem_size)
    for off in range(0, mem_size, BLOCK_BYTES):
        seed[off:off + BLOCK_BYTES] = golden(0x80000000 | off).to_bytes(BLOCK_BYTES, "little")
    ram.write(0, bytes(seed))
    return master, ram


class MAwCounter:
    def __init__(self, dut):
        self.dut = dut
        self.ar = 0
        self.n = 0
        self.full_awaddrs = []
        if not hasattr(dut, "dbg_m_awaddr_full"):
            raise AttributeError(
                "MAwCounter requires the pre-mask dbg_m_awaddr_full tap"
            )

    async def run(self):
        while True:
            await RisingEdge(self.dut.clk)
            await ReadOnly()
            if int(self.dut.m_arvalid) and int(self.dut.m_arready):
                self.ar += 1
            if int(self.dut.m_awvalid) and int(self.dut.m_awready):
                self.n += 1
                self.full_awaddrs.append(int(self.dut.dbg_m_awaddr_full))


def assert_address_prefix(addresses, label):
    expected_prefix = TEST_BASE & ~MEM_MASK
    assert addresses, f"{label} emitted no full-width AW addresses"
    assert all(
        (addr & ~MEM_MASK) == expected_prefix
        for addr in addresses
    ), (
        f"{label} changed address bits above the backing-RAM mask: "
        f"expected prefix 0x{expected_prefix:x}, "
        f"got {[hex(addr) for addr in addresses[:8]]}"
    )


async def request_flush(dut, timeout_cycles=20_000, mode=0):
    dut.flush_mode.value = mode
    dut.flush_req.value = 1
    await RisingEdge(dut.clk)
    dut.flush_req.value = 0
    # Wait for flush_active to rise then fall
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.flush_done):
            return
    assert False, "flush did not complete within timeout"


@cocotb.test()
async def test_flush_clean_state(dut):
    """Warm every line via reads, then flush with MakeInvalid (drop, no
    writeback). flush_done must pulse; 0 mem AWs (no writeback)."""
    await reset_dut(dut)
    master, ram = attach(dut)
    mon = MAwCounter(dut); cocotb.start_soon(mon.run())
    for li in range(LINES):
        await with_timeout(master.read(TAG_TEST_BASE | (li * LINE_BYTES), BLOCK_BYTES),
                            5_000, "ns")
    await request_flush(dut, mode=0b1101)   # MakeInvalid
    await Timer(200, "ns")
    assert mon.n == 0, f"MakeInvalid flush produced {mon.n} mem AWs (expected 0)"
    ar_before = mon.ar
    for li in range(LINES):
        await with_timeout(master.read(TAG_TEST_BASE | (li * LINE_BYTES), BLOCK_BYTES),
                           5_000, "ns")
    refills = mon.ar - ar_before
    assert refills == LINES, (
        f"MakeInvalid left {LINES - refills} clean lines resident"
    )
    dut._log.info(
        f"[flush_clean] MakeInvalid flush_done pulsed, "
        f"mem AWs={mon.n}, refills={refills}"
    )


@cocotb.test()
async def test_flush_writes_back_dirty(dut):
    """Write N dirty lines + warm the rest, flush with CleanInvalid,
    verify every dirty word landed in mem. The flush hits every line
    (LINES total mem AWs is the upper bound, one writeback per line)."""
    await reset_dut(dut)
    master, ram = attach(dut)
    mon = MAwCounter(dut); cocotb.start_soon(mon.run())

    # Warm every line (read) so the CBOM path always hits a present line.
    for li in range(LINES):
        await with_timeout(master.read(TEST_BASE | (li * LINE_BYTES), BLOCK_BYTES),
                            5_000, "ns")

    # Dirty 8 lines with known values
    N = 8
    written = {}
    for k in range(N):
        addr = TEST_BASE | (k * LINE_BYTES + 0x10)
        val  = 0xC0FFEE00 | k
        await with_timeout(master.write(addr, val.to_bytes(BLOCK_BYTES, "little")),
                            5_000, "ns")
        written[addr] = val

    aw_before = mon.n
    address_before = len(mon.full_awaddrs)
    await request_flush(dut)                # CleanInvalidByIndex
    await Timer(400, "ns")
    aw_during = mon.n - aw_before
    # At least N writebacks; cap depends on the cache always-writes-back-on-CleanInvalid behaviour.
    assert aw_during >= N, \
        f"flush issued {aw_during} writebacks (expected >= {N})"
    flushed_addresses = mon.full_awaddrs[address_before:]
    assert_address_prefix(flushed_addresses, "flush")

    for addr, val in written.items():
        mem_off = addr & MEM_MASK
        got = int.from_bytes(ram.read(mem_off, BLOCK_BYTES), "little")
        assert got == val, \
            f"mem @0x{mem_off:08x} after flush: got=0x{got:08x} exp=0x{val:08x}"
    dut._log.info(f"[flush_writes_back_dirty] {N} dirty lines, {aw_during} mem AWs, all data preserved")


@cocotb.test()
async def test_flush_idempotent(dut):
    """Warm + dirty + flush (MakeInvalid). Re-warm and flush again; second
    flush touches now-clean lines and produces no writebacks."""
    await reset_dut(dut)
    master, ram = attach(dut)
    mon = MAwCounter(dut); cocotb.start_soon(mon.run())

    # Warm every line
    for li in range(LINES):
        await with_timeout(master.read(TAG_TEST_BASE | (li * LINE_BYTES), BLOCK_BYTES),
                            5_000, "ns")

    # Dirty one line via write
    addr = TAG_TEST_BASE | 0x2000
    val = 0xDEADBEEF
    await with_timeout(master.write(addr, val.to_bytes(BLOCK_BYTES, "little")),
                        5_000, "ns")

    n0 = mon.n
    await request_flush(dut, mode=0b1101)   # MakeInvalid (drop, no writeback expected)
    await Timer(200, "ns")
    first_writeback = mon.n - n0
    assert first_writeback == 0, f"first MakeInvalid flush produced {first_writeback} writebacks (expected 0)"

    # Second flush: cache is empty after MakeInvalid drop; warm again then flush.
    ar_before = mon.ar
    for li in range(LINES):
        await with_timeout(master.read(TAG_TEST_BASE | (li * LINE_BYTES), BLOCK_BYTES),
                            5_000, "ns")
    refills = mon.ar - ar_before
    assert refills == LINES, (
        f"first MakeInvalid left {LINES - refills} lines resident"
    )
    n1 = mon.n
    await request_flush(dut, mode=0b1101)   # MakeInvalid
    await Timer(200, "ns")
    second_writeback = mon.n - n1
    assert second_writeback == 0, f"second MakeInvalid flush produced {second_writeback} writebacks (expected 0)"
    dut._log.info(
        f"[flush_idempotent] flush1={first_writeback} "
        f"refills={refills} flush2={second_writeback} mem AWs"
    )


@cocotb.test()
async def test_flush_cold_cache(dut):
    """Flushing an unwarmed cache completes without memory traffic."""
    await reset_dut(dut)
    master, ram = attach(dut)
    mon = MAwCounter(dut); cocotb.start_soon(mon.run())
    # Track memory ARs as well
    n_ar = 0
    async def ar_mon():
        nonlocal n_ar
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.m_arvalid) and int(dut.m_arready):
                n_ar += 1
    cocotb.start_soon(ar_mon())

    await request_flush(dut, mode=0b1101)   # MakeInvalid on cold cache
    await Timer(200, "ns")
    assert mon.n == 0, f"cold-cache flush produced {mon.n} mem AWs (expected 0)"
    assert n_ar == 0, f"cold-cache flush produced {n_ar} bogus mem ARs (expected 0)"
    dut._log.info(f"[flush_cold_cache] PASS: mem ARs={n_ar}, mem AWs={mon.n}")


@cocotb.test()
async def test_flush_cold_cache_cleaninvalid(dut):
    """Flush an unwarmed (cold) cache with CleanInvalid (4'b1001) -- the mode
    the tc_flush_controller DEFAULTS to (DEFAULT_MODE). Unlike MakeInvalid,
    CleanInvalid asserts in_clean=1 and exercises the writeback/evict path.
    A cold line is clean+invalid so there is nothing to write back: the flush
    must still complete with 0 mem AWs and 0 mem ARs, returning an R-beat per
    CBOM so the flush controller's WAIT_R never wedges."""
    await reset_dut(dut)
    master, ram = attach(dut)
    mon = MAwCounter(dut); cocotb.start_soon(mon.run())
    n_ar = 0
    async def ar_mon():
        nonlocal n_ar
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.m_arvalid) and int(dut.m_arready):
                n_ar += 1
    cocotb.start_soon(ar_mon())

    await request_flush(dut, mode=0b1001)   # CleanInvalid on cold cache
    await Timer(200, "ns")
    assert mon.n == 0, f"cold-cache CleanInvalid flush produced {mon.n} mem AWs (expected 0)"
    assert n_ar == 0, f"cold-cache CleanInvalid flush produced {n_ar} bogus mem ARs (expected 0)"
    dut._log.info(f"[flush_cold_cache_cleaninvalid] PASS: mem ARs={n_ar}, mem AWs={mon.n}")


@cocotb.test()
async def test_flush_cold_cache_byindex(dut):
    """Flush an unwarmed (cold) cache with the tc_flush_controller's ACTUAL
    default mode = CleanInvalidByIndex (4'b1011). Every invalid-line request
    must still return its completion beat so the controller reaches FINISH."""
    await reset_dut(dut)
    master, ram = attach(dut)
    mon = MAwCounter(dut); cocotb.start_soon(mon.run())
    n_ar = 0
    async def ar_mon():
        nonlocal n_ar
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.m_arvalid) and int(dut.m_arready):
                n_ar += 1
    cocotb.start_soon(ar_mon())

    # mode=0 selects DEFAULT_MODE = CleanInvalidByIndex.
    # request_flush requires completion within its timeout.
    await request_flush(dut, mode=0)
    await Timer(200, "ns")
    assert mon.n == 0, f"cold by-index flush produced {mon.n} mem AWs (expected 0)"
    dut._log.info(f"[flush_cold_cache_byindex] PASS: reached FINISH; mem ARs={n_ar}, mem AWs={mon.n}")


FLUSH_WAYS = int(os.environ.get("TC_WAYS", "4"))


def _flush_addr(set_i: int, tag_i: int, word: int = 4) -> int:
    # set occupies bits [LOG2(LINE_BYTES) +: LOG2(LINES)]; tag is above that.
    log2_line = LINE_BYTES.bit_length() - 1
    log2_sets = LINES.bit_length() - 1
    return TEST_BASE | (tag_i << (log2_line + log2_sets)) | (set_i << log2_line) | (word * BLOCK_BYTES)


@cocotb.test()
async def test_flush_multitag_all_ways(dut):
    """A by-index flush writes back every dirty way regardless of tag."""
    await reset_dut(dut)
    master, ram = attach(dut)
    mon = MAwCounter(dut); cocotb.start_soon(mon.run())
    rangemon = MemRangeMonitor(dut); cocotb.start_soon(rangemon.run())

    SET = 5
    HIGH_TAG = 0x30
    written = {}
    for w in range(FLUSH_WAYS):
        addr = _flush_addr(SET, HIGH_TAG + w, word=w % LINE_W)
        val  = 0xCA11E000 | w
        await with_timeout(master.write(addr, val.to_bytes(BLOCK_BYTES, "little")),
                            5_000, "ns")
        written[addr] = val

    # Pre-flush: backend still holds the ORIGINAL golden values (dirty in cache).
    for addr in written:
        raw = int.from_bytes(ram.read(addr & MEM_MASK, BLOCK_BYTES), "little")
        assert raw == golden(0x80000000 | (addr & MEM_MASK)), \
            f"pre-flush backend @0x{addr:08x} already 0x{raw:08x} (canary not dirty in cache?)"

    aw_before = mon.n
    address_before = len(mon.full_awaddrs)
    await request_flush(dut)                 # mode=0 -> DEFAULT_MODE = by-index
    await Timer(600, "ns")
    aw_during = mon.n - aw_before
    assert aw_during >= FLUSH_WAYS, \
        f"by-index flush issued {aw_during} writebacks (expected >= {FLUSH_WAYS} dirty ways)"
    assert_address_prefix(
        mon.full_awaddrs[address_before:], "multitag flush"
    )

    miss = 0
    for addr, val in written.items():
        got = int.from_bytes(ram.read(addr & MEM_MASK, BLOCK_BYTES), "little")
        if got != val:
            miss += 1
            dut._log.error(f"backend @0x{addr:08x} got=0x{got:08x} exp=0x{val:08x}")
    assert miss == 0, f"{miss}/{FLUSH_WAYS} high-tag dirty ways not written back by flush"

    # Read-back through the cache must also return the written value.
    for addr, val in written.items():
        op = await with_timeout(master.read(addr, BLOCK_BYTES), 5_000, "ns")
        got = int.from_bytes(op.data, "little")
        assert got == val, f"read-back @0x{addr:08x} got=0x{got:08x} exp=0x{val:08x}"
    dut._log.info(f"[flush_multitag_all_ways] PASS: {FLUSH_WAYS} high-tag ways flushed, AWs={aw_during}")
    rangemon.check()   # every reconstructed writeback AW landed in the cacheable range


@cocotb.test()
async def test_flush_scattered_multitag(dut):
    """Flush dirty high-tag lines across multiple sets and ways.

    Writebacks must remain within one line, reach memory with correct data, and
    leave the cache fully invalidated.
    """
    await reset_dut(dut)
    master, ram = attach(dut)
    mon = WritebackMonitor(dut, line_w=LINE_W, mem_mask=MEM_MASK)
    cocotb.start_soon(mon.run())
    counter = MAwCounter(dut); cocotb.start_soon(counter.run())
    rangemon = MemRangeMonitor(dut); cocotb.start_soon(rangemon.run())

    rng = random.Random(0xF10E)
    NSET = min(LINES, 8)
    written = {}
    for s in range(NSET):
        # one clean warmed line (read) at a low tag -> clean+dirty mix per set
        await with_timeout(master.read(_flush_addr(s, 0, 0), BLOCK_BYTES), 5_000, "ns")
        for w in range(FLUSH_WAYS):
            tag = 0x100 + (s * FLUSH_WAYS + w) * 3        # distinct, scattered HIGH tags
            blk = rng.randrange(LINE_W)
            addr = _flush_addr(s, tag, blk)
            val  = 0xD1500000 | (s << 8) | w
            await with_timeout(master.write(addr, val.to_bytes(BLOCK_BYTES, "little")),
                               5_000, "ns")
            written[addr] = val

    address_before = len(mon.full_awaddrs)
    await request_flush(dut)                 # by-index whole-set clean (default)
    await Timer(1000, "ns")
    mon.check()
    assert_address_prefix(
        mon.full_awaddrs[address_before:], "scattered flush"
    )

    # (b) every dirty canary reached the backend (backdoor read, no cache access)
    miss = 0
    for addr, val in written.items():
        got = int.from_bytes(ram.read(addr & MEM_MASK, BLOCK_BYTES), "little")
        if got != val:
            miss += 1
            dut._log.error(f"scattered backend @0x{addr:08x} got=0x{got:08x} exp=0x{val:08x}")
    assert miss == 0, f"{miss}/{len(written)} scattered high-tag dirty lines NOT written back"

    # (c) invalidation: the 1st flush dropped every line, so a 2nd flush over the
    # now-empty cache must issue ZERO writebacks. Done BEFORE any cache read-back
    # (a read would re-allocate the lines and the flush writes valid lines back).
    aw = counter.n
    await request_flush(dut)
    await Timer(600, "ns")
    assert counter.n == aw, \
        f"2nd flush issued {counter.n - aw} writebacks -> 1st flush left lines resident (not invalidated)"

    # data is also correct when refetched through the cache
    for addr, val in written.items():
        op = await with_timeout(master.read(addr, BLOCK_BYTES), 5_000, "ns")
        got = int.from_bytes(op.data, "little")
        assert got == val, f"scattered read-back @0x{addr:08x} got=0x{got:08x} exp=0x{val:08x}"
    dut._log.info(f"[flush_scattered_multitag] PASS: {len(written)} scattered ways over "
                  f"{NSET} sets flushed+invalidated, writeback_bursts={mon.bursts}")
    rangemon.check()   # every reconstructed writeback AW landed in the cacheable range
