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
const analysis = @import("analysis");

test {
    std.testing.refAllDeclsRecursive(@This());
}

var syntax_mutex = std.Thread.Mutex{};
var syntax: ?analysis.Syntax = null;

pub fn dumpCstSExprs(source: []const u8, cst: analysis.SyntaxTree, writer: anytype) !void {
    switch(cst.type) {
        cst_types.Identifier, cst_types.Int => try writer.print("{s}", .{cst.token.data.sequence.asSlice()}),
        cst_types.String => {
            try writer.print("{u}", .{cst.token.data.special.punctuation.toChar()});
            try assembleString(writer, source, cst);
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
                try dumpCstSExprs(source, child, writer);
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
                try dumpCstSExprs(source, child, writer);
            }

            try writer.writeAll("⟩");
        }
    }
}

/// Get the syntax for the meta-language.
pub fn getSyntax() *const analysis.Syntax {
    syntax_mutex.lock();
    defer syntax_mutex.unlock();

    if (syntax) |*s| {
        return s;
    }

    var out = analysis.Syntax.init(std.heap.page_allocator);

    inline for (nuds()) |nud| {
        out.bindNud(nud) catch unreachable;
    }

    inline for (leds()) |led| {
        out.bindLed(led) catch unreachable;
    }

    syntax = out;

    return &syntax.?;
}

/// Get a parser for the meta-language.
pub fn getParser(
    allocator: std.mem.Allocator,
    lexer_settings: analysis.LexerSettings,
    source: []const u8,
    parser_settings: analysis.ParserSettings,
) analysis.SyntaxError!analysis.Parser {
    const ml_syntax = getSyntax();
    return ml_syntax.createParser(allocator, lexer_settings, source, parser_settings);
}

/// Parse a meta-language source string to a concrete syntax tree.
/// * Returns null if the source is empty.
/// * Returns an error if we cannot parse the entire source.
pub fn getCst(
    allocator: std.mem.Allocator,
    lexer_settings: analysis.LexerSettings,
    source: []const u8,
) analysis.SyntaxError!?analysis.SyntaxTree {
    var parser = try getParser(allocator, lexer_settings, source, .{ .ignore_space = false });

    const out = try parser.pratt(std.math.minInt(i16));

    log.debug("getCst: parser result: {?}", .{out});

    if (!parser.isEof()) {
        const inner = inner: {
            if (parser.lexer.peek()) |maybe_cached_token| {
                if (maybe_cached_token) |cached_token| {
                    log.err("getCst: unused token in lexer cache {}: `{s}` ({x})", .{parser.lexer.inner.location, cached_token, cached_token});
                }
                break :inner analysis.SyntaxError.UnexpectedInput;
            } else |err| {
                log.err("syntax error: {}", .{err});
                break :inner err;
            }
        };

        const rem = source[parser.lexer.inner.location.buffer..];

        if (parser.lexer.inner.iterator.peek_cache) |cached_char| {
            log.err("getCst: unused character in lexer cache {}: `{u}` ({x})", .{parser.lexer.inner.location, cached_char, cached_char});
        } else if (rem.len > 0) {
            log.err("getCst: unexpected input after parsing {}: `{s}` ({any})", .{parser.lexer.inner.location, rem, rem});
        }

        return inner;
    }

    return out.?;
}

/// rml concrete syntax tree types.
pub const cst_types = gen: {
    var fresh = common.Id.of(analysis.SyntaxTree).fromInt(0);

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
        .Unary = fresh.next(),
        .Decl = fresh.next(),
        .Set = fresh.next(),
        .Lambda = fresh.next(),
    };
};

// comptime {
//     for (std.meta.fieldNames(@TypeOf(cst_types))) |name| {
//         const value = @field(cst_types, name);

//         @compileLog(name, value);
//     }
// }

