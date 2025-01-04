const std = @import("std");
const TextUtils = @import("Utils").Text;

const Rml = @import("root.zig");
const Char = Rml.Char;
const OOM = Rml.OOM;
const Error = Rml.Error;
const ptr = Rml.ptr;
const Obj = Rml.Obj;
const Object = Rml.Object;
const Writer = Rml.Writer;
const getObj = Rml.getObj;
const getRml = Rml.getRml;


pub const String = struct {
    unmanaged: StringUnmanaged = .{},

    pub fn create(rml: *Rml, str: []const u8) OOM! String {
        var self = String {};
        try self.unmanaged.appendSlice(rml, str);
        return self;
    }

    pub fn onFormat(self: ptr(String), writer: Rml.Obj(Writer)) Error! void {
        try writer.data.print("{}", .{self.unmanaged});
    }


    pub fn text(self: ptr(String)) []const u8 {
        return self.unmanaged.text();
    }

    pub fn length(self: ptr(String)) usize {
        return self.unmanaged.length();
    }

    pub fn append(self: ptr(String), ch: Char) OOM! void {
        return self.unmanaged.append(getRml(self), ch);
    }

    pub fn appendSlice(self: ptr(String), str: []const u8) OOM! void {
        return self.unmanaged.appendSlice(getRml(self), str);
    }

    pub fn makeInternedSlice(self: ptr(String)) OOM! []const u8 {
        return self.unmanaged.makeInternedSlice(getRml(self));
    }
};

pub const NativeString = std.ArrayListUnmanaged(u8);
pub const NativeWriter = NativeString.Writer;

pub const StringUnmanaged = struct {
    native_string: NativeString = .{},


    pub fn format(self: *const StringUnmanaged, comptime _: []const u8, _: std.fmt.FormatOptions, w: anytype) Error! void {
        // TODO: escape non-ascii & control etc Chars
        w.print("\"{s}\"", .{self.native_string.items}) catch |err| return Rml.errorCast(err);
    }

    pub fn text(self: *StringUnmanaged) []const u8 {
        return self.native_string.items;
    }

    pub fn length(self: *StringUnmanaged) usize {
        return self.native_string.items.len;
    }

    pub fn append(self: *StringUnmanaged, rml: *Rml, ch: Char) OOM! void {
        var buf = [1]u8{0} ** 4;
        const len = TextUtils.encode(ch, &buf) catch @panic("invalid ch");
        return self.native_string.appendSlice(rml.blobAllocator(), buf[0..len]);
    }

    pub fn appendSlice(self: *StringUnmanaged, rml: *Rml, str: []const u8) OOM! void {
        return self.native_string.appendSlice(rml.blobAllocator(), str);
    }

    pub fn makeInternedSlice(self: *StringUnmanaged, rml: *Rml) OOM! []const u8 {
        return try rml.storage.intern(self.native_string.items);
    }

    pub fn writer(self: *StringUnmanaged, rml: *Rml) NativeWriter {
        return self.native_string.writer(rml.blobAllocator());
    }
};


