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
const utils = @import("utils");
const source = @import("source");
const Source = source.Source;
const bytecode = @import("bytecode");

test {
    std.testing.refAllDeclsRecursive(@This());
}


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
        }
    } = .{ .root = .{} },
    /// general purpose allocator for the context, used for collections and the following arena.
    gpa: std.mem.Allocator,
    /// arena allocator for the context, used for data nodes.
    arena: std.heap.ArenaAllocator,
    /// contains all graph nodes in this context.
    nodes: pl.UniqueReprMap(LocalRef, Node, 80) = .empty,
    /// Maps constant value nodes to references.
    interner: pl.HashMap(Node, LocalRef, NodeHasher, 80) = .empty,
    /// Flags whether a node is interned or not.
    interned_refs: pl.UniqueReprSet(LocalRef, 80) = .empty,
    /// Used to generate context-unique ids for nodes.
    fresh_node: NodeId = .fromInt(1),

    /// The root context state.
    pub const Root = struct {
        /// Used to generate unique ids for child contexts.
        fresh_ctx: ContextId = .fromInt(1),
        /// All child contexts owned by this root context.
        children: pl.UniqueReprMap(ContextId, *Context, 80) = .empty,
        /// Maps specific refs to user defined data, used for miscellaneous operations like layout computation, display, etc.
        userdata: pl.UniqueReprMap(Ref, *UserData, 80) = .empty,
        /// Maps builtin structures to their definition references.
        builtin: pl.UniqueReprMap(Builtin, Ref, 80) = .empty,

        /// Get a pointer to the Context this Root is stored in.
        pub fn getRootContext(self: *Root) *Context {
            const inner: *@FieldType(Context, "inner") = @fieldParentPtr("root", self);
            return @fieldParentPtr("inner", inner);
        }

        /// Deinitialize the root context, freeing all memory it owns.
        pub fn deinit(self: *Root, gpa: std.mem.Allocator) void {
            var it = self.children.valueIterator();
            while (it.next()) |child_ptr| child_ptr.*.deinit();

            var arena = self.getRootContext().arena;
            arena.deinit();
            _ = self.children.deinit(gpa);
        }

        /// Get the ref associated with a builtin identity.
        ///
        /// **IMPORTANT**
        /// * Unlike the frontend language, this requires canonicalization of the order of set and map types.
        /// * While the frontend type system uses marker types to distinguish the layout of structure fields,
        /// here we do not use unordered sets; thus the order of the lists is used to encode the layout.
        pub fn getBuiltin(self: *Root, comptime builtin: Builtin, args: anytype) !Ref {
            const ctx = self.getRootContext();
            const gop = try self.builtin.getOrPut(ctx.gpa, builtin);

            if (!gop.found_existing) {
                const initializer = @field(builtins, @tagName(builtin));

                gop.value_ptr.* = try @call(.auto, initializer, .{ self.getRootContext() } ++ args);
            }

            return gop.value_ptr.*;
        }

        /// Get the userdata for a specific reference.
        pub fn getUserData(self: *Root, ref: Ref) !*UserData {
            const ctx = self.getRootContext();
            const gop = try self.userdata.getOrPut(ctx.gpa, ref);

            if (!gop.found_existing) {
                const addr = try ctx.gpa.create(UserData);
                addr.* = .{ .context = ctx };
                gop.value_ptr.* = addr;
            }

            return gop.value_ptr.*;
        }

        /// Delete a userdata for a specific reference.
        pub fn delUserData(self: *Root, ref: Ref) void {
            _ = self.userdata.remove(ref);
        }

        /// Create a new context.
        pub fn createContext(self: *Root) !*Context {
            const ctx = self.getRootContext();

            var arena = std.heap.ArenaAllocator.init(ctx.gpa);
            errdefer arena.deinit();

            const child = try arena.allocator().create(Context);

            child.* = Context{
                .id = ctx.inner.root.fresh_ctx.next(),
                .inner = .{ .child = .{ .root = ctx } },
                .gpa = ctx.gpa,
                .arena = arena,
            };

            try child.nodes.ensureTotalCapacity(ctx.gpa, 16384);

            return child;
        }

        /// Destroy a context by its id.
        pub fn destroyContext(self: *Root, id: ContextId) void {
            const child = self.children.get(id) orelse return;
            child.destroy();
            _ = self.children.remove(id);
        }

        /// Get a context by its id.
        pub fn getContext(self: *Root, id: ContextId) ?*Context {
            return self.children.get(id);
        }
    };

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
        self.nodes.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    /// Destroy the context, freeing all memory it owns.
    /// * This is called by `Context.deinit` in roots, and by `Root.destroyContext` for child contexts.
    fn destroy(self: *Context) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |node| node.deinit(self.gpa);
        var arena = self.arena;
        arena.deinit();
    }

    /// Deinitialize the context, freeing all memory it owns.
    pub fn deinit(self: *Context) void {
        switch (self.inner) {
            .child => {
                self.getRoot().destroyContext(self.id);
            },
            .root => |*root| {
                root.deinit(self.gpa);

                self.destroy();
            }
        }
    }

    /// Generate a unique id.
    pub fn genId(self: *Context) Id {
        return Id { .context = self.id, .node = self.fresh_node.next() };
    }

    /// Determine if this context is a root context.
    pub fn isRoot(self: *Context) bool {
        return self.inner == .root;
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

    /// Intern a node within the context, returning a reference to it.
    /// * This performs no validation on the node kind or value.
    /// * If the node already exists in this context, it will return the existing reference.
    /// * Modifying nodes added this way is unsafe.
    pub fn internLocalUnchecked(self: *Context, node: Node) !Ref {
        const gop = try self.interner.getOrPut(self.gpa, node);

        if (!gop.found_existing) {
            gop.value_ptr.* = (try self.addLocalUnchecked(node)).local;

            try self.interned_refs.put(self.gpa, gop.value_ptr.*, {});
        }

        return Ref { .context = self, .local = gop.value_ptr.* };
    }

    /// Add a node to the context, returning a reference to it.
    /// * This performs no validation on the node kind or value.
    pub fn addLocalUnchecked(self: *Context, node: Node) !Ref {
        const local_ref = LocalRef{
            .node_kind = node.kind,
            .id = self.genId(),
        };

        try self.nodes.put(self.gpa, local_ref, node);

        return Ref { .context = self, .local = local_ref };
    }

    /// Delete a node from the context, given its reference.
    /// * This will deinitialize the node, freeing any memory it owns.
    /// * Nodes relying on this node will be invalidated.
    /// * If the node does not exist, this is a no-op.
    /// * If the node is interned, this is a no-op.
    pub fn delLocal(self: *Context, ref: LocalRef) void {
        if (self.interned_refs.contains(ref)) {
            log.debug("Tried to delete an interned node: {}", .{ref});
            return;
        }

        const node = self.nodes.getPtr(ref) orelse return;
        node.deinit(self.gpa);
        _ = self.nodes.remove(ref);
    }

    /// Get an immutable pointer to raw node data, given its reference.
    pub fn getLocal(self: *Context, ref: LocalRef) ?*const Data {
        return &(self.nodes.getPtr(ref) orelse return null).data;
    }

    /// Get a mutable pointer to raw node data, given its reference.
    /// * This will return null if the node is interned, as interned nodes are immutable.
    pub fn getLocalMut(self: *Context, ref: LocalRef) ?*Data {
        const node = self.nodes.getPtr(ref) orelse return null;

        if (self.interned_refs.contains(ref)) {
            log.debug("Tried to get mutable pointer to an interned node: {}", .{ref});
            return null;
        }

        return &node.data;
    }

    /// Intern a data buffer in the context.
    /// * If the buffer already exists in this context, it will return the existing reference.
    /// * Modifying nodes added this way is unsafe.
    pub fn internLocalBuffer(self: *Context, value: []const u8) !Ref {
        const gop = try self.interner.getOrPutAdapted(self.gpa, value, BufferHasher);

        if (!gop.found_existing) {
            var arr = try pl.ArrayList(u8).initCapacity(self.gpa, value.len);
            errdefer arr.deinit(self.gpa);

            arr.appendSliceAssumeCapacity(value);

            var node = try data(.buffer, arr);
            errdefer node.deinit(self.gpa);

            gop.value_ptr.* = (try self.addLocalUnchecked(node)).local;

            try self.interned_refs.put(self.gpa, gop.value_ptr.*, {});
        }

        return Ref { .context = self, .local = gop.value_ptr.* };
    }

    /// Intern a ref list in the context.
    /// * If the list already exists in this context, it will return the existing reference.
    /// * Modifying nodes added this way is unsafe.
    pub fn internLocalList(self: *Context, comptime element_kind: Discriminator, value: []const Ref) !Ref {
        const gop = try self.interner.getOrPutAdapted(self.gpa, value, ListHasher(element_kind));

        if (!gop.found_existing) {
            var arr = try pl.ArrayList(Ref).initCapacity(self.gpa, value.len);
            errdefer arr.deinit(self.gpa);

            arr.appendSliceAssumeCapacity(value);

            var node = Node {
                .kind = NodeKind.collection(element_kind),
                .data = .{ .ref_list = arr },
            };
            errdefer node.deinit(self.gpa);

            gop.value_ptr.* = (try self.addLocalUnchecked(node)).local;

            try self.interned_refs.put(self.gpa, gop.value_ptr.*, {});
        }

        return Ref { .context = self, .local = gop.value_ptr.* };
    }

    /// Intern a data node in the context, given a data kind and data.
    /// * If the node already exists in this context, it will return the existing reference.
    /// * Modifying nodes added this way is unsafe.
    /// * Prefer `internLocalBuffer` for buffer data, as it is more efficient and avoids ownership issues.
    pub fn internLocalData(self: *Context, comptime kind: DataKind, value: DataType(kind)) !Ref {
        var node = try data(kind, value);
        errdefer node.deinit(self.gpa);

        return self.internLocalUnchecked(node);
    }

    /// Intern a structure node in the context, given a structure kind and an initializer.
    /// * The initializer must be a struct with the same fields as the structure kind. See `ir.structure`.
    /// * If the node already exists in this context, it will return the existing reference.
    /// * Modifying nodes added this way is unsafe.
    pub fn internLocalStructure(self: *Context, comptime kind: StructureKind, value: anytype) !Ref {
        var node = try structure(self.gpa, kind, value);
        errdefer node.deinit(self.gpa);

        return self.internLocalUnchecked(node);
    }

    /// Create a new data node in the context, given a data kind and data.
    pub fn addLocalData(self: *Context, comptime kind: DataKind, value: DataType(kind)) !Ref {
        var node = try data(kind, value);
        errdefer node.deinit(self.gpa);

        return self.addLocalUnchecked(node);
    }

    /// Create a new structure node in the context, given a structure kind and an initializer.
    /// * The initializer must be a struct with the same fields as the structure kind. See `ir.structure`.
    pub fn addLocalStructure(self: *Context, comptime kind: StructureKind, value: anytype) !Ref {
        var node = try structure(self.gpa, kind, value);
        errdefer node.deinit(self.gpa);

        return self.addLocalUnchecked(node);
    }
};

