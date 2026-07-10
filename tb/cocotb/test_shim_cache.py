"""
End-to-end shim + l2_cache integration test.

Topology:  AxiMaster(NARROW_W) -> tc_narrow_shim -> l2_cache -> AxiRam(BLOCK_W)

Goals:
1. Smoke: narrow R/W round-trips with golden checking.
2. Heavy random: 5000+ ops with byte-level golden tracking; ensure data
   correctness through the full stack.
3. Locality replay: hot/cold workload that exercises cache eviction +
   shim line buffer interaction.
"""
import logging
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge
from cocotbext.axi import AxiBus, AxiMaster, AxiRam

# Suppress chatty per-transaction INFO logs from cocotbext-axi; they dominate
# wall time at BLOCK_W=512. Override with TC_AXI_LOG=INFO (or DEBUG) if needed.
_AXI_LOG_LVL = getattr(logging, os.environ.get("TC_AXI_LOG", "WARNING").upper(), logging.WARNING)
logging.getLogger("cocotbext.axi").setLevel(_AXI_LOG_LVL)
for _n in ("cocotb.dut_shim_cache.s", "cocotb.dut_shim_cache.m"):
    logging.getLogger(_n).setLevel(_AXI_LOG_LVL)

CLK_NS    = 10
BASE      = 0x8000_0000
NARROW_W  = int(os.environ.get("TC_NARROW_W", "32"))
BLOCK_W   = int(os.environ.get("TC_BLOCK_W",  "512"))
NARROW_B  = NARROW_W // 8
BLOCK_B   = BLOCK_W  // 8
RATIO     = BLOCK_W  // NARROW_W
LINES     = int(os.environ.get("TC_LINES",  "128"))
LINE_W    = int(os.environ.get("TC_LINE_W", "2"))
WAYS      = int(os.environ.get("TC_WAYS",   "8"))
READ_REORDER_DEPTH = int(os.environ.get("TC_READ_REORDER_DEPTH", "1"))
MEM_SIZE  = 1 << 24                  # 16 MiB AxiRam (after MEM_MASK)
SEED_SZ   = 1 << 20                  # 1 MiB seeded window
MASK      = (1 << NARROW_W) - 1
CACHE_LINE_B = LINE_W * BLOCK_B
WORDS_PER_LINE = LINE_W * RATIO


def golden(addr_narrow: int) -> int:
    a = addr_narrow & 0xFFFF_FFFF
    return ((a * 0x9E37_79B1) ^ (a >> 16) ^ 0xC0FF_EE00) & MASK


def cache_line_base(line_idx: int) -> int:
    return BASE + line_idx * CACHE_LINE_B


def cache_word_addr(line_base: int, block: int, lane: int = 0) -> int:
    return line_base + block * BLOCK_B + lane * NARROW_B


def line_word_addr(line_base: int, word: int) -> int:
    return line_base + word * NARROW_B


def assert_bus_geometry(dut):
    assert len(dut.s_rdata) == NARROW_W, (
        f"test expected NARROW_W={NARROW_W}, DUT s_rdata is {len(dut.s_rdata)} bits")
    assert len(dut.m_rdata) == BLOCK_W, (
        f"test expected BLOCK_W={BLOCK_W}, DUT m_rdata is {len(dut.m_rdata)} bits")


async def check_cached_line(master, line_base: int, expected=None):
    values = expected or [golden(line_word_addr(line_base, w))
                          for w in range(WORDS_PER_LINE)]
    bad = []
    for word, exp in enumerate(values):
        addr = line_word_addr(line_base, word)
        data = await master.read(addr, NARROW_B)
        got = int.from_bytes(data.data, "little")
        if got != exp:
            bad.append((word, addr, got, exp))
    return bad


async def reset_dut(dut):
    # Scale reset to LINES (sdp_ram_rst LFSR walk needs 2^ADDR_WIDTH).
    cycles = max(64, LINES * 2)
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    dut.rst.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


