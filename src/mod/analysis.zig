//! Language-agnostic static analysis utilities.

const analysis = @This();

const std = @import("std");

pub const Source = @import("analysis/Source.zig");
pub const Diagnostic = @import("analysis/Diagnostic.zig");
pub const Attribute = @import("analysis/Attribute.zig");
pub const Token = @import("analysis/Token.zig");
pub const SyntaxTree = @import("analysis/SyntaxTree.zig");
pub const Lexer = @import("analysis/Lexer.zig");
pub const Parser = @import("analysis/Parser.zig");

test {
    // std.debug.print("semantic analysis for analysis\n", .{});
    std.testing.refAllDecls(@This());
}
