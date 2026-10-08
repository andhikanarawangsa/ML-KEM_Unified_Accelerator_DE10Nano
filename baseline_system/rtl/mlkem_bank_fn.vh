// mlkem_bank_fn.vh -- conflict-free bank mapping (include INSIDE a module body)
//
// Polynomial = 128 packed words (word w holds coeff 2w in [15:0], 2w+1 in [31:16]).
// 4 polynomial slots p = 0..3 share the 4 banks.
//   bank(p,w) = (p + w[1:0] + w[3:2] + w[5:4] + w[6]) mod 4,   addr = w
// Properties used by the controller:
//   * Two words whose indices differ in exactly one bit land in different banks
//     (delta = 1 for even bit position, 2 for odd position) -> NTT butterflies conflict-free.
//   * Same word of two different slots lands in different banks -> ADD/SUB/PWM conflict-free.
//   * (bank, addr) -> (p, w) is a bijection -> 4 x 128 x 32 bit = 4 x 256 x 16 bit capacity.
function [1:0] bank_of;
    input [1:0] p;
    input [6:0] w;
    reg   [4:0] s;
    begin
        s = {3'b0, w[1:0]} + {3'b0, w[3:2]} + {3'b0, w[5:4]} + {4'b0, w[6]} + {3'b0, p};
        bank_of = s[1:0];
    end
endfunction
