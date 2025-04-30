//! # meta-language
//! The Ribbon Meta Language (Rml) is a compile-time meta-programming language targeting the ribbon virtual machine.
//!
//! While Ribbon does not have a `core.Value` sum type, Rml does have such a type,
//! and it is used to represent both source code and user data structures.
const meta_language = @This();

const std = @import("std");
const log = std.log.scoped(.Rml);

const pl = @import("platform");
const common = @import("common");
const utils = @import("utils");

test {
    std.testing.refAllDeclsRecursive(@This());
}

/// A position in the source code, in terms of the buffer.
pub const BufferPosition = u64;

/// A position in the source code, in terms of the line and column.
pub const VisualPosition = packed struct {
    /// 1-based line number.
    line: u32 = 1,
    /// 1-based column number.
    column: u32 = 1,
};

/// A location in the source code, both buffer-wise and line and column.
pub const Location = packed struct {
    buffer: BufferPosition = 0,
    visual: VisualPosition = .{},
    pub fn format(self: *const Location, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}:{} ({})", .{ self.visual.line, self.visual.column, self.buffer });
    }
};

/// A token produced by the lexer.
pub const Token = extern struct {
    /// The original location of the token in the source code.
    location: Location,
    /// The type of token data contained in this token.
    tag: TokenType,
    /// The actual value of the token.
    data: TokenData,

    pub fn format(self: Token, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self.tag) {
            .sequence => {
                const s = self.data.sequence;
                try writer.print("s⟨{s}⟩", .{ s.asSlice() });
            },
            .linebreak => {
                const lb = self.data.linebreak;

                if (lb.i > 0) {
                    try writer.print("b⟨⇓{}⇒{}⟩", .{ lb.n, lb.i });
                } else if (lb.i < 0) {
                    try writer.print("b⟨⇓{}⇐{}⟩", .{ lb.n, -lb.i });
                } else {
                    try writer.print("b⟨⇓{}⟩", .{ lb.n });
                }
            },
            .special => {
                const p = self.data.special;

                if (p.escaped) {
                    try writer.print("p⟨\\{u}⟩", .{ p.punctuation.toChar() });
                } else {
                    try writer.print("p⟨{u}⟩", .{ p.punctuation.toChar() });
                }
            },
        }
    }
};

/// This is an enumeration of the types of tokens that can be produced by the lexer.
pub const TokenType = enum (u8) {
    /// A sequence of characters that do not fit the other categories,
    /// and contain no control characters or whitespace.
    sequence = 0,
    /// \n * `n` new lines with `i`* relative indentation change.
    ///
    /// * provided in text-format-agnostic "levels";
    /// to get actual indentations inspect column of the next token
    linebreak = 1,
    /// Special lexical control characters, such as `{`, `\"`, etc.
    special = 2,
};

/// This is a packed union of all the possible types of tokens that can be produced by the lexer.
pub const TokenData = packed union {
    /// a sequence of characters that do not fit the other categories,
    /// and contain no control characters or whitespace.
    sequence: common.Id.Buffer(u8, .constant),
    /// \n * `n` new lines with `i`* relative indentation change.
    ///
    /// * provided in text-format-agnostic "levels";
    /// to get actual indentations inspect column of the next token
    linebreak: packed struct {
        n: u32,
        i: i32,
    },
    /// Special lexical control characters, such as `{`, `\"`, etc.
    special: Special,
};

/// While we are trying to allow as much syntactic flexibility as we can, we must consider some
/// characters reserved, ie unusable for custom purposes like operator overloading, in order to make
/// sense of anything.
///
/// Additionally, we need to distinguish whether some of these characters
/// are proceeded by the `\` character.
pub const Special = packed struct {
    /// Whether or not the special punctuation character is escaped with a backslash.
    escaped: bool,
    /// The special punctuation character.
    punctuation: Punctuation,
};

