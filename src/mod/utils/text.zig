const utils = @import("../utils.zig");

const text = @This();

const std = @import("std");
const GenCatData = @import("zg/GenCatData");
const PropsData = @import("zg/PropsData");
const CaseData = @import("zg/CaseData");
const CaseFold = @import("zg/CaseFold");
const DisplayWidth = @import("zg/DisplayWidth");

pub const Char = u21;

pub var ALLOCATOR = std.heap.page_allocator;

pub const Error = error{BadEncoding};

pub fn isTextError(err: anyerror) bool {
    return err == Error.BadEncoding;
}

const Data = struct {
    genCat: GenCatData,
    props: PropsData,
    case: CaseData,
    caseFold: CaseFold.FoldData,
    displayWidth: DisplayWidth.DisplayWidthData,

    const Self = @This();

    pub fn init(al: std.mem.Allocator) !Self {
        return Self{
            .genCat = try GenCatData.init(al),
            .props = try PropsData.init(al),
            .case = try CaseData.init(al),
            .caseFold = try CaseFold.FoldData.init(al),
            .displayWidth = try DisplayWidth.DisplayWidthData.init(al),
        };
    }

    pub fn deinit(self: *Self) void {
        self.genCat.deinit();
        self.props.deinit();
        self.case.deinit();
        self.caseFold.deinit();
        self.displayWidth.deinit();
    }
};

threadlocal var DATA: ?*Data = null;

fn getDataImpl() !*Data {
    if (DATA) |data| {
        return data;
    } else {
        var data = try Data.init(ALLOCATOR);
        errdefer data.deinit();

        const ptr: *Data = @ptrCast((try ALLOCATOR.alloc(Data, 1)).ptr);
        ptr.* = data;

        DATA = ptr;

        return ptr;
    }
}

fn getData() *Data {
    return getDataImpl() catch unreachable;
}

pub const GeneralCategory = GenCatData.Gc;

pub fn generalCategory(c: Char) GeneralCategory {
    return getData().genCat.gc(c);
}

pub fn generalCategoryFromName(name: []const u8) ?GeneralCategory {
    inline for (comptime std.meta.fieldNames(GeneralCategory)) |field| {
        if (std.mem.eql(u8, field, name)) return @field(GeneralCategory, field);
    }
    return null;
}

pub fn describeGeneralCategory(cat: GeneralCategory) []const u8 {
    return switch (cat) {
        .Cc => "Other, Control",
        .Cf => "Other, Format",
        .Cn => "Other, Unassigned",
        .Co => "Other, Private Use",
        .Cs => "Other, Surrogate",
        .Ll => "Letter, Lowercase",
        .Lm => "Letter, Modifier",
        .Lo => "Letter, Other",
        .Lu => "Letter, Uppercase",
        .Lt => "Letter, Titlecase",
        .Mc => "Mark, Spacing Combining",
        .Me => "Mark, Enclosing",
        .Mn => "Mark, Non-Spacing",
        .Nd => "Number, Decimal Digit",
        .Nl => "Number, Letter",
        .No => "Number, Other",
        .Pc => "Punctuation, Connector",
        .Pd => "Punctuation, Dash",
        .Pe => "Punctuation, Close",
        .Pf => "Punctuation, Final quote (may behave like Ps or Pe depending on usage)",
        .Pi => "Punctuation, Initial quote (may behave like Ps or Pe depending on usage)",
        .Po => "Punctuation, Other",
        .Ps => "Punctuation, Open",
        .Sc => "Symbol, Currency",
        .Sk => "Symbol, Modifier",
        .Sm => "Symbol, Math",
        .So => "Symbol, Other",
        .Zl => "Separator, Line",
        .Zp => "Separator, Paragraph",
        .Zs => "Separator, Space",
    };
}

inline fn strPredicate(str: []const u8, comptime f: fn (c: Char) bool) bool {
    var i: usize = 0;
    while (i < str.len) {
        const dec = decode1(str[i..]) catch return false;
        if (!@call(.always_inline, f, .{dec.ch})) return false;
        i += dec.len;
    }
    return true;
}

pub fn isControl(c: Char) bool {
    return getData().genCat.isControl(c);
}
pub fn isLetter(c: Char) bool {
    return getData().genCat.isLetter(c);
}
pub fn isMark(c: Char) bool {
    return getData().genCat.isMark(c);
}
pub fn isNumber(c: Char) bool {
    return getData().genCat.isNumber(c);
}
pub fn isPunctuation(c: Char) bool {
    return getData().genCat.isPunctuation(c);
}
pub fn isSeparator(c: Char) bool {
    return getData().genCat.isSeparator(c);
}
pub fn isSymbol(c: Char) bool {
    return getData().genCat.isSymbol(c);
}

pub fn isControlStr(str: []const u8) bool {
    return strPredicate(str, isControl);
}
pub fn isLetterStr(str: []const u8) bool {
    return strPredicate(str, isLetter);
}
pub fn isMarkStr(str: []const u8) bool {
    return strPredicate(str, isMark);
}
pub fn isNumberStr(str: []const u8) bool {
    return strPredicate(str, isNumber);
}
pub fn isPunctuationStr(str: []const u8) bool {
    return strPredicate(str, isPunctuation);
}
pub fn isSeparatorStr(str: []const u8) bool {
    return strPredicate(str, isSeparator);
}
pub fn isSymbolStr(str: []const u8) bool {
    return strPredicate(str, isSymbol);
}

pub fn isMath(c: Char) bool {
    return getData().props.isMath(c);
}
pub fn isAlphabetic(c: Char) bool {
    return getData().props.isAlphabetic(c);
}
pub fn isIdStart(c: Char) bool {
    return getData().props.isIdStart(c);
}
pub fn isIdContinue(c: Char) bool {
    return getData().props.isIdContinue(c);
}
pub fn isXidStart(c: Char) bool {
    return getData().props.isXidStart(c);
}
pub fn isXidContinue(c: Char) bool {
    return getData().props.isXidContinue(c);
}
pub fn isSpace(c: Char) bool {
    return getData().props.isWhitespace(c);
}
pub fn isHexDigit(c: Char) bool {
    return getData().props.isHexDigit(c);
}
pub fn isDiacritic(c: Char) bool {
    return getData().props.isDiacritic(c);
}
pub fn isNumeric(c: Char) bool {
    return getData().props.isNumeric(c);
}
pub fn isDigit(c: Char) bool {
    return getData().props.isDigit(c);
}
pub fn isDecimal(c: Char) bool {
    return getData().props.isDecimal(c);
}

pub fn isMathStr(str: []const u8) bool {
    return strPredicate(str, isMath);
}
pub fn isAlphabeticStr(str: []const u8) bool {
    return strPredicate(str, isAlphabetic);
}
pub fn isIdStartStr(str: []const u8) bool {
    return strPredicate(str, isIdStart);
}
pub fn isIdContinueStr(str: []const u8) bool {
    return strPredicate(str, isIdContinue);
}
pub fn isXidStartStr(str: []const u8) bool {
    return strPredicate(str, isXidStart);
}
pub fn isXidContinueStr(str: []const u8) bool {
    return strPredicate(str, isXidContinue);
}
pub fn isSpaceStr(str: []const u8) bool {
    return strPredicate(str, isSpace);
}
pub fn isHexDigitStr(str: []const u8) bool {
    return strPredicate(str, isHexDigit);
}
pub fn isDiacriticStr(str: []const u8) bool {
    return strPredicate(str, isDiacritic);
}
pub fn isNumericStr(str: []const u8) bool {
    return strPredicate(str, isNumeric);
}
pub fn isDigitStr(str: []const u8) bool {
    return strPredicate(str, isDigit);
}
pub fn isDecimalStr(str: []const u8) bool {
    return strPredicate(str, isDecimal);
}

pub fn isCased(c: Char) bool {
    return getData().case.isCased(c);
}

pub fn isCasedStr(str: []const u8) bool {
    var is = false;
    var i: usize = 0;
    while (i < str.len) {
        const dec = decode1(str[i..]) catch return false;
        is = is or isCased(dec.ch);
        i += dec.len;
    }
    return true;
}

pub fn isUpper(c: Char) bool {
    return getData().case.isUpper(c);
}
pub fn isLower(c: Char) bool {
    return getData().case.isLower(c);
}

