%include "ribbon.h.asm"



nop: ; 0000
    TODO



breakpoint: ; 0001
    jmp [FIBER + Fiber.breakpoint]



halt: ; 0002
    jmp R_EXIT_HALT



trap: ; 0003
    jmp R_TRAP_REQUESTED



unreachable: ; 0004
    jmp R_TRAP_REQUESTED



push_set: ; 0005 H___
    TODO


pop_set: ; 0006
    TODO


br: ; 0007 C___
    TODO


br_if: ; 0008 C___R_
    TODO


call: ; 0009 R_C___
    TODO


call_c: ; 000a F___C___
    TODO


call_builtin: ; 000b R_C___
    TODO


call_builtinc: ; 000c B___C___
    TODO


call_foreign: ; 000d R_C___
    TODO


call_foreignc: ; 000e X___C___
    TODO


call_v: ; 000f RxRyC___
    TODO


call_c_v: ; 0010 R_F___C___
    TODO


call_builtin_v: ; 0011 RxRyC___
    TODO


call_builtinc_v: ; 0012 R_B___C___
    TODO


call_foreign_v: ; 0013 RxRyC___
    TODO


call_foreignc_v: ; 0014 R_X___C___
    TODO


prompt: ; 0015 E___C___
    TODO


prompt_v: ; 0016 R_E___C___
    TODO


return: ; 0017
    TODO


return_v: ; 0018 R_
    TODO


cancel: ; 0019
    TODO


cancel_v: ; 001a R_
    TODO


mem_set: ; 001b RxRyRz
    TODO


mem_set_a: ; 001c RxRyC___
    TODO


mem_set_b: ; 001d RxRyC___
    TODO


mem_set_c: ; 001e R_Cx__Cy__
    TODO


mem_copy: ; 001f RxRyRz
    TODO


mem_copy_a: ; 0020 RxRyC___
    TODO


mem_copy_b: ; 0021 RxRyC___
    TODO


mem_copy_c: ; 0022 R_Cx__Cy__
    TODO


mem_swap: ; 0023 RxRyRz
    TODO


mem_swap_c: ; 0024 RxRyC___
    TODO


addr_l: ; 0025 R_C___
    TODO


addr_u: ; 0026 R_U_
    TODO


addr_g: ; 0027 R_G___
    TODO


addr_f: ; 0028 R_F___
    TODO


addr_b: ; 0029 R_B___
    TODO


addr_x: ; 002a R_X___
    TODO


addr_c: ; 002b R_C___
    TODO


load8: ; 002c RxRyC___
    TODO


load16: ; 002d RxRyC___
    TODO


load32: ; 002e RxRyC___
    TODO


load64: ; 002f RxRyC___
    TODO


load8c: ; 0030 R_C___
    TODO


load16c: ; 0031 R_C___
    TODO


load32c: ; 0032 R_C___
    TODO


load64c: ; 0033 R_C___
    TODO


store8: ; 0034 RxRyC___
    TODO


store16: ; 0035 RxRyC___
    TODO


store32: ; 0036 RxRyC___
    TODO


store64: ; 0037 RxRyC___
    TODO


store8c: ; 0038 R_Cx__Cy__
    TODO


store16c: ; 0039 R_Cx__Cy__
    TODO


store32c: ; 003a R_Cx__Cy__
    TODO


store64c: ; 003b R_Cx__Cy__
    TODO


bit_swap8: ; 003c RxRy
    TODO


bit_swap16: ; 003d RxRy
    TODO


bit_swap32: ; 003e RxRy
    TODO


bit_swap64: ; 003f RxRy
    TODO


bit_copy8: ; 0040 RxRy
    TODO


bit_copy16: ; 0041 RxRy
    TODO


bit_copy32: ; 0042 RxRy
    TODO


bit_copy64: ; 0043 RxRy
    TODO


bit_clz8: ; 0044 RxRy
    TODO


bit_clz16: ; 0045 RxRy
    TODO


bit_clz32: ; 0046 RxRy
    TODO


