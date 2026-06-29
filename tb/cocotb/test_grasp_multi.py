"""Directed tests for GRASP with MULTIPLE address windows per reuse class.

Exercises the GRASP_HIGH_REGIONS / GRASP_MODERATE_REGIONS generalization:
each reuse class is now N independent [_l, _h] windows packed into a
flattened bus (window i = bits [i*32 +: 32]).  The single-window behaviour
(GRASP_HIGH_REGIONS=1) is covered by test_grasp.py; this module proves the
N>1 path and that window i>0 is independently effective.

REQUIRED BUILD (the region ports widen with these defines):
    make MODULE=test_grasp_multi POLICY=GRASP \
         GRASP_HIGH_REGIONS=2 GRASP_MODERATE_REGIONS=2

Pressure model (from test_grasp_moderate.py, the pattern that actually
evicts): conflicting lines are placed SET_STRIDE = LINES*LINE_BYTES apart so
they collide in ONE cache set.  WAYS+1 such lines force an eviction, so an
unpinned/cold line (RRPV=MAX) is evicted while a pinned (RRPV=0) line
survives.

Hit/miss oracle: this module uses its OWN inline mem-AR watcher
(_read_classify) rather than test_grasp._read_and_classify.  The latter
starts a single background counter coroutine and caches it on the dut;
cocotb kills per-test coroutines at test end, so from the 2nd test in a
module onward that counter is dead and silently reports HIT for everything.
A multi-test module that asserts a MISS (the fallback case) needs a
per-read watcher that is alive during the read.

Coverage:
  - two lines in different sets, each pinned by its OWN high window, both
    survive same-set cold conflict (proves high_hit[1], not just [0])
  - a disabled window (_h=0) must NOT match: the line covered only by the
    unused window is evicted (proves OR-reduction stays 0 for empty slots)
  - a high window and a separate moderate window coexist and both retain
    their line (high precedence holds where high overlaps moderate)
  - all windows disabled -> SRRIP-FP fallback genuinely evicts (proves the
    multi-window OR-reduction collapses to the no-region path)
"""
from __future__ import annotations
import os
import cocotb
from cocotb.triggers import RisingEdge
from tb_common import reset_dut, attach_mem
from test_grasp import BASE, _drive_read

# Cache geometry from the build env so the set-aliased pressure model adapts
# to LINES/WAYS/LINE_W (the bare-cocotb path is BLOCK_W=32 = 4 bytes/word).
BLOCK_BYTES = 4
LINES = int(os.environ.get("TC_LINES", "64"))
WAYS  = int(os.environ.get("TC_WAYS",  "4"))
LINE_BYTES = int(os.environ.get("TC_LINE_W", "8")) * BLOCK_BYTES
SET_STRIDE = LINES * LINE_BYTES          # one full way: same line index, new tag
N_CONFLICT = WAYS + 1                     # WAYS+1 same-set lines force >=1 evict

# Two pinned lines living in DIFFERENT sets so each faces its own conflict
# storm without interfering with the other. _line(set_idx, slot) returns the
# address of the slot-th distinct line (tag) that maps to cache set set_idx.
SET_A = 0
SET_B = 4


def _line(set_idx, slot=0):
    return BASE + (set_idx * LINE_BYTES) + (slot * SET_STRIDE)


def _window(addr):
    """Tight [_l, _h] covering exactly the one line at addr."""
    return (addr, addr + LINE_BYTES - 1)


def _require_policy():
    pol = os.environ.get("TC_POLICY_NAME", "GRASP")
    assert pol == "GRASP", f"This test requires POLICY=GRASP, got {pol}"


def _require_windows(dut, n_high=2, n_mod=2):
    """Fail loudly if the DUT was not built with enough windows, instead of
    silently truncating packed values into a too-narrow port."""
    hw = len(dut.grasp_high_addr_l.value)
    mw = len(dut.grasp_moderate_addr_l.value)
    assert hw >= n_high * 32, (
        f"DUT built with only {hw // 32} high window(s); this test needs "
        f">= {n_high}. Rebuild with GRASP_HIGH_REGIONS={n_high} "
        f"(rm -rf sim_build first)."
    )
    assert mw >= n_mod * 32, (
        f"DUT built with only {mw // 32} moderate window(s); this test needs "
        f">= {n_mod}. Rebuild with GRASP_MODERATE_REGIONS={n_mod}."
    )


