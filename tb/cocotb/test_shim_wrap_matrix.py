"""Focused matrix for critical-word-first mem-side line fills.

The matrix factors the meaningful axes instead of crossing replacement-policy
settings exhaustively. Every cell checks all critical block offsets, every
narrow lane, AR WRAP/INCR metadata, response/memory backpressure, and same-id
gather behavior. One direct-mapped cell also proves eviction/refill.

Run:
    source .venv/bin/activate
    pytest -q test_shim_wrap_matrix.py
"""
from __future__ import annotations

import pytest

from matrix_utils import assert_clean_summary, run_make

POSITIVE_TESTS = ",".join([
    "test_wrap_fill_allwords",
    "test_sparse_boundary_zero_one",
    "test_midline_fill_is_wrap",
    "test_wrap_fill_backpressure",
    "test_wrap_fill_concurrent",
    "test_wrap_fill_refill_direct_mapped",
])

# id, WIDE_W, NARROW_W, LINE_W, WAYS, POLICY, DB_LATENCY, ROB, SDP, SDP_REG
WRAP_MATRIX = [
    ("deploy-r1-l8",       32, 32,  8, 1, "LRU",   1, 8, 0, 0),
    ("min-r1-l2-rob1",     32, 32,  2, 2, "SRRIP", 1, 1, 0, 0),
    ("max-r1-l16-sdp",     64, 64, 16, 8, "GRASP", 2, 8, 1, 1),
    ("r2-l4",              64, 32,  4, 2, "LRU",   1, 4, 0, 0),
    ("r4-l8-db2",         128, 32,  8, 4, "SRRIP", 2, 8, 0, 0),
    ("r8-l4",             256, 32,  4, 4, "GRASP", 1, 8, 0, 0),
    ("r16-l2-db2-sdp",    512, 32,  2, 8, "LRU",   2, 8, 1, 0),
]

@pytest.mark.parametrize(
    "tag,wide,narrow,line_w,ways,policy,db_latency,rob,sdp,sdp_reg",
    WRAP_MATRIX, ids=[cell[0] for cell in WRAP_MATRIX])
def test_wrap_matrix(tag, wide, narrow, line_w, ways, policy, db_latency,
                     rob, sdp, sdp_reg):
    args = [
        "MODULE=test_shim_cache",
        f"WIDE_W={wide}",
        f"NARROW_W={narrow}",
        f"LINE_W={line_w}",
        "LINES=64",
        f"WAYS={ways}",
        f"POLICY={policy}",
        f"DB_LATENCY={db_latency}",
        f"READ_REORDER_DEPTH={rob}",
        f"DATABANK_SDP={sdp}",
        f"SDP_WRITE_INPUT_REG={sdp_reg}",
        "ASSERT=1",
        f"TESTCASE={POSITIVE_TESTS}",
    ]
    result, output = run_make("wrap", tag, args, timeout=900)
    counts = assert_clean_summary(tag, result, output)

    # Guard against a false-green matrix where Makefile defaults silently win.
    for define in (
        f"+define+TC_NARROW_W={narrow}",
        f"+define+TC_BLOCK_W={wide}",
        f"+define+TC_LINE_W={line_w}",
        f"+define+TC_WAYS={ways}",
        f"+define+TC_DB_LATENCY={db_latency}",
        f"+define+TC_POLICY={policy}",
        f"+define+TC_DATABANK_SDP={sdp}",
        f"+define+TC_SDP_WRITE_INPUT_REG={sdp_reg}",
    ):
        assert define in output, (
            f"{tag}: intended geometry was not present in compile command: "
            f"missing {define}\n---output head---\n{output[:3000]}")

    tests, passed, failed, skipped = counts
    assert failed == 0 and passed >= 5 and tests == passed + skipped, (
        f"{tag}: unexpected summary TESTS={tests} PASS={passed} "
        f"FAIL={failed} SKIP={skipped}\n---output tail---\n{output[-3000:]}")


def test_wrong_wrap_boundary_negative_control():
    """The boundary mutation must reproduce the expected sparse-data error."""
    args = [
        "MODULE=test_shim_wrap_negative",
        "WIDE_W=32", "NARROW_W=32", "LINE_W=8", "LINES=128",
        "WAYS=1", "POLICY=LRU", "DB_LATENCY=1",
        "READ_REORDER_DEPTH=8", "ASSERT=1",
    ]
    result, output = run_make("wrap", "negative", args, timeout=300)
    assert_clean_summary("negative control", result, output)
    assert "words 13 and 14 corrupted; other words match" in output


@pytest.mark.parametrize("line_w", [1, 3, 32])
def test_invalid_line_width_rejected(line_w):
    """Unsupported/illegal AXI WRAP lengths must fail at time zero."""
    args = [
        "MODULE=test_shim_cache",
        "WIDE_W=32", "NARROW_W=32", f"LINE_W={line_w}", "LINES=64",
        "WAYS=1", "POLICY=LRU", "DB_LATENCY=1",
        "READ_REORDER_DEPTH=1", "TESTCASE=test_smoke",
    ]
    result, output = run_make(
        "wrap", f"invalid_l{line_w}", args, timeout=300)
    assert result.returncode != 0, (
        f"LINE_W={line_w} unexpectedly built/ran successfully")
    assert f"LINE_W={line_w} unsupported; must be one of" in output, (
        f"LINE_W={line_w} failed without the intended parameter diagnostic\n"
        f"---output tail---\n{output[-3000:]}")
