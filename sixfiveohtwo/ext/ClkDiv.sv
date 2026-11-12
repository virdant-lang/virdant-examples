// Registered divide-by-eight clock divider (see fomu_top.vir).
//
// sys_clk is a register output (glitch-free): it toggles at the edges
// ending cnt==3 and cnt==7, so it is low for cnt 0-3 and high for
// cnt 4-7 -- 50% duty, one eighth of the input period.

module ClkDiv(
    input  wire clock,
    output wire sys_clk
);
    reg [2:0] cnt = 3'd0;
    reg       out = 1'b0;

    always @(posedge clock) begin
        cnt <= cnt + 3'd1;
        if (cnt[0] & cnt[1])
            out <= ~out;
    end

    assign sys_clk = out;
endmodule
