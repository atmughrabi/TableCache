"""Set-aliased hot/cold stress for GRASP."""
from __future__ import annotations
import os
import cocotb
from cocotb.triggers import RisingEdge
from tb_common import reset_dut, attach_mem, CLK_PERIOD_NS
from test_grasp import (
    BASE, LINE_BYTES, _set_grasp, _drive_read, _read_and_classify,
)


@cocotb.test()
async def test_grasp_hot_under_pressure(dut):
    pol = os.environ.get("TC_POLICY_NAME", "GRASP")
    assert pol == "GRASP", f"This test requires POLICY=GRASP, got {pol}"

    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 22)

    # 8 hot lines map to cache sets 0..7 (line_addr bits 11:6 = i).
    hot_addrs  = [BASE + (i * LINE_BYTES) for i in range(8)]

    # Cold pool aliases the same 8 sets with 20 distinct tags. Adding
    # TAG_STRIDE = LINES * LINE_BYTES (= 64 * 32 = 2048) only changes the
    # tag bits, not the set index, so every cold line directly competes
    # with one of the hot ways.
    TAG_STRIDE = 64 * LINE_BYTES
    cold_addrs = []
    for k in range(1, 21):
        for s in range(8):
            cold_addrs.append(BASE + k * TAG_STRIDE + s * LINE_BYTES)

    hot_l = min(hot_addrs)
    hot_h = max(hot_addrs) + LINE_BYTES - 1
    _set_grasp(dut, hot_l=hot_l, hot_h=hot_h)

    # Round 0 warms (all hot lines miss the first time). Rounds 1-4 must
    # see every hot line still cached, even after per-round cold thrash.
    ROUNDS = 5
    for r in range(ROUNDS):
        round_hits = 0
        for a in hot_addrs:
            if await _read_and_classify(dut, a):
                round_hits += 1
        dut._log.info(f"round {r}: hot hits {round_hits}/{len(hot_addrs)}")
        if r > 0:
            assert round_hits == len(hot_addrs), (
                f"round {r}: hot retention broke under set-aliased "
                f"pressure: {round_hits}/{len(hot_addrs)}"
            )
        for a in cold_addrs:
            await _drive_read(dut, a)
