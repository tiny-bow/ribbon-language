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

/// Assembles an rml concrete syntax tree string literal into a buffer.
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

/// Dumps an rml concrete syntax tree to a string.
pub fn dumpSExprs(source: []const u8, writer: *std.io.Writer, cst: *const analysis.SyntaxTree) !void {
    switch (cst.type) {
        types.Identifier, types.Int => try writer.print("{s}", .{cst.token.data.sequence.asSlice()}),
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
        types.Set => try writer.writeAll("⟨𝓼𝓮𝓽"),
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
        types.String, types.Identifier, types.Int => return,
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

/// Get the syntax for the meta-language.
pub fn getSyntax() *const analysis.Parser.Syntax {
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
    lexer_settings: analysis.Lexer.Settings,
    source_name: []const u8,
    src: []const u8,
) analysis.Parser.Error!analysis.Parser {
    const ml_syntax = getSyntax();
    return ml_syntax.createParser(allocator, lexer_settings, src, .{
        .ignore_space = false,
        .source_name = source_name,
    });
}

/// Parse a meta-language source string to a concrete syntax tree.
/// * Returns null if the source is empty.
/// * Returns an error if we cannot parse the entire source.
pub fn parseSource(
    allocator: std.mem.Allocator,
    lexer_settings: analysis.Lexer.Settings,
    source_name: []const u8,
    src: []const u8,
) analysis.Parser.Error!?analysis.SyntaxTree {
    var parser = try getParser(allocator, lexer_settings, source_name, src);

    const out = parser.pratt(std.math.minInt(i16));

    if (std.debug.runtime_safety) {
        log.debug("getCst: parser result: {!?f}", .{out});

        if (std.meta.isError(out) or (try out) == null or !parser.isEof()) {
            log.debug("getCst: parser result was null or error, or did not consume input {any} {any} {any}", .{ std.meta.isError(out), if (!std.meta.isError(out)) (try out) == null else false, !parser.isEof() });

            if (parser.lexer.peek()) |maybe_cached_token| {
                if (maybe_cached_token) |cached_token| {
                    log.debug("getCst: unused token in lexer cache {f}: `{f}`", .{ parser.lexer.inner.location, cached_token });
                }
            } else |err| {
                log.debug("syntax error: {s}", .{@errorName(err)});
            }

            const rem = src[parser.lexer.inner.location.buffer..];

            if (parser.lexer.inner.iterator.peek_cache) |cached_char| {
                log.debug("getCst: unused character in lexer cache {f}: `{u}` ({x})", .{ parser.lexer.inner.location, cached_char, cached_char });
            } else if (rem.len > 0) {
                log.debug("getCst: unexpected input after parsing {f}: `{s}` ({x})", .{ parser.lexer.inner.location, rem, rem });
            }
        }
    }

    return try out;
}

/// creates rml prefix/atomic parser defs.
pub fn nuds() [10]analysis.Parser.Nud {
    return .{
        analysis.Parser.createNud(
            "builtin_function",
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
        ),
        analysis.Parser.createNud(
            "builtin_leading_br",
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
        ),
        analysis.Parser.createNud(
            "builtin_indent",
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
        ),
        analysis.Parser.createNud(
            "builtin_block",
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
        ),
        analysis.Parser.createNud(
            "builtin_single_quote",
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
        ),
        analysis.Parser.createNud(
            "builtin_string",
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
        ),
        analysis.Parser.createNud(
            "builtin_leaf",
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
                        if (applicable_nuds.len != 1 or applicable_leds.len != 1) {
                            log.debug("leaf: identifier {s} is bound by another pattern, rejecting", .{s});
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
        ),
        analysis.Parser.createNud(
            "builtin_logical_not",
            -2999,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("not") } } },
            null,
            struct {
                pub fn logical_not(
                    parser: *analysis.Parser,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.Parser.Error!?analysis.SyntaxTree {
                    log.debug("logical_not: parsing token {f}", .{token});
                    try parser.lexer.advance(); // discard not
                    var inner = try parser.pratt(bp) orelse none: {
                        log.debug("logical_not: no inner expression found", .{});
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
            }.logical_not,
        ),
        analysis.Parser.createNud(
            "builtin_unary_minus",
            -1999,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("-") } } },
            null,
            struct {
                pub fn unary_minus(
                    parser: *analysis.Parser,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.Parser.Error!?analysis.SyntaxTree {
                    log.debug("unary_minus: parsing token {f}", .{token});
                    try parser.lexer.advance(); // discard -
                    var inner = try parser.pratt(bp) orelse none: {
                        log.debug("unary_minus: no inner expression found", .{});
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
            }.unary_minus,
        ),
        analysis.Parser.createNud(
            "builtin_unary_plus",
            -1999,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("+") } } },
            null,
            struct {
                pub fn unary_plus(
                    parser: *analysis.Parser,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.Parser.Error!?analysis.SyntaxTree {
                    log.debug("unary_plus: parsing token {f}", .{token});
                    try parser.lexer.advance(); // discard +
                    var inner = try parser.pratt(bp) orelse none: {
                        log.debug("unary_plus: no inner expression found", .{});
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
            }.unary_plus,
        ),
    };
}

/// creates rml infix/postfix parser defs.
pub fn leds() [17]analysis.Parser.Led {
    return .{
        analysis.Parser.createLed(
            "builtin_decl_inferred_type",
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
        ),
        analysis.Parser.createLed(
            "builtin_set",
            std.math.minInt(i16),
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("=") } } },
            null,
            struct {
                pub fn set(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.Parser.Error!?analysis.SyntaxTree {
                    log.debug("set: parsing token {f}", .{token});
                    if (lhs.precedence == bp) {
                        log.debug("set: lhs has same binding power; panic", .{});
                        return error.UnexpectedInput;
                    }
                    try parser.lexer.advance(); // discard operator
                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("set: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };
                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;
                    return analysis.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = types.Set,
                        .token = token,
                        .operands = .fromSlice(buff),
                    };
                }
            }.set,
        ),
        analysis.Parser.createLed(
            "builtin_list",
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
        ),
        analysis.Parser.createLed(
            "builtin_seq",
            std.math.minInt(i16),
            .{ .any_of = &.{
                .linebreak,
                .{ .special = .{ .standard = .{
                    .escaped = .{ .standard = false },
                    .punctuation = .{ .standard = .semicolon },
                } } },
            } },
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
                    if (lhs.type == types.Seq and rhs.type == types.Seq) {
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
                    } else if (lhs.type == types.Seq) {
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
                    } else if (rhs.type == types.Seq) {
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
        ),
        analysis.Parser.createLed(
            "builtin_apply",
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
        ),
        analysis.Parser.createLed(
            "builtin_mul",
            -1000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("*") } } },
            null,
            struct {
                pub fn mul(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.Parser.Error!?analysis.SyntaxTree {
                    log.debug("mul: parsing token {f}", .{token});
                    try parser.lexer.advance(); // discard operator
                    const rhs = if (try parser.pratt(bp + 1)) |r| r else {
                        log.debug("mul: no rhs; panic", .{});
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
            }.mul,
        ),
        analysis.Parser.createLed(
            "builtin_div",
            -1000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("/") } } },
            null,
            struct {
                pub fn div(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.Parser.Error!?analysis.SyntaxTree {
                    log.debug("div: parsing token {f}", .{token});
                    try parser.lexer.advance(); // discard operator
                    const rhs = if (try parser.pratt(bp + 1)) |r| r else {
                        log.debug("div: no rhs; panic", .{});
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
            }.div,
        ),
        analysis.Parser.createLed(
            "builtin_add",
            -2000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("+") } } },
            null,
            struct {
                pub fn add(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.Parser.Error!?analysis.SyntaxTree {
                    log.debug("add: parsing token {f}", .{token});
                    try parser.lexer.advance(); // discard operator
                    const rhs = if (try parser.pratt(bp + 1)) |r| r else {
                        log.debug("add: no rhs; panic", .{});
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
            }.add,
        ),
        analysis.Parser.createLed(
            "builtin_sub",
            -2000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("-") } } },
            null,
            struct {
                pub fn sub(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.Parser.Error!?analysis.SyntaxTree {
                    log.debug("sub: parsing token {f}", .{token});
                    try parser.lexer.advance(); // discard operator
                    const rhs = if (try parser.pratt(bp + 1)) |r| r else {
                        log.debug("sub: no rhs; panic", .{});
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
            }.sub,
        ),

        analysis.Parser.createLed(
            "builtin_eq",
            -4001,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("==") } } },
            null,
            struct {
                pub fn eq(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.Parser.Error!?analysis.SyntaxTree {
                    log.debug("eq: parsing token {f}", .{token});
                    if (lhs.precedence == bp) {
                        log.debug("eq: lhs has same binding power; panic", .{});
                        return error.UnexpectedInput;
                    }
                    try parser.lexer.advance(); // discard operator
                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("eq: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };
                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;
                    return analysis.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = types.Binary,
                        .token = token,
                        .operands = .fromSlice(buff),
                    };
                }
            }.eq,
        ),

        analysis.Parser.createLed(
            "builtin_neq",
            -4001,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("!=") } } },
            null,
            struct {
                pub fn neq(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.Parser.Error!?analysis.SyntaxTree {
                    log.debug("neq: parsing token {f}", .{token});
                    if (lhs.precedence == bp) {
                        log.debug("neq: lhs has same binding power; panic", .{});
                        return error.UnexpectedInput;
                    }
                    try parser.lexer.advance(); // discard operator
                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("neq: no rhs, panic", .{});
                        return error.UnexpectedInput;
                    };
                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;
                    return analysis.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = types.Binary,
                        .token = token,
                        .operands = .fromSlice(buff),
                    };
                }
            }.neq,
        ),

        analysis.Parser.createLed(
            "builtin_lt",
            -4000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("<") } } },
            null,
            struct {
                pub fn lt(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.Parser.Error!?analysis.SyntaxTree {
                    log.debug("lt: parsing token {f}", .{token});
                    if (lhs.precedence == bp) {
                        log.debug("lt: lhs has same binding power; panic", .{});
                        return error.UnexpectedInput;
                    }
                    try parser.lexer.advance(); // discard operator
                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("lt: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };
                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;
                    return analysis.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = types.Binary,
                        .token = token,
                        .operands = .fromSlice(buff),
                    };
                }
            }.lt,
        ),

        analysis.Parser.createLed(
            "builtin_gt",
            -4000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice(">") } } },
            null,
            struct {
                pub fn gt(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.Parser.Error!?analysis.SyntaxTree {
                    log.debug("gt: parsing token {f}", .{token});
                    if (lhs.precedence == bp) {
                        log.debug("gt: lhs has same binding power; panic", .{});
                        return error.UnexpectedInput;
                    }
                    try parser.lexer.advance(); // discard operator
                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("gt: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };
                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;
                    return analysis.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = types.Binary,
                        .token = token,
                        .operands = .fromSlice(buff),
                    };
                }
            }.gt,
        ),

        analysis.Parser.createLed(
            "builtin_leq",
            -4000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("<=") } } },
            null,
            struct {
                pub fn leq(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.Parser.Error!?analysis.SyntaxTree {
                    log.debug("leq: parsing token {f}", .{token});
                    if (lhs.precedence == bp) {
                        log.debug("leq: lhs has same binding power; panic", .{});
                        return error.UnexpectedInput;
                    }
                    try parser.lexer.advance(); // discard operator
                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("leq: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };
                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;
                    return analysis.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = types.Binary,
                        .token = token,
                        .operands = .fromSlice(buff),
                    };
                }
            }.leq,
        ),

        analysis.Parser.createLed(
            "builtin_geq",
            -4000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice(">=") } } },
            null,
            struct {
                pub fn geq(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.Parser.Error!?analysis.SyntaxTree {
                    log.debug("geq: parsing token {f}", .{token});
                    if (lhs.precedence == bp) {
                        log.debug("geq: lhs has same binding power; panic", .{});
                        return error.UnexpectedInput;
                    }
                    try parser.lexer.advance(); // discard operator
                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("geq: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };
                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;
                    return analysis.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = types.Binary,
                        .token = token,
                        .operands = .fromSlice(buff),
                    };
                }
            }.geq,
        ),

        analysis.Parser.createLed(
            "builtin_logical_and",
            -3000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("and") } } },
            null,
            struct {
                pub fn logical_and(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.Parser.Error!?analysis.SyntaxTree {
                    log.debug("logical_and: parsing token {f}", .{token});
                    try parser.lexer.advance(); // discard operator
                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("logical_and: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };
                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;
                    return analysis.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = types.Binary,
                        .token = token,
                        .operands = .fromSlice(buff),
                    };
                }
            }.logical_and,
        ),

        analysis.Parser.createLed(
            "builtin_logical_or",
            -3000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("or") } } },
            null,
            struct {
                pub fn logical_or(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.Parser.Error!?analysis.SyntaxTree {
                    log.debug("logical_or: parsing token {f}", .{token});
                    try parser.lexer.advance(); // discard operator
                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("logical_or: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };
                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;
                    return analysis.SyntaxTree{
                        .source = lhs.source,
                        .precedence = bp,
                        .type = types.Binary,
                        .token = token,
                        .operands = .fromSlice(buff),
                    };
                }
            }.logical_or,
        ),
    };
}
