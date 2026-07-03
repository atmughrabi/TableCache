"""Whole-cache flush scenarios routed THROUGH l2_top (dut_l2top_flush).

These are the exact same scenarios as test_flush.py, but the chain is
tc_flush_controller -> l2_top -> l2_cache instead of straight to l2_cache.
That extra hop is what GraphBlox's FPGA integration actually uses, and it
is where a CBOM (CleanInvalid) flush silently broke: l2_top used to drop
the s00_axi_arsnoop sideband and instantiate l2_cache with INCLUDE_CBOM=0,
so every flush CBOM was demoted to a plain read, the cold-line "read"
never got a fill, and tc_flush_controller wedged in WAIT_R forever.

Run the fixed (INCLUDE_CBOM=1) path:
    make MODULE=test_l2top_flush
Reproduce the historical hang (INCLUDE_CBOM=0 -> CBOM demoted to read):
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
    test_flush_multitag_all_ways,
    test_flush_scattered_multitag,
)
