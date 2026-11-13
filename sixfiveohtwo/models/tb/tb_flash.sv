`timescale 10ns/1ns

// Differential test for the native SPI flash model (models::Flash)
// against the ext/Flash.sv Verilog reference it replaces. One SPI
// mode-0 master drives both with the same transactions (matching the
// boot ROM's phase structure: mosi stable before each rising clk
// edge, cs falling while clk is low), and the miso each model
// presents at every rising edge must agree — and match the flash
// image (the same file the native model loads via @image_hex).

module Tb;
    reg  clk = 0;     // the SPI clock line
    reg  cs = 1;
    reg  mosi = 0;
    wire miso_ref, miso_native;

    Flash flash_ref(.cs(cs), .clk(clk), .mosi(mosi), .miso(miso_ref));
    \models::Flash native(.cs(cs), .clk(clk), .mosi(mosi), .miso(miso_native));

    reg [7:0] image [0:4194303];

    integer errors;
    integer k, bit_i;
    reg expected_bit;

    // One bit period: mosi goes out while clk is low; both models are
    // compared (and checked against expected_bit) at the rising edge;
    // then clk falls.
    task spi_bit(input b);
        begin
            mosi = b;
            #5;
            clk = 1;
            if (miso_ref !== miso_native) begin
                $display("FAIL: miso mismatch at %0t (ref=%b native=%b)",
                         $time, miso_ref, miso_native);
                errors = errors + 1;
            end
            if (miso_ref !== expected_bit) begin
                $display("FAIL: miso vs image at %0t (expected=%b ref=%b)",
                         $time, expected_bit, miso_ref);
                errors = errors + 1;
            end
            #5;
            clk = 0;
        end
    endtask

    task spi_byte(input [7:0] b);
        begin
            for (k = 7; k >= 0; k = k - 1) spi_bit(b[k]);
        end
    endtask

    // A read transaction: select, command, address, nbytes of data
    // checked against the image, release.
    task flash_read(input [23:0] start_addr, input integer nbytes);
        integer j;
        begin
            expected_bit = 1'b0;
            cs = 0;
            spi_byte(8'h03);
            spi_byte(start_addr[23:16]);
            spi_byte(start_addr[15:8]);
            spi_byte(start_addr[7:0]);
            for (j = 0; j < nbytes; j = j + 1) begin
                for (bit_i = 7; bit_i >= 0; bit_i = bit_i - 1) begin
                    expected_bit = image[start_addr + j][bit_i];
                    spi_bit(expected_bit);
                end
            end
            cs = 1;
        end
    endtask

    initial begin
        errors = 0;
        $readmemh("models/build/flash_image.hex", image);

        // Read 48 bytes from the program region.
        flash_read(24'h080000, 48);

        // Idle with the chip released: miso must be 0 on both.
        expected_bit = 1'b0;
        for (k = 0; k < 20; k = k + 1) spi_bit(1'b0);

        // A second read at another offset (reframing).
        flash_read(24'h080100, 16);

        // An unmodeled command: both models must ignore it (miso
        // stays 0 through a command byte, an address's worth of bits,
        // and a dummy byte).
        expected_bit = 1'b0;
        cs = 0;
        spi_byte(8'hAB);
        spi_byte(8'h00);
        spi_byte(8'h00);
        spi_byte(8'h00);
        spi_byte(8'h00);
        cs = 1;
        for (k = 0; k < 4; k = k + 1) spi_bit(1'b0);

        // Re-command: read the start again.
        flash_read(24'h080000, 8);

        if (errors == 0) begin
            $display("FLASH DIFFERENTIAL PASS");
        end else begin
            $display("FAIL");
            $fatal;
        end
        $finish;
    end
endmodule
