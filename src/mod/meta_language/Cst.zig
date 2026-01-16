const Cst = @This();

const std = @import("std");
const log = std.log.scoped(.meta_language_cst);

const rg = @import("rg");
const common = @import("common");
const analysis = @import("analysis");

const ml = @import("../meta_language.zig");

/// rml concrete syntax tree types.
pub const types = gen: {
    var fresh = analysis.SyntaxTree.Type.fromInt(0);

    break :gen .{
        .Int = fresh.next(),
        .Float = fresh.next(),
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
        .Assign = fresh.next(),
        .Lambda = fresh.next(),
        .Symbol = fresh.next(),
        .MemberAccess = fresh.next(),
        .fresh = fresh,
    };
};

/// Assembles a concrete syntax tree string literal into a buffer.
/// * This requires the start and end components of the provided syntax tree to be from the same source buffer;
///   other contents are ignored, and the string is assembled from the intermediate source text.
pub fn assembleString(writer: *std.io.Writer, source: []const u8, string: *const analysis.SyntaxTree) !void {
    std.debug.assert(string.type == types.String);

    const subexprs = string.operands.asSlice();

    if (!std.mem.eql(u8, subexprs[0].source.name, subexprs[subexprs.len - 1].source.name)) {
        log.err("assembleString: input string tree has mismatched source origins, {f} and {f}", .{
            subexprs[0],
            subexprs[subexprs.len - 1],
        });
        return error.InvalidString;
    }

    const start_loc = subexprs[0].source.location;
    const end_loc = subexprs[subexprs.len - 1].source.location;

    if (start_loc.buffer > end_loc.buffer or end_loc.buffer > source.len) {
        log.err("assembleString: invalid string {f} -> {f}", .{ start_loc, end_loc });
        return error.InvalidString;
    }

    const sub = source[start_loc.buffer..end_loc.buffer];

    var char_it = analysis.Lexer.CodepointIterator.from(sub);

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

/// Dumps a cst as a nested tree to the given writer.
pub fn dumpTree(source: []const u8, writer: *std.io.Writer, cst: *const analysis.SyntaxTree, level: usize) !void {
    const open = cst.operands.len > 0 and cst.type != types.String;

    for (0..level) |_| try writer.writeAll("  ");

    switch (cst.type) {
        types.Identifier, types.Int => {
            try writer.print("{s}", .{cst.token.data.sequence.asSlice()});
        },
        types.Float => {
            const parts = cst.operands.asSlice();
            try writer.print("{s}.{s}", .{ parts[0].token.data.sequence.asSlice(), parts[1].token.data.sequence.asSlice() });
        },
        types.String => {
            try writer.print("{u}", .{cst.token.data.special.punctuation.toChar()});
            try assembleString(writer, source, cst);
            try writer.print("{u}", .{cst.token.data.special.punctuation.toChar()});
        },
        types.Block => switch (cst.token.tag) {
            .indentation => {
                try writer.writeAll("𝓲𝓷𝓭𝓮𝓷𝓽");
            },
            .special => {
                try writer.print("{u}", .{cst.token.data.special.punctuation.toChar()});
            },
            else => unreachable,
        },
        types.Seq => {
            try writer.writeAll("𝓼𝓮𝓺");
        },
        types.Apply => {
            try writer.writeAll("𝓪𝓹𝓹");
        },
        types.Decl => {
            try writer.writeAll("𝓭𝓮𝓬𝓵");
        },
        types.Assign => {
            try writer.writeAll("𝓪𝓼𝓼𝓲𝓰𝓷");
        },
        types.List => {
            try writer.writeAll("𝓵𝓲𝓼𝓽");
        },

        types.Lambda => {
            try writer.writeAll("λ");
        },
        types.Symbol => {
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
                    try writer.print("{s}", .{cst.token.data.sequence.asSlice()});
                },
                else => try writer.print("{f}", .{cst.token}),
            }
        },
    }

    if (open) {
        const operands = cst.operands.asSlice();

        for (operands) |*child| {
            try writer.writeByte('\n');
            try dumpTree(source, writer, child, level + 1);
        }
    }
}

