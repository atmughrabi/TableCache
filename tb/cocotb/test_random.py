"""Cocotb port of t03 random scoreboard.

Random RD/WR mix over an 8 set x 16 tag address pool. Maintains a sparse
golden dictionary; verifies reads, including a final read-back of every
written address. Drives `s_awsnoop = 0b101` for full-line writes
(WriteEvict, the only snoop the cache treats as full-line) so we exercise
the no-RMW fast path. Single-beat writes use `s_awsnoop = 0b000` (RMW).

Run:
  source .venv/bin/activate
  make MODULE=test_random NTXN=200 SEED=1
Env knobs (set via Makefile or shell): TC_NTXN, TC_SEED, TC_RATIO_RD,
TC_RATIO_FULL.
"""
from __future__ import annotations
import os
import random
import cocotb
from cocotb.triggers import RisingEdge, Timer, with_timeout
from tb_common import BASE, reset_dut, attach_master, attach_mem, golden
from tb_coverage import sample_read, sample_write, dump_coverage

BLOCK_BYTES  = 4
LINE_W       = int(os.environ.get("TC_LINE_W", "8"))
LINE_BYTES   = LINE_W * BLOCK_BYTES
LINES        = int(os.environ.get("TC_LINES", "64"))

NTXN         = int(os.environ.get("TC_NTXN", "100"))
SEED         = int(os.environ.get("TC_SEED", "1"))
RATIO_RD_PCT = int(os.environ.get("TC_RATIO_RD", "60"))
RATIO_FULL_PCT = int(os.environ.get("TC_RATIO_FULL", "70"))

NUM_SETS = min(8, LINES)
NUM_TAGS = 16


def line_addr(set_i: int, tag_i: int) -> int:
    return BASE + ((tag_i * LINES + set_i) * LINE_BYTES)


@cocotb.test()
async def test_random_scoreboard(dut):
    rng = random.Random(SEED)
    await reset_dut(dut)
    ram = attach_mem(dut, size_bytes=1 << 20)
    master = attach_master(dut)

    golden_mem: dict[int, int] = {}  # byte-addr (BASE-relative or absolute) -> 32-bit word

    def get_word(addr: int) -> int:
        if addr in golden_mem:
            return golden_mem[addr]
        return golden(addr)

    n_rd = n_wr = n_full = n_single = n_beats = 0

    for i in range(NTXN):
        s = rng.randrange(NUM_SETS)
        t = rng.randrange(NUM_TAGS)
        la = line_addr(s, t)
        is_read = rng.randrange(100) < RATIO_RD_PCT
        is_full = rng.randrange(100) < RATIO_FULL_PCT
        dut._log.info(f"[t03c][{i}] {'RD' if is_read else 'WR'} {'full' if is_full else 'single'} s={s} t={t}")

        if is_read:
            if is_full:
                addr  = la
                nbeat = LINE_W
            else:
                # Choose nbeat from {1, 2, 4} to fill beat_x_snoop cross cells.
                # Each beat is one BLOCK_BYTES; addr must stay within the line.
                nbeat = rng.choice([beats for beats in (1, 2, 4)
                                    if beats <= LINE_W])
                max_blk = LINE_W - nbeat
                blk   = rng.randrange(max_blk + 1)
                addr  = la + blk * BLOCK_BYTES
            try:
                op = await with_timeout(master.read(addr, nbeat * BLOCK_BYTES), 10_000, "ns")
            except Exception as e:
                dut._log.error(
                    f"[t03c][{i}] RD HANG addr=0x{addr:08x} nbeat={nbeat} "
                    f"s={s} t={t} -- {e}"
                )
                raise
            sample_read(addr, nbeat, 0)
            got = op.data
            for b in range(nbeat):
                ba = addr + b * BLOCK_BYTES
                exp = get_word(ba)
                got_w = int.from_bytes(got[b * BLOCK_BYTES:(b + 1) * BLOCK_BYTES], "little")
                assert got_w == exp, (
                    f"[t03c][{i}] RD addr=0x{addr:08x} beat{b} "
                    f"got=0x{got_w:08x} exp=0x{exp:08x}"
                )
                n_beats += 1
            n_rd += 1
        else:
            if is_full:
                addr  = la
                nbeat = LINE_W
                snoop = 0b101  # WriteEvict (cache's only true full-line shortcut)
                n_full += 1
            else:
                # Choose nbeat from {1, 2, 4, 8} for plain writes; partial=False
                # because we drive full strobes here. partial=True cells are
                # filled by test_strobe.
                nbeat = rng.choice([beats for beats in (1, 2, 4, LINE_W)
                                    if beats <= LINE_W])
                max_blk = LINE_W - nbeat
                blk   = rng.randrange(max_blk + 1)
                addr  = la + blk * BLOCK_BYTES
                snoop = 0b000  # plain write
                n_single += 1
            data_words = [rng.randrange(1 << 32) for _ in range(nbeat)]
            # Update golden BEFORE the cache observes the write.
            for b, w in enumerate(data_words):
                golden_mem[addr + b * BLOCK_BYTES] = w
            payload = b"".join(w.to_bytes(BLOCK_BYTES, "little") for w in data_words)

            # Drive snoop sideband for the AW handshake. Must be set BEFORE
            # AW asserts and held across handshake. The simplest race-free
            # approach is to assert at posedge, then issue the write.
            await RisingEdge(dut.clk)
            dut.s_awsnoop.value = snoop
            try:
                await with_timeout(master.write(addr, payload), 10_000, "ns")
            except Exception as e:
                dut._log.error(
                    f"[t03c][{i}] WR HANG addr=0x{addr:08x} nbeat={nbeat} "
                    f"s={s} t={t} snoop={snoop:b} -- {e}"
                )
                raise
            sample_write(addr, nbeat, snoop, False)
            await RisingEdge(dut.clk)
            dut.s_awsnoop.value = 0
            n_wr += 1

    # Final read-back of every written line / address
    for addr, exp in sorted(golden_mem.items()):
        op = await master.read(addr, BLOCK_BYTES)
        got = int.from_bytes(op.data, "little")
        assert got == exp, (
            f"[t03c] final readback addr=0x{addr:08x} got=0x{got:08x} exp=0x{exp:08x}"
        )

    await Timer(200, "ns")
    dut._log.info(
        f"[t03c] DONE n_rd={n_rd} n_wr={n_wr} (full={n_full} single={n_single}) "
        f"beats_checked={n_beats} golden_writes={len(golden_mem)}"
    )

    # ---- inuse-leak end-of-test assertion (regression net for bug #6 class) ----
    # If any inuse_id or inuse_line bit is still set after the final drain, the
    # NEXT request targeting that (id, hash) will hang. Sweep every
    # (set, tag) x rolling-id so any stuck bit surfaces as a per-op timeout
    # rather than as a much harder-to-diagnose future-run hang.
    dut._log.info("[t03c] leak-check sweep: every (set, tag) x rolling id")
    leak_id = 0
    for ts in range(NUM_TAGS):
        for ss in range(NUM_SETS):
            addr = line_addr(ss, ts)
            try:
                await with_timeout(master.read(addr, BLOCK_BYTES), 2_000, "ns")
            except Exception as e:
                raise AssertionError(
                    f"[t03c] LEAK CHECK FAIL: stuck inuse on set={ss} tag={ts} "
                    f"addr=0x{addr:08x} -- {e}"
                )
            leak_id = (leak_id + 1) & 0xF
    dut._log.info("[t03c] leak-check sweep clean (no stuck inuse_id / inuse_line)")
    path = dump_coverage("test_random")
    dut._log.info(f"[t03c] coverage exported to {path}")
