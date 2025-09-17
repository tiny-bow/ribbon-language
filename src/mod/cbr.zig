//! An in-memory, deterministic data structure derived from a module's public interface,
//! used exclusively for generating a cryptographic hash (`interface_hash`) that uniquely
//! and verifiably identifies that interface.

const cbr = @This();

const std = @import("std");
const ir = @import("ir");
const sma = @import("sma");
const backend = @import("backend");
const common = @import("common");

const log = std.log.scoped(.cbr);

test {
    // std.debug.print("semantic analysis for cbr\n", .{});
    std.testing.refAllDecls(@This());
}

/// A cryptographic hash, typically BLAKE3, used to identify canonicalized structures.
pub const Hash = u128;

/// The root of a CBR tree for any public symbol.
pub const Node = union(enum) {
    struct_type: Struct,
    function_type: Function,
    enum_type: Enum,
    type_class: TypeClass,
    // ... other public symbol kinds (e.g., primitive types, which have constant hashes; constraints, etc.)
};

pub const Struct = struct {
    /// The memory layout policy. This is part of the public contract.
    layout_policy: enum { @"packed", c_abi },

    /// A CANONICALLY SORTED list of the public fields.
    /// Sorting key: alphabetical by name for `packed`, numerical by memory offset for `c_abi`.
    fields: []const Field,
};

pub const Field = struct {
    /// Hash of the field name string.
    name_hash: Hash,
    /// Hash of the field's type CBR.
    type_hash: Hash,
};

pub const Function = struct {
    /// Hash of the function's return type CBR.
    return_type_hash: Hash,

    /// A list of the hashes of each parameter type's CBR, in declaration order.
    parameter_hashes: []const Hash,

    /// Hash of the function's generic constraints, if any.
    /// Constraints are canonicalized (e.g., sorted alphabetically by type class name) before hashing.
    constraints_hash: Hash,

    /// Hash of the function's full, inferred effect row.
    /// The effect row is canonicalized (e.g., sorted alphabetically by effect name) before hashing.
    effect_row_hash: Hash,
};

pub const Enum = struct {
    /// A CANONICALLY SORTED list of enum members.
    /// Sorting key: alphabetical by member name.
    members: []const EnumMember,
};

pub const EnumMember = struct {
    name_hash: Hash,
    /// The explicit value, if provided. Part of the public contract.
    value: ?u64,
};

pub const TypeClass = struct {
    /// A CANONICALLY SORTED list of the type class's members (e.g., function signatures).
    /// Sorting key: alphabetical by member name.
    members: []const Node,
};

/// Context for a single CBR generation pass.
const Context = struct {
    /// The job whose public symbols are being processed.
    job: *const backend.Job,
    /// An arena allocator for building the temporary CBR tree structures.
    allocator: std.mem.Allocator,
    /// A cache to store the hashes of already-processed `ir.Ref`s,
    /// avoiding re-computation and handling cycles/shared types.
    hash_cache: common.UniqueReprMap(ir.Ref, Hash),

    /// Recursively generates the `cbr.Node` tree for a given public symbol `ir.Ref`.
    pub fn generate(ctx: *Context, ref: ir.Ref) !Node {
        // TODO: Implement the recursive generation of the CBR tree.
        // 1. Get the `ir.Node` for the `ref`.
        // 2. Based on the `ir.NodeKind`, create the corresponding `*` struct.
        // 3. For struct fields, function parameters, etc., recursively call `generate` on their `ir.Ref`s.
        // 4. Use the `ctx.allocator` to allocate slices for fields, parameters, etc.
        // 5. CRITICAL: Apply canonical sorting rules at each step as described in the plan.
        //    - Sort struct fields (by name for packed, by offset for C).
        //    - Sort enum members by name.
        //    - Sort effect rows by effect name.

        common.todo(noreturn, .{ ctx, ref });
    }

    /// Recursively computes the Merkle-style hash for a `cbr.Node` tree.
    pub fn hashNode(ctx: *Context, node: Node) !Hash {
        // TODO: Implement the Merkle-style hashing.
        // 1. Switch on the `Node` variant.
        // 2. For each variant, construct a canonical byte buffer.
        //    - This buffer should contain the hashes from child nodes (e.g., `type_hash`, `return_type_hash`).
        //    - It must also include ABI-relevant data like `layout_policy`.
        // 3. Use `ctx.hashBytes` to hash the buffer.
        // 4. IMPORTANT: Use `ctx.hash_cache` to store and retrieve results for `ir.Ref`s
        //    to avoid re-computation and handle graph cycles correctly.

        common.todo(noreturn, .{ ctx, node });
    }
};

/// The main entry point for generating the final `interface_hash` for an entire module.
pub fn generateInterfaceHash(job: *backend.Job, arena: std.mem.Allocator) !Hash {
    var ctx = Context{
        .job = job,
        .allocator = arena,
        .hash_cache = .empty,
    };
    defer ctx.hash_cache.deinit(arena);

    // TODO: Implement the top-level algorithm.
    // 1. Identify all public symbols in the `job.context`.
    // 2. Create a list to store `(symbol_name, symbol_hash)` pairs.
    // 3. For each public symbol:
    //    a. Call `cbr.generate()` to create its CBR tree.
    //    b. Call `cbr.hashNode()` on the result to get its hash.
    //    c. Store the (name, hash) pair.
    // 4. CRITICAL: Sort the list of pairs alphabetically by `symbol_name`.
    // 5. Concatenate just the hashes from the sorted list into a single byte buffer.
    // 6. Hash this final buffer using `ctx.hashBytes` to produce the `interface_hash`.

    common.todo(noreturn, .{ctx});
}

/// Hashes a byte slice using the canonical hashing algorithm (unkeyed BLAKE3).
pub fn hashBytes(data: []const u8) Hash {
    var hasher = std.crypto.hash.Blake3.init(.{ .key = null });
    var result: u128 = undefined;

    hasher.update(data);
    hasher.final(std.mem.asBytes(&result));

    return result;
}
