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
            try writer.print("\"{s}\"", .{cst.token.data.sequence.asSlice()});
        },
        cst_types.IndentedBlock => try writer.writeAll("(do"),
        cst_types.Stmts => try writer.writeAll("(begin"),
        else => {
            switch (cst.token.tag) {
                .sequence => {
                    try writer.writeAll("(");
                    try writer.print("{s}", .{cst.token.data.sequence.asSlice()});
                },
                else => try writer.print("({}", .{cst.token}),
            }
        },
    }

    switch (cst.type) {
        cst_types.String, cst_types.Identifier, cst_types.Int => return,
        else => {
            for (cst.operands.asSlice()) |child| {
                try writer.writeByte(' ');
                try dumpCstSExprs(source, child, writer);
            }

            try writer.writeByte(')');
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
) analysis.SyntaxError!analysis.Parser {
    const ml_syntax = getSyntax();
    return ml_syntax.createParser(allocator, lexer_settings, source);
}

/// Parse a meta-language source string to a concrete syntax tree.
/// * Returns null if the source is empty.
/// * Returns an error if we cannot parse the entire source.
pub fn getCst(
    allocator: std.mem.Allocator,
    lexer_settings: analysis.LexerSettings,
    source: []const u8,
) analysis.SyntaxError!?analysis.SyntaxTree {
    var parser = try getParser(allocator, lexer_settings, source);

    const out = try parser.pratt(std.math.minInt(i16)) orelse return null;

    if (!parser.isEof()) {
        const rem = source[parser.lexer.location.buffer..];
        if (parser.lexer.iterator.peek_cache) |cached_char| {
            log.err("getCst: unused character in lexer cache {}: `{u}` ({x})", .{parser.lexer.location, cached_char, cached_char});
        } else if (rem.len > 0) {
            log.err("getCst: unexpected input after parsing {}: `{s}` ({any})", .{parser.lexer.location, rem, rem});
        } else {
            unreachable;
        }
        return analysis.SyntaxError.UnexpectedInput;
    }

    log.debug("getCst: parsed successfully; {}", .{out});

    return out;
}

/// rml concrete syntax tree types.
pub const cst_types = gen: {
    var fresh = common.Id.of(analysis.SyntaxTree).fromInt(1);

    break :gen .{
        .Int = fresh.next(),
        .String = fresh.next(),
        .StringElement = fresh.next(),
        .StringSentinel = fresh.next(),
        .Identifier = fresh.next(),
        .IndentedBlock = fresh.next(),
        .Stmts = fresh.next(),
        .Binary = fresh.next(),
        .Qed = fresh.next(),
    };
};

pub fn assembleString(writer: anytype, source: []const u8, string: analysis.SyntaxTree) !void {
    std.debug.assert(string.type == cst_types.String);

    const subexprs = string.operands.asSlice();
    log.debug("assembling string from subexprs: {any}", .{subexprs});

    const start_loc = subexprs[0].location;
    const end_loc = subexprs[subexprs.len - 1].location;

    log.debug("string subsection: {} -> {}", .{start_loc, end_loc});

    if (start_loc.buffer > end_loc.buffer or end_loc.buffer > source.len) {
        log.err("assembleString: invalid string {} -> {}", .{start_loc, end_loc});
        return error.InvalidString;
    }

    const sub = source[start_loc.buffer..end_loc.buffer];

    log.debug("string subsection: `{s}`", .{sub});

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
pub fn nuds() [3]analysis.Nud {
    return .{
        analysis.createNud(
            "builtin_string",
            std.math.maxInt(i16),
            .{ .standard = .{ .special = .{ .standard = .{ .escaped = .{ .standard = false }, .punctuation = .{ .standard = .double_quote } } } } },
            null, struct {
                pub fn string(
                    parser: *analysis.Parser,
                    _: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("string: parsing token {}", .{token});

                    var buff: pl.ArrayList(analysis.SyntaxTree) = .empty;
                    defer buff.deinit(parser.allocator);

                    while (try parser.lexer.next()) |next_token| {
                        if (next_token.tag == .special
                        and !next_token.data.special.escaped
                        and next_token.data.special.punctuation == .double_quote) {
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
                    _: *analysis.Parser,
                    _: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("leaf: parsing token", .{});
                    log.debug("{}", .{token});
                    const s = token.data.sequence.asSlice();
                    log.debug("leaf: checking token {s}", .{s});

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
        analysis.createNud(
            "leading_linebreak",
            std.math.maxInt(i16),
            .{ .standard = .{ .linebreak = .any } },
            null, struct {
                pub fn indentation(
                    parser: *analysis.Parser,
                    _: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    const save_state = parser.lexer;

                    log.debug("leading_linebreak: parsing token {}", .{token});

                    const next_token = try parser.lexer.next() orelse {
                        log.err("leading_linebreak: source ends with whitespace, returning sentinel", .{});

                        return analysis.SyntaxTree {
                            .location = token.location,
                            .type = cst_types.Qed,
                            .token = token,
                            .operands = .empty,
                        };
                    };

                    log.debug("leading_linebreak: checking next token {}", .{next_token});

                    if (next_token.tag == .indentation) {
                        log.debug("leading_linebreak: found indentation token", .{});
                        if (next_token.data.indentation == .indent) {
                            log.debug("leading_linebreak: found indent token, returning sentinel", .{});
                            return parser_utils.indentation(parser, 0, next_token);
                        } else {
                            log.debug("leading_linebreak: found unindent token, this is a sentinel; rejecting", .{});
                            return null;
                        }
                    } else {
                        log.debug("leading_linebreak: next token is not indentation, recursing pratt", .{});
                    }

                    parser.lexer = save_state;

                    return parser.pratt(std.math.minInt(i16));
                }
            }.indentation,
        ),
    };
}

pub const parser_utils = struct {
    pub fn indentation(
        parser: *analysis.Parser,
        _: i16,
        token: analysis.Token,
    ) analysis.SyntaxError!?analysis.SyntaxTree {
        log.debug("indentation: parsing token {}", .{token.data.linebreak});

        const buff = parser.allocator.alloc(analysis.SyntaxTree, 1) catch unreachable;

        buff[0] = try parser.pratt(std.math.minInt(i16)) orelse return null;

        const lb = try parser.lexer.next() orelse {
            return error.UnexpectedEof;
        };

        if (lb.tag != .linebreak) {
            log.err("indentation: indent block end expected linebreak, got: {}", .{lb.tag});
            return error.UnexpectedToken;
        }

        const save_state = parser.lexer;
        const ind = try parser.lexer.next() orelse {
            return error.UnexpectedEof;
        };

        if (ind.tag != .indentation) {
            log.err("indentation: indent block end expected indentation token, got: {}", .{ind.tag});
            return error.UnexpectedToken;
        }

        if (ind.data.indentation != .unindent) {
            log.err("indentation: indent block end expected unindent token, got: {}", .{ind.data.indentation});
            return error.UnexpectedToken;
        }

        parser.lexer = save_state;

        log.debug("indentation: indent block successfully parsed by indentation parser: {any}", .{buff});

        return analysis.SyntaxTree{
            .location = buff[0].location,
            .type = cst_types.IndentedBlock,
            .token = token,
            .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buff),
        };
    }
};


/// creates rml infix/postfix parser defs.
pub fn leds() [5]analysis.Led {
    return .{
        analysis.createLed(
            "builtin_mul",
            200,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("*") } } },
            null, struct {
                pub fn mul(
                    parser: *analysis.Parser,
                    first_stmt: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("mul: parsing token {}", .{token});

                    var buff: pl.ArrayList(analysis.SyntaxTree) = .empty;
                    defer buff.deinit(parser.allocator);

                    try buff.append(parser.allocator, first_stmt);

                    if (try parser.pratt(bp - 1)) |second_stmt| {
                        try buff.append(parser.allocator, second_stmt);
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
            200,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("/") } } },
            null, struct {
                pub fn div(
                    parser: *analysis.Parser,
                    first_stmt: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("div: parsing token {}", .{token});

                    var buff: pl.ArrayList(analysis.SyntaxTree) = .empty;
                    defer buff.deinit(parser.allocator);

                    try buff.append(parser.allocator, first_stmt);

                    if (try parser.pratt(bp - 1)) |second_stmt| {
                        try buff.append(parser.allocator, second_stmt);
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
            100,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("+") } } },
            null, struct {
                pub fn add(
                    parser: *analysis.Parser,
                    first_stmt: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("add: parsing token {}", .{token});

                    var buff: pl.ArrayList(analysis.SyntaxTree) = .empty;
                    defer buff.deinit(parser.allocator);

                    try buff.append(parser.allocator, first_stmt);

                    if (try parser.pratt(bp - 1)) |second_stmt| {
                        try buff.append(parser.allocator, second_stmt);
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
            100,
            .{ .standard = .{ .sequence = .{ .standard = .fromSlice("-") } } },
            null, struct {
                pub fn sub(
                    parser: *analysis.Parser,
                    first_stmt: analysis.SyntaxTree,
                    bp: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("sub: parsing token {}", .{token});

                    var buff: pl.ArrayList(analysis.SyntaxTree) = .empty;
                    defer buff.deinit(parser.allocator);

                    try buff.append(parser.allocator, first_stmt);

                    if (try parser.pratt(bp - 1)) |second_stmt| {
                        try buff.append(parser.allocator, second_stmt);
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
        analysis.createLed(
            "builtin_newline",
            std.math.minInt(i16),
            .{
                .any_of = &.{
                    .{ .linebreak = .any },
                    .{ .indentation = .{ .standard = .unindent } },
                },
            },
            null, struct {
                pub fn newline(
                    parser: *analysis.Parser,
                    first_stmt: analysis.SyntaxTree,
                    _: i16,
                    token: analysis.Token,
                ) analysis.SyntaxError!?analysis.SyntaxTree {
                    log.debug("newline: parsing token {}", .{token});

                    switch (token.tag) {
                        .linebreak => {
                            const lexer_save_state = parser.lexer;

                            if (try parser.lexer.next()) |next_token| {
                                log.debug("newline: checking next token {} is not indentation", .{next_token});
                                if (next_token.tag == .indentation) {
                                    log.debug("newline: found indentation token; rejecting", .{});
                                    return null;
                                } else {
                                    log.debug("newline: not indentation, continuing with stmt parse", .{});
                                    parser.lexer = lexer_save_state;
                                }
                            }
                        },
                        else => {},
                    }

                    var buff: pl.ArrayList(analysis.SyntaxTree) = .empty;
                    defer buff.deinit(parser.allocator);

                    try buff.append(parser.allocator, first_stmt);

                    if (try parser.pratt(std.math.minInt(i16))) |second_stmt| {
                        try buff.append(parser.allocator, second_stmt);

                        return analysis.SyntaxTree{
                            .location = first_stmt.location,
                            .type = cst_types.Stmts,
                            .token = token,
                            .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(try buff.toOwnedSlice(parser.allocator)),
                        };
                    } else {
                        return first_stmt;
                    }
                }
            }.newline,
        )
    };
}
