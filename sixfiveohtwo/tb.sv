`timescale 10ns/1ns

// Generic testbench for the sixfiveohtwo 6502.
//
// Models 64K of async-read memory: data is valid in the same cycle
// addr is driven, and stores commit at the rising edge when the valid
// tag of bus_write is set.
//
// Expectations come from an expectation file (+exp=<file>) processed
// top to bottom. Line types (first character):
//   M <addr> <byte>   wait until the program stores <byte> at <addr>
//   F <flag> <0|1>    check a CPU flag (N Z C V D I) at this point
//   R <reg> <hex>     check a register (A X Y S=SP P=PC) at this point
//   C <addr> <hex>    compare memory at <addr>
// '#' starts a comment line.
//
// Run with: ./run +hex=<image.hex> +exp=<expectations> [+debug=1]

module Tb;
    reg clock = 0;
    reg reset = 0;
    reg irq_n = 1;      // active-low, level-sensitive
    reg nmi_n = 1;      // active-low, edge-triggered
    reg vcd = 0;        // waveform dump (off by default: huge for long runs)

    // -- 64K async-read memory --
    reg [7:0] mem [0:65535];

    wire [15:0] bus_addr;
    wire [9:0]  bus_write;      // bits [1:0] = tag (2'b10 = valid); payload [9:2]
    wire [7:0]  bus_data;

    \top::Top dut(
        .clock(clock),
        .reset(reset),
        .irq_n(irq_n),
        .nmi_n(nmi_n),
        .\busif.addr (bus_addr),
        .\busif.write (bus_write),
        .\busif.data (bus_data)
    );

    // Async read: data valid in the same cycle as addr.
    assign bus_data = mem[bus_addr];

    // Stores commit at the rising edge.
    always @(posedge clock) begin
        if (bus_write[1:0] == 2'b10) begin
            mem[bus_addr] <= bus_write[9:2];
        end
    end

    always begin
        #1 clock = ~clock;
    end

    reg debug = 0;
    reg klaus = 0;      // Klaus Dormann mode: watch for the success loop

    always @(posedge clock) begin
        if (debug) begin
            $display("%0t pc=%h ir=%h st=%b al=%h md=%b a=%h x=%h y=%h NZCVID=%b%b%b%b%b%b wr=%b ad=%h ov=%b nz=%h alu_a=%h alu_b=%h dec=%b op=%h",
                     $time, dut.cpu.pc, dut.cpu.ir, dut.cpu.state,
                     dut.cpu.addr_low, dut.cpu.mode,
                     dut.cpu.a, dut.cpu.x, dut.cpu.y,
                     dut.cpu.flag_n, dut.cpu.flag_z, dut.cpu.flag_c,
                     dut.cpu.flag_v, dut.cpu.flag_i, dut.cpu.flag_d,
                     bus_write, bus_addr, dut.cpu.math.overflow, dut.cpu.math.nz_source, dut.cpu.math.a, dut.cpu.math.b, dut.cpu.math.decimal, dut.cpu.math.op);
        end
    end

    integer errors;
    integer cycles;

    // Klaus Dormann functional test: success = PC parked in the
    // final self-loop at $3469 (see klaus/README.md). All other
    // traps are also self-loops, so on timeout we report the parked
    // PC, which identifies the failing test section.
    task run_klaus;
        integer n;
    begin
        n = 0;
        while (dut.cpu.pc !== 16'h3469 && n < 200000000) begin
            @(posedge clock);
            n = n + 1;
            if (n % 10000000 == 0) begin
                $display("... %0dM cycles, pc=%h", n / 1000000, dut.cpu.pc);
            end
        end
        cycles = n;
        if (dut.cpu.pc !== 16'h3469) begin
            $display("TIMEOUT after %0d cycles, parked at pc=%h (a=%h x=%h y=%h s=%h)",
                     n, dut.cpu.pc, dut.cpu.a, dut.cpu.x, dut.cpu.y, dut.cpu.sp);
            $display("FAIL");
            $fatal;
        end
        $display("Klaus functional test PASSED in %0d cycles", n);
        $display("PASS");
        $finish;
    end
    endtask

    task do_reset;
    begin
        reset = 0; #0.1; @(posedge clock);
        reset = 1; #0.1; @(posedge clock);
        reset = 0; #0.1; @(posedge clock);
    end
    endtask

    // Wait until the program stores exactly val at addr.
    task wait_marker(input [15:0] addr, input [7:0] val);
        integer n;
    begin
        n = 0;
        while (mem[addr] !== val && n < 200000) begin
            @(posedge clock);
            #0.1;
            n = n + 1;
        end
        cycles = cycles + n;
        if (mem[addr] !== val) begin
            $display("TIMEOUT waiting for store of %h at %h", val, addr);
            $display("FAIL");
            $fatal;
        end
    end
    endtask

    task chk(input cond, input [8*48:1] name, input integer lineno);
    begin
        if (cond !== 1'b1) begin
            $display("FAIL: line %0d: %s", lineno, name);
            errors = errors + 1;
        end
    end
    endtask

    // -- Expectation file (hex records from tools/exp.py, FF-terminated) --
    reg [7:0] expbytes [0:8191];
    integer nbytes;

    task load_exp(input [8*64:1] path);
    begin
        for (i = 0; i < 8192; i = i + 1) expbytes[i] = 8'hFF;
        $readmemh(path, expbytes);
        nbytes = 8192;
    end
    endtask

    // Process the expectation records in order.
    task run_exp;
        integer p;
        reg [7:0] t, ltr;
        reg [15:0] a, rv, ln;
    begin
        p = 0;
        while (p < nbytes && expbytes[p] != 8'hFF) begin
            t = expbytes[p]; p = p + 1;
            ln = {expbytes[p], expbytes[p+1]}; p = p + 2;
            if (t == 8'h01) begin                      // marker
                a = {expbytes[p], expbytes[p+1]}; p = p + 2;
                rv = expbytes[p]; p = p + 1;
                wait_marker(a, rv[7:0]);
            end else if (t == 8'h02) begin             // flag
                ltr = expbytes[p]; p = p + 1;
                rv = expbytes[p]; p = p + 1;
                if (ltr == "N")
                    chk(dut.cpu.flag_n === (rv != 0), "flag N", ln);
                else if (ltr == "Z")
                    chk(dut.cpu.flag_z === (rv != 0), "flag Z", ln);
                else if (ltr == "C")
                    chk(dut.cpu.flag_c === (rv != 0), "flag C", ln);
                else if (ltr == "V")
                    chk(dut.cpu.flag_v === (rv != 0), "flag V", ln);
                else if (ltr == "D")
                    chk(dut.cpu.flag_d === (rv != 0), "flag D", ln);
                else if (ltr == "I")
                    chk(dut.cpu.flag_i === (rv != 0), "flag I", ln);
                else begin
                    $display("FAIL: line %0d: unknown flag", ln);
                    errors = errors + 1;
                end
            end else if (t == 8'h03) begin             // reg
                ltr = expbytes[p]; p = p + 1;
                a = {expbytes[p], expbytes[p+1]}; p = p + 2;
                if (ltr == "A")
                    chk(dut.cpu.a === a[7:0], "reg A", ln);
                else if (ltr == "X")
                    chk(dut.cpu.x === a[7:0], "reg X", ln);
                else if (ltr == "Y")
                    chk(dut.cpu.y === a[7:0], "reg Y", ln);
                else if (ltr == "S")
                    chk(dut.cpu.sp === a[7:0], "reg SP", ln);
                else if (ltr == "P")
                    chk(dut.cpu.pc === a, "reg PC", ln);
                else begin
                    $display("FAIL: line %0d: unknown reg", ln);
                    errors = errors + 1;
                end
            end else if (t == 8'h05) begin             // pin drive
                ltr = expbytes[p]; p = p + 1;
                rv = expbytes[p]; p = p + 1;
                if (ltr == "I")
                    irq_n = rv[0];
                else if (ltr == "N")
                    nmi_n = rv[0];
                else begin
                    $display("FAIL: line %0d: unknown pin", ln);
                    errors = errors + 1;
                end
            end else if (t == 8'h04) begin             // mem compare
                a = {expbytes[p], expbytes[p+1]}; p = p + 2;
                rv = expbytes[p]; p = p + 1;
                if (mem[a] !== rv[7:0]) begin
                    $display("FAIL: line %0d: mem[%h] = %h, expected %h",
                             ln, a, mem[a], rv[7:0]);
                    errors = errors + 1;
                end
            end else begin
                $display("FAIL: bad expectation record type %h at byte %0d", t, p - 3);
                errors = errors + 1;
                p = nbytes;
            end
        end
    end
    endtask

    reg [8*64:1] hexfile;
    reg [8*64:1] expfile;

    initial begin
        void'($value$plusargs("vcd=%d", vcd));
        if (vcd) begin
            $dumpfile("dump.vcd");
            $dumpvars(0, dut);
        end
        errors = 0;
        cycles = 0;

        for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
        if (!$value$plusargs("hex=%s", hexfile)) begin
            $display("ERROR: +hex=<image.hex> required");
            $fatal;
        end
        void'($value$plusargs("klaus=%d", klaus));
        if (!klaus && !$value$plusargs("exp=%s", expfile)) begin
            $display("ERROR: +exp=<expectations> required");
            $fatal;
        end
        void'($value$plusargs("debug=%d", debug));
        $readmemh(hexfile, mem);
        if (klaus) begin
            // Klaus expects a monitor to start execution at $0400.
            mem[16'hFFFC] = 8'h00;
            mem[16'hFFFD] = 8'h04;
        end else begin
            // Reset vector -> $0200 (the fixed smoke-test origin).
            mem[16'hFFFC] = 8'h00;
            mem[16'hFFFD] = 8'h02;
        end

        do_reset;

        if (klaus) begin
            run_klaus;
        end else begin
            load_exp(expfile);
            run_exp;
        end

        $display("smoke test finished in %0d cycles, %0d errors", cycles, errors);
        if (errors == 0) begin
            $display("PASS");
        end else begin
            $display("FAIL");
            $fatal;
        end
        $finish;
    end

    integer i;
endmodule