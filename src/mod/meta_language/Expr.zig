//! A meta-language expression.
//! This is a tree structure, where each node is an expression.

const Expr = @This();

const std = @import("std");
const log = std.log.scoped(.ml_expr);

const common = @import("common");
const analysis = @import("analysis");

const ml = @import("../meta_language.zig");

test {
    // std.debug.print("semantic analysis for Expr\n", .{});
    std.testing.refAllDecls(@This());
}

/// The source location of the expression.
source: analysis.Source,
/// The attributes of the expression.
/// These are used to store metadata about the expression.
attributes: common.StringMap(Expr) = .empty,
/// The data of the expression.
data: Expr.Data,

/// The variant of expression carried by an `Expr`.
/// This is a union of all possible expression types.
/// Not all syntactic combinations are semantically valid.
pub const Data = union(enum) {
    /// 64-bit signed integer literal.
    int: i64,
    /// Character literal.
    char: common.Char,
    /// String literal.
    string: []const u8,
    /// Variable reference.
    identifier: []const u8,
    /// Symbol literal.
    /// This is a special token that is simply a name, but is not a variable reference.
    /// It is used as a kind of global enum.
    symbol: []const u8,
    /// Sequenced expressions; statement list.
    seq: []Expr,
    /// Comma-separated expressions; abstract list.
    list: []Expr,
    /// Product constructor compound literal.
    tuple: []Expr,
    /// Array constructor compound literal.
    array: []Expr,
    /// Object constructor compound literal.
    compound: []Expr,
    /// Function application.
    apply: []Expr,
    /// Operator application.
    operator: Expr.Operator,
    /// Declaration.
    decl: []Expr,
    /// Assignment.
    set: []Expr,
    /// Function abstraction.
    lambda: []Expr,

    /// Determines if the expression *potentially* requires parentheses,
    /// depending on the precedence of its possible-parent.
    pub fn mayRequireParens(self: *const Data) bool {
        switch (self.*) {
            .int => return false,
            .char => return false,
            .string => return false,
            .identifier => return false,
            .symbol => return false,
            .seq => return true,
            .list => return false,
            .tuple => return false,
            .array => return false,
            .compound => return false,
            .apply => return true,
            .operator => return true,
            .decl => return true,
            .set => return true,
            .lambda => return false,
        }
    }

    /// Deinitializes the expression and its sub-expressions, freeing any allocated memory.
    pub fn deinit(self: *Data, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .int => {},
            .char => {},
            .identifier => {},
            .symbol => {},
            .string => allocator.free(self.string),
            .seq => {
                for (self.seq) |*child| child.deinit(allocator);

                allocator.free(self.seq);
            },
            .list => {
                for (self.list) |*child| child.deinit(allocator);

                allocator.free(self.list);
            },
            .tuple => {
                for (self.tuple) |*child| child.deinit(allocator);

                allocator.free(self.tuple);
            },
            .array => {
                for (self.array) |*child| child.deinit(allocator);

                allocator.free(self.array);
            },
            .compound => {
                for (self.compound) |*child| child.deinit(allocator);

                allocator.free(self.compound);
            },
            .apply => {
                for (self.apply) |*child| child.deinit(allocator);

                allocator.free(self.apply);
            },
            .operator => {
                for (self.operator.operands) |*child| child.deinit(allocator);

                allocator.free(self.operator.operands);
            },
            .decl => {
                for (self.decl) |*child| child.deinit(allocator);

                allocator.free(self.decl);
            },
            .set => {
                for (self.set) |*child| child.deinit(allocator);

                allocator.free(self.set);
            },
            .lambda => {
                for (self.lambda) |*child| child.deinit(allocator);

                allocator.free(self.lambda);
            },
        }
    }
};

