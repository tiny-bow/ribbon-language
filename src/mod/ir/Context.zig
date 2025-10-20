//! The main graph context of the ir.
const Context = @This();

const std = @import("std");
const log = std.log.scoped(.ir_context);

const common = @import("common");
const core = @import("core");
const analysis = @import("analysis");

const ir = @import("../ir.zig");

test {
    // std.debug.print("semantic analysis for ir Context\n", .{});
    std.testing.refAllDecls(@This());
}

/// Uniquely identifies a child context in an ir.
pub const Id = common.Id.of(Context, 16);

/// The context id. This is used to generate unique ids for nodes without knowing about sibling contexts.
id: Id = .fromInt(0),
/// State that varies between root/child contexts.
inner: union(enum) {
    /// This is a root context.
    root: ir.Root,
    /// This is a child context.
    child: struct {
        /// The root context this child belongs to.
        root: *Context,
    },
} = .{ .root = .{} },
/// general purpose allocator for the context, used for collections and the following arena.
gpa: std.mem.Allocator,
/// arena allocator for the context, used for data nodes.
arena: std.heap.ArenaAllocator,
/// contains all graph nodes in this context.
nodes: common.UniqueReprMap(ir.Ref, ir.Node) = .empty,
/// The def->use edges of nodes.
users: common.UniqueReprMap(ir.Ref, ir.UseDefSet) = .empty,
/// Maps specific refs to user defined data, used for miscellaneous operations like layout computation, display, etc.
userdata: common.UniqueReprMap(ir.Ref, *ir.UserData) = .empty,
/// Maps builtin structures to their definition references.
builtin: common.UniqueReprMap(ir.Builtin, ir.Ref) = .empty,
/// The set of all global symbols defined in this context. See `bindGlobal`.
global_symbols: common.StringMap(ir.Ref) = .empty,
/// Reverse mapping from a public node's Ref to its export name.
/// Only populated for nodes bound via `bindGlobal`.
exported_nodes: common.UniqueReprMap(ir.Ref, []const u8) = .empty,
/// Maps constant value nodes to references.
interner: common.HashMap(ir.Node, ir.Ref, ir.NodeHasher) = .empty,
/// Flags whether a node is interned or not.
interned_refs: ir.RefSet = .empty,
/// Flags whether a node is immutable or not.
immutable_refs: ir.RefSet = .empty,
/// Flags whether a node is builtin or not.
builtin_refs: ir.RefSet = .empty,
/// Used to generate context-unique ids for nodes.
fresh_node: ir.NodeId = .fromInt(1),
/// Api wrapper for IR builder functions.
builder: ir.Builder = .{},

/// Create a root context with the given allocator.
pub fn init(gpa: std.mem.Allocator) !*Context {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const self = try arena.allocator().create(Context);

    self.* = Context{
        .gpa = gpa,
        .arena = arena,
    };

    try self.nodes.ensureTotalCapacity(self.gpa, 16384);

    return self;
}

/// Clear the context, retaining the graph memory for reuse.
pub fn clear(self: *Context) void {
    if (self.asRoot()) |root| root.mutex.lock();
    defer if (self.asRoot()) |root| root.mutex.unlock();

    self.fresh_node = .fromInt(1);

    var node_it = self.nodes.valueIterator();
    while (node_it.next()) |node| node.deinit(self.gpa);

    var userdata_it = self.userdata.valueIterator();
    while (userdata_it.next()) |ptr2ptr| ptr2ptr.*.deinit();

    var users_it = self.users.valueIterator();
    while (users_it.next()) |set| set.deinit(self.gpa);

    self.nodes.clearRetainingCapacity();
    self.users.clearRetainingCapacity();
    self.global_symbols.clearRetainingCapacity();
    self.exported_nodes.clearRetainingCapacity();
    self.interner.clearRetainingCapacity();
    self.interned_refs.clearRetainingCapacity();
    self.immutable_refs.clearRetainingCapacity();
    self.builtin_refs.clearRetainingCapacity();
    self.userdata.clearRetainingCapacity();
    self.builtin.clearRetainingCapacity();

    _ = self.arena.reset(.retain_capacity);

    if (self.asRoot()) |root| root._clear();
}

