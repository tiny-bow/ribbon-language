const std = @import("std");
const log = std.log.scoped(.orch_integration);
const ribbon = @import("ribbon_language");
const SyntaxTree = ribbon.analysis.SyntaxTree;
const common = ribbon.common;
const analysis = ribbon.analysis;
const orch = ribbon.orchestration;

// test {
//     std.debug.print("orch_integration", .{});
// }

test "orch_init_dir" {
    var ctx = try orch.Context.init(std.testing.allocator, "src/test/script", null);
    defer ctx.deinit();

    try std.testing.expectEqualStrings(ctx.root_rel, "min.rpkg");
    try std.testing.expectStringEndsWith(ctx.rwd_path, "/src/test/script");

    try orch.cleanupCache(null);
}

test "orch_init_file" {
    var ctx = try orch.Context.init(std.testing.allocator, "src/test/script/min.rpkg", "foocache");
    defer ctx.deinit();

    try std.testing.expectEqualStrings(ctx.root_rel, "min.rpkg");
    try std.testing.expectStringEndsWith(ctx.rwd_path, "/src/test/script");

    try orch.cleanupCache("foocache");
}

test "orch_init_invalid" {
    const invalid_paths = [_][]const u8{
        "src/test/script/min.txt",
        "src/test/script/nonexistent",
    };

    for (invalid_paths) |path| {
        const result = orch.Context.init(std.testing.allocator, path, null);
        try std.testing.expectError(error.InvalidRootPkgPath, result);
    }

    try orch.cleanupCache(null);
}

test "orch_init_ambiguous" {
    const ambiguous_path = "src/test/script/ambiguous";

    const result = orch.Context.init(std.testing.allocator, ambiguous_path, null);
    try std.testing.expectError(error.AmbiguousRootPkgPath, result);

    try orch.cleanupCache(null);
}
