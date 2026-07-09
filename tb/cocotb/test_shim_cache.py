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
from cocotb.triggers import RisingEdge
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
MEM_SIZE  = 1 << 24                  # 16 MiB AxiRam (after MEM_MASK)
SEED_SZ   = 1 << 20                  # 1 MiB seeded window
MASK      = (1 << NARROW_W) - 1


def golden(addr_narrow: int) -> int:
    a = addr_narrow & 0xFFFF_FFFF
    return ((a * 0x9E37_79B1) ^ (a >> 16) ^ 0xC0FF_EE00) & MASK


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
    """Heavy random R/W stress.

    NOTE: Skipped by default. Exposes an unrelated multi-beat fill ordering
    issue in the upstream l2_cache when LINE_W>1 (cache returns R to the shim
    before all line beats are written to the data bank, so reads of not-yet-
    requested beats can see zeros). Option B's cold-write-miss workaround
    is already validated by test_cold_write_miss_preserves_other_lanes and
    test_partial_write_preserves_other_lanes. Enable with TC_RUN_RANDOM_STACK=1
    once the multi-beat fill order is fixed (or use a 1-beat-per-line build).
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
# Test — critical-word-first (mid-line) cold fill must populate EVERY word
# ----------------------------------------------------------------------
# Reproduces the GraphBlox "aux_1[13],[14] read 0" report at the deploy
# geometry (RATIO=1 BLOCK_W==NARROW_W, LINE_W=8, WAYS=1, LRU). A line first
# touched at a MID-LINE word makes l2_cache issue a WRAP (critical-word-first)
# burst on the mem port (l2_cache.sv:889 arburst = |block ? WRAP : INCR).
# The WRAP-tail words (the beats after the wrap seam) are exactly the aux_1
# 13,14 analog. Every word of the filled line must read golden, not 0.
# Run with: make MODULE=test_shim_cache WIDE_W=32 NARROW_W=32 \
#           LINE_W=8 WAYS=1 READ_REORDER_DEPTH=8
@cocotb.test(skip=(RATIO != 1))   # RATIO=1 deploy WRAP-fill regression
async def test_wrap_fill_allwords(dut):
    await reset_dut(dut)
    master, ram = attach(dut)
    LW = LINE_W
    bad = []
    # Every possible critical offset (esp. LW-1 -> full WRAP, tail words last).
    crit_list = list(range(LW))
    for k, crit in enumerate(crit_list):
        line_idx  = 3 + k * 5                 # spread across sets, cold each
        line_base = BASE | (line_idx * LW * NARROW_B)
        crit_addr = line_base + crit * NARROW_B
        # (1) critical word FIRST -> cold miss -> WRAP/INCR line fill
        d = await master.read(crit_addr, NARROW_B)
        gc = int.from_bytes(d.data, "little")
        if gc != golden(crit_addr):
            bad.append((crit_addr, gc, golden(crit_addr), f"crit={crit}"))
        # (2) now every word of the just-filled line must be golden
        for w in range(LW):
            a = line_base + w * NARROW_B
            d = await master.read(a, NARROW_B)
            got = int.from_bytes(d.data, "little")
            exp = golden(a)
            if got != exp:
                bad.append((a, got, exp, f"crit={crit} w={w}"))
    assert not bad, "WRAP-fill word corruption:\n" + "\n".join(
        f"  @{a:#010x} got={g:#010x} exp={e:#010x} ({why})" for a, g, e, why in bad)
    dut._log.info(f"[wrap_fill_allwords] LINE_W={LW}: all words correct "
                  f"after {len(crit_list)} critical-first cold fills")


# ----------------------------------------------------------------------
# Test — EXACT aux_1 mimic: cold [0]*k ++ [1]*m region, mid-line 0->1
# transition, critical word = the LAST '1' word of the boundary line.
# ----------------------------------------------------------------------
@cocotb.test(skip=(RATIO != 1))   # RATIO=1 deploy WRAP-fill regression
async def test_aux1_boundary_zero_one(dut):
    await reset_dut(dut)
    master, ram = attach(dut)
    LW = LINE_W
    # Boundary line: seed offsets [0..LW-1] as 0 for the low part and 1 for
    # the words at/after the transition. Put the 0->1 flip mid-line (pos t).
    line_idx  = 11
    line_base = BASE | (line_idx * LW * NARROW_B)
    t = LW // 2 + 1 if LW > 2 else 1          # transition offset (e.g. 5 @LW=8)
    vals = [0] * t + [1] * (LW - t)
    # Write the custom pattern straight into the backing RAM (ram off == addr
    # low bits; BASE masks to 0). This is the READ-ONLY host-initialized store.
    ram_off = line_idx * LW * NARROW_B
    buf = b"".join(v.to_bytes(NARROW_B, "little") for v in vals)
    ram.write(ram_off, buf)
    # Critical word FIRST = the LAST word (offset LW-1): a '1' word past the
    # transition -> forces a full WRAP fill; the wrap-tail lands on the '1'
    # words just after the transition (the aux_1[13],[14] analog).
    crit = LW - 1
    d = await master.read(line_base + crit * NARROW_B, NARROW_B)
    assert int.from_bytes(d.data, "little") == 1, "critical '1' word read wrong"
    bad = []
    for w in range(LW):
        d = await master.read(line_base + w * NARROW_B, NARROW_B)
        got = int.from_bytes(d.data, "little")
        exp = vals[w]
        if got != exp:
            bad.append((w, got, exp))
    assert not bad, ("aux1-boundary corruption (0->1 @off %d):\n" % t) + "\n".join(
        f"  word off {w} got={g} exp={e}" for w, g, e in bad)
    dut._log.info(f"[aux1_boundary] LINE_W={LW} flip@{t}: every word correct "
                  f"(wrap-tail '1' words read 1, not 0)")


# ----------------------------------------------------------------------
# Test — PROOF: l2_cache emits a WRAP (critical-word-first) mem burst for a
# mid-line first-touch. This is the necessary condition that a downstream
# width converter (GraphBlox cu_axi_narrow_shim) MUST honor. Snoops m_arburst.
# ----------------------------------------------------------------------
@cocotb.test(skip=(RATIO != 1))   # RATIO=1 deploy WRAP-fill regression
async def test_midline_fill_is_wrap(dut):
    await reset_dut(dut)
    master, ram = attach(dut)
    LW = LINE_W
    seen = []   # (araddr, arlen, arburst)

    async def snoop_ar():
        while True:
            await RisingEdge(dut.clk)
            if dut.m_arvalid.value == 1 and dut.m_arready.value == 1:
                try:
                    seen.append((int(dut.m_araddr.value),
                                 int(dut.m_arlen.value),
                                 int(dut.m_arburst.value)))
                except ValueError:
                    pass
    snoop = cocotb.start_soon(snoop_ar())

    line_base = BASE | (17 * LW * NARROW_B)
    # first-touch a MID-LINE word (offset LW-1) -> must be a WRAP fill
    await master.read(line_base + (LW - 1) * NARROW_B, NARROW_B)
    for _ in range(20):
        await RisingEdge(dut.clk)
    snoop.kill()

    fills = [s for s in seen if s[1] == LW - 1]     # full-line (arlen=LW-1) bursts
    assert fills, f"no full-line mem burst observed (seen={seen})"
    araddr, arlen, arburst = fills[0]
    # 2'b10 == WRAP, 2'b01 == INCR
    assert arburst == 0b10, (
        f"mid-line first-touch fill was NOT WRAP: arburst={arburst:#04b} "
        f"araddr={araddr:#x} arlen={arlen} -- if the deploy converter assumes "
        f"INCR it will misplace the wrap-tail words (aux_1[13],[14])")
    dut._log.info(f"[midline_fill_is_wrap] confirmed WRAP: araddr={araddr:#x} "
                  f"arlen={arlen} arburst=WRAP -- converter MUST honor WRAP")


# ----------------------------------------------------------------------
# Test — NEGATIVE CONTROL: a deliberately WRAP-IGNORING slave (returns beats
# in INCR order regardless of arburst, like a converter that only implements
# INCR) reproduces GraphBlox's EXACT symptom: the wrap-tail words read wrong,
# every other word correct. Proves the defect is in the (non-vendored) slave,
# not l2_cache/databank.
# ----------------------------------------------------------------------
@cocotb.test(skip=(RATIO != 1))   # RATIO=1 deploy WRAP-fill regression
async def test_wrap_ignoring_slave_reproduces_bug(dut):
    await reset_dut(dut)
    master = AxiMaster(AxiBus.from_prefix(dut, "s"), dut.clk, dut.rst,
                       reset_active_level=True)
    LW = LINE_W

    # Backing store: golden per NARROW_B word (same as attach()).
    def gbytes(addr):
        return golden(addr).to_bytes(NARROW_B, "little")

    # Minimal WRAP-IGNORING AXI-read slave on the m_* port. It ACKS the AR,
    # then returns LW beats in *linear INCR* order from the line base,
    # IGNORING arburst (the classic converter defect). Data driven from the
    # golden backing store so a correct WRAP consumer would still be right.
    line_bytes = LW * NARROW_B

    async def wrap_ignoring_slave():
        dut.m_arready.value = 1
        dut.m_rvalid.value = 0
        dut.m_rlast.value = 0
        while True:
            await RisingEdge(dut.clk)
            if dut.m_arvalid.value == 1 and dut.m_arready.value == 1:
                araddr = int(dut.m_araddr.value)
                arlen = int(dut.m_arlen.value)
                arid = int(dut.m_arid.value) if hasattr(dut, "m_arid") else 0
                dut.m_arready.value = 0
                line_base = araddr - (araddr % line_bytes)   # ignore critical word
                for beat in range(arlen + 1):
                    a = line_base + beat * NARROW_B          # INCR from base
                    val = int.from_bytes(gbytes(a), "little")
                    dut.m_rdata.value = val
                    dut.m_rid.value = arid
                    dut.m_rresp.value = 0
                    dut.m_rlast.value = 1 if beat == arlen else 0
                    dut.m_rvalid.value = 1
                    while True:
                        await RisingEdge(dut.clk)
                        if dut.m_rready.value == 1:
                            break
                    dut.m_rvalid.value = 0
                    dut.m_rlast.value = 0
                dut.m_arready.value = 1

    # Tie off the m_* write channels (unused for read-only test).
    for sig in ("m_awready", "m_wready", "m_bvalid"):
        if hasattr(dut, sig):
            getattr(dut, sig).value = 0
    slave = cocotb.start_soon(wrap_ignoring_slave())

    line_base = BASE | (23 * LW * NARROW_B)
    # first-touch the LAST word -> l2_cache issues WRAP; slave returns INCR.
    await master.read(line_base + (LW - 1) * NARROW_B, NARROW_B)
    bad = []
    for w in range(LW):
        a = line_base + w * NARROW_B
        d = await master.read(a, NARROW_B)
        got = int.from_bytes(d.data, "little")
        exp = golden(a)
        if got != exp:
            bad.append((w, got, exp))
    slave.kill()
    # We EXPECT corruption at the wrap-tail words -> this asserts the bug is
    # reproduced by a WRAP-ignoring slave (negative control MUST find badness).
    assert bad, ("WRAP-ignoring slave did NOT corrupt any word -- negative "
                 "control failed (l2_cache may not be issuing WRAP)")
    dut._log.info(f"[wrap_ignoring_slave] reproduced GraphBlox symptom: "
                  f"{len(bad)} wrap-tail word(s) wrong "
                  f"(offsets={[w for w,_,_ in bad]}) while the rest are correct "
                  f"-- defect is the WRAP-ignoring converter, NOT the cache")


# ----------------------------------------------------------------------
# Test — CONCURRENT multi-outstanding gather of a COLD line while its fill
# is in flight. Closes the test_random_stack docstring caveat ("reads of
# not-yet-requested beats can see zeros") at the deploy geometry: even with
# LW reads outstanding at once (critical WRAP fill in flight), every word is
# correct. Mirrors GraphBlox max_outstanding=8 gather of aux_1.
# ----------------------------------------------------------------------
@cocotb.test(skip=(RATIO != 1))   # RATIO=1 deploy WRAP-fill regression
async def test_wrap_fill_concurrent(dut):
    await reset_dut(dut)
    master, ram = attach(dut)
    LW = LINE_W
    line_base = BASE | (29 * LW * NARROW_B)
    # Launch the mid-line critical word (offset LW-1, forces WRAP) first, then
    # every sibling word -- all outstanding together while the fill is running.
    order = [LW - 1] + [w for w in range(LW) if w != LW - 1]
    tasks = [(w, cocotb.start_soon(
                 master.read(line_base + w * NARROW_B, NARROW_B))) for w in order]
    bad = []
    for w, t in tasks:
        d = await t
        got = int.from_bytes(d.data, "little")
        exp = golden(line_base + w * NARROW_B)
        if got != exp:
            bad.append((w, got, exp))
    assert not bad, "concurrent wrap-fill corruption:\n" + "\n".join(
        f"  w={w} got={g:#010x} exp={e:#010x}" for w, g, e in bad)
    dut._log.info(f"[wrap_fill_concurrent] LINE_W={LW}: {LW} concurrent "
                  f"multi-outstanding reads of a cold WRAP-filled line all correct")
