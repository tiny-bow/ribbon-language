const std = @import("std");

const Core = @import("../Core.zig");

const Block = @This();


function: *Core.Function,
parent: ?*Block,
id: Core.BlockId,
name: Core.Name,
has_exit: bool = false,
instructions: std.ArrayListUnmanaged(Core.Instruction) = .{},


pub fn init(function: *Core.Function, parent: ?*Block, id: Core.BlockId, name: Core.Name) !*Block {
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
    self.instructions.deinit(self.function.module.root.allocator);
    self.function.module.root.allocator.destroy(self);
}

pub fn onFormat(self: *const Block, formatter: Core.Formatter) !void {
    try formatter.fmt(self.name);
    try formatter.writeAll(":");
    try formatter.beginBlock();
        for (self.instructions.items, 0..) |inst, i| {
            try formatter.print("{} ", .{i});
            try formatter.fmt(inst);
            if (i < self.instructions.items.len - 1) try formatter.endLine();
        }
    try formatter.endBlock();
}

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
    try @call(.always_inline, std.ArrayListUnmanaged(Core.Instruction).append, .{
        &self.instructions,
        self.function.module.root.allocator,
        @as(Core.Instruction, @bitCast(wCast(x))),
    });
}

inline fn op(self: *Block, comptime code: Core.Op.Code, data: Core.Op.TypeOf(code)) !void {
    try @call(.always_inline, std.ArrayListUnmanaged(Core.Instruction).append, .{
        &self.instructions,
        self.function.module.root.allocator,
        Core.Instruction {
            .code = code,
            .data = @unionInit(Core.Op.Data, @tagName(code), data),
        },
    });
}

inline fn exitOp(self: *Block, comptime code: Core.Op.Code, data: Core.Op.TypeOf(code)) !void {
    if (self.has_exit) {
        return error.MultipleExits;
    }
    try self.op(code, data);
    self.has_exit = true;
}


pub fn nop(self: *Block) !void {
    try self.op(.nop, {});
}

pub fn halt(self: *Block) !void {
    try self.exitOp(.halt, {});
}

pub fn trap(self: *Block) !void {
    try self.exitOp(.trap, {});
}

pub fn block(self: *Block) !void {
    try self.op(.block, {});
}

pub fn with(self: *Block) !void {
    try self.op(.with, {});
}

pub fn @"if"(self: *Block, x: Core.Op.ZeroCheck) !void {
    try self.op(.@"if", x);
}

pub fn when(self: *Block, x: Core.Op.ZeroCheck) !void {
    try self.op(.when, x);
}

pub fn re(self: *Block, x: Core.Op.OptZeroCheck) !void {
    if (x != .none) {
        try self.op(.re, x);
    } else {
        try self.exitOp(.re, x);
    }
}

pub fn br(self: *Block, x: Core.Op.OptZeroCheck) !void {
    if (x != .none) {
        try self.op(.br, x);
    } else {
        try self.exitOp(.br, x);
    }
}

pub fn call(self: *Block) !void {
    try self.op(.call, {});
}

pub fn prompt(self: *Block) !void {
    try self.op(.prompt, {});
}

pub fn ret(self: *Block) !void {
    try self.exitOp(.ret, {});
}

pub fn term(self: *Block) !void {
    try self.exitOp(.term, {});
}

pub fn alloca(self: *Block, x: Core.RegisterOffset) !void {
    try self.op(.alloca, x);
}

pub fn addr(self: *Block) !void {
    try self.op(.addr, {});
}

pub fn read(self: *Block) !void {
    try self.op(.read, {});
}

pub fn write(self: *Block) !void {
    try self.op(.write, {});
}

pub fn load(self: *Block) !void {
    try self.op(.load, {});
}

pub fn store(self: *Block) !void {
    try self.op(.store, {});
}

pub fn clear(self: *Block) !void {
    try self.op(.clear, {});
}

pub fn swap(self: *Block) !void {
    try self.op(.swap, {});
}

pub fn copy(self: *Block) !void {
    try self.op(.copy, {});
}

pub fn add(self: *Block) !void {
    try self.op(.add, {});
}

pub fn sub(self: *Block) !void {
    try self.op(.sub, {});
}

