"""Smoke test: single 8-beat read miss → fill → check golden bytes.

Mirrors smoke_tb.sv. Validates the cocotb harness end-to-end:
  - clock/reset works
  - AxiMaster issues AR
  - cache fills from AxiRam
  - R beats return correct golden data
"""
from __future__ import annotations
import cocotb
from cocotb.triggers import Timer
from tb_common import reset_dut, attach_master, attach_mem, golden

LINE_W   = 8
BLOCK_BYTES = 4
LINE_BYTES  = LINE_W * BLOCK_BYTES  # 32 bytes

BASE = 0x80000000


@cocotb.test()
async def test_smoke_single_line_read(dut):
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    addr = BASE | 0x00001000  # line-aligned somewhere in seeded region
    burst_bytes = LINE_BYTES

    # cocotbext-axi: init_read returns AxiReadResp; await it to get data
    op = await master.read(addr, burst_bytes)
    got = op.data
    # Expected: 8 blocks of golden(addr+i*4)
    exp = b"".join(
        golden(addr + i * BLOCK_BYTES).to_bytes(BLOCK_BYTES, "little")
        for i in range(LINE_W)
    )
    assert got == exp, (
        f"data mismatch at addr 0x{addr:08x}\n"
        f"  got={got.hex()}\n  exp={exp.hex()}"
    )
    await Timer(100, "ns")
