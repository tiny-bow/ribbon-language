//! The primary tranformer pass, applies peephole transformations to the IR.

const PeepholePass = @This();

const std = @import("std");
const log = std.log.scoped(.backend_peephole_pass);

const common = @import("common");
const ir = @import("ir");

const backend = @import("../backend.zig");

test {
    // std.debug.print("semantic analysis for peephole pass builder\n", .{});
    std.testing.refAllDecls(@This());
}

patterns: common.ArrayList(PeepholePattern) = .empty,

/// A unique identifier for a captured node within a pattern match.
/// Allows the transformer function to retrieve specific nodes from the matched subgraph.
pub const CaptureId = enum { a, b, c, d, value, condition, address, offset, lhs, rhs };

/// Specifies the arity and operand-matching rules for a `PatternNode`.
pub const MatchCommutativity = enum {
    /// The number of operands must exactly match the pattern's operand list.
    fixed,
    /// The pattern's operands are matched against the node's operands commutatively.
    /// Example: `(i_add ?x, ?y)` will match both `i_add(A, B)` and `i_add(B, A)`.
    commutative,
};

/// Represents a pattern for a single operand (a `ir.Ref`) of an `ir.Node`.
pub const OperandPattern = union(enum) {
    /// Matches any node and does not capture it.
    any,
    /// Matches any node and captures its `ir.Ref` under the given `CaptureId`.
    capture: CaptureId,
    /// Matches a specific, literal `ir.Ref`.
    // literal_ref: ir.Ref,
    /// Matches a node whose value is a specific primitive integer.
    /// This is a shortcut for matching a `primitive` node with a specific value.
    literal_primitive: u64,
    /// Matches a node by recursively applying a sub-pattern.
    sub_pattern: *const PatternNode,
    // /// An escape hatch for complex checks. Matches if the provided function returns `true`.
    // predicate: *const fn (ctx: *ir.Context, ref: ir.Ref) bool,
};

/// A declarative representation of a subgraph within the `ir.Context` to be matched.
pub const PatternNode = struct {
    /// The specific `ir.NodeKind` to match. If null, any kind is matched.
    // kind: ?ir.NodeKind = null,

    /// An optional pattern to match against the *type* of the node being evaluated.
    /// This is a powerful constraint, e.g., "match an 'i_add' node *whose result type is i32*".
    type_pattern: ?*const PatternNode = null,

    /// A list of patterns to match against the node's operands (`ref_list`).
    operands: []const OperandPattern = &.{},

    /// The matching strategy for the operands.
    arity: MatchCommutativity = .fixed,
};

pub const CaptureMap = common.UniqueReprMap(CaptureId, void); // TODO

/// Holds the results of a successful pattern match, mapping `CaptureId`s
/// to the `ir.Ref`s they captured from the live IR graph.
pub const MatchResult = struct {
    /// The `ir.Ref` of the root node of the matched subgraph.
    /// This is the node that the `PeepholePattern` will replace.
    // root_ref: ir.Ref = ir.Ref.nil,

    /// A map from the capture ID to the `ir.Ref` of the captured node.
    captures: CaptureMap = .{},

    /// Deinitialize the match result, freeing all memory it owns.
    pub fn deinit(self: *MatchResult, allocator: std.mem.Allocator) void {
        self.captures.deinit(allocator);
    }
};

/// A safe, high-level API for a transformer function to modify the IR graph.
/// It provides methods to create new nodes and replace the matched subgraph atomically.
pub const PatternBuilder = struct {
    job: *backend.Job,
    match_result: *const MatchResult,

    /// Atomically replaces the entire matched subgraph (`match_result.root_ref`)
    /// with `new_ref`. This function handles rewiring all uses and marking the old,
    /// now-unreachable nodes for garbage collection.
    pub fn replaceMatch(self: *PatternBuilder, new_ref: ir.Ref) !void {
        try self.job.context.replaceAllUses(self.match_result.root_ref, new_ref);

        // Mark the old sub-tree for deletion.
        try self.job.markSubtreeForDeletion(self.match_result.root_ref);
    }

    // Convenience functions to create new IR nodes
    pub fn createConstant(self: *PatternBuilder, comptime T: type, value: T) !ir.Ref {
        return self.job.context.internPrimitive(value);
    }

    pub fn createInstruction(self: *PatternBuilder, op: ir.Operation, type_ref: ir.Ref, operands: []const ir.Ref) !ir.Ref {
        // TODO: implementation using ir.Context.
        common.todo(noreturn, .{ self, op, type_ref, operands });
    }
};

/// A complete definition of a peephole optimization: a pattern to find
/// and a transformer function to execute upon a match.
pub const PeepholePattern = struct {
    /// A descriptive name for debugging and logging, e.g., "constant_fold_iadd".
    name: []const u8,

    /// The root of the pattern subgraph to match against the IR.
    match_root: PatternNode,

    /// The function that transforms the IR graph upon a successful match.
    transformer_fn: *const fn (builder: *PatternBuilder, result: *const MatchResult) anyerror!void,
};

/// Creates a `backend.Pass` from a slice of patterns.
pub fn init(allocator: std.mem.Allocator, patterns: []const PeepholePattern) !backend.Pass {
    const self = try allocator.create(PeepholePass);
    errdefer allocator.destroy(self);

    self.* = PeepholePass{};

    try self.patterns.appendSlice(allocator, patterns);

    return backend.Pass{
        .data = @ptrCast(self),
        .vtable = comptime &backend.Pass.VTable.of(@This()),
    };
}

