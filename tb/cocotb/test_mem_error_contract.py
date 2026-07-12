"""Negative controls for the error-free memory-backend contract."""
from __future__ import annotations

import cocotb
from cocotb.triggers import ReadOnly, RisingEdge, with_timeout
from cocotbext.axi import AxiBus, AxiMaster

from tb_common import BASE, reset_dut

BLOCK_BYTES = 4
LINE_W = 2
LINES = 2
WB_ALLOC = 0xF
SLVERR = 0b10


async def wait_handshake(dut, valid_name, ready_name, limit=2000):
    for _ in range(limit):
        await ReadOnly()
        if int(getattr(dut, valid_name)) and int(getattr(dut, ready_name)):
            return
        await RisingEdge(dut.clk)
    raise AssertionError(f"timeout waiting for {valid_name}/{ready_name}")


async def drive_read_response(dut, resp):
    await wait_handshake(dut, "m_arvalid", "m_arready")
    rid = int(dut.m_arid)
    beats = int(dut.m_arlen) + 1
    await RisingEdge(dut.clk)
    for beat in range(beats):
        dut.m_rid.value = rid
        dut.m_rdata.value = 0x1000 + beat
        dut.m_rresp.value = resp
        dut.m_rlast.value = int(beat == beats - 1)
        dut.m_rvalid.value = 1
        await wait_handshake(dut, "m_rvalid", "m_rready")
        await RisingEdge(dut.clk)
        dut.m_rvalid.value = 0
        dut.m_rlast.value = 0


async def drive_write_error(dut):
    await wait_handshake(dut, "m_awvalid", "m_awready")
    bid = int(dut.m_awid)
    beats = int(dut.m_awlen) + 1
    seen = 0
    while seen < beats:
        await ReadOnly()
        if int(dut.m_wvalid) and int(dut.m_wready):
            seen += 1
        await RisingEdge(dut.clk)
    dut.m_bid.value = bid
    dut.m_bresp.value = SLVERR
    dut.m_bvalid.value = 1
    await wait_handshake(dut, "m_bvalid", "m_bready")
    await RisingEdge(dut.clk)
    dut.m_bvalid.value = 0


async def setup(dut):
    await reset_dut(dut)
    dut.m_arready.value = 1
    dut.m_awready.value = 1
    dut.m_wready.value = 1
    dut.m_rvalid.value = 0
    dut.m_bvalid.value = 0
    return AxiMaster(AxiBus.from_prefix(dut, "s"), dut.clk, dut.rst,
                     reset_active_level=True)


@cocotb.test()
async def test_read_slverr_is_rejected(dut):
    master = await setup(dut)
    response = cocotb.start_soon(drive_read_response(dut, SLVERR))
    read = cocotb.start_soon(
        master.read(BASE, BLOCK_BYTES, arid=0, cache=WB_ALLOC))
    await with_timeout(response, 50_000, "ns")
    await with_timeout(read, 50_000, "ns")
    raise AssertionError("non-OKAY RRESP was not rejected")


@cocotb.test()
async def test_writeback_slverr_is_rejected(dut):
    master = await setup(dut)
    line_bytes = LINE_W * BLOCK_BYTES
    set_stride = LINES * line_bytes

    fill_a = cocotb.start_soon(drive_read_response(dut, 0))
    await master.write(BASE, (0xA5A5_A5A5).to_bytes(4, "little"),
                       awid=0, cache=WB_ALLOC)
    await fill_a

    fill_b = cocotb.start_soon(drive_read_response(dut, 0))
    writeback = cocotb.start_soon(drive_write_error(dut))
    await master.write(BASE + set_stride, (0x5A5A_5A5A).to_bytes(4, "little"),
                       awid=1, cache=WB_ALLOC)
    await with_timeout(fill_b, 50_000, "ns")
    await with_timeout(writeback, 50_000, "ns")
    raise AssertionError("non-OKAY BRESP was not rejected")
