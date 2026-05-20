"""Hit/miss/eviction latency KPIs.

Latency definitions (in clk cycles, measured from posedge to posedge):
  hit_latency_read         : AR-handshake -> first R beat   (cold-hit, line cached, no other traffic)
  miss_latency_read_first  : AR-handshake -> first R beat   (line not cached, mem provides 8 beats)
  miss_latency_read_last   : AR-handshake -> last R beat    (full line returned)
  full_line_writeevict     : AW-handshake -> BVALID         (snoop=101, no RMW)
  rmw_write_single         : AW-handshake -> BVALID         (snoop=0, single-beat, RMW from mem)

We report all numbers and assert against generous upper bounds (the goal is
to FAIL LOUDLY if any path regresses dramatically, not to micro-benchmark).
The bounds are derived from the default config (LINE_W=8, DB_LATENCY=1).
"""
from __future__ import annotations
import cocotb
from cocotb.triggers import RisingEdge, Timer
from tb_common import reset_dut, attach_mem, golden, CLK_PERIOD_NS

BASE        = 0x80000000
BLOCK_BYTES = 4
LINE_W      = 8
LINE_BYTES  = LINE_W * BLOCK_BYTES

# Bounds. These should hold for default config; tighten as the design matures.
HIT_READ_MAX_FIRST     = 8     # AR->first R, hit
MISS_READ_MAX_FIRST    = 40    # AR->first R, miss (incl. mem latency)
MISS_READ_MAX_LAST     = 60    # AR->last  R, miss (8 beats)
WRITEEVICT_MAX_B       = 25    # AW->B, full-line WriteEvict (no RMW, no evict)
RMW_SINGLE_MAX_B       = 50    # AW->B, single-beat write (RMW fill + merge)


async def _cycles_until(dut, sig_test_fn, max_cycles=500):
    """Wait for sig_test_fn(dut) to be true; return cycle count from caller's
    own posedge (i.e. caller already aligned to clock edge)."""
    for c in range(max_cycles):
        await RisingEdge(dut.clk)
        if sig_test_fn(dut):
            return c + 1
    raise TimeoutError("signal did not assert within max_cycles")


async def _ar_first_r(dut, addr, nbeats=1, arid=0):
    """Issue an AR and time AR-handshake -> first R beat.

    Returns (cycles_to_first_R, total_cycles_to_last_R).
    """
    await RisingEdge(dut.clk)
    dut.s_araddr.value   = addr
    dut.s_arlen.value    = nbeats - 1
    dut.s_arsize.value   = 2
    dut.s_arburst.value  = 1
    dut.s_arlock.value   = 0
    dut.s_arcache.value  = 0xF
    dut.s_arprot.value   = 0
    dut.s_arqos.value    = 0
    dut.s_arregion.value = 0
    dut.s_arsnoop.value  = 0
    dut.s_arid.value     = arid
    dut.s_arvalid.value  = 1
    dut.s_rready.value   = 1
    # AR handshake (count cycles waiting for arready)
    while True:
        await RisingEdge(dut.clk)
        if dut.s_arready.value == 1:
            dut.s_arvalid.value = 0
            ar_cycle = 0  # start counting from THIS edge
            break
    cycles_first = None
    cycles_last  = None
    c = 0
    while True:
        await RisingEdge(dut.clk)
        c += 1
        if dut.s_rvalid.value == 1 and dut.s_rready.value == 1:
            if cycles_first is None:
                cycles_first = c
            if dut.s_rlast.value == 1:
                cycles_last = c
                break
    return cycles_first, cycles_last


async def _aw_b_writeevict(dut, addr, awid=0):
    """Time AW-handshake -> BVALID for a full-line WriteEvict."""
    nbeats = LINE_W
    await RisingEdge(dut.clk)
    dut.s_awaddr.value   = addr
    dut.s_awlen.value    = nbeats - 1
    dut.s_awsize.value   = 2
    dut.s_awburst.value  = 1
    dut.s_awlock.value   = 0
    dut.s_awcache.value  = 0xF
    dut.s_awprot.value   = 0
    dut.s_awqos.value    = 0
    dut.s_awregion.value = 0
    dut.s_awsnoop.value  = 0b101       # WriteEvict
    dut.s_awid.value     = awid
    dut.s_awvalid.value  = 1
    dut.s_bready.value   = 1
    while True:
        await RisingEdge(dut.clk)
        if dut.s_awready.value == 1:
            dut.s_awvalid.value = 0
            break
    # Stream nbeats of W
    for i in range(nbeats):
        dut.s_wdata.value  = 0xAAAA0000 | i
        dut.s_wstrb.value  = 0xF
        dut.s_wlast.value  = 1 if (i == nbeats - 1) else 0
        dut.s_wvalid.value = 1
        while True:
            await RisingEdge(dut.clk)
            if dut.s_wready.value == 1:
                break
    dut.s_wvalid.value = 0
    dut.s_wlast.value  = 0
    # Count cycles to BVALID
    c = 0
    while True:
        await RisingEdge(dut.clk)
        c += 1
        if dut.s_bvalid.value == 1 and dut.s_bready.value == 1:
            break
    dut.s_awsnoop.value = 0
    return c


