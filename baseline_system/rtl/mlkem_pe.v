// mlkem_pe.v -- Unified Processing Element (blok c)
// One shared modular multiplier + modular add/sub + accumulator-style combine.
// Modes (see mlkem_defs.vh):
//   FNTT : y0 = a + z*b          y1 = a - z*b              (CT butterfly)
//   INTT : y0 = a + b            y1 = z*(b - a)            (GS butterfly, FIPS 203 form)
//   PWM  : (a0,a1)=(a,b) (b0,b1)=(c,d), z=gamma
//          y0 = a0*b0 + a1*b1*gamma    y1 = a0*b1 + a1*b0  (5 multiplier slots -> II = 5)
//   ADD  : y0 = a + b             SUB : y0 = a - b
//   SCALE: y0 = a * z
// Initiation interval: 1 cycle for all modes except PWM (5 cycles, enforced by the controller).
// Latency (in_valid -> out_valid): 5 cycles (non-PWM), 9 cycles (PWM).
`include "mlkem_defs.vh"
module mlkem_pe (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire [2:0]  mode,
    input  wire [11:0] a, b, c, d, z,
    output reg         out_valid,
    output reg  [11:0] y0, y1
);
    localparam [11:0] Q = 12'd3329;

    function [11:0] addmod; input [11:0] u, v; reg [12:0] s;
        begin s = u + v; addmod = (s >= Q) ? s - Q : s[11:0]; end endfunction
    function [11:0] submod; input [11:0] u, v; reg [12:0] s;
        begin s = {1'b0,u} + Q - v; submod = (s >= Q) ? s - Q : s[11:0]; end endfunction

    // ---- stage S0: operand registers + PWM phase counter ----
    reg        s_act;
    reg [2:0]  s_mode, ph;
    reg [11:0] ra, rb, rc, rd, rz;

    always @(posedge clk) begin
        if (!rst_n) begin
            s_act <= 1'b0; ph <= 3'd0;
        end else if (in_valid) begin
            s_act <= 1'b1; ph <= 3'd0; s_mode <= mode;
            ra <= a; rb <= b; rc <= c; rd <= d; rz <= z;
        end else if (s_act) begin
            if (s_mode == `MODE_PWM && ph != 3'd4) ph <= ph + 3'd1;
            else s_act <= 1'b0;
        end
    end

    // ---- multiplier operand select ----
    wire [11:0] mr;                       // multiplier output (3 cycles after issue)
    reg  [11:0] mx, my;
    always @* begin
        mx = 12'd0; my = 12'd0;
        case (s_mode)
            `MODE_FNTT:  begin mx = rb;               my = rz; end
            `MODE_INTT:  begin mx = submod(rb, ra);   my = rz; end
            `MODE_SCALE: begin mx = ra;               my = rz; end
            `MODE_PWM: case (ph)
                3'd0: begin mx = rb; my = rd; end     // a1*b1
                3'd1: begin mx = ra; my = rc; end     // a0*b0
                3'd2: begin mx = ra; my = rd; end     // a0*b1
                3'd3: begin mx = mr; my = rz; end     // (a1*b1)*gamma  (mr = result of ph0)
                default: begin mx = rb; my = rc; end  // a1*b0
            endcase
            default: begin end
        endcase
    end

    mlkem_modmul u_mm (.clk(clk), .x(mx), .y(my), .r(mr));

    // ---- tag / side-operand delay line (3 stages, aligned with multiplier) ----
    reg        t1v, t2v, t3v;
    reg [2:0]  t1m, t2m, t3m, t1p, t2p, t3p;
    reg [11:0] a1, a2, a3, b1, b2, b3;
    always @(posedge clk) begin
        if (!rst_n) begin t1v <= 0; t2v <= 0; t3v <= 0; end
        else begin t1v <= s_act; t2v <= t1v; t3v <= t2v; end
        t1m <= s_mode; t2m <= t1m; t3m <= t2m;
        t1p <= ph;     t2p <= t1p; t3p <= t2p;
        a1 <= ra; a2 <= a1; a3 <= a2;
        b1 <= rb; b2 <= b1; b3 <= b2;
    end

    // ---- output / accumulate stage ----
    reg [11:0] acc0, acc1;               // PWM partial products (accumulator)
    always @(posedge clk) begin
        if (!rst_n) out_valid <= 1'b0;
        else begin
            out_valid <= 1'b0;
            if (t3v) begin
                case (t3m)
                    `MODE_FNTT:  begin y0 <= addmod(a3, mr); y1 <= submod(a3, mr); out_valid <= 1'b1; end
                    `MODE_INTT:  begin y0 <= addmod(a3, b3); y1 <= mr;             out_valid <= 1'b1; end
                    `MODE_SCALE: begin y0 <= mr;             y1 <= 12'd0;          out_valid <= 1'b1; end
                    `MODE_ADD:   begin y0 <= addmod(a3, b3); y1 <= 12'd0;          out_valid <= 1'b1; end
                    `MODE_SUB:   begin y0 <= submod(a3, b3); y1 <= 12'd0;          out_valid <= 1'b1; end
                    `MODE_PWM: case (t3p)
                        3'd1: acc0 <= mr;                       // a0*b0
                        3'd2: acc1 <= mr;                       // a0*b1
                        3'd3: y0   <= addmod(acc0, mr);         // + a1*b1*gamma
                        3'd4: begin y1 <= addmod(acc1, mr); out_valid <= 1'b1; end // + a1*b0
                        default: begin end
                    endcase
                    default: begin end
                endcase
            end
        end
    end
endmodule