/// This is an enumeration of the special characters reserved by Ribbon.
/// ```
/// " ' ` . , ; {} () [] \\ #
/// ```
pub const Punctuation = enum(pl.Char) {
    /// `(`
    paren_l = '(',
    /// `)`
    paren_r = ')',
    /// `{`
    brace_l = '{',
    /// `}`
    brace_r = '}',
    /// `[`
    bracket_l = '[',
    /// `]`
    bracket_r = ']',
    /// `.`
    dot = '.',
    /// `,`
    comma = ',',
    /// `;`
    semicolon = ';',
    /// `"`
    double_quote = '"',
    /// `'`
    single_quote = '\'',
    /// `
    backtick = '`',
    /// \\
    backslash = '\\',
    /// `#`
    hash = '#',

    /// Given a punctuation type, returns the corresponding character.
    pub fn toChar(self: Punctuation) pl.Char {
        return @intFromEnum(self);
    }

    /// Given a character, returns the corresponding punctuation type.
    /// * This is only error checked in safe mode. See also `castChar`.
    pub fn fromChar(ch: pl.Char) Punctuation {
        return @enumFromInt(ch);
    }

    /// Given a character, returns whether it has a punctuation type.
    pub fn includesChar(ch: pl.Char) bool {
        inline for (comptime std.meta.fieldNames(Punctuation)) |p| {
            if (ch == comptime @intFromEnum(@field(Punctuation, p))) return true;
        }

        return false;
    }

    /// Given a character, returns the corresponding punctuation type.
    /// * This returns null if the character is not punctuation. See also `fromChar`.
    pub fn castChar(ch: pl.Char) ?Punctuation {
        if (!includesChar(ch)) return null;

        return @enumFromInt(ch);
    }
};

/// Basic utf8 scanner.
pub const CodepointIterator = struct {
    /// Utf8 encoded bytes to scan.
    bytes: []const u8,
    /// Current position in the byte array.
    i: usize,

    pub const Error = error {
        /// The iterator encountered bytes that were not valid utf-8.
        BadEncoding,
    };

    pub fn totalLength(it: *CodepointIterator) usize {
        return it.bytes.len;
    }

    pub fn remainingLength(it: *CodepointIterator) usize {
        return it.bytes.len - it.i;
    }

    pub fn from(bytes: []const u8) CodepointIterator {
        return CodepointIterator{
            .bytes = bytes,
            .i = 0,
        };
    }

    pub fn isEof(it: *CodepointIterator) bool {
        return it.i >= it.bytes.len;
    }

    pub fn nextSlice(it: *CodepointIterator) Error!?[]const u8 {
        if (it.i >= it.bytes.len) {
            return null;
        }

        const cp_len = std.unicode.utf8ByteSequenceLength(it.bytes[it.i]) catch return error.BadEncoding;
        it.i += cp_len;
        return it.bytes[it.i - cp_len .. it.i];
    }

    pub fn next(it: *CodepointIterator) Error!?u21 {
        const slice = try it.nextSlice() orelse return null;
        return std.unicode.utf8Decode(slice) catch return error.BadEncoding;
    }
};

/// Create a new lexer for a given source, allowing single token lookahead.
pub fn lexWithPeek(
    settings: Lexer0.Settings,
    source: []const u8,
) LexicalError!Lexer1 {
    const lexer = try Lexer0.init(settings, source);
    return try Lexer1.from(lexer);
}

/// Lexical analysis abstraction with one token lookahead.
pub const Lexer1 = common.PeekableIterator(Lexer0, Token, .use_try(LexicalError));


/// Errors that can occur in the lexer.
pub const LexicalError = error {
    OutOfMemory,
    /// The lexer encountered bytes that were not valid utf-8.
    BadEncoding,
    /// The lexer encountered the end of input while processing a compound token.
    UnexpectedEof,
    /// The lexer encountered a utf-valid but unexpected codepoint or combination thereof.
    UnexpectedInput,
    /// The lexer encountered an unexpected indentation level;
    /// * ie an indentation level that un-indents the current level,
    /// but does not match any existing level.
    UnexpectedIndent,
};

