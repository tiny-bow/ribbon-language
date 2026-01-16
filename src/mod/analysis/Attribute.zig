//! Tracks attributes within a source file, such as comments and annotations

const Attribute = @This();

const std = @import("std");
const log = std.log.scoped(.attribute);

const common = @import("common");
const analysis = @import("../analysis.zig");

test {
    // std.debug.print("semantic analysis for attribute\n", .{});
    std.testing.refAllDecls(@This());
}

/// How an attribute was presented in the source code
kind: Kind,
/// The raw value of the attribute
value: []const u8,
/// The source location this attribute originates from
source: analysis.Source,

/// Defines how an Attribute `value` should be interpreted.
pub const Kind = union(enum) {
    /// A comment attribute, e.g. `// this is a comment`
    comment: CommentPosition,
    /// An annotation attribute, e.g. `@inline`
    annotation,
};

/// Defines where a comment attribute appears in relation to code it is attached to.
pub const CommentPosition = enum {
    /// A comment that appears on its own line
    pre,
    /// A comment that appears at the end of a line of code
    post,
};
