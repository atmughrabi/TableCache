# Formal verification harnesses (yosys + z3 SMTBMC, sv2v for SV->V lowering)
ROOT     := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
BUILD    := $(ROOT)/tb/formal/build
YOSYS    := yosys
SMTBMC   := yosys-smtbmc
SOLVER   := z3
SV2V     := $(if $(shell command -v sv2v 2>/dev/null),sv2v,$(HOME)/.local/bin/sv2v)

HARNESS_1    := $(ROOT)/tb/formal/fifo_formal.sv
HARNESS_DEEP := $(ROOT)/tb/formal/fifo_formal_deep.sv
RTL_1        := $(ROOT)/src/fifo.sv
RTL_DEEP     := $(ROOT)/src/fifo.sv $(ROOT)/src/lfsr.sv $(ROOT)/src/lutram_1w_1r.sv
SMT2_1       := $(BUILD)/fifo.smt2
SMT2_DEEP    := $(BUILD)/fifo_deep.smt2

.PHONY: all bmc induct bmc-deep induct-deep clean
all: bmc induct bmc-deep induct-deep

$(SMT2_1): $(HARNESS_1) $(RTL_1)
	@mkdir -p $(BUILD)
	$(YOSYS) -q -p "verilog_defines -DASSERT_OFF; read -sv -formal $(HARNESS_1) $(RTL_1); prep -top fifo_formal -flatten; write_smt2 -wires $@"

$(SMT2_DEEP): $(HARNESS_DEEP) $(RTL_DEEP)
	@mkdir -p $(BUILD)
	$(SV2V) -DASSERT_OFF $(HARNESS_DEEP) $(RTL_DEEP) > $(BUILD)/all_deep.v
	$(YOSYS) -q -p "read_verilog -formal $(BUILD)/all_deep.v; prep -top fifo_formal_deep -flatten; write_smt2 -wires $@"

bmc: $(SMT2_1)        ; $(SMTBMC) --presat -s $(SOLVER) -t 32 $<
induct: $(SMT2_1)     ; $(SMTBMC) --presat -s $(SOLVER) -i -t 16 $<
bmc-deep: $(SMT2_DEEP)    ; $(SMTBMC) --presat -s $(SOLVER) -t 32 $<
induct-deep: $(SMT2_DEEP) ; $(SMTBMC) --presat -s $(SOLVER) -i -t 24 $<

clean:
	rm -rf $(BUILD)
