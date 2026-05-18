# Multi-test Verilator runner for TableCache.
#
# Usage:
#   make smoke              # legacy single-file smoke (in this dir)
#   make t02                # tier-2 directed
#   make all                # everything
#   make WAVES=1 t02        # build + run with VCD
#   make clean
#
# Per-test config overrides:
#   make t02 POLICY=SRRIP VICTIM=1 DB_LATENCY=4

SRC_DIR := ../src
COMMON  := common
TESTS   := tests

# cache_config.sv must be first (package).
RTL := \
    $(SRC_DIR)/cache_config.sv \
    $(filter-out $(SRC_DIR)/cache_config.sv $(SRC_DIR)/l2_top.sv, $(wildcard $(SRC_DIR)/*.sv))

COMMON_TB := $(wildcard $(COMMON)/*.sv)

POLICY     ?= LRU
LINES      ?= 64
LINE_W     ?= 8
WAYS       ?= 4
BLOCK_W    ?= 32
DB_LATENCY ?= 1
VICTIM     ?= 0
VLINES     ?= 8
CBOM       ?= 1

DEFS := \
    +define+TC_POLICY=$(POLICY) \
    +define+TC_LINES=$(LINES) \
    +define+TC_LINE_W=$(LINE_W) \
    +define+TC_WAYS=$(WAYS) \
    +define+TC_BLOCK_W=$(BLOCK_W) \
    +define+TC_DB_LATENCY=$(DB_LATENCY) \
    +define+TC_VICTIM=$(VICTIM) \
    +define+TC_VICTIM_LINES=$(VLINES) \
    +define+TC_CBOM=$(CBOM)

VFLAGS := \
    --binary --timing -j 0 -Wall \
    -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN -Wno-WIDTHEXPAND \
    -Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-INITIALDLY \
    -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTITOP

ifeq ($(WAVES),1)
RUN_ARGS := +waves
VFLAGS   += --trace
else
RUN_ARGS :=
endif

.PHONY: smoke t02 t03 diag all clean

smoke: obj_dir_smoke/Vsmoke_tb
	./obj_dir_smoke/Vsmoke_tb $(RUN_ARGS)

obj_dir_smoke/Vsmoke_tb: smoke_tb.sv $(RTL)
	verilator $(VFLAGS) --top-module smoke_tb \
	    --Mdir obj_dir_smoke -o Vsmoke_tb \
	    $(RTL) smoke_tb.sv

t02: obj_dir_t02/Vt02_directed
	./obj_dir_t02/Vt02_directed $(RUN_ARGS)

obj_dir_t02/Vt02_directed: $(TESTS)/t02_directed.sv $(COMMON_TB) $(RTL)
	verilator $(VFLAGS) $(DEFS) --top-module t02_directed \
	    --Mdir obj_dir_t02 -o Vt02_directed \
	    $(RTL) $(COMMON_TB) $(TESTS)/t02_directed.sv

# Tier-3 random scoreboard. Override SEED/NTXN/RATIO_RD/RATIO_FULL/TIMEOUT_NS
# via make vars; they are passed as runtime plusargs.
SEED       ?= 1
NTXN       ?= 200
RATIO_RD   ?= 60
RATIO_FULL ?= 70
TIMEOUT_NS ?= 2000000

T03_RUN_ARGS := +seed=$(SEED) +ntxn=$(NTXN) +ratio_rd=$(RATIO_RD) \
                +ratio_full=$(RATIO_FULL) +timeout_ns=$(TIMEOUT_NS)
ifeq ($(VERBOSE),1)
T03_RUN_ARGS += +verbose
endif

t03: obj_dir_t03/Vt03_random
	./obj_dir_t03/Vt03_random $(RUN_ARGS) $(T03_RUN_ARGS)

obj_dir_t03/Vt03_random: $(TESTS)/t03_random.sv $(COMMON_TB) $(RTL)
	verilator $(VFLAGS) $(DEFS) --top-module t03_random \
	    --Mdir obj_dir_t03 -o Vt03_random \
	    $(RTL) $(COMMON_TB) $(TESTS)/t03_random.sv

diag: obj_dir_diag/Vt02_diag
	./obj_dir_diag/Vt02_diag $(RUN_ARGS)

obj_dir_diag/Vt02_diag: $(TESTS)/t02_diag.sv $(COMMON_TB) $(RTL)
	verilator $(VFLAGS) $(DEFS) --top-module t02_diag \
	    --Mdir obj_dir_diag -o Vt02_diag \
	    $(RTL) $(COMMON_TB) $(TESTS)/t02_diag.sv

all: smoke t02 t03

clean:
	rm -rf obj_dir_* *.vcd
