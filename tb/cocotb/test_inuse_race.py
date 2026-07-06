"""Repro for the inuse same-cycle set/clear collision (tablecache_bug_inuse_
setclear_race.md), the l2_cache internal SVA `inuse_id_no_same_cycle_collide` /
`inuse_line_no_same_cycle_collide` (l2_cache.sv:1545-1552).

The race: a read-miss that evicts a DIRTY line produces a two-phase (combined
writeback + fill, and possibly a co-retiring write response) finish entry. When
phase-1 finish_clear drops inuse for one (id/hash), a freshly accepted request
whose in_id/in_hash equals a LATER phase's finish_id/finish_hash can be accepted
(tb_advance) the same cycle that phase fires finish_clear -> both toggle the same
inuse bit -> stuck SET -> wedge. `~same_target` only suppresses re-clears of the
SAME already-cleared (id,hash), not an incoming-accept-vs-finish collision.

Deployment config that triggers it (GraphBlox BFS property path): WAYS=1 / LRU /
INCLUDE_VICTIM, with read-modify-write traffic (read visited[v]; write visited[v])
to a small set of lines so every same-set access evicts a dirty line.

MUST be built with ASSERT=1 (Verilator --assert) so the internal SVA is a real
failure; without it the wedge only shows as a liveness hang.

Run: make MODULE=test_inuse_race LINES=16 WAYS=1 VICTIM=1 ASSERT=1
"""
from __future__ import annotations
import os
import cocotb
from cocotb.triggers import RisingEdge
from cocotbext.axi import AxiBus, AxiMaster
from tb_common import reset_dut, attach_mem

BASE        = 0x80000000
BLOCK_BYTES = 4
LINE_W      = int(os.environ.get("TC_LINE_W", "8"))
LINE_BYTES  = LINE_W * BLOCK_BYTES
LINES       = int(os.environ.get("TC_LINES", "16"))
WAYS        = int(os.environ.get("TC_WAYS", "1"))
WB_ALLOC    = 0xF          # arcache/awcache = write-back read+write allocate


@cocotb.test()
async def test_inuse_setclear_race(dut):
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = AxiMaster(AxiBus.from_prefix(dut, "s"), dut.clk, dut.rst,
                       reset_active_level=True)
    if hasattr(dut, "s_arsnoop"):
        dut.s_arsnoop.value = 0
    if hasattr(dut, "s_awsnoop"):
        dut.s_awsnoop.value = 0

    # A pool of tags that all collide into a handful of sets, so every access to
    # a set evicts the (dirty) resident line -> a steady stream of combined
    # writeback+fill (+ co-retiring write) finishes. SET_STRIDE-apart addresses
    # share a set with distinct tags.
    SET_STRIDE = LINES * LINE_BYTES
    NSETS = int(os.environ.get("TC_NSETS", "2"))  # >=3 trips a cocotbext-axi auto-id concurrency limit, unrelated to the SVA
    TAGS = max(WAYS + 2, 4)
    def addr(tag, s):
        return BASE | (0x1000 + s * LINE_BYTES + tag * SET_STRIDE)

    # Prime every (set, tag) line dirty via cache writes (write-allocate), so the
    # first eviction wave is dirty.
    for s in range(NSETS):
        for tag in range(TAGS):
            await master.write(addr(tag, s), bytes([tag, s, 0x5A, 0x00]), cache=WB_ALLOC)

    # Hammer: many rounds of concurrent read-modify-write across the colliding
    # lines. Use UNIQUE, non-reused ids from rotating counters (bounded
    # outstanding) so ops overlap and finishes pile up / co-retire, forcing
    # constant dirty evictions and combined writeback+fill(+write) finishes.
    ROUNDS = int(os.environ.get("TC_ROUNDS", "150"))
    for r in range(ROUNDS):
        rd = []
        wr = []
        for s in range(NSETS):
            tag = (r + s) % TAGS
            ra = addr(tag, s)                     # read one line in set s
            wa = addr((tag + 1) % TAGS, s)        # write DIFFERENT lines, same set
            wb = addr((tag + 3) % TAGS, s)        #   -> forces dirty evictions
            # auto-assigned ids (AxiMaster manages the id pool safely)
            rd.append(master.init_read(ra, BLOCK_BYTES, cache=WB_ALLOC))
            wr.append(master.init_write(wa, bytes([r & 0xFF, s, 0xC3, 0x00]), cache=WB_ALLOC))
            wr.append(master.init_write(wb, bytes([r & 0xFF, s, 0x3C, 0x00]), cache=WB_ALLOC))
        for op in rd:
            await op.wait()
        for op in wr:
            await op.wait()

    # Liveness: if the inuse toggle wedged, some later op would never complete
    # (this test would time out). Reaching here with ASSERT=1 and no SVA fire is
    # the pass condition. Do a final round-trip to be sure the cache still serves.
    probe = addr(0, 0)
    rop = await master.read(probe, BLOCK_BYTES, cache=WB_ALLOC)
    assert len(rop.data) == BLOCK_BYTES, "final probe read returned no data"
    dut._log.info(f"[inuse race] completed {ROUNDS} RMW rounds + probe -- "
                  f"cache live, no inuse same-cycle collision")
