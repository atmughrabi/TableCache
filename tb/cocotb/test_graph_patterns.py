"""Graph-algorithm access patterns.

Five tests modeled on kernels a graph accelerator would issue:
  1. pointer_chase_random_walk  - dependent-read chain (BFS, GNN)
  2. frontier_merge_same_set    - N concurrent reads, all same set
  3. csr_row_pointer_scan       - sequential + random streams interleaved
  4. vertex_property_scatter    - scattered 1-byte writes (PageRank)
  5. rmw_contention             - serial W then concurrent R on same line

All gate on `pc_violations_total == 0`.
"""
from __future__ import annotations

import os
import random
import cocotb
from cocotb.triggers import RisingEdge, with_timeout
from cocotb.utils import get_sim_time
from tb_common import reset_dut, attach_master, attach_mem, golden

BASE        = 0x80000000
BLOCK_BYTES = 4
LINE_W      = int(os.environ.get("TC_LINE_W", "8"))
LINE_BYTES  = LINE_W * BLOCK_BYTES
LINES       = int(os.environ.get("TC_LINES", "64"))
WAYS        = int(os.environ.get("TC_WAYS", "4"))


def line_addr(line_idx: int) -> int:
    return BASE | (line_idx * LINE_BYTES)


def set_of(addr: int) -> int:
    # bits[5+log2(LINES)-1 : 5] are the set index
    return (addr >> 5) & (LINES - 1)


def assert_pc_clean(dut, ctx: str):
    pc = int(dut.pc_violations_total.value)
    assert pc == 0, f"AXI_PC violations during {ctx}: {pc}"


@cocotb.test()
async def test_pointer_chase_random_walk(dut):
    """64-hop deterministic walk. Cold pass = all misses; warm pass has
    some hits. Assert warm < cold wall-clock."""
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    rng = random.Random(0xBEEF)
    CHAIN_LEN = 64
    POOL = max(LINES * WAYS * 4, 256)
    walk = [rng.randrange(POOL) for _ in range(CHAIN_LEN)]

    t0 = get_sim_time("ns")
    for li in walk:
        op = await with_timeout(master.read(line_addr(li), BLOCK_BYTES), 5_000, "ns")
        assert int.from_bytes(op.data, "little") == golden(line_addr(li))
    t_cold = get_sim_time("ns") - t0

    t0 = get_sim_time("ns")
    for li in walk:
        op = await with_timeout(master.read(line_addr(li), BLOCK_BYTES), 5_000, "ns")
        assert int.from_bytes(op.data, "little") == golden(line_addr(li))
    t_warm = get_sim_time("ns") - t0

    dut._log.info(f"[pointer_chase] cold={t_cold/CHAIN_LEN:.1f} warm={t_warm/CHAIN_LEN:.1f} ns/hop")
    assert t_warm < t_cold, f"warm ({t_warm} ns) not faster than cold ({t_cold} ns)"
    assert_pc_clean(dut, "pointer_chase")


@cocotb.test()
async def test_frontier_merge_same_set(dut):
    """N=2*WAYS distinct lines hashing to the same set, all read concurrently."""
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    TARGET_SET = LINES // 2
    N = WAYS * 2
    # Default layout: line_idx & (LINES-1) == set index
    indices = [TARGET_SET + k * LINES for k in range(N)]
    for li in indices:
        assert set_of(line_addr(li)) == TARGET_SET

    tasks = [cocotb.start_soon(master.read(line_addr(li), BLOCK_BYTES)) for li in indices]
    for li, t in zip(indices, tasks):
        op = await with_timeout(t, 20_000, "ns")
        assert int.from_bytes(op.data, "little") == golden(line_addr(li))

    assert_pc_clean(dut, "frontier_merge_same_set")


