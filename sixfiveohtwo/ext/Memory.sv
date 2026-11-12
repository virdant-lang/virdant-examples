// sixfiveohtwo — Fomu memory.
//
// 64K x 8 synchronous-read RAM for the iCE40 UP5K. Shaped as two
// 16K x 16 arrays (split on addr[15]) so that yosys maps each to one
// SB_SPRAM256KA (256 Kbit = 32 KiB, 16-bit data port with nibble
// write masks); a byte-wide array would lane-pack into block RAMs
// instead, and the UP5K has only 30 of those.
//
// Address decomposition: addr[15] selects the half, addr[14:1] is the
// 16-bit word index, addr[0] is the byte lane.
//
// Read latency: one cycle. The CPU's wait-state protocol samples data
// on the second cycle of every bus transaction.

module Memory(
    input  wire        clock,
    input  wire [15:0] addr,
    input  wire [7:0]  wdata,
    input  wire        wren,
    output reg  [7:0]  rdata
);
    reg [15:0] mem_lo [0:16383];    // $0000-$7FFF
    reg [15:0] mem_hi [0:16383];    // $8000-$FFFF

    wire        sel  = addr[15];        // which 32K half
    wire [13:0] widx = addr[14:1];      // 16-bit word index
    wire        lane = addr[0];         // byte lane within the word

    always @(posedge clock) begin
        rdata <= lane
               ? (sel ? mem_hi[widx][15:8] : mem_lo[widx][15:8])
               : (sel ? mem_hi[widx][7:0]  : mem_lo[widx][7:0]);
        if (wren) begin
            if (sel) begin
                if (!lane) mem_hi[widx][7:0]  <= wdata;
                else       mem_hi[widx][15:8] <= wdata;
            end else begin
                if (!lane) mem_lo[widx][7:0]  <= wdata;
                else       mem_lo[widx][15:8] <= wdata;
            end
        end
    end

`ifdef SIM
    // Simulation preload: two hex files (one 16-bit word per line,
    // 16384 lines each), produced by tools/mkspram.py from a 64K
    // program image.
    initial begin
        reg [8*64:1] lofile;
        reg [8*64:1] hifile;
        if ($value$plusargs("memlo=%s", lofile)) $readmemh(lofile, mem_lo);
        if ($value$plusargs("memhi=%s", hifile)) $readmemh(hifile, mem_hi);
    end
`endif
endmodule