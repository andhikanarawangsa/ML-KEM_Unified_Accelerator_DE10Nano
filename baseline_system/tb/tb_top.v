// tb_top.v -- self-checking system testbench (HPS-like Avalon-MM master)
// Run from repo root:  make sim   (needs tb/vectors/*.hex from scripts/gen_vectors.py)
`timescale 1ns/1ps
module tb_top;
    reg         clk = 0, rst_n = 0;
    reg  [10:0] avs_address = 0;
    reg         avs_read = 0, avs_write = 0;
    reg  [31:0] avs_writedata = 0;
    wire [31:0] avs_readdata;
    wire        avs_readdatavalid, irq;

    mlkem_top dut (.clk(clk), .rst_n(rst_n), .avs_address(avs_address), .avs_read(avs_read),
                   .avs_write(avs_write), .avs_writedata(avs_writedata),
                   .avs_readdata(avs_readdata), .avs_readdatavalid(avs_readdatavalid), .irq(irq));
    always #3.333 clk = ~clk;   // ~150 MHz

    localparam R_ID=0, R_CTRL=1, R_STATUS=2, R_OP=3, R_SLOT=4, R_CYC=5, MEM=11'h400;
    localparam FNTT=0, INTT=1, PWM=2, ADD=3, SUB=4, SCALE=5;

    integer errors = 0, tests = 0;
    reg [31:0] exp [0:127];
    reg [31:0] tmp [0:127];

    task bus_write(input [10:0] a, input [31:0] d);
        begin @(posedge clk); avs_address <= a; avs_writedata <= d; avs_write <= 1;
              @(posedge clk); avs_write <= 0; end
    endtask
    task bus_read(input [10:0] a, output [31:0] d);
        begin @(posedge clk); avs_address <= a; avs_read <= 1;
              @(posedge clk); avs_read <= 0;
              while (!avs_readdatavalid) @(posedge clk);
              d = avs_readdata; end
    endtask

    task load_poly(input integer slot, input [8*40-1:0] file);
        integer w;
        begin
            $readmemh(file, tmp);
            for (w = 0; w < 128; w = w + 1) bus_write(MEM + slot*128 + w, tmp[w]);
        end
    endtask

    task run_op(input integer mode, input integer sa, input integer sb, input integer sd,
                input integer scale);
        reg [31:0] st;
        begin
            bus_write(R_OP,   mode | (scale << 3));
            bus_write(R_SLOT, sa | (sb << 2) | (sd << 4));
            bus_write(R_CTRL, 1);
            st = 0;
            while (!st[1]) bus_read(R_STATUS, st);
        end
    endtask

    task check_poly(input integer slot, input [8*40-1:0] file, input [8*40-1:0] name);
        integer w, bad;
        reg [31:0] v, cyc;
        begin
            $readmemh(file, exp);
            bad = 0;
            for (w = 0; w < 128; w = w + 1) begin
                bus_read(MEM + slot*128 + w, v);
                if (v !== exp[w]) begin
                    if (bad < 4) $display("  MISMATCH %0s word %0d: got %08h exp %08h", name, w, v, exp[w]);
                    bad = bad + 1;
                end
            end
            bus_read(R_CYC, cyc);
            tests = tests + 1;
            if (bad == 0) $display("[PASS] %-40s  (%0d cycles)", name, cyc);
            else begin $display("[FAIL] %-40s  %0d bad words", name, bad); errors = errors + 1; end
        end
    endtask

    reg [31:0] r;
    integer da, db, dd, i;
    initial begin
        $dumpfile("sim/tb_top.vcd"); $dumpvars(0, tb_top);
        repeat (5) @(posedge clk); rst_n <= 1; repeat (3) @(posedge clk);

        bus_read(R_ID, r);
        if (r !== 32'h4D4C4B31) begin $display("[FAIL] ID reg = %08h", r); errors = errors + 1; end
        else $display("[PASS] ID register");

        // ---- FNTT a,b ; PWM ; INTT  (FNTT -> PWM -> INTT chain stays inside the scratchpad)
        load_poly(0, "tb/vectors/a.hex");
        load_poly(1, "tb/vectors/b.hex");
        run_op(FNTT, 0, 0, 0, 0);  check_poly(0, "tb/vectors/ntt_a.hex", "FNTT(a)");
        run_op(FNTT, 1, 1, 1, 0);  check_poly(1, "tb/vectors/ntt_b.hex", "FNTT(b)");
        run_op(PWM,  0, 1, 2, 0);  check_poly(2, "tb/vectors/pwm_ab.hex", "PWM(NTT a, NTT b)");
        run_op(INTT, 2, 2, 2, 1);  check_poly(2, "tb/vectors/mul_ab.hex", "INTT+scale == a*b mod x^256+1");

        // ---- INTT roundtrip and unscaled INTT
        run_op(INTT, 0, 0, 0, 0);  check_poly(0, "tb/vectors/intt_raw_a.hex", "INTT (no scale)");
        load_poly(0, "tb/vectors/a.hex");
        run_op(FNTT, 0, 0, 0, 0);
        run_op(INTT, 0, 0, 0, 1);  check_poly(0, "tb/vectors/a.hex", "INTT(FNTT(a)) == a");

        // ---- standalone SCALE
        run_op(SCALE, 0, 0, 0, 0); check_poly(0, "tb/vectors/scale_a.hex", "SCALE (x128^-1)");

        // ---- ADD / SUB over every distinct slot pair (exercises both interleave patterns)
        for (da = 0; da < 4; da = da + 1)
          for (db = 0; db < 4; db = db + 1)
            if (da != db) begin
                dd = (da == 0 && db == 1) ? 2 : (da == 0 ? 1 : 0);
                if (dd == da || dd == db) dd = 3;
                if (dd == da || dd == db) dd = 2;
                load_poly(da, "tb/vectors/a.hex");
                load_poly(db, "tb/vectors/b.hex");
                run_op(ADD, da, db, dd, 0);
                check_poly(dd, "tb/vectors/add_ab.hex", "ADD slots");
                run_op(SUB, da, db, dd, 0);
                check_poly(dd, "tb/vectors/sub_ab.hex", "SUB slots");
            end

        // ---- corner-value polynomial FNTT / INTT
        load_poly(3, "tb/vectors/c.hex");
        run_op(FNTT, 3, 3, 3, 0); check_poly(3, "tb/vectors/ntt_c.hex", "FNTT(corner values)");
        run_op(INTT, 3, 3, 3, 1); check_poly(3, "tb/vectors/c.hex", "INTT(FNTT(c)) == c");

        // ---- error handling: ADD with identical source slots
        bus_write(R_OP, ADD); bus_write(R_SLOT, 0 | (0 << 2) | (1 << 4)); bus_write(R_CTRL, 1);
        repeat (6) @(posedge clk);
        bus_read(R_STATUS, r);
        tests = tests + 1;
        if (r[2]) $display("[PASS] ERR flag on ADD with SRC_A == SRC_B");
        else begin $display("[FAIL] ERR flag not set (STATUS=%08h)", r); errors = errors + 1; end

        $display("--------------------------------------------------");
        if (errors == 0) $display("ALL %0d TESTS PASSED", tests);
        else             $display("%0d / %0d TESTS FAILED", errors, tests);
        $finish;
    end

    initial begin #20_000_000; $display("TIMEOUT"); $finish; end
endmodule