pub fn mul(self: *Block) !void {
    try self.op(.mul, {});
}

pub fn div(self: *Block) !void {
    try self.op(.div, {});
}

pub fn rem(self: *Block) !void {
    try self.op(.rem, {});
}

pub fn neg(self: *Block) !void {
    try self.op(.neg, {});
}

pub fn band(self: *Block) !void {
    try self.op(.band, {});
}

pub fn bor(self: *Block) !void {
    try self.op(.bor, {});
}

pub fn bxor(self: *Block) !void {
    try self.op(.bxor, {});
}

pub fn bnot(self: *Block) !void {
    try self.op(.bnot, {});
}

pub fn bshiftl(self: *Block) !void {
    try self.op(.bshiftl, {});
}

pub fn bshiftr(self: *Block) !void {
    try self.op(.bshiftr, {});
}

pub fn eq(self: *Block) !void {
    try self.op(.eq, {});
}

pub fn ne(self: *Block) !void {
    try self.op(.ne, {});
}

pub fn lt(self: *Block) !void {
    try self.op(.lt, {});
}

pub fn gt(self: *Block) !void {
    try self.op(.gt, {});
}

pub fn le(self: *Block) !void {
    try self.op(.le, {});
}

pub fn ge(self: *Block) !void {
    try self.op(.ge, {});
}

pub fn ext(self: *Block, x: Core.Op.BitSize) !void {
    try self.op(.ext, x);
}

pub fn trunc(self: *Block, x: Core.Op.BitSize) !void {
    try self.op(.trunc, x);
}

pub fn cast(self: *Block, x: Core.TypeId) !void {
    try self.op(.cast, x);
}


pub fn new_local(self: *Block, x: Core.TypeId) !void {
    try self.op(.new_local, x);
}

pub fn ref_local(self: *Block, x: Core.LocalId) !void {
    try self.op(.ref_local, x);
}

pub fn ref_block(self: *Block, x: Core.BlockId) !void {
    try self.op(.ref_block, x);
}

pub fn ref_function(self: *Block, x: Core.FunctionId) !void {
    try self.op(.ref_function, .{ .module = self.function.module.id, .id = x });
}

pub fn ref_extern_function(self: *Block, m: Core.ModuleId, x: Core.FunctionId) !void {
    try self.op(.ref_function, .{ .module = m, .id = x });
}

pub fn ref_foreign(self: *Block, x: Core.ForeignId) !void {
    try self.op(.ref_foreign, x);
}

pub fn ref_global(self: *Block, x: anytype) !void {
    try self.op(.ref_global, .{ .module = self.function.module.id, .id = x });
}

pub fn ref_extern_global(self: *Block, m: Core.ModuleId, x: Core.GlobalId) !void {
    try self.op(.ref_global, .{ .module = m, .id = x });
}

pub fn ref_upvalue(self: *Block, x: Core.UpvalueId) !void {
    try self.op(.ref_upvalue, x);
}


pub fn discard(self: *Block) !void {
    try self.op(.discard, {});
}


pub fn im_b(self: *Block, x: anytype) !void {
    const ty = try self.function.module.typeIdFromNative(@TypeOf(x));
    try self.op(.im_b, .{.type = ty, .data = bCast(x)});
}

pub fn im_s(self: *Block, x: anytype) !void {
    const ty = try self.function.module.typeIdFromNative(@TypeOf(x));
    try self.op(.im_s, .{.type = ty, .data = sCast(x)});
}

pub fn im_i(self: *Block, x: anytype) !void {
    const ty = try self.function.module.typeIdFromNative(@TypeOf(x));
    try self.op(.im_i, .{.type = ty, .data = iCast(x)});
}

pub fn im_w(self: *Block, x: anytype) !void {
    const ty = try self.function.module.typeIdFromNative(@TypeOf(x));
    try self.op(.im_w, .{.type = ty});
    try self.wideImmediate(x);
}


comptime {
    for (std.meta.fieldNames(Core.Op.Code)) |opName| {
        if (!@hasDecl(Block, opName)) {
            @compileError("missing Block method: `" ++ opName ++ "`");
        }
    }
}
