# wb — NS8520 UART example

A small [Virdant](https://virdant.org) design: an NS8520-style UART
controller (`Ns8520`) with a Wishbone-classic slave interface, exposed
through a `Top` module and verified with an Icarus Verilog simulation.

The UART runs at a fixed 115200 baud from a 48 MHz clock and has 8-deep
TX and RX FIFOs. Register map (word-aligned Wishbone access):

- `0x0` — RBR/THR: read = received byte, write = byte to transmit
- `0x4` — LSR: DR (bit 0), OE (bit 1), THRE (bit 5), TEMT (bit 6)

`Top` also exposes a `uart_clock` debug output: a Bit that toggles once
per bit time, for aligning frames in a waveform viewer.

## Run

```sh
make          # compile .vir -> Verilog, build sim, run testbench
make build    # only generate Verilog into build/
make clean    # remove build artifacts
```

The testbench verifies the transmit path (LSR behavior and decoded
bytes on `tx`, via a testbench-side serial monitor). The receive path
is implemented and can be exercised by enabling the serial-loopback
checks in `tb/tb.sv` (`assign rx = reset ? 1'b1 : tx;` plus the
commented RX checks: single byte round-trip, FIFO ordering, and
RX overrun).

`read.py` decodes the `tx` signal from `build/tb.vcd` into characters
on stdout:

```sh
python3 read.py build/tb.vcd
```

An earlier example in this project, `WishboneMemory` (`src/wishbone_memory.vir`),
is still present but no longer instantiated by `Top`.
