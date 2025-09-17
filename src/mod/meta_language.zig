//! # meta-language
//! The Ribbon Meta Language (Rml) is a compile-time meta-programming language targeting the ribbon virtual machine.
//!
//! While Ribbon does not have a `core.Value` sum type, Rml does have such a type,
//! and it is used to represent both source code and user data structures.
const meta_language = @This();

const std = @import("std");

pub const Cst = @import("meta_language/Cst.zig");
pub const Expr = @import("meta_language/Expr.zig");
pub const Value = @import("meta_language/Value.zig").Value;

test {
    // std.debug.print("semantic analysis for meta_language\n", .{});
    std.testing.refAllDeclsRecursive(@This());
}
