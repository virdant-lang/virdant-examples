`timescale 10ns/1ns

// Differential test for the native SPRAM model (models::SB_SPRAM256KA)
// against the ext/Spram.sv Verilog reference it replaces: identical
// pseudorandom contents and random stimulus (with occasional
// chip-select deasserts, which must hold DATAOUT), and DATAOUT must
// agree after every cycle.

module Tb;
    reg CLOCK = 0;
    always #5 CLOCK = ~CLOCK;

    reg         CHIPSELECT = 1;
    reg         WREN = 0;
    reg  [13:0] ADDRESS = 0;
    reg  [15:0] DATAIN = 0;
    reg  [3:0]  MASKWREN = 0;
    wire [15:0] DATAOUT_ref;
    wire [15:0] DATAOUT_native;

    SB_SPRAM256KA spram_ref(
        .CLOCK(CLOCK),
        .ADDRESS(ADDRESS),
        .DATAIN(DATAIN),
        .MASKWREN(MASKWREN),
        .WREN(WREN),
        .CHIPSELECT(CHIPSELECT),
        .STANDBY(1'b0),
        .SLEEP(1'b0),
        .POWEROFF(1'b0),
        .DATAOUT(DATAOUT_ref)
    );

    \models::SB_SPRAM256KA native(
        .CLOCK(CLOCK),
        .ADDRESS(ADDRESS),
        .DATAIN(DATAIN),
        .MASKWREN(MASKWREN),
        .WREN(WREN),
        .CHIPSELECT(CHIPSELECT),
        .STANDBY(1'b0),
        .SLEEP(1'b0),
        .POWEROFF(1'b0),
        .DATAOUT(DATAOUT_native)
    );

    integer i, errors;
    reg [15:0] r;

    initial begin
        errors = 0;

        // Identical contents: both models must agree even on words
        // the stimulus never writes.
        for (i = 0; i < 16384; i = i + 1) begin
            r = $random;
            spram_ref.mem[i] = r;
            native.mem[i] = r;
        end

        // 20000 cycles of random stimulus.
        for (i = 0; i < 20000; i = i + 1) begin
            @(negedge CLOCK);
            if (DATAOUT_ref !== DATAOUT_native) begin
                $display("FAIL cycle %0d: r=%h native=%h",
                         i, DATAOUT_ref, DATAOUT_native);
                errors = errors + 1;
            end
            CHIPSELECT = ($random % 8 != 0);
            WREN       = ($random % 3 != 0);
            ADDRESS    = $random;
            DATAIN     = $random;
            MASKWREN   = $random;
        end
        @(negedge CLOCK);
        if (DATAOUT_ref !== DATAOUT_native) begin
            $display("FAIL final: r=%h native=%h", DATAOUT_ref, DATAOUT_native);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("SPRAM DIFFERENTIAL PASS");
        end else begin
            $display("FAIL");
            $fatal;
        end
        $finish;
    end
endmodule
