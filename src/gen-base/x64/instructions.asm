%include "ribbon.h.asm"



nop: ; 0000  No operation
    jmp R_DECODE

breakpoint: ; 0001  Triggers a breakpoint in debuggers; does nothing otherwise
    jmp [FIBER + Fiber.breakpoint]

halt: ; 0002  Halts execution at this instruction offset
    jmp R_EXIT_HALT

trap: ; 0003  Traps execution of the `Rvm.Fiber` at this instruction offset  Unlike `unreachable`, this indicates expected behavior; optimizing compilers should *not* assume it is never reached
    jmp R_TRAP_REQUESTED

unreachable: ; 0004  Marks a point in the code as unreachable; if executed in Rvm, it is the same as `trap`  Unlike `trap`, however, this indicates undefined behavior; optimizing compilers should assume it is never reached
    jmp R_TRAP_REQUESTED



push_set: ; 0005 H___ Pushes `H` onto the stack.  The handlers in this set will be first in line for their effects' prompts until a corresponding `pop` operation.
    ; increment and check the stack pointer
    inc qword [FIBER + Fiber.sets]
    mov AUX1, [FIBER + Fiber.sets]
    cmp AUX1, [FIBER + Fiber.sets.limit]
    jg R_TRAP_OVERFLOW

    ; the value in AUX1 is a pointer to an uninitialized core.SetFrame
    ; we need to initialize its fields: SetFrame.call, SetFrame.handler_set, SetFrame.data

    ; call and data are easy, just need the current call frame
    mov [AUX1 + SetFrame.call], FRAME
    mem2mem [AUX1 + SetFrame.data], [FRAME + CallFrame.data]

    ; we need to access CallFrame.function, then Function.header,
    ; then Header.addresses
    ; then AddressTable.handler_sets
    ; moving the handler_set at our offset H into AUX2
    mov AUX2, [FRAME + CallFrame.function] ; *core.Function
    mov AUX2, [AUX2 + Function.header] ; *core.Header
    mov AUX2, [AUX2 + Header.addresses + AddressTable.handler_sets] ; Id.Buffer(HandlerSet)
    ; need to drop the most significant 16 bits of AUX2 to mask out the length from the pointer
    shr AUX2, 16 ; [*]core.HandlerSet
    ; only one operand so we don't need to mask off TER_B before use
    mov AUX2, [AUX2 + TER_B] ; *core.HandlerSet
    ; put the pointer to the handler_set in the SetFrame.handler_set field
    mov [AUX1 + SetFrame.handler_set], AUX2

    ; TODO: seems like we could avoid the stack copy;
    ;       given that we have begun placing frame-specific data into handler sets??
    ;       think i may be confusing myself on this one

    ; we need to push all the evidence from this effect handler set
    ; the current evidence are layed out by id in Fiber.evidence
    ; we need to create stack entries for each of the handlers in our set,
    ; initialize them with core.Evidence, and link them to the previous evidence,
    ; finally replacing the previous evidence with ours on the stack.

    ; FIXME: we dont actually have the ev buffer yet lol
    ; mov AUX1, [FIBER + Fiber.evidence] ; [*]core.Evidence

    ; evidence_push_loop:
    ;     mov AUX3, [AUX1 + ]



pop_set: ; 0006  Pops the top most `Id.of(HandlerSet)` from the stack, restoring the old one if there was any
    ; decrement and check the stack pointer
    mov AUX1, [FIBER + Fiber.sets]
    dec qword [FIBER + Fiber.sets]
    cmp AUX1, [FIBER + Fiber.sets.base]
    jl R_TRAP_UNDERFLOW

    ; the value in AUX1 is a pointer to the core.SetFrame we just popped
    ; we need to restore the handlers in the previous set



br: ; 0007 C___ Applies a signed integer offset `C` to the instruction pointer
    TODO


br_if: ; 0008 C___R_ Applies a signed integer offset `C` to the instruction pointer, if the value stored in `R` is non-zero
    TODO



call: ; 0009 R_C___ Calls the function in `R`
    TODO


call_c: ; 000a F___C___ Calls the function at `F`
    TODO


call_builtin: ; 000b R_C___ Calls the builtin function in `R`
    TODO


call_builtinc: ; 000c B___C___ Calls the builtin function at `B`
    TODO


call_foreign: ; 000d R_C___ Calls the C ABI function in `R`
    TODO


call_foreignc: ; 000e X___C___ Calls the C ABI function at `X`
    TODO


call_v: ; 000f RxRyC___ Calls the function in `Ry`, placing the result in `Rx`
    TODO


call_c_v: ; 0010 R_F___C___ Calls the function at `F`, placing the result in `R`
    TODO


call_builtin_v: ; 0011 RxRyC___ Calls the builtin function in `Ry`, placing the result in `Rx`
    TODO


call_builtinc_v: ; 0012 R_B___C___ Calls the builtin function at `B`, placing the result in `R`
    TODO


call_foreign_v: ; 0013 RxRyC___ Calls the C ABI function in `Ry`, placing the result in `Rx`
    TODO


call_foreignc_v: ; 0014 R_X___C___ Calls the C ABI function at `X`, placing the result in `R`
    TODO


prompt: ; 0015 E___C___ Calls the effect handler designated by `E`
    TODO


prompt_v: ; 0016 R_E___C___ Calls the effect handler designated by `E`, placing the result in `R`
    TODO



return: ; 0017  Returns flow control to the caller of current function
    TODO


return_v: ; 0018 R_ Returns flow control to the caller of current function, yielding `R` to the caller
    TODO


cancel: ; 0019  Returns flow control to the offset associated with the current effect handler's `Id.of(HandlerSet)`
    TODO


cancel_v: ; 001a R_ Returns flow control to the offset associated with the current effect handler's `Id.of(HandlerSet)`, yielding `R` as the cancellation value
    TODO




mem_set: ; 001b RxRyRz Each byte, starting from the address in `Rx`, up to an offset of `Rz`, is set to the least significant byte of `Ry`
    TODO


mem_set_a: ; 001c RxRyC___ Each byte, starting from the address in `Rx`, up to an offset of `Ry`, is set to the least significant byte of `C`
    TODO


mem_set_b: ; 001d RxRyC___ Each byte, starting from the address in `Rx`, up to an offset of `C`, is set to the least significant byte of `Ry`
    TODO


mem_set_c: ; 001e R_Cx__Cy__ Each byte, starting from the address in `R`, up to an offset of `Cy`, is set to the least significant byte of `Cx`
    TODO



mem_copy: ; 001f RxRyRz Each byte, starting from the address in `Ry`, up to an offset of `Rz`, is copied to the same offset of the address in `Rx`
    TODO


mem_copy_a: ; 0020 RxRyC___ Each byte, starting from the address of `C`, up to an offset of `Ry`, is copied to the same offset from the address in `Rx`
    TODO


mem_copy_b: ; 0021 RxRyC___ Each byte, starting from the address in `Ry`, up to an offset of `C`, is copied to the same offset from the address in `Rx`
    TODO


mem_copy_c: ; 0022 R_Cx__Cy__ Each byte, starting from the address of `Cx`, up to an offset of `Cy`, is copied to the same offset from the address in `R`
    TODO



mem_swap: ; 0023 RxRyRz Each byte, starting from the addresses in `Rx` and `Ry`, up to an offset of `Rz`, are swapped with each-other
    TODO


mem_swap_c: ; 0024 RxRyC___ Each byte, starting from the addresses in `Rx` and `Ry`, up to an offset of `C`, are swapped with each-other
    TODO



