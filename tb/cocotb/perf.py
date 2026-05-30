#!/usr/bin/env python3
"""Performance benchmark across the 5 replacement policies.

Runs test_workload at NTXN=5000 for each POLICY {LRU, SRRIP, FRQ,
SECOND_CHANCE, RANDOM} and reports observed hit-rate, p50/p95/p99
latency, predicted-vs-observed drift, and wall-clock sim time.

Run from tb/cocotb/:
    source .venv/bin/activate
    python3 perf.py                 # default LINES=64 WAYS=4 LINE_W=8
    POLICIES=LRU,SRRIP python3 perf.py
    NTXN=10000 WAYS=8 python3 perf.py

Output: stdout markdown table + per-run logs at /tmp/tc_perf/.
"""
from __future__ import annotations
import os, re, shutil, subprocess, sys, time
from pathlib import Path

HERE         = Path(__file__).parent
OUT          = Path(os.environ.get("OUT", "/tmp/tc_perf"))
POLICIES     = os.environ.get("POLICIES",
    "LRU,SRRIP,GRASP,FRQ,SECOND_CHANCE,RANDOM").split(",")
NTXN         = os.environ.get("NTXN", "5000")
LINES        = os.environ.get("LINES", "64")
WAYS         = os.environ.get("WAYS", "4")
LINE_W       = os.environ.get("LINE_W", "8")
SEED         = os.environ.get("SEED", "1")
TIMEOUT_S    = int(os.environ.get("TIMEOUT_S", "600"))

PAT_PRED = re.compile(r"predicted=\s*([\d.]+)%\s+observed=\s*([\d.]+)%\s+drift=\s*([\d.]+)pp")
PAT_LAT  = re.compile(r"LAT\((hit |miss)\)\s+p50=\s*(\d+)\s+p95=\s*(\d+)\s+p99=\s*(\d+)\s+mean=\s*([\d.]+)")
PAT_OPS  = re.compile(r"\[wl\] DONE.*reads=(\d+)\s+writes=(\d+)\s+full_writes=(\d+)")
PAT_TESTS= re.compile(r"\*\* TESTS=(\d+) PASS=(\d+) FAIL=(\d+)")


def run_policy(policy: str) -> dict:
    OUT.mkdir(parents=True, exist_ok=True)
    log_path = OUT / f"workload_{policy}.log"
    env = os.environ.copy()
    env.update({
        "MODULE":       "test_workload",
        "POLICY":       policy,
        "LINES":        LINES,
        "WAYS":         WAYS,
        "LINE_W":       LINE_W,
        "NTXN":         NTXN,
        "SEED":         SEED,
    })
    # Always rebuild so the policy change actually rewires.
    shutil.rmtree(HERE / "sim_build", ignore_errors=True)

    t0 = time.time()
    r = subprocess.run(["make", "MODULE=test_workload"],
                       cwd=HERE, env=env, timeout=TIMEOUT_S,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True)
    wall_s = time.time() - t0
    log_path.write_text(r.stdout)

    out = {"policy": policy, "wall_s": wall_s, "rc": r.returncode}
    tests = PAT_TESTS.search(r.stdout)
    out["tests_pass"] = tests.group(2) if tests else "?"
    out["tests_fail"] = tests.group(3) if tests else "?"

    pred = PAT_PRED.search(r.stdout)
    if pred:
        out["pred_pct"]    = float(pred.group(1))
        out["obs_pct"]     = float(pred.group(2))
        out["drift_pp"]    = float(pred.group(3))

    lats = PAT_LAT.findall(r.stdout)
    for tag, p50, p95, p99, _mean in lats:
        kind = tag.strip()
        out[f"{kind}_p50"] = p50
        out[f"{kind}_p95"] = p95
        out[f"{kind}_p99"] = p99

    ops = PAT_OPS.search(r.stdout)
    if ops:
        out["reads"]       = int(ops.group(1))
        out["writes"]      = int(ops.group(2))
        out["full_writes"] = int(ops.group(3))

    return out


def main():
    print(f"# TableCache replacement-policy performance benchmark")
    print(f"# config: LINES={LINES} WAYS={WAYS} LINE_W={LINE_W} NTXN={NTXN} SEED={SEED}")
    print()
    results = []
    for p in POLICIES:
        sys.stdout.write(f"running {p:14s}... "); sys.stdout.flush()
        r = run_policy(p)
        results.append(r)
        if r.get("rc") != 0 or r.get("tests_fail") != "0":
            print(f"  FAIL rc={r.get('rc')} tests_fail={r.get('tests_fail')}")
        else:
            print(f"  obs={r.get('obs_pct','?')}% wall={r['wall_s']:.1f}s")

    # Markdown table
    print()
    print("| Policy | Hit rate (obs) | Hit rate (pred) | Drift (pp) | "
          "p50 hit | p95 hit | p50 miss | p95 miss | Wall (s) |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for r in results:
        if r.get("rc") == 0 and r.get("tests_fail") == "0":
            print(f"| {r['policy']} | "
                  f"{r.get('obs_pct', '?')}% | "
                  f"{r.get('pred_pct', '?')}% | "
                  f"{r.get('drift_pp', '?')} | "
                  f"{r.get('hit_p50', '?')} | "
                  f"{r.get('hit_p95', '?')} | "
                  f"{r.get('miss_p50', '?')} | "
                  f"{r.get('miss_p95', '?')} | "
                  f"{r['wall_s']:.1f} |")
        else:
            print(f"| {r['policy']} | FAILED (rc={r.get('rc')}, tests_fail={r.get('tests_fail')}) |")

    print()
    print(f"# logs: {OUT}/")
    failed = [r for r in results if r.get("rc") != 0 or r.get("tests_fail") != "0"]
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
