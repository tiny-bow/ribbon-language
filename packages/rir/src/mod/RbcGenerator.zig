const Generator = @This();

test {
    std.testing.refAllDeclsRecursive(Generator);
}

const std = @import("std");
const TypeUtils = @import("Utils").Type;
const MiscUtils = @import("Utils").Misc;
const Rbc = @import("Rbc");
const RbcBuilder = @import("RbcBuilder");

const Rir = @import("Rir");

pub const Error = Rir.Error || RbcBuilder.Error || error {
    StackOverflow,
    StackUnderflow,
    StackNotCleared,
    StackBranchMismatch,
};


pub const block = @import("RbcGenerator/block.zig");
pub const Block = block.Block;

pub const function = @import("RbcGenerator/function.zig");
pub const Function = function.Function;

pub const global = @import("RbcGenerator/global.zig");
pub const Global = global.Global;

pub const module = @import("RbcGenerator/module.zig");
pub const Module = module.Module;

pub const MAX_FRESH_NAME_LEN = 128;


allocator: std.mem.Allocator,

ir: *Rir,
builder: RbcBuilder,

evidence_lookup: std.ArrayHashMapUnmanaged(Rir.EvidenceId, Rbc.EvidenceIndex, MiscUtils.SimpleHashContext, false) = .{},
module_lookup: std.ArrayHashMapUnmanaged(Rir.ModuleId, *Module, MiscUtils.SimpleHashContext, false) = .{},


pub const Export = union(enum) {
    Function: Rir.Ref(Rir.FunctionId),
    Global: Rir.Ref(Rir.GlobalId),

    pub fn @"export"(value: anytype) Export {
        switch (@TypeOf(value)) {
            Rir.Ref(Rir.FunctionId) => return .{ .Function = value },
            *const Rir.Function => return .{ .Function = value.getRef() },
            *Rir.Function => return .{ .Function = value.getRef() },

            Rir.Ref(Rir.GlobalId) => return .{ .Global = value },
            *const Rir.Global => return .{ .Global = value.getRef() },
            *Rir.Global => return .{ .Global = value.getRef() },

            else => @compileError("Invalid export type " ++ @typeName(@TypeOf(value))),
        }
    }
};


/// Allocator provided should be an arena or a similar allocator,
/// that does not care about freeing individual allocations
pub fn init(allocator: std.mem.Allocator, ir: *Rir) error{OutOfMemory} !Generator {
    return Generator {
        .allocator = allocator,
        .builder = try RbcBuilder.init(allocator),
        .ir = ir,
    };
}



/// Allocator provided does not have to be the allocator used to create the generator,
/// a long term allocator is preferred.
///
/// In the event of an error, this function cleans up any allocations it created.
pub fn generate(self: *Generator, allocator: std.mem.Allocator, exports: []const Export) Error! Rbc.Program {
    for (exports) |exp| {
        switch (exp) {
            .Function => |ref| _ = try self.getFunction(ref),
            .Global => |ref| _ = try self.getGlobal(ref),
        }
    }

    return try self.builder.assemble(allocator);
}

pub fn getModule(self: *Generator, modId: Rir.ModuleId) error{InvalidModule, OutOfMemory}! *Module {
    const getOrPut = try self.module_lookup.getOrPut(self.allocator, modId);

    if (!getOrPut.found_existing) {
        const modIr = try self.ir.getModule(modId);
        getOrPut.value_ptr.* = try Module.init(self, modIr);
    }

    return getOrPut.value_ptr.*;
}

pub fn getGlobal(self: *Generator, gRef: Rir.Ref(Rir.GlobalId)) Error! *Global {
    return (try self.getModule(gRef.module)).getGlobal(gRef.id);
}

pub fn getFunction(self: *Generator, fRef: Rir.Ref(Rir.FunctionId)) Error! *Function {
    return (try self.getModule(fRef.module)).getFunction(fRef.id);
}

pub fn getEvidence(self: *Generator, evId: Rir.EvidenceId) !Rbc.EvidenceIndex {
    const getOrPut = try self.evidence_lookup.getOrPut(self.allocator, evId);

    if (!getOrPut.found_existing) {
        const index = try self.builder.evidence();
        getOrPut.value_ptr.* = index;
    }

    return getOrPut.value_ptr.*;
}


pub fn freshName(self: *Generator, args: anytype) Error! Rir.NameId {
    var buf = [1]u8{0} ** MAX_FRESH_NAME_LEN;

    var fbs = std.io.fixedBufferStream(&buf);

    const w = fbs.writer();

    const formatter = try Rir.Formatter.init(self.ir, w.any());
    defer formatter.deinit();

    inline for (0..args.len) |i| {
        if (i > 0) {
            formatter.writeAll("-")
                catch |err| {
                    return TypeUtils.forceErrorSet(Error, err);
                };
        }

        formatter.fmt(args[i])
            catch |err| {
                return TypeUtils.forceErrorSet(Error, err);
            };
    }

    const str = fbs.getWritten();

    return self.ir.internName(str);
}
