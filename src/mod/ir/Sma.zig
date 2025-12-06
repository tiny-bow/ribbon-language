//! Serializable Module Artifact (SMA) format for Ribbon IR.
const Sma = @This();

const std = @import("std");
const log = std.log.scoped(.@"ir.sma");

const core = @import("core");
const common = @import("common");

const ir = @import("../ir.zig");

allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,

version: common.SemVer = core.VERSION,

tags: common.ArrayList([]const u8) = .empty,
names: common.ArrayList([]const u8) = .empty,
blobs: common.ArrayList(*const ir.Blob) = .empty,
shared: common.ArrayList(u32) = .empty,
terms: common.ArrayList(Sma.Term) = .empty,
modules: common.ArrayList(Sma.Module) = .empty,
expressions: common.ArrayList(Sma.Expression) = .empty,
globals: common.ArrayList(Sma.Global) = .empty,
handler_sets: common.ArrayList(Sma.HandlerSet) = .empty,
functions: common.ArrayList(Sma.Function) = .empty,

pub const magic = "RIBBONIR";
pub const sentinel_index: u32 = std.math.maxInt(u32);

pub const Dehydrator = struct {
    sma: *Sma,
    ctx: *ir.Context,

    tag_to_index: common.UniqueReprMap(ir.Term.Tag, u8) = .empty,
    name_to_index: common.StringMap(u32) = .empty,
    blob_to_index: common.UniqueReprMap(*const ir.Blob, u32) = .empty,
    term_to_index: common.UniqueReprMap(ir.Term, u32) = .empty,
    module_to_index: common.UniqueReprMap(*ir.Module, u32) = .empty,
    expression_to_index: common.UniqueReprMap(*ir.Block, u32) = .empty,
    global_to_index: common.UniqueReprMap(*ir.Global, u32) = .empty,
    handler_set_to_index: common.UniqueReprMap(*ir.HandlerSet, u32) = .empty,
    function_to_index: common.UniqueReprMap(*ir.Function, u32) = .empty,
    block_to_index: common.UniqueReprMap(*ir.Block, struct { u32, common.UniqueReprMap(*ir.Instruction, u32) }) = .empty,

    pub fn init(ctx: *ir.Context, allocator: std.mem.Allocator) !Dehydrator {
        const sma = try Sma.init(allocator);
        return Dehydrator{
            .sma = sma,
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *Dehydrator) void {
        self.finalize().deinit();
    }

    pub fn finalize(self: *Dehydrator) *Sma {
        self.tag_to_index.deinit(self.ctx.allocator);
        self.name_to_index.deinit(self.ctx.allocator);
        self.blob_to_index.deinit(self.ctx.allocator);
        self.term_to_index.deinit(self.ctx.allocator);
        self.module_to_index.deinit(self.ctx.allocator);
        self.expression_to_index.deinit(self.ctx.allocator);
        self.global_to_index.deinit(self.ctx.allocator);
        self.handler_set_to_index.deinit(self.ctx.allocator);
        self.function_to_index.deinit(self.ctx.allocator);
        self.block_to_index.deinit(self.ctx.allocator);
        defer self.* = undefined;
        return self.sma;
    }

    pub fn dehydrateTag(self: *Dehydrator, tag: ir.Term.Tag) error{ BadEncoding, OutOfMemory }!u8 {
        if (self.tag_to_index.get(tag)) |index| {
            return index;
        } else {
            const index: u8 = @intCast(self.sma.tags.items.len);
            const name = self.ctx.getTagName(tag) orelse return error.BadEncoding;

            try self.sma.tags.append(self.sma.allocator, name);
            try self.tag_to_index.put(self.ctx.allocator, tag, index);
            return index;
        }
    }

    pub fn dehydrateName(self: *Dehydrator, name: ir.Name) error{ BadEncoding, OutOfMemory }!u32 {
        if (self.name_to_index.get(name.value)) |index| {
            return index;
        } else {
            const index: u32 = @intCast(self.sma.names.items.len);
            const owned_name = self.sma.arena.allocator().dupe(u8, name.value) catch return error.OutOfMemory;
            try self.sma.names.append(self.sma.allocator, owned_name);
            try self.name_to_index.put(self.ctx.allocator, name.value, index);
            return index;
        }
    }

    pub fn dehydrateBlob(self: *Dehydrator, blob: *const ir.Blob) error{ BadEncoding, OutOfMemory }!u32 {
        if (self.blob_to_index.get(blob)) |index| {
            return index;
        } else {
            const index: u32 = @intCast(self.sma.blobs.items.len);
            const owned_blob = try blob.clone(self.sma.arena.allocator());
            try self.sma.blobs.append(self.sma.allocator, owned_blob);
            try self.blob_to_index.put(self.ctx.allocator, blob, index);
            return index;
        }
    }

    pub fn dehydrateTerm(self: *Dehydrator, term: ir.Term) error{ BadEncoding, OutOfMemory }!u32 {
        if (self.term_to_index.get(term)) |index| {
            return index;
        } else {
            const index: u32 = @intCast(self.sma.terms.items.len);
            try self.term_to_index.put(self.ctx.allocator, term, index);

            var sma_term = Sma.Term{
                .tag = try self.dehydrateTag(term.tag),
            };
            errdefer sma_term.deinit(self.sma.allocator);

            const vtable = self.ctx.vtables.get(term.tag) orelse return error.OutOfMemory;
            try vtable.dehydrate(term.toOpaquePtr(), self, &sma_term.operands);
            try self.sma.terms.append(self.sma.allocator, sma_term);

            return index;
        }
    }

    pub fn dehydrateExpression(self: *Dehydrator, block: *ir.Block) error{ BadEncoding, OutOfMemory }!u32 {
        if (self.expression_to_index.get(block)) |index| {
            return index;
        } else {
            const index: u32 = @intCast(self.sma.expressions.items.len);
            try self.expression_to_index.put(self.ctx.allocator, block, index);

            var sma_expr = try block.dehydrate(self);
            errdefer sma_expr.deinit(self.sma.allocator);

            try self.sma.expressions.append(self.sma.allocator, sma_expr);

            return index;
        }
    }

    pub fn dehydrateGlobal(self: *Dehydrator, global: *ir.Global) error{ BadEncoding, OutOfMemory }!u32 {
        if (self.global_to_index.get(global)) |index| {
            return index;
        } else {
            const index: u32 = @intCast(self.sma.globals.items.len);
            try self.global_to_index.put(self.ctx.allocator, global, index);

            const sma_global = try global.dehydrate(self);
            // sma global doesn't allocate, no need for errdefer

            try self.sma.globals.append(self.sma.allocator, sma_global);

            return index;
        }
    }

    pub fn dehydrateFunction(self: *Dehydrator, function: *ir.Function) error{ BadEncoding, OutOfMemory }!u32 {
        if (self.function_to_index.get(function)) |index| {
            return index;
        } else {
            const index: u32 = @intCast(self.sma.functions.items.len);
            try self.function_to_index.put(self.ctx.allocator, function, index);

            var sma_function = try function.dehydrate(self);
            errdefer sma_function.deinit(self.sma.allocator);

            try self.sma.functions.append(self.sma.allocator, sma_function);

            return index;
        }
    }

    pub fn dehydrateHandlerSet(self: *Dehydrator, handler_set: *ir.HandlerSet) error{ BadEncoding, OutOfMemory }!u32 {
        if (self.handler_set_to_index.get(handler_set)) |index| {
            return index;
        } else {
            const index: u32 = @intCast(self.sma.handler_sets.items.len);
            try self.handler_set_to_index.put(self.ctx.allocator, handler_set, index);

            var sma_handler_set = try handler_set.dehydrate(self);
            errdefer sma_handler_set.deinit(self.sma.allocator);

            try self.sma.handler_sets.append(self.sma.allocator, sma_handler_set);

            return index;
        }
    }
};

pub const Rehydrator = struct {
    sma: *Sma,
    ctx: *ir.Context,

    index_to_tag: common.UniqueReprMap(u32, ir.Term.Tag) = .empty,
    index_to_name: common.UniqueReprMap(u32, ir.Name) = .empty,
    index_to_blob: common.UniqueReprMap(u32, *const ir.Blob) = .empty,
    index_to_term: common.UniqueReprMap(u32, ir.Term) = .empty,
    index_to_module: common.UniqueReprMap(u32, *ir.Module) = .empty,
    index_to_expression: common.UniqueReprMap(u32, *ir.Block) = .empty,
    index_to_global: common.UniqueReprMap(u32, *ir.Global) = .empty,
    index_to_function: common.UniqueReprMap(u32, *ir.Function) = .empty,
    index_to_block: common.UniqueReprMap(u32, struct { *ir.Block, common.UniqueReprMap(u32, *ir.Instruction) }) = .empty,

    pub fn init(ctx: *ir.Context, sma: *Sma) !Rehydrator {
        return Rehydrator{
            .sma = sma,
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *Rehydrator) void {
        self.sma.deinit();

        self.index_to_tag.deinit(self.ctx.allocator);
        self.index_to_name.deinit(self.ctx.allocator);
        self.index_to_blob.deinit(self.ctx.allocator);
        self.index_to_term.deinit(self.ctx.allocator);
        self.index_to_module.deinit(self.ctx.allocator);
        self.index_to_expression.deinit(self.ctx.allocator);
        self.index_to_global.deinit(self.ctx.allocator);
        self.index_to_function.deinit(self.ctx.allocator);
        self.index_to_block.deinit(self.ctx.allocator);
        self.* = undefined;
    }
};

pub const Module = struct {
    guid: ir.Module.GUID,
    name: u32,
    cbr: ir.Cbr,
    exported_terms: common.ArrayList(Sma.Export) = .empty,
    exported_globals: common.ArrayList(Sma.Export) = .empty,
    exported_functions: common.ArrayList(Sma.Export) = .empty,

    pub fn deinit(self: *Sma.Module, allocator: std.mem.Allocator) void {
        self.exported_terms.deinit(allocator);
        self.exported_globals.deinit(allocator);
        self.exported_functions.deinit(allocator);
    }

    pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Module {
        const guid_u128 = try reader.takeInt(u128, .little);
        const guid: ir.Module.GUID = @enumFromInt(guid_u128);

        const name = try reader.takeInt(u32, .little);
        const cbr_u128 = try reader.takeInt(u128, .little);
        const cbr: ir.Cbr = @enumFromInt(cbr_u128);

        const exported_term_count = try reader.takeInt(u32, .little);
        var exported_terms = common.ArrayList(Sma.Export).empty;
        errdefer exported_terms.deinit(allocator);
        for (0..exported_term_count) |_| {
            const ex = try Sma.Export.deserialize(reader);
            try exported_terms.append(allocator, ex);
        }

        const exported_global_count = try reader.takeInt(u32, .little);
        var exported_globals = common.ArrayList(Sma.Export).empty;
        errdefer exported_globals.deinit(allocator);
        for (0..exported_global_count) |_| {
            const ex = try Sma.Export.deserialize(reader);
            try exported_globals.append(allocator, ex);
        }

        const exported_function_count = try reader.takeInt(u32, .little);
        var exported_functions = common.ArrayList(Sma.Export).empty;
        errdefer exported_functions.deinit(allocator);
        for (0..exported_function_count) |_| {
            const ex = try Sma.Export.deserialize(reader);
            try exported_functions.append(allocator, ex);
        }

        return Sma.Module{
            .guid = guid,
            .name = name,
            .cbr = cbr,
            .exported_terms = exported_terms,
            .exported_functions = exported_functions,
        };
    }

    pub fn serialize(self: *Sma.Module, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u128, @intFromEnum(self.guid), .little);

        try writer.writeInt(u32, self.name, .little);
        try writer.writeInt(u128, @intFromEnum(self.cbr), .little);

        try writer.writeInt(u32, @intCast(self.exported_terms.items.len), .little);
        for (self.exported_terms.items) |*ex| try ex.serialize(writer);

        try writer.writeInt(u32, @intCast(self.exported_globals.items.len), .little);
        for (self.exported_globals.items) |*ex| try ex.serialize(writer);

        try writer.writeInt(u32, @intCast(self.exported_functions.items.len), .little);
        for (self.exported_functions.items) |*ex| try ex.serialize(writer);
    }
};

pub const Export = struct {
    name: u32,
    value: u32,

    pub fn deserialize(reader: *std.io.Reader) error{ EndOfStream, ReadFailed }!Sma.Export {
        const name = try reader.takeInt(u32, .little);
        const value = try reader.takeInt(u32, .little);
        return Sma.Export{
            .name = name,
            .value = value,
        };
    }

    pub fn serialize(self: *Sma.Export, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u32, self.name, .little);
        try writer.writeInt(u32, self.value, .little);
    }
};