addr_l: ; 0025 R_C___ Get the address of a signed integer frame-relative operand stack offset `C`, placing it in `R`.  An operand stack offset of 1 is equivalent to 8 bytes down from the base of the stack frame
    TODO


addr_u: ; 0026 R_U_ Get the address of `U`, placing it in `R`
    TODO


addr_g: ; 0027 R_G___ Get the address of `G`, placing it in `R`
    TODO


addr_f: ; 0028 R_F___ Get the address of `F`, placing it in `R`
    TODO


addr_b: ; 0029 R_B___ Get the address of `B`, placing it in `R`
    TODO


addr_x: ; 002a R_X___ Get the address of `X`, placing it in `R`
    TODO


addr_c: ; 002b R_C___ Get the address of `C`, placing it in `R`
    TODO



load8: ; 002c RxRyC___ Loads an 8-bit value from memory at the address in `Ry` offset by `C`, placing the result in `Rx`
    TODO


load16: ; 002d RxRyC___ Loads a 16-bit value from memory at the address in `Ry` offset by `C`, placing the result in `Rx`
    TODO


load32: ; 002e RxRyC___ Loads a 32-bit value from memory at the address in `Ry` offset by `C`, placing the result in `Rx`
    TODO


load64: ; 002f RxRyC___ Loads a 64-bit value from memory at the address in `Ry` offset by `C`, placing the result in `Rx`
    TODO


load8c: ; 0030 R_C___ Loads an 8-bit `C` into `R`
    TODO


load16c: ; 0031 R_C___ Loads a 16-bit `C` into `R`
    TODO


load32c: ; 0032 R_C___ Loads a 32-bit `C` into `R`
    TODO


load64c: ; 0033 R_C___ Loads a 64-bit `C` into `R`
    TODO



store8: ; 0034 RxRyC___ Stores an 8-bit value from `Ry` to memory at the address in `Rx` offset by `C`
    TODO


store16: ; 0035 RxRyC___ Stores a 16-bit value from `Ry` to memory at the address in `Rx` offset by `C`
    TODO


store32: ; 0036 RxRyC___ Stores a 32-bit value from `Ry` to memory at the address in `Rx` offset by `C`
    TODO


store64: ; 0037 RxRyC___ Stores a 64-bit value from `Ry` to memory at the address in `Rx` offset by `C`
    TODO


store8c: ; 0038 R_Cx__Cy__ Stores an 8-bit `Cx` to memory at the address in `R` offset by `Cy`
    TODO


store16c: ; 0039 R_Cx__Cy__ Stores a 16-bit `Cx` to memory at the address in `R` offset by `Cy`
    TODO


store32c: ; 003a R_Cx__Cy__ Stores a 32-bit `Cx` to memory at the address in `R` offset by `Cy`
    TODO


store64c: ; 003b R_Cx__Cy__ Stores a 64-bit `Cx` to memory at the address in `R` offset by `Cy`
    TODO




bit_swap8: ; 003c RxRy 8-bit `Rx` *xor_swap* `Ry`
    TODO


bit_swap16: ; 003d RxRy 16-bit `Rx` *xor_swap* `Ry`
    TODO


bit_swap32: ; 003e RxRy 32-bit `Rx` *xor_swap* `Ry`
    TODO


bit_swap64: ; 003f RxRy 64-bit `Rx` *xor_swap* `Ry`
    TODO



bit_copy8: ; 0040 RxRy 8-bit `Rx` = `Ry`
    TODO


bit_copy16: ; 0041 RxRy 16-bit `Rx` = `Ry`
    TODO


bit_copy32: ; 0042 RxRy 32-bit `Rx` = `Ry`
    TODO


bit_copy64: ; 0043 RxRy 64-bit `Rx` = `Ry`
    TODO



bit_clz8: ; 0044 RxRy Counts the leading zeroes in 8-bits of `Ry`, placing the result in `Rx`
    TODO


bit_clz16: ; 0045 RxRy Counts the leading zeroes in 16-bits of `Ry`, placing the result in `Rx`
    TODO


bit_clz32: ; 0046 RxRy Counts the leading zeroes in 32-bits of `Ry`, placing the result in `Rx`
    TODO


bit_clz64: ; 0047 RxRy Counts the leading zeroes in 64-bits of `Ry`, placing the result in `Rx`
    TODO



bit_pop8: ; 0048 RxRy Counts the set bits in 8-bits of `Ry`, placing the result in `Rx`
    TODO


bit_pop16: ; 0049 RxRy Counts the set bits in 16-bits of `Ry`, placing the result in `Rx`
    TODO


bit_pop32: ; 004a RxRy Counts the set bits in 32-bits of `Ry`, placing the result in `Rx`
    TODO


bit_pop64: ; 004b RxRy Counts the set bits in 64-bits of `Ry`, placing the result in `Rx`
    TODO



bit_not8: ; 004c RxRy 8-bit `Rx` = *not* `Ry`
    TODO


bit_not16: ; 004d RxRy 16-bit `Rx` = *not* `Ry`
    TODO


bit_not32: ; 004e RxRy 32-bit `Rx` = *not* `Ry`
    TODO


bit_not64: ; 004f RxRy 64-bit `Rx` = *not* `Ry`
    TODO



bit_and8: ; 0050 RxRyRz 8-bit `Rx` = `Ry` *and* `Rz`
    TODO


bit_and16: ; 0051 RxRyRz 6-bit `Rx` = `Ry` *and* `Rz`
    TODO


bit_and32: ; 0052 RxRyRz 32-bit `Rx` = `Ry` *and* `Rz`
    TODO


bit_and64: ; 0053 RxRyRz 64-bit `Rx` = `Ry` *and* `Rz`
    TODO


bit_and8c: ; 0054 RxRyC___ 8-bit `Rx` = `Ry` *and* `C`
    TODO


bit_and16c: ; 0055 RxRyC___ 6-bit `Rx` = `Ry` *and* `C`
    TODO


bit_and32c: ; 0056 RxRyC___ 32-bit `Rx` = `Ry` *and* `C`
    TODO


bit_and64c: ; 0057 RxRyC___ 64-bit `Rx` = `Ry` *and* `C`
    TODO



bit_or8: ; 0058 RxRyRz 8-bit `Rx` = `Ry` *and* `Rz`
    TODO


bit_or16: ; 0059 RxRyRz 16-bit `Rx` = `Ry` *and* `Rz`
    TODO


bit_or32: ; 005a RxRyRz 32-bit `Rx` = `Ry` *and* `Rz`
    TODO


bit_or64: ; 005b RxRyRz 64-bit `Rx` = `Ry` *and* `Rz`
    TODO


bit_or8c: ; 005c RxRyC___ 8-bit `Rx` = `Ry` *or* `C`
    TODO


bit_or16c: ; 005d RxRyC___ 16-bit `Rx` = `Ry` *or* `C`
    TODO


bit_or32c: ; 005e RxRyC___ 32-bit `Rx` = `Ry` *or* `C`
    TODO


bit_or64c: ; 005f RxRyC___ 64-bit `Rx` = `Ry` *or* `C`
    TODO



bit_xor8: ; 0060 RxRyRz 8-bit `Rx` = `Ry` *xor* `Rz`
    TODO


bit_xor16: ; 0061 RxRyRz 16-bit `Rx` = `Ry` *xor* `Rz`
    TODO


