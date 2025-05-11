const analysis = @import("../analysis.zig");
const std = @import("std");
const log = std.log.scoped(.lexical_analysis);
const pl = @import("platform");
const common = @import("common");
const utils = @import("utils");


/// A token produced by the lexer.
pub const Token = extern struct {
    /// The original location of the token in the source code.
    location: analysis.Location,
    /// The type of token data contained in this token.
    tag: TokenType,
    /// The actual value of the token.
    data: TokenData,

    pub fn format(self: Token, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}:", .{self.location});
        switch (self.tag) {
            .sequence => try writer.print("s⟨{s}⟩", .{ self.data.sequence.asSlice() }),
            .linebreak => try writer.print("b⟨⇓⟩", .{}),
            .indentation => try writer.print("i⟨{}⟩", .{ @intFromEnum(self.data.indentation) }),
            .special => if (self.data.special.escaped) {
                try writer.print("p⟨\\{u}⟩", .{ self.data.special.punctuation.toChar() });
            } else {
                try writer.print("p⟨{u}⟩", .{ self.data.special.punctuation.toChar() });
            },
        }
    }
};

/// This is an enumeration of the types of tokens that can be produced by the lexer.
pub const TokenType = enum (u8) {
    /// A sequence of characters that do not fit the other categories,
    /// and contain no control characters or whitespace.
    sequence = 0,
    /// \n * `n`.
    linebreak = 1,
    /// A relative change in indentation level.
    indentation = 2,
    /// Special lexical control characters, such as `{`, `\"`, etc.
    special = 3,
};

/// A relative change in indentation level.
pub const IndentationDelta = enum(i8) {
    /// Indentation level decreased.
    unindent = -1,
    /// Indentation level increased.
    indent = 1,

    /// Inverts the indentation delta.
    pub fn invert(self: IndentationDelta) IndentationDelta {
        return switch (self) {
            .unindent => .indent,
            .indent => .unindent,
        };
    }

    /// Get a codepoint representing the indentation delta.
    pub fn toChar(self: IndentationDelta) pl.Char {
        return switch (self) {
            .indent => '⌊',
            .unindent => '⌋',
        };
    }
};