pub fn destroy(self: *Context) void {
    var node_it = self.nodes.valueIterator();
    while (node_it.next()) |node| node.deinit(self.gpa);

    var userdata_it = self.userdata.valueIterator();
    while (userdata_it.next()) |ptr2ptr| ptr2ptr.*.deinit();

    var users_it = self.users.valueIterator();
    while (users_it.next()) |set| set.deinit(self.gpa);

    self.nodes.deinit(self.gpa);
    self.users.deinit(self.gpa);
    self.global_symbols.deinit(self.gpa);
    self.exported_nodes.deinit(self.gpa);
    self.interner.deinit(self.gpa);
    self.interned_refs.deinit(self.gpa);
    self.immutable_refs.deinit(self.gpa);
    self.builtin_refs.deinit(self.gpa);
    self.userdata.deinit(self.gpa);
    self.builtin.deinit(self.gpa);

    self.arena.deinit(); // this also frees self
}

/// Deinitialize the context, freeing all memory it owns.
pub fn deinit(self: *Context) void {
    const root = self.getRoot();

    root.mutex.lock();

    if (self.isRoot()) {
        root._deinit();
    } else {
        defer root.mutex.unlock();

        root.destroyContext(self.id);
    }
}

/// Generate a unique id.
pub fn genId(self: *Context) ir.Id {
    return ir.Id{ .context = self.id, .node = self.fresh_node.next() };
}

/// Determine if this context is a root context.
pub fn isRoot(self: *Context) bool {
    return self.inner == .root;
}

/// Get the Root if this context is a root context.
pub fn asRoot(self: *Context) ?*ir.Root {
    return switch (self.inner) {
        .root => &self.inner.root,
        .child => null,
    };
}

/// Get the root state of this context.
pub fn getRoot(self: *Context) *ir.Root {
    return switch (self.inner) {
        .root => &self.inner.root,
        .child => &self.inner.child.root.inner.root,
    };
}

/// Get the root context of this context.
pub fn getRootContext(self: *Context) *Context {
    return switch (self.inner) {
        .root => self,
        .child => self.inner.child.root,
    };
}

/// Get the ref associated with a builtin identity.
pub fn getBuiltin(self: *Context, builtin: ir.Builtin) !ir.Ref {
    const gop = try self.builtin.getOrPut(self.gpa, builtin);

    if (!gop.found_existing) {
        const initializer = ir.getBuiltinInitializer(builtin);

        const ref = try initializer(self);

        gop.value_ptr.* = ref;

        try self.builtin_refs.put(self.gpa, ref, {});
    }

    return gop.value_ptr.*;
}

/// Get the userdata for a specific reference.
pub fn getLocalUserData(self: *Context, ref: ir.Ref) !*ir.UserData {
    const gop = try self.userdata.getOrPut(self.gpa, ref);

    if (!gop.found_existing) {
        const addr = try self.arena.allocator().create(ir.UserData);
        addr.* = .{ .context = self };
        gop.value_ptr.* = addr;
    }

    return gop.value_ptr.*;
}

/// Get the userdata for a specific reference.
pub fn getUserData(self: *Context, ref: ir.Ref) !*ir.UserData {
    if (ref.id.context == self.id) {
        return self.getLocalUserData(ref);
    } else {
        const root = self.getRoot();

        root.mutex.lock();
        defer root.mutex.unlock();

        if (root.getContext(ref.id.context)) |ctx| {
            return ctx.getLocalUserData(ref);
        } else {
            return root.getRootContext().getLocalUserData(ref);
        }
    }
}

/// Delete a userdata for a specific reference.
pub fn delLocalUserData(self: *Context, ref: ir.Ref) void {
    const userdata = self.userdata.get(ref) orelse {
        log.debug("Tried to delete non-existing local userdata: {f}", .{ref});
        return;
    };

    userdata.deinit();

    _ = self.userdata.remove(ref);
}

/// Delete a userdata for a specific reference.
pub fn delUserData(self: *Context, ref: ir.Ref) void {
    if (ref.id.context == self.id) {
        self.delLocalUserData(ref);
    } else {
        const root = self.getRoot();

        root.mutex.lock();
        defer root.mutex.unlock();

        if (root.getContext(ref.id.context)) |ctx| {
            return ctx.delLocalUserData(ref);
        } else {
            return root.getRootContext().delLocalUserData(ref);
        }
    }
}