pub const Level = u16;
pub const MAX_LEVELS = 32;

/// Basic lexical analysis abstraction, no lookahead.
pub const Lexer0 = struct {
    /// Utf8 source code being lexically analyzed.
    source: []const u8,
    /// Iterator over `source`.
    iterator: common.PeekableIterator(CodepointIterator, pl.Char, .use_try(CodepointIterator.Error)),
    /// The indentation levels at this point in the source code.
    indentation: [MAX_LEVELS]Level,
    /// The number of indentation levels currently in use.
    levels: u8 = 1,
    level_change_queue: [MAX_LEVELS]Level = [1]Level{0} ** MAX_LEVELS,
    levels_queued: u8 = 0,
    /// The current location in the source code.
    location: Location,

    /// Alias for `LexicalError`.
    pub const Error = LexicalError;

    /// Lexical analysis settings.
    pub const Settings = struct {
        /// If you are analyzing a subsection of a file that is itself indented,
        /// set this to the indentation level of the surrounding text.
        startingIndent: Level = 0,
        /// The offset to apply to the visual position (line and column) of the lexer,
        /// when creating token locations.
        attrOffset: VisualPosition = .{},
    };

    /// Initialize a new lexer for a given source.
    pub fn init(settings: Settings, source: []const u8) error{BadEncoding}!Lexer0 {
        log.debug("Lexing string ⟨{s}⟩", .{source});

        return Lexer0 {
            .source = source,
            .iterator = try .from(.from(source)),
            .indentation = [1]Level{settings.startingIndent} ++ ([1]Level{0} ** (MAX_LEVELS - 1)),
            .location = Location {
                .visual = settings.attrOffset,
            },
        };
    }

    /// Determine whether the lexer has processed the last character in the source code.
    pub fn isEof(self: *const Lexer0) bool {
        return self.iterator.isEof();
    }

    /// Get the next character in the source code without consuming it.
    /// * Returns null if the end of the source code is reached.
    pub fn peekChar(self: *Lexer0) Error!?pl.Char {
        return self.iterator.peek();
    }

    /// Get the current character in the source code and consume it.
    /// * Updates lexer source location
    /// * Returns null if the end of the source code is reached.
    pub fn nextChar(self: *Lexer0) Error!?pl.Char {
        const ch = try self.iterator.next() orelse return null;

        if (ch == '\n') {
            self.location.visual.line += 1;
            self.location.visual.column = 1;
        } else if (!utils.text.isControl(ch)) {
            self.location.visual.column += 1;
        }

        self.location.buffer += std.unicode.utf8CodepointSequenceLength(ch) catch unreachable;

        return ch;
    }

    /// Consume the current character in the source code.
    /// * Updates lexer source location
    /// * No-op if the end of the source code is reached.
    pub fn advanceChar(self: *Lexer0) Error!void {
        _ = try self.nextChar();
    }

    /// Get the current indentation level.
    pub fn currentIndentation(self: *const Lexer0) u32 {
        std.debug.assert(self.levels > 0);
        return self.indentation[self.levels - 1];
    }

    /// Get the next token from the lexer's source code.
    pub fn next(self: *Lexer0) Error!?Token {
        var start = self.location;

        var tag: TokenType = undefined;

        if (self.levels_queued > 0) {
            log.debug("processing queued indentation level {}", .{self.levels_queued});

            self.levels_queued -= 1;

            return Token{
                .location = start,
                .tag = .linebreak,
                .data = TokenData{
                    .linebreak = .{ .n = 0, .i = -1 },
                },
            };
        }

        const data = char_switch: switch (try self.nextChar() orelse return null) {
            '\n' => {
                log.debug("processing line break", .{});

                tag = .linebreak;

                var n: u32 = 1;

                line_loop: while(try self.peekChar()) |pk| {
                    if (pk == '\n') {
                        n += 1;
                    } else if (!utils.text.isSpace(pk)) {
                        break :line_loop;
                    }

                    try self.advanceChar();
                }

                // we can compare the current column with the previous indentation level
                // to determine if we are increasing or decreasing indentation
                const oldIndent = self.currentIndentation();
                const newIndent = self.location.visual.column - 1;

                const oldLen = self.levels;
                std.debug.assert(oldLen > 0);

                if (newIndent > oldIndent) {
                    log.debug("increasing indentation to {} ({})", .{ oldLen, newIndent });

                    self.indentation[self.levels] = @intCast(newIndent); // TODO: check for overflow?
                    self.levels += 1;

                    break :char_switch TokenData { .linebreak = .{ .n = n, .i = 1 } };
                } else if (newIndent < oldIndent) {
                    // we need to traverse back down the indentation stack until we find the right level
                    var newIndentIndex = self.levels - 1;
                    while (true) {
                        const indent = self.indentation[newIndentIndex];
                        log.debug("checking vs indentation level {} ({})", .{ newIndentIndex, indent });

                        if (indent == newIndent) break;

                        if (indent < newIndent) {
                            log.err("unmatched indentation level {}", .{ newIndent });
                            return error.UnexpectedIndent;
                        }

                        newIndentIndex -= 1;
                    }

                    log.debug("decreasing indentation to {} ({})", .{ newIndentIndex, newIndent });

                    self.levels = newIndentIndex + 1;

                    const level_delta = oldLen - self.levels;

                    self.levels_queued = level_delta - 1;

                    break :char_switch TokenData { .linebreak = .{ .n = n, .i = -1 } };
                } else {
                    log.debug("same indentation level {} ({})", .{ self.levels - 1, n });

                    break :char_switch TokenData { .linebreak = .{ .n = n, .i = 0 } };
                }
            },
            '\\' => {
                tag = .special;
                if (try self.peekChar()) |pk| {
                    if (Punctuation.castChar(pk)) |esc| {
                        try self.advanceChar();

                        log.debug("escaped punctuation", .{});

                        break :char_switch TokenData { .special = .{ .punctuation = esc, .escaped = true } };
                    }
                }

                log.debug("unescaped backslash character", .{});

                break :char_switch TokenData { .special = .{ .punctuation = .fromChar('\\'), .escaped = false } };
            },
            else => |x| {
                if (utils.text.isSpace(@intCast(x))) {
                    log.debug("skipping whitespace {u} (0x{x:0>2})", .{x, x});

                    start = self.location;

                    continue :char_switch try self.nextChar() orelse {
                        return null;
                    };
                }

                if (utils.text.isControl(@intCast(x))) {
                    log.err("unexpected control character {u} (0x{x:0>2})", .{x, x});
                    return error.UnexpectedInput;
                }

                if (Punctuation.castChar(@intCast(x))) |p| {
                    tag = .special;

                    log.debug("punctuation {u} (0x{x:0>2})", .{p.toChar(), p.toChar()});

                    break :char_switch TokenData { .special = .{ .punctuation = p, .escaped = false } };
                }

                tag = .sequence;

                log.debug("processing sequence", .{});

                symbol_loop: while (try self.peekChar()) |pk| {
                    if (utils.text.isSpace(@intCast(pk))
                    or utils.text.isControl(@intCast(pk))
                    or Punctuation.includesChar(@intCast(pk))) {
                        log.debug("ending sequence at {u} (0x{x:0>2})", .{pk, pk});
                        break :symbol_loop;
                    }

                    try self.advanceChar();
                }

                const end = self.location;

                const len = end.buffer - start.buffer;

                if (len == 0) {
                    return null;
                }

                const seq = self.source[start.buffer..end.buffer];

                log.debug("sequence {s}", .{seq});

                break :char_switch TokenData { .sequence = .fromSlice(seq) };
            }
        };

        return Token {
            .location = start,
            .tag = tag,
            .data = data,
        };
    }
};


