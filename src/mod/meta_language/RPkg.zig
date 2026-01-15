//! In-memory representation of a parsed `.rpkg` package definition file, and the cst parser to construct it.

const RPkg = @This();

const std = @import("std");
const log = std.log.scoped(.package_def);

const common = @import("common");
const analysis = @import("analysis");
const ir = @import("ir");

const ml = @import("../meta_language.zig");

test {
    // std.debug.print("semantic analysis for RPkg\n", .{});
    std.testing.refAllDecls(@This());
}