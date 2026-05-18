"""Partial-strobe write tests (wstrb != all-ones).

cocotbext-axi's AxiMaster does not expose per-beat wstrb, and its B-channel
monitor asserts on unexpected IDs if we drive writes around it. So this
test drives BOTH AR/R and AW/W/B manually via the slave-port signals.
"""
from __future__ import annotations
import cocotb
from cocotb.triggers import RisingEdge, Timer
from tb_common import reset_dut, attach_mem, golden
from tb_coverage import sample_read, sample_write, dump_coverage

BASE        = 0x80000000
BLOCK_BYTES = 4
LINE_W      = 8
LINE_BYTES  = LINE_W * BLOCK_BYTES


def merge_bytes(orig: int, new: int, strb: int) -> int:
    out = 0
    for i in range(4):
        b = (new >> (8 * i)) & 0xFF if (strb >> i) & 1 else (orig >> (8 * i)) & 0xFF
        out |= b << (8 * i)
    return out


# ------- manual AXI helpers driving the slave port directly -------

async def manual_read(dut, addr, nbeats=1, arid=0):
    await RisingEdge(dut.clk)
    dut.s_araddr.value   = addr
    dut.s_arlen.value    = nbeats - 1
    dut.s_arsize.value   = 2
    dut.s_arburst.value  = 1            # INCR
    dut.s_arlock.value   = 0
    dut.s_arcache.value  = 0xF
    dut.s_arprot.value   = 0
    dut.s_arqos.value    = 0
    dut.s_arregion.value = 0
    dut.s_arsnoop.value  = 0
    dut.s_arid.value     = arid
    dut.s_arvalid.value  = 1
    dut.s_rready.value   = 1
    while True:
        await RisingEdge(dut.clk)
        if dut.s_arready.value == 1:
            dut.s_arvalid.value = 0
            break
    out = bytearray()
    while True:
        await RisingEdge(dut.clk)
        if dut.s_rvalid.value == 1 and dut.s_rready.value == 1:
            word = int(dut.s_rdata.value) & ((1 << (BLOCK_BYTES * 8)) - 1)
            out += word.to_bytes(BLOCK_BYTES, "little")
            if dut.s_rlast.value == 1:
                break
    return bytes(out)


async def manual_write(dut, addr, data: bytes, strbs, awsnoop=0b000, awid=0):
    nbeats = len(strbs)
    assert len(data) == nbeats * BLOCK_BYTES
    await RisingEdge(dut.clk)
    dut.s_awaddr.value   = addr
    dut.s_awlen.value    = nbeats - 1
    dut.s_awsize.value   = 2
    dut.s_awburst.value  = 1
    dut.s_awlock.value   = 0
    dut.s_awcache.value  = 0xF
    dut.s_awprot.value   = 0
    dut.s_awqos.value    = 0
    dut.s_awregion.value = 0
    dut.s_awsnoop.value  = awsnoop
    dut.s_awid.value     = awid
    dut.s_awvalid.value  = 1
    dut.s_bready.value   = 1
    while True:
        await RisingEdge(dut.clk)
        if dut.s_awready.value == 1:
            dut.s_awvalid.value = 0
            break
    for i in range(nbeats):
        beat = data[i * BLOCK_BYTES:(i + 1) * BLOCK_BYTES]
        dut.s_wdata.value  = int.from_bytes(beat, "little")
        dut.s_wstrb.value  = strbs[i]
        dut.s_wlast.value  = 1 if (i == nbeats - 1) else 0
        dut.s_wvalid.value = 1
        while True:
            await RisingEdge(dut.clk)
            if dut.s_wready.value == 1:
                break
    dut.s_wvalid.value = 0
    dut.s_wlast.value  = 0
    while True:
        await RisingEdge(dut.clk)
        if dut.s_bvalid.value == 1 and dut.s_bready.value == 1:
            break
    dut.s_awsnoop.value = 0


@cocotb.test()
async def test_partial_strobe_single_beat(dut):
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    dut.s_rready.value = 1
    dut.s_bready.value = 1

    addr     = BASE | 0x00002080
    orig_raw = await manual_read(dut, addr, 1, arid=0)
    orig     = int.from_bytes(orig_raw, "little")
    assert orig == golden(addr)

    new_word = 0xDEADBEEF
    strb     = 0b0110
    expect   = merge_bytes(orig, new_word, strb)

    await manual_write(dut, addr, new_word.to_bytes(BLOCK_BYTES, "little"), [strb],
                       awsnoop=0b000, awid=0)
    await Timer(50, "ns")

    got_raw = await manual_read(dut, addr, 1, arid=1)
    got     = int.from_bytes(got_raw, "little")
    assert got == expect, (
        f"single-beat partial-strobe: got=0x{got:08x} expected=0x{expect:08x} "
        f"orig=0x{orig:08x} new=0x{new_word:08x} strb=0b{strb:04b}"
    )
    dut._log.info(f"partial-strobe single-beat OK (0x{got:08x})")


