//! # ir
//! This namespace provides a mid-level hybrid SSA Intermediate Representation (ir) for Ribbon.
//!
//! It is used to represent the program in a way that is easy to optimize and transform.
//!
//! This ir targets:
//! * rvm's core bytecode (via the `bytecode` module)
//! * native machine code, in two ways:
//!    + in house x64 jit (the `machine` module)
//!    + freestanding (eventually)
//!
//! ### TODO
//!
//! #### Core IR Infrastructure & Correctness
//!
//! *   ** Thread Safety:**
//!     *   Currently, the ir context and its contents are not thread-safe.
//!     *   Implement atomic operations for identifier generation.
//!     *   Use mutex for modifications to shared data structures like interned name and data sets.
//!     *   TODO: study plan.md and higher level modules to see if this is necessary.
//!
//! *   ** Serialization/Deserialization:**
//!     *   Create a textual representation of the IR for debugging. This is invaluable for inspecting the output of compiler passes.
//!     *   Implement a binary serialization format for caching IR or saving it for later stages.
//!
//! *   ** Create a Builder API:**
//!     *   Design a `Builder` struct to simplify IR construction.
//!     *   Methods like `builder.setInsertPoint(*Block)`, `builder.createAdd(lhs, rhs, ?name)`, `builder.createBr(dest_block)`.
//!     *   The builder should handle memory allocation for instructions and operands, and automatically link instructions into the block.
//!
//! *   ** Implement an IR Verifier:**
//!     *   Verify that every block ends with a `Termination` instruction.
//!     *   Check that `phi` nodes only appear at the beginning of a block.
//!     *   Validate that the number of `phi` operands matches the number of predecessor blocks.
//!     *   Ensure that an instruction's result is used only by instructions that it dominates (the core SSA property).
//!     *   Type check every instruction, ensuring operand types match what the operation expects.
//!     *   Verify that `prev` and `next` pointers in blocks are consistent.
//!     *   Check that `predecessors` and `successors` lists are correctly maintained.
//!
//! #### Type System (`Term`s)
//!
//! *   ** Implement Type System `TODO`s:**
//!     *   Add support for bit-offset pointers as mentioned in the `PointerType` `TODO`.
//!
//! #### Instruction Set & Semantics
//!
//! *   ** Define User-Defined Operation (`_`) Semantics:**
//!     *   The `Operation._` is only the start for extensibility.
//!         A mechanism is needed for extensions to register these operations,
//!         including their type-checking rules, semantics, and how they are eventually lowered or code-generated.
//! *   ** Specify Intrinsic Functions:**
//!     *   Many operations are better represented as "intrinsics" (special functions known to the compiler) rather than low-level instructions.
//!         This could include things like `memcpy`, `memset`, or complex math operations. Decide which should be instructions vs. intrinsics.
//! *   ** Define `reify` and `lift` Semantics:**
//!     *   The purpose of `reify` (term to SSA) and `lift` (SSA to term) is clear, but their exact semantics and constraints need to be rigorously defined.
//!         For example, what happens if we try to `reify` a type that has no runtime representation?
//!
//! #### Analysis & Transformation Framework
//!
//! *   ** SSA Construction Utilities:**
//!     *   Implement a standard "Mem2Reg" pass that converts stack allocations (`stack_alloc`, `load`, `store`) of local variables into SSA registers (`phi` nodes). This is a cornerstone of building SSA form from an AST.
//!     *   Develop an algorithm for computing dominance frontiers, which is required for placing `phi` nodes.
//! *   ** Create a Pass Manager:**
//!     *   Design a system to schedule and run analysis and transformation passes over the IR.
//!     *   It should handle dependencies between passes (e.g., a dominance analysis must run before Mem2Reg).
//!     *   It should support passes at different granularities (Module, Function, etc.).
//! *   ** Implement Standard Analyses:**
//!     *   **Dominator Tree:** Essential for SSA construction and many optimizations.
//!     *   **Control Flow Graph (CFG) Analysis:** Already partially present with `predecessors`/`successors`, but could be formalized.
//!     *   **Alias Analysis:** To determine if two pointers can refer to the same memory location. Crucial for reordering `load`/`store` operations.
//!     *   **Loop Analysis:** To find loops in the CFG, which are prime candidates for optimization.
//! *   ** Implement Foundational Optimizations:**
//!     *   Constant Folding and Propagation
//!     *   Dead Code Elimination
//!     *   Common Subexpression Elimination
//!     *   Instruction Combining
//!     *   Global Value Numbering (GVN)
//!
//! #### Tooling & Debugging
//!
//! *   ** Source-Level Debug Information:**
//!     *   Extend the IR to carry debug information. `Instruction`s should be able to store a source location (file, line, column).
//!     *   This is non-negotiable for producing debuggable executables.
//! *   ** Graph Visualization:**
//!     *   Write a utility to export the CFG of a `Function` to a format like Graphviz `.dot`. This is one of the most effective ways to debug a compiler's IR.
//!
//! #### Documentation
//!
//! *   ** Write Comprehensive Documentation:**
//!     *   Document the semantics of every single `Operation` and `Termination`.
//!     *   Explain the purpose and structure of every `Term`.
//!     *   Provide a high-level overview of the IR architecture and its design philosophy.
//!     *   Document the invariants that the IR Verifier checks.
const ir = @This();

