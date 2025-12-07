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

shared: common.UniqueReprSet(u32) = .empty,
cbr: common.UniqueReprMap(Sma.Operand, ir.Cbr) = .empty,

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
    expression_to_index: common.UniqueReprMap(*ir.Expression, u32) = .empty,
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
            try self.name_to_index.put(self.ctx.allocator, name.value, index);

            const owned_name = self.sma.arena.allocator().dupe(u8, name.value) catch return error.OutOfMemory;
            try self.sma.names.append(self.sma.allocator, owned_name);

            var hasher = ir.Cbr.Hasher.init();
            hasher.update(name.value);
            try self.sma.cbr.put(self.sma.allocator, .{ .kind = .name, .value = index }, hasher.final());

            return index;
        }
    }

    pub fn dehydrateBlob(self: *Dehydrator, blob: *const ir.Blob) error{ BadEncoding, OutOfMemory }!u32 {
        if (self.blob_to_index.get(blob)) |index| {
            return index;
        } else {
            const index: u32 = @intCast(self.sma.blobs.items.len);
            try self.blob_to_index.put(self.ctx.allocator, blob, index);

            const owned_blob = try blob.clone(self.sma.arena.allocator());
            try self.sma.blobs.append(self.sma.allocator, owned_blob);

            const cbr = owned_blob.getCbr();
            try self.sma.cbr.put(self.sma.allocator, .{ .kind = .blob, .value = index }, cbr);

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

            const cbr = sma_term.getCbr(self.sma);
            try self.sma.cbr.put(self.sma.allocator, .{ .kind = .term, .value = index }, cbr);

            if (term.isShared()) {
                try self.sma.shared.put(self.sma.allocator, index, {});
            }

            return index;
        }
    }

    pub fn dehydrateExpression(self: *Dehydrator, expr: *ir.Expression) error{ BadEncoding, OutOfMemory }!u32 {
        if (self.expression_to_index.get(expr)) |index| {
            return index;
        } else {
            const index: u32 = @intCast(self.sma.expressions.items.len);
            try self.expression_to_index.put(self.ctx.allocator, expr, index);

            var sma_expr = try expr.dehydrate(self);
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

            const cbr = sma_global.getCbr(self.sma);
            try self.sma.cbr.put(self.sma.allocator, .{ .kind = .global, .value = index }, cbr);

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

            const cbr = sma_function.getCbr(self.sma);
            try self.sma.cbr.put(self.sma.allocator, .{ .kind = .function, .value = index }, cbr);

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

            const cbr = sma_handler_set.getCbr(self.sma);
            try self.sma.cbr.put(self.sma.allocator, .{ .kind = .handler_set, .value = index }, cbr);

            return index;
        }
    }

    pub fn dehydrateModule(self: *Dehydrator, module: *ir.Module) error{ BadEncoding, OutOfMemory }!u32 {
        if (self.module_to_index.get(module)) |index| {
            return index;
        } else {
            const index: u32 = @intCast(self.sma.modules.items.len);
            try self.module_to_index.put(self.ctx.allocator, module, index);

            var sma_module = try module.dehydrate(self);
            errdefer sma_module.deinit(self.sma.allocator);

            try self.sma.modules.append(self.sma.allocator, sma_module);

            const cbr = sma_module.getCbr(self.sma);
            try self.sma.cbr.put(self.sma.allocator, .{ .kind = .module, .value = index }, cbr);

            return index;
        }
    }
};

