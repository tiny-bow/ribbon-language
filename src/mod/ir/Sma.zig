//! Serializable Module Artifact (SMA) format for Ribbon IR.
const Sma = @This();

const std = @import("std");
const log = std.log.scoped(.@"ir.sma");

const core = @import("core");
const common = @import("common");

const ir = @import("../ir.zig");

/// Allocator containing SMA managed data structures.
allocator: std.mem.Allocator,
/// Allocator containing interned data such as names and constants.
arena: std.heap.ArenaAllocator,

/// The semantic version number for this SMA.
version: common.SemVer = core.VERSION,

/// All registered term tags type names.
tags: common.ArrayList([]const u8) = .empty,
/// All interned symbolic names.
names: common.ArrayList([]const u8) = .empty,
/// All interned constant data blobs.
blobs: common.ArrayList(*const ir.Blob) = .empty,

/// Set of indices of terms that are interned.
shared: common.UniqueReprSet(u32) = .empty,
/// Map from SMA id to canonical binary representation (CBR) hash.
cbr: common.UniqueReprMap(Sma.Operand, ir.Cbr) = .empty,

/// All terms in the SMA, flattened.
terms: common.ArrayList(Sma.Term) = .empty,
/// All module definitions in the SMA.
modules: common.ArrayList(Sma.Module) = .empty,
/// All expressions in the SMA that are not function bodies.
expressions: common.ArrayList(Sma.Expression) = .empty,
/// All global variables in the SMA.
globals: common.ArrayList(Sma.Global) = .empty,
/// All effect handler sets in the SMA.
handler_sets: common.ArrayList(Sma.HandlerSet) = .empty,
/// All procedures and effect handlers in the SMA, with their expression body inline.
functions: common.ArrayList(Sma.Function) = .empty,

/// 8-byte magic number identifying a binary as a Ribbon IR SMA.
pub const magic = "RIBBONIR";
/// Sentinel index value indicating a missing optional reference.
pub const sentinel_index: u32 = std.math.maxInt(u32);

/// Intermediary structure for dehydrating IR into SMA format.
pub const Dehydrator = struct {
    /// The SMA being constructed.
    sma: *Sma,
    /// The IR being dehydrated.
    ctx: *ir.Context,

    /// Map from ir Tag to SMA tag index.
    tag_to_index: common.UniqueReprMap(ir.Term.Tag, u8) = .empty,
    /// Map from interned ir Name to SMA name index.
    name_to_index: common.StringMap(u32) = .empty,
    /// Map from ir Blob pointer to SMA blob index.
    blob_to_index: common.UniqueReprMap(*const ir.Blob, u32) = .empty,
    /// Map from ir Term to SMA term index.
    term_to_index: common.UniqueReprMap(ir.Term, u32) = .empty,
    /// Map from ir Module pointer to SMA module index.
    module_to_index: common.UniqueReprMap(*ir.Module, u32) = .empty,
    /// Map from ir Expression pointer to SMA expression index. Only used for non-function-body expressions.
    expression_to_index: common.UniqueReprMap(*ir.Expression, u32) = .empty,
    /// Map from ir Global pointer to SMA global index.
    global_to_index: common.UniqueReprMap(*ir.Global, u32) = .empty,
    /// Map from ir HandlerSet pointer to SMA handler set index.
    handler_set_to_index: common.UniqueReprMap(*ir.HandlerSet, u32) = .empty,
    /// Map from ir Function pointer to SMA function index.
    function_to_index: common.UniqueReprMap(*ir.Function, u32) = .empty,
    /// Map from ir Block pointer to SMA block index and instruction indices.
    block_to_index: common.UniqueReprMap(*ir.Block, struct { u32, common.UniqueReprMap(*ir.Instruction, u32) }) = .empty,

    /// Create a new Dehydrator for the given context. The provided allocator will be used to manage all SMA memory.
    pub fn init(ctx: *ir.Context, allocator: std.mem.Allocator) !Dehydrator {
        const sma = try Sma.init(allocator);
        return Dehydrator{
            .sma = sma,
            .ctx = ctx,
        };
    }

    /// Deinitialize this dehydrator, freeing its resources.
    pub fn deinit(self: *Dehydrator) void {
        self.finalize().deinit();
    }

    /// Finalize this dehydrator, freeing temporary resources and yielding the final Sma structure.
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
        var block_it = self.block_to_index.valueIterator();
        while (block_it.next()) |entry| {
            entry[1].deinit(self.ctx.allocator);
        }
        self.block_to_index.deinit(self.ctx.allocator);
        defer self.* = undefined;
        return self.sma;
    }

    /// Dehydrate the given term tag into an SMA tag index.
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

    /// Dehydrate the given name into an SMA name index.
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

    /// Dehydrate the given blob into an SMA blob index.
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

    /// Dehydrate the given term into an SMA term index.
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

    /// Dehydrate the given non-function-body expression into an SMA expression index.
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

    /// Dehydrate the given global into an SMA global index.
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

    /// Dehydrate the given function into an SMA function index.
    pub fn dehydrateFunction(self: *Dehydrator, function: *ir.Function) error{ BadEncoding, OutOfMemory }!u32 {
        if (self.function_to_index.get(function)) |index| {
            return index;
        } else {
            const index: u32 = @intCast(self.sma.functions.items.len);
            try self.function_to_index.put(self.ctx.allocator, function, index);

            var sma_function = try function.dehydrate(self);
            // sma function doesn't allocate, no need for errdefer

            try self.sma.functions.append(self.sma.allocator, sma_function);

            const cbr = sma_function.getCbr(self.sma);
            try self.sma.cbr.put(self.sma.allocator, .{ .kind = .function, .value = index }, cbr);

            return index;
        }
    }

    /// Dehydrate the given handler set into an SMA handler set index.
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

    /// Dehydrate the given module into an SMA module index.
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