bit_xor32: ; 0062 RxRyRz 32-bit `Rx` = `Ry` *xor* `Rz`
    TODO


bit_xor64: ; 0063 RxRyRz 64-bit `Rx` = `Ry` *xor* `Rz`
    TODO


bit_xor8c: ; 0064 RxRyC___ 8-bit `Rx` = `Ry` *xor* `C`
    TODO


bit_xor16c: ; 0065 RxRyC___ 16-bit `Rx` = `Ry` *xor* `C`
    TODO


bit_xor32c: ; 0066 RxRyC___ 32-bit `Rx` = `Ry` *xor* `C`
    TODO


bit_xor64c: ; 0067 RxRyC___ 64-bit `Rx` = `Ry` *xor* `C`
    TODO



bit_lshift8: ; 0068 RxRyRz 8-bit `Rx` = `Ry` << `Rz`
    TODO


bit_lshift16: ; 0069 RxRyRz 16-bit `Rx` = `Ry` << `Rz`
    TODO


bit_lshift32: ; 006a RxRyRz 32-bit `Rx` = `Ry` << `Rz`
    TODO


bit_lshift64: ; 006b RxRyRz 64-bit `Rx` = `Ry` << `Rz`
    TODO


bit_lshift8a: ; 006c RxRyC___ 8-bit `Rx` = `C` << `Ry`
    TODO


bit_lshift16a: ; 006d RxRyC___ 16-bit `Rx` = `C` << `Ry`
    TODO


bit_lshift32a: ; 006e RxRyC___ 32-bit `Rx` = `C` << `Ry`
    TODO


bit_lshift64a: ; 006f RxRyC___ 64-bit `Rx` = `C` << `Ry`
    TODO


bit_lshift8b: ; 0070 RxRyC___ 8-bit `Rx` = `Ry` << `C`
    TODO


bit_lshift16b: ; 0071 RxRyC___ 16-bit `Rx` = `Ry` << `C`
    TODO


bit_lshift32b: ; 0072 RxRyC___ 32-bit `Rx` = `Ry` << `C`
    TODO


bit_lshift64b: ; 0073 RxRyC___ 64-bit `Rx` = `Ry` << `C`
    TODO



u_rshift8: ; 0074 RxRyRz 8-bit unsigned/logical `Rx` = `Ry` >> `Rz`
    TODO


u_rshift16: ; 0075 RxRyRz 16-bit unsigned/logical `Rx` = `Ry` >> `Rz`
    TODO


u_rshift32: ; 0076 RxRyRz 32-bit unsigned/logical `Rx` = `Ry` >> `Rz`
    TODO


u_rshift64: ; 0077 RxRyRz 64-bit unsigned/logical `Rx` = `Ry` >> `Rz`
    TODO


u_rshift8a: ; 0078 RxRyC___ 8-bit unsigned/logical `Rx` = `C` >> `Ry`
    TODO


u_rshift16a: ; 0079 RxRyC___ 16-bit unsigned/logical `Rx` = `C` >> `Ry`
    TODO


u_rshift32a: ; 007a RxRyC___ 32-bit unsigned/logical `Rx` = `C` >> `Ry`
    TODO


u_rshift64a: ; 007b RxRyC___ 64-bit unsigned/logical `Rx` = `C` >> `Ry`
    TODO


u_rshift8b: ; 007c RxRyC___ 8-bit unsigned/logical `Rx` = `Ry` >> `C`
    TODO


u_rshift16b: ; 007d RxRyC___ 16-bit unsigned/logical `Rx` = `Ry` >> `C`
    TODO


u_rshift32b: ; 007e RxRyC___ 32-bit unsigned/logical `Rx` = `Ry` >> `C`
    TODO


u_rshift64b: ; 007f RxRyC___ 64-bit unsigned/logical `Rx` = `Ry` >> `C`
    TODO


s_rshift8: ; 0080 RxRyRz 8-bit signed/arithmetic `Rx` = `Ry` >> `Rz`
    TODO


s_rshift16: ; 0081 RxRyRz 16-bit signed/arithmetic `Rx` = `Ry` >> `Rz`
    TODO


s_rshift32: ; 0082 RxRyRz 32-bit signed/arithmetic `Rx` = `Ry` >> `Rz`
    TODO


s_rshift64: ; 0083 RxRyRz 64-bit signed/arithmetic `Rx` = `Ry` >> `Rz`
    TODO


s_rshift8a: ; 0084 RxRyC___ 8-bit signed/arithmetic `Rx` = `C` >> `Ry`
    TODO


s_rshift16a: ; 0085 RxRyC___ 16-bit signed/arithmetic `Rx` = `C` >> `Ry`
    TODO


s_rshift32a: ; 0086 RxRyC___ 32-bit signed/arithmetic `Rx` = `C` >> `Ry`
    TODO


s_rshift64a: ; 0087 RxRyC___ 64-bit signed/arithmetic `Rx` = `C` >> `Ry`
    TODO


s_rshift8b: ; 0088 RxRyC___ 8-bit signed/arithmetic `Rx` = `Ry` >> `C`
    TODO


s_rshift16b: ; 0089 RxRyC___ 16-bit signed/arithmetic `Rx` = `Ry` >> `C`
    TODO


s_rshift32b: ; 008a RxRyC___ 32-bit signed/arithmetic `Rx` = `Ry` >> `C`
    TODO


s_rshift64b: ; 008b RxRyC___ 64-bit signed/arithmetic `Rx` = `Ry` >> `C`
    TODO




i_eq8: ; 008c RxRyRz 8-bit integer `Rx` = `Ry` == `Rz`
    TODO


i_eq16: ; 008d RxRyRz 16-bit integer `Rx` = `Ry` == `Rz`
    TODO


i_eq32: ; 008e RxRyRz 32-bit integer `Rx` = `Ry` == `Rz`
    TODO


i_eq64: ; 008f RxRyRz 64-bit integer `Rx` = `Ry` == `Rz`
    TODO


i_eq8c: ; 0090 RxRyC___ 8-bit integer `Rx` = `Ry` == `C`
    TODO


i_eq16c: ; 0091 RxRyC___ 16-bit integer `Rx` = `Ry` == `C`
    TODO


i_eq32c: ; 0092 RxRyC___ 32-bit integer `Rx` = `Ry` == `C`
    TODO


i_eq64c: ; 0093 RxRyC___ 64-bit integer `Rx` = `Ry` == `C`
    TODO


f_eq32: ; 0094 RxRyRz 32-bit floating point `Rx` = `Ry` == `Rz`
    TODO


f_eq64: ; 0095 RxRyRz 64-bit floating point `Rx` = `Ry` == `Rz`
    TODO



i_ne8: ; 0096 RxRyRz 8-bit integer `Rx` = `Ry` != `Rz`
    TODO


i_ne16: ; 0097 RxRyRz 16-bit integer `Rx` = `Ry` != `Rz`
    TODO


i_ne32: ; 0098 RxRyRz 32-bit integer `Rx` = `Ry` != `Rz`
    TODO


i_ne64: ; 0099 RxRyRz 64-bit integer `Rx` = `Ry` != `Rz`
    TODO


i_ne8c: ; 009a RxRyC___ 8-bit integer `Rx` = `Ry` != `C`
    TODO


i_ne16c: ; 009b RxRyC___ 16-bit integer `Rx` = `Ry` != `C`
    TODO


i_ne32c: ; 009c RxRyC___ 32-bit integer `Rx` = `Ry` != `C`
    TODO


