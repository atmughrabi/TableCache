"""TEMPLATE: directed test for YOUR accelerator's traffic pattern.

The verification campaign (60 tests + 100% mutation + 8 formal proofs)
gives high confidence in the cache's *implementation*. The ONE thing
it can't tell you is whether the cache works correctly under YOUR
accelerator's specific traffic pattern.

Bug #13 (cold-cache flush hang) was found this way: a directed test
of a new use case exposed an interaction the random/matrix tests never
triggered. Plan for at least one of your patterns to do the same.

----------------------------------------------------------------------
HOW TO USE THIS TEMPLATE
----------------------------------------------------------------------

1. Copy this file:
      cp test_yours.py test_<myaccel>.py

2. Sketch your access pattern in code (see Pattern 1/2/3 below).

3. Replace the TODO sections with your actual stimulus.

4. Run it:
      cd tb/cocotb && source .venv/bin/activate
      make MODULE=test_<myaccel>

5. If it passes: run it across the parameter matrix.
      MODULE=test_<myaccel> N=8 NTXN=1000 ./seed_sweep.sh

6. If it FAILS: that's the most valuable signal you'll get.
      - Dump VCD: TRACE=1 make MODULE=test_<myaccel>
      - Open in GTKWave: make wave
      - Look at s_arvalid / s_arready / s_rvalid / mem_arvalid /
        cache_pc_violations_total
"""
from __future__ import annotations
import os
import cocotb
from cocotb.triggers import RisingEdge, Timer, with_timeout
from tb_common import reset_dut, attach_master, attach_mem, golden

# ---------------------------------------------------------------------
# Configuration (match how the cache will be built in your design)
# ---------------------------------------------------------------------
BASE        = 0x80000000          # cache address window base
BLOCK_BYTES = 4                   # one narrow beat
LINE_W      = int(os.environ.get("TC_LINE_W", "8"))
LINE_BYTES  = LINE_W * BLOCK_BYTES
NUM_LINES   = int(os.environ.get("TC_LINES",  "64"))


# =====================================================================
# PATTERN 1 -- streaming sequential read
#   accelerator reads a contiguous region of memory in order.
#   (common: graph CSR row scan, FFT stages, image row processing)
# =====================================================================
@cocotb.test()
async def test_my_streaming_read(dut):
    """TODO: replace `N_LINES` and `start_addr` with your real values."""
    await reset_dut(dut)
    ram    = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    start_addr = BASE | 0x00010000      # TODO
    n_lines    = 32                     # TODO

    for li in range(n_lines):
        addr = start_addr + li * LINE_BYTES
        op = await with_timeout(master.read(addr, LINE_BYTES), 10_000, "ns")
        # If you have a golden model:
        for b in range(LINE_W):
            ba  = addr + b * BLOCK_BYTES
            got = int.from_bytes(op.data[b*BLOCK_BYTES:(b+1)*BLOCK_BYTES], "little")
            exp = golden(ba)
            assert got == exp, (
                f"streaming read mismatch at line {li} beat {b}: "
                f"addr=0x{ba:08x} got=0x{got:08x} exp=0x{exp:08x}"
            )

    assert int(dut.pc_violations_total.value) == 0, "AXI protocol violation"
    dut._log.info(f"[stream] {n_lines} sequential lines, all match")


# =====================================================================
# PATTERN 2 -- pointer chase (indirect access)
#   accelerator reads addr A, that gives addr B, that gives addr C, ...
#   (common: graph BFS frontier, linked lists, trie traversal)
# =====================================================================
@cocotb.test()
async def test_my_pointer_chase(dut):
    """Read a head pointer, follow it through `chain_len` hops. Each
    hop reads a fresh cache line -- stresses miss + replacement +
    eviction ordering."""
    await reset_dut(dut)
    ram    = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    chain_len = 16                       # TODO
    # Seed a chain into the RAM that the cache fronts:
    #   ram[addr_i] = addr_{i+1}
    head = BASE | 0x00020000
    addrs = [head + (i * 11 * LINE_BYTES) & ~(BLOCK_BYTES - 1)
             for i in range(chain_len + 1)]
    for i in range(chain_len):
        next_ptr = addrs[i + 1]
        # Write next_ptr into the lower beat of addrs[i] (mem-side).
        off = addrs[i] & 0x000F_FFFF
        ram.write(off, next_ptr.to_bytes(BLOCK_BYTES, "little"))

    # Follow the chain through the cache.
    cur = head
    for hop in range(chain_len):
        op = await with_timeout(master.read(cur, BLOCK_BYTES), 5_000, "ns")
        next_ptr = int.from_bytes(op.data, "little")
        assert next_ptr == addrs[hop + 1], (
            f"chase hop {hop}: at 0x{cur:08x} got next=0x{next_ptr:08x} "
            f"expected 0x{addrs[hop+1]:08x}"
        )
        cur = next_ptr

    assert int(dut.pc_violations_total.value) == 0
    dut._log.info(f"[chase] {chain_len} hops, all pointers correct")