bit_clz64: ; 0047 RxRy
    TODO


bit_pop8: ; 0048 RxRy
    TODO


bit_pop16: ; 0049 RxRy
    TODO


bit_pop32: ; 004a RxRy
    TODO


bit_pop64: ; 004b RxRy
    TODO


bit_not8: ; 004c RxRy
    TODO


bit_not16: ; 004d RxRy
    TODO


bit_not32: ; 004e RxRy
    TODO


bit_not64: ; 004f RxRy
    TODO


bit_and8: ; 0050 RxRyRz
    TODO


bit_and16: ; 0051 RxRyRz
    TODO


bit_and32: ; 0052 RxRyRz
    TODO


bit_and64: ; 0053 RxRyRz
    TODO


bit_and8c: ; 0054 RxRyC___
    TODO


bit_and16c: ; 0055 RxRyC___
    TODO


bit_and32c: ; 0056 RxRyC___
    TODO


bit_and64c: ; 0057 RxRyC___
    TODO


bit_or8: ; 0058 RxRyRz
    TODO


bit_or16: ; 0059 RxRyRz
    TODO


bit_or32: ; 005a RxRyRz
    TODO


bit_or64: ; 005b RxRyRz
    TODO


bit_or8c: ; 005c RxRyC___
    TODO


bit_or16c: ; 005d RxRyC___
    TODO


bit_or32c: ; 005e RxRyC___
    TODO


bit_or64c: ; 005f RxRyC___
    TODO


bit_xor8: ; 0060 RxRyRz
    TODO


bit_xor16: ; 0061 RxRyRz
    TODO


bit_xor32: ; 0062 RxRyRz
    TODO


bit_xor64: ; 0063 RxRyRz
    TODO


bit_xor8c: ; 0064 RxRyC___
    TODO


bit_xor16c: ; 0065 RxRyC___
    TODO


bit_xor32c: ; 0066 RxRyC___
    TODO


bit_xor64c: ; 0067 RxRyC___
    TODO


bit_lshift8: ; 0068 RxRyRz
    TODO


bit_lshift16: ; 0069 RxRyRz
    TODO


bit_lshift32: ; 006a RxRyRz
    TODO


bit_lshift64: ; 006b RxRyRz
    TODO


bit_lshift8a: ; 006c RxRyC___
    TODO


bit_lshift16a: ; 006d RxRyC___
    TODO


bit_lshift32a: ; 006e RxRyC___
    TODO


bit_lshift64a: ; 006f RxRyC___
    TODO


bit_lshift8b: ; 0070 RxRyC___
    TODO


bit_lshift16b: ; 0071 RxRyC___
    TODO


bit_lshift32b: ; 0072 RxRyC___
    TODO


bit_lshift64b: ; 0073 RxRyC___
    TODO


u_rshift8: ; 0074 RxRyRz
    TODO


u_rshift16: ; 0075 RxRyRz
    TODO


u_rshift32: ; 0076 RxRyRz
    TODO


u_rshift64: ; 0077 RxRyRz
    TODO


u_rshift8a: ; 0078 RxRyC___
    TODO


u_rshift16a: ; 0079 RxRyC___
    TODO


u_rshift32a: ; 007a RxRyC___
    TODO


u_rshift64a: ; 007b RxRyC___
    TODO


u_rshift8b: ; 007c RxRyC___
    TODO


u_rshift16b: ; 007d RxRyC___
    TODO


u_rshift32b: ; 007e RxRyC___
    TODO


u_rshift64b: ; 007f RxRyC___
    TODO


s_rshift8: ; 0080 RxRyRz
    TODO


s_rshift16: ; 0081 RxRyRz
    TODO


s_rshift32: ; 0082 RxRyRz
    TODO


s_rshift64: ; 0083 RxRyRz
    TODO


s_rshift8a: ; 0084 RxRyC___
    TODO


s_rshift16a: ; 0085 RxRyC___
    TODO


s_rshift32a: ; 0086 RxRyC___
    TODO


