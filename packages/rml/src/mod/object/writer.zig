const std = @import("std");

const Rml = @import("../root.zig");



pub const Native = std.io.AnyWriter;

pub const Writer = struct {
    native: Native,

    pub fn create(native_writer: Native) Writer {
        return Writer { .native = native_writer };
    }

    pub fn onCompare(self: *Writer, other: Rml.Object) Rml.Ordering {
        var ord = Rml.compare(Rml.getHeader(self).type_id, other.getTypeId());
        if (ord == .Equal) {
            ord = Rml.compare(self.native, Rml.forceObj(Writer, other).data.native);
        }
        return ord;
    }

    pub fn onFormat(self: *const Writer, _: Rml.Format, writer: std.io.AnyWriter) anyerror! void {
        try writer.print("[native-writer-{x}-{x}]", .{@intFromPtr(self.native.context), @intFromPtr(self.native.writeFn)});
    }

    pub fn print(self: *const Writer, comptime fmt: []const u8, args: anytype) Rml.Error! void {
        return self.native.print(fmt, args) catch |err| return Rml.errorCast(err);
    }

    pub fn write(self: *const Writer, val: []const u8) Rml.Error! usize {
        return self.native.write(val) catch |err| return Rml.errorCast(err);
    }

    pub fn writeAll(self: *const Writer, val: []const u8) Rml.Error! void {
        return self.native.writeAll(val) catch |err| return Rml.errorCast(err);
    }
};