const std = @import("std");
const log = std.log.scoped(.Rir);

const core = @import("core");
const common = @import("common");
const analysis = @import("analysis");
const bytecode = @import("bytecode");

test {
    // std.debug.print("semantic analysis for ir\n", .{});
    std.testing.refAllDeclsRecursive(@This());
}

pub const terms = @import("ir/terms.zig");
pub const Sma = @import("ir/Sma.zig");
pub const Context = @import("ir/Context.zig");
pub const Term = @import("ir/Term.zig").Term;
pub const Blob = @import("ir/Blob.zig");
pub const Module = @import("ir/Module.zig");
pub const HandlerSet = @import("ir/HandlerSet.zig");
pub const Expression = @import("ir/Expression.zig");
pub const Function = @import("ir/Function.zig");
pub const Block = @import("ir/Block.zig");
pub const Global = @import("ir/Global.zig");
pub const Instruction = @import("ir/Instruction.zig");

/// A reference to an interned symbolic name within the ir context.
pub const Name = struct {
    /// Identifier for a symbolic name within the ir context.
    pub const Id = enum(u32) { _ };

    value: []const u8,
};

/// Canonical Binary Representation (CBR) 16-byte hash type.
pub const Cbr = enum(u128) {
    _,

    /// A hasher for computing canonical binary representation (CBR) hashes.
    pub const Hasher = struct {
        blake: std.crypto.hash.Blake3,

        /// Initialize a new Cbr.Hasher.
        pub fn init() Cbr.Hasher {
            return Cbr.Hasher{
                .blake = std.crypto.hash.Blake3.init(.{}),
            };
        }

        /// Update the hasher with the given value converted to bytes.
        pub inline fn update(self: *Cbr.Hasher, value: anytype) void {
            const T_info = @typeInfo(@TypeOf(value));
            if (comptime T_info == .pointer) {
                if (comptime T_info.pointer.child == u8) {
                    if (comptime T_info.pointer.size == .slice) {
                        self.blake.update(value);
                    } else {
                        self.blake.update(std.mem.span(value));
                    }
                } else {
                    self.blake.update(std.mem.asBytes(value));
                }
            } else {
                self.blake.update(std.mem.asBytes(&value));
            }
        }

        /// Finalize the hasher and return the resulting value.
        pub fn final(self: *Cbr.Hasher) Cbr {
            var out: Cbr = @enumFromInt(0);
            self.blake.final(std.mem.asBytes(&out));
            return out;
        }
    };
};

/// Wrapper for Fnv1a_64 hasher for quick hashing needs.
pub const QuickHasher = struct {
    fnv: std.hash.Fnv1a_64,

    /// Initialize a new QuickHasher.
    pub fn init() QuickHasher {
        return QuickHasher{
            .fnv = std.hash.Fnv1a_64.init(),
        };
    }

    /// Update the hasher with the given value converted to bytes.
    pub inline fn update(self: *QuickHasher, value: anytype) void {
        const T_info = @typeInfo(@TypeOf(value));
        if (comptime T_info == .pointer) {
            if (comptime T_info.pointer.child == u8) {
                if (comptime T_info.pointer.size == .slice) {
                    self.fnv.update(value);
                } else {
                    self.fnv.update(std.mem.span(value));
                }
            } else {
                self.fnv.update(std.mem.asBytes(value));
            }
        } else {
            self.fnv.update(std.mem.asBytes(&value));
        }
    }

    /// Finalize the hasher and return the resulting hash value.
    pub fn final(self: *QuickHasher) u64 {
        return self.fnv.final();
    }
};
