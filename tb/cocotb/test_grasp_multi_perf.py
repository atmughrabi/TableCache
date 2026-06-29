"""Performance demonstration for the GRASP multi-window feature.

Quantifies the hit-rate benefit of pinning MULTIPLE buffers. A workload with
NBUF disjoint hot buffers (one per cache set) is re-referenced across several
rounds, each round preceded by a same-set conflict storm that evicts anything
unpinned. Hit rate is measured under three GRASP configurations:

  A. fallback     - no region windows         -> hot buffers get thrashed
  B. single       - 1 high window (buffer 0)  -> only buffer 0 survives
  C. multi        - NBUF high windows (all)    -> every buffer survives

Expected ranking C > B > A, with A ~ 0 %, B ~ 1/NBUF, C ~ 100 %. This is the
core value proposition of the N-window generalization: one wide window cannot
pin NBUF disjoint buffers without also pinning the cold span between them.

REQUIRED BUILD:
    make MODULE=test_grasp_multi_perf POLICY=GRASP GRASP_HIGH_REGIONS=4
"""
from __future__ import annotations
import os
import cocotb
from tb_common import reset_dut, attach_mem
from test_grasp import BASE, _drive_read
from test_grasp_multi import (
    _line, _window, _set_windows, _read_classify, _thrash_set,
    _require_policy, WAYS, LINE_BYTES,
)

NBUF   = int(os.environ.get("NBUF", "4"))      # hot buffers (needs HR >= NBUF)
ROUNDS = int(os.environ.get("ROUNDS", "8"))


async def _measure(dut, highs):
    """Warm every buffer, then ROUNDS x (thrash all sets, re-read all buffers).
    Returns (hits, total) over the re-reads."""
    _set_windows(dut, highs=highs)
    bufs = [_line(s) for s in range(NBUF)]
    for b in bufs:
        await _drive_read(dut, b)
    hits = total = 0
    for _ in range(ROUNDS):
        for s in range(NBUF):
            await _thrash_set(dut, s)
        for b in bufs:
            total += 1
            if await _read_classify(dut, b):
                hits += 1
    return hits, total


async def _fresh(dut):
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 22)


@cocotb.test()
async def test_grasp_multi_perf(dut):
    _require_policy()
    n_high = len(dut.grasp_high_addr_l.value) // 32
    assert n_high >= NBUF, (
        f"build with GRASP_HIGH_REGIONS>={NBUF} (got {n_high}); "
        f"rm -rf sim_build first")

    windows = [_window(_line(s)) for s in range(NBUF)]

    await _fresh(dut)
    ha, ta = await _measure(dut, [])                 # A: fallback
    await _fresh(dut)
    hb, tb = await _measure(dut, [windows[0]])       # B: single window
    await _fresh(dut)
    hc, tc = await _measure(dut, windows)            # C: all NBUF windows

    ra, rb, rc = ha / ta, hb / tb, hc / tc
    dut._log.info(f"GRASP multi-window perf  (NBUF={NBUF}, ROUNDS={ROUNDS}, "
                  f"WAYS={WAYS}):")
    dut._log.info(f"  A fallback (0 windows)   hit-rate {ra*100:5.1f}%  ({ha}/{ta})")
    dut._log.info(f"  B single  (1 window)     hit-rate {rb*100:5.1f}%  ({hb}/{tb})")
    dut._log.info(f"  C multi   ({NBUF} windows)    hit-rate {rc*100:5.1f}%  ({hc}/{tc})")
    dut._log.info(f"  -> multi vs fallback: +{(rc-ra)*100:.1f} pp; "
                  f"multi vs single: +{(rc-rb)*100:.1f} pp")

    # Monotonic benefit and sane absolute levels.
    assert rc >= rb >= ra, f"hit-rate not monotonic C>=B>=A: {rc:.2f} {rb:.2f} {ra:.2f}"
    assert ra <= 0.10, f"fallback should thrash hot buffers (got {ra*100:.1f}%)"
    assert 0.5 / NBUF <= rb <= 1.5 / NBUF + 0.05, (
        f"single window should pin ~1/{NBUF} of buffers (got {rb*100:.1f}%)")
    assert rc >= 0.90, f"all-windows should pin every buffer (got {rc*100:.1f}%)"
    assert int(dut.pc_violations_total.value) == 0
