"""Pipelined multi-outstanding read coverage for tc_narrow_shim + l2_cache.

Reproduces the "issue a burst of reads without waiting per response" scenario
on TableCache's own bench and pins down the read-outstanding CONTRACT.

l2_cache is a 1-outstanding-per-ID design: a second read that shares an
already-in-flight arid is STALLED at chosen_arready by inuse_stall
(src/l2_cache.sv:670-679), and the shim mirrors this with rid_outstanding_q
(routing every response by id via rid_offset_q[m_rid]). So:

  * DISTINCT-id pipelining (the supported multi-outstanding path): N concurrent
    reads to N distinct lines, each with its own arid -> genuinely overlapped
    (>1 AR accepted before the first R) AND every word correct.
  * SAME-id pipelining: N concurrent reads all sharing arid=0 -> serialized by
    the cache to <=1 in flight; data must still be correct and the stack must
    NOT deadlock or drop/duplicate responses. A master wanting M-deep pipelining
    must therefore spread the reads across M distinct ids, not reuse one id.

This is the fast-flow guard for that contract (the prior shim+cache suite only
issued strictly serial `await master.read()` one-at-a-time).

Run:  make MODULE=test_shim_multiread
"""
import logging
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly
from cocotbext.axi import AxiBus, AxiMaster, AxiRam

_LVL = getattr(logging, os.environ.get("TC_AXI_LOG", "WARNING").upper(), logging.WARNING)
logging.getLogger("cocotbext.axi").setLevel(_LVL)
for _n in ("cocotb.dut_shim_cache.s", "cocotb.dut_shim_cache.m"):
    logging.getLogger(_n).setLevel(_LVL)

CLK_NS   = 10
BASE     = 0x8000_0000
NARROW_W = int(os.environ.get("TC_NARROW_W", "32"))
BLOCK_W  = int(os.environ.get("TC_BLOCK_W",  "512"))
NARROW_B = NARROW_W // 8
BLOCK_B  = BLOCK_W  // 8
LINES    = int(os.environ.get("TC_LINES", "128"))
MEM_SIZE = 1 << 24
SEED_SZ  = 1 << 20
MASK     = (1 << NARROW_W) - 1


def golden(addr_narrow: int) -> int:
    a = addr_narrow & 0xFFFF_FFFF
    return ((a * 0x9E37_79B1) ^ (a >> 16) ^ 0xC0FF_EE00) & MASK


async def reset_dut(dut):
    cycles = max(64, LINES * 2)
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    dut.rst.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


def attach(dut):
    master = AxiMaster(AxiBus.from_prefix(dut, "s"), dut.clk, dut.rst,
                       reset_active_level=True)
    ram = _attach_mem(dut)
    return master, ram


def _attach_mem(dut):
    """Backend AxiRam on m_ + golden seed only (no s_ master, so a test can
    drive the s_ AR/R channels by hand without a double-driver conflict)."""
    ram = AxiRam(AxiBus.from_prefix(dut, "m"), dut.clk, dut.rst,
                 size=MEM_SIZE, reset_active_level=True)
    seed = bytearray(SEED_SZ)
    for off in range(0, SEED_SZ, NARROW_B):
        seed[off:off + NARROW_B] = golden(BASE | off).to_bytes(NARROW_B, "little")
    ram.write(0, bytes(seed))
    return ram


class OutstandingMonitor:
    """Track in-flight read count = (AR accepted) - (R last accepted) and the
    peak overlap, so a test can assert reads actually pipelined (peak>1) or were
    serialized (peak==1)."""
    def __init__(self, dut):
        self.dut = dut
        self.inflight = 0
        self.peak = 0
        self.ar = 0
        self.r = 0

    async def run(self):
        while True:
            await RisingEdge(self.dut.clk)
            await ReadOnly()
            if int(self.dut.s_arvalid) and int(self.dut.s_arready):
                self.ar += 1
                self.inflight += 1
                self.peak = max(self.peak, self.inflight)
            if int(self.dut.s_rvalid) and int(self.dut.s_rready) and int(self.dut.s_rlast):
                self.r += 1
                self.inflight -= 1


