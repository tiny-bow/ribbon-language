//! # meta-language
//! The Ribbon Meta Language (Rml) is a compile-time meta-programming language targeting the ribbon virtual machine.
//!
//! While Ribbon does not have a `core.Value` sum type, Rml does have such a type,
//! and it is used to represent both source code and user data structures.
const meta_language = @This();

const std = @import("std");
const log = std.log.scoped(.rml);

const pl = @import("platform");
const common = @import("common");
const utils = @import("utils");
const source = @import("source");
const core = @import("core");

test {
    std.testing.refAllDeclsRecursive(@This());
}

// TODO: i think we should use nan-tagging instead;
// integers larger than 2^53 can be stored on the heap.

/// A meta-language value.
pub const Value = packed struct {
    /// Indicates the variant of `data`.
    tag: Tag,
    /// Variant-specific data, discriminated by `tag`.
    data: Data,

    /// Indicates the variant of the `data` in a `Value`.
    pub const Tag: type = std.meta.FieldEnum(Data);

    /// Variant-specific data for a `Value`.
    /// This is a union of all possible value types.
    pub const Data = packed union {
        /// 64-bit signed integer value.
        int: i64,
        /// Character value.
        char: pl.Char,
        /// String value.
        string: *Value.String,
        /// Interned symbolic value, can be compared by reference.
        symbol: *Value.String,
        /// Linear list of values.
        array: *pl.ArrayList(Value),
        /// Table of values.
        record: *pl.StringMap(Value),
        /// Function value.
        bytecode: *core.Function,
        /// Native value.
        native: core.ForeignAddress,
        /// Builtin value.
        builtin: *core.BuiltinAddress,
        /// Syntax tree.
        syntax: *source.SyntaxTree,
    };

    /// Variant data for a string `Value`.
    pub const String = opaque {
        const len_size = @sizeOf(usize);
        const len_align = @alignOf(usize);

        /// Duplicates a slice of bytes into a new string.
        pub fn init(allocator: std.mem.Allocator, value: []const u8) !*String {
            const str = try allocator.alignedAlloc(u8, len_align, value.len + len_size);
            @memcpy(str[0..len_size], std.mem.asBytes(&value.len));
            @memcpy(str[len_size..], value);

            return @ptrCast(str);
        }

        /// Deinitializes the string and frees its memory.
        pub fn deinit(self: *String, allocator: std.mem.Allocator) void {
            const l = self.len();
            allocator.free(@as([*]align(len_align) u8, @ptrCast(@alignCast(self)))[0..l + len_size]);
        }

        /// Get the length of the string.
        pub fn len(self: *const String) usize {
            return @as(*const usize, @ptrCast(@alignCast(self))).*;
        }
    };
};


