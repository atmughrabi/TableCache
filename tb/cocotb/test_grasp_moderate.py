"""Directed test for the GRASP `swap_hit_decrement` mutation.

The mutation flips `updated_RRPV[j] -= 1'b1` to `+= 1'b1` in the
SRRIP-FP-fallback hit-promotion branch of GRASP.sv (the `else` after
`if (high_reuse)`). Detecting it requires a workload that exposes the
RRPV-drift differential between correct (decrement, saturate at 0)
and mutant (increment toward MAX_RRPV) behavior.

Pure SRRIP-FP fallback doesn't work: cold inserts land at RRPV=MAX,
so the mutant's `+= 1` immediately wraps to 0 on the first hit (the
`!= 0` guard then stalls it there), matching the correct end state.
HOT-region tests don't work either: `if (high_reuse)` short-circuits
to `HOT_HIT_RRPV` and never reaches the mutated branch.

Configuring ONLY the MODERATE region (RRPV=1 insert) and hitting the
target line six times pushes the mutant 1 -> 2 -> ... -> 7 (MAX_RRPV
with the 3-bit GRASP RRPV) while correct decrements to 0 and
saturates. A single set-conflicting miss outside the moderate region
(which goes through SRRIP-FP -> RRPV=MAX_RRPV) then evicts A on the
mutant (A at MAX, leftmost tie-break picks it) and keeps A on correct
(A unique at 0, other ways evicted first).

Lives in its own module so cocotb gives a fresh sim/cache state
(test-isolation within a single MODULE is imperfect, see test_grasp.py
preamble).
"""
from __future__ import annotations
import os
import cocotb
from tb_common import reset_dut, attach_mem
from test_grasp import (
    BASE, LINE_BYTES, _set_grasp, _drive_read, _read_and_classify,
)

LINES = int(os.environ.get("TC_LINES", "64"))
WAYS  = int(os.environ.get("TC_WAYS",  "4"))
SET_STRIDE = LINES * LINE_BYTES

# 3-bit GRASP RRPV (see src/replacement_policy.sv:57 GRASP_RRPV_WIDTH=3).
# Moderate insert lands at 1; mutant `+= 1` on hit needs 6 hits to climb
# 1 -> 7 (MAX_RRPV). Correct `-= 1` saturates at 0 (`!= 0` guard).
PROMOTE_HITS = 6


@cocotb.test()
async def test_grasp_moderate_hit_promotion(dut):
    """Mutant `swap_hit_decrement` evicts a 6x-hit moderate line; correct keeps it."""
    pol = os.environ.get("TC_POLICY_NAME", "GRASP")
    assert pol == "GRASP", f"This test requires POLICY=GRASP, got {pol}"

    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 22)

    A = BASE
    conflicts = [BASE + (i * SET_STRIDE) for i in range(1, WAYS + 2)]

    # Moderate region covers ONLY A's line; the WAYS+1 conflicting lines
    # are deliberately OUTSIDE it so they fall through to SRRIP-FP
    # (insert at MAX_RRPV=7), making A's RRPV the discriminator.
    _set_grasp(dut, mod_l=A, mod_h=A + LINE_BYTES - 1)

    # Cold insert A. Moderate region -> RRPV=1.
    await _drive_read(dut, A)

    # Promote A. On correct, RRPV stays at 0 (1 -> 0 then guard).
    # On mutant, RRPV climbs to MAX_RRPV after PROMOTE_HITS hits.
    for _ in range(PROMOTE_HITS):
        await _drive_read(dut, A)

    # Force eviction: insert WAYS+1 set-aliased conflicting lines outside
    # the moderate region (so they get RRPV=MAX_RRPV via SRRIP-FP). On
    # the mutant, A and the cold ways are all at MAX -> tie-break picks
    # A (leftmost) on the eviction-eligible-RRPV scan. On correct, A
    # alone is at RRPV=0 so the cold ways win the eviction lottery.
    for a in conflicts:
        await _drive_read(dut, a)

    # Re-read A. Mem-AR oracle classifies hit/miss.
    a_is_hit = await _read_and_classify(dut, A)
    dut._log.info(f"A re-read classified as {'HIT' if a_is_hit else 'MISS'}")
    assert a_is_hit, (
        "A was evicted -- repeated hits on a moderate-region line drove "
        "RRPV toward MAX_RRPV (consistent with the swap_hit_decrement "
        "mutant). Correct policy decrements RRPV toward 0 on each hit "
        "and keeps A across cold conflict pressure."
    )

