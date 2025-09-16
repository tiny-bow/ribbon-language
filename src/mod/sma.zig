//! The on-disk, cacheable binary format that represents a module's public interface and dependencies.

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

/// A stable, serializable reference to an IR node.
/// The `sma.Ref` is the cornerstone of the SMA format. It is a stable, serializable, context-free representation of an in-memory `ir.Ref`.
pub const Ref = union(enum) {
    /// A reference to another node within this SAME artifact.
    /// The u32 is an index into this SMA's `node_table`.
    internal: u32,

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

    /// Byte offset from binary base to table base.
    string_table_offset: u32,
    /// Length in bytes.
    string_table_len: u32,
    /// Byte offset from binary base to table base.
    public_symbol_table_offset: u32,
    /// Number of entries.
    public_symbol_table_len: u32,
    /// Byte offset from binary base to table base.
    node_table_offset: u32,
    /// Number of entries.
    node_table_len: u32,
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
    node_table: []const Node,
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
};

/// Serializes a public `ir.Context` into a byte buffer representing an SMA file.
/// This process is called "dehydration".
pub fn serialize(ctx: *ir.Context, allocator: std.mem.Allocator) ![]u8 {
    _ = ctx;
    _ = allocator;
    // TODO: Implement the "dehydration" process.
    // 1. Traverse the public IR graph to determine the size of all tables.
    // 2. Allocate a single buffer for the entire SMA file.
    // 3. Create a mapping from `ir.Ref` to `sma.Ref` and from strings to string_table indices.
    // 4. Fill the `Header` with placeholder offsets.
    // 5. Populate the `string_table`, `node_table`, and `ref_table` by traversing the graph again.
    // 6. Fill in the final table offsets and lengths in the `Header`.
    // 7. Return the buffer.
    return error.Unsupported;
}

/// Deserializes an SMA byte buffer into a live `ir.Context`.
/// This process is called "rehydration".
pub fn deserialize(job: *backend.Job, buffer: []const u8) !void {
    _ = job;
    _ = buffer;
    // TODO: Implement the "rehydration" process.
    // 1. Validate the SMA header (magic number, version).
    // 2. Create a two-pass process to handle cyclic dependencies.
    // 3. Pass 1 (Shell Creation): Iterate the `sma.Node` table and create empty "shell"
    //    `ir.Node`s in the job's `ir.Context`. Store the mapping from the SMA `internal`
    //    index to the new `ir.Ref`.
    // 4. Pass 2 (Linkage): Iterate the `sma.Node` table again. For each shell `ir.Node`,
    //    populate its `ref_list` by resolving its `sma.Ref`s using the map from Pass 1
    //    and the SMA's ref_table. `external` references are kept as unresolved stubs for now.
    return error.Unsupported;
}
