//! # Abi
//! This module is a namespace defining the register conventions used by Ribbon on AArch64 platforms;
//! values will be different depending if `pl.ABI` is set to `.sys_v` or `.win`.
//!
//! ## AArch64 Register reference
//! Todo
const Abi = @This();

const std = @import("std");
const log = std.log.scoped(.AArch64Abi);

const core = @import("core");

test {
    // std.debug.print("semantic analysis for AArch64/abi\n", .{});
    std.testing.refAllDeclsRecursive(@This());
}
