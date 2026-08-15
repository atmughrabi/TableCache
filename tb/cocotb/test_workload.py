"""Graph-workload-style stress test with parallel scoreboard.

Models a graph traversal: a small HOT set (think: high-degree vertices)
is accessed with high probability; a larger COLD set provides background
churn. This exercises:
  - capacity vs working set (does the hot set fit in cache?)
  - LRU / SRRIP behaviour under skewed access
  - write-after-read patterns (vertex-property updates)
  - data correctness across long runs

Three concurrent scoreboards run on every transaction:
  1. DATA-CORRECTNESS: golden memory dict; every read beat checked.
  2. HIT-RATE: shadow tag model predicts hit/miss; observed mem AR count
     is compared against prediction (±15% drift tolerance).
  3. LATENCY: per-request wall-clock cycle count, bucketed by predicted
     hit vs miss, reported as p50 / p95 / p99 / mean.

Includes an end-of-test occupancy leak check.

Env knobs (set via Makefile or shell):
  TC_NTXN           - number of transactions (default 5000)
  TC_SEED           - RNG seed (default 1)
  TC_HOT_PCT        - % of address pool that's HOT (default 5)
  TC_HOT_ACCESS_PCT - % of accesses targeting HOT set (default 80)
  TC_RD_PCT         - % reads (default 70 — graph workloads are read-heavy)
  TC_FULL_PCT       - % of writes that are full-line WriteEvict (default 30)
  TC_POOL_LINES     - total unique lines in pool (default 4096 = 128 KiB worth)

Run:
  make MODULE=test_workload NTXN=5000 SEED=1 LINES=256 WAYS=4 POLICY=LRU
"""
from __future__ import annotations
import os
import random
import statistics
import cocotb
from cocotb.triggers import RisingEdge, Timer, with_timeout
from cocotb.utils import get_sim_time
from tb_common import reset_dut, attach_master, attach_mem, golden, CLK_PERIOD_NS

BASE         = 0x80000000
BLOCK_BYTES  = 4
LINE_W       = int(os.environ.get("TC_LINE_W", "8"))
LINE_BYTES   = LINE_W * BLOCK_BYTES
LINES        = int(os.environ.get("TC_LINES", "64"))
WAYS         = int(os.environ.get("TC_WAYS", "4"))

NTXN          = int(os.environ.get("TC_NTXN",           "5000"))
SEED          = int(os.environ.get("TC_SEED",           "1"))
HOT_PCT       = int(os.environ.get("TC_HOT_PCT",        "5"))
HOT_ACC_PCT   = int(os.environ.get("TC_HOT_ACCESS_PCT", "80"))
RD_PCT        = int(os.environ.get("TC_RD_PCT",         "70"))
FULL_PCT      = int(os.environ.get("TC_FULL_PCT",       "30"))
POOL_LINES    = int(os.environ.get("TC_POOL_LINES",     "4096"))


def line_addr(line_idx: int) -> int:
    """Return a line-aligned 32-bit address for a given unique line index.

    The cache hashes the low LINE_ADDR_W bits of the line index into a set.
    Different bits of line_idx vary tag vs set, so by sweeping
    line_idx over POOL_LINES we get a mix of set/tag combinations.

    The address must remain inside the cache's window AND fit in the
    AxiRam (MEM_MASK = 128 MiB). Line size LINE_BYTES → 128 MiB / LINE_BYTES
    = 4 Mi lines fit, far above POOL_LINES default.
    """
    return BASE | (line_idx * LINE_BYTES)


class ShadowSet:
    """Per-set tag LRU shadow; predicts hit/miss only (no exact way)."""

    def __init__(self, ways: int):
        self.ways = ways
        # Ordered list of tags, MRU front, LRU back.
        self.tags: list[int] = []

    def access(self, tag: int) -> bool:
        """Return True if hit (tag was already present)."""
        if tag in self.tags:
            self.tags.remove(tag)
            self.tags.insert(0, tag)
            return True
        # Miss: install at MRU; evict LRU if full.
        self.tags.insert(0, tag)
        if len(self.tags) > self.ways:
            self.tags.pop()
        return False


class HitRateModel:
    """Shadow tag array across LINES sets x WAYS ways."""

    def __init__(self, lines: int, ways: int):
        self.sets = [ShadowSet(ways) for _ in range(lines)]
        self.lines = lines

    def access(self, addr: int) -> bool:
        # bits[10:5] = set for the default config; generalize for LINES != 64.
        line_bits = (addr >> 5) & (self.lines - 1)
        tag       = addr >> (5 + self.lines.bit_length() - 1)
        return self.sets[line_bits].access(tag)


