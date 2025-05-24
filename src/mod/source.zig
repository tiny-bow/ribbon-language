const source = @This();

const std = @import("std");
const log = std.log.scoped(.source_analysis);

const pl = @import("platform");
const common = @import("common");
const utils = @import("utils");
const Id = common.Id;

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

/// A `Location`, with a source name attached.
pub const Source = struct {
    name: []const u8 = "anonymous",
    location: Location = .{},

    pub fn format(self: *const Source, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("[{s}:{}:{}]", .{ self.name, self.location.visual.line, self.location.visual.column });
    }

    pub fn dupe(self: *const Source, allocator: std.mem.Allocator) !Source {
        return Source{
            .name = try allocator.dupe(u8, self.name),
            .location = self.location,
        };
    }
};

pub inline fn SourceBiMap(comptime T: type, comptime Ctx: type, comptime style: pl.MapStyle) type {
    comptime return pl.BiMap(Source, T, if (style == .array) SourceContext32 else SourceContext64, Ctx, style);
}

pub inline fn UniqueReprSourceBiMap(comptime T: type, comptime style: pl.MapStyle) type {
    comptime return SourceBiMap(T, if (style == .array) pl.UniqueReprHashContext32(T) else pl.UniqueReprHashContext64(T), style);
}

pub inline fn SourceMap(comptime T: type) type {
    comptime return std.HashMapUnmanaged(Source, T, SourceContext64, 80);
}

pub inline fn SourceArrayMap(comptime T: type) type {
    return std.ArrayHashMapUnmanaged(Source, T, SourceContext64, true);
}

pub const SourceContext32 = struct {
    pub fn hash(_: SourceContext32, src: Source) u32 {
        var hasher = std.hash.Fnv1a_32.init();

        hasher.update(src.name);
        hasher.update(std.mem.asBytes(&src.location));

        return hasher.final();
    }

    pub fn eql(_: SourceContext64, src: Source, other: Source, _: usize) bool {
        return std.mem.eql(u8, src.name, other.name) and src.location == other.location;
    }
};

pub const SourceContext64 = struct {
    pub fn hash(_: SourceContext64, src: Source) u64 {
        var hasher = std.hash.Fnv1a_64.init();

        hasher.update(src.name);
        hasher.update(std.mem.asBytes(&src.location));

        return hasher.final();
    }

    pub fn eql(_: SourceContext64, src: Source, other: Source) bool {
        return std.mem.eql(u8, src.name, other.name) and src.location == other.location;
    }
};

/// A location in the source code, both buffer-wise and line and column.
pub const Location = packed struct {
    buffer: BufferPosition = 0,
    visual: VisualPosition = .{},

    pub fn localize(local_to: *const Location, to_localize: *const Location) Location {
        std.debug.assert(local_to.buffer <= to_localize.buffer);
        return .{
            .buffer = to_localize.buffer - local_to.buffer,
            .visual = VisualPosition{
                .line = to_localize.visual.line -| local_to.visual.line,
                .column = to_localize.visual.column -| local_to.visual.column,
            },
        };
    }

    pub fn format(self: *const Location, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("[{}:{} ({})]", .{ self.visual.line, self.visual.column, self.buffer });
    }
};

/// An error that can occur while scanning utf-8 codepoints.
pub const EncodingError = error {
    /// The iterator encountered bytes that were not valid utf-8.
    BadEncoding,
};

/// Basic utf8 scanner.
pub const CodepointIterator = struct {
    /// Utf8 encoded bytes to scan.
    bytes: []const u8,
    /// Current position in the byte array.
    i: usize,

    pub const Error = EncodingError;

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


/// A token produced by the lexer.
pub const Token = extern struct {
    /// The original location of the token in the source code.
    location: Location,
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
    settings: LexerSettings,
    text: []const u8,
) LexicalError!Lexer0 {
    return try Lexer0.init(settings, text);
}

/// Settings for a lexer.
pub const LexerSettings = Lexer0.Settings;

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
} || EncodingError;

pub const Level = u16;
pub const MAX_LEVELS = 32;

