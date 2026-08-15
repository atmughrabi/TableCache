"""
cocotb test for tc_narrow_shim.

DUT topology:
    AxiMaster(width=NARROW_W=32) ─► dut_shim_only ─► AxiRam(width=BLOCK_W=512)

Goals
-----
1. Functional correctness:
   - Reads return the right narrow word for any aligned 4-B address.
   - Writes update only the addressed bytes (rest of the line survives).
   - Random R/W with per-byte golden checking.
2. L0 line buffer:
   - Sequential reads within one line produce ONE wide AR (16 buffer hits).
   - Write to a line invalidates the buffer (next read sees fresh data).
3. AW->W FIFO ordering across IDs.
"""
import logging
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, Timer
from cocotbext.axi import AxiBus, AxiMaster, AxiRam

# Suppress chatty per-transaction INFO logs from cocotbext-axi; they dominate
# wall time at BLOCK_W=512. Override with TC_AXI_LOG=INFO (or DEBUG) if needed.
_AXI_LOG_LVL = getattr(logging, os.environ.get("TC_AXI_LOG", "WARNING").upper(), logging.WARNING)
logging.getLogger("cocotbext.axi").setLevel(_AXI_LOG_LVL)
for _n in ("cocotb.dut_shim_only.s", "cocotb.dut_shim_only.m"):
    logging.getLogger(_n).setLevel(_AXI_LOG_LVL)

CLK_PERIOD_NS    = 10
BASE             = 0x8000_0000
NARROW_W         = int(os.environ.get("TC_NARROW_W", "32"))
BLOCK_W          = int(os.environ.get("TC_BLOCK_W",  "512"))
NARROW_B         = NARROW_W // 8
BLOCK_B          = BLOCK_W  // 8
RATIO            = BLOCK_W  // NARROW_W
MEM_SIZE_BYTES   = 1 << 20                # 1 MiB shadow on the wide port
SEED_BYTES       = 1 << 17                # 128 KiB seeded
WORD_MASK        = (1 << NARROW_W) - 1


def golden_word(addr_narrow: int) -> int:
    """Deterministic 32-bit golden pattern per narrow word."""
    a = addr_narrow & 0xFFFF_FFFF
    return ((a * 0x9E37_79B1) ^ (a >> 16) ^ 0xC0FF_EE00) & WORD_MASK


async def reset_and_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    dut.rst.value = 1
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


def attach(dut):
    master = AxiMaster(AxiBus.from_prefix(dut, "s"), dut.clk, dut.rst,
                       reset_active_level=True)
    ram    = AxiRam(AxiBus.from_prefix(dut, "m"), dut.clk, dut.rst,
                    size=MEM_SIZE_BYTES, reset_active_level=True)
    # Seed each 4-B word with its golden pattern.
    seed = bytearray(SEED_BYTES)
    for off in range(0, SEED_BYTES, NARROW_B):
        seed[off:off + NARROW_B] = golden_word(BASE | off).to_bytes(NARROW_B, "little")
    ram.write(0, bytes(seed))
    return master, ram


class MemMonitor:
    """Counts wide AR/AW handshakes for line-buffer effectiveness checking."""
    def __init__(self, dut):
        self.dut = dut
        self.ar = 0
        self.aw = 0

    async def run(self):
        while True:
            await RisingEdge(self.dut.clk)
            await ReadOnly()
            if int(self.dut.m_arvalid) and int(self.dut.m_arready):
                self.ar += 1
            if int(self.dut.m_awvalid) and int(self.dut.m_awready):
                self.aw += 1


@cocotb.test()
async def test_basic_read(dut):
    await reset_and_clock(dut)
    master, _ram = attach(dut)

    # 8 reads in clearly distinct aligned lines — data-correctness only.
    # AR-count behaviour is covered by test_line_buffer_hits.
    for i in range(8):
        addr = BASE | (i * BLOCK_B * 4)
        data = await master.read(addr, NARROW_B)
        val  = int.from_bytes(data.data, "little")
        assert val == golden_word(addr), \
            f"read@{addr:#x}: got {val:#x} want {golden_word(addr):#x}"
    dut._log.info("[basic_read] 8 distinct-line reads OK")


