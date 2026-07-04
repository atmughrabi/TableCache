"""Prefill-race test for tc_narrow_shim.

Targets mutation `drop_prefill_check` (drops `& ~prefill_active` from
m_arvalid). The mutation only fires when:
  * a write triggered a prefill (line not in L0 buffer, no PREFILL_ID in
    flight) -> prefill_active=1, prefill_ar_pending fired and cleared,
    prefill_resp_pending=1 (waiting for wide R)
  * concurrently a NARROW READ arrives for a DIFFERENT (also not-buffered)
    line -> s_arvalid=1, ar_hits_buffer=0

With the guard, m_arvalid stays 0 for the read until prefill completes.
Without the guard, the shim issues a second m_arvalid driving s_araddr
while prefill_resp_pending is still high -- two ARs share the m_*
channel at the same time, only distinguishable by ID.

This test direct-drives s_aw*, s_w*, s_ar* (bypasses cocotbext-axi
serialisation) and asserts the m_arvalid handshakes that occur while
prefill_active=1 only carry m_arid == PREFILL_ID.
"""
from __future__ import annotations

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, Timer
from cocotbext.axi import AxiBus, AxiRam

CLK_NS   = 10
BASE     = 0x8000_0000
NARROW_W = int(os.environ.get("TC_NARROW_W", "32"))
BLOCK_W  = int(os.environ.get("TC_BLOCK_W",  "512"))
NARROW_B = NARROW_W // 8
BLOCK_B  = BLOCK_W  // 8
ID_W     = 4
PREFILL_ID = (1 << ID_W) - 1   # tc_narrow_shim uses '1 as PREFILL_ID

# This race is only reachable when PROMOTE_WMISS_TO_RW=1 (write-miss
# promotion path). Default build has it 0 and the prefill FSM is dead.
PROMOTE = os.environ.get("TC_PROMOTE_WMISS", "0") == "1"


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    dut.rst.value = 1
    # Quiesce all slave-side inputs.
    for sig, v in [("s_arvalid", 0), ("s_awvalid", 0), ("s_wvalid", 0),
                   ("s_rready", 1), ("s_bready", 1),
                   ("s_arlen", 0), ("s_arsize", NARROW_B.bit_length() - 1),
                   ("s_arburst", 1), ("s_arlock", 0), ("s_arcache", 0xF),
                   ("s_arprot", 0), ("s_arqos", 0), ("s_arregion", 0),
                   ("s_arsnoop", 0), ("s_arid", 0),
                   ("s_awlen", 0), ("s_awsize", NARROW_B.bit_length() - 1),
                   ("s_awburst", 1), ("s_awlock", 0), ("s_awcache", 0xF),
                   ("s_awprot", 0), ("s_awqos", 0), ("s_awregion", 0),
                   ("s_awsnoop", 0), ("s_awid", 0),
                   ("s_wlast", 1), ("s_wstrb", (1 << NARROW_B) - 1)]:
        if hasattr(dut, sig):
            getattr(dut, sig).value = v
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


