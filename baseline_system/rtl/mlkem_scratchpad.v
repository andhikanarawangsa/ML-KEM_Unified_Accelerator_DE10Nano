// mlkem_scratchpad.v -- Blok b: Bank-Centered Scratchpad Memory
// 4 independent simple-dual-port banks. Two masters share the ports:
//   * core side  (host_sel = 0): per-bank read/write ports driven by the controller
//   * host side  (host_sel = 1): single word access addressed by (slot, word) through
//     the conflict-free bank map; used by the Avalon window (replaces the DMA in this PoC).
module mlkem_scratchpad (
    input  wire         clk,
    input  wire         host_sel,
    // core side (packed per bank)
    input  wire [3:0]   c_we,
    input  wire [27:0]  c_waddr,
    input  wire [127:0] c_wdata,
    input  wire [3:0]   c_re,
    input  wire [27:0]  c_raddr,
    output wire [127:0] c_rdata,
    // host side
    input  wire         h_we,
    input  wire         h_re,
    input  wire [1:0]   h_slot,
    input  wire [6:0]   h_word,
    input  wire [31:0]  h_wdata,
    output wire [31:0]  h_rdata,     // valid 1 cycle after h_re
    output reg          h_rvalid
);
    `include "mlkem_bank_fn.vh"

    wire [1:0] hb = bank_of(h_slot, h_word);
    reg  [1:0] hb_q;
    always @(posedge clk) begin
        h_rvalid <= h_re & host_sel;
        hb_q     <= hb;
    end

    wire [31:0] bank_q [0:3];
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_bank
            wire        we_i = host_sel ? (h_we && hb == i) : c_we[i];
            wire        re_i = host_sel ? (h_re && hb == i) : c_re[i];
            wire [6:0]  wa_i = host_sel ? h_word : c_waddr[7*i +: 7];
            wire [6:0]  ra_i = host_sel ? h_word : c_raddr[7*i +: 7];
            wire [31:0] wd_i = host_sel ? h_wdata : c_wdata[32*i +: 32];
            mlkem_bank_mem u_bank (.clk(clk), .we(we_i), .waddr(wa_i), .wdata(wd_i),
                                   .re(re_i), .raddr(ra_i), .rdata(bank_q[i]));
            assign c_rdata[32*i +: 32] = bank_q[i];
        end
    endgenerate
    assign h_rdata = bank_q[hb_q];
endmodule
