// tb_scratchpad.v -- bank-map properties + 4-way parallel access
//  (1) (slot,word) -> (bank,addr) is a bijection onto 4 x 128 words
//  (2) any two words differing in ONE index bit hit different banks (NTT butterfly partners)
//  (3) same word of two different slots hits different banks (ADD/SUB/PWM operands)
//  (4) 4 banks accept 4 simultaneous writes and 4 simultaneous reads
`timescale 1ns/1ps
module tb_scratchpad;
    reg clk = 0; always #1 clk = ~clk;
    reg         host_sel = 0;
    reg  [3:0]  c_we = 0, c_re = 0;
    reg  [27:0] c_waddr = 0, c_raddr = 0;
    reg  [127:0] c_wdata = 0;
    wire [127:0] c_rdata;
    reg         h_we = 0, h_re = 0;
    reg  [1:0]  h_slot = 0;
    reg  [6:0]  h_word = 0;
    reg  [31:0] h_wdata = 0;
    wire [31:0] h_rdata;
    wire        h_rvalid;
    mlkem_scratchpad dut (.clk(clk), .host_sel(host_sel), .c_we(c_we), .c_waddr(c_waddr),
        .c_wdata(c_wdata), .c_re(c_re), .c_raddr(c_raddr), .c_rdata(c_rdata),
        .h_we(h_we), .h_re(h_re), .h_slot(h_slot), .h_word(h_word), .h_wdata(h_wdata),
        .h_rdata(h_rdata), .h_rvalid(h_rvalid));

    `include "mlkem_bank_fn.vh"
    integer errors = 0, p, p2, w, bit_i, k;
    reg [511:0] seen [0:3];
    reg [31:0] v;

    initial begin
        for (k = 0; k < 4; k = k + 1) seen[k] = 0;
        for (p = 0; p < 4; p = p + 1)
            for (w = 0; w < 128; w = w + 1) begin
                if (seen[bank_of(p, w)][w]) errors = errors + 1;     // collision at same (bank,addr)
                seen[bank_of(p, w)][w] = 1;
                for (bit_i = 0; bit_i < 7; bit_i = bit_i + 1)
                    if (bank_of(p, w) == bank_of(p, w ^ (1 << bit_i))) errors = errors + 1;
                for (p2 = 0; p2 < 4; p2 = p2 + 1)
                    if (p2 != p && bank_of(p, w) == bank_of(p2, w)) errors = errors + 1;
            end
        // host fill + readback of all 512 words
        host_sel = 1;
        for (p = 0; p < 4; p = p + 1) for (w = 0; w < 128; w = w + 1) begin
            @(negedge clk); h_we = 1; h_slot = p; h_word = w; h_wdata = {p[1:0], 5'd0, w[6:0], 16'hA5A5} ^ (p*w);
        end
        @(negedge clk); h_we = 0;
        for (p = 0; p < 4; p = p + 1) for (w = 0; w < 128; w = w + 1) begin
            @(negedge clk); h_re = 1; h_slot = p; h_word = w;
            @(negedge clk); h_re = 0;
            #0.5; if (!h_rvalid || h_rdata !== (({p[1:0], 5'd0, w[6:0], 16'hA5A5}) ^ (p*w))) errors = errors + 1;
        end
        // parallel core access: write 4 words to 4 banks at once, read back at once
        host_sel = 0;
        @(negedge clk);
        c_we = 4'hF; c_waddr = {7'd9, 7'd8, 7'd7, 7'd6};
        c_wdata = {32'hDDDD0004, 32'hCCCC0003, 32'hBBBB0002, 32'hAAAA0001};
        @(negedge clk); c_we = 0; c_re = 4'hF; c_raddr = {7'd9, 7'd8, 7'd7, 7'd6};
        @(negedge clk); c_re = 0;
        @(negedge clk);
        if (c_rdata !== {32'hDDDD0004, 32'hCCCC0003, 32'hBBBB0002, 32'hAAAA0001}) errors = errors + 1;
        if (errors == 0) $display("[PASS] scratchpad: bijective, conflict-free map, 4-way parallel access");
        else             $display("[FAIL] scratchpad: %0d errors", errors);
        $finish;
    end
endmodule