/// Intermediary structure for rehydrating SMA format into IR.
pub const Rehydrator = struct {
    /// The SMA being rehydrated.
    sma: *const Sma,
    /// The IR being constructed.
    ctx: *ir.Context,

    /// Map from SMA tag index to ir Tag.
    index_to_tag: common.UniqueReprMap(u8, ir.Term.Tag) = .empty,
    /// Map from SMA name index to interned ir Name.
    index_to_name: common.UniqueReprMap(u32, ir.Name) = .empty,
    /// Map from SMA blob index to interned ir Blob pointer.
    index_to_blob: common.UniqueReprMap(u32, *const ir.Blob) = .empty,
    /// Map from SMA term index to ir Term.
    index_to_term: common.UniqueReprMap(u32, ir.Term) = .empty,
    /// Map from module GUID to SMA module index.
    module_to_index: common.UniqueReprMap(ir.Module.GUID, u32) = .empty,
    /// Map from SMA expression index to ir Expression pointer.
    index_to_expression: common.UniqueReprMap(u32, *ir.Expression) = .empty,
    /// Map from SMA handler set index to ir HandlerSet pointer.
    index_to_handler_set: common.UniqueReprMap(u32, *ir.HandlerSet) = .empty,
    /// Map from SMA global index to ir Global pointer.
    index_to_global: common.UniqueReprMap(u32, *ir.Global) = .empty,
    /// Map from SMA function index to ir Function pointer.
    index_to_function: common.UniqueReprMap(u32, *ir.Function) = .empty,

    /// Create a new Rehydrator for the given context and SMA.
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

    /// Deinitialize this rehydrator, freeing all temporary resources.
    /// * Does not free the SMA or IR context.
    pub fn deinit(self: *Rehydrator) void {
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

    /// Rehydrate the given SMA tag index into an ir Term.Tag.
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

    /// Rehydrate the given SMA name index into an interned ir Name.
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

    /// Rehydrate the given optional SMA name index into an interned ir Name, if it is not the sentinel.
    pub fn tryRehydrateName(self: *Rehydrator, index: u32) error{ BadEncoding, OutOfMemory }!?ir.Name {
        if (index == Sma.sentinel_index) {
            return null;
        } else {
            return try self.rehydrateName(index);
        }
    }

    /// Rehydrate the given SMA blob index into an interned ir Blob pointer.
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

    /// Rehydrate the given SMA term index into an ir Term.
    /// * This may recursively rehydrate other items as needed.
    /// * The resulting term may be interned, if it was marked shared in the SMA.
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

    /// Rehydrate the given SMA expression index into an ir Expression pointer.
    /// * This may recursively rehydrate other items as needed.
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

    /// Try to rehydrate a given optional SMA expression index into an ir Expression pointer, returning null if the index is the sentinel.
    pub fn tryRehydrateExpression(self: *Rehydrator, index: u32) error{ BadEncoding, OutOfMemory }!?*ir.Expression {
        if (index == Sma.sentinel_index) {
            return null;
        } else {
            return try self.rehydrateExpression(index);
        }
    }

    /// Attempt to rehydrate a term, returning null if the index is the sentinel.
    pub fn tryRehydrateTerm(self: *Rehydrator, index: u32) error{ BadEncoding, OutOfMemory }!?ir.Term {
        if (index == Sma.sentinel_index) {
            return null;
        } else {
            return try self.rehydrateTerm(index);
        }
    }

    /// Rehydrate the given SMA global index into an ir Global pointer.
    /// * This may recursively rehydrate other items as needed.
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

    /// Rehydrate the given SMA function index into an ir Function pointer.
    /// * This may recursively rehydrate other items as needed.
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
                function.module.function_pool.destroy(function) catch |err| {
                    log.err("Failed to destroy function on rehydrate error: {s}", .{@errorName(err)});
                };
            }

            try self.index_to_function.put(self.ctx.allocator, index, function);

            return function;
        }
    }
};

