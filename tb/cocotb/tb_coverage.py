"""Functional-coverage covergroups for AXI traffic.

Lightweight wrapper around cocotb-coverage 1.2.x. Tests sample by calling:

    from tb_coverage import sample_read, sample_write, dump_coverage
    sample_read(addr, nbeat, snoop)
    sample_write(addr, nbeat, snoop, partial)
    ...
    dump_coverage("test_random")          # writes /tmp/tc_cov_<name>.xml

NOTE: cocotb-coverage 1.2.x requires POSITIONAL args (no kwargs).
"""
from __future__ import annotations

import os
from cocotb_coverage.coverage import CoverPoint, CoverCross, coverage_db

LINE_W = int(os.environ.get("TC_LINE_W", "8"))

_BEAT_BINS    = sorted(set([1, 2, 4, max(LINE_W, 8)]))
_SNOOP_AR_BIN = [0b0000, 0b1000, 0b1001, 0b1101]    # normal, CleanShared, CleanInvalid, MakeInvalid
_SNOOP_AW_BIN = [0b000, 0b101]                       # normal, WriteEvict

# ACE CBOMs are 1-beat by spec (arlen=0). Multi-beat × CBOM-snoop cells
# are architecturally unreachable, not a coverage gap. Ignore them so the
# cross score reflects reachable cells only.
_CBOM_AR_SNOOPS = [s for s in _SNOOP_AR_BIN if s != 0]
_R_IGN_BINS = [(b, s) for b in _BEAT_BINS if b != 1 for s in _CBOM_AR_SNOOPS]

# WriteEvict (awsnoop=0b101) is architecturally only valid full-line.
# Ignore the non-full-line WriteEvict cells.
_FULL_LINE = max(LINE_W, 8)
_W_IGN_BINS = [(b, 0b101) for b in _BEAT_BINS if b != _FULL_LINE]


@CoverPoint("axi.r.nbeat", xf=lambda addr, nbeat, snoop: nbeat,  bins=_BEAT_BINS)
@CoverPoint("axi.r.snoop", xf=lambda addr, nbeat, snoop: snoop,  bins=_SNOOP_AR_BIN)
@CoverCross("axi.r.beat_x_snoop", items=["axi.r.nbeat", "axi.r.snoop"], ign_bins=_R_IGN_BINS)
def sample_read(addr, nbeat, snoop):
    pass


@CoverPoint("axi.w.nbeat",   xf=lambda addr, nbeat, snoop, partial: nbeat,    bins=_BEAT_BINS)
@CoverPoint("axi.w.snoop",   xf=lambda addr, nbeat, snoop, partial: snoop,    bins=_SNOOP_AW_BIN)
@CoverPoint("axi.w.partial", xf=lambda addr, nbeat, snoop, partial: bool(partial), bins=[True, False])
@CoverCross("axi.w.beat_x_snoop",   items=["axi.w.nbeat", "axi.w.snoop"], ign_bins=_W_IGN_BINS)
@CoverCross("axi.w.beat_x_partial", items=["axi.w.nbeat", "axi.w.partial"])
def sample_write(addr, nbeat, snoop, partial):
    pass


def dump_coverage(test_name: str, outdir: str = "/tmp") -> str:
    """Write the merged coverage DB to /tmp/tc_cov_<test_name>.xml."""
    path = os.path.join(outdir, f"tc_cov_{test_name}.xml")
    coverage_db.export_to_xml(filename=path)
    return path