def attach(dut):
    master = AxiMaster(AxiBus.from_prefix(dut, "s"), dut.clk, dut.rst,
                       reset_active_level=True)
    ram = AxiRam(AxiBus.from_prefix(dut, "m"), dut.clk, dut.rst,
                 size=MEM_SIZE, reset_active_level=True)
    # Seed each NARROW_B word with deterministic golden pattern.
    seed = bytearray(SEED_SZ)
    for off in range(0, SEED_SZ, NARROW_B):
        seed[off:off + NARROW_B] = golden(BASE | off).to_bytes(NARROW_B, "little")
    ram.write(0, bytes(seed))
    return master, ram


# ----------------------------------------------------------------------
# Test 1 — smoke through full stack
# ----------------------------------------------------------------------
@cocotb.test()
async def test_smoke(dut):
    await reset_dut(dut)
    master, _ram = attach(dut)
    # N reads at random aligned addresses; env-tunable.
    n = int(os.environ.get("TC_SMOKE_N", "8"))
    rng = random.Random(0x5C0FFEE)
    n_ok = 0
    for _ in range(n):
        addr = BASE | (rng.randrange(0, SEED_SZ // NARROW_B) * NARROW_B)
        data = await master.read(addr, NARROW_B)
        got = int.from_bytes(data.data, "little")
        assert got == golden(addr), f"R@{addr:#x}: got {got:#x} want {golden(addr):#x}"
        n_ok += 1
    dut._log.info(f"[smoke] {n_ok}/{n} reads OK")


# ----------------------------------------------------------------------
# Test 2 — locality replay: hot lines + write-merge through cache
# ----------------------------------------------------------------------
@cocotb.test()
async def test_locality(dut):
    await reset_dut(dut)
    master, _ram = attach(dut)
    # Cover all RATIO lanes of one line with read+write+read.
    line_base = BASE | (10 * BLOCK_B)
    for w in range(RATIO):
        addr = line_base + w * NARROW_B
        # Initial read returns golden
        data = await master.read(addr, NARROW_B)
        got = int.from_bytes(data.data, "little")
        assert got == golden(addr)
        # Overwrite with new value
        new = (0xA000_0000 | w) & MASK
        await master.write(addr, new.to_bytes(NARROW_B, "little"))
        # Read back: must reflect new value
        data = await master.read(addr, NARROW_B)
        got = int.from_bytes(data.data, "little")
        assert got == new, f"after-write@{addr:#x}: got {got:#x} want {new:#x}"
    dut._log.info(f"[locality] {RATIO} lanes RW round-trip OK")


# ----------------------------------------------------------------------
# Test 3 — random R/W stress through the full stack with golden mirror
# ----------------------------------------------------------------------
@cocotb.test()
async def test_cold_write_miss_preserves_other_lanes(dut):
    """Write FIRST to fresh line lane 5 (no prior read), then read lane 0.
    Cache must do a write-miss RMW: fetch from mem, merge byte mask, install.
    Lane 0 must come back as the original golden value, NOT zero.
    """
    await reset_dut(dut)
    master, _ram = attach(dut)
    line_base = BASE | (250 * BLOCK_B)            # untouched fresh line
    lane5_addr = line_base + 5 * NARROW_B
    new = 0xDEADBEEF & MASK
    # Write WITHOUT prior read — forces cold-write-miss RMW path
    await master.write(lane5_addr, new.to_bytes(NARROW_B, "little"))
    # Now read lane 0 — must be golden, untouched
    data0 = await master.read(line_base, NARROW_B)
    got0 = int.from_bytes(data0.data, "little")
    data5 = await master.read(lane5_addr, NARROW_B)
    got5 = int.from_bytes(data5.data, "little")
    dut._log.info(f"[cold_write_miss] lane0={got0:#x} want {golden(line_base):#x}; "
                  f"lane5={got5:#x} want {new:#x}")
    assert got5 == new, f"lane5 lost: got {got5:#x} want {new:#x}"
    assert got0 == golden(line_base), \
        f"lane0 corrupted by cold-write-miss: got {got0:#x} want {golden(line_base):#x}"


@cocotb.test()
async def test_partial_write_preserves_other_lanes(dut):
    """Single write to lane 5 of a fresh line; verify lane 0 still golden."""
    await reset_dut(dut)
    master, _ram = attach(dut)
    line_base = BASE | (200 * BLOCK_B)            # untouched fresh line
    # Read lane 0 first to ensure golden is reachable
    data = await master.read(line_base, NARROW_B)
    lane0_pre = int.from_bytes(data.data, "little")
    assert lane0_pre == golden(line_base), \
        f"lane0 pre-write: got {lane0_pre:#x} want {golden(line_base):#x}"
    # Write only lane 5
    lane5_addr = line_base + 5 * NARROW_B
    new = 0xCAFEBABE & MASK
    await master.write(lane5_addr, new.to_bytes(NARROW_B, "little"))
    # Lane 0 must still be golden, lane 5 must be 0xCAFEBABE
    data0 = await master.read(line_base, NARROW_B)
    got0 = int.from_bytes(data0.data, "little")
    data5 = await master.read(lane5_addr, NARROW_B)
    got5 = int.from_bytes(data5.data, "little")
    dut._log.info(f"[partial_write] lane0={got0:#x} (want {golden(line_base):#x}) "
                  f"lane5={got5:#x} (want {new:#x})")
    assert got5 == new, f"lane5 write lost: got {got5:#x} want {new:#x}"
    assert got0 == golden(line_base), \
        f"lane0 corrupted by lane5 write: got {got0:#x} want {golden(line_base):#x}"


@cocotb.test()
async def test_read_then_other_line_read_then_read(dut):
    """Regression for the tdp_ram for-loop NBA Verilator quirk.

    Read line A → read line B (cold miss-fill) → re-read line A. Before the
    `tdp_ram.sv` mask-based rewrite, the second cold fill (any further
    fill, actually) silently dropped 63 of the 64 bytes written to its
    target way, but the bug only became visible on a subsequent hit because
    the all-zeros byte slot happened to be untouched until the next read.
    This minimal three-op sequence flushes that artefact into a single
    deterministic mismatch.
    """
    await reset_dut(dut)
    master, _ram = attach(dut)
    addr_a = BASE | 0x70
    addr_b = BASE | 0x73c
    d = await master.read(addr_a, NARROW_B)
    got_a1 = int.from_bytes(d.data, "little")
    assert got_a1 == golden(addr_a)
    d = await master.read(addr_b, NARROW_B)
    got_b = int.from_bytes(d.data, "little")
    assert got_b == golden(addr_b), f"R@B: got {got_b:#x} want {golden(addr_b):#x}"
    d = await master.read(addr_a, NARROW_B)
    got_a2 = int.from_bytes(d.data, "little")
    dut._log.info(f"[repro-RR] A1={got_a1:#x} B={got_b:#x} A2={got_a2:#x}")
    assert got_a2 == golden(addr_a), f"step3 R@A corrupted by R@B: got {got_a2:#x}"


@cocotb.test()
async def test_read_then_other_line_write_then_read(dut):
    """Same as the RRR variant but with a cold-write-miss on line B in
    between. Was the original symptom of the tdp_ram for-loop NBA bug —
    Option B's prefill_AR made it visible at the integration level.
    """
    await reset_dut(dut)
    master, _ram = attach(dut)
    addr_a = BASE | 0x70
    addr_b = BASE | 0x73c
    d = await master.read(addr_a, NARROW_B)
    got_a1 = int.from_bytes(d.data, "little")
    assert got_a1 == golden(addr_a), \
        f"step1 R@{addr_a:#x}: got {got_a1:#x} want {golden(addr_a):#x}"
    new = 0x35BF992D & MASK
    await master.write(addr_b, new.to_bytes(NARROW_B, "little"))
    d = await master.read(addr_a, NARROW_B)
    got_a2 = int.from_bytes(d.data, "little")
    dut._log.info(f"[repro-WR] step1 R@A={got_a1:#x} step3 R@A={got_a2:#x} "
                  f"want {golden(addr_a):#x}")
    assert got_a2 == golden(addr_a), \
        f"step3 R@{addr_a:#x} corrupted by W@{addr_b:#x}: got {got_a2:#x} want {golden(addr_a):#x}"


@cocotb.test()
async def test_random_stack(dut):
    """Serial random R/W stress with a byte-accurate golden mirror.

    This test intentionally awaits each transaction, so fill-time concurrency
    is covered separately by test_wrap_fill_concurrent.
    """
    await reset_dut(dut)
    master, _ram = attach(dut)

    # Sanity-probe: verify AxiRam returns golden for an address we'll touch.
    probe_addr = BASE | 0x70
    data = await master.read(probe_addr, NARROW_B)
    got = int.from_bytes(data.data, "little")
    exp = golden(probe_addr)
    assert got == exp, \
        f"probe failed @{probe_addr:#x}: got {got:#x} want {exp:#x} " \
        f"(AxiRam seed or cache initial-fill broken)"
    dut._log.info(f"[random_stack] probe@{probe_addr:#x} OK ({got:#x})")

    # NOTE: BLOCK_W=512 Verilator sim is slow (~1 op/sec wall); keep N small
    # by default. Bump via TC_NTXN for long-soak campaigns.
    N = int(os.environ.get("TC_NTXN", "100"))
    seed = int(os.environ.get("TC_SEED", "1"))
    rd_pct = int(os.environ.get("TC_RATIO_RD", "60"))
    hot_pct_access = int(os.environ.get("TC_HOT_ACCESS_PCT", "70"))

    rng = random.Random(seed)
    # Hot pool: small enough that the cache should retain most of it.
    line_pool = [BASE | (i * BLOCK_B) for i in range(SEED_SZ // BLOCK_B)]
    hot_n = 32                           # 32 lines * 64 B = 2 KiB hot
    hot_lines  = line_pool[:hot_n]
    cold_lines = line_pool[hot_n:]

    gold_bytes = bytearray(SEED_SZ)
    for off in range(0, SEED_SZ, NARROW_B):
        gold_bytes[off:off + NARROW_B] = golden(BASE | off).to_bytes(NARROW_B, "little")

    mismatches = 0
    trace = os.environ.get("TC_TRACE_OPS", "0") == "1"
    for k in range(N):
        if rng.randint(0, 99) < hot_pct_access:
            line = rng.choice(hot_lines)
        else:
            line = rng.choice(cold_lines)
        lane = rng.randrange(RATIO)
        addr = line + lane * NARROW_B

        if rng.randint(0, 99) < rd_pct:
            data = await master.read(addr, NARROW_B)
            got = int.from_bytes(data.data, "little")
            base_off = addr - BASE
            exp = int.from_bytes(gold_bytes[base_off:base_off + NARROW_B], "little")
            if trace:
                tag = "OK " if got == exp else "BAD"
                dut._log.warning(f"op{k:03d} R @{addr:#010x} got={got:#010x} exp={exp:#010x} {tag}")
            if got != exp:
                mismatches += 1
                if mismatches <= 5:
                    dut._log.error(f"txn{k} R@{addr:#x}: got {got:#x} want {exp:#x}")
        else:
            v = rng.randrange(1 << NARROW_W)
            vb = v.to_bytes(NARROW_B, "little")
            await master.write(addr, vb)
            base_off = addr - BASE
            gold_bytes[base_off:base_off + NARROW_B] = vb
            if trace:
                dut._log.warning(f"op{k:03d} W @{addr:#010x} val={v:#010x}")

    assert mismatches == 0, f"{mismatches} mismatches in {N} ops"
    dut._log.info(f"[random_stack] {N} ops @ {rd_pct}%R hot={hot_pct_access}% "
                  f"-- 0 mismatches "
                  f"(POLICY=cfg LINES={LINES} WAYS={WAYS} BLOCK_W={BLOCK_W})")


# ----------------------------------------------------------------------
# Generic critical-word-first line-fill regressions.
#
# AxiRam is the WRAP-compliant reference slave. The negative-control test
# below models the historical downstream-converter mutation explicitly.
# ----------------------------------------------------------------------
@cocotb.test()
async def test_wrap_fill_allwords(dut):
    """Every critical block offset must fill every narrow word of the line."""
    await reset_dut(dut)
    master, _ram = attach(dut)
    assert_bus_geometry(dut)

    bad = []
    for crit in range(LINE_W):
        line_base = cache_line_base(3 + crit * 5)
        crit_lane = (crit * 3 + 1) % RATIO
        crit_addr = cache_word_addr(line_base, crit, crit_lane)
        data = await master.read(crit_addr, NARROW_B)
        got = int.from_bytes(data.data, "little")
        exp = golden(crit_addr)
        if got != exp:
            bad.append((crit_lane + crit * RATIO, crit_addr, got, exp, crit))

        for word, addr, got, exp in await check_cached_line(master, line_base):
            bad.append((word, addr, got, exp, crit))

    assert not bad, "critical-first fill corruption:\n" + "\n".join(
        f"  crit_block={crit} word={word} @{addr:#010x} "
        f"got={got:#x} exp={exp:#x}"
        for word, addr, got, exp, crit in bad)
    dut._log.info(
        f"[wrap_fill_allwords] BLOCK_W={BLOCK_W} NARROW_W={NARROW_W} "
        f"RATIO={RATIO} LINE_W={LINE_W}: every word correct after every "
        f"critical-block cold fill")


@cocotb.test()
async def test_aux1_boundary_zero_one(dut):
    """Cold [0]*k ++ [1]*m line with a mid-line transition stays bit-exact."""
    await reset_dut(dut)
    master, ram = attach(dut)
    assert_bus_geometry(dut)

    line_base = cache_line_base(11)
    transition = WORDS_PER_LINE // 2 + 1 if WORDS_PER_LINE > 2 else 1
    values = [0] * transition + [1] * (WORDS_PER_LINE - transition)
    ram.write(line_base - BASE, b"".join(
        value.to_bytes(NARROW_B, "little") for value in values))

    critical_word = WORDS_PER_LINE - 1
    critical_addr = line_word_addr(line_base, critical_word)
    data = await master.read(critical_addr, NARROW_B)
    assert int.from_bytes(data.data, "little") == 1, (
        f"critical word {critical_word} read wrong")

    bad = await check_cached_line(master, line_base, values)
    assert not bad, (
        f"0->1 boundary corruption (transition word={transition}):\n" +
        "\n".join(f"  word={word} got={got} exp={exp}"
                  for word, _addr, got, exp in bad))
    dut._log.info(
        f"[aux1_boundary] RATIO={RATIO} LINE_W={LINE_W} transition="
        f"{transition}/{WORDS_PER_LINE}: every word correct")


@cocotb.test()
async def test_midline_fill_is_wrap(dut):
    """Check AR address, length, size, and burst type at every critical block."""
    await reset_dut(dut)
    master, _ram = attach(dut)
    assert_bus_geometry(dut)
    seen = []

    async def snoop_ar():
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.m_arvalid) and int(dut.m_arready):
                seen.append((int(dut.m_araddr), int(dut.m_arlen),
                             int(dut.m_arsize), int(dut.m_arburst)))

    snoop = cocotb.start_soon(snoop_ar())
    expected_size = BLOCK_B.bit_length() - 1

    for crit in range(LINE_W):
        before = len(seen)
        line_base = cache_line_base(17 + crit * 3)
        crit_addr = cache_word_addr(line_base, crit, RATIO - 1)
        await master.read(crit_addr, NARROW_B)
        for _ in range(20):
            await RisingEdge(dut.clk)
            if len(seen) > before:
                break

        fills = [entry for entry in seen[before:] if entry[1] == LINE_W - 1]
        assert len(fills) == 1, (
            f"critical block {crit}: expected one full-line AR, saw {seen[before:]}")
        araddr, arlen, arsize, arburst = fills[0]
        expected_burst = 0b01 if crit == 0 else 0b10
        observed_block = (araddr // BLOCK_B) % LINE_W
        assert arlen == LINE_W - 1
        assert arsize == expected_size, (
            f"critical block {crit}: arsize={arsize}, expected {expected_size}")
        assert arburst == expected_burst, (
            f"critical block {crit}: arburst={arburst:#04b}, expected "
            f"{'INCR' if crit == 0 else 'WRAP'}")
        assert observed_block == crit, (
            f"critical block {crit}: m_araddr={araddr:#x} starts at block "
            f"{observed_block}, not the requested critical block")

    snoop.kill()
    dut._log.info(
        f"[fill_ar_contract] LINE_W={LINE_W}: block0=INCR, blocks1.."
        f"{LINE_W-1}=WRAP; addr/len/size all correct")


@cocotb.test()
async def test_wrap_fill_backpressure(dut):
    """WRAP fills stay correct under memory-R and master-R backpressure."""
    from test_backpressure import burst_pause

    await reset_dut(dut)
    master, ram = attach(dut)
    pc_before = int(dut.pc_violations_total.value)
    ram.read_if.r_channel.set_pause_generator(
        burst_pause(random.Random(0xA11CE), pause_max=10, run_max=3))
    master.read_if.r_channel.set_pause_generator(
        burst_pause(random.Random(0xBACC), pause_max=8, run_max=2))

    critical_blocks = sorted({1, LINE_W // 2, LINE_W - 1})
    bad = []
    for index, crit in enumerate(critical_blocks):
        line_base = cache_line_base(37 + index * 5)
        critical_addr = cache_word_addr(line_base, crit, RATIO - 1)
        data = await master.read(critical_addr, NARROW_B)
        got = int.from_bytes(data.data, "little")
        exp = golden(critical_addr)
        if got != exp:
            bad.append((crit * RATIO + RATIO - 1, critical_addr, got, exp, crit))
        for word, addr, got, exp in await check_cached_line(master, line_base):
            bad.append((word, addr, got, exp, crit))

    assert not bad, "WRAP-fill corruption under backpressure:\n" + "\n".join(
        f"  crit={crit} word={word} @{addr:#x} got={got:#x} exp={exp:#x}"
        for word, addr, got, exp, crit in bad)
    pc_after = int(dut.pc_violations_total.value)
    assert pc_after == pc_before, (
        f"new AXI protocol violations under WRAP-fill backpressure: "
        f"before={pc_before} after={pc_after}")


@cocotb.test()
async def test_wrap_fill_concurrent(dut):
    """Same-id gather remains correct; ROB>1 must accept real overlap."""
    await reset_dut(dut)
    master, _ram = attach(dut)
    state = {"inflight": 0, "peak": 0, "ar": 0, "r": 0}

    async def monitor_engine_reads():
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            ar = int(dut.s_arvalid) and int(dut.s_arready)
            r = int(dut.s_rvalid) and int(dut.s_rready) and int(dut.s_rlast)
            state["ar"] += int(ar)
            state["r"] += int(r)
            state["inflight"] += int(ar) - int(r)
            state["peak"] = max(state["peak"], state["inflight"])

    monitor = cocotb.start_soon(monitor_engine_reads())
    line_base = cache_line_base(29)
    block_order = [LINE_W - 1] + list(range(LINE_W - 1))
    requests = []
    for block in block_order:
        lane = (block * 5 + 1) % RATIO
        addr = cache_word_addr(line_base, block, lane)
        requests.append((addr, cocotb.start_soon(
            master.read(addr, NARROW_B, arid=0))))

    bad = []
    for addr, task in requests:
        data = await task
        got = int.from_bytes(data.data, "little")
        exp = golden(addr)
        if got != exp:
            bad.append((addr, got, exp))
    for _ in range(2):
        await RisingEdge(dut.clk)
    monitor.kill()

    assert not bad, "concurrent WRAP-fill corruption:\n" + "\n".join(
        f"  @{addr:#x} got={got:#x} exp={exp:#x}"
        for addr, got, exp in bad)
    assert state["ar"] == LINE_W and state["r"] == LINE_W, (
        f"AR/R count mismatch: ar={state['ar']} r={state['r']} "
        f"expected={LINE_W}")
    if READ_REORDER_DEPTH > 1:
        assert state["peak"] > 1, (
            f"READ_REORDER_DEPTH={READ_REORDER_DEPTH} but reads did not overlap "
            f"(peak={state['peak']})")
    else:
        assert state["peak"] <= 1, (
            f"passthrough depth accepted {state['peak']} same-id reads concurrently")
    dut._log.info(
        f"[wrap_fill_concurrent] LINE_W={LINE_W} ROB={READ_REORDER_DEPTH}: "
        f"peak engine outstanding={state['peak']}, all data correct")


@cocotb.test()
async def test_wrap_fill_refill_direct_mapped(dut):
    """A WRAP-filled line remains correct after deterministic eviction/refill."""
    if WAYS != 1:
        dut._log.info(
            f"[wrap_fill_refill] not applicable at WAYS={WAYS}; "
            "direct-mapped eviction proof skipped")
        return
    await reset_dut(dut)
    master, _ram = attach(dut)
    seen = []

    async def snoop_ar():
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.m_arvalid) and int(dut.m_arready):
                if int(dut.m_arlen) == LINE_W - 1:
                    araddr = int(dut.m_araddr)
                    seen.append(araddr - araddr % CACHE_LINE_B)

    monitor = cocotb.start_soon(snoop_ar())
    target_idx = 7
    conflict_idx = target_idx + LINES
    target = cache_line_base(target_idx)
    conflict = cache_line_base(conflict_idx)
    target_mem_base = target - BASE
    conflict_mem_base = conflict - BASE

    await master.read(cache_word_addr(target, LINE_W - 1, RATIO - 1), NARROW_B)
    await master.read(cache_word_addr(conflict, max(1, LINE_W // 2),
                                     RATIO - 1), NARROW_B)
    await master.read(cache_word_addr(target, max(1, LINE_W // 2),
                                     RATIO - 1), NARROW_B)
    for _ in range(5):
        await RisingEdge(dut.clk)
    assert seen == [target_mem_base, conflict_mem_base, target_mem_base], (
        f"expected target/conflict/target miss sequence, saw mem line ARs={seen}")

    fills_before_check = len(seen)
    bad = await check_cached_line(master, target)
    for _ in range(10):
        await RisingEdge(dut.clk)
    monitor.kill()

    assert not bad, "refilled target line corrupted:\n" + "\n".join(
        f"  word={word} @{addr:#x} got={got:#x} exp={exp:#x}"
        for word, addr, got, exp in bad)
    assert len(seen) == fills_before_check, (
        f"checking the refilled line caused extra misses: mem line ARs={seen}")
    dut._log.info(
        f"[wrap_fill_refill] target filled, evicted by same-set conflict, "
        f"and refilled correctly (mem AR sequence={seen[:3]})")
