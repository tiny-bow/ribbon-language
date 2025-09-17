//! The root context state.
//! * All Root methods assume that the root mutex is already locked by the caller.
const Root = @This();

const std = @import("std");
const log = std.log.scoped(.ir_root);

const core = @import("core");
const common = @import("common");

const ir = @import("../ir.zig");

test {
    // std.debug.print("semantic analysis for ir Root\n", .{});
    std.testing.refAllDecls(@This());
}

/// Used to generate unique ids for child contexts.
fresh_ctx: ir.Context.Id = .fromInt(1),
/// All child contexts owned by this root context.
children: common.UniqueReprMap(ir.Context.Id, *ir.Context) = .empty,
/// Synchronization primitive for child contexts to use when accessing the root context.
/// * All Root methods assume that the root mutex is already locked by the caller.
mutex: std.Thread.Mutex = .{},

/// Create a new child context, returning its pointer.
/// * Caller must hold a lock on the root mutex for this call.
pub fn createContext(self: *Root) !*ir.Context {
    const root_ctx = self.getRootContext();

    var arena = std.heap.ArenaAllocator.init(root_ctx.gpa);

    const child = try arena.allocator().create(ir.Context);
    errdefer child.destroy();

    child.* = ir.Context{
        .id = self.fresh_ctx.next(),
        .inner = .{ .child = .{ .root = root_ctx } },
        .gpa = root_ctx.gpa,
        .arena = arena,
    };

    try child.nodes.ensureTotalCapacity(root_ctx.gpa, 16384);

    try self.children.put(root_ctx.gpa, child.id, child);

    return child;
}

/// Destroy a child context, freeing all of its memory.
/// * Caller must hold a lock on the root mutex for this call.
pub fn destroyContext(self: *Root, id: ir.Context.Id) void {
    const child = self.children.get(id) orelse return;
    child.destroy();

    _ = self.children.remove(id);
}

/// Get a pointer to a child context, if it exists.
/// * Caller must hold a lock on the root mutex for this call.
pub fn getContext(self: *Root, id: ir.Context.Id) ?*ir.Context {
    return self.children.get(id);
}

/// Get the context of this Root.
pub fn getRootContext(self: *Root) *ir.Context {
    const inner: *@FieldType(ir.Context, "inner") = @fieldParentPtr("root", self);
    return @fieldParentPtr("inner", inner);
}

/// Merges the nodes from a child context into this Root's context.
/// * Caller must hold a lock on the root mutex for this call.
pub fn merge(self: *Root, child_ctx: *ir.Context) !void {
    std.debug.assert(!child_ctx.isRoot() and child_ctx.getRootContext() == self.getRootContext());
    const root_ctx = self.getRootContext();

    var merged_refs: ir.RefMap = .{};
    defer merged_refs.deinit(root_ctx.gpa);

    // Iterate all nodes in the child context and copy them to the root.
    // The copyNode function is recursive and will handle dependencies, so a simple
    // iteration over all nodes ensures everything is copied.
    var it = child_ctx.nodes.iterator();
    while (it.next()) |entry| {
        // We only need to call copyNode; if it's already been copied as a
        // dependency of another node, it will return quickly from the cache.
        _ = try self._copyNode(child_ctx, &merged_refs, entry.key_ptr.*);
    }

    self.destroyContext(child_ctx.id);
}

