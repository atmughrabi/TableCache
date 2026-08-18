"""Smoke test: single 8-beat read miss → fill → check golden bytes.

Mirrors smoke_tb.sv. Validates the cocotb harness end-to-end:
  - clock/reset works
  - AxiMaster issues AR
  - cache fills from AxiRam
  - R beats return correct golden data
"""
from __future__ import annotations
import os
import cocotb
from cocotb.triggers import Timer, RisingEdge, ReadOnly, with_timeout
from tb_common import (
    reset_dut,
    attach_master,
    attach_mem,
    golden,
    BASE,
    ADDR_W,
    RANGE_H,
)

LINE_W   = 8
BLOCK_BYTES = 4
LINE_BYTES  = LINE_W * BLOCK_BYTES  # 32 bytes

@cocotb.test()
async def test_smoke_single_line_read(dut):
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    # For a base-0 full 64-bit range, deliberately set a variable upper
    # address bit. This distinguishes real 64-bit tag/reconstruction support
    # from a design that merely preserves a fixed high range prefix.
    addr = BASE | 0x00001000
    if BASE == 0 and ADDR_W > 32:
        addr |= 1 << (ADDR_W - 1)
    burst_bytes = LINE_BYTES

    reconstructed = []

    async def capture_mem_ar():
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.m_arvalid) and int(dut.m_arready):
                reconstructed.append(int(dut.dbg_m_araddr_full))
                return

    capture_task = cocotb.start_soon(capture_mem_ar())

    # cocotbext-axi: init_read returns AxiReadResp; await it to get data
    op = await master.read(addr, burst_bytes)
    await capture_task
    got = op.data
    assert reconstructed == [addr], (
        f"mem AR reconstruction lost address bits: "
        f"got 0x{reconstructed[0]:x}, expected 0x{addr:x}")
    # Expected: 8 blocks of golden(addr+i*4)
    exp = b"".join(
        golden(addr + i * BLOCK_BYTES).to_bytes(BLOCK_BYTES, "little")
        for i in range(LINE_W)
    )
    assert got == exp, (
        f"data mismatch at addr 0x{addr:x}\n"
        f"  got={got.hex()}\n  exp={exp.hex()}"
    )
    await Timer(100, "ns")


@cocotb.test()
async def test_same_low32_different_high_bits_do_not_alias(dut):
    """Two resident lines with identical low 32 bits retain distinct data."""
    ways = int(os.environ.get("TC_WAYS", "4"))
    high_addr = (1 << 32) | 0x0000_4000
    if ADDR_W <= 32 or BASE != 0 or RANGE_H < high_addr or ways < 2:
        assert os.environ.get("TC_REQUIRE_HIGH_ALIAS") != "1", (
            "required high-bit alias coverage is not active: "
            f"ADDR_W={ADDR_W} BASE=0x{BASE:x} RANGE_H=0x{RANGE_H:x} "
            f"WAYS={ways}")
        dut._log.info(
            "high-bit alias test requires a base-0 range wider than 32 bits "
            "and at least two ways")
        return

    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    low_addr = 0x0000_4000
    low_data = 0x1357_9BDF
    high_data = 0x2468_ACE0
    await with_timeout(
        master.write(low_addr, low_data.to_bytes(4, "little")),
        20_000,
        "ns",
    )
    await with_timeout(
        master.write(high_addr, high_data.to_bytes(4, "little")),
        20_000,
        "ns",
    )

    low_read = await with_timeout(master.read(low_addr, 4), 20_000, "ns")
    high_read = await with_timeout(master.read(high_addr, 4), 20_000, "ns")
    assert int.from_bytes(low_read.data, "little") == low_data
    assert int.from_bytes(high_read.data, "little") == high_data
