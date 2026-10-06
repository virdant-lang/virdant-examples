VIR ?= vir

# Which animation to build, simulate, and upload; any .txt in
# content/ works:
#     make test ANIM=content/showcase.txt
#     make upload-content ANIM=content/showcase.txt
ANIM ?= content/anim.txt

STEM   = $(basename $(notdir $(ANIM)))
BIN    = content/$(STEM).bin
HEX    = content/$(STEM).hex
EXPECT = content/$(STEM).expect

# Assemble the animation into flash content (.bin) plus the images
# the testbench consumes (.hex, .expect).
$(BIN) $(HEX) $(EXPECT) &: $(ANIM) scripts/anim.py
	python3 scripts/anim.py $(ANIM)

# Simulate with Icarus Verilog against the assembled animation.
# The bench reads anim.hex / anim.expect from build/, staged from
# the selected animation before the run.
test: $(HEX) $(EXPECT)
	mkdir -p build
	cp $(HEX) build/anim.hex
	cp $(EXPECT) build/anim.expect
	$(VIR) run-icarus

# Synthesize and flash the bitstream (offset 0 of the SPI flash).
upload:
	$(VIR) upload

# Program the selected animation, well above the bitstream region.
upload-content: $(BIN)
	iceprog -o 0x40000 $(BIN)

clean:
	rm -rf build

.PHONY: test upload upload-content clean
