// mlkem_modmul.v -- Unified Modular Multiplier + 2-cycle Barrett reducer (blok c)
// r = (x * y) mod 3329, x,y in [0,q).  Latency = 3 cycles, throughput = 1/cycle.
//   stage 1: p  = x*y                       (1 DSP 12x12)
//   stage 2: qe = (p * 5039) >> 24          (Barrett estimate, m = floor(2^24/q))
//   stage 3: r  = p - qe*q ; if r>=q r-=q   (qe*q = (qe<<12)-(qe<<9)-(qe<<8)+qe)
// Error bound: qe in {floor(p/q)-1, floor(p/q)} for p < 2^24 -> one conditional subtract.
module mlkem_modmul (
    input  wire        clk,
    input  wire [11:0] x,
    input  wire [11:0] y,
    output reg  [11:0] r
);
    reg [23:0] p1, p2;
    reg [11:0] qe;
    wire [36:0] pm  = p1 * 13'd5039;
    wire [23:0] qeq = ({12'b0,qe} << 12) - ({12'b0,qe} << 9) - ({12'b0,qe} << 8) + qe;
    wire [23:0] rr  = p2 - qeq;

    always @(posedge clk) begin
        p1 <= x * y;
        qe <= pm[35:24];
        p2 <= p1;
        r  <= (rr >= 24'd3329) ? (rr - 24'd3329) : rr[11:0];
    end
endmodule