# =====================================================================
# PATTERN 3 -- read-modify-write to a hot region
#   accelerator repeatedly reads & updates a small region.
#   (common: histogram bins, page-rank score updates, atomic counters)
# =====================================================================
@cocotb.test()
async def test_my_hot_rmw(dut):
    """Repeated R-M-W on `n_hot` lines for `n_iter` iterations.
    Stresses dirty-line tracking, writeback ordering, evict<->fill races."""
    await reset_dut(dut)
    ram    = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    n_hot  = 4                           # TODO
    n_iter = 64                          # TODO
    base   = BASE | 0x00030000
    addrs  = [base + (i * LINE_BYTES) for i in range(n_hot)]

    counters = [0] * n_hot
    for it in range(n_iter):
        for i, a in enumerate(addrs):
            op = await with_timeout(master.read(a, BLOCK_BYTES), 5_000, "ns")
            cur = int.from_bytes(op.data, "little")
            new = (cur + 1) & 0xFFFF_FFFF
            await with_timeout(
                master.write(a, new.to_bytes(BLOCK_BYTES, "little")),
                5_000, "ns"
            )
            counters[i] = new

    # Final verification: every hot line should hold n_iter (assuming
    # golden() returns 0 initially or you seeded zeros).
    for a, c in zip(addrs, counters):
        op = await with_timeout(master.read(a, BLOCK_BYTES), 5_000, "ns")
        got = int.from_bytes(op.data, "little")
        assert got == c, (
            f"hot RMW final: 0x{a:08x} got=0x{got:08x} expected 0x{c:08x}"
        )

    assert int(dut.pc_violations_total.value) == 0
    dut._log.info(f"[hot RMW] {n_hot} lines x {n_iter} iters, counters consistent")


# =====================================================================
# PATTERN 4 -- back-to-back same-line accesses with intervening eviction
#   stresses the inuse-line tracking that bug #6 was about.
# =====================================================================
@cocotb.test()
async def test_my_evict_revisit(dut):
    """Write line A, read line A (warm hit), evict via WAYS+1 distinct
    same-set tags, read A again (must miss-refetch, NOT hang)."""
    await reset_dut(dut)
    ram    = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    # set_id 0 fully populated:
    ways = int(os.environ.get("TC_WAYS", "4"))
    a    = BASE | 0x00040000
    sentinel = 0xDEADBEEF
    await master.write(a, sentinel.to_bytes(BLOCK_BYTES, "little"))
    op = await master.read(a, BLOCK_BYTES)
    assert int.from_bytes(op.data, "little") == sentinel

    # Force eviction: WAYS+1 reads to other tags in the same set.
    line_idx = (a >> 5) & (NUM_LINES - 1)
    for k in range(ways + 1):
        # Same set, different tag (tags live in bits above LINES bits).
        evict_addr = (a + (1 << 24) * (k + 1)) & 0xFFFF_FFFF
        await with_timeout(master.read(evict_addr, BLOCK_BYTES), 5_000, "ns")

    # Re-read a: must NOT hang.
    op = await with_timeout(master.read(a, BLOCK_BYTES), 5_000, "ns")
    got = int.from_bytes(op.data, "little")
    assert got == sentinel, f"evict-revisit: got=0x{got:08x} exp=0x{sentinel:08x}"

    assert int(dut.pc_violations_total.value) == 0
    dut._log.info("[evict_revisit] line round-tripped through eviction")
