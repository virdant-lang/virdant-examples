// External synchronous memory for the wb project.
//
// This module implements `\wishbone_memory::Memory`, the `ext mod Memory`
// declared in src/wishbone_memory.vir.  It is a simple synchronous
// read/write memory:
//
//   - Writes are committed on posedge clock when `we` is high,
//     storing `wr_data` at the word addressed by `addr`.
//   - Reads are synchronous: `rd_data` is registered on posedge clock,
//     presenting `mem[addr]` one cycle after the address is driven.
//
// The memory is indexed by the low 16 bits of the address (word-aligned,
// 64K words of 32 bits).
module \wishbone_memory::Memory (
    input  wire         clock,
    input  wire         we,
    input  wire [31:0]  addr,
    input  wire [31:0]  wr_data,
    output reg  [31:0]  rd_data
);
    reg [31:0] mem [0:65535];

    // Present 0 until the first posedge so the bus never starts at X.
    initial rd_data = 32'b0;

    always @(posedge clock) begin
        if (we) begin
            mem[addr[15:0]] <= wr_data;
        end
        rd_data <= mem[addr[15:0]];
    end
endmodule