/// Dumps a concrete syntax tree to a string, as a sequence of nested s-expressions.
pub fn dumpSExprs(source: []const u8, writer: *std.io.Writer, cst: *const analysis.SyntaxTree) !void {
    switch (cst.type) {
        types.Identifier, types.Int => try writer.print("{s}", .{cst.token.data.sequence.asSlice()}),
        types.Float => {
            const parts = cst.operands.asSlice();
            try writer.print("{s}.{s}", .{ parts[0].token.data.sequence.asSlice(), parts[1].token.data.sequence.asSlice() });
        },
        types.String => {
            try writer.print("{u}", .{cst.token.data.special.punctuation.toChar()});
            try assembleString(writer, source, cst);
            try writer.print("{u}", .{cst.token.data.special.punctuation.toChar()});
        },
        types.Block => switch (cst.token.tag) {
            .indentation => try writer.print("{u}", .{cst.token.data.indentation.toChar()}),
            .special => try writer.print("{u}", .{cst.token.data.special.punctuation.toChar()}),
            else => unreachable,
        },
        types.Seq => try writer.writeAll("⟨𝓼𝓮𝓺"),
        types.Apply => try writer.writeAll("⟨𝓪𝓹𝓹"),
        types.Decl => try writer.writeAll("⟨𝓭𝓮𝓬𝓵"),
        types.Assign => try writer.writeAll("⟨𝓪𝓼𝓼𝓲𝓰𝓷"),
        types.List => try writer.writeAll("⟨𝓵𝓲𝓼𝓽"),

        types.Lambda => try writer.writeAll("⟨λ"),
        types.Symbol => {
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
        types.MemberAccess => try writer.writeAll("⟨𝓶𝓮𝓶𝓫𝓮𝓻"),
        else => {
            switch (cst.token.tag) {
                .sequence => {
                    try writer.writeAll("⟨");
                    try writer.print("{s}", .{cst.token.data.sequence.asSlice()});
                },
                else => try writer.print("⟨{f}", .{cst.token}),
            }
        },
    }

    switch (cst.type) {
        types.String, types.Identifier, types.Int, types.Float => return,
        types.Block => {
            for (cst.operands.asSlice(), 0..) |*child, i| {
                if (i > 0) try writer.writeByte(' ');
                try dumpSExprs(source, writer, child);
            }

            switch (cst.token.tag) {
                .indentation => try writer.print("{u}", .{cst.token.data.indentation.invert().toChar()}),
                .special => try writer.print("{u}", .{cst.token.data.special.punctuation.invert().?.toChar()}),
                else => unreachable,
            }
        },
        else => {
            for (cst.operands.asSlice()) |*child| {
                try writer.writeByte(' ');
                try dumpSExprs(source, writer, child);
            }

            try writer.writeAll("⟩");
        },
    }
}

/// Get a parser for the meta-language.
pub fn getRmlParser(
    allocator: std.mem.Allocator,
    lexer_settings: analysis.Lexer.Settings,
    source_name: []const u8,
    src: []const u8,
) analysis.Parser.Error!analysis.Parser {
    const ml_syntax = getRmlSyntax();
    return ml_syntax.createParser(allocator, lexer_settings, src, .{
        .ignore_space = false,
        .source_name = source_name,
    });
}

/// Get the syntax for the meta-language.
pub fn getRmlSyntax() *const analysis.Parser.Syntax {
    const static = struct {
        pub var syntax_mutex = std.Thread.Mutex{};
        pub var syntax: ?analysis.Parser.Syntax = null;
    };

    static.syntax_mutex.lock();
    defer static.syntax_mutex.unlock();

    if (static.syntax) |*s| {
        return s;
    }

    var out = analysis.Parser.Syntax.init(std.heap.page_allocator);

    inline for (.{
        builtin_syntax.nud.leaf(),
        builtin_syntax.nud.function(),
        builtin_syntax.nud.leading_br(),
        builtin_syntax.nud.indent(),
        builtin_syntax.nud.block(),
        builtin_syntax.nud.single_quote(),
        builtin_syntax.nud.double_quote(),
        builtin_syntax.nud.logical_not(),
        builtin_syntax.nud.negate(),
        builtin_syntax.nud.abs(),
        builtin_syntax.nud.leading_comment(),
    }) |nud| {
        out.bindNud(nud) catch unreachable;
    }

    inline for (.{
        builtin_syntax.leds.decl_inferred(),
        builtin_syntax.leds.assign(),
        builtin_syntax.leds.list(),
        builtin_syntax.leds.inline_seq_or_post_comment(),
        builtin_syntax.leds.seq(),
        builtin_syntax.leds.apply(),
        builtin_syntax.leds.mul(),
        builtin_syntax.leds.div(),
        builtin_syntax.leds.add(),
        builtin_syntax.leds.sub(),
        builtin_syntax.leds.eq(),
        builtin_syntax.leds.neq(),
        builtin_syntax.leds.lt(),
        builtin_syntax.leds.gt(),
        builtin_syntax.leds.leq(),
        builtin_syntax.leds.geq(),
        builtin_syntax.leds.logical_and(),
        builtin_syntax.leds.logical_or(),
        builtin_syntax.leds.member_access_or_float(),
    }) |led| {
        out.bindLed(led) catch unreachable;
    }

    static.syntax = out;

    return &static.syntax.?;
}

pub const builtin_syntax = struct {
    pub const nud = struct {
        pub fn function() analysis.Parser.Nud {
            return analysis.Parser.createNud(
                "rml_function",
                std.math.maxInt(i16),
                .{ .standard = .{ .sequence = .{ .standard = .fromSlice("fun") } } },
                null,
                struct {
                    pub fn function(
                        parser: *analysis.Parser,
                        bp: i16,
                        token: analysis.Token,
                    ) analysis.Parser.Error!?analysis.SyntaxTree {
                        log.debug("function: parsing token {f}", .{token});
                        try parser.lexer.advance(); // discard fn token
                        var patt = try parser.pratt(std.math.minInt(i16)) orelse {
                            log.debug("function: no pattern found; panic", .{});
                            return error.UnexpectedInput;
                        };
                        errdefer patt.deinit(parser.allocator);
                        log.debug("function: got pattern {f}", .{patt});
                        if (try parser.lexer.peek()) |next_tok| {
                            if (next_tok.tag == .special and next_tok.data.special.escaped == false and next_tok.data.special.punctuation == .dot) {
                                log.debug("function: found dot token {f}", .{next_tok});
                                try parser.lexer.advance(); // discard dot
                                var inner = try parser.pratt(std.math.minInt(i16)) orelse {
                                    log.debug("function: no inner expression found; panic", .{});
                                    return error.UnexpectedEof;
                                };
                                errdefer inner.deinit(parser.allocator);
                                log.debug("function: got inner expression {f}", .{inner});
                                const buff: []analysis.SyntaxTree = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                                buff[0] = patt;
                                buff[1] = inner;
                                return analysis.SyntaxTree{
                                    .source = .{ .name = parser.settings.source_name, .location = token.location },
                                    .precedence = bp,
                                    .type = types.Lambda,
                                    .token = token,
                                    .operands = .fromSlice(buff),
                                };
                            } else {
                                log.debug("function: expected dot token, found {f}; panic", .{next_tok});
                                return error.UnexpectedInput;
                            }
                        } else {
                            log.debug("function: no dot token found; panic", .{});
                            return error.UnexpectedEof;
                        }
                    }
                }.function,
            );
        }

        pub fn leading_br() analysis.Parser.Nud {
            return analysis.Parser.createNud(
                "rml_leading_br",
                std.math.maxInt(i16),
                .{ .standard = .linebreak },
                null,
                struct {
                    pub fn leading_br(
                        parser: *analysis.Parser,
                        bp: i16,
                        token: analysis.Token,
                    ) analysis.Parser.Error!?analysis.SyntaxTree {
                        log.debug("leading_br: parsing token {f}", .{token});
                        try parser.lexer.advance(); // discard linebreak
                        return analysis.SyntaxTree{
                            .source = .{ .name = parser.settings.source_name, .location = token.location },
                            .precedence = bp,
                            .type = .null,
                            .token = token,
                            .operands = .empty,
                        };
                    }
                }.leading_br,
            );
        }

        pub fn indent() analysis.Parser.Nud {
            return analysis.Parser.createNud(
                "rml_indent",
                std.math.maxInt(i16),
                .{ .standard = .{ .indentation = .{ .standard = .indent } } },
                null,
                struct {
                    pub fn block(
                        parser: *analysis.Parser,
                        bp: i16,
                        token: analysis.Token,
                    ) analysis.Parser.Error!?analysis.SyntaxTree {
                        log.debug("indent: parsing token {f}", .{token});
                        try parser.lexer.advance(); // discard indent
                        var inner = try parser.pratt(std.math.minInt(i16)) orelse {
                            log.debug("indent: no inner expression found; panic", .{});
                            return error.UnexpectedEof;
                        };
                        errdefer inner.deinit(parser.allocator);
                        log.debug("indent: got {f} interior, looking for end of block token", .{inner});
                        if (try parser.lexer.peek()) |next_tok| {
                            if (next_tok.tag == .indentation and next_tok.data.indentation == .unindent) {
                                log.debug("indent: found end of block token {f}", .{next_tok});
                                const buff: []analysis.SyntaxTree = try parser.allocator.alloc(analysis.SyntaxTree, 1);
                                buff[0] = inner;
                                try parser.lexer.advance(); // discard indent
                                return analysis.SyntaxTree{
                                    .source = .{ .name = parser.settings.source_name, .location = token.location },
                                    .precedence = bp,
                                    .type = types.Block,
                                    .token = token,
                                    .operands = .fromSlice(buff),
                                };
                            } else {
                                log.debug("indent: found unexpected token {f}; panic", .{next_tok});
                                return error.UnexpectedInput;
                            }
                        } else {
                            log.debug("indent: no end of block token found; panic", .{});
                            return error.UnexpectedEof;
                        }
                    }
                }.block,
            );
        }

        pub fn block() analysis.Parser.Nud {
            return analysis.Parser.createNud(
                "rml_block",
                std.math.maxInt(i16),
                .{ .standard = .{ .special = .{ .standard = .{ .escaped = .{ .standard = false }, .punctuation = .{ .any_of = &.{ .paren_l, .bracket_l, .brace_l } } } } } },
                null,
                struct {
                    pub fn block(
                        parser: *analysis.Parser,
                        bp: i16,
                        token: analysis.Token,
                    ) analysis.Parser.Error!?analysis.SyntaxTree {
                        log.debug("block: parsing token {f}", .{token});
                        try parser.lexer.advance(); // discard beginning paren
                        var inner = try parser.pratt(std.math.minInt(i16)) orelse none: {
                            log.debug("block: no inner expression found", .{});
                            break :none null;
                        };
                        errdefer if (inner) |*i| i.deinit(parser.allocator);
                        log.debug("block: got {?f} interior, looking for end of block token", .{inner});
                        if (try parser.lexer.peek()) |next_tok| {
                            if (next_tok.tag == .special and next_tok.data.special.punctuation == token.data.special.punctuation.invert().? and next_tok.data.special.escaped == false) {
                                log.debug("block: found end of block token {f}", .{next_tok});
                                try parser.lexer.advance(); // discard end paren
                                return analysis.SyntaxTree{
                                    .source = .{ .name = parser.settings.source_name, .location = token.location },
                                    .precedence = bp,
                                    .type = types.Block,
                                    .token = token,
                                    .operands = if (inner) |sub| mk_buf: {
                                        const buff: []analysis.SyntaxTree = try parser.allocator.alloc(analysis.SyntaxTree, 1);
                                        buff[0] = sub;
                                        break :mk_buf .fromSlice(buff);
                                    } else .empty,
                                };
                            } else {
                                log.debug("block: found unexpected token {f}; panic", .{next_tok});
                                return error.UnexpectedInput;
                            }
                        } else {
                            log.debug("block: no end of block token found; panic", .{});
                            return error.UnexpectedEof;
                        }
                    }
                }.block,
            );
        }

        pub fn single_quote() analysis.Parser.Nud {
            return analysis.Parser.createNud(
                "rml_single_quote",
                std.math.maxInt(i16),
                .{ .standard = .{ .special = .{ .standard = .{ .escaped = .{ .standard = false }, .punctuation = .{ .standard = .single_quote } } } } },
                null,
                struct {
                    pub fn quote(
                        parser: *analysis.Parser,
                        bp: i16,
                        token: analysis.Token,
                    ) analysis.Parser.Error!?analysis.SyntaxTree {
                        log.debug("single_quote: parsing token {f}", .{token});
                        try parser.lexer.advance(); // discard beginning quote
                        const content = try parser.lexer.next() orelse {
                            log.debug("single_quote: no content found; panic", .{});
                            return error.UnexpectedEof;
                        };
                        log.debug("single_quote: found content token {f}", .{content});
                        var require_literal = false;
                        var consume_next = false;
                        var require_symbol = false;
                        switch (content.tag) {
                            .special => {
                                if (content.data.special.escaped) {
                                    log.debug("single_quote: found escaped token {f}", .{content});
                                    require_literal = true;
                                } else {
                                    log.debug("single_quote: found punctuation, unescaped {f}", .{content});
                                    if (content.data.special.punctuation == .backslash) {
                                        log.debug("single_quote: found unescaped backslash token; expect escape sequence char literal", .{});
                                        consume_next = true;
                                        require_literal = true;
                                    } else if (content.data.special.punctuation == .single_quote) {
                                        log.debug("single_quote: found end quote token {f}", .{content});
                                        const is_space = content.location.buffer > token.location.buffer + 1;
                                        if (!is_space) {
                                            log.debug("token {f} not expected with no space between proceeding token; panic", .{content});
                                            return error.UnexpectedInput;
                                        }
                                        log.debug("single_quote: found end quote token {f} with space between proceeding token", .{content});
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
                                log.debug("single_quote: found unexpected token {f}; panic", .{content});
                                return error.UnexpectedInput;
                            },
                        }
                        if (require_literal) {
                            log.debug("single_quote: require literal - content token {f}", .{content});
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
                            if (end_quote.tag != .special or end_quote.data.special.escaped != false or end_quote.data.special.punctuation != .single_quote) {
                                log.debug("single_quote: expected single quote to end literal, found {f}; panic", .{end_quote});
                                return error.UnexpectedInput;
                            }
                            const buff = try parser.allocator.alloc(analysis.SyntaxTree, if (consume_next) 3 else 2);
                            buff[0] = .{
                                .source = .{ .name = parser.settings.source_name, .location = content.location },
                                .precedence = std.math.maxInt(i16),
                                .type = types.StringElement,
                                .token = content,
                                .operands = .empty,
                            };
                            var i: usize = 1;
                            if (secondary) |s| {
                                buff[i] = .{
                                    .source = .{ .name = parser.settings.source_name, .location = s.location },
                                    .precedence = std.math.maxInt(i16),
                                    .type = types.StringElement,
                                    .token = s,
                                    .operands = .empty,
                                };
                                i += 1;
                            }
                            buff[i] = .{
                                .source = .{ .name = parser.settings.source_name, .location = end_quote.location },
                                .precedence = std.math.maxInt(i16),
                                .type = types.StringSentinel,
                                .token = end_quote,
                                .operands = .empty,
                            };
                            return analysis.SyntaxTree{
                                .source = .{ .name = parser.settings.source_name, .location = token.location },
                                .precedence = bp,
                                .type = types.String,
                                .token = token,
                                .operands = .fromSlice(buff),
                            };
                        } else if (require_symbol) {
                            log.debug("single_quote: require symbol token {f}", .{content});
                            return analysis.SyntaxTree{
                                .source = .{ .name = parser.settings.source_name, .location = token.location },
                                .precedence = bp,
                                .type = types.Symbol,
                                .token = content,
                                .operands = .empty,
                            };
                        }
                        log.debug("single_quote: not explicitly a literal or symbol, checking for end quote", .{});
                        if (try parser.lexer.peek()) |end_tok| {
                            if (end_tok.tag == .special and end_tok.data.special.escaped == false and end_tok.data.special.punctuation == .single_quote) {
                                log.debug("single_quote: found end of quote token {f}", .{end_tok});
                                try parser.lexer.advance(); // discard end quote
                                const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                                buff[0] = .{
                                    .source = .{ .name = parser.settings.source_name, .location = content.location },
                                    .precedence = std.math.maxInt(i16),
                                    .type = types.StringElement,
                                    .token = content,
                                    .operands = .empty,
                                };
                                buff[1] = .{
                                    .source = .{ .name = parser.settings.source_name, .location = end_tok.location },
                                    .precedence = std.math.maxInt(i16),
                                    .type = types.StringSentinel,
                                    .token = end_tok,
                                    .operands = .empty,
                                };
                                return analysis.SyntaxTree{
                                    .source = .{ .name = parser.settings.source_name, .location = token.location },
                                    .precedence = bp,
                                    .type = types.String,
                                    .token = token,
                                    .operands = .fromSlice(buff),
                                };
                            } else {
                                log.debug("single_quote: found unexpected token {f}; not a char literal", .{end_tok});
                            }
                        } else {
                            log.debug("single_quote: no end quote token found; not a char literal", .{});
                        }
                        return analysis.SyntaxTree{
                            .source = .{ .name = parser.settings.source_name, .location = token.location },
                            .precedence = bp,
                            .type = types.Symbol,
                            .token = content,
                            .operands = .empty,
                        };
                    }
                }.quote,
            );
        }

        pub fn double_quote() analysis.Parser.Nud {
            return analysis.Parser.createNud(
                "rml_string",
                std.math.maxInt(i16),
                .{ .standard = .{ .special = .{ .standard = .{ .escaped = .{ .standard = false }, .punctuation = .{ .standard = .double_quote } } } } },
                null,
                struct {
                    pub fn string(
                        parser: *analysis.Parser,
                        bp: i16,
                        token: analysis.Token,
                    ) analysis.Parser.Error!?analysis.SyntaxTree {
                        log.debug("string: parsing token {f}", .{token});
                        try parser.lexer.advance(); // discard beginning quote
                        var buff: common.ArrayList(analysis.SyntaxTree) = .empty;
                        defer buff.deinit(parser.allocator);
                        while (try parser.lexer.next()) |next_token| {
                            if (next_token.tag == .special and !next_token.data.special.escaped and next_token.data.special.punctuation == token.data.special.punctuation) {
                                log.debug("string: found end of string token {f}", .{next_token});
                                try buff.append(parser.allocator, analysis.SyntaxTree{
                                    .source = .{ .name = parser.settings.source_name, .location = next_token.location },
                                    .precedence = bp,
                                    .type = types.StringSentinel,
                                    .token = next_token,
                                    .operands = .empty,
                                });
                                return analysis.SyntaxTree{
                                    .source = .{ .name = parser.settings.source_name, .location = token.location },
                                    .precedence = bp,
                                    .type = types.String,
                                    .token = token,
                                    .operands = .fromSlice(try buff.toOwnedSlice(parser.allocator)),
                                };
                            } else {
                                try buff.append(parser.allocator, analysis.SyntaxTree{
                                    .source = .{ .name = parser.settings.source_name, .location = next_token.location },
                                    .precedence = bp,
                                    .type = types.StringElement,
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
            );
        }

        pub fn logical_not() analysis.Parser.Nud {
            return unop("rml_logical_not", -2999, "not");
        }

        pub fn negate() analysis.Parser.Nud {
            return unop("rml_negate", -1999, "-");
        }

        pub fn abs() analysis.Parser.Nud {
            return unop("rml_abs", -1999, "+");
        }

        pub fn leaf() analysis.Parser.Nud {
            return analysis.Parser.createNud(
                "rml_leaf",
                std.math.maxInt(i16),
                .{ .standard = .{ .sequence = .any } },
                null,
                struct {
                    pub fn leaf(
                        parser: *analysis.Parser,
                        bp: i16,
                        token: analysis.Token,
                    ) analysis.Parser.Error!?analysis.SyntaxTree {
                        log.debug("leaf: parsing token", .{});
                        log.debug("{f}", .{token});
                        const s = token.data.sequence.asSlice();
                        log.debug("leaf: checking token {s}", .{s});
                        try parser.lexer.advance(); // discard leaf
                        const first_char = rg.nthCodepoint(0, s) catch unreachable orelse unreachable;
                        if (rg.isDecimal(first_char)) {
                            log.debug("leaf: found int literal", .{});
                            return analysis.SyntaxTree{
                                .source = .{ .name = parser.settings.source_name, .location = token.location },
                                .precedence = bp,
                                .type = types.Int,
                                .token = token,
                                .operands = .empty,
                            };
                        } else {
                            log.debug("leaf: found identifier {s}", .{s});
                            const applicable_nuds = try parser.syntax.findNuds(std.math.minInt(i16), &token);
                            const applicable_leds = try parser.syntax.findLeds(std.math.minInt(i16), &token);
                            if (applicable_nuds.len > 1 or applicable_leds.len > 1) {
                                log.debug("leaf: identifier {s} is bound by another pattern ({d} nuds / {d} leds), rejecting", .{ s, applicable_nuds.len, applicable_leds.len });
                                for (applicable_nuds) |n| {
                                    log.debug("leaf: applicable nud {s}", .{n.name});
                                }
                                for (applicable_leds) |l| {
                                    log.debug("leaf: applicable led {s}", .{l.name});
                                }
                                return null;
                            } else {
                                log.debug("leaf: identifier {s} is not bound by another pattern; parsing as identifier", .{s});
                            }
                            return analysis.SyntaxTree{
                                .source = .{ .name = parser.settings.source_name, .location = token.location },
                                .precedence = bp,
                                .type = types.Identifier,
                                .token = token,
                                .operands = .empty,
                            };
                        }
                    }
                }.leaf,
            );
        }

        pub fn leading_comment() analysis.Parser.Nud {
            return analysis.Parser.createNud(
                "rml_leading_comment",
                std.math.maxInt(i16),
                .{
                    .standard = .{
                        .special = .{
                            .standard = .{
                                .escaped = .{ .standard = false },
                                .punctuation = .{ .standard = .semicolon },
                            },
                        },
                    },
                },
                null,
                struct {
                    pub fn leading_comment(
                        parser: *analysis.Parser,
                        _: i16,
                        token: analysis.Token,
                    ) analysis.Parser.Error!?analysis.SyntaxTree {
                        log.debug("leading_comment: parsing token {f}", .{token});
                        try parser.lexer.advance(); // discard first semi
                        if (try parser.lexer.peek()) |next_token| {
                            if (next_token.tag == .special and next_token.data.special.escaped == false and next_token.data.special.punctuation == .semicolon and next_token.location.buffer == token.location.buffer + 1) {
                                log.debug("leading_comment: found second semi token {f}", .{next_token});
                                try parser.lexer.advance(); // discard second semi

                                var last = next_token;
                                var broken = false;
                                while (try parser.lexer.peek()) |maybe_endl| {
                                    last = maybe_endl;
                                    if (last.tag == .linebreak or last.tag == .indentation) {
                                        log.debug("inline_seq_or_post_comment: found end-of-line after double semicolon", .{});
                                        broken = true;
                                        break;
                                    } else {
                                        try parser.lexer.advance();
                                    }
                                } else {
                                    log.debug("inline_seq_or_post_comment: reached eof after double semicolon, last token was {f}", .{last});
                                }

                                const attr = analysis.Attribute{
                                    .kind = .{ .comment = .pre },
                                    .value = parser.lexer.inner.source[next_token.location.buffer + 1 .. if (broken) last.location.buffer else parser.lexer.inner.location.buffer],
                                    .source = analysis.Source{
                                        .name = parser.settings.source_name,
                                        .location = token.location,
                                    },
                                };

                                log.debug("accumulated new prefix comment attribute: {any}", .{attr});

                                try parser.attr_accum.append(parser.allocator, attr);

                                return analysis.SyntaxTree{
                                    .source = .{ .name = parser.settings.source_name, .location = token.location },
                                    .precedence = std.math.maxInt(i16),
                                    .type = .null,
                                    .token = token,
                                    .operands = .empty,
                                };
                            } else {
                                log.debug("leading_comment: expected second semi token, found {f}; reject", .{next_token});
                                return null;
                            }
                        } else {
                            log.debug("leading_comment: no second semi token found; panic", .{});
                            return error.UnexpectedEof;
                        }
                    }
                }.leading_comment,
            );
        }
    };

    pub const leds = struct {
        pub fn decl_inferred() analysis.Parser.Led {
            return analysis.Parser.createLed(
                "rml_decl_inferred_type",
                std.math.minInt(i16),
                .{ .standard = .{ .sequence = .{ .standard = .fromSlice(":=") } } },
                null,
                struct {
                    pub fn decl(
                        parser: *analysis.Parser,
                        lhs: analysis.SyntaxTree,
                        bp: i16,
                        token: analysis.Token,
                    ) analysis.Parser.Error!?analysis.SyntaxTree {
                        log.debug("decl: parsing token {f}", .{token});
                        if (lhs.precedence == bp) {
                            log.debug("decl: lhs has same binding power; panic", .{});
                            return error.UnexpectedInput;
                        }
                        try parser.lexer.advance(); // discard operator
                        const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                            log.debug("decl: no rhs; panic", .{});
                            return error.UnexpectedInput;
                        };
                        const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                        buff[0] = lhs;
                        buff[1] = second_stmt;
                        return analysis.SyntaxTree{
                            .source = lhs.source,
                            .precedence = bp,
                            .type = types.Decl,
                            .token = token,
                            .operands = .fromSlice(buff),
                        };
                    }
                }.decl,
            );
        }

        pub fn assign() analysis.Parser.Led {
            return analysis.Parser.createLed(
                "rml_assign",
                std.math.minInt(i16),
                .{ .standard = .{ .sequence = .{ .standard = .fromSlice("=") } } },
                null,
                struct {
                    pub fn assign(
                        parser: *analysis.Parser,
                        lhs: analysis.SyntaxTree,
                        bp: i16,
                        token: analysis.Token,
                    ) analysis.Parser.Error!?analysis.SyntaxTree {
                        log.debug("assign: parsing token {f}", .{token});
                        if (lhs.precedence == bp) {
                            log.debug("assign: lhs has same binding power; panic", .{});
                            return error.UnexpectedInput;
                        }
                        try parser.lexer.advance(); // discard operator
                        const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                            log.debug("assign: no rhs; panic", .{});
                            return error.UnexpectedInput;
                        };
                        const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                        buff[0] = lhs;
                        buff[1] = second_stmt;
                        return analysis.SyntaxTree{
                            .source = lhs.source,
                            .precedence = bp,
                            .type = types.Assign,
                            .token = token,
                            .operands = .fromSlice(buff),
                        };
                    }
                }.assign,
            );
        }

        pub fn list() analysis.Parser.Led {
            return analysis.Parser.createLed(
                "rml_list",
                std.math.minInt(i16) + 100,
                .{ .standard = .{ .special = .{ .standard = .{ .escaped = .{ .standard = false }, .punctuation = .{ .standard = .comma } } } } },
                null,
                struct {
                    pub fn list(
                        parser: *analysis.Parser,
                        lhs: analysis.SyntaxTree,
                        bp: i16,
                        token: analysis.Token,
                    ) analysis.Parser.Error!?analysis.SyntaxTree {
                        log.debug("list: lhs {f}", .{lhs});
                        try parser.lexer.advance(); // discard linebreak
                        if (try parser.lexer.peek()) |next_token| {
                            if (next_token.tag == .indentation and next_token.data.indentation == .unindent) {
                                log.debug("list: found unindent token, returning lhs", .{});
                                return lhs;
                            }
                        } else {
                            log.debug("list: no next token found; returning lhs", .{});
                            return lhs;
                        }
                        var rhs = if (try parser.pratt(bp)) |r| r else {
                            log.debug("list: no rhs; return singleton list", .{});
                            const buff: []analysis.SyntaxTree = try parser.allocator.alloc(analysis.SyntaxTree, 1);
                            buff[0] = lhs;
                            return analysis.SyntaxTree{
                                .source = lhs.source,
                                .precedence = bp,
                                .type = types.List,
                                .token = token,
                                .operands = .fromSlice(buff),
                            };
                        };
                        errdefer rhs.deinit(parser.allocator);
                        log.debug("list: found rhs {f}", .{rhs});
                        if (lhs.type == types.List and rhs.type == types.List) {
                            log.debug("list: both lhs and rhs are lists, concatenating", .{});
                            const lhs_operands = lhs.operands.asSlice();
                            const rhs_operands = rhs.operands.asSlice();
                            defer parser.allocator.free(lhs_operands);
                            defer parser.allocator.free(rhs_operands);
                            const new_operands = try parser.allocator.alloc(analysis.SyntaxTree, lhs_operands.len + rhs_operands.len);
                            @memcpy(new_operands[0..lhs_operands.len], lhs_operands);
                            @memcpy(new_operands[lhs_operands.len..], rhs_operands);
                            return .{
                                .source = lhs.source,
                                .precedence = bp,
                                .type = types.List,
                                .token = token,
                                .operands = .fromSlice(new_operands),
                            };
                        } else if (lhs.type == types.List) {
                            log.debug("list: lhs is a list, concatenating rhs", .{});
                            const lhs_operands = lhs.operands.asSlice();
                            defer parser.allocator.free(lhs_operands);
                            const new_operands = try parser.allocator.alloc(analysis.SyntaxTree, lhs_operands.len + 1);
                            @memcpy(new_operands[0..lhs_operands.len], lhs_operands);
                            new_operands[lhs_operands.len] = rhs;
                            return .{
                                .source = lhs.source,
                                .precedence = bp,
                                .type = types.List,
                                .token = token,
                                .operands = .fromSlice(new_operands),
                            };
                        } else if (rhs.type == types.List) {
                            log.debug("list: rhs is a list, concatenating lhs", .{});
                            const rhs_operands = rhs.operands.asSlice();
                            defer parser.allocator.free(rhs_operands);
                            const new_operands = try parser.allocator.alloc(analysis.SyntaxTree, rhs_operands.len + 1);
                            new_operands[0] = lhs;
                            @memcpy(new_operands[1..], rhs_operands);
                            return .{
                                .source = lhs.source,
                                .precedence = bp,
                                .type = types.List,
                                .token = token,
                                .operands = .fromSlice(new_operands),
                            };
                        } else {
                            log.debug("list: creating new list", .{});
                        }
                        const buff: []analysis.SyntaxTree = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                        log.debug("list: buffer allocation {x}", .{@intFromPtr(buff.ptr)});
                        buff[0] = lhs;
                        buff[1] = rhs;
                        log.debug("list: buffer written; returning", .{});
                        return analysis.SyntaxTree{
                            .source = lhs.source,
                            .precedence = bp,
                            .type = types.List,
                            .token = token,
                            .operands = .fromSlice(buff),
                        };
                    }
                }.list,
            );
        }

        pub fn inline_seq_or_post_comment() analysis.Parser.Led {
            return analysis.Parser.createLed("rml_inline_seq_or_post_comment", std.math.minInt(i16), .{
                .standard = .{
                    .special = .{
                        .standard = .{
                            .escaped = .{ .standard = false },
                            .punctuation = .{ .standard = .semicolon },
                        },
                    },
                },
            }, null, struct {
                pub fn inline_seq_or_post_comment(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.Parser.Error!?analysis.SyntaxTree {
                    log.debug("inline_seq_or_post_comment: lhs {f}", .{lhs});
                    try parser.lexer.advance(); // discard semi
                    if (try parser.lexer.peek()) |next_token| {
                        if (next_token.tag == .special and next_token.data.special.punctuation == .semicolon and next_token.data.special.escaped == false and next_token.location.buffer == token.location.buffer + 1) {
                            log.debug("inline_seq_or_post_comment: found another semicolon, this is an end-of-line comment", .{});

                            try parser.lexer.advance(); // discard second semi

                            var last = next_token;
                            var broken = false;
                            while (try parser.lexer.peek()) |maybe_endl| {
                                last = maybe_endl;
                                if (last.tag == .linebreak or last.tag == .indentation) {
                                    log.debug("inline_seq_or_post_comment: found end-of-line after double semicolon", .{});
                                    broken = true;
                                    break;
                                } else {
                                    try parser.lexer.advance();
                                }
                            } else {
                                log.debug("inline_seq_or_post_comment: reached eof after double semicolon, last token was {f}", .{last});
                            }

                            const old_buf = lhs.attributes;
                            const new_buf = try parser.allocator.alloc(analysis.Attribute, old_buf.len + 1);

                            defer parser.allocator.free(old_buf);

                            @memcpy(new_buf[0..old_buf.len], old_buf);
                            new_buf[old_buf.len] = analysis.Attribute{
                                .kind = .{ .comment = .post },
                                .value = parser.lexer.inner.source[next_token.location.buffer + 1 .. if (broken) last.location.buffer else parser.lexer.inner.location.buffer],
                                .source = analysis.Source{
                                    .name = parser.settings.source_name,
                                    .location = token.location,
                                },
                            };

                            log.debug("created new attribute buffer with post comment attribute: {any}", .{new_buf});

                            var new_lhs = lhs;
                            new_lhs.attributes = new_buf;
                            return new_lhs;
                        }
                    }

                    log.debug("inline_seq_or_post_comment: not an eol comment; parsing rhs after semicolon", .{});

                    var rhs = if (try parser.pratt(std.math.minInt(i16))) |r| r else {
                        log.debug("inline_seq_or_post_comment: no rhs; return lhs", .{});
                        return lhs;
                    };
                    errdefer rhs.deinit(parser.allocator);
                    log.debug("inline_seq_or_post_comment: found rhs {f}", .{rhs});
                    if (lhs.type == types.Seq and rhs.type == types.Seq and lhs.token.tag == .special and rhs.token.tag == .special) {
                        log.debug("inline_seq_or_post_comment: both lhs and rhs are seqs, concatenating", .{});
                        const lhs_operands = lhs.operands.asSlice();
                        const rhs_operands = rhs.operands.asSlice();
                        defer parser.allocator.free(lhs_operands);
                        defer parser.allocator.free(rhs_operands);
                        const new_operands = try parser.allocator.alloc(analysis.SyntaxTree, lhs_operands.len + rhs_operands.len);
                        @memcpy(new_operands[0..lhs_operands.len], lhs_operands);
                        @memcpy(new_operands[lhs_operands.len..], rhs_operands);
                        return .{
                            .source = lhs.source,
                            .precedence = bp,
                            .type = types.Seq,
                            .token = token,
                            .operands = .fromSlice(new_operands),
                        };
                    } else if (lhs.type == types.Seq and lhs.token.tag == .special) {
                        log.debug("inline_seq_or_post_comment: lhs is a seq, concatenating rhs", .{});
                        const lhs_operands = lhs.operands.asSlice();
                        defer parser.allocator.free(lhs_operands);
                        const new_operands = try parser.allocator.alloc(analysis.SyntaxTree, lhs_operands.len + 1);
                        @memcpy(new_operands[0..lhs_operands.len], lhs_operands);
                        new_operands[lhs_operands.len] = rhs;
                        return .{
                            .source = lhs.source,
                            .precedence = bp,
                            .type = types.Seq,
                            .token = token,
                            .operands = .fromSlice(new_operands),
                        };
                    } else if (rhs.type == types.Seq and rhs.token.tag == .special) {
                        log.debug("inline_seq_or_post_comment: rhs is a seq, concatenating lhs", .{});
                        const rhs_operands = rhs.operands.asSlice();
                        defer parser.allocator.free(rhs_operands);
                        const new_operands = try parser.allocator.alloc(analysis.SyntaxTree, rhs_operands.len + 1);
                        new_operands[0] = lhs;
                        @memcpy(new_operands[1..], rhs_operands);
                        return .{
                            .source = lhs.source,
                            .precedence = bp,
                            .type = types.Seq,
                            .token = token,
                            .operands = .fromSlice(new_operands),
                        };
                    } else {
                        log.debug("inline_seq_or_post_comment: creating new seq", .{});
                    }
                    const buff: []analysis.SyntaxTree = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    log.debug("inline_seq_or_post_comment: buffer allocation {x}", .{@intFromPtr(buff.ptr)});
                    buff[0] = lhs;
                    buff[1] = rhs;
                    log.debug("inline_seq_or_post_comment: buffer written; returning", .{});
                    return analysis.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = types.Seq,
                        .token = token,
                        .operands = .fromSlice(buff),
                    };
                }
            }.inline_seq_or_post_comment);
        }

        pub fn seq() analysis.Parser.Led {
            return analysis.Parser.createLed(
                "rml_seq",
                std.math.minInt(i16),
                .{ .standard = .linebreak },
                null,
                struct {
                    pub fn seq(
                        parser: *analysis.Parser,
                        lhs: analysis.SyntaxTree,
                        bp: i16,
                        token: analysis.Token,
                    ) analysis.Parser.Error!?analysis.SyntaxTree {
                        log.debug("seq: lhs {f}", .{lhs});
                        try parser.lexer.advance(); // discard linebreak
                        if (try parser.lexer.peek()) |next_token| {
                            if (next_token.tag == .indentation and next_token.data.indentation == .unindent) {
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
                        log.debug("seq: found rhs {f}", .{rhs});
                        if (lhs.type == types.Seq and rhs.type == types.Seq and lhs.token.tag == .linebreak and rhs.token.tag == .linebreak) {
                            log.debug("seq: both lhs and rhs are seqs, concatenating", .{});
                            const lhs_operands = lhs.operands.asSlice();
                            const rhs_operands = rhs.operands.asSlice();
                            defer parser.allocator.free(lhs_operands);
                            defer parser.allocator.free(rhs_operands);
                            const new_operands = try parser.allocator.alloc(analysis.SyntaxTree, lhs_operands.len + rhs_operands.len);
                            @memcpy(new_operands[0..lhs_operands.len], lhs_operands);
                            @memcpy(new_operands[lhs_operands.len..], rhs_operands);
                            return .{
                                .source = lhs.source,
                                .precedence = bp,
                                .type = types.Seq,
                                .token = token,
                                .operands = .fromSlice(new_operands),
                            };
                        } else if (lhs.type == types.Seq and lhs.token.tag == .linebreak) {
                            log.debug("seq: lhs is a seq, concatenating rhs", .{});
                            const lhs_operands = lhs.operands.asSlice();
                            defer parser.allocator.free(lhs_operands);
                            const new_operands = try parser.allocator.alloc(analysis.SyntaxTree, lhs_operands.len + 1);
                            @memcpy(new_operands[0..lhs_operands.len], lhs_operands);
                            new_operands[lhs_operands.len] = rhs;
                            return .{
                                .source = lhs.source,
                                .precedence = bp,
                                .type = types.Seq,
                                .token = token,
                                .operands = .fromSlice(new_operands),
                            };
                        } else if (rhs.type == types.Seq and rhs.token.tag == .linebreak) {
                            log.debug("seq: rhs is a seq, concatenating lhs", .{});
                            const rhs_operands = rhs.operands.asSlice();
                            defer parser.allocator.free(rhs_operands);
                            const new_operands = try parser.allocator.alloc(analysis.SyntaxTree, rhs_operands.len + 1);
                            new_operands[0] = lhs;
                            @memcpy(new_operands[1..], rhs_operands);
                            return .{
                                .source = lhs.source,
                                .precedence = bp,
                                .type = types.Seq,
                                .token = token,
                                .operands = .fromSlice(new_operands),
                            };
                        } else {
                            log.debug("seq: creating new seq", .{});
                        }
                        const buff: []analysis.SyntaxTree = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                        log.debug("seq: buffer allocation {x}", .{@intFromPtr(buff.ptr)});
                        buff[0] = lhs;
                        buff[1] = rhs;
                        log.debug("seq: buffer written; returning", .{});
                        return analysis.SyntaxTree{
                            .source = lhs.source,
                            .precedence = bp,
                            .type = types.Seq,
                            .token = token,
                            .operands = .fromSlice(buff),
                        };
                    }
                }.seq,
            );
        }

        pub fn apply() analysis.Parser.Led {
            return analysis.Parser.createLed(
                "rml_apply",
                0,
                .any,
                null,
                struct {
                    pub fn apply(
                        parser: *analysis.Parser,
                        lhs: analysis.SyntaxTree,
                        bp: i16,
                        token: analysis.Token,
                    ) analysis.Parser.Error!?analysis.SyntaxTree {
                        log.debug("apply: {f} {f}", .{ lhs, token });
                        const applicable_leds = try parser.syntax.findLeds(std.math.minInt(i16), &token);
                        if (applicable_leds.len != 1) { // self
                            log.debug("apply: found {d} applicable led(s), rejecting", .{applicable_leds.len});
                            return null;
                        } else {
                            log.debug("apply: no applicable led(s) found for token {f} with bp >= {}", .{ token, 1 });
                        }
                        var rhs = try parser.pratt(bp + 1) orelse {
                            log.debug("apply: unable to parse rhs, rejecting", .{});
                            return null;
                        };
                        errdefer rhs.deinit(parser.allocator);
                        log.debug("apply: rhs {f}", .{rhs});
                        if (lhs.type == types.Apply) {
                            log.debug("apply: lhs is an apply, concatenating rhs", .{});
                            const lhs_operands = lhs.operands.asSlice();
                            defer parser.allocator.free(lhs_operands);
                            const new_operands = try parser.allocator.alloc(analysis.SyntaxTree, lhs_operands.len + 1);
                            @memcpy(new_operands[0..lhs_operands.len], lhs_operands);
                            new_operands[lhs_operands.len] = rhs;
                            return .{
                                .source = lhs.source,
                                .precedence = bp,
                                .type = types.Apply,
                                .token = token,
                                .operands = .fromSlice(new_operands),
                            };
                        } else {
                            log.debug("apply: lhs is not an apply, creating new apply", .{});
                        }
                        const buff: []analysis.SyntaxTree = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                        log.debug("apply: buffer allocation {x}", .{@intFromPtr(buff.ptr)});
                        buff[0] = lhs;
                        buff[1] = rhs;
                        log.debug("apply: buffer written; returning", .{});
                        return analysis.SyntaxTree{
                            .source = lhs.source,
                            .precedence = bp,
                            .type = types.Apply,
                            .token = analysis.Token{
                                .location = token.location,
                                .tag = .sequence,
                                .data = analysis.Token.Data{
                                    .sequence = .fromSlice(" "),
                                },
                            },
                            .operands = .fromSlice(buff),
                        };
                    }
                }.apply,
            );
        }

        pub fn mul() analysis.Parser.Led {
            return binop("rml_mul", -1000, "*", true);
        }

        pub fn div() analysis.Parser.Led {
            return binop("rml_div", -1000, "/", true);
        }

        pub fn add() analysis.Parser.Led {
            return binop("rml_add", -2000, "+", true);
        }

        pub fn sub() analysis.Parser.Led {
            return binop("rml_sub", -2000, "-", true);
        }

        pub fn eq() analysis.Parser.Led {
            return binop("rml_eq", -4001, "==", false);
        }

        pub fn neq() analysis.Parser.Led {
            return binop("rml_neq", -4001, "!=", false);
        }

        pub fn lt() analysis.Parser.Led {
            return binop("rml_lt", -4000, "<", false);
        }

        pub fn gt() analysis.Parser.Led {
            return binop("rml_gt", -4000, ">", false);
        }

        pub fn leq() analysis.Parser.Led {
            return binop("rml_leq", -4000, "<=", false);
        }

        pub fn geq() analysis.Parser.Led {
            return binop("rml_geq", -4000, ">=", false);
        }

        pub fn logical_and() analysis.Parser.Led {
            return binop("rml_logical_and", -3000, "and", true);
        }

        pub fn logical_or() analysis.Parser.Led {
            return binop("rml_logical_or", -3000, "or", true);
        }

        pub fn member_access_or_float() analysis.Parser.Led {
            return analysis.Parser.createLed(
                "rml_member_access_or_float",
                std.math.maxInt(i16),
                .{
                    .standard = .{
                        .special = .{
                            .standard = .{
                                .escaped = .{ .standard = false },
                                .punctuation = .{ .standard = .fromChar('.') },
                            },
                        },
                    },
                },
                null,
                struct {
                    pub fn binop(
                        parser: *analysis.Parser,
                        lhs: analysis.SyntaxTree,
                        bp: i16,
                        token: analysis.Token,
                    ) analysis.Parser.Error!?analysis.SyntaxTree {
                        log.debug("rml_member_access_or_float: parsing token {f}", .{token});

                        try parser.lexer.advance();

                        const rhs = if (try parser.lexer.next()) |next_token| rhs: {
                            if (next_token.location.buffer != token.location.buffer + 1) {
                                log.debug("rml_member_access_or_float: rhs is disconnected, rejecting", .{});
                                return null;
                            }

                            if (next_token.tag != .sequence) {
                                log.debug("rml_member_access_or_float: rhs is not a sequence token, rejecting", .{});
                                return null;
                            }

                            const first_char = rg.nthCodepoint(0, next_token.data.sequence.asSlice()) catch unreachable orelse unreachable;

                            break :rhs analysis.SyntaxTree{
                                .source = analysis.Source{
                                    .location = next_token.location,
                                    .name = parser.settings.source_name,
                                },
                                .precedence = bp,
                                .type = if (rg.isDecimal(first_char)) types.Int else types.Identifier,
                                .token = next_token,
                                .operands = .empty,
                            };
                        } else {
                            log.debug("rml_member_access_or_float: no next token found, rejecting", .{});
                            return null;
                        };

                        const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                        buff[0] = lhs;
                        buff[1] = rhs;
                        return analysis.SyntaxTree{
                            .source = lhs.source,
                            .precedence = bp,
                            .type = if (lhs.type == types.Int and rhs.type == types.Int) types.Float else types.MemberAccess,
                            .token = token,
                            .operands = .fromSlice(buff),
                        };
                    }
                }.binop,
            );
        }
    };
};

pub fn unop(comptime name: []const u8, binding_power: i16, symbol: []const u8) analysis.Parser.Nud {
    return analysis.Parser.createNud(
        name,
        binding_power,
        .{ .standard = .{ .sequence = .{ .standard = .fromSlice(symbol) } } },
        null,
        struct {
            pub fn unop(
                parser: *analysis.Parser,
                bp: i16,
                token: analysis.Token,
            ) analysis.Parser.Error!?analysis.SyntaxTree {
                log.debug(name ++ ": parsing token {f}", .{token});
                try parser.lexer.advance(); // discard not
                var inner = try parser.pratt(bp) orelse none: {
                    log.debug(name ++ ": no inner expression found", .{});
                    break :none null;
                };
                errdefer if (inner) |*i| i.deinit(parser.allocator);
                return analysis.SyntaxTree{
                    .source = .{ .name = parser.settings.source_name, .location = token.location },
                    .precedence = bp,
                    .type = types.Prefix,
                    .token = token,
                    .operands = if (inner) |sub| mk_buf: {
                        const buff: []analysis.SyntaxTree = try parser.allocator.alloc(analysis.SyntaxTree, 1);
                        buff[0] = sub;
                        break :mk_buf .fromSlice(buff);
                    } else .empty,
                };
            }
        }.unop,
    );
}

pub fn binop(comptime name: []const u8, binding_power: i16, symbol: []const u8, comptime allow_fixity: bool) analysis.Parser.Led {
    return analysis.Parser.createLed(
        name,
        binding_power,
        .{ .standard = .{ .sequence = .{ .standard = .fromSlice(symbol) } } },
        null,
        struct {
            pub fn binop(
                parser: *analysis.Parser,
                lhs: analysis.SyntaxTree,
                bp: i16,
                token: analysis.Token,
            ) analysis.Parser.Error!?analysis.SyntaxTree {
                log.debug(name ++ ": parsing token {f}", .{token});
                if (comptime !allow_fixity) {
                    if (lhs.precedence == bp) {
                        log.debug(name ++ ": lhs has same binding power; panic", .{});
                        return error.UnexpectedInput;
                    }
                }
                try parser.lexer.advance(); // discard operator
                const rhs = if (try parser.pratt(bp + 1)) |r| r else {
                    log.debug(name ++ ": no rhs; panic", .{});
                    return error.UnexpectedInput;
                };
                const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                buff[0] = lhs;
                buff[1] = rhs;
                return analysis.SyntaxTree{
                    .source = lhs.source,
                    .precedence = bp,
                    .type = types.Binary,
                    .token = token,
                    .operands = .fromSlice(buff),
                };
            }
        }.binop,
    );
}
