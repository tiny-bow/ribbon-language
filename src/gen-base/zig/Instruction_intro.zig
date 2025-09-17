// This file is only a template for `bin/tools/gen`;
// See `Instruction` for the full document; `gen.zig/#generateTypes` for the generator //

//! # Instruction
//! The instruction module is both the abstract data type representing a Ribbon bytecode instruction,
//! and the namespace for the opcode and operand definitions.
//!
//! * **IMPORTANT**: "Abstract data type" here means that the `Instruction` struct carries the same data,
//! but not in the same way, as an actual bytecode instruction stream. The layout and size is different.
//!
//! See the `bytecode` namespace for encoding and decoding utilities.
const Instruction = @This();
const core = @import("core");
const Id = @import("common").Id;
const common = @import("common");
const std = @import("std");

const log = std.log.scoped(.Instruction);

test {
    // std.debug.print("semantic analysis for Instruction\n", .{});
    std.testing.refAllDeclsRecursive(@This());
}
