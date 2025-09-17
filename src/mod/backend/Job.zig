//! Data local to the compilation of a specific set of values. Created by `Service`, reusable.

const Job = @This();

const std = @import("std");

const backend = @import("../backend.zig");

const core = @import("core");
const common = @import("common");
const ir = @import("ir");

test {
    // std.debug.print("semantic analysis for backend Job\n", .{});
    std.testing.refAllDecls(@This());
}

/// The root service storing common state between jobs
root: *backend.Service,
/// Identifies the job, used to ensure that the job is not reused after it has been compiled.
id: backend.ArtifactId,
/// The ir segment being compiled
context: *ir.Context,
/// A queue for nodes to be deleted
to_delete: common.UniqueReprSet(ir.Ref) = .empty,

/// Reset the job-local state for the compilation of a new set of values.
pub fn reset(self: *Job) void {
    self.context.clear();
}

/// Cancel the job, deinitializing it and freeing all memory it owns.
pub fn deinit(self: *Job) void {
    self.context.deinit();
    self.to_delete.deinit(self.root.allocator);
    self.root.allocator.destroy(self);
}

/// Allows deferred deletion of obsolete sub-trees.
/// * See also: `deleteMarkedSubtrees`
pub fn markSubtreeForDeletion(self: *Job, root_ref: ir.Ref) !void {
    var stack = common.ArrayList(ir.Ref).empty;
    defer stack.deinit(self.root.allocator);

    try stack.append(self.root.allocator, root_ref);

    while (stack.pop()) |current_ref| {
        try self.to_delete.put(self.root.allocator, current_ref, {});

        const children = self.context.getChildren(current_ref) catch continue;
        for (children) |child_ref| {
            try stack.append(self.root.allocator, child_ref);
        }
    }
}

/// Executes deferred deletions of sub-trees marked with `markSubtreeForDeletion`.
pub fn deleteMarkedSubtrees(self: *Job) void {
    var it = self.to_delete.keyIterator();
    while (it.next()) |rp| {
        self.context.delNode(rp.*);
    }
    self.to_delete.clearRetainingCapacity();
}
