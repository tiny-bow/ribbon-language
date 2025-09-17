const Lexer = @This();

const std = @import("std");
const log = std.log.scoped(.lexer);

const rg = @import("rg");
const common = @import("common");

const analysis = @import("../analysis.zig");
const Token = analysis.Token;
const Source = analysis.Source;

test {
    // std.debug.print("semantic analysis for Lexer\n", .{});
    std.testing.refAllDecls(@This());
}

/// An error that can occur while scanning utf-8 codepoints.
pub const EncodingError = error{
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

    pub fn nextSlice(it: *CodepointIterator) CodepointIterator.Error!?[]const u8 {
        if (it.i >= it.bytes.len) {
            return null;
        }

        const cp_len = std.unicode.utf8ByteSequenceLength(it.bytes[it.i]) catch return error.BadEncoding;
        it.i += cp_len;
        return it.bytes[it.i - cp_len .. it.i];
    }

    pub fn next(it: *CodepointIterator) CodepointIterator.Error!?u21 {
        const slice = try it.nextSlice() orelse return null;
        return std.unicode.utf8Decode(slice) catch return error.BadEncoding;
    }
};

/// Lexical analysis abstraction with one token lookahead.
pub const Peekable = common.PeekableIterator(Lexer, Token, .use_try(Error));

/// Create a new lexer for a given source, allowing single token lookahead.
pub fn lexWithPeek(
    settings: Settings,
    text: []const u8,
) Error!Peekable {
    return try Peekable.from(try Lexer.init(settings, text));
}

/// Create a new lexer for a given source, without lookahead.
pub fn lexNoPeek(
    settings: LexerSettings,
    text: []const u8,
) Error!Lexer {
    return try Lexer.init(settings, text);
}

/// Settings for a lexer.
pub const LexerSettings = Settings;

