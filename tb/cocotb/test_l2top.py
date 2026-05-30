"""Smoke test for l2_top (the AXI4 wrapper around l2_cache).

Before this test, all cocotb regression went through dut_*.sv wrappers
that instantiate l2_cache directly. l2_top's parameter casting,
port forwarding, and the .* connection from l2_top to l2_cache were
only validated at synthesis time (`syn/vivado/run_synth.sh TOP=l2_top`),
never functionally. This test closes that gap.

POLICY=LRU (the l2_top default).
"""
from __future__ import annotations
import cocotb
from cocotb.triggers import RisingEdge, Timer
from cocotbext.axi import AxiBus, AxiMaster, AxiRam
from tb_common import CLK_PERIOD_NS
from cocotb.clock import Clock

BASE        = 0x80000000
BLOCK_BYTES = 4
LINE_W      = 8
LINE_BYTES  = LINE_W * BLOCK_BYTES


async def _reset(dut, cycles=4096):
    dut.rst.value = 1
    for sig in ("s_arvalid", "s_awvalid", "s_wvalid"):
        if hasattr(dut, sig):
            getattr(dut, sig).value = 0
    for sig in ("s_rready", "s_bready"):
        if hasattr(dut, sig):
            getattr(dut, sig).value = 1
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


def _attach_master(dut):
    bus = AxiBus.from_prefix(dut, "s")
    return AxiMaster(bus, dut.clk, dut.rst, reset_active_level=True)


def _attach_mem(dut, size_bytes=1 << 20):
    bus = AxiBus.from_prefix(dut, "m")
    return AxiRam(bus, dut.clk, dut.rst, size=size_bytes, reset_active_level=True)


@cocotb.test()
async def test_l2top_smoke(dut):
    """Single read miss + single write + read-hit verification on l2_top."""
    await _reset(dut)
    ram = _attach_mem(dut, size_bytes=1 << 22)
    master = _attach_master(dut)

    addr = BASE | 0x1000
    written = b"\xDE\xAD\xBE\xEF"

    # Seed mem with a known pattern so the cold-miss read returns it.
    ram.write(addr & 0x000F_FFFF, b"\x01\x02\x03\x04")

    # Cold read: miss path, fetches the line from mem.
    rop = await master.read(addr, BLOCK_BYTES)
    cold = bytes(rop.data[:4])
    dut._log.info(f"cold read 0x{addr:x}: {cold.hex()}")
    assert cold == b"\x01\x02\x03\x04", f"cold read mismatch: {cold.hex()}"

    # Write through the cache.
    await master.write(addr, written)
    await Timer(20 * CLK_PERIOD_NS, "ns")

    # Read again: should hit cache and return the written data.
    rop = await master.read(addr, BLOCK_BYTES)
    hot = bytes(rop.data[:4])
    dut._log.info(f"warm read 0x{addr:x}: {hot.hex()}")
    assert hot == written, f"warm read mismatch: {hot.hex()} != {written.hex()}"


@cocotb.test()
async def test_l2top_two_addresses(dut):
    """Two distinct line addresses, write each, read each back -- exercises
    the l2_top wrapper's AXI ID width handling (.* connection)."""
    await _reset(dut)
    ram = _attach_mem(dut, size_bytes=1 << 22)
    master = _attach_master(dut)

    pairs = [(BASE | 0x2000, b"\x11\x22\x33\x44"),
             (BASE | 0x3000, b"\xAA\xBB\xCC\xDD")]

    for a, d in pairs:
        await master.write(a, d)
    await Timer(50 * CLK_PERIOD_NS, "ns")
    for a, expected in pairs:
        rop = await master.read(a, BLOCK_BYTES)
        got = bytes(rop.data[:4])
        assert got == expected, f"0x{a:x}: got {got.hex()} want {expected.hex()}"
