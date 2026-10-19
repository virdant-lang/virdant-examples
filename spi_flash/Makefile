TOP_SRCS := src/top.vir
TB_SRCS  := tb/spi_flash_tb.sv

VVP := build/spi_flash_tb.vvp

IVERILOG := iverilog
VVP_BIN  := vvp

.PHONY: all test clean

all: test

test:
	vir build
	$(IVERILOG) -g2012 -o $(VVP) build/top.sv build/builtin.sv $(TB_SRCS)
	$(VVP_BIN) $(VVP)

clean:
	rm -f $(VVP) build/spi_flash_tb.vcd
