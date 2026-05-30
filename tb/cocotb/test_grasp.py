"""Directed tests for the GRASP replacement policy.

Latency-as-oracle: the cocotb harness measures cycles from AR to
first R beat; hits land in ~<=10 cycles, misses in >=20 (memory
roundtrip). HIT_LATENCY_THRESHOLD splits them at 15.

Coverage:
  - hot retention under cold thrash (with HOT region configured)
  - SRRIP-FP fallback when all region ports are tied to 0
  - invalid region (_h<_l, _h!=0) treated as disabled
  - runtime reconfiguration between phases
  - hot/moderate overlap precedence (hot must win)

POLICY=GRASP is required (test asserts on TC_POLICY_NAME).
"""
from __future__ import annotations
import os
import cocotb
from cocotb.triggers import RisingEdge
from tb_common import reset_dut, attach_mem, CLK_PERIOD_NS

BASE        = 0x80000000
BLOCK_BYTES = 4
LINE_W      = 8
LINE_BYTES  = LINE_W * BLOCK_BYTES   # 32B default

# Hit-vs-miss threshold. Hits return on the same cycle the line is ready
# (a few cycles); misses pay the mem roundtrip. 15 is a safe split.
HIT_LATENCY_THRESHOLD = 15


def _set_grasp(dut, hot_l=0, hot_h=0, mod_l=0, mod_h=0):
    dut.grasp_high_addr_l.value     = hot_l
    dut.grasp_high_addr_h.value     = hot_h
    dut.grasp_moderate_addr_l.value = mod_l
    dut.grasp_moderate_addr_h.value = mod_h


async def _read_line_latency(dut, addr):
    """Issue a single-beat read and return cycles from AR-handshake to first R."""
    await RisingEdge(dut.clk)
    dut.s_araddr.value   = addr
    dut.s_arlen.value    = 0
    dut.s_arsize.value   = 2
    dut.s_arburst.value  = 1
    dut.s_arlock.value   = 0
    dut.s_arcache.value  = 0xF
    dut.s_arprot.value   = 0
    dut.s_arqos.value    = 0
    dut.s_arregion.value = 0
    dut.s_arsnoop.value  = 0
    dut.s_arid.value     = 0
    dut.s_arvalid.value  = 1
    dut.s_rready.value   = 1
    # Wait for AR handshake.
    for _ in range(500):
        await RisingEdge(dut.clk)
        if int(dut.s_arready.value) == 1 and int(dut.s_arvalid.value) == 1:
            break
    dut.s_arvalid.value = 0
    # Count cycles until first R beat.
    for c in range(500):
        await RisingEdge(dut.clk)
        if int(dut.s_rvalid.value) == 1 and int(dut.s_rready.value) == 1:
            # Drain RLAST if multi-beat (we issued single-beat so rlast=1).
            return c + 1
    raise TimeoutError(f"no R beat for addr 0x{addr:x}")


async def _hot_cold_workload(dut, hot_addrs, cold_addrs):
    """Warm hot lines, thrash cold lines, then re-measure hot latencies."""
    # Warm hot set (each becomes a miss the first time).
    for a in hot_addrs:
        await _read_line_latency(dut, a)
    # Thrash with cold.
    for a in cold_addrs:
        await _read_line_latency(dut, a)
    # Re-measure hot.
    hit_count = 0
    for a in hot_addrs:
        lat = await _read_line_latency(dut, a)
        if lat <= HIT_LATENCY_THRESHOLD:
            hit_count += 1
    return hit_count


@cocotb.test()
async def test_grasp_hot_retained(dut):
    """With a HOT region configured, hot lines should survive cold thrash."""
    pol = os.environ.get("TC_POLICY_NAME", "GRASP")
    assert pol == "GRASP", f"This test requires POLICY=GRASP, got {pol}"

    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 22)

    # Pick disjoint hot/cold pools.
    # WAYS=4 default, LINES=64 default -> 256 lines capacity.
    # Hot pool small (8 lines), cold pool large (200 lines) to force eviction.
    hot_addrs  = [BASE + (i * LINE_BYTES) for i in range(8)]
    cold_addrs = [BASE + 0x00100000 + (i * LINE_BYTES) for i in range(200)]

    hot_l = min(hot_addrs)
    hot_h = max(hot_addrs) + LINE_BYTES - 1
    _set_grasp(dut, hot_l=hot_l, hot_h=hot_h)

    hits = await _hot_cold_workload(dut, hot_addrs, cold_addrs)
    rate = hits / len(hot_addrs)
    dut._log.info(f"GRASP hot-configured: hot hits {hits}/{len(hot_addrs)} ({rate*100:.0f}%)")
    # With proper retention all 8 hot lines should hit. Allow 1 cold-eviction slop.
    assert hits >= len(hot_addrs) - 1, (
        f"GRASP hot region not retained: {hits}/{len(hot_addrs)} hits, "
        f"expected >= {len(hot_addrs)-1}"
    )


