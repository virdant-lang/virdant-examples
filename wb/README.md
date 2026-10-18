# wb — Wishbone memory example
A small [Virdant](https://virdant.org) design: a Wishbone-classic slave
(`WishboneMemory`) wrapping an external synchronous memory, exposed through a
`Top` module, verified with an Icarus Verilog simulation.

## Run

```sh
make          # compile .vir -> Verilog, build sim, run testbench
make build    # only generate Verilog into build/
make clean    # remove build artifacts
```
