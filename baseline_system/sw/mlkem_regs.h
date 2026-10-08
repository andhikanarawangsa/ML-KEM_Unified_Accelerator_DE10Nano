/* mlkem_regs.h -- register map for the HPS driver (word offsets x4 = byte offsets) */
#ifndef MLKEM_REGS_H
#define MLKEM_REGS_H
#define MLKEM_ID        0x000   /* RO 0x4D4C4B31 */
#define MLKEM_CTRL      0x004   /* [0] START  [1] IRQ_EN */
#define MLKEM_STATUS    0x008   /* [0] BUSY   [1] DONE (W1C)  [2] ERR (W1C) */
#define MLKEM_OP        0x00C   /* [2:0] 0 FNTT 1 INTT 2 PWM 3 ADD 4 SUB  [3] INTT_SCALE_EN */
#define MLKEM_SLOT      0x010   /* [1:0] SRC_A [3:2] SRC_B [5:4] DST */
#define MLKEM_CYCLES    0x014   /* RO cycles of last op */
#define MLKEM_MEM       0x1000  /* 4 slots x 128 words; word = {coeff[2w+1], coeff[2w]} (16b each) */
#define MLKEM_MEM_ADDR(slot, w) (MLKEM_MEM + 4u * ((slot) * 128u + (w)))
#endif
