# Formal verification harnesses (yosys + z3 SMTBMC, sv2v for SV->V lowering)
ROOT     := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
BUILD    := $(ROOT)/tb/formal/build
YOSYS    := yosys
SMTBMC   := yosys-smtbmc
SOLVER   := z3
SV2V     := $(if $(shell command -v sv2v 2>/dev/null),sv2v,$(HOME)/.local/bin/sv2v)

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

.PHONY: all bmc induct bmc-deep induct-deep bmc-scm induct-scm bmc-flush induct-flush bmc-grasp induct-grasp clean
all: bmc induct bmc-deep induct-deep bmc-scm induct-scm bmc-flush induct-flush bmc-grasp induct-grasp

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
	$(SV2V) -DASSERT_OFF $(HARNESS_1) $(RTL_1) $(ROOT)/src/lfsr.sv $(ROOT)/src/lutram_1w_1r.sv > $(BUILD)/all.v
	$(YOSYS) -q -p "read_verilog -formal $(BUILD)/all.v; prep -top fifo_formal -flatten; write_smt2 -wires $@"

$(SMT2_DEEP): $(HARNESS_DEEP) $(RTL_DEEP)
	@mkdir -p $(BUILD)
	$(SV2V) -DASSERT_OFF $(HARNESS_DEEP) $(RTL_DEEP) > $(BUILD)/all_deep.v
	$(YOSYS) -q -p "read_verilog -formal $(BUILD)/all_deep.v; prep -top fifo_formal_deep -flatten; write_smt2 -wires $@"

$(SMT2_SCM): $(HARNESS_SCM) $(RTL_SCM)
	@mkdir -p $(BUILD)
	$(SV2V) -DASSERT_OFF $(HARNESS_SCM) $(RTL_SCM) > $(BUILD)/scm.v
	$(YOSYS) -q -p "read -sv -formal $(BUILD)/scm.v; prep -top scm_formal -flatten; write_smt2 -wires $@"

$(SMT2_FLUSH): $(HARNESS_FLUSH) $(RTL_FLUSH)
	@mkdir -p $(BUILD)
	$(SV2V) -DASSERT_OFF $(HARNESS_FLUSH) $(RTL_FLUSH) > $(BUILD)/flush.v
	$(YOSYS) -q -p "read -sv -formal $(BUILD)/flush.v; prep -top flush_formal -flatten; write_smt2 -wires $@"

$(SMT2_GRASP): $(HARNESS_GRASP) $(RTL_GRASP)
	@mkdir -p $(BUILD)
	$(SV2V) -DASSERT_OFF $(HARNESS_GRASP) $(RTL_GRASP) > $(BUILD)/grasp.v
	$(YOSYS) -q -p "read -sv -formal $(BUILD)/grasp.v; prep -top grasp_formal -flatten; write_smt2 -wires $@"

bmc: $(SMT2_1)        ; $(SMTBMC) --presat -s $(SOLVER) -t 32 $<
induct: $(SMT2_1)     ; $(SMTBMC) --presat -s $(SOLVER) -i -t 16 $<
bmc-deep: $(SMT2_DEEP)    ; $(SMTBMC) --presat -s $(SOLVER) -t 32 $<
induct-deep: $(SMT2_DEEP) ; $(SMTBMC) --presat -s $(SOLVER) -i -t 24 $<
bmc-scm: $(SMT2_SCM)      ; $(SMTBMC) --presat -s $(SOLVER) -t 16 $<
induct-scm: $(SMT2_SCM)   ; $(SMTBMC) --presat -s $(SOLVER) -i -t 16 $<
bmc-flush: $(SMT2_FLUSH)      ; $(SMTBMC) --presat -s $(SOLVER) -t 32 $<
induct-flush: $(SMT2_FLUSH)   ; $(SMTBMC) --presat -s $(SOLVER) -i -t 16 $<
# GRASP invariants are pure combinational so BMC alone is enough; the
# k-induction target is kept for symmetry with the other harnesses.
bmc-grasp: $(SMT2_GRASP)      ; $(SMTBMC) --presat -s $(SOLVER) -t 8 $<
induct-grasp: $(SMT2_GRASP)   ; $(SMTBMC) --presat -s $(SOLVER) -i -t 8 $<

clean:
	rm -rf $(BUILD)
