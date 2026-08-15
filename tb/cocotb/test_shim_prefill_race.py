"""Backpressure and prefill arbitration tests for tc_narrow_shim."""

from __future__ import annotations

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotbext.axi import AxiBus, AxiRam


CLK_NS = 10
BASE = 0x8000_0000
NARROW_W = int(os.environ.get("TC_NARROW_W", "32"))
BLOCK_W = int(os.environ.get("TC_BLOCK_W", "512"))
ID_W = int(os.environ.get("TC_ID_W", "4"))
NARROW_B = NARROW_W // 8
BLOCK_B = BLOCK_W // 8
RATIO = BLOCK_W // NARROW_W
WORD_MASK = (1 << NARROW_W) - 1
PREFILL_ID = (1 << ID_W) - 1
PROMOTE = os.environ.get("TC_PROMOTE_WMISS", "0") == "1"
USABLE_IDS = [
    rid for rid in range(1 << ID_W)
    if not (PROMOTE and rid == PREFILL_ID)
]
USER_A = USABLE_IDS[0]
USER_B = USABLE_IDS[1] if len(USABLE_IDS) > 1 else None


def pause_for(cycles):
    for _ in range(cycles):
        yield 1
    while True:
        yield 0


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    dut.rst.value = 1
    for sig, value in [
        ("s_arvalid", 0), ("s_awvalid", 0), ("s_wvalid", 0),
        ("s_rready", 1), ("s_bready", 1),
        ("s_arlen", 0), ("s_arsize", NARROW_B.bit_length() - 1),
        ("s_arburst", 1), ("s_arlock", 0), ("s_arcache", 0xF),
        ("s_arprot", 0), ("s_arqos", 0), ("s_arregion", 0),
        ("s_arsnoop", 0), ("s_arid", 0),
        ("s_awlen", 0), ("s_awsize", NARROW_B.bit_length() - 1),
        ("s_awburst", 1), ("s_awlock", 0), ("s_awcache", 0xF),
        ("s_awprot", 0), ("s_awqos", 0), ("s_awregion", 0),
        ("s_awsnoop", 0), ("s_awid", 0),
        ("s_wlast", 1), ("s_wstrb", (1 << NARROW_B) - 1),
    ]:
        if hasattr(dut, sig):
            getattr(dut, sig).value = value
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


def attach_ram(dut):
    ram = AxiRam(
        AxiBus.from_prefix(dut, "m"), dut.clk, dut.rst,
        size=1 << 16, reset_active_level=True,
    )
    seed = bytes((i & 0xFF) for i in range(1 << 16))
    ram.write(0, seed)
    return ram, seed


async def drive_ar(dut, addr, arid, timeout=400):
    dut.s_araddr.value = addr
    dut.s_arid.value = arid
    dut.s_arvalid.value = 1
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.s_arvalid) and int(dut.s_arready):
            await Timer(1, units="ps")
            dut.s_arvalid.value = 0
            return
    raise AssertionError(f"AR id={arid} addr=0x{addr:x} did not handshake")


async def drive_aw(dut, addr, awid, timeout=600):
    dut.s_awaddr.value = addr
    dut.s_awid.value = awid
    dut.s_awvalid.value = 1
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.s_awvalid) and int(dut.s_awready):
            await Timer(1, units="ps")
            dut.s_awvalid.value = 0
            return
    raise AssertionError(f"AW id={awid} addr=0x{addr:x} did not handshake")


async def drive_w(dut, value, timeout=600):
    dut.s_wdata.value = value
    dut.s_wvalid.value = 1
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.s_wvalid) and int(dut.s_wready):
            await Timer(1, units="ps")
            dut.s_wvalid.value = 0
            return
    raise AssertionError("W did not handshake")


async def wait_r(dut, rid, timeout=600):
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.s_rvalid) and int(dut.s_rready) and int(dut.s_rid) == rid:
            return int(dut.s_rdata) & WORD_MASK
    raise AssertionError(f"R id={rid} did not return")


async def wait_b(dut, bid, timeout=600):
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.s_bvalid) and int(dut.s_bready) and int(dut.s_bid) == bid:
            return
    raise AssertionError(f"B id={bid} did not return")


class TrafficMonitor:
    def __init__(self, dut):
        self.dut = dut
        self.cycle = 0
        self.m_ar = []
        self.m_aw = []
        self.m_rlast = []
        self.s_r = []
        self.active_ids = set()

    async def run(self):
        while True:
            await RisingEdge(self.dut.clk)
            self.cycle += 1
            if int(self.dut.m_arvalid) and int(self.dut.m_arready):
                arid = int(self.dut.m_arid)
                assert arid not in self.active_ids, \
                    f"memory AR id {arid} issued while already outstanding"
                self.active_ids.add(arid)
                self.m_ar.append((self.cycle, arid, int(self.dut.m_araddr)))
            if int(self.dut.m_awvalid) and int(self.dut.m_awready):
                self.m_aw.append(
                    (self.cycle, int(self.dut.m_awid), int(self.dut.m_awaddr))
                )
            if int(self.dut.m_rvalid) and int(self.dut.m_rready) and int(self.dut.m_rlast):
                rid = int(self.dut.m_rid)
                assert rid in self.active_ids, \
                    f"memory R id {rid} returned without an outstanding AR"
                self.active_ids.remove(rid)
                self.m_rlast.append((self.cycle, rid))
            if int(self.dut.s_rvalid) and int(self.dut.s_rready):
                self.s_r.append(
                    (self.cycle, int(self.dut.s_rid), int(self.dut.s_rdata))
                )


