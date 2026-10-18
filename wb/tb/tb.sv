// Project testbench for the wb project's Top module.
// Instantiates the reusable WishboneMaster driver and runs bus transactions.
`timescale 1ns/1ps

module Tb;
    reg              clock = 1'b0;

    // NOTE: these nets must NOT carry `= 0` initializers.  A net
    // declaration assignment is a continuous driver; combined with the
    // module outputs driving them, every signal would resolve to X.
    // The drivers are zero-initialized instead (WishboneMaster initial
    // block, Memory `initial rd_data`, and the vir-generated `initial
    // ack`), so every signal below is 0 at t=0.
    wire             cyc, stb, we, ack;
    wire [31:0]      addr, wr_data, rd_data;

    Top dut(
        .clock             (clock),
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

    // 48 MHz: period 20.833ns (10.417ns half-period).
    always #10.417 clock = ~clock;

    initial begin
        $dumpfile("tb.vcd");
        $dumpvars(0, Tb);

        // Write to two addresses, then read them back.
        wb.wb_write(32'h0000_0000, 32'hDEAD_BEEF);
        wb.wb_write(32'h0000_0004, 32'h1234_5678);

        wb.wb_read_check(32'h0000_0000, 32'hDEAD_BEEF);
        wb.wb_read_check(32'h0000_0004, 32'h1234_5678);

        $display("DONE");
        $finish;
    end
endmodule