test "lexer_basic_integration" {
    var lexer = try lexWithPeek(.{},
        \\test
        \\    foo
        \\        [
        \\            1,
        \\            2,
        \\            3
        \\        ]
        \\
    );

    defer lexer.deinit();

    const expect = [_]Token {
        .{
            .location = undefined,
            .tag = .sequence,
            .data = .{ .sequence = .fromSlice("test") },
        },
        .{
            .location = undefined,
            .tag = .linebreak,
            .data = .{ .linebreak = .{ .n = 1, .i = 1 } },
        },
        .{
            .location = undefined,
            .tag = .sequence,
            .data = .{ .sequence = .fromSlice("foo") },
        },
        .{
            .location = undefined,
            .tag = .linebreak,
            .data = .{ .linebreak = .{ .n = 1, .i = 1 } },
        },
        .{
            .location = undefined,
            .tag = .special,
            .data = .{ .special = .{ .escaped = false, .punctuation = Punctuation.fromChar('[') } },
        },
        .{
            .location = undefined,
            .tag = .linebreak,
            .data = .{ .linebreak = .{ .n = 1, .i = 1 } },
        },
        .{
            .location = undefined,
            .tag = .sequence,
            .data = .{ .sequence = .fromSlice("1") },
        },
        .{
            .location = undefined,
            .tag = .special,
            .data = .{ .special = .{ .escaped = false, .punctuation = Punctuation.fromChar(',') } },
        },
        .{
            .location = undefined,
            .tag = .linebreak,
            .data = .{ .linebreak = .{ .n = 1, .i = 0 } },
        },
        .{
            .location = undefined,
            .tag = .sequence,
            .data = .{ .sequence = .fromSlice("2") },
        },
        .{
            .location = undefined,
            .tag = .special,
            .data = .{ .special = .{ .escaped = false, .punctuation = Punctuation.fromChar(',') } },
        },
        .{
            .location = undefined,
            .tag = .linebreak,
            .data = .{ .linebreak = .{ .n = 1, .i = 0 } },
        },
        .{
            .location = undefined,
            .tag = .sequence,
            .data = .{ .sequence = .fromSlice("3") },
        },
        .{
            .location = undefined,
            .tag = .linebreak,
            .data = .{ .linebreak = .{ .n = 1, .i = -1 } },
        },
        .{
            .location = undefined,
            .tag = .special,
            .data = .{ .special = .{ .escaped = false, .punctuation = Punctuation.fromChar(']') } },
        },
        .{
            .location = undefined,
            .tag = .linebreak,
            .data = .{ .linebreak = .{ .n = 1, .i = -1 } },
        },
        .{
            .location = undefined,
            .tag = .linebreak,
            .data = .{ .linebreak = .{ .n = 0, .i = -1 } },
        },
    };

    for (expect) |e| {
        const it = lexer.next() catch |err| {
            log.err("{}: {s}\n", .{ lexer.inner.location, @errorName(err) });
            return err;
        };

        if (it) |tok| {
            log.debug("{} to {}: {} (expecting {})\n", .{ tok.location, lexer.inner.location, tok.data, e });

            try std.testing.expectEqual(e.tag, tok.tag);
            switch (e.tag) {
                .sequence => {
                    const s = e.data.sequence;
                    try std.testing.expectEqualSlices(u8, s.asSlice(), tok.data.sequence.asSlice());
                },

                .special => {
                    const p = e.data.special;
                    try std.testing.expectEqual(p, tok.data.special);
                },

                .linebreak => {
                    const l = e.data.linebreak;
                    try std.testing.expectEqual(l.n, tok.data.linebreak.n);
                    try std.testing.expectEqual(l.i, tok.data.linebreak.i);
                },
            }
        } else {
            log.err("unexpected EOF {}; expected {}\n", .{ lexer.inner.location, e });
            return error.UnexpectedEof;
        }
    }

    try std.testing.expectEqual(lexer.inner.source.len, lexer.inner.location.buffer);
}

