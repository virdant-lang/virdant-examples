TOP_SRCS := src/top.vir
TB_SRCS  := tb/uart_sender_tb.sv

VVP := build/uart_sender_tb.vvp

IVERILOG := iverilog
VVP_BIN  := vvp

.PHONY: all test clean

all: test

test:
	vir build
	$(IVERILOG) -g2012 -o $(VVP) build/top.sv build/builtin.sv $(TB_SRCS)
	$(VVP_BIN) $(VVP)

clean:
	rm -f $(VVP) build/uart_sender_tb.vcd