/// In-memory representation of an SMA module definition.
pub const Module = struct {
    /// The globally unique identifier for this module.
    guid: ir.Module.GUID,
    /// The interned name index for this module.
    name: u32,
    /// Whether or not the module is a primary module in its context.
    /// I.E. whether its exports are fully serialized, or if they are included for dependency resolution only.
    is_primary: bool,
    /// The exports defined by this module.
    exports: common.ArrayList(Sma.Export) = .empty,

    /// Deinitialize this SMA module, freeing its resources.
    pub fn deinit(self: *Sma.Module, allocator: std.mem.Allocator) void {
        self.exports.deinit(allocator);
    }

    /// Deserialize an SMA module from the given reader.
    pub fn deserialize(reader: *std.io.Reader, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Module {
        const guid_u128 = try reader.takeInt(u128, .little);
        const guid: ir.Module.GUID = @enumFromInt(guid_u128);

        const name = try reader.takeInt(u32, .little);
        const is_primary = try reader.takeInt(u8, .little) != 0;

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
            .is_primary = is_primary,
            .exports = exports,
        };
    }

    /// Serialize this SMA module to the given writer.
    pub fn serialize(self: *Sma.Module, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u128, @intFromEnum(self.guid), .little);

        try writer.writeInt(u32, self.name, .little);
        try writer.writeInt(u8, @intFromBool(self.is_primary), .little);

        try writer.writeInt(u32, @intCast(self.exports.items.len), .little);
        for (self.exports.items) |*ex| try ex.serialize(writer);
    }

    /// Compute the canonical binary representation (CBR) hash for this SMA module.
    pub fn getCbr(self: *const Sma.Module, sma: *Sma) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("[Module]");

        hasher.update("guid:");
        hasher.update(@intFromEnum(self.guid));

        // module names do not factor into cbr

        hasher.update("exports:");
        for (self.exports.items, 0..) |*ex, i| {
            hasher.update("export.index:");
            hasher.update(i);

            hasher.update("export.value:");
            hasher.update(ex.getCbr(sma));
        }

        return hasher.final();
    }
};