pub fn toUpper(c: Char) Char {
    return getData().case.toUpper(c);
}
pub fn toLower(c: Char) Char {
    return getData().case.toLower(c);
}

pub fn isUpperStr(str: []const u8) bool {
    return getData().case.isUpperStr(str);
}
pub fn isLowerStr(str: []const u8) bool {
    return getData().case.isLowerStr(str);
}

pub fn toLowerStr(allocator: std.mem.Allocator, str: []const u8) ![]u8 {
    return getData().case.toLowerStr(allocator, str);
}
pub fn toUpperStr(allocator: std.mem.Allocator, str: []const u8) ![]u8 {
    return getData().case.toUpperStr(allocator, str);
}

pub fn caseFold(c: Char) []const Char {
    return getData().caseFold.caseFold(c);
}
pub fn caseFoldStr(allocator: std.mem.Allocator, str: []const u8) ![]u8 {
    var mem = std.ArrayList(u8).init(allocator);
    var i: usize = 0;
    var buf = [1]u8{0} ** 4;
    var def = [1]Char{0};
    while (i < str.len) {
        const dec = try decode1(str[i..]);
        const chars = chars: {
            const folded = caseFold(dec.ch);
            if (folded.len != 0) {
                break :chars folded;
            } else {
                def[0] = dec.ch;
                break :chars &def;
            }
        };
        for (chars) |ch| {
            const byteLen = try encode(ch, &buf);
            try mem.appendSlice(buf[0..byteLen]);
        }
        i += dec.len;
    }
    return try mem.toOwnedSlice();
}
pub fn changesWhenCaseFolded(c: Char) bool {
    return getData().caseFold.changesWhenCaseFolded(c);
}

pub fn displayWidth(c: Char) i3 {
    return getData().displayWidth.codePointWidth(c);
}
pub fn displayWidthStr(str: []const u8) !i64 {
    var w: i64 = 0;
    var i: usize = 0;
    while (i < str.len) {
        const dec = try decode1(str[i..]);
        const cw = displayWidth(dec.ch);
        w += cw;
        i += dec.len;
    }
    return w;
}

pub fn isValid(c: Char) bool {
    return std.unicode.utf8ValidCodepoint(c);
}
pub fn isValidStr(str: []const u8) bool {
    return std.unicode.utf8ValidateSlice(str);
}

pub fn sequenceLength(c: Char) Error!u3 {
    return std.unicode.utf8CodepointSequenceLength(c) catch return Error.BadEncoding;
}
pub fn sequenceLengthByte(b: u8) Error!u3 {
    return std.unicode.utf8ByteSequenceLength(b) catch return Error.BadEncoding;
}
pub fn codepointCount(str: []const u8) Error!usize {
    return std.unicode.utf8CountCodepoints(str) catch return Error.BadEncoding;
}

pub fn nthCodepoint(n: usize, str: []const u8) Error!?Char {
    var i: usize = 0;
    var j: usize = 0;

    while (i < str.len) {
        if (j == n) return (try decode1(str[i..])).ch;
        const len = try sequenceLengthByte(str[i]);
        i += len;
        j += 1;
    }

    return null;
}
pub fn nthCodepointOffset(n: usize, str: []const u8) Error!?usize {
    var i: usize = 0;
    var j: usize = 0;
    if (j == n) return i;

    while (i < str.len) {
        const len = try sequenceLengthByte(str[i]);
        i += len;
        j += 1;
        if (j == n) return i;
    }

    return null;
}

pub fn decode(str: []const u8) Error!Char {
    return std.unicode.utf8Decode(str) catch return Error.BadEncoding;
}
pub fn decode1(str: []const u8) Error!struct { ch: Char, len: u3 } {
    const len = try sequenceLengthByte(str[0]);
    const ch = try decode(str[0..len]);
    return .{ .ch = ch, .len = len };
}
pub fn encode(c: Char, out: []u8) Error!u3 {
    return std.unicode.utf8Encode(c, out) catch return Error.BadEncoding;
}

pub fn caseInsensitiveCompare(a: Char, b: Char) bool {
    if (a == b) return true;

    const defaultA = [1]Char{a};
    const defaultB = [1]Char{b};
    const foldedA = caseFold(a);
    const foldedB = caseFold(b);
    const aBuf = if (foldedA.len != 0) foldedA else &defaultA;
    const bBuf = if (foldedB.len != 0) foldedB else &defaultB;

    return std.mem.eql(Char, aBuf, bBuf);
}

pub fn caseInsensitiveCompareStr(a: []const u8, b: []const u8) !bool {
    var i: usize = 0;
    var j: usize = 0;

    while (true) {
        if (i == a.len) return j == b.len;
        if (j == b.len) return false;

        const ai = try decode1(a[i..]);
        const bi = try decode1(b[j..]);

        if (!caseInsensitiveCompare(ai.ch, bi.ch)) {
            return false;
        }

        i += ai.len;
        j += bi.len;
    }
}

pub fn decimalValue(c: Char) ?u4 {
    switch (c) {
        '0' => return 0,
        '1' => return 1,
        '2' => return 2,
        '3' => return 3,
        '4' => return 4,
        '5' => return 5,
        '6' => return 6,
        '7' => return 7,
        '8' => return 8,
        '9' => return 9,
        else => return null,
    }
}

pub fn numDigits(i: anytype, base: @TypeOf(i)) usize {
    var a: @TypeOf(i) = i;
    var count: usize = 0;
    while (true) {
        count += 1;
        a = @divFloor(a, base);
        if (a == 0) break;
    }
    return count;
}

pub fn offsetToCodepointIndex(str: []const u8, offset: usize) Error!usize {
    var i: usize = 0;
    var j: usize = 0;
    while (i < str.len) {
        if (i == offset) return j;
        const len = try sequenceLengthByte(str[i]);
        i += len;
        j += 1;
        if (i > offset) return Error.BadEncoding;
    }
    return Error.BadEncoding;
}

pub fn findStr(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return null;
    if (needle.len > haystack.len) return null;

    var i: usize = 0;
    while (i < haystack.len) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return i;
        i += 1;
    }

    return null;
}

pub fn findStrCodepointIndex(haystack: []const u8, needle: []const u8) Error!?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return Error.BadEncoding;

    var i: usize = 0;
    var j: usize = 0;
    while (i < haystack.len) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return j;
        const len = try sequenceLengthByte(haystack[i]);
        i += len;
        j += 1;
    }

    return null;
}

pub fn findInCStr(haystack: [*:0]const u8, needle: []const u8) ?usize {
    var i: usize = 0;
    while (true) {
        if (haystack[i] == 0) return null;
        var eq = true;
        for (0..needle.len) |j| {
            if (haystack[i + j] != needle[j]) {
                eq = false;
                break;
            }
        }
        if (eq) return i;
        i += 1;
    }
    return null;
}

pub fn cStrLen(str: [*:0]const u8) usize {
    var i: usize = 0;
    while (str[i] != 0) i += 1;
    return i;
}

pub fn indentStr(str: *std.ArrayList(u8), indent: []const u8) !void {
    var i: usize = indent.len;

    try str.insertSlice(0, indent);

    while (i < str.items.len) {
        const dec = try decode1(str.items[i..]);

        i += dec.len;

        if (i == str.items.len) break;

        if (dec.ch == '\n') {
            try str.insertSlice(i, indent);
            i += indent.len;
        }
    }
}