/// Errors that can occur in the parser.
pub const SyntaxError = error {
    /// The parser encountered an unexpected token.
    UnexpectedToken,
} || LexicalError;

/// Pratt parser.
pub const Parser = struct {
    /// The allocator to store parsed expressions in.
    allocator: std.mem.Allocator,
    /// The syntax used by this parser.
    syntax: *Syntax,
    /// Token stream being parsed.
    lexer: Lexer0,

    /// Alias for `SyntaxError`.
    pub const Error = SyntaxError;

    /// Create a new parser.
    pub fn init(
        allocator: std.mem.Allocator,
        syntax: *Syntax,
        lexer: Lexer0,
    ) Parser {
        return Parser{
            .allocator = allocator,
            .syntax = syntax,
            .lexer = lexer,
        };
    }


    /// Run the pratt algorithm at the current offset in the lexer stream.
    pub fn pratt(
        self: *Parser,
        binding_power: i64,
    ) Error!?Expr {
        var out: Expr = undefined;
        var err: SyntaxError = undefined;

        var lexer_save_state = self.lexer;

        const first_token = try self.lexer.next() orelse return null;

        const nuds = try self.syntax.findNuds(&first_token);

        if (nuds.len == 0) {
            self.lexer = lexer_save_state;
            return error.UnexpectedToken;
        }

        if (nuds[0].binding_power > binding_power) return null;

        var lhs = nuds: for (nuds) |nud| {
            switch (nud.invoke(.{self, nud.binding_power, first_token, &out, &err})) {
                .okay => break :nuds out,
                .panic => return err,
                .reject => continue :nuds,
            }
        } else {
            self.lexer = lexer_save_state;
            return error.UnexpectedToken;
        };

        lexer_save_state = self.lexer;

        while (try self.lexer.next()) |token| {
            const leds = try self.syntax.findLeds(&token);

            if (leds.len == 0 or leds[0].binding_power > binding_power) {
                self.lexer = lexer_save_state;
                return lhs;
            }

            leds: for (leds) |led|{
                switch (led.invoke(.{self, lhs, led.binding_power, token, &out, &err})) {
                    .okay => { lhs = out; break :leds; },
                    .panic => return err,
                    .reject => continue :leds,
                }
            } else {
                self.lexer = lexer_save_state;
                return lhs;
            }

            lexer_save_state = self.lexer;
        }

        return lhs;
    }
};

