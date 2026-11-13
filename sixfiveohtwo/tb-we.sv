`timescale 10ns/1ns

// Debug harness for FomuTop bus protocol inspection: drive a single
// store through the real memory write path and check whether the
// write lands in the right half.

module Tb;
    reg clock = 0;
    always #4 clock = ~clock;

    reg  [15:0] mem_addr = 0;
    reg  [7:0]  mem_wdata = 0;
    reg         mem_wren = 0;
    wire [7:0]  mem_rdata;

    // The real memory write path (fomu_memory::Memory).
    \fomu_memory::Memory mem(
        .clock(clock),
        .addr(mem_addr),
        .wdata(mem_wdata),
        .wren(mem_wren),
        .rdata(mem_rdata)
    );

    always @(posedge clock) begin
        if (mem_wren) begin
            $display("WRITE addr=%h data=%h", mem_addr, mem_wdata);
        end
    end

    initial begin
        // $F000 maps to hi word 0x3800 low byte (little-endian);
        // $F001 maps to the high byte of the same word.
        mem_addr = 16'hF000;
        mem_wdata = 8'hAA;
        mem_wren = 1;
        @(posedge clock);
        @(posedge clock);
        mem_addr = 16'hF001;
        mem_wdata = 8'hBB;
        @(posedge clock);
        @(posedge clock);
        mem_wren = 0;
        @(posedge clock);
        $display("hi word 0x3800 = %h (expect bbaa)", mem.hi.native.mem[16'h3800]);
        $finish;
    end
endmodule
