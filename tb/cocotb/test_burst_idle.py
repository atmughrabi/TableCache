"""Reproduce (and now regression-guard) the residual reported in
tablecache_flush_rootcause UPDATE 22/23 -- root-caused as bug #28.

Two tests:
  * test_burst_idle_liveness -- COLD same-id read burst + idle + reread. Always
    stayed live even pre-fix (cold reads never evict), so it does NOT trip the
    bug; kept as a baseline liveness check.
  * test_evict_burst_idle_liveness -- the real repro. Warm the cache dirty, then
    a back-to-back same-id read burst that EVICTS dirty lines PIPELINED across
    the databank's 2 ports (round-robin sets), drain, idle, reread.

Bug #28: needs_rdata (the "fill pending" per-id toggle) was set on req_arready
(the slave-port accept into the 1-deep AR skid) instead of the arbitrated
advance, so two back-to-back same-id reads toggled it twice -> 0. A writeback
that retired before its paired fill then read "fill done" and cleared inuse a
second time -> inuse_id/inuse_line stuck SET -> every later same-id/same-set
read wedged (accepted at the slave, no fetch, no rvalid). Needs a small geometry
(e.g. LINES=2 WAYS=2) so the burst actually evicts dirty lines.

This drives l2_cache's s_ AR/R (and s_ AW/W to warm) channels directly; its own
inuse_stall serializes same-id reads, like the shim would.

Run:  make MODULE=test_burst_idle LINES=2 WAYS=2 \
           [TC_BURST_N=..] [TC_IDLE=..] [TESTCASE=test_evict_burst_idle_liveness]
"""
from __future__ import annotations
import os
import cocotb
from cocotb.triggers import RisingEdge, ReadOnly
from tb_common import reset_dut, attach_mem, golden

BASE        = 0x80000000
BLOCK_BYTES = 4
LINE_W      = int(os.environ.get("TC_LINE_W", "8"))
LINE_BYTES  = LINE_W * BLOCK_BYTES
BURST_N     = int(os.environ.get("TC_BURST_N", "4"))
IDLE        = int(os.environ.get("TC_IDLE", "400"))
ARSIZE      = (BLOCK_BYTES.bit_length() - 1)   # log2(4) = 2


def _lines(n, base=0xB000):
    # n distinct cache lines (cold), spaced by one line, like GraphBlox 0xB000..
    return [BASE | (base + i * LINE_BYTES) for i in range(n)]


@cocotb.test()
async def test_burst_idle_liveness(dut):
    await reset_dut(dut)
    _ram = attach_mem(dut, size_bytes=1 << 20)
    if hasattr(dut, "s_arsnoop"):
        dut.s_arsnoop.value = 0

    got = []
    async def r_collector():
        dut.s_rready.value = 1
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.s_rvalid) and int(dut.s_rready):
                got.append((int(dut.s_rid), int(dut.s_rdata) & 0xFFFFFFFF, int(dut.s_rlast)))
    cocotb.start_soon(r_collector())

    def setup_ar(addr):
        dut.s_araddr.value  = addr
        dut.s_arid.value    = 0
        dut.s_arlen.value   = 0            # single-word read
        dut.s_arsize.value  = ARSIZE
        dut.s_arburst.value = 1

    async def wait_ar_accept(limit=3000):
        await ReadOnly()
        for _ in range(limit):
            if int(dut.s_arready):
                return True
            await RisingEdge(dut.clk)
            await ReadOnly()
        return False

    # ---- back-to-back same-id burst: hold s_arvalid, advance on handshake ----
    addrs = _lines(BURST_N)
    setup_ar(addrs[0]); dut.s_arvalid.value = 1
    idx = 0
    for _ in range(60_000):
        await ReadOnly()
        accepted = int(dut.s_arvalid) and int(dut.s_arready)
        await RisingEdge(dut.clk)
        if accepted:
            idx += 1
            if idx >= BURST_N:
                dut.s_arvalid.value = 0
                break
            setup_ar(addrs[idx])           # s_arvalid stays 1
    # drain all burst responses (rlast beats)
    lasts = lambda: sum(1 for _, _, l in got if l)
    for _ in range(60_000):
        await RisingEdge(dut.clk)
        if lasts() >= BURST_N:
            break
    assert lasts() >= BURST_N, f"burst delivered only {lasts()}/{BURST_N} rlast beats"
    dut._log.info(f"[burst+idle] burst delivered {lasts()}/{BURST_N}, BURST_N={BURST_N} IDLE={IDLE}")

    # ---- IDLE window (the trigger) ----
    dut.s_arvalid.value = 0
    for _ in range(IDLE):
        await RisingEdge(dut.clk)

    # ---- post-idle read: must be accepted AND responded to ----
    n_last = lasts()
    probe = addrs[0]                       # resident line
    setup_ar(probe); dut.s_arvalid.value = 1
    assert await wait_ar_accept(), "post-idle AR was never accepted at s_arready"
    await RisingEdge(dut.clk)
    dut.s_arvalid.value = 0
    live = False
    for _ in range(8000):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if lasts() > n_last:
            live = True
            break
    assert live, (
        f"CACHE WEDGE: post-idle same-id read accepted but NEVER responded "
        f"(BURST_N={BURST_N}, IDLE={IDLE}) -- l2_cache produced no R after a "
        f"back-to-back same-id burst + idle window")
    rid, data, _ = got[-1]
    assert data == golden(probe) and rid == 0, \
        f"post-idle read data wrong: got 0x{data:08x} exp 0x{golden(probe):08x} rid={rid}"
    dut._log.info(f"[burst+idle] post-idle read serviced -- cache stayed live")