/// Adds a use->def back-link.
pub fn _link(self: *Context, user_ref: ir.Ref, operand_index: u64, used_ref: ir.Ref) !void {
    if (used_ref == ir.Ref.nil) return;
    std.debug.assert(user_ref.node_kind.getTag() == .structure or user_ref.node_kind.getTag() == .collection);

    const users = try self._getNodeUsersMut(used_ref);

    try users.put(self.gpa, ir.Use{ .ref = user_ref, .index = operand_index }, {});
}

/// Removes a use->def back-link.
pub fn _unlink(self: *Context, user_ref: ir.Ref, operand_index: u64, used_ref: ir.Ref) void {
    if (used_ref == ir.Ref.nil) return;
    std.debug.assert(user_ref.node_kind.getTag() == .structure or user_ref.node_kind.getTag() == .collection);

    // failure here is allocation failure, but that can only happen if the node doesn't exist anyway
    const users = self._getNodeUsersMut(used_ref) catch return;

    _ = users.remove(ir.Use{ .ref = user_ref, .index = operand_index });

    const user_node = self._getNodeMut(user_ref) orelse return;

    user_node.content.ref_list.items[operand_index] = ir.Ref.nil;
}

/// Get a field of a structure data node bound by this reference.
pub fn getField(self: *Context, ref: ir.Ref, comptime field: common.EnumLiteral) !?ir.Ref {
    if (ref.node_kind.getTag() != .structure) {
        return error.InvalidNodeKind;
    }

    const field_name = comptime @tagName(field);

    const local_data = self.getNodeData(ref) orelse return error.InvalidReference;

    const structure_kind: ir.StructureKind = @enumFromInt(@intFromEnum(ref.node_kind.getDiscriminator()));

    if (structure_kind == .nil) return error.InvalidGraphState;

    outer: inline for (comptime std.meta.fieldNames(ir.StructureKind)[1..]) |kind_name| {
        const kind = comptime @field(ir.StructureKind, kind_name);

        if (kind == structure_kind) {
            const struct_info = comptime @field(ir.structures, kind_name);
            const struct_fields = comptime std.meta.fieldNames(@TypeOf(struct_info));

            const field_index = comptime for (struct_fields, 0..) |name, i| {
                if (std.mem.eql(u8, name, field_name)) break i;
            } else continue :outer;

            return local_data.ref_list.items[field_index];
        }
    }

    return null;
}

/// Get an element of a collection data node bound by index.
pub fn getElement(self: *Context, ref: ir.Ref, index: u64) !?ir.Ref {
    if (ref.node_kind.getTag() != .collection) {
        return error.InvalidNodeKind;
    }

    const local_data = self.getNodeData(ref) orelse return error.InvalidReference;

    if (index < local_data.ref_list.items.len) {
        return local_data.ref_list.items[index];
    } else {
        return null;
    }
}

/// Set an operand of a structure or collection data node bound by index.
pub fn setOperand(self: *Context, ref: ir.Ref, index: u64, value: ir.Ref) !void {
    std.debug.assert(ref.node_kind.getTag() == .collection or ref.node_kind.getTag() == .structure);

    const local_data = self._getNodeDataMut(ref) orelse return error.InvalidReference;

    if (index < local_data.ref_list.items.len) {
        const slot = &local_data.ref_list.items[index];

        if (slot.* == value) return;

        self._unlink(ref, index, slot.*);
        try self._link(ref, index, value);

        slot.* = value;
    } else if (index == local_data.ref_list.items.len) {
        const slot = try local_data.ref_list.addOne(self.gpa);

        try self._link(ref, index, value);

        slot.* = value;
    } else {
        return error.InvalidGraphState;
    }
}

/// Set a field of a structure data node bound by this reference.
/// * Runtime type checking is not performed.
/// * If the field does not exist, this is an error.
pub fn setField(self: *Context, ref: ir.Ref, comptime field: common.EnumLiteral, value: ir.Ref) !void {
    if (ref.node_kind.getTag() != .structure) {
        return error.InvalidNodeKind;
    }

    const field_name = comptime @tagName(field);

    const structure_kind: ir.StructureKind = @enumFromInt(@intFromEnum(ref.node_kind.getDiscriminator()));

    if (structure_kind == .nil) return error.InvalidGraphState;

    outer: inline for (comptime std.meta.fieldNames(ir.StructureKind)[1..]) |kind_name| {
        const kind = comptime @field(ir.StructureKind, kind_name);

        if (kind == structure_kind) {
            const struct_info = comptime @field(ir.structures, kind_name);
            const struct_fields = comptime std.meta.fieldNames(@TypeOf(struct_info));

            const index = comptime for (struct_fields, 0..) |name, i| {
                if (std.mem.eql(u8, name, field_name)) break i;
            } else continue :outer;

            return self.setOperand(ref, index, value);
        }
    }

    return error.InvalidGraphState;
}

