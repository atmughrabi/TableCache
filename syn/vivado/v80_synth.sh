#!/usr/bin/env bash
# Alveo V80 (Versal Premium) OOC synth preset.
# Wraps run_synth.tcl with the V80 PART + URAM-deployment knobs we
# validated against U250 (GRASP, no victim, DATABANK_SDP=1, DB_LATENCY=2,
# DIRECTIVE=default). Default config is 512 KB / 8-way / 250 MHz.
#
# Knobs: SIZE={256K,512K,1M,2M}, POLICY, PERIOD_NS, DB_LATENCY,
#        INCLUDE_VICTIM, DATABANK_SDP, DIRECTIVE, PART, PNR (0=synth-only,
#        1=synth+place+route via v80_synth_pnr.tcl).
#
# The default PART xcv80-lsva4737-2MHP-e-S is the only V80 speed file
# shipped with Vivado 2025.2 (engineering sample). It reports
# clock_uncertainty=0.300 ns (vs ~0.035 ns on production UltraScale+),
# which costs ~0.25 ns of post-synth WNS purely from characterisation
# pessimism. Production V80 speed files should narrow the gap.
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

TAG="v80_${SIZE}_w${WAYS}_p${POLICY}_period${PERIOD_NS}_dbl${DB_LATENCY}_wir${SDP_WRITE_INPUT_REG:-0}_pnr${PNR}"
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
