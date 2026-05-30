#!/usr/bin/env bash
# Alveo V80 (Versal Premium VP1902) synthesis preset.
#
# Wraps run_synth.sh with the V80-specific PART number and the
# URAM-deployment knobs we validated for this target:
#
#   POLICY=5  (GRASP, 0=LRU 1=FRQ 2=2ND 3=RANDOM 4=SRRIP 5=GRASP)
#   INCLUDE_VICTIM=0  (the victim cache's pending_reads LFSR drives
#                     the worst path on big SDP+URAM configs)
#   DATABANK_SDP=1    (UltraRAM-eligible storage)
#   DB_LATENCY=2      (Vivado-recommended pipeline_stages for the
#                     URAM cascade)
#   DIRECTIVE=default (AreaOptimized_high costs ~1+ ns of WNS on
#                     SDP+URAM and is no longer the default)
#
# Defaults to 512 KB / 8-way; override SIZE=512K|1M|2M to switch.
#
# Usage:
#   ./v80_synth.sh                         # 512KB / 8w / 250 MHz target
#   SIZE=1M ./v80_synth.sh                 # 1 MB  / 8w / 250 MHz target
#   SIZE=2M PERIOD_NS=4.5 ./v80_synth.sh   # 2 MB  / 8w / ~222 MHz target
#   PNR=1 ./v80_synth.sh                   # include place_design + route_design
#   POLICY=4 ./v80_synth.sh                # SRRIP instead of GRASP
#
# NOTE on the part: Vivado 2025.2 only ships `xcv80-lsva4737-2MHP-e-S`,
# the engineering-sample speed file. It reports `clock uncertainty =
# 0.300 ns` (vs ~0.035 ns on production UltraScale+ parts) which costs
# ~0.25 ns of WNS post-synth purely from characterisation conservatism.
# Production V80 speed files (when AMD ships them) will narrow the
# U250-vs-V80 gap by ~0.25 ns.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

# Tunables (env overridable)
PART="${PART:-xcv80-lsva4737-2MHP-e-S}"
SIZE="${SIZE:-512K}"
POLICY="${POLICY:-5}"
PERIOD_NS="${PERIOD_NS:-4.0}"
DIRECTIVE="${DIRECTIVE:-default}"
DB_LATENCY="${DB_LATENCY:-2}"
INCLUDE_VICTIM="${INCLUDE_VICTIM:-0}"
DATABANK_SDP="${DATABANK_SDP:-1}"
PNR="${PNR:-0}"

case "$SIZE" in
    256K) WAYS=4; LINES=512;  LINE_W=8 ;;
    512K) WAYS=8; LINES=1024; LINE_W=16 ;;
    1M)   WAYS=8; LINES=2048; LINE_W=16 ;;
    2M)   WAYS=8; LINES=4096; LINE_W=16 ;;
    *)    echo "Unknown SIZE=$SIZE; expected one of 256K, 512K, 1M, 2M" >&2; exit 2 ;;
esac

TAG="v80_${SIZE}_w${WAYS}_p${POLICY}_period${PERIOD_NS}_pnr${PNR}"
OUT="$HERE/build/${TAG}"
mkdir -p "$OUT"
echo "==== V80 synth: SIZE=$SIZE WAYS=$WAYS LINES=$LINES LINE_W=$LINE_W"
echo "             POLICY=$POLICY DB_LATENCY=$DB_LATENCY INCLUDE_VICTIM=$INCLUDE_VICTIM"
echo "             DATABANK_SDP=$DATABANK_SDP DIRECTIVE=$DIRECTIVE PERIOD_NS=$PERIOD_NS"
echo "             PNR=$PNR PART=$PART"
echo "             OUT=$OUT"

# Select the right TCL (synth-only vs synth+PnR)
if [[ "$PNR" == "1" ]]; then
    TCL="$HERE/v80_synth_pnr.tcl"
else
    TCL="$HERE/run_synth.tcl"
fi

VIVADO="${VIVADO:-/opt/xilinx/2025.2/Vivado/bin/vivado}"
if [[ ! -x "$VIVADO" ]]; then
    echo "Vivado not found at $VIVADO. Set VIVADO=/path/to/vivado." >&2
    exit 2
fi

REPO="$(cd "$HERE/../.." && pwd)"
cd "$OUT"

env PART="$PART" \
    WAYS="$WAYS" LINES="$LINES" LINE_W="$LINE_W" \
    POLICY="$POLICY" INCLUDE_VICTIM="$INCLUDE_VICTIM" \
    DATABANK_SDP="$DATABANK_SDP" DB_LATENCY="$DB_LATENCY" \
    DIRECTIVE="$DIRECTIVE" PERIOD_NS="$PERIOD_NS" \
    "$VIVADO" -mode batch -source "$TCL" \
        -tclargs l2_cache "$REPO" "$OUT" \
        -log "$OUT/vivado.log" -journal "$OUT/vivado.jou" -notrace \
        > "$OUT/synth.log" 2>&1
rc=$?

echo ""
echo "---- $TAG headline ----"
grep -E "(CLB LUTs|CLB Registers|Block RAM Tile|URAM |Registers   )" \
    "$OUT/utilization.rpt" 2>/dev/null | head -8 || true
echo ""
awk '/Design Timing Summary/{f=1} f{print; if(NR>20){exit}}' \
    "$OUT/timing_summary.rpt" 2>/dev/null | head -12 || true

wns=$(awk '/^    WNS\(ns\)/{getline; getline; print $1; exit}' "$OUT/timing_summary.rpt" 2>/dev/null)
if [[ -n "$wns" ]]; then
    mhz=$(awk -v p="$PERIOD_NS" -v w="$wns" 'BEGIN { printf "%d", 1000.0/(p - w) }')
    [[ "$PNR" == "1" ]] && phase="post-route" || phase="post-synth"
    echo ""
    echo "    headline: WNS=$wns ns  ~ ${mhz} MHz $phase"
fi
exit $rc
