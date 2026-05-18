"""Adversarial back-pressure on every AXI READY independently and combined.

Pauses are driven via cocotbext-axi `set_pause_generator(...)` on the
relevant channel sink/source. After applying the pause pattern we run a
small R/W mix and gate on golden-data correctness + `pc_violations_total == 0`.

Found bug #12 (mem-side VALIDs held into reset under m_*ready pause).
"""
from __future__ import annotations

import os
import random
import cocotb
from cocotb.triggers import with_timeout
from tb_common import reset_dut, attach_master, attach_mem, golden

BASE        = 0x80000000
BLOCK_BYTES = 4
LINE_W      = int(os.environ.get("TC_LINE_W", "8"))
LINE_BYTES  = LINE_W * BLOCK_BYTES


def burst_pause(rng: random.Random, pause_max: int = 16, run_max: int = 8):
    """Infinite 0/1 generator: alternates RUN (yield 0) and PAUSE (yield 1)
    bursts, each uniformly sized in [1, max]. Deterministic given `rng`."""
    while True:
        for _ in range(rng.randint(1, run_max)):
            yield 0
        for _ in range(rng.randint(1, pause_max)):
            yield 1


def assert_pc_clean(dut, ctx: str):
    pc = int(dut.pc_violations_total.value)
    assert pc == 0, f"AXI_PC violations during {ctx}: {pc}"


async def correctness_mix(master, rng: random.Random, n: int = 32):
    """Read+write mix over a 16-line hot pool. Most accesses hit after
    warm-up so R/B traffic dominates -- maximizes stress on response channels."""
    POOL = 16
    written: dict[int, int] = {}
    for _ in range(n):
        kind = rng.choice(["read_line", "read_word", "write_word"])
        addr = BASE | (rng.randrange(POOL) * LINE_BYTES)
        if kind == "read_line":
            op = await with_timeout(master.read(addr, LINE_BYTES), 30_000, "ns")
            for i in range(LINE_W):
                wa = addr + i * BLOCK_BYTES
                got = int.from_bytes(op.data[i*4:(i+1)*4], "little")
                exp = written.get(wa, golden(wa))
                assert got == exp, f"read_line @0x{wa:08x}: got=0x{got:08x} exp=0x{exp:08x}"
        elif kind == "read_word":
            wa = addr + rng.randrange(LINE_W) * BLOCK_BYTES
            op = await with_timeout(master.read(wa, BLOCK_BYTES), 30_000, "ns")
            got = int.from_bytes(op.data, "little")
            exp = written.get(wa, golden(wa))
            assert got == exp, f"read_word @0x{wa:08x}: got=0x{got:08x} exp=0x{exp:08x}"
        else:
            wa = addr + rng.randrange(LINE_W) * BLOCK_BYTES
            val = rng.randrange(1 << 32)
            await with_timeout(master.write(wa, val.to_bytes(BLOCK_BYTES, "little")),
                                30_000, "ns")
            written[wa] = val


@cocotb.test()
async def test_master_rready_backpressure(dut):
    """Pause s_rready in 1..16-cycle bursts."""
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)
    master.read_if.r_channel.set_pause_generator(burst_pause(random.Random(0x5A5A), 16, 4))
    await correctness_mix(master, random.Random(0xA1A1), n=40)
    assert_pc_clean(dut, "master_rready_backpressure")


@cocotb.test()
async def test_master_bready_backpressure(dut):
    """Pause s_bready in 1..16-cycle bursts."""
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)
    master.write_if.b_channel.set_pause_generator(burst_pause(random.Random(0xB6B6), 16, 4))
    await correctness_mix(master, random.Random(0xB1B1), n=40)
    assert_pc_clean(dut, "master_bready_backpressure")


@cocotb.test()
async def test_master_both_response_backpressure(dut):
    """Pause s_rready AND s_bready (independent generators)."""
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)
    master.read_if.r_channel.set_pause_generator(burst_pause(random.Random(0xCAFE5A), 12, 3))
    master.write_if.b_channel.set_pause_generator(burst_pause(random.Random(0xCAFEB6), 12, 3))
    await correctness_mix(master, random.Random(0xC0FFEE), n=60)
    assert_pc_clean(dut, "master_both_response_backpressure")


@cocotb.test()
async def test_mem_arready_backpressure(dut):
    """Pause m_arready in 1..20-cycle bursts."""
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)
    ram.read_if.ar_channel.set_pause_generator(burst_pause(random.Random(0xAA01), 20, 2))
    await correctness_mix(master, random.Random(0xA01A), n=40)
    assert_pc_clean(dut, "mem_arready_backpressure")


@cocotb.test()
async def test_mem_wready_backpressure(dut):
    """Pause m_wready; write-biased 70%/30% mix to stress wdata FIFO."""
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)
    ram.write_if.w_channel.set_pause_generator(burst_pause(random.Random(0xAA02), 20, 2))

    rng = random.Random(0x0B0B)
    written: dict[int, int] = {}
    for _ in range(60):
        wa = (BASE | (rng.randrange(16) * LINE_BYTES)) + rng.randrange(LINE_W) * BLOCK_BYTES
        if rng.random() < 0.7:
            val = rng.randrange(1 << 32)
            await with_timeout(master.write(wa, val.to_bytes(BLOCK_BYTES, "little")),
                                30_000, "ns")
            written[wa] = val
        else:
            op = await with_timeout(master.read(wa, BLOCK_BYTES), 30_000, "ns")
            got = int.from_bytes(op.data, "little")
            exp = written.get(wa, golden(wa))
            assert got == exp, f"mem_wready @0x{wa:08x}: got=0x{got:08x} exp=0x{exp:08x}"

    assert_pc_clean(dut, "mem_wready_backpressure")


@cocotb.test()
async def test_all_channels_backpressure(dut):
    """Pause every back-pressureable channel simultaneously with independent seeds."""
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)
    master.read_if.r_channel.set_pause_generator(burst_pause(random.Random(0xA001), 10, 4))
    master.write_if.b_channel.set_pause_generator(burst_pause(random.Random(0xA002), 10, 4))
    ram.read_if.ar_channel.set_pause_generator(burst_pause(random.Random(0xA003), 10, 4))
    ram.write_if.w_channel.set_pause_generator(burst_pause(random.Random(0xA004), 10, 4))
    ram.write_if.aw_channel.set_pause_generator(burst_pause(random.Random(0xA005), 10, 4))
    await correctness_mix(master, random.Random(0xDEADBEEF), n=80)
    assert_pc_clean(dut, "all_channels_backpressure")