i_ne64c: ; 009d RxRyC___ 64-bit integer `Rx` = `Ry` != `C`
    TODO


f_ne32: ; 009e RxRyRz 32-bit floating point `Rx` = `Ry` != `Rz`
    TODO


f_ne64: ; 009f RxRyRz 64-bit floating point `Rx` = `Ry` != `Rz`
    TODO



u_lt8: ; 00a0 RxRyRz 8-bit unsigned integer `Rx` = `Ry` < `Rz`
    TODO


u_lt16: ; 00a1 RxRyRz 16-bit unsigned integer `Rx` = `Ry` < `Rz`
    TODO


u_lt32: ; 00a2 RxRyRz 32-bit unsigned integer `Rx` = `Ry` < `Rz`
    TODO


u_lt64: ; 00a3 RxRyRz 64-bit unsigned integer `Rx` = `Ry` < `Rz`
    TODO


u_lt8a: ; 00a4 RxRyC___ 8-bit unsigned integer `Rx` = `C` < `Ry`
    TODO


u_lt16a: ; 00a5 RxRyC___ 16-bit unsigned integer `Rx` = `C` < `Ry`
    TODO


u_lt32a: ; 00a6 RxRyC___ 32-bit unsigned integer `Rx` = `C` < `Ry`
    TODO


u_lt64a: ; 00a7 RxRyC___ 64-bit unsigned integer `Rx` = `C` < `Ry`
    TODO


u_lt8b: ; 00a8 RxRyC___ 8-bit unsigned integer `Rx` = `Ry` < `C`
    TODO


u_lt16b: ; 00a9 RxRyC___ 16-bit unsigned integer `Rx` = `Ry` < `C`
    TODO


u_lt32b: ; 00aa RxRyC___ 32-bit unsigned integer `Rx` = `Ry` < `C`
    TODO


u_lt64b: ; 00ab RxRyC___ 64-bit unsigned integer `Rx` = `Ry` < `C`
    TODO


s_lt8: ; 00ac RxRyRz 8-bit signed integer `Rx` = `Ry` < `Rz`
    TODO


s_lt16: ; 00ad RxRyRz 16-bit signed integer `Rx` = `Ry` < `Rz`
    TODO


s_lt32: ; 00ae RxRyRz 32-bit signed integer `Rx` = `Ry` < `Rz`
    TODO


s_lt64: ; 00af RxRyRz 64-bit signed integer `Rx` = `Ry` < `Rz`
    TODO


s_lt8a: ; 00b0 RxRyC___ 8-bit signed integer `Rx` = `C` < `Ry`
    TODO


s_lt16a: ; 00b1 RxRyC___ 16-bit signed integer `Rx` = `C` < `Ry`
    TODO


s_lt32a: ; 00b2 RxRyC___ 32-bit signed integer `Rx` = `C` < `Ry`
    TODO


s_lt64a: ; 00b3 RxRyC___ 64-bit signed integer `Rx` = `C` < `Ry`
    TODO


s_lt8b: ; 00b4 RxRyC___ 8-bit signed integer `Rx` = `Ry` < `C`
    TODO


s_lt16b: ; 00b5 RxRyC___ 16-bit signed integer `Rx` = `Ry` < `C`
    TODO


s_lt32b: ; 00b6 RxRyC___ 32-bit signed integer `Rx` = `Ry` < `C`
    TODO


s_lt64b: ; 00b7 RxRyC___ 64-bit signed integer `Rx` = `Ry` < `C`
    TODO


f_lt32: ; 00b8 RxRyRz 32-bit floating point `Rx` = `Ry` < `Rz`
    TODO


f_lt32a: ; 00b9 RxRyC___ 32-bit floating point `Rx` = `C` < `Ry`
    TODO


f_lt32b: ; 00ba RxRyC___ 32-bit floating point `Rx` = `Ry` < `C`
    TODO


f_lt64: ; 00bb RxRyRz 64-bit floating point `Rx` = `Ry` < `Rz`
    TODO


f_lt64a: ; 00bc RxRyC___ 64-bit floating point `Rx` = `C` < `Ry`
    TODO


f_lt64b: ; 00bd RxRyC___ 64-bit floating point `Rx` = `Ry` < `C`
    TODO



u_gt8: ; 00be RxRyRz 8-bit unsigned integer `Rx` = `Ry` > `Rz`
    TODO


u_gt16: ; 00bf RxRyRz 16-bit unsigned integer `Rx` = `Ry` > `Rz`
    TODO


u_gt32: ; 00c0 RxRyRz 32-bit unsigned integer `Rx` = `Ry` > `Rz`
    TODO


u_gt64: ; 00c1 RxRyRz 64-bit unsigned integer `Rx` = `Ry` > `Rz`
    TODO


u_gt8a: ; 00c2 RxRyC___ 8-bit unsigned integer `Rx` = `C` > `Ry`
    TODO


u_gt16a: ; 00c3 RxRyC___ 16-bit unsigned integer `Rx` = `C` > `Ry`
    TODO


u_gt32a: ; 00c4 RxRyC___ 32-bit unsigned integer `Rx` = `C` > `Ry`
    TODO


u_gt64a: ; 00c5 RxRyC___ 64-bit unsigned integer `Rx` = `C` > `Ry`
    TODO


u_gt8b: ; 00c6 RxRyC___ 8-bit unsigned integer `Rx` = `Ry` > `C`
    TODO


u_gt16b: ; 00c7 RxRyC___ 16-bit unsigned integer `Rx` = `Ry` > `C`
    TODO


u_gt32b: ; 00c8 RxRyC___ 32-bit unsigned integer `Rx` = `Ry` > `C`
    TODO


u_gt64b: ; 00c9 RxRyC___ 64-bit unsigned integer `Rx` = `Ry` > `C`
    TODO


s_gt8: ; 00ca RxRyRz 8-bit signed integer `Rx` = `Ry` > `Rz`
    TODO


s_gt16: ; 00cb RxRyRz 16-bit signed integer `Rx` = `Ry` > `Rz`
    TODO


s_gt32: ; 00cc RxRyRz 32-bit signed integer `Rx` = `Ry` > `Rz`
    TODO


s_gt64: ; 00cd RxRyRz 64-bit signed integer `Rx` = `Ry` > `Rz`
    TODO


s_gt8a: ; 00ce RxRyC___ 8-bit signed integer `Rx` = `C` > `Ry`
    TODO


s_gt16a: ; 00cf RxRyC___ 16-bit signed integer `Rx` = `C` > `Ry`
    TODO


s_gt32a: ; 00d0 RxRyC___ 32-bit signed integer `Rx` = `C` > `Ry`
    TODO


s_gt64a: ; 00d1 RxRyC___ 64-bit signed integer `Rx` = `C` > `Ry`
    TODO


s_gt8b: ; 00d2 RxRyC___ 8-bit signed integer `Rx` = `Ry` > `C`
    TODO


s_gt16b: ; 00d3 RxRyC___ 16-bit signed integer `Rx` = `Ry` > `C`
    TODO


s_gt32b: ; 00d4 RxRyC___ 32-bit signed integer `Rx` = `Ry` > `C`
    TODO


s_gt64b: ; 00d5 RxRyC___ 64-bit signed integer `Rx` = `Ry` > `C`
    TODO


f_gt32: ; 00d6 RxRyRz 32-bit floating point `Rx` = `Ry` > `Rz`
    TODO


f_gt32a: ; 00d7 RxRyC___ 32-bit floating point `Rx` = `C` > `Ry`
    TODO