/// Basic lexical analysis abstraction, no lookahead.
pub const Lexer0 = struct {
    /// Utf8 source code being lexically analyzed.
    source: []const u8,
    /// Iterator over `source`.
    iterator: common.PeekableIterator(CodepointIterator, pl.Char, .use_try(EncodingError)),
    /// The indentation levels at this point in the source code.
    indentation: [MAX_LEVELS]Level,
    /// The number of indentation levels currently in use.
    levels: u8 = 1,
    level_change_queue: [MAX_LEVELS]Level = [1]Level{0} ** MAX_LEVELS,
    levels_queued: i16 = 0,
    br_queued: bool = false,
    done: bool = false,
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

    /// Initialize a new lexer for a given
    pub fn init(settings: Settings, text: []const u8) error{BadEncoding}!Lexer0 {
        log.debug("Lexing string ⟨{s}⟩", .{text});

        return Lexer0 {
            .source = text,
            .iterator = try .from(.from(text)),
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
                                .data = TokenData{
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

/// Errors that can occur in the parser.
pub const SyntaxError = error {
    /// The parser encountered an unexpected token.
    UnexpectedToken,
} || LexicalError;

/// A concrete syntax tree node yielded by the meta language parser.
pub const SyntaxTree = struct {
    /// The source location where the expression began.
    source: Source,
    /// The source precedence of this expression.
    precedence: i16,
    /// The type of the expression.
    type: common.Id.of(SyntaxTree),
    /// The token that generated this expression.
    token: Token,
    /// Subexpressions of this expression, if any.
    operands: common.Id.Buffer(SyntaxTree, .constant),

    /// Deinitialize the sub-tree of this expression and free all memory allocated for it.
    pub fn deinit(self: *SyntaxTree, allocator: std.mem.Allocator) void {
        const xs = @constCast(self.operands.asSlice());
        for (xs) |*x| x.deinit(allocator);
        if (xs.len != 0) {
            // empty buffer != empty slice
            allocator.free(xs);
        }
    }

    /// `std.fmt` impl
    pub fn format(self: *const SyntaxTree, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.operands.len == 0) {
            try writer.print("﴾{}, {}﴿", .{@intFromEnum(self.type), self.token});
        } else {
            try writer.print("﴾{}, {}, {any}﴿", .{@intFromEnum(self.type), self.token, self.operands.asSlice()});
        }
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

pub fn PatternModifier(comptime P: type) type {
    return union(enum) {
        const Self = @This();

        none: void,
        any: void,
        standard: P,
        inverted: P,
        none_of: []const P,
        one_of: []const P,
        any_of: []const P,
        all_of: []const P,

        const Q = if (pl.hasDecl(P, .QueryType)) P.QueryType else P;

        pub fn format(self: *const Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            switch (self.*) {
                .none => try writer.print("none", .{}),
                .any => try writer.print("any", .{}),
                .standard => try writer.print("{}", .{self.standard}),
                .inverted => try writer.print("inv({})", .{self.inverted}),
                .none_of => try writer.print("none({any})", .{self.none_of}),
                .one_of => try writer.print("one({any})", .{self.one_of}),
                .any_of => try writer.print("any({any})", .{self.any_of}),
                .all_of => try writer.print("all({any})", .{self.all_of}),
            }
        }

        fn processCallback(self: *const Self, q: Q, comptime callback: fn (P, Q) bool) bool {
            // log.debug("processing {} with {}", .{q, self});
            switch (self.*) {
                .none => return false,
                .any => return true,
                .standard => |my_p| return callback(my_p, q),
                .inverted => |my_p| return !callback(my_p, q),
                .none_of => |my_ps| {
                    for (my_ps) |my_p| {
                        if (callback(my_p, q)) {
                            return false;
                        }
                    }

                    return true;
                },
                .one_of => |my_ps| {
                    for (my_ps) |my_p| {
                        if (callback(my_p, q)) {
                            return true;
                        }
                    }

                    return false;
                },
                .any_of => |my_ps| {
                    for (my_ps) |my_p| {
                        if (callback(my_p, q)) {
                            return true;
                        }
                    }

                    return false;
                },
                .all_of => |my_ps| {
                    for (my_ps) |my_p| {
                        if (!callback(my_p, q)) {
                            return false;
                        }
                    }

                    return true;
                },
            }
        }

        pub fn process(self: *const Self, q: Q) bool {
            const result = self.processCallback(q, switch (P) {
                common.Id.Buffer(u8, .constant) => struct {
                    pub fn callback(a: P, b: Q) bool {
                        return std.mem.eql(u8, a.asSlice(), b.asSlice());
                    }
                },
                TokenPattern => struct {
                    pub fn callback(a: P, b: Q) bool {
                        if (@as(TokenType, a) != b.tag) return false;

                        return switch (a) {
                            .sequence => |p| p.process(b.data.sequence),
                            .linebreak => true,
                            .indentation => |p| p.process(b.data.indentation),
                            .special => |p| p.process(b.data.special),
                        };
                    }
                },
                else => if (comptime std.meta.hasUniqueRepresentation(P)) struct {
                    pub fn callback(a: P, b: Q) bool {
                        return a == b;
                    }
                } else switch (@typeInfo(P)) {
                    .bool => struct { // TODO: why is this necessary? bool doesnt have unique representation??
                        pub fn callback(a: P, b: Q) bool {
                            return a == b;
                        }
                    },
                    .@"struct" => |info| struct {
                        pub fn callback(a: P, b: Q) bool {
                            inline for (info.fields) |field| {
                                if (!@field(a, field.name).process(@field(b, field.name))) return false;
                            }

                            return true;
                        }
                    },
                    else => @compileError("PatternModifier: unsupported type " ++ @typeName(P)),
                },
            }.callback);

            // log.debug("process result: {s}", .{if (result) "accept" else "reject"});

            return result;
        }
    };
}

pub const TokenPattern = union(TokenType) {
    pub const QueryType = *const Token;
    sequence: PatternModifier(common.Id.Buffer(u8, .constant)),
    linebreak: void,
    indentation: PatternModifier(IndentationDelta),
    special: PatternModifier(struct {
        const Self = @This();
        pub const QueryType = @FieldType(TokenData, "special");
        escaped: PatternModifier(bool),
        punctuation: PatternModifier(Punctuation),

        pub fn format(self: *const Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("{}, {}", .{self.escaped, self.punctuation});
        }
    }),

    pub fn format(self: *const TokenPattern, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self.*) {
            .sequence => try writer.print("s⟨{}⟩", .{self.sequence}),
            .linebreak => try writer.print("b⟨{}⟩", .{self.linebreak}),
            .indentation => try writer.print("i⟨{}⟩", .{self.indentation}),
            .special => try writer.print("p⟨{}⟩", .{self.special}),
        }
    }
};

fn FunctionType(comptime Args: type, comptime Ret: type, comptime calling_conv: std.builtin.CallingConvention) type {
    comptime {
        const args = std.meta.fields(Args);

        var params = [1]std.builtin.Type.Fn.Param{.{
            .type = undefined,
            .is_generic = false,
            .is_noalias = false,
        }} ** args.len;

        for (args, 0..) |arg, i| {
            params[i].type = arg.type;
        }

        return @Type(std.builtin.Type {
            .@"fn" = .{
                .calling_convention = calling_conv,
                .return_type = Ret,
                .is_generic = false,
                .is_var_args = false,
                .params = &params
            },
        });
    }
}

pub fn PatternSet(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const QueryResult = struct {
            name: []const u8,
            binding_power: i16,
            userdata: ?*anyopaque,
            callback: *const T,

            pub fn invoke(
                self: *const QueryResult,
                args: anytype,
            ) ParserSignal {
                const closure_args = .{self.userdata} ++ args;
                return @call(.auto, @as(*const FunctionType(@TypeOf(closure_args), ParserSignal, .C), @ptrCast(self.callback)), closure_args);
            }
        };

        entries: std.MultiArrayList(Pattern(T)) = .empty,
        query_cache: pl.ArrayList(QueryResult) = .empty,

        pub const empty = Self { .entries = .empty };

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.entries.deinit(allocator);
        }

        pub fn bindPattern(
            self: *Self, allocator: std.mem.Allocator,
            pattern: Pattern(T),
        ) error{OutOfMemory}!void {
            try self.entries.append(allocator, pattern);
        }

        /// Find the patterns matching a given token, if any.
        pub fn findPatterns(
            self: *const PatternSet(T), allocator: std.mem.Allocator,
            binding_power: i16,
            token: *const Token,
        ) error{OutOfMemory}![]const QueryResult {
            const patterns = self.entries.items(.token);
            const bps = self.entries.items(.binding_power);
            const userdata = self.entries.items(.userdata);
            const callbacks = self.entries.items(.callback);
            const names = self.entries.items(.name);

            @constCast(self).query_cache.clearRetainingCapacity();

            for (patterns, 0..) |*pattern, index| {
                if (bps[index] < binding_power) {
                    // log.debug("rejecting pattern {s} of lesser binding power ({}) than current ({})", .{names[index], bps[index], binding_power});
                    continue;
                }

                if (!pattern.process(token)) {
                    // log.debug("pattern {s} rejected token {}", .{names[index], token});
                    continue;
                }

                try @constCast(self).query_cache.append(allocator, .{.name = names[index], .binding_power = bps[index], .userdata = userdata[index], .callback = callbacks[index]});
            }

            std.mem.sort(
                QueryResult,
                self.query_cache.items,
                {},
                struct {
                    pub fn query_result_sort(_: void, a: QueryResult, b: QueryResult) bool {
                        return a.binding_power < b.binding_power;
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
    nuds: PatternSet(NudCallbackMarker) = .empty,
    /// Led patterns for known token types.
    leds: PatternSet(LedCallbackMarker) = .empty,

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
        nud: Nud,
    ) error{OutOfMemory}!void {
        return self.nuds.bindPattern(self.allocator, nud);
    }

    pub fn bindLed(
        self: *Syntax,
        led: Led,
    ) error{OutOfMemory}!void {
        return self.leds.bindPattern(self.allocator, led);
    }

    /// Find the nuds matching a given token, if any.
    pub fn findNuds(self: *const Syntax, bp: i16, token: *const Token) error{OutOfMemory}![]const PatternSet(NudCallbackMarker).QueryResult {
        return self.nuds.findPatterns(self.allocator, bp, token);
    }

    /// Find the leds matching a given token, if any.
    pub fn findLeds(self: *const Syntax, bp: i16, token: *const Token) error{OutOfMemory}![]const PatternSet(LedCallbackMarker).QueryResult {
        return self.leds.findPatterns(self.allocator, bp, token);
    }

    /// Parse a source string using this syntax.
    pub fn createParser(
        self: *const Syntax,
        allocator: std.mem.Allocator,
        lexer_settings: LexerSettings,
        src: []const u8,
        parser_settings: Parser.Settings,
    ) SyntaxError!Parser {
        const lexer = try lexWithPeek(lexer_settings, src);
        return Parser.init(allocator, self, lexer, parser_settings);
    }
};

const NudCallbackMarker = fn () callconv(.C) void;

const LedCallbackMarker = fn () callconv(.C) void;

pub fn Pattern(comptime T: type) type {
    return struct {
        /// The name to refer to this pattern by in debug messages.
        name: []const u8,
        /// The token pattern to match
        token: PatternModifier(TokenPattern),
        /// The binding power of this pattern.
        binding_power: i16,
        /// Optional user data to pass to the callback.
        userdata: ?*anyopaque,
        /// The callback to invoke when this pattern is matched.
        callback: *const T,
    };
}

/// A nud is a function/closure that takes a parser and a token,
/// and parses some subset of the source code as a prefix expression.
pub const Nud = Pattern(NudCallbackMarker);

/// A led is a function/closure that takes a parser and a token, as well as a left hand side expression,
/// and parses some subset of the source code as an infix or postfix expression.
pub const Led = Pattern(LedCallbackMarker);


/// Expected inputs:
/// * `..., null, fn (*Parser, i16, Token) SyntaxError!?Expr`
/// * `..., *T, fn (*T, *Parser, i16, Token) SyntaxError!?Expr`
/// * `..., _, *const fn ..`
pub fn createNud(name: []const u8, binding_power: i16, token: PatternModifier(TokenPattern), userdata: anytype, callback: anytype) Nud {
    const Userdata = comptime @TypeOf(userdata);
    const uInfo = comptime @typeInfo(Userdata);
    return Nud {
        .name = name,
        .token = token,
        .binding_power = binding_power,
        .userdata = if (comptime uInfo == .null) null else @ptrCast(userdata),
        .callback = wrapNudCallback(if (comptime uInfo == .null) void else Userdata, callback),
    };
}

/// Expected inputs:
/// * `..., null, fn (*Parser, Expr, i16, Token) SyntaxError!?Expr`
/// * `..., *T, fn (*T, *Parser, Expr, i16, Token) SyntaxError!?Expr`
/// * `..., _, *const fn ..`
pub fn createLed(name: []const u8, binding_power: i16, token: PatternModifier(TokenPattern), userdata: anytype, callback: anytype) Led {
    const Userdata = comptime @TypeOf(userdata);
    const uInfo = comptime @typeInfo(Userdata);
    return Led {
        .name = name,
        .token = token,
        .binding_power = binding_power,
        .userdata = if (comptime uInfo == .null) null else @ptrCast(userdata),
        .callback = wrapLedCallback(if (comptime uInfo == .null) void else Userdata, callback),
    };
}

/// Expected inputs:
/// * `void, fn (*Parser, i16, Token) SyntaxError!?Expr`
/// * `T, fn (*T, *Parser, i16, Token) SyntaxError!?Expr`
/// * `_, *const fn ..`
pub fn wrapNudCallback(comptime Userdata: type, callback: anytype) *const NudCallbackMarker {
    return @ptrCast(&struct {
        pub fn nud_callback_wrapper(
            userdata: ?*anyopaque,
            parser: *Parser,
            bp: i16,
            token: Token,
            out: *SyntaxTree,
            err: *SyntaxError,
        ) callconv(.c) ParserSignal {
            const result =
                if (comptime Userdata != void)
                    @call(.auto, callback, .{userdata} ++ .{parser, bp, token})
                else
                    @call(.auto, callback, .{parser, bp, token});

            const maybe = result catch |e| {
                err.* = e;
                return .panic;
            };

            out.* = maybe orelse {
                return .reject;
            };

            return .okay;
        }
    }.nud_callback_wrapper);
}

/// Expected inputs:
/// * `void, fn (*Parser, Expr, i16, Token) SyntaxError!?Expr`
/// * `T, fn (*T, *Parser, Expr, i16, Token) SyntaxError!?Expr`
/// * `_, *const fn ..`
pub fn wrapLedCallback(comptime Userdata: type, callback: anytype) *const LedCallbackMarker {
    return @ptrCast(&struct {
        pub fn led_callback_wrapper(
            userdata: ?*anyopaque,
            parser: *Parser,
            lhs: *SyntaxTree,
            bp: i16,
            token: Token,
            out: *SyntaxTree,
            err: *SyntaxError,
        ) callconv(.c) ParserSignal {
            const result =
                if (comptime Userdata != void)
                    @call(.auto, callback, .{userdata} ++ .{parser, lhs.*, bp, token})
                else
                    @call(.auto, callback, .{parser, lhs.*, bp, token});

            const maybe = result catch |e| {
                err.* = e;
                return .panic;
            };

            out.* = maybe orelse {
                return .reject;
            };

            return .okay;
        }
    }.led_callback_wrapper);
}

// TODO: it would be better if the parser was generic over both lexer and result types.
// this is not really fun to do in zig; probably after bootstrap.

/// Pratt parser.
pub const Parser = struct {
    /// The allocator to store parsed expressions in.
    allocator: std.mem.Allocator,
    /// The syntax used by this parser.
    syntax: *const Syntax,
    /// Token stream being parsed.
    lexer: Lexer1,
    /// Settings for this parser.
    settings: Settings,

    /// Alias for `SyntaxError`.
    pub const Error = SyntaxError;

    pub const Settings = struct {
        /// Whether to ignore whitespace tokens when parsing; Default: false.
        ignore_space: bool = false,
        /// The name of the source file being parsed.
        source_name: []const u8 = "anonymous",
    };

    /// Create a new parser.
    pub fn init(
        allocator: std.mem.Allocator,
        syntax: *const Syntax,
        lexer: Lexer1,
        settings: Settings,
    ) Parser {
        return Parser{
            .allocator = allocator,
            .syntax = syntax,
            .lexer = lexer,
            .settings = settings,
        };
    }

    pub fn isEof(self: *Parser) bool {
        return self.lexer.isEof();
    }

    pub fn parseNud(self: *Parser, binding_power: i16, token: Token) Error!?SyntaxTree {
        const nuds = try self.syntax.findNuds(binding_power, &token);

        log.debug("pratt: found {} nuds", .{nuds.len});

        if (nuds.len == 0) {
            log.debug("pratt: unexpected token {}, no valid nuds found", .{token});
            return null;
        }

        var out: SyntaxTree = undefined;
        var err: SyntaxError = undefined;
        const save_state = self.lexer;

        nuds: for (nuds) |nud| {
            switch (nud.invoke(.{self, nud.binding_power, token, &out, &err})) {
                .okay => {
                    log.debug("pratt: nud {s} accepted input", .{nud.name});
                    return out;
                },
                .panic => {
                    log.debug("pratt: nud {s} for {} panicked", .{nud.name, token});
                    return err;
                },
                .reject => {
                    log.debug("restoring saved state", .{});
                    self.lexer = save_state;
                    log.debug("pratt: nud {s} for {} rejected", .{nud.name, token});
                    continue :nuds;
                },
            }
        } else {
            log.debug("pratt: all nuds rejected token {}", .{token});
            return null;
        }
    }

    pub fn parseLed(self: *Parser, binding_power: i16, token: Token, lhs: SyntaxTree) Error!?SyntaxTree {
        const leds = try self.syntax.findLeds(binding_power, &token);

        log.debug("pratt: found {} leds", .{leds.len});

        if (leds.len == 0) {
            log.debug("pratt: unexpected token {}, no valid leds found", .{token});
            return null;
        }

        var out: SyntaxTree = undefined;
        var err: SyntaxError = undefined;

        const save_state = self.lexer;

        leds: for (leds) |led| {
            switch (led.invoke(.{self, &lhs, led.binding_power, token, &out, &err})) {
                .okay => {
                    log.debug("pratt: led {s} accepted input", .{led.name});
                    return out;
                },
                .panic => {
                    log.debug("pratt: led {s} for {} panicked", .{led.name, token});
                    return err;
                },
                .reject => {
                    log.debug("restoring saved state", .{});
                    self.lexer = save_state;
                    log.debug("pratt: led {s} for {} rejected", .{led.name, token});
                    continue :leds;
                },
            }
        } else {
            log.debug("pratt: all leds rejected token {}", .{token});
            return null;
        }
    }

    /// Run the pratt algorithm at the current offset in the lexer stream.
    pub fn pratt(
        self: *Parser,
        binding_power: i16,
    ) Error!?SyntaxTree {
        var save_state = self.lexer;
        const first_token = try self.lexer.peek() orelse return null;

        if (self.settings.ignore_space) {
            while (first_token.tag == .linebreak or first_token.tag == .indentation) {
                if (self.settings.ignore_space) {
                    log.debug("pratt: ignoring whitespace token {}", .{first_token});
                    try self.lexer.advance();
                    _ = try self.lexer.peek() orelse {
                        log.debug("pratt: input is all whitespace, returning null", .{});
                        return null;
                    };
                } else {
                    break;
                }
            }
        }

        log.debug("pratt: first token {}; bp: {}", .{first_token, binding_power});

        var lhs = lhs: while (try self.lexer.peek()) |nth_first_token| {
            const x = try self.parseNud(binding_power, nth_first_token) orelse {
                log.debug("restoring saved state", .{});
                self.lexer = save_state;
                log.debug("pratt: reached end of recognized input while consuming (possibly ignored) nud(s)", .{});
                return null;
            };

            if (x.type == .null) {
                log.debug("pratt: nud returned null, reiterating loop (assumes nud function advanced)", .{});
                std.debug.assert(x.operands.len == 0);

                continue :lhs;
            } else {
                break :lhs x;
            }
        } else {
            log.debug("restoring saved state", .{});
            self.lexer = save_state;
            log.debug("pratt: reached end of recognized input while consuming (possibly ignored) nud(s)", .{});
            return null;
        };
        errdefer lhs.deinit(self.allocator);

        save_state = self.lexer;

        while (try self.lexer.peek()) |x| {
            var curr_token = x;

            if (self.settings.ignore_space) {
                while (curr_token.tag == .linebreak or curr_token.tag == .indentation) {
                    if (self.settings.ignore_space) {
                        log.debug("pratt: ignoring whitespace token {}", .{curr_token});
                        try self.lexer.advance();
                        curr_token = try self.lexer.peek() orelse {
                            log.debug("pratt: remaining input is all whitespace, returning lhs", .{});
                            return lhs;
                        };
                    } else {
                        break;
                    }
                }
            }

            log.debug("pratt: infix token {}", .{curr_token});

            if (try self.parseLed(binding_power, curr_token, lhs)) |new_lhs| {
                log.debug("pratt: infix token {} accepted", .{curr_token});
                save_state = self.lexer;
                lhs = new_lhs;
            } else {
                log.debug("restoring saved state", .{});
                self.lexer = save_state;
                log.debug("pratt: token {} rejected as infix", .{curr_token});
                break;
            }
        } else {
            log.debug("pratt: end of input", .{});
        }

        log.debug("pratt: exit", .{});

        return lhs;
    }
};
