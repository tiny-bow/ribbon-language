//! A language-agnostic concrete syntax tree node yielded by a parser.

const SyntaxTree = @This();

const std = @import("std");
const log = std.log.scoped(.syntax_tree);

const common = @import("common");

const analysis = @import("../analysis.zig");

test {
    // std.debug.print("semantic analysis for SyntaxTree\n", .{});
    std.testing.refAllDecls(@This());
}

/// Id indicating the type of a syntax tree node.
pub const Type = common.Id.of(SyntaxTree, 16);

/// A buffer of syntax tree nodes, used to store the results of parsing.
pub const Buffer = common.Buffer.of(SyntaxTree, .constant);

/// The source location where the expression began.
source: analysis.Source,
/// The source precedence of this expression.
precedence: i16,
/// The type of the expression.
type: Type,
/// The token that generated this expression.
token: analysis.Token,
/// Subexpressions of this expression, if any.
operands: Buffer,
/// Attributes associated with this syntax tree node.
attributes: []const analysis.Attribute = &.{},

/// Deinitialize the sub-tree of this expression and free all memory allocated for it.
pub fn deinit(self: *SyntaxTree, allocator: std.mem.Allocator) void {
    const xs = @constCast(self.operands.asSlice());
    for (xs) |*x| x.deinit(allocator);
    if (xs.len != 0) {
        // empty buffer != empty slice
        allocator.free(xs);
    }
    allocator.free(self.attributes);
}

/// `std.fmt` impl
pub fn format(self: *const SyntaxTree, writer: *std.io.Writer) !void {
    if (self.operands.len == 0) {
        try writer.print("﴾{d}, {f}﴿", .{ @intFromEnum(self.type), self.token });
    } else {
        try writer.print("﴾{d}, {f}, {any}﴿", .{ @intFromEnum(self.type), self.token, self.operands.asSlice() });
    }
}