@cocotb.test()
async def test_evict_burst_idle_liveness(dut):
    """The UPDATE-22/23 wedge needs the back-to-back same-id burst to EVICT
    dirty lines -- that is what produces split rvalid+bvalid finish entries and
    exercises the deferred_inuse_clear (bug #2) path under back-to-back same-id.
    Cold-cache read bursts (test_burst_idle_liveness) never evict, so they can't
    trip it. Here: warm the (small) cache fully dirty, then a same-id read burst
    that evicts every line, drain, idle, reread -> must stay live.

    Run small:  make MODULE=test_burst_idle LINES=2 WAYS=2 \
                     TESTCASE=test_evict_burst_idle_liveness
    """
    LINES = int(os.environ.get("TC_LINES", "2"))
    WAYS  = int(os.environ.get("TC_WAYS", "2"))
    SET_SHIFT = (BLOCK_BYTES.bit_length() - 1) + (LINE_W.bit_length() - 1)  # log2(LINE_BYTES)
    SET_STRIDE = LINES * LINE_BYTES   # addresses this far apart share a set (new tag)
    CAP = LINES * WAYS

    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    if hasattr(dut, "s_arsnoop"):
        dut.s_arsnoop.value = 0
    if hasattr(dut, "s_awsnoop"):
        dut.s_awsnoop.value = 0

    # count real writebacks (dirty evictions) on the mem AW channel
    wb = [0]
    async def wb_mon():
        while True:
            await RisingEdge(dut.clk); await ReadOnly()
            if int(dut.m_awvalid) and int(dut.m_awready):
                wb[0] += 1
    cocotb.start_soon(wb_mon())

    got = []
    async def r_collector():
        dut.s_rready.value = 1
        while True:
            await RisingEdge(dut.clk); await ReadOnly()
            if int(dut.s_rvalid) and int(dut.s_rready):
                got.append((int(dut.s_rid), int(dut.s_rlast)))
    cocotb.start_soon(r_collector())
    lasts = lambda: sum(1 for _, l in got if l)

    async def wr(addr, data):
        dut.s_awaddr.value = addr; dut.s_awid.value = 0; dut.s_awlen.value = 0
        dut.s_awsize.value = ARSIZE; dut.s_awburst.value = 1; dut.s_awvalid.value = 1
        for _ in range(3000):
            await ReadOnly()
            if int(dut.s_awready): break
            await RisingEdge(dut.clk)
        await RisingEdge(dut.clk); dut.s_awvalid.value = 0
        dut.s_wdata.value = data; dut.s_wstrb.value = (1 << BLOCK_BYTES) - 1
        dut.s_wlast.value = 1; dut.s_wvalid.value = 1
        for _ in range(3000):
            await ReadOnly()
            if int(dut.s_wready): break
            await RisingEdge(dut.clk)
        await RisingEdge(dut.clk); dut.s_wvalid.value = 0; dut.s_wlast.value = 0
        dut.s_bready.value = 1
        for _ in range(3000):
            await ReadOnly()
            if int(dut.s_bvalid): break
            await RisingEdge(dut.clk)
        await RisingEdge(dut.clk)

    # ---- warm the whole small cache with DIRTY lines (fill every set/way) ----
    # Consecutive lines land in DIFFERENT sets, so a round-robin read burst
    # PIPELINES evictions across the databank's 2 ports -- that concurrency is
    # what makes a writeback (bvalid) finish retire before its paired fill
    # (rvalid), tripping the double-clear. Single-set bursts serialize and hide it.
    warm = [BASE | (0x0000 + i * LINE_BYTES) for i in range(CAP)]
    for i, a in enumerate(warm):
        await wr(a, 0xD0D00000 | i)
    dut._log.info(f"[evict burst] warmed {CAP} dirty lines; writebacks so far={wb[0]}")

    # ---- back-to-back same-id READ burst to NEW tags that collide -> evict ----
    burst = [BASE | ((CAP + i) * LINE_BYTES) for i in range(BURST_N)]

    def setup_ar(addr):
        dut.s_araddr.value = addr; dut.s_arid.value = 0; dut.s_arlen.value = 0
        dut.s_arsize.value = ARSIZE; dut.s_arburst.value = 1

    wb_before = wb[0]
    setup_ar(burst[0]); dut.s_arvalid.value = 1
    idx = 0
    accepted_log = []
    for _ in range(20_000):
        await ReadOnly()
        accepted = int(dut.s_arvalid) and int(dut.s_arready)
        await RisingEdge(dut.clk)
        if accepted:
            accepted_log.append(idx)
            idx += 1
            if idx >= BURST_N:
                dut.s_arvalid.value = 0; break
            setup_ar(burst[idx])
    for _ in range(20_000):
        await RisingEdge(dut.clk)
        if lasts() >= idx:
            break
    evicts = wb[0] - wb_before
    dut._log.info(f"[evict burst] ARs accepted={idx}/{BURST_N}, rlast delivered={lasts()}, "
                  f"dirty evictions={evicts}")
    assert lasts() >= BURST_N, (
        f"WEDGE DURING BURST: accepted={idx}/{BURST_N} ARs but only {lasts()}/{BURST_N} "
        f"responded (evictions={evicts}) -- eviction burst hung mid-stream")
    assert evicts > 0, (
        f"TEST INEFFECTIVE: burst produced 0 dirty evictions at LINES={LINES} WAYS={WAYS} "
        f"BURST_N={BURST_N} -- the split rvalid+bvalid finish path was not exercised; "
        f"run with a config where the burst reads evict dirty lines (e.g. LINES=2 WAYS=2)")

    # ---- IDLE window (the trigger) ----
    dut.s_arvalid.value = 0
    for _ in range(IDLE):
        await RisingEdge(dut.clk)

    # ---- post-idle read -> must stay live ----
    n_last = lasts()
    setup_ar(burst[0]); dut.s_arvalid.value = 1
    ar_ok = False
    await ReadOnly()
    for _ in range(3000):
        if int(dut.s_arready):
            ar_ok = True; break
        await RisingEdge(dut.clk); await ReadOnly()
    assert ar_ok, "post-idle AR never accepted at s_arready"
    await RisingEdge(dut.clk); dut.s_arvalid.value = 0
    live = False
    for _ in range(8000):
        await RisingEdge(dut.clk); await ReadOnly()
        if lasts() > n_last:
            live = True; break
    assert live, (
        f"CACHE WEDGE (eviction burst): post-idle same-id read accepted but NEVER "
        f"responded (BURST_N={BURST_N}, IDLE={IDLE}, evictions={evicts})")
    dut._log.info("[evict burst] post-idle read serviced -- cache stayed live")
