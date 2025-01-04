const std = @import("std");

const Rml = @import("root.zig");
const Ordering = Rml.Ordering;
const Error = Rml.Error;
const OOM = Rml.OOM;
const ptr = Rml.ptr;
const Obj = Rml.Obj;
const ObjData = Rml.ObjData;
const Object = Rml.Object;
const Writer = Rml.Writer;
const getObj = Rml.getObj;
const getTypeId = Rml.getTypeId;
const forceObj = Rml.forceObj;
const getRml = Rml.getRml;
const getOrigin = Rml.getOrigin;


pub const BlockKind = enum {
    doc,
    curly,
    square,
    paren,

    pub fn compare(a: BlockKind, b: BlockKind) Ordering {
        if (a == .doc or b == .doc) return .Equal;
        return Rml.compare(@intFromEnum(a), @intFromEnum(b));
    }

    pub fn toOpenStr(self: BlockKind) []const u8 {
        return switch (self) {
            .doc => "",
            .curly => "{",
            .square => "[",
            .paren => "(",
        };
    }

    pub fn toCloseStr(self: BlockKind) []const u8 {
        return switch (self) {
            .doc => "",
            .curly => "}",
            .square => "]",
            .paren => ")",
        };
    }

    pub fn toOpenStrFmt(self: BlockKind) []const u8 {
        return switch (self) {
            .doc => "⧼",
            .curly => "{",
            .square => "[",
            .paren => "(",
        };
    }

    pub fn toCloseStrFmt(self: BlockKind) []const u8 {
        return switch (self) {
            .doc => "⧽",
            .curly => "}",
            .square => "]",
            .paren => ")",
        };
    }
};

pub const Block = struct {
    kind: BlockKind = .doc,
    array: Rml.array.ArrayUnmanaged = .{},

    pub fn onInit(self: ptr(Block), kind: BlockKind) OOM! void {
        self.kind = kind;
    }

    pub fn onCompare(a: ptr(Block), other: Object) Ordering {
        var ord = Rml.compare(getTypeId(a), other.getTypeId());

        if (ord == .Equal) {
            const b = forceObj(Block, other);

            ord = Rml.compare(a.kind, b.data.kind);

            if (ord == .Equal) {
                ord = Rml.compare(a.array, b.data.array);
            }
        }

        return ord;
    }

    pub fn onFormat(self: ptr(Block), writer: Obj(Writer)) Error! void {
        try writer.data.writeAll(self.kind.toOpenStrFmt());
        for (self.array.items(), 0..) |item, i| {
            try item.onFormat(writer);

            if (i < self.array.length() - 1) {
                try writer.data.writeAll(" ");
            }
        }
        try writer.data.writeAll(self.kind.toCloseStrFmt());
    }

    /// Length of the block.
    pub fn length(self: ptr(Block)) usize {
        return self.array.length();
    }

    /// Contents of the block.
    /// Pointers to elements in this slice are invalidated by various functions of this ArrayList in accordance with the respective documentation.
    /// In all cases, "invalidated" means that the memory has been passed to an allocator's resize or free function.
    pub fn items(self: ptr(Block)) []Object {
        return self.array.items();
    }

    /// Convert a block to an array.
    pub fn toArray(self: ptr(Block)) OOM! Obj(Rml.Array) {
        return try Obj(Rml.Array).wrap(getRml(self), getOrigin(self), .{ .unmanaged = try self.array.clone(getRml(self)) });
    }

    /// Extend the block by 1 element.
    /// Allocates more memory as necessary.
    /// Invalidates element pointers if additional memory is needed.
    pub fn append(self: ptr(Block), obj: Object) OOM! void {
        const rml = getRml(self);
        return self.array.append(rml, obj);
    }

    /// Append the slice of items to the block. Allocates more memory as necessary.
    /// Invalidates element pointers if additional memory is needed.
    pub fn appendSlice(self: ptr(Block), slice: []const Object) OOM! void {
        const rml = getRml(self);
        return self.array.appendSlice(rml, slice);
    }
};