/// Set an element of a collection data node bound by index.
/// * Runtime type checking is not performed.
/// * If the index is out of bounds, it must be equal to the length of the collection,
///   in which case the element is appended to the collection.
/// * If the index is greater than the length of the collection, this is an error.
pub fn setElement(self: *Context, ref: ir.Ref, index: u64, value: ir.Ref) !void {
    if (ref.node_kind.getTag() != .collection) {
        return error.InvalidNodeKind;
    }

    try self.setOperand(ref, index, value);
}

/// Get a ref list from a structure or list node bound by this reference.
pub fn getChildren(self: *Context, ref: ir.Ref) ![]const ir.Ref {
    if (ref.node_kind.getTag() != .structure and ref.node_kind.getTag() != .collection) {
        return error.InvalidNodeKind;
    }

    const local_data = self.getNodeData(ref) orelse return error.InvalidReference;

    return local_data.ref_list.items;
}

/// Determine if a node is interned, given its reference.
pub fn isLocalBuiltinNode(self: *const Context, ref: ir.Ref) bool {
    return self.builtin_refs.contains(ref);
}

/// Determine if a node is interned, given its reference.
pub fn isLocalInternedNode(self: *const Context, ref: ir.Ref) bool {
    return self.interned_refs.contains(ref);
}

/// Determine if a node is immutable, given its reference.
pub fn isLocalImmutableNode(self: *const Context, ref: ir.Ref) bool {
    return self.immutable_refs.contains(ref);
}

/// Determine if a node is interned, given its reference.
pub fn isBuiltinNode(self: *Context, ref: ir.Ref) bool {
    if (ref.id.context == self.id) {
        return self.isLocalBuiltinNode(ref);
    } else {
        const root = self.getRoot();

        root.mutex.lock();
        defer root.mutex.unlock();

        if (root.getContext(ref.id.context)) |ctx| {
            return ctx.isLocalBuiltinNode(ref);
        } else {
            return root.getRootContext().isLocalBuiltinNode(ref);
        }
    }
}

/// Determine if a node is interned, given its reference.
pub fn isInternedNode(self: *Context, ref: ir.Ref) bool {
    if (ref.id.context == self.id) {
        return self.isLocalInternedNode(ref);
    } else {
        const root = self.getRoot();

        root.mutex.lock();
        defer root.mutex.unlock();

        if (root.getContext(ref.id.context)) |ctx| {
            return ctx.isLocalInternedNode(ref);
        } else {
            return root.getRootContext().isLocalInternedNode(ref);
        }
    }
}

/// Determine if a node is immutable, given its reference.
pub fn isImmutableNode(self: *Context, ref: ir.Ref) bool {
    if (ref.id.context == self.id) {
        return self.isLocalImmutableNode(ref);
    } else {
        const root = self.getRoot();

        root.mutex.lock();
        defer root.mutex.unlock();

        if (root.getContext(ref.id.context)) |ctx| {
            return ctx.isLocalImmutableNode(ref);
        } else {
            return root.getRootContext().isLocalImmutableNode(ref);
        }
    }
}

/// Compute the layout of a type node by reference.
pub fn computeLayout(self: *Context, ref: ir.Ref) !struct { u64, core.Alignment } {
    if (ref.node_kind.getTag() != .structure or ref.node_kind.getDiscriminator() != .type) {
        return error.InvalidNodeKind;
    }

    const ref_constructor = try self.getField(ref, .constructor) orelse return error.InvalidGraphState;
    const ref_input_types = try self.getField(ref, .input_types) orelse return error.InvalidGraphState;

    const input_types = try self.getChildren(ref_input_types);

    const userdata = try self.getUserData(ref_input_types);

    if (userdata.computeLayout) |computeLayoutFn| {
        return computeLayoutFn(ref_constructor, input_types);
    } else {
        return error.InvalidGraphState;
    }
}

