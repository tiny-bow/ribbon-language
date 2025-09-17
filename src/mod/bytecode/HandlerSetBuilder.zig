//! A builder for effect handler collections.
const HandlerSetBuilder = @This();

const std = @import("std");
const log = std.log.scoped(.bytecode_handler_set_builder);

const core = @import("core");
const common = @import("common");
const binary = @import("binary");

const bytecode = @import("../bytecode.zig");
const UpvalueFixupMap = bytecode.UpvalueFixupMap;
const FunctionBuilder = bytecode.FunctionBuilder;

/// The general allocator used by this handler set for collections.
gpa: std.mem.Allocator,
/// The arena allocator used by this handler set for non-volatile data.
arena: std.mem.Allocator,
/// The function that utilizes this handler set.
function: ?core.FunctionId = null,
/// The unique identifier of the handler set.
id: core.HandlerSetId = .fromInt(0),
/// The handlers in this set, keyed by their unique identifiers.
handlers: HandlerMap = .empty,
/// The register to place the cancellation operand in if this handler set is cancelled at runtime.
register: core.Register = .r(0),
/// A map from the upvalue ids of this handler to the local variable ids they reference in its parent function.
upvalues: UpvalueMap = .empty,

/// A map from upvalue ids to local variable ids, representing the immediate lexical closure of an effect within a handler set builder entry.
pub const UpvalueMap = common.UniqueReprMap(core.UpvalueId, core.LocalId);

/// A map from handler ids to their entries in a handler set builder.
pub const HandlerMap = common.UniqueReprMap(core.HandlerId, Entry);

/// Binding for an effect handler within a handler set builder.
/// * The HandlerSetBuilder does not own the function builder
pub const Entry = struct {
    /// The id of the effect that this handler can process.
    effect: core.EffectId = .fromInt(0),
    /// The function that implements the handler.
    function: *FunctionBuilder,
};

/// Initialize a new handler set builder.
pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator) HandlerSetBuilder {
    return HandlerSetBuilder{
        .gpa = gpa,
        .arena = arena,
    };
}

/// Clear the handler set builder, retaining the current memory capacity.
pub fn clear(self: *HandlerSetBuilder) void {
    var it = self.handlers.valueIterator();
    while (it.next()) |entry| entry.deinit(self.gpa);
    self.handlers.clearRetainingCapacity();

    self.function = null;
    self.id = .fromInt(0);
    self.parent_location = .{};
    self.upvalues.clearRetainingCapacity();
    self.register = .r(0);
}

/// Deinitialize the handler set builder, freeing all memory associated with it.
pub fn deinit(self: *HandlerSetBuilder) void {
    self.handlers.deinit(self.gpa);
    self.upvalues.deinit(self.gpa);
    self.* = undefined;
}

/// Bind a function builder to a handler set entry for a given effect identity, returning its HandlerId.
/// * The handler id can be used with `getHandlerFunction` to retrieve the bound function builder address later.
/// * The handler set builder does not own the function builder, so it must be deinitialized separately.
///   Recommended usage pattern is to use `TableBuilder` to manage statics.
pub fn bindHandler(self: *HandlerSetBuilder, effect: core.EffectId, function: *FunctionBuilder) error{ BadEncoding, OutOfMemory }!core.HandlerId {
    if (function.parent) |parent| {
        log.debug("HandlerSetBuilder.bindHandlerFunction: function already bound to {f}", .{parent});
        return error.BadEncoding;
    }

    const index = self.handlers.count();

    if (index > core.HandlerId.MAX_INT) {
        log.debug("HandlerSetBuilder.createHandler: cannot create more than {d} handlers", .{core.HandlerId.MAX_INT});
        return error.OutOfMemory;
    }

    const handler_id = core.HandlerId.fromInt(index);

    const gop = try self.handlers.getOrPut(self.gpa, handler_id);

    // sanity check: handler_id should be fresh if the map has been mutated in append-only fashion
    std.debug.assert(!gop.found_existing);

    gop.value_ptr.* = Entry{
        .effect = effect,
        .function = function,
    };

    return handler_id;
}

/// Get a handler function builder by its local handler id.
pub fn getHandler(self: *const HandlerSetBuilder, id: core.HandlerId) ?*FunctionBuilder {
    const entry = self.handlers.getPtr(id) orelse return null;
    return entry.function;
}

