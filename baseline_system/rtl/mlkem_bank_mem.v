// mlkem_bank_mem.v -- one SRAM bank: simple dual-port (1 read + 1 write), 128 x 32 bit
// (= 256 x 16 bit capacity, 2 coefficients packed per word). 1-cycle synchronous read.
// Maps to a single M10K on Cyclone V.
module mlkem_bank_mem (
    input  wire        clk,
    input  wire        we,
    input  wire [6:0]  waddr,
    input  wire [31:0] wdata,
    input  wire        re,
    input  wire [6:0]  raddr,
    output reg  [31:0] rdata
);
    (* ramstyle = "M10K" *) reg [31:0] mem [0:127];
    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        if (re) rdata <= mem[raddr];
    end
endmodule