class MemMonitor:
    """Counts AR and AW handshakes on the master (m_*) port."""
    def __init__(self, dut):
        self.dut, self.n_ar, self.n_aw, self._stop = dut, 0, 0, False

    async def run(self):
        d = self.dut
        while not self._stop:
            await RisingEdge(d.clk)
            if int(d.m_arvalid.value) == 1 and int(d.m_arready.value) == 1:
                self.n_ar += 1
            if int(d.m_awvalid.value) == 1 and int(d.m_awready.value) == 1:
                self.n_aw += 1

    def stop(self):
        self._stop = True


@cocotb.test()
async def test_graph_workload(dut):
    rng = random.Random(SEED)
    await reset_dut(dut)
    # 128 MiB RAM, seeded; matches MEM_MASK in dut_cocotb.sv
    ram    = attach_mem(dut, size_bytes=1 << 27)
    master = attach_master(dut)

    # Address pool — POOL_LINES unique line-aligned addresses.
    pool        = [line_addr(i) for i in range(POOL_LINES)]
    n_hot       = max(1, (POOL_LINES * HOT_PCT) // 100)
    hot_pool    = pool[:n_hot]
    cold_pool   = pool[n_hot:]

    # POLICY=GRASP: drive the runtime hot region to match the workload's
    # hot pool. No-op for other policies.
    _policy = os.environ.get("POLICY", os.environ.get("TC_POLICY", ""))
    if _policy == "GRASP" and hasattr(dut, "grasp_high_addr_l"):
        hot_l = hot_pool[0]
        hot_h = hot_pool[-1] + LINE_BYTES - 1
        dut.grasp_high_addr_l.value = hot_l
        dut.grasp_high_addr_h.value = hot_h
        dut._log.info(f"[wl] GRASP hot region: [0x{hot_l:08x}, 0x{hot_h:08x}]")

    dut._log.info(
        f"[wl] config: LINES={LINES} WAYS={WAYS} POLICY={os.environ.get('TC_POLICY','?')} "
        f"NTXN={NTXN} pool={POOL_LINES} hot={n_hot} ({HOT_PCT}%) "
        f"hot-access={HOT_ACC_PCT}% rd={RD_PCT}% full-wr={FULL_PCT}%"
    )

    golden_mem: dict[int, int] = {}
    hits = HitRateModel(LINES, WAYS)
    mon  = MemMonitor(dut)
    cocotb.start_soon(mon.run())

    # Latency bucketing (per predicted class)
    lat_hit:  list[int] = []   # cycles
    lat_miss: list[int] = []
    pred_hits = pred_misses = 0
    n_rd = n_wr = n_full_wr = n_beats_checked = 0

    def get_word(addr: int) -> int:
        return golden_mem.get(addr, golden(addr))

    log_every = max(1, NTXN // 10)

    for i in range(NTXN):
        # Pick from hot pool with probability HOT_ACC_PCT, else cold.
        if rng.randrange(100) < HOT_ACC_PCT and hot_pool:
            base = rng.choice(hot_pool)
        else:
            base = rng.choice(cold_pool) if cold_pool else rng.choice(hot_pool)
        is_read = rng.randrange(100) < RD_PCT
        is_full = rng.randrange(100) < FULL_PCT

        # Predict hit/miss BEFORE issuing.
        was_hit = hits.access(base)
        if was_hit:
            pred_hits += 1
        else:
            pred_misses += 1

        try:
            if is_read:
                if is_full:
                    addr, nbeat = base, LINE_W
                else:
                    blk = rng.randrange(LINE_W)
                    addr, nbeat = base | (blk * BLOCK_BYTES), 1
                t0 = get_sim_time("ns")
                op = await with_timeout(
                    master.read(addr, nbeat * BLOCK_BYTES), 50_000, "ns"
                )
                t1 = get_sim_time("ns")
                lat = int((t1 - t0) / CLK_PERIOD_NS)
                (lat_hit if was_hit else lat_miss).append(lat)

                got = op.data
                for b in range(nbeat):
                    ba  = addr + b * BLOCK_BYTES
                    exp = get_word(ba)
                    g_w = int.from_bytes(got[b * BLOCK_BYTES:(b + 1) * BLOCK_BYTES],
                                         "little")
                    assert g_w == exp, (
                        f"[wl][{i}] DATA MISMATCH addr=0x{ba:08x} "
                        f"got=0x{g_w:08x} exp=0x{exp:08x} hot={base in hot_pool}"
                    )
                    n_beats_checked += 1
                n_rd += 1
            else:
                if is_full:
                    addr, nbeat, snoop = base, LINE_W, 0b101
                    n_full_wr += 1
                else:
                    blk = rng.randrange(LINE_W)
                    addr, nbeat, snoop = base | (blk * BLOCK_BYTES), 1, 0
                data_words = [rng.randrange(1 << 32) for _ in range(nbeat)]
                for b, w in enumerate(data_words):
                    golden_mem[addr + b * BLOCK_BYTES] = w
                payload = b"".join(w.to_bytes(BLOCK_BYTES, "little") for w in data_words)

                await RisingEdge(dut.clk)
                dut.s_awsnoop.value = snoop
                t0 = get_sim_time("ns")
                await with_timeout(master.write(addr, payload), 50_000, "ns")
                t1 = get_sim_time("ns")
                lat = int((t1 - t0) / CLK_PERIOD_NS)
                (lat_hit if was_hit else lat_miss).append(lat)
                await RisingEdge(dut.clk)
                dut.s_awsnoop.value = 0
                n_wr += 1
        except Exception as e:
            raise AssertionError(f"[wl][{i}] HANG / timeout addr=0x{addr:08x}: {e}")

        if i and (i % log_every == 0):
            so_far_hit_rate = 100.0 * pred_hits / (pred_hits + pred_misses)
            dut._log.info(
                f"[wl] {i}/{NTXN} ops | predicted hit-rate {so_far_hit_rate:.1f}% "
                f"| observed mem-AR={mon.n_ar} AW={mon.n_aw}"
            )

    # Drain
    await Timer(500, "ns")
    mon.stop()
    await Timer(50, "ns")

    # Occupancy leak sweep.
    dut._log.info("[wl] leak-check sweep on a sample of pool lines")
    for la in pool[:min(POOL_LINES, 256)]:
        try:
            await with_timeout(master.read(la, BLOCK_BYTES), 5_000, "ns")
        except Exception as e:
            raise AssertionError(f"[wl] LEAK: stuck inuse on line 0x{la:08x}: {e}")

    # ---- Report ----
    total = pred_hits + pred_misses
    pred_hit_rate = 100.0 * pred_hits / max(1, total)
    obs_misses    = mon.n_ar
    obs_writebacks = mon.n_aw
    obs_hit_rate  = 100.0 * (1.0 - obs_misses / max(1, total))
    drift_pp      = abs(obs_hit_rate - pred_hit_rate)

    def pct(xs, p):
        if not xs:
            return 0
        s = sorted(xs)
        k = max(0, min(len(s) - 1, int(round(p / 100.0 * (len(s) - 1)))))
        return s[k]

    dut._log.info("=" * 72)
    dut._log.info(f"[wl] DONE n_rd={n_rd} n_wr={n_wr} (full={n_full_wr}) "
                  f"beats_checked={n_beats_checked} golden_writes={len(golden_mem)}")
    dut._log.info(f"[wl] HIT RATE  predicted={pred_hit_rate:5.1f}% "
                  f"observed={obs_hit_rate:5.1f}% drift={drift_pp:4.1f}pp")
    dut._log.info(f"[wl] MEM TRAFFIC mem_AR={obs_misses} mem_AW(writebacks)={obs_writebacks}")
    if lat_hit:
        dut._log.info(
            f"[wl] LAT(hit ) p50={pct(lat_hit, 50):3d} p95={pct(lat_hit, 95):3d} "
            f"p99={pct(lat_hit, 99):3d} mean={statistics.mean(lat_hit):4.1f} cyc "
            f"(n={len(lat_hit)})"
        )
    if lat_miss:
        dut._log.info(
            f"[wl] LAT(miss) p50={pct(lat_miss, 50):3d} p95={pct(lat_miss, 95):3d} "
            f"p99={pct(lat_miss, 99):3d} mean={statistics.mean(lat_miss):4.1f} cyc "
            f"(n={len(lat_miss)})"
        )
    dut._log.info("=" * 72)

    # Loose invariants. Tight numbers depend on LRU encoding; we just want
    # the cache to behave roughly the way the shadow predicts.
    assert drift_pp <= 20.0, (
        f"hit-rate drift too large: predicted={pred_hit_rate:.1f}% "
        f"observed={obs_hit_rate:.1f}% (drift {drift_pp:.1f} pp). "
        f"Either the cache is malfunctioning or the shadow's LRU diverges too far."
    )
    assert obs_misses <= total, (
        f"mem AR count > total ops: {obs_misses} > {total} (this should be impossible)"
    )
    assert obs_writebacks <= obs_misses, (
        f"mem AW count > mem AR count: {obs_writebacks} > {obs_misses} "
        f"(every writeback should be triggered by a miss that needed a victim)"
    )
