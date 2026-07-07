# cocotb Makefile for TableCache L2.
# Usage:
#   source .venv/bin/activate
#   make MODULE=test_smoke
#   make MODULE=test_random NTXN=200 SEED=1
SIM        ?= verilator
TOPLEVEL_LANG ?= verilog
TOPLEVEL   ?= dut_cocotb
MODULE     ?= test_smoke

# Knobs forwarded into the SV defines and into the test via environ.
POLICY     ?= LRU
LINES      ?= 64
LINE_W     ?= 8
WAYS       ?= 4
# BLOCK_W is intentionally fixed at 32 on the bare-cocotb (l2_cache) path:
# `dut_cocotb.sv` declares `parameter int BLOCK_W = 32` without a TC_BLOCK_W
# guard, and every test_*.py file under tb/cocotb has BLOCK_BYTES hardcoded
# to 4 (with golden() returning 32-bit words). Wider buses are exercised on
# the shim integration path (test_shim_cache) at BLOCK_W=WIDE_W=512.
BLOCK_W    ?= 32
DB_LATENCY ?= 1
VICTIM     ?= 0
CBOM       ?= 1
NTXN       ?= 100
SEED       ?= 1
RATIO_RD   ?= 60
RATIO_FULL ?= 70

# Guard: warn if a user sets BLOCK_W != 32 on a bare-cocotb target. The
# dut_cocotb.sv parameter ignores TC_BLOCK_W (bus width stays 32), so the
# override silently does nothing for the RTL while the Python harness still
# expects 4-byte beats. Force-error instead of letting the test fail with a
# confusing data-mismatch message.
ifeq ($(filter $(MODULE),test_narrow_shim test_shim_latency test_shim_throughput test_shim_prefill_race test_shim_cache test_shim_multiread test_shim_reorder),)
ifneq ($(BLOCK_W),32)
$(error BLOCK_W=$(BLOCK_W) is not supported on the bare-cocotb path (MODULE=$(MODULE)); only BLOCK_W=32 is wired end-to-end. Use MODULE=test_shim_cache to exercise wider buses (BLOCK_W=512).)
endif
endif

REPO_ROOT  := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
SRC_DIR    := $(REPO_ROOT)/src
TB_DIR     := $(REPO_ROOT)/tb/cocotb

