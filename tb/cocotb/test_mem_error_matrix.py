"""Verify that non-OKAY backend responses fail loudly with and without victim."""
from __future__ import annotations

import pytest

from matrix_utils import run_make


@pytest.mark.parametrize("victim", [0, 1], ids=["no-victim", "victim"])
@pytest.mark.parametrize(
    "testcase,diagnostic",
    [
        ("test_read_slverr_is_rejected", "non-OKAY memory RRESP is unsupported"),
        ("test_writeback_slverr_is_rejected", "non-OKAY memory BRESP is unsupported"),
    ],
    ids=["read-slverr", "writeback-slverr"])
def test_memory_error_contract(victim, testcase, diagnostic):
    args = [
        "MODULE=test_mem_error_contract",
        f"TESTCASE={testcase}",
        "LINES=2", "WAYS=1", "LINE_W=2", "DB_LATENCY=1",
        f"VICTIM={victim}", "VICTIM_LINES=3", "ASSERT=1",
    ]
    result, output = run_make(
        "memerr", f"{testcase}_v{victim}", args, timeout=300)
    assert result.returncode != 0, (
        f"{testcase} VICTIM={victim}: non-OKAY response was accepted")
    assert diagnostic in output, (
        f"{testcase} VICTIM={victim}: missing diagnostic\n{output[-3000:]}")
