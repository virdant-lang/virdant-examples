`timescale 10ns/1ns

// Plain-named wrapper binding the native Virdant SPRAM model
// (models/src/models.vir, emitted as \models::SB_SPRAM256KA) to the
// SB_SPRAM256KA cell instances that fomu_memory.vir's ext mod emits:
// iverilog resolves the plain cell name through this file. Yosys
// never sees it — synthesis takes the cell from its own library.

module SB_SPRAM256KA(
    input  wire        CLOCK,
    input  wire [13:0] ADDRESS,
    input  wire [15:0] DATAIN,
    input  wire [3:0]  MASKWREN,
    input  wire        WREN,
    input  wire        CHIPSELECT,
    input  wire        STANDBY,
    input  wire        SLEEP,
    input  wire        POWEROFF,
    output wire [15:0] DATAOUT
);
    \models::SB_SPRAM256KA native(
        .CLOCK(CLOCK),
        .ADDRESS(ADDRESS),
        .DATAIN(DATAIN),
        .MASKWREN(MASKWREN),
        .WREN(WREN),
        .CHIPSELECT(CHIPSELECT),
        .STANDBY(STANDBY),
        .SLEEP(SLEEP),
        .POWEROFF(POWEROFF),
        .DATAOUT(DATAOUT)
    );
endmodule