@cocotb.test()
async def test_line_buffer_hits(dut):
    await reset_and_clock(dut)
    master, ram = attach(dut)
    mon = MemMonitor(dut); cocotb.start_soon(mon.run())

    line_base = BASE | (4 * BLOCK_B)            # arbitrary aligned line
    for w in range(RATIO):
        addr = line_base + w * NARROW_B
        data = await master.read(addr, NARROW_B)
        val  = int.from_bytes(data.data, "little")
        assert val == golden_word(addr), \
            f"buf-read@{addr:#x}: got {val:#x} want {golden_word(addr):#x}"
    assert mon.ar == 1, \
        f"line buffer broken: {RATIO} sequential reads issued {mon.ar} wide ARs"
    dut._log.info(f"[line_buffer_hits] {RATIO} reads -> {mon.ar} wide AR OK")


# Targets mutation `drop_buf_drain_term`: if ar_buf_drain_this_cycle is
# forced to 0, the buffer can hold only ONE pending response at a time;
# 4 reads fired back-to-back would either hang or take much longer.
@cocotb.test()
async def test_buffered_reads_pipelined(dut):
    await reset_and_clock(dut)
    master, ram = attach(dut)
    mon = MemMonitor(dut); cocotb.start_soon(mon.run())

    line_base = BASE | (5 * BLOCK_B)
    # Warm the buffer with the first read (forces a wide AR; sets lb_valid).
    _ = await master.read(line_base, NARROW_B)
    ar_after_warm = mon.ar
    assert ar_after_warm == 1, f"expected 1 warm AR, got {ar_after_warm}"

    # Fire 4 same-line narrow reads back-to-back via start_soon. They must
    # all complete within a reasonable timeout, and produce NO additional
    # wide AR (all serviced by the L0 buffer drain path).
    from cocotb.triggers import with_timeout
    tasks = [cocotb.start_soon(master.read(line_base + (w + 1) * NARROW_B, NARROW_B))
             for w in range(4)]
    for w, t in enumerate(tasks):
        data = await with_timeout(t, 5_000, "ns")
        got = int.from_bytes(data.data, "little")
        addr = line_base + (w + 1) * NARROW_B
        assert got == golden_word(addr), \
            f"buf-pipeline@{addr:#x}: got {got:#x} want {golden_word(addr):#x}"
    assert mon.ar == ar_after_warm, \
        f"buffer drain path broken: extra wide ARs {mon.ar - ar_after_warm}"
    dut._log.info("[buffered_reads_pipelined] 4 pipelined buffered reads -> 0 extra AR OK")


# Targets mutations `drop_m_arready_dep` (s_arready ignores m_arready)
# and `drop_prefill_check` (m_arvalid asserted during active prefill).
# Forces the shim to hold s_arready/m_arvalid stable across a stall.
@cocotb.test()
async def test_mem_arready_backpressure(dut):
    import random as _r
    from cocotb.triggers import with_timeout
    await reset_and_clock(dut)
    master, ram = attach(dut)
    mon = MemMonitor(dut); cocotb.start_soon(mon.run())

    # Pause m_arready aggressively: 1-cycle runs, 1..20-cycle stalls.
    rng = _r.Random(0xCAFE_BABE)
    def burst_pause():
        while True:
            yield 0
            for _ in range(rng.randint(1, 20)):
                yield 1
    ram.read_if.ar_channel.set_pause_generator(burst_pause())

    # Sequence: narrow write to one line (triggers prefill), then narrow
    # read to a DIFFERENT line (regular miss), then read-back the write
    # to verify it landed correctly. Repeat over several line pairs.
    for k in range(8):
        line_w = BASE | ((10 + 2*k) * BLOCK_B)
        line_r = BASE | ((11 + 2*k) * BLOCK_B)
        val    = (k * 0x1234_5678) & WORD_MASK

        await with_timeout(
            master.write(line_w + 2 * NARROW_B, val.to_bytes(NARROW_B, "little")),
            50_000, "ns")
        rd = await with_timeout(master.read(line_r, NARROW_B), 50_000, "ns")
        got = int.from_bytes(rd.data, "little")
        assert got == golden_word(line_r), \
            f"mem-bp miss-line@{line_r:#x}: got {got:#x} want {golden_word(line_r):#x}"

        rd = await with_timeout(master.read(line_w + 2 * NARROW_B, NARROW_B), 50_000, "ns")
        got = int.from_bytes(rd.data, "little")
        assert got == val, \
            f"mem-bp write-line@{line_w + 2*NARROW_B:#x}: got {got:#x} want {val:#x}"

    dut._log.info(f"[mem_arready_backpressure] 8 W/R/R sequences under m_arready stall OK (ar={mon.ar} aw={mon.aw})")


