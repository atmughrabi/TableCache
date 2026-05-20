"""FPGA-deployment-realism scenarios.

Two classes:
  * ddr_first_beat_latency_{20,40,80} -- sustained mem-R inter-beat delay
    via pause generator on `r_channel`. Stresses outstanding-AR tracking.
  * long_idle_then_reset_recover     -- warm-up, idle for 2*LINES*4 cycles,
    reset, fresh transaction. Models FPGA partial-reconfiguration.

All gate on `pc_violations_total == 0`.
"""
from __future__ import annotations

import os
import random
import cocotb
from cocotb.triggers import RisingEdge, with_timeout
from tb_common import reset_dut, attach_master, attach_mem, golden

BASE        = 0x80000000
BLOCK_BYTES = 4
LINE_W      = int(os.environ.get("TC_LINE_W", "8"))
LINE_BYTES  = LINE_W * BLOCK_BYTES
LINES       = int(os.environ.get("TC_LINES", "64"))


def assert_pc_clean(dut, ctx: str):
    pc = int(dut.pc_violations_total.value)
    assert pc == 0, f"AXI_PC violations during {ctx}: {pc}"


def fixed_latency_pause(latency: int):
    """Yield `latency` ones then one zero, repeating. Applied to an
    AxiRSource this stalls every R beat by `latency` cycles."""
    while True:
        for _ in range(latency):
            yield 1
        yield 0


@cocotb.test()
async def test_ddr_first_beat_latency_20(dut):
    await _ddr_body(dut, latency=20)


@cocotb.test()
async def test_ddr_first_beat_latency_40(dut):
    await _ddr_body(dut, latency=40)


@cocotb.test()
async def test_ddr_first_beat_latency_80(dut):
    await _ddr_body(dut, latency=80)


async def _ddr_body(dut, latency: int):
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)
    ram.read_if.r_channel.set_pause_generator(fixed_latency_pause(latency))

    rng = random.Random(0xDDDD0000 | latency)
    POOL = 32
    written: dict[int, int] = {}
    per_op_ns = max(30_000, LINE_W * (latency + 1) * 10 * 4)

    for _ in range(30):
        line_a = BASE | (rng.randrange(POOL) * LINE_BYTES)
        word_off = rng.randrange(LINE_W) * BLOCK_BYTES
        word_addr = line_a + word_off
        kind = rng.choice(["read_line", "read_word", "write_word"])

        if kind == "read_line":
            op = await with_timeout(master.read(line_a, LINE_BYTES), per_op_ns, "ns")
            for i in range(LINE_W):
                wa = line_a + i * BLOCK_BYTES
                got = int.from_bytes(op.data[i*4:(i+1)*4], "little")
                exp = written.get(wa, golden(wa))
                assert got == exp, f"DDR{latency} read_line @0x{wa:08x}"
        elif kind == "read_word":
            op = await with_timeout(master.read(word_addr, BLOCK_BYTES), per_op_ns, "ns")
            got = int.from_bytes(op.data, "little")
            exp = written.get(word_addr, golden(word_addr))
            assert got == exp, f"DDR{latency} read_word @0x{word_addr:08x}"
        else:
            val = rng.randrange(1 << 32)
            await with_timeout(master.write(word_addr, val.to_bytes(BLOCK_BYTES, "little")),
                                per_op_ns, "ns")
            written[word_addr] = val

    assert_pc_clean(dut, f"ddr_first_beat_latency_{latency}")
    dut._log.info(f"[ddr_latency] N={latency}: 30 ops OK")


@cocotb.test()
async def test_long_idle_then_reset_recover(dut):
    """Warm-up, idle for max(4096, LINES*8) cycles, reset, fresh read."""
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    addr_warm = BASE | 0x1000
    op = await with_timeout(master.read(addr_warm, LINE_BYTES), 5_000, "ns")
    exp = b"".join(golden(addr_warm + i * BLOCK_BYTES).to_bytes(BLOCK_BYTES, "little")
                   for i in range(LINE_W))
    assert op.data == exp
    payload = bytes((i * 17) & 0xFF for i in range(LINE_BYTES))
    await with_timeout(master.write(addr_warm, payload), 5_000, "ns")

    IDLE = max(4096, LINES * 8)
    for _ in range(IDLE):
        await RisingEdge(dut.clk)
    assert_pc_clean(dut, "long_idle (before reset)")

    # Toggle rst directly; clock already running from reset_dut.
    dut.rst.value = 1
    for sig, val in [("s_arvalid", 0), ("s_awvalid", 0), ("s_wvalid", 0),
                     ("s_rready", 1), ("s_bready", 1),
                     ("s_arsnoop", 0), ("s_awsnoop", 0)]:
        if hasattr(dut, sig):
            getattr(dut, sig).value = val
    for _ in range(max(128, LINES * 2)):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    # addr_post was never touched; cache is empty post-reset so this returns golden.
    addr_post = BASE | 0x2000
    op = await with_timeout(master.read(addr_post, LINE_BYTES), 5_000, "ns")
    exp_post = b"".join(golden(addr_post + i * BLOCK_BYTES).to_bytes(BLOCK_BYTES, "little")
                        for i in range(LINE_W))
    assert op.data == exp_post

    assert_pc_clean(dut, "long_idle_then_reset_recover")
    dut._log.info(f"[long_idle] idle={IDLE} cyc, reset OK")