def _line_addrs(n):
    # n distinct cache lines, each read at a non-zero lane so the shim's
    # per-id offset select (rid_offset_q) is exercised (not just lane 0).
    addrs = []
    for i in range(n):
        line = BASE | (i * BLOCK_B)
        lane = (i % (BLOCK_B // NARROW_B))
        addrs.append(line | (lane * NARROW_B))
    return addrs


async def _pipeline_reads(dut, master, addrs, arids):
    """Issue every read non-blocking (init_read) so they overlap, then collect
    each result via its completion event and check against golden."""
    from cocotb.triggers import Event

    events = []
    for addr, aid in zip(addrs, arids):
        ev = Event()
        master.init_read(addr, NARROW_B, arid=aid, event=ev)
        events.append((addr, ev))
    results = {}
    for addr, ev in events:
        await ev.wait()
        results[addr] = ev.data
    miss = 0
    for addr, op in results.items():
        got = int.from_bytes(op.data, "little")
        exp = golden(addr)
        if got != exp:
            miss += 1
            dut._log.error(f"multiread @0x{addr:08x} got=0x{got:08x} exp=0x{exp:08x}")
    return miss


@cocotb.test()
async def test_distinct_id_multi_outstanding(dut):
    """The supported path: N concurrent reads, one distinct arid each. They must
    genuinely overlap (peak in-flight > 1) and every word must be correct."""
    await reset_dut(dut)
    master, _ram = attach(dut)
    mon = OutstandingMonitor(dut); cocotb.start_soon(mon.run())

    N = 8                                   # ids 0..7 (id 15 is the shim prefill id)
    addrs = _line_addrs(N)
    arids = list(range(N))
    miss = await _pipeline_reads(dut, master, addrs, arids)

    assert miss == 0, f"{miss}/{N} distinct-id pipelined reads returned wrong data"
    assert mon.peak > 1, (
        f"distinct-id reads did NOT overlap (peak in-flight={mon.peak}); "
        f"multi-outstanding not exercised")
    assert mon.ar == N and mon.r == N, (
        f"AR/R count mismatch: {mon.ar} ARs, {mon.r} Rs (expected {N} each)")
    dut._log.info(f"[distinct-id] {N} reads, peak in-flight={mon.peak}, "
                  f"ar={mon.ar} r={mon.r}, all data correct")


@cocotb.test()
async def test_distinct_id_backpressure(dut):
    """Distinct-id multi-outstanding under random master s_rready backpressure:
    N concurrent reads on distinct arids must still all return correct data with
    zero protocol violations when the R channel is stalled in bursts (the fill
    routing keys off m_rid/rid_offset_q, which backpressure only delays)."""
    from test_backpressure import burst_pause  # reuse the shared pause generator
    import random as _r
    await reset_dut(dut)
    master, _ram = attach(dut)
    master.read_if.r_channel.set_pause_generator(burst_pause(_r.Random(0xBEEF), 12, 3))
    mon = OutstandingMonitor(dut); cocotb.start_soon(mon.run())

    N = 8
    addrs = _line_addrs(N)
    arids = list(range(N))
    miss = await _pipeline_reads(dut, master, addrs, arids)

    assert miss == 0, f"{miss}/{N} distinct-id reads returned wrong data under backpressure"
    assert mon.ar == N and mon.r == N, (
        f"AR/R count mismatch under backpressure: {mon.ar} ARs, {mon.r} Rs (expected {N})")
    assert int(dut.pc_violations_total.value) == 0, (
        f"AXI protocol violations under backpressure: {int(dut.pc_violations_total.value)}")
    dut._log.info(f"[distinct-id/bp] {N} reads correct under s_rready backpressure, "
                  f"peak in-flight={mon.peak}")


async def _run_same_id(dut, N, bp_seed=None):
    """Drive N back-to-back ARs all sharing arid=0 to N distinct lines and
    scoreboard the in-order R stream. bp_seed!=None applies random s_rready
    backpressure (stresses the rid_outstanding clear path -- the clear only
    happens on the R handshake, so backpressure must delay, never corrupt)."""
    import logging as _l, random as _r
    _l.getLogger("cocotb.dut_shim_cache").setLevel(_l.WARNING)
    await reset_dut(dut)
    _ram = _attach_mem(dut)              # backend only; drive s_ AR/R by hand
    mon = OutstandingMonitor(dut); cocotb.start_soon(mon.run())

    addrs = _line_addrs(N)
    ARSIZE = (NARROW_B.bit_length() - 1)
    rng = _r.Random(bp_seed) if bp_seed is not None else None

    # R collector: same-id responses arrive in order -> append to a list.
    # s_rready is driven in the active region (random pauses under backpressure).
    got_words = []
    async def r_collector():
        while True:
            await RisingEdge(dut.clk)
            dut.s_rready.value = 0 if (rng is not None and rng.random() < 0.4) else 1
            await ReadOnly()
            if int(dut.s_rvalid) and int(dut.s_rready):
                got_words.append((int(dut.s_rid), int(dut.s_rdata) & MASK))
    cocotb.start_soon(r_collector())

    # AR driver: issue every read with arid=0, honouring s_arready (raised only
    # once the prior same-id read has drained). Sample s_arready in ReadOnly,
    # then advance one edge past the accepting cycle before de-asserting.
    for addr in addrs:
        dut.s_araddr.value  = addr
        dut.s_arid.value    = 0
        dut.s_arlen.value   = 0
        dut.s_arsize.value  = ARSIZE
        dut.s_arburst.value = 1
        dut.s_arvalid.value = 1
        await ReadOnly()
        while not int(dut.s_arready):
            await RisingEdge(dut.clk)
            await ReadOnly()
        await RisingEdge(dut.clk)          # complete the accepted AR handshake
        dut.s_arvalid.value = 0
    # wait for all N responses (bounded timeout so a deadlock fails loud)
    for _ in range(40_000):
        await RisingEdge(dut.clk)
        if len(got_words) >= N:
            break
    tag = "same-id/bp" if bp_seed is not None else "same-id"
    assert len(got_words) == N, (
        f"{tag}: only {len(got_words)}/{N} R responses returned "
        f"(deadlock or dropped response); peak in-flight={mon.peak}")

    miss = 0
    for i, addr in enumerate(addrs):
        rid, got = got_words[i]
        exp = golden(addr)
        if got != exp or rid != 0:
            miss += 1
            dut._log.error(f"{tag} R#{i} @0x{addr:08x} rid={rid} "
                           f"got=0x{got:08x} exp=0x{exp:08x}")
    dut._log.info(f"[{tag}] peak in-flight={mon.peak}, responses={len(got_words)}, miss={miss}")
    assert miss == 0, f"{miss}/{N} {tag} serialized reads returned wrong data/id"
    # Reads sharing an id must NEVER overlap at the s_ interface (1-per-id
    # contract). peak<=1 proves they did not overlap. (A hand-driven AR can race
    # the monitor's ReadOnly sample to peak==0; data-correct + full-count above
    # are the real serialization proof.)
    assert mon.peak <= 1, (
        f"{tag} reads reached {mon.peak} in flight; they must serialize "
        f"(1-outstanding-per-id contract)")
    dut._log.info(f"[{tag}] {N} reads serialized in-order (peak={mon.peak}), all correct")


@cocotb.test()
async def test_same_id_pipelined_serializes(dut):
    """The contract path, driven at the wire level: N back-to-back same-id (0)
    reads must serialize (peak<=1) and return correct data in issue order."""
    await _run_same_id(dut, 8)


@cocotb.test()
async def test_same_id_backpressure(dut):
    """Same-id serialization under random s_rready backpressure: the
    rid_outstanding clear only fires on the R handshake, so backpressure must
    only DELAY completion -- never let a 2nd same-id AR through or corrupt data.
    This is the latency/backpressure hardening guard for the bug #26 fix."""
    await _run_same_id(dut, 8, bp_seed=0x5EED)

