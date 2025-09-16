//! The on-disk, cacheable binary format that represents a module's public interface, all definitions required to implement the interface, and dependencies.

const sma = @This();

const std = @import("std");
const source = @import("source");
const ir = @import("ir");
const core = @import("core");
const common = @import("common");
const backend = @import("backend");

const log = std.log.scoped(.sma);

test {
    std.testing.refAllDecls(@This());
}

/// Version of the SMA format.
pub const format_version_number = 1;

/// A stable, serializable reference to an IR node.
/// The `sma.Ref` is the cornerstone of the SMA format. It is a stable, serializable, context-free representation of an in-memory `ir.Ref`.
pub const Ref = union(enum) {
    /// A reference to another node within this SAME artifact, that is a public symbol.
    /// The u32 is an index into this SMA's `public_node_table`.
    public: u32,

    /// A reference to another node within this SAME artifact, that is NOT a public symbol.
    /// The u32 is an index into this SMA's `private_node_table`.
    private: u32,

    /// A stable, symbolic reference to a public item in another module.
    external: struct {
        /// Unique hash identifying the target module.
        module_guid: ir.ModuleGUID,
        /// Index into this SMA's string_table for the symbol name.
        symbol_name_idx: u32,
    },

    /// A reference to a well-known compiler primitive or builtin type.
    builtin: ir.Builtin,

    /// Represents a null or empty reference.
    nil,
};

/// A "dehydrated" representation of an `ir.Node`.
/// Flattened, serializable representation of a public declaration.
pub const Node = extern struct {
    /// The kind of the node, mirroring ir.NodeKind.
    kind: ir.NodeKind,

    /// The content of the node, where all ir.Refs are replaced with sma.Refs.
    content: Data,

    pub const Data = extern union {
        nil: void,
        primitive: u64,
        /// Index into string_table for names, buffers, etc.
        data: u32,
        structure: RefList,
        collection: RefList,
    };

    pub const RefList = extern struct {
        /// Start index into the SMA's flat ref_table.
        start_idx: u32,
        /// Length of the list in elements.
        len: u32,
    };
};

/// The header of a Serializable Module Artifact file.
pub const Header = extern struct {
    magic_number: [6]u8 = "RIBSMA".*,
    format_version: u16 = 1,
    ribbon_version: u64 = core.VERSION_NUMBER,
    module_guid: ir.ModuleGUID,
    interface_hash: u128,

    /// Length in bytes.
    /// string_table_offset is always @sizeOf(Header), so we don't store it.
    string_table_len: u32,

    /// Byte offset from binary base to table base.
    public_symbol_table_offset: u32,
    /// Number of entries.
    public_symbol_table_len: u32,

    /// Byte offset from binary base to table base.
    public_node_table_offset: u32,
    /// Number of entries.
    public_node_table_len: u32,

    /// Byte offset from binary base to table base.
    private_node_table_offset: u32,
    /// Number of entries.
    private_node_table_len: u32,

    /// Byte offset from binary base to table base.
    ref_table_offset: u32,
    /// Number of entries.
    ref_table_len: u32,
};

/// An entry in the public symbol table, mapping a symbol name to its root `sma.Node`.
pub const PublicSymbol = extern struct {
    /// Index into the string_table for the symbol's name.
    name_idx: u32,
    /// Index into the node_table for the symbol's root IR node.
    root_node_idx: u32,
};

/// The top-level structure representing a parsed SMA file. This struct provides
/// views into a single contiguous memory buffer.
pub const Artifact = struct {
    header: Header,
    string_table: []const u8,
    public_symbol_table: []const PublicSymbol,
    public_node_table: []const Node,
    private_node_table: []const Node,
    ref_table: []const Ref,

    /// Given a `sma.Node` that contains a `RefList`, this function returns a slice
    /// of the corresponding `sma.Ref`s from the flat `ref_table`.
    pub fn getRefs(self: *const Artifact, node: Node) ?[]const Ref {
        const ref_list = switch (node.content) {
            .structure => |rl| rl,
            .collection => |rl| rl,
            else => return null,
        };

        const end = ref_list.start_idx + ref_list.len;
        if (end > self.ref_table.len) return null; // Bounds check

        return self.ref_table[ref_list.start_idx..end];
    }

    /// Serializes a public `ir.Context` into an Artifact representing an SMA file.
    /// This process is called "dehydration".
    pub fn fromIr(ir_ctx: *ir.Context, module_guid: ir.ModuleGUID, arena: std.mem.Allocator) !Artifact {
        var dehydrator = try Dehydrator.init(ir_ctx, module_guid, arena);
        defer dehydrator.deinit();

        try dehydrator.findPublicRefs();

        var all_nodes_it = ir_ctx.nodes.keyIterator();
        while (all_nodes_it.next()) |ref| {
            try dehydrator.dehydrateNode(ref.*);
        }

        try dehydrator.buildPublicSymbolTable();

        return dehydrator.buildArtifact();
    }
};