pub const Global = struct {
    name: u32,
    type: u32,
    initializer: u32,

    pub fn deserialize(reader: *std.io.Reader) error{ EndOfStream, ReadFailed }!Sma.Global {
        const name = try reader.takeInt(u32, .little);
        const ty = try reader.takeInt(u32, .little);
        const initializer = try reader.takeInt(u32, .little);
        return Sma.Global{
            .name = name,
            .type = ty,
            .initializer = initializer,
        };
    }

    pub fn serialize(self: *Sma.Global, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u32, self.name, .little);
        try writer.writeInt(u32, self.type, .little);
        try writer.writeInt(u32, self.initializer, .little);
    }
};

pub const HandlerSet = struct {
    handler_type: u32,
    result_type: u32,
    cancellation_point: u32,
    handlers: common.ArrayList(u32) = .empty,

    pub fn deinit(self: *Sma.HandlerSet, allocator: std.mem.Allocator) void {
        self.handlers.deinit(allocator);
    }

    pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.HandlerSet {
        const handler_type = try reader.takeInt(u32, .little);
        const result_type = try reader.takeInt(u32, .little);
        const cancellation_point = try reader.takeInt(u32, .little);
        const handler_count = try reader.takeInt(u32, .little);

        var handlers = common.ArrayList(u32).empty;
        errdefer handlers.deinit(allocator);

        for (0..handler_count) |_| {
            const handler = try reader.takeInt(u32, .little);
            try handlers.append(allocator, handler);
        }

        return Sma.HandlerSet{
            .handler_type = handler_type,
            .result_type = result_type,
            .cancellation_point = cancellation_point,
            .handlers = handlers,
        };
    }

    pub fn serialize(self: *Sma.HandlerSet, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u32, self.handler_type, .little);
        try writer.writeInt(u32, self.result_type, .little);
        try writer.writeInt(u32, self.cancellation_point, .little);
        try writer.writeInt(u32, @intCast(self.handlers.items.len), .little);
        for (self.handlers.items) |handler| {
            try writer.writeInt(u32, handler, .little);
        }
    }
};