@cocotb.test()
async def test_write_invalidates_buffer(dut):
    await reset_and_clock(dut)
    master, ram = attach(dut)
    mon = MemMonitor(dut); cocotb.start_soon(mon.run())

    line_base = BASE | (6 * BLOCK_B)
    # Warm buffer
    _ = await master.read(line_base, NARROW_B)
    ar_before = mon.ar

    # Mutate lane 3 with a new value
    lane = 3
    new_val = 0xDEAD_BEEF & WORD_MASK
    await master.write(line_base + lane * NARROW_B,
                       new_val.to_bytes(NARROW_B, "little"))

    # Read it back — must be the new value, not the buffered stale one
    data = await master.read(line_base + lane * NARROW_B, NARROW_B)
    val  = int.from_bytes(data.data, "little")
    assert val == new_val, \
        f"stale buffer: got {val:#x} want {new_val:#x}"

    # Other lanes in the same line should still match golden (RMW preserved them)
    for w in range(RATIO):
        if w == lane:
            continue
        addr = line_base + w * NARROW_B
        data = await master.read(addr, NARROW_B)
        got  = int.from_bytes(data.data, "little")
        assert got == golden_word(addr), \
            f"RMW corrupted lane {w}: got {got:#x} want {golden_word(addr):#x}"

    dut._log.info(f"[write_invalidates_buffer] OK (mem ARs: {ar_before}->{mon.ar})")


@cocotb.test()
async def test_aw_fifo_burst(dut):
    await reset_and_clock(dut)
    master, ram = attach(dut)

    N = 16
    addrs = [BASE | (32 * BLOCK_B + i * NARROW_B) for i in range(N)]
    vals  = [random.Random(0xABCD + i).randrange(1 << NARROW_W) for i in range(N)]

    # Fire all writes without waiting
    futures = [master.write(a, v.to_bytes(NARROW_B, "little"))
               for a, v in zip(addrs, vals)]
    for f in futures:
        await f

    # Read back: all values must match
    for a, want in zip(addrs, vals):
        data = await master.read(a, NARROW_B)
        got = int.from_bytes(data.data, "little")
        assert got == want, \
            f"AW-burst readback @{a:#x}: got {got:#x} want {want:#x}"
    dut._log.info(f"[aw_fifo_burst] {N} writes + readbacks OK")