def _pack(windows, n_slots):
    """Pack (lo, hi) tuples into (lo_bus, hi_bus); window i at bits [i*32 +: 32].
    Unused slots stay 0 (disabled)."""
    lo_bus = hi_bus = 0
    for i, (lo, hi) in enumerate(windows):
        assert i < n_slots, "more windows than the DUT was built for"
        lo_bus |= (lo & 0xFFFFFFFF) << (i * 32)
        hi_bus |= (hi & 0xFFFFFFFF) << (i * 32)
    return lo_bus, hi_bus


def _set_windows(dut, highs=None, mods=None):
    """Drive the packed high/moderate window buses."""
    highs = highs or []
    mods = mods or []
    n_high = len(dut.grasp_high_addr_l.value) // 32
    n_mod = len(dut.grasp_moderate_addr_l.value) // 32
    hl, hh = _pack(highs, n_high)
    ml, mh = _pack(mods, n_mod)
    dut.grasp_high_addr_l.value = hl
    dut.grasp_high_addr_h.value = hh
    dut.grasp_moderate_addr_l.value = ml
    dut.grasp_moderate_addr_h.value = mh


async def _read_classify(dut, addr):
    """Drive one single-beat read and return True iff it HIT (no mem-AR fired).
    Uses a per-read watcher coroutine that is alive for the whole read, so it
    reliably catches the 1-cycle m_arvalid&m_arready handshake of a miss."""
    saw_miss = {"v": False}

    async def _watch():
        while True:
            await RisingEdge(dut.clk)
            if int(dut.m_arvalid.value) and int(dut.m_arready.value):
                saw_miss["v"] = True

    w = cocotb.start_soon(_watch())
    await _drive_read(dut, addr)
    for _ in range(8):              # settle: a late fill-AR still counts
        await RisingEdge(dut.clk)
    w.kill()
    return not saw_miss["v"]


async def _thrash_set(dut, set_idx):
    """Read N_CONFLICT distinct lines that all map to set_idx (slots 1..N),
    forcing eviction pressure in that set. Slot 0 is the line under test."""
    for k in range(1, N_CONFLICT + 1):
        await _drive_read(dut, _line(set_idx, k))


@cocotb.test()
async def test_grasp_multi_two_hot_buffers_pinned(dut):
    """Two lines in different sets, each pinned by its OWN high window, both
    survive a same-set conflict storm. The B assertion exercises high_hit[1]
    -- the second window's match path -- which window 0 alone cannot cover."""
    _require_policy()
    _require_windows(dut)
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 22)

    a, b = _line(SET_A), _line(SET_B)
    _set_windows(dut, highs=[_window(a), _window(b)])

    await _drive_read(dut, a)          # insert A via high window 0 -> RRPV 0
    await _drive_read(dut, b)          # insert B via high window 1 -> RRPV 0
    await _thrash_set(dut, SET_A)      # evict everything unpinned in set A
    await _thrash_set(dut, SET_B)      # evict everything unpinned in set B

    a_hit = await _read_classify(dut, a)
    b_hit = await _read_classify(dut, b)
    dut._log.info(f"two high windows: A {'HIT' if a_hit else 'MISS'}  "
                  f"B {'HIT' if b_hit else 'MISS'}")
    assert a_hit, "line A (high window 0) was evicted despite being pinned"
    assert b_hit, ("line B (high window 1) was evicted -- the second high "
                   "window did not pin it (high_hit[1] ineffective)")


@cocotb.test()
async def test_grasp_multi_disabled_window_does_not_match(dut):
    """Populate ONLY high window 0 (covering A); leave window 1 disabled
    (_h=0). B is in no window and must be evicted, proving a disabled slot
    does not spuriously match (its high_hit bit stays 0 in the OR-reduce)."""
    _require_policy()
    _require_windows(dut)
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 22)

    a, b = _line(SET_A), _line(SET_B)
    _set_windows(dut, highs=[_window(a)])   # slot 1 left (0,0) = disabled

    await _drive_read(dut, a)
    await _drive_read(dut, b)
    await _thrash_set(dut, SET_A)
    await _thrash_set(dut, SET_B)

    a_hit = await _read_classify(dut, a)
    b_hit = await _read_classify(dut, b)
    dut._log.info(f"one window only: A(pinned) {'HIT' if a_hit else 'MISS'}  "
                  f"B(unpinned) {'HIT' if b_hit else 'MISS'}")
    assert a_hit, "pinned line A (window 0) was evicted"
    assert not b_hit, ("unpinned line B survived -- a disabled window (_h=0) "
                       "must not match (OR-reduction should keep its bit 0)")


