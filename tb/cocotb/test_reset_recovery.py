"""Mid-burst reset recovery.

Four scenarios: reset between transactions, mid read fill, mid multi-beat
write, and with two reads in flight. Each scenario asserts reset before
the response returns, then issues a fresh transaction to verify recovery.
All scenarios gate on `pc_violations_total == 0`.

Found bugs #10 (slave VALIDs held into reset) and #11 (checker counter
multi-driver race). See doc/ARCHITECTURE.md §7.5.
"""
from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge, Timer, with_timeout
from tb_common import reset_dut, attach_master, attach_mem, golden

BLOCK_BYTES = 4
LINE_W      = 8
LINE_BYTES  = LINE_W * BLOCK_BYTES   # 32 B at default config

BASE = 0x80000000


async def reassert_reset(dut, cycles: int = 128):
    """Re-toggle rst without spawning a new clock (use after `reset_dut`)."""
    dut.rst.value = 1
    for sig, val in [
        ("s_arvalid", 0), ("s_awvalid", 0), ("s_wvalid", 0),
        ("s_rready", 1), ("s_bready", 1),
        ("s_arsnoop", 0), ("s_awsnoop", 0),
    ]:
        if hasattr(dut, sig):
            getattr(dut, sig).value = val
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def wait_for_handshake(dut, valid_sig: str, ready_sig: str,
                              max_cycles: int = 200) -> bool:
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if int(getattr(dut, valid_sig).value) and int(getattr(dut, ready_sig).value):
            return True
    return False


def assert_pc_clean(dut, context: str):
    pc = int(dut.pc_violations_total.value)
    assert pc == 0, f"AXI_PC violations after {context}: {pc}"


@cocotb.test()
async def test_reset_between_txns(dut):
    """Baseline: read, reset, read again. Must always pass."""
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    op = await with_timeout(master.read(BASE | 0x100, BLOCK_BYTES), 5_000, "ns")
    assert int.from_bytes(op.data, "little") == golden(BASE | 0x100)

    await reassert_reset(dut)

    op = await with_timeout(master.read(BASE | 0x100, BLOCK_BYTES), 5_000, "ns")
    assert int.from_bytes(op.data, "little") == golden(BASE | 0x100)

    assert_pc_clean(dut, "clean reset between transactions")


@cocotb.test()
async def test_reset_mid_read_fill(dut):
    """AR handshakes, reset before R drained, fresh read to a different line."""
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    _doomed = cocotb.start_soon(master.read(BASE | 0x2000, LINE_BYTES))
    assert await wait_for_handshake(dut, "s_arvalid", "s_arready", 100), \
        "AR handshake never fired for doomed read"

    await reassert_reset(dut)

    addr2 = BASE | 0x4000
    op = await with_timeout(master.read(addr2, LINE_BYTES), 10_000, "ns")
    exp = b"".join(
        golden(addr2 + i * BLOCK_BYTES).to_bytes(BLOCK_BYTES, "little")
        for i in range(LINE_W)
    )
    assert op.data == exp
    assert_pc_clean(dut, "mid-read reset")


@cocotb.test()
async def test_reset_mid_write_burst(dut):
    """AW + >=1 W beat fired, then reset; fresh write+readback to a different line."""
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    payload1 = bytes((i * 7 + 3) & 0xFF for i in range(LINE_BYTES))
    _doomed = cocotb.start_soon(master.write(BASE | 0x6000, payload1))
    assert await wait_for_handshake(dut, "s_awvalid", "s_awready", 100), "AW never fired"
    assert await wait_for_handshake(dut, "s_wvalid",  "s_wready",  50),  "W beat never fired"

    await reassert_reset(dut)

    addr2 = BASE | 0x8000
    payload2 = bytes((i * 13 + 11) & 0xFF for i in range(LINE_BYTES))
    await with_timeout(master.write(addr2, payload2), 10_000, "ns")
    op = await with_timeout(master.read(addr2, LINE_BYTES), 10_000, "ns")
    assert op.data == payload2
    assert_pc_clean(dut, "mid-write reset")


@cocotb.test()
async def test_reset_with_two_in_flight(dut):
    """Two reads in flight, reset before either completes (exposed bug #10)."""
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    cocotb.start_soon(master.read(BASE | 0xA000, LINE_BYTES))
    cocotb.start_soon(master.read(BASE | 0xC000, LINE_BYTES))
    assert await wait_for_handshake(dut, "s_arvalid", "s_arready", 100), "First AR never fired"
    for _ in range(5):
        await RisingEdge(dut.clk)

    await reassert_reset(dut)

    addr_c = BASE | 0xE000
    op = await with_timeout(master.read(addr_c, LINE_BYTES), 10_000, "ns")
    exp = b"".join(
        golden(addr_c + i * BLOCK_BYTES).to_bytes(BLOCK_BYTES, "little")
        for i in range(LINE_W)
    )
    assert op.data == exp
    assert_pc_clean(dut, "two-in-flight mid-burst reset")


@cocotb.test()
async def test_reset_with_bvalid_pending(dut):
    """Reset while req_b.bvalid is asserted and waiting for s_bready.

    Targets the B-channel half of bug #10: drops s_bready to LOW so the
    write's B response sticks high, asserts reset, then verifies the
    fresh read returns golden + PC stays clean. Mutation testing
    (`drop_rst_gate_bvalid`) surfaced this as a gap in test_reset_recovery."""
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    # Hold s_bready LOW indefinitely via pause generator.
    def always_pause():
        while True:
            yield 1
    master.write_if.b_channel.set_pause_generator(always_pause())

    addr_w = BASE | 0x10000
    payload = bytes((i * 11 + 5) & 0xFF for i in range(LINE_BYTES))
    cocotb.start_soon(master.write(addr_w, payload))

    # Wait for s_bvalid to rise (cache asserts B response, master holds bready=0)
    bvalid_seen = False
    for _ in range(200):
        await RisingEdge(dut.clk)
        if int(dut.s_bvalid.value):
            bvalid_seen = True
            break
    assert bvalid_seen, "s_bvalid never rose while s_bready was held LOW"

    # Reset while s_bvalid is high
    await reassert_reset(dut)

    # Recovery
    addr_r = BASE | 0x12000
    op = await with_timeout(master.read(addr_r, LINE_BYTES), 10_000, "ns")
    exp = b"".join(
        golden(addr_r + i * BLOCK_BYTES).to_bytes(BLOCK_BYTES, "little")
        for i in range(LINE_W)
    )
    assert op.data == exp
    assert_pc_clean(dut, "reset_with_bvalid_pending")