pub const Rehydrator = struct {
    sma: *const Sma,
    ctx: *ir.Context,

    index_to_tag: common.UniqueReprMap(u8, ir.Term.Tag) = .empty,
    index_to_name: common.UniqueReprMap(u32, ir.Name) = .empty,
    index_to_blob: common.UniqueReprMap(u32, *const ir.Blob) = .empty,
    index_to_term: common.UniqueReprMap(u32, ir.Term) = .empty,
    module_to_index: common.UniqueReprMap(ir.Module.GUID, u32) = .empty,
    index_to_expression: common.UniqueReprMap(u32, *ir.Expression) = .empty,
    index_to_handler_set: common.UniqueReprMap(u32, *ir.HandlerSet) = .empty,
    index_to_global: common.UniqueReprMap(u32, *ir.Global) = .empty,
    index_to_function: common.UniqueReprMap(u32, *ir.Function) = .empty,

    pub fn init(ctx: *ir.Context, sma: *const Sma) !Rehydrator {
        var self = Rehydrator{
            .sma = sma,
            .ctx = ctx,
        };

        for (sma.modules.items, 0..) |module, i| {
            try self.module_to_index.put(ctx.allocator, module.guid, @intCast(i));
        }

        return self;
    }

    pub fn deinit(self: *Rehydrator) void {
        self.sma.deinit();

        self.index_to_tag.deinit(self.ctx.allocator);
        self.index_to_name.deinit(self.ctx.allocator);
        self.index_to_blob.deinit(self.ctx.allocator);
        self.index_to_term.deinit(self.ctx.allocator);
        self.module_to_index.deinit(self.ctx.allocator);
        self.index_to_expression.deinit(self.ctx.allocator);
        self.index_to_handler_set.deinit(self.ctx.allocator);
        self.index_to_global.deinit(self.ctx.allocator);
        self.index_to_function.deinit(self.ctx.allocator);
        self.* = undefined;
    }

    pub fn rehydrateTag(self: *Rehydrator, index: u8) error{ BadEncoding, OutOfMemory }!ir.Term.Tag {
        if (self.index_to_tag.get(index)) |tag| {
            return tag;
        } else {
            if (index >= self.sma.tags.items.len) {
                return error.BadEncoding;
            }

            const name = self.sma.tags.items[index];
            const tag = self.ctx.tagFromName(name) orelse return error.BadEncoding;

            try self.index_to_tag.put(self.ctx.allocator, index, tag);
            return tag;
        }
    }

    pub fn rehydrateName(self: *Rehydrator, index: u32) error{ BadEncoding, OutOfMemory }!ir.Name {
        if (self.index_to_name.get(index)) |name| {
            return name;
        } else {
            if (index >= self.sma.names.items.len) {
                return error.BadEncoding;
            }

            const sma_name = self.sma.names.items[index];
            const name = try self.ctx.internName(sma_name);

            try self.index_to_name.put(self.ctx.allocator, index, name);
            return name;
        }
    }

    pub fn tryRehydrateName(self: *Rehydrator, index: u32) error{ BadEncoding, OutOfMemory }!?ir.Name {
        if (index == Sma.sentinel_index) {
            return null;
        } else {
            return try self.rehydrateName(index);
        }
    }

    pub fn rehydrateBlob(self: *Rehydrator, index: u32) error{ BadEncoding, OutOfMemory }!*const ir.Blob {
        if (self.index_to_blob.get(index)) |blob| {
            return blob;
        } else {
            if (index >= self.sma.blobs.items.len) {
                return error.BadEncoding;
            }

            const sma_blob = self.sma.blobs.items[index];
            const blob = try self.ctx.internData(sma_blob.layout.alignment, sma_blob.getBytes());

            try self.index_to_blob.put(self.ctx.allocator, index, blob);
            return blob;
        }
    }

    pub fn rehydrateTerm(self: *Rehydrator, index: u32) error{ BadEncoding, OutOfMemory }!ir.Term {
        if (self.index_to_term.get(index)) |term| {
            return term;
        } else {
            if (index >= self.sma.terms.items.len) {
                return error.BadEncoding;
            }

            const sma_term = &self.sma.terms.items[index];
            const tag = try self.rehydrateTag(sma_term.tag);

            const vtable = self.ctx.vtables.get(tag) orelse return error.BadEncoding;

            const term_value = vtable.create(self.ctx) catch |err| {
                return switch (err) {
                    error.ZigTypeNotRegistered => @panic("Term VTable exists but vtable.create reports ZigTypeNotRegistered"),
                    error.OutOfMemory => error.OutOfMemory,
                };
            };
            try vtable.rehydrate(sma_term, self, term_value);

            var term = ir.Term{
                .tag = tag,
                .header_offset = vtable.offset,
                .ptr = @intCast(@intFromPtr(term_value)),
            };

            if (self.sma.shared.contains(index)) {
                if (vtable.getShared(term_value, self.ctx)) |shared_term| {
                    // the arena can sometimes reclaim the temporary memory here, let's destroy it
                    // TODO? a slightly more advanced memory management strategy could fully reclaim here, but this is fine for now
                    vtable.destroy(term_value, self.ctx);

                    term = shared_term;
                }
            }

            try self.index_to_term.put(self.ctx.allocator, index, term);
            return term;
        }
    }

    pub fn rehydrateExpression(self: *Rehydrator, index: u32) error{ BadEncoding, OutOfMemory }!*ir.Expression {
        if (self.index_to_expression.get(index)) |expr| {
            return expr;
        } else {
            if (index >= self.sma.expressions.items.len) {
                return error.BadEncoding;
            }

            const sma_expr = &self.sma.expressions.items[index];

            const expr = try ir.Expression.rehydrate(sma_expr, self, null);
            errdefer expr.deinit();

            try self.index_to_expression.put(self.ctx.allocator, index, expr);

            return expr;
        }
    }

    pub fn rehydrateGlobal(self: *Rehydrator, index: u32) error{ BadEncoding, OutOfMemory }!*ir.Global {
        if (self.index_to_global.get(index)) |global| {
            return global;
        } else {
            if (index >= self.sma.globals.items.len) {
                return error.BadEncoding;
            }

            const sma_global = &self.sma.globals.items[index];

            const global = try ir.Global.rehydrate(sma_global, self);
            errdefer global.module.global_pool.destroy(global) catch |err| {
                log.err("Failed to destroy global on rehydrate error: {s}", .{@errorName(err)});
            };

            try self.index_to_global.put(self.ctx.allocator, index, global);

            return global;
        }
    }

    pub fn rehydrateFunction(self: *Rehydrator, index: u32) error{ BadEncoding, OutOfMemory }!*ir.Function {
        if (self.index_to_function.get(index)) |function| {
            return function;
        } else {
            if (index >= self.sma.functions.items.len) {
                return error.BadEncoding;
            }

            const sma_function = &self.sma.functions.items[index];

            const function = try ir.Function.rehydrate(sma_function, self);
            errdefer {
                function.deinit();
                function.body.module.function_pool.destroy(function) catch |err| {
                    log.err("Failed to destroy function on rehydrate error: {s}", .{@errorName(err)});
                };
            }

            try self.index_to_function.put(self.ctx.allocator, index, function);

            return function;
        }
    }
};

