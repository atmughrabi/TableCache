"""Functional tests for the flat AXI l2_top wrapper."""
from __future__ import annotations
import cocotb
from cocotb.triggers import RisingEdge, Timer
from cocotbext.axi import AxiBus, AxiMaster, AxiRam
from tb_common import CLK_PERIOD_NS, BASE, cacheable_master
from cocotb.clock import Clock

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
    return cacheable_master(
        AxiMaster(bus, dut.clk, dut.rst, reset_active_level=True)
    )


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


@cocotb.test()
async def test_l2top_burst_idle_liveness(dut):
    """Back-to-back same-ID reads remain live across an idle interval."""
    import os
    from cocotb.triggers import ReadOnly
    await _reset(dut)
    ram = _attach_mem(dut, size_bytes=1 << 22)
    if hasattr(dut, "s_arsnoop"):
        dut.s_arsnoop.value = 0
    BURST_N = int(os.environ.get("TC_BURST_N", "4"))
    IDLE    = int(os.environ.get("TC_IDLE", "400"))
    ARLEN   = int(os.environ.get("TC_ARLEN", "0"))   # 0=single word; LINE_W-1=full line
    ARSIZE  = (BLOCK_BYTES.bit_length() - 1)
    MEM_MASK = 0x000F_FFFF

    # Four distinct cold lines, seeded in memory.
    addrs = [BASE | (0xB000 + i * LINE_BYTES) for i in range(BURST_N)]
    for i, a in enumerate(addrs):
        ram.write(a & MEM_MASK, bytes([(0x11 * (i + 1)) & 0xFF, 0x2c, 0x00, 0x7c]))

    got = []
    async def r_collector():
        dut.s_rready.value = 1
        while True:
            await RisingEdge(dut.clk); await ReadOnly()
            if int(dut.s_rvalid) and int(dut.s_rready):
                got.append((int(dut.s_rid), int(dut.s_rlast)))
    cocotb.start_soon(r_collector())

    def setup_ar(addr):
        dut.s_araddr.value = addr; dut.s_arid.value = 0; dut.s_arlen.value = ARLEN
        dut.s_arsize.value = ARSIZE; dut.s_arburst.value = 1
    lasts = lambda: sum(1 for _, l in got if l)

    # back-to-back same-id burst (hold s_arvalid, advance on handshake)
    setup_ar(addrs[0]); dut.s_arvalid.value = 1
    idx = 0
    for _ in range(60_000):
        await ReadOnly()
        accepted = int(dut.s_arvalid) and int(dut.s_arready)
        await RisingEdge(dut.clk)
        if accepted:
            idx += 1
            if idx >= BURST_N:
                dut.s_arvalid.value = 0; break
            setup_ar(addrs[idx])
    for _ in range(60_000):
        await RisingEdge(dut.clk)
        if lasts() >= BURST_N:
            break
    assert lasts() >= BURST_N, f"burst delivered only {lasts()}/{BURST_N}"
    dut._log.info(f"[l2top burst+idle] burst {lasts()}/{BURST_N}, BURST_N={BURST_N} IDLE={IDLE}")

    dut.s_arvalid.value = 0
    for _ in range(IDLE):
        await RisingEdge(dut.clk)

    n_last = lasts()
    setup_ar(addrs[0]); dut.s_arvalid.value = 1
    await ReadOnly()
    ar_ok = False
    for _ in range(3000):
        if int(dut.s_arready):
            ar_ok = True; break
        await RisingEdge(dut.clk); await ReadOnly()
    assert ar_ok, "post-idle AR never accepted at s_arready"
    await RisingEdge(dut.clk); dut.s_arvalid.value = 0
    live = False
    for _ in range(8000):
        await RisingEdge(dut.clk); await ReadOnly()
        if lasts() > n_last:
            live = True; break
    assert live, (
        f"CACHE WEDGE: post-idle same-id read accepted but NEVER responded "
        f"(BURST_N={BURST_N}, IDLE={IDLE}) on l2_top")
    dut._log.info("[l2top burst+idle] post-idle read serviced -- l2_top stayed live")
