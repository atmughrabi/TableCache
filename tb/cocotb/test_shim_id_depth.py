"""Generic ID-width / outstanding-depth stress for shim + cache.

Exercises every usable engine ID (all except the reserved all-ones prefill ID),
same-ID recycling, response backpressure, and reorder-slot allocation.
"""
from __future__ import annotations

import logging
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Event, ReadOnly, RisingEdge
from cocotbext.axi import AxiBus, AxiMaster, AxiRam

from test_backpressure import burst_pause

CLK_NS = 10
BASE = 0x8000_0000
ID_W = int(os.environ.get("TC_ID_W", "4"))
DEPTH = int(os.environ.get("TC_READ_REORDER_DEPTH", "1"))
NARROW_W = int(os.environ.get("TC_NARROW_W", "32"))
BLOCK_W = int(os.environ.get("TC_BLOCK_W", "32"))
LINE_W = int(os.environ.get("TC_LINE_W", "8"))
LINES = int(os.environ.get("TC_LINES", "64"))
NARROW_B = NARROW_W // 8
BLOCK_B = BLOCK_W // 8
LINE_B = LINE_W * BLOCK_B
NUM_IDS = 1 << ID_W
RESERVED_ID = NUM_IDS - 1
USABLE_IDS = list(range(RESERVED_ID))
MASK = (1 << NARROW_W) - 1
MEM_SIZE = 1 << 22

logging.getLogger("cocotbext.axi").setLevel(logging.WARNING)


def golden(addr):
    a = addr & 0xFFFF_FFFF
    return ((a * 0x9E37_79B1) ^ (a >> 16) ^ 0xC0FF_EE00) & MASK


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    dut.rst.value = 1
    for _ in range(max(64, LINES * 2)):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


def attach(dut):
    master = AxiMaster(AxiBus.from_prefix(dut, "s"), dut.clk, dut.rst,
                       reset_active_level=True)
    ram = AxiRam(AxiBus.from_prefix(dut, "m"), dut.clk, dut.rst,
                 size=MEM_SIZE, reset_active_level=True)
    seed = bytearray(1 << 18)
    for offset in range(0, len(seed), NARROW_B):
        seed[offset:offset + NARROW_B] = golden(BASE + offset).to_bytes(
            NARROW_B, "little")
    ram.write(0, seed)
    return master, ram


@cocotb.test()
async def test_all_usable_ids_and_recycle(dut):
    await reset_dut(dut)
    assert len(dut.s_arid) == ID_W and len(dut.s_awid) == ID_W
    master, _ram = attach(dut)
    pc_before = int(dut.pc_violations_total.value)

    master.read_if.r_channel.set_pause_generator(
        burst_pause(random.Random(0x1D5), pause_max=5, run_max=3))
    master.write_if.b_channel.set_pause_generator(
        burst_pause(random.Random(0xB1D), pause_max=5, run_max=3))

    core_read_ids = []

    async def monitor_core_ids():
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.c_arvalid) and int(dut.c_arready):
                core_read_ids.append(int(dut.c_arid))

    core_monitor = cocotb.start_soon(monitor_core_ids())

    # One cold read on every non-reserved engine ID.
    read_events = []
    read_addrs = []
    for index, engine_id in enumerate(USABLE_IDS):
        addr = BASE + (index + 1) * LINE_B + (index % max(1, BLOCK_B // NARROW_B)) * NARROW_B
        event = Event()
        master.init_read(addr, NARROW_B, arid=engine_id, event=event)
        read_events.append(event)
        read_addrs.append(addr)

    for engine_id, addr, event in zip(USABLE_IDS, read_addrs, read_events):
        await event.wait()
        got = int.from_bytes(event.data.data, "little")
        assert got == golden(addr), (
            f"read id={engine_id} @{addr:#x}: got={got:#x} exp={golden(addr):#x}")
    core_monitor.kill()

    assert core_read_ids, "no shim->cache AR handshakes observed"
    assert all(core_id != RESERVED_ID for core_id in core_read_ids), (
        f"reserved core ID {RESERVED_ID} was allocated: {core_read_ids}")
    if DEPTH > 1:
        assert all(core_id < DEPTH for core_id in core_read_ids), (
            f"ROB allocated core ID outside 0..{DEPTH-1}: {core_read_ids}")

    # One full-word write on every usable write ID, then read each value back.
    write_events = []
    write_addrs = []
    write_values = []
    for index, engine_id in enumerate(USABLE_IDS):
        addr = BASE + (NUM_IDS + index + 4) * LINE_B
        value = (0xA500_0000 | (ID_W << 12) | engine_id) & MASK
        event = Event()
        master.init_write(
            addr, value.to_bytes(NARROW_B, "little"),
            awid=engine_id, event=event)
        write_events.append(event)
        write_addrs.append(addr)
        write_values.append(value)
    for event in write_events:
        await event.wait()
    for addr, expected in zip(write_addrs, write_values):
        data = await master.read(addr, NARROW_B, arid=0)
        assert int.from_bytes(data.data, "little") == expected

    # Recycle one ID repeatedly; the final value must win with no deadlock.
    recycle_addr = BASE + (2 * NUM_IDS + 8) * LINE_B
    final_value = 0
    for iteration in range(8):
        final_value = (0x5A00_0000 | iteration) & MASK
        await master.write(
            recycle_addr, final_value.to_bytes(NARROW_B, "little"), awid=0)
    recycled = await master.read(recycle_addr, NARROW_B, arid=0)
    assert int.from_bytes(recycled.data, "little") == final_value

    for _ in range(20):
        await RisingEdge(dut.clk)
    pc_after = int(dut.pc_violations_total.value)
    assert pc_after == pc_before, (
        f"ID/depth stress caused AXI violations: before={pc_before} after={pc_after}")
    dut._log.info(
        f"[id-depth] ID_W={ID_W} ROB={DEPTH}: {len(USABLE_IDS)} usable IDs "
        "read/write/recycle correct; reserved ID untouched")
