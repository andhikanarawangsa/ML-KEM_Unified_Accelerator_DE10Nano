// mlkem_ctrl.v -- Blok a: Top-Level Operation FSM + issue/schedule engine
//
// Per "group" (one scheduling step) the controller reads up to 4 words (8 coefficients) from
// 4 DIFFERENT banks in one cycle (conflict-free by construction, see mlkem_bank_fn.vh), routes
// them through a 4x4 crossbar into the 4 PEs, and later writes the results back in place.
//
//   FNTT/INTT : 32 groups/layer x 7 layers, 4 butterflies (2 word-pairs) per cycle
//   ADD/SUB   : 64 groups, 4 coefficient-pairs per cycle
//   SCALE     : 64 groups (run after INTT when scale_en)
//   PWM       : 32 groups x 5 cycles (each PE does 1 base-case product = 5 multiplier slots)
//
// Pipeline:  R (address) -> X (bank data + ROM data, crossbar, PE in_valid) -> PE -> W (write-back)
`include "mlkem_defs.vh"
module mlkem_ctrl (
    input  wire         clk,
    input  wire         rst_n,
    // CSR side
    input  wire         start,
    input  wire [2:0]   op,
    input  wire         scale_en,
    input  wire [1:0]   slot_a, slot_b, slot_d,
    output reg          busy,
    output reg          done_pulse,
    output reg          err,
    output reg  [31:0]  cycles,
    // scratchpad core side
    output reg  [3:0]   c_we,
    output reg  [27:0]  c_waddr,
    output reg  [127:0] c_wdata,
    output reg  [3:0]   c_re,
    output reg  [27:0]  c_raddr,
    input  wire [127:0] c_rdata,
    // twiddle ROM
    output reg  [6:0]   rom_a0,
    input  wire [11:0]  rom_q0,
    output reg  [6:0]   rom_a1,
    input  wire [11:0]  rom_q1,
    // arithmetic core
    output reg          core_valid,
    output reg  [2:0]   core_mode,
    output reg  [47:0]  a_bus, b_bus, c_bus, d_bus, z_bus,
    input  wire         core_out_valid,
    input  wire [47:0]  y0_bus, y1_bus
);
    `include "mlkem_bank_fn.vh"

    localparam [2:0] S_IDLE = 0, S_ISSUE = 1, S_WAIT_LAYER = 2, S_WAIT_LAST = 3, S_DONE = 4;
    reg [2:0] st;
    reg [2:0] cur_op;
    reg       scale_q;
    reg [1:0] sa, sb, sd;
    reg [2:0] layer;
    reg [5:0] grp;
    reg [2:0] beat;
    reg [5:0] outstanding;

    wire is_ntt   = (cur_op == `MODE_FNTT) || (cur_op == `MODE_INTT);
    wire is_pwm   = (cur_op == `MODE_PWM);
    wire is_vec   = (cur_op == `MODE_ADD)  || (cur_op == `MODE_SUB);
    wire is_scale = (cur_op == `MODE_SCALE);

    // ------------------------------------------------------------------ stage R (combinational)
    wire        issue_en = (st == S_ISSUE) && !(is_pwm && beat == 3'd4);

    wire [2:0]  k   = (cur_op == `MODE_FNTT) ? (3'd7 - layer) : (layer + 3'd1);   // len = 2^k
    wire [2:0]  kk  = (k < 3'd2) ? 3'd2 : k;
    wire [2:0]  sh  = kk - 3'd2;
    wire [6:0]  g5  = {2'b00, grp[4:0]};
    wire [6:0]  w0n = ((g5 >> sh) << kk) | (g5 & ((7'd1 << sh) - 7'd1));
    wire [6:0]  hh  = 7'd1 << (k - 3'd1);
    wire [6:0]  dd  = (k >= 3'd2) ? (7'd1 << (k - 3'd2)) : 7'd2;
    wire [6:0]  wA  = w0n, wB = w0n + dd, wC = w0n + hh, wD = w0n + hh + dd;
    wire [6:0]  blk = w0n >> k;
    wire [7:0]  idxA = (cur_op == `MODE_FNTT) ? ((8'd1 << (3'd7 - k)) + {1'b0, blk})
                                              : ((9'd256 >> k) - 9'd1 - {2'b0, blk});
    wire [7:0]  idxB = (k == 3'd1) ? ((cur_op == `MODE_FNTT) ? idxA + 8'd1 : idxA - 8'd1) : idxA;

    wire        e1   = ((sb - sa) == 2'd2);
    wire [6:0]  wv0  = is_scale ? {grp[5:0], 1'b0} :
                       e1       ? {grp[5:0], 1'b0} : {grp[5:1], 1'b0, grp[0]};
    wire [6:0]  wv1  = wv0 + ((is_scale || e1) ? 7'd1 : 7'd2);
    wire [6:0]  wpw  = {grp[4:0], 2'b00} + {5'b0, beat[1:0]};

    reg [6:0] rw  [0:3];
    reg [1:0] rp  [0:3];
    reg [3:0] ren;
    reg [6:0] ww  [0:3];
    reg [1:0] wp_ [0:3];
    reg [3:0] wval;
    integer s;
    always @* begin
        for (s = 0; s < 4; s = s + 1) begin rw[s] = 7'd0; rp[s] = 2'd0; ww[s] = 7'd0; wp_[s] = 2'd0; end
        ren = 4'b0000; wval = 4'b0000;
        rom_a0 = 7'd0; rom_a1 = 7'd0;
        if (is_ntt) begin
            rw[0] = wA; rw[1] = wB; rw[2] = wC; rw[3] = wD;
            for (s = 0; s < 4; s = s + 1) begin rp[s] = sa; ww[s] = rw[s]; wp_[s] = sa; end
            ren = 4'b1111; wval = 4'b1111;
            rom_a0 = idxA[6:0]; rom_a1 = idxB[6:0];
        end else if (is_vec) begin
            rw[0] = wv0; rp[0] = sa;  rw[1] = wv0; rp[1] = sb;
            rw[2] = wv1; rp[2] = sa;  rw[3] = wv1; rp[3] = sb;
            ren = 4'b1111;
            ww[0] = wv0; wp_[0] = sd; ww[1] = wv1; wp_[1] = sd; wval = 4'b0011;
        end else if (is_scale) begin
            rw[0] = wv0; rp[0] = sa;  rw[2] = wv1; rp[2] = sa;
            ren = 4'b0101;
            ww[0] = wv0; wp_[0] = sa; ww[1] = wv1; wp_[1] = sa; wval = 4'b0011;
        end else begin // PWM: one pair (A word, B word) per beat
            rw[0] = wpw; rp[0] = sa;  rw[1] = wpw; rp[1] = sb;
            ren = 4'b0011;
            ww[0] = wpw; wp_[0] = sd; wval = 4'b0001;
            rom_a0 = 7'd64 + {1'b0, wpw[6:1]};
        end
    end

    // bank read commands
    reg [1:0] rbank [0:3];
    integer b;
    always @* begin
        c_re = 4'b0; c_raddr = 28'd0;
        for (s = 0; s < 4; s = s + 1) rbank[s] = bank_of(rp[s], rw[s]);
        if (issue_en)
            for (s = 0; s < 4; s = s + 1)
                if (ren[s]) begin
                    c_re[rbank[s]] = 1'b1;
                    c_raddr[7*rbank[s] +: 7] = rw[s];
                end
    end

    // ------------------------------------------------------------------ R -> X pipeline registers
    reg        x_valid, x_last, x_odd;
    reg [2:0]  x_mode;
    reg [2:0]  x_beat;
    reg [7:0]  x_rbank;               // 4 x 2 bit: crossbar select per read slot
    reg [7:0]  x_wbank;
    reg [27:0] x_waddr;
    reg [3:0]  x_wval;
    always @(posedge clk) begin
        if (!rst_n) x_valid <= 1'b0;
        else        x_valid <= issue_en;
        x_mode  <= cur_op;
        x_beat  <= beat;
        x_last  <= (beat == 3'd3);
        x_odd   <= wpw[0];
        x_wval  <= wval;
        for (s = 0; s < 4; s = s + 1) begin
            x_rbank[2*s +: 2]  <= rbank[s];
            x_wbank[2*s +: 2]  <= bank_of(wp_[s], ww[s]);
            x_waddr[7*s +: 7]  <= ww[s];
        end
    end

    // ------------------------------------------------------------------ stage X
    wire [31:0] xw0 = c_rdata[32 * x_rbank[1:0]  +: 32];
    wire [31:0] xw1 = c_rdata[32 * x_rbank[3:2]  +: 32];
    wire [31:0] xw2 = c_rdata[32 * x_rbank[5:4]  +: 32];
    wire [31:0] xw3 = c_rdata[32 * x_rbank[7:6]  +: 32];

    // PWM operand staging (4 pairs gathered over 4 beats, fired together)
    reg [11:0] pa0 [0:3], pa1 [0:3], pb0 [0:3], pb1 [0:3], pz [0:3];
    reg [7:0]  pw_bank;
    reg [27:0] pw_addr;
    reg        p_fire;
    wire       x_pwm_beat = x_valid && (x_mode == `MODE_PWM);
    always @(posedge clk) begin
        if (!rst_n) p_fire <= 1'b0;
        else        p_fire <= x_pwm_beat && x_last;
        if (x_pwm_beat) begin
            pa0[x_beat[1:0]] <= xw0[11:0];
            pa1[x_beat[1:0]] <= xw0[27:16];
            pb0[x_beat[1:0]] <= xw1[11:0];
            pb1[x_beat[1:0]] <= xw1[27:16];
            pz [x_beat[1:0]] <= x_odd ? (12'd3329 - rom_q0) : rom_q0;
            pw_bank[2*x_beat[1:0] +: 2] <= x_wbank[1:0];
            pw_addr[7*x_beat[1:0] +: 7] <= x_waddr[6:0];
        end
    end

    always @* begin
        core_valid = p_fire | (x_valid && (x_mode != `MODE_PWM));
        core_mode  = p_fire ? `MODE_PWM : x_mode;
        a_bus = 48'd0; b_bus = 48'd0; c_bus = 48'd0; d_bus = 48'd0; z_bus = 48'd0;
        if (p_fire) begin
            for (s = 0; s < 4; s = s + 1) begin
                a_bus[12*s +: 12] = pa0[s];  b_bus[12*s +: 12] = pa1[s];
                c_bus[12*s +: 12] = pb0[s];  d_bus[12*s +: 12] = pb1[s];
                z_bus[12*s +: 12] = pz[s];
            end
        end else if (is_ntt_x(x_mode)) begin
            a_bus[11:0]  = xw0[11:0];  b_bus[11:0]  = xw2[11:0];
            a_bus[23:12] = xw0[27:16]; b_bus[23:12] = xw2[27:16];
            a_bus[35:24] = xw1[11:0];  b_bus[35:24] = xw3[11:0];
            a_bus[47:36] = xw1[27:16]; b_bus[47:36] = xw3[27:16];
            z_bus = {rom_q1, rom_q1, rom_q0, rom_q0};
        end else begin // ADD / SUB / SCALE
            a_bus[11:0]  = xw0[11:0];  b_bus[11:0]  = xw1[11:0];
            a_bus[23:12] = xw0[27:16]; b_bus[23:12] = xw1[27:16];
            a_bus[35:24] = xw2[11:0];  b_bus[35:24] = xw3[11:0];
            a_bus[47:36] = xw2[27:16]; b_bus[47:36] = xw3[27:16];
            z_bus = {4{`MLKEM_INV128}};
        end
    end
    function is_ntt_x; input [2:0] m;
        begin is_ntt_x = (m == `MODE_FNTT) || (m == `MODE_INTT); end endfunction

    // ------------------------------------------------------------------ write-descriptor FIFO
    reg [2:0]  f_mode [0:15];
    reg [3:0]  f_wval [0:15];
    reg [7:0]  f_wbank[0:15];
    reg [27:0] f_waddr[0:15];
    reg [3:0]  f_wp, f_rp;
    always @(posedge clk) begin
        if (!rst_n) begin f_wp <= 4'd0; f_rp <= 4'd0; end
        else begin
            if (core_valid) begin
                f_mode [f_wp] <= core_mode;
                f_wval [f_wp] <= p_fire ? 4'b1111 : x_wval;
                f_wbank[f_wp] <= p_fire ? pw_bank  : x_wbank;
                f_waddr[f_wp] <= p_fire ? pw_addr  : x_waddr;
                f_wp <= f_wp + 4'd1;
            end
            if (core_out_valid) f_rp <= f_rp + 4'd1;
        end
    end

    // ------------------------------------------------------------------ stage W (write-back)
    wire [2:0]  h_mode  = f_mode [f_rp];
    wire [3:0]  h_wval  = f_wval [f_rp];
    wire [7:0]  h_wbank = f_wbank[f_rp];
    wire [27:0] h_waddr = f_waddr[f_rp];
    reg  [31:0] wword [0:3];
    always @* begin
        for (s = 0; s < 4; s = s + 1) wword[s] = 32'd0;
        if (is_ntt_x(h_mode)) begin
            wword[0] = {4'b0, y0_bus[23:12],  4'b0, y0_bus[11:0]};
            wword[1] = {4'b0, y0_bus[47:36],  4'b0, y0_bus[35:24]};
            wword[2] = {4'b0, y1_bus[23:12],  4'b0, y1_bus[11:0]};
            wword[3] = {4'b0, y1_bus[47:36],  4'b0, y1_bus[35:24]};
        end else if (h_mode == `MODE_PWM) begin
            for (s = 0; s < 4; s = s + 1)
                wword[s] = {4'b0, y1_bus[12*s +: 12], 4'b0, y0_bus[12*s +: 12]};
        end else begin
            wword[0] = {4'b0, y0_bus[23:12],  4'b0, y0_bus[11:0]};
            wword[1] = {4'b0, y0_bus[47:36],  4'b0, y0_bus[35:24]};
        end
        c_we = 4'b0; c_waddr = 28'd0; c_wdata = 128'd0;
        if (core_out_valid)
            for (s = 0; s < 4; s = s + 1)
                if (h_wval[s]) begin
                    c_we[h_wbank[2*s +: 2]] = 1'b1;
                    c_waddr[7*h_wbank[2*s +: 2] +: 7]  = h_waddr[7*s +: 7];
                    c_wdata[32*h_wbank[2*s +: 2] +: 32] = wword[s];
                end
    end

    // ------------------------------------------------------------------ top-level FSM
    wire bad_cfg = (op > `MODE_SCALE) ||
                   ((op == `MODE_ADD || op == `MODE_SUB || op == `MODE_PWM) && (slot_a == slot_b));
    wire inc = issue_en && (!is_pwm || beat == 3'd3);
    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; busy <= 1'b0; done_pulse <= 1'b0; err <= 1'b0;
            outstanding <= 6'd0; cycles <= 32'd0;
            layer <= 3'd0; grp <= 6'd0; beat <= 3'd0; cur_op <= 3'd0;
        end else begin
            done_pulse <= 1'b0;
            outstanding <= outstanding + {5'b0, inc} - {5'b0, core_out_valid};
            if (busy) cycles <= cycles + 32'd1;
            case (st)
            S_IDLE: if (start) begin
                if (bad_cfg) begin err <= 1'b1; done_pulse <= 1'b1; end
                else begin
                    err <= 1'b0; busy <= 1'b1; cycles <= 32'd0;
                    cur_op <= op; scale_q <= scale_en; sa <= slot_a; sb <= slot_b; sd <= slot_d;
                    layer <= 3'd0; grp <= 6'd0; beat <= 3'd0; st <= S_ISSUE;
                end
            end
            S_ISSUE: begin
                if (is_pwm && beat == 3'd4) begin beat <= 3'd0; grp <= grp + 6'd1; end
                else if (issue_en) begin
                    if (is_ntt) begin
                        if (grp[4:0] == 5'd31) begin
                            grp <= 6'd0;
                            if (layer == 3'd6) st <= S_WAIT_LAST;
                            else begin layer <= layer + 3'd1; st <= S_WAIT_LAYER; end
                        end else grp <= grp + 6'd1;
                    end else if (is_pwm) begin
                        if (beat == 3'd3 && grp[4:0] == 5'd31) begin beat <= 3'd0; grp <= 6'd0; st <= S_WAIT_LAST; end
                        else if (beat == 3'd3) beat <= 3'd4;
                        else beat <= beat + 3'd1;
                    end else begin
                        if (grp == 6'd63) begin grp <= 6'd0; st <= S_WAIT_LAST; end
                        else grp <= grp + 6'd1;
                    end
                end
            end
            S_WAIT_LAYER: if (outstanding == 6'd0) st <= S_ISSUE;
            S_WAIT_LAST: if (outstanding == 6'd0) begin
                if (cur_op == `MODE_INTT && scale_q) begin
                    cur_op <= `MODE_SCALE; grp <= 6'd0; st <= S_ISSUE;
                end else st <= S_DONE;
            end
            S_DONE: begin busy <= 1'b0; done_pulse <= 1'b1; st <= S_IDLE; end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
