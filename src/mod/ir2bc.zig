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

/// Compilation state for the whole program, kept alive between compilation jobs.
pub const Compiler = struct {
    /// the allocator to use for compiler intermediate data
    /// * this can be different from the allocator used for `ir`
    allocator: std.mem.Allocator,
    /// the ir for the whole program compiled thus far
    ir: *ir.Context,
    /// table for the whole program compiled thus far
    table: bytecode.Table,
};

/// Data local to the compilation of a specific set of values. Created by `Compiler`, reusable.
pub const Job = struct {
    /// The root compiler storing common state between jobs
    root: *Compiler,
    /// The ir segment being compiled
    ir: *ir.Context,
    /// Local table for symbols being compiled
    table: bytecode.Table,

    /// Reset the job-local state for the compilation of a new set of values.
    pub fn reset(self: *Job) void {
        self.table.clear();
        self.ir.clear();
    }
};