/// Data for an operator application.
pub const Operator = struct {
    position: enum { prefix, infix, postfix },
    precedence: i16,
    token: analysis.Token,
    operands: []Expr,

    pub fn format(
        self: *const Operator,
        writer: *std.io.Writer,
    ) !void {
        switch (self.operands.len) {
            1 => {
                switch (self.position) {
                    .prefix => {
                        try writer.print("{s} ", .{self.token.data.sequence.asSlice()});
                        try self.operands[0].display(self.precedence, writer);
                    },
                    .postfix => {
                        try self.operands[0].display(self.precedence, writer);
                        try writer.print("{s}", .{self.token.data.sequence.asSlice()});
                    },
                    .infix => unreachable,
                }
            },
            2 => {
                switch (self.position) {
                    .prefix => {
                        try writer.print("{s} ", .{self.token.data.sequence.asSlice()});
                        try self.operands[0].display(self.precedence, writer);
                        try writer.writeByte(' ');
                        try self.operands[1].display(self.precedence, writer);
                    },
                    .postfix => {
                        try self.operands[0].display(self.precedence, writer);
                        try writer.writeByte(' ');
                        try self.operands[1].display(self.precedence, writer);
                        try writer.print(" {s}", .{self.token.data.sequence.asSlice()});
                    },
                    .infix => {
                        try self.operands[0].display(self.precedence, writer);
                        try writer.print(" {s} ", .{self.token.data.sequence.asSlice()});
                        try self.operands[1].display(self.precedence, writer);
                    },
                }
            },
            else => unreachable,
        }
    }
};

/// Deinitializes the expression and its sub-expressions, freeing any allocated memory.
pub fn deinit(self: *Expr, allocator: std.mem.Allocator) void {
    var it = self.attributes.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }

    self.attributes.deinit(allocator);
    self.data.deinit(allocator);
}

/// Returns the precedence of the expression.
pub fn precedence(self: *const Expr) i16 {
    return switch (self.data) {
        .operator => return self.data.operator.precedence,
        .int, .char, .string, .identifier, .symbol, .decl, .set, .lambda => std.math.maxInt(i16),
        .list, .tuple, .array, .compound => std.math.maxInt(i16),
        .seq => std.math.minInt(i16),
        .apply => 0,
    };
}

/// Dumps an expression as a nested tree to the given writer.
pub fn dumpTree(self: *const Expr, writer: *std.io.Writer, level: usize) !void {
    for (0..level) |_| try writer.writeAll("  ");

    switch (self.data) {
        .int => try writer.print("{d}", .{self.data.int}),
        .char => try writer.print("'{u}'", .{self.data.char}),
        .string => try writer.print("\"{s}\"", .{self.data.string}),
        .identifier => try writer.print("{s}", .{self.data.identifier}),
        .symbol => try writer.print("{s}", .{self.data.symbol}),
        .list => {
            try writer.writeAll("𝓵𝓲𝓼𝓽\n");
            for (self.data.list) |*child| {
                try child.dumpTree(writer, level + 1);
            }
        },
        .tuple => {
            try writer.writeAll("𝓽𝓾𝓹𝓵𝓮\n");
            for (self.data.tuple) |*child| {
                try child.dumpTree(writer, level + 1);
            }
        },
        .array => {
            try writer.writeAll("𝓪𝓻𝓻𝓪𝔂\n");
            for (self.data.array) |*child| {
                try child.dumpTree(writer, level + 1);
            }
        },
        .compound => {
            try writer.writeAll("𝓬𝓸𝓶𝓹𝓸𝓾𝓷𝓭\n");
            for (self.data.compound) |child| {
                try child.dumpTree(writer, level + 1);
            }
        },
        .seq => {
            try writer.writeAll("𝓼𝓮𝓺\n");
            for (self.data.seq) |*child| {
                try child.dumpTree(writer, level + 1);
            }
        },
        .apply => {
            try writer.writeAll("𝓪𝓹𝓹𝓵𝔂\n");
            for (self.data.apply) |*child| {
                try child.display(0, writer);
            }
        },
        .operator => {
            try writer.print("𝓸𝓹𝓮𝓻𝓪𝓽𝓸𝓻 {s} \n", .{self.data.operator.token.data.sequence.asSlice()});
            for (self.data.operator.operands) |*child| {
                try child.dumpTree(writer, level + 1);
            }
        },
        .decl => {
            try writer.writeAll("𝓭𝓮𝓬𝓵\n");
            for (self.data.decl) |*child| {
                try child.dumpTree(writer, level + 1);
            }
        },
        .set => {
            try writer.writeAll("𝓼𝓮𝓽\n");
            for (self.data.set) |*child| {
                try child.dumpTree(writer, level + 1);
            }
        },
        .lambda => {
            try writer.writeAll("𝓵𝓪𝓶𝓫𝓭𝓪\n");
            for (self.data.lambda) |*child| {
                try child.dumpTree(writer, level + 1);
            }
        },
    }

    try writer.writeByte('\n');
}