pub const Module = struct {
    guid: ir.Module.GUID,
    name: u32,
    exports: common.ArrayList(Sma.Export) = .empty,

    pub fn deinit(self: *Sma.Module, allocator: std.mem.Allocator) void {
        self.exports.deinit(allocator);
    }

    pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Module {
        const guid_u128 = try reader.takeInt(u128, .little);
        const guid: ir.Module.GUID = @enumFromInt(guid_u128);

        const name = try reader.takeInt(u32, .little);

        const export_count = try reader.takeInt(u32, .little);
        var exports = common.ArrayList(Sma.Export).empty;
        errdefer exports.deinit(allocator);
        for (0..export_count) |_| {
            const ex = try Sma.Export.deserialize(reader);
            try exports.append(allocator, ex);
        }

        return Sma.Module{
            .guid = guid,
            .name = name,
            .exports = exports,
        };
    }

    pub fn serialize(self: *Sma.Module, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u128, @intFromEnum(self.guid), .little);

        try writer.writeInt(u32, self.name, .little);

        try writer.writeInt(u32, @intCast(self.exports.items.len), .little);
        for (self.exports.items) |*ex| try ex.serialize(writer);
    }

    pub fn getCbr(self: *const Sma.Module, sma: *Sma) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("[Module]");

        hasher.update("guid:");
        hasher.update(@intFromEnum(self.guid));

        // module names do not factor into cbr

        hasher.update("exports:");
        for (self.exports.items, 0..) |ex, i| {
            hasher.update("export.index:");
            hasher.update(i);

            hasher.update("export.value:");
            hasher.update(ex.getCbr(sma));
        }

        return hasher.final();
    }
};

