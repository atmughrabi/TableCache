#!/usr/bin/env bash
# Functional-coverage aggregator.
# Runs the cocotb tests instrumented with tb_coverage.py and prints a
# combined per-coverpoint hit summary.
#
# Usage:
#   ./cov_functional.sh                    # default: test_random + test_cbom
#   MODS="test_random test_cbom" ./cov_functional.sh
set -uo pipefail
cd "$(dirname "$0")"
source .venv/bin/activate

MODS=${MODS:-"test_random test_cbom test_strobe"}
NTXN=${NTXN:-300}
SUPPORTED_MODS="test_random test_cbom test_strobe"
COVERAGE_DIR="${COVERAGE_DIR:-/tmp/tc_functional_coverage}"
mkdir -p "$COVERAGE_DIR"
find "$COVERAGE_DIR" -maxdepth 1 -type f -name 'tc_cov_*.xml' -delete
export TC_COVERAGE_DIR="$COVERAGE_DIR"

failed=0
for mod in $MODS; do
    if [[ " $SUPPORTED_MODS " != *" $mod "* ]]; then
        echo "FAIL: $mod is not instrumented for functional coverage" >&2
        failed=$((failed + 1))
        continue
    fi
    rm -rf sim_build
    rm -f "$COVERAGE_DIR/$mod.log"
    case "$mod" in
        test_random)
            NTXN=$NTXN SEED=1 timeout 300 make MODULE=$mod > "$COVERAGE_DIR/$mod.log" 2>&1
            ;;
        *)
            timeout 300 make MODULE=$mod > "$COVERAGE_DIR/$mod.log" 2>&1
            ;;
    esac
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "FAIL: $mod returned rc=$rc" >&2
        failed=$((failed + 1))
    fi
    if [[ ! -s "$COVERAGE_DIR/tc_cov_${mod}.xml" ]]; then
        echo "FAIL: $mod produced no coverage XML" >&2
        failed=$((failed + 1))
    fi
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

coverage_dir = os.environ["TC_COVERAGE_DIR"]
coverage_files = [
    f for f in os.listdir(coverage_dir)
    if f.startswith("tc_cov_") and f.endswith(".xml")
]
if not coverage_files:
    raise SystemExit("no functional-coverage XML files were produced")

for f in coverage_files:
    root = ET.parse(os.path.join(coverage_dir, f)).getroot()
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
aggregate_rc=$?
if [[ $aggregate_rc -ne 0 ]]; then
    failed=$((failed + 1))
fi

(( failed == 0 ))
