const std = @import("std");

const Rml = @import("root.zig");
const Ordering = Rml.Ordering;
const Error = Rml.Error;
const OOM = Rml.OOM;
const ptr = Rml.ptr;
const Obj = Rml.Obj;
const ref = Rml.ref;
const Object = Rml.Object;
const getHeader = Rml.getHeader;
const getObj = Rml.getObj;
const forceObj = Rml.forceObj;


pub const Native = std.io.AnyWriter;

pub const Writer = struct {
    native: Native,

    pub fn create(native_writer: Native) Writer {
        return Writer { .native = native_writer };
    }

    pub fn onCompare(self: ptr(Writer), other: Object) Ordering {
        var ord = Rml.compare(getHeader(self).type_id, other.getTypeId());
        if (ord == .Equal) {
            ord = Rml.compare(self.native, forceObj(Writer, other).data.native);
        }
        return ord;
    }

    pub fn onFormat(self: ptr(Writer), writer: std.io.AnyWriter) anyerror! void {
        try writer.print("{}", .{self.native});
    }

    pub fn print(self: ptr(Writer), comptime fmt: []const u8, args: anytype) Error! void {
        return self.native.print(fmt, args) catch |err| return Rml.errorCast(err);
    }

    pub fn write(self: ptr(Writer), val: []const u8) Error! usize {
        return self.native.write(val) catch |err| return Rml.errorCast(err);
    }

    pub fn writeAll(self: ptr(Writer), val: []const u8) Error! void {
        return self.native.writeAll(val) catch |err| return Rml.errorCast(err);
    }
};
