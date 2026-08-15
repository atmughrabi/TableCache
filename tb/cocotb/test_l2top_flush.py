"""Whole-cache flush scenarios routed THROUGH l2_top (dut_l2top_flush).

These scenarios route tc_flush_controller -> l2_top -> l2_cache and verify
that the wrapper preserves CBOM snoop signals.

Run the fixed (INCLUDE_CBOM=1) path:
    make MODULE=test_l2top_flush
Negative control with `INCLUDE_CBOM=0`:
    make MODULE=test_l2top_flush CBOM=0
"""
from __future__ import annotations

# Reuse every @cocotb.test() defined in test_flush.py unchanged; only the
# DUT (TOPLEVEL=dut_l2top_flush) differs, selected by the Makefile.
from test_flush import (  # noqa: F401
    test_flush_clean_state,
    test_flush_writes_back_dirty,
    test_flush_idempotent,
    test_flush_cold_cache,
    test_flush_cold_cache_cleaninvalid,
    test_flush_cold_cache_byindex,
    test_flush_multitag_all_ways,
    test_flush_scattered_multitag,
)
