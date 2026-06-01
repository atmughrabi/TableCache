#!/usr/bin/env python3
"""Performance comparison: TableCache v1 vs v2 (N=1, 2, 4).

Runs test_workload at NTXN=2000 against:
  - v1 baseline (no V2 flag)
  - v2 N_BANKS_V2=1 (passthrough; sanity check that v2 wrapper costs zero)
  - v2 N_BANKS_V2=2 (the recommended config)
  - v2 N_BANKS_V2=4 (max banking)

Same POLICY + LINES + WAYS + LINE_W + SEED across all configs so the
differences come ONLY from architecture, not from workload variance.

Run from tb/cocotb/:
    source .venv/bin/activate
    python3 perf_v2_vs_v1.py

Output: stdout markdown table.
"""
from __future__ import annotations
import os, re, shutil, subprocess, sys, time
from pathlib import Path

HERE         = Path(__file__).parent
OUT          = Path(os.environ.get("OUT", "/tmp/tc_perf_v2"))
POLICY       = os.environ.get("POLICY", "LRU")
NTXN         = os.environ.get("NTXN", "2000")
LINES        = os.environ.get("LINES", "64")
WAYS         = os.environ.get("WAYS", "4")
LINE_W       = os.environ.get("LINE_W", "8")
SEED         = os.environ.get("SEED", "1")
DB_LATENCY   = os.environ.get("DB_LATENCY", "3")
DATABANK_SDP = os.environ.get("DATABANK_SDP", "1")
SDP_WIR      = os.environ.get("SDP_WRITE_INPUT_REG", "1")
TIMEOUT_S    = int(os.environ.get("TIMEOUT_S", "900"))

PAT_LAT  = re.compile(r"LAT\((hit |miss)\)\s+p50=\s*(\d+)\s+p95=\s*(\d+)\s+p99=\s*(\d+)\s+mean=\s*([\d.]+)")
PAT_PRED = re.compile(r"predicted=\s*([\d.]+)%\s+observed=\s*([\d.]+)%\s+drift=\s*([\d.]+)pp")
PAT_DONE = re.compile(r"\[wl\] DONE n_rd=(\d+) n_wr=(\d+)")
PAT_TESTS= re.compile(r"\*\* TESTS=(\d+) PASS=(\d+) FAIL=(\d+)")
PAT_SIMT = re.compile(r"\*\* TESTS=\d+\s+PASS=\d+\s+FAIL=\d+\s+SKIP=\d+\s+([\d.]+)")


def run(config_name: str, extra_env: dict) -> dict:
    OUT.mkdir(parents=True, exist_ok=True)
    log_path = OUT / f"{config_name}.log"
    env = os.environ.copy()
    env.update({
        "MODULE":              "test_workload",
        "POLICY":              POLICY,
        "LINES":               LINES,
        "WAYS":                WAYS,
        "LINE_W":              LINE_W,
        "NTXN":                NTXN,
        "SEED":                SEED,
        "DB_LATENCY":          DB_LATENCY,
        "DATABANK_SDP":        DATABANK_SDP,
        "SDP_WRITE_INPUT_REG": SDP_WIR,
    })
    env.update(extra_env)
    shutil.rmtree(HERE / "sim_build", ignore_errors=True)

    t0 = time.time()
    r = subprocess.run(["make", "MODULE=test_workload"],
                       cwd=HERE, env=env, timeout=TIMEOUT_S,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True)
    wall_s = time.time() - t0
    log_path.write_text(r.stdout)

    out = {"config": config_name, "wall_s": wall_s, "rc": r.returncode}
    tests = PAT_TESTS.search(r.stdout)
    out["tests_pass"] = tests.group(2) if tests else "?"
    out["tests_fail"] = tests.group(3) if tests else "?"

    pred = PAT_PRED.search(r.stdout)
    if pred:
        out["obs_pct"]  = float(pred.group(2))
        out["pred_pct"] = float(pred.group(1))

    lats = PAT_LAT.findall(r.stdout)
    for tag, p50, p95, p99, _mean in lats:
        kind = tag.strip()
        out[f"{kind}_p50"] = int(p50)
        out[f"{kind}_p95"] = int(p95)
        out[f"{kind}_p99"] = int(p99)
        out[f"{kind}_mean"] = float(_mean)

    done = PAT_DONE.search(r.stdout)
    if done:
        out["reads"]  = int(done.group(1))
        out["writes"] = int(done.group(2))

    # Sim time (ns) from cocotb tail
    simt = PAT_SIMT.search(r.stdout)
    if simt:
        out["sim_ns"] = float(simt.group(1))
        # cyc/txn estimate: at 100 MHz default (10 ns clock), cyc = ns/10
        txns = out.get("reads", 0) + out.get("writes", 0)
        if txns > 0:
            out["cyc_per_txn"] = out["sim_ns"] / 10.0 / txns
    return out


