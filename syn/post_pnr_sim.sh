#!/usr/bin/env bash
# Post-PnR functional simulation driver.
#
# Consumes the routed netlist (and SDF, when SDF=1) emitted by
# v80_synth_pnr.tcl. Compiles them with Vivado xsim along with
# tb/post_pnr_smoke_tb.sv + post_pnr_l2cache_wrap.sv (which adapts the
# struct-typed source ports to the netlist's escaped-name flattened
# ports), runs a single read-miss burst, and grep's the log for PASS.
#
# Why pure SV (not cocotb): cocotb 1.9.x has no xsim support
# (`Makefile.xsim` is absent). Pure SV + xsim is the shortest path that
# exercises the routed netlist with the UNISIM library bound.
#
# Usage:
#   ./syn/post_pnr_sim.sh
#   PNR_BUILD=syn/vivado/build/v80_512K_w8_p5_period4.0_pnr1 ./syn/post_pnr_sim.sh
#   SDF=1 ./syn/post_pnr_sim.sh             # back-annotate SDF (slower; uses xelab -sdfmax)
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PNR_BUILD="${PNR_BUILD:-$REPO/syn/vivado/build/v80_512K_w8_p5_period4.0_pnr1}"
NETLIST="$PNR_BUILD/routed_netlist.v"
SDF="$PNR_BUILD/routed_netlist.sdf"
USE_SDF="${SDF_ANNOTATE:-0}"

if [[ ! -f "$NETLIST" ]]; then
    echo "ERROR: no routed netlist at $NETLIST" >&2
    echo "Run the PnR step first:" >&2
    echo "  cd syn/vivado && PNR=1 SIZE=512K ./v80_synth.sh" >&2
    exit 2
fi

VIVADO_BIN="$(command -v vivado 2>/dev/null || true)"
if [[ -z "$VIVADO_BIN" ]]; then
    echo "ERROR: vivado not in PATH (need 2024.x+ for xsim + xeclib)" >&2
    exit 3
fi
VIVADO_ROOT="$(dirname "$(dirname "$VIVADO_BIN")")"
GLBL="$VIVADO_ROOT/data/verilog/src/glbl.v"
if [[ ! -f "$GLBL" ]]; then
    echo "ERROR: glbl.v not found at $GLBL" >&2
    exit 4
fi

echo "==== Post-PnR sim ===="
echo "  netlist: $NETLIST"
echo "  sdf:     $SDF"
echo "  vivado:  $VIVADO_BIN"
echo "  glbl:    $GLBL"

WORK="$REPO/syn/build_post_pnr"
mkdir -p "$WORK"
cd "$WORK"
# The netlist contains `$sdf_annotate("routed_netlist.sdf", ...)` from
# Vivado's `write_verilog -sdf_anno true`. Symlink so the call finds
# the SDF in xsim's CWD, but ALSO strip the call when SDF=0 — xsim's
# SDF binding warns/errors on many Versal primitive timing arcs that
# the SDF doesn't cover (RAMD32, FDRE port mismatches).
ln -sf "$SDF" routed_netlist.sdf
if [[ "$USE_SDF" == "1" ]]; then
    NETLIST_LOCAL="$NETLIST"   # use original with embedded $sdf_annotate
else
    NETLIST_LOCAL="$WORK/routed_netlist_nosdf.v"
    sed '/\$sdf_annotate/d' "$NETLIST" > "$NETLIST_LOCAL"
fi

# Compile order: cache_config first (typedefs), then the wrapper (uses
# the typedefs), then the testbench. The routed netlist + glbl come in
# as separate xelab args.
SOURCES=(
    "$REPO/src/cache_config.sv"
    "$REPO/tb/post_pnr_l2cache_wrap.sv"
    "$REPO/tb/post_pnr_smoke_tb.sv"
)

cat > files.prj <<EOF
sv work $REPO/src/cache_config.sv
sv work $REPO/tb/post_pnr_l2cache_wrap.sv
sv work $REPO/tb/post_pnr_smoke_tb.sv
verilog work $NETLIST_LOCAL
verilog work $GLBL
EOF

# Run xvlog through the .prj file (xsim's batch flow).
echo "---- xvlog (compile) ----"
xvlog --nolog --prj files.prj 2>&1 | tail -30
echo "(compile exit: $?)"

# Elaborate; --debug typical lets us see internal signals. Add
# -L unisims_ver -L unimacro_ver -L secureip for primitive bindings.
XELAB_ARGS=(
    --nolog
    --debug typical
    -L simprims_ver
    -L secureip
    -L xpm
    --timescale 1ns/1ps
    -relax
    -snapshot post_pnr_snap
    work.post_pnr_smoke_tb
    work.glbl
)
if [[ "$USE_SDF" == "1" && -f "$SDF" ]]; then
    echo "  SDF back-annotation: ENABLED"
    XELAB_ARGS+=(-sdfmax /post_pnr_smoke_tb/dut/dut="$SDF")
fi
echo "---- xelab (elaborate) ----"
xelab "${XELAB_ARGS[@]}" 2>&1 | tail -30

# Run.
echo "---- xsim (run) ----"
xsim --nolog --runall post_pnr_snap 2>&1 | tee xsim.log | tail -40

if grep -q "post_pnr_smoke: PASS" xsim.log; then
    echo ""
    echo "==== post_pnr_sim: PASS ===="
    exit 0
fi
echo ""
echo "==== post_pnr_sim: FAIL (see $WORK/xsim.log) ===="
exit 1
