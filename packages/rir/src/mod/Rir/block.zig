const std = @import("std");
const MiscUtils = @import("Utils").Misc;

const Rir = @import("../Rir.zig");


const LocalMap = std.ArrayHashMapUnmanaged(Rir.LocalId, *Rir.Local, MiscUtils.SimpleHashContext, false);


pub const BlockKind = union(enum) {
    basic: void,
    with: Rir.HandlerSetId,
};

pub const Block = struct {
    function: *Rir.Function,
    locals: LocalMap = .{},
    parent: ?*Block,
    id: Rir.BlockId,
    name: Rir.NameId,
    has_exit: bool = false,
    kind: BlockKind = .basic,
    instructions: std.ArrayListUnmanaged(Rir.Instruction) = .{},


    pub fn init(function: *Rir.Function, parent: ?*Block, id: Rir.BlockId, name: Rir.NameId) !*Block {
        const ptr = try function.module.root.allocator.create(Block);
        errdefer function.module.root.allocator.destroy(ptr);

        ptr.* = Block {
            .function = function,
            .parent = parent,
            .id = id,
            .name = name,
        };

        return ptr;
    }

    pub fn deinit(self: *Block) void {
        for (self.locals.values()) |x| x.deinit();
        self.locals.deinit(self.function.module.root.allocator);

        self.instructions.deinit(self.function.module.root.allocator);
        self.function.module.root.allocator.destroy(self);
    }

    pub fn onFormat(self: *const Block, formatter: Rir.Formatter) !void {
        const oldBlock = formatter.swapBlock(self);
        defer formatter.setBlock(oldBlock);

        try formatter.fmt(self.name);
        if (formatter.getFlag(.show_ids)) try formatter.print("#{}", .{@intFromEnum(self.id)});
        try formatter.writeAll(" =");
        try formatter.beginBlock();
            for (self.instructions.items, 0..) |inst, i| {
                if (formatter.getFlag(.show_indices)) try formatter.print("{d: <4} ", .{i});
                try formatter.fmt(inst);
                if (i < self.instructions.items.len - 1) try formatter.endLine();
            }
        try formatter.endBlock();
    }


    pub fn length(self: *const Block) Rir.Offset {
        return @intCast(self.instructions.items.len);
    }

    pub fn localCount(self: *const Block) usize {
        return self.locals.count();
    }


    pub fn getLocal(self: *const Block, id: Rir.LocalId) error{InvalidLocal}! *Rir.Local {
        if (self.locals.get(id)) |x| {
            return x;
        } else if (self.parent) |p| {
            return p.getLocal(id);
        } else {
            return error.InvalidLocal;
        }
    }

    pub fn createLocal(self: *Block, name: Rir.NameId, tyId: Rir.TypeId) error{TooManyLocals, OutOfMemory}! *Rir.Local {
        const id = try self.function.freshLocalId();

        const local = try Rir.Local.init(self, id, name, tyId);
        errdefer local.deinit();

        try self.locals.put(self.function.module.root.allocator, id, local);

        return local;
    }



    pub fn nop(self: *Block) !void {
        try op(self, .nop, {});
    }

    pub fn halt(self: *Block) !void {
        try exitOp(self, .halt, {});
    }

    pub fn trap(self: *Block) !void {
        try exitOp(self, .trap, {});
    }

    pub fn block(self: *Block) !void {
        try op(self, .block, {});
    }

    pub fn with(self: *Block) !void {
        try op(self, .with, {});
    }

    pub fn @"if"(self: *Block, x: Rir.instruction.ZeroCheck) !void {
        try op(self, .@"if", x);
    }

    pub fn when(self: *Block, x: Rir.instruction.ZeroCheck) !void {
        try op(self, .when, x);
    }

    pub fn re(self: *Block, x: Rir.instruction.OptZeroCheck) !void {
        if (x != .none) {
            try op(self, .re, x);
        } else {
            try exitOp(self, .re, x);
        }
    }

    pub fn br(self: *Block, x: Rir.instruction.OptZeroCheck) !void {
        if (x != .none) {
            try op(self, .br, x);
        } else {
            try exitOp(self, .br, x);
        }
    }

    pub fn call(self: *Block) !void {
        try op(self, .call, {});
    }

    pub fn prompt(self: *Block) !void {
        try op(self, .prompt, {});
    }

    pub fn ret(self: *Block) !void {
        try exitOp(self, .ret, {});
    }

    pub fn term(self: *Block) !void {
        try exitOp(self, .term, {});
    }

    pub fn alloca(self: *Block, x: Rir.RegisterOffset) !void {
        try op(self, .alloca, x);
    }

    pub fn addr(self: *Block) !void {
        try op(self, .addr, {});
    }

    pub fn read(self: *Block) !void {
        try op(self, .read, {});
    }

    pub fn write(self: *Block) !void {
        try op(self, .write, {});
    }

    pub fn load(self: *Block) !void {
        try op(self, .load, {});
    }

    pub fn store(self: *Block) !void {
        try op(self, .store, {});
    }

    pub fn add(self: *Block) !void {
        try op(self, .add, {});
    }

    pub fn sub(self: *Block) !void {
        try op(self, .sub, {});
    }

    pub fn mul(self: *Block) !void {
        try op(self, .mul, {});
    }

    pub fn div(self: *Block) !void {
        try op(self, .div, {});
    }

    pub fn rem(self: *Block) !void {
        try op(self, .rem, {});
    }

    pub fn neg(self: *Block) !void {
        try op(self, .neg, {});
    }

    pub fn band(self: *Block) !void {
        try op(self, .band, {});
    }

    pub fn bor(self: *Block) !void {
        try op(self, .bor, {});
    }

    pub fn bxor(self: *Block) !void {
        try op(self, .bxor, {});
    }

    pub fn bnot(self: *Block) !void {
        try op(self, .bnot, {});
    }

    pub fn bshiftl(self: *Block) !void {
        try op(self, .bshiftl, {});
    }

    pub fn bshiftr(self: *Block) !void {
        try op(self, .bshiftr, {});
    }

    pub fn eq(self: *Block) !void {
        try op(self, .eq, {});
    }

    pub fn ne(self: *Block) !void {
        try op(self, .ne, {});
    }

    pub fn lt(self: *Block) !void {
        try op(self, .lt, {});
    }

    pub fn gt(self: *Block) !void {
        try op(self, .gt, {});
    }

    pub fn le(self: *Block) !void {
        try op(self, .le, {});
    }

    pub fn ge(self: *Block) !void {
        try op(self, .ge, {});
    }

    pub fn ext(self: *Block, x: Rir.instruction.BitSize) !void {
        try op(self, .ext, x);
    }

    pub fn trunc(self: *Block, x: Rir.instruction.BitSize) !void {
        try op(self, .trunc, x);
    }

    pub fn cast(self: *Block) !void {
        try op(self, .cast, {});
    }

    pub fn clear(self: *Block, count: Rir.Index) !void {
        try op(self, .clear, count);
    }

    pub fn swap(self: *Block, index: Rir.Index) !void {
        try op(self, .swap, index);
    }

    pub fn copy(self: *Block, index: Rir.Index) !void {
        try op(self, .copy, index);
    }

    pub fn new_local(self: *Block, x: Rir.NameId) !void {
        try op(self, .new_local, x);
    }

    pub fn ref_local(self: *Block, x: Rir.LocalId) !void {
        try op(self, .ref_local, x);
    }

    pub fn ref_block(self: *Block, x: Rir.BlockId) !void {
        try op(self, .ref_block, x);
    }

    pub fn ref_function(self: *Block, x: Rir.FunctionId) !void {
        try op(self, .ref_function, .{ .module = self.function.module.id, .id = x });
    }

    pub fn ref_extern_function(self: *Block, m: Rir.ModuleId, x: Rir.FunctionId) !void {
        try op(self, .ref_function, .{ .module = m, .id = x });
    }

    pub fn ref_foreign(self: *Block, x: Rir.ForeignId) !void {
        try op(self, .ref_foreign, x);
    }

    pub fn ref_global(self: *Block, x: anytype) !void {
        try op(self, .ref_global, .{ .module = self.function.module.id, .id = x });
    }

    pub fn ref_extern_global(self: *Block, m: Rir.ModuleId, x: Rir.GlobalId) !void {
        try op(self, .ref_global, .{ .module = m, .id = x });
    }

    pub fn ref_upvalue(self: *Block, x: Rir.UpvalueId) !void {
        try op(self, .ref_upvalue, x);
    }


    pub fn im(self: *Block, x: anytype) !void {
        const size = @bitSizeOf(@TypeOf(x));
        return if (comptime size > 32) @call(.always_inline, im_w, .{self, x})
        else if (comptime size > 16) @call(.always_inline, im_i, .{self, x})
        else if (comptime size > 8) @call(.always_inline, im_s, .{self, x})
        else @call(.always_inline, im_b, .{self, x});
    }

    pub fn im_b(self: *Block, x: anytype) !void {
        const ty = try self.function.module.root.createTypeFromNative(@TypeOf(x), null, null);
        try op(self, .im_b, .{.type = ty.id, .data = bCast(x)});
    }

    pub fn im_s(self: *Block, x: anytype) !void {
        const ty = try self.function.module.root.createTypeFromNative(@TypeOf(x), null, null);
        try op(self, .im_s, .{.type = ty.id, .data = sCast(x)});
    }

    pub fn im_i(self: *Block, x: anytype) !void {
        const ty = try self.function.module.root.createTypeFromNative(@TypeOf(x), null, null);
        try op(self, .im_i, .{.type = ty.id, .data = iCast(x)});
    }

    pub fn im_w(self: *Block, x: anytype) !void {
        const ty = try self.function.module.root.createTypeFromNative(@TypeOf(x), null, null);
        try op(self, .im_w, .{.type = ty.id});
        try wideImmediate(self, x);
    }
};