pub const Export = struct {
    name: u32,
    value: Operand,

    pub fn deserialize(reader: *std.io.Reader) error{ EndOfStream, ReadFailed }!Sma.Export {
        const name = try reader.takeInt(u32, .little);
        const value = try Operand.deserialize(reader);
        return Sma.Export{
            .name = name,
            .value = value,
        };
    }

    pub fn serialize(self: *Sma.Export, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u32, self.name, .little);
        try self.value.serialize(writer);
    }

    pub fn sort(buf: []Sma.Export) void {
        std.mem.sort(Sma.Export, buf, {}, struct {
            pub fn sma_export_sorter(_: void, a: Sma.Export, b: Sma.Export) bool {
                return a.name < b.name;
            }
        }.sma_export_sorter);
    }

    pub fn getCbr(self: *const Sma.Export, sma: *Sma) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("[Export]");

        hasher.update("name:");
        hasher.update(sma.cbr.get(.{ .kind = .name, .value = self.name }).?);

        hasher.update("value:");
        hasher.update(self.value.getCbr(sma));

        return hasher.final();
    }
};

pub const Global = struct {
    module: ir.Module.GUID,
    name: u32,
    type: u32,
    initializer: u32,

    pub fn deserialize(reader: *std.io.Reader) error{ EndOfStream, ReadFailed }!Sma.Global {
        const module_u128 = try reader.takeInt(u128, .little);
        const module_guid: ir.Module.GUID = @enumFromInt(module_u128);

        const name = try reader.takeInt(u32, .little);
        const ty = try reader.takeInt(u32, .little);
        const initializer = try reader.takeInt(u32, .little);
        return Sma.Global{
            .module = module_guid,
            .name = name,
            .type = ty,
            .initializer = initializer,
        };
    }

    pub fn serialize(self: *Sma.Global, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u128, @intFromEnum(self.module), .little);
        try writer.writeInt(u32, self.name, .little);
        try writer.writeInt(u32, self.type, .little);
        try writer.writeInt(u32, self.initializer, .little);
    }

    pub fn getCbr(self: *const Sma.Global, sma: *Sma) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("[Global]");

        hasher.update("name:"); // TODO: not sure if abi names should factor into cbr
        hasher.update(sma.cbr.get(.{ .kind = .name, .value = self.name }).?);

        hasher.update("type:");
        hasher.update(sma.cbr.get(.{ .kind = .term, .value = self.type }).?);

        hasher.update("initializer:");
        hasher.update(sma.cbr.get(.{ .kind = .term, .value = self.initializer }).?);

        return hasher.final();
    }
};

