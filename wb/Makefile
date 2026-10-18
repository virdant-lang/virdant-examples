VIR      ?= vir
IVERILOG ?= iverilog
VVP      ?= vvp

VIR_SOURCES := $(wildcard src/*.vir)
EXT_SOURCES := $(wildcard ext/*.sv)
TB_SOURCES  := tb/wishbone_master.sv tb/tb.sv
BUILD_DIR   := build
SIM_BIN     := $(BUILD_DIR)/tb

.PHONY: all build sim clean

all: build sim

# Compile Virdant sources into Verilog in build/
build: $(VIR_SOURCES)
	$(VIR) build

# Compile the testbench simulation
$(SIM_BIN): build $(VIR_SOURCES) $(EXT_SOURCES) $(TB_SOURCES)
	$(IVERILOG) -g2012 -o $@ $(BUILD_DIR)/*.sv $(EXT_SOURCES) $(TB_SOURCES)

# Build and run the simulation
sim: $(SIM_BIN)
	cd $(BUILD_DIR) && $(VVP) tb

clean:
	rm -rf $(BUILD_DIR)