@cocotb.test()
async def test_grasp_multi_high_and_moderate_coexist(dut):
    """A high window and a separate moderate window are both effective at the
    same time, and high precedence holds where high overlaps moderate.
    high window 0 + moderate window 0 both cover A (overlap -> high wins);
    moderate window 1 independently covers B. Under a single WAYS+1 conflict
    both A (RRPV 0) and B (RRPV 1, below the cold RRPV MAX) are retained."""
    _require_policy()
    _require_windows(dut)
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 22)

    a, b = _line(SET_A), _line(SET_B)
    _set_windows(dut, highs=[_window(a)], mods=[_window(a), _window(b)])

    await _drive_read(dut, a)          # high+moderate overlap -> high -> RRPV 0
    await _drive_read(dut, b)          # moderate window 1 -> RRPV 1
    await _thrash_set(dut, SET_A)
    await _thrash_set(dut, SET_B)

    a_hit = await _read_classify(dut, a)
    b_hit = await _read_classify(dut, b)
    dut._log.info(f"high+moderate: A(high) {'HIT' if a_hit else 'MISS'}  "
                  f"B(moderate win1) {'HIT' if b_hit else 'MISS'}")
    assert a_hit, "line A not retained under high+moderate overlap (high should pin)"
    assert b_hit, ("line B not retained -- moderate window 1 (RRPV 1) should "
                   "outlive the cold RRPV-MAX conflict lines")


@cocotb.test()
async def test_grasp_multi_all_disabled_fallback(dut):
    """All windows in both classes disabled -> GRASP collapses to SRRIP-FP and
    the conflict storm DOES evict the unpinned line. This is the discriminating
    counterpart to the pinned tests: proves the multi-window OR-reduction
    yields 0/0 (no pinning) when nothing is configured."""
    _require_policy()
    _require_windows(dut)
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 22)

    a = _line(SET_A)
    _set_windows(dut)                  # everything 0 -> SRRIP-FP fallback

    await _drive_read(dut, a)          # cold insert at RRPV MAX (no region)
    await _thrash_set(dut, SET_A)      # WAYS+1 same-set lines evict A

    a_hit = await _read_classify(dut, a)
    dut._log.info(f"all-disabled fallback: A {'HIT' if a_hit else 'MISS'}")
    assert not a_hit, ("line A survived with all windows disabled -- GRASP "
                       "should fall back to SRRIP-FP and evict the cold line")
    assert int(dut.pc_violations_total.value) == 0


@cocotb.test()
async def test_grasp_multi_highest_high_window(dut):
    """Pin a buffer using the HIGHEST high-window slot (index n_high-1), with
    every lower slot disabled. Proves an ARBITRARY window index is effective,
    not just slot 1. At the default 2-window build this is slot 1; at larger
    builds (e.g. GRASP_HIGH_REGIONS=8) it exercises the top slot (window 7)."""
    _require_policy()
    _require_windows(dut)
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 22)

    n_high = len(dut.grasp_high_addr_l.value) // 32
    top = n_high - 1
    a = _line(SET_A)
    lo, hi = _window(a)
    # Place A's window in the TOP slot; all lower slots stay 0 (disabled).
    dut.grasp_high_addr_l.value = (lo & 0xFFFFFFFF) << (top * 32)
    dut.grasp_high_addr_h.value = (hi & 0xFFFFFFFF) << (top * 32)
    dut.grasp_moderate_addr_l.value = 0
    dut.grasp_moderate_addr_h.value = 0

    await _drive_read(dut, a)
    await _thrash_set(dut, SET_A)

    a_hit = await _read_classify(dut, a)
    dut._log.info(f"highest high window (slot {top} of {n_high}): "
                  f"A {'HIT' if a_hit else 'MISS'}")
    assert a_hit, (f"line A pinned by the top high window (slot {top}) was "
                   f"evicted -- a non-zero window index is not effective")