pub fn _internNode(self: *Context, node: ir.Node) !ir.Ref {
    try self._ensureConstantRefs(node);

    return self._internNodeUnchecked(node);
}

pub fn _addNode(self: *Context, mutability: core.Mutability, node: ir.Node) !ir.Ref {
    if (mutability == .constant) try self._ensureConstantRefs(node);

    return self._addNodeUnchecked(mutability, node);
}

pub fn _ensureConstantRefs(self: *Context, node: ir.Node) !void {
    const tag = node.kind.getTag();
    if (tag.containsReferences()) {
        for (node.content.ref_list.items) |content_ref| {
            if (content_ref != ir.Ref.nil and !self.isImmutableNode(content_ref)) {
                log.debug("Attempted to create an immutable node that references a mutable node {f}", .{content_ref});
                return error.ImmutableNodeReferencesMutable;
            }
        }
    }
}

pub fn _internNodeUnchecked(self: *Context, node: ir.Node) !ir.Ref {
    const gop = try self.interner.getOrPut(self.gpa, node);

    if (!gop.found_existing) {
        gop.value_ptr.* = try self._addNodeUnchecked(.constant, node);
    } else {
        var input_node = node;
        input_node.deinit(self.gpa);
    }

    try self.interned_refs.put(self.gpa, gop.value_ptr.*, {});

    return gop.value_ptr.*;
}

pub fn _addNodeUnchecked(self: *Context, mutability: core.Mutability, node: ir.Node) !ir.Ref {
    const tag = node.kind.getTag();

    const ref = ir.Ref{
        .node_kind = node.kind,
        .id = self.genId(),
    };

    try self.nodes.put(self.gpa, ref, node);

    if (tag == .structure or tag == .collection) {
        for (node.content.ref_list.items, 0..) |used_ref, i| {
            try self._link(ref, i, used_ref);
        }
    }

    if (mutability == .constant) {
        try self.immutable_refs.put(self.gpa, ref, {});
    }

    return ref;
}

/// Delete a local node from this context, given its reference.
/// * This will deinitialize the node, freeing any memory it owns.
/// * Nodes relying on this node will be invalidated.
/// * If the node does not exist, this is a no-op.
/// * If the node is interned, this is a no-op.
pub fn delLocalNode(self: *Context, ref: ir.Ref) void {
    if (self.isLocalImmutableNode(ref)) {
        log.debug("Tried to delete an immutable node: {f}", .{ref});
        return;
    }

    const node = self.nodes.getPtr(ref) orelse return;
    defer node.deinit(self.gpa);

    _ = self.nodes.remove(ref);
    _ = self.users.remove(ref);

    const users = self.getNodeUsers(ref) catch return;

    var user_it = users.keyIterator();
    while (user_it.next()) |user| {
        self._unlink(user.ref, user.index, ref);
    }
}

/// Delete a node from the context, given its reference.
/// * This will deinitialize the node, freeing any memory it owns.
/// * Nodes relying on this node will be invalidated.
/// * If the node does not exist, this is a no-op.
/// * If the node is interned, this is a no-op.
pub fn delNode(self: *Context, ref: ir.Ref) void {
    if (ref.id.context == self.id) {
        self.delLocalNode(ref);
    } else {
        const root = self.getRoot();

        root.mutex.lock();
        defer root.mutex.unlock();

        if (root.getContext(ref.id.context)) |ctx| {
            return ctx.delLocalNode(ref);
        } else {
            return root.getRootContext().delLocalNode(ref);
        }
    }
}

/// Get an immutable pointer to a raw node, given its reference.
pub fn getLocalNode(self: *Context, ref: ir.Ref) ?*const ir.Node {
    return self.nodes.getPtr(ref);
}

pub fn _getLocalNodeMut(self: *Context, ref: ir.Ref) ?*ir.Node {
    const node = self.nodes.getPtr(ref) orelse return null;

    if (self.isLocalImmutableNode(ref)) {
        log.debug("Tried to get mutable pointer to an immutable node: {f}", .{ref});
        return null;
    }

    return node;
}