const Escape = struct { text: []const u8, len: u3 };
const escapeTable = [32]Escape{
    .{ .text = "\\0", .len = 2 },
    .{ .text = "\\x01", .len = 4 },
    .{ .text = "\\x02", .len = 4 },
    .{ .text = "\\x03", .len = 4 },
    .{ .text = "\\x04", .len = 4 },
    .{ .text = "\\x05", .len = 4 },
    .{ .text = "\\x06", .len = 4 },
    .{ .text = "\\a", .len = 2 },
    .{ .text = "\\b", .len = 2 },
    .{ .text = "\\t", .len = 2 },
    .{ .text = "\\n", .len = 2 },
    .{ .text = "\\v", .len = 2 },
    .{ .text = "\\f", .len = 2 },
    .{ .text = "\\r", .len = 2 },
    .{ .text = "\\x0E", .len = 4 },
    .{ .text = "\\x0F", .len = 4 },
    .{ .text = "\\x10", .len = 4 },
    .{ .text = "\\x11", .len = 4 },
    .{ .text = "\\x12", .len = 4 },
    .{ .text = "\\x13", .len = 4 },
    .{ .text = "\\x14", .len = 4 },
    .{ .text = "\\x15", .len = 4 },
    .{ .text = "\\x16", .len = 4 },
    .{ .text = "\\x17", .len = 4 },
    .{ .text = "\\x18", .len = 4 },
    .{ .text = "\\x19", .len = 4 },
    .{ .text = "\\x1A", .len = 4 },
    .{ .text = "\\esc", .len = 4 },
    .{ .text = "\\x1C", .len = 4 },
    .{ .text = "\\x1D", .len = 4 },
    .{ .text = "\\x1E", .len = 4 },
    .{ .text = "\\x1F", .len = 4 },
};

pub const QuoteMode = enum {
    None,
    Single,
    Double,
    Both,
};

pub const EscapeFormatter = struct {
    buf: []const u8,

    pub fn init(buf: []const u8) EscapeFormatter {
        return .{ .buf = buf };
    }

    pub fn format(self: *const EscapeFormatter, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        var i: usize = 0;
        while (i < self.buf.len) {
            const dec = try decode1(self.buf[i..]);

            var escBuf = [1]u8{0} ** 4;
            const escBytes = try escape(dec.ch, .Double, &escBuf);

            try writer.print("{s}", .{escBytes});

            i += dec.len;
        }
    }
};

pub fn escapeStr(allocator: std.mem.Allocator, str: []const u8, quoteMode: QuoteMode) ![]u8 {
    var mem = std.ArrayList(u8).init(allocator);
    var i: usize = 0;
    var buf = [1]u8{0} ** 4;
    while (i < str.len) {
        const dec = try decode1(str[i..]);
        const escBytes = try escape(dec.ch, quoteMode, &buf);
        try mem.appendSlice(escBytes);
        i += dec.len;
    }
    return try mem.toOwnedSlice();
}

pub fn escapeStrWrite(writer: std.io.AnyWriter, str: []const u8, quoteMode: QuoteMode) !void {
    var i: usize = 0;
    var buf = [1]u8{0} ** 4;
    while (i < str.len) {
        const dec = try decode1(str[i..]);
        const escBytes = try escape(dec.ch, quoteMode, &buf);
        try writer.writeAll(escBytes);
        i += dec.len;
    }
}

pub fn escape(c: Char, quoteMode: QuoteMode, out: []u8) ![]u8 {
    if (c < 32) {
        const entry = escapeTable[c];
        std.mem.copyForwards(u8, out, entry.text);
        return out[0..entry.len];
    } else {
        switch (c) {
            127 => {
                std.mem.copyForwards(u8, out, "\\x7F");
                return out[0..4];
            },
            '\\' => {
                std.mem.copyForwards(u8, out, "\\\\");
                return out[0..2];
            },
            '"' => {
                if (quoteMode == QuoteMode.Double or quoteMode == QuoteMode.Both) {
                    std.mem.copyForwards(u8, out, "\\\"");
                    return out[0..2];
                } else {
                    out[0] = '"';
                    return out[0..1];
                }
            },
            '\'' => {
                if (quoteMode == QuoteMode.Single or quoteMode == QuoteMode.Both) {
                    std.mem.copyForwards(u8, out, "\\'");
                    return out[0..2];
                } else {
                    out[0] = '\'';
                    return out[0..1];
                }
            },
            else => {
                const len = try encode(c, out);
                return out[0..len];
            },
        }
    }
}

pub fn wcwidth(wc: Char) isize {
    return tableSearch.wcwidth(wc);
}

pub fn wcwidthStr(str: []const u8) !isize {
    var width: isize = 0;

    var i: usize = 0;

    while (i < str.len) {
        const dec = try decode1(str[i..]);
        const wcw = wcwidth(dec.ch);
        if (wcw < 0) return -1;
        width += wcw;
        i += dec.len;
    }

    return width;
}

pub fn isContinuationByte(b: u8) bool {
    return (b & 0b1100_0000) == 0b1000_0000;
}

pub fn isBoundaryByte(b: u8) bool {
    return b < 128 or b >= 192;
}

pub fn lastChar(str: []const u8) Error!?Char {
    if (str.len == 0) return null;
    var lastIndex = str.len - 1;
    while (!isBoundaryByte(str[lastIndex])) {
        lastIndex -= 1;
    }
    const dec = try decode1(str[lastIndex..]);
    return dec.ch;
}

pub fn lastToken(comptime predicateMode: bool, predicate: *const fn (Char) bool, buffer: []const u8) Error!?[]const u8 {
    if (buffer.len == 0) return null;
    var it = try InvertibleTokenIterator(predicateMode).init(buffer, predicate);
    return it.last();
}

pub const PosTokenIterator = InvertibleTokenIterator(true);
pub const NegTokenIterator = InvertibleTokenIterator(false);

fn InvertibleTokenIterator(comptime predicateMode: bool) type {
    return struct {
        cache: ?[]const u8,
        buffer: []const u8,
        index: usize,
        predicate: *const fn (Char) bool,

        const Self = @This();

        inline fn predicateCheck(self: *Self, ch: Char) bool {
            if (comptime predicateMode) {
                return self.predicate(ch);
            } else {
                return !self.predicate(ch);
            }
        }

        inline fn skipUnrecognized(self: *Self) Error!void {
            while (self.index < self.buffer.len) {
                const dec = try decode1(self.buffer[self.index..]);
                if (self.predicateCheck(dec.ch)) break;
                self.index += dec.len;
            }
        }

        pub fn init(buffer: []const u8, predicate: *const fn (Char) bool) Error!Self {
            var out = Self{
                .cache = null,
                .buffer = buffer,
                .index = 0,
                .predicate = predicate,
            };

            try out.skipUnrecognized();

            return out;
        }

        pub fn next(self: *Self) Error!?[]const u8 {
            const pk = try self.peek();

            if (pk) |buf| {
                self.index += buf.len;
                self.cache = null;

                try self.skipUnrecognized();
            }

            return pk;
        }

        pub fn peek(self: *Self) Error!?[]const u8 {
            if (self.cache) |buf| return buf;

            if (self.index >= self.buffer.len) return null;

            const start = self.index;
            var end = self.index;

            while (end < self.buffer.len) {
                const dec = try decode1(self.buffer[end..]);
                if (!self.predicateCheck(dec.ch)) break;
                end += dec.len;
            }

            self.cache = self.buffer[start..end];

            return self.cache;
        }

        pub fn rest(self: Self) []const u8 {
            const start = self.index;
            const end = self.buffer.len;
            return self.buffer[start..end];
        }

        pub fn reset(self: *Self) void {
            self.index = 0;
            self.cache = null;
        }

        pub fn last(self: *Self) Error!?[]const u8 {
            var ls: ?[]const u8 = null;
            while (try self.peek() != null) ls = try self.next();
            return ls;
        }
    };
}