/// Extern signal for parser callbacks.
pub const ParserSignal = enum(i8) {
    /// Continue parsing with the result of this pattern.
    okay = 0,
    /// Continue parsing with a different pattern, this one did not match.
    reject = 1,
    /// Stop parsing.
    panic = -1,
};



pub fn PatternSet(comptime T: type) type {
    return struct {
        const Self = @This();

        const Data = struct {
            tag: TokenType,
            data: ?TokenData,
            binding_power: i16,
            userdata: ?*anyopaque,
            callback: *const T,
        };

        pub const QueryResult = struct {
            binding_power: i16,
            userdata: ?*anyopaque,
            callback: *const T,

            pub fn invoke(
                self: *const QueryResult,
                args: anytype,
            ) ParserSignal {
                return @call(.auto, self.callback, .{self.userdata} ++ args);
            }
        };

        entries: std.MultiArrayList(Data) = .empty,
        query_cache: pl.ArrayList(QueryResult) = .empty,

        pub const empty = Self { .entries = .empty };

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.entries.deinit(allocator);
        }

        pub fn bindPattern(
            self: *Self, allocator: std.mem.Allocator,
            tag: TokenType, data: ?TokenData, binding_power: i16,
            userdata: ?*anyopaque, callback: *const T,
        ) error{OutOfMemory}!void {
            try self.entries.append(allocator, Data {
                .tag = tag,
                .data = data,
                .binding_power = binding_power,
                .userdata = userdata,
                .callback = callback,
            });
        }

        /// Find the patterns matching a given token, if any.
        pub fn findPatterns(
            self: *const PatternSet(T), allocator: std.mem.Allocator,
            token: *const Token,
        ) error{OutOfMemory}![]const QueryResult {
            const tags = self.entries.items(.tag);
            const data = self.entries.items(.data);
            const bps = self.entries.items(.binding_power);
            const userdata = self.entries.items(.userdata);
            const callbacks = self.entries.items(.callback);

            @constCast(self).query_cache.clearRetainingCapacity();

            for (tags, 0..) |tag, index| {
                if (tag != token.tag) continue;

                if (data[index]) |*key_data| {
                    switch (tag) {
                        .sequence => {
                            if (!std.mem.eql(u8, key_data.sequence.asSlice(), token.data.sequence.asSlice())) continue;
                        },
                        .linebreak => {
                            if (key_data.linebreak.n != token.data.linebreak.n
                            or  key_data.linebreak.i != token.data.linebreak.i) continue;
                        },
                        .special => {
                            if (key_data.special.punctuation != token.data.special.punctuation
                            or  key_data.special.escaped != token.data.special.escaped) continue;
                        },
                    }
                }

                try @constCast(self).query_cache.append(allocator, .{.binding_power = bps[index], .userdata = userdata[index], .callback = callbacks[index]});
            }

            std.mem.sort(
                QueryResult,
                self.query_cache.items,
                {},
                struct {
                    pub fn query_result_sort(_: void, a: QueryResult, b: QueryResult) bool {
                        return a.binding_power > b.binding_power;
                    }
                }.query_result_sort
            );

            return self.query_cache.items;
        }
    };
}