/// Deinitialize the peephole pass, freeing all memory it owns.
pub fn deinit(self: *PeepholePass, allocator: std.mem.Allocator) void {
    self.patterns.deinit(allocator);
    allocator.destroy(self);
}

// /// The main execution function for a PeepholePass.
// pub fn run(self: *PeepholePass, job: *backend.Job) !void {
// var changed = true;

// Ensure we clean up any nodes marked for deletion at the end of the pass.
// defer job.deleteMarkedSubtrees();

// while (changed) {
//     changed = false;
//     var node_it = job.context.nodes.iterator();

//     while (node_it.next()) |entry| {
//         const current_ref = entry.key_ptr.*;

//         for (self.patterns.items) |pattern| {
//             var match_result = MatchResult{};
//             defer match_result.deinit(job.root.allocator);

//             if (try PeepholePass.tryMatch(job, &pattern.match_root, current_ref, &match_result)) {
//                 var builder = PatternBuilder{
//                     .job = job,
//                     .match_result = &match_result,
//                 };
//                 try pattern.transformer_fn(&builder, &match_result);
//                 changed = true;
//                 break;
//             }
//         }
//         if (changed) break;
//     }
// }
// }

// /// Recursively tries to match a `PatternNode` against a live `ir.Ref`.
// pub fn tryMatch(
//     job: *backend.Job,
//     pattern: *const PatternNode,
//     // ref: ir.Ref,
//     result: *MatchResult,
// ) !bool {
//     const ctx = job.context;

//     // 1. Initial Node Validation
//     // const node = ctx.getNode(ref) orelse return false;
//     // const node_kind = ref.node_kind;

//     // 1a. Match Node Kind
//     // if (pattern.kind) |pk| {
//     //     if (node_kind != pk) return false;
//     // }

//     // 1b. Match Node Type (Recursive Call)
//     if (pattern.type_pattern) |type_pattern| {
//         // We need to get the type of the current node.
//         // This part of the IR design needs to be firm to make this work reliably.
//         // const node_type_ref = try ctx.getField(ref, .type) orelse return false;

//         // if (!try tryMatch(job, type_pattern, node_type_ref, result)) {
//         //     return false;
//         // }
//     }

//     // 2. Operand Matching
//     if (pattern.operands.len > 0) {
//         if (node_kind.getTag() != .structure and node_kind.getTag() != .collection) {
//             // The pattern expects operands, but the node is a leaf (primitive/data).
//             return false;
//         }

//         const node_operands = node.content.ref_list.items;

//         switch (pattern.arity) {
//             .fixed => {
//                 // 2a. Non-commutative Match
//                 if (pattern.operands.len != node_operands.len) return false;

//                 for (pattern.operands, 0..) |op_pattern, i| {
//                     if (!try tryMatchOperand(job, op_pattern, node_operands[i], result)) {
//                         return false;
//                     }
//                 }
//             },
//             .commutative => {
//                 // 2b. Commutative Match
//                 // This is more complex. It requires finding a permutation of `node_operands`
//                 // that satisfies the `pattern.operands`.
//                 if (pattern.operands.len != node_operands.len) return false;

//                 // For simplicity here, we'll sketch a basic algorithm. A real implementation
//                 // might need a more optimized one (e.g., bipartite matching).
//                 var used_node_operands = std.bit_set.IntegerBitSet(16).initEmpty();

//                 outer: for (pattern.operands) |op_pattern| {
//                     inner: for (node_operands, 0..) |node_op_ref, i| {
//                         // If this node operand has already been matched by another pattern operand, skip.
//                         if (used_node_operands.isSet(i)) continue :inner;

//                         if (try tryMatchOperand(job, op_pattern, node_op_ref, result)) {
//                             // Found a match. Mark this operand as used and move to the next pattern operand.
//                             used_node_operands.set(i);
//                             continue :outer;
//                         }
//                     }
//                     // If we get here, it means op_pattern found no match among the unused node operands.
//                     // The entire match fails.
//                     return false;
//                 }
//             },
//         }
//     }

//     // 3. Success
//     // If we've gotten this far, all parts of the pattern have matched.
//     return true;
// }

// /// Matches a single `OperandPattern` against a live `ir.Ref`.
// pub fn tryMatchOperand(
//     job: *backend.Job,
//     pattern: OperandPattern,
//     ref: ir.Ref,
//     result: *MatchResult,
// ) anyerror!bool {
//     const node_kind = ref.node_kind;
//     switch (pattern) {
//         .any => return true,
//         .capture => |id| {
//             // Capture the ref. If the same ID is captured twice with different refs, it's a failure.
//             // (e.g., matching `i_add(?x, ?x)` against `i_add(A, B)`).
//             if (result.captures.get(id)) |existing_ref| {
//                 return existing_ref == ref;
//             } else {
//                 try result.captures.put(job.root.allocator, id, ref);
//                 return true;
//             }
//         },
//         .literal_ref => |lit_ref| {
//             return ref == lit_ref;
//         },
//         .literal_primitive => |lit_val| {
//             const node = job.context.getNode(ref) orelse return false;
//             if (node_kind.getTag() != .primitive) return false;
//             return node.content.primitive == lit_val;
//         },
//         .sub_pattern => |sub| {
//             // Recursive call for nested patterns.
//             return tryMatch(job, sub, ref, result);
//         },
//         .predicate => |pred_fn| {
//             return pred_fn(job.context, ref);
//         },
//     }
// }
