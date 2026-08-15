"""Stress targeting `cp_finish_fifo_full` and `cp_same_target_suppression`
cover points in src/l2_cache.sv.

Triggers:
  * cp_finish_fifo_full: 8+ in-flight distinct (id, hash) pairs +
    aggressive response back-pressure so finishes queue past depth 4.
  * cp_same_target_suppression: a finish whose head (id, hash) equals the
    just-cleared previous head's (id, hash).

Gates on data correctness + `pc_violations_total == 0`.
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


def burst_pause(rng: random.Random, pmax: int, rmax: int):
    while True:
        for _ in range(rng.randint(1, rmax)):
            yield 0
        for _ in range(rng.randint(1, pmax)):
            yield 1


def assert_pc_clean(dut, ctx: str):
    pc = int(dut.pc_violations_total.value)
    assert pc == 0, f"AXI_PC violations during {ctx}: {pc}"


@cocotb.test()
async def test_finish_fifo_overflow(dut):
    """16 distinct lines (distinct hashes) hit concurrently, then drained
    under heavy s_rready / s_bready stall. finish-FIFO is depth 4; with
    16 simultaneous completions queued and trickling out, finish_full
    must rise."""
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    # Heavy response back-pressure: 1..40-cycle pauses, 1-cycle runs.
    master.read_if.r_channel.set_pause_generator(
        burst_pause(random.Random(0xFF01), pmax=40, rmax=1))
    master.write_if.b_channel.set_pause_generator(
        burst_pause(random.Random(0xFF02), pmax=40, rmax=1))

    rng = random.Random(0xFEED)
    N_LINES = 16
    written: dict[int, int] = {}
    # Pick lines far apart so they land on distinct sets.
    line_addrs = [BASE | (i * 1024) for i in range(N_LINES)]

    tasks = []
    for li_addr in line_addrs:
        if rng.random() < 0.5:
            wa = li_addr + rng.randrange(LINE_W) * BLOCK_BYTES
            val = rng.randrange(1 << 32)
            tasks.append(cocotb.start_soon(
                master.write(wa, val.to_bytes(BLOCK_BYTES, "little"))))
            written[wa] = val
        else:
            tasks.append(cocotb.start_soon(master.read(li_addr, LINE_BYTES)))

    for t in tasks:
        await with_timeout(t, 200_000, "ns")

    # Verify
    for li_addr in line_addrs:
        op = await with_timeout(master.read(li_addr, LINE_BYTES), 200_000, "ns")
        for i in range(LINE_W):
            wa = li_addr + i * BLOCK_BYTES
            got = int.from_bytes(op.data[i*4:(i+1)*4], "little")
            exp = written.get(wa, golden(wa))
            assert got == exp, f"finish_fifo_overflow @0x{wa:08x} got=0x{got:08x} exp=0x{exp:08x}"

    assert_pc_clean(dut, "finish_fifo_overflow")


@cocotb.test()
async def test_same_target_finishes_back_to_back(dut):
    """Exercise consecutive finish entries carrying the same
    (id, hash) as head N. Triggers: alternating write-then-read on the
    same line under response back-pressure so consecutive finishes share
    target. With cocotbext-axi rotating IDs the cache may merge them into
    combined finish entries, which is exactly the suppression case."""
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    master.read_if.r_channel.set_pause_generator(
        burst_pause(random.Random(0xFF03), pmax=30, rmax=1))
    master.write_if.b_channel.set_pause_generator(
        burst_pause(random.Random(0xFF04), pmax=30, rmax=1))

    HOT = BASE | 0x800
    written: dict[int, int] = {}
    tasks = []
    for k in range(40):
        wa = HOT + (k % LINE_W) * BLOCK_BYTES
        val = (k * 0xDEAD + 0xBEEF) & 0xFFFFFFFF
        tasks.append(cocotb.start_soon(
            master.write(wa, val.to_bytes(BLOCK_BYTES, "little"))))
        written[wa] = val
        tasks.append(cocotb.start_soon(master.read(HOT, LINE_BYTES)))

    for t in tasks:
        await with_timeout(t, 200_000, "ns")

    op = await with_timeout(master.read(HOT, LINE_BYTES), 200_000, "ns")
    for i in range(LINE_W):
        wa = HOT + i * BLOCK_BYTES
        got = int.from_bytes(op.data[i*4:(i+1)*4], "little")
        exp = written.get(wa, golden(wa))
        assert got == exp, f"same_target @0x{wa:08x} got=0x{got:08x} exp=0x{exp:08x}"

    assert_pc_clean(dut, "same_target_finishes_back_to_back")
