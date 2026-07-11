"""Shared subprocess helpers for pytest configuration matrices."""
from __future__ import annotations

import os
import re
import shutil
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
SUMMARY_RE = re.compile(r"TESTS=(\d+)\s+PASS=(\d+)\s+FAIL=(\d+)\s+SKIP=(\d+)")


def run_make(prefix, tag, args, timeout=600, clean=True):
    build_name = f"sim_build_{prefix}_{tag}"
    if clean:
        shutil.rmtree(os.path.join(HERE, build_name), ignore_errors=True)
    try:
        os.remove(os.path.join(HERE, "results.xml"))
    except FileNotFoundError:
        pass
    result = subprocess.run(
        ["make", f"SIM_BUILD={build_name}", *args],
        cwd=HERE, env=os.environ.copy(), capture_output=True,
        text=True, timeout=timeout)
    return result, result.stdout + result.stderr


def summary(output):
    matches = SUMMARY_RE.findall(output)
    return tuple(map(int, matches[-1])) if matches else None


def assert_clean_summary(tag, result, output):
    assert result.returncode == 0, (
        f"{tag}: build/sim failed\n---output tail---\n{output[-5000:]}")
    assert "AXI_PC_VIOLATION" not in output, (
        f"{tag}: protocol violation\n---output tail---\n{output[-4000:]}")
    counts = summary(output)
    assert counts and counts[2] == 0, (
        f"{tag}: bad/missing cocotb summary\n---output tail---\n{output[-3000:]}")
    return counts
