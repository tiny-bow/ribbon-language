//! Binds information about a global variable inside an ir context.
const Global = @This();

const std = @import("std");

const ir = @import("../ir.zig");

module: *ir.Module,
id: Global.Id,
name: ir.Name,
type: ir.Term,
initializer: ir.Term,

/// Identifier for a global variable within a module.
pub const Id = enum(u32) { _ };

pub fn getCbr(self: *const Global) ir.Cbr {
    var hasher = ir.Cbr.Hasher.init();
    hasher.update("Global");

    hasher.update("name:");
    hasher.update(self.name.value);

    hasher.update("type:");
    hasher.update(self.type.getCbr());

    hasher.update("initializer:");
    hasher.update(self.initializer.getCbr());

    return hasher.final();
}

pub fn writeSma(self: *const Global, ctx: *const ir.Context, writer: *std.io.Writer) error{WriteFailed}!void {
    const name_id = ctx.interned_name_set.get(self.name.value).?;
    try writer.writeInt(u32, @intFromEnum(name_id), .little);
    try writer.writeInt(u32, @intFromEnum(self.type.getId()), .little);
    try writer.writeInt(u32, @intFromEnum(self.initializer.getId()), .little);
}
