//! This module provides predicate and conversion functions,
//! to enable working with utf8 text and utf32 codepoints.

const std = @import("std");
const TextUtils = @import("Utils").Text;

const Rml = @import("../../root.zig");


/// given a char, gives a symbol representing the unicode general category
pub fn @"category"(char: Rml.Char) TextUtils.GeneralCategory {
    return TextUtils.generalCategory(char);
}

/// given a string or char, checks if all characters are control characters
pub fn @"control?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isControl, TextUtils.isControlStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are letter characters
pub fn @"letter?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isLetter, TextUtils.isLetterStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are mark characters
pub fn @"mark?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isMark, TextUtils.isMarkStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are number characters
pub fn @"number?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isNumber, TextUtils.isNumberStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are punctuation characters
pub fn @"punctuation?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isPunctuation, TextUtils.isPunctuationStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are separator characters
pub fn @"separator?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isSeparator, TextUtils.isSeparatorStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are symbol characters
pub fn @"symbol?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isSymbol, TextUtils.isSymbolStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are math characters
pub fn @"math?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isMath, TextUtils.isMathStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are alphabetic characters
pub fn @"alphabetic?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isAlphabetic, TextUtils.isAlphabeticStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are id-start characters char
pub fn @"id-start?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isIdStart, TextUtils.isIdStartStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are id-continue characters char
pub fn @"id-continue?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isIdContinue, TextUtils.isIdContinueStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are xid-start characters char
pub fn @"xid-start?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isXidStart, TextUtils.isXidStartStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are xid-continue characters char
pub fn @"xid-continue?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isXidContinue, TextUtils.isXidContinueStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are space characters
pub fn @"space?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isSpace, TextUtils.isSpaceStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are hexadecimal digit characters char
pub fn @"hex-digit?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isHexDigit, TextUtils.isHexDigitStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are diacritic characters
pub fn @"diacritic?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isDiacritic, TextUtils.isDiacriticStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are numeric characters
pub fn @"numeric?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isNumeric, TextUtils.isNumericStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are digit characters
pub fn @"digit?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isDigit, TextUtils.isDigitStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are decimal digit characters char
pub fn @"decimal?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isDecimal, TextUtils.isDecimalStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are hexadecimal digit characters char
pub fn @"hex?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isHexDigit, TextUtils.isHexDigitStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are lowercase
pub fn @"lowercase?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isLower, TextUtils.isLowerStr, interpreter, origin, args);
}

/// given a string or char, checks if all characters are uppercase
pub fn @"uppercase?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textPred(TextUtils.isUpper, TextUtils.isUpperStr, interpreter, origin, args);
}

/// given a string or char, returns a new copy with all of the characters converted to lowercase
pub fn @"lowercase"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textConv(TextUtils.toLower, interpreter, origin, args);
}

/// given a string or char, returns a new copy with all of the characters converted to uppercase
pub fn @"uppercase"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return textConv(TextUtils.toUpper, interpreter, origin, args);
}

/// given a string or a char, returns a new copy with all characters converted with unicode case folding; note that is may require converting chars to strings
pub fn @"casefold"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    return try textConv(TextUtils.caseFold, interpreter, origin, args);
}

/// given a string or a char, returns the number of bytes required to represent it as text/8
pub fn @"byte-count"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    var a: Rml.Int = 0;

    for (args) |arg| {
        if (Rml.castObj(Rml.String, arg)) |str| {
            a += @intCast(str.data.text().len);
        } else if (Rml.castObj(Rml.Char, arg)) |char| {
            a += @intCast(TextUtils.sequenceLength(char.data.*) catch {
                return try interpreter.abort(origin, error.TypeError,
                    "bad utf32 char", .{});
            });
        } else {
            return try interpreter.abort(origin, error.TypeError,
                "expected a String or a Char, got {}: `{}`", .{ arg.getTypeId(), arg });
        }
    }

    return (try Rml.Obj(Rml.Int).wrap(Rml.getRml(interpreter), origin, a)).typeErase();
}

/// given a string or a char, returns the width of the value in visual columns (approximate
pub fn @"display-width"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    var a: Rml.Int = 0;

    for (args) |arg| {
        if (Rml.castObj(Rml.String, arg)) |str| {
            a += @intCast(TextUtils.displayWidthStr(str.data.text()) catch 0);
        } else if (Rml.castObj(Rml.Char, arg)) |char| {
            a += @intCast(TextUtils.displayWidth(char.data.*));
        } else {
            return try interpreter.abort(origin, error.TypeError,
                "expected a String or a Char, got {}: `{}`", .{ arg.getTypeId(), arg });
        }
    }

    return (try Rml.Obj(Rml.Int).wrap(Rml.getRml(interpreter), origin, a)).typeErase();
}