/// Writes a source-text representation of the expression to the given writer.
/// * This is *not* the same as the original text parsed to produce this expression;
///   it is a canonical representation of the expression.
pub fn display(self: *const Expr, bp: i16, writer: *std.io.Writer) !void {
    const need_parens = self.data.mayRequireParens() and self.precedence() < bp;

    if (need_parens) try writer.writeByte('(');

    switch (self.data) {
        .int => try writer.print("{d}", .{self.data.int}),
        .char => try writer.print("'{u}'", .{self.data.char}),
        .string => try writer.print("\"{s}\"", .{self.data.string}),
        .identifier => try writer.print("{s}", .{self.data.identifier}),
        .symbol => try writer.print("{s}", .{self.data.symbol}),
        .list => {
            try writer.writeAll("⟨ ");
            for (self.data.list) |child| {
                try writer.print("{f}, ", .{child});
            }
            try writer.writeAll("⟩");
        },
        .tuple => {
            try writer.writeAll("(");
            for (self.data.tuple, 0..) |child, i| {
                try writer.print("{f}", .{child});

                if (i < self.data.tuple.len - 1) {
                    try writer.writeAll(", ");
                } else if (self.data.tuple.len == 1) {
                    try writer.writeAll(",");
                }
            }
            try writer.writeAll(")");
        },
        .array => {
            try writer.writeAll("[ ");
            for (self.data.array) |child| {
                try writer.print("{f}, ", .{child});
            }
            try writer.writeAll("]");
        },
        .compound => {
            try writer.writeAll("{ ");
            for (self.data.compound) |child| {
                try writer.print("{f}, ", .{child});
            }
            try writer.writeAll("}");
        },
        .seq => {
            for (self.data.seq, 0..) |child, i| {
                try writer.print("{f}", .{child});
                if (i < self.data.seq.len - 1) {
                    try writer.writeAll("; ");
                }
            }
        },
        .apply => {
            for (self.data.apply, 0..) |child, i| {
                if (i > 0) try writer.writeAll(" ");
                try child.display(0, writer);
            }
        },
        .operator => try writer.print("{f}", .{self.data.operator}),
        .decl => try writer.print("{f} := {f}", .{ self.data.decl[0], self.data.decl[1] }),
        .set => try writer.print("{f} = {f}", .{ self.data.set[0], self.data.set[1] }),
        .lambda => try writer.print("fun {f}. {f}", .{ self.data.lambda[0], self.data.lambda[1] }),
    }

    if (need_parens) try writer.writeByte(')');
}

/// `std.fmt` impl
pub fn format(
    self: *const Expr,
    writer: *std.io.Writer,
) !void {
    try self.display(std.math.minInt(i16), writer);
}

/// Parse a meta-language source string to an `Expr`.
/// * Returns null if the source is empty.
/// * Returns an error if we cannot parse the entire source.
pub fn parseSource(
    allocator: std.mem.Allocator,
    lexer_settings: analysis.Lexer.Settings,
    source_name: []const u8,
    src: []const u8,
) (analysis.Parser.Error || error{ InvalidString, InvalidEscape } || std.io.Writer.Error)!?Expr {
    var parser = try ml.Cst.getRmlParser(allocator, lexer_settings, source_name, src);
    var cst = try parser.parse() orelse return null;
    defer cst.deinit(allocator);

    return try parseCst(allocator, src, &cst);
}

