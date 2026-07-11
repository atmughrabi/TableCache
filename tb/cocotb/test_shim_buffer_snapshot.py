"""Line-buffer pending-response snapshot regression.

A buffer hit can wait behind an unrelated cache response. The selected word
must be captured when the buffer-hit AR is accepted; slicing live line-buffer
data later returns the unrelated refill if the buffer changes while pending.
"""
from __future__ import annotations

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

CLK_NS = 10
NARROW_W = int(os.environ.get("TC_NARROW_W", "32"))
BLOCK_W = int(os.environ.get("TC_BLOCK_W", "512"))
NARROW_B = NARROW_W // 8
RATIO = BLOCK_W // NARROW_W
MASK = (1 << NARROW_W) - 1


def wide_word(seed):
    value = 0
    for lane in range(RATIO):
        value |= ((seed + lane) & MASK) << (lane * NARROW_W)
    return value


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    dut.rst.value = 1
    dut.s_arvalid.value = 0
    dut.s_awvalid.value = 0
    dut.s_wvalid.value = 0
    dut.s_rready.value = 1
    dut.s_bready.value = 1
    dut.m_arready.value = 1
    dut.m_awready.value = 0
    dut.m_wready.value = 0
    dut.m_rvalid.value = 0
    dut.m_bvalid.value = 0
    for _ in range(16):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def issue_ar(dut, addr, arid):
    dut.s_araddr.value = addr
    dut.s_arid.value = arid
    dut.s_arlen.value = 0
    dut.s_arsize.value = NARROW_B.bit_length() - 1
    dut.s_arburst.value = 1
    dut.s_arcache.value = 0xF
    dut.s_arvalid.value = 1
    for _ in range(100):
        await ReadOnly()
        accepted = int(dut.s_arready)
        await RisingEdge(dut.clk)
        if accepted:
            dut.s_arvalid.value = 0
            return
    raise AssertionError(f"AR id={arid} addr={addr:#x} was not accepted")


async def return_mem_read(dut, rid, data):
    dut.m_rid.value = rid
    dut.m_rdata.value = data
    dut.m_rresp.value = 0
    dut.m_rlast.value = 1
    dut.m_rvalid.value = 1
    for _ in range(100):
        await ReadOnly()
        accepted = int(dut.m_rready)
        await RisingEdge(dut.clk)
        if accepted:
            dut.m_rvalid.value = 0
            dut.m_rlast.value = 0
            return
    raise AssertionError(f"memory R id={rid} was not accepted")


@cocotb.test()
async def test_buffer_hit_word_is_snapshotted(dut):
    await reset_dut(dut)
    responses = []

    async def collect_responses():
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.s_rvalid) and int(dut.s_rready):
                responses.append((int(dut.s_rid), int(dut.s_rdata) & MASK))

    cocotb.start_soon(collect_responses())

    lane = min(5, RATIO - 1)
    line_b = 0x8000_0100
    line_a = 0x8000_0200
    addr_b = line_b + lane * NARROW_B
    data_b = wide_word(0xB000_1000)
    data_a = wide_word(0xA000_2000)

    # Warm B so it resides in the shim line buffer.
    await issue_ar(dut, addr_b, 1)
    await return_mem_read(dut, 1, data_b)
    for _ in range(20):
        await RisingEdge(dut.clk)
        if responses:
            break
    assert responses[-1] == (1, (0xB000_1000 + lane) & MASK)
    responses.clear()

    # Leave A outstanding, then accept a buffer-hit read of B.
    await issue_ar(dut, line_a, 0)
    await issue_ar(dut, addr_b, 2)
    assert not int(dut.m_arvalid), "buffer hit unexpectedly issued a memory AR"

    # A's response wins the output mux and refills the live line buffer before
    # the pending B response drains.
    await return_mem_read(dut, 0, data_a)
    for _ in range(50):
        await RisingEdge(dut.clk)
        if len(responses) >= 2:
            break

    assert responses[0] == (0, 0xA000_2000 & MASK)
    assert responses[1] == (2, (0xB000_1000 + lane) & MASK), (
        f"buffered B response changed after A refill: responses={responses}")
    assert int(dut.pc_violations_total.value) == 0
