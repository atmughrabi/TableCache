"""Shared cocotb fixtures: clock/reset, AxiMaster on s_*, AxiRam on m_*.

The DUT is the flat wrapper `dut_cocotb` in tb/cocotb/dut_cocotb.sv.
Memory backing: cocotbext-axi AxiRam, seeded with the same golden pattern
as the SV testbench (`golden(addr) = {addr[15:0], 16'hCAFE}`) so directed
tests cross-check.
"""
from __future__ import annotations

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ReadOnly
from cocotbext.axi import AxiBus, AxiMaster, AxiRam

CLK_PERIOD_NS = 10


def golden(addr: int) -> int:
    return ((addr & 0xFFFF) << 16) | 0xCAFE


async def reset_dut(dut, cycles: int = None):
    # NOTE: sdp_ram_rst uses an LFSR-driven reset that needs >= 2^ADDR_WIDTH
    # cycles to initialize every entry. The largest storage is the tag bank
    # (sized by LINES). If cycles=None we auto-size: 2 * LINES (some safety
    # margin) read from env TC_LINES, capped at 4096. Manually pass cycles=N
    # to override for shim-only builds where the cache isn't in the loop
    # (those need only a handful of cycles).
    if cycles is None:
        lines = int(os.environ.get("TC_LINES", "64"))
        cycles = min(4096, max(64, lines * 2))
    dut.rst.value = 1
    # Hold all slave inputs at safe defaults during reset
    for sig, val in [
        ("s_arvalid", 0), ("s_awvalid", 0), ("s_wvalid", 0),
        ("s_rready", 1), ("s_bready", 1),
        ("s_arsnoop", 0), ("s_awsnoop", 0),
        # GRASP region ports default to 0 (regions disabled; SRRIP-FP fallback).
        ("grasp_high_addr_l", 0), ("grasp_high_addr_h", 0),
        ("grasp_moderate_addr_l", 0), ("grasp_moderate_addr_h", 0),
    ]:
        if hasattr(dut, sig):
            getattr(dut, sig).value = val
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


def attach_master(dut):
    """Cocotb AXI master driving the cache's slave (request) port."""
    bus = AxiBus.from_prefix(dut, "s")
    return AxiMaster(bus, dut.clk, dut.rst, reset_active_level=True)


def attach_mem(dut, size_bytes: int = 1 << 20, seed_window_bytes: int = None):
    """Cocotb AXI RAM responding to the cache's memory port.

    Pre-populated with the golden pattern so initial reads hit the same
    values the legacy SV mem model returned.

    size_bytes:        total RAM size (must be >= max(addr) the test touches
                       after MEM_MASK, default 1 MiB for legacy tests).
    seed_window_bytes: how many bytes to seed with golden(); defaults to
                       `size_bytes`. Use a smaller value if you only need to
                       seed a hot region (saves Python init time).
    """
    bus = AxiBus.from_prefix(dut, "m")
    ram = AxiRam(bus, dut.clk, dut.rst, size=size_bytes, reset_active_level=True)
    if seed_window_bytes is None:
        seed_window_bytes = size_bytes
    # Seed at the 4-byte golden-word granularity, independent of bus width.
    # `golden()` returns a 32-bit value; reading TC_BLOCK_W here and zero-
    # extending to wider strides would clobber bytes 4..BLOCK_BYTES-1 of
    # every block (was a real seeding bug when TC_BLOCK_W>32). The cache's
    # bus width only affects how many golden words pack into one beat; the
    # underlying RAM contents are always 4-byte-stride golden().
    GOLDEN_BYTES = 4
    seed = bytearray(seed_window_bytes)
    for addr in range(0, seed_window_bytes, GOLDEN_BYTES):
        seed[addr:addr + GOLDEN_BYTES] = golden(0x80000000 | addr).to_bytes(
            GOLDEN_BYTES, "little")
    ram.write(0, bytes(seed))
    return ram


# ---------------------------------------------------------------------------
# Backend-writeback monitor (enrichment)
#
# Snoops the memory-side write channel (m_aw* + m_w*) and, for every completed
# write burst, asserts it covers EXACTLY ONE cache line. This is the direct
# net for the FIX-A class ("the 8-beat writeback spans two lines"): a full-line
# writeback must be either an INCR from the line base (awlen = LINE_W-1) or a
# WRAP whose wrap boundary equals the line size -- either way every beat lands
# in the same line. Any burst whose beats touch two distinct line bases fails.
#
# It also records, per completed burst, the {byte_addr: word} actually written
# (honouring INCR/WRAP addressing and wstrb) so a test can cross-check the
# backend contents against its reference model.
# ---------------------------------------------------------------------------
class WritebackMonitor:
    def __init__(self, dut, line_w: int = None, block_bytes: int = 4,
                 mem_mask: int = 0xFFFFFFFF):
        self.dut = dut
        self.line_w = line_w if line_w is not None else int(os.environ.get("TC_LINE_W", "8"))
        self.block_bytes = block_bytes
        self.line_bytes = self.line_w * block_bytes
        self.mem_mask = mem_mask
        self.bursts = 0
        self.beats = 0
        self.errors: list[str] = []
        self.written: dict[int, int] = {}   # byte-addr -> word (last write wins)

    async def run(self):
        aw_q: list[tuple[int, int, int, int]] = []  # (addr, len, size, burst)
        cur = None       # (base_addr, size, burst, boundary, beat_idx, [line_bases])
        while True:
            await RisingEdge(self.dut.clk)
            await ReadOnly()
            if int(self.dut.m_awvalid) and int(self.dut.m_awready):
                aw_q.append((int(self.dut.m_awaddr) & self.mem_mask,
                             int(self.dut.m_awlen), int(self.dut.m_awsize),
                             int(self.dut.m_awburst)))
            if int(self.dut.m_wvalid) and int(self.dut.m_wready):
                if cur is None:
                    if not aw_q:
                        # W before AW: tolerate, resync on next AW.
                        continue
                    addr, alen, asize, aburst = aw_q.pop(0)
                    size = 1 << asize
                    boundary = (alen + 1) * size
                    cur = [addr, size, aburst, boundary, 0, set(), alen]
                base, size, aburst, boundary, j, lines, alen = cur
                if aburst == 2:  # WRAP
                    lower = base - (base % boundary)
                    beat_addr = lower + ((base - lower + j * size) % boundary)
                else:            # INCR (1) / FIXED (0, unused here)
                    beat_addr = base + j * size
                lines.add(beat_addr - (beat_addr % self.line_bytes))
                data = int(self.dut.m_wdata) & 0xFFFFFFFF
                strb = int(self.dut.m_wstrb)
                if strb & 0xF:
                    self.written[beat_addr] = data
                self.beats += 1
                cur[4] = j + 1
                if int(self.dut.m_wlast):
                    self.bursts += 1
                    if len(lines) != 1:
                        self.errors.append(
                            f"writeback burst @0x{base:08x} burst={aburst} "
                            f"len={alen} spans {len(lines)} lines: "
                            f"{sorted(hex(x) for x in lines)}")
                    cur = None

    def check(self):
        assert not self.errors, "WritebackMonitor: " + " | ".join(self.errors)
