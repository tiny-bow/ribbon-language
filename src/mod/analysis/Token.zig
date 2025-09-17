//! A token produced by lexical analysis.

const Token = @This();

const std = @import("std");
const common = @import("common");

const analysis = @import("../analysis.zig");
const Source = analysis.Source;

test {
    // std.debug.print("semantic analysis for Token\n", .{});
    std.testing.refAllDecls(@This());
}

/// The original location of the token in the source code.
location: Source.Location,
/// The type of token data contained in this token.
tag: Type,
/// The actual value of the token.
data: Data,

pub fn format(self: Token, writer: *std.io.Writer) !void {
    try writer.print("{f}:", .{self.location});
    switch (self.tag) {
        .sequence => try writer.print("s⟨{s}⟩", .{self.data.sequence.asSlice()}),
        .linebreak => try writer.print("b⟨⇓⟩", .{}),
        .indentation => try writer.print("i⟨{d}⟩", .{@intFromEnum(self.data.indentation)}),
        .special => if (self.data.special.escaped) {
            try writer.print("p⟨\\{u}⟩", .{self.data.special.punctuation.toChar()});
        } else {
            try writer.print("p⟨{u}⟩", .{self.data.special.punctuation.toChar()});
        },
    }
}

/// This is an enumeration of the types of tokens that can be produced by the lexer.
pub const Type = enum(u8) {
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
    pub fn toChar(self: IndentationDelta) common.Char {
        return switch (self) {
            .indent => '⌊',
            .unindent => '⌋',
        };
    }
};

/// This is a packed union of all the possible types of tokens that can be produced by the lexer.
pub const Data = packed union {
    /// a sequence of characters that do not fit the other categories,
    /// and contain no control characters or whitespace.
    sequence: common.Buffer.short(u8, .constant),
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
pub const Punctuation = enum(common.Char) {
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

    /// `std.fmt` impl
    pub fn format(self: Punctuation, writer: *std.io.Writer) error{WriteFailed}!void {
        try writer.print("{u}", .{self.toChar()});
    }

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
    pub fn toChar(self: Punctuation) common.Char {
        return @intFromEnum(self);
    }

    /// Given a character, returns the corresponding punctuation type.
    /// * This is only error checked in safe mode. See also `castChar`.
    pub fn fromChar(ch: common.Char) Punctuation {
        return @enumFromInt(ch);
    }

    /// Given a character, returns whether it has a punctuation type.
    pub fn includesChar(ch: common.Char) bool {
        inline for (comptime std.meta.fieldNames(Punctuation)) |p| {
            if (ch == comptime @intFromEnum(@field(Punctuation, p))) return true;
        }

        return false;
    }

    /// Given a character, returns the corresponding punctuation type.
    /// * This returns null if the character is not punctuation. See also `fromChar`.
    pub fn castChar(ch: common.Char) ?Punctuation {
        if (!includesChar(ch)) return null;

        return @enumFromInt(ch);
    }
};