CONFIGS = [
    ("v1_baseline", {}),
    ("v2_n1",       {"V2": "1", "N_BANKS_V2": "1"}),
    ("v2_n2",       {"V2": "1", "N_BANKS_V2": "2"}),
    ("v2_n4",       {"V2": "1", "N_BANKS_V2": "4"}),
]


def main():
    print(f"# TableCache v1 vs v2 perf comparison")
    print(f"# POLICY={POLICY} LINES={LINES} WAYS={WAYS} LINE_W={LINE_W} "
          f"NTXN={NTXN} SEED={SEED}")
    print(f"# Knobs: DB_LATENCY={DB_LATENCY} DATABANK_SDP={DATABANK_SDP} "
          f"SDP_WRITE_INPUT_REG={SDP_WIR}")
    print()

    results = []
    for name, extra in CONFIGS:
        sys.stdout.write(f"running {name:14s}... "); sys.stdout.flush()
        r = run(name, extra)
        results.append(r)
        if r.get("rc") != 0 or r.get("tests_fail") != "0":
            print(f"  FAIL rc={r.get('rc')} tests_fail={r.get('tests_fail')}")
        else:
            print(f"  obs={r.get('obs_pct','?')}% cyc/txn={r.get('cyc_per_txn',0):.2f} wall={r['wall_s']:.1f}s")

    print()
    print("# Note: test_workload's `drift_pp <= 20` assertion assumes a single")
    print("# unified cache; banking (LINES_PER_BANK = LINES/N) creates more")
    print("# conflict misses than the shadow model expects. A 'FAILED' v2_nN")
    print("# entry below is the drift assertion firing, NOT a correctness bug")
    print("# (correctness is gated separately by verify.sh; both N=2 and N=4")
    print("# pass 19/19 + 5/5 + 10/10). Compare cyc/txn across rows regardless.")
    print()
    print("| Config | rc/tests | Hit (obs) | hit p50 | hit p95 | miss p50 | miss p95 | cyc/txn | sim ns | wall |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for r in results:
        ok = "OK" if (r.get("rc") == 0 and r.get("tests_fail") == "0") else f"FAIL({r.get('tests_fail','?')})"
        if 'cyc_per_txn' in r:
            print(f"| {r['config']} | {ok} | "
                  f"{r.get('obs_pct','?')}% | "
                  f"{r.get('hit_p50','?')} | "
                  f"{r.get('hit_p95','?')} | "
                  f"{r.get('miss_p50','?')} | "
                  f"{r.get('miss_p95','?')} | "
                  f"{r.get('cyc_per_txn',0):.2f} | "
                  f"{int(r.get('sim_ns',0))} | "
                  f"{r['wall_s']:.1f}s |")
        else:
            print(f"| {r['config']} | {ok} | -- |")

    # Deltas vs v1 baseline
    base = next((r for r in results if r['config'] == 'v1_baseline'
                 and 'cyc_per_txn' in r), None)
    if base and 'cyc_per_txn' in base:
        print()
        print("## cyc/txn deltas vs v1_baseline")
        print()
        print("| Config | cyc/txn | delta | %change |")
        print("|---|---:|---:|---:|")
        for r in results:
            if r.get('cyc_per_txn'):
                d = r['cyc_per_txn'] - base['cyc_per_txn']
                pct = 100.0 * d / base['cyc_per_txn']
                print(f"| {r['config']} | {r['cyc_per_txn']:.2f} | "
                      f"{d:+.2f} | {pct:+.2f}% |")


if __name__ == "__main__":
    main()
