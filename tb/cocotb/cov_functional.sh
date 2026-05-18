#!/usr/bin/env bash
# Functional-coverage aggregator.
# Runs the cocotb tests instrumented with tb_coverage.py and prints a
# combined per-coverpoint hit summary.
#
# Usage:
#   ./cov_functional.sh                    # default: test_random + test_cbom
#   MODS="test_random test_cbom test_workload" ./cov_functional.sh
set -u
cd "$(dirname "$0")"
source .venv/bin/activate

MODS=${MODS:-"test_random test_cbom test_strobe"}
NTXN=${NTXN:-300}

for mod in $MODS; do
    rm -rf sim_build
    case "$mod" in
        test_random)
            NTXN=$NTXN SEED=1 timeout 300 make MODULE=$mod > /tmp/cov_$mod.log 2>&1
            ;;
        test_workload)
            NTXN=2000 SEED=1 timeout 600 make MODULE=$mod > /tmp/cov_$mod.log 2>&1
            ;;
        *)
            timeout 300 make MODULE=$mod > /tmp/cov_$mod.log 2>&1
            ;;
    esac
    rc=$?
    [[ $rc -ne 0 ]] && echo "WARN: $mod returned rc=$rc"
done

python3 - <<'PYEOF'
import os
import xml.etree.ElementTree as ET

# Merge: per-bin OR (union of hits) across all XMLs.
merged = {}  # bin_path -> [hits_total, size_of_parent_group]

def walk(node, prefix=""):
    name = (prefix + "." + node.tag) if prefix else node.tag
    yield (name, node)
    for c in node:
        yield from walk(c, name)

for f in os.listdir("/tmp"):
    if not f.startswith("tc_cov_") or not f.endswith(".xml"):
        continue
    root = ET.parse(f"/tmp/{f}").getroot()
    # collect non-bin parent groups (have size attribute) and per-bin hits
    for name, node in walk(root):
        if "bin" in node.tag and "hits" in node.attrib:
            cur = merged.setdefault(name, [0, 1])
            cur[0] += int(node.attrib["hits"])
        elif "size" in node.attrib:
            s = int(node.attrib["size"])
            merged.setdefault(name, [0, s])
            merged[name][1] = s

# Aggregate per-group: count bins with >0 hits / total bins.
group_counts = {}
for n, (hits, _) in merged.items():
    if "bin" in n:
        parent = ".".join(n.split(".")[:-1])
        c, t = group_counts.setdefault(parent, [0, 0])
        group_counts[parent] = [c + (1 if hits > 0 else 0), t + 1]

print(f"\n=== Functional coverage (merged across MODS) ===")
for n in sorted(group_counts):
    if "axi." not in n:
        continue
    c, t = group_counts[n]
    pct = 100 * c / t if t else 0
    print(f"  {n:55s}  {c:3d}/{t:3d}  {pct:5.1f}%")
PYEOF