def check_protocol(dut):
    assert int(dut.pc_violations_total.value) == 0


@cocotb.test(skip=not PROMOTE)
async def test_prefill_blocks_later_user_ar(dut):
    """A user miss presented during an active prefill waits for its RLAST."""
    await reset_dut(dut)
    ram, seed = attach_ram(dut)
    ram.read_if.r_channel.set_pause_generator(pause_for(30))
    monitor = TrafficMonitor(dut)
    cocotb.start_soon(monitor.run())

    line_w = BASE | (8 * BLOCK_B)
    line_r = BASE | (12 * BLOCK_B)
    write_addr = line_w + min(3, RATIO - 1) * NARROW_B
    write_value = 0xC0FF_EE00 & WORD_MASK

    aw_task = cocotb.start_soon(drive_aw(dut, write_addr, 1))
    w_task = cocotb.start_soon(drive_w(dut, write_value))

    for _ in range(100):
        await RisingEdge(dut.clk)
        if any(arid == PREFILL_ID for _, arid, _ in monitor.m_ar):
            break
    else:
        raise AssertionError("prefill AR did not issue")

    ar_task = cocotb.start_soon(drive_ar(dut, line_r, USER_A))
    read_value = await wait_r(dut, USER_A)
    await ar_task
    await aw_task
    await w_task
    await wait_b(dut, 1)
    await Timer(100, units="ns")

    expected = int.from_bytes(
        seed[(line_r & 0xFFFF):(line_r & 0xFFFF) + NARROW_B], "little"
    )
    assert read_value == expected

    prefill_ar_cycle = next(
        cycle for cycle, arid, _ in monitor.m_ar if arid == PREFILL_ID
    )
    prefill_r_cycle = next(
        cycle for cycle, rid in monitor.m_rlast
        if rid == PREFILL_ID and cycle >= prefill_ar_cycle
    )
    leaks = [
        entry for entry in monitor.m_ar
        if entry[1] != PREFILL_ID
        and prefill_ar_cycle <= entry[0] <= prefill_r_cycle
    ]
    assert not leaks, f"user AR issued during prefill: {leaks}"
    write_aw_cycle = next(
        cycle for cycle, _, addr in monitor.m_aw
        if addr == (write_addr & ~(BLOCK_B - 1))
    )
    assert write_aw_cycle > prefill_r_cycle
    assert not monitor.active_ids
    check_protocol(dut)


@cocotb.test(skip=not PROMOTE)
async def test_reserved_id_stall_serializes_prefill(dut):
    """A held user request on PREFILL_ID completes before an internal prefill."""
    await reset_dut(dut)
    ram, seed = attach_ram(dut)
    ram.read_if.ar_channel.set_pause_generator(pause_for(12))
    monitor = TrafficMonitor(dut)
    cocotb.start_soon(monitor.run())

    line_w = BASE | (16 * BLOCK_B)
    line_r = BASE | (20 * BLOCK_B)
    write_addr = line_w + min(2, RATIO - 1) * NARROW_B
    write_value = 0x1234_5600 & WORD_MASK

    aw_task = cocotb.start_soon(drive_aw(dut, write_addr, 1))
    w_task = cocotb.start_soon(drive_w(dut, write_value))
    ar_task = cocotb.start_soon(drive_ar(dut, line_r, PREFILL_ID))

    read_value = await wait_r(dut, PREFILL_ID)
    await ar_task
    await aw_task
    await w_task
    await wait_b(dut, 1)
    await Timer(100, units="ns")

    expected = int.from_bytes(
        seed[(line_r & 0xFFFF):(line_r & 0xFFFF) + NARROW_B], "little"
    )
    assert read_value == expected
    assert [arid for _, arid, _ in monitor.m_ar] == [PREFILL_ID, PREFILL_ID]
    assert sum(1 for _, rid, _ in monitor.s_r if rid == PREFILL_ID) == 1
    assert not monitor.active_ids
    check_protocol(dut)


