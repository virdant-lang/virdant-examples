`timescale 10ns/1ns

// Hardware-wrapper testbench for the Fomu build of the sixfiveohtwo
// 6502: the real FomuTop (boot ROM, SPRAM-backed memory, I/O
// registers) against the native flash model (models::Flash, built
// from models/src/models.vir).
//
// The flash image (models/build/flash_image.hex, which the model
// loads via @image_hex) carries the hw1 demo program at $80000; the
// boot ROM copies it into SPRAM, releases the CPU, and the program
// runs: it cycles the RGB LED through colors 0-7 (off, red, green,
// yellow, blue, magenta, cyan, white) with a ~440 ms delay between
// steps, checkpointing the current color to $F001.
//
// Run with: make fomu-sim PROG=hw1

module Tb;
    reg clock = 0;

    wire led_red;
    wire led_green;
    wire led_blue;
    reg  touch1 = 1;
    reg  touch2 = 1;
    wire usb_dp;
    wire usb_dn;
    wire usb_dp_pu;
    wire flash_cs;
    wire flash_clk;
    wire flash_mosi;
    wire flash_miso;

    \fomu_top::FomuTop dut(
        .clock(clock),
        .led_red(led_red),
        .led_green(led_green),
        .led_blue(led_blue),
        .touch1(touch1),
        .touch2(touch2),
        .touch3(1),
        .touch4(1),
        .usb_dp(usb_dp),
        .usb_dn(usb_dn),
        .usb_dp_pu(usb_dp_pu),
        .flash_cs(flash_cs),
        .flash_clk(flash_clk),
        .flash_mosi(flash_mosi),
        .flash_miso(flash_miso)
    );

    \models::Flash flash_model(
        .cs(flash_cs),
        .clk(flash_clk),
        .mosi(flash_mosi),
        .miso(flash_miso)
    );

    always begin
        #1 clock = ~clock;
    end

    reg [15:0] prev_addr = 16'hFFFF;
    always @(*) begin
        if (dut.bridge.\busif.addr  != prev_addr) begin
            if (dut.bridge.\busif.addr  == 16'hFF00 || dut.bridge.\busif.addr  == 16'hF001) begin
                $display("DBG addr=%h->%h data=%h wren=%b io_sel=%b leds=%h tick=%b bus_write=%b",
                         prev_addr, dut.bridge.\busif.addr , dut.bridge.\busif.data , dut.bridge.wren,
                         dut.bridge.io_select, dut.io.leds, dut.cpu.tick, dut.bridge.\busif.write [1]);
            end
            prev_addr <= dut.bridge.\busif.addr ;
        end
    end

    integer errors;
    integer i;

    task chk(input cond, input [8*56:1] name);
    begin
        if (cond !== 1'b1) begin
            $display("FAIL: %s", name);
            errors = errors + 1;
        end
    end
    endtask

    function [7:0] mem_peek(input [15:0] addr);
        reg [15:0] word;
        begin
            // The plain SB_SPRAM256KA cell instances resolve through
            // models/shim, which instantiates the native model as
            // `native` — one hierarchy level below each cell.
            word = addr[15] ? dut.mem.hi.native.mem[addr[14:1]]
                            : dut.mem.lo.native.mem[addr[14:1]];
            mem_peek = addr[0] ? word[15:8] : word[7:0];
        end
    endfunction

    initial begin
        errors = 0;

        repeat (100) @(posedge clock);
        chk(dut.boot.running === 1'b1, "boot ROM running after POR");

        i = 0;
        while (dut.boot.done !== 1'b1 && i < 12000000) begin
            @(posedge clock);
            i = i + 1;
        end
        chk(dut.boot.done === 1'b1, "boot completes");
        chk(dut.cpu_reset === 1'b0, "CPU released after boot");
        chk(flash_cs === 1'b1, "flash released after boot");

        i = 0;
        while (mem_peek(16'hF000) !== 8'hA5 && i < 2000000) begin
            @(posedge clock);
            i = i + 1;
        end
        chk(mem_peek(16'hF000) === 8'hA5, "init marker ($F000=$A5)");

        // ---- color 1 (red) ----
        i = 0;
        while (mem_peek(16'hF001) !== 8'h01 && i < 50000) begin
            @(posedge clock);
            i = i + 1;
        end
        chk(mem_peek(16'hF001) === 8'h01, "color 1 checkpoint");
        chk(dut.io.leds === 8'h01, "color 1 leds");

        // ---- color 2 (green) ----
        i = 0;
        while (mem_peek(16'hF001) !== 8'h02 && i < 6000000) begin
            @(posedge clock);
            i = i + 1;
        end
        chk(mem_peek(16'hF001) === 8'h02, "color 2 checkpoint");
        $display("DBG color 2: mem=$%h leds=$%h", mem_peek(16'hF001), dut.io.leds);
        chk(dut.io.leds === 8'h02, "color 2 leds");

        // ---- color 3 (yellow) ----
        i = 0;
        while (mem_peek(16'hF001) !== 8'h03 && i < 6000000) begin
            @(posedge clock);
            i = i + 1;
        end
        chk(mem_peek(16'hF001) === 8'h03, "color 3 checkpoint");
        $display("DBG color 3: mem=$%h leds=$%h", mem_peek(16'hF001), dut.io.leds);
        chk(dut.io.leds === 8'h03, "color 3 leds");

        // ---- color 4 (blue) ----
        i = 0;
        while (mem_peek(16'hF001) !== 8'h04 && i < 6000000) begin
            @(posedge clock);
            i = i + 1;
        end
        chk(mem_peek(16'hF001) === 8'h04, "color 4 checkpoint");
        $display("DBG color 4: mem=$%h leds=$%h", mem_peek(16'hF001), dut.io.leds);
        chk(dut.io.leds === 8'h04, "color 4 leds");

        // ---- color 5 (magenta) ----
        i = 0;
        while (mem_peek(16'hF001) !== 8'h05 && i < 6000000) begin
            @(posedge clock);
            i = i + 1;
        end
        chk(mem_peek(16'hF001) === 8'h05, "color 5 checkpoint");
        chk(dut.io.leds === 8'h05, "color 5 leds");

        // ---- color 6 (cyan) ----
        i = 0;
        while (mem_peek(16'hF001) !== 8'h06 && i < 6000000) begin
            @(posedge clock);
            i = i + 1;
        end
        chk(mem_peek(16'hF001) === 8'h06, "color 6 checkpoint");
        chk(dut.io.leds === 8'h06, "color 6 leds");

        // ---- color 7 (white) ----
        i = 0;
        while (mem_peek(16'hF001) !== 8'h07 && i < 6000000) begin
            @(posedge clock);
            i = i + 1;
        end
        chk(mem_peek(16'hF001) === 8'h07, "color 7 checkpoint");
        chk(dut.io.leds === 8'h07, "color 7 leds");

        // ---- wraps back to 0 (off) ----
        i = 0;
        while (mem_peek(16'hF001) !== 8'h00 && i < 6000000) begin
            @(posedge clock);
            i = i + 1;
        end
        chk(mem_peek(16'hF001) === 8'h00, "color 0 checkpoint");
        chk(dut.io.leds === 8'h00, "color 0 leds");

        // ---- wraps to 1 again ----
        i = 0;
        while (mem_peek(16'hF001) !== 8'h01 && i < 6000000) begin
            @(posedge clock);
            i = i + 1;
        end
        chk(mem_peek(16'hF001) === 8'h01, "color 1 again checkpoint");
        chk(dut.io.leds === 8'h01, "color 1 again leds");

        if (errors == 0) begin
            $display("FOMU SIM PASS");
        end else begin
            $display("FAIL");
            $fatal;
        end
        $finish;
    end
endmodule