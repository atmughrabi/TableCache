"""Negative control for a downstream WRAP-boundary error.

Runs alone because it hand-drives the memory-side AXI slave instead of attaching
AxiRam. Keeping it in a separate cocotb module prevents bus-driver contention
with reference-slave coroutines from positive tests.
"""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, with_timeout
from cocotbext.axi import AxiBus, AxiMaster

CLK_NS = 10
BASE = 0x8000_0000
NARROW_W = 32
NARROW_B = NARROW_W // 8
LINE_W = 8
LINES = 128


async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    dut.rst.value = 1
    for _ in range(max(64, LINES * 2)):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_wrong_wrap_boundary_sparse_corruption(dut):
    """A modulo-16 drain corrupts the tail of an eight-beat WRAP burst.

    The mutated slave returns words 15,0..6 instead of the AXI-correct
    15,8..14 sequence. A sparse data pattern isolates the two misplaced words.
    """
    await reset_dut(dut)
    assert len(dut.s_rdata) == 32 and len(dut.m_rdata) == 32
    master = AxiMaster(AxiBus.from_prefix(dut, "s"), dut.clk, dut.rst,
                       reset_active_level=True)
    pc_before = int(dut.pc_violations_total.value)
    converter_words = 16

    def sparse_value(global_word):
        return 1 if global_word >= 13 else 0

    async def wrong_wrap_boundary_slave():
        dut.m_arready.value = 1
        dut.m_rvalid.value = 0
        dut.m_rlast.value = 0
        while True:
            await RisingEdge(dut.clk)
            if int(dut.m_arvalid) and int(dut.m_arready):
                araddr = int(dut.m_araddr)
                arlen = int(dut.m_arlen)
                arburst = int(dut.m_arburst)
                arid = int(dut.m_arid)
                start_word = araddr // NARROW_B
                converter_base = (start_word // converter_words) * converter_words
                start_lane = start_word - converter_base
                dut.m_arready.value = 0
                for beat in range(arlen + 1):
                    if arburst == 0b10:
                        source_word = converter_base + (
                            (start_lane + beat) % converter_words)
                    else:
                        source_word = start_word + beat
                    dut.m_rdata.value = sparse_value(source_word)
                    dut.m_rid.value = arid
                    dut.m_rresp.value = 0
                    dut.m_rlast.value = int(beat == arlen)
                    dut.m_rvalid.value = 1
                    while True:
                        await RisingEdge(dut.clk)
                        if int(dut.m_rready):
                            break
                    dut.m_rvalid.value = 0
                    dut.m_rlast.value = 0
                dut.m_arready.value = 1

    for signal in ("m_awready", "m_wready", "m_bvalid"):
        getattr(dut, signal).value = 0
    slave = cocotb.start_soon(wrong_wrap_boundary_slave())

    critical = await with_timeout(
        master.read(BASE + 15 * NARROW_B, NARROW_B), 100_000, "ns")
    assert int.from_bytes(critical.data, "little") == 1

    actual = []
    for global_word in range(8, 16):
        data = await with_timeout(
            master.read(BASE + global_word * NARROW_B, NARROW_B),
            100_000, "ns")
        actual.append(int.from_bytes(data.data, "little"))
    slave.kill()

    mutated_source = {
        destination: source
        for destination, source in zip([15] + list(range(8, 15)),
                                       [15] + list(range(0, 7)))
    }
    mutated_expected = [
        sparse_value(mutated_source[global_word]) for global_word in range(8, 16)
    ]
    correct_expected = [sparse_value(global_word) for global_word in range(8, 16)]
    assert actual == mutated_expected, (
        f"negative-control mapping changed: got={actual}, "
        f"expected={mutated_expected}")
    bad_global_words = [
        8 + offset for offset, (got, exp)
        in enumerate(zip(actual, correct_expected)) if got != exp
    ]
    assert bad_global_words == [13, 14], (
        f"expected corruption at words 13 and 14, got {bad_global_words}")
    pc_after = int(dut.pc_violations_total.value)
    assert pc_after == pc_before, (
        f"negative slave violated AXI protocol: before={pc_before} after={pc_after}")
    dut._log.info(
        "[wrong_wrap_boundary] words 13 and 14 corrupted; other words match")