/// In-memory representation of an SMA module export.
pub const Export = struct {
    /// The interned name index for this export.
    name: u32,
    /// The operand value exported.
    /// * Note: Not all operand kinds are valid here.
    value: Operand,

    /// Deserialize an SMA export from the given reader.
    pub fn deserialize(reader: *std.io.Reader) error{ EndOfStream, ReadFailed }!Sma.Export {
        const name = try reader.takeInt(u32, .little);
        const value = try Operand.deserialize(reader);
        return Sma.Export{
            .name = name,
            .value = value,
        };
    }

    /// Serialize this SMA export to the given writer.
    pub fn serialize(self: *Sma.Export, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u32, self.name, .little);
        try self.value.serialize(writer);
    }

    /// Sort an array of SMA exports by name.
    pub fn sort(buf: []Sma.Export) void {
        std.mem.sort(Sma.Export, buf, {}, struct {
            pub fn sma_export_sorter(_: void, a: Sma.Export, b: Sma.Export) bool {
                return a.name < b.name;
            }
        }.sma_export_sorter);
    }

    /// Compute the canonical binary representation (CBR) hash for this SMA export.
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

/// In-memory representation of an SMA global variable.
pub const Global = struct {
    /// The GUID of the module that defines this global.
    module: ir.Module.GUID,
    /// The interned name index for this global.
    name: u32,
    /// The type term index for this global.
    type: u32,
    /// The initializer term index for this global.
    initializer: u32,

    /// Deserialize an SMA global variable from the given reader.
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

    /// Serialize this SMA global variable to the given writer.
    pub fn serialize(self: *Sma.Global, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u128, @intFromEnum(self.module), .little);
        try writer.writeInt(u32, self.name, .little);
        try writer.writeInt(u32, self.type, .little);
        try writer.writeInt(u32, self.initializer, .little);
    }

    /// Compute the canonical binary representation (CBR) hash for this SMA global variable.
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

/// In-memory representation of an SMA effect handler set.
pub const HandlerSet = struct {
    /// The GUID of the module that defines this handler set.
    module: ir.Module.GUID,
    /// The handler type term index for this handler set.
    handler_type: u32,
    /// The result type term index for this handler set.
    result_type: u32,
    /// The cancellation point term index for this handler set.
    cancellation_point: u32,
    /// The list of function indices for the effect handlers in this handler set.
    handlers: common.ArrayList(u32) = .empty,

    /// Deinitialize this SMA handler set, freeing its resources.
    pub fn deinit(self: *Sma.HandlerSet, allocator: std.mem.Allocator) void {
        self.handlers.deinit(allocator);
    }

    /// Deserialize an SMA handler set from the given reader.
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

    /// Serialize this SMA handler set to the given writer.
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

    /// Compute the canonical binary representation (CBR) hash for this SMA handler set.
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

/// In-memory representation of an SMA function definition.
pub const Function = struct {
    /// The GUID of the module that defines this function.
    module: ir.Module.GUID,
    /// The interned name index for this function.
    name: u32,
    /// The kind of this function.
    kind: ir.Function.Kind,
    /// The type of this function.
    type: u32,
    /// The body expression for this function.
    body: u32,

    /// Deserialize an SMA function from the given reader.
    pub fn deserialize(reader: *std.io.Reader) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Function {
        const module_u128 = try reader.takeInt(u128, .little);
        const module_guid: ir.Module.GUID = @enumFromInt(module_u128);
        const name = try reader.takeInt(u32, .little);
        const kind_u8 = try reader.takeInt(u8, .little);
        const kind: ir.Function.Kind = @enumFromInt(kind_u8);
        const type_id = try reader.takeInt(u32, .little);
        const body = try reader.takeInt(u32, .little);

        return Sma.Function{
            .module = module_guid,
            .name = name,
            .kind = kind,
            .type = type_id,
            .body = body,
        };
    }

    /// Serialize this SMA function to the given writer.
    pub fn serialize(self: *Sma.Function, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u128, @intFromEnum(self.module), .little);
        try writer.writeInt(u32, self.name, .little);
        try writer.writeInt(u8, @intFromEnum(self.kind), .little);
        try writer.writeInt(u32, self.type, .little);
        try writer.writeInt(u32, self.body, .little);
    }

    /// Compute the canonical binary representation (CBR) hash for this SMA function.
    pub fn getCbr(self: *const Sma.Function, sma: *Sma) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("[Function]");

        hasher.update("name:"); // TODO: not sure if abi names should factor into cbr
        hasher.update(sma.cbr.get(.{ .kind = .name, .value = self.name }).?);

        hasher.update("kind:");
        hasher.update(self.kind);

        hasher.update("type:");
        hasher.update(sma.cbr.get(.{ .kind = .term, .value = self.type }).?);

        if (sma.cbr.get(.{ .kind = .expression, .value = self.body })) |body_cbr| {
            hasher.update("body:");
            hasher.update(body_cbr);
        } else {
            hasher.update("declaration");
        }

        return hasher.final();
    }
};