/// Get an immutable pointer to a raw node, given its reference.
pub fn getNode(self: *Context, ref: ir.Ref) ?*const ir.Node {
    if (ref.id.context == self.id) {
        return self.getLocalNode(ref);
    } else {
        const root = self.getRoot();

        root.mutex.lock();
        defer root.mutex.unlock();

        if (root.getContext(ref.id.context)) |ctx| {
            return ctx.getLocalNode(ref);
        } else {
            return root.getRootContext().getLocalNode(ref);
        }
    }
}

/// Validate a node reference, ensuring it exists in the graph.
pub fn validateNode(self: *Context, ref: ir.Ref) !void {
    _ = self.getNode(ref) orelse return error.InvalidReference;
}

pub fn _getNodeMut(self: *Context, ref: ir.Ref) ?*ir.Node {
    if (ref.id.context == self.id) {
        return self._getLocalNodeMut(ref);
    } else {
        const root = self.getRoot();

        root.mutex.lock();
        defer root.mutex.unlock();

        if (root.getContext(ref.id.context)) |ctx| {
            return ctx._getLocalNodeMut(ref);
        } else {
            return root.getRootContext()._getLocalNodeMut(ref);
        }
    }
}

/// Get a list of all the users of a node, given its reference.
pub fn getLocalNodeUsers(self: *Context, ref: ir.Ref) !*const common.UniqueReprSet(ir.Use) {
    std.debug.assert(ref.id.context == self.id);

    const gop = try self.users.getOrPut(self.gpa, ref);

    if (!gop.found_existing) gop.value_ptr.* = .{};

    return gop.value_ptr;
}

/// Get a list of all the users of a node, given its reference.
pub fn getNodeUsers(self: *Context, ref: ir.Ref) !*const common.UniqueReprSet(ir.Use) {
    if (ref.id.context == self.id) {
        return self.getLocalNodeUsers(ref);
    } else {
        const root = self.getRoot();

        root.mutex.lock();
        defer root.mutex.unlock();

        if (root.getContext(ref.id.context)) |ctx| {
            return ctx.getLocalNodeUsers(ref);
        } else {
            return root.getRootContext().getLocalNodeUsers(ref);
        }
    }
}

/// Replace all uses of a node with another node.
/// * This will update all users of the old node to reference the new node instead.
/// * If the old node does not exist, this is an error.
/// * If the new node does not exist, this is an error.
/// * If a user is immutable, this is an error.
/// * If the old node is the same as the new node, this is a no-op.
/// * This does not delete the old node.
pub fn replaceAllUses(self: *Context, old_ref: ir.Ref, new_ref: ir.Ref) !void {
    if (old_ref == new_ref) return;

    var user_set = try self.getNodeUsers(old_ref);
    try self.validateNode(new_ref);

    // setOperand will invalidate the iterator, so we need to clone it first
    var temp_set = try user_set.clone(self.arena.allocator());
    errdefer temp_set.deinit(self.arena.allocator());

    var uses = temp_set.keyIterator();
    while (uses.next()) |use_ptr| {
        try self.setOperand(use_ptr.ref, use_ptr.index, new_ref);
    }
}

pub fn _getLocalNodeUsersMut(self: *Context, ref: ir.Ref) !*common.UniqueReprSet(ir.Use) {
    std.debug.assert(ref.id.context == self.id);

    const gop = try self.users.getOrPut(self.gpa, ref);

    if (!gop.found_existing) gop.value_ptr.* = .{};

    return gop.value_ptr;
}

pub fn _getNodeUsersMut(self: *Context, ref: ir.Ref) !*common.UniqueReprSet(ir.Use) {
    if (ref.id.context == self.id) {
        return self._getLocalNodeUsersMut(ref);
    } else {
        const root = self.getRoot();

        root.mutex.lock();
        defer root.mutex.unlock();

        if (root.getContext(ref.id.context)) |ctx| {
            return ctx._getLocalNodeUsersMut(ref);
        } else {
            return root.getRootContext()._getLocalNodeUsersMut(ref);
        }
    }
}

/// Get an immutable pointer to raw node data, given its reference.
pub fn getLocalNodeData(self: *Context, ref: ir.Ref) ?*const ir.Data {
    return &(self.getLocalNode(ref) orelse return null).content;
}

