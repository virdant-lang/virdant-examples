`timescale 10ns/1ns

// Debug: drive a single store through the memory and check whether
// it lands.

module Tb;
    reg clock = 0;
    always #4 clock = ~clock;

    reg  [15:0] addr = 0;
    reg  [7:0]  wdata = 0;
    reg         wren = 0;
    wire [7:0]  rdata;

    \fomu_memory::Memory mem(
        .clock(clock),
        .addr(addr),
        .wdata(wdata),
        .wren(wren),
        .rdata(rdata)
    );

    always @(posedge clock) begin
        if (wren) begin
            $display("WRITE addr=%h data=%h", addr, wdata);
        end else begin
            $display("READ  addr=%h rdata=%h", addr, rdata);
        end
    end

    initial begin
        // $F000 and $F001 both map to hi word 0x7800; $F000 is the
        // low byte, $F001 the high byte.
        addr = 16'hF000;
        wdata = 8'hA5;
        wren = 1;
        @(posedge clock);
        @(posedge clock);
        addr = 16'hF001;
        wdata = 8'h5A;
        @(posedge clock);
        @(posedge clock);
        wren = 0;
        @(posedge clock);
        @(posedge clock);
        @(posedge clock);
        $finish;
    end
endmodule