s_rshift64a: ; 0087 RxRyC___
    TODO


s_rshift8b: ; 0088 RxRyC___
    TODO


s_rshift16b: ; 0089 RxRyC___
    TODO


s_rshift32b: ; 008a RxRyC___
    TODO


s_rshift64b: ; 008b RxRyC___
    TODO


i_eq8: ; 008c RxRyRz
    TODO


i_eq16: ; 008d RxRyRz
    TODO


i_eq32: ; 008e RxRyRz
    TODO


i_eq64: ; 008f RxRyRz
    TODO


i_eq8c: ; 0090 RxRyC___
    TODO


i_eq16c: ; 0091 RxRyC___
    TODO


i_eq32c: ; 0092 RxRyC___
    TODO


i_eq64c: ; 0093 RxRyC___
    TODO


f_eq32: ; 0094 RxRyRz
    TODO


f_eq64: ; 0095 RxRyRz
    TODO


i_ne8: ; 0096 RxRyRz
    TODO


i_ne16: ; 0097 RxRyRz
    TODO


i_ne32: ; 0098 RxRyRz
    TODO


i_ne64: ; 0099 RxRyRz
    TODO


i_ne8c: ; 009a RxRyC___
    TODO


i_ne16c: ; 009b RxRyC___
    TODO


i_ne32c: ; 009c RxRyC___
    TODO


i_ne64c: ; 009d RxRyC___
    TODO


f_ne32: ; 009e RxRyRz
    TODO


f_ne64: ; 009f RxRyRz
    TODO


u_lt8: ; 00a0 RxRyRz
    TODO


u_lt16: ; 00a1 RxRyRz
    TODO


u_lt32: ; 00a2 RxRyRz
    TODO


u_lt64: ; 00a3 RxRyRz
    TODO


u_lt8a: ; 00a4 RxRyC___
    TODO


u_lt16a: ; 00a5 RxRyC___
    TODO


u_lt32a: ; 00a6 RxRyC___
    TODO


u_lt64a: ; 00a7 RxRyC___
    TODO


u_lt8b: ; 00a8 RxRyC___
    TODO


u_lt16b: ; 00a9 RxRyC___
    TODO


u_lt32b: ; 00aa RxRyC___
    TODO


u_lt64b: ; 00ab RxRyC___
    TODO


s_lt8: ; 00ac RxRyRz
    TODO


s_lt16: ; 00ad RxRyRz
    TODO


s_lt32: ; 00ae RxRyRz
    TODO


s_lt64: ; 00af RxRyRz
    TODO


s_lt8a: ; 00b0 RxRyC___
    TODO


s_lt16a: ; 00b1 RxRyC___
    TODO


s_lt32a: ; 00b2 RxRyC___
    TODO


s_lt64a: ; 00b3 RxRyC___
    TODO


s_lt8b: ; 00b4 RxRyC___
    TODO


s_lt16b: ; 00b5 RxRyC___
    TODO


s_lt32b: ; 00b6 RxRyC___
    TODO


s_lt64b: ; 00b7 RxRyC___
    TODO


f_lt32: ; 00b8 RxRyRz
    TODO


f_lt32a: ; 00b9 RxRyC___
    TODO


f_lt32b: ; 00ba RxRyC___
    TODO


f_lt64: ; 00bb RxRyRz
    TODO


f_lt64a: ; 00bc RxRyC___
    TODO


f_lt64b: ; 00bd RxRyC___
    TODO


u_gt8: ; 00be RxRyRz
    TODO


u_gt16: ; 00bf RxRyRz
    TODO


u_gt32: ; 00c0 RxRyRz
    TODO


u_gt64: ; 00c1 RxRyRz
    TODO


u_gt8a: ; 00c2 RxRyC___
    TODO


u_gt16a: ; 00c3 RxRyC___
    TODO


u_gt32a: ; 00c4 RxRyC___
    TODO


u_gt64a: ; 00c5 RxRyC___
    TODO


u_gt8b: ; 00c6 RxRyC___
    TODO


