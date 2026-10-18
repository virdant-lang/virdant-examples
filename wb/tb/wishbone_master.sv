// Reusable Wishbone classic master testbench driver.
//
// Instantiate WishboneMaster in your project's testbench and wire it to the
// DUT's Wishbone socket ports.  Then call the procedural tasks, which block
// until the transaction completes (ACK received):
//
//     wb.wb_write(addr, data);            // blocking write
//     wb.wb_read(addr, data);             // blocking read
//     wb.wb_read_check(addr, expected);   // blocking read + $fatal on mismatch
//
// Bus timing: all signals are driven on the negedge of `clock` so they are
// stable well before each posedge, avoiding races with the DUT.  The driver
// holds `cyc`/`stb` until it observes `ack`, then deasserts on the same
// negedge, so each transaction occupies exactly one accepted bus cycle.
//
// NOTE: tasks are static (not automatic); this driver is intended for
// single-threaded use from one initial block.

module WishboneMaster #(
    parameter AWIDTH = 32,
    parameter DWIDTH = 32
) (
    input  wire             clock,

    // Request channels (driven by this master)
    output reg              cyc,
    output reg              stb,
    output reg              we,
    output reg  [AWIDTH-1:0] addr,
    output reg  [DWIDTH-1:0] wr_data,

    // Response channels (driven by the DUT)
    input  wire             ack,
    input  wire [DWIDTH-1:0] rd_data
);

    // Start every request signal at 0 so the bus is idle at t=0.  These are
    // reg variables, so this is a one-time initialization, not a continuous
    // driver (a `wire ... = 0` initializer on the tb net would be a second
    // driver and would resolve the bus to X).
    initial begin
        cyc     = 1'b0;
        stb     = 1'b0;
        we      = 1'b0;
        addr    = {AWIDTH{1'b0}};
        wr_data = {DWIDTH{1'b0}};
    end

    // Internal helper: start a transaction and wait for ack.
    // Drives `we`/`wr_data` as given; returns rd_data sampled at ack.
    task _wb_txn(
        input              txn_we,
        input [AWIDTH-1:0] txn_addr,
        input [DWIDTH-1:0] txn_wr_data,
        output [DWIDTH-1:0] txn_rd_data
    );
        begin
            @(negedge clock);
            cyc      = 1'b1;
            stb      = 1'b1;
            we       = txn_we;
            addr     = txn_addr;
            wr_data  = txn_wr_data;

            // ack is registered by the DUT, so sample it on negedge after
            // each posedge to make sure any NBA updates have settled.
            @(posedge clock);
            @(negedge clock);
            while (ack !== 1'b1) begin
                @(posedge clock);
                @(negedge clock);
            end

            txn_rd_data = rd_data;
            cyc      = 1'b0;
            stb      = 1'b0;
            we       = 1'b0;
        end
    endtask

    task wb_write(
        input [AWIDTH-1:0]  a,
        input [DWIDTH-1:0]  d
    );
        reg [DWIDTH-1:0] dummy;
        begin
            _wb_txn(1'b1, a, d, dummy);
        end
    endtask

    task wb_read(
        input  [AWIDTH-1:0]  a,
        output [DWIDTH-1:0]  d
    );
        begin
            _wb_txn(1'b0, a, {DWIDTH{1'b0}}, d);
        end
    endtask

    task wb_read_check(
        input [AWIDTH-1:0]  a,
        input [DWIDTH-1:0]  expected
    );
        reg [DWIDTH-1:0] d;
        begin
            wb_read(a, d);
            if (d !== expected) begin
                $display("FAIL: wb_read_check: addr 0x%08x: read 0x%08x, expected 0x%08x (time %0t)", a, d, expected, $time);
                $fatal(1);
            end else begin
                $display("PASS: wb_read_check: addr 0x%08x == 0x%08x", a, expected);
            end
        end
    endtask

endmodule
