#!/usr/bin/env bash
# l2_top integration matrix: POLICY x WAYS sweep through dut_l2top.sv.
#
# Closes residual A16 broadening — base test_l2top.py is LRU/WAYS=4 only;
# this sweeps the parameter casting + GRASP region tie-off across the
# practical combos.

set -eu
cd "$(dirname "$0")"

POLICIES=(LRU SRRIP GRASP)
WAYS_LIST=(2 4 8)

pass=0
fail=0
failed_combos=()

for pol in "${POLICIES[@]}"; do
    for w in "${WAYS_LIST[@]}"; do
        tag="${pol}_w${w}"
        echo "==== l2_top matrix: POLICY=${pol} WAYS=${w} ===="
        rm -rf sim_build results.xml
        if POLICY="${pol}" WAYS="${w}" MODULE=test_l2top \
           make -s 2>&1 | tail -5; then
            if [[ -f results.xml ]] && \
               ! grep -q '<failure' results.xml && \
               ! grep -q '<error' results.xml; then
                pass=$((pass + 1))
                echo "  PASS"
            else
                fail=$((fail + 1))
                failed_combos+=("${tag}")
                echo "  FAIL (results.xml shows failures/errors)"
            fi
        else
            fail=$((fail + 1))
            failed_combos+=("${tag}")
            echo "  FAIL (make exit non-zero)"
        fi
    done
done

echo ""
echo "==== l2_top matrix summary ===="
echo "  PASS: ${pass}"
echo "  FAIL: ${fail}"
if [[ ${fail} -gt 0 ]]; then
    echo "  failed combos: ${failed_combos[*]}"
    exit 1
fi