f_gt32b: ; 00d8 RxRyC___ 32-bit floating point `Rx` = `Ry` > `C`
    TODO


f_gt64: ; 00d9 RxRyRz 64-bit floating point `Rx` = `Ry` > `Rz`
    TODO


f_gt64a: ; 00da RxRyC___ 64-bit floating point `Rx` = `C` > `Ry`
    TODO


f_gt64b: ; 00db RxRyC___ 64-bit floating point `Rx` = `Ry` > `C`
    TODO



u_le8: ; 00dc RxRyRz 8-bit unsigned integer `Rx` = `Ry` <= `Rz`
    TODO


u_le16: ; 00dd RxRyRz 16-bit unsigned integer `Rx` = `Ry` <= `Rz`
    TODO


u_le32: ; 00de RxRyRz 32-bit unsigned integer `Rx` = `Ry` <= `Rz`
    TODO


u_le64: ; 00df RxRyRz 64-bit unsigned integer `Rx` = `Ry` <= `Rz`
    TODO


u_le8a: ; 00e0 RxRyC___ 8-bit unsigned integer `Rx` = `C` <= `Ry`
    TODO


u_le16a: ; 00e1 RxRyC___ 16-bit unsigned integer `Rx` = `C` <= `Ry`
    TODO


u_le32a: ; 00e2 RxRyC___ 32-bit unsigned integer `Rx` = `C` <= `Ry`
    TODO


u_le64a: ; 00e3 RxRyC___ 64-bit unsigned integer `Rx` = `C` <= `Ry`
    TODO


u_le8b: ; 00e4 RxRyC___ 8-bit unsigned integer `Rx` = `Ry` <= `C`
    TODO


u_le16b: ; 00e5 RxRyC___ 16-bit unsigned integer `Rx` = `Ry` <= `C`
    TODO


u_le32b: ; 00e6 RxRyC___ 32-bit unsigned integer `Rx` = `Ry` <= `C`
    TODO


u_le64b: ; 00e7 RxRyC___ 64-bit unsigned integer `Rx` = `Ry` <= `C`
    TODO


s_le8: ; 00e8 RxRyRz 8-bit signed integer `Rx` = `Ry` <= `Rz`
    TODO


s_le16: ; 00e9 RxRyRz 16-bit signed integer `Rx` = `Ry` <= `Rz`
    TODO


s_le32: ; 00ea RxRyRz 32-bit signed integer `Rx` = `Ry` <= `Rz`
    TODO


s_le64: ; 00eb RxRyRz 64-bit signed integer `Rx` = `Ry` <= `Rz`
    TODO


s_le8a: ; 00ec RxRyC___ 8-bit signed integer `Rx` = `C` <= `Ry`
    TODO


s_le16a: ; 00ed RxRyC___ 16-bit signed integer `Rx` = `C` <= `Ry`
    TODO


s_le32a: ; 00ee RxRyC___ 32-bit signed integer `Rx` = `C` <= `Ry`
    TODO


s_le64a: ; 00ef RxRyC___ 64-bit signed integer `Rx` = `C` <= `Ry`
    TODO


s_le8b: ; 00f0 RxRyC___ 8-bit signed integer `Rx` = `Ry` <= `C`
    TODO


s_le16b: ; 00f1 RxRyC___ 16-bit signed integer `Rx` = `Ry` <= `C`
    TODO


s_le32b: ; 00f2 RxRyC___ 32-bit signed integer `Rx` = `Ry` <= `C`
    TODO


s_le64b: ; 00f3 RxRyC___ 64-bit signed integer `Rx` = `Ry` <= `C`
    TODO


f_le32: ; 00f4 RxRyRz 32-bit floating point `Rx` = `Ry` <= `Rz`
    TODO


f_le32a: ; 00f5 RxRyC___ 32-bit floating point `Rx` = `C` <= `Ry`
    TODO


f_le32b: ; 00f6 RxRyC___ 32-bit floating point `Rx` = `Ry` <= `C`
    TODO


f_le64: ; 00f7 RxRyRz 64-bit floating point `Rx` = `Ry` <= `Rz`
    TODO


f_le64a: ; 00f8 RxRyC___ 64-bit floating point `Rx` = `C` <= `Ry`
    TODO


f_le64b: ; 00f9 RxRyC___ 64-bit floating point `Rx` = `Ry` <= `C`
    TODO



u_ge8: ; 00fa RxRyRz 8-bit unsigned integer `Rx` = `Ry` >= `Rz`
    TODO


u_ge16: ; 00fb RxRyRz 16-bit unsigned integer `Rx` = `Ry` >= `Rz`
    TODO


u_ge32: ; 00fc RxRyRz 32-bit unsigned integer `Rx` = `Ry` >= `Rz`
    TODO


u_ge64: ; 00fd RxRyRz 64-bit unsigned integer `Rx` = `Ry` >= `Rz`
    TODO


u_ge8a: ; 00fe RxRyC___ 8-bit unsigned integer `Rx` = `C` >= `Ry`
    TODO


u_ge16a: ; 00ff RxRyC___ 16-bit unsigned integer `Rx` = `C` >= `Ry`
    TODO


u_ge32a: ; 0100 RxRyC___ 32-bit unsigned integer `Rx` = `C` >= `Ry`
    TODO


u_ge64a: ; 0101 RxRyC___ 64-bit unsigned integer `Rx` = `C` >= `Ry`
    TODO


u_ge8b: ; 0102 RxRyC___ 8-bit unsigned integer `Rx` = `Ry` >= `C`
    TODO


u_ge16b: ; 0103 RxRyC___ 16-bit unsigned integer `Rx` = `Ry` >= `C`
    TODO


u_ge32b: ; 0104 RxRyC___ 32-bit unsigned integer `Rx` = `Ry` >= `C`
    TODO


u_ge64b: ; 0105 RxRyC___ 64-bit unsigned integer `Rx` = `Ry` >= `C`
    TODO


s_ge8: ; 0106 RxRyRz 8-bit signed integer `Rx` = `Ry` >= `Rz`
    TODO


s_ge16: ; 0107 RxRyRz 16-bit signed integer `Rx` = `Ry` >= `Rz`
    TODO


s_ge32: ; 0108 RxRyRz 32-bit signed integer `Rx` = `Ry` >= `Rz`
    TODO


s_ge64: ; 0109 RxRyRz 64-bit signed integer `Rx` = `Ry` >= `Rz`
    TODO


s_ge8a: ; 010a RxRyC___ 8-bit signed integer `Rx` = `C` >= `Ry`
    TODO


s_ge16a: ; 010b RxRyC___ 16-bit signed integer `Rx` = `C` >= `Ry`
    TODO


s_ge32a: ; 010c RxRyC___ 32-bit signed integer `Rx` = `C` >= `Ry`
    TODO


s_ge64a: ; 010d RxRyC___ 64-bit signed integer `Rx` = `C` >= `Ry`
    TODO


s_ge8b: ; 010e RxRyC___ 8-bit signed integer `Rx` = `Ry` >= `C`
    TODO


s_ge16b: ; 010f RxRyC___ 16-bit signed integer `Rx` = `Ry` >= `C`
    TODO


s_ge32b: ; 0110 RxRyC___ 32-bit signed integer `Rx` = `Ry` >= `C`
    TODO


s_ge64b: ; 0111 RxRyC___ 64-bit signed integer `Rx` = `Ry` >= `C`
    TODO


