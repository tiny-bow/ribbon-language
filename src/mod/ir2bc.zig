//! Backend compiling Ribbon IR to Ribbon bytecode.

const ir2bc = @This();

const std = @import("std");
const pl = @import("platform");
const ir = @import("ir");
const core = @import("core");
const bytecode = @import("bytecode");
const Id = @import("Id");

test {
    std.testing.refAllDeclsRecursive(@This());
}

/// Compilation state for the whole program, kept alive between `Jit` compilation jobs.
pub const Compiler = struct {
    /// the allocator to use for compiler intermediate data
    /// * this can be different from the allocator used for `ir`
    allocator: std.mem.Allocator,
    /// the ir for the whole program.
    /// can be appended to, but not (yet, anyway) mutated;
    /// not all IR is necessarily compiled at any given time.
    ir: *ir.Context,
    /// table for the whole program compiled thus far
    table: bytecode.Table,
};

/// Data local to the compilation of a single function. Created by `Compiler`, reusable.
pub const Jit = struct {
    /// The root compiler storing common state between jit jobs
    root: *const Compiler,
    /// The ir for the function being compiled
    // ir: *const ir.Function,
    /// Local table for the function being compiled
    table: bytecode.Table,

    // /// Reset the Jit-local state for the compilation of a new function.
    // pub fn reset(self: *Jit, new_function: *const ir.Function) void {
    //     self.table.clear();
    //     self.ir = new_function;
    // }
};
