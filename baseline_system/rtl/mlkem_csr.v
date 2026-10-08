// mlkem_csr.v -- Blok a (bagian bus): Avalon-MM slave, CSR + polynomial memory window
//
// Word addresses (avs_address[10:0], 32-bit data):
//   0x000 ID      RO  32'h4D4C4B31 ("MLK1")
//   0x001 CTRL    RW  [0] START (write 1, self-clearing)  [1] IRQ_EN
//   0x002 STATUS  RW  [0] BUSY (RO)  [1] DONE (W1C)  [2] ERR (W1C)
//   0x003 OP      RW  [2:0] MODE (0 FNTT,1 INTT,2 PWM,3 ADD,4 SUB)  [3] INTT_SCALE_EN
//   0x004 SLOT    RW  [1:0] SRC_A  [3:2] SRC_B  [5:4] DST
//   0x005 CYCLES  RO  cycle count of the last operation
//   0x400..0x5FF  MEM RW  polynomial window: addr[8:7]=slot, addr[6:0]=word (2 packed coeffs)
//                     (accessible only while BUSY=0; PoC replacement for the DMA path)
// Read latency: 1 cycle, signalled with avs_readdatavalid (Avalon pipelined read).
module mlkem_csr (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [10:0] avs_address,
    input  wire        avs_read,
    input  wire        avs_write,
    input  wire [31:0] avs_writedata,
    output reg  [31:0] avs_readdata,
    output reg         avs_readdatavalid,
    output wire        irq,
    // to controller
    output reg         start,
    output wire [2:0]  op,
    output wire        scale_en,
    output wire [1:0]  slot_a, slot_b, slot_d,
    input  wire        busy,
    input  wire        done_pulse,
    input  wire        err_in,
    input  wire [31:0] cycles,
    // to scratchpad host port
    output wire        h_we,
    output wire        h_re,
    output wire [1:0]  h_slot,
    output wire [6:0]  h_word,
    output wire [31:0] h_wdata,
    input  wire [31:0] h_rdata
);
    reg        irq_en, done_q, err_q;
    reg [3:0]  op_r;
    reg [5:0]  slot_r;
    assign op       = op_r[2:0];
    assign scale_en = op_r[3];
    assign slot_a   = slot_r[1:0];
    assign slot_b   = slot_r[3:2];
    assign slot_d   = slot_r[5:4];
    assign irq      = irq_en & done_q;

    wire is_mem = (avs_address[10:9] == 2'b10);   // exactly 0x400..0x5FF (no aliasing)
    assign h_we    = avs_write && is_mem && !busy;
    assign h_re    = avs_read  && is_mem && !busy;
    assign h_slot  = avs_address[8:7];
    assign h_word  = avs_address[6:0];
    assign h_wdata = avs_writedata;

    reg        rd_mem, rd_blocked;
    reg [31:0] rd_reg;

    always @(posedge clk) begin
        if (!rst_n) begin
            start <= 1'b0; irq_en <= 1'b0; done_q <= 1'b0; err_q <= 1'b0;
            op_r <= 4'd0; slot_r <= 6'd0; avs_readdatavalid <= 1'b0;
            rd_mem <= 1'b0; rd_blocked <= 1'b0; rd_reg <= 32'd0;
        end else begin
            start <= 1'b0;
            if (done_pulse) begin done_q <= 1'b1; if (err_in) err_q <= 1'b1; end
            // ---- writes
            if (avs_write && !is_mem && !avs_address[10]) begin
                case (avs_address[3:0])
                    4'h1: if (busy) begin if (avs_writedata[0]) err_q <= 1'b1; end   // START while BUSY -> ERR
                          else begin start <= avs_writedata[0]; irq_en <= avs_writedata[1];
                                if (avs_writedata[0]) begin done_q <= 1'b0; err_q <= 1'b0; end end
                    4'h2: begin if (avs_writedata[1]) done_q <= 1'b0; if (avs_writedata[2]) err_q <= 1'b0; end
                    4'h3: if (busy) err_q <= 1'b1; else op_r   <= avs_writedata[3:0];
                    4'h4: if (busy) err_q <= 1'b1; else slot_r <= avs_writedata[5:0];
                    default: ;
                endcase
            end
            if (avs_write && is_mem && busy) err_q <= 1'b1;   // access violation
            // ---- reads (1-cycle latency)
            avs_readdatavalid <= avs_read;
            rd_mem     <= avs_read && is_mem;
            rd_blocked <= avs_read && is_mem && busy;
            case (avs_address[3:0])
                4'h0: rd_reg <= 32'h4D4C4B31;
                4'h1: rd_reg <= {30'd0, irq_en, 1'b0};
                4'h2: rd_reg <= {29'd0, err_q, done_q, busy};
                4'h3: rd_reg <= {28'd0, op_r};
                4'h4: rd_reg <= {26'd0, slot_r};
                4'h5: rd_reg <= cycles;
                default: rd_reg <= 32'd0;
            endcase
        end
    end

    always @* begin
        if (rd_blocked)  avs_readdata = 32'hBAD0BAD0;
        else if (rd_mem) avs_readdata = h_rdata;
        else             avs_readdata = rd_reg;
    end
endmodule
