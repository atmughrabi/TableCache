"""ID-width, reorder-depth, and l2_top ID-namespace matrix."""
from __future__ import annotations

import os
import re
import shutil
import subprocess

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SUMMARY_RE = re.compile(r"TESTS=(\d+)\s+PASS=(\d+)\s+FAIL=(\d+)\s+SKIP=(\d+)")

# tag, ID_W, READ_REORDER_DEPTH, MAX_OUTSTANDING_W, DB_LATENCY
SHIM_CELLS = [
    ("id1-d1",   1,  1,  1, 1),
    ("id2-d1",   2,  1,  2, 2),
    ("id2-d2",   2,  2,  2, 1),
    ("id2-d3",   2,  3,  4, 2),
    ("id3-d4",   3,  4,  8, 1),
    ("id3-d7",   3,  7,  8, 2),
    ("id4-d8",   4,  8, 16, 1),
    ("id4-d15",  4, 15, 16, 2),
]

INVALID_CELLS = [
    ("shim-id0",
     ["MODULE=test_shim_id_depth", "ID_W=0", "READ_REORDER_DEPTH=1",
      "MAX_OUTSTANDING_W=1"],
     "ID_W=0 unsupported"),
    ("shim-depth0",
     ["MODULE=test_shim_id_depth", "ID_W=2", "READ_REORDER_DEPTH=0",
      "MAX_OUTSTANDING_W=2"],
     "READ_REORDER_DEPTH=0 unsupported"),
    ("shim-depth-too-large",
     ["MODULE=test_shim_id_depth", "ID_W=2", "READ_REORDER_DEPTH=4",
      "MAX_OUTSTANDING_W=4"],
     "READ_REORDER_DEPTH=4 unsupported"),
    ("shim-write-depth3",
     ["MODULE=test_shim_id_depth", "ID_W=3", "READ_REORDER_DEPTH=1",
      "MAX_OUTSTANDING_W=3"],
     "MAX_OUTSTANDING_W=3 unsupported"),
    ("l2top-id-mismatch-small",
     ["MODULE=test_l2top_ids", "ID_W=2", "M_ID_W=2"],
     "C_M00_AXI_ID_WIDTH=2 must equal"),
    ("l2top-id-mismatch-large",
     ["MODULE=test_l2top_ids", "ID_W=2", "M_ID_W=4"],
     "C_M00_AXI_ID_WIDTH=4 must equal"),
]


def run_make(tag, args, timeout=600, clean=True):
    build_name = f"sim_build_ids_{tag}"
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


def assert_clean_summary(tag, result, output):
    assert result.returncode == 0, (
        f"{tag}: build/sim failed\n---output tail---\n{output[-5000:]}")
    assert "AXI_PC_VIOLATION" not in output, (
        f"{tag}: protocol violation\n---output tail---\n{output[-4000:]}")
    summaries = SUMMARY_RE.findall(output)
    assert summaries and int(summaries[-1][2]) == 0, (
        f"{tag}: bad/missing cocotb summary\n---output tail---\n{output[-3000:]}")


@pytest.mark.parametrize(
    "tag,id_w,depth,max_w,db_latency",
    SHIM_CELLS, ids=[cell[0] for cell in SHIM_CELLS])
def test_shim_id_depth(tag, id_w, depth, max_w, db_latency):
    common = [
        "WIDE_W=32", "NARROW_W=32", "LINE_W=8", "LINES=64",
        "WAYS=2", "POLICY=LRU", f"DB_LATENCY={db_latency}",
        f"ID_W={id_w}", f"READ_REORDER_DEPTH={depth}",
        f"MAX_OUTSTANDING_W={max_w}", "ASSERT=1",
    ]
    result, output = run_make(
        tag, ["MODULE=test_shim_id_depth", *common], timeout=700)
    assert_clean_summary(tag, result, output)
    for define in (
        f"+define+TC_ID_W={id_w}",
        f"+define+TC_READ_REORDER_DEPTH={depth}",
        f"+define+TC_MAX_OUTSTANDING_W={max_w}",
    ):
        assert define in output, f"{tag}: missing compile define {define}"

    if depth > 1:
        result, output = run_make(
            tag, ["MODULE=test_shim_reorder", *common],
            timeout=700, clean=False)
        assert_clean_summary(f"{tag}/reorder", result, output)


@pytest.mark.parametrize("id_w", [1, 2, 3, 4], ids=lambda width: f"id{width}")
def test_l2top_id_namespace(id_w):
    m_id_w = id_w + 1
    args = [
        "MODULE=test_l2top_ids", f"ID_W={id_w}", f"M_ID_W={m_id_w}",
        "LINES=64", "LINE_W=8", "WAYS=2", "POLICY=LRU",
        "DB_LATENCY=1",
    ]
    result, output = run_make(f"l2top_id{id_w}", args, timeout=600)
    assert_clean_summary(f"l2top-id{id_w}", result, output)
    assert f"+define+TC_ID_W={id_w}" in output
    assert f"+define+TC_M_ID_W={m_id_w}" in output


@pytest.mark.parametrize(
    "tag,args,diagnostic",
    INVALID_CELLS, ids=[cell[0] for cell in INVALID_CELLS])
def test_invalid_id_depth_rejected(tag, args, diagnostic):
    common = [
        "WIDE_W=32", "NARROW_W=32", "LINE_W=8", "LINES=64",
        "WAYS=2", "POLICY=LRU", "DB_LATENCY=1",
    ]
    result, output = run_make(tag, [*args, *common], timeout=300)
    assert result.returncode != 0, f"{tag}: invalid configuration unexpectedly passed"
    assert diagnostic in output, (
        f"{tag}: expected diagnostic {diagnostic!r}\n"
        f"---output tail---\n{output[-3000:]}")