async def _aw_b_rmw_single(dut, addr, awid=0):
    """Time AW-handshake -> BVALID for a single-beat RMW write."""
    await RisingEdge(dut.clk)
    dut.s_awaddr.value   = addr
    dut.s_awlen.value    = 0
    dut.s_awsize.value   = 2
    dut.s_awburst.value  = 1
    dut.s_awlock.value   = 0
    dut.s_awcache.value  = 0xF
    dut.s_awprot.value   = 0
    dut.s_awqos.value    = 0
    dut.s_awregion.value = 0
    dut.s_awsnoop.value  = 0           # plain (RMW)
    dut.s_awid.value     = awid
    dut.s_awvalid.value  = 1
    dut.s_bready.value   = 1
    while True:
        await RisingEdge(dut.clk)
        if dut.s_awready.value == 1:
            dut.s_awvalid.value = 0
            break
    dut.s_wdata.value  = 0xCAFEFEED
    dut.s_wstrb.value  = 0xF
    dut.s_wlast.value  = 1
    dut.s_wvalid.value = 1
    while True:
        await RisingEdge(dut.clk)
        if dut.s_wready.value == 1:
            break
    dut.s_wvalid.value = 0
    dut.s_wlast.value  = 0
    c = 0
    while True:
        await RisingEdge(dut.clk)
        c += 1
        if dut.s_bvalid.value == 1 and dut.s_bready.value == 1:
            break
    return c


@cocotb.test()
async def test_latency_kpis(dut):
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    dut.s_rready.value = 1
    dut.s_bready.value = 1

    addr_miss_a = BASE | 0x00000800   # set=0, tag=1
    addr_miss_b = BASE | 0x00001000   # set=0, tag=2 (different line)
    addr_we     = BASE | 0x00001800   # set=0, tag=3
    addr_rmw    = BASE | 0x00002800   # set=0, tag=5

    # ---- miss (cold) - full line ----
    miss_first, miss_last = await _ar_first_r(dut, addr_miss_a, nbeats=LINE_W, arid=0)
    await Timer(50, "ns")
    # ---- hit (same line, second read) ----
    hit_first, _ = await _ar_first_r(dut, addr_miss_a, nbeats=1, arid=1)
    await Timer(50, "ns")
    # ---- single-beat miss (different line, single beat) ----
    miss_single_first, _ = await _ar_first_r(dut, addr_miss_b, nbeats=1, arid=2)
    await Timer(50, "ns")
    # ---- write-evict ----
    we_b = await _aw_b_writeevict(dut, addr_we, awid=3)
    await Timer(50, "ns")
    # ---- single-beat RMW write ----
    rmw_b = await _aw_b_rmw_single(dut, addr_rmw, awid=4)

    dut._log.info("=" * 60)
    dut._log.info("LATENCY KPIs (cycles, AR/AW handshake -> first response)")
    dut._log.info(f"  miss read first beat   : {miss_first:3d}  (bound {MISS_READ_MAX_FIRST})")
    dut._log.info(f"  miss read last  beat   : {miss_last:3d}  (bound {MISS_READ_MAX_LAST})")
    dut._log.info(f"  hit  read first beat   : {hit_first:3d}  (bound {HIT_READ_MAX_FIRST})")
    dut._log.info(f"  miss single-beat read  : {miss_single_first:3d}")
    dut._log.info(f"  WriteEvict AW->B       : {we_b:3d}  (bound {WRITEEVICT_MAX_B})")
    dut._log.info(f"  RMW single AW->B       : {rmw_b:3d}  (bound {RMW_SINGLE_MAX_B})")
    dut._log.info("=" * 60)

    assert miss_first <= MISS_READ_MAX_FIRST, f"miss first-beat regressed: {miss_first}"
    assert miss_last  <= MISS_READ_MAX_LAST,  f"miss last-beat regressed: {miss_last}"
    assert hit_first  <= HIT_READ_MAX_FIRST,  f"hit  first-beat regressed: {hit_first}"
    assert we_b       <= WRITEEVICT_MAX_B,    f"WriteEvict B regressed: {we_b}"
    assert rmw_b      <= RMW_SINGLE_MAX_B,    f"RMW B regressed: {rmw_b}"