/// Rehydrates only the PUBLIC INTERFACE from an SMA buffer into a live `ir.Context`.
/// Used for compiling a dependency.
pub fn rehydratePublic(job: *backend.Job, artifact: Artifact) !void {
    // ... implement 2-pass rehydration using ONLY the public_node_table
    common.todo(void, .{ job, artifact });
}

/// Rehydrates the ENTIRE MODULE (public + private) from an SMA buffer.
/// Used when compiling the module itself.
pub fn rehydrateFull(job: *backend.Job, artifact: Artifact) !void {
    // ... implement 2-pass rehydration using BOTH public_node_table and private_node_table,
    // correctly linking refs between them.
    common.todo(void, .{ job, artifact });
}

/// Facility for serializing a public `ir.Context` into an `Artifact` representing an SMA file. Typically used via `Artifact.fromIr`.
pub const Dehydrator = struct {
    ir_ctx: *ir.Context,
    module_guid: ir.ModuleGUID,
    arena: std.mem.Allocator,
    temp_allocator: std.heap.ArenaAllocator,

    /// Set of all refs reachable from public symbols.
    public_refs: ir.RefSet,

    /// Maps a processed `ir.Ref` to its partition (public/private) and its index within that partition's node table.
    ref_map: common.UniqueReprMap(ir.Ref, struct { is_public: bool, index: u32 }),

    /// Interns strings and maps them to their index in the final `string_table`.
    string_interner: common.StringMap(u32),
    string_table_builder: common.ArrayList(u8),

    /// Builders for the final artifact tables.
    public_symbol_table: common.ArrayList(PublicSymbol),
    public_node_table: common.ArrayList(Node),
    private_node_table: common.ArrayList(Node),
    ref_table: common.ArrayList(Ref),

    pub fn init(init_ir_ctx: *ir.Context, init_module_guid: ir.ModuleGUID, init_arena: std.mem.Allocator) !*Dehydrator {
        var temp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator); // TODO: backing allocator should probably be passed in
        errdefer temp_arena.deinit();

        const self = try temp_arena.allocator().create(Dehydrator);

        self.* = .{
            .ir_ctx = init_ir_ctx,
            .module_guid = init_module_guid,
            .arena = init_arena,
            .temp_allocator = temp_arena,
            .public_refs = .{},
            .ref_map = .{},
            .string_interner = .{},
            .string_table_builder = .{},
            .public_symbol_table = .{},
            .public_node_table = .{},
            .private_node_table = .{},
            .ref_table = .{},
        };

        return self;
    }

    pub fn deinit(self: *Dehydrator) void {
        self.public_refs.deinit(self.temp_allocator.allocator());
        self.ref_map.deinit(self.temp_allocator.allocator());
        self.string_interner.deinit(self.temp_allocator.allocator());
        self.string_table_builder.deinit(self.temp_allocator.allocator());
        self.public_symbol_table.deinit(self.temp_allocator.allocator());
        self.public_node_table.deinit(self.temp_allocator.allocator());
        self.private_node_table.deinit(self.temp_allocator.allocator());
        self.ref_table.deinit(self.temp_allocator.allocator());
        self.temp_allocator.deinit();
    }

    /// Populates `self.public_refs` by traversing the graph from all public entry points.
    /// This traversal is "API-aware": it explores the full definition of exposed types
    /// but deliberately does not traverse into the implementation (bodies) of functions,
    /// correctly separating the public contract from private details.
    pub fn findPublicRefs(self: *Dehydrator) !void {
        var work_queue = std.ArrayList(ir.Ref).init(self.temp_allocator.allocator());
        defer work_queue.deinit();

        // 1. Seed the traversal with all public `global_symbol` nodes and their direct targets.
        //    This is more efficient than scanning the entire node table.
        var global_it = self.ir_ctx.global_symbols.valueIterator();
        while (global_it.next()) |global_symbol_ref_ptr| {
            const global_symbol_ref = global_symbol_ref_ptr.*;

            // The global_symbol node itself is part of the public interface, as it defines the export name.
            try self.addRefToPublic(global_symbol_ref, &work_queue);

            // The node the symbol points to is the actual public item.
            const target_ref = try self.ir_ctx.getField(global_symbol_ref, .node) orelse {
                log.err("SMA Dehydration: public symbol {f} has no target node.", .{global_symbol_ref});
                return error.InvalidGraphState;
            };
            try self.addRefToPublic(target_ref, &work_queue);
        }

        // 2. Perform the API-aware graph traversal.
        while (work_queue.popOrNull()) |current_ref| {
            const node = self.ir_ctx.getNode(current_ref) orelse continue;

            // Stop traversal at leaves or nodes outside the current module.
            if (!node.kind.getTag().containsReferences() or current_ref.id.context != self.ir_ctx.id) {
                continue;
            }

            // --- This is the critical boundary logic ---
            if (node.kind == .structure and node.kind.getDiscriminator() == .function) {
                // For a function node, ONLY traverse its type signature, NOT its body.
                // The body is the implementation.
                const function_type_ref = try self.ir_ctx.getField(current_ref, .type) orelse continue;
                try self.addRefToPublic(function_type_ref, &work_queue);

                // We could also traverse other ABI-relevant fields here if they existed,
                // e.g., `.parent_handler`, `.linkage_name`, etc.
            } else {
                // For ALL OTHER node types (structs, enums, function_types, constants, etc.),
                // their entire definition is part of the contract if they are public.
                // Therefore, we traverse all of their children.
                for (node.content.ref_list.items) |child_ref| {
                    try self.addRefToPublic(child_ref, &work_queue);
                }
            }
        }
    }

    /// Helper to add a ref to the public set and the work queue if it hasn't been seen before.
    /// This prevents redundant work and infinite loops in cyclic graphs.
    fn addRefToPublic(self: *Dehydrator, ref: ir.Ref, work_queue: *std.ArrayList(ir.Ref)) !void {
        // We only traverse nodes that are part of the current compilation unit.
        // External (dependency) and builtin refs are treated as opaque leaves from
        // the perspective of this module's public interface definition.
        if (ref == ir.Ref.nil or ref.id.context != self.ir_ctx.id) {
            return;
        }

        // `put` returns true if the item was newly inserted.
        if (try self.public_refs.put(self.temp_allocator.allocator(), ref, {})) {
            // If it's a new public ref, add it to the queue to traverse its children.
            try work_queue.append(ref);
        }
    }

    /// Recursively dehydrates a single `ir.Node` and its dependencies.
    pub fn dehydrateNode(self: *Dehydrator, ref: ir.Ref) !void {
        if (ref == ir.Ref.nil or self.ref_map.contains(ref) or self.ir_ctx.isBuiltinNode(ref)) {
            return;
        }

        // External refs are handled by `dehydrateChildRef` and don't get entries in `ref_map`.
        if (ref.id.context != self.ir_ctx.id) return;

        const node = self.ir_ctx.getNode(ref).?;

        // 1. Recurse: Ensure all children are dehydrated before this node.
        if (node.kind.getTag().containsReferences()) {
            for (node.content.ref_list.items) |child_ref| {
                try self.dehydrateNode(child_ref);
            }
        }

        // 2. Process current node
        var sma_node: sma.Node = .{ .kind = node.kind, .content = .{ .nil = {} } };
        switch (node.kind.getTag()) {
            .nil => {},
            .primitive => sma_node.content = .{ .primitive = node.content.primitive },
            .data => switch (node.kind.getDiscriminator()) {
                .name, .buffer => {
                    const str = if (node.kind.getDiscriminator() == .name) node.content.name else node.content.buffer.items;
                    const idx = try self.internString(str);
                    sma_node.content = .{ .data = idx };
                },
                else => return error.InvalidGraphState, // TODO: Handle .source
            },
            .structure, .collection => {
                const start_idx = self.ref_table.items.len;
                for (node.content.ref_list.items) |child_ref| {
                    const sma_ref = try self.dehydrateChildRef(child_ref);
                    try self.ref_table.append(self.temp_allocator.allocator(), sma_ref);
                }
                sma_node.content.structure = .{
                    .start_idx = @intCast(start_idx),
                    .len = @intCast(self.ref_table.items.len - start_idx),
                };
            },
        }

        // 3. Add to appropriate table and update map
        const is_public = self.public_refs.contains(ref);
        const table = if (is_public) &self.public_node_table else &self.private_node_table;
        const index = table.items.len;
        try table.append(self.temp_allocator.allocator(), sma_node);
        try self.ref_map.put(self.temp_allocator.allocator(), ref, .{ .is_public = is_public, .index = @intCast(index) });
    }

    /// Converts an `ir.Ref` to a `sma.Ref`, assuming dependencies have been processed.
    pub fn dehydrateChildRef(self: *Dehydrator, child_ref: ir.Ref) !sma.Ref {
        if (child_ref == ir.Ref.nil) return .nil;

        // TODO: A robust implementation requires access to the full dependency graph and
        // a reverse mapping from builtin refs to their `ir.Builtin` tags.
        // These are assumed to be available through a richer compiler context.
        if (self.ir_ctx.isBuiltinNode(child_ref)) {
            // Fictional reverse lookup.
            // return .{ .builtin = try self.ir_ctx.getBuiltinByRef(child_ref) };
            common.todo(noreturn, .{});
        }
        if (child_ref.id.context != self.ir_ctx.id) {
            // Fictional external symbol lookup.
            // const name = try self.ir_ctx.getExternalSymbolName(child_ref);
            // const guid = try self.ir_ctx.getExternalModuleGuid(child_ref);
            // const name_idx = try self.internString(name);
            // return .{ .external = .{ .module_guid = guid, .symbol_name_idx = name_idx } };
            common.todo(noreturn, .{});
        }

        const mapping = self.ref_map.get(child_ref).?;
        return if (mapping.is_public) .{ .public = mapping.index } else .{ .private = mapping.index };
    }

    pub fn internString(self: *Dehydrator, str: []const u8) !u32 {
        const gop = try self.string_interner.getOrPut(self.temp_allocator.allocator(), str);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.arena.dupe(u8, str);
            gop.value_ptr.* = @intCast(self.string_table_builder.items.len);
            try self.string_table_builder.appendSlice(self.temp_allocator.allocator(), str);
            try self.string_table_builder.append(self.temp_allocator.allocator(), 0); // Null terminator
        }
        return gop.value_ptr.*;
    }

    pub fn buildPublicSymbolTable(self: *Dehydrator) !void {
        var node_it = self.ir_ctx.nodes.iterator();
        while (node_it.next()) |entry| {
            const ref = entry.key_ptr.*;
            if (ref.node_kind == .structure and ref.node_kind.getDiscriminator() == .global_symbol) {
                const node = entry.value_ptr.*;
                const name_ref = node.content.ref_list.items[0];
                const target_ref = node.content.ref_list.items[1];
                const name = self.ir_ctx.getNode(name_ref).?.content.name;
                const name_idx = self.string_interner.get(name).?;
                const target_mapping = self.ref_map.get(target_ref).?;

                std.debug.assert(target_mapping.is_public);

                try self.public_symbol_table.append(self.temp_allocator.allocator(), .{
                    .name_idx = name_idx,
                    .root_node_idx = target_mapping.index,
                });
            }
        }
    }

    pub fn buildArtifact(self: *Dehydrator) !Artifact {
        const string_table = try self.arena.dupe(u8, self.string_table_builder.items);
        errdefer self.arena.free(string_table);

        const public_symbol_table = try self.arena.dupe(PublicSymbol, self.public_symbol_table.items);
        errdefer self.arena.free(public_symbol_table);

        const public_node_table = try self.arena.dupe(Node, self.public_node_table.items);
        errdefer self.arena.free(public_node_table);

        const private_node_table = try self.arena.dupe(Node, self.private_node_table.items);
        errdefer self.arena.free(private_node_table);

        const ref_table = try self.arena.dupe(Ref, self.ref_table.items);
        errdefer self.arena.free(ref_table);

        return Artifact{
            .header = .{
                .module_guid = self.module_guid,
                .interface_hash = 0, // Computed later by CBR pass
                .string_table_len = @intCast(self.string_table_builder.items.len),
                .public_symbol_table_len = @intCast(self.public_symbol_table.items.len),
                .public_node_table_len = @intCast(self.public_node_table.items.len),
                .private_node_table_len = @intCast(self.private_node_table.items.len),
                .ref_table_len = @intCast(self.ref_table.items.len),
                // Offsets are calculated by the final binary writer.
                .public_symbol_table_offset = 0,
                .public_node_table_offset = 0,
                .private_node_table_offset = 0,
                .ref_table_offset = 0,
            },
            .string_table = string_table,
            .public_symbol_table = public_symbol_table,
            .public_node_table = public_node_table,
            .private_node_table = private_node_table,
            .ref_table = ref_table,
        };
    }
};