pub fn assembleString(writer: anytype, source: []const u8, string: analysis.SyntaxTree) !void {
    std.debug.assert(string.type == cst_types.String);

    const subexprs = string.operands.asSlice();
    // log.debug("assembling string from subexprs: {any}", .{subexprs});

    const start_loc = subexprs[0].location;
    const end_loc = subexprs[subexprs.len - 1].location;

    // log.debug("string subsection: {} -> {}", .{start_loc, end_loc});

    if (start_loc.buffer > end_loc.buffer or end_loc.buffer > source.len) {
        log.err("assembleString: invalid string {} -> {}", .{start_loc, end_loc});
        return error.InvalidString;
    }

    const sub = source[start_loc.buffer..end_loc.buffer];

    // log.debug("string subsection: `{s}`", .{sub});

    var char_it = analysis.CodepointIterator.from(sub);

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
pub fn nuds() [9]analysis.Nud {
    return .{
        analysis.createNud(
            "builtin_function",
            std.math.maxInt(i16),
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("fun") } } },
            null, struct {
                pub fn function(
                    parser: *analysis.Parser,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
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
                                return error.UnexpectedInput;
                            };
                            errdefer inner.deinit(parser.allocator);

                            log.debug("function: got inner expression {}", .{inner});

                            const buff: []analysis.SyntaxTree = try parser.allocator.alloc(analysis.SyntaxTree, 2);

                            buff[0] = patt;
                            buff[1] = inner;

                            return analysis.SyntaxTree{
                                .location = token.location,
                                .precedence = bp,
                                .type = cst_types.Lambda,
                                .token = token,
                                .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
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
        analysis.createNud(
            "builtin_leading_br",
            std.math.maxInt(i16),
            .{ .standard = .linebreak },
            null, struct {
                pub fn leading_br(
                    parser: *analysis.Parser,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("leading_br: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard linebreak

                    return analysis.SyntaxTree{
                        .location = token.location,
                        .precedence = bp,
                        .type = .null,
                        .token = token,
                        .operands = .empty,
                    };
                }
            }.leading_br,
        ),
        analysis.createNud(
            "builtin_indent",
            std.math.maxInt(i16),
            .{ .standard = .{ .indentation = .{ .standard = .indent } } },
            null, struct {
                pub fn block(
                    parser: *analysis.Parser,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("indent: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard indent

                    var inner = try parser.pratt(std.math.minInt(i16)) orelse {
                        log.debug("indent: no inner expression found; panic", .{});
                        return error.UnexpectedInput;
                    };
                    errdefer inner.deinit(parser.allocator);

                    log.debug("indent: got {} interior, looking for end of block token", .{inner});

                    if (try parser.lexer.peek()) |next_tok| {
                        if (next_tok.tag == .indentation
                        and next_tok.data.indentation == .unindent) {
                            log.debug("indent: found end of block token {}", .{next_tok});

                            const buff: []analysis.SyntaxTree = try parser.allocator.alloc(analysis.SyntaxTree, 1);
                            buff[0] = inner;

                            try parser.lexer.advance(); // discard indent
                            return analysis.SyntaxTree{
                                .location = token.location,
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
        analysis.createNud(
            "builtin_block",
            std.math.maxInt(i16),
            .{ .standard = .{ .special = .{ .standard = .{ .escaped = .{ .standard = false }, .punctuation = .{ .any_of = &.{ .paren_l, .bracket_l, .brace_l } } } } } },
            null, struct {
                pub fn block(
                    parser: *analysis.Parser,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
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
                            return analysis.SyntaxTree{
                                .location = token.location,
                                .precedence = bp,
                                .type = cst_types.Block,
                                .token = token,
                                .operands = if (inner) |sub| mk_buf: {
                                    const buff: []analysis.SyntaxTree = try parser.allocator.alloc(analysis.SyntaxTree, 1);
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
        analysis.createNud(
            "builtin_string",
            std.math.maxInt(i16),
            .{ .standard = .{ .special = .{ .standard = .{ .escaped = .{ .standard = false }, .punctuation = .{ .any_of = &.{.double_quote, .single_quote} } } } } },
            null, struct {
                pub fn string(
                    parser: *analysis.Parser,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("string: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard beginning quote

                    var buff: pl.ArrayList(analysis.SyntaxTree) = .empty;
                    defer buff.deinit(parser.allocator);

                    while (try parser.lexer.next()) |next_token| {
                        if (next_token.tag == .special
                        and !next_token.data.special.escaped
                        and next_token.data.special.punctuation == token.data.special.punctuation) {
                            log.debug("string: found end of string token {}", .{next_token});

                            try buff.append(parser.allocator, analysis.SyntaxTree{
                                .location = next_token.location,
                                .precedence = bp,
                                .type = cst_types.StringSentinel,
                                .token = next_token,
                                .operands = .empty,
                            });

                            return analysis.SyntaxTree{
                                .location = token.location,
                                .precedence = bp,
                                .type = cst_types.String,
                                .token = token,
                                .operands = .fromSlice(try buff.toOwnedSlice(parser.allocator)),
                            };
                        } else {
                            try buff.append(parser.allocator, analysis.SyntaxTree{
                                .location = next_token.location,
                                .precedence = bp,
                                .type = cst_types.StringElement,
                                .token = next_token,
                                .operands = .empty,
                            });
                        }
                    } else {
                        log.err("string: no end of string token found", .{});
                        return error.UnexpectedEof;
                    }
                }
            }.string,
        ),
        analysis.createNud(
            "builtin_leaf",
            std.math.maxInt(i16),
            .{ .standard = .{ .sequence = .any } },
            null, struct {
                pub fn leaf(
                    parser: *analysis.Parser,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("leaf: parsing token", .{});
                    log.debug("{}", .{token});
                    const s = token.data.sequence.asSlice();
                    log.debug("leaf: checking token {s}", .{s});

                    try parser.lexer.advance(); // discard leaf

                    const first_char = utils.text.nthCodepoint(0, s) catch unreachable orelse unreachable;

                    if (utils.text.isDecimal(first_char) and utils.text.isHexDigitStr(s)) {
                        log.debug("leaf: found int literal", .{});
                        return analysis.SyntaxTree{
                            .location = token.location,
                            .precedence = bp,
                            .type = cst_types.Int,
                            .token = token,
                            .operands = .empty,
                        };
                    } else if (utils.text.isAlphanumericStr(s)) {
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
                            .location = token.location,
                            .precedence = bp,
                            .type = cst_types.Identifier,
                            .token = token,
                            .operands = .empty,
                        };
                    } else {
                        log.debug("leaf: found unknown token", .{});
                        return null;
                    }
                }
            }.leaf,
        ),
        analysis.createNud(
            "builtin_logical_not",
            -2999,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("not") } } },
            null, struct {
                pub fn logical_not(
                    parser: *analysis.Parser,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("logical_not: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard not

                    var inner = try parser.pratt(bp) orelse none: {
                        log.debug("logical_not: no inner expression found", .{});
                        break :none null;
                    };
                    errdefer if (inner) |*i| i.deinit(parser.allocator);

                    return analysis.SyntaxTree{
                        .location = token.location,
                        .precedence = bp,
                        .type = cst_types.Unary,
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
        analysis.createNud(
            "builtin_unary_minus",
            -1999,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("-") } } },
            null, struct {
                pub fn unary_minus(
                    parser: *analysis.Parser,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("unary_minus: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard -

                    var inner = try parser.pratt(bp) orelse none: {
                        log.debug("unary_minus: no inner expression found", .{});
                        break :none null;
                    };
                    errdefer if (inner) |*i| i.deinit(parser.allocator);

                    return analysis.SyntaxTree{
                        .location = token.location,
                        .precedence = bp,
                        .type = cst_types.Unary,
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
        analysis.createNud(
            "builtin_unary_plus",
            -1999,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("+") } } },
            null, struct {
                pub fn unary_plus(
                    parser: *analysis.Parser,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("unary_plus: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard -

                    var inner = try parser.pratt(bp) orelse none: {
                        log.debug("unary_plus: no inner expression found", .{});
                        break :none null;
                    };
                    errdefer if (inner) |*i| i.deinit(parser.allocator);

                    return analysis.SyntaxTree{
                        .location = token.location,
                        .precedence = bp,
                        .type = cst_types.Unary,
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
pub fn leds() [17]analysis.Led {
    return .{
        analysis.createLed(
            "builtin_decl_inferred_type",
            std.math.minInt(i16),
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice(":=") } } },
            null, struct {
                pub fn decl(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
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

                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return analysis.SyntaxTree{
                        .location = lhs.location,
                        .precedence = bp,
                        .type = cst_types.Decl,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.decl,
        ),
        analysis.createLed(
            "builtin_set",
            std.math.minInt(i16),
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("=") } } },
            null, struct {
                pub fn set(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
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

                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return analysis.SyntaxTree{
                        .location = lhs.location,
                        .precedence = bp,
                        .type = cst_types.Set,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.set,
        ),
        analysis.createLed(
            "builtin_list",
            std.math.minInt(i16) + 100,
            .{ .standard = .{ .special = .{ .standard = .{ .escaped = .{ .standard = false }, .punctuation = .{ .standard = .comma } } } } },
            null, struct {
                pub fn list(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
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
                        const buff: []analysis.SyntaxTree = try parser.allocator.alloc(analysis.SyntaxTree, 1);
                        buff[0] = lhs;
                        return analysis.SyntaxTree{
                            .location = lhs.location,
                            .precedence = bp,
                            .type = cst_types.List,
                            .token = token,
                            .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
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

                        const new_operands = try parser.allocator.alloc(analysis.SyntaxTree, lhs_operands.len + rhs_operands.len);
                        @memcpy(new_operands[0..lhs_operands.len], lhs_operands);
                        @memcpy(new_operands[lhs_operands.len..], rhs_operands);

                        return .{
                            .location = lhs.location,
                            .precedence = bp,
                            .type = cst_types.List,
                            .token = token,
                            .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(new_operands),
                        };
                    } else if (lhs.type == cst_types.List) {
                        log.debug("list: lhs is a list, concatenating rhs", .{});

                        const lhs_operands = lhs.operands.asSlice();
                        defer parser.allocator.free(lhs_operands);

                        const new_operands = try parser.allocator.alloc(analysis.SyntaxTree, lhs_operands.len + 1);
                        @memcpy(new_operands[0..lhs_operands.len], lhs_operands);
                        new_operands[lhs_operands.len] = rhs;

                        return .{
                            .location = lhs.location,
                            .precedence = bp,
                            .type = cst_types.List,
                            .token = token,
                            .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(new_operands),
                        };
                    } else if (rhs.type == cst_types.List) {
                        log.debug("list: rhs is a list, concatenating lhs", .{});

                        const rhs_operands = rhs.operands.asSlice();
                        defer parser.allocator.free(rhs_operands);

                        const new_operands = try parser.allocator.alloc(analysis.SyntaxTree, rhs_operands.len + 1);
                        new_operands[0] = lhs;
                        @memcpy(new_operands[1..], rhs_operands);

                        return .{
                            .location = lhs.location,
                            .precedence = bp,
                            .type = cst_types.List,
                            .token = token,
                            .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(new_operands),
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
                        .location = lhs.location,
                        .precedence = bp,
                        .type = cst_types.List,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.list,
        ),
        analysis.createLed(
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
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
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

                        const new_operands = try parser.allocator.alloc(analysis.SyntaxTree, lhs_operands.len + rhs_operands.len);
                        @memcpy(new_operands[0..lhs_operands.len], lhs_operands);
                        @memcpy(new_operands[lhs_operands.len..], rhs_operands);

                        return .{
                            .location = lhs.location,
                            .precedence = bp,
                            .type = cst_types.Seq,
                            .token = token,
                            .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(new_operands),
                        };
                    } else if (lhs.type == cst_types.Seq) {
                        log.debug("seq: lhs is a seq, concatenating rhs", .{});

                        const lhs_operands = lhs.operands.asSlice();
                        defer parser.allocator.free(lhs_operands);

                        const new_operands = try parser.allocator.alloc(analysis.SyntaxTree, lhs_operands.len + 1);
                        @memcpy(new_operands[0..lhs_operands.len], lhs_operands);
                        new_operands[lhs_operands.len] = rhs;

                        return .{
                            .location = lhs.location,
                            .precedence = bp,
                            .type = cst_types.Seq,
                            .token = token,
                            .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(new_operands),
                        };
                    } else if (rhs.type == cst_types.Seq) {
                        log.debug("seq: rhs is a seq, concatenating lhs", .{});

                        const rhs_operands = rhs.operands.asSlice();
                        defer parser.allocator.free(rhs_operands);

                        const new_operands = try parser.allocator.alloc(analysis.SyntaxTree, rhs_operands.len + 1);
                        new_operands[0] = lhs;
                        @memcpy(new_operands[1..], rhs_operands);

                        return .{
                            .location = lhs.location,
                            .precedence = bp,
                            .type = cst_types.Seq,
                            .token = token,
                            .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(new_operands),
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
                        .location = lhs.location,
                        .precedence = bp,
                        .type = cst_types.Seq,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.seq,
        ),
        analysis.createLed(
            "builtin_apply",
            0,
            .any,
            null, struct {
                pub fn apply(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
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

                        const new_operands = try parser.allocator.alloc(analysis.SyntaxTree, lhs_operands.len + 1);
                        @memcpy(new_operands[0..lhs_operands.len], lhs_operands);
                        new_operands[lhs_operands.len] = rhs;

                        return .{
                            .location = lhs.location,
                            .precedence = bp,
                            .type = cst_types.Apply,
                            .token = token,
                            .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(new_operands),
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
                        .location = lhs.location,
                        .precedence = bp,
                        .type = cst_types.Apply,
                        .token = analysis.Token{
                            .location = token.location,
                            .tag = .sequence,
                            .data = analysis.TokenData{
                                .sequence = common.Id.Buffer(u8, .constant).fromSlice(" "),
                            },
                        },
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.apply,
        ),
        analysis.createLed(
            "builtin_mul",
            -1000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("*") } } },
            null, struct {
                pub fn mul(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("mul: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard operator

                    const rhs = if (try parser.pratt(bp + 1)) |r| r else {
                        log.debug("mul: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = rhs;

                    return analysis.SyntaxTree{
                        .location = lhs.location,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.mul,
        ),
        analysis.createLed(
            "builtin_div",
            -1000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("/") } } },
            null, struct {
                pub fn div(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("div: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard operator

                    const rhs = if (try parser.pratt(bp + 1)) |r| r else {
                        log.debug("div: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = rhs;

                    return analysis.SyntaxTree{
                        .location = lhs.location,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.div,
        ),
        analysis.createLed(
            "builtin_add",
            -2000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("+") } } },
            null, struct {
                pub fn add(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("add: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard operator

                    const rhs = if (try parser.pratt(bp + 1)) |r| r else {
                        log.debug("add: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = rhs;

                    return analysis.SyntaxTree{
                        .location = lhs.location,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.add,
        ),
        analysis.createLed(
            "builtin_sub",
            -2000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("-") } } },
            null, struct {
                pub fn sub(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("sub: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard operator

                    const rhs = if (try parser.pratt(bp + 1)) |r| r else {
                        log.debug("sub: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = rhs;

                    return analysis.SyntaxTree{
                        .location = lhs.location,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.sub,
        ),

        analysis.createLed(
            "builtin_eq",
            -4001,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("==") } } },
            null, struct {
                pub fn eq(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
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

                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return analysis.SyntaxTree{
                        .location = lhs.location,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.eq,
        ),

        analysis.createLed(
            "builtin_neq",
            -4001,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("!=") } } },
            null, struct {
                pub fn neq(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
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

                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return analysis.SyntaxTree{
                        .location = lhs.location,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.neq,
        ),

        analysis.createLed(
            "builtin_lt",
            -4000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("<") } } },
            null, struct {
                pub fn lt(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
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

                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return analysis.SyntaxTree{
                        .location = lhs.location,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.lt,
        ),

        analysis.createLed(
            "builtin_gt",
            -4000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice(">") } } },
            null, struct {
                pub fn gt(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
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

                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return analysis.SyntaxTree{
                        .location = lhs.location,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.gt,
        ),

        analysis.createLed(
            "builtin_leq",
            -4000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("<=") } } },
            null, struct {
                pub fn leq(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
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

                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return analysis.SyntaxTree{
                        .location = lhs.location,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.leq,
        ),

        analysis.createLed(
            "builtin_geq",
            -4000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice(">=") } } },
            null, struct {
                pub fn geq(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
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

                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return analysis.SyntaxTree{
                        .location = lhs.location,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.geq,
        ),

        analysis.createLed(
            "builtin_logical_and",
            -3000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("and") } } },
            null, struct {
                pub fn logical_and(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("logical_and: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard operator

                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("logical_and: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return analysis.SyntaxTree{
                        .location = lhs.location,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.logical_and,
        ),

        analysis.createLed(
            "builtin_logical_or",
            -3000,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("or") } } },
            null, struct {
                pub fn logical_or(
                    parser: *analysis.Parser,
                    lhs: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("logical_or: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard operator

                    const second_stmt = if (try parser.pratt(bp + 1)) |rhs| rhs else {
                        log.debug("logical_or: no rhs; panic", .{});
                        return error.UnexpectedInput;
                    };

                    const buff = try parser.allocator.alloc(analysis.SyntaxTree, 2);
                    buff[0] = lhs;
                    buff[1] = second_stmt;

                    return analysis.SyntaxTree{
                        .location = lhs.location,
                        .precedence = bp,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
                    };
                }
            }.logical_or,
        ),
    };
}