/// Cleans up a concrete syntax tree, producing an `Expr`.
/// This removes comments, indentation, parens and other purely-syntactic elements,
/// as well as finalizing literals, applying attributes etc.
pub fn parseCst(allocator: std.mem.Allocator, source: []const u8, cst: *const analysis.SyntaxTree) !Expr {
    switch (cst.type) {
        ml.Cst.types.Identifier => return Expr{
            .source = cst.source,
            .data = .{ .identifier = cst.token.data.sequence.asSlice() },
        },

        ml.Cst.types.Int => {
            const bytes = cst.token.data.sequence.asSlice();

            // Zig's parseInt supports our precise syntax:
            // When base is zero the string prefix is examined to detect the true base:
            // A prefix of "0b" implies base=2,
            // A prefix of "0x" implies base=16,
            // Otherwise base=10 is assumed.
            // Ignores '_' character in buf.
            const int = std.fmt.parseInt(i64, bytes, 0) catch |err| {
                // The cst parser interpreted this as an integer, meaning it starts with a decimal digit.
                // If we can't parse it as an integer, it is lexically invalid. User error.
                log.debug("parseCst: failed to parse int literal {s}: {}", .{ bytes, err });
                return error.UnexpectedInput;
            };

            return Expr{
                .source = cst.source,
                .data = .{ .int = int },
            };
        },

        ml.Cst.types.String => {
            var buf = std.io.Writer.Allocating.init(allocator);
            defer buf.deinit();

            try ml.Cst.assembleString(&buf.writer, source, cst);

            return Expr{
                .source = cst.source,
                .data = .{ .string = try buf.toOwnedSlice() },
            };
        },

        ml.Cst.types.Symbol => {
            if (cst.token.tag == .sequence) {
                const bytes = cst.token.data.sequence.asSlice();

                return Expr{
                    .source = cst.source,
                    .data = .{ .symbol = bytes },
                };
            }

            if (cst.token.tag != .special or cst.token.data.special.escaped != false) return error.UnexpectedInput;

            const char = cst.token.data.special.punctuation.toChar();
            const buf = try allocator.alloc(u8, std.unicode.utf8CodepointSequenceLength(char) catch unreachable);
            errdefer allocator.free(buf);

            _ = std.unicode.utf8Encode(char, buf) catch unreachable;

            return Expr{
                .source = cst.source,
                .data = .{ .symbol = buf },
            };
        },

        ml.Cst.types.StringElement, ml.Cst.types.StringSentinel => return error.UnexpectedInput,

        ml.Cst.types.Block => {
            if (cst.operands.len == 0) { // unit values
                if (cst.token.tag != .special or cst.token.data.special.escaped != false) return error.UnexpectedInput;

                return switch (cst.token.data.special.punctuation) {
                    .paren_l => Expr{
                        .source = cst.source,
                        .data = .{
                            .tuple = &.{},
                        },
                    },
                    .brace_l => Expr{
                        .source = cst.source,
                        .data = .{
                            .compound = &.{},
                        },
                    },
                    .bracket_l => Expr{
                        .source = cst.source,
                        .data = .{
                            .array = &.{},
                        },
                    },
                    else => return error.UnexpectedInput,
                };
            }

            if (cst.token.tag == .indentation) {
                if (cst.operands.len != 1) return error.UnexpectedInput;
                return try parseCst(allocator, source, &cst.operands.asSlice()[0]);
            }

            std.debug.assert(cst.token.tag == .special);
            std.debug.assert(cst.token.data.special.escaped == false);

            if (cst.operands.len == 1) {
                const inner = try parseCst(allocator, source, &cst.operands.asSlice()[0]);

                if (inner.data == .seq) {
                    return switch (cst.token.data.special.punctuation) {
                        .paren_l => Expr{
                            .attributes = inner.attributes,
                            .source = cst.source,
                            .data = .{ .seq = inner.data.seq },
                        },
                        .brace_l => Expr{
                            .attributes = inner.attributes,
                            .source = cst.source,
                            .data = .{ .seq = inner.data.seq },
                        },
                        .bracket_l => return error.UnexpectedInput,
                        else => return error.UnexpectedInput,
                    };
                } else if (inner.data == .list) {
                    return switch (cst.token.data.special.punctuation) {
                        .paren_l => Expr{
                            .attributes = inner.attributes,
                            .source = cst.source,
                            .data = .{ .tuple = inner.data.list },
                        },
                        .brace_l => Expr{
                            .attributes = inner.attributes,
                            .source = cst.source,
                            .data = .{ .compound = inner.data.list },
                        },
                        .bracket_l => Expr{
                            .attributes = inner.attributes,
                            .source = cst.source,
                            .data = .{ .array = inner.data.list },
                        },
                        else => return error.UnexpectedInput,
                    };
                } else {
                    switch (cst.token.data.special.punctuation) {
                        .paren_l => return inner,
                        .brace_l => {
                            const buff = try allocator.alloc(Expr, 1);
                            buff[0] = inner;

                            return Expr{
                                .source = cst.source,
                                .data = .{ .compound = buff },
                            };
                        },
                        .bracket_l => {
                            const buff = try allocator.alloc(Expr, 1);
                            buff[0] = inner;

                            return Expr{
                                .source = cst.source,
                                .data = .{ .array = buff },
                            };
                        },
                        else => return error.UnexpectedInput,
                    }
                }
            } else return error.UnexpectedInput; // should not be possible
        },

        ml.Cst.types.List => {
            if (cst.operands.len == 0) {
                return Expr{
                    .source = cst.source,
                    .data = .{
                        .list = &.{},
                    },
                };
            }

            var subs = try allocator.alloc(Expr, cst.operands.len);
            errdefer allocator.free(subs);

            for (cst.operands.asSlice(), 0..) |*child, i| {
                subs[i] = try parseCst(allocator, source, child);
            }

            return Expr{
                .source = cst.source,
                .data = .{ .list = subs },
            };
        },

        ml.Cst.types.Seq => {
            if (cst.operands.len == 0) {
                return Expr{
                    .source = cst.source,
                    .data = .{
                        .seq = &.{},
                    },
                };
            }

            var subs = try allocator.alloc(Expr, cst.operands.len);
            errdefer allocator.free(subs);

            for (cst.operands.asSlice(), 0..) |*child, i| {
                subs[i] = try parseCst(allocator, source, child);
            }

            return Expr{
                .source = cst.source,
                .data = .{ .seq = subs },
            };
        },

        ml.Cst.types.Apply => {
            if (cst.operands.len == 0) {
                return Expr{
                    .source = cst.source,
                    .data = .{
                        .apply = &.{},
                    },
                };
            }

            var subs = try allocator.alloc(Expr, cst.operands.len);
            errdefer allocator.free(subs);

            for (cst.operands.asSlice(), 0..) |*child, i| {
                subs[i] = try parseCst(allocator, source, child);
            }

            return Expr{
                .source = cst.source,
                .data = .{ .apply = subs },
            };
        },

        ml.Cst.types.Decl => {
            const operands = cst.operands.asSlice();
            std.debug.assert(operands.len == 2);

            const name_or_pattern = try parseCst(allocator, source, &operands[0]);
            const value = try parseCst(allocator, source, &operands[1]);

            const buff = try allocator.alloc(Expr, 2);
            buff[0] = name_or_pattern;
            buff[1] = value;

            return Expr{
                .source = cst.source,
                .data = .{ .decl = buff },
            };
        },

        ml.Cst.types.Assign => {
            const operands = cst.operands.asSlice();
            std.debug.assert(operands.len == 2);

            const name_or_pattern = try parseCst(allocator, source, &operands[0]);
            const value = try parseCst(allocator, source, &operands[1]);

            const buff = try allocator.alloc(Expr, 2);
            buff[0] = name_or_pattern;
            buff[1] = value;

            return Expr{
                .source = cst.source,
                .data = .{ .set = buff },
            };
        },

        ml.Cst.types.Lambda => {
            const operands = cst.operands.asSlice();
            std.debug.assert(operands.len == 2);

            const name_or_pattern = try parseCst(allocator, source, &operands[0]);
            const value = try parseCst(allocator, source, &operands[1]);

            const buff = try allocator.alloc(Expr, 2);
            buff[0] = name_or_pattern;
            buff[1] = value;

            return Expr{
                .source = cst.source,
                .data = .{ .lambda = buff },
            };
        },

        ml.Cst.types.Prefix => {
            const operands = cst.operands.asSlice();
            std.debug.assert(operands.len == 1);

            const inner = try parseCst(allocator, source, &operands[0]);

            const buff = try allocator.alloc(Expr, 1);
            buff[0] = inner;

            return Expr{
                .source = cst.source,
                .data = .{ .operator = .{
                    .position = .prefix,
                    .token = cst.token,
                    .precedence = cst.precedence,
                    .operands = buff,
                } },
            };
        },

        ml.Cst.types.Binary => {
            const operands = cst.operands.asSlice();
            std.debug.assert(operands.len == 2);

            const left = try parseCst(allocator, source, &operands[0]);
            const right = try parseCst(allocator, source, &operands[1]);

            const buff = try allocator.alloc(Expr, 2);
            buff[0] = left;
            buff[1] = right;

            return Expr{
                .source = cst.source,
                .data = .{ .operator = .{
                    .position = .infix,
                    .token = cst.token,
                    .precedence = cst.precedence,
                    .operands = buff,
                } },
            };
        },

        else => {
            log.debug("parseCst: unexpected cst type {f}", .{cst.type});
            unreachable;
        },
    }
}
