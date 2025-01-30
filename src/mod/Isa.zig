// zig fmt: off

const Isa = @This();

const std = @import("std");

pub const log = std.log.scoped(.isa);

test {
    std.testing.refAllDeclsRecursive(@This());
}

pub const Instructions = &[_]InstructionCategory {
    .{ .name = "Miscellaneous"
     , .kinds = &[_]InstructionKind {
        .{ .base_name = "nop"
         , .description =
            \\Not an operation; does nothing
         , .instructions = &[_]InstructionDescriptor {
            .{ .description =
                \\No operation
            },
         }
        },
        .{ .base_name = "eof"
         , .description =
            \\End of file; stops read of the program
         , .instructions = &[_]InstructionDescriptor {
            .{ .description =
                \\End of file
            },
         }
        },
     }
    },
    .{ .name = "Control Flow"
     , .description =
        \\Control the flow of program execution
     , .kinds = &[_]InstructionKind {
        .{ .base_name = "halt"
         , .description =
            \\Stops execution of the program
         , .instructions = &[_]InstructionDescriptor {
            .{ .description =
                \\Halt execution
            },
         }
        },
        .{ .base_name = "trap"
         , .description =
            \\Stops execution of the program and triggers the `unreachable` trap
         , .instructions = &[_]InstructionDescriptor {
            .{ .description =
                \\Trigger a trap
            },
         }
        },
        .{ .base_name = "push_set"
         , .description =
            \\Push the handler set operand to handle matching effects,
            \\until a matching `pop_set` instruction is encountered
            \\
            \\The jump offset provided is used in the event an effect handler in the provided set cancels computation.
            \\This should be the address of the corresponding `pop_set` instruction, or the end of the function, if no such instruction exists
         , .instructions = &[_]InstructionDescriptor {
            .{ .description =
                \\Begin using the designated handler set
             , .operands = &[_]OperandDescriptor { .jump_offset, .handler_set_index }
            },
            .{ .suffix = "v"
             , .description =
                \\Begin using the designated handler set.
                \\If the handler cancels computation, place the cancellation value in the provided register.
             , .operands = &[_]OperandDescriptor { .jump_offset, .handler_set_index, .register }
            },
         }
        },
        .{ .base_name = "pop_set"
         , .description =
            \\End the top-most effect handler set, popping the associated handlers off the evidence stack
         , .instructions = &[_]InstructionDescriptor {
            .{ .description =
                \\End the top-most effect handler set
            },
         }
        },
        .{ .base_name = "br"
         , .description =
            \\Jump to the designated offset
         , .instructions = &[_]InstructionDescriptor {
            .{ .description =
                \\Jump to the designated offset
             , .operands = &[_]OperandDescriptor { .jump_offset }
            },
            .{ .suffix = "if"
             , .description =
                \\If the value in the designated register is not zero, jump to the first offset, otherwise jump to the second offset
             , .operands = &[_]OperandDescriptor { .jump_offset, .jump_offset, .register }
            },
         }
        },
        .{ .base_name = "call"
         , .description =
            \\Call the function designated by the function operand; expects a number of arguments designated by the immediate
         , .instructions = &[_]InstructionDescriptor {
            .{ .description =
                \\Call a function found in the designated register, expecting no return value
             , .operands = &[_]OperandDescriptor { .byte, .register }
            },
            .{ .suffix = "v"
             , .description =
                \\Call a function found in the primary register, and place the return value in the secondary register
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .suffix = "im"
             , .description =
                \\Call a statically designated function, expecting no return value
             , .operands = &[_]OperandDescriptor { .byte, .function_index }
            },
            .{ .suffix = "im_v"
             , .description =
                \\Call a statically designated function, and place the return value in the designated register
             , .operands = &[_]OperandDescriptor { .byte, .function_index, .register }
            },
            .{ .prefix = "tail"
             , .description =
                \\Call a function found in the designated register, in tail position
             , .operands = &[_]OperandDescriptor { .byte, .register }
            },
            .{ .prefix = "tail"
             , .suffix = "im"
             , .description =
                \\Call a statically designated function, in tail position
             , .operands = &[_]OperandDescriptor { .byte, .function_index }
            },
         }
        },
        .{ .base_name = "foreign_call"
         , .description =
            \\Call the foreign function designated by the foreign operand
            \\
            \\Expects a number of register indices, designated by the immediate, to follow this instruction in the stream
         , .instructions = &[_]InstructionDescriptor {
            .{ .description =
                \\Call a foreign function found in the designated register, expecting no return value
             , .operands = &[_]OperandDescriptor { .byte, .register }
            },
            .{ .suffix = "v"
             , .description =
                \\Call a foreign function found in the primary register, and place the return value in the secondary register
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .suffix = "im"
             , .description =
                \\Call a statically designated foreign, expecting no return value
             , .operands = &[_]OperandDescriptor { .byte, .foreign_index }
            },
            .{ .suffix = "im_v"
             , .description =
                \\Call a statically designated foreign, and place the return value in the designated register
             , .operands = &[_]OperandDescriptor { .byte, .foreign_index, .register }
            },
            .{ .prefix = "tail"
             , .description =
                \\Call a foreign function found in the designated register, in tail position
             , .operands = &[_]OperandDescriptor { .byte, .register }
            },
            .{ .prefix = "tail"
             , .suffix = "im"
             , .description =
                \\Call a statically designated foreign, in tail position
             , .operands = &[_]OperandDescriptor { .byte, .foreign_index }
            },
         }
        },
        .{ .base_name = "prompt"
         , .description =
            \\Call the effect handler designated by the evidence operand
            \\
            \\Expects a number of register indices, designated by the immediate, to follow this instruction in the stream
         , .instructions = &[_]InstructionDescriptor {
            .{ .description =
                \\Call an effect handler, expecting no return value
             , .operands = &[_]OperandDescriptor { .byte, .evidence_index }
            },
            .{ .suffix = "v"
             , .description =
                \\Call an effect handler, and place the return value in the designated register
             , .operands = &[_]OperandDescriptor { .byte, .evidence_index, .register }
            },
            .{ .prefix = "tail"
             , .description =
                \\Call an effect handler, in tail position
             , .operands = &[_]OperandDescriptor { .byte, .evidence_index }
            },
         }
        },
        .{ .base_name = "ret"
         , .description =
            \\Return from the current function, optionally placing the result in the designated register
         , .instructions = &[_]InstructionDescriptor {
            .{ .description =
                \\Return from the current function, yielding no value
            },
            .{ .suffix = "v"
             , .description =
                \\Return from the current function, yielding the value in the designated register
             , .operands = &[_]OperandDescriptor { .register }
            },
            .{ .suffix = "im_v"
             , .description =
                \\Return from the current function, yielding an immediate value up to 32 bits
             , .operands = &[_]OperandDescriptor { .immediate }
            },
            .{ .suffix = "im_w_v"
             , .description =
                \\Return from the current function, yielding an immediate value up to 64 bits
             , .wide_immediate = true
            },
         }
        },
        .{ .base_name = "cancel"
         , .description =
            \\Trigger cancellation of an effect handler, ending the computation it was introduced in
         , .instructions = &[_]InstructionDescriptor {
            .{ .description =
                \\Cancel the current effect handler, yielding no value
            },
            .{ .suffix = "v"
             , .description =
                \\Cancel the current effect handler, yielding the value in the designated register
             , .operands = &[_]OperandDescriptor { .register }
            },
            .{ .suffix = "im_v"
             , .description =
                \\Cancel the current effect handler, yielding an immediate value up to 32 bits
             , .operands = &[_]OperandDescriptor { .immediate }
            },
            .{ .suffix = "im_w_v"
             , .description =
                \\Cancel the current effect handler, yielding an immediate value up to 64 bits
             , .wide_immediate = true
            },
         }
        },
     }
    },
    .{ .name = "Memory"
     , .description =
        \\Instructions for memory access and manipulation
     , .kinds = &[_]InstructionKind {
        .{ .base_name = "alloca"
         , .description =
            \\Allocate a number of bytes on the stack, placing the address in the designated register
         , .instructions = &[_]InstructionDescriptor {
            .{ .description =
                \\Allocate a number of bytes (up to 65k) on the stack, placing the address in the register
             , .operands = &[_]OperandDescriptor { .short, .register }
            },
         }
        },
        .{ .base_name = "addr"
         , .description =
            \\Place the address of the value designated by the first operand into the register provided in the second operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .suffix = "global"
             , .description =
                \\Place the address of the global into the register
             , .operands = &[_]OperandDescriptor { .global_index, .register }
            },
            .{ .suffix = "upvalue"
             , .description =
                \\Place the address of the upvalue into the register
             , .operands = &[_]OperandDescriptor { .upvalue_index, .register }
            },
            .{ .suffix = "foreign"
             , .description =
                \\Place the provided foreign address into the designated register
             , .operands = &[_]OperandDescriptor { .foreign_index, .register }
            },
            .{ .suffix = "function"
             , .description =
                \\Place the address of the function into the register
             , .operands = &[_]OperandDescriptor { .function_index, .register }
            },
         }
        },
        .{ .base_name = "read"
         , .description =
             \\Copy a number of bits from the value designated by the first operand into the register provided in the second operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .suffix = "global_8"
             , .description =
                \\Copy 8 bits from the global into the register
             , .operands = &[_]OperandDescriptor { .global_index, .register }
            },
            .{ .suffix = "global_16"
             , .description =
                \\Copy 16 bits from the global into the register
             , .operands = &[_]OperandDescriptor { .global_index, .register }
            },
            .{ .suffix = "global_32"
             , .description =
                \\Copy 32 bits from the global into the register
             , .operands = &[_]OperandDescriptor { .global_index, .register }
            },
            .{ .suffix = "global_64"
             , .description =
                \\Copy 64 bits from the global into the register
             , .operands = &[_]OperandDescriptor { .global_index, .register }
            },
             .{ .suffix = "upvalue_8"
             , .description =
                \\Copy 8 bits from the upvalue into the register
             , .operands = &[_]OperandDescriptor { .upvalue_index, .register },
             },
             .{ .suffix = "upvalue_16"
             , .description =
                \\Copy 16 bits from the upvalue into the register
             , .operands = &[_]OperandDescriptor { .upvalue_index, .register },
             },
             .{ .suffix = "upvalue_32"
             , .description =
                \\Copy 32 bits from the upvalue into the register
             , .operands = &[_]OperandDescriptor { .upvalue_index, .register },
             },
             .{ .suffix = "upvalue_64"
             , .description =
                \\Copy 64 bits from the upvalue into the register
             , .operands = &[_]OperandDescriptor { .upvalue_index, .register },
             },
         }
        },
        .{ .base_name = "write"
         , .description =
            \\Copy a number of bits from the value designated by the first operand into the value provided in the second operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .suffix = "global_8"
             , .description =
                \\Copy 8 bits from the register into the designated global
             , .operands = &[_]OperandDescriptor { .register, .global_index }
            },
            .{ .suffix = "global_16"
             , .description =
                \\Copy 16 bits from the register into the designated global
             , .operands = &[_]OperandDescriptor { .register, .global_index }
            },
            .{ .suffix = "global_32"
             , .description =
                \\Copy 32 bits from the register into the designated global
             , .operands = &[_]OperandDescriptor { .register, .global_index }
            },
            .{ .suffix = "global_64"
             , .description =
                \\Copy 64 bits from the register into the designated global
             , .operands = &[_]OperandDescriptor { .register, .global_index }
            },
            .{ .suffix = "global_8_im"
             , .description =
                \\Copy 8 bits from the immediate into the designated global
             , .operands = &[_]OperandDescriptor { .byte, .global_index }
            },
            .{ .suffix = "global_16_im"
             , .description =
                \\Copy 16 bits from the immediate into the designated global
             , .operands = &[_]OperandDescriptor { .short, .global_index }
            },
            .{ .suffix = "global_32_im"
             , .description =
                \\Copy 32 bits from the immediate into the designated global
             , .operands = &[_]OperandDescriptor { .immediate, .global_index }
            },
            .{ .suffix = "global_64_im"
             , .description =
                \\Copy 64 bits from the immediate into the designated global
             , .operands = &[_]OperandDescriptor { .global_index }
             , .wide_immediate = true
            },
             .{ .suffix = "upvalue_8"
              , .description =
                \\Copy 8 bits from the register into the designated upvalue
              , .operands = &[_]OperandDescriptor { .register, .upvalue_index }
             },
             .{ .suffix = "upvalue_16"
              , .description =
                \\Copy 16 bits from the register into the designated upvalue
              , .operands = &[_]OperandDescriptor { .register, .upvalue_index }
             },
             .{ .suffix = "upvalue_32"
              , .description =
                \\Copy 32 bits from the register into the designated upvalue
              , .operands = &[_]OperandDescriptor { .register, .upvalue_index }
             },
             .{ .suffix = "upvalue_64"
              , .description =
                \\Copy 64 bits from the register into the designated upvalue
              , .operands = &[_]OperandDescriptor { .register, .upvalue_index }
             },
             .{ .suffix = "upvalue_8_im"
              , .description =
                \\Copy 8 bits from the immediate into the designated upvalue
              , .operands = &[_]OperandDescriptor { .byte, .upvalue_index }
             },
             .{ .suffix = "upvalue_16_im"
              , .description =
                \\Copy 16 bits from the immediate into the designated upvalue
              , .operands = &[_]OperandDescriptor { .short, .upvalue_index }
             },
             .{ .suffix = "upvalue_32_im"
              , .description =
                \\Copy 32 bits from the register into the designated upvalue
              , .operands = &[_]OperandDescriptor { .immediate, .upvalue_index }
             },
             .{ .suffix = "upvalue_64_im"
              , .description =
                \\Copy 64 bits from the immediate into the designated upvalue
              , .operands = &[_]OperandDescriptor { .upvalue_index }
              , .wide_immediate = true
             },
         }
        },
        .{ .base_name = "load"
         , .description =
            \\Copy a number of bits from the memory address designated by the first operand into the register provided in the second operand
            \\
            \\The address must be located on the stack or global memory
         , .instructions = &[_]InstructionDescriptor {
            .{ .suffix = "8"
             , .description =
                \\Copy 8 bits from the memory address in the first register into the second register
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .suffix = "16"
             , .description =
                \\Copy 16 bits from the memory address in the first register into the second register
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .suffix = "32"
             , .description =
                \\Copy 32 bits from the memory address in the first register into the second register
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .suffix = "64"
             , .description =
                \\Copy 64 bits from the memory address in the first register into the second register
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
         }
        },
        .{ .base_name = "store"
         , .description =
            \\Copy a number of bits from the value designated by the first operand into the memory address in the register provided in the second operand
            \\
            \\The address must be located on the stack or global memory
         , .instructions = &[_]InstructionDescriptor {
            .{ .suffix = "8"
             , .description =
                \\Copy 8 bits from the first register into the memory address in the second register
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .suffix = "16"
             , .description =
                \\Copy 16 bits from the first register into the memory address in the second register
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .suffix = "32"
             , .description =
                \\Copy 32 bits from the first register into the memory address in the second register
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .suffix = "64"
             , .description =
                \\Copy 64 bits from the first register into the memory address in the second register
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .suffix = "8_im"
             , .description =
                \\Copy 8 bits from the immediate into the memory address in the register
             , .operands = &[_]OperandDescriptor { .byte, .register }
            },
            .{ .suffix = "16_im"
             , .description =
                \\Copy 16 bits from the immediate into the memory address in the register
             , .operands = &[_]OperandDescriptor { .short, .register }
            },
            .{ .suffix = "32_im"
             , .description =
                \\Copy 32 bits from the immediate into the memory address in the register
             , .operands = &[_]OperandDescriptor { .immediate, .register }
            },
            .{ .suffix = "64_im"
             , .description =
                \\Copy 64 bits from the immediate into the memory address in the register
             , .operands = &[_]OperandDescriptor { .register }
             , .wide_immediate = true
            },
         }
        },
        .{ .base_name = "clear"
         , .description =
            \\Clear a number of bits in the designated register
         , .instructions = &[_]InstructionDescriptor {
            .{ .suffix = "8"
             , .description =
                \\Clear 8 bits from the register
             , .operands = &[_]OperandDescriptor { .register }
            },
            .{ .suffix = "16"
             , .description =
                \\Clear 16 bits from the register
             , .operands = &[_]OperandDescriptor { .register }
            },
            .{ .suffix = "32"
             , .description =
                \\Clear 32 bits from the register
             , .operands = &[_]OperandDescriptor { .register }
            },
            .{ .suffix = "64"
             , .description =
                \\Clear 64 bits from the register
             , .operands = &[_]OperandDescriptor { .register }
            },
         }
        },
        .{ .base_name = "swap"
         , .description =
            \\Swap a number of bits in the two designated registers
         , .instructions = &[_]InstructionDescriptor {
            .{ .suffix = "8"
             , .description =
                \\Swap 8 bits between the two registers
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .suffix = "16"
             , .description =
                \\Swap 16 bits between the two registers
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .suffix = "32"
             , .description =
                \\Swap 32 bits between the two registers
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .suffix = "64"
             , .description =
                \\Swap 64 bits between the two registers
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
         }
        },
        .{ .base_name = "copy"
         , .description =
            \\Copy a number of bits from the first register into the second register
         , .instructions = &[_]InstructionDescriptor {
            .{ .suffix = "8"
             , .description =
                \\Copy 8 bits from the first register into the second register
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .suffix = "16"
             , .description =
                \\Copy 16 bits from the first register into the second register
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .suffix = "32"
             , .description =
                \\Copy 32 bits from the first register into the second register
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .suffix = "64"
             , .description =
                \\Copy 64 bits from the first register into the second register
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .suffix = "8_im"
             , .description =
                \\Copy 8-bits from an immediate value into the register
             , .operands = &[_]OperandDescriptor { .byte, .register }
            },
            .{ .suffix = "16_im"
             , .description =
                \\Copy 16-bits from an immediate value into the register
             , .operands = &[_]OperandDescriptor { .short, .register }
            },
            .{ .suffix = "32_im"
             , .description =
                \\Copy 32-bits from an immediate value into the register
             , .operands = &[_]OperandDescriptor { .immediate, .register }
            },
            .{ .suffix = "64_im"
             , .description =
                \\Copy 64-bits from an immediate value into the register
             , .operands = &[_]OperandDescriptor { .register }
             , .wide_immediate = true
            },
         }
        },
     }
    },
    .{ .name = "Arithmetic"
     , .description =
        \\Basic arithmetic operations
     , .kinds = &[_]InstructionKind {
        .{ .base_name = "add"
         , .description =
            \\Addition on two operands, with the result placed in a register designated by the third operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .prefix = "i"
             , .suffix = "8"
             , .description =
                \\Sign-agnostic addition on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "16"
             , .description =
                \\Sign-agnostic addition on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "32"
             , .description =
                \\Sign-agnostic addition on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "64"
             , .description =
                \\Sign-agnostic addition on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "8_im"
             , .description =
                \\Sign-agnostic addition on 8-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "16_im"
             , .description =
                \\Sign-agnostic addition on 16-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "32_im"
             , .description =
                \\Sign-agnostic addition on 32-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "64_im"
             , .description =
                \\Sign-agnostic addition on 64-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },

            .{ .prefix = "f"
             , .suffix = "32"
             , .description =
                \\Addition on 32-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64"
             , .description =
                \\Addition on 64-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "32_im"
             , .description =
                \\Addition on 32-bit floats; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64_im"
             , .description =
                \\Addition on 64-bit floats; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
         }
        },
        .{ .base_name = "sub"
         , .description =
            \\Subtraction on two operands, with the result placed in a register designated by the third operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .prefix = "i"
             , .suffix = "8"
             , .description =
                \\Sign-agnostic subtraction on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "16"
             , .description =
                \\Sign-agnostic subtraction on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "32"
             , .description =
                \\Sign-agnostic subtraction on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "64"
             , .description =
                \\Sign-agnostic subtraction on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "8_im_a"
             , .description =
                \\Sign-agnostic subtraction on 8-bit integers; subtract register value from immediate value
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "16_im_a"
             , .description =
                \\Sign-agnostic subtraction on 16-bit integers; subtract register value from immediate value
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "32_im_a"
             , .description =
                \\Sign-agnostic subtraction on 32-bit integers; subtract register value from immediate value
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "64_im_a"
             , .description =
                \\Sign-agnostic subtraction on 64-bit integers; subtract register value from immediate value
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "i"
             , .suffix = "8_im_b"
             , .description =
                \\Sign-agnostic subtraction on 8-bit integers; subtract immediate value from register value
             , .operands = &[_]OperandDescriptor { .register, .byte, .register }
            },
            .{ .prefix = "i"
             , .suffix = "16_im_b"
             , .description =
                \\Sign-agnostic subtraction on 16-bit integers; subtract immediate value from register value
             , .operands = &[_]OperandDescriptor { .register, .short, .register }
            },
            .{ .prefix = "i"
             , .suffix = "32_im_b"
             , .description =
                \\Sign-agnostic subtraction on 32-bit integers; subtract immediate value from register value
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "i"
             , .suffix = "64_im_b"
             , .description =
                \\Sign-agnostic subtraction on 64-bit integers; subtract immediate value from register value
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },

            .{ .prefix = "f"
             , .suffix = "32"
             , .description =
                \\Subtraction on 32-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64"
             , .description =
                \\Subtraction on 64-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "32_im_a"
             , .description =
                \\Subtraction on 32-bit floats; subtract register value from immediate value
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64_im_a"
             , .description =
                \\Subtraction on 64-bit floats; subtract register value from immediate value
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "f"
             , .suffix = "32_im_b"
             , .description =
                \\Subtraction on 32-bit floats; subtract immediate value from register value
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64_im_b"
             , .description =
                \\Subtraction on 64-bit floats; subtract immediate value from register value
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
         }
        },
        .{ .base_name = "mul"
         , .description =
            \\Multiplication on two operands, with the result placed in a register designated by the third operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .prefix = "i"
             , .suffix = "8"
             , .description =
                \\Sign-agnostic multiplication on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "16"
             , .description =
                \\Sign-agnostic multiplication on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "32"
             , .description =
                \\Sign-agnostic multiplication on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "64"
             , .description =
                \\Sign-agnostic multiplication on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "8_im"
             , .description =
                \\Sign-agnostic multiplication on 8-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "16_im"
             , .description =
                \\Sign-agnostic multiplication on 16-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "32_im"
             , .description =
                \\Sign-agnostic multiplication on 32-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "64_im"
             , .description =
                \\Sign-agnostic multiplication on 64-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },

            .{ .prefix = "f"
             , .suffix = "32"
             , .description =
                \\Multiplication on 32-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64"
             , .description =
                \\Multiplication on 64-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "32_im"
             , .description =
                \\Multiplication on 32-bit floats; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64_im"
             , .description =
                \\Multiplication on 64-bit floats; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
         }
        },
        .{ .base_name = "div"
         , .description =
            \\Division on two operands, with the result placed in a register designated by the third operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .prefix = "u"
             , .suffix = "8"
             , .description =
                \\Unsigned division on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16"
             , .description =
                \\Unsigned division on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32"
             , .description =
                \\Unsigned division on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64"
             , .description =
                \\Unsigned division on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "8_im_a"
             , .description =
                \\Unsigned division on 8-bit integers; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16_im_a"
             , .description =
                \\Unsigned division on 16-bit integers; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32_im_a"
             , .description =
                \\Unsigned division on 32-bit integers; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64_im_a"
             , .description =
                \\Unsigned division on 64-bit integers; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "u"
             , .suffix = "8_im_b"
             , .description =
                \\Unsigned division on 8-bit integers; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .byte, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16_im_b"
             , .description =
                \\Unsigned division on 16-bit integers; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .short, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32_im_b"
             , .description =
                \\Unsigned division on 32-bit integers; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64_im_b"
             , .description =
                \\Unsigned division on 64-bit integers; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },

            .{ .prefix = "s"
             , .suffix = "8"
             , .description =
                \\Signed division on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16"
             , .description =
                \\Signed division on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32"
             , .description =
                \\Signed division on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64"
             , .description =
                \\Signed division on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "8_im_a"
             , .description =
                \\Signed division on 8-bit integers; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16_im_a"
             , .description =
                \\Signed division on 16-bit integers; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32_im_a"
             , .description =
                \\Signed division on 32-bit integers; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64_im_a"
             , .description =
                \\Signed division on 64-bit integers; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "s"
             , .suffix = "8_im_b"
             , .description =
                \\Signed division on 8-bit integers; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .byte, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16_im_b"
             , .description =
                \\Signed division on 16-bit integers; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .short, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32_im_b"
             , .description =
                \\Signed division on 32-bit integers; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64_im_b"
             , .description =
                \\Signed division on 64-bit integers; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },

            .{ .prefix = "f"
             , .suffix = "32"
             , .description =
                \\Division on 32-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64"
             , .description =
                \\Division on 64-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "32_im_a"
             , .description =
                \\Division on 32-bit floats; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64_im_a"
             , .description =
                \\Division on 64-bit floats; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "f"
             , .suffix = "32_im_b"
             , .description =
                \\Division on 32-bit floats; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64_im_b"
             , .description =
                \\Division on 64-bit floats; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
         }
        },
        .{ .base_name = "rem"
         , .description =
            \\Remainder division on two operands, with the result placed in a register designated by the third operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .prefix = "u"
             , .suffix = "8"
             , .description =
                \\Unsigned remainder division on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16"
             , .description =
                \\Unsigned remainder division on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32"
             , .description =
                \\Unsigned remainder division on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64"
             , .description =
                \\Unsigned remainder division on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "8_im_a"
             , .description =
                \\Unsigned remainder division on 8-bit integers; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16_im_a"
             , .description =
                \\Unsigned remainder division on 16-bit integers; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32_im_a"
             , .description =
                \\Unsigned remainder division on 32-bit integers; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64_im_a"
             , .description =
                \\Unsigned remainder division on 64-bit integers; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "u"
             , .suffix = "8_im_b"
             , .description =
                \\Unsigned remainder division on 8-bit integers; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .byte, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16_im_b"
             , .description =
                \\Unsigned remainder division on 16-bit integers; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .short, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32_im_b"
             , .description =
                \\Unsigned remainder division on 32-bit integers; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64_im_b"
             , .description =
                \\Unsigned remainder division on 64-bit integers; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },

            .{ .prefix = "s"
             , .suffix = "8"
             , .description =
                \\Signed remainder division on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16"
             , .description =
                \\Signed remainder division on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32"
             , .description =
                \\Signed remainder division on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64"
             , .description =
                \\Signed remainder division on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "8_im_a"
             , .description =
                \\Signed remainder division on 8-bit integers; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16_im_a"
             , .description =
                \\Signed remainder division on 16-bit integers; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32_im_a"
             , .description =
                \\Signed remainder division on 32-bit integers; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64_im_a"
             , .description =
                \\Signed remainder division on 64-bit integers; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "s"
             , .suffix = "8_im_b"
             , .description =
                \\Signed remainder division on 8-bit integers; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .byte, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16_im_b"
             , .description =
                \\Signed remainder division on 16-bit integers; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .short, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32_im_b"
             , .description =
                \\Signed remainder division on 32-bit integers; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64_im_b"
             , .description =
                \\Signed remainder division on 64-bit integers; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },

            .{ .prefix = "f"
             , .suffix = "32"
             , .description =
                \\Remainder division on 32-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64"
             , .description =
                \\Remainder division on 64-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "32_im_a"
             , .description =
                \\Remainder division on 32-bit floats; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64_im_a"
             , .description =
                \\Remainder division on 64-bit floats; immediate dividend, register divisor
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "f"
             , .suffix = "32_im_b"
             , .description =
                \\Remainder division on 32-bit floats; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64_im_b"
             , .description =
                \\Remainder division on 64-bit floats; register dividend, immediate divisor
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
         }
        },
        .{ .base_name = "neg"
         , .description =
            \\Negation of a single operand, with the result placed in a register designated by the second operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .prefix = "s"
             , .suffix = "8"
             , .description =
                \\Negation of an 8-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16"
             , .description =
                \\Negation of a 16-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32"
             , .description =
                \\Negation of a 32-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64"
             , .description =
                \\Negation of a 64-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "32"
             , .description =
                \\Negation of a 32-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64"
             , .description =
                \\Negation of a 64-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
         }
        },
     }
    },
    .{ .name = "Bitwise"
     , .description =
        \\Basic bitwise operations
     , .kinds = &[_]InstructionKind {
        .{ .base_name = "band"
         , .description =
            \\Bitwise AND on two operands, with the result placed in a register designated by the third operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .suffix = "8"
             , .description =
                \\Bitwise AND on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .suffix = "16"
             , .description =
                \\Bitwise AND on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .suffix = "32"
             , .description =
                \\Bitwise AND on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .suffix = "64"
             , .description =
                \\Bitwise AND on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .suffix = "8_im"
             , .description =
                \\Bitwise AND on 8-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .suffix = "16_im"
             , .description =
                \\Bitwise AND on 16-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .suffix = "32_im"
             , .description =
                \\Bitwise AND on 32-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .suffix = "64_im"
             , .description =
                \\Bitwise AND on 64-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
         }
        },
        .{ .base_name = "bor"
         , .description =
            \\Bitwise OR on two operands, with the result placed in a register designated by the third operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .suffix = "8"
             , .description =
                \\Bitwise OR on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .suffix = "16"
             , .description =
                \\Bitwise OR on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .suffix = "32"
             , .description =
                \\Bitwise OR on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .suffix = "64"
             , .description =
                \\Bitwise OR on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .suffix = "8_im"
             , .description =
                \\Bitwise OR on 8-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .suffix = "16_im"
             , .description =
                \\Bitwise OR on 16-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .suffix = "32_im"
             , .description =
                \\Bitwise OR on 32-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .suffix = "64_im"
             , .description =
                \\Bitwise OR on 64-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
         }
        },
        .{ .base_name = "bxor"
         , .description =
            \\Bitwise XOR on two operands, with the result placed in a register designated by the third operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .suffix = "8"
             , .description =
                \\Bitwise XOR on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .suffix = "16"
             , .description =
                \\Bitwise XOR on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .suffix = "32"
             , .description =
                \\Bitwise XOR on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .suffix = "64"
             , .description =
                \\Bitwise XOR on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .suffix = "8_im"
             , .description =
                \\Bitwise XOR on 8-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .suffix = "16_im"
             , .description =
                \\Bitwise XOR on 16-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .suffix = "32_im"
             , .description =
                \\Bitwise XOR on 32-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .suffix = "64_im"
             , .description =
                \\Bitwise XOR on 64-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
         }
        },
        .{ .base_name = "bnot"
         , .description =
            \\Bitwise NOT on a single operand, with the result placed in a register designated by the second operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .suffix = "8"
             , .description =
                \\Bitwise NOT on an 8-bit integer in a register
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .suffix = "16"
             , .description =
                \\Bitwise NOT on a 16-bit integer in registers
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .suffix = "32"
             , .description =
                \\Bitwise NOT on a 32-bit integer in a register
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .suffix = "64"
             , .description =
                \\Bitwise NOT on a 64-bit integer in a register
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
         }
        },
        .{ .base_name = "bshiftl"
         , .description =
            \\Bitwise left shift on two operands, with the result placed in a register designated by the third operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .suffix = "8"
             , .description =
                \\Bitwise left shift on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .suffix = "16"
             , .description =
                \\Bitwise left shift on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .suffix = "32"
             , .description =
                \\Bitwise left shift on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .suffix = "64"
             , .description =
                \\Bitwise left shift on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .suffix = "8_im_a"
             , .description =
                \\Bitwise left shift on 8-bit integers; the shifted value is immediate, the shift count is in a register
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .suffix = "16_im_a"
             , .description =
                \\Bitwise left shift on 16-bit integers; the shifted value is immediate, the shift count is in a register
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .suffix = "32_im_a"
             , .description =
                \\Bitwise left shift on 32-bit integers; the shifted value is immediate, the shift count is in a register
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .suffix = "64_im_a"
             , .description =
                \\Bitwise left shift on 64-bit integers; the shifted value is immediate, the shift count is in a register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .suffix = "8_im_b"
             , .description =
                \\Bitwise left shift on 8-bit integers; the shifted value is in a register, the shift count is immediate
             , .operands = &[_]OperandDescriptor { .register, .byte, .register }
            },
            .{ .suffix = "16_im_b"
             , .description =
                \\Bitwise left shift on 16-bit integers; the shifted value is in a register, the shift count is immediate
             , .operands = &[_]OperandDescriptor { .register, .short, .register }
            },
            .{ .suffix = "32_im_b"
             , .description =
                \\Bitwise left shift on 32-bit integers; the shifted value is in a register, the shift count is immediate
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .suffix = "64_im_b"
             , .description =
                \\Bitwise left shift on 64-bit integers; the shifted value is in a register, the shift count is immediate
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
         }
        },
        .{ .base_name = "bshiftr"
         , .description =
            \\Bitwise right shift on two operands, with the result placed in a register designated by the third operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .prefix = "u"
             , .suffix = "8"
             , .description =
                \\Logical bitwise right shift on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16"
             , .description =
                \\Logical bitwise right shift on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32"
             , .description =
                \\Logical bitwise right shift on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64"
             , .description =
                \\Logical bitwise right shift on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "8_im_a"
             , .description =
                \\Logical bitwise right shift on 8-bit integers; the shifted value is immediate, the shift count is in a register
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16_im_a"
             , .description =
                \\Logical bitwise right shift on 16-bit integers; the shifted value is immediate, the shift count is in a register
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32_im_a"
             , .description =
                \\Logical bitwise right shift on 32-bit integers; the shifted value is immediate, the shift count is in a register
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64_im_a"
             , .description =
                \\Logical bitwise right shift on 64-bit integers; the shifted value is immediate, the shift count is in a register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "u"
             , .suffix = "8_im_b"
             , .description =
                \\Logical bitwise right shift on 8-bit integers; the shifted value is in a register, the shift count is immediate
             , .operands = &[_]OperandDescriptor { .register, .byte, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16_im_b"
             , .description =
                \\Logical bitwise right shift on 16-bit integers; the shifted value is in a register, the shift count is immediate
             , .operands = &[_]OperandDescriptor { .register, .short, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32_im_b"
             , .description =
                \\Logical bitwise right shift on 32-bit integers; the shifted value is in a register, the shift count is immediate
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64_im_b"
             , .description =
                \\Logical bitwise right shift on 64-bit integers; the shifted value is in a register, the shift count is immediate
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },

            .{ .prefix = "s"
             , .suffix = "8"
             , .description =
                \\Arithmetic bitwise right shift on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16"
             , .description =
                \\Arithmetic bitwise right shift on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32"
             , .description =
                \\Arithmetic bitwise right shift on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64"
             , .description =
                \\Arithmetic bitwise right shift on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "8_im_a"
             , .description =
                \\Arithmetic bitwise right shift on 8-bit integers; the shifted value is immediate, the shift count is in a register
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16_im_a"
             , .description =
                \\Arithmetic bitwise right shift on 16-bit integers; the shifted value is immediate, the shift count is in a register
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32_im_a"
             , .description =
                \\Arithmetic bitwise right shift on 32-bit integers; the shifted value is immediate, the shift count is in a register
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64_im_a"
             , .description =
                \\Arithmetic bitwise right shift on 64-bit integers; the shifted value is immediate, the shift count is in a register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "s"
             , .suffix = "8_im_b"
             , .description =
                \\Arithmetic bitwise right shift on 8-bit integers; the shifted value is in a register, the shift count is immediate
             , .operands = &[_]OperandDescriptor { .register, .byte, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16_im_b"
             , .description =
                \\Arithmetic bitwise right shift on 16-bit integers; the shifted value is in a register, the shift count is immediate
             , .operands = &[_]OperandDescriptor { .register, .short, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32_im_b"
             , .description =
                \\Arithmetic bitwise right shift on 32-bit integers; the shifted value is in a register, the shift count is immediate
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64_im_b"
             , .description =
                \\Arithmetic bitwise right shift on 64-bit integers; the shifted value is in a register, the shift count is immediate
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
         }
        },
     }
    },
    .{ .name = "Comparison"
     , .description =
        \\Value comparison operations
     , .kinds = &[_]InstructionKind {
        .{ .base_name = "eq"
         , .description =
            \\Equality comparison on two operands, with the result placed in a register designated by the third operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .prefix = "i"
             , .suffix = "8"
             , .description =
                \\Sign-agnostic equality comparison on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "16"
             , .description =
                \\Sign-agnostic equality comparison on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "32"
             , .description =
                \\Sign-agnostic equality comparison on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "64"
             , .description =
                \\Sign-agnostic equality comparison on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "8_im"
             , .description =
                \\Sign-agnostic equality comparison on 8-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "16_im"
             , .description =
                \\Sign-agnostic equality comparison on 16-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "32_im"
             , .description =
                \\Sign-agnostic equality comparison on 32-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "64_im"
             , .description =
                \\Sign-agnostic equality comparison on 64-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },

            .{ .prefix = "f"
             , .suffix = "32"
             , .description =
                \\Equality comparison on 32-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64"
             , .description =
                \\Equality comparison on 64-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "32_im"
             , .description =
                \\Equality comparison on 32-bit floats; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64_im"
             , .description =
                \\Equality comparison on 64-bit floats; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
         }
        },
        .{ .base_name = "ne"
         , .description =
            \\Inequality comparison on two operands, with the result placed in a register designated by the third operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .prefix = "i"
             , .suffix = "8"
             , .description =
                \\Sign-agnostic inequality comparison on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "16"
             , .description =
                \\Sign-agnostic inequality comparison on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "32"
             , .description =
                \\Sign-agnostic inequality comparison on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "64"
             , .description =
                \\Sign-agnostic inequality comparison on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "8_im"
             , .description =
                \\Sign-agnostic inequality comparison on 8-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "16_im"
             , .description =
                \\Sign-agnostic inequality comparison on 16-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "32_im"
             , .description =
                \\Sign-agnostic inequality comparison on 32-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "64_im"
             , .description =
                \\Sign-agnostic inequality comparison on 64-bit integers; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },

            .{ .prefix = "f"
             , .suffix = "32"
             , .description =
                \\Inequality comparison on 32-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64"
             , .description =
                \\Inequality comparison on 64-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "32_im"
             , .description =
                \\Inequality comparison on 32-bit floats; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64_im"
             , .description =
                \\Inequality comparison on 64-bit floats; one immediate, one in a register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
         }
        },
        .{ .base_name = "lt"
         , .description =
            \\Less than comparison on two operands, with the result placed in a register designated by the third operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .prefix = "u"
             , .suffix = "8"
             , .description =
                \\Unsigned less than comparison on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16"
             , .description =
                \\Unsigned less than comparison on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32"
             , .description =
                \\Unsigned less than comparison on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64"
             , .description =
                \\Unsigned less than comparison on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "8_im_a"
             , .description =
                \\Unsigned less than comparison on 8-bit integers; check register less than immediate
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16_im_a"
             , .description =
                \\Unsigned less than comparison on 16-bit integers; check register less than immediate
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32_im_a"
             , .description =
                \\Unsigned less than comparison on 32-bit integers; check register less than immediate
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64_im_a"
             , .description =
                \\Unsigned less than comparison on 64-bit integers; check register less than immediate
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "u"
             , .suffix = "8_im_b"
             , .description =
                \\Unsigned less than comparison on 8-bit integers; check immediate less than register
             , .operands = &[_]OperandDescriptor { .register, .byte, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16_im_b"
             , .description =
                \\Unsigned less than comparison on 16-bit integers; check immediate less than register
             , .operands = &[_]OperandDescriptor { .register, .short, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32_im_b"
             , .description =
                \\Unsigned less than comparison on 32-bit integers; check immediate less than register
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64_im_b"
             , .description =
                \\Unsigned less than comparison on 64-bit integers; check immediate less than register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },

            .{ .prefix = "s"
             , .suffix = "8"
             , .description =
                \\Signed less than comparison on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16"
             , .description =
                \\Signed less than comparison on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32"
             , .description =
                \\Signed less than comparison on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64"
             , .description =
                \\Signed less than comparison on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "8_im_a"
             , .description =
                \\Signed less than comparison on 8-bit integers; check register less than immediate
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16_im_a"
             , .description =
                \\Signed less than comparison on 16-bit integers; check register less than immediate
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32_im_a"
             , .description =
                \\Signed less than comparison on 32-bit integers; check register less than immediate
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64_im_a"
             , .description =
                \\Signed less than comparison on 64-bit integers; check register less than immediate
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "s"
             , .suffix = "8_im_b"
             , .description =
                \\Signed less than comparison on 8-bit integers; check immediate less than register
             , .operands = &[_]OperandDescriptor { .register, .byte, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16_im_b"
             , .description =
                \\Signed less than comparison on 16-bit integers; check immediate less than register
             , .operands = &[_]OperandDescriptor { .register, .short, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32_im_b"
             , .description =
                \\Signed less than comparison on 32-bit integers; check immediate less than register
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64_im_b"
             , .description =
                \\Signed less than comparison on 64-bit integers; check immediate less than register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },

            .{ .prefix = "f"
             , .suffix = "32"
             , .description =
                \\Less than comparison on 32-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64"
             , .description =
                \\Less than comparison on 64-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "32_im_a"
             , .description =
                \\Less than comparison on 32-bit floats; one immediate; check register less than immediate
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64_im_a"
             , .description =
                \\Less than comparison on 64-bit floats; one immediate; check register less than immediate
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "f"
             , .suffix = "32_im_b"
             , .description =
                \\Less than comparison on 32-bit floats; check immediate less than register
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64_im_b"
             , .description =
                \\Less than comparison on 64-bit floats; check immediate less than register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
         }
        },
        .{ .base_name = "gt"
         , .description =
            \\Greater than comparison on two operands, with the result placed in a register designated by the third operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .prefix = "u"
             , .suffix = "8"
             , .description =
                \\Unsigned greater than comparison on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16"
             , .description =
                \\Unsigned greater than comparison on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32"
             , .description =
                \\Unsigned greater than comparison on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64"
             , .description =
                \\Unsigned greater than comparison on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "8_im_a"
             , .description =
                \\Unsigned greater than comparison on 8-bit integers; check register greater than immediate
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16_im_a"
             , .description =
                \\Unsigned greater than comparison on 16-bit integers; check register greater than immediate
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32_im_a"
             , .description =
                \\Unsigned greater than comparison on 32-bit integers; check register greater than immediate
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64_im_a"
             , .description =
                \\Unsigned greater than comparison on 64-bit integers; check register greater than immediate
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "u"
             , .suffix = "8_im_b"
             , .description =
                \\Unsigned greater than comparison on 8-bit integers; check immediate greater than register
             , .operands = &[_]OperandDescriptor { .register, .byte, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16_im_b"
             , .description =
                \\Unsigned greater than comparison on 16-bit integers; check immediate greater than register
             , .operands = &[_]OperandDescriptor { .register, .short, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32_im_b"
             , .description =
                \\Unsigned greater than comparison on 32-bit integers; check immediate greater than register
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64_im_b"
             , .description =
                \\Unsigned greater than comparison on 64-bit integers; check immediate greater than register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },

            .{ .prefix = "s"
             , .suffix = "8"
             , .description =
                \\Signed greater than comparison on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16"
             , .description =
                \\Signed greater than comparison on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32"
             , .description =
                \\Signed greater than comparison on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64"
             , .description =
                \\Signed greater than comparison on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "8_im_a"
             , .description =
                \\Signed greater than comparison on 8-bit integers; check register greater than immediate
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16_im_a"
             , .description =
                \\Signed greater than comparison on 16-bit integers; check register greater than immediate
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32_im_a"
             , .description =
                \\Signed greater than comparison on 32-bit integers; check register greater than immediate
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64_im_a"
             , .description =
                \\Signed greater than comparison on 64-bit integers; check register greater than immediate
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "s"
             , .suffix = "8_im_b"
             , .description =
                \\Signed greater than comparison on 8-bit integers; check immediate greater than register
             , .operands = &[_]OperandDescriptor { .register, .byte, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16_im_b"
             , .description =
                \\Signed greater than comparison on 16-bit integers; check immediate greater than register
             , .operands = &[_]OperandDescriptor { .register, .short, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32_im_b"
             , .description =
                \\Signed greater than comparison on 32-bit integers; check immediate greater than register
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64_im_b"
             , .description =
                \\Signed greater than comparison on 64-bit integers; check immediate greater than register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },

            .{ .prefix = "f"
             , .suffix = "32"
             , .description =
                \\Greater than comparison on 32-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64"
             , .description =
                \\Greater than comparison on 64-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "32_im_a"
             , .description =
                \\Greater than comparison on 32-bit floats; one immediate; check register less than immediate
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64_im_a"
             , .description =
                \\Greater than comparison on 64-bit floats; one immediate; check register less than immediate
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "f"
             , .suffix = "32_im_b"
             , .description =
                \\Greater than comparison on 32-bit floats; check immediate less than register
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64_im_b"
             , .description =
                \\Greater than comparison on 64-bit floats; check immediate less than register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
         }
        },
        .{ .base_name = "le"
         , .description =
            \\Less than or equal comparison on two operands, with the result placed in a register designated by the third operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .prefix = "u"
             , .suffix = "8"
             , .description =
                \\Unsigned less than or equal comparison on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16"
             , .description =
                \\Unsigned less than or equal comparison on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32"
             , .description =
                \\Unsigned less than or equal comparison on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64"
             , .description =
                \\Unsigned less than or equal comparison on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "8_im_a"
             , .description =
                \\Unsigned less than or equal comparison on 8-bit integers; check register less than or equal immediate
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16_im_a"
             , .description =
                \\Unsigned less than or equal comparison on 16-bit integers; check register less than or equal immediate
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32_im_a"
             , .description =
                \\Unsigned less than or equal comparison on 32-bit integers; check register less than or equal immediate
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64_im_a"
             , .description =
                \\Unsigned less than or equal comparison on 64-bit integers; check register less than or equal immediate
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "u"
             , .suffix = "8_im_b"
             , .description =
                \\Unsigned less than or equal comparison on 8-bit integers; check immediate less than or equal register
             , .operands = &[_]OperandDescriptor { .register, .byte, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16_im_b"
             , .description =
                \\Unsigned less than or equal comparison on 16-bit integers; check immediate less than or equal register
             , .operands = &[_]OperandDescriptor { .register, .short, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32_im_b"
             , .description =
                \\Unsigned less than or equal comparison on 32-bit integers; check immediate less than or equal register
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64_im_b"
             , .description =
                \\Unsigned less than or equal comparison on 64-bit integers; check immediate less than or equal register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },

            .{ .prefix = "s"
             , .suffix = "8"
             , .description =
                \\Signed less than or equal comparison on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16"
             , .description =
                \\Signed less than or equal comparison on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32"
             , .description =
                \\Signed less than or equal comparison on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64"
             , .description =
                \\Signed less than or equal comparison on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "8_im_a"
             , .description =
                \\Signed less than or equal comparison on 8-bit integers; check register less than or equal immediate
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16_im_a"
             , .description =
                \\Signed less than or equal comparison on 16-bit integers; check register less than or equal immediate
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32_im_a"
             , .description =
                \\Signed less than or equal comparison on 32-bit integers; check register less than or equal immediate
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64_im_a"
             , .description =
                \\Signed less than or equal comparison on 64-bit integers; check register less than or equal immediate
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "s"
             , .suffix = "8_im_b"
             , .description =
                \\Signed less than or equal comparison on 8-bit integers; check immediate less than or equal register
             , .operands = &[_]OperandDescriptor { .register, .byte, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16_im_b"
             , .description =
                \\Signed less than or equal comparison on 16-bit integers; check immediate less than or equal register
             , .operands = &[_]OperandDescriptor { .register, .short, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32_im_b"
             , .description =
                \\Signed less than or equal comparison on 32-bit integers; check immediate less than or equal register
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64_im_b"
             , .description =
                \\Signed less than or equal comparison on 64-bit integers; check immediate less than or equal register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },

            .{ .prefix = "f"
             , .suffix = "32"
             , .description =
                \\Less than or equal comparison on 32-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64"
             , .description =
                \\Less than or equal comparison on 64-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "32_im_a"
             , .description =
                \\Less than or equal comparison on 32-bit floats; one immediate; check register less than or equal immediate
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64_im_a"
             , .description =
                \\Less than or equal comparison on 64-bit floats; one immediate; check register less than or equal immediate
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "f"
             , .suffix = "32_im_b"
             , .description =
                \\Less than or equal comparison on 32-bit floats; check immediate less than or equal register
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64_im_b"
             , .description =
                \\Less than or equal comparison on 64-bit floats; check immediate less than or equal register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
         }
        },
        .{ .base_name = "ge"
         , .description =
            \\Greater than or equal comparison on two operands, with the result placed in a register designated by the third operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .prefix = "u"
             , .suffix = "8"
             , .description =
                \\Unsigned greater than or equal comparison on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16"
             , .description =
                \\Unsigned greater than or equal comparison on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32"
             , .description =
                \\Unsigned greater than or equal comparison on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64"
             , .description =
                \\Unsigned greater than or equal comparison on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "8_im_a"
             , .description =
                \\Unsigned greater than or equal comparison on 8-bit integers; check register greater than or equal immediate
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16_im_a"
             , .description =
                \\Unsigned greater than or equal comparison on 16-bit integers; check register greater than or equal immediate
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32_im_a"
             , .description =
                \\Unsigned greater than or equal comparison on 32-bit integers; check register greater than or equal immediate
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64_im_a"
             , .description =
                \\Unsigned greater than or equal comparison on 64-bit integers; check register greater than or equal immediate
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "u"
             , .suffix = "8_im_b"
             , .description =
                \\Unsigned greater than or equal comparison on 8-bit integers; check immediate greater than or equal register
             , .operands = &[_]OperandDescriptor { .register, .byte, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16_im_b"
             , .description =
                \\Unsigned greater than or equal comparison on 16-bit integers; check immediate greater than or equal register
             , .operands = &[_]OperandDescriptor { .register, .short, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32_im_b"
             , .description =
                \\Unsigned greater than or equal comparison on 32-bit integers; check immediate greater than or equal register
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "u"
             , .suffix = "64_im_b"
             , .description =
                \\Unsigned greater than or equal comparison on 64-bit integers; check immediate greater than or equal register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },

            .{ .prefix = "s"
             , .suffix = "8"
             , .description =
                \\Signed greater than or equal comparison on 8-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16"
             , .description =
                \\Signed greater than or equal comparison on 16-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32"
             , .description =
                \\Signed greater than or equal comparison on 32-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64"
             , .description =
                \\Signed greater than or equal comparison on 64-bit integers in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "8_im_a"
             , .description =
                \\Signed greater than or equal comparison on 8-bit integers; check register greater than or equal immediate
             , .operands = &[_]OperandDescriptor { .byte, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16_im_a"
             , .description =
                \\Signed greater than or equal comparison on 16-bit integers; check register greater than or equal immediate
             , .operands = &[_]OperandDescriptor { .short, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32_im_a"
             , .description =
                \\Signed greater than or equal comparison on 32-bit integers; check register greater than or equal immediate
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64_im_a"
             , .description =
                \\Signed greater than or equal comparison on 64-bit integers; check register greater than or equal immediate
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "s"
             , .suffix = "8_im_b"
             , .description =
                \\Signed greater than or equal comparison on 8-bit integers; check immediate greater than or equal register
             , .operands = &[_]OperandDescriptor { .register, .byte, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16_im_b"
             , .description =
                \\Signed greater than or equal comparison on 16-bit integers; check immediate greater than or equal register
             , .operands = &[_]OperandDescriptor { .register, .short, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32_im_b"
             , .description =
                \\Signed greater than or equal comparison on 32-bit integers; check immediate greater than or equal register
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "s"
             , .suffix = "64_im_b"
             , .description =
                \\Signed greater than or equal comparison on 64-bit integers; check immediate greater than or equal register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },

            .{ .prefix = "f"
             , .suffix = "32"
             , .description =
                \\Greater than or equal comparison on 32-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64"
             , .description =
                \\Greater than or equal comparison on 64-bit floats in registers
             , .operands = &[_]OperandDescriptor { .register, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "32_im_a"
             , .description =
                \\Greater than or equal comparison on 32-bit floats; one immediate; check register less than or equal immediate
             , .operands = &[_]OperandDescriptor { .immediate, .register, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64_im_a"
             , .description =
                \\Greater than or equal comparison on 64-bit floats; one immediate; check register less than or equal immediate
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
            .{ .prefix = "f"
             , .suffix = "32_im_b"
             , .description =
                \\Greater than or equal comparison on 32-bit floats; check immediate less than or equal register
             , .operands = &[_]OperandDescriptor { .register, .immediate, .register }
            },
            .{ .prefix = "f"
             , .suffix = "64_im_b"
             , .description =
                \\Greater than or equal comparison on 64-bit floats; check immediate less than or equal register
             , .operands = &[_]OperandDescriptor { .register, .register }
             , .wide_immediate = true
            },
          }
         },
     }
    },
    .{ .name = "Conversion"
     , .description =
        \\Convert between different types and sizes of values
     , .kinds = &[_]InstructionKind {
        .{ .base_name = "ext"
         , .description =
            \\Convert a value in a register to a larger size, with the result placed in a register designated by the second operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .prefix = "u"
             , .suffix = "8_16"
             , .description =
                \\Zero-extend an 8-bit integer to a 16-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "8_32"
             , .description =
                \\Zero-extend an 8-bit integer to a 32-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "8_64"
             , .description =
                \\Zero-extend an 8-bit integer to a 64-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16_32"
             , .description =
                \\Zero-extend a 16-bit integer to a 32-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "16_64"
             , .description =
                \\Zero-extend a 16-bit integer to a 64-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "u"
             , .suffix = "32_64"
             , .description =
                \\Zero-extend a 32-bit integer to a 64-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },

            .{ .prefix = "s"
             , .suffix = "8_16"
             , .description =
                \\Sign-extend an 8-bit integer to a 16-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "8_32"
             , .description =
                \\Sign-extend an 8-bit integer to a 32-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "8_64"
             , .description =
                \\Sign-extend an 8-bit integer to a 64-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16_32"
             , .description =
                \\Sign-extend a 16-bit integer to a 32-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "16_64"
             , .description =
                \\Sign-extend a 16-bit integer to a 64-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "s"
             , .suffix = "32_64"
             , .description =
                \\Sign-extend a 32-bit integer to a 64-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },

            .{ .prefix = "f"
             , .suffix = "32_64"
             , .description =
                \\Convert a 32-bit float to a 64-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
         }
        },
        .{ .base_name = "trunc"
         , .description =
            \\Convert a value in a register to a smaller size, with the result placed in a register designated by the second operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .prefix = "i"
             , .suffix = "64_32"
             , .description =
                \\Truncate a 64-bit integer to a 32-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "64_16"
             , .description =
                \\Truncate a 64-bit integer to a 16-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "64_8"
             , .description =
                \\Truncate a 64-bit integer to an 8-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "32_16"
             , .description =
                \\Truncate a 32-bit integer to a 16-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "32_8"
             , .description =
                \\Truncate a 32-bit integer to an 8-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "i"
             , .suffix = "16_8"
             , .description =
                \\Truncate a 16-bit integer to an 8-bit integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },

            .{ .prefix = "f"
             , .suffix = "64_32"
             , .description =
                \\Convert a 64-bit float to a 32-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
         }
        },
        .{ .display_name = "cast"
         , .base_name = "to"
         , .description =
            \\Convert a value in a register to a different type, with the result placed in a register designated by the second operand
         , .instructions = &[_]InstructionDescriptor {
            .{ .prefix = "u8"
             , .suffix = "f32"
             , .description =
                \\Convert an 8-bit unsigned integer to a 32-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "u16"
             , .suffix = "f32"
             , .description =
                \\Convert a 16-bit unsigned integer to a 32-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "u32"
             , .suffix = "f32"
             , .description =
                \\Convert a 32-bit unsigned integer to a 32-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "u64"
             , .suffix = "f32"
             , .description =
                \\Convert a 64-bit unsigned integer to a 32-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },

            .{ .prefix = "s8"
             , .suffix = "f32"
             , .description =
                \\Convert an 8-bit signed integer to a 32-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "s16"
             , .suffix = "f32"
             , .description =
                \\Convert a 16-bit signed integer to a 32-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "s32"
             , .suffix = "f32"
             , .description =
                \\Convert a 32-bit signed integer to a 32-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "s64"
             , .suffix = "f32"
             , .description =
                \\Convert a 64-bit signed integer to a 32-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },

            .{ .prefix = "f32"
             , .suffix = "u8"
             , .description =
                \\Convert a 32-bit float to an 8-bit unsigned integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "f32"
             , .suffix = "u16"
             , .description =
                \\Convert a 32-bit float to a 16-bit unsigned integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "f32"
             , .suffix = "u32"
             , .description =
                \\Convert a 32-bit float to a 32-bit unsigned integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "f32"
             , .suffix = "u64"
             , .description =
                \\Convert a 32-bit float to a 64-bit unsigned integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },

            .{ .prefix = "f32"
             , .suffix = "s8"
             , .description =
                \\Convert a 32-bit float to an 8-bit signed integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "f32"
             , .suffix = "s16"
             , .description =
                \\Convert a 32-bit float to a 16-bit signed integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "f32"
             , .suffix = "s32"
             , .description =
                \\Convert a 32-bit float to a 32-bit signed integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "f32"
             , .suffix = "s64"
             , .description =
                \\Convert a 32-bit float to a 64-bit signed integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },

            .{ .prefix = "u8"
             , .suffix = "f64"
             , .description =
                \\Convert an 8-bit unsigned integer to a 64-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "u16"
             , .suffix = "f64"
             , .description =
                \\Convert a 16-bit unsigned integer to a 64-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "u32"
             , .suffix = "f64"
             , .description =
                \\Convert a 32-bit unsigned integer to a 64-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "u64"
             , .suffix = "f64"
             , .description =
                \\Convert a 64-bit unsigned integer to a 64-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },

            .{ .prefix = "s8"
             , .suffix = "f64"
             , .description =
                \\Convert an 8-bit signed integer to a 64-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "s16"
             , .suffix = "f64"
             , .description =
                \\Convert a 16-bit signed integer to a 64-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "s32"
             , .suffix = "f64"
             , .description =
                \\Convert a 32-bit signed integer to a 64-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "s64"
             , .suffix = "f64"
             , .description =
                \\Convert a 64-bit signed integer to a 64-bit float
             , .operands = &[_]OperandDescriptor { .register, .register }
            },

            .{ .prefix = "f64"
             , .suffix = "u8"
             , .description =
                \\Convert a 64-bit float to an 8-bit unsigned integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "f64"
             , .suffix = "u16"
             , .description =
                \\Convert a 64-bit float to a 16-bit unsigned integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "f64"
             , .suffix = "u32"
             , .description =
                \\Convert a 64-bit float to a 32-bit unsigned integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "f64"
             , .suffix = "u64"
             , .description =
                \\Convert a 64-bit float to a 64-bit unsigned integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },

            .{ .prefix = "f64"
             , .suffix = "s8"
             , .description =
                \\Convert a 64-bit float to an 8-bit signed integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "f64"
             , .suffix = "s16"
             , .description =
                \\Convert a 64-bit float to a 16-bit signed integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "f64"
             , .suffix = "s32"
             , .description =
                \\Convert a 64-bit float to a 32-bit signed integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
            .{ .prefix = "f64"
             , .suffix = "s64"
             , .description =
                \\Convert a 64-bit float to a 64-bit signed integer
             , .operands = &[_]OperandDescriptor { .register, .register }
            },
         }
        },
     }
    },
};

pub fn computeInstructionName(comptime kind: InstructionKind, comptime instr: InstructionDescriptor) [:0]const u8 {
    return comptime
        (if (instr.prefix.len > 0) instr.prefix ++ "_" else "")
        ++ kind.base_name
        ++ (if (instr.suffix.len > 0) "_" ++ instr.suffix else "");
}

pub fn getAbbreviation(operandDescriptor: OperandDescriptor) u8 {
    return switch (operandDescriptor) {
        .register => 'R',
        .byte => 'b',
        .short => 's',
        .immediate => 'i',
        .handler_set_index => 'H',
        .evidence_index => 'E',
        .global_index => 'G',
        .upvalue_index => 'U',
        .function_index => 'F',
        .foreign_index => 'X',
        .jump_offset => 'B',
    };
}



pub const ReturnStyle = enum { v, no_v };

pub const InstructionCategory = struct {
    name: [:0]const u8,
    description: [:0]const u8 = "",
    kinds: []const InstructionKind,
};

pub const InstructionKind = struct {
    display_name: ?[:0]const u8 = null,
    base_name: [:0]const u8,
    description: [:0]const u8,
    instructions: []const InstructionDescriptor,

    pub fn humanFriendlyName(comptime kind: InstructionKind) [:0]const u8 {
        return kind.display_name orelse kind.base_name;
    }
};

pub const InstructionDescriptor = struct {
    prefix: [:0]const u8 = "",
    suffix: [:0]const u8 = "",
    description: []const u8,
    operands: []const OperandDescriptor = &[0]OperandDescriptor { },
    wide_immediate: bool = false,
};

pub const OperandDescriptor = enum {
    register,
    byte,
    short,
    immediate,
    handler_set_index,
    evidence_index,
    global_index,
    upvalue_index,
    function_index,
    foreign_index,
    jump_offset,
};