inline fn bCast(b: anytype) u8 {
    return switch (@typeInfo(@TypeOf(b))) {
        .comptime_int => @as(u8, b),
        .int => |info|
            if (info.bits <= 8) switch (info.signedness) {
                .unsigned => @as(u8, b),
                .signed => @as(u8, @as(std.meta.Int(.unsigned, info.bits), @bitCast(b))),
            }
            else @bitCast(@as(std.meta.Int(info.signedness, 8), @intCast(b))),
        .@"enum" => bCast(@intFromEnum(b)),
        else => @as(u8, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(b))), @bitCast(b))),
    };
}

inline fn sCast(b: anytype) u16 {
    return switch (@typeInfo(@TypeOf(b))) {
        .comptime_int => @as(u16, b),
        .int => |info|
            if (info.bits <= 16) switch (info.signedness) {
                .unsigned => @as(u16, b),
                .signed => @as(u16, @as(std.meta.Int(.unsigned, info.bits), @bitCast(b))),
            }
            else @bitCast(@as(std.meta.Int(info.signedness, 16), @intCast(b))),
        .@"enum" => sCast(@intFromEnum(b)),
        else => @as(u16, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(b))), @bitCast(b))),
    };
}

inline fn iCast(b: anytype) u32 {
    return switch (@typeInfo(@TypeOf(b))) {
        .comptime_int => @as(u32, b),
        .int => |info|
            if (info.bits <= 32) switch (info.signedness) {
                .unsigned => @as(u32, b),
                .signed => @as(u32, @as(std.meta.Int(.unsigned, info.bits), @bitCast(b))),
            }
            else @bitCast(@as(std.meta.Int(info.signedness, 32), @intCast(b))),
        .@"enum" => iCast(@intFromEnum(b)),
        else => @as(u32, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(b))), @bitCast(b))),
    };
}

