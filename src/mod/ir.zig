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
const Interner = @import("Interner");
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

        /// Get a pointer to the Context this Root is stored in.
        pub fn getRootContext(self: *Root) *Context {
            const inner: *@FieldType(Context, "inner") = @fieldParentPtr("root", self);
            return @fieldParentPtr("inner", inner);
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

        /// Deinitialize the root context, freeing all memory it owns.
        pub fn deinit(self: *Root, gpa: std.mem.Allocator) void {
            var it = self.children.valueIterator();
            while (it.next()) |child_ptr| child_ptr.*.deinit();

            var arena = self.getRootContext().arena;
            arena.deinit();
            _ = self.children.deinit(gpa);
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

    /// Intern a data node in the context, given a data kind and data.
    /// * If the node already exists in this context, it will return the existing reference.
    /// * Modifying nodes added this way is unsafe.
    pub fn internLocalData(self: *Context, comptime kind: DataKind, value: DataType(kind)) !Ref {
        const node = try data(kind, value);
        errdefer node.deinit(self.gpa);

        return try self.internLocalUnchecked(node);
    }

    /// Intern a structure node in the context, given a structure kind and an initializer.
    /// * The initializer must be a struct with the same fields as the structure kind. See `ir.structure`.
    /// * If the node already exists in this context, it will return the existing reference.
    /// * Modifying nodes added this way is unsafe.
    pub fn internLocalStructure(self: *Context, comptime kind: StructureKind, value: anytype) !Ref {
        const node = try structure(self.gpa, kind, value);
        errdefer node.deinit(self.gpa);

        return try self.internLocalUnchecked(node);
    }

    /// Create a new data node in the context, given a data kind and data.
    pub fn addLocalData(self: *Context, comptime kind: DataKind, value: DataType(kind)) !Ref {
        const node = try data(kind, value);
        errdefer node.deinit(self.gpa);

        return self.addLocalUnchecked(node);
    }

    /// Create a new structure node in the context, given a structure kind and an initializer.
    /// * The initializer must be a struct with the same fields as the structure kind. See `ir.structure`.
    pub fn addLocalStructure(self: *Context, comptime kind: StructureKind, value: anytype) !Ref {
        const node = try structure(self.gpa, kind, value);
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
    const T = comptime std.meta.FieldType(Structures, kind);
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
                if (!info.fields.len == 2) @compileError("Unexpected type for structure " ++ struct_name ++ " field decl " ++ decl.name ++ ": " ++ @typeName(decl.type));

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
    /// A set of types; for example a set of effect types. No value.
    set,
    /// A map of types; for example the fields of a struct. No value.
    map,
    /// This is *data*, but which cannot be a value; Only the destination of a pointer.
    @"opaque",
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
