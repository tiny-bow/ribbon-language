//! Backend compiling Ribbon IR to Ribbon bytecode.

const ir2bc = @This();

const std = @import("std");
const pl = @import("platform");
const ir = @import("ir");
const core = @import("core");
const bytecode = @import("bytecode");

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
    ir: *const ir.Builder,
    // TODO the following types from core contain static buffers, but we will need extensible buffers.
    // theres a bunch of ways we could handle this such as:
    // * grab a larger buffer from `allocator`; expand as necessary, like an ArrayList but manual
    // * create a mirror type using actual arraylists
    // * use a fixed size buffer and just assume we won't need more than that
    // * use virtual memory and commit pages as needed
    // ways we shouldnt handle it include:
    // * rewrite existing type using actual arraylists
    //   > core is meant to be the static binary representation of the language
    /// binds fully qualified names to bytecode ids, for the whole program compiled so far
    symbol_table: core.SymbolTable,
    /// binds bytecode ids to addresses, for the whole program compiled so far
    address_table: core.AddressTable,
};

/// Data local to the compilation of a single function. Created by `Compiler`, reusable.
pub const Jit = struct {
    /// the root compiler storing common state between jit jobs
    root: *const Compiler,
    /// the ir for the function being compiled
    ir: *const ir.Function,
    // TODO same as above but different considerations: we probably just use a fixed size buffer here; its temp data.
    /// binds fully qualified names to bytecode ids for the function being compiled
    symbol_table: core.SymbolTable,
    /// binds bytecode ids to addresses for the function being compiled
    address_table: core.AddressTable,
};