pub fn _getLocalNodeDataMut(self: *Context, ref: ir.Ref) ?*ir.Data {
    return &(self._getLocalNodeMut(ref) orelse return null).content;
}

/// Get an immutable pointer to raw node data, given its reference.
pub fn getNodeData(self: *Context, ref: ir.Ref) ?*const ir.Data {
    return &(self.getNode(ref) orelse return null).content;
}

pub fn _getNodeDataMut(self: *Context, ref: ir.Ref) ?*ir.Data {
    return &(self._getNodeMut(ref) orelse return null).content;
}

/// Bind a symbol to an id.
/// This exports the symbol as part of the public interface.
/// * Returns the global_symbol ref created
pub fn bindGlobal(self: *Context, name: []const u8, ref: ir.Ref) !ir.Ref {
    const gop = try self.global_symbols.getOrPut(self.gpa, name);

    if (gop.found_existing) {
        // rebind the symbol
        const existing_ref = gop.value_ptr.*;

        if (existing_ref == ref) return error.InvalidReference; // a symbol cannot refer to itself

        try self.setField(existing_ref, .node, ref);

        return existing_ref;
    }

    const name_ref, const owned_buf = try self.internNameWithBuf(name);

    const symbol = try self.addStructure(.mutable, .global_symbol, .{
        .name = name_ref,
        .node = ref,
    });

    gop.key_ptr.* = owned_buf;
    gop.value_ptr.* = symbol;

    try self.exported_nodes.put(self.gpa, ref, owned_buf);

    return symbol;
}

/// Create a new primitive node in the context, given a primitive kind and value.
/// * The value must be a primitive type, such as an integer, index, or opcode. See `ir.primitives`.
pub fn addPrimitive(self: *Context, mutability: core.Mutability, value: anytype) !ir.Ref {
    const node = try ir.Node.primitive(value);

    return self._addNode(mutability, node);
}

/// Create a new structure node in the context, given a structure kind and an initializer.
/// * The initializer must be a struct with the same fields as the structure kind. See `ir.structure`.
pub fn addStructure(self: *Context, mutability: core.Mutability, comptime kind: ir.StructureKind, value: anytype) !ir.Ref {
    var node = try ir.Node.structure(self.gpa, kind, value);
    errdefer node.deinit(self.gpa);

    return self._addNode(mutability, node);
}

/// Add a data buffer to the context.
pub fn addBuffer(self: *Context, mutability: core.Mutability, value: []const u8) !ir.Ref {
    var node = try ir.Node.buffer(self.gpa, value);
    errdefer node.deinit(self.gpa);

    return self._addNode(mutability, node);
}

/// Add a ref list to the context.
pub fn addList(self: *Context, mutability: core.Mutability, element_kind: ir.Discriminator, value: []const ir.Ref) !ir.Ref {
    var node = try ir.Node.list(self.gpa, element_kind, value);
    errdefer node.deinit(self.gpa);

    return self._addNode(mutability, node);
}

/// Intern a primitive value in the context, given a primitive kind and value.
/// * If the node already exists in this context, it will return the existing reference.
/// * Modifying nodes added this way is unsafe.
/// * The value must be a primitive type, such as an integer, index, or opcode. See `ir.primitives`.
pub fn internPrimitive(self: *Context, value: anytype) !ir.Ref {
    const node = try ir.Node.primitive(value);

    return self._internNode(node);
}

/// Intern a structure node in the context, given a structure kind and an initializer.
/// * The initializer must be a struct with the same fields as the structure kind. See `ir.structure`.
/// * If the node already exists in this context, it will return the existing reference.
/// * Modifying nodes added this way is unsafe.
pub fn internStructure(self: *Context, comptime kind: ir.StructureKind, value: anytype) !ir.Ref {
    var node = try ir.Node.structure(self.gpa, kind, value);
    errdefer node.deinit(self.gpa);

    return self._internNode(node);
}

/// Intern a name value in the context.
/// * If the node already exists in this context, it will return the existing reference.
/// * Modifying nodes added this way is unsafe.
pub fn internNameWithBuf(self: *Context, value: []const u8) !struct { ir.Ref, []const u8 } {
    const gop = try self.interner.getOrPutAdapted(self.gpa, value, ir.NameHasher);

    if (!gop.found_existing) {
        const arr = try self.arena.allocator().dupe(u8, value);

        const node = try ir.Node.data(.name, arr);

        gop.key_ptr.* = node;

        gop.value_ptr.* = try self._addNode(.constant, node);

        try self.interned_refs.put(self.gpa, gop.value_ptr.*, {});

        return .{ gop.value_ptr.*, arr };
    } else {
        return .{ gop.value_ptr.*, (self.getNodeData(gop.value_ptr.*) orelse return error.InvalidReference).name };
    }
}