f_ge32: ; 0112 RxRyRz 32-bit floating point `Rx` = `Ry` >= `Rz`
    TODO


f_ge32a: ; 0113 RxRyC___ 32-bit floating point `Rx` = `C` >= `Ry`
    TODO


f_ge32b: ; 0114 RxRyC___ 32-bit floating point `Rx` = `Ry` >= `C`
    TODO


f_ge64: ; 0115 RxRyRz 64-bit floating point `Rx` = `Ry` >= `Rz`
    TODO


f_ge64a: ; 0116 RxRyC___ 64-bit floating point `Rx` = `C` >= `Ry`
    TODO


f_ge64b: ; 0117 RxRyC___ 64-bit floating point `Rx` = `Ry` >= `C`
    TODO




s_neg8: ; 0118 RxRy 8-bit `Rx` = -`Ry`
    TODO


s_neg16: ; 0119 RxRy 16-bit `Rx` = -`Ry`
    TODO


s_neg32: ; 011a RxRy 32-bit `Rx` = -`Ry`
    TODO


s_neg64: ; 011b RxRy 64-bit `Rx` = -`Ry`
    TODO



s_abs8: ; 011c RxRy 8-bit `Rx` = \|`Ry`\|
    TODO


s_abs16: ; 011d RxRy 16-bit `Rx` = \|`Ry`\|
    TODO


s_abs32: ; 011e RxRy 32-bit `Rx` = \|`Ry`\|
    TODO


s_abs64: ; 011f RxRy 64-bit `Rx` = \|`Ry`\|
    TODO



i_add8: ; 0120 RxRyRz 8-bit `Rx` = `Ry` + `Rz`
    TODO


i_add16: ; 0121 RxRyRz 16-bit `Rx` = `Ry` + `Rz`
    TODO


i_add32: ; 0122 RxRyRz 32-bit `Rx` = `Ry` + `Rz`
    TODO


i_add64: ; 0123 RxRyRz 64-bit `Rx` = `Ry` + `Rz`
    TODO


i_add8c: ; 0124 RxRyC___ 8-bit `Rx` = `Ry` + `C`
    TODO


i_add16c: ; 0125 RxRyC___ 16-bit `Rx` = `Ry` + `C`
    TODO


i_add32c: ; 0126 RxRyC___ 32-bit `Rx` = `Ry` + `C`
    TODO


i_add64c: ; 0127 RxRyC___ 64-bit `Rx` = `Ry` + `C`
    TODO



i_sub8: ; 0128 RxRyRz 8-bit `Rx` = `Ry` - `Rz`
    TODO


i_sub16: ; 0129 RxRyRz 16-bit `Rx` = `Ry` - `Rz`
    TODO


i_sub32: ; 012a RxRyRz 32-bit `Rx` = `Ry` - `Rz`
    TODO


i_sub64: ; 012b RxRyRz 64-bit `Rx` = `Ry` - `Rz`
    TODO


i_sub8a: ; 012c RxRyC___ 8-bit `Rx` = `C` - `Ry`
    TODO


i_sub16a: ; 012d RxRyC___ 16-bit `Rx` = `C` - `Ry`
    TODO


i_sub32a: ; 012e RxRyC___ 32-bit `Rx` = `C` - `Ry`
    TODO


i_sub64a: ; 012f RxRyC___ 64-bit `Rx` = `C` - `Ry`
    TODO


i_sub8b: ; 0130 RxRyC___ 8-bit `Rx` = `Ry` - `C`
    TODO


i_sub16b: ; 0131 RxRyC___ 16-bit `Rx` = `Ry` - `C`
    TODO


i_sub32b: ; 0132 RxRyC___ 32-bit `Rx` = `Ry` - `C`
    TODO


i_sub64b: ; 0133 RxRyC___ 64-bit `Rx` = `Ry` - `C`
    TODO



i_mul8: ; 0134 RxRyRz 8-bit `Rx` = `Ry` * `Rz`
    TODO


i_mul16: ; 0135 RxRyRz 16-bit `Rx` = `Ry` * `Rz`
    TODO


i_mul32: ; 0136 RxRyRz 32-bit `Rx` = `Ry` * `Rz`
    TODO


i_mul64: ; 0137 RxRyRz 64-bit `Rx` = `Ry` * `Rz`
    TODO


i_mul8c: ; 0138 RxRyC___ 8-bit `Rx` = `Ry` * `C`
    TODO


i_mul16c: ; 0139 RxRyC___ 16-bit `Rx` = `Ry` * `C`
    TODO


i_mul32c: ; 013a RxRyC___ 32-bit `Rx` = `Ry` * `C`
    TODO


i_mul64c: ; 013b RxRyC___ 64-bit `Rx` = `Ry` * `C`
    TODO



u_i_div8: ; 013c RxRyRz 8-bit unsigned `Rx` = `Ry` / `Rz`
    TODO


u_i_div16: ; 013d RxRyRz 16-bit unsigned `Rx` = `Ry` / `Rz`
    TODO


u_i_div32: ; 013e RxRyRz 32-bit unsigned `Rx` = `Ry` / `Rz`
    TODO


u_i_div64: ; 013f RxRyRz 64-bit unsigned `Rx` = `Ry` / `Rz`
    TODO


u_i_div8a: ; 0140 RxRyC___ 8-bit unsigned `Rx` = `C` / `Ry`
    TODO


u_i_div16a: ; 0141 RxRyC___ 16-bit unsigned `Rx` = `C` / `Ry`
    TODO


u_i_div32a: ; 0142 RxRyC___ 32-bit unsigned `Rx` = `C` / `Ry`
    TODO


u_i_div64a: ; 0143 RxRyC___ 64-bit unsigned `Rx` = `C` / `Ry`
    TODO


u_i_div8b: ; 0144 RxRyC___ 8-bit unsigned `Rx` = `Ry` / `C`
    TODO


u_i_div16b: ; 0145 RxRyC___ 16-bit unsigned `Rx` = `Ry` / `C`
    TODO


u_i_div32b: ; 0146 RxRyC___ 32-bit unsigned `Rx` = `Ry` / `C`
    TODO


u_i_div64b: ; 0147 RxRyC___ 64-bit unsigned `Rx` = `Ry` / `C`
    TODO


s_i_div8: ; 0148 RxRyRz 8-bit signed `Rx` = `Ry` / `Rz`
    TODO


s_i_div16: ; 0149 RxRyRz 16-bit signed `Rx` = `Ry` / `Rz`
    TODO


s_i_div32: ; 014a RxRyRz 32-bit signed `Rx` = `Ry` / `Rz`
    TODO


s_i_div64: ; 014b RxRyRz 64-bit signed `Rx` = `Ry` / `Rz`
    TODO


s_i_div8a: ; 014c RxRyC___ 8-bit signed `Rx` = `C` / `Ry`
    TODO


s_i_div16a: ; 014d RxRyC___ 16-bit signed `Rx` = `C` / `Ry`
    TODO


s_i_div32a: ; 014e RxRyC___ 32-bit signed `Rx` = `C` / `Ry`
    TODO


s_i_div64a: ; 014f RxRyC___ 64-bit signed `Rx` = `C` / `Ry`
    TODO


s_i_div8b: ; 0150 RxRyC___ 8-bit signed `Rx` = `Ry` / `C`
    TODO


s_i_div16b: ; 0151 RxRyC___ 16-bit signed `Rx` = `Ry` / `C`
    TODO


s_i_div32b: ; 0152 RxRyC___ 32-bit signed `Rx` = `Ry` / `C`
    TODO