@cocotb.test(expect_fail=not PROMOTE)
async def test_prefill_race_no_extra_ar(dut):
    """Drive an AW+W that triggers prefill, then drive a concurrent AR to
    a different line. Snoop every m_arvalid handshake; assert that any
    handshake observed while prefill_active is high carries PREFILL_ID."""
    await reset_dut(dut)
    ram = AxiRam(AxiBus.from_prefix(dut, "m"), dut.clk, dut.rst,
                 size=1 << 16, reset_active_level=True)
    seed = bytes((i & 0xFF) for i in range(1 << 16))
    ram.write(0, seed)

    line_w = BASE | (8 * BLOCK_B)
    line_r = BASE | (12 * BLOCK_B)
    write_lane = 3
    write_val  = 0xC0FFEE00 & ((1 << NARROW_W) - 1)

    # Background monitor on m_arvalid and m_rvalid. The mutation
    # drop_prefill_check lets the user's m_arvalid fire BEFORE the
    # prefill's m_r response returns; correct RTL forces user AR to
    # wait until prefill_resp_pending clears (i.e. until after the
    # PREFILL m_r last beat). Track the cycle of each ar/r handshake.
    ar_handshakes = []   # (cycle, arid)
    r_handshakes  = []   # (cycle, rid, rlast)
    cycle = 0
    async def snoop():
        nonlocal cycle
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            cycle += 1
            if int(dut.m_arvalid) and int(dut.m_arready):
                ar_handshakes.append((cycle, int(dut.m_arid.value)))
            if int(dut.m_rvalid) and int(dut.m_rready):
                r_handshakes.append((cycle, int(dut.m_rid.value), int(dut.m_rlast.value)))
    mon = cocotb.start_soon(snoop())

    # 1. Drive AW+W AND s_ar concurrently so the user's read is pending
    #    when prefill_active asserts. The mutation drop_prefill_check
    #    lets the user's m_arvalid fire while prefill is still in flight;
    #    only the concurrent-assertion ordering exposes it.
    dut.s_awaddr.value  = line_w + write_lane * NARROW_B
    dut.s_awid.value    = 1
    dut.s_awvalid.value = 1
    dut.s_wdata.value   = write_val
    dut.s_wvalid.value  = 1
    dut.s_wlast.value   = 1
    dut.s_araddr.value  = line_r
    dut.s_arid.value    = 2
    dut.s_arvalid.value = 1

    # Concurrently serve the read, decoupled from the AW/W handshake waits
    # below. Deassert s_arvalid on the FIRST accept (so a lingering AR is not
    # re-served as a buffer hit once the fill lands) and capture its R data.
    # This makes the functional check robust to the exact cycle the read AR
    # fires: with the same-id serialization fix the read AR issues right after
    # the prefill R, which can race the AW-handshake wait below.
    read_result = {}
    async def _serve_read():
        for _ in range(400):
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.s_arvalid) and int(dut.s_arready):
                break
        await RisingEdge(dut.clk)
        dut.s_arvalid.value = 0
        for _ in range(100):
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.s_rvalid) and int(dut.s_rready) and int(dut.s_rid) == 2:
                read_result["data"] = int(dut.s_rdata) & ((1 << NARROW_W) - 1)
                return
    read_task = cocotb.start_soon(_serve_read())
    # Wait for AW handshake.
    awseen = False
    for _ in range(50):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.s_awvalid) and int(dut.s_awready):
            awseen = True
            break
    assert awseen, "AW did not handshake (prefill may have stalled)"
    # Wait for W handshake then deassert.
    for _ in range(50):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.s_wvalid) and int(dut.s_wready):
            break
    await RisingEdge(dut.clk)
    dut.s_awvalid.value = 0
    dut.s_wvalid.value  = 0

    # 2+3. Await the concurrent read-server: it deasserts s_arvalid on the AR
    #      handshake and captures the read's R data (correct value = seed).
    await read_task
    assert "data" in read_result, "no R returned for the user read"
    exp_lo = line_r & 0xFFFF
    exp    = int.from_bytes(seed[exp_lo:exp_lo + NARROW_B], "little")
    assert read_result["data"] == exp, \
        f"read mismatch: got=0x{read_result['data']:08x} exp=0x{exp:08x}"
    await Timer(200, "ns")
    mon.kill()

    # 4. Leak detection. Find the cycle of the first PREFILL_ID AR and
    # the cycle of its R-last response. Under correct RTL, any non-
    # PREFILL_ID m_arvalid handshake must come at or AFTER that R-last
    # cycle (the gate ~prefill_active forces it to wait). Under the
    # drop_prefill_check mutation, the user m_ar fires immediately
    # alongside the prefill, before the R returns.
    pf_ar = next(((c, a) for c, a in ar_handshakes if a == PREFILL_ID), None)
    assert pf_ar, f"no prefill AR observed; ar_handshakes={ar_handshakes}"
    pf_ar_cyc = pf_ar[0]
    pf_r_last = next(((c, rid) for c, rid, last in r_handshakes
                      if rid == PREFILL_ID and last == 1), None)
    assert pf_r_last, f"no prefill R-last observed; r_handshakes={r_handshakes}"
    pf_r_cyc = pf_r_last[0]

    leaks = [(c, a) for c, a in ar_handshakes
             if a != PREFILL_ID and pf_ar_cyc <= c <= pf_r_cyc]
    dut._log.info(
        f"[prefill_race] prefill AR@{pf_ar_cyc} R-last@{pf_r_cyc} "
        f"ARs={ar_handshakes} Rs={r_handshakes}"
    )
    assert not leaks, (
        f"m_arvalid leak: non-PREFILL_ID handshake {leaks} during "
        f"prefill window [{pf_ar_cyc}, {pf_r_cyc}]. "
        f"This is the drop_prefill_check mutation footprint."
    )
    dut._log.info(f"[prefill_race] no leak in prefill window")
