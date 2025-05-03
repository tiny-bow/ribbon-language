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

/// Get the syntax for the meta-language.
pub fn getSyntax() *const analysis.Syntax {
    syntax_mutex.lock();
    defer syntax_mutex.unlock();

    if (syntax) |*s| {
        return s;
    }

    var out = analysis.Syntax.init(std.heap.page_allocator);

    inline for (comptime std.meta.fieldNames(@TypeOf(nud))) |name| {
        out.bindNud(@field(nud, name)) catch unreachable;
    }

    inline for (comptime std.meta.fieldNames(@TypeOf(led))) |name| {
        out.bindLed(@field(led, name)) catch unreachable;
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

    const out = try parser.pratt(std.math.maxInt(i16)) orelse return null;

    if (!parser.isEof()) {
        const rem = source[parser.lexer.location.buffer..];
        if (parser.lexer.iterator.peek_cache) |cached_char| {
            log.err("getCst: unused character in lexer cache: `{u}` ({x})", .{cached_char, cached_char});
        } else if (rem.len > 0) {
            log.err("getCst: unexpected input after parsing: `{s}` ({any})", .{rem, rem});
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
        .Qed = fresh.next(),
    };
};

pub fn assembleString(allocator: std.mem.Allocator, source: []const u8, string: analysis.SyntaxTree) ![]const u8 {
    std.debug.assert(string.type == cst_types.String);

    const subexprs = string.operands.asSlice();
    log.debug("assembling string from subexprs: {any}", .{subexprs});

    var out = pl.ArrayList(u8).empty;
    defer out.deinit(allocator);

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
                    '\\' => try out.append(allocator, '\\'),
                    'n' => try out.append(allocator, '\n'),
                    't' => try out.append(allocator, '\t'),
                    'r' => try out.append(allocator, '\r'),
                    '"' => try out.append(allocator, '"'),
                    '\'' => try out.append(allocator, '\''),
                    '0' => try out.append(allocator, 0),
                    else => return error.InvalidEscape,
                }
            } else {
                return error.InvalidEscape;
            }
        } else {
            var buf = [1]u8{0} ** 4;
            const len = std.unicode.utf8Encode(ch, &buf) catch unreachable;
            try out.appendSlice(allocator, buf[0..len]);
        }
    }

    return out.toOwnedSlice(allocator);
}

/// rml prefix/atomic parser defs.
pub const nud = .{
    .string = analysis.createNud(
        "builtin_string",
        std.math.minInt(i16),
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
    .leaf = analysis.createNud(
        "builtin_leaf",
        std.math.minInt(i16),
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
};

/// rml infix/postfix parser defs.
pub const led = .{
    .space_sig = analysis.createLed(
        "builtin_space_sig",
        std.math.maxInt(i16),
        .{ .standard = .{ .linebreak = .{ .standard = .{ .n = .any, .i = .{ .inverted = .unindent }} } } },
        null, struct {
            pub fn space_sig(
                parser: *analysis.Parser,
                first_stmt: analysis.SyntaxTree,
                bp: i16,
                token: analysis.Token,
            ) analysis.SyntaxError!?analysis.SyntaxTree {
                log.debug("space_sig: parsing token {}", .{token.data.linebreak});

                var buff: pl.ArrayList(analysis.SyntaxTree) = .empty;
                defer buff.deinit(parser.allocator);

                try buff.append(parser.allocator, first_stmt);

                switch (token.data.linebreak.i) {
                    .none => {
                        log.debug("space_sig: no indent", .{});
                    },
                    .indent => {
                        log.debug("space_sig: indent accepted by indentation parser", .{});

                        const buffer = try parser.allocator.alloc(analysis.SyntaxTree, 1);

                        buffer[0] = try parser.pratt(bp) orelse {
                            log.err("space_sig: indent block expected expression, got nothing", .{});
                            return error.UnexpectedToken;
                        };

                        const unindent = try parser.lexer.next() orelse {
                            return error.UnexpectedEof;
                        };

                        if (unindent.tag != .linebreak) {
                            log.err("space_sig: indent block end expected unindent, got: {}", .{unindent.tag});
                            return error.UnexpectedToken;
                        }

                        if (unindent.data.linebreak.i != .unindent) {
                            log.err("space_sig: indent block end expected unindent, got: {}", .{unindent.data.linebreak.i});
                            return error.UnexpectedToken;
                        }

                        log.debug("space_sig: indent block successfully parsed by indentation parser: {any}", .{buffer});

                        try buff.append(parser.allocator, analysis.SyntaxTree{
                            .location = token.location,
                            .type = cst_types.IndentedBlock,
                            .token = token,
                            .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(buffer),
                        });
                    },
                    .unindent => unreachable,
                }

                if (try parser.pratt(bp)) |second_stmt| {
                    try buff.append(parser.allocator, second_stmt);
                }

                return analysis.SyntaxTree{
                    .location = first_stmt.location,
                    .type = cst_types.Stmts,
                    .token = token,
                    .operands = common.Id.Buffer(analysis.SyntaxTree, .constant).fromSlice(try buff.toOwnedSlice(parser.allocator)),
                };
            }
        }.space_sig,
    ),
};