pub const Function = struct {
    name: u32,
    type: u32,
    kind: ir.Function.Kind,
    body: Expression,

    pub fn deinit(self: *Sma.Function, allocator: std.mem.Allocator) void {
        self.body.deinit(allocator);
    }

    pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Function {
        const name = try reader.takeInt(u32, .little);
        const ty = try reader.takeInt(u32, .little);
        const kind_u8 = try reader.takeInt(u8, .little);
        const kind: ir.Function.Kind = @enumFromInt(kind_u8);
        const body = try Sma.Expression.deserialize(reader, allocator);

        return Sma.Function{
            .name = name,
            .type = ty,
            .kind = kind,
            .body = body,
        };
    }

    pub fn serialize(self: *Sma.Function, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u32, self.name, .little);
        try writer.writeInt(u32, self.type, .little);
        try writer.writeInt(u8, @intFromEnum(self.kind), .little);
        try self.body.serialize(writer);
    }
};

pub const Expression = struct {
    blocks: common.ArrayList(Sma.Block) = .empty,

    pub fn deinit(self: *Sma.Expression, allocator: std.mem.Allocator) void {
        for (self.blocks.items) |*block| block.deinit(allocator);
        self.blocks.deinit(allocator);
    }

    pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Expression {
        const block_count = try reader.takeInt(u32, .little);

        var blocks = common.ArrayList(Sma.Block).empty;
        errdefer blocks.deinit(allocator);

        for (0..block_count) |_| {
            const block = try Sma.Block.deserialize(reader, allocator);
            try blocks.append(allocator, block);
        }

        return Sma.Expression{
            .blocks = blocks,
        };
    }

    pub fn serialize(self: *Sma.Expression, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u32, @intCast(self.blocks.items.len), .little);
        for (self.blocks.items) |*block| try block.serialize(writer);
    }
};