/// This is a packed union of all the possible types of tokens that can be produced by the lexer.
pub const TokenData = packed union {
    /// a sequence of characters that do not fit the other categories,
    /// and contain no control characters or whitespace.
    sequence: common.Id.Buffer(u8, .constant),
    /// \n
    linebreak: void,
    /// A relative change in indentation level.
    indentation: IndentationDelta,
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

    /// Inverts bracket-like punctuation, ie `(` to `)`.
    pub fn invert(self: Punctuation) ?Punctuation {
        return switch (self) {
            .paren_l => .paren_r,
            .paren_r => .paren_l,
            .brace_l => .brace_r,
            .brace_r => .brace_l,
            .bracket_l => .bracket_r,
            .bracket_r => .bracket_l,
            else => null,
        };
    }

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


/// Lexical analysis abstraction with one token lookahead.
pub const Lexer1 = common.PeekableIterator(Lexer0, Token, .use_try(LexicalError));

/// Create a new lexer for a given source, allowing single token lookahead.
pub fn lexWithPeek(
    settings: Lexer0.Settings,
    text: []const u8,
) LexicalError!Lexer1 {
    return try Lexer1.from(try Lexer0.init(settings, text));
}

/// Create a new lexer for a given source, without lookahead.
pub fn lexNoPeek(
    settings: Lexer0.Settings,
    text: []const u8,
) LexicalError!Lexer0 {
    return try Lexer0.init(settings, text);
}


/// Errors that can occur in the lexer.
pub const LexicalError = error {
    OutOfMemory,
    /// The lexer encountered the end of input while processing a compound token.
    UnexpectedEof,
    /// The lexer encountered a utf-valid but unexpected codepoint or combination thereof.
    UnexpectedInput,
    /// The lexer encountered an unexpected indentation level;
    /// * ie an indentation level that un-indents the current level,
    /// but does not match any existing level.
    UnexpectedIndent,
} || analysis.EncodingError;

pub const Level = u16;
pub const MAX_LEVELS = 32;

/// Basic lexical analysis abstraction, no lookahead.
pub const Lexer0 = struct {
    /// Utf8 source code being lexically analyzed.
    source: []const u8,
    /// Iterator over `source`.
    iterator: common.PeekableIterator(analysis.source.CodepointIterator, pl.Char, .use_try(analysis.EncodingError)),
    /// The indentation levels at this point in the source code.
    indentation: [MAX_LEVELS]Level,
    /// The number of indentation levels currently in use.
    levels: u8 = 1,
    level_change_queue: [MAX_LEVELS]Level = [1]Level{0} ** MAX_LEVELS,
    levels_queued: i16 = 0,
    br_queued: bool = false,
    done: bool = false,
    /// The current location in the source code.
    location: analysis.Location,

    /// Alias for `LexicalError`.
    pub const Error = LexicalError;

    /// Lexical analysis settings.
    pub const Settings = struct {
        /// If you are analyzing a subsection of a file that is itself indented,
        /// set this to the indentation level of the surrounding text.
        startingIndent: Level = 0,
        /// The offset to apply to the visual position (line and column) of the lexer,
        /// when creating token locations.
        attrOffset: analysis.VisualPosition = .{},
    };

    /// Initialize a new lexer for a given source.
    pub fn init(settings: Settings, text: []const u8) error{BadEncoding}!Lexer0 {
        log.debug("Lexing string ⟨{s}⟩", .{text});

        return Lexer0 {
            .source = text,
            .iterator = try .from(.from(text)),
            .indentation = [1]Level{settings.startingIndent} ++ ([1]Level{0} ** (MAX_LEVELS - 1)),
            .location = analysis.Location {
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

        if (self.levels_queued != 0) {
            log.debug("processing queued indentation level {}", .{self.levels_queued});

            if (self.levels_queued > 0) {
                self.levels = self.levels + 1;
                self.levels_queued = self.levels_queued - 1;

                return Token{
                    .location = start,
                    .tag = .indentation,
                    .data = TokenData{ .indentation = .indent },
                };
            } else {
                self.levels = self.levels - 1;
                self.levels_queued = self.levels_queued + 1;
                self.br_queued = true;

                return Token{
                    .location = start,
                    .tag = .indentation,
                    .data = TokenData{ .indentation = .unindent },
                };
            }
        } else if (self.br_queued) {
            log.debug("processing queued line end", .{});

            self.br_queued = false;

            return Token{
                .location = start,
                .tag = .linebreak,
                .data = TokenData{ .linebreak = {} },
            };
        }

        const ch = try self.nextChar() orelse {
            if (self.levels > 1) {
                log.debug("processing 1st ch EOF with {} indentation levels", .{self.levels});
                self.levels_queued = self.levels - 2;
                self.levels -= 1;

                if (self.levels_queued == 0) self.br_queued = true;

                return Token{
                    .location = start,
                    .tag = .indentation,
                    .data = TokenData{ .indentation = .unindent },
                };
            } else {
                log.debug("EOF with no extraneous indentation levels", .{});
                return null;
            }
        };

        const data = char_switch: switch (ch) {
            '\n' => {
                log.debug("processing line break", .{});

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

                    tag = .indentation;
                    break :char_switch TokenData { .indentation = .indent };
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

                    const level_delta = oldLen - (newIndentIndex + 1);
                    std.debug.assert(level_delta > 0);

                    self.levels -= 1;
                    self.levels_queued = -@as(i16, @intCast(level_delta - 1));
                    if (self.levels_queued == 0) self.br_queued = true;

                    tag = .indentation;
                    break :char_switch TokenData { .indentation = .unindent };
                } else {
                    log.debug("same indentation level {} ({})", .{ self.levels - 1, n });

                    tag = .linebreak;
                    break :char_switch TokenData { .linebreak = {} };
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
                        if (self.levels > 1) {
                            log.debug("processing nth ch EOF with {} indentation levels", .{self.levels});

                            self.levels_queued = self.levels - 2;
                            self.levels -= 1;

                            if (self.levels_queued == 0) self.br_queued = true;

                            return Token{
                                .location = start,
                                .tag = .indentation,
                                .data = analysis.TokenData{
                                    .indentation = .unindent,
                                },
                            };
                        } else {
                            log.debug("processing nth ch EOF with no indentation levels", .{});

                            return null;
                        }
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
