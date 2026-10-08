// mlkem_arith_core.v -- Blok c: Unified Arithmetic Core (KDA Computational Unit)
// 4 identical PEs in lock-step. Lane buses are packed: lane i = bits [12*i +: 12].
module mlkem_arith_core (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire [2:0]  mode,
    input  wire [47:0] a_bus, b_bus, c_bus, d_bus, z_bus,
    output wire        out_valid,
    output wire [47:0] y0_bus, y1_bus
);
    wire [3:0] ov;
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_pe
            mlkem_pe u_pe (
                .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .mode(mode),
                .a(a_bus[12*i +: 12]), .b(b_bus[12*i +: 12]),
                .c(c_bus[12*i +: 12]), .d(d_bus[12*i +: 12]), .z(z_bus[12*i +: 12]),
                .out_valid(ov[i]), .y0(y0_bus[12*i +: 12]), .y1(y1_bus[12*i +: 12])
            );
        end
    endgenerate
    assign out_valid = ov[0];   // lock-step: all lanes identical timing
endmodule
