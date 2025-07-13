//! # ir
//! This namespace provides a mid-level SSA/Sea of Nodes hybrid Intermediate Representation (ir) for Ribbon.
//!
//! It is used to represent the program in a way that is easy to optimize and transform.
//!
//! This ir targets:
//! * rvm's `core` bytecode (via the `bytecode` module)
//! * native machine code, in two ways:
//!    + in house x64 jit (the `machine` module)
//!    + freestanding (eventually)
const ir = @This();

const std = @import("std");
const log = std.log.scoped(.Rir);

const pl = @import("platform");
const common = @import("common");
const source = @import("source");
const Source = source.Source;
const bytecode = @import("bytecode");

test {
    std.testing.refAllDecls(@This());
}

/// VTable and arbitrary data map for user defined data on nodes.
pub const UserData = struct {
    /// The context this user data is bound to.
    context: *Context,
    /// Type constructors are expected to bind this.
    computeLayout: ?*const fn (constructor: Ref, input_types: []const Ref) anyerror!struct { u64, pl.Alignment } = null,
    /// Any ref can bind this to provide a custom display function for the node.
    display: ?*const fn (value: *const Data, writer: std.io.AnyWriter) anyerror!void = null,
    /// Any opaque data can be stored here, bound with comptime-known names.
    bindings: pl.StringArrayMap(pl.Any) = .empty,

    /// Deinitialize the user data, freeing all memory it owns.
    fn deinit(self: *UserData) void {
        self.bindings.deinit(self.context.gpa);
        self.context.arena.allocator().destroy(self);
    }

    /// Store an arbitrary address in the user data map, bound to a comptime-known key.
    /// * Cannnot take ownership of the value, as it is type erased. It must be valid for the lifetime of the userdata.
    pub fn addData(self: *UserData, comptime key: pl.EnumLiteral, value: anytype) !void {
        try self.bindings.put(self.context.gpa, comptime @tagName(key), pl.Any.from(value));
    }

    /// Get an arbitrary address from the user data map, bound to a comptime-known key.
    /// * This does not perform any checking on the type stored in the map.
    pub fn getData(self: *UserData, comptime T: type, comptime key: pl.EnumLiteral) ?*T {
        return (self.bindings.get(comptime @tagName(key)) orelse return null).to(T);
    }

    /// Delete an arbitrary address from the user data map, given the comptime-known key it is bound to.
    /// * If the key does not exist, this is a no-op.
    /// * This cannot deinitialize the value, as it is type-erased.
    pub fn delData(self: *UserData, comptime key: pl.EnumLiteral) void {
        _ = self.bindings.swapRemove(comptime @tagName(key));
    }
};

/// Designates the kind of type that a node represents. Kinds provide a high-level categorization
/// of types, allowing us to discern which locations and functionalities their values are
/// compatible with.
pub const KindTag = enum(u8) {
    /// The kind of nodes which only have control flow outputs, such as `set`.
    /// No value, no size, not usable for anything but reference.
    void,
    /// Values of data types can be stored anywhere, passed as arguments, etc.
    /// Size is known, some can be used in arithmetic or comparisons.
    data,
    /// In the event a type is referenced as a value, it will have the type `Type`,
    /// which is the only type of this kind.
    /// Size is known, can be used for comparisons.
    type,
    /// Effect types represent a side effect that can be performed by a function.
    /// They are markers that bind sets of handlers together, but do not have a value.
    effect,
    /// An array of types; for example a set of effect types. No value.
    ///
    /// **IMPORTANT**
    /// * Unlike the frontend language, this requires canonicalization of the order of types.
    set,
    /// An associative array of types; for example the fields of a struct. No value.
    ///
    /// **IMPORTANT**
    /// * Unlike the frontend language, this requires canonicalization of the order of types.
    map,
    /// This is *data*, but which cannot be a value; Only the destination of a pointer.
    @"opaque",
    /// The kind of types that designate a single structural value.
    /// The product type `(Int, Int)` or a struct `{ 0 'x Int, 1 'y Int }` for example.
    structure,
    /// The kind of types that designate a single primitive value.
    /// The integer type `1` or symbolic type `'foo` for example.
    primitive,
    /// The kind of types that designate a function *definition*, which can be called,
    /// have side effects, have a return value, and have an address that can be taken.
    /// They differ from `data` in that they are not values, they are available for uses like
    /// inlining, they cannot be stored in memory, and have no size.
    function,
    /// Types of the handler kind represent a definition of a special function which can handle a side effect.
    /// In addition to the properties of the function kind,
    /// they have a specific effect they handle,
    /// and a type they may cancel the effect with.
    handler,
    /// The result of something which does not return control flow to the caller, such as a panic function,
    /// or the `unreachable` instruction, will have the type `noreturn`, which is the only type of this kind.
    /// Any use of a value of this kind is undefined, as it is inherently dead code.
    noreturn,
    /// In the event a block is referenced as a value,
    /// it will have the type `Block`, which is of this kind.
    /// Size is known, can be used for comparisons.
    block,
    /// In the event a local variable is referenced as a value,
    /// it will have the type `Local (type)`, which is of this kind.
    /// Size is known, can be used for comparisons.
    local,
};

/// Designates the kind of operation, be it data manipulation or control flow, that is performed by an ir instruction.
pub const Operation = enum(u8) {
    /// No operation.
    nop,

    /// Standard ssa phi node, merge values from predecessor flows. As a user of the ir api,
    /// it is typically not necessary to use this directly. It is primarily used by the optimizer to
    /// eliminate unnecessary stack allocations and allocate registers.
    /// * In-bound control edges designate the predecessors to merge from.
    /// * In-bound data edges designate the value to use in case of arrival from the associated predecessor.
    /// * The out-bound data edges are the merged values.
    phi,

    /// Indicates a breakpoint should be emitted in the output; skipped by optimizers.
    breakpoint,
    /// Indicates an undefined state; all uses may be discarded by optimizers.
    @"unreachable",
    /// Indicates a defined but undesirable state that should halt execution.
    trap,
    /// Return flow control from a function or handler.
    @"return",
    /// Cancel the effect block of the current handler.
    cancel,
    /// Jump to the control edge.
    unconditional_branch,
    /// Jump to the first control edge, if the data edge is non-zero. Othewrise, jump to the second control edge.
    conditional_branch,
    /// A standard function call.
    /// * The first in-bound data edge is the function to call,
    /// the rest are the arguments to the function.
    /// * The out-bound data edge is the return value of the function.
    call,
    /// An effect handler prompt.
    /// * The first in-bound data edge is the effect to prompt,
    /// the rest are the arguments to the prompt.
    /// * The out-bound data edge is the return value of the prompt.
    prompt,

    /// Combine r-values to create a composite r-value.
    /// * The type of the instruction is the type of the composite value.
    /// * The in-bound data edges are the r-values to combine.
    /// * The out-bound data edge is the composite r-value.
    compose,

    /// Get the value of a local variable.
    /// * The first in-bound data edge is the l-value of the local variable to get,
    /// the second is the value to set it to.
    /// * The out-bound data edge is the r-value of the local variable.
    get_local,
    /// Set the value of a local variable.
    /// * The first in-bound data edge is the l-value of the local variable to set,
    /// the second is the value to set it to.
    /// * No out-bound data edge.
    set_local,

    /// Extract an elemental r-value from a composite r-value.
    get_element,
    /// Set an elemental value in a composite l-value or r-value.
    set_element,

    /// Extract an elemental r-value address from a composite l-value or r-value.
    /// * Type of the instruction is the type of the element.
    /// * The first in-bound data edge is the composite value to extract from,
    /// the second is the index of the element to extract. Second edge must be constant.
    /// * The out-bound data edge is the r-value address of the element.
    /// * If the composite edge is a local variable, this will force de-optimization of the local variable in mem2reg.
    get_element_addr,

    /// Load an r-value from an r-value address.
    /// * Type of the instruction is the type of the value to load.
    /// * The in-bound data edge is the r-value address to store to.
    /// * The out-bound data edge is the loaded value.
    load,
    /// Store an r-value to an r-value address.
    /// * The first in-bound data edge is the r-value address to store to,
    /// the second is the value to store.
    /// * No out-bound data edge.
    store,

    /// Convert a value to (approximately) the same value in another representation.
    /// * Type of the instruction is the type to convert to.
    /// * The in-bound data edge is the value to convert.
    /// * The out-bound data edge is the converted value.
    convert,
    /// Convert bits to a different type, changing the meaning without changing the bits.
    /// * Type of the instruction is the type to convert to.
    /// * The in-bound data edge is the value to convert.
    /// * The out-bound data edge is the converted value.
    bitcast,
};