/// In-memory representation of an SMA expression.
pub const Expression = struct {
    /// The GUID of the module that defines this expression.
    module: ir.Module.GUID,
    /// The type term index for this expression.
    type: u32,
    /// The list of handler set indices for this expression.
    handler_sets: common.ArrayList(u32) = .empty,
    /// The list of blocks for this expression.
    blocks: common.ArrayList(Sma.Block) = .empty,
    /// The list of instructions for this expression.
    instructions: common.ArrayList(Sma.Instruction) = .empty,

    /// Deinitialize this SMA expression, freeing its resources.
    pub fn deinit(self: *Sma.Expression, allocator: std.mem.Allocator) void {
        self.handler_sets.deinit(allocator);
        self.blocks.deinit(allocator);
        for (self.instructions.items) |*inst| inst.deinit(allocator);
        self.instructions.deinit(allocator);
    }

    /// Deserialize an SMA expression from the given reader.
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

    /// Serialize this SMA expression to the given writer.
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

    /// Compute the canonical binary representation (CBR) hash for this SMA expression.
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

/// In-memory representation of an SMA basic block.
pub const Block = struct {
    /// The interned name index for this block.
    name: u32,
    /// The start index of this block.
    start: u32,
    /// The instruction count of this block.
    count: u32,

    /// Deserialize an SMA block from the given reader.
    pub fn deserialize(reader: *std.io.Reader) error{ EndOfStream, ReadFailed, OutOfMemory }!Sma.Block {
        return Sma.Block{
            .name = try reader.takeInt(u32, .little),
            .start = try reader.takeInt(u32, .little),
            .count = try reader.takeInt(u32, .little),
        };
    }

    /// Serialize this SMA block to the given writer.
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

/// In-memory representation of an SMA term.
pub const Term = struct {
    /// The tag of this term.
    tag: u8,
    /// The list of operands for this term.
    operands: common.ArrayList(Sma.Operand) = .empty,

    /// Deinitialize this SMA term, freeing its resources.
    pub fn deinit(self: *Sma.Term, allocator: std.mem.Allocator) void {
        self.operands.deinit(allocator);
    }

    /// Get the operand at the given index.
    pub fn getOperand(self: *const Sma.Term, index: usize) error{BadEncoding}!Sma.Operand {
        return if (index >= self.operands.items.len) self.operands.items[index] else error.BadEncoding;
    }

    /// Get the operand of the given kind at the given index.
    pub fn getOperandOf(self: *const Sma.Term, kind: Sma.Operand.Kind, index: usize) error{BadEncoding}!u32 {
        const op = try self.getOperand(index);
        if (op.kind != kind) {
            return error.BadEncoding;
        }
        return op.value;
    }

    /// Deserialize an SMA term from the given reader.
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

    /// Serialize this SMA term to the given writer.
    pub fn serialize(self: *Sma.Term, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u8, self.tag, .little);
        try writer.writeInt(u32, @intCast(self.operands.items.len), .little);
        for (self.operands.items) |*op| try op.serialize(writer);
    }

    /// Compute the canonical binary representation (CBR) hash for this SMA term.
    pub fn getCbr(self: *const Sma.Term, sma: *Sma) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("[Term]");

        hasher.update("tag:");
        hasher.update(self.tag);

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

/// In-memory representation of an SMA instruction.
pub const Instruction = struct {
    /// The command byte of this instruction.
    command: u8,
    /// The type term index for this instruction.
    type: u32,
    /// The name index for this instruction.
    name: u32,
    /// The list of operands for this instruction.
    operands: common.ArrayList(Sma.Operand) = .empty,

    /// Deinitialize this SMA instruction, freeing its resources.
    pub fn deinit(self: *Sma.Instruction, allocator: std.mem.Allocator) void {
        self.operands.deinit(allocator);
    }

    /// Deserialize an SMA instruction from the given reader.
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

    /// Serialize this SMA instruction to the given writer.
    pub fn serialize(self: *Sma.Instruction, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u8, self.command, .little);
        try writer.writeInt(u32, self.type, .little);
        try writer.writeInt(u32, self.name, .little);
        try writer.writeInt(u32, @intCast(self.operands.items.len), .little);
        for (self.operands.items) |*op| try op.serialize(writer);
    }

    /// Compute the canonical binary representation (CBR) hash for this SMA instruction.
    pub fn getCbr(self: *const Sma.Instruction, sma: *Sma) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("[Instruction]");

        hasher.update("command:");
        hasher.update(self.command);

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

/// In-memory representation of an SMA operand.
pub const Operand = packed struct(u64) { // Must be packed for UniqueReprMap
    /// The kind of value this operand contains.
    kind: Kind,
    /// The value associated with this operand.
    value: u32,
    /// Unused padding bits.
    _unused: u24 = 0,

    /// The kinds of operands supported in SMA.
    pub const Kind = enum(u8) { module, name, expression, term, uint, blob, global, handler_set, function, block, variable };

    /// Deserialize an SMA operand from the given reader.
    pub fn deserialize(reader: *std.io.Reader) error{ EndOfStream, ReadFailed }!Sma.Operand {
        const kind = try reader.takeInt(u8, .little);
        const value = try reader.takeInt(u32, .little);
        return Sma.Operand{
            .kind = @enumFromInt(kind),
            .value = value,
        };
    }

    /// Serialize this SMA operand to the given writer.
    pub fn serialize(self: *Sma.Operand, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.writeInt(u8, @intFromEnum(self.kind), .little);
        try writer.writeInt(u32, self.value, .little);
    }

    /// Compute the canonical binary representation (CBR) hash for this SMA operand.
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

/// Create a new SMA instance using the given allocator.
pub fn init(allocator: std.mem.Allocator) !*Sma {
    const self = try allocator.create(Sma);
    self.* = Sma{
        .allocator = allocator,
        .arena = .init(allocator),
    };
    return self;
}

/// Destroy the given SMA instance, freeing its resources.
pub fn deinit(const_ptr: *const Sma) void {
    const self = @constCast(const_ptr);
    self.arena.deinit();

    self.tags.deinit(self.allocator);
    self.names.deinit(self.allocator);
    self.shared.deinit(self.allocator);
    self.globals.deinit(self.allocator);
    self.functions.deinit(self.allocator);
    self.cbr.deinit(self.allocator);

    for (self.blobs.items) |blob| blob.deinit(self.allocator);
    self.blobs.deinit(self.allocator);

    for (self.terms.items) |*term| term.deinit(self.allocator);
    self.terms.deinit(self.allocator);

    for (self.modules.items) |*module| module.deinit(self.allocator);
    self.modules.deinit(self.allocator);

    for (self.expressions.items) |*expression| expression.deinit(self.allocator);
    self.expressions.deinit(self.allocator);

    self.allocator.destroy(self);
}

/// Deserialize an SMA instance from the given reader.
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
        const function = try Sma.Function.deserialize(reader);
        try sma.functions.append(allocator, function);
    }

    return sma;
}

/// Serialize this SMA instance to the given writer.
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