/// Errors that can occur in the lexer.
pub const Error = error{
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

/// Utf8 source code being lexically analyzed.
source: []const u8,
/// Iterator over `source`.
iterator: common.PeekableIterator(CodepointIterator, common.Char, .use_try(EncodingError)),
/// The indentation levels at this point in the source code.
indentation: [MAX_LEVELS]Level,
/// The number of indentation levels currently in use.
levels: u8 = 1,
level_change_queue: [MAX_LEVELS]Level = [1]Level{0} ** MAX_LEVELS,
levels_queued: i16 = 0,
br_queued: bool = false,
done: bool = false,
/// The current location in the source code.
location: Source.Location,

/// Lexical analysis settings.
pub const Settings = struct {
    /// If you are analyzing a subsection of a file that is itself indented,
    /// set this to the indentation level of the surrounding text.
    startingIndent: Level = 0,
    /// The offset to apply to the visual position (line and column) of the lexer,
    /// when creating token locations.
    attrOffset: Source.VisualPosition = .{},
};

/// Initialize a new lexer for a given
pub fn init(settings: Settings, text: []const u8) error{BadEncoding}!Lexer {
    log.debug("Lexing string ⟨{s}⟩", .{text});

    return Lexer{
        .source = text,
        .iterator = try .from(.from(text)),
        .indentation = [1]Level{settings.startingIndent} ++ ([1]Level{0} ** (MAX_LEVELS - 1)),
        .location = Source.Location{
            .visual = settings.attrOffset,
        },
    };
}

/// Determine whether the lexer has processed the last character in the source code.
pub fn isEof(self: *const Lexer) bool {
    return self.iterator.isEof();
}

/// Get the next character in the source code without consuming it.
/// * Returns null if the end of the source code is reached.
pub fn peekChar(self: *Lexer) Error!?common.Char {
    return self.iterator.peek();
}

/// Get the current character in the source code and consume it.
/// * Updates lexer source location
/// * Returns null if the end of the source code is reached.
pub fn nextChar(self: *Lexer) Error!?common.Char {
    const ch = try self.iterator.next() orelse return null;

    if (ch == '\n') {
        self.location.visual.line += 1;
        self.location.visual.column = 1;
    } else if (!rg.isControl(ch)) {
        self.location.visual.column += 1;
    }

    self.location.buffer += std.unicode.utf8CodepointSequenceLength(ch) catch unreachable;

    return ch;
}

/// Consume the current character in the source code.
/// * Updates lexer source location
/// * No-op if the end of the source code is reached.
pub fn advanceChar(self: *Lexer) Error!void {
    _ = try self.nextChar();
}

/// Get the current indentation level.
pub fn currentIndentation(self: *const Lexer) u32 {
    std.debug.assert(self.levels > 0);
    return self.indentation[self.levels - 1];
}

/// Get the next token from the lexer's source code.
pub fn next(self: *Lexer) Error!?Token {
    var start = self.location;

    var tag: Token.Type = undefined;

    if (self.levels_queued != 0) {
        log.debug("processing queued indentation level {d}", .{self.levels_queued});

        if (self.levels_queued > 0) {
            self.levels = self.levels + 1;
            self.levels_queued = self.levels_queued - 1;

            return Token{
                .location = start,
                .tag = .indentation,
                .data = Token.Data{ .indentation = .indent },
            };
        } else {
            self.levels = self.levels - 1;
            self.levels_queued = self.levels_queued + 1;
            self.br_queued = true;

            return Token{
                .location = start,
                .tag = .indentation,
                .data = Token.Data{ .indentation = .unindent },
            };
        }
    } else if (self.br_queued) {
        log.debug("processing queued line end", .{});

        self.br_queued = false;

        return Token{
            .location = start,
            .tag = .linebreak,
            .data = Token.Data{ .linebreak = {} },
        };
    }

    const ch = try self.nextChar() orelse {
        if (self.levels > 1) {
            log.debug("processing 1st ch EOF with {d} indentation levels", .{self.levels});
            self.levels_queued = self.levels - 2;
            self.levels -= 1;

            if (self.levels_queued == 0) self.br_queued = true;

            return Token{
                .location = start,
                .tag = .indentation,
                .data = Token.Data{ .indentation = .unindent },
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

            line_loop: while (try self.peekChar()) |pk| {
                if (pk == '\n') {
                    n += 1;
                } else if (!rg.isSpace(pk)) {
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
                log.debug("increasing indentation to {d} ({d})", .{ oldLen, newIndent });

                self.indentation[self.levels] = @intCast(newIndent); // TODO: check for overflow?
                self.levels += 1;

                tag = .indentation;
                break :char_switch Token.Data{ .indentation = .indent };
            } else if (newIndent < oldIndent) {
                // we need to traverse back down the indentation stack until we find the right level
                var newIndentIndex = self.levels - 1;
                while (true) {
                    const indent = self.indentation[newIndentIndex];
                    log.debug("checking vs indentation level {d} ({d})", .{ newIndentIndex, indent });

                    if (indent == newIndent) break;

                    if (indent < newIndent) {
                        log.err("unmatched indentation level {d}", .{newIndent});
                        return error.UnexpectedIndent;
                    }

                    newIndentIndex -= 1;
                }

                log.debug("decreasing indentation to {d} ({d})", .{ newIndentIndex, newIndent });

                const level_delta = oldLen - (newIndentIndex + 1);
                std.debug.assert(level_delta > 0);

                self.levels -= 1;
                self.levels_queued = -@as(i16, @intCast(level_delta - 1));
                if (self.levels_queued == 0) self.br_queued = true;

                tag = .indentation;
                break :char_switch Token.Data{ .indentation = .unindent };
            } else {
                log.debug("same indentation level {d} ({d})", .{ self.levels - 1, n });

                tag = .linebreak;
                break :char_switch Token.Data{ .linebreak = {} };
            }
        },
        '\\' => {
            tag = .special;
            if (try self.peekChar()) |pk| {
                if (Token.Punctuation.castChar(pk)) |esc| {
                    try self.advanceChar();

                    log.debug("escaped punctuation", .{});

                    break :char_switch Token.Data{ .special = .{ .punctuation = esc, .escaped = true } };
                }
            }

            log.debug("unescaped backslash character", .{});

            break :char_switch Token.Data{ .special = .{ .punctuation = .fromChar('\\'), .escaped = false } };
        },
        else => |x| {
            if (rg.isSpace(@intCast(x))) {
                log.debug("skipping whitespace {u} (0x{x:0>2})", .{ x, x });

                start = self.location;

                continue :char_switch try self.nextChar() orelse {
                    if (self.levels > 1) {
                        log.debug("processing nth ch EOF with {d} indentation levels", .{self.levels});

                        self.levels_queued = self.levels - 2;
                        self.levels -= 1;

                        if (self.levels_queued == 0) self.br_queued = true;

                        return Token{
                            .location = start,
                            .tag = .indentation,
                            .data = Token.Data{
                                .indentation = .unindent,
                            },
                        };
                    } else {
                        log.debug("processing nth ch EOF with no indentation levels", .{});

                        return null;
                    }
                };
            }

            if (rg.isControl(@intCast(x))) {
                log.err("unexpected control character {u} (0x{x:0>2})", .{ x, x });
                return error.UnexpectedInput;
            }

            if (Token.Punctuation.castChar(@intCast(x))) |p| {
                tag = .special;

                log.debug("punctuation {u} (0x{x:0>2})", .{ p.toChar(), p.toChar() });

                break :char_switch Token.Data{ .special = .{ .punctuation = p, .escaped = false } };
            }

            tag = .sequence;

            log.debug("processing sequence", .{});

            symbol_loop: while (try self.peekChar()) |pk| {
                if (rg.isSpace(@intCast(pk)) or rg.isControl(@intCast(pk)) or Token.Punctuation.includesChar(@intCast(pk))) {
                    log.debug("ending sequence at {u} (0x{x:0>2})", .{ pk, pk });
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

            break :char_switch Token.Data{ .sequence = .fromSlice(seq) };
        },
    };

    return Token{
        .location = start,
        .tag = tag,
        .data = data,
    };
}