/// Create a data node outside of a context, given a data kind and data.
pub fn data(comptime kind: DataKind, value: DataType(kind)) !Node {
    return Node {
        .kind = NodeKind.data(kind),
        .data = @unionInit(Data, @tagName(kind), value),
    };
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

                if (init_value.local.node_kind == node_kind) {
                    ref_list.appendAssumeCapacity(init_value);
                } else {
                    log.debug("Unexpected node kind for structure {s} field decl {s}: expected {}, got {}", .{
                        struct_name,
                        decl.name,
                        node_kind,
                        init_value.local.node_kind,
                    });

                    return error.InvalidNodeKind;
                }
            },
            else => @compileError("Unexpected type for structure " ++ struct_name ++ " field decl " ++ decl.name ++ ": " ++ @typeName(decl.type)),
        }
    }

    return Node{
        .kind = NodeKind.structure(kind),
        .data = .{
            .ref_list = ref_list,
        },
    };
}

/// Combines a `LocalRef` to a node in an ir context with a reference to the context itself.
pub const Ref = packed struct(u128) {
    /// The context this reference is bound to.
    /// * This has to be type erased due to zig compiler limitations wrt comptime eval;
    /// it is always of type `?*ir.Context`.
    context: ?*anyopaque,
    /// The inner reference to the node in the context.
    local: LocalRef,

    /// The nil reference, a placeholder for an invalid or irrelevant reference.
    pub const nil = Ref { .context = null, .local = .nil };

    /// Cast the Ref to a Context pointer.
    pub fn getContext(self: Ref) ?*Context {
        return @alignCast(@ptrCast(self.context));
    }

    /// Get a field of a structure data node bound by this reference.
    pub fn getField(self: Ref, comptime field: anytype) !Ref {
        const context = self.getContext() orelse return error.InvalidReference;

        return self.local.getField(context, field);
    }

    /// Get a ref list from a structure or list node bound by this reference.
    pub fn getChildren(self: Ref) ![]const Ref {
        const context = self.getContext() orelse return error.InvalidReference;

        std.debug.assert(self.local.node_kind.getTag() == .structure or self.local.node_kind.getTag() == .collection);

        const local_data = context.getLocal(self.local) orelse return error.InvalidReference;

        return local_data.ref_list.items;
    }

    /// Get the userdata for the node bound by this reference.
    pub fn getUserData(self: Ref) !*UserData {
        const context = self.getContext() orelse return error.InvalidReference;

        const root = context.getRoot();
        const userdata = try root.getUserData(self);

        return userdata;
    }

    /// Delete the userdata for the node bound by this reference.
    pub fn delUserData(self: Ref) void {
        const context = self.getContext() orelse return;

        const root = context.getRoot();
        root.delUserData(self);
    }

    /// `std.fmt` impl
    pub fn format(self: Ref, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
        const context = self.getContext() orelse return error.InvalidReference;

        const node_data = context.getLocal(self.local) orelse return error.InvalidReference;

        const userdata = try context.getRoot().getUserData(self);

        if (userdata.display) |display_fn| {
            try display_fn(node_data, writer.any());
        } else {
            try std.fmt.format(writer, "Ref({}, {d})", .{self.local.node_kind, self.local.id});
        }
    }
};

