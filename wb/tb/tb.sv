// Project testbench for the wb project's Ns8520 UART.
//
// Instantiates the reusable WishboneMaster driver and verifies the
// TRANSMIT path of the UART:
//
//   1. LSR reads DR=0, OE=0, THRE=1, TEMT=1 after reset
//   2. A single byte written to THR is serialized on tx; THRE stays
//      set and TEMT clears while the frame is in progress
//   3. Nine bytes written back to back fill the FIFO: THRE clears,
//      all nine are serialized (start-bit edges counted on tx), and
//      THRE returns once the FIFO drains
//
// The RX path is exercised by an earlier version of this testbench
// via a serial loopback (rx = tx): write a byte, poll DR, read it
// back from the RBR, and force an RX-FIFO overrun with 10 bytes.
// Those checks are commented out below to keep this run TX-only.

`timescale 1ns/1ps

module Tb;
    reg              clock = 1'b0;
    reg              reset = 1'b1;

    // NOTE: these nets must NOT carry `= 0` initializers.  A net
    // declaration assignment is a continuous driver; combined with the
    // module outputs driving them, every signal would resolve to X.
    // The drivers are zero-initialized instead (WishboneMaster initial
    // block, and the vir-generated `initial` register values), so every
    // signal below is 0 at t=0.
    wire             cyc, stb, we, ack;
    wire [31:0]      addr, wr_data, rd_data;
    wire             tx, rx, uart_clock;

    Top dut(
        .clock             (clock),
        .reset             (reset),
        .rx                (rx),
        .tx                (tx),
        .uart_clock        (uart_clock),
        .\wishbone.cyc     (cyc),
        .\wishbone.stb     (stb),
        .\wishbone.we      (we),
        .\wishbone.addr    (addr),
        .\wishbone.wr_data (wr_data),
        .\wishbone.ack     (ack),
        .\wishbone.rd_data (rd_data)
    );

    WishboneMaster wb(
        .clock    (clock),
        .cyc      (cyc),
        .stb      (stb),
        .we       (we),
        .addr     (addr),
        .wr_data  (wr_data),
        .ack      (ack),
        .rd_data  (rd_data)
    );

    // RX path inactive: hold the serial input idle-high.  (The loopback
    // used for RX testing was:  assign rx = reset ? 1'b1 : tx;)
    assign rx = 1'b1;

    // 48 MHz: period 20.833ns (10.4165ns half-period).
    always #10.4165 clock = ~clock;

    // LSR address and status bits (ns8520 register map).
    localparam [31:0] ADDR_THR  = 32'h0000_0000;
    localparam [31:0] ADDR_LSR  = 32'h0000_0004;
    localparam [31:0] LSR_DR    = 32'h01;
    localparam [31:0] LSR_OE    = 32'h02;
    localparam [31:0] LSR_THRE  = 32'h20;
    localparam [31:0] LSR_TEMT  = 32'h40;

    // Serial monitor: decodes the byte stream on tx (115200 baud,
    // 48 MHz clock, 8N1).  On the start-bit falling edge it waits 1.5
    // bit times to reach the center of data bit 0, samples the eight
    // data bits LSB first, and records the byte.
    integer tx_frames = 0;
    reg [7:0] tx_sent [0:15];   // decoded bytes, in order
    localparam realtime BIT_NS = 416 * 20.833;   // one bit = 8666.5ns
    integer mon_i;
    initial begin
        forever begin
            @(negedge tx);
            #(BIT_NS * 1.5);
            tx_byte = 8'h0;
            for (mon_i = 0; mon_i < 8; mon_i = mon_i + 1) begin
                tx_byte[mon_i] = tx;
                #(BIT_NS);
            end
            tx_sent[tx_frames] = tx_byte;
            tx_frames = tx_frames + 1;
        end
    end
    reg [7:0] tx_byte;

    // Verify a decoded byte and fail loudly on a mismatch.
    task check_sent(
        input integer index,
        input [7:0]  expected
    );
        begin
            if (tx_sent[index] !== expected) begin
                $display("FAIL: tx byte %0d: sent 0x%02x, expected 0x%02x (time %0t)",
                         index, tx_sent[index], expected, $time);
                $fatal(1);
            end else begin
                $display("PASS: tx byte %0d == 0x%02x", index, expected);
            end
        end
    endtask

    // Poll the LSR until (lsr & mask) == value.
    task poll_lsr(
        input [31:0] mask,
        input [31:0] value
    );
        reg [31:0] d;
        begin
            wb.wb_read(ADDR_LSR, d);
            while ((d & mask) !== value) begin
                wb.wb_read(ADDR_LSR, d);
            end
        end
    endtask

    // Poll until the transmitter is completely idle (TEMT).
    task wait_tx_idle;
        begin
            poll_lsr(LSR_TEMT, LSR_TEMT);
        end
    endtask

    // Poll until the transmitter is busy (TEMT clear).
    task wait_tx_busy;
        begin
            poll_lsr(LSR_TEMT, 32'h0);
        end
    endtask

    integer i;
    reg [31:0] d;

    initial begin
        // Dump only the top-level signals (keep the VCD small).
        $dumpfile("tb.vcd");
        $dumpvars(0, clock);
        $dumpvars(0, reset);
        $dumpvars(0, cyc);
        $dumpvars(0, stb);
        $dumpvars(0, we);
        $dumpvars(0, addr);
        $dumpvars(0, wr_data);
        $dumpvars(0, ack);
        $dumpvars(0, rd_data);
        $dumpvars(0, tx);
        $dumpvars(0, rx);
        $dumpvars(0, uart_clock);

        repeat (10) @(negedge clock);
        reset = 1'b0;
        repeat (5) @(negedge clock);
        $display("[%0t] reset released, tests begin", $time);

        // 1. Fresh LSR: transmitter empty and idle.
        wb.wb_read_check(ADDR_LSR, LSR_THRE | LSR_TEMT);

        // 2. Single byte: TEMT clears while the frame is shifting out,
        //    THRE stays set (FIFO has room), TEMT returns after.
        wb.wb_write(ADDR_THR, "A");
        wait_tx_busy;
        wb.wb_read_check(ADDR_LSR, LSR_THRE);
        wait_tx_idle;
        wb.wb_read_check(ADDR_LSR, LSR_THRE | LSR_TEMT);
        if (tx_frames !== 1) begin
            $display("FAIL: expected 1 frame, saw %0d (time %0t)", tx_frames, $time);
            $fatal(1);
        end
        check_sent(0, "A");

        // 3. Nine bytes back to back: one in the serializer plus eight
        //    in the FIFO; the ninth write makes THRE clear until the
        //    FIFO drains.
        for (i = 0; i < 9; i = i + 1) begin
            wb.wb_write(ADDR_THR, "A" + i[31:0]);
        end
        wb.wb_read_check(ADDR_LSR, 32'h0);
        wait_tx_idle;
        wb.wb_read_check(ADDR_LSR, LSR_THRE | LSR_TEMT);
        if (tx_frames !== 10) begin
            $display("FAIL: expected 10 frames, saw %0d (time %0t)", tx_frames, $time);
            $fatal(1);
        end
        for (i = 0; i < 9; i = i + 1) begin
            check_sent(i + 1, "A" + i[7:0]);
        end

        // ---- RX-path checks (disabled: TX-only run) ----
        // // Serial loopback testing:  assign rx = reset ? 1'b1 : tx;
        //
        // // Single byte, full round trip through the TX and RX paths.
        // wb.wb_write(ADDR_THR, 32'h41);
        // read_byte_check(32'h41);
        // wait_tx_idle;
        // wb.wb_read_check(ADDR_LSR, LSR_THRE | LSR_TEMT);
        //
        // // Three bytes back to back: they must come back in order.
        // wb.wb_write(ADDR_THR, 32'h42);
        // wb.wb_write(ADDR_THR, 32'h43);
        // wb.wb_write(ADDR_THR, 32'h44);
        // read_byte_check(32'h42);
        // read_byte_check(32'h43);
        // read_byte_check(32'h44);
        // wait_tx_idle;
        // wb.wb_read_check(ADDR_LSR, LSR_THRE | LSR_TEMT);
        //
        // // Overrun: 10 bytes without draining (serializer holds one,
        // // FIFO holds eight, the rest is dropped and flagged).
        // for (i = 0; i < 10; i = i + 1) begin
        //     wb.wb_write(ADDR_THR, 32'h41 + i[31:0]);
        // end
        // wait_tx_idle;
        // poll_lsr(LSR_OE, LSR_OE);
        // wb.wb_read_check(ADDR_LSR, LSR_DR | LSR_OE | LSR_THRE | LSR_TEMT);
        // for (i = 0; i < 8; i = i + 1) begin
        //     read_byte_check(32'h41 + i[31:0]);
        // end
        // wb.wb_read_check(ADDR_LSR, LSR_THRE | LSR_TEMT);

        $display("DONE");
        $finish;
    end

    // Helper used by the disabled RX checks above.
    task read_byte_check(
        input [31:0] expected
    );
        begin
            poll_lsr(LSR_DR, LSR_DR);
            wb.wb_read_check(ADDR_THR, expected);
        end
    endtask

endmodule