pub fn _copyNode(
    self: *Root,
    child_ctx: *const ir.Context,
    merged_refs: *ir.RefMap,
    child_ref: ir.Ref,
) !ir.Ref {
    // Base case: If nil or already copied, return immediately.
    if (child_ref == ir.Ref.nil) return .nil;

    if (merged_refs.get(child_ref)) |cached_root_ref| {
        return cached_root_ref;
    }

    const root_ctx = self.getRootContext();
    const child_node = child_ctx.nodes.getPtr(child_ref).?;

    const was_interned = child_ctx.isLocalInternedNode(child_ref);
    const was_immutable = child_ctx.isLocalImmutableNode(child_ref);
    const old_mutability: core.Mutability = if (was_immutable) .constant else .mutable;

    // Potentially cyclic nodes (which can contain refs to other nodes) must be
    // handled with the "Create, Cache, Populate" strategy. This applies only
    // to non-interned structures and collections.
    const is_potentially_cyclic = child_node.kind.getTag() == .structure or child_node.kind.getTag() == .collection;

    if (!was_interned and is_potentially_cyclic) {
        // 1. CREATE SHELL: Create a node with an empty ref_list.
        const root_ref = try root_ctx._addNodeUnchecked(.mutable, .{
            .kind = child_node.kind,
            .content = .{ .ref_list = .{} },
        });

        // 2. CACHE IMMEDIATELY
        try merged_refs.put(root_ctx.gpa, child_ref, root_ref);

        // 3. POPULATE using low-level, non-locking operations.
        const root_node_mut = root_ctx._getNodeMut(root_ref).?;

        for (child_node.content.ref_list.items, 0..) |original_child_ref, i| {
            const new_child_ref = try self._copyNode(child_ctx, merged_refs, original_child_ref);

            // Manually append the copied child to the list.
            try root_node_mut.content.ref_list.append(root_ctx.gpa, new_child_ref);

            if (new_child_ref != ir.Ref.nil) {
                // Manually create the def->use link using the non-locking local primitive.
                const users = try root_ctx._getLocalNodeUsersMut(new_child_ref);
                try users.put(root_ctx.gpa, ir.Use{ .ref = root_ref, .index = i }, {});
            }
        }

        // 4. MERGE USERDATA
        try self._copyUserData(child_ctx, root_ctx, child_ref, root_ref);

        // 5. IMMUTABLE HANDLING we have to create the node in a mutable state to populate, now we set it to immutable if it needed.
        if (was_immutable) try root_ctx.immutable_refs.put(root_ctx.gpa, root_ref, {});

        return root_ref;
    } else {
        // --- "Build then Add" for primitives, data, and all interned nodes ---
        // These are treated as values and are assumed to be acyclic. The original
        // logic is sound for them.

        var new_root_node: ir.Node = undefined;
        var new_node_owns_memory = false;
        defer if (new_node_owns_memory) new_root_node.deinit(root_ctx.gpa);

        switch (child_node.kind.getTag()) {
            .nil, .primitive => {
                new_root_node = child_node.*;
            },
            .data => {
                new_root_node = child_node.*;
                if (child_node.kind.getDiscriminator() == .buffer) {
                    new_root_node.content.buffer = try child_node.content.buffer.clone(root_ctx.gpa);
                    new_node_owns_memory = true;
                }
            },
            // This case now only handles INTERNED structure/collection nodes.
            .structure, .collection => {
                var new_ref_list = try child_node.content.ref_list.clone(root_ctx.gpa);
                errdefer new_ref_list.deinit(root_ctx.gpa);

                // Recursively copy children. This is safe as interned nodes form a DAG.
                for (new_ref_list.items) |*ref_in_list| {
                    ref_in_list.* = try self._copyNode(child_ctx, merged_refs, ref_in_list.*);
                }

                new_root_node = .{
                    .kind = child_node.kind,
                    .content = .{ .ref_list = new_ref_list },
                };
                new_node_owns_memory = true;
            },
        }

        const root_ref = if (was_interned)
            try root_ctx._internNodeUnchecked(new_root_node)
        else
            // This path should now only be taken by primitives and data nodes.
            try root_ctx._addNodeUnchecked(old_mutability, new_root_node);

        // Disarm the defer. Ownership of memory is now with the context.
        new_node_owns_memory = false;

        // Cache the result for subsequent lookups.
        try merged_refs.put(root_ctx.gpa, child_ref, root_ref);

        // MERGE USERDATA: Copy associated UserData.
        try self._copyUserData(child_ctx, root_ctx, child_ref, root_ref);

        return root_ref;
    }
}

pub fn _copyUserData(
    self: *Root,
    child_ctx: *const ir.Context,
    root_ctx: *ir.Context,
    child_ref: ir.Ref,
    root_ref: ir.Ref,
) !void {
    _ = self; // self is unused, but keeps the function within the Root's namespace
    if (child_ctx.userdata.get(child_ref)) |child_ud_ptr| {
        const root_ud = try root_ctx.getLocalUserData(root_ref);

        // Merge vtable pointers (child takes precedence)
        if (child_ud_ptr.computeLayout) |ptr| root_ud.computeLayout = ptr;
        if (child_ud_ptr.display) |ptr| root_ud.display = ptr;

        // Merge bindings map (element-level overwrite)
        var binding_it = child_ud_ptr.bindings.iterator();
        while (binding_it.next()) |entry| {
            // The common.Any value is a simple pointer, so we just copy it.
            try root_ud.bindings.put(root_ctx.gpa, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
}

pub fn _deinit(self: *Root) void {
    const root_ctx = self.getRootContext();

    var it = self.children.valueIterator();
    while (it.next()) |child_ptr| child_ptr.*.destroy();

    self.children.deinit(root_ctx.gpa);

    root_ctx.destroy();
}

pub fn _clear(self: *Root) void {
    var it = self.children.valueIterator();
    while (it.next()) |child_ptr| child_ptr.*.destroy();

    self.fresh_ctx = .fromInt(1);
    self.children.clearRetainingCapacity();
}