/// The root context state.
/// * All Root methods assume that the root mutex is already locked by the caller.
pub const Root = struct {
    /// Used to generate unique ids for child contexts.
    fresh_ctx: ContextId = .fromInt(1),
    /// All child contexts owned by this root context.
    children: pl.UniqueReprMap(ContextId, *Context, 80) = .empty,
    /// Synchronization primitive for child contexts to use when accessing the root context.
    /// * All Root methods assume that the root mutex is already locked by the caller.
    mutex: std.Thread.Mutex = .{},

    /// Create a new child context, returning its pointer.
    /// * Caller must hold a lock on the root mutex for this call.
    pub fn createContext(self: *Root) !*Context {
        const root_ctx = self.getRootContext();

        var arena = std.heap.ArenaAllocator.init(root_ctx.gpa);

        const child = try arena.allocator().create(Context);
        errdefer child.destroy();

        child.* = Context{
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
    pub fn destroyContext(self: *Root, id: ContextId) void {
        const child = self.children.get(id) orelse return;
        child.destroy();

        _ = self.children.remove(id);
    }

    /// Get a pointer to a child context, if it exists.
    /// * Caller must hold a lock on the root mutex for this call.
    pub fn getContext(self: *Root, id: ContextId) ?*Context {
        return self.children.get(id);
    }

    /// Get the context of this Root.
    pub fn getRootContext(self: *Root) *Context {
        const inner: *@FieldType(Context, "inner") = @fieldParentPtr("root", self);
        return @fieldParentPtr("inner", inner);
    }

    /// Merges the nodes from a child context into this Root's context.
    /// * Caller must hold a lock on the root mutex for this call.
    pub fn merge(self: *Root, child_ctx: *Context) !void {
        std.debug.assert(!child_ctx.isRoot() and child_ctx.getRootContext() == self.getRootContext());
        const root_ctx = self.getRootContext();

        var merged_refs: RefMap = .{};
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

    fn _copyNode(
        self: *Root,
        child_ctx: *const Context,
        merged_refs: *RefMap,
        child_ref: Ref,
    ) !Ref {
        // Base case: If nil or already copied, return immediately.
        if (child_ref == Ref.nil) return Ref.nil;

        if (merged_refs.get(child_ref)) |cached_root_ref| {
            return cached_root_ref;
        }

        const root_ctx = self.getRootContext();
        const child_node = child_ctx.nodes.getPtr(child_ref).?;

        const was_interned = child_ctx.isLocalInternedNode(child_ref);
        const was_immutable = child_ctx.isLocalImmutableNode(child_ref);
        const old_mutability: pl.Mutability = if (was_immutable) .constant else .mutable;

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

                if (new_child_ref != Ref.nil) {
                    // Manually create the def->use link using the non-locking local primitive.
                    const users = try root_ctx._getLocalNodeUsersMut(new_child_ref);
                    try users.put(root_ctx.gpa, Use{ .ref = root_ref, .index = i }, {});
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

            var new_root_node: Node = undefined;
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

    fn _copyUserData(
        self: *Root,
        child_ctx: *const Context,
        root_ctx: *Context,
        child_ref: Ref,
        root_ref: Ref,
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
                // The pl.Any value is a simple pointer, so we just copy it.
                try root_ud.bindings.put(root_ctx.gpa, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }

    fn _deinit(self: *Root) void {
        const root_ctx = self.getRootContext();

        var it = self.children.valueIterator();
        while (it.next()) |child_ptr| child_ptr.*.destroy();

        self.children.deinit(root_ctx.gpa);

        root_ctx.destroy();
    }

    fn _clear(self: *Root) void {
        var it = self.children.valueIterator();
        while (it.next()) |child_ptr| child_ptr.*.destroy();

        self.fresh_ctx = .fromInt(1);
        self.children.clearRetainingCapacity();
    }
};

/// The main graph context of the ir.
pub const Context = struct {
    /// The context id. This is used to generate unique ids for nodes without knowing about sibling contexts.
    id: ContextId = .fromInt(0),
    /// State that varies between root/child contexts.
    inner: union(enum) {
        /// This is a root context.
        root: Root,
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
    nodes: pl.UniqueReprMap(Ref, Node, 80) = .empty,
    /// The def->use edges of nodes.
    users: pl.UniqueReprMap(Ref, pl.UniqueReprSet(Use, 80), 80) = .empty,
    /// Maps specific refs to user defined data, used for miscellaneous operations like layout computation, display, etc.
    userdata: pl.UniqueReprMap(Ref, *UserData, 80) = .empty,
    /// Maps builtin structures to their definition references.
    builtin: pl.UniqueReprMap(Builtin, Ref, 80) = .empty,
    /// Maps constant value nodes to references.
    interner: pl.HashMap(Node, Ref, NodeHasher, 80) = .empty,
    /// Flags whether a node is interned or not.
    interned_refs: RefSet = .empty,
    /// Flags whether a node is immutable or not.
    immutable_refs: RefSet = .empty,
    /// Flags whether a node is builtin or not.
    builtin_refs: RefSet = .empty,
    /// Used to generate context-unique ids for nodes.
    fresh_node: NodeId = .fromInt(1),
    /// Api wrapper for IR builder functions.
    builder: Builder = .{},

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
        self.interner.clearRetainingCapacity();
        self.interned_refs.clearRetainingCapacity();
        self.immutable_refs.clearRetainingCapacity();
        self.builtin_refs.clearRetainingCapacity();
        self.userdata.clearRetainingCapacity();
        self.builtin.clearRetainingCapacity();

        _ = self.arena.reset(.retain_capacity);

        if (self.asRoot()) |root| root._clear();
    }

    fn destroy(self: *Context) void {
        var node_it = self.nodes.valueIterator();
        while (node_it.next()) |node| node.deinit(self.gpa);

        var userdata_it = self.userdata.valueIterator();
        while (userdata_it.next()) |ptr2ptr| ptr2ptr.*.deinit();

        var users_it = self.users.valueIterator();
        while (users_it.next()) |set| set.deinit(self.gpa);

        self.nodes.deinit(self.gpa);
        self.users.deinit(self.gpa);
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
    pub fn genId(self: *Context) Id {
        return Id{ .context = self.id, .node = self.fresh_node.next() };
    }

    /// Determine if this context is a root context.
    pub fn isRoot(self: *Context) bool {
        return self.inner == .root;
    }

    /// Get the Root if this context is a root context.
    pub fn asRoot(self: *Context) ?*Root {
        return switch (self.inner) {
            .root => &self.inner.root,
            .child => null,
        };
    }

    /// Get the root state of this context.
    pub fn getRoot(self: *Context) *Root {
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
    pub fn getBuiltin(self: *Context, builtin: Builtin) !Ref {
        const gop = try self.builtin.getOrPut(self.gpa, builtin);

        if (!gop.found_existing) {
            const initializer = getBuiltinInitializer(builtin);

            const ref = try initializer(self);

            gop.value_ptr.* = ref;

            try self.builtin_refs.put(self.gpa, ref, {});
        }

        return gop.value_ptr.*;
    }

    /// Get the userdata for a specific reference.
    pub fn getLocalUserData(self: *Context, ref: Ref) !*UserData {
        const gop = try self.userdata.getOrPut(self.gpa, ref);

        if (!gop.found_existing) {
            const addr = try self.arena.allocator().create(UserData);
            addr.* = .{ .context = self };
            gop.value_ptr.* = addr;
        }

        return gop.value_ptr.*;
    }

    /// Get the userdata for a specific reference.
    pub fn getUserData(self: *Context, ref: Ref) !*UserData {
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
    pub fn delLocalUserData(self: *Context, ref: Ref) void {
        const userdata = self.userdata.get(ref) orelse {
            log.debug("Tried to delete non-existing local userdata: {}", .{ref});
            return;
        };

        userdata.deinit();

        _ = self.userdata.remove(ref);
    }

    /// Delete a userdata for a specific reference.
    pub fn delUserData(self: *Context, ref: Ref) void {
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
    fn _link(self: *Context, user_ref: Ref, operand_index: u64, used_ref: Ref) !void {
        if (used_ref == Ref.nil) return;
        std.debug.assert(user_ref.node_kind.getTag() == .structure or user_ref.node_kind.getTag() == .collection);

        const users = try self._getNodeUsersMut(used_ref);

        try users.put(self.gpa, Use{ .ref = user_ref, .index = operand_index }, {});
    }

    /// Removes a use->def back-link.
    fn _unlink(self: *Context, user_ref: Ref, operand_index: u64, used_ref: Ref) void {
        if (used_ref == Ref.nil) return;
        std.debug.assert(user_ref.node_kind.getTag() == .structure or user_ref.node_kind.getTag() == .collection);

        // failure here is allocation failure, but that can only happen if the node doesn't exist anyway
        const users = self._getNodeUsersMut(used_ref) catch return;

        _ = users.remove(Use{ .ref = user_ref, .index = operand_index });

        const user_node = self._getNodeMut(user_ref) orelse return;

        user_node.content.ref_list.items[operand_index] = Ref.nil;
    }

    /// Get a field of a structure data node bound by this reference.
    pub fn getField(self: *Context, ref: Ref, comptime field: pl.EnumLiteral) !?Ref {
        if (ref.node_kind.getTag() != .structure) {
            return error.InvalidNodeKind;
        }

        const field_name = comptime @tagName(field);

        const local_data = self.getNodeData(ref) orelse return error.InvalidReference;

        const structure_kind: StructureKind = @enumFromInt(@intFromEnum(ref.node_kind.getDiscriminator()));

        if (structure_kind == .nil) return error.InvalidGraphState;

        outer: inline for (comptime std.meta.fieldNames(StructureKind)[1..]) |kind_name| {
            const kind = comptime @field(StructureKind, kind_name);

            if (kind == structure_kind) {
                const struct_info = comptime @field(structures, kind_name);
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
    pub fn getElement(self: *Context, ref: Ref, index: u64) !?Ref {
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

    fn _setOperand(self: *Context, ref: Ref, index: u64, value: Ref) !void {
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
    pub fn setField(self: *Context, ref: Ref, comptime field: pl.EnumLiteral, value: Ref) !void {
        if (ref.node_kind.getTag() != .structure) {
            return error.InvalidNodeKind;
        }

        const field_name = comptime @tagName(field);

        const structure_kind: StructureKind = @enumFromInt(@intFromEnum(ref.node_kind.getDiscriminator()));

        if (structure_kind == .nil) return error.InvalidGraphState;

        outer: inline for (comptime std.meta.fieldNames(StructureKind)[1..]) |kind_name| {
            const kind = comptime @field(StructureKind, kind_name);

            if (kind == structure_kind) {
                const struct_info = comptime @field(structures, kind_name);
                const struct_fields = comptime std.meta.fieldNames(@TypeOf(struct_info));

                const index = comptime for (struct_fields, 0..) |name, i| {
                    if (std.mem.eql(u8, name, field_name)) break i;
                } else continue :outer;

                return self._setOperand(ref, index, value);
            }
        }

        return error.InvalidGraphState;
    }

    /// Set an element of a collection data node bound by index.
    /// * Runtime type checking is not performed.
    /// * If the index is out of bounds, it must be equal to the length of the collection,
    ///   in which case the element is appended to the collection.
    /// * If the index is greater than the length of the collection, this is an error.
    pub fn setElement(self: *Context, ref: Ref, index: u64, value: Ref) !void {
        if (ref.node_kind.getTag() != .collection) {
            return error.InvalidNodeKind;
        }

        try self._setOperand(ref, index, value);
    }

    /// Get a ref list from a structure or list node bound by this reference.
    pub fn getChildren(self: *Context, ref: Ref) ![]const Ref {
        if (ref.node_kind.getTag() != .structure and ref.node_kind.getTag() != .collection) {
            return error.InvalidNodeKind;
        }

        const local_data = self.getNodeData(ref) orelse return error.InvalidReference;

        return local_data.ref_list.items;
    }

    /// Determine if a node is interned, given its reference.
    pub fn isLocalBuiltinNode(self: *const Context, ref: Ref) bool {
        return self.builtin_refs.contains(ref);
    }

    /// Determine if a node is interned, given its reference.
    pub fn isLocalInternedNode(self: *const Context, ref: Ref) bool {
        return self.interned_refs.contains(ref);
    }

    /// Determine if a node is immutable, given its reference.
    pub fn isLocalImmutableNode(self: *const Context, ref: Ref) bool {
        return self.immutable_refs.contains(ref);
    }

    /// Determine if a node is interned, given its reference.
    pub fn isBuiltinNode(self: *Context, ref: Ref) bool {
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
    pub fn isInternedNode(self: *Context, ref: Ref) bool {
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
    pub fn isImmutableNode(self: *Context, ref: Ref) bool {
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
    pub fn computeLayout(self: *Context, ref: Ref) !struct { u64, pl.Alignment } {
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

    fn _internNode(self: *Context, node: Node) !Ref {
        try self._ensureConstantRefs(node);

        return self._internNodeUnchecked(node);
    }

    fn _addNode(self: *Context, mutability: pl.Mutability, node: Node) !Ref {
        if (mutability == .constant) try self._ensureConstantRefs(node);

        return self._addNodeUnchecked(mutability, node);
    }

    fn _ensureConstantRefs(self: *Context, node: Node) !void {
        const tag = node.kind.getTag();
        if (tag.containsReferences()) {
            for (node.content.ref_list.items) |content_ref| {
                if (content_ref != Ref.nil and !self.isImmutableNode(content_ref)) {
                    log.debug("Attempted to create an immutable node that references a mutable node {}", .{content_ref});
                    return error.ImmutableNodeReferencesMutable;
                }
            }
        }
    }

    fn _internNodeUnchecked(self: *Context, node: Node) !Ref {
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

    fn _addNodeUnchecked(self: *Context, mutability: pl.Mutability, node: Node) !Ref {
        const tag = node.kind.getTag();

        const ref = Ref{
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
    pub fn delLocalNode(self: *Context, ref: Ref) void {
        if (self.isLocalImmutableNode(ref)) {
            log.debug("Tried to delete an immutable node: {}", .{ref});
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
    pub fn delNode(self: *Context, ref: Ref) void {
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
    pub fn getLocalNode(self: *Context, ref: Ref) ?*const Node {
        return self.nodes.getPtr(ref);
    }

    fn _getLocalNodeMut(self: *Context, ref: Ref) ?*Node {
        const node = self.nodes.getPtr(ref) orelse return null;

        if (self.isLocalImmutableNode(ref)) {
            log.debug("Tried to get mutable pointer to an immutable node: {}", .{ref});
            return null;
        }

        return node;
    }

    /// Get an immutable pointer to a raw node, given its reference.
    pub fn getNode(self: *Context, ref: Ref) ?*const Node {
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

    fn _getNodeMut(self: *Context, ref: Ref) ?*Node {
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
    pub fn getLocalNodeUsers(self: *Context, ref: Ref) !*const pl.UniqueReprSet(Use, 80) {
        std.debug.assert(ref.id.context == self.id);

        const gop = try self.users.getOrPut(self.gpa, ref);

        if (!gop.found_existing) gop.value_ptr.* = .{};

        return gop.value_ptr;
    }

    /// Get a list of all the users of a node, given its reference.
    pub fn getNodeUsers(self: *Context, ref: Ref) !*const pl.UniqueReprSet(Use, 80) {
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

    fn _getLocalNodeUsersMut(self: *Context, ref: Ref) !*pl.UniqueReprSet(Use, 80) {
        std.debug.assert(ref.id.context == self.id);

        const gop = try self.users.getOrPut(self.gpa, ref);

        if (!gop.found_existing) gop.value_ptr.* = .{};

        return gop.value_ptr;
    }

    fn _getNodeUsersMut(self: *Context, ref: Ref) !*pl.UniqueReprSet(Use, 80) {
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
    pub fn getLocalNodeData(self: *Context, ref: Ref) ?*const Data {
        return &(self.getLocalNode(ref) orelse return null).content;
    }

    fn _getLocalNodeDataMut(self: *Context, ref: Ref) ?*Data {
        return &(self._getLocalNodeMut(ref) orelse return null).content;
    }

    /// Get an immutable pointer to raw node data, given its reference.
    pub fn getNodeData(self: *Context, ref: Ref) ?*const Data {
        return &(self.getNode(ref) orelse return null).content;
    }

    fn _getNodeDataMut(self: *Context, ref: Ref) ?*Data {
        return &(self._getNodeMut(ref) orelse return null).content;
    }

    /// Create a new primitive node in the context, given a primitive kind and value.
    /// * The value must be a primitive type, such as an integer, index, or opcode. See `ir.primitives`.
    pub fn addPrimitive(self: *Context, mutability: pl.Mutability, value: anytype) !Ref {
        const node = try Node.primitive(value);

        return self._addNode(mutability, node);
    }

    /// Create a new structure node in the context, given a structure kind and an initializer.
    /// * The initializer must be a struct with the same fields as the structure kind. See `ir.structure`.
    pub fn addStructure(self: *Context, mutability: pl.Mutability, comptime kind: StructureKind, value: anytype) !Ref {
        var node = try Node.structure(self.gpa, kind, value);
        errdefer node.deinit(self.gpa);

        return self._addNode(mutability, node);
    }

    /// Add a data buffer to the context.
    pub fn addBuffer(self: *Context, mutability: pl.Mutability, value: []const u8) !Ref {
        var node = try Node.buffer(self.gpa, value);
        errdefer node.deinit(self.gpa);

        return self._addNode(mutability, node);
    }

    /// Add a ref list to the context.
    pub fn addList(self: *Context, mutability: pl.Mutability, element_kind: Discriminator, value: []const Ref) !Ref {
        var node = try Node.list(self.gpa, element_kind, value);
        errdefer node.deinit(self.gpa);

        return self._addNode(mutability, node);
    }

    /// Intern a primitive value in the context, given a primitive kind and value.
    /// * If the node already exists in this context, it will return the existing reference.
    /// * Modifying nodes added this way is unsafe.
    /// * The value must be a primitive type, such as an integer, index, or opcode. See `ir.primitives`.
    pub fn internPrimitive(self: *Context, value: anytype) !Ref {
        const node = try Node.primitive(value);

        return self._internNode(node);
    }

    /// Intern a structure node in the context, given a structure kind and an initializer.
    /// * The initializer must be a struct with the same fields as the structure kind. See `ir.structure`.
    /// * If the node already exists in this context, it will return the existing reference.
    /// * Modifying nodes added this way is unsafe.
    pub fn internStructure(self: *Context, comptime kind: StructureKind, value: anytype) !Ref {
        var node = try Node.structure(self.gpa, kind, value);
        errdefer node.deinit(self.gpa);

        return self._internNode(node);
    }

    /// Intern a name value in the context.
    /// * If the node already exists in this context, it will return the existing reference.
    /// * Modifying nodes added this way is unsafe.
    pub fn internName(self: *Context, value: []const u8) !Ref {
        const gop = try self.interner.getOrPutAdapted(self.gpa, value, NameHasher);

        if (!gop.found_existing) {
            const arr = try self.arena.allocator().dupe(u8, value);

            const node = try Node.data(.name, arr);

            gop.key_ptr.* = node;

            gop.value_ptr.* = try self._addNode(.constant, node);

            try self.interned_refs.put(self.gpa, gop.value_ptr.*, {});
        }

        return gop.value_ptr.*;
    }

    /// Intern a `Source` value in the context.
    /// * If the node already exists in this context, it will return the existing reference.
    /// * Modifying nodes added this way is unsafe.
    pub fn internSource(self: *Context, value: Source) !Ref {
        const gop = try self.interner.getOrPutAdapted(self.gpa, value, SourceHasher);

        if (!gop.found_existing) {
            const owned_value = try value.dupe(self.arena.allocator());

            const node = try Node.data(.source, owned_value);

            gop.key_ptr.* = node;

            gop.value_ptr.* = try self._addNode(.constant, node);

            try self.interned_refs.put(self.gpa, gop.value_ptr.*, {});
        }

        return gop.value_ptr.*;
    }

    /// Intern a data buffer in the context.
    /// * If the buffer already exists in this context, it will return the existing reference.
    /// * Modifying nodes added this way is unsafe.
    pub fn internBuffer(self: *Context, value: []const u8) !Ref {
        const gop = try self.interner.getOrPutAdapted(self.gpa, value, BufferHasher);

        if (!gop.found_existing) {
            var arr = try pl.ArrayList(u8).initCapacity(self.gpa, value.len);
            errdefer arr.deinit(self.gpa);

            arr.appendSliceAssumeCapacity(value);

            const node = try Node.data(.buffer, arr);

            gop.key_ptr.* = node;

            gop.value_ptr.* = try self._addNode(.constant, node);

            try self.interned_refs.put(self.gpa, gop.value_ptr.*, {});
        }

        return gop.value_ptr.*;
    }

    /// Intern a ref list in the context.
    /// * If the list already exists in this context, it will return the existing reference.
    /// * Modifying nodes added this way is unsafe.
    pub fn internList(self: *Context, comptime element_kind: Discriminator, value: []const Ref) !Ref {
        const gop = try self.interner.getOrPutAdapted(self.gpa, value, ListHasher(element_kind));

        if (!gop.found_existing) {
            var arr = try pl.ArrayList(Ref).initCapacity(self.gpa, value.len);
            errdefer arr.deinit(self.gpa);

            arr.appendSliceAssumeCapacity(value);

            const node = Node{
                .kind = NodeKind.collection(element_kind),
                .content = .{ .ref_list = arr },
            };

            gop.key_ptr.* = node;
            gop.value_ptr.* = try self._addNode(.constant, node);

            try self.interned_refs.put(self.gpa, gop.value_ptr.*, {});
        }

        return gop.value_ptr.*;
    }
};

/// A reference to a node in an ir context; unlike `Ref`,
/// this does not bind the context it is contained within.
pub const Ref = packed struct(u64) {
    /// The kind of the node bound by this reference.
    node_kind: NodeKind,
    /// The unique id of the node in the context.
    id: Id,

    /// The nil reference, a placeholder for an invalid or irrelevant reference.
    pub const nil = Ref{ .node_kind = .nil, .id = .nil };
};

/// `platform.UniqueReprMap` for `Ref` to `Ref`.
pub const RefMap = pl.UniqueReprMap(Ref, Ref, 80);

/// `platform.UniqueReprSet` for `Ref`.
pub const RefSet = pl.UniqueReprSet(Ref, 80);

/// Uniquely identifies a child context in an ir.
pub const ContextId = common.Id.of(Context, 16);
/// Uniquely identifies a node in an unknown ir context.
pub const NodeId = common.Id.of(Node, 32);

/// Uniquely identifies a node in a specific ir context.
pub const Id = packed struct {
    /// The context this node is bound to.
    context: ContextId,
    /// The unique id of the node in the context.
    node: NodeId,

    /// The nil id, a placeholder for an invalid or irrelevant id.
    pub const nil = Id{
        .context = .null,
        .node = .null,
    };
};

/// A reference to a node in the ir, which can be used to access the node's data.
pub const NodeKind = packed struct(u16) {
    /// The tag of the node, which indicates the shape of node.
    /// * We have to type erase the bits here because of zig compiler limitations wrt comptime eval;
    /// this is always of type `ir.Tag`.
    tag: u3,
    /// The discriminator of the node, which indicates the specific kind of value it contains.
    /// * We have to type erase the bits here because of zig compiler limitations wrt comptime eval;
    /// this is always of type `ir.Discriminator`.
    discriminator: u13,

    /// The nil node kind, which is used to indicate an empty or invalid node.
    pub const nil = NodeKind{ .tag = @intFromEnum(Tag.nil), .discriminator = 0 };

    /// Create a new node kind with a data tag and the given data kind as its discriminator.
    pub fn data(discriminator: DataKind) NodeKind {
        return NodeKind{ .tag = @intFromEnum(Tag.data), .discriminator = @intFromEnum(discriminator) };
    }

    /// Create a new node kind with a primitive tag and the given primitive kind as its discriminator.
    pub fn primitive(discriminator: PrimitiveKind) NodeKind {
        return NodeKind{ .tag = @intFromEnum(Tag.primitive), .discriminator = @intFromEnum(discriminator) };
    }

    /// Create a new node kind with a structure tag and the given structure kind as its discriminator.
    pub fn structure(discriminator: StructureKind) NodeKind {
        return NodeKind{ .tag = @intFromEnum(Tag.structure), .discriminator = @intFromEnum(discriminator) };
    }

    /// Create a new node kind with a collection tag and the given discriminator.
    pub fn collection(discriminator: Discriminator) NodeKind {
        return NodeKind{ .tag = @intFromEnum(Tag.collection), .discriminator = @intFromEnum(discriminator) };
    }

    /// Extract the tag bits of the node kind.
    pub fn getTag(self: NodeKind) Tag {
        return @enumFromInt(self.tag);
    }

    /// Extract the discriminator bits of the node kind.
    pub fn getDiscriminator(self: NodeKind) Discriminator {
        return @enumFromInt(self.discriminator);
    }

    /// `std.fmt` impl
    pub fn format(self: NodeKind, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}:{s}", .{
            @tagName(self.getTag()),
            @tagName(self.getDiscriminator()),
        });
    }
};

/// 64-bit context providing eql and hash functions for `Node` types.
/// This is used by the interner to map constant value nodes to their references.
pub const NodeHasher = struct {
    pub fn eql(_: @This(), a: Node, b: Node) bool {
        if (a.kind != b.kind) return false;

        return switch (a.kind.getTag()) {
            .nil => false,
            .data => switch (discriminants.force(DataKind, a.kind.getDiscriminator())) {
                .nil => false,
                .name => std.mem.eql(u8, a.content.name, b.content.name),
                .source => a.content.source.eql(&b.content.source),
                .buffer => std.mem.eql(u8, a.content.buffer.items, b.content.buffer.items),
            },
            .primitive => a.content.primitive == b.content.primitive,
            .structure, .collection => std.mem.eql(Ref, a.content.ref_list.items, b.content.ref_list.items),
        };
    }

    pub fn hash(_: @This(), n: Node) u64 {
        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(std.mem.asBytes(&n.kind));

        switch (n.kind.getTag()) {
            .nil => {},
            .data => switch (discriminants.force(DataKind, n.kind.getDiscriminator())) {
                .nil => {},
                .name => hasher.update(n.content.name),
                .source => n.content.source.hash(&hasher),
                .buffer => hasher.update(n.content.buffer.items),
            },
            .primitive => hasher.update(std.mem.asBytes(&n.content.primitive)),
            .structure, .collection => hasher.update(std.mem.sliceAsBytes(n.content.ref_list.items)),
        }

        return hasher.final();
    }
};

/// Utilities for working with node discriminant enums.
pub const discriminants = struct {
    /// Determine if a zig type is a node discriminant enum.
    /// * ie, one of `Discriminator`, `DataKind`, `PrimitiveKind`, or `StructureKind`.
    pub fn isValidType(comptime T: type) bool {
        comptime return switch (T) {
            Discriminator,
            DataKind,
            PrimitiveKind,
            StructureKind,
            => true,
            else => false,
        };
    }

    /// Determine if `T` is substitutable for `U`
    /// * `Discriminator isSubstitutableFor { DataKind, PrimitiveKind, StructureKind }`
    /// * `DataKind isSubstitutableFor { Discriminator, DataKind }`
    /// * `PrimitiveKind isSubstitutableFor { Discriminator, PrimitiveKind }`
    /// * `StructureKind isSubstitutableFor { Discriminator, StructureKind }`
    pub fn isSubstitutableFor(comptime T: type, comptime U: type) bool {
        comptime return switch (T) {
            Discriminator => switch (U) {
                Discriminator => true,
                DataKind => true,
                PrimitiveKind => true,
                StructureKind => true,
                else => false,
            },
            DataKind => switch (U) {
                Discriminator => true,
                DataKind => true,
                PrimitiveKind => false,
                StructureKind => false,
                else => false,
            },
            PrimitiveKind => switch (U) {
                Discriminator => true,
                DataKind => false,
                PrimitiveKind => true,
                StructureKind => false,
                else => false,
            },
            StructureKind => switch (U) {
                Discriminator => true,
                DataKind => false,
                PrimitiveKind => false,
                StructureKind => true,
                else => false,
            },
            else => false,
        };
    }

    /// Cast node discriminant enums between types.
    /// * Compile time checked via subtype relation `ir.discriminants.isSubstitutableFor`.
    /// * Runtime checks for specific discriminant.
    pub fn cast(comptime T: type, value: anytype) ?T {
        const U = comptime @TypeOf(value);
        const u = @intFromEnum(value);

        // Ensure a valid *type* conversion. Ie, Discriminator can become DataKind, PrimitiveKind, or StructureKind.
        if (comptime !isSubstitutableFor(U, T)) {
            @compileError("ir.discriminants.cast: Cannot cast " ++ @typeName(U) ++ " to " ++ @typeName(T));
        }

        if (pl.isEnumVariant(T, u)) {
            return @enumFromInt(u);
        } else {
            return null;
        }
    }

    /// Cast node discriminant enums between types.
    /// * Compile time checked via subtype relation `ir.discriminants.isSubstitutableFor`.
    /// * Runtime checked in safe modes via zig enum validation.
    pub fn force(comptime T: type, value: anytype) T {
        const U = comptime @TypeOf(value);

        // Ensure a valid *type* conversion. Ie, Discriminator can become DataKind, PrimitiveKind, or StructureKind.
        if (comptime !isSubstitutableFor(U, T)) {
            @compileError("ir.discriminants.force: Cannot cast " ++ @typeName(U) ++ " to " ++ @typeName(T));
        }

        // Whether this is valid still depends on the value. Ie, a single Discriminator is not valid as both a DataKind and a PrimitiveKind, despite being type compatible.
        return @enumFromInt(@intFromEnum(value));
    }

    /// Convert an integer value to a node discriminant enum, if it is valid.
    pub fn fromInt(comptime T: type, value: anytype) ?T {
        if (comptime !isValidType(T)) {
            @compileError("ir.discriminants.fromInt: Cannot cast to " ++ @typeName(T));
        }

        if (pl.isEnumVariant(T, value)) {
            return @enumFromInt(value);
        } else {
            return null;
        }
    }
};

/// 64-bit context providing eql and hash functions for `Node` and `[]const u8` types.
/// This is used by the interner to map constant value nodes to their references.
pub fn ListHasher(comptime element_kind: Discriminator) type {
    return struct {
        pub fn eql(b: []const Ref, a: Node) bool {
            if (a.kind.getTag() != .collection or a.kind.getDiscriminator() != element_kind) return false;

            return std.mem.eql(Ref, a.content.ref_list.items, b);
        }

        pub fn hash(n: []const Ref) u64 {
            var hasher = std.hash.Fnv1a_64.init();
            hasher.update(std.mem.asBytes(&ir.NodeKind.collection(element_kind)));
            hasher.update(std.mem.sliceAsBytes(n));

            return hasher.final();
        }
    };
}

/// 64-bit context providing eql and hash functions for `Node` and `[]const u8` types.
/// This is used by the interner to map constant value nodes to their references.
pub const NameHasher = struct {
    pub fn eql(b: []const u8, a: Node) bool {
        if (a.kind != NodeKind.data(.name)) return false;

        return std.mem.eql(u8, a.content.name, b);
    }

    pub fn hash(n: []const u8) u64 {
        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(std.mem.asBytes(&ir.NodeKind.data(.name)));
        hasher.update(n);

        return hasher.final();
    }
};

/// 64-bit context providing eql and hash functions for `Node` and `Source` types.
/// This is used by the interner to map constant value nodes to their references.
pub const SourceHasher = struct {
    pub fn eql(a: Source, b: Node) bool {
        if (b.kind != NodeKind.data(.source)) return false;

        return a.eql(&b.content.source);
    }

    pub fn hash(n: Source) u64 {
        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(std.mem.asBytes(&ir.NodeKind.data(.source)));
        n.hash(&hasher);

        return hasher.final();
    }
};

/// 64-bit context providing eql and hash functions for `Node` and `[]const u8` types.
/// This is used by the interner to map constant value nodes to their references.
pub const BufferHasher = struct {
    pub fn eql(b: []const u8, a: Node) bool {
        if (a.kind != NodeKind.data(.buffer)) return false;

        return std.mem.eql(u8, a.content.buffer.items, b);
    }

    pub fn hash(n: []const u8) u64 {
        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(std.mem.asBytes(&ir.NodeKind.data(.buffer)));
        hasher.update(n);

        return hasher.final();
    }
};

/// Represents a def->use edge in the ir graph.
pub const Use = packed struct(u128) {
    /// The node referencing this definition.
    ref: Ref,
    /// The index of the use within the referencing node.
    index: u64,
};

/// Body data type for data nodes.
pub const Node = struct {
    /// The kind of the data stored here.
    kind: NodeKind,
    /// The untagged union of the data that can be stored here.
    content: Data,

    /// Creates a deep copy of the node, duplicating any owned memory.
    pub fn dupe(self: *const Node, allocator: std.mem.Allocator) !Node {
        var new_node = self.*;

        switch (self.kind.getTag()) {
            .data => switch (discriminants.force(DataKind, self.kind.getDiscriminator())) {
                // Buffer is the only data kind that owns memory
                .buffer => new_node.content.buffer = try self.content.buffer.clone(allocator),
                // Name and Source are always interned
                .nil, .name, .source => {},
            },
            // Structures and collections both use ref_list, which owns memory
            .structure, .collection => {
                new_node.content.ref_list = try self.content.ref_list.clone(allocator);
            },
            .nil, .primitive => {},
        }

        return new_node;
    }

    /// Deinitialize the node, freeing any owned memory.
    /// * This is a no-op for nodes that do not own memory.
    /// * This should only be called on nodes that were created outside of a context and never added to one.
    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.kind.getTag()) {
            .data => switch (self.kind.getDiscriminator()) {
                .buffer => self.content.buffer.deinit(allocator),
                else => {},
            },
            .structure, .collection => self.content.ref_list.deinit(allocator),
            else => {},
        }
    }

    /// Create a data node outside of a context, given a data kind and data.
    pub fn data(comptime kind: DataKind, value: DataType(kind)) !Node {
        return Node{
            .kind = NodeKind.data(kind),
            .content = @unionInit(Data, @tagName(kind), value),
        };
    }

    /// Create a primitive node outside of a context, given a primitive value.
    /// * The value must be a primitive type, such as an integer, index, or opcode.
    pub fn primitive(value: anytype) !Node {
        const T = comptime @TypeOf(value);

        inline for (comptime std.meta.fieldNames(Primitives)) |field| {
            const field_type = comptime @field(primitives, field);

            if (comptime T == field_type) {
                const converter = @field(primitive_converters, field);

                return Node{
                    .kind = NodeKind.primitive(@field(PrimitiveKind, field)),
                    .content = .{ .primitive = converter(value) },
                };
            }
        } else {
            @compileError("Non-primitive type " ++ @typeName(T));
        }
    }

    /// Create a structure node outside of a context, given a structure kind and data.
    /// * The initializer must be a struct with the same fields as the structure kind.
    /// * Comptime and runtime checking is employed to ensure the initializer field refs are the right kinds.
    /// * Allocator should be that of the context that will own the node.
    pub fn structure(allocator: std.mem.Allocator, comptime kind: StructureKind, value: anytype) !Node {
        const struct_name = comptime @tagName(kind);
        const T = comptime @FieldType(Structures, struct_name);
        const structure_decls = comptime std.meta.fields(T);
        const structure_value = @field(structures, struct_name);

        var ref_list = pl.ArrayList(Ref).empty;
        try ref_list.ensureTotalCapacity(allocator, structure_decls.len);
        errdefer ref_list.deinit(allocator);

        inline for (structure_decls) |decl| {
            const decl_info = @typeInfo(decl.type);
            const decl_value = @field(structure_value, decl.name);
            const init_value: Ref = @field(value, decl.name);

            switch (decl_info) {
                .enum_literal => {
                    if (comptime std.mem.eql(u8, @tagName(decl_value), "any")) {
                        ref_list.appendAssumeCapacity(init_value);
                    } else {
                        @compileError("Unexpected type for structure " ++ struct_name ++ " field decl " ++ decl.name ++ ": " ++ @typeName(decl.type));
                    }
                },
                .@"struct" => |info| {
                    if (!info.is_tuple) @compileError("Unexpected type for structure " ++ struct_name ++ " field decl " ++ decl.name ++ ": " ++ @typeName(decl.type));
                    if (info.fields.len != 2) @compileError("Unexpected type for structure " ++ struct_name ++ " field decl " ++ decl.name ++ ": " ++ @typeName(decl.type));

                    const node_kind = comptime NodeKind{
                        .tag = @intFromEnum(@field(Tag, @tagName(decl_value[0]))),
                        .discriminator = @intFromEnum(@field(Discriminator, @tagName(decl_value[1]))),
                    };

                    const ta = node_kind.getTag();
                    const tb = init_value.node_kind.getTag();

                    const da = node_kind.getDiscriminator();
                    const db = init_value.node_kind.getDiscriminator();

                    if ((tb == ta or ta == .nil or tb == .nil) and
                        (db == da or da == .nil or db == .nil))
                    {
                        ref_list.appendAssumeCapacity(init_value);
                    } else {
                        log.debug("Unexpected node kind for structure {s} field decl {s}: expected {}, got {}", .{
                            struct_name,
                            decl.name,
                            node_kind,
                            init_value.node_kind,
                        });

                        return error.InvalidNodeKind;
                    }
                },
                else => {
                    @compileError("Unexpected type for structure " ++ struct_name ++ " field decl " ++ decl.name ++ ": " ++ @typeName(decl.type));
                },
            }
        }

        return Node{
            .kind = NodeKind.structure(kind),
            .content = .{
                .ref_list = ref_list,
            },
        };
    }

    /// Create a data buffer node outside of a context, given a buffer of bytes.
    /// * Allocator should be that of the context that will own the node.
    pub fn buffer(allocator: std.mem.Allocator, init: []const u8) !Node {
        var arr = try pl.ArrayList(u8).initCapacity(allocator, init.len);
        errdefer arr.deinit(allocator);

        arr.appendSliceAssumeCapacity(init);

        return Node{
            .kind = NodeKind.data(.buffer),
            .content = .{ .buffer = arr },
        };
    }

    /// Create a ref list node outside of a context, given a list of references.
    /// * Allocator should be that of the context that will own the node.
    pub fn list(allocator: std.mem.Allocator, element_kind: Discriminator, init: []const Ref) !Node {
        var arr = try pl.ArrayList(Ref).initCapacity(allocator, init.len);
        errdefer arr.deinit(allocator);

        arr.appendSliceAssumeCapacity(init);

        return Node{
            .kind = NodeKind.collection(element_kind),
            .content = .{ .ref_list = arr },
        };
    }
};

/// An untagged union of all the data types that can be stored in an ir node.
pub const Data = union {
    /// A symbolic name, such as a variable name or a function name.
    name: []const u8,
    /// A source location.
    source: Source,
    /// Arbitrary data, such as a string body.
    buffer: pl.ArrayList(u8),

    /// An arbitrary integer value, such as an index into an array.
    primitive: u64,
    /// Arbitrary list of graph refs, such as a list of types.
    ref_list: pl.ArrayList(Ref),
};

/// The tag of a node, which indicates the overall node shape, be it data, structure, or collection.
pub const Tag = enum(u3) {
    /// The tag for an empty or invalid node.
    /// Discriminator is ignored, and should always be initialized to nil.
    nil,
    /// The tag for a node that contains unstructured data, such as a name, source, or similar.
    /// Discriminator always carries a specific kind, such as `name`, `source`, etc.
    data,
    /// The tag for a node that contains a primitive, such as an integer, index, or opcode.
    /// Discriminator may carry a specific kind, or nil to indicate untyped bytes.
    primitive,
    /// The tag for a node that contains a structure, such as a function, block, or instruction.
    /// Discriminator always carries a specific kind, such as `type`, `effect`, or `function`.
    structure,
    /// The tag for a node that is simply a list of other nodes.
    /// Discriminator may carry a specific kind, or nil to indicate a heterogeneous collection.
    collection,

    /// Determine if a node with this tag can contain references to other nodes.
    pub fn containsReferences(self: Tag) bool {
        return switch (self) {
            .nil, .data, .primitive => false,
            .structure, .collection => true,
        };
    }
};

/// The type of primitive data nodes definition structure.
pub const Primitives: type = @TypeOf(primitives);

/// The type of the ir structures definition structure.
pub const Structures: type = @TypeOf(structures);

/// The discriminator of a node, which indicates the specific kind of value it contains.
/// * Variant names are the field names of `ir.structures`, `ir.primitives`, `ir.Data` without `ref_list` or `primitive`, and `nil`.
pub const Discriminator: type = Discriminator: {
    const data_fields = std.meta.fieldNames(DataKind);
    const primitive_fields = std.meta.fieldNames(PrimitiveKind);
    const structure_fields = std.meta.fieldNames(StructureKind);

    var fields = [1]std.builtin.Type.EnumField{undefined} ** ((primitive_fields.len - 1) + (structure_fields.len - 1) + (data_fields.len - 1) + 1);
    fields[0] = .{ .name = "nil", .value = 0 };

    var i = 1;

    for (data_fields[0..]) |field| {
        if (std.mem.eql(u8, field, "nil")) continue;

        fields[i] = .{ .name = field, .value = @intFromEnum(@field(DataKind, field)) };
        i += 1;
    }

    for (primitive_fields[0..]) |field| {
        if (std.mem.eql(u8, field, "nil")) continue;

        fields[i] = .{ .name = field, .value = @intFromEnum(@field(PrimitiveKind, field)) };
        i += 1;
    }

    for (structure_fields[0..]) |field| {
        if (std.mem.eql(u8, field, "nil")) continue;

        fields[i] = .{ .name = field, .value = @intFromEnum(@field(StructureKind, field)) };
        i += 1;
    }

    break :Discriminator @Type(.{
        .@"enum" = std.builtin.Type.Enum{
            .tag_type = u13,
            .fields = &fields,
            .decls = &.{},
            .is_exhaustive = true,
        },
    });
};

/// The kind of data that can be stored in a `Data` node.
/// * Variant names are the field names of `ir.Data` without `ref_list` or `primitive`, as well as `nil`.
pub const DataKind: type = DataKind: {
    const data_fields = std.meta.fieldNames(Data);

    const ignored = .{ "ref_list", "primitive" };

    var fields = [1]std.builtin.Type.EnumField{undefined} ** ((data_fields.len - ignored.len) + 1);
    var i = 1;
    fields[0] = .{ .name = "nil", .value = 0 };

    field_loop: for (data_fields) |field_name| {
        for (ignored) |ignore| {
            if (std.mem.eql(u8, field_name, ignore)) continue :field_loop;
        }

        fields[i] = .{
            .name = field_name,
            .value = 1000 + i,
        };

        i += 1;
    }

    break :DataKind @Type(.{
        .@"enum" = std.builtin.Type.Enum{
            .tag_type = u13,
            .fields = &fields,
            .decls = &.{},
            .is_exhaustive = true,
        },
    });
};

/// Convert a `DataKind` to the type of data it represents.
pub fn DataType(comptime kind: DataKind) type {
    comptime return @FieldType(Data, @tagName(kind));
}

/// The kind of primitives that can be stored in a `Primitive` node.
/// * Variant names are the field names of `ir.primitives`, as well as `nil`.
pub const PrimitiveKind: type = Primitive: {
    const generated_fields = std.meta.fieldNames(Primitives);

    var fields = [1]std.builtin.Type.EnumField{undefined} ** (generated_fields.len + 1);

    fields[0] = .{ .name = "nil", .value = 0 };

    for (generated_fields, 1..) |field_name, i| {
        fields[i] = .{
            .name = field_name,
            .value = 2000 + i,
        };
    }

    break :Primitive @Type(.{
        .@"enum" = std.builtin.Type.Enum{
            .tag_type = u13,
            .fields = &fields,
            .decls = &.{},
            .is_exhaustive = true,
        },
    });
};

/// The kind of structures that can be stored in a `Structure` node.
/// * Variant names are the field names of `ir.structures`, as well as `nil`.
pub const StructureKind: type = Structure: {
    const generated_fields = std.meta.fieldNames(Structures);

    var fields = [1]std.builtin.Type.EnumField{undefined} ** (generated_fields.len + 1);

    fields[0] = .{ .name = "nil", .value = 0 };

    for (generated_fields, 1..) |field_name, i| {
        fields[i] = .{
            .name = field_name,
            .value = 3000 + i,
        };
    }

    break :Structure @Type(.{
        .@"enum" = std.builtin.Type.Enum{
            .tag_type = u13,
            .fields = &fields,
            .decls = &.{},
            .is_exhaustive = true,
        },
    });
};

/// Identity of a builtin construct such as a type constructor, type, etc.
pub const Builtin: type = builtin: {
    const decls = std.meta.declarations(builtins);
    var fields = [1]std.builtin.Type.EnumField{undefined} ** decls.len;

    for (decls, 0..) |decl, i| {
        fields[i] = .{
            .name = decl.name,
            .value = i,
        };
    }

    break :builtin @Type(.{
        .@"enum" = std.builtin.Type.Enum{
            .tag_type = u32,
            .fields = &fields,
            .decls = &.{},
            .is_exhaustive = true,
        },
    });
};

/// Get the initializer function for a given builtin construct.
pub fn getBuiltinInitializer(builtin: Builtin) *const BuiltinInitializer {
    return builtin_table[@intFromEnum(builtin)];
}

pub const BuiltinInitializer = fn (*Context) anyerror!Ref;

pub const builtin_table = builtin_table: {
    const field_names = std.meta.fieldNames(Builtin);
    var functions = [1]*const fn (*Context) anyerror!Ref{undefined} ** field_names.len;
    for (field_names, 0..) |field_name, i| {
        functions[i] = @field(builtins, field_name);
    }
    break :builtin_table functions;
};

/// Comptime data structure describing the primitive data nodes in the ir. Type is `ir.Primitives`.
pub const primitives = .{
    // IR-specific instruction operation.
    .operation = Operation,
    // Bytecode instruction opcode; for use in intrinsics and final assembly.
    .opcode = bytecode.Instruction.OpCode,
    // A variant describing the kind of a type.
    .kind_tag = KindTag,
    // An index into a collection, such as a list or array.
    .index = u64,
};

/// Bitwise conversion functions for primitive data nodes.
pub const primitive_converters = struct {
    pub fn operation(op: Operation) u64 {
        return @intFromEnum(op);
    }

    pub fn opcode(op: bytecode.Instruction.OpCode) u64 {
        return @intFromEnum(op);
    }

    pub fn kind_tag(tag: KindTag) u64 {
        return @intFromEnum(tag);
    }

    pub fn index(idx: u64) u64 {
        return idx;
    }
};

/// Comptime data structure describing the kinds of structural nodes in the ir. Type is `ir.Structures`.
pub const structures = .{
    .kind = .{
        .output_tag = .{ .primitive, .kind_tag },
        .input_kinds = .{ .collection, .kind },
    },
    .constructor = .{
        .kind = .{ .structure, .kind },
    },
    .type = .{
        .constructor = .{ .structure, .constructor },
        .input_types = .{ .collection, .type },
    },
    .effect = .{
        .handler_types = .{ .collection, .type },
    },
    .constant = .{
        .type = .{ .structure, .type },
        .value = .any,
    },
    .global = .{
        .type = .{ .structure, .type },
        .initializer = .{ .structure, .constant },
    },
    .local = .{ .type = .{ .structure, .type } },
    .handler = .{
        .parent_block = .{ .structure, .block }, // the block that this handler is alive within
        .function = .{ .structure, .function }, // the function that implements the handler
        .handled_effect = .{ .structure, .effect }, // the effect that this handler can handle
        .cancellation_type = .{ .structure, .type }, // the type that this handler can cancel the effect with
    },
    .function = .{
        .parent_handler = .{ .structure, .handler }, // the handler that this function is a part of, if any
        .body_block = .{ .structure, .block },
        .type = .{ .structure, .type },
    },
    .block = .{
        .parent = .{ .structure, .nil }, // either a block, function, or constant
        .locals = .{ .collection, .local },
        .handlers = .{ .collection, .handler },
        .contents = .{ .collection, .nil }, // a collection of either blocks or instructions
        .type = .{ .structure, .type }, // the type of data yielded by the block
    },
    .instruction = .{
        .parent = .{ .structure, .block }, // the block that contains this instruction
        .operation = .{ .primitive, .operation }, // the operation performed by this instruction
        .type = .{ .structure, .type }, // the type of data yielded by the instruction
    },
    .ctrl_edge = .{
        .source = .{ .structure, .nil }, // either a block or an instruction
        .destination = .{ .structure, .nil }, // either a block or an instruction
        .source_index = .{ .primitive, .index }, // the index of the edge in the source
        .destination_index = .{ .primitive, .index }, // the index of the edge in the destination
    },
    .data_edge = .{
        .source = .{ .structure, .nil }, // either a block or an instruction
        .destination = .{ .structure, .nil }, // either a block or an instruction
        .source_index = .{ .primitive, .index }, // the index of the edge in the source
        .destination_index = .{ .primitive, .index }, // the index of the edge in the destination
    },
    .global_symbol = .{
        .name = .{ .data, .name },
        .node = .any,
    },
    .debug_symbols = .{
        .name = .{ .collection, .name },
        .node = .any,
    },
    .debug_sources = .{
        .source = .{ .collection, .source },
        .node = .any,
    },
    .foreign = .{
        .address = .{ .primitive, .index }, // the address of the foreign function
    },
    .builtin = .{
        .address = .{ .primitive, .index }, // the address of the builtin function
    },
    .intrinsic = .{
        .data = .any, // the data of the intrinsic function; usually, a bytecode opcode
    },
};

/// initializers for builtin constructs. See `ir.Context.Root.getBuiltin`.
pub const builtins = struct {
    pub fn data_kind(ctx: *Context) !Ref {
        return ctx.internStructure(.kind, .{
            .output_tag = try ctx.internPrimitive(KindTag.data),
            .input_kinds = Ref.nil,
        });
    }

    pub fn interned_bytes_constructor(ctx: *Context) !Ref {
        return ctx.internStructure(.constructor, .{
            .kind = try ctx.getBuiltin(.primitive_kind),
        });
    }

    pub fn interned_bytes_type(ctx: *Context) !Ref {
        return ctx.internStructure(.type, .{
            .constructor = try ctx.getBuiltin(.interned_bytes_constructor),
            .input_types = try ctx.internList(.type, &.{}),
        });
    }

    pub fn primitive_kind(ctx: *Context) !Ref {
        return ctx.internStructure(.kind, .{
            .output_tag = try ctx.internPrimitive(KindTag.primitive),
            .input_kinds = Ref.nil,
        });
    }

    pub fn data_type_set_kind(ctx: *Context) !Ref {
        return ctx.builder.type_set_kind(try ctx.getBuiltin(.data_kind));
    }

    pub fn data_type_map_kind(ctx: *Context) !Ref {
        return ctx.builder.type_map_kind(
            try ctx.getBuiltin(.data_type_set_kind),
            try ctx.getBuiltin(.data_type_set_kind),
        );
    }

    pub fn integer_constructor(ctx: *Context) !Ref {
        const k_primitive = try ctx.getBuiltin(.primitive_kind);

        return ctx.internStructure(.constructor, .{
            .kind = try ctx.internStructure(.kind, .{
                .output_tag = try ctx.internPrimitive(KindTag.primitive),
                .input_kinds = try ctx.internList(.kind, &.{ k_primitive, k_primitive }),
            }),
        });
    }

    pub fn symbol_constructor(ctx: *Context) !Ref {
        const k_arrow = try ctx.internStructure(.kind, .{
            .output_tag = try ctx.internPrimitive(KindTag.primitive),
            .input_kinds = try ctx.internList(.kind, &.{try ctx.getBuiltin(.primitive_kind)}),
        });

        return ctx.internStructure(.constructor, .{
            .kind = k_arrow,
        });
    }

    pub fn struct_constructor(ctx: *Context) !Ref {
        return ctx.internStructure(.constructor, .{
            .kind = try ctx.internStructure(.kind, .{
                .output_tag = try ctx.internPrimitive(KindTag.structure),
                .input_kinds = try ctx.internList(.kind, &.{
                    try ctx.getBuiltin(.primitive_kind), // layout
                    try ctx.getBuiltin(.data_type_map_kind), // field names -> types
                }),
            }),
        });
    }

    pub fn c_symbol(ctx: *Context) !Ref {
        return ctx.builder.symbol("c");
    }

    pub fn packed_symbol(ctx: *Context) !Ref {
        return ctx.builder.symbol("packed");
    }
};

pub const Builder = struct {
    fn getContext(self: *Builder) *Context {
        return @alignCast(@fieldParentPtr("builder", self));
    }

    pub fn type_set_kind(self: *Builder, key_kind: Ref) !Ref {
        const ctx = self.getContext();

        return ctx.internStructure(.kind, .{
            .output_tag = try ctx.internPrimitive(KindTag.set),
            .input_kinds = try ctx.internList(.kind, &.{key_kind}),
        });
    }

    pub fn type_map_kind(self: *Builder, key_set_kind: Ref, val_set_kind: Ref) !Ref {
        const ctx = self.getContext();

        return ctx.internStructure(.kind, .{
            .output_tag = try ctx.internPrimitive(KindTag.map),
            .input_kinds = try ctx.internList(.kind, &.{
                key_set_kind,
                val_set_kind,
            }),
        });
    }

    pub fn type_set_constructor(self: *Builder, key_kind: Ref) !Ref {
        const ctx = self.getContext();

        return ctx.internStructure(.constructor, .{
            .kind = try self.type_set_kind(key_kind),
        });
    }

    pub fn type_map_constructor(self: *Builder, key_set_kind: Ref, val_set_kind: Ref) !Ref {
        const ctx = self.getContext();

        return ctx.internStructure(.constructor, .{
            .kind = try self.type_map_kind(key_set_kind, val_set_kind),
        });
    }

    pub fn integer_type(self: *Builder, signedness: pl.Signedness, bit_size: pl.Alignment) !Ref {
        const ctx = self.getContext();

        return ctx.internStructure(.type, .{
            .constructor = try ctx.getBuiltin(.integer_constructor),
            .input_types = try ctx.internList(.type, &.{
                try ctx.internStructure(.constant, .{
                    .type = try ctx.getBuiltin(.interned_bytes_type),
                    .value = try ctx.internBuffer(std.mem.asBytes(&signedness)),
                }),
                try ctx.internStructure(.constant, .{
                    .type = try ctx.getBuiltin(.interned_bytes_type),
                    .value = try ctx.internBuffer(std.mem.asBytes(&bit_size)),
                }),
            }),
        });
    }

    pub fn symbol(self: *Builder, name: []const u8) !Ref {
        const ctx = self.getContext();

        return ctx.internStructure(.type, .{
            .constructor = try ctx.getBuiltin(.symbol_constructor),
            .input_types = try ctx.internList(.type, &.{try ctx.internName(name)}),
        });
    }

    pub fn type_set_type(self: *Builder, key_kind: Ref, keys: []const Ref) !Ref {
        const ctx = self.getContext();

        return ctx.internStructure(.type, .{
            .constructor = try self.type_set_constructor(key_kind),
            .input_types = try ctx.internList(.type, keys),
        });
    }

    pub fn type_map_type(self: *Builder, key_kind: Ref, val_kind: Ref, keys: []const Ref, vals: []const Ref) !Ref {
        const ctx = self.getContext();

        return ctx.internStructure(.type, .{
            .constructor = try self.type_map_constructor(
                try self.type_set_kind(key_kind),
                try self.type_set_kind(val_kind),
            ),
            .input_types = try ctx.internList(.type, &.{
                try self.type_set_type(key_kind, keys),
                try self.type_set_type(val_kind, vals),
            }),
        });
    }

    /// * Note: While the frontend type system uses marker types to distinguish the order of structure fields,
    /// here we do not use unordered sets; thus the order of the lists is used to encode the order.
    /// * The `layout` must be a symbol of the set `{'c, 'packed}`
    pub fn struct_type(self: *Builder, layout: Ref, names: []const Ref, types: []const Ref) !Ref {
        const ctx = self.getContext();

        const k_data = try ctx.getBuiltin(.data_kind);

        return ctx.internStructure(.type, .{
            .constructor = try ctx.getBuiltin(.struct_constructor),
            .input_types = try ctx.internList(.type, &.{
                layout,
                try self.type_map_type(
                    k_data,
                    k_data,
                    names,
                    types,
                ),
            }),
        });
    }
};

/// Performs a depth-first search from a starting node to detect cycles. I.e., if ref is reachable from itself
/// `visiting` is the set of nodes in the current recursion stack.
/// * This function assumes that the caller holds a lock on the context's root mutex
pub fn detectCycle(ctx: *Context, visiting: *RefSet, ref: Ref) !bool {
    if (ref == Ref.nil) return false;

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

const testing = std.testing;

test "ir integration - basic context operations" {
    const gpa = testing.allocator;

    // Create root context
    const ctx = try ir.Context.init(gpa);
    defer ctx.deinit();

    // Test basic node creation
    const int_node = try ctx.addPrimitive(.constant, @as(u64, 42));
    const name_node = try ctx.internName("test_variable");

    // Verify nodes were created
    try testing.expect(int_node != ir.Ref.nil);
    try testing.expect(name_node != ir.Ref.nil);

    // Test data retrieval
    const int_data = ctx.getNodeData(int_node);
    try testing.expect(int_data != null);
    try testing.expectEqual(@as(u64, 42), int_data.?.primitive);

    const name_data = ctx.getNodeData(name_node);
    try testing.expect(name_data != null);
    try testing.expectEqualStrings("test_variable", name_data.?.name);
}

test "ir integration - struct type creation with packed layout" {
    const gpa = testing.allocator;

    // Create root context
    const ctx = try ir.Context.init(gpa);
    defer ctx.deinit();

    // Create basic types for struct fields
    const u32_type = try ctx.builder.integer_type(.unsigned, 32);
    const u16_type = try ctx.builder.integer_type(.unsigned, 16);
    const u8_type = try ctx.builder.integer_type(.unsigned, 8);

    // Create field names
    const field1_name = try ctx.builder.symbol("x");
    const field2_name = try ctx.builder.symbol("y");
    const field3_name = try ctx.builder.symbol("z");

    // Create packed layout symbol
    const packed_layout = try ctx.builder.symbol("packed");

    // Create the struct type with packed layout and three fields
    const field_names = [_]ir.Ref{ field1_name, field2_name, field3_name };
    const field_types = [_]ir.Ref{ u32_type, u16_type, u8_type };

    const struct_type = try ctx.builder.struct_type(packed_layout, &field_names, &field_types);

    // Verify the struct type was created
    try testing.expect(struct_type != ir.Ref.nil);
    try testing.expectEqual(ir.Tag.structure, struct_type.node_kind.getTag());
    try testing.expectEqual(ir.StructureKind.type, ir.discriminants.force(ir.StructureKind, struct_type.node_kind.getDiscriminator()));

    // Verify we can get the constructor and input types
    const constructor = try ctx.getField(struct_type, .constructor) orelse return error.InvalidGraphState;
    const input_types = try ctx.getField(struct_type, .input_types) orelse return error.InvalidGraphState;

    try testing.expect(constructor != ir.Ref.nil);
    try testing.expect(input_types != ir.Ref.nil);

    // Verify the input types list contains our field information
    const children = try ctx.getChildren(input_types);
    try testing.expect(children.len > 0);
}

test "ir integration - interning and node reuse" {
    const gpa = testing.allocator;

    const ctx = try ir.Context.init(gpa);
    defer ctx.deinit();

    // Test primitive interning
    const int1 = try ctx.internPrimitive(@as(u64, 100));
    const int2 = try ctx.internPrimitive(@as(u64, 100));

    // Should be the same reference (interned)
    try testing.expectEqual(int1, int2);

    // Test buffer interning
    const buf1 = try ctx.internBuffer("hello world");
    const buf2 = try ctx.internBuffer("hello world");

    // Should be the same reference (interned)
    try testing.expectEqual(buf1, buf2);

    // Different content should give different references
    const buf3 = try ctx.internBuffer("different");
    try testing.expect(buf1.id.node != buf3.id.node);
}

test "ir integration - user data management" {
    const gpa = testing.allocator;

    const ctx = try ir.Context.init(gpa);
    defer ctx.deinit();

    // Create a test node
    const test_ref = try ctx.addPrimitive(.constant, @as(u64, 42));

    // Get user data for the node
    const userdata = try ctx.getUserData(test_ref);
    try testing.expect(userdata.context == ctx);

    // Test adding custom data
    const test_value: u32 = 12345;
    try userdata.addData(.test_key, @constCast(&test_value));

    // Test retrieving custom data
    const retrieved = userdata.getData(u32, .test_key);
    try testing.expect(retrieved != null);
    try testing.expectEqual(@as(u32, 12345), retrieved.?.*);

    // Test deleting custom data
    userdata.delData(.test_key);
    const after_delete = userdata.getData(*const u32, .test_key);
    try testing.expect(after_delete == null);
}

test "ir integration - list and collection operations" {
    const gpa = testing.allocator;

    const ctx = try ir.Context.init(gpa);
    defer ctx.deinit();

    // Create some test references
    const ref1 = try ctx.addPrimitive(.constant, @as(u64, 1));
    const ref2 = try ctx.addPrimitive(.constant, @as(u64, 2));
    const ref3 = try ctx.addPrimitive(.constant, @as(u64, 3));

    const refs = [_]ir.Ref{ ref1, ref2, ref3 };

    // Create a list
    const list_ref = try ctx.addList(.constant, .index, &refs);
    try testing.expect(list_ref != ir.Ref.nil);
    try testing.expectEqual(ir.Tag.collection, list_ref.node_kind.getTag());

    // Get children from the list
    const children = try ctx.getChildren(list_ref);
    try testing.expectEqual(@as(u64, 3), children.len);
    try testing.expectEqual(ref1, children[0]);
    try testing.expectEqual(ref2, children[1]);
    try testing.expectEqual(ref3, children[2]);

    // Test interned list
    const interned_list = try ctx.internList(.index, &refs);
    try testing.expect(interned_list != ir.Ref.nil);

    // Create the same list again - should be interned
    const interned_list2 = try ctx.internList(.index, &refs);
    try testing.expectEqual(interned_list, interned_list2);
}

test "ir integration - builtin types and operations" {
    const gpa = testing.allocator;

    const ctx = try ir.Context.init(gpa);
    defer ctx.deinit();

    // Test getting builtin kinds
    const data_kind = try ctx.getBuiltin(.data_kind);
    const primitive_kind = try ctx.getBuiltin(.primitive_kind);

    try testing.expect(data_kind != ir.Ref.nil);
    try testing.expect(primitive_kind != ir.Ref.nil);

    // Test integer type creation
    const i32_type = try ctx.builder.integer_type(.signed, 32);
    const u64_type = try ctx.builder.integer_type(.unsigned, 64);

    try testing.expect(i32_type != ir.Ref.nil);
    try testing.expect(u64_type != ir.Ref.nil);

    // Different types should have different references
    try testing.expect(i32_type.id.node != u64_type.id.node);

    // Test symbol type creation
    const symbol_type = try ctx.builder.symbol("my_symbol");
    try testing.expect(symbol_type != ir.Ref.nil);
}

test "ir integration - discriminant utilities" {
    const data_disc: ir.Discriminator = .name;
    const data_kind = ir.discriminants.cast(ir.DataKind, data_disc);
    try testing.expect(data_kind != null);
    try testing.expectEqual(ir.DataKind.name, data_kind.?);

    const prim_disc: ir.Discriminator = .operation;
    const prim_kind = ir.discriminants.cast(ir.PrimitiveKind, prim_disc);
    try testing.expect(prim_kind != null);
    try testing.expectEqual(ir.PrimitiveKind.operation, prim_kind.?);

    // Test invalid conversion
    const invalid = ir.discriminants.cast(ir.DataKind, prim_disc);
    try testing.expect(invalid == null);

    // Test force conversion
    const forced = ir.discriminants.force(ir.DataKind, data_disc);
    try testing.expectEqual(ir.DataKind.name, forced);
}

test "ir integration - node kind operations" {
    const data_kind = ir.NodeKind.data(.name);
    try testing.expectEqual(ir.Tag.data, data_kind.getTag());
    try testing.expectEqual(ir.DataKind.name, ir.discriminants.force(ir.DataKind, data_kind.getDiscriminator()));

    const prim_kind = ir.NodeKind.primitive(.operation);
    try testing.expectEqual(ir.Tag.primitive, prim_kind.getTag());
    try testing.expectEqual(ir.PrimitiveKind.operation, ir.discriminants.force(ir.PrimitiveKind, prim_kind.getDiscriminator()));

    const struct_kind = ir.NodeKind.structure(.type);
    try testing.expectEqual(ir.Tag.structure, struct_kind.getTag());
    try testing.expectEqual(ir.StructureKind.type, ir.discriminants.force(ir.StructureKind, struct_kind.getDiscriminator()));

    const coll_kind = ir.NodeKind.collection(.index);
    try testing.expectEqual(ir.Tag.collection, coll_kind.getTag());
    try testing.expectEqual(ir.Discriminator.index, coll_kind.getDiscriminator());
}

test "ir integration - child context creation" {
    const gpa = testing.allocator;

    const root_ctx = try ir.Context.init(gpa);
    defer root_ctx.deinit();

    // Create child context
    const child_ctx = try root_ctx.inner.root.createContext();

    // Verify child context properties
    try testing.expect(!child_ctx.isRoot());
    try testing.expectEqual(root_ctx, child_ctx.getRootContext());
    try testing.expect(child_ctx.id.toInt() != 0);

    // Test that we can create nodes in child context
    const test_node_in_child = try child_ctx.addPrimitive(.constant, @as(u64, 999));
    try testing.expect(test_node_in_child != ir.Ref.nil);
    try testing.expectEqual(child_ctx.id, test_node_in_child.id.context);

    // Destroy this child context before we test merging with a new one
    {
        const root = root_ctx.asRoot().?;
        root.mutex.lock();
        root.destroyContext(child_ctx.id);
        root.mutex.unlock();
    }
}

test "ir integration - merging child context into root" {
    const gpa = testing.allocator;

    const root_ctx = try ir.Context.init(gpa);
    defer root_ctx.deinit();

    // Create child context
    const child_ctx = try root_ctx.asRoot().?.createContext();
    const child_id = child_ctx.id;

    // Populate root and child contexts with a mix of shared and unique nodes
    const root_shared_node = try root_ctx.internPrimitive(@as(u64, 42));

    const child_unique_node = try child_ctx.internPrimitive(@as(u64, 123));
    const child_shared_node = try child_ctx.internPrimitive(@as(u64, 42)); // Same content as root_shared_node

    // Create a list in the child that references other child nodes
    const child_list_refs = [_]ir.Ref{ child_unique_node, child_shared_node };
    const child_list = try child_ctx.internList(.index, &child_list_refs);

    // Add UserData to the list node in the child context
    const child_userdata_val: u32 = 54321;
    // An enum literal is needed for the key
    const child_userdata = try child_ctx.getUserData(child_list);
    try child_userdata.addData(.test_key, @constCast(&child_userdata_val));

    // Perform the merge
    {
        const root = root_ctx.asRoot().?;
        root.mutex.lock();
        // Don't defer unlock here, merge might call functions that need the lock
        try root.merge(child_ctx);
        root.mutex.unlock();
    }

    // Verify child context was destroyed by checking if it's still in the root's map
    {
        const root = root_ctx.asRoot().?;
        root.mutex.lock();
        defer root.mutex.unlock();
        try testing.expect(root.getContext(child_id) == null);
    }

    // Find the nodes in the root context and verify their new refs
    const merged_unique_node = try root_ctx.internPrimitive(@as(u64, 123));
    const merged_shared_node = try root_ctx.internPrimitive(@as(u64, 42));

    // The unique node should now be in the root context
    try testing.expectEqual(root_ctx.id, merged_unique_node.id.context);

    // The shared node should have been mapped to the pre-existing root node
    try testing.expectEqual(root_shared_node, merged_shared_node);

    // Find the merged list and verify its children and UserData
    const merged_list_refs = [_]ir.Ref{ merged_unique_node, merged_shared_node };
    const merged_list = try root_ctx.internList(.index, &merged_list_refs);

    // The list itself should now be in the root context
    try testing.expectEqual(root_ctx.id, merged_list.id.context);

    // Check its children to ensure refs were remapped
    const children = try root_ctx.getChildren(merged_list);
    try testing.expectEqual(2, children.len);
    try testing.expectEqual(merged_unique_node, children[0]);
    try testing.expectEqual(merged_shared_node, children[1]);

    // Check that its UserData was transferred
    const merged_userdata = try root_ctx.getUserData(merged_list);
    const retrieved_data = merged_userdata.getData(u32, .test_key);
    try testing.expect(retrieved_data != null);
    try testing.expectEqual(child_userdata_val, retrieved_data.?.*);
}

test "ir integration - merging child context with cyclic nodes" {
    const gpa = testing.allocator;

    const root_ctx = try ir.Context.init(gpa);
    defer root_ctx.deinit();

    // Create a child context to build our cyclic graph in.
    const child_ctx = try root_ctx.asRoot().?.createContext();
    const child_id = child_ctx.id;

    // --- Create a cyclic graph in the child context ---
    // This graph represents a simple loop: loop_header -> loop_body -> loop_header

    const type_type = try child_ctx.internStructure(.type, .{
        .constructor = ir.Ref.nil,
        .input_types = ir.Ref.nil,
    });
    const op_branch = try child_ctx.internPrimitive(ir.Operation.unconditional_branch);
    const zero = try child_ctx.internPrimitive(@as(u64, 0));

    // 1. Create two blocks: a loop header and a loop body.
    const loop_header = try child_ctx.addStructure(.mutable, .block, .{
        .parent = ir.Ref.nil,
        .locals = ir.Ref.nil,
        .handlers = ir.Ref.nil,
        .contents = ir.Ref.nil,
        .type = type_type,
    });
    const loop_body = try child_ctx.addStructure(.mutable, .block, .{
        .parent = ir.Ref.nil,
        .locals = ir.Ref.nil,
        .handlers = ir.Ref.nil,
        .contents = ir.Ref.nil,
        .type = type_type,
    });

    // 2. Create the instruction in the header that branches to the body.
    const branch_to_body_inst = try child_ctx.addStructure(.mutable, .instruction, .{
        .parent = loop_header,
        .operation = op_branch,
        .type = type_type,
    });
    const branch_to_body_edge = try child_ctx.addStructure(.mutable, .ctrl_edge, .{
        .source = branch_to_body_inst,
        .destination = loop_body, // Header -> Body
        .source_index = zero,
        .destination_index = zero,
    });

    // 3. Create the instruction in the body that branches back to the header (the loop).
    const branch_to_header_inst = try child_ctx.addStructure(.mutable, .instruction, .{
        .parent = loop_body,
        .operation = op_branch,
        .type = type_type,
    });
    const branch_to_header_edge = try child_ctx.addStructure(.mutable, .ctrl_edge, .{
        .source = branch_to_header_inst,
        .destination = loop_header, // Body -> Header <--- The cyclic reference!
        .source_index = zero,
        .destination_index = zero,
    });

    // To make the graph fully connected, populate the blocks' contents.
    const header_contents = try child_ctx.addList(.mutable, .instruction, &.{branch_to_body_inst});
    try child_ctx.setField(loop_header, .contents, header_contents);

    const body_contents = try child_ctx.addList(.mutable, .instruction, &.{branch_to_header_inst});
    try child_ctx.setField(loop_body, .contents, body_contents);

    // Suppress "unused variable" warnings. Their creation and linking into the graph
    // via other nodes is their purpose.
    _ = branch_to_body_edge;
    _ = branch_to_header_edge;

    // At this point, `child_ctx` contains a clear cyclic graph:
    // loop_header -> branch_to_body_inst -> branch_to_body_edge -> loop_body
    // loop_body   -> branch_to_header_inst -> branch_to_header_edge -> loop_header

    // Perform the merge. The old implementation would stack overflow.
    {
        const root = root_ctx.asRoot().?;
        root.mutex.lock();
        try root.merge(child_ctx);
        root.mutex.unlock();
    }

    // --- Verification in the Root Context ---
    try testing.expect(root_ctx.asRoot().?.getContext(child_id) == null);

    // Find the merged blocks. We'll identify them by their structure.
    var merged_blocks = std.ArrayList(ir.Ref).init(gpa);
    defer merged_blocks.deinit();

    var root_it = root_ctx.nodes.keyIterator();
    while (root_it.next()) |ref| {
        if (ref.node_kind.getTag() == .structure and
            ir.discriminants.force(ir.StructureKind, ref.node_kind.getDiscriminator()) == .block)
        {
            try merged_blocks.append(ref.*);
        }
    }
    try testing.expectEqual(@as(usize, 2), merged_blocks.items.len);

    // We don't know the order, so we find the header by looking for the one
    // that is the destination of the other's edge.
    const block_A = merged_blocks.items[0];
    const block_B = merged_blocks.items[1];

    const getBranchDest = struct {
        fn getBranchDest(ctx: *ir.Context, block_ref: ir.Ref) !ir.Ref {
            const contents_list_ref = try ctx.getField(block_ref, .contents) orelse return error.TestFailed;
            const contents = try ctx.getChildren(contents_list_ref);
            const inst_ref = contents[0];
            const users = try ctx.getNodeUsers(inst_ref);

            // Iterate users to find the actual control edge, since the instruction
            // is also used by the block's `contents` list.
            var edge_ref: ?ir.Ref = null;
            var it = users.keyIterator();
            while (it.next()) |use| {
                if (use.ref.node_kind.getTag() == .structure and
                    ir.discriminants.force(ir.StructureKind, use.ref.node_kind.getDiscriminator()) == .ctrl_edge)
                {
                    edge_ref = use.ref;
                    break;
                }
            }

            if (edge_ref == null) {
                log.debug("Could not find control edge user for instruction {}", .{inst_ref});
                return error.TestFailed;
            }

            return try ctx.getField(edge_ref.?, .destination) orelse return error.TestFailed;
        }
    }.getBranchDest;

    const dest_of_A = try getBranchDest(root_ctx, block_A);
    const dest_of_B = try getBranchDest(root_ctx, block_B);

    var merged_header: ir.Ref = undefined;
    var merged_body: ir.Ref = undefined;

    if (dest_of_A == block_B and dest_of_B == block_A) {
        // This is the cycle we expect. Arbitrarily assign.
        merged_header = block_A;
        merged_body = block_B;
    } else {
        return error.TestFailed;
    }
}

test "ir integration - immutable nodes cannot reference mutable nodes" {
    const gpa = testing.allocator;
    const ctx = try ir.Context.init(gpa);
    defer ctx.deinit();

    // 1. Create a mutable node.
    // This will be the reference that our immutable nodes will illegally point to.
    const mutable_list = try ctx.addList(.mutable, .nil, &.{});

    // 2. Define the structure for our test nodes.
    const illegal_struct_value = .{
        .data = mutable_list, // <-- The illegal reference
    };

    // 3. Test failure case 1: Trying to create a non-interned, but immutable, node.
    // We expect this to fail because illegal_struct_value.contents points to a mutable ref.
    // The internal call to _addNode should trigger _ensureConstantRefs, which should fail.
    const immutable_add_result = ctx.addStructure(.constant, .intrinsic, illegal_struct_value);
    try testing.expectError(error.ImmutableNodeReferencesMutable, immutable_add_result);

    // 4. Test failure case 2: Trying to intern a node.
    // We expect this to also fail for the same reason.
    // The internal call to _internNode should trigger _ensureConstantRefs, which should fail.
    const intern_result = ctx.internStructure(.intrinsic, illegal_struct_value);
    try testing.expectError(error.ImmutableNodeReferencesMutable, intern_result);

    // 5. Sanity Check: Confirm that creating a mutable version of the same node SUCCEEDS.
    // This ensures our test isn't failing for some other reason.
    const mutable_add_result = ctx.addStructure(.mutable, .intrinsic, illegal_struct_value);
    try testing.expect(mutable_add_result != error.ImmutableNodeReferencesMutable);
    const success_ref = try mutable_add_result;
    try testing.expect(success_ref != ir.Ref.nil);
}
