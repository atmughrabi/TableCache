"""
Pipelined throughput micro-benchmark for tc_narrow_shim.

Bypasses cocotbext-axi's high-level master.read() (which serializes one
transaction at a time) and drives s_arvalid / s_araddr directly to measure
the real sustained throughput of buffer hits.

Goal: prove 1 narrow R beat / cycle when the buffer holds the line.
"""
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly
from cocotbext.axi import AxiBus, AxiMaster, AxiRam

CLK_NS   = 10
BASE     = 0x8000_0000
NARROW_W = int(os.environ.get("TC_NARROW_W", "32"))
BLOCK_W  = int(os.environ.get("TC_BLOCK_W",  "512"))
NARROW_B = NARROW_W // 8
BLOCK_B  = BLOCK_W  // 8
RATIO    = BLOCK_W  // NARROW_W


async def reset(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    dut.rst.value = 1
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_pipelined_hit_throughput(dut):
    """Drive AR signals directly; count AR & R handshakes per cycle."""
    await reset(dut)

    # Wide-port AxiRam responds to misses.
    ram = AxiRam(AxiBus.from_prefix(dut, "m"), dut.clk, dut.rst,
                 size=1 << 16, reset_active_level=True)
    seed = bytes((i & 0xFF) for i in range(1 << 16))
    ram.write(0, seed)

    line_base = BASE | (4 * BLOCK_B)

    # Initialise narrow-slave signals (we own them; no cocotb master).
    dut.s_arvalid.value = 0
    dut.s_rready.value  = 1
    dut.s_arlen.value   = 0
    dut.s_arsize.value  = NARROW_B.bit_length() - 1
    dut.s_arburst.value = 1
    dut.s_arlock.value  = 0
    dut.s_arcache.value = 0xF
    dut.s_arprot.value  = 0
    dut.s_arqos.value   = 0
    dut.s_arregion.value = 0
    dut.s_arid.value    = 0
    dut.s_awvalid.value = 0
    dut.s_wvalid.value  = 0
    dut.s_bready.value  = 1
    await RisingEdge(dut.clk)

    # The first AR is a cold miss to AxiRam (fills the buffer); subsequent
    # ARs to lanes within the same line hit the buffer at 1 beat/cycle.
    ar_fired = 0
    r_fired  = 0
    r_data   = []
    issued   = 0
    max_cycles = RATIO * 8 + 30
    cycles = 0

    for c in range(max_cycles):
        cycles = c + 1
        if issued < RATIO:
            dut.s_arvalid.value = 1
            dut.s_araddr.value  = line_base + issued * NARROW_B
            dut.s_arid.value    = issued & 0xF       # rotate IDs (16 distinct)
        else:
            dut.s_arvalid.value = 0

        await ReadOnly()
        if int(dut.s_arvalid) and int(dut.s_arready):
            ar_fired += 1
            issued   += 1
        if int(dut.s_rvalid) and int(dut.s_rready):
            r_fired += 1
            r_data.append(int(dut.s_rdata) & ((1 << NARROW_W) - 1))

        await RisingEdge(dut.clk)
        if ar_fired == RATIO and r_fired == RATIO:
            break

    dut.s_arvalid.value = 0

    dut._log.info(f"[pipe-hit] AR handshakes={ar_fired} R handshakes={r_fired} "
                  f"in {cycles} cycles (line size={RATIO} narrow words)")

    assert ar_fired == RATIO, f"AR fired {ar_fired}, expected {RATIO}"
    assert r_fired  == RATIO, f"R  fired {r_fired}, expected {RATIO}"

    # The first AR is a miss → wide AR + wide R (~3 cycles in AxiRam).
    # Subsequent (RATIO-1) ARs should be served from the buffer at
    # one R beat per cycle. Allow ample slack for the cold miss.
    assert cycles <= RATIO + 8, \
        f"throughput broken: {cycles} cycles for {RATIO} reads " \
        f"(want <= {RATIO+8})"

    # Data correctness
    for i, got in enumerate(r_data):
        addr_lo = ((line_base + i * NARROW_B) & 0xFFFF)
        exp = int.from_bytes(seed[addr_lo:addr_lo + NARROW_B], "little")
        assert got == exp, \
            f"beat {i}: got {got:#x} want {exp:#x} addr_lo={addr_lo:#x}"

    avg = cycles / RATIO
    dut._log.info(f"[pipe-hit] {RATIO} reads in {cycles} cycles "
                  f"-> {avg:.2f} cyc/read; steady-state hits = "
                  f"{(RATIO-1)/(cycles-1):.2f} beats/cycle")
