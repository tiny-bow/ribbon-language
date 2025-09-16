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
        var header = Header{
            .format_version = format_version_number,
            .module_guid = module_guid,
            .interface_hash = 0,
            .string_table_len = 0,
            .public_symbol_table_offset = 0,
            .public_symbol_table_len = 0,
            .public_node_table_offset = 0,
            .public_node_table_len = 0,
            .private_node_table_offset = 0,
            .private_node_table_len = 0,
            .ref_table_offset = 0,
            .ref_table_len = 0,
        };

        // TODO: Implement the "dehydration" process.
        // * Partition the ir.Context graph into a "public" set (nodes reachable from
        //   public symbols) and a "private" set (the rest).
        // * Create mappings from `ir.Ref` to `sma.Ref` and from strings to string_table indices.
        // * Serialize the public set into the `public_node_table`.
        // * Serialize the private set into the `private_node_table`.
        // * Populate the shared `string_table` and `ref_table`.
        // * Fill in the final table offsets and lengths in the `Header`.

        common.todo(void, .{ ir_ctx, arena, &header });

        return Artifact{
            .header = header,
            .string_table = &.{},
            .public_symbol_table = &.{},
            .node_table = &.{},
            .ref_table = &.{},
        };
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
