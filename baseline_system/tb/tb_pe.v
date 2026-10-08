// tb_pe.v -- PE unit test: every mode vs behavioural reference, random + corner operands.
`timescale 1ns/1ps
`include "mlkem_defs.vh"
module tb_pe;
    reg clk = 0, rst_n = 0; always #1 clk = ~clk;
    reg        v = 0;
    reg [2:0]  mode = 0;
    reg [11:0] a, b, c, d, z;
    wire       ov;
    wire [11:0] y0, y1;
    mlkem_pe dut (.clk(clk), .rst_n(rst_n), .in_valid(v), .mode(mode),
                  .a(a), .b(b), .c(c), .d(d), .z(z), .out_valid(ov), .y0(y0), .y1(y1));

    integer errors = 0, n = 0, lat, t;
    reg [11:0] e0, e1;
    function [11:0] rnd; input dummy; reg [31:0] r; begin
        case ($random & 7)
            0: rnd = 0; 1: rnd = 3328; 2: rnd = 1; default: begin r = $random; rnd = r % 3329; end
        endcase end endfunction

    task run(input [2:0] m);
        begin
            a = rnd(0); b = rnd(0); c = rnd(0); d = rnd(0); z = rnd(0);
            case (m)
                `MODE_FNTT: begin e0 = (a + z*b) % 3329; e1 = (a + 3329 - (z*b)%3329) % 3329; end
                `MODE_INTT: begin e0 = (a + b) % 3329;   e1 = (z * ((b + 3329 - a) % 3329)) % 3329; end
                `MODE_PWM:  begin e0 = (a*c + ((b*d)%3329)*z) % 3329; e1 = (a*d + b*c) % 3329; end
                `MODE_ADD:  begin e0 = (a + b) % 3329;   e1 = y1; end
                `MODE_SUB:  begin e0 = (a + 3329 - b) % 3329; e1 = y1; end
                `MODE_SCALE:begin e0 = (a * z) % 3329;   e1 = y1; end
            endcase
            @(negedge clk); mode = m; v = 1;
            @(negedge clk); v = 0; lat = 1;
            while (!ov) begin @(negedge clk); lat = lat + 1; end
            n = n + 1;
            if (y0 !== e0 || (m != `MODE_ADD && m != `MODE_SUB && m != `MODE_SCALE && y1 !== e1)) begin
                errors = errors + 1;
                if (errors < 6) $display("ERR mode %0d: y0=%0d/%0d y1=%0d/%0d", m, y0, e0, y1, e1);
            end
            if (m == `MODE_PWM && lat != 9)       begin errors = errors + 1; $display("PWM latency %0d", lat); end
            if (m != `MODE_PWM && lat != 5)       begin errors = errors + 1; $display("latency %0d", lat); end
            repeat (3) @(negedge clk);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk); rst_n = 1;
        for (t = 0; t < 4000; t = t + 1) begin
            run(`MODE_FNTT); run(`MODE_INTT); run(`MODE_PWM);
            run(`MODE_ADD);  run(`MODE_SUB);  run(`MODE_SCALE);
        end
        if (errors == 0) $display("[PASS] PE all modes: %0d ops, latency 5 (PWM 9)", n);
        else             $display("[FAIL] PE: %0d errors", errors);
        $finish;
    end
endmodule
