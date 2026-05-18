# Formal verification harnesses (yosys + z3 SMTBMC)
#
# Usage:
#   make bmc         # bounded model check, 32 cycles
#   make induct      # k-induction (unbounded proof)
#   make all         # both
#   make clean
#
# Deps: yosys, yosys-smtbmc, z3 (apt install yosys z3)

ROOT     := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
BUILD    := $(ROOT)/tb/formal/build
SMT2     := $(BUILD)/fifo.smt2

YOSYS    := yosys
SMTBMC   := yosys-smtbmc
SOLVER   := z3

HARNESS  := $(ROOT)/tb/formal/fifo_formal.sv
RTL      := $(ROOT)/src/fifo.sv

.PHONY: all bmc induct clean

all: bmc induct

$(SMT2): $(HARNESS) $(RTL)
	@mkdir -p $(BUILD)
	$(YOSYS) -q -p "verilog_defines -DASSERT_OFF; read -sv -formal $(HARNESS) $(RTL); prep -top fifo_formal -flatten; write_smt2 -wires $(SMT2)"

bmc: $(SMT2)
	$(SMTBMC) --presat -s $(SOLVER) -t 32 $(SMT2)

induct: $(SMT2)
	$(SMTBMC) --presat -s $(SOLVER) -i -t 16 $(SMT2)

clean:
	rm -rf $(BUILD)