/// Intern a name value in the context.
/// * If the node already exists in this context, it will return the existing reference.
/// * Modifying nodes added this way is unsafe.
pub fn internName(self: *Context, value: []const u8) !ir.Ref {
    return (try self.internNameWithBuf(value))[0];
}

/// Intern a `Source` value in the context.
/// * If the node already exists in this context, it will return the existing reference.
/// * Modifying nodes added this way is unsafe.
pub fn internSource(self: *Context, value: analysis.Source) !ir.Ref {
    const gop = try self.interner.getOrPutAdapted(self.gpa, value, ir.SourceHasher);

    if (!gop.found_existing) {
        const owned_value = try value.dupe(self.arena.allocator());

        const node = try ir.Node.data(.source, owned_value);

        gop.key_ptr.* = node;

        gop.value_ptr.* = try self._addNode(.constant, node);

        try self.interned_refs.put(self.gpa, gop.value_ptr.*, {});
    }

    return gop.value_ptr.*;
}

/// Intern a data buffer in the context.
/// * If the buffer already exists in this context, it will return the existing reference.
/// * Modifying nodes added this way is unsafe.
pub fn internBuffer(self: *Context, value: []const u8) !ir.Ref {
    const gop = try self.interner.getOrPutAdapted(self.gpa, value, ir.BufferHasher);

    if (!gop.found_existing) {
        var arr = try common.ArrayList(u8).initCapacity(self.gpa, value.len);
        errdefer arr.deinit(self.gpa);

        arr.appendSliceAssumeCapacity(value);

        const node = try ir.Node.data(.buffer, arr);

        gop.key_ptr.* = node;

        gop.value_ptr.* = try self._addNode(.constant, node);

        try self.interned_refs.put(self.gpa, gop.value_ptr.*, {});
    }

    return gop.value_ptr.*;
}

/// Intern a ref list in the context.
/// * If the list already exists in this context, it will return the existing reference.
/// * Modifying nodes added this way is unsafe.
pub fn internList(self: *Context, comptime element_kind: ir.Discriminator, value: []const ir.Ref) !ir.Ref {
    const gop = try self.interner.getOrPutAdapted(self.gpa, value, ir.ListHasher(element_kind));

    if (!gop.found_existing) {
        var arr = try common.ArrayList(ir.Ref).initCapacity(self.gpa, value.len);
        errdefer arr.deinit(self.gpa);

        arr.appendSliceAssumeCapacity(value);

        const node = ir.Node{
            .kind = ir.NodeKind.collection(element_kind),
            .content = .{ .ref_list = arr },
        };

        gop.key_ptr.* = node;
        gop.value_ptr.* = try self._addNode(.constant, node);

        try self.interned_refs.put(self.gpa, gop.value_ptr.*, {});
    }

    return gop.value_ptr.*;
}

/// Performs a depth-first search from a starting node to detect cycles. I.e., if ref is reachable from itself
/// `visiting` is the set of nodes in the current recursion stack.
/// * This function assumes that the caller holds a lock on the context's root mutex
pub fn detectCycle(ctx: *Context, visiting: *ir.RefSet, ref: ir.Ref) !bool {
    if (ref == ir.Ref.nil) return false;

    if (visiting.contains(ref)) return true;

    const tag = ref.node_kind.getTag();

    if (tag != .collection or tag != .structure) {
        if (ref.id.context != ctx.id) {
            const root = ctx.getRoot();
            const other_context = if (root.getContext(ref.id.context)) |cx| cx else root.getRootContext();

            return detectCycle(other_context, visiting, ref);
        }

        if (ctx.getLocalNode(ref)) |node| {
            try visiting.put(ctx.gpa, ref, {});
            defer _ = visiting.remove(ref);

            for (node.content.ref_list.items) |child_ref| {
                if (try detectCycle(ctx, visiting, child_ref)) return true;
            }
        }
    }

    return false;
}