/// A reference to a node in an ir context; unlike `Ref`,
/// this does not bind the context it is contained within.
pub const LocalRef = packed struct (u64) {
    /// The kind of the node bound by this reference.
    node_kind: NodeKind,
    /// The unique id of the node in the context.
    id: Id,

    /// The nil reference, a placeholder for an invalid or irrelevant reference.
    pub const nil = LocalRef { .node_kind = .nil, .id = .nil };

    /// Get a field of a structure data node bound by this reference.
    pub fn getField(self: LocalRef, context: *Context, comptime field: anytype) !Ref {
        const field_name = comptime @tagName(field);

        std.debug.assert(self.node_kind.getTag() == .structure);

        const local_data = context.getLocal(self) orelse return error.InvalidReference;

        const structure_kind: StructureKind = @enumFromInt(@intFromEnum(self.node_kind.getDiscriminator()));

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

        unreachable;
    }
};

/// Uniquely identifies a child context in an ir.
pub const ContextId = common.Id.ofSize(Context, 16);
/// Uniquely identifies a node in an unknown ir context.
pub const NodeId = common.Id.ofSize(Node, 32);

/// Uniquely identifies a node in a specific ir context.
pub const Id = packed struct {
    /// The context this node is bound to.
    context: ContextId,
    /// The unique id of the node in the context.
    node: NodeId,

    /// The nil id, a placeholder for an invalid or irrelevant id.
    pub const nil = Id {
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
    pub const nil = NodeKind { .tag = @intFromEnum(Tag.nil), .discriminator = 0 };

    /// Create a new node kind with a data tag and the given data kind as its discriminator.
    pub fn data(discriminator: DataKind) NodeKind {
        return NodeKind { .tag = @intFromEnum(Tag.data), .discriminator = @intFromEnum(discriminator) };
    }

    /// Create a new node kind with a structure tag and the given structure kind as its discriminator.
    pub fn structure(discriminator: StructureKind) NodeKind {
        return NodeKind { .tag = @intFromEnum(Tag.structure), .discriminator = @intFromEnum(discriminator) };
    }

    /// Create a new node kind with a collection tag and the given discriminator.
    pub fn collection(discriminator: Discriminator) NodeKind {
        return NodeKind { .tag = @intFromEnum(Tag.collection), .discriminator = @intFromEnum(discriminator) };
    }

    /// Extract the tag bits of the node kind.
    pub fn getTag(self: NodeKind) Tag {
        return @enumFromInt(self.tag);
    }

    /// Extract the discriminator bits of the node kind.
    pub fn getDiscriminator(self: NodeKind) Discriminator {
        return @enumFromInt(self.discriminator);
    }
};

/// The tag of a node, which indicates the overall node shape, be it data, structure, or collection.
pub const Tag = enum(u3) {
    /// The tag for an empty or invalid node.
    /// Discriminator is ignored, and should always be initialized to nil.
    nil,
    /// The tag for a node that contains unstructured data, such as a name, source, or operation.
    /// Discriminator always carries a specific kind, such as `name`, `source`, or `operation`.
    data,
    /// The tag for a node that contains a structure, such as a function, block, or instruction.
    /// Discriminator always carries a specific kind, such as `type`, `effect`, or `function`.
    structure,
    /// The tag for a node that is simply a list of other nodes.
    /// Discriminator may carry a specific kind, or nil to indicate a heterogeneous collection.
    collection,
};

/// The discriminator of a node, which indicates the specific kind of value it contains.
/// * Variant names are the field names of `ir.structures` and `ir.Data`, as well as `nil`.
pub const Discriminator: type = Discriminator: {
    const data_fields = std.meta.fieldNames(Data);
    const structure_fields = std.meta.fieldNames(Structures);

    var fields = [1]std.builtin.Type.EnumField {undefined} ** (structure_fields.len + data_fields.len + 1);
    fields[0] = .{ .name = "nil", .value = 0 };

    var i = 1;

    for (data_fields[0..], 0..) |field, j| {
        fields[i] = .{ .name = field, .value = j + 1000 };
        i += 1;
    }

    for (structure_fields[0..], 0..) |field, j| {
        fields[i] = .{ .name = field, .value = j + 2000 };
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
/// * Variant names are the field names of `ir.Data` without `ref_list`, as well as `nil`.
pub const DataKind: type = DataKind: {
    const data_fields = std.meta.fieldNames(Data);

    var fields = [1]std.builtin.Type.EnumField {undefined} ** data_fields.len;
    fields[0] = .{ .name = "nil", .value = 0 };

    for(data_fields[0..data_fields.len - 1], 1..) |field_name, i| {
        fields[i] = .{
            .name = field_name,
            .value = i + 1000,
        };
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

/// The kind of structures that can be stored in a `Structure` node.
/// * Variant names are the field names of `ir.structures`, as well as `nil`.
pub const StructureKind: type = Structure: {
    const generated_fields = std.meta.fieldNames(Structures);

    var fields = [1]std.builtin.Type.EnumField {undefined} ** (generated_fields.len + 1);

    fields[0] = .{ .name = "nil", .value = 0 };

    for (generated_fields, 1..) |field_name, i| {
        fields[i] = .{
            .name = field_name,
            .value = 2000 + i,
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

/// The type of the ir structures definition structure.
pub const Structures: type = @TypeOf(structures);

/// Comptime data structure describing the kinds of structural nodes in the ir. Type is `ir.Structures`.
pub const structures = .{
    .kind = .{
        .output_tag = .{ .data, .kind_tag },
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
        .initializer = .{ .structure, .constant }
    },
    .local = .{
        .type = .{ .structure, .type }
    },
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
        .operation = .{ .data, .operation }, // the operation performed by this instruction
        .type = .{ .structure, .type }, // the type of data yielded by the instruction
    },
    .ctrl_edge = .{
        .source = .{ .structure, .nil }, // either a block or an instruction
        .destination = .{ .structure, .nil }, // either a block or an instruction
        .source_index = .{ .data, .index }, // the index of the edge in the source
        .destination_index = .{ .data, .index }, // the index of the edge in the destination
    },
    .data_edge = .{
        .source = .{ .structure, .nil }, // either a block or an instruction
        .destination = .{ .structure, .nil }, // either a block or an instruction
        .source_index = .{ .data, .index }, // the index of the edge in the source
        .destination_index = .{ .data, .index }, // the index of the edge in the destination
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
        .address = .{ .data, .index }, // the address of the foreign function
    },
    .builtin = .{
        .address = .{ .data, .index }, // the address of the builtin function
    },
    .intrinsic = .{
        .data = .{ .data, .nil }, // the data of the intrinsic function; usually, a bytecode opcode
    },
};

/// 64-bit context providing eql and hash functions for `Node` types.
/// This is used by the interner to map constant value nodes to their references.
pub const NodeHasher = struct {
    pub fn eql(_: @This(), a: Node, b: Node) bool {
        if (a.kind != b.kind) return false;

        return switch (a.kind.getDiscriminator()) {
            .nil => true,
            .name => std.mem.eql(u8, a.data.name, b.data.name),
            .source => a.data.source.eql(&b.data.source),
            .buffer => std.mem.eql(u8, a.data.buffer.items, b.data.buffer.items),
            .operation => a.data.operation == b.data.operation,
            .opcode => a.data.opcode == b.data.opcode,
            .index => a.data.index == b.data.index,
            .kind_tag => a.data.kind_tag == b.data.kind_tag,
            else => std.mem.eql(Ref, a.data.ref_list.items, b.data.ref_list.items),
        };
    }

    pub fn hash(_: @This(), n: Node) u64 {
        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(std.mem.asBytes(&n.kind));

        switch (n.kind.getDiscriminator()) {
            .nil => hasher.update(&.{0}),
            .name => hasher.update(n.data.name),
            .source => {
                hasher.update(n.data.source.name);
                hasher.update(std.mem.asBytes(&n.data.source.location));
            },
            .buffer => hasher.update(n.data.buffer.items),
            .operation => hasher.update(std.mem.asBytes(&n.data.operation)),
            .opcode => hasher.update(std.mem.asBytes(&n.data.opcode)),
            .index => hasher.update(std.mem.asBytes(&n.data.index)),
            .kind_tag => hasher.update(std.mem.asBytes(&n.data.kind_tag)),
            else => hasher.update(std.mem.sliceAsBytes(n.data.ref_list.items)),
        }

        return hasher.final();
    }
};

/// 64-bit context providing eql and hash functions for `Node` and `[]const u8` types.
/// This is used by the interner to map constant value nodes to their references.
pub fn ListHasher(comptime element_kind: Discriminator) type {
    return struct {
        pub fn eql(b: []const Ref, a: Node) bool {
            if (a.kind.getTag() != .collection or a.kind.getDiscriminator() != element_kind) return false;

            return std.mem.eql(Ref, a.data.ref_list.items, b);
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
pub const BufferHasher = struct {
    pub fn eql(b: []const u8, a: Node) bool {
        if (a.kind != NodeKind.data(.buffer)) return false;

        return std.mem.eql(u8, a.data.buffer.items, b);
    }

    pub fn hash(n: []const u8) u64 {
        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(std.mem.asBytes(&ir.NodeKind.data(.buffer)));
        hasher.update(n);

        return hasher.final();
    }
};

/// Body data type for data nodes.
pub const Node = struct {
    /// The kind of the data stored here.
    kind: NodeKind,
    /// The untagged union of the data that can be stored here.
    data: Data,

    fn deinit(self: *Node, gpa: std.mem.Allocator) void {
        switch (self.kind.getTag()) {
            .data => switch (self.kind.getDiscriminator()) {
                .buffer => self.data.buffer.deinit(gpa),
                else => {},
            },
            .collection => self.data.ref_list.deinit(gpa),
            else => {},
        }
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
    /// IR-specific instruction operation.
    operation: Operation,
    /// Bytecode instruction opcode; for use in intrinsics and final assembly.
    opcode: bytecode.Instruction.OpCode,
    /// An arbitrary integer value, such as an index into an array.
    index: u64,
    /// A variant describing the kind of a type.
    kind_tag: KindTag,
    /// Arbitrary list of graph refs, such as a list of types.
    ref_list: pl.ArrayList(Ref),
};

/// Identity of a builtin construct such as a type constructor, type, etc.
pub const Builtin = enum(u8) {
    /// See `ir.KindTag.data`.
    data_kind,
    /// See `ir.KindTag.primitive`.
    primitive_kind,
    /// See `ir.KindTag.set`.
    type_set_kind,
    /// See `ir.KindTag.set`.
    data_type_set_kind,
    /// See `ir.KindTag.map`.
    type_map_kind,
    /// See `ir.KindTag.map`.
    data_type_map_kind,

    /// A type constructor for the `integer` type family, which is a type of kind `primitive`,
    /// with a signedness symbolic parameter and a bit width parameter.
    integer_constructor,
    /// A type constructor for the `symbol` type family, which is a type of kind `primitive`,
    /// with a primitive parameter for the name of the symbol.
    symbol_constructor,
    /// A type constructor for the `set` family, which is a type of kind `set`,
    /// with a key kind.
    type_set_constructor,
    /// A type constructor for the `map` type family, which is a type of kind `map`,
    /// with two type set parameters
    type_map_constructor,
    /// A type constructor for the `struct` type family, which is a type of kind `structure`,
    /// with a map of fields.
    struct_constructor,

    /// Interned byte buffers may designate this type of kind `primitive`,
    /// in lieu of a more specific type that must otherwise be discerned from their usage.
    /// This is done to prevent situations like `integer_type` referring to itself,
    /// in the process of typing its bit size constant.
    interned_bytes_type,
    /// An integer type, an instance of the `integer` type constructor.
    integer_type,
    /// A symbol type, an instance of the `symbol` type constructor.
    symbol_type,
    /// A type of kind `set`, which is a list of keys of kind `key_kind`.
    type_set_type,
    /// A type of kind `map`, which is a pair of two sets, keys and values.
    type_map_type,
    /// A structural type, an instance of the `struct` type constructor.
    struct_type,
};

/// initializers for builtin constructs. See `ir.Context.Root.getBuiltin`.
pub const builtins = struct {
    pub fn data_kind(ctx: *Context) !Ref {
        return ctx.internLocalStructure(.kind, .{
            .output_tag = try ctx.internLocalData(.kind_tag, .data),
            .input_kinds = Ref.nil,
        });
    }

    pub fn primitive_kind(ctx: *Context) !Ref {
        return ctx.internLocalStructure(.kind, .{
            .output_tag = try ctx.internLocalData(.kind_tag, .primitive),
            .input_kinds = Ref.nil,
        });
    }

    pub fn type_set_kind(ctx: *Context, key_kind: Ref) !Ref {
        return ctx.internLocalStructure(.kind, .{
            .output_tag = try ctx.internLocalData(.kind_tag, .set),
            .input_kinds = try ctx.internLocalList(.kind, &.{ key_kind }),
        });
    }

    pub fn type_map_kind(ctx: *Context, key_set_kind: Ref, val_set_kind: Ref) !Ref {
        return ctx.internLocalStructure(.kind, .{
            .output_tag = try ctx.internLocalData(.kind_tag, .map),
            .input_kinds = try ctx.internLocalList(.kind, &.{
                key_set_kind,
                val_set_kind,
            }),
        });
    }

    pub fn data_type_set_kind(ctx: *Context) !Ref {
        return ctx.getRoot().getBuiltin(.type_set_kind, .{
            try ctx.getRoot().getBuiltin(.data_kind, .{}),
        });
    }

    pub fn data_type_map_kind(ctx: *Context) !Ref {
        return ctx.getRoot().getBuiltin(.type_map_kind, .{
            try ctx.getRoot().getBuiltin(.data_type_set_kind, .{}),
            try ctx.getRoot().getBuiltin(.data_type_set_kind, .{}),
        });
    }

    pub fn integer_constructor(ctx: *Context) !Ref {
        const k_primitive = try ctx.getRoot().getBuiltin(.primitive_kind, .{});

        return ctx.addLocalStructure(.constructor, .{
            .kind = try ctx.internLocalStructure(.kind, .{
                .output_tag = try ctx.internLocalData(.kind_tag, .primitive),
                .input_kinds = try ctx.internLocalList(.kind, &.{ k_primitive, k_primitive }),
            }),
        });
    }

    pub fn symbol_constructor(ctx: *Context) !Ref {
        const k_arrow = try ctx.internLocalStructure(.kind, .{
            .output_tag = try ctx.internLocalData(.kind_tag, .primitive),
            .input_kinds = try ctx.internLocalList(.kind, &.{ try ctx.getRoot().getBuiltin(.primitive_kind, .{}) }),
        });

        return ctx.addLocalStructure(.constructor, .{
            .kind = k_arrow,
        });
    }

    pub fn type_set_constructor(ctx: *Context, key_kind: Ref) !Ref {
        return ctx.addLocalStructure(.constructor, .{
            .kind = try ctx.getRoot().getBuiltin(.type_set_kind, .{ key_kind }),
        });
    }

    pub fn type_map_constructor(ctx: *Context, key_set_kind: Ref, val_set_kind: Ref) !Ref {
        return ctx.addLocalStructure(.constructor, .{
            .kind = try ctx.getRoot().getBuiltin(.type_map_kind, .{ key_set_kind, val_set_kind }),
        });
    }

    // TODO: we need to be able to add additional flags; such as layout method, ie packed vs c, etc.
    //       should this be done with the userdata? or with additional type parameters?
    pub fn struct_constructor(ctx: *Context) !Ref {
        return ctx.addLocalStructure(.constructor, .{
            .kind = try ctx.internLocalStructure(.kind, .{
                .output_tag = try ctx.internLocalData(.kind_tag, .structure),
                .input_kinds = try ctx.internLocalList(.kind, &.{
                    try ctx.getRoot().getBuiltin(.data_type_map_kind, .{}),
                }),
            }),
        });
    }

    pub fn interned_bytes_type(ctx: *Context) !Ref {
        return ctx.addLocalStructure(.constructor, .{
            .kind = try ctx.getRoot().getBuiltin(.primitive_kind, .{}),
        });
    }

    pub fn integer_type(ctx: *Context, signedness: pl.Signedness, bit_size: pl.Alignment) !Ref {
        return ctx.internLocalStructure(.type, .{
            .constructor = try ctx.getRoot().getBuiltin(.integer_constructor, .{}),
            .input_types = try ctx.internLocalList(.type, &.{
                try ctx.internLocalStructure(.constant, .{
                    .type = try ctx.getRoot().getBuiltin(.interned_bytes_type, .{}),
                    .value = try ctx.internLocalBuffer(std.mem.asBytes(&signedness)),
                }),
                try ctx.internLocalStructure(.constant, .{
                    .type = try ctx.getRoot().getBuiltin(.interned_bytes_type, .{}),
                    .value = try ctx.internLocalBuffer(std.mem.asBytes(&bit_size)),
                }),
            }),
        });
    }

    pub fn symbol_type(ctx: *Context, name: []const u8) !Ref {
        return ctx.internLocalStructure(.type, .{
            .constructor = try ctx.getRoot().getBuiltin(.symbol_constructor, .{}),
            .input_types = try ctx.internLocalList(.type, &.{ try ctx.internLocalData(.name, name) }),
        });
    }

    pub fn type_set_type(ctx: *Context, key_kind: Ref, keys: []const Ref) !Ref {
        return ctx.internLocalStructure(.type, .{
            .constructor = try ctx.getRoot().getBuiltin(.type_set_constructor, .{ key_kind }),
            .input_types = try ctx.internLocalList(.type, keys),
        });
    }

    pub fn type_map_type(ctx: *Context, key_kind: Ref, val_kind: Ref, keys: []const Ref, vals: []const Ref) !Ref {
        return ctx.internLocalStructure(.type, .{
            .constructor = try ctx.getRoot().getBuiltin(.type_map_constructor, .{
                try ctx.getRoot().getBuiltin(.type_set_kind, .{ key_kind }),
                try ctx.getRoot().getBuiltin(.type_set_kind, .{ val_kind }),
            }),
            .input_types = try ctx.internLocalList(.type, &.{
                try ctx.getRoot().getBuiltin(.type_set_type, .{ key_kind, keys }),
                try ctx.getRoot().getBuiltin(.type_set_type, .{ val_kind, vals }),
            }),
        });
    }

    pub fn struct_type(ctx: *Context, names: []const Ref, types: []const Ref) !Ref {
        const k_data = try ctx.getRoot().getBuiltin(.data_kind, .{});

        return ctx.internLocalStructure(.type, .{
            .constructor = try ctx.getRoot().getBuiltin(.struct_constructor, .{}),
            .input_types = try ctx.internLocalList(.type, &.{
                try ctx.getRoot().getBuiltin(.type_map_type, .{
                    k_data,
                    k_data,
                    names,
                    types,
                }),
            }),
        });
    }
};

/// VTable and arbitrary data map for user defined data on nodes.
pub const UserData = struct {
    /// The context this user data is bound to.
    context: *Context,
    /// Type constructors are expected to bind this.
    computeLayout: ?*const fn (constructor: Ref, input_types: []const Ref) anyerror!struct { u64, pl.Alignment } = null,
    /// Any ref can bind this to provide a custom display function for the node.
    display: ?*const fn (value: *const Data, writer: std.io.AnyWriter) anyerror!void = null,
    /// Any opaque data can be stored here, bound with comptime-known names.
    bindings: pl.StringArrayMap(*anyopaque) = .empty,

    // TODO: zig seems to hate TypeId-style abstraction, but in the event this becomes viable,
    // we could use a custom map here to provide type-safe access to the bindings.

    /// Store an arbitrary address in the user data map, bound to a comptime-known key.
    pub fn addData(self: *UserData, comptime key: pl.EnumLiteral, value: anytype) !void {
        try self.bindings.put(self.context.gpa, comptime @tagName(key), @ptrCast(value));
    }

    /// Get an arbitrary address from the user data map, bound to a comptime-known key.
    /// * This does not perform any checking on the type stored in the map.
    pub fn getData(self: *UserData, comptime T: type, comptime key: pl.EnumLiteral) ?*T {
        return @alignCast(@ptrCast(self.bindings.get(comptime @tagName(key))));
    }

    /// Delete an arbitrary address from the user data map, given the comptime-known key it is bound to.
    /// * If the key does not exist, this is a no-op.
    pub fn delData(self: *UserData, comptime key: pl.EnumLiteral) void {
        _ = self.bindings.remove(comptime @tagName(key));
    }
};

/// Compute the layout of a type node by reference.
pub fn computeLayout(ref: Ref) !struct { u64, pl.Alignment } {
    if (ref.local.node_kind.getTag() != .structure or ref.local.node_kind.getDiscriminator() != .type) {
        return error.InvalidNodeKind;
    }

    const ref_constructor = try ref.getField(.constructor);
    const ref_input_types = try ref.getField(.input_types);

    const input_types = try ref_input_types.getChildren();

    const userdata = try ref_constructor.getUserData();

    if (userdata.computeLayout) |computeLayoutFn| {
        return computeLayoutFn(ref_constructor, input_types);
    } else {
        return error.InvalidGraphState;
    }
}

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
    set,
    /// An associative array of types; for example the fields of a struct. No value.
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