s_i_div64b: ; 0153 RxRyC___ 64-bit signed `Rx` = `Ry` / `C`
    TODO



u_i_rem8: ; 0154 RxRyRz 8-bit unsigned `Rx` = `Ry` % `Rz`
    TODO


u_i_rem16: ; 0155 RxRyRz 16-bit unsigned `Rx` = `Ry` % `Rz`
    TODO


u_i_rem32: ; 0156 RxRyRz 32-bit unsigned `Rx` = `Ry` % `Rz`
    TODO


u_i_rem64: ; 0157 RxRyRz 64-bit unsigned `Rx` = `Ry` % `Rz`
    TODO


u_i_rem8a: ; 0158 RxRyC___ 8-bit unsigned `Rx` = `C` % `Ry`
    TODO


u_i_rem16a: ; 0159 RxRyC___ 16-bit unsigned `Rx` = `C` % `Ry`
    TODO


u_i_rem32a: ; 015a RxRyC___ 32-bit unsigned `Rx` = `C` % `Ry`
    TODO


u_i_rem64a: ; 015b RxRyC___ 64-bit unsigned `Rx` = `C` % `Ry`
    TODO


u_i_rem8b: ; 015c RxRyC___ 8-bit unsigned `Rx` = `Ry` % `C`
    TODO


u_i_rem16b: ; 015d RxRyC___ 16-bit unsigned `Rx` = `Ry` % `C`
    TODO


u_i_rem32b: ; 015e RxRyC___ 32-bit unsigned `Rx` = `Ry` % `C`
    TODO


u_i_rem64b: ; 015f RxRyC___ 64-bit unsigned `Rx` = `Ry` % `C`
    TODO


s_i_rem8: ; 0160 RxRyRz 8-bit signed `Rx` = `Ry` % `Rz`
    TODO


s_i_rem16: ; 0161 RxRyRz 16-bit signed `Rx` = `Ry` % `Rz`
    TODO


s_i_rem32: ; 0162 RxRyRz 32-bit signed `Rx` = `Ry` % `Rz`
    TODO


s_i_rem64: ; 0163 RxRyRz 64-bit signed `Rx` = `Ry` % `Rz`
    TODO


s_i_rem8a: ; 0164 RxRyC___ 8-bit signed `Rx` = `C` % `Ry`
    TODO


s_i_rem16a: ; 0165 RxRyC___ 16-bit signed `Rx` = `C` % `Ry`
    TODO


s_i_rem32a: ; 0166 RxRyC___ 32-bit signed `Rx` = `C` % `Ry`
    TODO


s_i_rem64a: ; 0167 RxRyC___ 64-bit signed `Rx` = `C` % `Ry`
    TODO


s_i_rem8b: ; 0168 RxRyC___ 8-bit signed `Rx` = `Ry` % `C`
    TODO


s_i_rem16b: ; 0169 RxRyC___ 16-bit signed `Rx` = `Ry` % `C`
    TODO


s_i_rem32b: ; 016a RxRyC___ 32-bit signed `Rx` = `Ry` % `C`
    TODO


s_i_rem64b: ; 016b RxRyC___ 64-bit signed `Rx` = `Ry` % `C`
    TODO



i_pow8: ; 016c RxRyRz 8-bit `Rx` = `Ry` ** `Rz`
    TODO


i_pow16: ; 016d RxRyRz 16-bit `Rx` = `Ry` ** `Rz`
    TODO


i_pow32: ; 016e RxRyRz 32-bit `Rx` = `Ry` ** `Rz`
    TODO


i_pow64: ; 016f RxRyRz 64-bit `Rx` = `Ry` ** `Rz`
    TODO


i_pow8a: ; 0170 RxRyC___ 8-bit `Rx` = `C` ** `Ry`
    TODO


i_pow16a: ; 0171 RxRyC___ 16-bit `Rx` = `C` ** `Ry`
    TODO


i_pow32a: ; 0172 RxRyC___ 32-bit `Rx` = `C` ** `Ry`
    TODO


i_pow64a: ; 0173 RxRyC___ 64-bit `Rx` = `C` ** `Ry`
    TODO


i_pow8b: ; 0174 RxRyC___ 8-bit `Rx` = `Ry` ** `C`
    TODO


i_pow16b: ; 0175 RxRyC___ 16-bit `Rx` = `Ry` ** `C`
    TODO


i_pow32b: ; 0176 RxRyC___ 32-bit `Rx` = `Ry` ** `C`
    TODO


i_pow64b: ; 0177 RxRyC___ 64-bit `Rx` = `Ry` ** `C`
    TODO




f_neg32: ; 0178 RxRy 32-bit `Rx` = -`Ry`
    TODO


f_neg64: ; 0179 RxRy 64-bit `Rx` = -`Ry`
    TODO



f_abs32: ; 017a RxRy 32-bit `Rx` = \|`Ry`\|
    TODO


f_abs64: ; 017b RxRy 64-bit `Rx` = \|`Ry`\|
    TODO



f_sqrt32: ; 017c RxRy 32-bit `Rx` = *sqrt* `Ry`
    TODO


f_sqrt64: ; 017d RxRy 64-bit `Rx` = *sqrt* `Ry`
    TODO



f_floor32: ; 017e RxRy 32-bit `Rx` = *floor* `Ry`
    TODO


f_floor64: ; 017f RxRy 64-bit `Rx` = *floor* `Ry`
    TODO



f_ceil32: ; 0180 RxRy 32-bit `Rx` = *ceiling* `Ry`
    TODO


f_ceil64: ; 0181 RxRy 64-bit `Rx` = *ceiling* `Ry`
    TODO



f_round32: ; 0182 RxRy 32-bit `Rx` = *round* `Ry`
    TODO


f_round64: ; 0183 RxRy 64-bit `Rx` = *round* `Ry`
    TODO



f_trunc32: ; 0184 RxRy 32-bit `Rx` = *truncate* `Ry`
    TODO


f_trunc64: ; 0185 RxRy 64-bit `Rx` = *truncate* `Ry`
    TODO



f_man32: ; 0186 RxRy 32-bit `Rx` = *man* `Ry`
    TODO


f_man64: ; 0187 RxRy 64-bit `Rx` = *man* `Ry`
    TODO



f_frac32: ; 0188 RxRy 32-bit `Rx` = *frac* `Ry`
    TODO


f_frac64: ; 0189 RxRy 64-bit `Rx` = *frac* `Ry`
    TODO



f_add32: ; 018a RxRyRz 32-bit `Rx` = `Ry` + `Rz`
    TODO


f_add32c: ; 018b RxRyC___ 32-bit `Rx` = `Ry` + `C`
    TODO


f_add64: ; 018c RxRyRz 64-bit `Rx` = `Ry` + `Rz`
    TODO


f_add64c: ; 018d RxRyC___ 64-bit `Rx` = `Ry` + `C`
    TODO



f_sub32: ; 018e RxRyRz 32-bit `Rx` = `Ry` - `Rz`
    TODO


f_sub32a: ; 018f RxRyC___ 32-bit `Rx` = `C` - `Ry`
    TODO


f_sub32b: ; 0190 RxRyC___ 32-bit `Rx` = `Ry` - `C`
    TODO


f_sub64: ; 0191 RxRyRz 64-bit `Rx` = `Ry` - `Rz`
    TODO


f_sub64a: ; 0192 RxRyC___ 64-bit `Rx` = `C` - `Ry`
    TODO


