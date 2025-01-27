const Rml = @import("../../Rml.zig");

const std = @import("std");
const utils = @import("utils");



pub const Native = std.io.AnyWriter;

pub const Writer = struct {
    native: Native,

    pub fn create(native_writer: Native) Writer {
        return Writer { .native = native_writer };
    }

    pub fn compare(self: Writer, other: Writer) utils.Ordering {
        return utils.compare(self.native, other.native);
    }

    pub fn format(self: *const Writer, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror! void {
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