pub const HandlerSet = struct {
    module: ir.Module.GUID,
    handler_type: u32,
    result_type: u32,
    cancellation_point: u32,
    handlers: common.ArrayList(u32) = .empty,

    pub fn deinit(self: *Sma.HandlerSet, allocator: std.mem.Allocator) void {
        self.handlers.deinit(allocator);
    }

    pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.HandlerSet {
        const module_u128 = try reader.takeInt(u128, .little);
        const module_guid: ir.Module.GUID = @enumFromInt(module_u128);
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
            .module = module_guid,
            .handler_type = handler_type,
            .result_type = result_type,
            .cancellation_point = cancellation_point,
            .handlers = handlers,
        };
    }

    pub fn serialize(self: *Sma.HandlerSet, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u128, @intFromEnum(self.module), .little);
        try writer.writeInt(u32, self.handler_type, .little);
        try writer.writeInt(u32, self.result_type, .little);
        try writer.writeInt(u32, self.cancellation_point, .little);
        try writer.writeInt(u32, @intCast(self.handlers.items.len), .little);
        for (self.handlers.items) |handler| {
            try writer.writeInt(u32, handler, .little);
        }
    }

    pub fn getCbr(self: *const Sma.HandlerSet, sma: *Sma) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("[HandlerSet]");

        hasher.update("handler_type:");
        hasher.update(sma.cbr.get(.{ .kind = .term, .value = self.handler_type }).?);

        hasher.update("result_type:");
        hasher.update(sma.cbr.get(.{ .kind = .term, .value = self.result_type }).?);

        hasher.update("cancellation_point:");
        hasher.update(sma.cbr.get(.{ .kind = .term, .value = self.cancellation_point }).?);

        hasher.update("handlers:");
        for (self.handlers.items, 0..) |handler, i| {
            hasher.update("handler.index:");
            hasher.update(i);

            hasher.update("handler.value:");
            hasher.update(sma.cbr.get(.{ .kind = .function, .value = handler }).?);
        }

        return hasher.final();
    }
};

pub const Function = struct {
    name: u32,
    kind: ir.Function.Kind,
    body: Expression,

    pub fn deinit(self: *Sma.Function, allocator: std.mem.Allocator) void {
        self.body.deinit(allocator);
    }

    pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Function {
        const name = try reader.takeInt(u32, .little);
        const kind_u8 = try reader.takeInt(u8, .little);
        const kind: ir.Function.Kind = @enumFromInt(kind_u8);

        const body = try Sma.Expression.deserialize(reader, allocator);

        return Sma.Function{
            .name = name,
            .kind = kind,
            .body = body,
        };
    }

    pub fn serialize(self: *Sma.Function, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u32, self.name, .little);
        try writer.writeInt(u8, @intFromEnum(self.kind), .little);

        try self.body.serialize(writer);
    }

    pub fn getCbr(self: *const Sma.Function, sma: *Sma) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("[Function]");

        hasher.update("name:"); // TODO: not sure if abi names should factor into cbr
        hasher.update(sma.cbr.get(.{ .kind = .name, .value = self.name }).?);

        hasher.update("kind:");
        hasher.update(self.kind);

        hasher.update("body:");
        hasher.update(self.body.getCbr(sma));

        return hasher.final();
    }
};

