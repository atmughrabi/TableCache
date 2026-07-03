"""Pytest config-matrix sweep.

Sweeps {POLICY, WAYS, DB_LATENCY, VICTIM} and runs the smoke + random tests
under each combination. Each combination is a fresh `make`, so build is the
slow part; runtime is fast.

Run:
  pytest -v test_matrix.py
  pytest -v test_matrix.py -k 'SRRIP'
  pytest -v test_matrix.py --no-header -q     # condensed

Selected matrix kept SMALL by default to keep total runtime reasonable;
extend in MATRIX below as needed. Each combo runs both `test_smoke` and a
short `test_random NTXN=80 SEED=1`.
"""
from __future__ import annotations
import os
import re
import shutil
import subprocess
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))

# Default matrix. Each tuple: (POLICY, WAYS, DB_LATENCY, VICTIM, CBOM)
MATRIX = [
    # baseline (already proven)
    ("LRU",           4, 1, 0, 1),
    # ways sweep
    ("LRU",           2, 1, 0, 1),
    ("LRU",           8, 1, 0, 1),
    # DB latency sweep
    ("LRU",           4, 2, 0, 1),
    ("LRU",           4, 3, 0, 1),
    # policy sweep
    ("FRQ",           4, 1, 0, 1),
    ("SECOND_CHANCE", 4, 1, 0, 1),
    ("RANDOM",        4, 1, 0, 1),
    ("SRRIP",         4, 1, 0, 1),
    # CBOM off
    ("LRU",           4, 1, 0, 0),
    # VICTIM on (3 variants exercise different victim-cache pressure patterns)
    ("LRU",           4, 1, 1, 1),
    ("LRU",           8, 1, 1, 1),
    ("SRRIP",         4, 1, 1, 1),
]


def _make(env_overrides: dict, target: str, ntxn: int = None, seed: int = 1,
          timeout_s: int = 180) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env.update(env_overrides)
    cmd = ["make", f"MODULE={target}"]
    # Force a fresh build dir per combo so sim_build/Vtop is rebuilt with
    # the new defines.
    obj = os.path.join(HERE, "sim_build")
    if os.path.exists(obj):
        shutil.rmtree(obj)
    if ntxn is not None:
        cmd += [f"NTXN={ntxn}", f"SEED={seed}"]
    # Knobs flow into both the verilator EXTRA_ARGS (via Makefile) and the
    # python tests (via env-exported TC_*).
    for k in ("POLICY", "LINES", "LINE_W", "WAYS", "BLOCK_W",
              "DB_LATENCY", "VICTIM", "CBOM"):
        if k in env_overrides:
            cmd.append(f"{k}={env_overrides[k]}")
    return subprocess.run(cmd, cwd=HERE, env=env, capture_output=True,
                          text=True, timeout=timeout_s)


# cocotb's per-run summary line is e.g.
#   ** TESTS=1 PASS=1 FAIL=0 SKIP=0 **
# Match the LAST occurrence and return the integer FAIL count, or None if no
# summary line was emitted (build failure, timeout, etc.).
_FAIL_RE = re.compile(r"\*\*\s*TESTS=\d+\s+PASS=\d+\s+FAIL=(\d+)\s+SKIP=\d+\s*")
def _cocotb_fail_count(stdout: str):
    matches = _FAIL_RE.findall(stdout)
    return int(matches[-1]) if matches else None


@pytest.mark.parametrize("policy,ways,db_lat,victim,cbom", MATRIX,
                          ids=[f"{p}-W{w}-L{l}-V{v}-C{c}" for p, w, l, v, c in MATRIX])
def test_smoke(policy, ways, db_lat, victim, cbom):
    """Single-line read miss must pass for every config."""
    env = {
        "POLICY":     policy,
        "WAYS":       str(ways),
        "DB_LATENCY": str(db_lat),
        "VICTIM":     str(victim),
        "CBOM":       str(cbom),
    }
    r = _make(env, "test_smoke", timeout_s=180)
    assert r.returncode == 0, (
        f"smoke FAIL ({policy} W={ways} DB={db_lat} V={victim} C={cbom})\n"
        f"---stdout tail---\n{r.stdout[-2000:]}\n---stderr tail---\n{r.stderr[-1000:]}"
    )
    nfail = _cocotb_fail_count(r.stdout)
    assert nfail == 0, (
        f"smoke cocotb FAIL count = {nfail} ({policy} W={ways} DB={db_lat} V={victim} C={cbom})\n"
        f"---stdout tail---\n{r.stdout[-2000:]}"
    )


