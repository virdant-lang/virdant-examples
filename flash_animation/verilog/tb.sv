`timescale 1ns/1ps

// FlashAnimTb -- testbench for the flash-driven LED animation.
//
// A behavioral model of the iCEstick's SPI flash, preloaded with
// the selected animation (build/anim.hex, staged by the Makefile),
// answers the design's READ commands.  The bench also loads
// build/anim.expect, the sequence of LED transitions that
// scripts/anim.py derives by simulating the bytecode the same way
// the player runs it.
//
// Tests:
//   1. The magic byte is found and the program plays: every
//      expected transition appears, in order.
//   2. Every `wait` and `pause` holds its pattern for the right
//      number of cycles (within fetch overhead).
//   3. The show loops: the last expected transition is the first
//      one of the period, repeated.

module FlashAnimTb;

    localparam integer RESET_CYCLES = 65536;   // reset_counter
    localparam integer GAP_SLACK    = 5000;    // cycles, fetch overhead
    localparam integer MAX_LOG      = 256;     // recorded transitions

    reg  clock   = 1;
    reg  uart_rx = 1;

    wire uart_tx;
    wire led1, led2, led3, led4, led5;
    wire flash_cs, flash_clk, flash_mosi;
    reg  flash_miso;

    // Bit 0 of the pattern is LED 1, matching the design's mapping.
    wire [4:0] leds = {led5, led4, led3, led2, led1};

    integer errors = 0;

    \top::Top dut (
        .clock      (clock),
        .uart_rx    (uart_rx),
        .uart_tx    (uart_tx),
        .led1       (led1),
        .led2       (led2),
        .led3       (led3),
        .led4       (led4),
        .led5       (led5),
        .flash_cs   (flash_cs),
        .flash_clk  (flash_clk),
        .flash_mosi (flash_mosi),
        .flash_miso (flash_miso)
    );

    always #41.667 clock = ~clock;    // ~12 MHz

    // ---------- behavioral SPI flash ----------

    // 4 MiB, the iCEstick's configuration flash.
    reg [7:0] flash_mem [0:32'h3FFFFF];

    initial begin
        $readmemh("anim.hex", flash_mem, 32'h040000);
    end

    integer   cmd_bits;
    reg [31:0] cmd_shift;
    reg [23:0] read_addr;
    reg [7:0]  data_shift;
    reg        reading;

    // A transaction begins when cs falls: forget the old command.
    always @(negedge flash_cs) begin
        cmd_bits = 0;
        reading  = 1'b0;
    end

    // Sample mosi on rising sck edges, MSB-first.  After the 32nd
    // bit, a READ (0x03) latches the address and presents the first
    // data byte.
    always @(posedge flash_clk) if (!flash_cs) begin
        if (!reading) begin
            cmd_shift = {cmd_shift[30:0], flash_mosi};
            cmd_bits  = cmd_bits + 1;
            if (cmd_bits == 32) begin
                if (cmd_shift[31:24] === 8'h03) begin
                    read_addr  = cmd_shift[23:0];
                    data_shift = flash_mem[read_addr];
                    read_addr  = read_addr + 1;
                    reading    = 1'b1;
                end
            end
        end
    end

    // Drive miso on falling sck edges while cs stays low: mode 0,
    // the device shifts the next bit out when the clock falls.
    always @(negedge flash_clk) if (!flash_cs && reading) begin
        flash_miso <= data_shift[7];
        data_shift <= {data_shift[6:0], 1'b0};
    end

    // ---------- LED recorder ----------

    reg [4:0] pattern_log [0:MAX_LOG-1];
    integer   gap_log     [0:MAX_LOG-1];   // cycles since the previous change
    integer   pattern_count = 0;
    integer   last_change   = 0;
    integer   cycle_count   = 0;

    always @(posedge clock) cycle_count = cycle_count + 1;

    // Record pattern changes once the reset has been released.
    always @(leds) if (cycle_count > RESET_CYCLES && pattern_count < MAX_LOG) begin
        pattern_log[pattern_count] = leds;
        gap_log[pattern_count]     = cycle_count - last_change;
        last_change                = cycle_count;
        $display("[%0t] cycle %0d: leds -> %b (gap %0d)",
                 $time, cycle_count, leds, gap_log[pattern_count]);
        pattern_count              = pattern_count + 1;
    end

    // ---------- expected behavior, from the assembler ----------

    // anim.expect, written by scripts/anim.py alongside anim.hex:
    //   word 0        number of expected LED transitions
    //   words 1..2N   (pattern, gap) pairs -- the pattern shown and
    //                 the cycles from the previous transition to it
    reg [31:0] expect_mem [0:2*MAX_LOG];
    integer    expect_count;
    reg [63:0] expect_total;   // sum of gaps, for the watchdog
    reg        expect_loaded = 0;

    integer k;

    initial begin
        $readmemh("anim.expect", expect_mem);
        expect_count = expect_mem[0];
        expect_total = 0;
        for (k = 0; k < expect_count; k = k + 1)
            expect_total = expect_total + expect_mem[2 + 2*k];
        expect_loaded = 1;
    end

    // Watchdog: the whole show, plus slack, in cycles converted to
    // nanoseconds at 84 ns per cycle (12 MHz, rounded up).
    real watchdog_ns;
    initial begin
        wait (expect_loaded);
        watchdog_ns = (expect_total + RESET_CYCLES + 10_000_000) * 84.0;
        #(watchdog_ns);
        $display("FAIL: watchdog timeout (only %0d of %0d LED transitions seen)",
                 pattern_count, expect_count);
        $fatal(1);
    end

    // ---------- checks ----------

    integer want_gap;
    integer i;

    initial begin
        wait (expect_loaded);
        wait (pattern_count >= expect_count);

        // 1. and 3.: the sequence of patterns, ending with the
        // period's first transition again to prove the loop.
        for (i = 0; i < expect_count; i = i + 1) begin
            if (pattern_log[i] !== expect_mem[1 + 2*i][4:0]) begin
                $display("FAIL: transition %0d is %b, want %b",
                         i, pattern_log[i], expect_mem[1 + 2*i][4:0]);
                errors = errors + 1;
            end
        end

        // 2.: the gap before each transition matches its wait and
        // pause (the first gap starts at simulation time zero and
        // is not checked).
        for (i = 1; i < expect_count; i = i + 1) begin
            want_gap = expect_mem[2 + 2*i];
            if (gap_log[i] < want_gap - GAP_SLACK || gap_log[i] > want_gap + GAP_SLACK) begin
                $display("FAIL: gap %0d is %0d cycles, want %0d +/- %0d",
                         i, gap_log[i], want_gap, GAP_SLACK);
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("PASS: flash animation played %0d transitions with correct timing, then looped",
                    expect_count);
        else
            $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule
