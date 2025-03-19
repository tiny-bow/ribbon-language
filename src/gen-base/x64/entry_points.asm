%include "ribbon.h.asm"
%undef R_EXIT_OKAY
%undef R_EXIT_HALT
%undef R_TRAP_BAD_ENCODING
%undef R_TRAP_OVERFLOW
%undef R_TRAP_REQUESTED
%undef R_DECODE
%undef R_DISPATCH

section .text

ENTRY_POINT rvm_interpreter_step, R_EXIT_OKAY

ENTRY_POINT rvm_interpreter_eval, R_DECODE

R_EXIT_OKAY:
    EXIT BuiltinSignal.return

R_EXIT_HALT:
    EXIT BuiltinSignal.halt

R_TRAP_BAD_ENCODING:
    mov [FIBER + Fiber.trap], IP
    EXIT BuiltinSignal.bad_encoding

R_TRAP_OVERFLOW:
    EXIT BuiltinSignal.overflow

R_TRAP_REQUESTED:
    EXIT BuiltinSignal.request_trap

R_DECODE:
    ; put the opcode into TER_A
    movzx TER_A_short, [IP]

    %ifdef DBG ; check if the opcode is valid
        cmp TER_A, R_JUMP_TABLE_LENGTH
        ja R_TRAP_BAD_ENCODING
    %endif

    ; increment the instruction pointer by the size of the opcode (2 bytes)
    add IP, OP_SIZE

R_DISPATCH:
    ; jump to the instruction
    jmp R_JUMP_TABLE[TER_A * 8]
