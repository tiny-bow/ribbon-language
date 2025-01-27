const Generator = @This();

test {
    std.testing.refAllDeclsRecursive(Generator);
}

const std = @import("std");
const utils = @import("utils");
const Rbc = @import("Rbc");
const RbcBuilder = @import("RbcBuilder");

const Rir = @import("Rir");

pub const Error = Rir.Error || RbcBuilder.Error || error {
    StackOverflow,
    StackUnderflow,
    StackNotCleared,
    StackBranchMismatch,
    LocalNotAssignedStorage,
    LocalNotAssignedRegister,
    ExpectedRegister,
    AddressOfRegister,
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

// TODO: rename to _map, type aliases
evidence_lookup: std.ArrayHashMapUnmanaged(Rir.EvidenceId, Rbc.EvidenceIndex, utils.SimpleHashContext, false) = .{},
module_lookup: std.ArrayHashMapUnmanaged(Rir.ModuleId, *Module, utils.SimpleHashContext, false) = .{},
foreign_lookup: std.ArrayHashMapUnmanaged(Rir.ForeignId, Rbc.ForeignId, utils.SimpleHashContext, false) = .{},


pub const Export = union(enum) {
    function: *Rir.Function,
    global: *Rir.Global,

    pub fn @"export"(value: anytype) Export {
        switch (@TypeOf(value)) {
            *const Rir.Function => return .{ .function = @constCast(value) },
            *Rir.Function => return .{ .function = value },

            *const Rir.Global => return .{ .global = @constCast(value) },
            *Rir.Global => return .{ .global = value },

            else => @compileError("Invalid export type " ++ @typeName(@TypeOf(value) ++ ", must be a pointer to an Rir.Function or Rir.Global"),),
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
            .function => |ref| _ = try self.getFunction(ref),
            .global => |ref| _ = try self.getGlobal(ref),
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

pub fn getGlobal(self: *Generator, gRef: *Rir.Global) Error! *Global {
    return (try self.getModule(gRef.module.id)).getGlobal(gRef.id);
}

pub fn getFunction(self: *Generator, fRef: *Rir.Function) Error! *Function {
    return (try self.getModule(fRef.module.id)).getFunction(fRef.id);
}

pub fn getEvidence(self: *Generator, evId: Rir.EvidenceId) !Rbc.EvidenceIndex {
    const getOrPut = try self.evidence_lookup.getOrPut(self.allocator, evId);

    if (!getOrPut.found_existing) {
        const index = try self.builder.evidence();
        getOrPut.value_ptr.* = index;
    }

    return getOrPut.value_ptr.*;
}

pub fn getForeign(self: *Generator, foreignAddressIr: *Rir.ForeignAddress) !Rbc.ForeignId {
    const getOrPut = try self.foreign_lookup.getOrPut(self.allocator, foreignAddressIr.id);

    if (!getOrPut.found_existing) {
        @panic("TODO: Implement Generator.getForeign");
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
                    return utils.types.forceErrorSet(Error, err);
                };
        }

        formatter.fmt(args[i])
            catch |err| {
                return utils.types.forceErrorSet(Error, err);
            };
    }

    const str = fbs.getWritten();

    return self.ir.internName(str);
}