/// compare two strings or chars using unicode case folding to ignore case
pub fn @"case-insensitive-eq?"(interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    var is = true;

    for (args) |arg| {
        if (Rml.castObj(Rml.String, arg)) |str1| {
            if (Rml.castObj(Rml.String, arg)) |str2| {
                is = TextUtils.caseInsensitiveCompareStr(str1.data.text(), str2.data.text()) catch true;
            } else {
                return try interpreter.abort(origin, error.TypeError,
                    "expected two Strings or Two chars, got {}: `{}`, and {}: `{}`", .{ arg.getTypeId(), arg, arg.getTypeId(), arg });
            }
        } else if (Rml.castObj(Rml.Char, arg)) |char1| {
            if (Rml.castObj(Rml.Char, arg)) |char2| {
                is = TextUtils.caseInsensitiveCompare(char1.data.*, char2.data.*);
            } else {
                return try interpreter.abort(origin, error.TypeError,
                    "expected two Strings or Two chars, got {}: `{}`, and {}: `{}`", .{ arg.getTypeId(), arg, arg.getTypeId(), arg });
            }
        } else {
            return try interpreter.abort(origin, error.TypeError,
                "expected two Strings or Two chars, got {}: `{}`, and {}: `{}`", .{ arg.getTypeId(), arg, arg.getTypeId(), arg });
        }

        if (!is) {
            break;
        }
    }

    return (try Rml.Obj(Rml.Bool).wrap(Rml.getRml(interpreter), origin, is)).typeErase();
}

fn appendConv (newStr: *Rml.String, conv: anytype) Rml.Result! void {
    const T = @TypeOf(conv);
    if (T == Rml.Char) {
        try newStr.append(conv);
    } else if (@typeInfo(T) == .pointer) {
        if (@typeInfo(T).pointer.child == Rml.Char) {
            for (conv) |ch| try newStr.append(ch);
        } else if (comptime @typeInfo(T).pointer.child == u8)  {
            try newStr.appendSlice(conv);
        } else {
            @compileError("unexpected type");
        }
    } else {
        @compileError("unexpected type");
    }
}

fn textConv(comptime charConv: anytype, interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    var compound = args.len != 1;
    var newStr = try Rml.String.create(Rml.getRml(interpreter), "");

    for (args) |arg| {
        if (Rml.castObj(Rml.String, arg)) |str| {
            compound = true;
            const text = str.data.text();
            var i: usize = 0;
            while (i < text.len) {
                const res = try TextUtils.decode1(text[i..]);
                i += res.len;
                const conv = charConv(res.ch);
                try appendConv(&newStr, conv);
            }
        } else if (Rml.castObj(Rml.Char, arg)) |char| {
            const conv = charConv(char.data.*);
            try appendConv(&newStr, conv);
        } else {
            return try interpreter.abort(origin, Rml.Error.TypeError,
                "expected a String or a Char, got {}: `{}`", .{ arg.getTypeId(), arg });
        }
    }

    if (!compound) {
        if (TextUtils.codepointCount(newStr.text()) catch 0 == 1) {
            return (try Rml.Obj(Rml.Char).wrap(Rml.getRml(interpreter), origin, TextUtils.nthCodepoint(0, newStr.text()) catch unreachable orelse unreachable)).typeErase();
        }
    }

    return (try Rml.Obj(Rml.String).wrap(Rml.getRml(interpreter), origin, newStr)).typeErase();
}

fn textPred(comptime chPred: fn (Rml.Char) bool, comptime strPred: fn ([]const u8) bool, interpreter: *Rml.Interpreter, origin: Rml.Origin, args: []const Rml.Object) Rml.Result! Rml.Object {
    var is = true;

    for (args) |arg| {
        const argIs = if (Rml.castObj(Rml.String, arg)) |str|
            strPred(str.data.text())
        else if (Rml.castObj(Rml.Char, arg)) |char|
            chPred(char.data.*)
        else {
            try interpreter.abort(origin, error.TypeError,
                "expected a String or a Char, got {}: `{}`", .{ arg.getTypeId(), arg });
        };

        if (!argIs) {
            is = false;
            break;
        }
    }

    return (try Rml.Obj(Rml.Bool).wrap(Rml.getRml(interpreter), origin, is)).typeErase();
}
