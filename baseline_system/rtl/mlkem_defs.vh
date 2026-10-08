// mlkem_defs.vh -- global constants for the ML-KEM polynomial coprocessor PoC
`ifndef MLKEM_DEFS_VH
`define MLKEM_DEFS_VH

`define MLKEM_Q        12'd3329     // q = 3329 = 13*2^8 + 1
`define MLKEM_INV128   12'd3303     // 128^-1 mod q (INTT final scaling)

// Operation / PE mode encoding (CSR OP[2:0])
`define MODE_FNTT      3'd0         // Cooley-Tukey forward NTT   (in-place on slot A)
`define MODE_INTT      3'd1         // Gentleman-Sande inverse NTT (in-place on slot A, optional x128^-1)
`define MODE_PWM       3'd2         // base-case pointwise mult    C = A o B
`define MODE_ADD       3'd3         // C = A + B
`define MODE_SUB       3'd4         // C = A - B
`define MODE_SCALE     3'd5         // A = A * 128^-1 (used internally by INTT)

`endif
