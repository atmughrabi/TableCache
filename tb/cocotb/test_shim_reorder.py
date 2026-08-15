"""Read reorder-buffer coverage (`READ_REORDER_DEPTH > 1`).

One engine ID is mapped onto distinct cache IDs and responses must return in
issue order despite concurrent and out-of-order completion.
"""
from __future__ import annotations
import os
import cocotb
from cocotb.triggers import RisingEdge, ReadOnly, Timer
from test_shim_multiread import (
    golden, reset_dut, _attach_mem,
    BASE, NARROW_B, BLOCK_B,
)
from tb_common import reset_cycle_count

DEPTH = int(os.environ.get("TC_READ_REORDER_DEPTH", "8"))
LINE_W = int(os.environ.get("TC_LINE_W", "8"))
LINE_B = LINE_W * BLOCK_B          # cache line bytes (LINE_W wide blocks)
ARSIZE = (NARROW_B.bit_length() - 1)


def _distinct_line_addrs(n):
    # n reads, each to a DISTINCT cache line (spaced by a full line) so they land
    # in distinct sets -> the cache's inuse_line does NOT serialize them and they
    # can overlap. Read at a rotating lane within the block so the per-slot offset
    # select is exercised. BLOCK_OFF (env, bytes) shifts reads into a chosen block
    # of the line (e.g. the upper block) to probe which block the cache marks last.
    out = []
    lanes = max(1, BLOCK_B // NARROW_B)
    block_off = int(os.environ.get("BLOCK_OFF", "0"))
    for i in range(n):
        line = BASE | (i * LINE_B)
        out.append(line | block_off | ((i % lanes) * NARROW_B))
    return out


class MSideRidMonitor:
    """Record the order of core-side (cache) read completions by m_rid, to show
    reads completed out of order across distinct core ids. Also tracks the peak
    number of memory-side reads outstanding at once (m_ar accepted but not yet
    m_rlast) -- a race-free proof of true cache-level concurrency, since a cold
    miss keeps its memory read outstanding for many cycles."""
    def __init__(self, dut):
        self.dut = dut
        self.order = []
        self.inflight = 0
        self.peak = 0

    async def run(self):
        while True:
            await RisingEdge(self.dut.clk)
            await ReadOnly()
            if int(self.dut.m_arvalid) and int(self.dut.m_arready):
                self.inflight += 1
                self.peak = max(self.peak, self.inflight)
            if int(self.dut.m_rvalid) and int(self.dut.m_rready) and int(self.dut.m_rlast):
                self.order.append(int(self.dut.m_rid))
                self.inflight -= 1


async def _read_one(dut, addr):
    """Blocking single read on engine id 0 (used to warm lines)."""
    dut.s_araddr.value = addr; dut.s_arid.value = 0; dut.s_arlen.value = 0
    dut.s_arsize.value = ARSIZE; dut.s_arburst.value = 1
    if hasattr(dut, "s_arsnoop"):
        dut.s_arsnoop.value = 0
    dut.s_arvalid.value = 1
    dut.s_rready.value = 1
    for _ in range(4000):
        await ReadOnly()
        if int(dut.s_arready):
            break
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk); dut.s_arvalid.value = 0
    for _ in range(6000):
        await ReadOnly()
        if int(dut.s_rvalid) and int(dut.s_rready):
            break
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_reorder_in_order_concurrency(dut):
    await reset_dut(dut)
    pc_before = int(dut.pc_violations_total.value)
    _attach_mem(dut)                       # seeded backend on m_; no s master
    if hasattr(dut, "s_arsnoop"):
        dut.s_arsnoop.value = 0
    dut.s_rready.value = 1

    mrid = MSideRidMonitor(dut); cocotb.start_soon(mrid.run())

    N = DEPTH
    addrs = _distinct_line_addrs(N)

    # All reads are cold MISSES to distinct lines -> the shim issues a wide AR
    # per read on a distinct core id and the cache overlaps them. The reorder
    # buffer must still deliver strictly in issue order on the single engine id.

    # ---- issue N back-to-back reads, ALL engine id 0 ----
    got = []
    async def r_collector():
        while True:
            await RisingEdge(dut.clk); await ReadOnly()
            if int(dut.s_rvalid) and int(dut.s_rready):
                got.append((int(dut.s_rid) & 0xFFFF_FFFF,
                            int(dut.s_rdata) & ((1 << (NARROW_B*8)) - 1),
                            int(dut.s_rlast)))
    cocotb.start_soon(r_collector())

    def setup_ar(a):
        dut.s_araddr.value = a; dut.s_arid.value = 0; dut.s_arlen.value = 0
        dut.s_arsize.value = ARSIZE; dut.s_arburst.value = 1
        if hasattr(dut, "s_arsnoop"):
            dut.s_arsnoop.value = 0

    setup_ar(addrs[0]); dut.s_arvalid.value = 1
    dut.s_rready.value = 0                 # hold responses so reads accumulate

    # Count engine-side in-flight INSIDE the driving loop (race-free): with
    # s_rready held low no response is ever consumed, so every accepted AR stays
    # outstanding and the running accept count IS the simultaneous in-flight depth.
    idx = 0
    eng_peak = 0
    for _ in range(60_000):
        await ReadOnly()
        acc = int(dut.s_arvalid) and int(dut.s_arready)
        await RisingEdge(dut.clk)
        if acc:
            idx += 1
            eng_peak = idx            # nothing retired yet (s_rready low) -> all outstanding
            if idx >= N:
                dut.s_arvalid.value = 0; break
            setup_ar(addrs[idx])
    assert idx >= N, f"only {idx}/{N} reads accepted (s_arready never freed for >1 in flight)"

    # let the accumulated (out-of-order) completions settle into the ROB, then
    # release the response channel and drain in issue order.
    for _ in range(400):
        await RisingEdge(dut.clk)
    dut.s_rready.value = 1

    # drain N responses
    for _ in range(60_000):
        await RisingEdge(dut.clk)
        if len(got) >= N:
            break
    assert len(got) >= N, f"only {len(got)}/{N} responses returned"
    for _ in range(50):
        await RisingEdge(dut.clk)
    assert len(got) == N, (
        f"expected exactly {N} responses, got {len(got)} "
        "(duplicate/trailing response escaped the reorder buffer)")

    # Responses carry the engine ID and remain in issue order.
    for k in range(N):
        rid, data, last = got[k]
        assert rid == 0, f"response {k} has rid={rid}, expected engine id 0"
        assert last == 1, f"response {k} has rlast={last}, expected single-beat rlast=1"
        exp = golden(addrs[k])
        assert data == exp, (
            f"OUT-OF-ORDER/wrong data at response {k}: got 0x{data:08x} "
            f"exp 0x{exp:08x} for addr 0x{addrs[k]:08x} -- reorder buffer failed")
    # Both the engine-facing queue and cache-side reads must overlap.
    assert eng_peak > 1, (
        f"engine did NOT keep >1 read outstanding (eng_peak={eng_peak}); the "
        f"reorder buffer did not lift the 1-outstanding-per-id serialization")
    assert mrid.peak > 1, (
        f"cache did NOT service >1 memory read concurrently (m-side peak="
        f"{mrid.peak}); reads were serialized")
    for _ in range(10):
        await RisingEdge(dut.clk)
    pc_after = int(dut.pc_violations_total.value)
    assert pc_after == pc_before, (
        f"AXI protocol violations during reorder concurrency: "
        f"before={pc_before} after={pc_after}")
    dut._log.info(
        f"[shim reorder] N={N}: in-order OK, engine peak outstanding={eng_peak}, "
        f"cache memory-read peak concurrency={mrid.peak}, m-side completion order "
        f"(by m_rid) during burst={mrid.order[-N:]}")


