VIR ?= vir
IVERILOG ?= iverilog

# The fomu-upload recipe uses bash's ${PIPESTATUS}; make's default
# shell (dash on Debian/Ubuntu) rejects it with "Bad substitution".
SHELL := /bin/bash

# The 6502 program (asm/<name>.s, name without the extension) that the
# Fomu flows assemble, simulate, and upload. Override per invocation,
# e.g. `make fomu-sim PROG=s3` or `make fomu-upload PROG=myprog`.
PROG ?= hw1

# The CPU-only flows (tb.sv) link the core's Verilog; the Fomu build's
# fomu_top.sv and fomu_memory.sv (hard-cell SPRAM instantiations) are
# excluded there (the fomu-sim flow links them with ext/Spram.sv).
# Lazily expanded: after `make clean` the files only exist once the
# build/.virdant.stamp prerequisite has run.
TB_SV = $(filter-out build/fomu_top.sv build/fomu_memory.sv,$(wildcard build/*.sv))

check:
	$(VIR) check

build:
	$(VIR) build

build/%.exp.hex: asm/%.exp tools/exp.py
	python3 tools/exp.py $< $@

build/%.bin: asm/%.s asm/6502.cfg
	mkdir -p build
	ca65 $< -o build/$*.o
	ld65 -C asm/6502.cfg -o $@ build/$*.o

build/%.hex: build/%.bin tools/mkhex.py
	python3 tools/mkhex.py $< > $@

test-%: build/.virdant.stamp build/%.hex build/%.exp.hex
	$(IVERILOG) -g2012 $(TB_SV) tb.sv -o build/run
	./build/run +hex=build/$*.hex +exp=build/$*.exp.hex

test: test-s1 test-s2 test-s3 test-s4 test-s5 test-s6 test-s7

# -- Fomu (iCE40 UP5K) flows --

# fomu-sim's flash image: the program at $080000 (reset vector
# patched to $0200). Named for PROG, so switching PROG rebuilds it.
build/$(PROG).flash.hex: build/$(PROG).bin tools/mkflash.py
	python3 tools/mkflash.py $< $@

build/ClkDiv.sv: ext/ClkDiv.sv
	cp $< $@

# The emitted Verilog (build/*.sv) that the sim flows link.
build/.virdant.stamp: $(wildcard src/*.vir) $(wildcard ../lib/*.vir)
	$(VIR) build
	touch $@

fomu-sim: build/.virdant.stamp build/$(PROG).flash.hex build/ClkDiv.sv
	$(IVERILOG) -g2012 build/*.sv ext/Spram.sv ext/Flash.sv tb-fomu.sv -o build/run-fomu
	./build/run-fomu +flashhex=build/$(PROG).flash.hex

# The memory's SPRAM cells and the ClkDiv divider are instantiated
# directly in Virdant (ext mods emitted by name) and must exist as
# Verilog: ClkDiv is copied into build/ for yosys's script (which
# globs build/*.sv); SB_SPRAM256KA comes from yosys's own cell
# library, and the SPRAM sim model is only needed for iverilog.
fomu-build: build/ClkDiv.sv
	$(VIR) bitstream

# Flash image: bitstream at $00000, 64K program at $080000 (with the
# reset vector patched to $0200). Replaces the Foboot bitstream -- the
# board's USB/DFU stops working until re-flashed over SPI.
#
# The upload regenerates the image first, then adds the DFU suffix
# (dfu-suffix needs the filename on its action flag, -a, and refuses
# to double-suffix; the bare img target stays suffixless). dfu-util
# reports failure when the board reboots into the new bitstream before
# the final status poll; reaching that poll means every byte was sent,
# and the Fomu drops off USB the moment the design boots (it holds the
# USB pins low) -- that is success, not failure, so the specific error
# is accepted here (the same logic lives in `vir upload`).
fomu-upload: build/$(PROG).bin
	python3 tools/mkimg.py build/sixfiveohtwo.bin build/$(PROG).bin build/sixfiveohtwo.img
	dfu-suffix -v 1209 -p 5bf0 -a build/sixfiveohtwo.img
	set +e; dfu-util -d 1209:5bf0 -D build/sixfiveohtwo.img 2>&1 | tee /tmp/opencode/dfu.log; rc=$${PIPESTATUS[0]}; set -e; \
	if grep -q "unable to read DFU status" /tmp/opencode/dfu.log; then \
		echo "Uploaded: the board rebooted into the new design (USB gone, as expected)"; \
	elif test $$rc -eq 0; then \
		echo "Uploaded"; \
	else \
		echo "dfu-util failed:"; cat /tmp/opencode/dfu.log; exit 1; \
	fi

# The suffixless base image (no DFU suffix; fomu-upload adds one).
build/sixfiveohtwo.img: build/sixfiveohtwo.bin build/$(PROG).bin tools/mkimg.py
	python3 tools/mkimg.py build/sixfiveohtwo.bin build/$(PROG).bin $@

clean:
	rm -rf build

.PHONY: check build test fomu-sim fomu-build fomu-upload clean
.PRECIOUS: build/%.hex

klaus: build/klaus.hex

build/klaus.hex: klaus/6502_functional_test.bin tools/mkklaus.py
	mkdir -p build
	python3 tools/mkklaus.py $< > $@

klaus-run: build/.virdant.stamp build/klaus.hex
	$(IVERILOG) -g2012 $(TB_SV) tb.sv -o build/run
	./build/run +hex=$< +klaus=1

.PHONY: klaus klaus-run
