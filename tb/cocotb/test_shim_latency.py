"""
Quick latency micro-benchmark for tc_narrow_shim.
Reports per-operation cycle counts for:
  - Cold read (buffer miss -> wide AR + wide R + slice)
  - Hot read  (buffer hit  -> single-cycle slice)
  - Cold write + read-back (write-merge -> 0 extra ARs)
"""
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb.utils import get_sim_time
from cocotbext.axi import AxiBus, AxiMaster, AxiRam

CLK_NS   = 10
BASE     = 0x8000_0000
NARROW_W = int(os.environ.get("TC_NARROW_W", "32"))
BLOCK_W  = int(os.environ.get("TC_BLOCK_W",  "512"))
NARROW_B = NARROW_W // 8
BLOCK_B  = BLOCK_W  // 8
RATIO    = BLOCK_W  // NARROW_W

COLD_READ_MAX = 12
HOT_READ_MAX = 6
WRITE_MAX = 12
MERGED_READ_MAX = 6


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    dut.rst.value = 1
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)
    master = AxiMaster(AxiBus.from_prefix(dut, "s"), dut.clk, dut.rst,
                       reset_active_level=True)
    ram = AxiRam(AxiBus.from_prefix(dut, "m"), dut.clk, dut.rst,
                 size=1 << 20, reset_active_level=True)
    # seed a 4 KiB window so cold reads see deterministic data
    seed = bytes(range(256)) * 16
    ram.write(0, seed)
    return master


def cyc(start_ns: int, end_ns: int) -> int:
    return int((end_ns - start_ns) / CLK_NS)


@cocotb.test()
async def test_latency_microbench(dut):
    master = await setup(dut)
    line_base = BASE | (50 * BLOCK_B)

    # --- cold read (buffer empty) ---
    t0 = get_sim_time("ns")
    _ = await master.read(line_base, NARROW_B)
    t1 = get_sim_time("ns")
    cold = cyc(t0, t1)
    dut._log.info(f"COLD-READ  (miss + wide R + slice) : {cold:>3} cycles")

    # --- hot reads on the remaining lanes of the same line ---
    hot_cycles = []
    for w in range(1, RATIO):
        ta = get_sim_time("ns")
        _ = await master.read(line_base + w * NARROW_B, NARROW_B)
        tb = get_sim_time("ns")
        hot_cycles.append(cyc(ta, tb))
    dut._log.info(f"HOT-READ   (buffer hit, per access) : min={min(hot_cycles)} "
                  f"max={max(hot_cycles)} avg={sum(hot_cycles)/len(hot_cycles):.1f} cycles "
                  f"({len(hot_cycles)} samples)")

    # --- write to a lane already buffered + read-back (merge path) ---
    addr = line_base + 7 * NARROW_B
    t0 = get_sim_time("ns")
    await master.write(addr, (0xDEADBEEF).to_bytes(NARROW_B, "little"))
    t1 = get_sim_time("ns")
    write_lat = cyc(t0, t1)
    t0 = get_sim_time("ns")
    rb = await master.read(addr, NARROW_B)
    t1 = get_sim_time("ns")
    merge_read = cyc(t0, t1)
    val = int.from_bytes(rb.data, "little")
    assert val == 0xDEADBEEF
    dut._log.info(f"WRITE      (RMW path AW+W+B)        : {write_lat:>3} cycles")
    dut._log.info(f"MERGED-READ(read after write, hit)  : {merge_read:>3} cycles")

    # --- cold read of a DIFFERENT line to confirm cold cost is reproducible ---
    line_other = BASE | (80 * BLOCK_B)
    t0 = get_sim_time("ns")
    _ = await master.read(line_other, NARROW_B)
    t1 = get_sim_time("ns")
    dut._log.info(f"COLD-READ-2(different line)         : {cyc(t0,t1):>3} cycles")
    cold_2 = cyc(t0, t1)

    assert cold <= COLD_READ_MAX, f"cold read latency regressed: {cold}"
    assert max(hot_cycles) <= HOT_READ_MAX, (
        f"hot read latency regressed: max={max(hot_cycles)}"
    )
    assert write_lat <= WRITE_MAX, f"write latency regressed: {write_lat}"
    assert merge_read <= MERGED_READ_MAX, (
        f"merged read latency regressed: {merge_read}"
    )
    assert cold_2 <= COLD_READ_MAX, f"second cold read latency regressed: {cold_2}"