u_gt16b: ; 00c7 RxRyC___
    TODO


u_gt32b: ; 00c8 RxRyC___
    TODO


u_gt64b: ; 00c9 RxRyC___
    TODO


s_gt8: ; 00ca RxRyRz
    TODO


s_gt16: ; 00cb RxRyRz
    TODO


s_gt32: ; 00cc RxRyRz
    TODO


s_gt64: ; 00cd RxRyRz
    TODO


s_gt8a: ; 00ce RxRyC___
    TODO


s_gt16a: ; 00cf RxRyC___
    TODO


s_gt32a: ; 00d0 RxRyC___
    TODO


s_gt64a: ; 00d1 RxRyC___
    TODO


s_gt8b: ; 00d2 RxRyC___
    TODO


s_gt16b: ; 00d3 RxRyC___
    TODO


s_gt32b: ; 00d4 RxRyC___
    TODO


s_gt64b: ; 00d5 RxRyC___
    TODO


f_gt32: ; 00d6 RxRyRz
    TODO


f_gt32a: ; 00d7 RxRyC___
    TODO


f_gt32b: ; 00d8 RxRyC___
    TODO


f_gt64: ; 00d9 RxRyRz
    TODO


f_gt64a: ; 00da RxRyC___
    TODO


f_gt64b: ; 00db RxRyC___
    TODO


u_le8: ; 00dc RxRyRz
    TODO


u_le16: ; 00dd RxRyRz
    TODO


u_le32: ; 00de RxRyRz
    TODO


u_le64: ; 00df RxRyRz
    TODO


u_le8a: ; 00e0 RxRyC___
    TODO


u_le16a: ; 00e1 RxRyC___
    TODO


u_le32a: ; 00e2 RxRyC___
    TODO


u_le64a: ; 00e3 RxRyC___
    TODO


u_le8b: ; 00e4 RxRyC___
    TODO


u_le16b: ; 00e5 RxRyC___
    TODO


u_le32b: ; 00e6 RxRyC___
    TODO


u_le64b: ; 00e7 RxRyC___
    TODO


s_le8: ; 00e8 RxRyRz
    TODO


s_le16: ; 00e9 RxRyRz
    TODO


s_le32: ; 00ea RxRyRz
    TODO


s_le64: ; 00eb RxRyRz
    TODO


s_le8a: ; 00ec RxRyC___
    TODO


s_le16a: ; 00ed RxRyC___
    TODO


s_le32a: ; 00ee RxRyC___
    TODO


s_le64a: ; 00ef RxRyC___
    TODO


s_le8b: ; 00f0 RxRyC___
    TODO


s_le16b: ; 00f1 RxRyC___
    TODO


s_le32b: ; 00f2 RxRyC___
    TODO


s_le64b: ; 00f3 RxRyC___
    TODO


f_le32: ; 00f4 RxRyRz
    TODO


f_le32a: ; 00f5 RxRyC___
    TODO


f_le32b: ; 00f6 RxRyC___
    TODO


f_le64: ; 00f7 RxRyRz
    TODO


f_le64a: ; 00f8 RxRyC___
    TODO


f_le64b: ; 00f9 RxRyC___
    TODO


u_ge8: ; 00fa RxRyRz
    TODO


u_ge16: ; 00fb RxRyRz
    TODO


u_ge32: ; 00fc RxRyRz
    TODO


u_ge64: ; 00fd RxRyRz
    TODO


u_ge8a: ; 00fe RxRyC___
    TODO


u_ge16a: ; 00ff RxRyC___
    TODO


u_ge32a: ; 0100 RxRyC___
    TODO


u_ge64a: ; 0101 RxRyC___
    TODO


u_ge8b: ; 0102 RxRyC___
    TODO


u_ge16b: ; 0103 RxRyC___
    TODO


u_ge32b: ; 0104 RxRyC___
    TODO


u_ge64b: ; 0105 RxRyC___
    TODO


s_ge8: ; 0106 RxRyRz
    TODO