@cocotb.test()
async def test_random_rw(dut):
    await reset_and_clock(dut)
    master, ram = attach(dut)

    rng = random.Random(int(os.environ.get("TC_SEED", "1")))
    # Default N is BLOCK_W-aware: at BLOCK_W=512 each op runs Verilator's
    # wide-bus simulation, so default 30 keeps wall time bounded. Override
    # via TC_NTXN for long-soak campaigns.
    default_n = "30" if BLOCK_W >= 512 else "300"
    N   = int(os.environ.get("TC_NTXN", default_n))
    rd_pct = int(os.environ.get("TC_RATIO_RD", "60"))

    # Golden memory mirror per narrow word (within SEED_BYTES window).
    gold = {}
    def gold_get(addr):
        return gold.get(addr, golden_word(addr))

    # Restrict to seeded window
    max_word_addr = SEED_BYTES - NARROW_B
    pool = [BASE | (i * NARROW_B) for i in range(max_word_addr // NARROW_B)]

    mismatches = 0
    for k in range(N):
        addr = rng.choice(pool)
        if rng.randint(0, 99) < rd_pct:
            data = await master.read(addr, NARROW_B)
            got  = int.from_bytes(data.data, "little")
            exp  = gold_get(addr) & WORD_MASK
            if got != exp:
                mismatches += 1
                dut._log.error(f"txn[{k}] R@{addr:#x}: got {got:#x} want {exp:#x}")
        else:
            v = rng.randrange(1 << NARROW_W)
            await master.write(addr, v.to_bytes(NARROW_B, "little"))
            gold[addr] = v

    assert mismatches == 0, f"{mismatches} read mismatches in {N} txns"
    dut._log.info(f"[random_rw] {N} txns ({rd_pct}% R) clean")


@cocotb.test()
async def test_write_merge_no_refetch(dut):
    await reset_and_clock(dut)
    master, _ram = attach(dut)
    mon = MemMonitor(dut); cocotb.start_soon(mon.run())

    line_base = BASE | (10 * BLOCK_B)
    # Warm the buffer with a read of lane 0.
    _ = await master.read(line_base, NARROW_B)
    # Write lane 5 with a new value.
    lane = 5
    new_val = 0xCAFEBABE & WORD_MASK
    await master.write(line_base + lane * NARROW_B,
                       new_val.to_bytes(NARROW_B, "little"))
    # Read lane 5 from the merged buffer without another wide AR.
    ar_before_read = mon.ar
    data = await master.read(line_base + lane * NARROW_B, NARROW_B)
    val  = int.from_bytes(data.data, "little")
    ar_after_read  = mon.ar

    assert val == new_val, f"merge mismatch: got {val:#x} want {new_val:#x}"
    assert ar_after_read == ar_before_read, \
        f"buffer should hit after merge: AR before={ar_before_read} after={ar_after_read}"

    # Verify that untouched lanes retain their original data.
    data0 = await master.read(line_base, NARROW_B)
    val0  = int.from_bytes(data0.data, "little")
    assert val0 == golden_word(line_base), \
        f"untouched lane0 corrupted: got {val0:#x} want {golden_word(line_base):#x}"

    dut._log.info(f"[write_merge_no_refetch] OK (total wide ARs: {mon.ar})")


@cocotb.test()
async def test_full_line_rmw_scan(dut):
    await reset_and_clock(dut)
    master, _ram = attach(dut)
    mon = MemMonitor(dut); cocotb.start_soon(mon.run())

    line_base = BASE | (20 * BLOCK_B)
    # Warm-up read so all subsequent writes have a buffer to merge into.
    _ = await master.read(line_base, NARROW_B)
    new_vals = [(0xA0000000 | (i << 4) | i) & WORD_MASK for i in range(RATIO)]
    # Write every lane
    for i, v in enumerate(new_vals):
        await master.write(line_base + i * NARROW_B,
                           v.to_bytes(NARROW_B, "little"))
    ar_after_writes = mon.ar
    # Read every lane back
    for i, expect in enumerate(new_vals):
        data = await master.read(line_base + i * NARROW_B, NARROW_B)
        got  = int.from_bytes(data.data, "little")
        assert got == expect, f"lane{i}: got {got:#x} want {expect:#x}"
    ar_after_reads = mon.ar

    assert ar_after_reads == ar_after_writes, \
        f"writes + reads should not refetch: AR after writes={ar_after_writes} after reads={ar_after_reads}"
    dut._log.info(f"[full_line_rmw_scan] {RATIO} W+R after warmup, "
                  f"wide ARs={mon.ar} (expected 1)")


# Short-data write at a sub-lane offset: AxiMaster derives wstrb automatically.
# Validates that the shim+merge handles short-byte writes correctly.
@cocotb.test()
async def test_subword_write_merge(dut):
    await reset_and_clock(dut)
    master, _ram = attach(dut)

    line_base = BASE | (30 * BLOCK_B)
    lane      = 2
    addr      = line_base + lane * NARROW_B
    # Warm + read original
    data = await master.read(addr, NARROW_B)
    old  = int.from_bytes(data.data, "little")
    # Write only the low 2 bytes (AxiMaster derives wstrb=0b0011 from len=2)
    new_low = 0x1234
    await master.write(addr, new_low.to_bytes(2, "little"))
    expect  = (old & 0xFFFF_0000) | new_low
    data    = await master.read(addr, NARROW_B)
    got     = int.from_bytes(data.data, "little")
    assert got == expect, \
        f"sub-word merge: got {got:#x} want {expect:#x} (old {old:#x})"
    dut._log.info(f"[subword_write_merge] old={old:#x} -> got={got:#x} OK")


@cocotb.test()
async def test_other_line_write_no_corruption(dut):
    await reset_and_clock(dut)
    master, _ram = attach(dut)
    mon = MemMonitor(dut); cocotb.start_soon(mon.run())

    line_A = BASE | (40 * BLOCK_B)
    line_B = BASE | (41 * BLOCK_B)
    # Warm buffer with line A
    _ = await master.read(line_A, NARROW_B)
    # Write to line B
    bw = 0xDEADBEEF & WORD_MASK
    await master.write(line_B + 3 * NARROW_B, bw.to_bytes(NARROW_B, "little"))
    # Read back line A's first lane — should still be in buffer with golden
    data = await master.read(line_A, NARROW_B)
    val  = int.from_bytes(data.data, "little")
    assert val == golden_word(line_A), \
        f"line-A buffer corrupted by line-B write: got {val:#x} want {golden_word(line_A):#x}"
    # Read line B back — verifies the write actually landed
    data = await master.read(line_B + 3 * NARROW_B, NARROW_B)
    val  = int.from_bytes(data.data, "little")
    assert val == bw, f"line-B write lost: got {val:#x} want {bw:#x}"
    dut._log.info(f"[other_line_write_no_corruption] wide ARs={mon.ar}")


@cocotb.test()
async def test_heavy_random(dut):
    await reset_and_clock(dut)
    master, _ram = attach(dut)

    N_TXN  = int(os.environ.get("TC_NTXN", "1000"))
    SEEDS  = int(os.environ.get("TC_SHIM_SEEDS", "3"))
    rd_pct = int(os.environ.get("TC_RATIO_RD", "55"))

    # Byte-granular golden mirror keyed by absolute address.
    gold_bytes = bytearray(SEED_BYTES)
    for off in range(0, SEED_BYTES, NARROW_B):
        gold_bytes[off:off + NARROW_B] = golden_word(BASE | off).to_bytes(NARROW_B, "little")

    mismatches = 0
    total = 0
    # Bias addresses toward a small hot set so the line-buffer merge
    # path is exercised heavily.
    hot_lines  = 32                                  # 32 lines = 64*32 = 2 KiB
    cold_lines = (SEED_BYTES // BLOCK_B) - hot_lines
    line_pool = [BASE | (i * BLOCK_B) for i in range(SEED_BYTES // BLOCK_B)]

    for seed_i in range(SEEDS):
        rng = random.Random(0x1000 + seed_i * 31)
        for k in range(N_TXN):
            # 70% hot, 30% cold
            if rng.randint(0, 99) < 70:
                line = line_pool[rng.randrange(hot_lines)]
            else:
                line = line_pool[hot_lines + rng.randrange(cold_lines)]
            lane = rng.randrange(RATIO)
            addr = line + lane * NARROW_B
            total += 1

            if rng.randint(0, 99) < rd_pct:
                # Read
                data = await master.read(addr, NARROW_B)
                got  = int.from_bytes(data.data, "little")
                exp  = int.from_bytes(gold_bytes[addr - BASE:addr - BASE + NARROW_B],
                                      "little")
                if got != exp:
                    mismatches += 1
                    if mismatches <= 8:
                        dut._log.error(f"seed{seed_i} txn{k} R@{addr:#x}: "
                                       f"got {got:#x} want {exp:#x}")
            else:
                # Write (full-width; sub-word strobes tested separately)
                v  = rng.randrange(1 << NARROW_W)
                vb = v.to_bytes(NARROW_B, "little")
                await master.write(addr, vb)
                base_off = addr - BASE
                gold_bytes[base_off:base_off + NARROW_B] = vb

    assert mismatches == 0, f"{mismatches} mismatches in {total} txns"
    dut._log.info(f"[heavy_random] {total} txns x {SEEDS} seeds, 0 mismatches")