@cocotb.test()
async def test_csr_row_pointer_scan(dut):
    """Interleaved sequential row_ptr[i] + random col_idx[r]. Bound m_ar
    handshakes by `ceil(N_ROWS/LINE_W) + N_ROWS`."""
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    rng = random.Random(0xC5C5)
    N_ROWS = 128
    ROW_PTR_BASE = BASE | 0x10000
    COL_POOL = max(LINES * WAYS * 4, 256)

    m_ar = 0
    async def count_ar():
        nonlocal m_ar
        while True:
            await RisingEdge(dut.clk)
            if int(dut.m_arvalid.value) and int(dut.m_arready.value):
                m_ar += 1
    monitor = cocotb.start_soon(count_ar())

    await with_timeout(master.read(ROW_PTR_BASE, BLOCK_BYTES), 5_000, "ns")  # warm-up
    before = m_ar
    for i in range(N_ROWS):
        await with_timeout(master.read(ROW_PTR_BASE + i * BLOCK_BYTES, BLOCK_BYTES), 5_000, "ns")
        col_line = rng.randrange(COL_POOL) + COL_POOL * 2
        await with_timeout(master.read(line_addr(col_line), BLOCK_BYTES), 5_000, "ns")
    streamed = m_ar - before
    monitor.kill()

    bound = (N_ROWS // LINE_W + 2) + N_ROWS
    assert streamed <= bound, f"m_ar={streamed} > bound {bound}"
    dut._log.info(f"[csr_scan] m_ar={streamed} (bound {bound})")
    assert_pc_clean(dut, "csr_row_pointer_scan")


@cocotb.test()
async def test_vertex_property_scatter(dut):
    """256 scattered 1-byte writes across `4*LINES*WAYS` lines; verify
    last-writer-wins on readback."""
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    rng = random.Random(0x5CA77E2)
    NWR = 256
    POOL = max(LINES * WAYS * 4, 512)

    final: dict[int, int] = {}
    for _ in range(NWR):
        li = rng.randrange(POOL)
        word_off = rng.randrange(LINE_W) * BLOCK_BYTES
        lane = rng.randrange(BLOCK_BYTES)
        byte_addr = line_addr(li) + word_off + lane
        val = rng.randrange(256)
        await with_timeout(master.write(byte_addr, bytes([val]), size=0), 5_000, "ns")
        final[byte_addr] = val

    touched = {a & ~3 for a in final}
    for word_addr in touched:
        op = await with_timeout(master.read(word_addr, BLOCK_BYTES), 5_000, "ns")
        exp = list(golden(word_addr).to_bytes(BLOCK_BYTES, "little"))
        for b in range(BLOCK_BYTES):
            if (word_addr + b) in final:
                exp[b] = final[word_addr + b]
        assert list(op.data) == exp, f"scatter mismatch @0x{word_addr:08x}"

    dut._log.info(f"[scatter] {NWR} writes / {len(touched)} words verified")
    assert_pc_clean(dut, "vertex_property_scatter")


@cocotb.test()
async def test_rmw_contention(dut):
    """Serial writes to a hot line, then 16 concurrent full-line reads."""
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    HOT = BASE | 0x4000
    rng = random.Random(0x404D)

    expected = bytearray(LINE_BYTES)
    for o in range(LINE_BYTES):
        expected[o] = (golden(HOT + (o & ~3)) >> ((o & 3) * 8)) & 0xFF
    for _ in range(16):
        word_off = rng.randrange(LINE_W) * BLOCK_BYTES
        val = rng.randrange(1 << 32)
        await with_timeout(master.write(HOT + word_off, val.to_bytes(BLOCK_BYTES, "little")),
                            5_000, "ns")
        for b in range(BLOCK_BYTES):
            expected[word_off + b] = (val >> (b * 8)) & 0xFF

    tasks = [cocotb.start_soon(master.read(HOT, LINE_BYTES)) for _ in range(16)]
    for i, t in enumerate(tasks):
        op = await with_timeout(t, 20_000, "ns")
        assert op.data == bytes(expected), f"rmw_contention read {i}"

    assert_pc_clean(dut, "rmw_contention")