s_ge16: ; 0107 RxRyRz
    TODO


s_ge32: ; 0108 RxRyRz
    TODO


s_ge64: ; 0109 RxRyRz
    TODO


s_ge8a: ; 010a RxRyC___
    TODO


s_ge16a: ; 010b RxRyC___
    TODO


s_ge32a: ; 010c RxRyC___
    TODO


s_ge64a: ; 010d RxRyC___
    TODO


s_ge8b: ; 010e RxRyC___
    TODO


s_ge16b: ; 010f RxRyC___
    TODO


s_ge32b: ; 0110 RxRyC___
    TODO


s_ge64b: ; 0111 RxRyC___
    TODO


f_ge32: ; 0112 RxRyRz
    TODO


f_ge32a: ; 0113 RxRyC___
    TODO


f_ge32b: ; 0114 RxRyC___
    TODO


f_ge64: ; 0115 RxRyRz
    TODO


f_ge64a: ; 0116 RxRyC___
    TODO


f_ge64b: ; 0117 RxRyC___
    TODO


s_neg8: ; 0118 RxRy
    TODO


s_neg16: ; 0119 RxRy
    TODO


s_neg32: ; 011a RxRy
    TODO


s_neg64: ; 011b RxRy
    TODO


s_abs8: ; 011c RxRy
    TODO


s_abs16: ; 011d RxRy
    TODO


s_abs32: ; 011e RxRy
    TODO


s_abs64: ; 011f RxRy
    TODO


i_add8: ; 0120 RxRyRz
    TODO


i_add16: ; 0121 RxRyRz
    TODO


i_add32: ; 0122 RxRyRz
    TODO


i_add64: ; 0123 RxRyRz
    TODO


i_add8c: ; 0124 RxRyC___
    TODO


i_add16c: ; 0125 RxRyC___
    TODO


i_add32c: ; 0126 RxRyC___
    TODO


i_add64c: ; 0127 RxRyC___
    TODO


i_sub8: ; 0128 RxRyRz
    TODO


i_sub16: ; 0129 RxRyRz
    TODO


i_sub32: ; 012a RxRyRz
    TODO


i_sub64: ; 012b RxRyRz
    TODO


i_sub8a: ; 012c RxRyC___
    TODO


i_sub16a: ; 012d RxRyC___
    TODO


i_sub32a: ; 012e RxRyC___
    TODO


i_sub64a: ; 012f RxRyC___
    TODO


i_sub8b: ; 0130 RxRyC___
    TODO


i_sub16b: ; 0131 RxRyC___
    TODO


i_sub32b: ; 0132 RxRyC___
    TODO


i_sub64b: ; 0133 RxRyC___
    TODO


i_mul8: ; 0134 RxRyRz
    TODO


i_mul16: ; 0135 RxRyRz
    TODO


i_mul32: ; 0136 RxRyRz
    TODO


i_mul64: ; 0137 RxRyRz
    TODO


i_mul8c: ; 0138 RxRyC___
    TODO


i_mul16c: ; 0139 RxRyC___
    TODO


i_mul32c: ; 013a RxRyC___
    TODO


i_mul64c: ; 013b RxRyC___
    TODO


u_i_div8: ; 013c RxRyRz
    TODO


u_i_div16: ; 013d RxRyRz
    TODO


u_i_div32: ; 013e RxRyRz
    TODO


u_i_div64: ; 013f RxRyRz
    TODO


u_i_div8a: ; 0140 RxRyC___
    TODO


u_i_div16a: ; 0141 RxRyC___
    TODO


u_i_div32a: ; 0142 RxRyC___
    TODO


u_i_div64a: ; 0143 RxRyC___
    TODO


u_i_div8b: ; 0144 RxRyC___
    TODO


u_i_div16b: ; 0145 RxRyC___
    TODO


u_i_div32b: ; 0146 RxRyC___
    TODO


u_i_div64b: ; 0147 RxRyC___
    TODO


s_i_div8: ; 0148 RxRyRz
    TODO


