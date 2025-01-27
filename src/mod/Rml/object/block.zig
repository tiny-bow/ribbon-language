const std = @import("std");

const Rml = @import("../../Rml.zig");



pub const BlockKind = enum {
    doc,
    curly,
    square,
    paren,

    pub fn compare(a: BlockKind, b: BlockKind) Rml.Ordering {
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

    pub fn toOpenStrFmt(self: BlockKind, format: Rml.Format) []const u8 {
        return switch (self) {
            .doc => if (format != .source) "⧼" else "",
            .curly => "{",
            .square => "[",
            .paren => "(",
        };
    }

    pub fn toCloseStrFmt(self: BlockKind, format: Rml.Format) []const u8 {
        return switch (self) {
            .doc => if (format != .source) "⧽" else "",
            .curly => "}",
            .square => "]",
            .paren => ")",
        };
    }
};

pub const Block = struct {
    allocator: std.mem.Allocator,
    kind: BlockKind = .doc,
    array: std.ArrayListUnmanaged(Rml.Object) = .{},

    pub fn create(rml: *Rml, kind: BlockKind, initialItems: []const Rml.Object) Rml.OOM! Block {
        const allocator = rml.blobAllocator();

        var array: std.ArrayListUnmanaged(Rml.Object) = .{};
        try array.appendSlice(allocator, initialItems);

        return .{
            .allocator = allocator,
            .kind = kind,
            .array = array,
        };
    }

    pub fn compare(self: Block, other: Block) Rml.Ordering {
        var ord = BlockKind.compare(self.kind, other.kind);

        if (ord == .Equal) {
            ord = Rml.compare(self.array.items, other.array.items);
        }

        return ord;
    }

    pub fn format(self: *const Block, comptime fmtStr: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror! void {
        const fmt = Rml.Format.fromStr(fmtStr) orelse .debug;
        const w = if (@TypeOf(writer) == std.io.AnyWriter) writer else writer.any();
        try w.writeAll(self.kind.toOpenStrFmt(fmt));
        for (self.items(), 0..) |item, i| {
            try item.onFormat(fmt, w);

            if (i < self.length() - 1) {
                try w.writeAll(" ");
            }
        }
        try w.writeAll(self.kind.toCloseStrFmt(fmt));
    }


    /// Length of the block.
    pub fn length(self: *const Block) Rml.Int {
        return @intCast(self.array.items.len);
    }

    /// Contents of the block.
    /// Pointers to elements in this slice are invalidated by various functions of this ArrayList in accordance with the respective documentation.
    /// In all cases, "invalidated" means that the memory has been passed to an allocator's resize or free function.
    pub fn items(self: *const Block) []Rml.Object {
        return self.array.items;
    }

    /// Convert a block to an array.
    pub fn toArray(self: *const Block) Rml.OOM! Rml.Obj(Rml.Array) {
        const allocator = Rml.getRml(self).blobAllocator();
        return try Rml.Obj(Rml.Array).wrap(Rml.getRml(self), Rml.getOrigin(self), try .create(allocator, self.items()));
    }

    /// Extend the block by 1 element.
    /// Allocates more memory as necessary.
    /// Invalidates element pointers if additional memory is needed.
    pub fn append(self: *Block, obj: Rml.Object) Rml.OOM! void {
        return self.array.append(self.allocator, obj);
    }

    /// Append the slice of items to the block. Allocates more memory as necessary.
    /// Invalidates element pointers if additional memory is needed.
    pub fn appendSlice(self: *Block, slice: []const Rml.Object) Rml.OOM! void {
        return self.array.appendSlice(self.allocator, slice);
    }
};
