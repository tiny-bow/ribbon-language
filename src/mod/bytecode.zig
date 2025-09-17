//! # bytecode
//! This is a namespace for Ribbon bytecode data types, and the builder api.
const bytecode = @This();

const std = @import("std");
const common = @import("common");
const core = @import("core");
const binary = @import("binary");

pub const Instruction = @import("Instruction");

pub const Decoder = @import("bytecode/Decoder.zig");
pub const ProtoInstr = @import("bytecode/ProtoInstr.zig");

pub const TableBuilder = @import("bytecode/TableBuilder.zig");
pub const HeaderBuilder = @import("bytecode/HeaderBuilder.zig");
pub const SymbolTableBuilder = @import("bytecode/SymbolTableBuilder.zig");
pub const AddressTableBuilder = @import("bytecode/AddressTableBuilder.zig");
pub const DataBuilder = @import("bytecode/DataBuilder.zig");
pub const HandlerSetBuilder = @import("bytecode/HandlerSetBuilder.zig");
pub const FunctionBuilder = @import("bytecode/FunctionBuilder.zig");
pub const SequenceBuilder = @import("bytecode/SequenceBuilder.zig");
pub const BlockBuilder = @import("bytecode/BlockBuilder.zig");

test {
    // std.debug.print("semantic analysis for bytecode\n", .{});
    std.testing.refAllDecls(@This());
}

/// Error type shared by bytecode apis.
pub const Error = binary.Error;

/// A map from core.LocalId to core.Layout, representing the local variables of a function.
pub const LocalMap = common.UniqueReprArrayMap(core.LocalId, core.Layout);

/// A map from core.LocalId to a stack operand offset. Used by address-of instructions to resolve local variable addresses.
pub const LocalFixupMap = common.UniqueReprArrayMap(core.LocalId, u64);

/// A map from UpvalueId to a stack operand offset. Used by address-of instructions to resolve local variable addresses.
pub const UpvalueFixupMap = common.UniqueReprArrayMap(core.UpvalueId, u64);

/// A map from core.BlockId to BlockBuilder pointers, representing the basic blocks of a function.
pub const BlockMap = common.UniqueReprMap(core.BlockId, *BlockBuilder);

/// A map from HandlerSetId to HandlerSetBuilder pointers, representing the basic blocks of a function.
pub const HandlerSetMap = common.UniqueReprMap(core.HandlerSetId, *HandlerSetBuilder);

/// A visitor for bytecode blocks, used to track which blocks have been visited during encoding.
pub const BlockVisitor = common.Visitor(core.BlockId);

/// A queue of bytecode blocks to visit, used by the Block encoder to queue references to jump targets.
pub const BlockVisitorQueue = common.VisitorQueue(core.BlockId);

/// A table of bytecode, containing the unit, statics, and linker map.
pub const Table = struct {
    /// The map of unbound locations and their fixups.
    linker_map: binary.LinkerMap,
    /// The bytecode unit.
    bytecode: *core.Bytecode,

    /// Deinitialize the table, freeing all memory.
    pub fn deinit(self: *Table) void {
        self.bytecode.deinit(self.linker_map.gpa);
        self.linker_map.deinit();
        self.* = undefined;
    }
};

/// Disassemble a bytecode buffer, printing to the provided writer.
pub fn disas(bc: []const core.InstructionBits, options: struct {
    /// Whether to print the buffer address in the disassembly.
    buffer_address: bool = true,
    /// Whether to indent the disassembly output body.
    indent: ?[]const u8 = "    ",
    /// Instruction separator.
    separator: []const u8 = "\n",
}, writer: *std.io.Writer) (error{BadEncoding} || std.io.Writer.Error)!void {
    var decoder = Decoder.init(bc);

    if (options.buffer_address) {
        try writer.print("[{x:0<16}]:\n", .{@intFromPtr(bc.ptr)});
    }

    const indent = if (options.indent) |s| s else "";

    while (try decoder.next()) |item| {
        try writer.print("{s}{f}{s}", .{ indent, item, options.separator });
    }
}
