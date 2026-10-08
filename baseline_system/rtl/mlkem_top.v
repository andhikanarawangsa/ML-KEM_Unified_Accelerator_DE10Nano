// mlkem_top.v -- ML-KEM Unified Polynomial Coprocessor (FPGA PL domain)
//   a. mlkem_csr + mlkem_ctrl   : Avalon-MM slave (CSR) + top-level FSM
//   b. mlkem_scratchpad         : 4 x (128x32b) simple-dual-port banks
//   c. mlkem_arith_core         : 4 PEs (CT/GS butterfly, PWM, ADD/SUB)
//   d. mlkem_zeta_rom           : twiddle ROM
module mlkem_top (
    input  wire        clk,
    input  wire        rst_n,
    // Avalon-MM slave (HPS lightweight bridge)
    input  wire [10:0] avs_address,
    input  wire        avs_read,
    input  wire        avs_write,
    input  wire [31:0] avs_writedata,
    output wire [31:0] avs_readdata,
    output wire        avs_readdatavalid,
    output wire        irq
);
    wire        start, busy, done_pulse, err, scale_en;
    wire [2:0]  op;
    wire [1:0]  slot_a, slot_b, slot_d;
    wire [31:0] cycles;

    wire        h_we, h_re, h_rvalid;
    wire [1:0]  h_slot;
    wire [6:0]  h_word;
    wire [31:0] h_wdata, h_rdata;

    wire [3:0]   c_we, c_re;
    wire [27:0]  c_waddr, c_raddr;
    wire [127:0] c_wdata, c_rdata;

    wire [6:0]  rom_a0, rom_a1;
    wire [11:0] rom_q0, rom_q1;

    wire        core_valid, core_out_valid;
    wire [2:0]  core_mode;
    wire [47:0] a_bus, b_bus, c_bus, d_bus, z_bus, y0_bus, y1_bus;

    mlkem_csr u_csr (
        .clk(clk), .rst_n(rst_n),
        .avs_address(avs_address), .avs_read(avs_read), .avs_write(avs_write),
        .avs_writedata(avs_writedata), .avs_readdata(avs_readdata),
        .avs_readdatavalid(avs_readdatavalid), .irq(irq),
        .start(start), .op(op), .scale_en(scale_en),
        .slot_a(slot_a), .slot_b(slot_b), .slot_d(slot_d),
        .busy(busy), .done_pulse(done_pulse), .err_in(err), .cycles(cycles),
        .h_we(h_we), .h_re(h_re), .h_slot(h_slot), .h_word(h_word),
        .h_wdata(h_wdata), .h_rdata(h_rdata)
    );

    mlkem_ctrl u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .start(start), .op(op), .scale_en(scale_en),
        .slot_a(slot_a), .slot_b(slot_b), .slot_d(slot_d),
        .busy(busy), .done_pulse(done_pulse), .err(err), .cycles(cycles),
        .c_we(c_we), .c_waddr(c_waddr), .c_wdata(c_wdata),
        .c_re(c_re), .c_raddr(c_raddr), .c_rdata(c_rdata),
        .rom_a0(rom_a0), .rom_q0(rom_q0), .rom_a1(rom_a1), .rom_q1(rom_q1),
        .core_valid(core_valid), .core_mode(core_mode),
        .a_bus(a_bus), .b_bus(b_bus), .c_bus(c_bus), .d_bus(d_bus), .z_bus(z_bus),
        .core_out_valid(core_out_valid), .y0_bus(y0_bus), .y1_bus(y1_bus)
    );

    mlkem_scratchpad u_spm (
        .clk(clk), .host_sel(~busy),
        .c_we(c_we), .c_waddr(c_waddr), .c_wdata(c_wdata),
        .c_re(c_re), .c_raddr(c_raddr), .c_rdata(c_rdata),
        .h_we(h_we), .h_re(h_re), .h_slot(h_slot), .h_word(h_word),
        .h_wdata(h_wdata), .h_rdata(h_rdata), .h_rvalid(h_rvalid)
    );

    mlkem_arith_core u_core (
        .clk(clk), .rst_n(rst_n), .in_valid(core_valid), .mode(core_mode),
        .a_bus(a_bus), .b_bus(b_bus), .c_bus(c_bus), .d_bus(d_bus), .z_bus(z_bus),
        .out_valid(core_out_valid), .y0_bus(y0_bus), .y1_bus(y1_bus)
    );

    mlkem_zeta_rom u_rom (
        .clk(clk), .addr0(rom_a0), .q0(rom_q0), .addr1(rom_a1), .q1(rom_q1)
    );
endmodule
