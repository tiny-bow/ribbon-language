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

pub noinline fn dumpCstSExprs(source: []const u8, cst: analysis.SyntaxTree, writer: anytype) !void {
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
        } else {
            unreachable;
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
        .Apply = fresh.next(),
        .Binary = fresh.next(),
        .Qed = fresh.next(),
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
pub fn nuds() [5]analysis.Nud {
    return .{
        analysis.createNud(
            "builtin_leading_br",
            std.math.maxInt(i16),
            .{ .standard = .linebreak },
            null, struct {
                pub fn leading_br(
                    parser: *analysis.Parser,
                    _: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("leading_br: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard linebreak

                    return analysis.SyntaxTree{
                        .location = token.location,
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
                    _: i16,
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
                    _: i16,
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
                    _: i16,
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
                                .type = cst_types.StringSentinel,
                                .token = next_token,
                                .operands = .empty,
                            });

                            return analysis.SyntaxTree{
                                .location = token.location,
                                .type = cst_types.String,
                                .token = token,
                                .operands = .fromSlice(try buff.toOwnedSlice(parser.allocator)),
                            };
                        } else {
                            try buff.append(parser.allocator, analysis.SyntaxTree{
                                .location = next_token.location,
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
                    _: i16,
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
                            .type = cst_types.Int,
                            .token = token,
                            .operands = .empty,
                        };
                    } else if (utils.text.isAlphanumericStr(s)) {
                        log.debug("leaf: found identifier", .{});
                        return analysis.SyntaxTree{
                            .location = token.location,
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
    };
}

/// creates rml infix/postfix parser defs.
pub fn leds() [6]analysis.Led {
    return .{
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
                    first_stmt: analysis.SyntaxTree,
                    _: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("seq: first_stmt {}", .{first_stmt});

                    try parser.lexer.advance(); // discard linebreak

                    if (try parser.lexer.peek()) |next_token| {
                        if (next_token.tag == .indentation
                        and next_token.data.indentation == .unindent) {
                            log.debug("seq: found unindent token, returning lhs", .{});
                            return first_stmt;
                        }
                    } else {
                        log.debug("seq: no next token found; returning lhs", .{});
                        return first_stmt;
                    }

                    var second_stmt = if (try parser.pratt(std.math.minInt(i16))) |rhs| rhs else {
                        log.debug("no rhs, return lhs", .{});
                        return first_stmt;
                    };
                    errdefer second_stmt.deinit(parser.allocator);

                    log.debug("seq: found rhs {}", .{second_stmt});

                    const buff: []analysis.SyntaxTree = try parser.allocator.alloc(analysis.SyntaxTree, 2);

                    log.debug("seq: buffer allocation {x}", .{@intFromPtr(buff.ptr)});

                    buff[0] = first_stmt;
                    buff[1] = second_stmt;

                    log.debug("seq: buffer written; returning", .{});

                    return analysis.SyntaxTree{
                        .location = first_stmt.location,
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

                    if (rhs.type == cst_types.Qed) {
                        log.debug("apply: rhs is qed, returning lhs", .{});
                        return lhs;
                    }

                    const buff: []analysis.SyntaxTree = try parser.allocator.alloc(analysis.SyntaxTree, 2);

                    log.debug("apply: buffer allocation {x}", .{@intFromPtr(buff.ptr)});

                    buff[0] = lhs;
                    buff[1] = rhs;

                    log.debug("apply: buffer written; returning", .{});

                    return analysis.SyntaxTree{
                        .location = lhs.location,
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
            -100,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("*") } } },
            null, struct {
                pub fn mul(
                    parser: *analysis.Parser,
                    first_stmt: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("mul: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard operator

                    var buff: pl.ArrayList(analysis.SyntaxTree) = .empty;
                    defer buff.deinit(parser.allocator);

                    try buff.append(parser.allocator, first_stmt);

                    if (try parser.pratt(bp + 1)) |second_stmt| {
                        try buff.append(parser.allocator, second_stmt);
                    } else {
                        log.debug("no rhs, panic", .{});
                        return error.UnexpectedInput;
                    }

                    return analysis.SyntaxTree{
                        .location = first_stmt.location,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(try buff.toOwnedSlice(parser.allocator)),
                    };
                }
            }.mul,
        ),
        analysis.createLed(
            "builtin_div",
            -100,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("/") } } },
            null, struct {
                pub fn div(
                    parser: *analysis.Parser,
                    first_stmt: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("div: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard operator

                    var buff: pl.ArrayList(analysis.SyntaxTree) = .empty;
                    defer buff.deinit(parser.allocator);

                    try buff.append(parser.allocator, first_stmt);

                    if (try parser.pratt(bp + 1)) |second_stmt| {
                        try buff.append(parser.allocator, second_stmt);
                    } else {
                        log.debug("no rhs, panic", .{});
                        return error.UnexpectedInput;
                    }

                    return analysis.SyntaxTree{
                        .location = first_stmt.location,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(try buff.toOwnedSlice(parser.allocator)),
                    };
                }
            }.div,
        ),
        analysis.createLed(
            "builtin_add",
            -200,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("+") } } },
            null, struct {
                pub fn add(
                    parser: *analysis.Parser,
                    first_stmt: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("add: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard operator

                    var buff: pl.ArrayList(analysis.SyntaxTree) = .empty;
                    defer buff.deinit(parser.allocator);

                    try buff.append(parser.allocator, first_stmt);

                    if (try parser.pratt(bp + 1)) |second_stmt| {
                        try buff.append(parser.allocator, second_stmt);
                    } else {
                        log.debug("no rhs, panic", .{});
                        return error.UnexpectedInput;
                    }

                    return analysis.SyntaxTree{
                        .location = first_stmt.location,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(try buff.toOwnedSlice(parser.allocator)),
                    };
                }
            }.add,
        ),
        analysis.createLed(
            "builtin_sub",
            -200,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("-") } } },
            null, struct {
                pub fn sub(
                    parser: *analysis.Parser,
                    first_stmt: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("sub: parsing token {}", .{token});

                    try parser.lexer.advance(); // discard operator

                    var buff: pl.ArrayList(analysis.SyntaxTree) = .empty;
                    defer buff.deinit(parser.allocator);

                    try buff.append(parser.allocator, first_stmt);

                    if (try parser.pratt(bp + 1)) |second_stmt| {
                        try buff.append(parser.allocator, second_stmt);
                    } else {
                        log.debug("no rhs, panic", .{});
                        return error.UnexpectedInput;
                    }

                    return analysis.SyntaxTree{
                        .location = first_stmt.location,
                        .type = cst_types.Binary,
                        .token = token,
                        .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(try buff.toOwnedSlice(parser.allocator)),
                    };
                }
            }.sub,
        ),
    };
}
