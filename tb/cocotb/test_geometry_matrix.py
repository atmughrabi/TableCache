"""Generic cache-geometry and long-stress matrix."""
from __future__ import annotations

import os
import re
import shutil
import subprocess

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SUMMARY_RE = re.compile(r"TESTS=(\d+)\s+PASS=(\d+)\s+FAIL=(\d+)\s+SKIP=(\d+)")

LRU_WAYS = [2, 3, 4, 5, 8]
ODD_POLICY_CELLS = [
    ("FRQ-w3", "FRQ", 3),
    ("SC-w3", "SECOND_CHANCE", 3),
    ("RANDOM-w5", "RANDOM", 5),
    ("SRRIP-w3", "SRRIP", 3),
    ("GRASP-w5", "GRASP", 5),
]
LINE_CELLS = [2, 8, 128, 512, 1024]
BANK_CELLS = [
    ("b1-c1", 1, 1, 64),
    ("b2-c4", 2, 4, 64),
    ("b4-c8", 4, 8, 64),
    ("b8-c2", 8, 2, 64),
    ("one-line-per-bank", 4, 1, 4),
]
INVALID_CELLS = [
    ("lines1", ["MODULE=test_smoke", "LINES=1"], "LINES=1 unsupported"),
    ("lines3", ["MODULE=test_smoke", "LINES=3"], "LINES=3 unsupported"),
    ("ways0", ["MODULE=test_smoke", "WAYS=0"], None),
    ("cascade0",
     ["MODULE=test_smoke", "DATABANK_SDP=1", "CASCADE_DEPTH=0"],
     "CASCADE_DEPTH=0 unsupported"),
    ("cascade9",
     ["MODULE=test_smoke", "DATABANK_SDP=1", "CASCADE_DEPTH=9"],
     "CASCADE_DEPTH=9 unsupported"),
    ("banks3",
     ["MODULE=test_smoke", "DATABANK_SDP=1", "N_BANKS=3"],
     "N_BANKS=3 must be a power of two"),
    ("banks0",
     ["MODULE=test_smoke", "DATABANK_SDP=1", "N_BANKS=0"],
     "N_BANKS=0 unsupported"),
    ("shim-banks3",
     ["MODULE=test_shim_cache", "WIDE_W=32", "NARROW_W=32",
      "DATABANK_SDP=1", "N_BANKS=3"],
     "N_BANKS=3 must be a power of two"),
    ("l2top-banks3",
     ["MODULE=test_l2top", "DATABANK_SDP=1", "N_BANKS=3"],
     "N_BANKS=3 must be a power of two"),
    ("victim1",
     ["MODULE=test_smoke", "VICTIM=1", "VICTIM_LINES=1"],
     "victim_cache: LINES=1 unsupported"),
    ("tagwidth0",
     ["MODULE=test_smoke", "ADDR_L=0x80000000", "ADDR_H=0x800007FF",
      "LINES=64", "LINE_W=8"],
     "TAG_W=0"),
    ("id-width-mismatch",
     ["MODULE=test_smoke", "READ_ID_W=1", "WRITE_ID_W=2"],
     "READ_ID_WIDTH=1 must equal WRITE_ID_WIDTH=2"),
    ("axi-beat-too-wide",
     ["MODULE=test_shim_cache", "WIDE_W=2048", "NARROW_W=32"],
     "BLOCK_W=2048 must be"),
    ("range-nonpow2",
     ["MODULE=test_smoke", "ADDR_L=0x80000000", "ADDR_H=0x8FFFFFFE"],
     "span 0x00fffffff is not a power of two"),
    ("range-misaligned",
     ["MODULE=test_smoke", "ADDR_L=0x90000000", "ADDR_H=0xAFFFFFFF"],
     "not aligned to span"),
]

STRESS_CELLS = [
    (
        "tiny-direct",
        ["LINES=2", "WAYS=1", "LINE_W=2", "DB_LATENCY=2",
         "POLICY=LRU", "VICTIM=0"],
        [("test_random", ["NTXN=1200", "SEED=41"]),
         ("test_eviction", [])],
    ),
    (
        "odd-victim",
        ["LINES=32", "WAYS=3", "LINE_W=8", "DB_LATENCY=2",
         "POLICY=LRU", "VICTIM=1", "VICTIM_LINES=3"],
        [("test_random", ["NTXN=1200", "SEED=43"]),
         ("test_eviction", [])],
    ),
    (
        "large-sdp-banked",
        ["LINES=1024", "WAYS=8", "LINE_W=16", "DB_LATENCY=2",
         "POLICY=GRASP", "VICTIM=0", "DATABANK_SDP=1",
         "SDP_WRITE_INPUT_REG=1", "N_BANKS=4", "CASCADE_DEPTH=1"],
        [("test_random", ["NTXN=600", "SEED=47"]),
         ("test_eviction", [])],
    ),
]