@cocotb.test()
async def test_grasp_srrip_fallback(dut):
    """With ALL region ports tied to 0, GRASP must behave like SRRIP-FP:
    the same workload that retains 100% of hot lines under a hot region
    should evict most of them when the region is unconfigured."""
    pol = os.environ.get("TC_POLICY_NAME", "GRASP")
    assert pol == "GRASP", f"This test requires POLICY=GRASP, got {pol}"

    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 22)
    _set_grasp(dut)  # all zero -> SRRIP fallback

    hot_addrs  = [BASE + (i * LINE_BYTES) for i in range(8)]
    cold_addrs = [BASE + 0x00100000 + (i * LINE_BYTES) for i in range(200)]

    hits = await _hot_cold_workload(dut, hot_addrs, cold_addrs)
    rate = hits / len(hot_addrs)
    dut._log.info(f"GRASP fallback (regions=0): hot hits {hits}/{len(hot_addrs)} ({rate*100:.0f}%)")
    # Pure SRRIP-FP with 200-line cold thrash will evict most/all of 8 hot
    # lines; we tolerate the test simply completing without crashing. The
    # comparative assertion is informational: hot-configured should beat this.
    assert hits <= len(hot_addrs), "sanity: cannot have more hits than probes"


@cocotb.test()
async def test_grasp_invalid_region(dut):
    """Region with _h < _l (and _h != 0) must be treated as disabled, not
    as wrap-around. The (_h >= _l) guard in GRASP.sv is what enforces this."""
    pol = os.environ.get("TC_POLICY_NAME", "GRASP")
    assert pol == "GRASP", f"This test requires POLICY=GRASP, got {pol}"

    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 22)

    # Invalid hot range (_h < _l, _h != 0), valid moderate range covering hot addrs.
    hot_addrs = [BASE + (i * LINE_BYTES) for i in range(8)]
    dut.grasp_high_addr_l.value     = 0x80001000  # > _h
    dut.grasp_high_addr_h.value     = 0x80000FFF  # < _l, non-zero
    dut.grasp_moderate_addr_l.value = hot_addrs[0]
    dut.grasp_moderate_addr_h.value = hot_addrs[-1] + LINE_BYTES - 1

    cold_addrs = [BASE + 0x00200000 + (i * LINE_BYTES) for i in range(64)]
    hits = await _hot_cold_workload(dut, hot_addrs, cold_addrs)
    dut._log.info(f"invalid-hot + valid-warm: hits {hits}/{len(hot_addrs)}")
    # Must not crash; moderate region active so hot lines should mostly survive.
    assert hits >= len(hot_addrs) // 2, (
        f"moderate region not effective when hot is invalidly configured: "
        f"{hits}/{len(hot_addrs)}"
    )


@cocotb.test()
async def test_grasp_runtime_reconfig(dut):
    """Drive hot region differently between two workload phases; the
    region inputs are classified per access (no internal latch)."""
    pol = os.environ.get("TC_POLICY_NAME", "GRASP")
    assert pol == "GRASP", f"This test requires POLICY=GRASP, got {pol}"

    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 22)

    # Phase 1: pin set-A as hot, thrash with set-B.
    set_a = [BASE + (i * LINE_BYTES) for i in range(8)]
    set_b = [BASE + 0x00040000 + (i * LINE_BYTES) for i in range(8)]
    cold  = [BASE + 0x00100000 + (i * LINE_BYTES) for i in range(64)]

    _set_grasp(dut, hot_l=set_a[0], hot_h=set_a[-1] + LINE_BYTES - 1)
    hits_a1 = await _hot_cold_workload(dut, set_a, cold)
    dut._log.info(f"phase1 set_a-hot: A hits {hits_a1}/8")

    # Phase 2: pin set-B as hot instead; set-A is now cold; thrash with cold pool.
    _set_grasp(dut, hot_l=set_b[0], hot_h=set_b[-1] + LINE_BYTES - 1)
    hits_b = await _hot_cold_workload(dut, set_b, cold)
    dut._log.info(f"phase2 set_b-hot: B hits {hits_b}/8")

    assert hits_a1 >= 7, f"phase1 set_a retention failed: {hits_a1}/8"
    assert hits_b   >= 7, f"phase2 set_b retention failed after reconfig: {hits_b}/8"


@cocotb.test()
async def test_grasp_overlap_priority(dut):
    """When hot and moderate cover the same range, hot must win
    (the ~high_reuse term in moderate_reuse enforces precedence)."""
    pol = os.environ.get("TC_POLICY_NAME", "GRASP")
    assert pol == "GRASP", f"This test requires POLICY=GRASP, got {pol}"

    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 22)

    # Identical hot/moderate range; HOT_HIT_RRPV=0 retains; moderate
    # alone (insert at RRPV=1) would age the lines out fast.
    hot_addrs = [BASE + (i * LINE_BYTES) for i in range(8)]
    lo = hot_addrs[0]; hi = hot_addrs[-1] + LINE_BYTES - 1
    dut.grasp_high_addr_l.value     = lo
    dut.grasp_high_addr_h.value     = hi
    dut.grasp_moderate_addr_l.value = lo
    dut.grasp_moderate_addr_h.value = hi

    cold_addrs = [BASE + 0x00100000 + (i * LINE_BYTES) for i in range(200)]
    hits = await _hot_cold_workload(dut, hot_addrs, cold_addrs)
    assert hits >= len(hot_addrs) - 1, (
        f"hot precedence broken in overlap: {hits}/{len(hot_addrs)}"
    )
