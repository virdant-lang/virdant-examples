`timescale 10ns/1ns

// Differential test for the native 64K memory (models::Memory) against
// the design's actual memory implementation: two ext/Spram.sv
// hard-cell models wired exactly as fomu_memory::Memory wires them
// (addr[15] half select, addr[14:1] word index, addr[0] byte lane,
// nibble write masks). Identical pseudorandom contents and random
// stimulus; rdata must agree after every cycle.

module Tb;
    reg clock = 0;
    always #5 clock = ~clock;

    reg  [15:0] addr = 0;
    reg  [7:0]  wdata = 0;
    reg         wren = 0;
    wire [7:0]  rdata_native;

    \models::Memory native(
        .clock(clock),
        .addr(addr),
        .wdata(wdata),
        .wren(wren),
        .rdata(rdata_native)
    );

    // -- the reference: fomu_memory::Memory's hard-cell wiring --
    wire        sel  = addr[15];
    wire [13:0] widx = addr[14:1];
    wire        lane = addr[0];
    wire [3:0]  mask = lane ? 4'b1100 : 4'b0011;
    wire [15:0] din  = {wdata, wdata};
    wire [15:0] lo_out, hi_out;

    SB_SPRAM256KA lo(
        .CLOCK(clock), .ADDRESS(widx), .DATAIN(din), .MASKWREN(mask),
        .WREN(wren && !sel), .CHIPSELECT(1'b1),
        .STANDBY(1'b0), .SLEEP(1'b0), .POWEROFF(1'b0), .DATAOUT(lo_out)
    );
    SB_SPRAM256KA hi(
        .CLOCK(clock), .ADDRESS(widx), .DATAIN(din), .MASKWREN(mask),
        .WREN(wren && sel), .CHIPSELECT(1'b1),
        .STANDBY(1'b0), .SLEEP(1'b0), .POWEROFF(1'b0), .DATAOUT(hi_out)
    );

    wire [7:0] rdata_ref = lane ? (sel ? hi_out[15:8] : lo_out[15:8])
                                : (sel ? hi_out[7:0]  : lo_out[7:0]);

    integer i, errors;
    reg [15:0] r;

    initial begin
        errors = 0;

        // Identical contents on both sides: the native array is read
        // back byte-for-byte out of the reference pair (byte address
        // i: word i[14:1] of the selected half, lane i[0]).
        for (i = 0; i < 16384; i = i + 1) begin
            lo.mem[i] = $random;
            hi.mem[i] = $random;
        end
        for (i = 0; i < 65536; i = i + 1)
            native.mem[i] = (i[0] ? (i[15] ? hi.mem[i[14:1]][15:8]
                                          : lo.mem[i[14:1]][15:8])
                                  : (i[15] ? hi.mem[i[14:1]][7:0]
                                           : lo.mem[i[14:1]][7:0]));

        // 20000 cycles of random stimulus (writes and reads).
        for (i = 0; i < 20000; i = i + 1) begin
            @(negedge clock);
            if (rdata_ref !== rdata_native) begin
                $display("FAIL cycle %0d: addr=%h ref=%h native=%h",
                         i, addr, rdata_ref, rdata_native);
                errors = errors + 1;
            end
            addr  = $random;
            wdata = $random;
            wren  = ($random % 3 != 0);
        end
        @(negedge clock);
        if (rdata_ref !== rdata_native) begin
            $display("FAIL final: addr=%h ref=%h native=%h",
                     addr, rdata_ref, rdata_native);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("MEMORY DIFFERENTIAL PASS");
        end else begin
            $display("FAIL");
            $fatal;
        end
        $finish;
    end
endmodule
