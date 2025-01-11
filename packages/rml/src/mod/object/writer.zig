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

    pub fn onFormat(self: *Writer, writer: std.io.AnyWriter) anyerror! void {
        try writer.print("{}", .{self.native});
    }

    pub fn print(self: *Writer, comptime fmt: []const u8, args: anytype) Rml.Error! void {
        return self.native.print(fmt, args) catch |err| return Rml.errorCast(err);
    }

    pub fn write(self: *Writer, val: []const u8) Rml.Error! usize {
        return self.native.write(val) catch |err| return Rml.errorCast(err);
    }

    pub fn writeAll(self: *Writer, val: []const u8) Rml.Error! void {
        return self.native.writeAll(val) catch |err| return Rml.errorCast(err);
    }
};