s_i_div16: ; 0149 RxRyRz
    TODO


s_i_div32: ; 014a RxRyRz
    TODO


s_i_div64: ; 014b RxRyRz
    TODO


s_i_div8a: ; 014c RxRyC___
    TODO


s_i_div16a: ; 014d RxRyC___
    TODO


s_i_div32a: ; 014e RxRyC___
    TODO


s_i_div64a: ; 014f RxRyC___
    TODO


s_i_div8b: ; 0150 RxRyC___
    TODO


s_i_div16b: ; 0151 RxRyC___
    TODO


s_i_div32b: ; 0152 RxRyC___
    TODO


s_i_div64b: ; 0153 RxRyC___
    TODO


u_i_rem8: ; 0154 RxRyRz
    TODO


u_i_rem16: ; 0155 RxRyRz
    TODO


u_i_rem32: ; 0156 RxRyRz
    TODO


u_i_rem64: ; 0157 RxRyRz
    TODO


u_i_rem8a: ; 0158 RxRyC___
    TODO


u_i_rem16a: ; 0159 RxRyC___
    TODO


u_i_rem32a: ; 015a RxRyC___
    TODO


u_i_rem64a: ; 015b RxRyC___
    TODO


u_i_rem8b: ; 015c RxRyC___
    TODO


u_i_rem16b: ; 015d RxRyC___
    TODO


u_i_rem32b: ; 015e RxRyC___
    TODO


u_i_rem64b: ; 015f RxRyC___
    TODO


s_i_rem8: ; 0160 RxRyRz
    TODO


s_i_rem16: ; 0161 RxRyRz
    TODO


s_i_rem32: ; 0162 RxRyRz
    TODO


s_i_rem64: ; 0163 RxRyRz
    TODO


s_i_rem8a: ; 0164 RxRyC___
    TODO


s_i_rem16a: ; 0165 RxRyC___
    TODO


s_i_rem32a: ; 0166 RxRyC___
    TODO


s_i_rem64a: ; 0167 RxRyC___
    TODO


s_i_rem8b: ; 0168 RxRyC___
    TODO


s_i_rem16b: ; 0169 RxRyC___
    TODO


s_i_rem32b: ; 016a RxRyC___
    TODO


s_i_rem64b: ; 016b RxRyC___
    TODO


i_pow8: ; 016c RxRyRz
    TODO


i_pow16: ; 016d RxRyRz
    TODO


i_pow32: ; 016e RxRyRz
    TODO


i_pow64: ; 016f RxRyRz
    TODO


i_pow8a: ; 0170 RxRyC___
    TODO


i_pow16a: ; 0171 RxRyC___
    TODO


i_pow32a: ; 0172 RxRyC___
    TODO


i_pow64a: ; 0173 RxRyC___
    TODO


i_pow8b: ; 0174 RxRyC___
    TODO


i_pow16b: ; 0175 RxRyC___
    TODO


i_pow32b: ; 0176 RxRyC___
    TODO


i_pow64b: ; 0177 RxRyC___
    TODO


f_neg32: ; 0178 RxRy
    TODO


f_neg64: ; 0179 RxRy
    TODO


f_abs32: ; 017a RxRy
    TODO


f_abs64: ; 017b RxRy
    TODO


f_sqrt32: ; 017c RxRy
    TODO


f_sqrt64: ; 017d RxRy
    TODO


f_floor32: ; 017e RxRy
    TODO


f_floor64: ; 017f RxRy
    TODO


f_ceil32: ; 0180 RxRy
    TODO


f_ceil64: ; 0181 RxRy
    TODO


f_round32: ; 0182 RxRy
    TODO


f_round64: ; 0183 RxRy
    TODO


f_trunc32: ; 0184 RxRy
    TODO


f_trunc64: ; 0185 RxRy
    TODO


f_man32: ; 0186 RxRy
    TODO


f_man64: ; 0187 RxRy
    TODO


f_frac32: ; 0188 RxRy
    TODO