@cocotb.test()
async def test_partial_strobe_multi_beat(dut):
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    dut.s_rready.value = 1
    dut.s_bready.value = 1

    addr = BASE | 0x00003000
    n    = 8
    orig_raw = await manual_read(dut, addr, n, arid=2)
    orig_words = [
        int.from_bytes(orig_raw[i * BLOCK_BYTES:(i + 1) * BLOCK_BYTES], "little")
        for i in range(n)
    ]

    new_words = [0x11223344, 0x55667788, 0x99AABBCC, 0xDDEEFF00,
                 0x11111111, 0x22222222, 0x33333333, 0x44444444]
    strbs     = [0b1111, 0b1010, 0b0001, 0b1100,
                 0b0101, 0b1001, 0b0110, 0b1110]
    expect    = [merge_bytes(o, w, s) for o, w, s in zip(orig_words, new_words, strbs)]
    payload   = b"".join(w.to_bytes(BLOCK_BYTES, "little") for w in new_words)

    await manual_write(dut, addr, payload, strbs, awsnoop=0b000, awid=1)
    await Timer(80, "ns")

    got_raw = await manual_read(dut, addr, n, arid=3)
    for i in range(n):
        got = int.from_bytes(got_raw[i * BLOCK_BYTES:(i + 1) * BLOCK_BYTES], "little")
        assert got == expect[i], (
            f"beat {i}: got=0x{got:08x} expected=0x{expect[i]:08x} "
            f"orig=0x{orig_words[i]:08x} new=0x{new_words[i]:08x} strb=0b{strbs[i]:04b}"
        )
    sample_read(addr, n, 0)
    sample_write(addr, n, 0, True)
    dut._log.info("partial-strobe multi-beat OK")


@cocotb.test()
async def test_partial_strobe_2beat(dut):
    """2-beat burst variant: fills the nbeat=2 functional-coverage bin
    that the rest of the suite (1-beat + 8-beat only) does not."""
    await reset_dut(dut)
    attach_mem(dut, size_bytes=1 << 20)
    dut.s_rready.value = 1
    dut.s_bready.value = 1

    addr = BASE | 0x00004000
    n    = 2
    orig_raw = await manual_read(dut, addr, n, arid=4)
    sample_read(addr, n, 0)
    orig_words = [
        int.from_bytes(orig_raw[i * BLOCK_BYTES:(i + 1) * BLOCK_BYTES], "little")
        for i in range(n)
    ]

    new_words = [0xCAFE0001, 0xCAFE0002]
    strbs     = [0b1100, 0b0011]
    expect    = [merge_bytes(o, w, s) for o, w, s in zip(orig_words, new_words, strbs)]
    payload   = b"".join(w.to_bytes(BLOCK_BYTES, "little") for w in new_words)

    await manual_write(dut, addr, payload, strbs, awsnoop=0b000, awid=5)
    sample_write(addr, n, 0, True)
    await Timer(50, "ns")

    got_raw = await manual_read(dut, addr, n, arid=6)
    sample_read(addr, n, 0)
    for i in range(n):
        got = int.from_bytes(got_raw[i * BLOCK_BYTES:(i + 1) * BLOCK_BYTES], "little")
        assert got == expect[i], f"beat {i}: got=0x{got:08x} expected=0x{expect[i]:08x}"

    # 4-beat partial-strobe to fill the (4, True) beat_x_partial cell.
    addr4 = BASE | 0x00005000
    n4    = 4
    orig4_raw = await manual_read(dut, addr4, n4, arid=8)
    sample_read(addr4, n4, 0)
    orig4 = [int.from_bytes(orig4_raw[i*BLOCK_BYTES:(i+1)*BLOCK_BYTES], "little")
             for i in range(n4)]
    new4   = [0xA1B2C3D4, 0xA5A6A7A8, 0xB1B2B3B4, 0xC1C2C3C4]
    strb4  = [0b1100, 0b0011, 0b1010, 0b0101]
    exp4   = [merge_bytes(o, w, s) for o, w, s in zip(orig4, new4, strb4)]
    pl4    = b"".join(w.to_bytes(BLOCK_BYTES, "little") for w in new4)
    await manual_write(dut, addr4, pl4, strb4, awsnoop=0b000, awid=9)
    sample_write(addr4, n4, 0, True)
    await Timer(50, "ns")
    got4_raw = await manual_read(dut, addr4, n4, arid=10)
    sample_read(addr4, n4, 0)
    for i in range(n4):
        got = int.from_bytes(got4_raw[i*BLOCK_BYTES:(i+1)*BLOCK_BYTES], "little")
        assert got == exp4[i], f"4b beat {i}: got=0x{got:08x} expected=0x{exp4[i]:08x}"

    dump_coverage("test_strobe")
    dut._log.info("partial-strobe 2-beat + 4-beat OK")
