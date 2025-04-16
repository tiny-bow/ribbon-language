//! # meta-language
//! The Ribbon Meta Language (Rml) is a compile-time meta-programming language targeting the ribbon virtual machine.
//!
//! While Ribbon does not have a `core.Value` sum type, Rml does have such a type,
//! and it is used to represent both source code and user data structures.
const meta_language = @This();

const std = @import("std");
const log = std.log.scoped(.Rml);

const pl = @import("platform");

test {
    std.testing.refAllDeclsRecursive(@This());
}

pub const BufferPosition = u64;

pub const VisualPosition = packed struct {
    line: u32 = 1,
    column: u32 = 1,
};

pub const Location = packed struct {
    buffer: BufferPosition = 0,
    visual: VisualPosition = .{},
    pub fn format(self: *const Location, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}:{} ({})", .{ self.visual.line, self.visual.column, self.buffer });
    }
};

pub const Token = struct {
    location: Location,
    data: TokenData,
};

pub const TokenData = union(enum) {
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
    /// a sequence of characters that do not fit the above categories,
    /// and contain no control characters or whitespace.
    sequence: []const u8,


    pub fn format(self: *const TokenData, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self.*) {
            .linebreak => |lb| {
                if (lb.i > 0) {
                    try writer.print("b⟨⇓{}⇒{}⟩", .{ lb.n, lb.i });
                } else if (lb.i < 0) {
                    try writer.print("b⟨⇓{}⇐{}⟩", .{ lb.n, -lb.i });
                } else {
                    try writer.print("b⟨⇓{}⟩", .{ lb.n });
                }
            },
            .special => |s| {
                if (s.escaped) {
                    try writer.print("p⟨\\{u}⟩", .{ s.punctuation.toChar() });
                } else {
                    try writer.print("p⟨{u}⟩", .{ s.punctuation.toChar() });
                }
            },
            .sequence => |seq| {
                try writer.print("s⟨{s}⟩", .{ seq });
            },
        }
    }
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

