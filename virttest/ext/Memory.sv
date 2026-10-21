// Behavioral message memory for the virttest demo.
//
// Preloaded with "HELLO, WORLD!\n\r\0" (16 bytes).  Combinational read:
// `data` always reflects `mem[addr]`.
//
// The module name must match the ext mod's qualified Virdant name
// (`top::Memory`, since it is declared in src/top.vir).

module \top::Memory (
    input  wire [3:0] addr,
    output wire [7:0] data
);
    reg [7:0] mem [16];

    initial begin
        mem[0]  = 8'h48; // 'H'
        mem[1]  = 8'h45; // 'E'
        mem[2]  = 8'h4C; // 'L'
        mem[3]  = 8'h4C; // 'L'
        mem[4]  = 8'h4F; // 'O'
        mem[5]  = 8'h2C; // ','
        mem[6]  = 8'h20; // ' '
        mem[7]  = 8'h57; // 'W'
        mem[8]  = 8'h4F; // 'O'
        mem[9]  = 8'h52; // 'R'
        mem[10] = 8'h4C; // 'L'
        mem[11] = 8'h44; // 'D'
        mem[12] = 8'h21; // '!'
        mem[13] = 8'h0A; // '\n'
        mem[14] = 8'h0D; // '\r'
        mem[15] = 8'h00; // '\0' terminator (never transmitted)
    end

    assign data = mem[addr];
endmodule