f_frac64: ; 0189 RxRy
    TODO


f_add32: ; 018a RxRyRz
    TODO


f_add32c: ; 018b RxRyC___
    TODO


f_add64: ; 018c RxRyRz
    TODO


f_add64c: ; 018d RxRyC___
    TODO


f_sub32: ; 018e RxRyRz
    TODO


f_sub32a: ; 018f RxRyC___
    TODO


f_sub32b: ; 0190 RxRyC___
    TODO


f_sub64: ; 0191 RxRyRz
    TODO


f_sub64a: ; 0192 RxRyC___
    TODO


f_sub64b: ; 0193 RxRyC___
    TODO


f_mul32: ; 0194 RxRyRz
    TODO


f_mul32c: ; 0195 RxRyC___
    TODO


f_mul64: ; 0196 RxRyRz
    TODO


f_mul64c: ; 0197 RxRyC___
    TODO


f_div32: ; 0198 RxRyRz
    TODO


f_div32a: ; 0199 RxRyC___
    TODO


f_div32b: ; 019a RxRyC___
    TODO


f_div64: ; 019b RxRyRz
    TODO


f_div64a: ; 019c RxRyC___
    TODO


f_div64b: ; 019d RxRyC___
    TODO


f_rem32: ; 019e RxRyRz
    TODO


f_rem32a: ; 019f RxRyC___
    TODO


f_rem32b: ; 01a0 RxRyC___
    TODO


f_rem64: ; 01a1 RxRyRz
    TODO


f_rem64a: ; 01a2 RxRyC___
    TODO


f_rem64b: ; 01a3 RxRyC___
    TODO


f_pow32: ; 01a4 RxRyRz
    TODO


f_pow32a: ; 01a5 RxRyC___
    TODO


f_pow32b: ; 01a6 RxRyC___
    TODO


f_pow64: ; 01a7 RxRyRz
    TODO


f_pow64a: ; 01a8 RxRyC___
    TODO


f_pow64b: ; 01a9 RxRyC___
    TODO


s_ext8_16: ; 01aa RxRy
    TODO


s_ext8_32: ; 01ab RxRy
    TODO


s_ext8_64: ; 01ac RxRy
    TODO


s_ext16_32: ; 01ad RxRy
    TODO


s_ext16_64: ; 01ae RxRy
    TODO


s_ext32_64: ; 01af RxRy
    TODO


f32_to_u8: ; 01b0 RxRy
    TODO


f32_to_u16: ; 01b1 RxRy
    TODO


f32_to_u32: ; 01b2 RxRy
    TODO


f32_to_u64: ; 01b3 RxRy
    TODO


f32_to_s8: ; 01b4 RxRy
    TODO


f32_to_s16: ; 01b5 RxRy
    TODO


f32_to_s32: ; 01b6 RxRy
    TODO


f32_to_s64: ; 01b7 RxRy
    TODO


u8_to_f32: ; 01b8 RxRy
    TODO


u16_to_f32: ; 01b9 RxRy
    TODO


u32_to_f32: ; 01ba RxRy
    TODO


u64_to_f32: ; 01bb RxRy
    TODO


s8_to_f32: ; 01bc RxRy
    TODO


s16_to_f32: ; 01bd RxRy
    TODO


s32_to_f32: ; 01be RxRy
    TODO


s64_to_f32: ; 01bf RxRy
    TODO


u8_to_f64: ; 01c0 RxRy
    TODO


u16_to_f64: ; 01c1 RxRy
    TODO


u32_to_f64: ; 01c2 RxRy
    TODO


u64_to_f64: ; 01c3 RxRy
    TODO


s8_to_f64: ; 01c4 RxRy
    TODO


s16_to_f64: ; 01c5 RxRy
    TODO


s32_to_f64: ; 01c6 RxRy
    TODO


s64_to_f64: ; 01c7 RxRy
    TODO


f32_to_f64: ; 01c8 RxRy
    TODO


f64_to_f32: ; 01c9 RxRy
    TODO
