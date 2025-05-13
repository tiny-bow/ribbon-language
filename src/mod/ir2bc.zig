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
    /// binds fully qualified names to bytecode ids, for the whole program compiled so far
    symbol_table: SymbolTable,
    /// binds bytecode ids to addresses, for the whole program compiled so far
    address_table: AddressTable,
};

/// Data local to the compilation of a single function. Created by `Compiler`, reusable.
pub const Jit = struct {
    /// the root compiler storing common state between jit jobs
    root: *const Compiler,
    /// the ir for the function being compiled
    ir: *const ir.Function,
    /// binds fully qualified names to bytecode ids for the function being compiled
    symbol_table: SymbolTable,
    /// binds bytecode ids to addresses for the function being compiled
    address_table: AddressTable,
};


/// A mirror of `core.SymbolTable` that is extensible.
pub const SymbolTable = pl.StringMap(core.SymbolTable.Value);

/// A mirror of `core.AddressTable` that is extensible.
pub const AddressTable = struct {
    /// Constant value bindings section.
    constants: pl.ArrayList(*const core.Constant) = .empty,
    /// Global value bindings section.
    globals: pl.ArrayList(*const core.Global) = .empty,
    /// Function value bindings section.
    functions: pl.ArrayList(*const core.Function) = .empty,
    /// Builtin function value bindings section.
    builtin_addresses: pl.ArrayList(*const core.BuiltinAddress) = .empty,
    /// C ABI value bindings section.
    foreign_addresses: pl.ArrayList(*const core.ForeignAddress) = .empty,
    /// Effect handler set bindings section.
    handler_sets: pl.ArrayList(*const core.HandlerSet) = .empty,
    /// Effect identity bindings section.
    effects: pl.ArrayList(*const core.Effect) = .empty,

    // validate mirror
    comptime {
        outer: for (std.meta.fieldNames(core.AddressTable)) |core_field| {
            for (std.meta.fieldNames(AddressTable)) |comp_field| {
                if (std.mem.eql(u8, core_field, comp_field)) continue :outer;
            } else {
                @compileError("missing field " ++ core_field ++ " in ir2bc.AddressTable");
            }
        }

        outer: for (std.meta.fieldNames(AddressTable)) |comp_field| {
            for (std.meta.fieldNames(core.AddressTable)) |core_field| {
                if (std.mem.eql(u8, core_field, comp_field)) continue :outer;
            } else {
                @compileError("extra field " ++ comp_field ++ " in ir2bc.AddressTable");
            }
        }

        for (std.meta.fieldNames(AddressTable)) |field| {
            const our_type = @typeInfo(@FieldType(@FieldType(AddressTable, field), "items")).pointer.child;
            const core_type = @FieldType(core.AddressTable, field).ValueType;

            if (our_type != core_type) {
                @compileError("type mismatch for field " ++ field ++ ": expected " ++ @typeName(core_type) ++ ", got " ++ @typeName(our_type));
            }
        }
    }
};