# Shim-only target uses a different top + a single RTL source.
ifneq (,$(filter $(MODULE),test_narrow_shim test_shim_latency test_shim_throughput test_shim_prefill_race))
NARROW_W   ?= 32
WIDE_W     ?= 512
export TC_NARROW_W := $(NARROW_W)
export TC_BLOCK_W  := $(WIDE_W)
TOPLEVEL := dut_shim_only
VERILOG_SOURCES := $(SRC_DIR)/tc_narrow_shim.sv $(TB_DIR)/axi_protocol_checker.sv $(TB_DIR)/dut_shim_only.sv
EXTRA_ARGS += +define+TC_NARROW_W=$(NARROW_W) +define+TC_BLOCK_W=$(WIDE_W)
ifeq ($(TC_PROMOTE_WMISS),1)
EXTRA_ARGS += +define+TC_PROMOTE_WMISS=1
endif
else ifneq (,$(filter $(MODULE),test_shim_cache test_shim_multiread test_shim_reorder))
NARROW_W   ?= 32
WIDE_W     ?= 512
# Force LINES/LINE_W/WAYS overrides for the shim+cache integration target.
# The top-level `?=` defaults above (LINES=64 LINE_W=8 WAYS=4) are for the
# legacy l2_cache-only tests; with LINE_W>1 a physical cache line spans
# multiple BLOCK_W beats, but the narrow-port shim only issues 1-beat req_ar
# (m_arlen=0) and relies on the cache's beat-selection. Use LINE_W=2 as the
# smallest non-degenerate value Verilator accepts (LINE_W=1 triggers a
# zero-width bit-extract in the upstream cache RTL).
LINES      := 128
LINE_W     := 2
WAYS       := 8
export TC_NARROW_W := $(NARROW_W)
export TC_BLOCK_W  := $(WIDE_W)
export TC_LINES    := $(LINES)
export TC_LINE_W   := $(LINE_W)
export TC_WAYS     := $(WAYS)
ifdef READ_REORDER_DEPTH
export TC_READ_REORDER_DEPTH := $(READ_REORDER_DEPTH)
endif
TOPLEVEL := dut_shim_cache
VERILOG_SOURCES := $(SRC_DIR)/cache_config.sv \
    $(filter-out $(SRC_DIR)/cache_config.sv $(SRC_DIR)/l2_top.sv,$(wildcard $(SRC_DIR)/*.sv)) \
    $(TB_DIR)/axi_protocol_checker.sv \
    $(TB_DIR)/dut_shim_cache.sv
EXTRA_ARGS += +define+TC_NARROW_W=$(NARROW_W) +define+TC_BLOCK_W=$(WIDE_W) \
              +define+TC_LINES=$(LINES) +define+TC_LINE_W=$(LINE_W) +define+TC_WAYS=$(WAYS)
ifdef READ_REORDER_DEPTH
EXTRA_ARGS += +define+TC_READ_REORDER_DEPTH=$(READ_REORDER_DEPTH)
endif
else ifeq ($(MODULE),test_flush)
TOPLEVEL := dut_flush
VERILOG_SOURCES := $(SRC_DIR)/cache_config.sv \
    $(filter-out $(SRC_DIR)/cache_config.sv $(SRC_DIR)/l2_top.sv $(SRC_DIR)/tc_narrow_shim.sv,$(wildcard $(SRC_DIR)/*.sv)) \
    $(TB_DIR)/axi_protocol_checker.sv \
    $(TB_DIR)/dut_flush.sv
else ifeq ($(MODULE),test_l2top)
# Direct integration test of l2_top (the AXI4 wrapper). Differs from
# dut_cocotb.sv in that the DUT chain is l2_top -> l2_cache (vs
# l2_cache directly). Validates l2_top's parameter casting + port
# forwarding + .* connection -- previously only checked at synth time.
TOPLEVEL := dut_l2top
VERILOG_SOURCES := $(SRC_DIR)/cache_config.sv \
    $(filter-out $(SRC_DIR)/cache_config.sv $(SRC_DIR)/tc_narrow_shim.sv,$(wildcard $(SRC_DIR)/*.sv)) \
    $(TB_DIR)/dut_l2top.sv
# Map POLICY name -> integer index for l2_top's REPLACEMENT_POLICY param.
# (l2_cache uses POLICY enum; l2_top uses the integer index cast.)
ifeq ($(POLICY),LRU)
TC_POLICY_INT := 0
else ifeq ($(POLICY),FRQ)
TC_POLICY_INT := 1
else ifeq ($(POLICY),SECOND_CHANCE)
TC_POLICY_INT := 2
else ifeq ($(POLICY),RANDOM)
TC_POLICY_INT := 3
else ifeq ($(POLICY),SRRIP)
TC_POLICY_INT := 4
else ifeq ($(POLICY),GRASP)
TC_POLICY_INT := 5
else
TC_POLICY_INT := 0
endif
EXTRA_ARGS += +define+TC_POLICY_INT=$(TC_POLICY_INT)
else ifeq ($(MODULE),test_l2top_flush)
# Flush-through-l2_top integration: tc_flush_controller -> l2_top -> AxiRam.
# Verifies a CBOM (CleanInvalid) whole-cache flush actually reaches l2_cache
# THROUGH the l2_top AXI wrapper -- i.e. that l2_top forwards s00_axi_arsnoop
# and is built with INCLUDE_CBOM=1. dut_flush.sv covers the same flush against
# l2_cache directly; this catches l2_top-boundary snoop/CBOM drops.
TOPLEVEL := dut_l2top_flush
VERILOG_SOURCES := $(SRC_DIR)/cache_config.sv \
    $(filter-out $(SRC_DIR)/cache_config.sv $(SRC_DIR)/tc_narrow_shim.sv,$(wildcard $(SRC_DIR)/*.sv)) \
    $(TB_DIR)/dut_l2top_flush.sv
ifeq ($(POLICY),LRU)
TC_POLICY_INT := 0
else ifeq ($(POLICY),FRQ)
TC_POLICY_INT := 1
else ifeq ($(POLICY),SECOND_CHANCE)
TC_POLICY_INT := 2
else ifeq ($(POLICY),RANDOM)
TC_POLICY_INT := 3
else ifeq ($(POLICY),SRRIP)
TC_POLICY_INT := 4
else ifeq ($(POLICY),GRASP)
TC_POLICY_INT := 5
else
TC_POLICY_INT := 0
endif
EXTRA_ARGS += +define+TC_POLICY_INT=$(TC_POLICY_INT)
else
# All RTL files (cache_config first, l2_cache and friends; exclude l2_top and shim).
VERILOG_SOURCES := $(SRC_DIR)/cache_config.sv \
    $(filter-out $(SRC_DIR)/cache_config.sv $(SRC_DIR)/l2_top.sv $(SRC_DIR)/tc_narrow_shim.sv,$(wildcard $(SRC_DIR)/*.sv)) \
    $(TB_DIR)/axi_protocol_checker.sv \
    $(TB_DIR)/dut_cocotb.sv
endif

EXTRA_ARGS += --timing
# Coverage: enable with COV=1. Emits sim_build/logs/coverage.dat which
# `verilator_coverage` merges + annotates. Slows sim ~2x; off by default.
# --coverage-user picks up SVA `cover property` hits.
ifeq ($(COV),1)
EXTRA_ARGS += --coverage --coverage-line --coverage-toggle --coverage-user
endif
# X-propagation: enable with XPROP=1. Verilator randomizes uninit storage
# and unassigned signals; any test that reads pre-fill data fails. Catches
# reset-then-read-before-fill bugs that Verilator's default (drive 0) hides.
ifeq ($(XPROP),1)
EXTRA_ARGS += --x-assign unique --x-initial unique
endif
# Stats (item 2): --stats dumps FSM/var/inst counts and per-process line
# counts to sim_build/Vtop__stats.txt. Free; on by default.
EXTRA_ARGS += --stats --stats-vars
# VCD trace is hugely slow at BLOCK_W>=512 (signal count explodes). Opt in
# only when explicitly requested (TRACE=1) or for the small-bus builds.
ifeq ($(TRACE),1)
EXTRA_ARGS += --trace --trace-structs
else ifeq ($(filter $(MODULE),test_narrow_shim test_shim_latency test_shim_throughput test_shim_prefill_race test_shim_cache test_shim_multiread test_shim_reorder),)
EXTRA_ARGS += --trace --trace-structs
endif
EXTRA_ARGS += -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
              -Wno-VARHIDDEN -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-INITIALDLY \
              -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTITOP \
              -Wno-ALWCOMBORDER -Wno-UNOPTFLAT -Wno-BLKLOOPINIT \
              -Wno-SYMRSVDWORD
EXTRA_ARGS += +define+TC_POLICY=$(POLICY) +define+TC_LINES=$(LINES) +define+TC_LINE_W=$(LINE_W) \
              +define+TC_WAYS=$(WAYS) \
              +define+TC_DB_LATENCY=$(DB_LATENCY) +define+TC_VICTIM=$(VICTIM) +define+TC_CBOM=$(CBOM)
# Optional RTL diagnostic $display blocks (e.g. DIAG=DIAG_FINISH DIAG_STALL).
# Harmless when unset; forwards each token as a +define+.
ifdef DIAG
EXTRA_ARGS += $(patsubst %,+define+%,$(DIAG))
endif
# Enable Verilator SVA checking (concurrent assert property). OFF by default
# because the cocotb flow historically ran without it; ASSERT=1 turns on the
# internal invariants (e.g. inuse_id_no_same_cycle_collide) as real failures.
ifeq ($(ASSERT),1)
EXTRA_ARGS += --assert
endif
# DATABANK_SDP + SDP_WRITE_INPUT_REG: only forward when explicitly set so
# pre-existing tests that don't set them keep the historical defaults.
ifneq ($(DATABANK_SDP),)
EXTRA_ARGS += +define+TC_DATABANK_SDP=$(DATABANK_SDP)
endif
ifneq ($(SDP_WRITE_INPUT_REG),)
EXTRA_ARGS += +define+TC_SDP_WRITE_INPUT_REG=$(SDP_WRITE_INPUT_REG)
endif
# N_BANKS: only forward when set so the tree's default (1) is unaffected
# for pre-existing tests. See experiment/banked-memory and
# experiment/DESIGN_BANKED_MEMORY.md.
ifneq ($(N_BANKS),)
EXTRA_ARGS += +define+TC_N_BANKS=$(N_BANKS)
endif
# GRASP_HIGH_REGIONS / GRASP_MODERATE_REGIONS: number of address windows per
# GRASP reuse class. Only forwarded when set so existing tests keep the
# single-window default (1). Used by MODULE=test_grasp_multi.
ifneq ($(GRASP_HIGH_REGIONS),)
EXTRA_ARGS += +define+TC_GRASP_HIGH_REGIONS=$(GRASP_HIGH_REGIONS)
endif
ifneq ($(GRASP_MODERATE_REGIONS),)
EXTRA_ARGS += +define+TC_GRASP_MODERATE_REGIONS=$(GRASP_MODERATE_REGIONS)
endif
# ADDR_L / ADDR_H: cacheable address range (must be NAPOT). Only forwarded when
# set so existing tests keep the default [0x80000000,0xFFFFFFFF] (OMITTED_ADDR_W=1).
# Set ADDR_L=0 ADDR_H=0xFFFFFFFF for a base-0 full range (OMITTED_ADDR_W=0).
# Values are normalized to a plain decimal literal so a 0x.. knob is legal Verilog.
ifneq ($(ADDR_L),)
ADDR_L_DEC := $(shell printf '%u' $(ADDR_L))
EXTRA_ARGS += +define+TC_ADDR_L=$(ADDR_L_DEC)
endif
ifneq ($(ADDR_H),)
ADDR_H_DEC := $(shell printf '%u' $(ADDR_H))
EXTRA_ARGS += +define+TC_ADDR_H=$(ADDR_H_DEC)
endif
ifeq ($(filter $(MODULE),test_narrow_shim test_shim_latency test_shim_throughput test_shim_prefill_race test_shim_cache test_shim_multiread test_shim_reorder),)
EXTRA_ARGS += +define+TC_BLOCK_W=$(BLOCK_W)
endif
# DIAG knobs: pass DIAG=1 (DB-level) or DIAG=2 (DB + stall) to enable per-cycle dumps.
ifeq ($(DIAG),1)
EXTRA_ARGS += +define+DIAG_DB
endif
ifeq ($(DIAG),2)
EXTRA_ARGS += +define+DIAG_DB +define+DIAG_STALL2 +define+DIAG_FINISH
endif

# Pass test parameters via env so Python can read them.
export TC_NTXN     := $(NTXN)
export TC_SEED     := $(SEED)
export TC_RATIO_RD := $(RATIO_RD)
export TC_RATIO_FULL := $(RATIO_FULL)
export TC_LINES    := $(LINES)
export TC_LINE_W   := $(LINE_W)
export TC_WAYS     := $(WAYS)
# Cacheable base: exported so tests build addresses at the configured range.
# Empty unless ADDR_L is set; tb_common falls back to 0x80000000.
export TC_ADDR_L   := $(ADDR_L)
export TC_ADDR_H   := $(ADDR_H)
ifeq ($(filter $(MODULE),test_narrow_shim test_shim_latency test_shim_throughput test_shim_prefill_race test_shim_cache test_shim_multiread test_shim_reorder),)
export TC_BLOCK_W  := $(BLOCK_W)
endif
# workload knobs (test_workload.py); leave default if unset
TC_POOL_LINES     ?=
TC_HOT_PCT        ?=
TC_HOT_ACCESS_PCT ?=
TC_RD_PCT         ?=
TC_FULL_PCT       ?=
ifneq ($(TC_POOL_LINES),)
export TC_POOL_LINES
endif
ifneq ($(TC_HOT_PCT),)
export TC_HOT_PCT
endif
ifneq ($(TC_HOT_ACCESS_PCT),)
export TC_HOT_ACCESS_PCT
endif
ifneq ($(TC_RD_PCT),)
export TC_RD_PCT
endif
ifneq ($(TC_FULL_PCT),)
export TC_FULL_PCT
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

# ---- Static lint gate (item 9 in doc/VERIFICATION_XILINX_VIP_ROADMAP.md) ----
# Runs Verilator with -Wall and the SAME suppressions the build uses (those
# warnings are known-benign upstream patterns: UNUSEDSIGNAL, PINCONNECTEMPTY,
# WIDTHEXPAND in assertion comparisons, etc.). Exits non-zero on anything
# else, which is the production gate -- new latches, multi-drivers,
# bit-width truncations would all fall out here.
LINT_SUPPRESS := -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
                  -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN -Wno-WIDTHEXPAND \
                  -Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-INITIALDLY \
                  -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTITOP \
                  -Wno-ALWCOMBORDER -Wno-UNOPTFLAT -Wno-BLKLOOPINIT \
                  -Wno-SYMRSVDWORD
LINT_DEFINES  := +define+TC_POLICY=LRU +define+TC_LINES=64 +define+TC_LINE_W=8 \
                  +define+TC_WAYS=4 +define+TC_DB_LATENCY=1 +define+TC_VICTIM=0 \
                  +define+TC_CBOM=1 +define+TC_BLOCK_W=32
.PHONY: lint
lint:
	verilator --lint-only -Wall --top-module l2_cache $(LINT_SUPPRESS) $(LINT_DEFINES) \
	    $(SRC_DIR)/cache_config.sv \
	    $(filter-out $(SRC_DIR)/cache_config.sv $(SRC_DIR)/l2_top.sv $(SRC_DIR)/tc_narrow_shim.sv,$(wildcard $(SRC_DIR)/*.sv))
	@echo "lint: clean"

.PHONY: perf
perf:
	@python3 $(TB_DIR)/perf.py

.PHONY: vlint
vlint:
	@VERIBLE=$$(command -v verible-verilog-lint 2>/dev/null || \
	            echo $$HOME/.local/bin/verible-verilog-lint); \
	if [ ! -x "$$VERIBLE" ]; then \
	    echo "verible-verilog-lint not found; download from"; \
	    echo "  https://github.com/chipsalliance/verible/releases"; \
	    exit 1; \
	fi; \
	cd $(REPO_ROOT) && $$VERIBLE --rules_config_search src/*.sv && \
	echo "vlint: clean (bug-class rules only -- see .rules.verible_lint)"

# Open the most recent VCD in GTKWave. Re-run a test with TRACE=1 first
# (default builds dump dump.vcd to the current dir).
.PHONY: wave
wave:
	@VCD=$$(ls -t $(TB_DIR)/dump.vcd $(REPO_ROOT)/tb/dump.vcd 2>/dev/null | head -1); \
	if [ -z "$$VCD" ]; then \
	    echo "no dump.vcd found. Re-run a test with TRACE=1, e.g.:"; \
	    echo "  TRACE=1 make MODULE=test_smoke"; \
	    exit 1; \
	fi; \
	if ! command -v gtkwave >/dev/null; then \
	    echo "gtkwave not installed: sudo apt install gtkwave"; \
	    exit 1; \
	fi; \
	echo "opening $$VCD ..."; \
	gtkwave "$$VCD" &
