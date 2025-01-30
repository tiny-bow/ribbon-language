const Rir = @import("../Rir.zig");

const block = @This();

const std = @import("std");
const Rbc = @import("Rbc");
const utils = @import("utils");

const LocalMap = std.ArrayHashMapUnmanaged(Rir.LocalId, *Rir.Local, utils.SimpleHashContext, false);

pub const Block = struct {
    pub const Id = Rir.BlockId;

    ir: *Rir,
    function: *Rir.Function,

    parent: ?*Block,
    id: Rir.BlockId,
    name: Rir.NameId,

    has_exit: bool = false,
    handler_set: ?*Rir.HandlerSet = null,
    local_map: LocalMap = .{},
    instructions: std.ArrayListUnmanaged(Rir.Instruction) = .{},

    pub fn init(function: *Rir.Function, parent: ?*Block, id: Rir.BlockId, name: Rir.NameId) !*Block {
        const ir = function.ir;

        const ptr = try ir.allocator.create(Block);
        errdefer ir.allocator.destroy(ptr);

        ptr.* = Block{
            .ir = ir,
            .function = function,
            .parent = parent,
            .id = id,
            .name = name,
        };

        return ptr;
    }

    pub fn deinit(self: *Block) void {
        for (self.local_map.values()) |x| x.deinit();
        self.local_map.deinit(self.ir.allocator);

        self.instructions.deinit(self.ir.allocator);
        self.ir.allocator.destroy(self);
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
        return self.local_map.count();
    }

    pub fn getLocal(self: *const Block, id: Rir.LocalId) error{InvalidLocal}!*Rir.Local {
        if (self.local_map.get(id)) |x| {
            return x;
        } else if (self.parent) |p| {
            return p.getLocal(id);
        } else {
            return error.InvalidLocal;
        }
    }

    pub fn createLocal(self: *Block, name: Rir.NameId, typeIr: *Rir.Type) error{ TooManyLocals, OutOfMemory }!*Rir.Local {
        const id = try self.function.freshLocalId();

        const local = try Rir.Local.init(self, id, name, typeIr);
        errdefer local.deinit();

        try self.local_map.put(self.ir.allocator, id, local);

        return local;
    }

    pub fn referenceCount(self: *Block, offset: Rir.Offset, registerIndex: Rbc.RegisterIndex) usize {
        var count: usize = 0;

        var i = offset;
        while (i < self.instructions.items.len) {
            const instr = self.instructions.items[i];
            i += 1;

            switch (instr.code) {
                .ref_block => {
                    const blockId = instr.data.ref_block;
                    const blockIr = self.function.getBlock(blockId) catch continue;

                    count += blockIr.referenceCount(0, registerIndex);
                },
                .ref_local => {
                    const localId = instr.data.ref_local;
                    const localIr = self.getLocal(localId) catch continue;

                    if (localIr.register) |reg| {
                        if (reg.getIndex() == registerIndex) count += 1;
                    }
                },
                else => {},
            }
        }

        return count;
    }

    pub fn hasReference(self: *Block, offset: Rir.Offset, registerIndex: Rbc.RegisterIndex) bool {
        var i = offset;
        while (i < self.instructions.items.len) {
            const instr = self.instructions.items[i];
            i += 1;

            switch (instr.code) {
                .ref_block => {
                    const blockId = instr.data.ref_block;
                    const blockIr = self.function.getBlock(blockId) catch continue;

                    if (blockIr.hasReference(0, registerIndex)) return true;
                },
                .ref_local => {
                    const localId = instr.data.ref_local;
                    const localIr = self.getLocal(localId) catch continue;

                    if (localIr.register) |reg| {
                        if (reg.getIndex() == registerIndex) return true;
                    }
                },
                else => {},
            }
        }

        return false;
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

    pub fn block(self: *Block, x: *Rir.Type) !void {
        try op(self, .block, x.id);
    }

    pub fn with(self: *Block, x: *Rir.Type) !void {
        try op(self, .with, x.id);
    }

    pub fn @"if"(self: *Block, x: *Rir.Type) !void {
        try op(self, .@"if", x.id);
    }

    pub fn when(self: *Block) !void {
        try op(self, .when, {});
    }

    pub fn re(self: *Block, x: Rir.value.Check) !void {
        if (x != .none) {
            try op(self, .re, x);
        } else {
            try exitOp(self, .re, x);
        }
    }

    pub fn br(self: *Block, x: Rir.value.Check) !void {
        if (x != .none) {
            try op(self, .br, x);
        } else {
            try exitOp(self, .br, x);
        }
    }

    pub fn call(self: *Block, x: Rir.Arity) !void {
        try op(self, .call, x);
    }

    pub fn ret(self: *Block) !void {
        try exitOp(self, .ret, {});
    }

    pub fn cancel(self: *Block) !void {
        try exitOp(self, .cancel, {});
    }

    pub fn alloca(self: *Block, x: *Rir.Type) !void {
        try op(self, .alloca, x.id);
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

    pub fn ext(self: *Block, x: Rir.value.BitSize) !void {
        try op(self, .ext, x);
    }

    pub fn trunc(self: *Block, x: Rir.value.BitSize) !void {
        try op(self, .trunc, x);
    }

    pub fn cast(self: *Block, x: *Rir.Type) !void {
        try op(self, .cast, x.id);
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

    pub fn new_local(self: *Block, x: Rir.value.OpLocal) !void {
        try op(self, .new_local, x);
    }

    pub fn ref_local(self: *Block, x: *Rir.Local) !void {
        try op(self, .ref_local, x.id);
    }

    pub fn ref_block(self: *Block, x: *Rir.Block) !void {
        try op(self, .ref_block, x.id);
    }

    pub fn ref_function(self: *Block, x: *Rir.Function) !void {
        try op(self, .ref_function, .{ .module_id = self.function.module.id, .id = x.id });
    }

    pub fn ref_extern_function(self: *Block, m: *Rir.Module, x: *Rir.Function) !void {
        try op(self, .ref_function, .{ .module_id = m.id, .id = x.id });
    }

    pub fn ref_foreign(self: *Block, x: *Rir.Foreign) !void {
        try op(self, .ref_foreign, x.id);
    }

    pub fn ref_global(self: *Block, x: *Rir.Global) !void {
        try op(self, .ref_global, .{ .module_id = self.function.module.id, .id = x.id });
    }

    pub fn ref_extern_global(self: *Block, m: *Rir.Module, x: *Rir.Global) !void {
        try op(self, .ref_global, .{ .module_id = m.id, .id = x.id });
    }

    pub fn ref_upvalue(self: *Block, x: *Rir.Upvalue) !void {
        try op(self, .ref_upvalue, x.id);
    }

    pub fn im(self: *Block, x: anytype) !void {
        const size = @bitSizeOf(@TypeOf(x));
        return if (comptime size > 32) @call(.always_inline, im_w, .{ self, x })
             else @call(.always_inline, im_i, .{ self, x });
    }

    pub fn im_i(self: *Block, x: anytype) !void {
        const ty = try self.ir.createTypeFromNative(@TypeOf(x), null, null);
        try op(self, .im_i, try Rir.value.OpImmediate.fromNative(ty, x));
    }

    pub fn im_w(self: *Block, x: anytype) !void {
        const ty = try self.ir.createTypeFromNative(@TypeOf(x), null, null);
        try op(self, .im_w, ty.id);
        try @call(.always_inline, std.ArrayListUnmanaged(Rir.Instruction).append, .{
            &self.instructions,
            self.ir.allocator,
            @as(Rir.Instruction, @bitCast(try Rir.Immediate.fromNative(x))),
        });
    }

    pub fn op(self: *Block, comptime code: Rir.OpCode, data: Rir.value.OpData.Of(code)) !void {
        try @call(.always_inline, std.ArrayListUnmanaged(Rir.Instruction).append, .{
            &self.instructions,
            self.ir.allocator,
            Rir.Instruction{
                .code = code,
                .data = @unionInit(Rir.OpData, @tagName(code), data),
            },
        });
    }

    pub fn exitOp(self: *Block, comptime code: Rir.OpCode, data: Rir.value.OpData.Of(code)) !void {
        if (self.has_exit) {
            return error.MultipleExits;
        }
        try op(self, code, data);
        self.has_exit = true;
    }
};

comptime {
    for (std.meta.fieldNames(Rir.OpCode)) |opName| {
        if (!@hasDecl(Block, opName)) {
            @compileError("missing Block method: `" ++ opName ++ "`");
        }
    }
}