@cocotb.test()
async def test_reorder_out_of_order_completion(dut):
    """A cold head miss must hold faster trailing hits until it completes."""
    from cocotb.utils import get_sim_time

    N = DEPTH
    if N < 2:
        return  # passthrough depth: nothing to reorder

    await reset_dut(dut)
    pc_before = int(dut.pc_violations_total.value)
    _attach_mem(dut)
    if hasattr(dut, "s_arsnoop"):
        dut.s_arsnoop.value = 0
    dut.s_rready.value = 1

    addrs = _distinct_line_addrs(N)
    # Warm every line EXCEPT the head so reads 1..N-1 are hits and read 0 is a
    # cold miss. (Distinct sets -> no eviction of each other.)
    for a in addrs[1:]:
        await _read_one(dut, a)

    # ---- timing taps: head miss memory completion vs first engine response ----
    taps = {"miss_rlast_t": None, "first_s_r_t": None, "miss_rid": None}
    core_done = []

    async def _mem_watch():
        while True:
            await RisingEdge(dut.clk); await ReadOnly()
            if (int(dut.m_rvalid) and int(dut.m_rready) and int(dut.m_rlast)
                    and taps["miss_rlast_t"] is None):
                taps["miss_rlast_t"] = get_sim_time("ns")
                taps["miss_rid"] = int(dut.m_rid)

    got = []

    async def _eng_watch():
        while True:
            await RisingEdge(dut.clk); await ReadOnly()
            if int(dut.s_rvalid) and int(dut.s_rready):
                if taps["first_s_r_t"] is None:
                    taps["first_s_r_t"] = get_sim_time("ns")
                got.append((int(dut.s_rid),
                            int(dut.s_rdata) & ((1 << (NARROW_B*8)) - 1),
                            int(dut.s_rlast)))

    async def _core_watch():
        while True:
            await RisingEdge(dut.clk); await ReadOnly()
            if int(dut.c_rvalid) and int(dut.c_rready) and int(dut.c_rlast):
                core_done.append((
                    int(dut.c_rid),
                    int(dut.c_rdata) & ((1 << (NARROW_B*8)) - 1)))

    cocotb.start_soon(_mem_watch())
    cocotb.start_soon(_eng_watch())
    cocotb.start_soon(_core_watch())

    def setup_ar(a):
        dut.s_araddr.value = a; dut.s_arid.value = 0; dut.s_arlen.value = 0
        dut.s_arsize.value = ARSIZE; dut.s_arburst.value = 1
        if hasattr(dut, "s_arsnoop"):
            dut.s_arsnoop.value = 0

    # issue all N back-to-back on engine id 0 (head cold, rest warm)
    setup_ar(addrs[0]); dut.s_arvalid.value = 1
    idx = 0
    for _ in range(60_000):
        await ReadOnly()
        acc = int(dut.s_arvalid) and int(dut.s_arready)
        await RisingEdge(dut.clk)
        if acc:
            idx += 1
            if idx >= N:
                dut.s_arvalid.value = 0; break
            setup_ar(addrs[idx])
    assert idx >= N, f"only {idx}/{N} reads accepted"

    for _ in range(60_000):
        await RisingEdge(dut.clk)
        if len(got) >= N:
            break
    assert len(got) >= N, f"only {len(got)}/{N} responses returned"
    for _ in range(50):
        await RisingEdge(dut.clk)
    assert len(got) == N, (
        f"expected exactly {N} responses, got {len(got)} "
        "(duplicate/trailing response escaped the reorder buffer)")

    # Require issue-order delivery despite out-of-order cache completion.
    for k in range(N):
        rid, data, last = got[k]
        assert rid == 0, f"response {k} rid={rid} != engine id 0"
        assert last == 1, f"response {k} has rlast={last}, expected single-beat rlast=1"
        exp = golden(addrs[k])
        assert data == exp, (
            f"OUT-OF-ORDER/wrong data at response {k}: got 0x{data:08x} exp "
            f"0x{exp:08x} for addr 0x{addrs[k]:08x} -- reorder failed; "
            f"core completions={core_done}")
    # The head miss must hold later hit responses until memory completion.
    assert taps["miss_rlast_t"] is not None, (
        "head read did not miss to memory -- test did not create a miss/hit split")
    assert taps["first_s_r_t"] is not None
    assert taps["first_s_r_t"] >= taps["miss_rlast_t"], (
        f"engine saw a response at t={taps['first_s_r_t']}ns BEFORE the head miss "
        f"completed at t={taps['miss_rlast_t']}ns -- a trailing hit bypassed the "
        f"head; the ROB did not reorder")
    for _ in range(10):
        await RisingEdge(dut.clk)
    pc_after = int(dut.pc_violations_total.value)
    assert pc_after == pc_before, (
        f"AXI protocol violations during out-of-order completion: "
        f"before={pc_before} after={pc_after}")
    dut._log.info(
        f"[shim reorder OoO] N={N}: head miss (mem id {taps['miss_rid']}) done @"
        f"{taps['miss_rlast_t']}ns, first engine response @{taps['first_s_r_t']}ns "
        f"-> {N-1} trailing hits held behind the pending head, delivered in order")