inline fn wCast(b: anytype) u64 {
    return switch (@typeInfo(@TypeOf(b))) {
        .comptime_int => @as(u64, b),
        .int => |info|
            if (info.bits <= 64) switch (info.signedness) {
                .unsigned => @as(u64, b),
                .signed => @as(u64, @as(std.meta.Int(.unsigned, info.bits), @bitCast(b))),
            }
            else @bitCast(@as(std.meta.Int(info.signedness, 64), @intCast(b))),
        .@"enum" => wCast(@intFromEnum(b)),
        else => @as(u64, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(b))), @bitCast(b))),
    };
}


inline fn wideImmediate(self: *Block, x: u64) !void {
    try @call(.always_inline, std.ArrayListUnmanaged(Rir.Instruction).append, .{
        &self.instructions,
        self.function.module.root.allocator,
        @as(Rir.Instruction, @bitCast(wCast(x))),
    });
}

inline fn op(self: *Block, comptime code: Rir.OpCode, data: Rir.instruction.DataOf(code)) !void {
    try @call(.always_inline, std.ArrayListUnmanaged(Rir.Instruction).append, .{
        &self.instructions,
        self.function.module.root.allocator,
        Rir.Instruction {
            .code = code,
            .data = @unionInit(Rir.OpData, @tagName(code), data),
        },
    });
}

inline fn exitOp(self: *Block, comptime code: Rir.OpCode, data: Rir.instruction.DataOf(code)) !void {
    if (self.has_exit) {
        return error.MultipleExits;
    }
    try op(self, code, data);
    self.has_exit = true;
}

comptime {
    for (std.meta.fieldNames(Rir.OpCode)) |opName| {
        if (!@hasDecl(Block, opName)) {
            @compileError("missing Block method: `" ++ opName ++ "`");
        }
    }
}