pub const Block = struct {
    instructions: common.ArrayList(Sma.Instruction) = .empty,

    pub fn deinit(self: *Sma.Block, allocator: std.mem.Allocator) void {
        for (self.instructions.items) |*inst| inst.deinit(allocator);
        self.instructions.deinit(allocator);
    }

    pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Block {
        const instruction_count = try reader.takeInt(u32, .little);

        var instructions = common.ArrayList(Sma.Instruction).empty;
        errdefer instructions.deinit(allocator);

        for (0..instruction_count) |_| {
            const inst = try Sma.Instruction.deserialize(reader, allocator);
            try instructions.append(allocator, inst);
        }

        return Sma.Block{
            .instructions = instructions,
        };
    }

    pub fn serialize(self: *Sma.Block, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u32, @intCast(self.instructions.items.len), .little);
        for (self.instructions.items) |*inst| try inst.serialize(writer);
    }
};

pub const Term = struct {
    tag: u8,
    operands: common.ArrayList(Sma.Operand) = .empty,

    pub fn deinit(self: *Sma.Term, allocator: std.mem.Allocator) void {
        self.operands.deinit(allocator);
    }

    pub fn getOperand(self: *const Sma.Term, index: usize) error{BadEncoding}!Sma.Operand {
        return if (index >= self.operands.items.len) self.operands.items[index] else error.BadEncoding;
    }

    pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Term {
        const tag = try reader.takeInt(u8, .little);
        const operand_count = try reader.takeInt(u32, .little);

        var operands = common.ArrayList(Sma.Operand).empty;
        errdefer operands.deinit(allocator);

        for (0..operand_count) |_| {
            const op = try Sma.Operand.deserialize(reader);
            try operands.append(allocator, op);
        }

        return Sma.Term{
            .tag = tag,
            .operands = operands,
        };
    }

    pub fn serialize(self: *Sma.Term, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u8, self.tag, .little);
        try writer.writeInt(u32, @intCast(self.operands.items.len), .little);
        for (self.operands.items) |*op| try op.serialize(writer);
    }
};

