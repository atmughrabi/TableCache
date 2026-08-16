# Formal verification harnesses (yosys + z3 SMTBMC, sv2v for SV->V lowering)
ROOT     := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
.DELETE_ON_ERROR:
BUILD    := $(ROOT)/tb/formal/build
YOSYS    := yosys
SMTBMC   := yosys-smtbmc
SOLVER   := z3
SV2V     := $(if $(shell command -v sv2v 2>/dev/null),sv2v,$(HOME)/.local/bin/sv2v)
SV2V_FLAGS := -E Assert -DASSERT_OFF
FORMAL_Z3 := $(ROOT)/tb/formal/.venv/bin/z3
Z3_BIN := $(if $(wildcard $(FORMAL_Z3)),$(FORMAL_Z3),$(shell command -v z3 2>/dev/null))
Z3_DIR := $(dir $(Z3_BIN))
RUN_SMTBMC = PATH="$(Z3_DIR):$$PATH" $(SMTBMC)

HARNESS_1    := $(ROOT)/tb/formal/fifo_formal.sv
HARNESS_DEEP := $(ROOT)/tb/formal/fifo_formal_deep.sv
HARNESS_SCM  := $(ROOT)/tb/formal/scm_formal.sv
HARNESS_FLUSH:= $(ROOT)/tb/formal/flush_formal.sv
HARNESS_GRASP:= $(ROOT)/tb/formal/grasp_formal.sv
RTL_1        := $(ROOT)/src/fifo.sv
RTL_DEEP     := $(ROOT)/src/fifo.sv $(ROOT)/src/lfsr.sv $(ROOT)/src/lutram_1w_1r.sv
RTL_SCM      := $(ROOT)/src/set_clear_memory.sv $(ROOT)/src/toggle_memory_set.sv \
                $(ROOT)/src/toggle_memory.sv $(ROOT)/src/lutram_1w_mr.sv \
                $(ROOT)/src/lutram_1w_1r.sv $(ROOT)/src/lfsr.sv \
                $(ROOT)/src/cache_config.sv
RTL_FLUSH    := $(ROOT)/src/cache_config.sv $(ROOT)/src/tc_flush_controller.sv
RTL_GRASP    := $(ROOT)/src/GRASP.sv $(ROOT)/src/rrip_tree.sv
SMT2_1       := $(BUILD)/fifo.smt2
SMT2_DEEP    := $(BUILD)/fifo_deep.smt2
SMT2_SCM     := $(BUILD)/scm.smt2
SMT2_FLUSH   := $(BUILD)/flush.smt2
SMT2_GRASP   := $(BUILD)/grasp.smt2

.PHONY: all check-z3 bmc induct cover-fifo bmc-deep cover-deep bmc-scm cover-scm bmc-flush induct-flush cover-flush bmc-grasp induct-grasp cover-grasp clean
all: bmc induct cover-fifo bmc-deep cover-deep bmc-scm cover-scm bmc-flush induct-flush cover-flush bmc-grasp induct-grasp cover-grasp

check-z3:
	@test -x "$(Z3_BIN)" || { \
	    echo "z3 not found; create tb/formal/.venv and install requirements.txt"; \
	    exit 1; \
	}
	@version=`"$(Z3_BIN)" --version | awk '{print $$3}'`; \
	minimum=4.12.0; \
	test "`printf '%s\n' "$$minimum" "$$version" | sort -V | head -1`" = "$$minimum" || { \
	    echo "z3 $$version is too old; install tb/formal/requirements.txt (>= $$minimum)"; \
	    exit 1; \
	}

$(SMT2_1): $(HARNESS_1) $(RTL_1)
	@mkdir -p $(BUILD)
	# Lower SV -> plain Verilog through sv2v first. Yosys' built-in
	# SV reader (especially older apt-shipped 0.9 on Ubuntu 22.04 CI)
	# rejects typed parameters like 'parameter int unsigned' that the
	# harness uses. The other three targets already do this; matching
	# the pattern here keeps the formal job CI-portable.
	#
	# Need to feed sv2v ALL of fifo.sv's submodule deps even though the
	# DEPTH=1 generate branch in the harness doesn't instantiate them --
	# sv2v parses the whole file and needs to resolve the `.*` wildcard
	# port connections in fifo.sv lines 112/117/127 (which reference
	# lfsr / lutram_1w_1r) before yosys' plain-verilog reader can take
	# the lowered file. Without these deps sv2v leaves `.*` literally
	# in the output and yosys rejects "Wildcard port connections are
	# only supported in SystemVerilog mode."
	$(SV2V) $(SV2V_FLAGS) $(HARNESS_1) $(RTL_1) $(ROOT)/src/lfsr.sv $(ROOT)/src/lutram_1w_1r.sv > $(BUILD)/all.v
	@test "$$(grep -c 'assert (' $(BUILD)/all.v)" -ge 3
	@test "$$(grep -c 'cover (' $(BUILD)/all.v)" -ge 1
	$(YOSYS) -q -p "read -sv -formal $(BUILD)/all.v; prep -top fifo_formal -flatten; write_smt2 -wires $@"
	@test "$$(grep -c 'yosys-smt2-assert' $@)" -ge 1 || { echo "formal assertions missing from $@"; exit 1; }
	@test "$$(grep -c 'yosys-smt2-cover' $@)" -ge 1 || { echo "formal covers missing from $@"; exit 1; }

