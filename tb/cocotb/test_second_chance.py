"""Directed Second Chance replacement-policy test."""

from __future__ import annotations

import os

import cocotb
from cocotb.triggers import RisingEdge, Timer

from tb_common import attach_master, attach_mem, reset_dut

BASE = 0x8000_0000
BLOCK_BYTES = 4
LINE_W = int(os.environ.get("TC_LINE_W", "8"))
LINE_BYTES = LINE_W * BLOCK_BYTES
LINES = int(os.environ.get("TC_LINES", "64"))
WAYS = int(os.environ.get("TC_WAYS", "4"))


class MemReadCounter:
    def __init__(self, dut):
        self.dut = dut
        self.count = 0

    async def run(self):
        while True:
            await RisingEdge(self.dut.clk)
            if int(self.dut.m_arvalid.value) and int(self.dut.m_arready.value):
                self.count += 1


async def _fill_resident_set(master):
    set_stride = LINES * LINE_BYTES
    resident = [BASE | (index * set_stride) for index in range(WAYS)]
    for addr in resident:
        await master.read(addr, BLOCK_BYTES)
    return resident, set_stride


def _require_policy():
    assert os.environ.get("TC_POLICY_NAME") == "SECOND_CHANCE", (
        "test_second_chance requires POLICY=SECOND_CHANCE"
    )
    assert not int(os.environ.get("TC_VICTIM") or "0"), (
        "test_second_chance requires VICTIM=0"
    )
    assert WAYS >= 2


@cocotb.test()
async def test_fills_all_ways(dut):
    _require_policy()

    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 27)
    master = attach_master(dut)
    counter = MemReadCounter(dut)
    cocotb.start_soon(counter.run())

    resident, _ = await _fill_resident_set(master)
    await Timer(50, "ns")
    assert counter.count == WAYS

    for addr in resident:
        await master.read(addr, BLOCK_BYTES)
    await Timer(50, "ns")
    assert counter.count == WAYS, (
        "clock hand did not advance while filling an associative set"
    )


@cocotb.test()
async def test_recent_hit_gets_second_chance(dut):
    _require_policy()

    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 27)
    master = attach_master(dut)
    counter = MemReadCounter(dut)
    cocotb.start_soon(counter.run())

    resident, set_stride = await _fill_resident_set(master)
    newcomer = BASE | (WAYS * set_stride)

    await Timer(100, "ns")
    assert counter.count == WAYS, (
        f"Second Chance did not fill all {WAYS} ways: memory reads={counter.count}"
    )

    await master.read(resident[0], BLOCK_BYTES)
    await Timer(50, "ns")
    assert counter.count == WAYS, "resident hit unexpectedly missed"

    await master.read(newcomer, BLOCK_BYTES)
    await Timer(50, "ns")
    assert counter.count == WAYS + 1, "new line did not miss"

    await master.read(resident[0], BLOCK_BYTES)
    await Timer(50, "ns")
    assert counter.count == WAYS + 1, (
        "recently hit line was evicted instead of receiving a second chance"
    )


@cocotb.test()
async def test_second_chance_expires(dut):
    _require_policy()

    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 27)
    master = attach_master(dut)
    counter = MemReadCounter(dut)
    cocotb.start_soon(counter.run())

    resident, set_stride = await _fill_resident_set(master)
    await master.read(resident[0], BLOCK_BYTES)

    for index in range(WAYS, 2 * WAYS):
        await master.read(BASE | (index * set_stride), BLOCK_BYTES)
    await Timer(50, "ns")
    before_probe = counter.count

    await master.read(resident[0], BLOCK_BYTES)
    await Timer(50, "ns")
    assert counter.count == before_probe + 1, (
        "referenced line remained protected after a full clock revolution"
    )