/// A meta-language expression.
/// This is a tree structure, where each node is an expression.
pub const Expr = struct {
    /// The source location of the expression.
    source: source.Source,
    /// The attributes of the expression.
    /// These are used to store metadata about the expression.
    attributes: pl.StringMap(Expr) = .empty,
    /// The data of the expression.
    data: Expr.Data,

    /// The variant of expression carried by an `Expr`.
    /// This is a union of all possible expression types.
    /// Not all syntactic combinations are semantically valid.
    pub const Data = union(enum) {
        /// 64-bit signed integer literal.
        int: i64,
        /// Character literal.
        char: pl.Char,
        /// String literal.
        string: []const u8,
        /// Variable reference.
        identifier: []const u8,
        /// Symbol literal.
        /// This is a special token that is simply a name, but is not a variable reference.
        /// It is used as a kind of global enum.
        symbol: Expr.Symbol,
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

    /// Data for a symbol literal.
    pub const Symbol = union(enum) {
        punctuation: source.Punctuation,
        sequence: []const u8,

        pub fn format(
            self: *const Symbol,
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            switch (self.*) {
                .punctuation => try writer.print("{u}", .{self.punctuation.toChar()}),
                .sequence => try writer.print("{s}", .{self.sequence}),
            }
        }
    };

    /// Data for an operator application.
    pub const Operator = struct {
        position: enum { prefix, infix, postfix },
        precedence: i16,
        token: source.Token,
        operands: []Expr,

        pub fn format(
            self: *const Operator,
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
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
        switch (self.data) {
            .operator => return self.data.operator.precedence,
            .int, .char, .string, .identifier, .symbol, .decl, .set, .lambda => return std.math.maxInt(i16),
            .list, .tuple, .array, .compound => return std.math.maxInt(i16),
            .seq => return std.math.minInt(i16),
            .apply => return 0,
        }
    }

    /// Writes a source-text representation of the expression to the given writer.
    /// * This is *not* the same as the original text parsed to produce this expression;
    ///   it is a canonical representation of the expression.
    pub fn display(self: *const Expr, bp: i16, writer: anytype) !void {
        const need_parens = self.data.mayRequireParens() and self.precedence() < bp;

        if (need_parens) try writer.writeByte('(');

        switch (self.data) {
            .int => try writer.print("{d}", .{self.data.int}),
            .char => try writer.print("'{u}'", .{self.data.char}),
            .string => try writer.print("\"{s}\"", .{self.data.string}),
            .identifier => try writer.print("{s}", .{self.data.identifier}),
            .symbol => try writer.print("{}", .{self.data.symbol}),
            .list => {
                try writer.writeAll("⟨ ");
                for (self.data.list) |child| {
                    try writer.print("{}, ", .{child});
                }
                try writer.writeAll("⟩");
            },
            .tuple => {
                try writer.writeAll("(");
                for (self.data.tuple, 0..) |child, i| {
                    try writer.print("{}", .{child});

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
                    try writer.print("{}, ", .{child});
                }
                try writer.writeAll("]");
            },
            .compound => {
                try writer.writeAll("{ ");
                for (self.data.compound) |child| {
                    try writer.print("{}, ", .{child});
                }
                try writer.writeAll("}");
            },
            .seq => {
                for (self.data.seq, 0..) |child, i| {
                    try writer.print("{}", .{child});
                    if (i < self.data.seq.len - 1) {
                        try writer.writeAll("; ");
                    }
                }
            },
            .apply => {
                for (self.data.apply) |child| {
                    try child.display(0, writer);
                }
            },
            .operator => try writer.print("{}", .{self.data.operator}),
            .decl => try writer.print("{} := {}", .{self.data.decl[0], self.data.decl[1]}),
            .set => try writer.print("{} = {}", .{self.data.set[0], self.data.set[1]}),
            .lambda => try writer.print("fun {}. {}", .{self.data.lambda[0], self.data.lambda[1]}),
        }

        if (need_parens) try writer.writeByte(')');
    }

    /// `std.fmt` impl
    pub fn format(
        self: *const Expr,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try self.display(std.math.minInt(i16), writer);
    }
};

/// Cleans up a concrete syntax tree, producing an `Expr`.
/// This removes comments, indentation, parens and other purely-syntactic elements,
/// as well as finalizing literals, applying attributes etc.
pub fn parseCst(allocator: std.mem.Allocator, src: []const u8, cst: source.SyntaxTree) !Expr {
    switch (cst.type) {
        cst_types.Identifier => return Expr{
            .source = cst.source,
            .data = .{ .identifier = cst.token.data.sequence.asSlice() },
        },

        cst_types.Int => {
            const bytes = cst.token.data.sequence.asSlice();

            const int = std.fmt.parseInt(i64, bytes, 0) catch |err| {
                log.debug("parseCst: failed to parse int literal {s}: {}", .{bytes, err});
                return error.UnexpectedInput;
            };

            return Expr{
                .source = cst.source,
                .data = .{ .int = int },
            };
        },

        cst_types.String => {
            var buf = std.ArrayList(u8).init(allocator);
            defer buf.deinit();

            const writer = buf.writer();

            try assembleString(writer, src, cst);

            return Expr{
                .source = cst.source,
                .data = .{ .string = try buf.toOwnedSlice() },
            };
        },

        cst_types.Symbol => {
            if (cst.token.tag == .sequence) {
                const bytes = cst.token.data.sequence.asSlice();

                return Expr{
                   .source = cst.source,
                    .data = .{ .symbol = .{
                        .sequence = bytes,
                    } },
                };
            }

            if (cst.token.tag != .special
            or  cst.token.data.special.escaped != false) return error.UnexpectedInput;

            return Expr{
               .source = cst.source,
                .data = .{ .symbol = .{
                    .punctuation = cst.token.data.special.punctuation,
                } },
            };
        },

        cst_types.StringElement, cst_types.StringSentinel => return error.UnexpectedInput,

        cst_types.Block => {
            if (cst.operands.len == 0) { // unit values
                if (cst.token.tag != .special
                or  cst.token.data.special.escaped != false) return error.UnexpectedInput;

                return switch (cst.token.data.special.punctuation) {
                    .paren_l => Expr{
                       .source = cst.source,
                        .data = .{ .tuple = &.{}, },
                    },
                    .brace_l => Expr{
                       .source = cst.source,
                        .data = .{ .compound = &.{}, },
                    },
                    .bracket_l => Expr{
                       .source = cst.source,
                        .data = .{ .array = &.{}, },
                    },
                    else => return error.UnexpectedInput,
                };
            }

            if (cst.token.tag == .indentation) {
                if (cst.operands.len != 1) return error.UnexpectedInput;
                return try parseCst(allocator, src, cst.operands.asSlice()[0]);
            }

            std.debug.assert(cst.token.tag == .special);
            std.debug.assert(cst.token.data.special.escaped == false);

            if (cst.operands.len == 1) {
                const inner = try parseCst(allocator, src, cst.operands.asSlice()[0]);

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

        cst_types.List => {
            if (cst.operands.len == 0) {
                return Expr{
                   .source = cst.source,
                    .data = .{ .list = &.{}, },
                };
            }

            var subs = try allocator.alloc(Expr, cst.operands.len);
            errdefer allocator.free(subs);

            for (cst.operands.asSlice(), 0..) |child, i| {
                subs[i] = try parseCst(allocator, src, child);
            }

            return Expr{
               .source = cst.source,
                .data = .{ .list = subs },
            };
        },

        cst_types.Seq => {
            if (cst.operands.len == 0) {
                return Expr{
                   .source = cst.source,
                    .data = .{ .seq = &.{}, },
                };
            }

            var subs = try allocator.alloc(Expr, cst.operands.len);
            errdefer allocator.free(subs);

            for (cst.operands.asSlice(), 0..) |child, i| {
                subs[i] = try parseCst(allocator, src, child);
            }

            return Expr{
               .source = cst.source,
                .data = .{ .seq = subs },
            };
        },

        cst_types.Apply => {
            if (cst.operands.len == 0) {
                return Expr{
                   .source = cst.source,
                    .data = .{ .apply = &.{}, },
                };
            }

            var subs = try allocator.alloc(Expr, cst.operands.len);
            errdefer allocator.free(subs);

            for (cst.operands.asSlice(), 0..) |child, i| {
                subs[i] = try parseCst(allocator, src, child);
            }

            return Expr{
               .source = cst.source,
                .data = .{ .apply = subs },
            };
        },

        cst_types.Decl => {
            const operands = cst.operands.asSlice();
            std.debug.assert(operands.len == 2);

            const name_or_pattern = try parseCst(allocator, src, operands[0]);
            const value = try parseCst(allocator, src, operands[1]);

            const buff = try allocator.alloc(Expr, 2);
            buff[0] = name_or_pattern;
            buff[1] = value;

            return Expr{
               .source = cst.source,
                .data = .{ .decl = buff },
            };
        },

        cst_types.Set => {
            const operands = cst.operands.asSlice();
            std.debug.assert(operands.len == 2);

            const name_or_pattern = try parseCst(allocator, src, operands[0]);
            const value = try parseCst(allocator, src, operands[1]);

            const buff = try allocator.alloc(Expr, 2);
            buff[0] = name_or_pattern;
            buff[1] = value;

            return Expr{
               .source = cst.source,
                .data = .{ .set = buff },
            };
        },

        cst_types.Lambda => {
            const operands = cst.operands.asSlice();
            std.debug.assert(operands.len == 2);

            const name_or_pattern = try parseCst(allocator, src, operands[0]);
            const value = try parseCst(allocator, src, operands[1]);

            const buff = try allocator.alloc(Expr, 2);
            buff[0] = name_or_pattern;
            buff[1] = value;

            return Expr{
               .source = cst.source,
                .data = .{ .lambda = buff },
            };
        },

        cst_types.Prefix => {
            const operands = cst.operands.asSlice();
            std.debug.assert(operands.len == 1);

            const inner = try parseCst(allocator, src, operands[0]);

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

        cst_types.Binary => {
            const operands = cst.operands.asSlice();
            std.debug.assert(operands.len == 2);

            const left = try parseCst(allocator, src, operands[0]);
            const right = try parseCst(allocator, src, operands[1]);

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
            log.debug("parseCst: unexpected cst type {}", .{cst.type});
            unreachable;
        },
    }
}

/// Dumps an rml concrete syntax tree to a string.
pub fn dumpCstSExprs(src: []const u8, cst: source.SyntaxTree, writer: anytype) !void {
    switch(cst.type) {
        cst_types.Identifier, cst_types.Int => try writer.print("{s}", .{cst.token.data.sequence.asSlice()}),
        cst_types.String => {
            try writer.print("{u}", .{cst.token.data.special.punctuation.toChar()});
            try assembleString(writer, src, cst);
            try writer.print("{u}", .{cst.token.data.special.punctuation.toChar()});
        },
        cst_types.Block => switch (cst.token.tag) {
            .indentation => try writer.print("{u}", .{cst.token.data.indentation.toChar()}),
            .special => try writer.print("{u}", .{cst.token.data.special.punctuation.toChar()}),
            else => unreachable,
        },
        cst_types.Seq => try writer.writeAll("⟨𝓼𝓮𝓺"),
        cst_types.Apply => try writer.writeAll("⟨𝓪𝓹𝓹"),
        cst_types.Decl => try writer.writeAll("⟨𝓭𝓮𝓬𝓵"),
        cst_types.Set => try writer.writeAll("⟨𝓼𝓮𝓽"),
        cst_types.List => try writer.writeAll("⟨𝓵𝓲𝓼𝓽"),
        cst_types.Lambda => try writer.writeAll("⟨λ"),
        cst_types.Symbol => {
            try writer.writeAll("'");
            switch (cst.token.tag) {
                .special => {
                    if (cst.token.data.special.escaped) {
                        try writer.print("\\{u}", .{cst.token.data.special.punctuation.toChar()});
                    } else {
                        try writer.print("{u}", .{cst.token.data.special.punctuation.toChar()});
                    }
                },
                .sequence => try writer.print("{s}", .{cst.token.data.sequence.asSlice()}),
                else => unreachable,
            }
            return;
        },
        else => {
            switch (cst.token.tag) {
                .sequence => {
                    try writer.writeAll("⟨");
                    try writer.print("{s}", .{cst.token.data.sequence.asSlice()});
                },
                else => try writer.print("⟨{}", .{cst.token}),
            }
        },
    }

    switch (cst.type) {
        cst_types.String, cst_types.Identifier, cst_types.Int => return,
        cst_types.Block => {
            for (cst.operands.asSlice(), 0..) |child, i| {
                if (i > 0) try writer.writeByte(' ');
                try dumpCstSExprs(src, child, writer);
            }

            switch (cst.token.tag) {
                .indentation => try writer.print("{u}", .{cst.token.data.indentation.invert().toChar()}),
                .special => try writer.print("{u}", .{cst.token.data.special.punctuation.invert().?.toChar()}),
                else => unreachable,
            }
        },
        else => {
            for (cst.operands.asSlice()) |child| {
                try writer.writeByte(' ');
                try dumpCstSExprs(src, child, writer);
            }

            try writer.writeAll("⟩");
        }
    }
}

/// Get the syntax for the meta-language.
pub fn getSyntax() *const source.Syntax {
    const static = struct {
        pub var syntax_mutex = std.Thread.Mutex{};
        pub var syntax: ?source.Syntax = null;
    };

    static.syntax_mutex.lock();
    defer static.syntax_mutex.unlock();

    if (static.syntax) |*s| {
        return s;
    }

    var out = source.Syntax.init(std.heap.page_allocator);

    inline for (nuds()) |nud| {
        out.bindNud(nud) catch unreachable;
    }

    inline for (leds()) |led| {
        out.bindLed(led) catch unreachable;
    }

    static.syntax = out;

    return &static.syntax.?;
}

/// Get a parser for the meta-language.
pub fn getParser(
    allocator: std.mem.Allocator,
    lexer_settings: source.LexerSettings,
    source_name: []const u8,
    src: []const u8,
) source.SyntaxError!source.Parser {
    const ml_syntax = getSyntax();
    return ml_syntax.createParser(allocator, lexer_settings, src, .{
        .ignore_space = false,
        .source_name = source_name,
    });
}

/// Parse a meta-language source string to a concrete syntax tree.
/// * Returns null if the source is empty.
/// * Returns an error if we cannot parse the entire source.
pub fn getCst(
    allocator: std.mem.Allocator,
    lexer_settings: source.LexerSettings,
    source_name: []const u8,
    src: []const u8,
) source.SyntaxError!?source.SyntaxTree {
    var parser = try getParser(allocator, lexer_settings, source_name, src);

    const out = parser.pratt(std.math.minInt(i16));

    if (std.debug.runtime_safety) {
        log.debug("getCst: parser result: {!?}", .{out});

        if (std.meta.isError(out) or (try out) == null or !parser.isEof()) {
            log.debug("getCst: parser result was null or error, or did not consume input {} {} {}", .{ std.meta.isError(out), if (!std.meta.isError(out)) (try out) == null else false, !parser.isEof() });

            if (parser.lexer.peek()) |maybe_cached_token| {
                if (maybe_cached_token) |cached_token| {
                    log.debug("getCst: unused token in lexer cache {}: `{s}` ({x})", .{parser.lexer.inner.location, cached_token, cached_token});
                }
            } else |err| {
                log.debug("syntax error: {}", .{err});
            }

            const rem = src[parser.lexer.inner.location.buffer..];

            if (parser.lexer.inner.iterator.peek_cache) |cached_char| {
                log.debug("getCst: unused character in lexer cache {}: `{u}` ({x})", .{parser.lexer.inner.location, cached_char, cached_char});
            } else if (rem.len > 0) {
                log.debug("getCst: unexpected input after parsing {}: `{s}` ({any})", .{parser.lexer.inner.location, rem, rem});
            }
        }
    }

    return try out;
}

/// Parse a meta-language source string to an `Expr`.
/// * Returns null if the source is empty.
/// * Returns an error if we cannot parse the entire source.
pub fn getExpr(
    allocator: std.mem.Allocator,
    lexer_settings: source.LexerSettings,
    source_name: []const u8,
    src: []const u8,
) (source.SyntaxError || error { InvalidString, InvalidEscape })!?Expr {
    var cst = try getCst(allocator, lexer_settings, source_name, src) orelse return null;
    defer cst.deinit(allocator);

    return try parseCst(allocator, src, cst);
}

/// rml concrete syntax tree types.
pub const cst_types = gen: {
    var fresh = common.Id.of(source.SyntaxTree).fromInt(0);

    break :gen .{
        .Int = fresh.next(),
        .String = fresh.next(),
        .StringElement = fresh.next(),
        .StringSentinel = fresh.next(),
        .Identifier = fresh.next(),
        .Block = fresh.next(),
        .Seq = fresh.next(),
        .List = fresh.next(),
        .Apply = fresh.next(),
        .Binary = fresh.next(),
        .Prefix = fresh.next(),
        .Decl = fresh.next(),
        .Set = fresh.next(),
        .Lambda = fresh.next(),
        .Symbol = fresh.next(),
    };
};

// comptime {
//     for (std.meta.fieldNames(@TypeOf(cst_types))) |name| {
//         const value = @field(cst_types, name);
//         @compileLog(name, value);
//     }
// }

/// Assembles an rml concrete syntax tree string literal into a buffer.
/// * This requires the start and end components of the provided syntax tree to be from the same source buffer;
///   other contents are ignored, and the string is assembled from the intermediate source text.
pub fn assembleString(writer: anytype, src: []const u8, string: source.SyntaxTree) !void {
    std.debug.assert(string.type == cst_types.String);

    const subexprs = string.operands.asSlice();

    if (!std.mem.eql(u8, subexprs[0].source.name, subexprs[subexprs.len - 1].source.name)) {
        log.err("assembleString: input string tree has mismatched source origins, {} and {}", .{
            subexprs[0],
            subexprs[subexprs.len - 1],
        });
        return error.InvalidString;
    }

    const start_loc = subexprs[0].source.location;
    const end_loc = subexprs[subexprs.len - 1].source.location;

    if (start_loc.buffer > end_loc.buffer or end_loc.buffer > src.len) {
        log.err("assembleString: invalid string {} -> {}", .{start_loc, end_loc});
        return error.InvalidString;
    }

    const sub = src[start_loc.buffer..end_loc.buffer];

    var char_it = source.CodepointIterator.from(sub);

    while (try char_it.next()) |ch| {
        if (ch == '\\') {
            if (try char_it.next()) |next_ch| {
                switch (next_ch) {
                    '\\' => try writer.writeByte('\\'),
                    'n' => try writer.writeByte('\n'),
                    't' => try writer.writeByte('\t'),
                    'r' => try writer.writeByte('\r'),
                    '"' => try writer.writeByte('"'),
                    '\'' => try writer.writeByte('\''),
                    '0' => try writer.writeByte(0),
                    else => return error.InvalidEscape,
                }
            } else {
                return error.InvalidEscape;
            }
        } else {
            var buf = [1]u8{0} ** 4;
            const len = std.unicode.utf8Encode(ch, &buf) catch unreachable;
            try writer.writeAll(buf[0..len]);
        }
    }
}

/// creates rml prefix/atomic parser defs.
pub fn nuds() [10]source.Nud {
    return .{
        source.createNud(
            "builtin_function",
            std.math.maxInt(i16),
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("fun") } } },
            null, struct {
                pub fn function(
                    parser: *source.Parser,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("function: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard fn token

                    var patt = try parser.pratt(std.math.minInt(i16)) orelse {
                        log.debug("function: no pattern found; panic", .{});
                        return error.UnexpectedInput;
                    };
                    errdefer patt.deinit(parser.allocator);

                    log.debug("function: got pattern {}", .{patt});

                    if (try parser.lexer.peek()) |next_tok| {
                        if (next_tok.tag == .special
                        and next_tok.data.special.escaped == false
                        and next_tok.data.special.punctuation == .dot) {
                            log.debug("function: found dot token {}", .{next_tok});

                            try parser.lexer.advance(); // discard dot

                            var inner = try parser.pratt(std.math.minInt(i16)) orelse {
                                log.debug("function: no inner expression found; panic", .{});
                                return error.UnexpectedEof;
                            };
                            errdefer inner.deinit(parser.allocator);

                            log.debug("function: got inner expression {}", .{inner});

                            const buff: []source.SyntaxTree = try parser.allocator.alloc(source.SyntaxTree, 2);

                            buff[0] = patt;
                            buff[1] = inner;

                            return source.SyntaxTree{
                                .source = .{ .name = parser.settings.source_name, .location = token.location },
                                .precedence = bp,
                                .type = cst_types.Lambda,
                                .token = token,
                                .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                            };
                        } else {
                            log.debug("function: expected dot token, found {}; panic", .{next_tok});
                            return error.UnexpectedInput;
                        }
                    } else {
                        log.debug("function: no dot token found; panic", .{});
                        return error.UnexpectedEof;
                    }
                }
            }.function,
        ),
        source.createNud(
            "builtin_leading_br",
            std.math.maxInt(i16),
            .{ .standard = .linebreak },
            null, struct {
                pub fn leading_br(
                    parser: *source.Parser,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("leading_br: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard linebreak

                    return source.SyntaxTree{
                        .source = .{ .name = parser.settings.source_name, .location = token.location },
                        .precedence = bp,
                        .type = .null,
                        .token = token,
                        .operands = .empty,
                    };
                }
            }.leading_br,
        ),
        source.createNud(
            "builtin_indent",
            std.math.maxInt(i16),
            .{ .standard = .{ .indentation = .{ .standard = .indent } } },
            null, struct {
                pub fn block(
                    parser: *source.Parser,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("indent: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard indent

                    var inner = try parser.pratt(std.math.minInt(i16)) orelse {
                        log.debug("indent: no inner expression found; panic", .{});
                        return error.UnexpectedEof;
                    };
                    errdefer inner.deinit(parser.allocator);

                    log.debug("indent: got {} interior, looking for end of block token", .{inner});

                    if (try parser.lexer.peek()) |next_tok| {
                        if (next_tok.tag == .indentation
                        and next_tok.data.indentation == .unindent) {
                            log.debug("indent: found end of block token {}", .{next_tok});

                            const buff: []source.SyntaxTree = try parser.allocator.alloc(source.SyntaxTree, 1);
                            buff[0] = inner;

                            try parser.lexer.advance(); // discard indent
                            return source.SyntaxTree{
                                .source = .{ .name = parser.settings.source_name, .location = token.location },
                                .precedence = bp,
                                .type = cst_types.Block,
                                .token = token,
                                .operands = .fromSlice(buff),
                            };
                        } else {
                            log.debug("indent: found unexpected token {}; panic", .{next_tok});
                            return error.UnexpectedInput;
                        }
                    } else {
                        log.debug("indent: no end of block token found; panic", .{});
                        return error.UnexpectedEof;
                    }
                }
            }.block,
        ),
        source.createNud(
            "builtin_block",
            std.math.maxInt(i16),
            .{ .standard = .{ .special = .{ .standard = .{ .escaped = .{ .standard = false }, .punctuation = .{ .any_of = &.{ .paren_l, .bracket_l, .brace_l } } } } } },
            null, struct {
                pub fn block(
                    parser: *source.Parser,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("block: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard beginning paren

                    var inner = try parser.pratt(std.math.minInt(i16)) orelse none: {
                        log.debug("block: no inner expression found", .{});
                        break :none null;
                    };
                    errdefer if (inner) |*i| i.deinit(parser.allocator);

                    log.debug("block: got {?} interior, looking for end of block token", .{inner});

                    if (try parser.lexer.peek()) |next_tok| {
                        if (next_tok.tag == .special
                        and next_tok.data.special.punctuation == token.data.special.punctuation.invert().?
                        and next_tok.data.special.escaped == false) {
                            log.debug("block: found end of block token {}", .{next_tok});

                            try parser.lexer.advance(); // discard end paren
                            return source.SyntaxTree{
                                .source = .{ .name = parser.settings.source_name, .location = token.location },
                                .precedence = bp,
                                .type = cst_types.Block,
                                .token = token,
                                .operands = if (inner) |sub| mk_buf: {
                                    const buff: []source.SyntaxTree = try parser.allocator.alloc(source.SyntaxTree, 1);
                                    buff[0] = sub;

                                    break :mk_buf .fromSlice(buff);
                                } else .empty,
                            };
                        } else {
                            log.debug("block: found unexpected token {}; panic", .{next_tok});
                            return error.UnexpectedInput;
                        }
                    } else {
                        log.debug("block: no end of block token found; panic", .{});
                        return error.UnexpectedEof;
                    }
                }
            }.block,
        ),
        source.createNud(
            "builtin_single_quote",
            std.math.maxInt(i16),
            .{ .standard = .{ .special = .{ .standard = .{ .escaped = .{ .standard = false }, .punctuation = .{ .standard = .single_quote } } } } },
            null, struct {
                pub fn quote(
                    parser: *source.Parser,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("single_quote: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard beginning quote

                    const content = try parser.lexer.next() orelse {
                        log.debug("single_quote: no content found; panic", .{});
                        return error.UnexpectedEof;
                    };

                    log.debug("single_quote: found content token {}", .{content});

                    var require_literal = false;
                    var consume_next = false;

                    var require_symbol = false;

                    switch (content.tag) {
                        .special => {
                            if (content.data.special.escaped) {
                                log.debug("single_quote: found escaped token {}", .{content});
                                require_literal = true;
                            } else {
                                log.debug("single_quote: found punctuation, unescaped {}", .{content});

                                if (content.data.special.punctuation == .backslash) {
                                    log.debug("single_quote: found unescaped backslash token; expect escape sequence char literal", .{});
                                    consume_next = true;
                                    require_literal = true;
                                } else if (content.data.special.punctuation == .single_quote) {
                                    log.debug("single_quote: found end quote token {}", .{content});

                                    const is_space = content.location.buffer > token.location.buffer + 1;
                                    if (!is_space) {
                                        log.debug("token {} not expected with no space between proceeding token; panic", .{content});
                                        return error.UnexpectedInput;
                                    }

                                    log.debug("single_quote: found end quote token {} with space between proceeding token", .{content});

                                    require_literal = true;
                                }
                            }
                        },
                        .sequence => {
                            if (content.data.sequence.len > 1) {
                                log.debug("single_quote: content is seq > 1, must be a symbol", .{});
                                require_symbol = true;
                            }
                        },
                        else => {
                            log.debug("single_quote: found unexpected token {}; panic", .{content});
                            return error.UnexpectedInput;
                        },
                    }

                    if (require_literal) {
                        log.debug("single_quote: require literal - content token {}", .{content});

                        const secondary = if (consume_next) consume: {
                            log.debug("single_quote: required to consume next token", .{});

                            break :consume try parser.lexer.next() orelse {
                                log.debug("single_quote: no secondary token found; panic", .{});
                                return error.UnexpectedEof;
                            };
                        } else null;

                        const end_quote = try parser.lexer.next() orelse {
                            log.debug("single_quote: no end quote found; panic", .{});
                            return error.UnexpectedEof;
                        };

                        if (end_quote.tag != .special
                        or  end_quote.data.special.escaped != false
                        or  end_quote.data.special.punctuation != .single_quote) {
                            log.debug("single_quote: expected single quote to end literal, found {}; panic", .{end_quote});
                            return error.UnexpectedInput;
                        }

                        const buff = try parser.allocator.alloc(source.SyntaxTree, if (consume_next) 3 else 2);

                        buff[0] = .{
                            .source = .{ .name = parser.settings.source_name, .location = content.location },
                            .precedence = std.math.maxInt(i16),
                            .type = cst_types.StringElement,
                            .token = content,
                            .operands = .empty,
                        };
                        var i: usize = 1;
                        if (secondary) |s| {
                            buff[i] = .{
                                .source = .{ .name = parser.settings.source_name, .location = s.location },
                                .precedence = std.math.maxInt(i16),
                                .type = cst_types.StringElement,
                                .token = s,
                                .operands = .empty,
                            };
                            i += 1;
                        }
                        buff[i] = .{
                            .source = .{ .name = parser.settings.source_name, .location = end_quote.location },
                            .precedence = std.math.maxInt(i16),
                            .type = cst_types.StringSentinel,
                            .token = end_quote,
                            .operands = .empty,
                        };

                        return source.SyntaxTree{
                            .source = .{ .name = parser.settings.source_name, .location = token.location },
                            .precedence = bp,
                            .type = cst_types.String,
                            .token = token,
                            .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                        };
                    } else if (require_symbol) {
                        log.debug("single_quote: require symbol token {}", .{content});

                        return source.SyntaxTree{
                            .source = .{ .name = parser.settings.source_name, .location = token.location },
                            .precedence = bp,
                            .type = cst_types.Symbol,
                            .token = content,
                            .operands = .empty,
                        };
                    }

                    log.debug("single_quote: not explicitly a literal or symbol, checking for end quote", .{});

                    if (try parser.lexer.peek()) |end_tok| {
                        if (end_tok.tag == .special
                        and end_tok.data.special.escaped == false
                        and end_tok.data.special.punctuation == .single_quote) {
                            log.debug("single_quote: found end of quote token {}", .{end_tok});

                            try parser.lexer.advance(); // discard end quote

                            const buff = try parser.allocator.alloc(source.SyntaxTree, 2);
                            buff[0] = .{
                                .source = .{ .name = parser.settings.source_name, .location = content.location },
                                .precedence = std.math.maxInt(i16),
                                .type = cst_types.StringElement,
                                .token = content,
                                .operands = .empty,
                            };

                            buff[1] = .{
                                .source = .{ .name = parser.settings.source_name, .location = end_tok.location },
                                .precedence = std.math.maxInt(i16),
                                .type = cst_types.StringSentinel,
                                .token = end_tok,
                                .operands = .empty,
                            };

                            return source.SyntaxTree{
                                .source = .{ .name = parser.settings.source_name, .location = token.location },
                                .precedence = bp,
                                .type = cst_types.String,
                                .token = token,
                                .operands = .fromSlice(buff),
                            };
                        } else {
                            log.debug("single_quote: found unexpected token {}; not a char literal", .{end_tok});
                        }
                    } else {
                        log.debug("single_quote: no end quote token found; not a char literal", .{});
                    }

                    return source.SyntaxTree{
                        .source = .{ .name = parser.settings.source_name, .location = token.location },
                        .precedence = bp,
                        .type = cst_types.Symbol,
                        .token = content,
                        .operands = .empty,
                    };
                }
            }.quote,
        ),
        source.createNud(
            "builtin_string",
            std.math.maxInt(i16),
            .{ .standard = .{ .special = .{ .standard = .{ .escaped = .{ .standard = false }, .punctuation = .{ .standard = .double_quote } } } } },
            null, struct {
                pub fn string(
                    parser: *source.Parser,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("string: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard beginning quote

                    var buff: pl.ArrayList(source.SyntaxTree) = .empty;
                    defer buff.deinit(parser.allocator);

                    while (try parser.lexer.next()) |next_token| {
                        if (next_token.tag == .special
                        and !next_token.data.special.escaped
                        and next_token.data.special.punctuation == token.data.special.punctuation) {
                            log.debug("string: found end of string token {}", .{next_token});

                            try buff.append(parser.allocator, source.SyntaxTree{
                                .source = .{ .name = parser.settings.source_name, .location = next_token.location },
                                .precedence = bp,
                                .type = cst_types.StringSentinel,
                                .token = next_token,
                                .operands = .empty,
                            });

                            return source.SyntaxTree{
                                .source = .{ .name = parser.settings.source_name, .location = token.location },
                                .precedence = bp,
                                .type = cst_types.String,
                                .token = token,
                                .operands = .fromSlice(try buff.toOwnedSlice(parser.allocator)),
                            };
                        } else {
                            try buff.append(parser.allocator, source.SyntaxTree{
                                .source = .{ .name = parser.settings.source_name, .location = next_token.location },
                                .precedence = bp,
                                .type = cst_types.StringElement,
                                .token = next_token,
                                .operands = .empty,
                            });
                        }
                    } else {
                        log.debug("string: no end of string token found", .{});
                        return error.UnexpectedEof;
                    }
                }
            }.string,
        ),
        source.createNud(
            "builtin_leaf",
            std.math.maxInt(i16),
            .{ .standard = .{ .sequence = .any } },
            null, struct {
                pub fn leaf(
                    parser: *source.Parser,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("leaf: parsing token", .{});
                    log.debug("{}", .{token});
                    const s = token.data.sequence.asSlice();
                    log.debug("leaf: checking token {s}", .{s});

                    try parser.lexer.advance(); // discard leaf

                    const first_char = utils.text.nthCodepoint(0, s) catch unreachable orelse unreachable;

                    if (utils.text.isDecimal(first_char) and utils.text.isHexDigitStr(s)) {
                        log.debug("leaf: found int literal", .{});
                        return source.SyntaxTree{
                            .source = .{ .name = parser.settings.source_name, .location = token.location },
                            .precedence = bp,
                            .type = cst_types.Int,
                            .token = token,
                            .operands = .empty,
                        };
                    } else {
                        log.debug("leaf: found identifier {s}", .{s});

                        const applicable_nuds = try parser.syntax.findNuds(std.math.minInt(i16), &token);
                        const applicable_leds = try parser.syntax.findLeds(std.math.minInt(i16), &token);
                        if (applicable_nuds.len != 1 or applicable_leds.len != 1) {
                            log.debug("leaf: identifier {s} is bound by another pattern, rejecting", .{s});
                            return null;
                        } else {
                            log.debug("leaf: identifier {s} is not bound by another pattern; parsing as identifier", .{s});
                        }

                        return source.SyntaxTree{
                            .source = .{ .name = parser.settings.source_name, .location = token.location },
                            .precedence = bp,
                            .type = cst_types.Identifier,
                            .token = token,
                            .operands = .empty,
                        };
                    }
                }
            }.leaf,
        ),
        source.createNud(
            "builtin_logical_not",
            -2999,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("not") } } },
            null, struct {
                pub fn logical_not(
                    parser: *source.Parser,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("logical_not: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard not

                    var inner = try parser.pratt(bp) orelse none: {
                        log.debug("logical_not: no inner expression found", .{});
                        break :none null;
                    };
                    errdefer if (inner) |*i| i.deinit(parser.allocator);

                    return source.SyntaxTree{
                        .source = .{ .name = parser.settings.source_name, .location = token.location },
                        .precedence = bp,
                        .type = cst_types.Prefix,
                        .token = token,
                        .operands = if (inner) |sub| mk_buf: {
                            const buff: []source.SyntaxTree = try parser.allocator.alloc(source.SyntaxTree, 1);
                            buff[0] = sub;

                            break :mk_buf .fromSlice(buff);
                        } else .empty,
                    };
                }
            }.logical_not,
        ),
        source.createNud(
            "builtin_unary_minus",
            -1999,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("-") } } },
            null, struct {
                pub fn unary_minus(
                    parser: *source.Parser,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("unary_minus: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard -

                    var inner = try parser.pratt(bp) orelse none: {
                        log.debug("unary_minus: no inner expression found", .{});
                        break :none null;
                    };
                    errdefer if (inner) |*i| i.deinit(parser.allocator);

                    return source.SyntaxTree{
                        .source = .{ .name = parser.settings.source_name, .location = token.location },
                        .precedence = bp,
                        .type = cst_types.Prefix,
                        .token = token,
                        .operands = if (inner) |sub| mk_buf: {
                            const buff: []source.SyntaxTree = try parser.allocator.alloc(source.SyntaxTree, 1);
                            buff[0] = sub;

                            break :mk_buf .fromSlice(buff);
                        } else .empty,
                    };
                }
            }.unary_minus,
        ),
        source.createNud(
            "builtin_unary_plus",
            -1999,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("+") } } },
            null, struct {
                pub fn unary_plus(
                    parser: *source.Parser,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("unary_plus: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard +

                    var inner = try parser.pratt(bp) orelse none: {
                        log.debug("unary_plus: no inner expression found", .{});
                        break :none null;
                    };
                    errdefer if (inner) |*i| i.deinit(parser.allocator);

                    return source.SyntaxTree{
                        .source = .{ .name = parser.settings.source_name, .location = token.location },
                        .precedence = bp,
                        .type = cst_types.Prefix,
                        .token = token,
                        .operands = if (inner) |sub| mk_buf: {
                            const buff: []source.SyntaxTree = try parser.allocator.alloc(source.SyntaxTree, 1);
                            buff[0] = sub;

                            break :mk_buf .fromSlice(buff);
                        } else .empty,
                    };
                }
            }.unary_plus,
        ),
    };
}

/// creates rml infix/postfix parser defs.
pub fn leds() [17]source.Led {
    return .{
        source.createLed(
            "builtin_decl_inferred_type",
            std.math.minInt(i16),
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice(":=") } } },
            null, struct {
                pub fn decl(
                    parser: *source.Parser,
                    lhs: source.SyntaxTree,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("decl: parsing token {}", .{token});

                    if (lhs.precedence == bp) {
                        log.debug("decl: lhs has same binding power; panic", .{});
                        return error.UnexpectedInput;
                    }

                    try parser.lexer.advance(); // discard operator

                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("decl: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(source.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return source.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = cst_types.Decl,
                        .token = token,
                        .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.decl,
        ),
        source.createLed(
            "builtin_set",
            std.math.minInt(i16),
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("=") } } },
            null, struct {
                pub fn set(
                    parser: *source.Parser,
                    lhs: source.SyntaxTree,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("set: parsing token {}", .{token});

                    if (lhs.precedence == bp) {
                        log.debug("set: lhs has same binding power; panic", .{});
                        return error.UnexpectedInput;
                    }

                    try parser.lexer.advance(); // discard operator

                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("set: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(source.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return source.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = cst_types.Set,
                        .token = token,
                        .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.set,
        ),
        source.createLed(
            "builtin_list",
            std.math.minInt(i16) + 100,
            .{ .standard = .{ .special = .{ .standard = .{ .escaped = .{ .standard = false }, .punctuation = .{ .standard = .comma } } } } },
            null, struct {
                pub fn list(
                    parser: *source.Parser,
                    lhs: source.SyntaxTree,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("list: lhs {}", .{lhs});

                    try parser.lexer.advance(); // discard linebreak

                    if (try parser.lexer.peek()) |next_token| {
                        if (next_token.tag == .indentation
                        and next_token.data.indentation == .unindent) {
                            log.debug("list: found unindent token, returning lhs", .{});
                            return lhs;
                        }
                    } else {
                        log.debug("list: no next token found; returning lhs", .{});
                        return lhs;
                    }

                    var rhs = if (try parser.pratt(bp)) |r| r else {
                        log.debug("list: no rhs; return singleton list", .{});
                        const buff: []source.SyntaxTree = try parser.allocator.alloc(source.SyntaxTree, 1);
                        buff[0] = lhs;
                        return source.SyntaxTree{
                            .source = lhs.source,
                            .precedence = bp,
                            .type = cst_types.List,
                            .token = token,
                            .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                        };
                    };
                    errdefer rhs.deinit(parser.allocator);

                    log.debug("list: found rhs {}", .{rhs});

                    if (lhs.type == cst_types.List and rhs.type == cst_types.List) {
                        log.debug("list: both lhs and rhs are lists, concatenating", .{});

                        const lhs_operands = lhs.operands.asSlice();
                        const rhs_operands = rhs.operands.asSlice();
                        defer parser.allocator.free(lhs_operands);
                        defer parser.allocator.free(rhs_operands);

                        const new_operands = try parser.allocator.alloc(source.SyntaxTree, lhs_operands.len + rhs_operands.len);
                        @memcpy(new_operands[0..lhs_operands.len], lhs_operands);
                        @memcpy(new_operands[lhs_operands.len..], rhs_operands);

                        return .{
                           .source = lhs.source,
                            .precedence = bp,
                            .type = cst_types.List,
                            .token = token,
                            .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(new_operands),
                        };
                    } else if (lhs.type == cst_types.List) {
                        log.debug("list: lhs is a list, concatenating rhs", .{});

                        const lhs_operands = lhs.operands.asSlice();
                        defer parser.allocator.free(lhs_operands);

                        const new_operands = try parser.allocator.alloc(source.SyntaxTree, lhs_operands.len + 1);
                        @memcpy(new_operands[0..lhs_operands.len], lhs_operands);
                        new_operands[lhs_operands.len] = rhs;

                        return .{
                            .source = lhs.source,
                            .precedence = bp,
                            .type = cst_types.List,
                            .token = token,
                            .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(new_operands),
                        };
                    } else if (rhs.type == cst_types.List) {
                        log.debug("list: rhs is a list, concatenating lhs", .{});

                        const rhs_operands = rhs.operands.asSlice();
                        defer parser.allocator.free(rhs_operands);

                        const new_operands = try parser.allocator.alloc(source.SyntaxTree, rhs_operands.len + 1);
                        new_operands[0] = lhs;
                        @memcpy(new_operands[1..], rhs_operands);

                        return .{
                           .source = lhs.source,
                            .precedence = bp,
                            .type = cst_types.List,
                            .token = token,
                            .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(new_operands),
                        };
                    } else {
                        log.debug("list: creating new list", .{});
                    }

                    const buff: []source.SyntaxTree = try parser.allocator.alloc(source.SyntaxTree, 2);

                    log.debug("list: buffer allocation {x}", .{@intFromPtr(buff.ptr)});

                    buff[0] = lhs;
                    buff[1] = rhs;

                    log.debug("list: buffer written; returning", .{});

                    return source.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = cst_types.List,
                        .token = token,
                        .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.list,
        ),
        source.createLed(
            "builtin_seq",
            std.math.minInt(i16),
            .{ .any_of = &.{
                .linebreak,
                .{ .special = .{ .standard = .{
                    .escaped = .{ .standard = false },
                    .punctuation = .{ .standard = .semicolon },
                } } },
            } },
            null, struct {
                pub fn seq(
                    parser: *source.Parser,
                    lhs: source.SyntaxTree,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("seq: lhs {}", .{lhs});

                    try parser.lexer.advance(); // discard linebreak

                    if (try parser.lexer.peek()) |next_token| {
                        if (next_token.tag == .indentation
                        and next_token.data.indentation == .unindent) {
                            log.debug("seq: found unindent token, returning lhs", .{});
                            return lhs;
                        }
                    } else {
                        log.debug("seq: no next token found; returning lhs", .{});
                        return lhs;
                    }

                    var rhs = if (try parser.pratt(std.math.minInt(i16))) |r| r else {
                        log.debug("seq: no rhs; return lhs", .{});
                        return lhs;
                    };
                    errdefer rhs.deinit(parser.allocator);

                    log.debug("seq: found rhs {}", .{rhs});

                    if (lhs.type == cst_types.Seq and rhs.type == cst_types.Seq) {
                        log.debug("seq: both lhs and rhs are seqs, concatenating", .{});

                        const lhs_operands = lhs.operands.asSlice();
                        const rhs_operands = rhs.operands.asSlice();
                        defer parser.allocator.free(lhs_operands);
                        defer parser.allocator.free(rhs_operands);

                        const new_operands = try parser.allocator.alloc(source.SyntaxTree, lhs_operands.len + rhs_operands.len);
                        @memcpy(new_operands[0..lhs_operands.len], lhs_operands);
                        @memcpy(new_operands[lhs_operands.len..], rhs_operands);

                        return .{
                           .source = lhs.source,
                            .precedence = bp,
                            .type = cst_types.Seq,
                            .token = token,
                            .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(new_operands),
                        };
                    } else if (lhs.type == cst_types.Seq) {
                        log.debug("seq: lhs is a seq, concatenating rhs", .{});

                        const lhs_operands = lhs.operands.asSlice();
                        defer parser.allocator.free(lhs_operands);

                        const new_operands = try parser.allocator.alloc(source.SyntaxTree, lhs_operands.len + 1);
                        @memcpy(new_operands[0..lhs_operands.len], lhs_operands);
                        new_operands[lhs_operands.len] = rhs;

                        return .{
                           .source = lhs.source,
                            .precedence = bp,
                            .type = cst_types.Seq,
                            .token = token,
                            .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(new_operands),
                        };
                    } else if (rhs.type == cst_types.Seq) {
                        log.debug("seq: rhs is a seq, concatenating lhs", .{});

                        const rhs_operands = rhs.operands.asSlice();
                        defer parser.allocator.free(rhs_operands);

                        const new_operands = try parser.allocator.alloc(source.SyntaxTree, rhs_operands.len + 1);
                        new_operands[0] = lhs;
                        @memcpy(new_operands[1..], rhs_operands);

                        return .{
                           .source = lhs.source,
                            .precedence = bp,
                            .type = cst_types.Seq,
                            .token = token,
                            .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(new_operands),
                        };
                    } else {
                        log.debug("seq: creating new seq", .{});
                    }

                    const buff: []source.SyntaxTree = try parser.allocator.alloc(source.SyntaxTree, 2);

                    log.debug("seq: buffer allocation {x}", .{@intFromPtr(buff.ptr)});

                    buff[0] = lhs;
                    buff[1] = rhs;

                    log.debug("seq: buffer written; returning", .{});

                    return source.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = cst_types.Seq,
                        .token = token,
                        .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.seq,
        ),
        source.createLed(
            "builtin_apply",
            0,
            .any,
            null, struct {
                pub fn apply(
                    parser: *source.Parser,
                    lhs: source.SyntaxTree,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("apply: {} {}", .{lhs, token});

                    const applicable_leds = try parser.syntax.findLeds(std.math.minInt(i16), &token);
                    if (applicable_leds.len != 1) { // self
                        log.debug("apply: found {} applicable led(s), rejecting", .{applicable_leds.len});
                        return null;
                    } else {
                        log.debug("apply: no applicable led(s) found for token {} with bp >= {}", .{token, 1});
                    }

                    var rhs = try parser.pratt(bp + 1) orelse {
                        log.debug("apply: unable to parse rhs, rejecting", .{});
                        return null;
                    };
                    errdefer rhs.deinit(parser.allocator);

                    log.debug("apply: rhs {}", .{rhs});

                    if (lhs.type == cst_types.Apply) {
                        log.debug("apply: lhs is an apply, concatenating rhs", .{});

                        const lhs_operands = lhs.operands.asSlice();
                        defer parser.allocator.free(lhs_operands);

                        const new_operands = try parser.allocator.alloc(source.SyntaxTree, lhs_operands.len + 1);
                        @memcpy(new_operands[0..lhs_operands.len], lhs_operands);
                        new_operands[lhs_operands.len] = rhs;

                        return .{
                           .source = lhs.source,
                            .precedence = bp,
                            .type = cst_types.Apply,
                            .token = token,
                            .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(new_operands),
                        };
                    } else {
                        log.debug("apply: lhs is not an apply, creating new apply", .{});
                    }

                    const buff: []source.SyntaxTree = try parser.allocator.alloc(source.SyntaxTree, 2);

                    log.debug("apply: buffer allocation {x}", .{@intFromPtr(buff.ptr)});

                    buff[0] = lhs;
                    buff[1] = rhs;

                    log.debug("apply: buffer written; returning", .{});

                    return source.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = cst_types.Apply,
                        .token = source.Token{
                            .location = token.location,
                            .tag = .sequence,
                            .data = source.TokenData{
                                .sequence = common.Id.Buffer(u8, .constant).fromSlice(" "),
                            },
                        },
                        .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.apply,
        ),
        source.createLed(
            "builtin_mul",
            -1000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("*") } } },
            null, struct {
                pub fn mul(
                    parser: *source.Parser,
                    lhs: source.SyntaxTree,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("mul: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard operator

                    const rhs = if (try parser.pratt(bp + 1)) |r| r else {
                        log.debug("mul: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(source.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = rhs;

                    return source.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.mul,
        ),
        source.createLed(
            "builtin_div",
            -1000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("/") } } },
            null, struct {
                pub fn div(
                    parser: *source.Parser,
                    lhs: source.SyntaxTree,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("div: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard operator

                    const rhs = if (try parser.pratt(bp + 1)) |r| r else {
                        log.debug("div: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(source.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = rhs;

                    return source.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.div,
        ),
        source.createLed(
            "builtin_add",
            -2000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("+") } } },
            null, struct {
                pub fn add(
                    parser: *source.Parser,
                    lhs: source.SyntaxTree,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("add: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard operator

                    const rhs = if (try parser.pratt(bp + 1)) |r| r else {
                        log.debug("add: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(source.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = rhs;

                    return source.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.add,
        ),
        source.createLed(
            "builtin_sub",
            -2000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("-") } } },
            null, struct {
                pub fn sub(
                    parser: *source.Parser,
                    lhs: source.SyntaxTree,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("sub: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard operator

                    const rhs = if (try parser.pratt(bp + 1)) |r| r else {
                        log.debug("sub: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(source.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = rhs;

                    return source.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.sub,
        ),

        source.createLed(
            "builtin_eq",
            -4001,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("==") } } },
            null, struct {
                pub fn eq(
                    parser: *source.Parser,
                    lhs: source.SyntaxTree,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("eq: parsing token {}", .{token});

                    if (lhs.precedence == bp) {
                        log.debug("eq: lhs has same binding power; panic", .{});
                        return error.UnexpectedInput;
                    }

                    try parser.lexer.advance(); // discard operator

                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("eq: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(source.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return source.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.eq,
        ),

        source.createLed(
            "builtin_neq",
            -4001,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("!=") } } },
            null, struct {
                pub fn neq(
                    parser: *source.Parser,
                    lhs: source.SyntaxTree,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("neq: parsing token {}", .{token});

                    if (lhs.precedence == bp) {
                        log.debug("neq: lhs has same binding power; panic", .{});
                        return error.UnexpectedInput;
                    }

                    try parser.lexer.advance(); // discard operator

                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("neq: no rhs, panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(source.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return source.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.neq,
        ),

        source.createLed(
            "builtin_lt",
            -4000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("<") } } },
            null, struct {
                pub fn lt(
                    parser: *source.Parser,
                    lhs: source.SyntaxTree,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("lt: parsing token {}", .{token});

                    if (lhs.precedence == bp) {
                        log.debug("lt: lhs has same binding power; panic", .{});
                        return error.UnexpectedInput;
                    }

                    try parser.lexer.advance(); // discard operator

                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("lt: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(source.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return source.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.lt,
        ),

        source.createLed(
            "builtin_gt",
            -4000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice(">") } } },
            null, struct {
                pub fn gt(
                    parser: *source.Parser,
                    lhs: source.SyntaxTree,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("gt: parsing token {}", .{token});

                    if (lhs.precedence == bp) {
                        log.debug("gt: lhs has same binding power; panic", .{});
                        return error.UnexpectedInput;
                    }

                    try parser.lexer.advance(); // discard operator

                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("gt: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(source.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return source.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.gt,
        ),

        source.createLed(
            "builtin_leq",
            -4000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("<=") } } },
            null, struct {
                pub fn leq(
                    parser: *source.Parser,
                    lhs: source.SyntaxTree,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("leq: parsing token {}", .{token});

                    if (lhs.precedence == bp) {
                        log.debug("leq: lhs has same binding power; panic", .{});
                        return error.UnexpectedInput;
                    }

                    try parser.lexer.advance(); // discard operator

                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("leq: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(source.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return source.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.leq,
        ),

        source.createLed(
            "builtin_geq",
            -4000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice(">=") } } },
            null, struct {
                pub fn geq(
                    parser: *source.Parser,
                    lhs: source.SyntaxTree,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("geq: parsing token {}", .{token});

                    if (lhs.precedence == bp) {
                        log.debug("geq: lhs has same binding power; panic", .{});
                        return error.UnexpectedInput;
                    }

                    try parser.lexer.advance(); // discard operator

                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("geq: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(source.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return source.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.geq,
        ),

        source.createLed(
            "builtin_logical_and",
            -3000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("and") } } },
            null, struct {
                pub fn logical_and(
                    parser: *source.Parser,
                    lhs: source.SyntaxTree,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("logical_and: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard operator

                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("logical_and: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(source.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return source.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.logical_and,
        ),

        source.createLed(
            "builtin_logical_or",
            -3000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("or") } } },
            null, struct {
                pub fn logical_or(
                    parser: *source.Parser,
                    lhs: source.SyntaxTree,
                    bp: i16,
                    token: source.Token,
                ) source.SyntaxError!?source.SyntaxTree {
                    log.debug("logical_or: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard operator

                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("logical_or: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(source.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return source.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(source.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.logical_or,
        ),
    };
}


test "expr_parse" {
    try pl.snapshotTest(.use_log("expr"), struct {
        pub fn testExpr(input: []const u8, expect: []const u8) !void {
            _ = .{input, expect};
            var syn = try getCst(std.testing.allocator, .{}, "test", input) orelse {
                log.err("Failed to parse source", .{});
                return error.NullCst;
            };
            defer syn.deinit(std.testing.allocator);

            var expr = try parseCst(std.testing.allocator, input, syn);
            defer expr.deinit(std.testing.allocator);

            log.info("input: {s}\nresult: {any}", .{ input, expr });

            var buf = std.ArrayList(u8).init(std.testing.allocator);
            defer buf.deinit();

            const writer = buf.writer();
            try writer.print("{any}", .{expr});

            try std.testing.expectEqualStrings(expect, buf.items);
        }
    }.testExpr, &.{
        .{ .input = "1 + 2", .expect = "1 + 2" }, // 0
        .{ .input = "1 * 2", .expect = "1 * 2" }, // 1
        .{ .input = "1 + 2 + 3", .expect = "1 + 2 + 3" }, // 2
        .{ .input = "1 - 2 * 3", .expect = "1 - 2 * 3" }, // 3
        .{ .input = "1 * 2 + 3", .expect = "1 * 2 + 3" }, // 4
        .{ .input = "(1 + 2) * 3", .expect = "(1 + 2) * 3" }, // 5
        .{ .input = "1, 2, 3", .expect = "⟨ 1, 2, 3, ⟩" }, // 6
        .{ .input = "[1, 2, 3]", .expect = "[ 1, 2, 3, ]" }, // 7
        .{ .input = "(1, 2, 3,)", .expect = "(1, 2, 3)" }, // 8
        .{ .input = "(1, )", .expect = "(1,)" }, // 9
    });
}

test "cst_parse" {
    try pl.snapshotTest(.use_log("cst"), struct {
        pub fn testCst(input: []const u8, expect: []const u8) !void {
            _ = .{ input, expect };
            var syn = try getCst(std.testing.allocator, .{}, "test", input) orelse {
                log.err("Failed to parse source", .{});
                return error.BadEncoding;
            };
            defer syn.deinit(std.testing.allocator);

            log.info("input: {s}\nresult: {}", .{
                input,
                std.fmt.Formatter(struct {
                    pub fn formatter(
                        data: struct { input: []const u8, syn: source.SyntaxTree},
                        comptime _: []const u8,
                        _: std.fmt.FormatOptions,
                        writer: anytype,
                    ) !void {
                        return dumpCstSExprs(data.input, data.syn, writer);
                    }
                }.formatter) { .data = .{ .input = input, .syn = syn } }
            });

            var buf = std.ArrayList(u8).init(std.testing.allocator);
            defer buf.deinit();

            const writer = buf.writer();

            try dumpCstSExprs(input, syn, writer);

            try std.testing.expectEqualStrings(expect, buf.items);
        }
    }.testCst, &.{
        .{ .input = "\n1", .expect = "1" }, // 0
        .{ .input = "()", .expect = "()" }, // 1
        .{ .input = "a b", .expect = "⟨𝓪𝓹𝓹 a b⟩" }, // 2
        .{ .input = "a b c", .expect = "⟨𝓪𝓹𝓹 a b c⟩" }, // 3
        .{ .input = "1 * a b", .expect = "⟨* 1 ⟨𝓪𝓹𝓹 a b⟩⟩" }, // 4
        .{ .input = "1 * (a b)", .expect = "⟨* 1 (⟨𝓪𝓹𝓹 a b⟩)⟩" }, // 5
        .{ .input = "1 + 2", .expect = "⟨+ 1 2⟩" }, // 6
        .{ .input = "1 * 2", .expect = "⟨* 1 2⟩" }, // 7
        .{ .input = "1 + 2 + 3", .expect = "⟨+ ⟨+ 1 2⟩ 3⟩" }, // 8
        .{ .input = "1 - 2 - 3", .expect = "⟨- ⟨- 1 2⟩ 3⟩" }, // 9
        .{ .input = "1 * 2 * 3", .expect = "⟨* ⟨* 1 2⟩ 3⟩" }, // 10
        .{ .input = "1 / 2 / 3", .expect = "⟨/ ⟨/ 1 2⟩ 3⟩" }, // 11
        .{ .input = "1 + 2 * 3", .expect = "⟨+ 1 ⟨* 2 3⟩⟩" }, // 12
        .{ .input = "a b := x y", .expect = "⟨𝓭𝓮𝓬𝓵 ⟨𝓪𝓹𝓹 a b⟩ ⟨𝓪𝓹𝓹 x y⟩⟩" }, // 13
        .{ .input = "a b = x y", .expect = "⟨𝓼𝓮𝓽 ⟨𝓪𝓹𝓹 a b⟩ ⟨𝓪𝓹𝓹 x y⟩⟩" }, // 14
        .{ .input = "x y\nz w", .expect = "⟨𝓼𝓮𝓺 ⟨𝓪𝓹𝓹 x y⟩ ⟨𝓪𝓹𝓹 z w⟩⟩" }, // 15
        .{ .input = "x y\nz w\n", .expect = "⟨𝓼𝓮𝓺 ⟨𝓪𝓹𝓹 x y⟩ ⟨𝓪𝓹𝓹 z w⟩⟩" }, // 16
        .{ .input = "a b\nc d\ne f\n", .expect = "⟨𝓼𝓮𝓺 ⟨𝓪𝓹𝓹 a b⟩ ⟨𝓪𝓹𝓹 c d⟩ ⟨𝓪𝓹𝓹 e f⟩⟩" }, // 17
        .{ .input = "1\n2\n3\n4\n", .expect = "⟨𝓼𝓮𝓺 1 2 3 4⟩" }, // 18
        .{ .input = "1;2;3;4;", .expect = "⟨𝓼𝓮𝓺 1 2 3 4⟩" }, // 19
        .{ .input = "1 *\n  2 + 3\n", .expect = "⟨* 1 ⌊⟨+ 2 3⟩⌋⟩" }, // 20
        .{ .input = "1 *\n  2 + 3\n4", .expect = "⟨𝓼𝓮𝓺 ⟨* 1 ⌊⟨+ 2 3⟩⌋⟩ 4⟩" }, // 21
        .{ .input = "foo(1) * 3 * 2 +\n  1 * 2\nalert \"hello world\" + 2\ntest 2 3\n", .expect = "⟨𝓼𝓮𝓺 ⟨+ ⟨* ⟨* ⟨𝓪𝓹𝓹 foo (1)⟩ 3⟩ 2⟩ ⌊⟨* 1 2⟩⌋⟩ ⟨+ ⟨𝓪𝓹𝓹 alert \"hello world\"⟩ 2⟩ ⟨𝓪𝓹𝓹 test 2 3⟩⟩" }, // 22
        .{ .input = "foo(1) * 3 * 2 + (1 * 2); alert \"hello world\" + 2; test 2 3;", .expect = "⟨𝓼𝓮𝓺 ⟨+ ⟨* ⟨* ⟨𝓪𝓹𝓹 foo (1)⟩ 3⟩ 2⟩ (⟨* 1 2⟩)⟩ ⟨+ ⟨𝓪𝓹𝓹 alert \"hello world\"⟩ 2⟩ ⟨𝓪𝓹𝓹 test 2 3⟩⟩" }, // 23
        .{ .input = "foo(1) * 3 * 2 + (1 * 2);\nalert \"hello world\" + 2;\ntest 2 3;\n", .expect = "⟨𝓼𝓮𝓺 ⟨+ ⟨* ⟨* ⟨𝓪𝓹𝓹 foo (1)⟩ 3⟩ 2⟩ (⟨* 1 2⟩)⟩ ⟨+ ⟨𝓪𝓹𝓹 alert \"hello world\"⟩ 2⟩ ⟨𝓪𝓹𝓹 test 2 3⟩⟩" }, // 24
        .{ .input = "\n\n \nfoo(1) * 3 * 2 +\n  1 * 2;\nalert \"hello\nworld\" + 2;\ntest 2 3;\n", .expect = "⟨𝓼𝓮𝓺 ⟨+ ⟨* ⟨* ⟨𝓪𝓹𝓹 foo (1)⟩ 3⟩ 2⟩ ⌊⟨* 1 2⟩⌋⟩ ⟨+ ⟨𝓪𝓹𝓹 alert \"hello\nworld\"⟩ 2⟩ ⟨𝓪𝓹𝓹 test 2 3⟩⟩" }, // 25
        .{ .input = "incr := fun x.\n  y := x + 1\n  y = y * 2\n  3 / y\n", .expect = "⟨𝓭𝓮𝓬𝓵 incr ⟨λ x ⌊⟨𝓼𝓮𝓺 ⟨𝓭𝓮𝓬𝓵 y ⟨+ x 1⟩⟩ ⟨𝓼𝓮𝓽 y ⟨* y 2⟩⟩ ⟨/ 3 y⟩⟩⌋⟩⟩" }, // 26
        .{ .input = "fun x y z. x * y * z", .expect = "⟨λ ⟨𝓪𝓹𝓹 x y z⟩ ⟨* ⟨* x y⟩ z⟩⟩" }, // 27
        .{ .input = "x, y, z", .expect = "⟨𝓵𝓲𝓼𝓽 x y z⟩" }, // 28
        .{ .input = "fun x, y, z. x, y, z", .expect = "⟨λ ⟨𝓵𝓲𝓼𝓽 x y z⟩ ⟨𝓵𝓲𝓼𝓽 x y z⟩⟩" }, // 29
        .{ .input = "fun x (y, z). Set [\n  x,\n  y,\n  z\n]", .expect = "⟨λ ⟨𝓪𝓹𝓹 x (⟨𝓵𝓲𝓼𝓽 y z⟩)⟩ ⟨𝓪𝓹𝓹 Set [⌊⟨𝓵𝓲𝓼𝓽 x y z⟩⌋]⟩⟩" }, // 30
        .{ .input = "fun x (y, z). Set\n  [ x\n  , y\n  , z\n  ]", .expect = "⟨λ ⟨𝓪𝓹𝓹 x (⟨𝓵𝓲𝓼𝓽 y z⟩)⟩ ⟨𝓪𝓹𝓹 Set ⌊[⟨𝓵𝓲𝓼𝓽 x y z⟩]⌋⟩⟩" }, // 31
        .{ .input = "x := y := z", .expect = error.UnexpectedInput }, // 32
        .{ .input = "x = y = z", .expect = error.UnexpectedInput }, // 33
        .{ .input = "x = y := z", .expect = error.UnexpectedInput }, // 34
        .{ .input = "x := y = z", .expect = error.UnexpectedInput }, // 35
        .{ .input = "x == y != z", .expect = error.UnexpectedInput }, // 36
        .{ .input = "not x and y", .expect = "⟨and ⟨not x⟩ y⟩" }, // 37
        .{ .input = "f x and - y == not w or z + 1", .expect = "⟨== ⟨and ⟨𝓪𝓹𝓹 f x⟩ ⟨- y⟩⟩ ⟨or ⟨not w⟩ ⟨+ z 1⟩⟩⟩" }, // 38
        .{ .input = "x-x", .expect = "x-x" }, // 39
        .{ .input = "- x", .expect = "⟨- x⟩" }, // 40
        .{ .input = "+ x - y", .expect = "⟨- ⟨+ x⟩ y⟩" }, // 41
        .{ .input = "'h'", .expect = "'h'" }, // 42
        .{ .input = "'\\r'", .expect = "'\r'" }, // 43
        .{ .input = "'\\n'", .expect = "'\n'" }, // 44
        .{ .input = "'\\0'", .expect = "'\x00'" }, // 45
        .{ .input = "'x", .expect = "'x" }, // 46
        .{ .input = "'\\0", .expect = error.UnexpectedEof }, // 47
        .{ .input = "'x + 'y", .expect = "⟨+ 'x 'y⟩"}, // 48
    });
}
