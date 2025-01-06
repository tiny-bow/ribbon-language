const std = @import("std");

const Rml = @import("root.zig");
const Ordering = Rml.Ordering;
const Error = Rml.Error;
const OOM = Rml.OOM;
const ptr = Rml.ptr;
const const_ptr = Rml.const_ptr;
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
    allocator: std.mem.Allocator,
    kind: BlockKind = .doc,
    array: std.ArrayListUnmanaged(Object) = .{},

    pub fn create(rml: *Rml, kind: BlockKind, initialItems: []const Object) OOM! Block {
        const allocator = rml.blobAllocator();

        var array: std.ArrayListUnmanaged(Object) = .{};
        try array.appendSlice(allocator, initialItems);

        return .{
            .allocator = allocator,
            .kind = kind,
            .array = array,
        };
    }

    pub fn onCompare(a: *Block, other: Object) Ordering {
        var ord = Rml.compare(getTypeId(a), other.getTypeId());

        if (ord == .Equal) {
            const b = forceObj(Block, other);

            ord = a.compare(b.data.*);
        }

        return ord;
    }

    pub fn compare(self: Block, other: Block) Ordering {
        var ord = BlockKind.compare(self.kind, other.kind);

        if (ord == .Equal) {
            ord = Rml.compare(self.array.items, other.array.items);
        }

        return ord;
    }

    pub fn onFormat(self: *Block, writer: std.io.AnyWriter) anyerror! void {
        try writer.writeAll(self.kind.toOpenStrFmt());
        for (self.items(), 0..) |item, i| {
            try item.onFormat(writer);

            if (i < self.length() - 1) {
                try writer.writeAll(" ");
            }
        }
        try writer.writeAll(self.kind.toCloseStrFmt());
    }

    /// Length of the block.
    pub fn length(self: *const Block) usize {
        return self.array.items.len;
    }

    /// Contents of the block.
    /// Pointers to elements in this slice are invalidated by various functions of this ArrayList in accordance with the respective documentation.
    /// In all cases, "invalidated" means that the memory has been passed to an allocator's resize or free function.
    pub fn items(self: *const Block) []Object {
        return self.array.items;
    }

    /// Convert a block to an array.
    pub fn toArray(self: *Block) OOM! Obj(Rml.Array) {
        const allocator = getRml(self).blobAllocator();
        return try Obj(Rml.Array).wrap(getRml(self), getOrigin(self), try .create(allocator, self.items()));
    }

    /// Extend the block by 1 element.
    /// Allocates more memory as necessary.
    /// Invalidates element pointers if additional memory is needed.
    pub fn append(self: *Block, obj: Object) OOM! void {
        return self.array.append(self.allocator, obj);
    }

    /// Append the slice of items to the block. Allocates more memory as necessary.
    /// Invalidates element pointers if additional memory is needed.
    pub fn appendSlice(self: *Block, slice: []const Object) OOM! void {
        return self.array.appendSlice(self.allocator, slice);
    }
};