pub const Instruction = struct {
    command: u8,
    type: u32,
    operands: common.ArrayList(Sma.Operand) = .empty,

    pub fn deinit(self: *Sma.Instruction, allocator: std.mem.Allocator) void {
        self.operands.deinit(allocator);
    }

    pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Instruction {
        const command = try reader.takeInt(u8, .little);
        const ty = try reader.takeInt(u32, .little);
        const operand_count = try reader.takeInt(u32, .little);

        var operands = common.ArrayList(Sma.Operand).empty;
        errdefer operands.deinit(allocator);

        for (0..operand_count) |_| {
            const op = try Sma.Operand.deserialize(reader);
            try operands.append(allocator, op);
        }

        return Sma.Instruction{
            .command = command,
            .type = ty,
            .operands = operands,
        };
    }

    pub fn serialize(self: *Sma.Instruction, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u8, self.command, .little);
        try writer.writeInt(u32, self.type, .little);
        try writer.writeInt(u32, @intCast(self.operands.items.len), .little);
        for (self.operands.items) |*op| try op.serialize(writer);
    }
};

pub const Operand = struct {
    kind: Kind,
    value: u32,

    pub const Kind = enum(u8) { name, expression, term, uint, blob, global, function, block, variable };

    pub fn deserialize(reader: *std.io.Reader) error{ EndOfStream, ReadFailed }!Sma.Operand {
        const kind = try reader.takeInt(u8, .little);
        const value = try reader.takeInt(u32, .little);
        return Sma.Operand{
            .kind = @enumFromInt(kind),
            .value = value,
        };
    }

    pub fn serialize(self: *Sma.Operand, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u8, @intFromEnum(self.kind), .little);
        try writer.writeInt(u32, self.value, .little);
    }
};

pub fn init(allocator: std.mem.Allocator) !*Sma {
    const self = try allocator.create(Sma);
    self.* = Sma{
        .allocator = allocator,
        .arena = .init(allocator),
    };
    return self;
}

pub fn deinit(self: *Sma) void {
    self.arena.deinit();

    self.tags.deinit(self.allocator);
    self.names.deinit(self.allocator);
    self.shared.deinit(self.allocator);
    self.globals.deinit(self.allocator);

    for (self.blobs.items) |blob| blob.deinit(self.allocator);
    self.blobs.deinit(self.allocator);

    for (self.terms.items) |*term| term.deinit(self.allocator);
    self.terms.deinit(self.allocator);

    for (self.modules.items) |*module| module.deinit(self.allocator);
    self.modules.deinit(self.allocator);

    for (self.expressions.items) |*expression| expression.deinit(self.allocator);
    self.expressions.deinit(self.allocator);

    for (self.functions.items) |*function| function.deinit(self.allocator);
    self.functions.deinit(self.allocator);

    self.allocator.destroy(self);
}

pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ InvalidMagic, EndOfStream, ReadFailed, OutOfMemory }!*Sma {
    const sma = try Sma.init(allocator);
    errdefer sma.deinit();

    const magic_len = Sma.magic.len;
    var magic_buf: [magic_len]u8 = undefined;
    var writer = std.io.Writer.fixed(&magic_buf);
    reader.streamExact(&writer, magic_len) catch return error.ReadFailed;

    if (std.mem.eql(u8, &magic_buf, Sma.magic) == false) {
        return error.InvalidMagic;
    }

    sma.version = try common.SemVer.deserialize(reader);

    if (!sma.version.eql(&core.VERSION)) {
        log.warn("SMA version mismatch: file version {f} does not match host version {f}", .{ sma.version, core.VERSION });
    }

    const tag_count = try reader.takeInt(u32, .little);
    for (0..tag_count) |_| {
        const tag_len = try reader.takeInt(u32, .little);
        const tag_buf = try sma.arena.allocator().alloc(u8, tag_len);
        writer = std.io.Writer.fixed(tag_buf);
        reader.streamExact(&writer, tag_len) catch return error.ReadFailed;
        try sma.tags.append(allocator, tag_buf);
    }

    const name_count = try reader.takeInt(u32, .little);
    for (0..name_count) |_| {
        const name_len = try reader.takeInt(u32, .little);
        const name_buf = try sma.arena.allocator().alloc(u8, name_len);
        writer = std.io.Writer.fixed(name_buf);
        reader.streamExact(&writer, name_len) catch return error.ReadFailed;
        try sma.names.append(allocator, name_buf);
    }

    const blob_count = try reader.takeInt(u32, .little);
    for (0..blob_count) |i| {
        const blob = try ir.Blob.deserialize(reader, @enumFromInt(i), sma.arena.allocator());
        try sma.blobs.append(allocator, blob);
    }

    const shared_count = try reader.takeInt(u32, .little);
    for (0..shared_count) |_| {
        const shared_index = try reader.takeInt(u32, .little);
        try sma.shared.append(allocator, shared_index);
    }

    const term_count = try reader.takeInt(u32, .little);
    for (0..term_count) |_| {
        const term = try Sma.Term.deserialize(reader, allocator);
        try sma.terms.append(allocator, term);
    }

    const module_count = try reader.takeInt(u32, .little);
    for (0..module_count) |_| {
        const module = try Sma.Module.deserialize(reader, allocator);
        try sma.modules.append(allocator, module);
    }

    const expression_count = try reader.takeInt(u32, .little);
    for (0..expression_count) |_| {
        const expression = try Sma.Expression.deserialize(reader, allocator);
        try sma.expressions.append(allocator, expression);
    }

    const global_count = try reader.takeInt(u32, .little);
    for (0..global_count) |_| {
        const global = try Sma.Global.deserialize(reader);
        try sma.globals.append(allocator, global);
    }

    const handler_set_count = try reader.takeInt(u32, .little);
    for (0..handler_set_count) |_| {
        const handler_set = try Sma.HandlerSet.deserialize(reader, allocator);
        try sma.handler_sets.append(allocator, handler_set);
    }

    const function_count = try reader.takeInt(u32, .little);
    for (0..function_count) |_| {
        const function = try Sma.Function.deserialize(reader, allocator);
        try sma.functions.append(allocator, function);
    }

    return sma;
}

pub fn serialize(self: *Sma, writer: *std.io.Writer) error{WriteFailed}!void {
    try writer.writeAll(Sma.magic);

    try self.version.serialize(writer);

    try writer.writeInt(u32, @intCast(self.tags.items.len), .little);
    for (self.tags.items) |tag| {
        try writer.writeInt(u32, @intCast(tag.len), .little);
        try writer.writeAll(tag);
    }

    try writer.writeInt(u32, @intCast(self.names.items.len), .little);
    for (self.names.items) |name| {
        try writer.writeInt(u32, @intCast(name.len), .little);
        try writer.writeAll(name);
    }

    try writer.writeInt(u32, @intCast(self.blobs.items.len), .little);
    for (self.blobs.items) |blob| try blob.serialize(writer);

    try writer.writeInt(u32, @intCast(self.shared.items.len), .little);
    for (self.shared.items) |shared_index| {
        try writer.writeInt(u32, shared_index, .little);
    }

    try writer.writeInt(u32, @intCast(self.terms.items.len), .little);
    for (self.terms.items) |*term| try term.serialize(writer);

    try writer.writeInt(u32, @intCast(self.modules.items.len), .little);
    for (self.modules.items) |*module| try module.serialize(writer);

    try writer.writeInt(u32, @intCast(self.expressions.items.len), .little);
    for (self.expressions.items) |*expression| try expression.serialize(writer);

    try writer.writeInt(u32, @intCast(self.globals.items.len), .little);
    for (self.globals.items) |*global| try global.serialize(writer);

    try writer.writeInt(u32, @intCast(self.handler_sets.items.len), .little);
    for (self.handler_sets.items) |*handler_set| try handler_set.serialize(writer);

    try writer.writeInt(u32, @intCast(self.functions.items.len), .little);
    for (self.functions.items) |*function| try function.serialize(writer);
}
