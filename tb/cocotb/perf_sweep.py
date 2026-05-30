#!/usr/bin/env python3
"""WAYS x POLICY sweep on test_workload.

Drives the 5 policies x {2, 4, 8} ways. Reports observed hit rate
per (policy, ways) so integrators can pick the smallest associativity
that meets their hit-rate target.

Run from tb/cocotb/:
    source .venv/bin/activate
    python3 perf_sweep.py             # default NTXN=3000 (~12 min)
    NTXN=5000 python3 perf_sweep.py

Output: stdout markdown matrix + per-run logs at /tmp/tc_perf_sweep/.
"""
from __future__ import annotations
import os, re, shutil, subprocess, sys, time
from pathlib import Path

HERE     = Path(__file__).parent
OUT      = Path(os.environ.get("OUT", "/tmp/tc_perf_sweep"))
POLICIES = os.environ.get("POLICIES",
    "LRU,SRRIP,GRASP,FRQ,SECOND_CHANCE,RANDOM").split(",")
WAYS_LIST= [int(w) for w in os.environ.get("WAYS_LIST", "2,4,8").split(",")]
NTXN     = os.environ.get("NTXN", "3000")
LINES    = os.environ.get("LINES", "64")
LINE_W   = os.environ.get("LINE_W", "8")
SEED     = os.environ.get("SEED", "1")
TIMEOUT_S= int(os.environ.get("TIMEOUT_S", "600"))

PAT_PRED = re.compile(r"predicted=\s*([\d.]+)%\s+observed=\s*([\d.]+)%")
PAT_TESTS= re.compile(r"\*\* TESTS=(\d+) PASS=(\d+) FAIL=(\d+)")


def run_one(policy: str, ways: int) -> dict:
    OUT.mkdir(parents=True, exist_ok=True)
    log_path = OUT / f"wl_{policy}_w{ways}.log"
    env = os.environ.copy()
    env.update({
        "POLICY": policy, "LINES": LINES, "WAYS": str(ways),
        "LINE_W": LINE_W, "NTXN": NTXN, "SEED": SEED,
    })
    shutil.rmtree(HERE / "sim_build", ignore_errors=True)
    t0 = time.time()
    r = subprocess.run(["make", "MODULE=test_workload"],
                       cwd=HERE, env=env, timeout=TIMEOUT_S,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True)
    wall = time.time() - t0
    log_path.write_text(r.stdout)
    pred = PAT_PRED.search(r.stdout)
    tests = PAT_TESTS.search(r.stdout)
    return {
        "policy": policy, "ways": ways,
        "wall_s": wall,
        "rc": r.returncode,
        "tests_pass": tests.group(2) if tests else "?",
        "tests_fail": tests.group(3) if tests else "?",
        "obs_pct": float(pred.group(2)) if pred else None,
    }


def main():
    print(f"# WAYS x POLICY hit-rate sweep")
    print(f"# config: LINES={LINES} LINE_W={LINE_W} NTXN={NTXN} SEED={SEED}")
    print(f"# matrix: {len(POLICIES)} policies x {len(WAYS_LIST)} ways = {len(POLICIES)*len(WAYS_LIST)} runs")
    print()

    grid: dict[tuple[str, int], dict] = {}
    for p in POLICIES:
        for w in WAYS_LIST:
            sys.stdout.write(f"  {p:14s} w={w}... "); sys.stdout.flush()
            res = run_one(p, w)
            grid[(p, w)] = res
            if res.get("rc") != 0 or res.get("tests_fail") != "0":
                print(f"FAIL rc={res.get('rc')}")
            else:
                print(f"obs={res.get('obs_pct')}% wall={res['wall_s']:.0f}s")

    # Print matrix
    print()
    header = "| Policy | " + " | ".join(f"{w} ways" for w in WAYS_LIST) + " |"
    sep    = "|---|" + "|".join("---:" for _ in WAYS_LIST) + "|"
    print(header)
    print(sep)
    for p in POLICIES:
        row = [p]
        for w in WAYS_LIST:
            r = grid[(p, w)]
            if r.get("rc") == 0 and r.get("tests_fail") == "0":
                row.append(f"{r['obs_pct']:.1f}%")
            else:
                row.append("FAIL")
        print("| " + " | ".join(row) + " |")
    print()
    print(f"# logs: {OUT}/")
    failed = [r for r in grid.values() if r.get("rc") != 0 or r.get("tests_fail") != "0"]
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