@cocotb.test(skip=USER_B is None or RATIO < 2)
async def test_held_miss_returns_once_after_buffer_fill(dut):
    """A held miss is not also accepted from a line buffer filled meanwhile."""
    await reset_dut(dut)
    ram, seed = attach_ram(dut)
    ram.read_if.r_channel.set_pause_generator(pause_for(8))
    monitor = TrafficMonitor(dut)
    cocotb.start_soon(monitor.run())

    line = BASE | (24 * BLOCK_B)
    first_addr = line
    second_addr = line + NARROW_B

    first_ar = cocotb.start_soon(drive_ar(dut, first_addr, USER_A))
    await first_ar

    ram.read_if.ar_channel.set_pause_generator(pause_for(20))
    for _ in range(20):
        await RisingEdge(dut.clk)
        if not int(dut.m_arready):
            break
    else:
        raise AssertionError("memory AR channel did not stall")

    second_ar = cocotb.start_soon(drive_ar(dut, second_addr, USER_B))
    first_value = await wait_r(dut, USER_A)
    second_value = await wait_r(dut, USER_B)
    await second_ar
    await Timer(200, units="ns")

    expected_first = int.from_bytes(
        seed[(first_addr & 0xFFFF):(first_addr & 0xFFFF) + NARROW_B], "little"
    )
    expected_second = int.from_bytes(
        seed[(second_addr & 0xFFFF):(second_addr & 0xFFFF) + NARROW_B], "little"
    )
    assert first_value == expected_first
    assert second_value == expected_second
    assert sum(1 for _, rid, _ in monitor.s_r if rid == USER_A) == 1
    assert sum(1 for _, rid, _ in monitor.s_r if rid == USER_B) == 1
    assert len(monitor.m_ar) == 2
    assert not monitor.active_ids
    check_protocol(dut)


@cocotb.test(skip=not PROMOTE)
async def test_buffer_hit_reserved_id_defers_prefill(dut):
    """A reserved-ID buffer hit completes before a cold-write prefill starts."""
    await reset_dut(dut)
    _ram, seed = attach_ram(dut)
    monitor = TrafficMonitor(dut)
    cocotb.start_soon(monitor.run())

    hot_line = BASE | (28 * BLOCK_B)
    cold_line = BASE | (32 * BLOCK_B)
    warm_ar = cocotb.start_soon(drive_ar(dut, hot_line, USER_A))
    warm_value = await wait_r(dut, USER_A)
    await warm_ar

    write_addr = cold_line + min(2, RATIO - 1) * NARROW_B
    write_value = 0xABCD_1200 & WORD_MASK
    hit_ar = cocotb.start_soon(drive_ar(dut, hot_line, PREFILL_ID))
    aw_task = cocotb.start_soon(drive_aw(dut, write_addr, 1))
    w_task = cocotb.start_soon(drive_w(dut, write_value))

    hit_value = await wait_r(dut, PREFILL_ID)
    await hit_ar
    await aw_task
    await w_task
    await wait_b(dut, 1)
    await Timer(100, units="ns")

    expected = int.from_bytes(
        seed[(hot_line & 0xFFFF):(hot_line & 0xFFFF) + NARROW_B], "little"
    )
    assert warm_value == expected
    assert hit_value == expected
    assert sum(1 for _, rid, _ in monitor.s_r if rid == PREFILL_ID) == 1
    assert sum(1 for _, arid, _ in monitor.m_ar if arid == PREFILL_ID) == 1
    assert not monitor.active_ids
    check_protocol(dut)


@cocotb.test(skip=not PROMOTE)
async def test_stalled_aw_survives_unrelated_refill(dut):
    """A stalled AW remains valid when another read replaces the line buffer."""
    await reset_dut(dut)
    ram, seed = attach_ram(dut)
    ram.write_if.aw_channel.set_pause_generator(pause_for(20))
    monitor = TrafficMonitor(dut)
    cocotb.start_soon(monitor.run())

    line_y = BASE | (36 * BLOCK_B)
    line_x = BASE | (40 * BLOCK_B)
    write_addr = line_y + min(1, RATIO - 1) * NARROW_B
    write_value = 0x7654_3200 & WORD_MASK

    warm_ar = cocotb.start_soon(drive_ar(dut, line_y, USER_A))
    await wait_r(dut, USER_A)
    await warm_ar

    aw_task = cocotb.start_soon(drive_aw(dut, write_addr, 1))
    w_task = cocotb.start_soon(drive_w(dut, write_value))
    for _ in range(50):
        await RisingEdge(dut.clk)
        if int(dut.m_awvalid) and not int(dut.m_awready):
            break
    else:
        raise AssertionError("memory AW did not stall")

    refill_ar = cocotb.start_soon(drive_ar(dut, line_x, USER_A))
    refill_value = await wait_r(dut, USER_A)
    await refill_ar
    await aw_task
    await w_task
    await wait_b(dut, 1)
    await Timer(100, units="ns")

    expected = int.from_bytes(
        seed[(line_x & 0xFFFF):(line_x & 0xFFFF) + NARROW_B], "little"
    )
    assert refill_value == expected
    assert len(monitor.m_aw) == 1
    assert monitor.m_aw[0][2] == (write_addr & ~(BLOCK_B - 1))
    assert not monitor.active_ids
    check_protocol(dut)