/// Create a new upvalue within this handler, returning an id for it.
pub fn createUpvalue(self: *HandlerSetBuilder, local_id: core.LocalId) error{OutOfMemory}!core.UpvalueId {
    const index = self.upvalues.count();

    if (index > core.UpvalueId.MAX_INT) {
        log.debug("HandlerSetBuilder.createUpvalue: Cannot create more than {d} upvalues", .{core.UpvalueId.MAX_INT});
        return error.OutOfMemory;
    }

    const upvalue_id = core.UpvalueId.fromInt(index);

    const gop = try self.upvalues.getOrPut(self.gpa, upvalue_id);

    // sanity check: upvalue_id should be fresh if the map has been mutated in append-only fashion
    std.debug.assert(!gop.found_existing);

    gop.value_ptr.* = local_id;

    return upvalue_id;
}

/// Get the local variable id of an upvalue by its id.
/// * Returns the core.LocalId of the upvalue, inside the parent function; or null if the upvalue does not exist.
pub fn getUpvalue(self: *const HandlerSetBuilder, id: core.UpvalueId) ?core.LocalId {
    return self.upvalues.get(id);
}

/// Get the location to bind for this handler set's cancellation address.
pub fn cancellationLocation(self: *const HandlerSetBuilder) error{BadEncoding}!binary.Location {
    return .from(self.function orelse {
        log.debug("HandlerSetBuilder.cancellationLocation: parent function not set", .{});
        return error.BadEncoding;
    }, self.id);
}

/// Encode the handler set into the provided encoder.
pub fn encode(self: *const HandlerSetBuilder, maybe_upvalue_fixups: ?*const UpvalueFixupMap, encoder: *binary.Encoder) binary.Encoder.Error!void {
    const location = encoder.localLocationId(self.id);

    const upvalue_fixups = if (maybe_upvalue_fixups) |x| x else {
        log.debug("HandlerSetBuilder.encode: No upvalue fixups provided, skipping upvalue encoding", .{});
        return encoder.skipLocation(location);
    };

    if (!try encoder.visitLocation(location)) {
        log.debug("HandlerSetBuilder.encode: {f} has already been encoded, skipping", .{self.id});
        return;
    }

    // create the core.HandlerSet and bind it to the header table
    const handler_set_rel = try encoder.createRel(core.HandlerSet);

    // bind the table entry
    try encoder.bindLocation(location, handler_set_rel);

    // create the buffer memory for the handlers
    const handlers_buf_rel = try encoder.allocRel(core.Handler, self.handlers.count());

    // write the handler set header
    const handler_set = encoder.relativeToPointer(*core.HandlerSet, handler_set_rel);
    handler_set.handlers.len = @intCast(self.handlers.count());
    handler_set.cancellation.register = self.register;

    const cancel_loc = try self.cancellationLocation();

    try encoder.bindFixup(
        .absolute,
        .{ .relative = handler_set_rel.applyOffset(@intCast(@offsetOf(core.HandlerSet, "cancellation"))).applyOffset(@intCast(@offsetOf(core.Cancellation, "address"))) },
        .{ .location = cancel_loc },
        null,
    );

    // bind the buffer to the handler set
    try encoder.bindFixup(
        .absolute,
        .{ .relative = handler_set_rel.applyOffset(@intCast(@offsetOf(core.HandlerSet, "handlers"))) },
        .{ .relative = handlers_buf_rel },
        @bitOffsetOf(core.HandlerSet.Buffer, "ptr"),
    );

    // encode each handler in the set and create a binary.Fixup for it
    var handler_it = self.handlers.valueIterator();
    var i: usize = 0;
    while (handler_it.next()) |entry| {
        const handler_rel = handlers_buf_rel.applyOffset(@intCast(i * @sizeOf(core.Handler)));
        const handler = encoder.relativeToPointer(*core.Handler, handler_rel);

        handler.effect = entry.effect;

        try encoder.bindFixup(
            .absolute,
            .{ .relative = handler_rel.applyOffset(@intCast(@offsetOf(core.Handler, "function"))) },
            .{ .location = encoder.localLocationId(entry.function.id) },
            null,
        );

        try entry.function.encode(upvalue_fixups, encoder);

        i += 1;
    }
}