test {
    const expect = std.testing.expect;
    const expectEqual = std.testing.expectEqual;
    const expectEqualSlices = std.testing.expectEqualSlices;
    const expectError = std.testing.expectError;

    try expect(isControl('\t'));
    try expect(isAlphabetic('a'));
    try expect(isSymbol('´'));
    try expect(isSymbol('©'));
    try expect(isSpace(' '));
    try expect(isLetter('a'));
    try expect(isControl('\t'));
    try expect(isDecimal('9'));
    try expectEqual(false, isDigit('9'));

    try expectEqual(1, displayWidth('a'));
    try expectEqual(2, displayWidth('🦀'));

    try expectEqual(1, try sequenceLength('a'));
    try expectEqual(4, try sequenceLength('🦀'));
    try expectError(Error.BadEncoding, sequenceLength(0x11FFFF));

    try expectEqual('A', toUpper('a'));
    try expectEqual('x', toLower('X'));
    try expectEqualSlices(Char, &[_]Char{'g'}, caseFold('G'));

    try expectEqual(3, numDigits(@as(i32, 100), 10));
    try expectEqual(2, numDigits(@as(i32, 0xFF), 16));

    try expectEqual(0, findStr("hello world", "hello"));
    try expectEqual(6, findStr("hello world", "world"));

    var str = std.ArrayList(u8).init(std.heap.page_allocator);
    try str.appendSlice("hello\nworld\n");
    try indentStr(&str, "\t");
    try expectEqualSlices(u8, "\thello\n\tworld\n", str.items);

    var escBuf = [1]u8{0} ** 4;
    try expectEqualSlices(u8, "\\0", try escape('\x00', .None, &escBuf));
    try expectEqualSlices(u8, "\\x01", try escape('\x01', .None, &escBuf));
    try expectEqualSlices(u8, "\\x02", try escape('\x02', .None, &escBuf));
    try expectEqualSlices(u8, "\\x03", try escape('\x03', .None, &escBuf));
    try expectEqualSlices(u8, "\\x04", try escape('\x04', .None, &escBuf));
    try expectEqualSlices(u8, "\\x05", try escape('\x05', .None, &escBuf));
    try expectEqualSlices(u8, "\\x06", try escape('\x06', .None, &escBuf));
    try expectEqualSlices(u8, "\\a", try escape('\x07', .None, &escBuf));
    try expectEqualSlices(u8, "\\b", try escape('\x08', .None, &escBuf));
    try expectEqualSlices(u8, "\\t", try escape('\t', .None, &escBuf));
    try expectEqualSlices(u8, "\\n", try escape('\n', .None, &escBuf));
    try expectEqualSlices(u8, "\\v", try escape('\x0b', .None, &escBuf));
    try expectEqualSlices(u8, "\\f", try escape('\x0c', .None, &escBuf));
    try expectEqualSlices(u8, "\\r", try escape('\r', .None, &escBuf));
    try expectEqualSlices(u8, "\\x0E", try escape('\x0E', .None, &escBuf));
    try expectEqualSlices(u8, "\\x0F", try escape('\x0F', .None, &escBuf));
    try expectEqualSlices(u8, "\\x10", try escape('\x10', .None, &escBuf));
    try expectEqualSlices(u8, "\\x11", try escape('\x11', .None, &escBuf));
    try expectEqualSlices(u8, "\\x12", try escape('\x12', .None, &escBuf));
    try expectEqualSlices(u8, "\\x13", try escape('\x13', .None, &escBuf));
    try expectEqualSlices(u8, "\\x14", try escape('\x14', .None, &escBuf));
    try expectEqualSlices(u8, "\\x15", try escape('\x15', .None, &escBuf));
    try expectEqualSlices(u8, "\\x16", try escape('\x16', .None, &escBuf));
    try expectEqualSlices(u8, "\\x17", try escape('\x17', .None, &escBuf));
    try expectEqualSlices(u8, "\\x18", try escape('\x18', .None, &escBuf));
    try expectEqualSlices(u8, "\\x19", try escape('\x19', .None, &escBuf));
    try expectEqualSlices(u8, "\\x1A", try escape('\x1A', .None, &escBuf));
    try expectEqualSlices(u8, "\\esc", try escape('\x1B', .None, &escBuf));
    try expectEqualSlices(u8, "\\x1C", try escape('\x1C', .None, &escBuf));
    try expectEqualSlices(u8, "\\x1D", try escape('\x1D', .None, &escBuf));
    try expectEqualSlices(u8, "\\x1E", try escape('\x1E', .None, &escBuf));
    try expectEqualSlices(u8, "\\x1F", try escape('\x1F', .None, &escBuf));
    try expectEqualSlices(u8, "\\x7F", try escape('\x7F', .None, &escBuf));
    try expectEqualSlices(u8, "\\\\", try escape('\\', .None, &escBuf));
    try expectEqualSlices(u8, "\"", try escape('"', .None, &escBuf));
    try expectEqualSlices(u8, "\"", try escape('"', .Single, &escBuf));
    try expectEqualSlices(u8, "\\\"", try escape('"', .Double, &escBuf));
    try expectEqualSlices(u8, "\\\"", try escape('"', .Both, &escBuf));
    try expectEqualSlices(u8, "\'", try escape('\'', .None, &escBuf));
    try expectEqualSlices(u8, "\'", try escape('\'', .Double, &escBuf));
    try expectEqualSlices(u8, "\\\'", try escape('\'', .Single, &escBuf));
    try expectEqualSlices(u8, "\\\'", try escape('\'', .Both, &escBuf));
    try expectEqualSlices(u8, "❔", try escape('❔', .None, &escBuf));

    try expect(caseInsensitiveCompare('a', 'A'));
    try expect(caseInsensitiveCompare('a', 'a'));
    try expect(caseInsensitiveCompare('X', 'x'));
    try expect(caseInsensitiveCompare('x', 'x'));
    try expect(!caseInsensitiveCompare('x', 'y'));
    try expect(!caseInsensitiveCompare('X', 'y'));

    try expect(try caseInsensitiveCompareStr("foo", "FOO"));
    try expect(try caseInsensitiveCompareStr("foo", "foo"));

    {
        try expectEqual(@as(isize, 0), wcwidth(0));
        try expectEqual(@as(isize, 1), wcwidth('a'));
        try expectEqual(@as(isize, 1), wcwidth('1'));
        try expectEqual(@as(isize, 1), wcwidth('-'));

        {
            const phrase = "コンニチハ, セカイ!";
            const expect_length_each = [_]isize{ 2, 2, 2, 2, 2, 1, 1, 2, 2, 2, 1 };
            const expect_length_phrase = comptime blk: {
                var sum: isize = 0;
                for (expect_length_each) |x| sum += x;
                break :blk sum;
            };

            // Check individual widths
            var utf8 = (try std.unicode.Utf8View.init(phrase)).iterator();
            var i: usize = 0;
            while (utf8.nextCodepoint()) |codepoint| : (i += 1) {
                try expectEqual(expect_length_each[i], wcwidth(codepoint));
            }

            // Check phrase width
            try expectEqual(expect_length_phrase, try wcwidthStr(phrase));
        }

        {
            const phrase = "\x1B[0m";
            const expect_length_each = [_]isize{ -1, 1, 1, 1 };
            const expect_length_phrase: isize = -1;

            // Check individual widths
            var utf8 = (try std.unicode.Utf8View.init(phrase)).iterator();
            var i: usize = 0;
            while (utf8.nextCodepoint()) |codepoint| : (i += 1) {
                try expectEqual(expect_length_each[i], wcwidth(codepoint));
            }

            // Check phrase width
            try expectEqual(expect_length_phrase, try wcwidthStr(phrase));
        }

        {
            const phrase = "--\u{05BF}--";
            const expect_length_each = [_]isize{ 1, 1, 0, 1, 1 };
            const expect_length_phrase: isize = 4;

            // Check individual widths
            var utf8 = (try std.unicode.Utf8View.init(phrase)).iterator();
            var i: usize = 0;
            while (utf8.nextCodepoint()) |codepoint| : (i += 1) {
                try expectEqual(expect_length_each[i], wcwidth(codepoint));
            }

            // Check phrase width
            try expectEqual(expect_length_phrase, try wcwidthStr(phrase));
        }

        {
            const phrase = "cafe\u{0301}";
            const expect_length_each = [_]isize{ 1, 1, 1, 1, 0 };
            const expect_length_phrase: isize = 4;

            // Check individual widths
            var utf8 = (try std.unicode.Utf8View.init(phrase)).iterator();
            var i: usize = 0;
            while (utf8.nextCodepoint()) |codepoint| : (i += 1) {
                try expectEqual(expect_length_each[i], wcwidth(codepoint));
            }

            // Check phrase width
            try expectEqual(expect_length_phrase, try wcwidthStr(phrase));
        }

        {
            const phrase = "\u{0401}\u{0488}";
            const expect_length_each = [_]isize{ 1, 0 };
            const expect_length_phrase: isize = 1;

            // Check individual widths
            var utf8 = (try std.unicode.Utf8View.init(phrase)).iterator();
            var i: usize = 0;
            while (utf8.nextCodepoint()) |codepoint| : (i += 1) {
                try expectEqual(expect_length_each[i], wcwidth(codepoint));
            }

            // Check phrase width
            try expectEqual(expect_length_phrase, try wcwidthStr(phrase));
        }

        {
            const phrase = "\u{1B13}\u{1B28}\u{1B2E}\u{1B44}";
            const expect_length_each = [_]isize{ 1, 1, 1, 1 };
            const expect_length_phrase: isize = 4;

            // Check individual widths
            var utf8 = (try std.unicode.Utf8View.init(phrase)).iterator();
            var i: usize = 0;
            while (utf8.nextCodepoint()) |codepoint| : (i += 1) {
                try expectEqual(expect_length_each[i], wcwidth(codepoint));
            }

            // Check phrase width
            try expectEqual(expect_length_phrase, try wcwidthStr(phrase));
        }
    }
}

