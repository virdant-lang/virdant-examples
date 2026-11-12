`timescale 10ns/1ns

// Simulation-only behavioral model of a 4 MiB SPI flash chip (mode 0),
// for the Fomu boot testbench: the boot ROM is read from flash.
//
// Pins match the Fomu platform: cs (active-low), clk (the SPI clock
// line), mosi, miso. Mode 0 convention: the master samples on rising
// clk edges, so this model samples mosi on rising clk edges and drives
// miso on falling clk edges. Command, address, and data all move MSB
// first.
//
// Only command 0x03 (READ) is modeled. While cs is high the model
// idles; a falling cs edge selects the chip and starts a command byte,
// then a 24-bit address, then the bytes at that address stream out
// (incrementing) until cs rises again. Any other command is ignored
// (miso stays 0).
//
// Contents come from +flashhex=<image.hex> via $readmemh, defaulting
// to flash.hex.

module Flash(
    input  wire cs,
    input  wire clk,
    input  wire mosi,
    output reg  miso = 0
);

    reg [7:0] flash [0:4194303];

    localparam
        WAIT    = 3'd0,     // cs high: idle
        COMMAND = 3'd1,     // receiving the command byte
        ADDRESS = 3'd2,     // receiving the 24-bit address
        READ    = 3'd3,     // streaming data out
        IGNORE  = 3'd4;     // unmodeled command

    reg [2:0]  state = WAIT;
    reg [4:0]  bitcount = 0;    // bits shifted in so far
    reg [7:0]  cmd = 0;
    reg [23:0] addr = 0;
    reg [2:0]  outbit = 0;      // next bit of the byte to present

    initial begin
        begin
            reg [8*64:1] fh;
            if (!$value$plusargs("flashhex=%s", fh)) begin
                fh = "flash.hex";
            end
            $readmemh(fh, flash);
        end
    end

    // Transaction framing: falling cs selects the chip, rising cs
    // releases it and resets the state machine.
    always @(negedge cs) begin
        state <= COMMAND;
        bitcount <= 0;
        miso <= 0;
    end

    always @(posedge cs) begin
        state <= WAIT;
        miso <= 0;
    end

    // Input side: sample mosi on rising clk edges.
    always @(posedge clk) begin
        if (state == COMMAND) begin
            cmd <= {cmd[6:0], mosi};
            if (bitcount == 3'd7) begin
                bitcount <= 0;
                if ({cmd[6:0], mosi} == 8'h03) begin
                    state <= ADDRESS;
                end else begin
                    state <= IGNORE;
                end
            end else begin
                bitcount <= bitcount + 1;
            end
        end else if (state == ADDRESS) begin
            addr <= {addr[22:0], mosi};
            if (bitcount == 5'd23) begin
                bitcount <= 0;
                state <= READ;
                outbit <= 0;
            end else begin
                bitcount <= bitcount + 1;
            end
        end
    end

    // Output side: present data on falling clk edges. addr wraps at the
    // 4 MiB boundary (only addr[21:0] indexes the array).
    always @(negedge clk) begin
        if (state == READ) begin
            miso <= flash[addr[21:0]][3'd7 - outbit];
            if (outbit == 3'd7) begin
                outbit <= 0;
                addr <= addr + 1;
            end else begin
                outbit <= outbit + 1;
            end
        end
    end

endmodule