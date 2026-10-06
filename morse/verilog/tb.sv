`timescale 1ns/1ps

// MorseTb -- testbench for the iCEstick Morse decoder.
//
// Drives bytes into \top::Top over the UART at the design's native
// rate (104 clock cycles per bit at 12 MHz).  A background recorder
// captures every frame the design sends back, and each vector
// compares the recorded replies once they have drained.
//
// Tests:
//   1. Full round trip: SOS, HI, CQ
//   2. An element pattern that is no Morse character decodes to '?'
//   3. A sixth element flushes '?' and restarts the letter
//   4. Digits at the five-element boundary
//   5. Unknown bytes are ignored mid-letter
//   6. Repeated breaks are ignored
//   7. LEDs mirror the elements typed so far

module MorseTb;

    localparam integer CYCLES_PER_BIT = 104;

    reg  clock   = 1;
    reg  uart_rx = 1;

    wire uart_tx;
    wire led1, led2, led3, led4, led5;

    integer errors = 0;

    \top::Top dut (
        .clock   (clock),
        .uart_rx (uart_rx),
        .uart_tx (uart_tx),
        .led1    (led1),
        .led2    (led2),
        .led3    (led3),
        .led4    (led4),
        .led5    (led5)
    );

    always #41.667 clock = ~clock;    // ~12 MHz

    // Watchdog: the whole run fits in ~15 ms of simulated time.
    initial begin
        #50_000_000;
        $display("FAIL: watchdog timeout");
        $fatal(1);
    end

    // ---------- transmit helpers ----------

    task automatic send_bit(input b);
        begin
            uart_rx = b;
            repeat (CYCLES_PER_BIT) @(posedge clock);
        end
    endtask

    task automatic send_byte(input [7:0] b);
        integer i;
        begin
            send_bit(0);                            // start bit
            for (i = 0; i < 8; i = i + 1)
                send_bit(b[i]);                     // data, LSB first
            send_bit(1);                            // stop bit
        end
    endtask

    // Number of characters in a packed string (no interior NULs).
    function integer text_len(input [1023:0] s);
        integer i;
        begin
            text_len = 0;
            for (i = 0; i < 127; i = i + 1)
                if (s[8*i +: 8] != 0) text_len = i + 1;
        end
    endfunction

    task automatic send_text(input [1023:0] s);
        integer i;
        integer n;
        begin
            // Strings are right-justified: character 0 is the
            // highest nonzero byte, so send from the top down.
            n = text_len(s);
            for (i = n - 1; i >= 0; i = i - 1)
                send_byte(s[8*i +: 8]);
        end
    endtask

    // ---------- reply recorder ----------

    reg [7:0] reply [0:63];
    integer reply_count = 0;

    // Forever process: capture every frame on uart_tx.
    initial begin
        integer i;
        forever begin
            @(negedge uart_tx);
            // Wait to the middle of the first data bit.
            repeat (CYCLES_PER_BIT + CYCLES_PER_BIT/2) @(posedge clock);
            for (i = 0; i < 8; i = i + 1) begin
                reply[reply_count][i] = uart_tx;
                repeat (CYCLES_PER_BIT) @(posedge clock);
            end
            reply_count = reply_count + 1;
        end
    end

    // ---------- checks ----------

    // Types `morse`, waits for the replies to drain, then compares
    // them against `expected`.
    task automatic test_vector(input [1023:0] morse, input [255:0] expected);
        integer i;
        integer n;
        integer base;
        begin
            $display("-- typing \"%0s\"", morse);
            base = reply_count;
            send_text(morse);
            // The last reply frame needs ~11 bit periods to drain.
            repeat (3 * CYCLES_PER_BIT * 11) @(posedge clock);
            n = text_len(expected);
            if (reply_count - base != n) begin
                $display("FAIL %0s: expected %0d char(s), got %0d",
                         expected, n, reply_count - base);
                errors = errors + 1;
            end else begin
                for (i = 0; i < n; i = i + 1) begin
                    if (reply[base + i] === expected[8*(n-1-i) +: 8])
                        $display("PASS %0s: got %c", expected, reply[base + i]);
                    else begin
                        $display("FAIL %0s: wanted %c, got %c (0x%02x)",
                                 expected, expected[8*(n-1-i) +: 8],
                                 reply[base + i], reply[base + i]);
                        errors = errors + 1;
                    end
                end
            end
        end
    endtask

    task automatic check_leds(input [4:0] want, input [255:0] label);
        begin
            repeat (2) @(posedge clock);
            if ({led5, led4, led3, led2, led1} === want)
                $display("PASS %0s: LEDs are %b", label, want);
            else begin
                $display("FAIL %0s: wanted LEDs %b, got %b",
                         label, want, {led5, led4, led3, led2, led1});
                errors = errors + 1;
            end
        end
    endtask

    // ---------- stimulus ----------

    initial begin
        // Hold through the power-on reset (2^16 clock cycles).
        repeat (65540) @(posedge clock);

        test_vector("... --- ... ", "SOS");
        test_vector(".... .. ",     "HI");
        test_vector("-.-. --.- ",  "CQ");
        test_vector("..-- ",        "?");    // no such Morse character
        test_vector("...... ",      "?");    // sixth element overflows
        test_vector("----- ",       "0");    // five-element digits
        test_vector(".---- ",       "1");
        test_vector("x...x ",        "S");    // unknown bytes ignored
        test_vector("....  ",       "H");    // extra break ignored

        // The LEDs mirror the elements typed so far: dot = off,
        // dash = lit, first element on LED1.
        $display("-- LED check while typing \"..-\"");
        send_text("..-");
        check_leds(5'b00100, "LEDs ..-");    // the dash shows on LED3
        test_vector(" ", "U");              // finish the letter
        check_leds(5'b00000, "LEDs after decode");

        if (errors == 0) begin
            $display("ALL TESTS PASSED");
            $finish;
        end else
            $fatal(1, "%0d TEST(S) FAILED", errors);
    end

endmodule