/// Defines the possible syntax accepted by a Parser.
pub const Syntax = struct {
    /// Allocator providing all Syntax memory.
    allocator: std.mem.Allocator,

    /// Nud patterns for known token types.
    nuds: PatternSet(Nud) = .empty,
    /// Led patterns for known token types.
    leds: PatternSet(Led) = .empty,

    /// Initialize a new, empty syntax.
    pub fn init(
        allocator: std.mem.Allocator,
    ) Syntax {
        return Syntax{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Syntax) void {
        self.nuds.deinit(self.allocator);
        self.leds.deinit(self.allocator);
    }

    pub fn bindNud(
        self: *Syntax,
        tag: TokenType,
        data: ?TokenData,
        binding_power: i16,
        comptime NudDef: type,
    ) error{OutOfMemory}!void {
        return self.nuds.bindPattern(
            self.allocator, tag, data, binding_power,
            if (comptime @hasDecl(NudDef, "userdata")) &@field(NudDef, "userdata")
            else null,
            struct {
                pub fn nud_callback_wrapper(
                    userdata: ?*anyopaque,
                    parser: *Parser,
                    bp: i16,
                    token: Token,
                    out: *Expr,
                    err: *SyntaxError,
                ) callconv(.c) ParserSignal {
                    const result =
                        if (comptime @hasDecl(NudDef, "userdata"))
                            @call(.auto, NudDef.callback, .{userdata} ++ .{parser, bp, token})
                        else
                            @call(.auto, NudDef.callback, .{parser, bp, token});

                    const maybe = result catch |e| {
                        err.* = e;
                        return .panic;
                    };

                    out.* = maybe orelse {
                        return .reject;
                    };

                    return .okay;
                }
            }.nud_callback_wrapper
        );
    }

    pub fn bindLed(
        self: *Syntax,
        tag: TokenType,
        data: ?TokenData,
        binding_power: i16,
        comptime LedDef: type,
    ) error{OutOfMemory}!void {
        return self.leds.bindPattern(
            self.allocator, tag, data, binding_power,
            if (comptime @hasDecl(LedDef, "userdata")) &@field(LedDef, "userdata")
            else null,
            struct {
                pub fn led_callback_wrapper(
                    userdata: ?*anyopaque,
                    parser: *Parser,
                    lhs: Expr,
                    bp: i16,
                    token: Token,
                    out: *Expr,
                    err: *SyntaxError,
                ) callconv(.c) ParserSignal {
                    const result =
                        if (comptime @hasDecl(LedDef, "userdata"))
                            @call(.auto, LedDef.callback, .{userdata} ++ .{parser, lhs, bp, token, out, err})
                        else
                            @call(.auto, LedDef.callback, .{parser, lhs, bp, token, out});

                    const maybe = result catch |e| {
                        err.* = e;
                        return .panic;
                    };

                    return maybe orelse {
                        return .reject;
                    };
                }
            }.led_callback_wrapper
        );
    }

    /// Find the nuds matching a given token, if any.
    pub fn findNuds(self: *const Syntax, token: *const Token) error{OutOfMemory}![]const PatternSet(Nud).QueryResult {
        return self.nuds.findPatterns(self.allocator, token);
    }

    /// Find the leds matching a given token, if any.
    pub fn findLeds(self: *const Syntax, token: *const Token) error{OutOfMemory}![]const PatternSet(Led).QueryResult {
        return self.leds.findPatterns(self.allocator, token);
    }
};

/// A nud is a function/closure that takes a parser and a token,
/// and parses some subset of the source code as a prefix expression.
pub const Nud = fn (userdata: ?*anyopaque, parser: *Parser, bp: i16, token: Token, out: *Expr, err: *SyntaxError) callconv(.C) ParserSignal;

/// A led is a function/closure that takes a parser and a token, as well as a left hand side expression,
/// and parses some subset of the source code as an infix or postfix expression.
pub const Led = fn (userdata: ?*anyopaque, parser: *Parser, lhs: Expr, bp: i16, token: Token, out: *Expr, err: *SyntaxError) callconv(.C) ParserSignal;

/// A concrete syntax tree node yielded by the meta language parser.
pub const Expr = extern struct {
    /// The source location where the expression began.
    location: Location,
    /// The type of the expression.
    type: common.Id.of(Expr),
    /// The token that generated this expression.
    token: Token,
    /// Subexpressions of this expression, if any.
    operands: common.Id.Buffer(Expr, .constant),
};

/// Builtin types of expressions.
pub var ExprTypes = gen: {
    var fresh = common.Id.of(Expr).fromInt(1);

    break :gen .{
        .Int = fresh.next(),
        .Identifier = fresh.next(),
        .IndentedBlock = fresh.next(),
        .fresh_id = fresh,
    };
};

test "parser_basic_integration" {

    const allocator = std.testing.allocator;

    var syntax = Syntax.init(allocator);
    defer syntax.deinit();

    try syntax.bindNud(.linebreak, null, std.math.minInt(i16), struct {
        pub fn callback(
            _: *Parser,
            _: i16,
            token: Token,
        ) SyntaxError!?Expr {
            return Expr{
                .location = token.location,
                .type = ExprTypes.IndentedBlock,
                .token = token,
                .operands = .empty,
            };
        }
    });

    try syntax.bindNud(.sequence, null, std.math.minInt(i16), struct {
        pub fn callback(
            _: *Parser,
            _: i16,
            token: Token,
        ) SyntaxError!?Expr {
            const s = token.data.sequence.asSlice();

            const first_char = utils.text.nthCodepoint(0, s) catch unreachable orelse unreachable;

            if (utils.text.isDecimal(first_char) and utils.text.isHexDigitStr(s)) {
                return Expr{
                    .location = token.location,
                    .type = ExprTypes.Int,
                    .token = token,
                    .operands = .empty,
                };
            } else if (utils.text.isAlphanumericStr(s)) {
                return Expr{
                    .location = token.location,
                    .type = ExprTypes.Identifier,
                    .token = token,
                    .operands = .empty,
                };
            } else {
                return null;
            }
        }
    });

    const parser = Parser.init(allocator, &syntax, try Lexer0.init(.{},
        \\test
        \\  [
        \\      1,
        \\      2,
        \\      3
        \\  ]
        \\
    ));
    _ = parser;


}
