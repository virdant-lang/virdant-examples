// Simulation-only behavioral model of the iCE40 UltraPlus
// SB_SPRAM256KA hard cell (256 Kbit single-port RAM, 16K x 16).
//
// Semantics modeled: on each rising CLOCK edge with CHIPSELECT high,
// WREN writes the nibbles selected by MASKWREN (bit0 -> DATAIN[3:0],
// bit1 -> [7:4], bit2 -> [11:8], bit3 -> [15:12]) and DATAOUT is
// updated with the word at ADDRESS as it was BEFORE the write
// (read-old-data). STANDBY/SLEEP/POWEROFF are ignored.
//
// Synthesis never sees this file: yosys maps the SB_SPRAM256KA
// instantiations through its own spram_map techmap.

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
    output reg  [15:0] DATAOUT
);
    reg [15:0] mem [0:16383];

    always @(posedge CLOCK) begin
        if (CHIPSELECT) begin
            if (WREN) begin
                if (MASKWREN[0]) mem[ADDRESS][3:0]  <= DATAIN[3:0];
                if (MASKWREN[1]) mem[ADDRESS][7:4]  <= DATAIN[7:4];
                if (MASKWREN[2]) mem[ADDRESS][11:8] <= DATAIN[11:8];
                if (MASKWREN[3]) mem[ADDRESS][15:12] <= DATAIN[15:12];
            end
            DATAOUT <= mem[ADDRESS];
        end
    end
endmodule
