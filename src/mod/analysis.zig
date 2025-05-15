const std = @import("std");

pub const source = @import("analysis/source.zig");
pub const lexical = @import("analysis/lexical.zig");
pub const syntactic = @import("analysis/syntactic.zig");

test {
    std.testing.refAllDeclsRecursive(source);
    std.testing.refAllDeclsRecursive(lexical);
    std.testing.refAllDeclsRecursive(syntactic);
}

pub const BufferPosition = source.BufferPosition;
pub const Source = source.Source;
pub const Location = source.Location;
pub const VisualPosition = source.VisualPosition;
pub const CodepointIterator = source.CodepointIterator;
pub const EncodingError = source.EncodingError;

pub const Token = lexical.Token;
pub const TokenType = lexical.TokenType;
pub const TokenData = lexical.TokenData;
pub const SpecialPunctuation = lexical.Special;
pub const Punctuation = lexical.Punctuation;
pub const IndentationDelta = lexical.IndentationDelta;
pub const Lexer0 = lexical.Lexer0;
pub const Lexer1 = lexical.Lexer1;
pub const LexerSettings = lexical.Lexer0.Settings;
pub const LexicalError = lexical.LexicalError;

pub const SyntaxTree = syntactic.SyntaxTree;
pub const ParserSettings = syntactic.Parser.Settings;
pub const Syntax = syntactic.Syntax;
pub const Parser = syntactic.Parser;
pub const Nud = syntactic.Nud;
pub const Led = syntactic.Led;
pub const SyntaxError = syntactic.SyntaxError;
pub const lexNoPeek = lexical.lexNoPeek;
pub const lexWithPeek = lexical.lexWithPeek;
pub const createNud = syntactic.createNud;
pub const createLed = syntactic.createLed;