@cocotb.test(skip=DEPTH <= 1)
async def test_reorder_pending_response_drops_valid_on_reset(dut):
    await reset_dut(dut)
    _attach_mem(dut)
    dut.s_rready.value = 0

    dut.s_araddr.value = BASE
    dut.s_arid.value = 0
    dut.s_arlen.value = 0
    dut.s_arsize.value = ARSIZE
    dut.s_arburst.value = 1
    if hasattr(dut, "s_arsnoop"):
        dut.s_arsnoop.value = 0
    dut.s_arvalid.value = 1
    for _ in range(4000):
        await RisingEdge(dut.clk)
        if int(dut.s_arready):
            await Timer(1, units="ps")
            dut.s_arvalid.value = 0
            break
    else:
        raise AssertionError("reorder reset test AR was not accepted")

    for _ in range(6000):
        await RisingEdge(dut.clk)
        if int(dut.s_rvalid):
            break
    else:
        raise AssertionError("reorder response did not become pending")

    dut.rst.value = 1
    await Timer(1, units="ps")
    assert not int(dut.s_rvalid)
    await RisingEdge(dut.clk)
    assert not int(dut.s_rvalid)

    for _ in range(reset_cycle_count() - 1):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    dut.s_rready.value = 1
    await RisingEdge(dut.clk)
    await _read_one(dut, BASE + LINE_B)
    assert int(dut.pc_violations_total.value) == 0