// adapted from https://github.com/joachimschmidt557/zig-wcwidth (MIT License)
const tableSearch = struct {
    fn wcwidth(wc: Char) isize {
        if (tableSearch.onList(wc, &tableSearch.zero_width_cf)) {
            return 0;
        }

        if (wc < 32 or 0x07F <= wc and wc < 0x0A0) {
            return -1;
        }

        if (tableSearch.bisearch(wc, &tableSearch.zero_width)) {
            return 0;
        }

        // double width
        if (tableSearch.bisearch(wc, &tableSearch.wide_east_asian)) {
            return 2;
        } else {
            return 1;
        }
    }

    fn bisearch(ucs: Char, table: []const [2]Char) bool {
        var lbound: usize = 0;
        var ubound: usize = table.len - 1;

        if (ucs < table[lbound][0] or ucs > table[ubound][1]) {
            return false;
        }

        while (ubound >= lbound) {
            const mid = (lbound + ubound) / 2;
            if (ucs > table[mid][1]) {
                lbound = mid + 1;
            } else if (ucs < table[mid][0]) {
                ubound = mid - 1;
            } else {
                return true;
            }
        }

        return false;
    }

    fn onList(ucs: Char, list: []const Char) bool {
        var lbound: usize = 0;
        var ubound: usize = list.len - 1;

        if (ucs < list[lbound] or ucs > list[ubound]) {
            return false;
        }

        while (ubound >= lbound) {
            const mid = (lbound + ubound) / 2;
            if (ucs > list[mid]) {
                lbound = mid + 1;
            } else if (ucs < list[mid]) {
                ubound = mid - 1;
            } else {
                return true;
            }
        }

        return false;
    }

    const zero_width_cf = [_]u21{
        0, // Null (Cc)
        0x034F, // Combining grapheme joiner (Mn)
        0x200B, // Zero width space
        0x200C, // Zero width non-joiner
        0x200D, // Zero width joiner
        0x200E, // Left-to-right mark
        0x200F, // Right-to-left mark
        0x2028, // Line separator (Zl)
        0x2029, // Paragraph separator (Zp)
        0x202A, // Left-to-right embedding
        0x202B, // Right-to-left embedding
        0x202C, // Pop directional formatting
        0x202D, // Left-to-right override
        0x202E, // Right-to-left override
        0x2060, // Word joiner
        0x2061, // Function application
        0x2062, // Invisible times
        0x2063, // Invisible separator
    };

    const wide_east_asian = [_][2]u21{
        [2]u21{
            0x1100,
            0x115f,
        },
        [2]u21{
            0x231a,
            0x231b,
        },
        [2]u21{
            0x2329,
            0x232a,
        },
        [2]u21{
            0x23e9,
            0x23ec,
        },
        [2]u21{
            0x23f0,
            0x23f0,
        },
        [2]u21{
            0x23f3,
            0x23f3,
        },
        [2]u21{
            0x25fd,
            0x25fe,
        },
        [2]u21{
            0x2614,
            0x2615,
        },
        [2]u21{
            0x2648,
            0x2653,
        },
        [2]u21{
            0x267f,
            0x267f,
        },
        [2]u21{
            0x2693,
            0x2693,
        },
        [2]u21{
            0x26a1,
            0x26a1,
        },
        [2]u21{
            0x26aa,
            0x26ab,
        },
        [2]u21{
            0x26bd,
            0x26be,
        },
        [2]u21{
            0x26c4,
            0x26c5,
        },
        [2]u21{
            0x26ce,
            0x26ce,
        },
        [2]u21{
            0x26d4,
            0x26d4,
        },
        [2]u21{
            0x26ea,
            0x26ea,
        },
        [2]u21{
            0x26f2,
            0x26f3,
        },
        [2]u21{
            0x26f5,
            0x26f5,
        },
        [2]u21{
            0x26fa,
            0x26fa,
        },
        [2]u21{
            0x26fd,
            0x26fd,
        },
        [2]u21{
            0x2705,
            0x2705,
        },
        [2]u21{
            0x270a,
            0x270b,
        },
        [2]u21{
            0x2728,
            0x2728,
        },
        [2]u21{
            0x274c,
            0x274c,
        },
        [2]u21{
            0x274e,
            0x274e,
        },
        [2]u21{
            0x2753,
            0x2755,
        },
        [2]u21{
            0x2757,
            0x2757,
        },
        [2]u21{
            0x2795,
            0x2797,
        },
        [2]u21{
            0x27b0,
            0x27b0,
        },
        [2]u21{
            0x27bf,
            0x27bf,
        },
        [2]u21{
            0x2b1b,
            0x2b1c,
        },
        [2]u21{
            0x2b50,
            0x2b50,
        },
        [2]u21{
            0x2b55,
            0x2b55,
        },
        [2]u21{
            0x2e80,
            0x2e99,
        },
        [2]u21{
            0x2e9b,
            0x2ef3,
        },
        [2]u21{
            0x2f00,
            0x2fd5,
        },
        [2]u21{
            0x2ff0,
            0x2ffb,
        },
        [2]u21{
            0x3000,
            0x303e,
        },
        [2]u21{
            0x3041,
            0x3096,
        },
        [2]u21{
            0x3099,
            0x30ff,
        },
        [2]u21{
            0x3105,
            0x312f,
        },
        [2]u21{
            0x3131,
            0x318e,
        },
        [2]u21{
            0x3190,
            0x31e3,
        },
        [2]u21{
            0x31f0,
            0x321e,
        },
        [2]u21{
            0x3220,
            0x3247,
        },
        [2]u21{
            0x3250,
            0x4dbf,
        },
        [2]u21{
            0x4e00,
            0xa48c,
        },
        [2]u21{
            0xa490,
            0xa4c6,
        },
        [2]u21{
            0xa960,
            0xa97c,
        },
        [2]u21{
            0xac00,
            0xd7a3,
        },
        [2]u21{
            0xf900,
            0xfaff,
        },
        [2]u21{
            0xfe10,
            0xfe19,
        },
        [2]u21{
            0xfe30,
            0xfe52,
        },
        [2]u21{
            0xfe54,
            0xfe66,
        },
        [2]u21{
            0xfe68,
            0xfe6b,
        },
        [2]u21{
            0xff01,
            0xff60,
        },
        [2]u21{
            0xffe0,
            0xffe6,
        },
        [2]u21{
            0x16fe0,
            0x16fe4,
        },
        [2]u21{
            0x16ff0,
            0x16ff1,
        },
        [2]u21{
            0x17000,
            0x187f7,
        },
        [2]u21{
            0x18800,
            0x18cd5,
        },
        [2]u21{
            0x18d00,
            0x18d08,
        },
        [2]u21{
            0x1b000,
            0x1b11e,
        },
        [2]u21{
            0x1b150,
            0x1b152,
        },
        [2]u21{
            0x1b164,
            0x1b167,
        },
        [2]u21{
            0x1b170,
            0x1b2fb,
        },
        [2]u21{
            0x1f004,
            0x1f004,
        },
        [2]u21{
            0x1f0cf,
            0x1f0cf,
        },
        [2]u21{
            0x1f18e,
            0x1f18e,
        },
        [2]u21{
            0x1f191,
            0x1f19a,
        },
        [2]u21{
            0x1f200,
            0x1f202,
        },
        [2]u21{
            0x1f210,
            0x1f23b,
        },
        [2]u21{
            0x1f240,
            0x1f248,
        },
        [2]u21{
            0x1f250,
            0x1f251,
        },
        [2]u21{
            0x1f260,
            0x1f265,
        },
        [2]u21{
            0x1f300,
            0x1f320,
        },
        [2]u21{
            0x1f32d,
            0x1f335,
        },
        [2]u21{
            0x1f337,
            0x1f37c,
        },
        [2]u21{
            0x1f37e,
            0x1f393,
        },
        [2]u21{
            0x1f3a0,
            0x1f3ca,
        },
        [2]u21{
            0x1f3cf,
            0x1f3d3,
        },
        [2]u21{
            0x1f3e0,
            0x1f3f0,
        },
        [2]u21{
            0x1f3f4,
            0x1f3f4,
        },
        [2]u21{
            0x1f3f8,
            0x1f43e,
        },
        [2]u21{
            0x1f440,
            0x1f440,
        },
        [2]u21{
            0x1f442,
            0x1f4fc,
        },
        [2]u21{
            0x1f4ff,
            0x1f53d,
        },
        [2]u21{
            0x1f54b,
            0x1f54e,
        },
        [2]u21{
            0x1f550,
            0x1f567,
        },
        [2]u21{
            0x1f57a,
            0x1f57a,
        },
        [2]u21{
            0x1f595,
            0x1f596,
        },
        [2]u21{
            0x1f5a4,
            0x1f5a4,
        },
        [2]u21{
            0x1f5fb,
            0x1f64f,
        },
        [2]u21{
            0x1f680,
            0x1f6c5,
        },
        [2]u21{
            0x1f6cc,
            0x1f6cc,
        },
        [2]u21{
            0x1f6d0,
            0x1f6d2,
        },
        [2]u21{
            0x1f6d5,
            0x1f6d7,
        },
        [2]u21{
            0x1f6eb,
            0x1f6ec,
        },
        [2]u21{
            0x1f6f4,
            0x1f6fc,
        },
        [2]u21{
            0x1f7e0,
            0x1f7eb,
        },
        [2]u21{
            0x1f90c,
            0x1f93a,
        },
        [2]u21{
            0x1f93c,
            0x1f945,
        },
        [2]u21{
            0x1f947,
            0x1f978,
        },
        [2]u21{
            0x1f97a,
            0x1f9cb,
        },
        [2]u21{
            0x1f9cd,
            0x1f9ff,
        },
        [2]u21{
            0x1fa70,
            0x1fa74,
        },
        [2]u21{
            0x1fa78,
            0x1fa7a,
        },
        [2]u21{
            0x1fa80,
            0x1fa86,
        },
        [2]u21{
            0x1fa90,
            0x1faa8,
        },
        [2]u21{
            0x1fab0,
            0x1fab6,
        },
        [2]u21{
            0x1fac0,
            0x1fac2,
        },
        [2]u21{
            0x1fad0,
            0x1fad6,
        },
        [2]u21{
            0x20000,
            0x2fffd,
        },
        [2]u21{
            0x30000,
            0x3fffd,
        },
    };

    const zero_width = [_][2]u21{
        [2]u21{
            0x0300,
            0x036f,
        },
        [2]u21{
            0x0483,
            0x0489,
        },
        [2]u21{
            0x0591,
            0x05bd,
        },
        [2]u21{
            0x05bf,
            0x05bf,
        },
        [2]u21{
            0x05c1,
            0x05c2,
        },
        [2]u21{
            0x05c4,
            0x05c5,
        },
        [2]u21{
            0x05c7,
            0x05c7,
        },
        [2]u21{
            0x0610,
            0x061a,
        },
        [2]u21{
            0x064b,
            0x065f,
        },
        [2]u21{
            0x0670,
            0x0670,
        },
        [2]u21{
            0x06d6,
            0x06dc,
        },
        [2]u21{
            0x06df,
            0x06e4,
        },
        [2]u21{
            0x06e7,
            0x06e8,
        },
        [2]u21{
            0x06ea,
            0x06ed,
        },
        [2]u21{
            0x0711,
            0x0711,
        },
        [2]u21{
            0x0730,
            0x074a,
        },
        [2]u21{
            0x07a6,
            0x07b0,
        },
        [2]u21{
            0x07eb,
            0x07f3,
        },
        [2]u21{
            0x07fd,
            0x07fd,
        },
        [2]u21{
            0x0816,
            0x0819,
        },
        [2]u21{
            0x081b,
            0x0823,
        },
        [2]u21{
            0x0825,
            0x0827,
        },
        [2]u21{
            0x0829,
            0x082d,
        },
        [2]u21{
            0x0859,
            0x085b,
        },
        [2]u21{
            0x08d3,
            0x08e1,
        },
        [2]u21{
            0x08e3,
            0x0902,
        },
        [2]u21{
            0x093a,
            0x093a,
        },
        [2]u21{
            0x093c,
            0x093c,
        },
        [2]u21{
            0x0941,
            0x0948,
        },
        [2]u21{
            0x094d,
            0x094d,
        },
        [2]u21{
            0x0951,
            0x0957,
        },
        [2]u21{
            0x0962,
            0x0963,
        },
        [2]u21{
            0x0981,
            0x0981,
        },
        [2]u21{
            0x09bc,
            0x09bc,
        },
        [2]u21{
            0x09c1,
            0x09c4,
        },
        [2]u21{
            0x09cd,
            0x09cd,
        },
        [2]u21{
            0x09e2,
            0x09e3,
        },
        [2]u21{
            0x09fe,
            0x09fe,
        },
        [2]u21{
            0x0a01,
            0x0a02,
        },
        [2]u21{
            0x0a3c,
            0x0a3c,
        },
        [2]u21{
            0x0a41,
            0x0a42,
        },
        [2]u21{
            0x0a47,
            0x0a48,
        },
        [2]u21{
            0x0a4b,
            0x0a4d,
        },
        [2]u21{
            0x0a51,
            0x0a51,
        },
        [2]u21{
            0x0a70,
            0x0a71,
        },
        [2]u21{
            0x0a75,
            0x0a75,
        },
        [2]u21{
            0x0a81,
            0x0a82,
        },
        [2]u21{
            0x0abc,
            0x0abc,
        },
        [2]u21{
            0x0ac1,
            0x0ac5,
        },
        [2]u21{
            0x0ac7,
            0x0ac8,
        },
        [2]u21{
            0x0acd,
            0x0acd,
        },
        [2]u21{
            0x0ae2,
            0x0ae3,
        },
        [2]u21{
            0x0afa,
            0x0aff,
        },
        [2]u21{
            0x0b01,
            0x0b01,
        },
        [2]u21{
            0x0b3c,
            0x0b3c,
        },
        [2]u21{
            0x0b3f,
            0x0b3f,
        },
        [2]u21{
            0x0b41,
            0x0b44,
        },
        [2]u21{
            0x0b4d,
            0x0b4d,
        },
        [2]u21{
            0x0b55,
            0x0b56,
        },
        [2]u21{
            0x0b62,
            0x0b63,
        },
        [2]u21{
            0x0b82,
            0x0b82,
        },
        [2]u21{
            0x0bc0,
            0x0bc0,
        },
        [2]u21{
            0x0bcd,
            0x0bcd,
        },
        [2]u21{
            0x0c00,
            0x0c00,
        },
        [2]u21{
            0x0c04,
            0x0c04,
        },
        [2]u21{
            0x0c3e,
            0x0c40,
        },
        [2]u21{
            0x0c46,
            0x0c48,
        },
        [2]u21{
            0x0c4a,
            0x0c4d,
        },
        [2]u21{
            0x0c55,
            0x0c56,
        },
        [2]u21{
            0x0c62,
            0x0c63,
        },
        [2]u21{
            0x0c81,
            0x0c81,
        },
        [2]u21{
            0x0cbc,
            0x0cbc,
        },
        [2]u21{
            0x0cbf,
            0x0cbf,
        },
        [2]u21{
            0x0cc6,
            0x0cc6,
        },
        [2]u21{
            0x0ccc,
            0x0ccd,
        },
        [2]u21{
            0x0ce2,
            0x0ce3,
        },
        [2]u21{
            0x0d00,
            0x0d01,
        },
        [2]u21{
            0x0d3b,
            0x0d3c,
        },
        [2]u21{
            0x0d41,
            0x0d44,
        },
        [2]u21{
            0x0d4d,
            0x0d4d,
        },
        [2]u21{
            0x0d62,
            0x0d63,
        },
        [2]u21{
            0x0d81,
            0x0d81,
        },
        [2]u21{
            0x0dca,
            0x0dca,
        },
        [2]u21{
            0x0dd2,
            0x0dd4,
        },
        [2]u21{
            0x0dd6,
            0x0dd6,
        },
        [2]u21{
            0x0e31,
            0x0e31,
        },
        [2]u21{
            0x0e34,
            0x0e3a,
        },
        [2]u21{
            0x0e47,
            0x0e4e,
        },
        [2]u21{
            0x0eb1,
            0x0eb1,
        },
        [2]u21{
            0x0eb4,
            0x0ebc,
        },
        [2]u21{
            0x0ec8,
            0x0ecd,
        },
        [2]u21{
            0x0f18,
            0x0f19,
        },
        [2]u21{
            0x0f35,
            0x0f35,
        },
        [2]u21{
            0x0f37,
            0x0f37,
        },
        [2]u21{
            0x0f39,
            0x0f39,
        },
        [2]u21{
            0x0f71,
            0x0f7e,
        },
        [2]u21{
            0x0f80,
            0x0f84,
        },
        [2]u21{
            0x0f86,
            0x0f87,
        },
        [2]u21{
            0x0f8d,
            0x0f97,
        },
        [2]u21{
            0x0f99,
            0x0fbc,
        },
        [2]u21{
            0x0fc6,
            0x0fc6,
        },
        [2]u21{
            0x102d,
            0x1030,
        },
        [2]u21{
            0x1032,
            0x1037,
        },
        [2]u21{
            0x1039,
            0x103a,
        },
        [2]u21{
            0x103d,
            0x103e,
        },
        [2]u21{
            0x1058,
            0x1059,
        },
        [2]u21{
            0x105e,
            0x1060,
        },
        [2]u21{
            0x1071,
            0x1074,
        },
        [2]u21{
            0x1082,
            0x1082,
        },
        [2]u21{
            0x1085,
            0x1086,
        },
        [2]u21{
            0x108d,
            0x108d,
        },
        [2]u21{
            0x109d,
            0x109d,
        },
        [2]u21{
            0x135d,
            0x135f,
        },
        [2]u21{
            0x1712,
            0x1714,
        },
        [2]u21{
            0x1732,
            0x1734,
        },
        [2]u21{
            0x1752,
            0x1753,
        },
        [2]u21{
            0x1772,
            0x1773,
        },
        [2]u21{
            0x17b4,
            0x17b5,
        },
        [2]u21{
            0x17b7,
            0x17bd,
        },
        [2]u21{
            0x17c6,
            0x17c6,
        },
        [2]u21{
            0x17c9,
            0x17d3,
        },
        [2]u21{
            0x17dd,
            0x17dd,
        },
        [2]u21{
            0x180b,
            0x180d,
        },
        [2]u21{
            0x1885,
            0x1886,
        },
        [2]u21{
            0x18a9,
            0x18a9,
        },
        [2]u21{
            0x1920,
            0x1922,
        },
        [2]u21{
            0x1927,
            0x1928,
        },
        [2]u21{
            0x1932,
            0x1932,
        },
        [2]u21{
            0x1939,
            0x193b,
        },
        [2]u21{
            0x1a17,
            0x1a18,
        },
        [2]u21{
            0x1a1b,
            0x1a1b,
        },
        [2]u21{
            0x1a56,
            0x1a56,
        },
        [2]u21{
            0x1a58,
            0x1a5e,
        },
        [2]u21{
            0x1a60,
            0x1a60,
        },
        [2]u21{
            0x1a62,
            0x1a62,
        },
        [2]u21{
            0x1a65,
            0x1a6c,
        },
        [2]u21{
            0x1a73,
            0x1a7c,
        },
        [2]u21{
            0x1a7f,
            0x1a7f,
        },
        [2]u21{
            0x1ab0,
            0x1ac0,
        },
        [2]u21{
            0x1b00,
            0x1b03,
        },
        [2]u21{
            0x1b34,
            0x1b34,
        },
        [2]u21{
            0x1b36,
            0x1b3a,
        },
        [2]u21{
            0x1b3c,
            0x1b3c,
        },
        [2]u21{
            0x1b42,
            0x1b42,
        },
        [2]u21{
            0x1b6b,
            0x1b73,
        },
        [2]u21{
            0x1b80,
            0x1b81,
        },
        [2]u21{
            0x1ba2,
            0x1ba5,
        },
        [2]u21{
            0x1ba8,
            0x1ba9,
        },
        [2]u21{
            0x1bab,
            0x1bad,
        },
        [2]u21{
            0x1be6,
            0x1be6,
        },
        [2]u21{
            0x1be8,
            0x1be9,
        },
        [2]u21{
            0x1bed,
            0x1bed,
        },
        [2]u21{
            0x1bef,
            0x1bf1,
        },
        [2]u21{
            0x1c2c,
            0x1c33,
        },
        [2]u21{
            0x1c36,
            0x1c37,
        },
        [2]u21{
            0x1cd0,
            0x1cd2,
        },
        [2]u21{
            0x1cd4,
            0x1ce0,
        },
        [2]u21{
            0x1ce2,
            0x1ce8,
        },
        [2]u21{
            0x1ced,
            0x1ced,
        },
        [2]u21{
            0x1cf4,
            0x1cf4,
        },
        [2]u21{
            0x1cf8,
            0x1cf9,
        },
        [2]u21{
            0x1dc0,
            0x1df9,
        },
        [2]u21{
            0x1dfb,
            0x1dff,
        },
        [2]u21{
            0x20d0,
            0x20f0,
        },
        [2]u21{
            0x2cef,
            0x2cf1,
        },
        [2]u21{
            0x2d7f,
            0x2d7f,
        },
        [2]u21{
            0x2de0,
            0x2dff,
        },
        [2]u21{
            0x302a,
            0x302d,
        },
        [2]u21{
            0x3099,
            0x309a,
        },
        [2]u21{
            0xa66f,
            0xa672,
        },
        [2]u21{
            0xa674,
            0xa67d,
        },
        [2]u21{
            0xa69e,
            0xa69f,
        },
        [2]u21{
            0xa6f0,
            0xa6f1,
        },
        [2]u21{
            0xa802,
            0xa802,
        },
        [2]u21{
            0xa806,
            0xa806,
        },
        [2]u21{
            0xa80b,
            0xa80b,
        },
        [2]u21{
            0xa825,
            0xa826,
        },
        [2]u21{
            0xa82c,
            0xa82c,
        },
        [2]u21{
            0xa8c4,
            0xa8c5,
        },
        [2]u21{
            0xa8e0,
            0xa8f1,
        },
        [2]u21{
            0xa8ff,
            0xa8ff,
        },
        [2]u21{
            0xa926,
            0xa92d,
        },
        [2]u21{
            0xa947,
            0xa951,
        },
        [2]u21{
            0xa980,
            0xa982,
        },
        [2]u21{
            0xa9b3,
            0xa9b3,
        },
        [2]u21{
            0xa9b6,
            0xa9b9,
        },
        [2]u21{
            0xa9bc,
            0xa9bd,
        },
        [2]u21{
            0xa9e5,
            0xa9e5,
        },
        [2]u21{
            0xaa29,
            0xaa2e,
        },
        [2]u21{
            0xaa31,
            0xaa32,
        },
        [2]u21{
            0xaa35,
            0xaa36,
        },
        [2]u21{
            0xaa43,
            0xaa43,
        },
        [2]u21{
            0xaa4c,
            0xaa4c,
        },
        [2]u21{
            0xaa7c,
            0xaa7c,
        },
        [2]u21{
            0xaab0,
            0xaab0,
        },
        [2]u21{
            0xaab2,
            0xaab4,
        },
        [2]u21{
            0xaab7,
            0xaab8,
        },
        [2]u21{
            0xaabe,
            0xaabf,
        },
        [2]u21{
            0xaac1,
            0xaac1,
        },
        [2]u21{
            0xaaec,
            0xaaed,
        },
        [2]u21{
            0xaaf6,
            0xaaf6,
        },
        [2]u21{
            0xabe5,
            0xabe5,
        },
        [2]u21{
            0xabe8,
            0xabe8,
        },
        [2]u21{
            0xabed,
            0xabed,
        },
        [2]u21{
            0xfb1e,
            0xfb1e,
        },
        [2]u21{
            0xfe00,
            0xfe0f,
        },
        [2]u21{
            0xfe20,
            0xfe2f,
        },
        [2]u21{
            0x101fd,
            0x101fd,
        },
        [2]u21{
            0x102e0,
            0x102e0,
        },
        [2]u21{
            0x10376,
            0x1037a,
        },
        [2]u21{
            0x10a01,
            0x10a03,
        },
        [2]u21{
            0x10a05,
            0x10a06,
        },
        [2]u21{
            0x10a0c,
            0x10a0f,
        },
        [2]u21{
            0x10a38,
            0x10a3a,
        },
        [2]u21{
            0x10a3f,
            0x10a3f,
        },
        [2]u21{
            0x10ae5,
            0x10ae6,
        },
        [2]u21{
            0x10d24,
            0x10d27,
        },
        [2]u21{
            0x10eab,
            0x10eac,
        },
        [2]u21{
            0x10f46,
            0x10f50,
        },
        [2]u21{
            0x11001,
            0x11001,
        },
        [2]u21{
            0x11038,
            0x11046,
        },
        [2]u21{
            0x1107f,
            0x11081,
        },
        [2]u21{
            0x110b3,
            0x110b6,
        },
        [2]u21{
            0x110b9,
            0x110ba,
        },
        [2]u21{
            0x11100,
            0x11102,
        },
        [2]u21{
            0x11127,
            0x1112b,
        },
        [2]u21{
            0x1112d,
            0x11134,
        },
        [2]u21{
            0x11173,
            0x11173,
        },
        [2]u21{
            0x11180,
            0x11181,
        },
        [2]u21{
            0x111b6,
            0x111be,
        },
        [2]u21{
            0x111c9,
            0x111cc,
        },
        [2]u21{
            0x111cf,
            0x111cf,
        },
        [2]u21{
            0x1122f,
            0x11231,
        },
        [2]u21{
            0x11234,
            0x11234,
        },
        [2]u21{
            0x11236,
            0x11237,
        },
        [2]u21{
            0x1123e,
            0x1123e,
        },
        [2]u21{
            0x112df,
            0x112df,
        },
        [2]u21{
            0x112e3,
            0x112ea,
        },
        [2]u21{
            0x11300,
            0x11301,
        },
        [2]u21{
            0x1133b,
            0x1133c,
        },
        [2]u21{
            0x11340,
            0x11340,
        },
        [2]u21{
            0x11366,
            0x1136c,
        },
        [2]u21{
            0x11370,
            0x11374,
        },
        [2]u21{
            0x11438,
            0x1143f,
        },
        [2]u21{
            0x11442,
            0x11444,
        },
        [2]u21{
            0x11446,
            0x11446,
        },
        [2]u21{
            0x1145e,
            0x1145e,
        },
        [2]u21{
            0x114b3,
            0x114b8,
        },
        [2]u21{
            0x114ba,
            0x114ba,
        },
        [2]u21{
            0x114bf,
            0x114c0,
        },
        [2]u21{
            0x114c2,
            0x114c3,
        },
        [2]u21{
            0x115b2,
            0x115b5,
        },
        [2]u21{
            0x115bc,
            0x115bd,
        },
        [2]u21{
            0x115bf,
            0x115c0,
        },
        [2]u21{
            0x115dc,
            0x115dd,
        },
        [2]u21{
            0x11633,
            0x1163a,
        },
        [2]u21{
            0x1163d,
            0x1163d,
        },
        [2]u21{
            0x1163f,
            0x11640,
        },
        [2]u21{
            0x116ab,
            0x116ab,
        },
        [2]u21{
            0x116ad,
            0x116ad,
        },
        [2]u21{
            0x116b0,
            0x116b5,
        },
        [2]u21{
            0x116b7,
            0x116b7,
        },
        [2]u21{
            0x1171d,
            0x1171f,
        },
        [2]u21{
            0x11722,
            0x11725,
        },
        [2]u21{
            0x11727,
            0x1172b,
        },
        [2]u21{
            0x1182f,
            0x11837,
        },
        [2]u21{
            0x11839,
            0x1183a,
        },
        [2]u21{
            0x1193b,
            0x1193c,
        },
        [2]u21{
            0x1193e,
            0x1193e,
        },
        [2]u21{
            0x11943,
            0x11943,
        },
        [2]u21{
            0x119d4,
            0x119d7,
        },
        [2]u21{
            0x119da,
            0x119db,
        },
        [2]u21{
            0x119e0,
            0x119e0,
        },
        [2]u21{
            0x11a01,
            0x11a0a,
        },
        [2]u21{
            0x11a33,
            0x11a38,
        },
        [2]u21{
            0x11a3b,
            0x11a3e,
        },
        [2]u21{
            0x11a47,
            0x11a47,
        },
        [2]u21{
            0x11a51,
            0x11a56,
        },
        [2]u21{
            0x11a59,
            0x11a5b,
        },
        [2]u21{
            0x11a8a,
            0x11a96,
        },
        [2]u21{
            0x11a98,
            0x11a99,
        },
        [2]u21{
            0x11c30,
            0x11c36,
        },
        [2]u21{
            0x11c38,
            0x11c3d,
        },
        [2]u21{
            0x11c3f,
            0x11c3f,
        },
        [2]u21{
            0x11c92,
            0x11ca7,
        },
        [2]u21{
            0x11caa,
            0x11cb0,
        },
        [2]u21{
            0x11cb2,
            0x11cb3,
        },
        [2]u21{
            0x11cb5,
            0x11cb6,
        },
        [2]u21{
            0x11d31,
            0x11d36,
        },
        [2]u21{
            0x11d3a,
            0x11d3a,
        },
        [2]u21{
            0x11d3c,
            0x11d3d,
        },
        [2]u21{
            0x11d3f,
            0x11d45,
        },
        [2]u21{
            0x11d47,
            0x11d47,
        },
        [2]u21{
            0x11d90,
            0x11d91,
        },
        [2]u21{
            0x11d95,
            0x11d95,
        },
        [2]u21{
            0x11d97,
            0x11d97,
        },
        [2]u21{
            0x11ef3,
            0x11ef4,
        },
        [2]u21{
            0x16af0,
            0x16af4,
        },
        [2]u21{
            0x16b30,
            0x16b36,
        },
        [2]u21{
            0x16f4f,
            0x16f4f,
        },
        [2]u21{
            0x16f8f,
            0x16f92,
        },
        [2]u21{
            0x16fe4,
            0x16fe4,
        },
        [2]u21{
            0x1bc9d,
            0x1bc9e,
        },
        [2]u21{
            0x1d167,
            0x1d169,
        },
        [2]u21{
            0x1d17b,
            0x1d182,
        },
        [2]u21{
            0x1d185,
            0x1d18b,
        },
        [2]u21{
            0x1d1aa,
            0x1d1ad,
        },
        [2]u21{
            0x1d242,
            0x1d244,
        },
        [2]u21{
            0x1da00,
            0x1da36,
        },
        [2]u21{
            0x1da3b,
            0x1da6c,
        },
        [2]u21{
            0x1da75,
            0x1da75,
        },
        [2]u21{
            0x1da84,
            0x1da84,
        },
        [2]u21{
            0x1da9b,
            0x1da9f,
        },
        [2]u21{
            0x1daa1,
            0x1daaf,
        },
        [2]u21{
            0x1e000,
            0x1e006,
        },
        [2]u21{
            0x1e008,
            0x1e018,
        },
        [2]u21{
            0x1e01b,
            0x1e021,
        },
        [2]u21{
            0x1e023,
            0x1e024,
        },
        [2]u21{
            0x1e026,
            0x1e02a,
        },
        [2]u21{
            0x1e130,
            0x1e136,
        },
        [2]u21{
            0x1e2ec,
            0x1e2ef,
        },
        [2]u21{
            0x1e8d0,
            0x1e8d6,
        },
        [2]u21{
            0x1e944,
            0x1e94a,
        },
        [2]u21{
            0xe0100,
            0xe01ef,
        },
    };
};
