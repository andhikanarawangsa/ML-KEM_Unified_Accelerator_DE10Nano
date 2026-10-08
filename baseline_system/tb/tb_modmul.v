// tb_modmul.v -- EXHAUSTIVE check of the Barrett modular multiplier: all 3329 x 3329 pairs.
`timescale 1ns/1ps
module tb_modmul;
    reg clk = 0; always #1 clk = ~clk;
    reg  [11:0] x = 0, y = 0;
    wire [11:0] r;
    mlkem_modmul dut (.clk(clk), .x(x), .y(y), .r(r));

    // reference pipeline: expected value delayed by 3 cycles
    reg [11:0] e1, e2, e3;
    integer i, j, errors = 0, n = 0;
    always @(posedge clk) begin e1 <= (x * y) % 3329; e2 <= e1; e3 <= e2; end

    initial begin
        for (i = 0; i < 3329; i = i + 1)
            for (j = 0; j < 3329; j = j + 1) begin
                @(negedge clk); x = i; y = j;
                if (n >= 4 && r !== e3) begin
                    errors = errors + 1;
                    if (errors < 5) $display("ERR x*y: r=%0d exp=%0d", r, e3);
                end
                n = n + 1;
            end
        repeat (6) @(negedge clk);
        if (errors == 0) $display("[PASS] modmul exhaustive: %0d products", n);
        else             $display("[FAIL] modmul: %0d errors", errors);
        $finish;
    end
endmodule