pub const Lexer = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    indentation: pl.ArrayList(u32),
    location: Location,
    lookahead: ?pl.Char,

    pub const Error = error {
        OutOfMemory,
        BadEncoding,
        UnexpectedEof,
        UnexpectedInput,
    };

    pub const Settings = struct {
        startingIndent: u32 = 0,
        attrOffset: VisualPosition = .{},
    };

    pub fn init(allocator: std.mem.Allocator, settings: Settings, source: []const u8) error{OutOfMemory}!Lexer {
        var indentation: pl.ArrayList(u32) = .empty;

        try indentation.append(allocator, settings.startingIndent);

        return Lexer{
            .allocator = allocator,
            .source = source,
            .indentation = indentation,
            .location = Location {
                .buffer = 0,
                .visual = settings.attrOffset,
            },
            .lookahead = null,
        };
    }

    pub fn deinit(self: *Lexer) void {
        self.indentation.deinit(self.allocator);
    }

    pub fn peekChar(self: *Lexer) Lexer.Error!?pl.Char {
        if (self.lookahead) |ch| {
            return ch;
        }

        if (self.location.buffer >= self.source.len) {
            return null;
        }

        const ch = self.source[self.location.buffer];

        const len = std.unicode.utf8ByteSequenceLength(ch) catch return error.BadEncoding;

        const out = std.unicode.utf8Decode(self.source[self.location.buffer..self.location.buffer + len]) catch return error.BadEncoding;

        self.lookahead = out;

        log.info("peekChar: {u} (0x{x:0>2})", .{ out, out });

        return out;
    }

    pub fn nextChar(self: *Lexer) Lexer.Error!?pl.Char {
        const ch = try self.peekChar() orelse return null;

        if (ch == '\n') {
            self.location.visual.line += 1;
            self.location.visual.column = 1;
        } else if (!std.ascii.isControl(@intCast(ch))) {
            self.location.visual.column += 1;
        }

        self.location.buffer += std.unicode.utf8CodepointSequenceLength(ch) catch unreachable;
        self.lookahead = null;

        return ch;
    }

    pub fn advanceChar(self: *Lexer) Lexer.Error!void {
        _ = try self.nextChar();
    }

    pub fn currentIndentation(self: *const Lexer) u32 {
        std.debug.assert(self.indentation.items.len > 0);
        return self.indentation.items[self.indentation.items.len - 1];
    }

    pub fn next(self: *Lexer) Lexer.Error!?Token {
        var start = self.location;

        const data = char_switch: switch (try self.nextChar() orelse return null) {
            '\n' => {
                log.info("processing line break", .{});

                var n: u32 = 0;

                line_loop: while(try self.peekChar()) |pk| {
                    if (pk == '\n') {
                        n += 1;
                    } else if (!std.ascii.isWhitespace(@intCast(pk))) { // FIXME: unicode identification
                        break :line_loop;
                    }

                    try self.advanceChar();
                } else {
                    log.info("stream ends with new line", .{});
                    break :char_switch TokenData { .linebreak = .{ .n = 1, .i = 0 } };
                }

                // we can compare the current column with the previous indentation level
                // to determine if we are increasing or decreasing indentation
                const currentIndent = self.currentIndentation();
                const newIndent = self.location.visual.column;

                const oldLen = self.indentation.items.len;
                std.debug.assert(oldLen > 0);

                if (newIndent > currentIndent) {
                    log.info("increasing indentation to {}", .{ newIndent });

                    try self.indentation.append(self.allocator, newIndent);

                    break :char_switch TokenData { .linebreak = .{ .n = n, .i = 1 } };
                } else if (newIndent < currentIndent) {
                    // we need to traverse back down the indentation stack until we find the right level
                    var newIndentIndex = self.indentation.items.len - 1;
                    while (true) {
                        const indent = self.indentation.items[newIndentIndex];

                        if (indent == newIndent) break;

                        if (indent < newIndent or newIndentIndex == 0) {
                            log.err("Unmatched indentation level {}", .{ indent });
                            return error.UnexpectedInput;
                        }

                        newIndentIndex -= 1;
                    }

                    log.info("decreasing indentation to {}", .{ newIndent });

                    self.indentation.shrinkRetainingCapacity(newIndentIndex + 1);

                    break :char_switch TokenData { .linebreak = .{ .n = n, .i = -@as(i32, @intCast(oldLen - self.indentation.items.len)) } };
                } else {
                    log.info("same indentation level {}", .{ newIndent });

                    break :char_switch TokenData { .linebreak = .{ .n = n, .i = 0 } };
                }
            },
            '\\' => {
                if (try self.peekChar()) |pk| {
                    if (Punctuation.castChar(pk)) |esc| {
                        try self.advanceChar();

                        log.info("escaped punctuation", .{});

                        break :char_switch TokenData { .special = .{ .punctuation = esc, .escaped = true } };
                    }
                }

                log.info("unescaped backslash character", .{});

                break :char_switch TokenData { .special = .{ .punctuation = .fromChar('\\'), .escaped = false } };
            },
            else => |x| {
                if (std.ascii.isWhitespace(@intCast(x))) {
                    log.info("skipping whitespace {u} (0x{x:0>2})", .{x, x});

                    start = self.location;

                    continue :char_switch try self.nextChar() orelse {
                        return null;
                    };
                }

                if (std.ascii.isControl(@intCast(x))) {
                    log.err("unexpected control character {u} (0x{x:0>2})", .{x, x});
                    return error.UnexpectedInput;
                }

                if (Punctuation.castChar(@intCast(x))) |p| {
                    log.info("punctuation {u} (0x{x:0>2})", .{p.toChar(), p.toChar()});
                    try self.advanceChar();

                    break :char_switch TokenData { .special = .{ .punctuation = p, .escaped = false } };
                }

                log.info("processing sequence", .{});

                symbol_loop: while (try self.peekChar()) |pk| {
                    if (std.ascii.isWhitespace(@intCast(pk))
                    or std.ascii.isControl(@intCast(pk))
                    or Punctuation.includesChar(@intCast(pk))) {
                        log.info("ending sequence at {u} (0x{x:0>2})", .{pk, pk});
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

                log.info("sequence {s}", .{seq});

                break :char_switch TokenData { .sequence = seq };
            }
        };

        return Token {
            .location = start,
            .data = data,
        };
    }
};
