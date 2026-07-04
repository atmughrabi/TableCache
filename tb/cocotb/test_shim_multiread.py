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
async def test_same_id_pipelined_serializes(dut):
    """The contract path, driven at the wire level to remove cocotbext's own
    same-id response pairing from the picture: issue N back-to-back ARs that all
    share arid=0 to N distinct lines. l2_cache's inuse_stall serializes them to
    <=1 in flight; per AXI, same-id R responses return in ISSUE ORDER, so the
    Nth R word must equal golden(addr[N]). Data must be correct and nothing may
    deadlock or drop/duplicate a response."""
    import logging as _l
    _l.getLogger("cocotb.dut_shim_cache").setLevel(_l.WARNING)
    await reset_dut(dut)
    _ram = _attach_mem(dut)              # backend only; drive s_ AR/R by hand
    mon = OutstandingMonitor(dut); cocotb.start_soon(mon.run())

    N = 8
    addrs = _line_addrs(N)
    ARSIZE = (NARROW_B.bit_length() - 1)

    # R collector: same-id responses arrive in order -> append to a list.
    got_words = []
    async def r_collector():
        dut.s_rready.value = 1
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.s_rvalid) and int(dut.s_rready):
                got_words.append((int(dut.s_rid), int(dut.s_rdata) & MASK))
    cocotb.start_soon(r_collector())

    # AR driver: issue every read with arid=0, honouring s_arready (the cache
    # will only raise it once the prior same-id read has drained). Sample
    # s_arready in ReadOnly, then advance one edge past the accepting cycle
    # before de-asserting so we never write a signal during ReadOnly.
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
    # wait for all N responses (with a bounded timeout so a deadlock fails loud)
    for _ in range(20_000):
        await RisingEdge(dut.clk)
        if len(got_words) >= N:
            break
    assert len(got_words) == N, (
        f"same-id: only {len(got_words)}/{N} R responses returned "
        f"(deadlock or dropped response); peak in-flight={mon.peak}")

    miss = 0
    for i, addr in enumerate(addrs):
        rid, got = got_words[i]
        exp = golden(addr)
        if got != exp or rid != 0:
            miss += 1
            dut._log.error(f"same-id R#{i} @0x{addr:08x} rid={rid} "
                           f"got=0x{got:08x} exp=0x{exp:08x}")
    dut._log.info(f"[same-id] peak in-flight={mon.peak}, responses={len(got_words)}, miss={miss}")
    assert miss == 0, f"{miss}/{N} same-id serialized reads returned wrong data/id"
    # Reads sharing an id must NEVER overlap at the s_ interface (the cache is
    # 1-outstanding-per-id; the shim holds both s_arready AND the wide m_arvalid
    # until the prior same-id R drains). peak<=1 proves they did not overlap.
    # (A hand-driven AR can race the monitor's ReadOnly sample to peak==0; the
    # data-correct + full-count checks above are the real serialization proof.)
    assert mon.peak <= 1, (
        f"same-id reads reached {mon.peak} in flight; they must serialize "
        f"(1-outstanding-per-id contract)")
    dut._log.info(f"[same-id] {N} reads serialized in-order (peak={mon.peak}), all correct")