@pytest.mark.parametrize("policy,ways,db_lat,victim,cbom", MATRIX,
                          ids=[f"{p}-W{w}-L{l}-V{v}-C{c}" for p, w, l, v, c in MATRIX])
def test_random_small(policy, ways, db_lat, victim, cbom):
    """80-txn random scoreboard across every config."""
    env = {
        "POLICY":     policy,
        "WAYS":       str(ways),
        "DB_LATENCY": str(db_lat),
        "VICTIM":     str(victim),
        "CBOM":       str(cbom),
    }
    r = _make(env, "test_random", ntxn=80, seed=1, timeout_s=300)
    assert r.returncode == 0, (
        f"random FAIL ({policy} W={ways} DB={db_lat} V={victim} C={cbom})\n"
        f"---stdout tail---\n{r.stdout[-3000:]}\n---stderr tail---\n{r.stderr[-1000:]}"
    )
    nfail = _cocotb_fail_count(r.stdout)
    assert nfail == 0, (
        f"random cocotb FAIL count = {nfail} ({policy} W={ways} DB={db_lat} V={victim} C={cbom})\n"
        f"---stdout tail---\n{r.stdout[-3000:]}"
    )


# Focused subset for the heavier enrichment tests (writeback monitor + flush
# tag-coverage). Policy is largely orthogonal to writeback/flush correctness, so
# we sweep what actually matters: VICTIM on/off and the associativity, plus one
# non-LRU policy. Each entry: (POLICY, WAYS, DB_LATENCY, VICTIM, CBOM).
ENRICH_MATRIX = [
    ("LRU",   4, 1, 0, 1),   # baseline
    ("LRU",   4, 1, 1, 1),   # + victim cache
    ("LRU",   2, 1, 1, 1),   # WAYS=2 + victim (deployment-like)
    ("LRU",   8, 1, 0, 1),   # WAYS=8
    ("SRRIP", 4, 1, 1, 1),   # non-LRU policy + victim
]


@pytest.mark.parametrize("policy,ways,db_lat,victim,cbom", ENRICH_MATRIX,
                          ids=[f"{p}-W{w}-L{l}-V{v}-C{c}" for p, w, l, v, c in ENRICH_MATRIX])
def test_eviction_matrix(policy, ways, db_lat, victim, cbom):
    """Heavy non-aligned eviction round-trip + backend WritebackMonitor across
    configs (the FIX-A / writeback-correctness net)."""
    env = {"POLICY": policy, "WAYS": str(ways), "DB_LATENCY": str(db_lat),
           "VICTIM": str(victim), "CBOM": str(cbom)}
    r = _make(env, "test_eviction", timeout_s=360)
    assert r.returncode == 0, (
        f"eviction FAIL ({policy} W={ways} DB={db_lat} V={victim} C={cbom})\n"
        f"---stdout tail---\n{r.stdout[-3000:]}\n---stderr tail---\n{r.stderr[-1000:]}")
    nfail = _cocotb_fail_count(r.stdout)
    assert nfail == 0, (
        f"eviction cocotb FAIL count = {nfail} ({policy} W={ways} V={victim})\n"
        f"---stdout tail---\n{r.stdout[-3000:]}")


@pytest.mark.parametrize("policy,ways,db_lat,victim,cbom", ENRICH_MATRIX,
                          ids=[f"{p}-W{w}-L{l}-V{v}-C{c}" for p, w, l, v, c in ENRICH_MATRIX])
def test_flush_matrix(policy, ways, db_lat, victim, cbom):
    """Whole-cache flush suite incl. multi-tag/all-ways + scattered high-tag
    regressions (the FIX-B / flush tag-coverage net) across configs."""
    env = {"POLICY": policy, "WAYS": str(ways), "DB_LATENCY": str(db_lat),
           "VICTIM": str(victim), "CBOM": str(cbom)}
    r = _make(env, "test_flush", timeout_s=360)
    assert r.returncode == 0, (
        f"flush FAIL ({policy} W={ways} DB={db_lat} V={victim} C={cbom})\n"
        f"---stdout tail---\n{r.stdout[-3000:]}\n---stderr tail---\n{r.stderr[-1000:]}")
    nfail = _cocotb_fail_count(r.stdout)
    assert nfail == 0, (
        f"flush cocotb FAIL count = {nfail} ({policy} W={ways} V={victim})\n"
        f"---stdout tail---\n{r.stdout[-3000:]}")