f_sub64b: ; 0193 RxRyC___ 64-bit `Rx` = `Ry` - `C`
    TODO



f_mul32: ; 0194 RxRyRz 32-bit `Rx` = `Ry` * `Rz`
    TODO


f_mul32c: ; 0195 RxRyC___ 32-bit `Rx` = `Ry` * `C`
    TODO


f_mul64: ; 0196 RxRyRz 64-bit `Rx` = `Ry` * `Rz`
    TODO


f_mul64c: ; 0197 RxRyC___ 64-bit `Rx` = `Ry` * `C`
    TODO



f_div32: ; 0198 RxRyRz 32-bit `Rx` = `Ry` / `Rz`
    TODO


f_div32a: ; 0199 RxRyC___ 32-bit `Rx` = `C` / `Ry`
    TODO


f_div32b: ; 019a RxRyC___ 32-bit `Rx` = `Ry` / `C`
    TODO


f_div64: ; 019b RxRyRz 64-bit `Rx` = `Ry` / `Rz`
    TODO


f_div64a: ; 019c RxRyC___ 64-bit `Rx` = `C` / `Ry`
    TODO


f_div64b: ; 019d RxRyC___ 64-bit `Rx` = `Ry` / `C`
    TODO



f_rem32: ; 019e RxRyRz 32-bit `Rx` = `Ry` % `Rz`
    TODO


f_rem32a: ; 019f RxRyC___ 32-bit `Rx` = `C` % `Ry`
    TODO


f_rem32b: ; 01a0 RxRyC___ 32-bit `Rx` = `Ry` % `C`
    TODO


f_rem64: ; 01a1 RxRyRz 64-bit `Rx` = `Ry` % `Rz`
    TODO


f_rem64a: ; 01a2 RxRyC___ 64-bit `Rx` = `C` % `Ry`
    TODO


f_rem64b: ; 01a3 RxRyC___ 64-bit `Rx` = `Ry` % `C`
    TODO



f_pow32: ; 01a4 RxRyRz 32-bit `Rx` = `Ry` ** `Rz`
    TODO


f_pow32a: ; 01a5 RxRyC___ 32-bit `Rx` = `C` ** `Ry`
    TODO


f_pow32b: ; 01a6 RxRyC___ 32-bit `Rx` = `Ry` ** `C`
    TODO


f_pow64: ; 01a7 RxRyRz 64-bit `Rx` = `Ry` ** `Rz`
    TODO


f_pow64a: ; 01a8 RxRyC___ 64-bit `Rx` = `C` ** `Ry`
    TODO


f_pow64b: ; 01a9 RxRyC___ 64-bit `Rx` = `Ry` ** `C`
    TODO




s_ext8_16: ; 01aa RxRy Sign extend 8-bits of `Ry` to 16-bits, placing the result in `Rx`
    TODO


s_ext8_32: ; 01ab RxRy Sign extend 8-bits of `Ry` to 32-bits, placing the result in `Rx`
    TODO


s_ext8_64: ; 01ac RxRy Sign extend 8-bits of `Ry` to 64-bits, placing the result in `Rx`
    TODO


s_ext16_32: ; 01ad RxRy Sign extend 16-bits of `Ry` to 32-bits, placing the result in `Rx`
    TODO


s_ext16_64: ; 01ae RxRy Sign extend 16-bits of `Ry` to 64-bits, placing the result in `Rx`
    TODO


s_ext32_64: ; 01af RxRy Sign extend 32-bits of `Ry` to 64-bits, placing the result in `Rx`
    TODO



f32_to_u8: ; 01b0 RxRy Convert of 32-bit float in `Ry` to 8-bit integer; discards sign, places the result in `Rx`
    TODO


f32_to_u16: ; 01b1 RxRy Convert of 32-bit float in `Ry` to 16-bit integer; discards sign, places the result in `Rx`
    TODO


f32_to_u32: ; 01b2 RxRy Convert of 32-bit float in `Ry` to 32-bit integer; discards sign, places the result in `Rx`
    TODO


f32_to_u64: ; 01b3 RxRy Convert of 32-bit float in `Ry` to 64-bit integer; discards sign, places the result in `Rx`
    TODO


f32_to_s8: ; 01b4 RxRy Convert of 32-bit float in `Ry` to 8-bit integer; keeps sign, places the result in `Rx`
    TODO


f32_to_s16: ; 01b5 RxRy Convert of 32-bit float in `Ry` to 16-bit integer; keeps sign, places the result in `Rx`
    TODO


f32_to_s32: ; 01b6 RxRy Convert of 32-bit float in `Ry` to 32-bit integer; keeps sign, places the result in `Rx`
    TODO


f32_to_s64: ; 01b7 RxRy Convert of 32-bit float in `Ry` to 64-bit integer; keeps sign, places the result in `Rx`
    TODO



u8_to_f32: ; 01b8 RxRy Convert 8-bits in `Ry` to 32-bit float; discards sign, places result in `Rx`
    TODO


u16_to_f32: ; 01b9 RxRy Convert 16-bits in `Ry` to 32-bit float; discards sign, places result in `Rx`
    TODO


u32_to_f32: ; 01ba RxRy Convert 32-bits in `Ry` to 32-bit float; discards sign, places result in `Rx`
    TODO


u64_to_f32: ; 01bb RxRy Convert 64-bits in `Ry` to 32-bit float; discards sign, places result in `Rx`
    TODO


s8_to_f32: ; 01bc RxRy Convert 8-bits in `Ry` to 32-bit float; keeps sign, places result in `Rx`
    TODO


s16_to_f32: ; 01bd RxRy Convert 16-bits in `Ry` to 32-bit float; keeps sign, places result in `Rx`
    TODO


s32_to_f32: ; 01be RxRy Convert 32-bits in `Ry` to 32-bit float; keeps sign, places result in `Rx`
    TODO


s64_to_f32: ; 01bf RxRy Convert 64-bits in `Ry` to 32-bit float; keeps sign, places result in `Rx`
    TODO


u8_to_f64: ; 01c0 RxRy Convert 8-bits in `Ry` to 64-bit float; discards sign, places result in `Rx`
    TODO


u16_to_f64: ; 01c1 RxRy Convert 16-bits in `Ry` to 64-bit float; discards sign, places result in `Rx`
    TODO


u32_to_f64: ; 01c2 RxRy Convert 32-bits in `Ry` to 64-bit float; discards sign, places result in `Rx`
    TODO


u64_to_f64: ; 01c3 RxRy Convert 64-bits in `Ry` to 64-bit float; discards sign, places result in `Rx`
    TODO


s8_to_f64: ; 01c4 RxRy Convert 8-bits in `Ry` to 64-bit float; keeps sign, places result in `Rx`
    TODO


s16_to_f64: ; 01c5 RxRy Convert 16-bits in `Ry` to 64-bit float; keeps sign, places result in `Rx`
    TODO


s32_to_f64: ; 01c6 RxRy Convert 32-bits in `Ry` to 64-bit float; keeps sign, places result in `Rx`
    TODO


s64_to_f64: ; 01c7 RxRy Convert 64-bits in `Ry` to 64-bit float; keeps sign, places result in `Rx`
    TODO



f32_to_f64: ; 01c8 RxRy Convert 32-bit float in `Ry` to 64-bit float; places the result in `Rx`
    TODO


f64_to_f32: ; 01c9 RxRy Convert 64-bit float in `Ry` to 32-bit float; places the result in `Rx`
    TODO