pub const Expression = struct {
    module: ir.Module.GUID,
    type: u32,
    handler_sets: common.ArrayList(u32) = .empty,
    blocks: common.ArrayList(Sma.Block) = .empty,
    instructions: common.ArrayList(Sma.Instruction) = .empty,

    pub fn deinit(self: *Sma.Expression, allocator: std.mem.Allocator) void {
        self.handler_sets.deinit(allocator);
        self.blocks.deinit(allocator);
        for (self.instructions.items) |*inst| inst.deinit(allocator);
        self.instructions.deinit(allocator);
    }

    pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Expression {
        const module_u128 = try reader.takeInt(u128, .little);
        const module_guid: ir.Module.GUID = @enumFromInt(module_u128);

        const type_id = try reader.takeInt(u32, .little);

        const handler_set_count = try reader.takeInt(u32, .little);
        var handler_sets = common.ArrayList(u32).empty;
        errdefer handler_sets.deinit(allocator);
        for (0..handler_set_count) |_| {
            const hs_id = try reader.takeInt(u32, .little);
            try handler_sets.append(allocator, hs_id);
        }

        const block_count = try reader.takeInt(u32, .little);

        var blocks = common.ArrayList(Sma.Block).empty;
        errdefer blocks.deinit(allocator);

        for (0..block_count) |_| {
            const block = try Sma.Block.deserialize(reader);
            try blocks.append(allocator, block);
        }

        var instructions = common.ArrayList(Sma.Instruction).empty;
        errdefer instructions.deinit(allocator);

        const instruction_count = try reader.takeInt(u32, .little);
        for (0..instruction_count) |_| {
            const inst = try Sma.Instruction.deserialize(reader, allocator);
            try instructions.append(allocator, inst);
        }

        return Sma.Expression{
            .module = module_guid,
            .type = type_id,
            .handler_sets = handler_sets,
            .blocks = blocks,
            .instructions = instructions,
        };
    }

    pub fn serialize(self: *Sma.Expression, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u128, @intFromEnum(self.module), .little);

        try writer.writeInt(u32, self.type, .little);

        try writer.writeInt(u32, @intCast(self.handler_sets.items.len), .little);
        for (self.handler_sets.items) |hs_id| try writer.writeInt(u32, hs_id, .little);

        try writer.writeInt(u32, @intCast(self.blocks.items.len), .little);
        for (self.blocks.items) |*block| try block.serialize(writer);

        try writer.writeInt(u32, @intCast(self.instructions.items.len), .little);
        for (self.instructions.items) |*inst| try inst.serialize(writer);
    }

    pub fn getCbr(self: *const Sma.Expression, sma: *Sma) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("[Expression]");

        hasher.update("type:");
        hasher.update(sma.cbr.get(.{ .kind = .term, .value = self.type }).?);

        hasher.update("handler_sets:");
        for (self.handler_sets.items, 0..) |hs_id, i| {
            hasher.update("handler_set.index:");
            hasher.update(i);

            hasher.update("handler_set.value:");
            hasher.update(sma.cbr.get(.{ .kind = .handler_set, .value = hs_id }).?);
        }

        hasher.update("blocks:");
        for (self.blocks.items, 0..) |block, i| {
            hasher.update("block.index:");
            hasher.update(i);

            hasher.update("block.value:");
            hasher.update(block.getCbr());
        }

        hasher.update("instructions:");
        for (self.instructions.items, 0..) |inst, i| {
            hasher.update("instruction.index:");
            hasher.update(i);

            hasher.update("instruction.value:");
            hasher.update(inst.getCbr(sma));
        }

        return hasher.final();
    }
};

pub const Block = struct {
    name: u32,
    start: u32,
    count: u32,

    pub fn deserialize(reader: *std.io.Reader) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Block {
        return Sma.Block{
            .name = try reader.takeInt(u32, .little),
            .start = try reader.takeInt(u32, .little),
            .count = try reader.takeInt(u32, .little),
        };
    }

    pub fn serialize(self: *Sma.Block, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u32, self.name, .little);
        try writer.writeInt(u32, self.start, .little);
        try writer.writeInt(u32, self.count, .little);
    }

    pub fn getCbr(self: *const Sma.Block) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("[Block]");

        // names here are strictly debug, definitely don't factor into cbr

        hasher.update("start:");
        hasher.update(self.start);

        hasher.update("count:");
        hasher.update(self.count);

        return hasher.final();
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

    pub fn getOperandOf(self: *const Sma.Term, kind: Sma.Operand.Kind, index: usize) error{BadEncoding}!u32 {
        const op = try self.getOperand(index);
        if (op.kind != kind) {
            return error.BadEncoding;
        }
        return op.value;
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

    pub fn getCbr(self: *const Sma.Term, sma: *Sma) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("[Term]");

        hasher.update("tag:");
        hasher.update(&self.tag);

        hasher.update("operands.count:");
        hasher.update(self.operands.items.len);

        for (self.operands.items, 0..) |op, i| {
            const operand_cbr = sma.cbr.get(op).?;

            hasher.update("operand.index:");
            hasher.update(i);

            hasher.update("operand.value:");
            hasher.update(operand_cbr);
        }

        return hasher.final();
    }
};