$(SMT2_DEEP): $(HARNESS_DEEP) $(RTL_DEEP)
	@mkdir -p $(BUILD)
	$(SV2V) $(SV2V_FLAGS) $(HARNESS_DEEP) $(RTL_DEEP) > $(BUILD)/all_deep.v
	@test "$$(grep -c 'assert (' $(BUILD)/all_deep.v)" -ge 3
	@test "$$(grep -c 'cover (' $(BUILD)/all_deep.v)" -ge 1
	$(YOSYS) -q -p "read -sv -formal $(BUILD)/all_deep.v; prep -top fifo_formal_deep -flatten; write_smt2 -wires $@"
	@test "$$(grep -c 'yosys-smt2-assert' $@)" -ge 1 || { echo "formal assertions missing from $@"; exit 1; }
	@test "$$(grep -c 'yosys-smt2-cover' $@)" -ge 1 || { echo "formal covers missing from $@"; exit 1; }

$(SMT2_SCM): $(HARNESS_SCM) $(RTL_SCM)
	@mkdir -p $(BUILD)
	$(SV2V) $(SV2V_FLAGS) $(HARNESS_SCM) $(RTL_SCM) > $(BUILD)/scm.v
	@test "$$(grep -c 'assert (' $(BUILD)/scm.v)" -ge 1
	@test "$$(grep -c 'cover (' $(BUILD)/scm.v)" -ge 1
	$(YOSYS) -q -p "read -sv -formal $(BUILD)/scm.v; prep -top scm_formal -flatten; write_smt2 -wires $@"
	@test "$$(grep -c 'yosys-smt2-assert' $@)" -ge 1 || { echo "formal assertions missing from $@"; exit 1; }
	@test "$$(grep -c 'yosys-smt2-cover' $@)" -ge 1 || { echo "formal covers missing from $@"; exit 1; }

$(SMT2_FLUSH): $(HARNESS_FLUSH) $(RTL_FLUSH)
	@mkdir -p $(BUILD)
	$(SV2V) $(SV2V_FLAGS) $(HARNESS_FLUSH) $(RTL_FLUSH) > $(BUILD)/flush.v
	@test "$$(grep -c 'assert (' $(BUILD)/flush.v)" -ge 10
	@test "$$(grep -c 'cover (' $(BUILD)/flush.v)" -ge 1
	$(YOSYS) -q -p "read -sv -formal $(BUILD)/flush.v; prep -top flush_formal -flatten; write_smt2 -wires $@"
	@test "$$(grep -c 'yosys-smt2-assert' $@)" -ge 1 || { echo "formal assertions missing from $@"; exit 1; }
	@test "$$(grep -c 'yosys-smt2-cover' $@)" -ge 1 || { echo "formal covers missing from $@"; exit 1; }

$(SMT2_GRASP): $(HARNESS_GRASP) $(RTL_GRASP)
	@mkdir -p $(BUILD)
	$(SV2V) $(SV2V_FLAGS) $(HARNESS_GRASP) $(RTL_GRASP) > $(BUILD)/grasp.v
	@test "$$(grep -c 'assert (' $(BUILD)/grasp.v)" -ge 12
	@test "$$(grep -c 'cover (' $(BUILD)/grasp.v)" -ge 4
	$(YOSYS) -q -p "read -sv -formal $(BUILD)/grasp.v; prep -top grasp_formal -flatten; write_smt2 -wires $@"
	@test "$$(grep -c 'yosys-smt2-assert' $@)" -ge 1 || { echo "formal assertions missing from $@"; exit 1; }
	@test "$$(grep -c 'yosys-smt2-cover' $@)" -ge 4 || { echo "formal covers missing from $@"; exit 1; }

bmc: check-z3 $(SMT2_1)        ; $(RUN_SMTBMC) --presat -s $(SOLVER) -t 32 $(SMT2_1)
induct: check-z3 $(SMT2_1)     ; $(RUN_SMTBMC) --presat -s $(SOLVER) -i -t 16 $(SMT2_1)
cover-fifo: check-z3 $(SMT2_1) ; $(RUN_SMTBMC) --presat -s $(SOLVER) -c -t 4 $(SMT2_1)
bmc-deep: check-z3 $(SMT2_DEEP)    ; $(RUN_SMTBMC) --presat -s $(SOLVER) -t 32 $(SMT2_DEEP)
cover-deep: check-z3 $(SMT2_DEEP)  ; $(RUN_SMTBMC) --presat -s $(SOLVER) -c -t 8 $(SMT2_DEEP)
bmc-scm: check-z3 $(SMT2_SCM)      ; $(RUN_SMTBMC) --presat -s $(SOLVER) -t 16 $(SMT2_SCM)
cover-scm: check-z3 $(SMT2_SCM)    ; $(RUN_SMTBMC) --presat -s $(SOLVER) -c -t 16 $(SMT2_SCM)
bmc-flush: check-z3 $(SMT2_FLUSH)      ; $(RUN_SMTBMC) --presat -s $(SOLVER) -t 32 $(SMT2_FLUSH)
induct-flush: check-z3 $(SMT2_FLUSH)   ; $(RUN_SMTBMC) --presat -s $(SOLVER) -i -t 24 $(SMT2_FLUSH)
cover-flush: check-z3 $(SMT2_FLUSH)    ; $(RUN_SMTBMC) --presat -s $(SOLVER) -c -t 32 $(SMT2_FLUSH)
# GRASP invariants are pure combinational so BMC alone is enough; the
# k-induction target is kept for symmetry with the other harnesses.
bmc-grasp: check-z3 $(SMT2_GRASP)      ; $(RUN_SMTBMC) --presat -s $(SOLVER) -t 2 $(SMT2_GRASP)
induct-grasp: check-z3 $(SMT2_GRASP)   ; $(RUN_SMTBMC) --presat -s $(SOLVER) -i -t 2 $(SMT2_GRASP)
cover-grasp: check-z3 $(SMT2_GRASP)    ; $(RUN_SMTBMC) --presat -s $(SOLVER) -c -t 3 $(SMT2_GRASP)

clean:
	rm -rf $(BUILD)
