//! Backend compiling Ribbon IR.

const backend = @This();

const std = @import("std");
const core = @import("core");
const common = @import("common");

test {
    // std.debug.print("semantic analysis for backend\n", .{});
    std.testing.refAllDecls(@This());
}
