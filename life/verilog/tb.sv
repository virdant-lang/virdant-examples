`timescale 1ns/1ps

// LifeTb -- testbenches for the Game of Life design.
//
// Bench 1 (exhaustive `LifeCell`): drives all 512 combinations of
// center + 8 neighbors against \life::LifeCell directly and checks
// the next state against a golden B3/S23 table.  The rule is
// proven, not sampled.
//
// Bench 2 (end-to-end `Top`): drives real UART frames into
// \top::Top at 104 cycles/bit (115200 baud at 12 MHz), captures
// every TX byte, and parses the rendered grid back out of the VT100
// frames.  An independent B3/S23-on-a-torus stepper (`step_grid`,
// below) predicts the next generation from a parsed frame; the test
// passes when that prediction matches what the real hardware draws
// after a single-step.  Two independent implementations of the rule
// agreeing is the point -- this sidesteps needing to replicate the
// 64-bit LFSR's free-running cycle count bit-for-bit in two
// languages at once (see `scripts/life.py`, which mirrors the LFSR
// and the renderer for offline/documentation use instead).
//
// Both benches share one clock and run sequentially in one process,
// so there is a single `$finish` for the whole file.

module LifeTb;

    // ================= shared clock =================
    reg clock = 0;
    always #41.667 clock = ~clock;    // ~12 MHz

    integer errors = 0;

    // Watchdog: generous for both benches together.
    initial begin
        #600_000_000;
        $display("FAIL: watchdog timeout");
        $fatal(1);
    end

    // ================= Bench 1: exhaustive LifeCell =================

    reg  cell_reset = 1;
    reg  center;
    reg  nw, n, ne, w, e, sw, s, se;
    reg  advance = 0;
    reg  load_seed = 0;
    reg  seed_bit = 0;
    wire cell_state;

    \life::LifeCell cell_dut (
        .clock      (clock),
        .reset      (cell_reset),
        .north      (n),
        .south      (s),
        .west       (w),
        .east       (e),
        .northwest  (nw),
        .northeast  (ne),
        .southwest  (sw),
        .southeast  (se),
        .advance    (advance),
        .load_seed  (load_seed),
        .seed_bit   (seed_bit),
        .state      (cell_state)
    );

    task automatic run_lifecell_bench;
        integer vector;
        integer neighbors;
        integer expected;
        begin
            $display("== Bench 1: exhaustive LifeCell (512 vectors) ==");
            @(posedge clock);
            @(posedge clock);
            cell_reset = 0;

            for (vector = 0; vector < 512; vector = vector + 1) begin
                center = vector[8];
                nw = vector[7];
                n  = vector[6];
                ne = vector[5];
                w  = vector[4];
                e  = vector[3];
                sw = vector[2];
                s  = vector[1];
                se = vector[0];

                seed_bit = center;
                load_seed = 1;
                advance = 0;
                @(posedge clock);
                #1;
                load_seed = 0;

                advance = 1;
                @(posedge clock);
                #1;
                advance = 0;

                neighbors = nw + n + ne + w + e + sw + s + se;
                if (center)
                    expected = (neighbors == 2) || (neighbors == 3);
                else
                    expected = (neighbors == 3);

                if (cell_state !== expected) begin
                    $display("FAIL vector %0d: center=%0d neighbors=%0d expected=%0d got=%0d",
                              vector, center, neighbors, expected, cell_state);
                    errors = errors + 1;
                end

                cell_reset = 1;
                @(posedge clock);
                #1;
                cell_reset = 0;
            end

            if (errors == 0)
                $display("Bench 1: ALL 512 VECTORS PASSED");
            else
                $display("Bench 1: %0d / 512 VECTOR(S) FAILED", errors);
        end
    endtask

    // ================= Bench 2: end-to-end Top =================

    localparam integer CYCLES_PER_BIT = 104;

    reg  uart_rx = 1;
    wire uart_tx;
    wire led1, led2, led3, led4, led5;

    \top::Top top_dut (
        .clock   (clock),
        .uart_rx (uart_rx),
        .uart_tx (uart_tx),
        .led1    (led1),
        .led2    (led2),
        .led3    (led3),
        .led4    (led4),
        .led5    (led5)
    );

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
            send_bit(0);                     // start bit
            for (i = 0; i < 8; i = i + 1)
                send_bit(b[i]);              // data, LSB first
            send_bit(1);                     // stop bit
        end
    endtask

    // ---------- reply recorder ----------

    reg [7:0] reply [0:4095];
    integer reply_count = 0;

    initial begin
        integer i;
        forever begin
            @(negedge uart_tx);
            repeat (CYCLES_PER_BIT + CYCLES_PER_BIT/2) @(posedge clock);
            for (i = 0; i < 8; i = i + 1) begin
                reply[reply_count][i] = uart_tx;
                repeat (CYCLES_PER_BIT) @(posedge clock);
            end
            reply_count = reply_count + 1;
        end
    end

    task automatic wait_for_reply_count(input integer target);
        begin
            while (reply_count < target) @(posedge clock);
        end
    endtask

    // ---------- grid model: B3/S23 on an 8x8 torus ----------

    function automatic cell_at(input [0:63] grid, input integer x, input integer y);
        integer xi, yi;
        begin
            xi = (x + 8) % 8;
            yi = (y + 8) % 8;
            cell_at = grid[yi * 8 + xi];
        end
    endfunction

    function automatic [0:63] step_grid(input [0:63] grid);
        integer x, y, n;
        reg [0:63] next_grid;
        begin
            for (y = 0; y < 8; y = y + 1) begin
                for (x = 0; x < 8; x = x + 1) begin
                    n = cell_at(grid, x-1, y-1) + cell_at(grid, x, y-1) + cell_at(grid, x+1, y-1)
                      + cell_at(grid, x-1, y)                          + cell_at(grid, x+1, y)
                      + cell_at(grid, x-1, y+1) + cell_at(grid, x, y+1) + cell_at(grid, x+1, y+1);
                    next_grid[y*8+x] = (n == 3) || (grid[y*8+x] && n == 2);
                end
            end
            step_grid = next_grid;
        end
    endfunction

    // ---------- frame parsing ----------
    // `base` is the index in `reply[]` of the frame's first byte
    // (the first preamble byte for the boot frame, otherwise the
    // first row-prefix byte).  Returns the 64-bit grid (bit y*8+x =
    // cell (x, y)), straight off the rendered '#'/' ' pairs.

    function automatic [0:63] parse_grid(input integer base, input integer has_preamble);
        integer row_start;
        integer row, col;
        reg [0:63] grid;
        begin
            row_start = base + (has_preamble ? 10 : 0);
            for (row = 0; row < 8; row = row + 1) begin
                // Only even terminal rows are sampled; the odd one
                // underneath is an identical zoomed copy.
                integer term_row_offset;
                integer cell_base;
                term_row_offset = row_start + (row * 2) * 24;
                cell_base = term_row_offset + 8;
                for (col = 0; col < 8; col = col + 1) begin
                    grid[row*8+col] = (reply[cell_base + col*2] == 8'h23);  // '#'
                end
            end
            parse_grid = grid;
        end
    endfunction

    function automatic integer frame_length(input integer has_preamble);
        begin
            frame_length = (has_preamble ? 10 : 0) + 16*24 + 7 + 18;
        end
    endfunction

    // Status-line fields, relative to `base` as in `parse_grid`.
    function automatic [7:0] status_running_char(input integer base, input integer has_preamble);
        integer status_start;
        begin
            status_start = base + (has_preamble ? 10 : 0) + 16*24 + 7;
            status_running_char = reply[status_start + 0];
        end
    endfunction

    function automatic [31:0] status_generation(input integer base, input integer has_preamble);
        integer status_start;
        integer thousands, hundreds, tens, ones;
        begin
            status_start = base + (has_preamble ? 10 : 0) + 16*24 + 7;
            thousands = reply[status_start + 14] - 8'h30;
            hundreds  = reply[status_start + 15] - 8'h30;
            tens      = reply[status_start + 16] - 8'h30;
            ones      = reply[status_start + 17] - 8'h30;
            status_generation = thousands*1000 + hundreds*100 + tens*10 + ones;
        end
    endfunction

    function automatic [3:0] led_speed_level;
        begin
            led_speed_level = {led4, led3, led2, led1};
        end
    endfunction

    task automatic check(input cond, input [511:0] label);
        begin
            if (cond)
                $display("PASS %0s", label);
            else begin
                $display("FAIL %0s", label);
                errors = errors + 1;
            end
        end
    endtask

    task automatic run_top_bench;
        reg [0:63] boot_grid, frame2_grid, predicted_grid, frame3_grid, frame4_grid;
        integer base1, base2, base3, base4;
        integer i;
        begin
            $display("== Bench 2: end-to-end Top ==");

            // Skip the power-on reset quickly instead of waiting out
            // all 2^16 cycles: force the counter to its last-but-one
            // value so it reaches 0xFFFF (releasing reset) in one
            // more edge.
            @(posedge clock);
            top_dut.reset_counter = 16'hFFFE;
            @(posedge clock);
            #1;

            // ---- boot frame: paused, default speed, generation 0 ----
            base1 = reply_count;
            wait_for_reply_count(base1 + frame_length(1));
            check(reply[base1] == 8'h1b && reply[base1+1] == "[" && reply[base1+2] == "2" && reply[base1+3] == "J",
                  "boot frame starts with clear-screen");
            check(status_running_char(base1, 1) == "P", "boot: paused");
            check(status_generation(base1, 1) == 0, "boot: generation 0");
            check(led5 == 1'b0, "boot: led5 dark (paused)");
            boot_grid = parse_grid(base1, 1);

            // ---- space: single-step, compare against the model ----
            base2 = reply_count;
            send_byte(" ");
            wait_for_reply_count(base2 + frame_length(0));
            frame2_grid = parse_grid(base2, 0);
            predicted_grid = step_grid(boot_grid);
            check(frame2_grid == predicted_grid, "space: next generation matches independent B3/S23 model");
            check(status_generation(base2, 0) == 1, "space: generation 1");

            // ---- R: reseed, generation resets, grid changes ----
            base3 = reply_count;
            send_byte("R");
            wait_for_reply_count(base3 + frame_length(0));
            frame3_grid = parse_grid(base3, 0);
            check(status_generation(base3, 0) == 0, "R: generation resets to 0");
            check(frame3_grid != frame2_grid, "R: grid changes");

            // ---- S: run, LED lights ----
            send_byte("S");
            repeat (4) @(posedge clock);
            check(led5 == 1'b1, "S: led5 lit (running)");

            // ---- S again: pause, LED dark ----
            send_byte("S");
            repeat (4) @(posedge clock);
            check(led5 == 1'b0, "S: led5 dark again (paused)");

            // ---- '0': default speed level 8 (0b1000: led4 only) ----
            send_byte("0");
            repeat (4) @(posedge clock);
            check(led_speed_level() == 4'b1000, "0: speed level 8 (led4 only)");

            // ---- '+' seven times: saturate at level 15 (all lit) ----
            for (i = 0; i < 7; i = i + 1)
                send_byte("+");
            repeat (4) @(posedge clock);
            check(led_speed_level() == 4'b1111, "+: speed level saturates at 15");

            // One more '+' past the ceiling must not wrap.
            send_byte("+");
            repeat (4) @(posedge clock);
            check(led_speed_level() == 4'b1111, "+: stays at 15 (no wraparound)");

            // ---- '-' sixteen times: saturate at level 0 (all dark) ----
            for (i = 0; i < 16; i = i + 1)
                send_byte("-");
            repeat (4) @(posedge clock);
            check(led_speed_level() == 4'b0000, "-: speed level saturates at 0 (no underflow)");

            // ---- run at max speed and watch an un-keyed tick advance ----
            // the grid on its own.
            base4 = reply_count;
            for (i = 0; i < 15; i = i + 1)
                send_byte("+");                 // level 15: ticks every ~4 ms
            send_byte("S");                      // run
            wait_for_reply_count(base4 + frame_length(0));
            frame4_grid = parse_grid(base4, 0);
            predicted_grid = step_grid(frame3_grid);
            check(frame4_grid == predicted_grid,
                  "auto-run: an un-keyed tick advances exactly one generation");
            check(led5 == 1'b1, "auto-run: led5 lit while running");

            if (errors == 0)
                $display("Bench 2: ALL CHECKS PASSED");
            else
                $display("Bench 2: SOME CHECKS FAILED");
        end
    endtask

    // ================= run both benches =================

    initial begin
        run_lifecell_bench();
        run_top_bench();

        if (errors == 0) begin
            $display("ALL TESTS PASSED");
            $finish;
        end else
            $fatal(1, "%0d TEST(S) FAILED", errors);
    end

endmodule