def run_make(tag, args, timeout=600, clean=True):
    build_name = f"sim_build_geometry_{tag}"
    if clean:
        shutil.rmtree(os.path.join(HERE, build_name), ignore_errors=True)
    try:
        os.remove(os.path.join(HERE, "results.xml"))
    except FileNotFoundError:
        pass
    cmd = ["make", f"SIM_BUILD={build_name}", *args]
    result = subprocess.run(
        cmd, cwd=HERE, env=os.environ.copy(), capture_output=True,
        text=True, timeout=timeout)
    return result, result.stdout + result.stderr


def assert_pass(tag, result, output):
    assert result.returncode == 0, (
        f"{tag}: build/sim failed\n---output tail---\n{output[-5000:]}")
    assert "AXI_PC_VIOLATION" not in output, (
        f"{tag}: protocol violation\n---output tail---\n{output[-4000:]}")
    summaries = SUMMARY_RE.findall(output)
    assert summaries and int(summaries[-1][2]) == 0, (
        f"{tag}: bad/missing summary\n---output tail---\n{output[-3000:]}")


@pytest.mark.parametrize("ways", LRU_WAYS, ids=lambda ways: f"w{ways}")
def test_exact_lru_ways(ways):
    args = [
        "MODULE=test_lru_exact", "POLICY=LRU", f"WAYS={ways}",
        "LINES=32", "LINE_W=8", "VICTIM=0",
    ]
    result, output = run_make(f"lru_w{ways}", args)
    assert_pass(f"LRU-W{ways}", result, output)


@pytest.mark.parametrize(
    "tag,policy,ways", ODD_POLICY_CELLS,
    ids=[cell[0] for cell in ODD_POLICY_CELLS])
def test_odd_way_policy_stress(tag, policy, ways):
    args = [
        "MODULE=test_random", f"POLICY={policy}", f"WAYS={ways}",
        "LINES=32", "LINE_W=8", "DB_LATENCY=2",
        "NTXN=400", "SEED=37",
    ]
    result, output = run_make(tag, args)
    assert_pass(tag, result, output)


@pytest.mark.parametrize("lines", LINE_CELLS, ids=lambda lines: f"lines{lines}")
def test_line_count_sweep(lines):
    args = [
        "MODULE=test_random", f"LINES={lines}", "WAYS=2", "LINE_W=8",
        "POLICY=SRRIP", "DB_LATENCY=2", "NTXN=300", "SEED=31",
    ]
    result, output = run_make(f"lines{lines}", args, timeout=900)
    assert_pass(f"LINES={lines}", result, output)


@pytest.mark.parametrize("victim_lines", [3, 5, 8], ids=lambda lines: f"vlines{lines}")
def test_victim_capacity_sweep(victim_lines):
    common = [
        "VICTIM=1", f"VICTIM_LINES={victim_lines}", "LINES=64",
        "WAYS=4", "LINE_W=8", "POLICY=LRU",
    ]
    result, output = run_make(
        f"victim{victim_lines}", ["MODULE=test_victim", *common], timeout=700)
    assert_pass(f"victim-lines={victim_lines}", result, output)
    result, output = run_make(
        f"victim{victim_lines}", ["MODULE=test_eviction", *common],
        timeout=700, clean=False)
    assert_pass(f"victim-lines={victim_lines}/eviction", result, output)


@pytest.mark.parametrize(
    "tag,banks,cascade,lines", BANK_CELLS, ids=[cell[0] for cell in BANK_CELLS])
def test_sdp_bank_cascade(tag, banks, cascade, lines):
    args = [
        "MODULE=test_random", "DATABANK_SDP=1",
        f"N_BANKS={banks}", f"CASCADE_DEPTH={cascade}",
        f"LINES={lines}", "WAYS=4", "LINE_W=8", "DB_LATENCY=2",
        "POLICY=GRASP", "NTXN=400", "SEED=53",
    ]
    result, output = run_make(tag, args, timeout=700)
    assert_pass(tag, result, output)
    assert f"+define+TC_N_BANKS={banks}" in output
    assert f"+define+TC_CASCADE_DEPTH={cascade}" in output


@pytest.mark.parametrize(
    "tag,args,diagnostic", INVALID_CELLS,
    ids=[cell[0] for cell in INVALID_CELLS])
def test_invalid_geometry_rejected(tag, args, diagnostic):
    common = [
        "LINES=64", "WAYS=4", "LINE_W=8", "POLICY=LRU",
        "DB_LATENCY=1",
    ]
    result, output = run_make(tag, [*common, *args], timeout=300)
    assert result.returncode != 0, f"{tag}: invalid geometry unexpectedly passed"
    if diagnostic is not None:
        assert diagnostic in output, (
            f"{tag}: expected diagnostic {diagnostic!r}\n"
            f"---output tail---\n{output[-3000:]}")


@pytest.mark.parametrize(
    "tag,common,modules", STRESS_CELLS,
    ids=[cell[0] for cell in STRESS_CELLS])
def test_long_geometry_stress(tag, common, modules):
    first = True
    for module, extra in modules:
        result, output = run_make(
            tag, [f"MODULE={module}", *common, *extra],
            timeout=1200, clean=first)
        first = False
        assert_pass(f"{tag}/{module}", result, output)