pub const Instruction = struct {
    command: u8,
    type: u32,
    name: u32,
    operands: common.ArrayList(Sma.Operand) = .empty,

    pub fn deinit(self: *Sma.Instruction, allocator: std.mem.Allocator) void {
        self.operands.deinit(allocator);
    }

    pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Instruction {
        const command = try reader.takeInt(u8, .little);
        const ty = try reader.takeInt(u32, .little);
        const name = try reader.takeInt(u32, .little);
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
            .name = name,
            .operands = operands,
        };
    }

    pub fn serialize(self: *Sma.Instruction, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u8, self.command, .little);
        try writer.writeInt(u32, self.type, .little);
        try writer.writeInt(u32, self.name, .little);
        try writer.writeInt(u32, @intCast(self.operands.items.len), .little);
        for (self.operands.items) |*op| try op.serialize(writer);
    }

    pub fn getCbr(self: *const Sma.Instruction, sma: *Sma) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("[Instruction]");

        hasher.update("command:");
        hasher.update(&self.command);

        hasher.update("type:");
        hasher.update(sma.cbr.get(.{ .kind = .term, .value = self.type }).?);

        // name is debug only, doesn't factor into cbr

        hasher.update("operands.count:");
        hasher.update(self.operands.items.len);

        for (self.operands.items, 0..) |op, i| {
            hasher.update("operand.index:");
            hasher.update(i);

            hasher.update("operand.value:");
            hasher.update(op.getCbr(sma));
        }

        return hasher.final();
    }
};

pub const Operand = packed struct(u64) { // Must be packed for UniqueReprMap
    kind: Kind,
    value: u32,
    _unused: u24 = 0,

    pub const Kind = enum(u8) { module, name, expression, term, uint, blob, global, handler_set, function, block, variable };

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

    pub fn getCbr(self: *const Sma.Operand, sma: *Sma) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("[Operand]");

        hasher.update("kind:");
        hasher.update(self.kind);

        hasher.update("value:");
        switch (self.kind) {
            .uint, .variable, .block => {
                hasher.update(self.value);
            },
            else => {
                const operand_cbr = sma.cbr.get(self.*).?;
                hasher.update(operand_cbr);
            },
        }

        return hasher.final();
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

pub fn deinit(const_ptr: *const Sma) void {
    const self = @constCast(const_ptr);
    self.arena.deinit();

    self.tags.deinit(self.allocator);
    self.names.deinit(self.allocator);
    self.shared.deinit(self.allocator);
    self.globals.deinit(self.allocator);
    self.cbr.deinit(self.allocator);

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
    for (0..blob_count) |_| {
        const blob = try ir.Blob.deserialize(reader, sma.arena.allocator());
        try sma.blobs.append(allocator, blob);
    }

    const shared_count = try reader.takeInt(u32, .little);
    for (0..shared_count) |_| {
        const shared_index = try reader.takeInt(u32, .little);
        try sma.shared.put(allocator, shared_index, {});
    }

    const cbr_count = try reader.takeInt(u32, .little);
    for (0..cbr_count) |_| {
        const kind_u8 = try reader.takeInt(u8, .little);
        const kind: Sma.Operand.Kind = @enumFromInt(kind_u8);
        const operand_index = try reader.takeInt(u32, .little);
        const cbr_u128 = try reader.takeInt(u128, .little);
        const cbr: ir.Cbr = @enumFromInt(cbr_u128);
        try sma.cbr.put(allocator, Sma.Operand{ .kind = kind, .value = operand_index }, cbr);
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

    try writer.writeInt(u32, @intCast(self.shared.count()), .little);
    var shared_it = self.shared.keyIterator();
    while (shared_it.next()) |shared_index| {
        try writer.writeInt(u32, shared_index.*, .little);
    }

    try writer.writeInt(u32, @intCast(self.cbr.count()), .little);
    var cbr_it = self.cbr.iterator();
    while (cbr_it.next()) |kv| {
        try writer.writeInt(u8, @intFromEnum(kv.key_ptr.kind), .little);
        try writer.writeInt(u32, kv.key_ptr.value, .little);
        try writer.writeInt(u128, @intFromEnum(kv.value_ptr.*), .little);
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
