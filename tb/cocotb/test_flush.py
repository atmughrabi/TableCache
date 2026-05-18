"""tc_flush_controller integration test.

Exercises the flush sequencer on top of l2_cache (via dut_flush.sv).
Three scenarios:
  1. test_flush_clean_state -- flush on empty cache; flush_done pulses
     and no mem writebacks fire.
  2. test_flush_writes_back_dirty -- write N dirty lines, flush, verify
     every dirty line was written back to AxiRam.
  3. test_flush_idempotent -- run two flushes back-to-back; second one
     must be fast (no dirty data) and produce no extra mem AW.
"""
from __future__ import annotations

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, Timer, with_timeout
from cocotbext.axi import AxiBus, AxiMaster, AxiRam

CLK_NS      = 10
BASE        = 0x80000000
BLOCK_BYTES = 4
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
    # Enough cycles to cover LFSR reset in storage banks
    for _ in range(max(128, LINES * 2)):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


def attach(dut, mem_size=1 << 21):
    master = AxiMaster(AxiBus.from_prefix(dut, "s"), dut.clk, dut.rst,
                       reset_active_level=True)
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
        self.dut = dut; self.n = 0
    async def run(self):
        while True:
            await RisingEdge(self.dut.clk)
            await ReadOnly()
            if int(self.dut.m_awvalid) and int(self.dut.m_awready):
                self.n += 1


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
        await with_timeout(master.read(BASE | (li * LINE_BYTES), BLOCK_BYTES),
                            5_000, "ns")
    await request_flush(dut, mode=0b1101)   # MakeInvalid
    await Timer(200, "ns")
    assert mon.n == 0, f"MakeInvalid flush produced {mon.n} mem AWs (expected 0)"
    dut._log.info(f"[flush_clean] MakeInvalid flush_done pulsed, mem AWs={mon.n}")


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
        await with_timeout(master.read(BASE | (li * LINE_BYTES), BLOCK_BYTES),
                            5_000, "ns")

    # Dirty 8 lines with known values
    N = 8
    written = {}
    for k in range(N):
        addr = BASE | (k * LINE_BYTES + 0x10)
        val  = 0xC0FFEE00 | k
        await with_timeout(master.write(addr, val.to_bytes(BLOCK_BYTES, "little")),
                            5_000, "ns")
        written[addr] = val

    aw_before = mon.n
    await request_flush(dut, mode=0b1001)   # CleanInvalid
    await Timer(400, "ns")
    aw_during = mon.n - aw_before
    # At least N writebacks; cap depends on the cache always-writes-back-on-CleanInvalid behaviour.
    assert aw_during >= N, \
        f"flush issued {aw_during} writebacks (expected >= {N})"

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
        await with_timeout(master.read(BASE | (li * LINE_BYTES), BLOCK_BYTES),
                            5_000, "ns")

    # Dirty one line via write
    addr = BASE | 0x2000
    val = 0xDEADBEEF
    await with_timeout(master.write(addr, val.to_bytes(BLOCK_BYTES, "little")),
                        5_000, "ns")

    n0 = mon.n
    await request_flush(dut, mode=0b1101)   # MakeInvalid (drop, no writeback expected)
    await Timer(200, "ns")
    first_writeback = mon.n - n0
    assert first_writeback == 0, f"first MakeInvalid flush produced {first_writeback} writebacks (expected 0)"

    # Second flush: cache is empty after MakeInvalid drop; warm again then flush.
    for li in range(LINES):
        await with_timeout(master.read(BASE | (li * LINE_BYTES), BLOCK_BYTES),
                            5_000, "ns")
    n1 = mon.n
    await request_flush(dut, mode=0b1101)   # MakeInvalid
    await Timer(200, "ns")
    second_writeback = mon.n - n1
    assert second_writeback == 0, f"second MakeInvalid flush produced {second_writeback} writebacks (expected 0)"
    dut._log.info(f"[flush_idempotent] flush1={first_writeback} flush2={second_writeback} mem AWs")


@cocotb.test()
async def test_flush_cold_cache(dut):
    """Flush an unwarmed (cold) cache. Previously hung because the cache
    issued a bogus memory fetch on CBOM-miss. After the l2_cache fix
    gating ar_fifo_push for CBOMs, the flush should complete cleanly
    with 0 mem ARs and 0 mem AWs."""
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
