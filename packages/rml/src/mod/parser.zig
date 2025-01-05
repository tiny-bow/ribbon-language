const std = @import("std");
const MiscUtils = @import("Utils").Misc;
const TextUtils = @import("Utils").Text;

const Rml = @import("root.zig");
const Ordering = Rml.Ordering;
const Error = Rml.Error;
const OOM = Rml.OOM;
const log = Rml.log;
const Object = Rml.Object;
const Obj = Rml.Obj;
const ptr = Rml.ptr;
const getObj = Rml.getObj;
const getTypeId = Rml.getTypeId;
const getRml = Rml.getRml;
const castObj = Rml.castObj;
const forceObj = Rml.forceObj;
const String = Rml.String;
const Symbol = Rml.Symbol;
const Quote = Rml.Quote;
const Map = Rml.Map;
const Array = Rml.Array;
const Writer = Rml.Writer;
const PropertySet = Rml.object.PropertySet;
const Origin = Rml.source.Origin;
const Range = Rml.source.Range;
const Pos = Rml.source.Pos;
const str = Rml.str;
const Int = Rml.Int;
const Float = Rml.Float;
const Char = Rml.Char;


pub const parsing = std.log.scoped(.parsing);


pub const SyntaxError = error{ SyntaxError, UnexpectedInput, UnexpectedEOF } || TextUtils.Error;

pub const Parser = struct {
    input: Obj(String),
    filename: str,
    buffer_pos: Pos,
    rel_offset: Pos,
    peek_cache: ?Object,
    char_peek_cache: ?Char,

    pub fn create(filename: str, input: Obj(String)) Parser {
        return .{
            .input = input,
            .filename = filename,
            .buffer_pos = Pos { .line = 0, .column = 0, .offset = 0, .indentation = 0 },
            .rel_offset = Pos { .line = 1, .column = 1, .offset = 0, .indentation = 0 },
            .peek_cache = null,
            .char_peek_cache = null,
        };
    }

    pub fn onCompare(a: *Parser, other: Object) Ordering {
        var ord = Rml.compare(getTypeId(a), other.getTypeId());

        if (ord == .Equal) {
            const b = forceObj(Parser, other);
            ord = Rml.compare(@intFromPtr(a), @intFromPtr(b.data));
        }

        return ord;
    }

    pub fn onFormat(self: *Parser, writer: std.io.AnyWriter) anyerror! void {
        return writer.print("Parser{x}", .{@intFromPtr(self)});
    }

    pub fn peek(self: *Parser) Error! ?Object {
        return self.peekWith(&self.peek_cache);
    }

    pub fn offsetPos(self: *Parser, pos: Pos) Pos {
        return .{
            .line = pos.line + self.rel_offset.line,
            .column = pos.column + self.rel_offset.column,
            .offset = pos.offset + self.rel_offset.offset,
            .indentation = pos.indentation + self.rel_offset.indentation,
        };
    }

    pub fn getOffsetPos(self: *Parser) Pos {
        return self.offsetPos(self.buffer_pos);
    }

    pub fn peekWith(self: *Parser, peek_cache: *?Object) Error! ?Object {
        if (peek_cache.*) |cachedObject| {
            parsing.debug("peek: using cached object", .{});
            return cachedObject;
        }

        parsing.debug("peek: parsing object", .{});

        const rml = getRml(self);

        var properties = try self.scan() orelse PropertySet{};

        if (try self.parseAnyBlockClosing()) {
            return null;
        }

        const obj = try self.parseObject() orelse return null;
        try obj.getHeader().properties.copyFrom(rml, &properties);

        peek_cache.* = obj;

        return obj;
    }

    pub fn next(self: *Parser) Error! ?Object {
        return self.nextWith(&self.peek_cache);
    }

    pub fn nextWith(self: *Parser, peek_cache: *?Object) Error! ?Object {
        const result = try self.peekWith(peek_cache) orelse return null;

        peek_cache.* = null;

        return result;
    }


    pub fn setOffset(self: *Parser, offset: Pos) void {
        self.rel_offset = offset;
    }

    pub fn clearOffset(self: *Parser) void {
        self.rel_offset = Pos { .line = 1, .column = 1, .offset = 0 };
    }

    pub fn getOrigin(self: *Parser, start: ?Pos, end: ?Pos) Origin {
        return self.getOffsetOrigin(
            if (start) |x| self.offsetPos(x) else null,
            if (end) |x| self.offsetPos(x) else null,
        );
    }

    pub fn getOffsetOrigin(self: *Parser, start: ?Pos, end: ?Pos) Origin {
        return Origin {
            .filename = self.filename,
            .range = Range { .start = start, .end = end },
        };
    }

    pub fn parseObject(self: *Parser) Error! ?Object {
        parsing.debug("parseObject {?u}", .{self.peekChar() catch null});
        errdefer parsing.debug("parseObject failed", .{});

        const result
             = try self.parseAtom()
        orelse if (try self.parseAnyBlock()) |x| x.typeErase() else null
        orelse if (try self.parseAnyQuote()) |x| x.typeErase() else null;

        parsing.debug("parseObject result: {?}", .{result});

        return result;
    }

    pub fn parseAtom(self: *Parser) Error! ?Object {
        parsing.debug("parseAtom", .{});
        errdefer parsing.debug("parseAtom failed", .{});

        const result
             = (if (try self.parseInt()) |x| x.typeErase() else null)
        orelse (if (try self.parseFloat()) |x| x.typeErase() else null)
        orelse (if (try self.parseChar()) |x| x.typeErase() else null)
        orelse (if (try self.parseString()) |x| x.typeErase() else null)
        orelse try self.parseSymbolic();

        parsing.debug("parseAtom result: {?}", .{result});

        return result;
    }

    pub fn parseQuote(self: *Parser, quoteKind: Rml.quote.QuoteKind) Error! ?Obj(Rml.Quote) {
        parsing.debug("parseQuote", .{});
        errdefer parsing.debug("parseQuote failed", .{});

        const rml = getRml(self);
        const start = self.buffer_pos;

        if (!try self.parseQuoteOpening(quoteKind)) {
            parsing.debug("parseQuote stop: no quote kind", .{});
            return null;
        }

        const body = try self.parseObject() orelse
            try self.failed(self.getOrigin(self.buffer_pos, null),
                "expected an object to follow quote operator `{s}`", .{quoteKind.toStr()});

        const result: Obj(Quote) = try .wrap(rml, self.getOrigin(start, self.buffer_pos), .{ .kind = quoteKind, .body = body });

        parsing.debug("parseQuote result: {?}", .{result});

        return result;
    }

    pub fn parseAnyQuote(self: *Parser) Error! ?Obj(Rml.Quote) {
        parsing.debug("parseQuote", .{});
        errdefer parsing.debug("parseQuote failed", .{});

        const rml = getRml(self);
        const start = self.buffer_pos;

        const quoteKind = try self.parseAnyQuoteOpening() orelse return null;

        parsing.debug("got quote opening {s}", .{quoteKind.toStr()});

        const body = try self.parseObject() orelse
            try self.failed(self.getOrigin(self.buffer_pos, null),
                "expected an object to follow quote operator `{s}`", .{quoteKind.toStr()});

        const result: Obj(Quote) = try .wrap(rml, self.getOrigin(start, self.buffer_pos), .{ .kind = quoteKind, .body = body });

        parsing.debug("parseQuote result: {?}", .{result});

        return result;
    }

    pub fn parseBlock(self: *Parser, blockKind: Rml.block.BlockKind) Error! ?Obj(Rml.Block) {
        parsing.debug("parseBlock", .{});
        errdefer parsing.debug("parseBlock failed", .{});

        const start = self.buffer_pos;

        if (!try self.parseBlockOpening(blockKind)) {
            return null;
        }

        const result = try self.parseBlockTail(start, blockKind);

        parsing.debug("parseBlock result: {?}", .{result});

        return result;
    }

    pub fn parseAnyBlock(self: *Parser) Error! ?Obj(Rml.Block) {
        parsing.debug("parseBlock", .{});
        errdefer parsing.debug("parseBlock failed", .{});

        const start = self.buffer_pos;

        const blockKind = try self.parseAnyBlockOpening() orelse return null;

        parsing.debug("got block opening {s}", .{blockKind.toOpenStr()});

        const result = try self.parseBlockTail(start, blockKind);

        parsing.debug("parseBlock result: {?}", .{result});

        return result;
    }

    pub fn nextBlob(self: *Parser) Error! ?[]Object {
        return self.nextBlobWith(&self.peek_cache);
    }

    pub fn nextBlobWith(self: *Parser, peekCache: *?Object) Error! ?[]Object {
        var blob: std.ArrayListUnmanaged(Object) = .{};

        const first = try self.peekWith(peekCache) orelse {
            return null;
        };
        const start = first.getOrigin().range.?.start.?;

        blob: while (next: {
            const nxt = try self.nextWith(peekCache);
            break :next nxt;
        }) |sourceExpr| {
            {
                try blob.append(getRml(self).blobAllocator(), sourceExpr);
            }

            const nxt: Rml.Object = try self.peekWith(peekCache) orelse break :blob;

            if (!isIndentationDomain(start, nxt.getOrigin().range.?.start.?)) {
                break :blob;
            }
        }

        return try self.blobify(.same_indent, start, blob.items);
    }

    pub fn blobify(self: *Parser, heuristic: enum {same_indent, domain}, start: Pos, blob: []Object) Error! []Object {
        const end = blob[blob.len - 1].getOrigin().range.?.end.?;
        const blobOrigin = self.getOffsetOrigin(start, end);

        parsing.debug("blobify: {any}", .{blob});

        var array: std.ArrayListUnmanaged(Object) = .{};

        var i: usize = 0;
        for (blob) |item| {
            const pos = item.getOrigin().range.?.start.?;

            switch (heuristic) {
                .same_indent => if (start.indentation != pos.indentation) break,
                .domain => if (!isIndentationDomain(start, pos)) break,
            }

            try array.append(getRml(self).blobAllocator(), item);
            i += 1;
        }

        parsing.debug("scanned: {}", .{array});

        if (i == blob.len) {
            parsing.debug("return blob", .{});
            return array.items;
        } else {
            const first = blob[i].getOrigin().range.?.start.?;

            const newBlob = try self.blobify(.domain, first, blob[i..]);

            parsing.debug("new blob: {any}", .{newBlob});

            switch (heuristic) {
                .domain => {
                    const firstLine = try Rml.Obj(Rml.Block).wrap(getRml(self), blobOrigin, .{ .kind = .doc, .array = array });

                    var allDocBlock = true;
                    for (newBlob) |item| {
                        if (Rml.castObj(Rml.Block, item)) |x| {
                            if (x.data.kind != .doc) {
                                allDocBlock = false;
                                break;
                            }
                        } else {
                            allDocBlock = false;
                            break;
                        }
                    }

                    if (allDocBlock) {
                        parsing.debug("concat", .{});
                        return std.mem.concat(getRml(self).blobAllocator(), Object, &.{&.{firstLine.typeErase()}, newBlob});
                    } else {
                        parsing.debug("append first line, wrap", .{});
                        var newArr: std.ArrayListUnmanaged(Object) = .{};
                        try newArr.append(getRml(self).blobAllocator(), firstLine.typeErase());
                        try newArr.append(getRml(self).blobAllocator(), (try Rml.Obj(Rml.Block).wrap(getRml(self), blobOrigin, try .create(getRml(self), .doc, newBlob))).typeErase());

                        return newArr.items;
                    }
                },
                .same_indent => {
                    parsing.debug("append", .{});
                    try array.append(getRml(self).blobAllocator(), (try Rml.Obj(Rml.Block).wrap(getRml(self), blobOrigin, try .create(getRml(self), .doc, newBlob))).typeErase());
                    return array.items;
                }
            }
        }
    }

    fn parseBlockTail(self: *Parser, start: Pos, blockKind: Rml.block.BlockKind) Error! Obj(Rml.Block) {
        const rml = getRml(self);

        var array: std.ArrayListUnmanaged(Object) = .{};

        var properties = try self.scan() orelse PropertySet{};

        var tailDeinit = true;
        var tailProperties: Rml.object.PropertySet = .{};

        var peekCache: ?Object = null;

        while (true) {
            if (self.isEof() and blockKind != .doc) {
                return error.UnexpectedEOF;
            }

            if (try self.parseBlockClosing(blockKind)) {
                tailProperties = try properties.clone(rml);
                break;
            }

            {
                const blob = try self.nextBlobWith(&peekCache) orelse {
                    try self.failed(self.getOrigin(self.buffer_pos, null), "expected object", .{});
                };

                const blobOrigin = self.getOffsetOrigin(blob[0].getOrigin().range.?.start.?, blob[blob.len - 1].getOrigin().range.?.end.?);

                try array.append(rml.blobAllocator(), (try Rml.Obj(Rml.Block).wrap(getRml(self), blobOrigin, try .create(getRml(self), .doc, blob))).typeErase());
            }

            if (try self.scan()) |props| {
                properties = props;
            } else { // require whitespace between objects
                if (try self.parseBlockClosing(blockKind)) {
                    tailProperties = try properties.clone(rml);
                    break;
                } else {
                    try self.failed(self.getOrigin(self.buffer_pos, null), "expected space or `{s}`", .{blockKind.toCloseStr()});
                }
            }
        }

        const origin = self.getOrigin(start, self.buffer_pos);

        const block: Obj(Rml.Block) = block: {
            if (array.items.len == 1) {
                const item = array.items[0];
                if (Rml.castObj(Rml.Block, item)) |x| {
                    if (x.data.kind == .doc) {
                        x.data.kind = blockKind;
                        x.getHeader().origin = origin;
                        break :block x;
                    }
                }
            }

            break :block try .wrap(rml, origin, .{
                .kind = blockKind,
                .array = array
            });
        };

        if (tailProperties.length() > 0) {
            const sym: Obj(Symbol) = try .wrap(rml, origin, try .create(rml, "tail"));

            const map: Obj(Map) = try .wrap(rml, origin, .{ .unmanaged = tailProperties });
            tailDeinit = false;

            try block.getHeader().properties.set(rml, sym.typeErase(), map.typeErase());
        }

        return block;
    }

    pub fn parseQuoteOpening(self: *Parser, kind : Rml.quote.QuoteKind) Error! bool {
        const openStr = kind.toStr();

        std.debug.assert(!std.mem.eql(u8, openStr, ""));

        return try self.expectSlice(openStr);
    }

    pub fn parseAnyQuoteOpening(self: *Parser) Error! ?Rml.quote.QuoteKind {
        inline for (comptime std.meta.fieldNames(Rml.quote.QuoteKind)) |quoteKindName| {
            const quoteKind = @field(Rml.quote.QuoteKind, quoteKindName);
            const openStr = comptime quoteKind.toStr();

            if (comptime std.mem.eql(u8, openStr, "")) @compileError("QuoteKind." ++ quoteKindName ++ ".toStr() must not return an empty string");

            if (try self.expectSlice(openStr)) {
                parsing.debug("got quote opening {s}", .{openStr});
                return quoteKind;
            }
        }

        return null;
    }

    pub fn parseBlockOpening(self: *Parser, kind: Rml.block.BlockKind) Error! bool {
        const openStr = kind.toOpenStr();

        if (std.mem.eql(u8, openStr, "")) {
            parsing.debug("checking for bof", .{});
            const is = self.isBof();
            parsing.debug("bof: {}", .{is});
            return is;
        } else {
            parsing.debug("checking for {s}", .{openStr});
            const is = try self.expectSlice(openStr);
            parsing.debug("{s}: {}", .{openStr, is});
            return is;
        }
    }

    pub fn parseAnyBlockOpening(self: *Parser) Error! ?Rml.block.BlockKind {
        inline for (comptime std.meta.fieldNames(Rml.block.BlockKind)) |blockKindName| {
            const blockKind = @field(Rml.block.BlockKind, blockKindName);
            const openStr = comptime blockKind.toOpenStr();

            if (comptime std.mem.eql(u8, openStr, "")) continue;

            if (try self.expectSlice(openStr)) {
                parsing.debug("got block opening {s}", .{openStr});
                return blockKind;
            }
        }

        return null;
    }

    pub fn parseBlockClosing(self: *Parser, kind: Rml.block.BlockKind) Error! bool {
        const closeStr = kind.toCloseStr();

        if (std.mem.eql(u8, closeStr, "")) {
            parsing.debug("checking for eof", .{});
            const is = self.isEof();
            parsing.debug("eof: {}", .{is});
            return is;
        } else {
            parsing.debug("checking for {s}", .{closeStr});
            const is = try self.expectSlice(closeStr);
            parsing.debug("{s}: {}", .{closeStr, is});
            return is;
        }
    }

    pub fn parseAnyBlockClosing(self: *Parser) Error! bool {
        inline for (comptime std.meta.fieldNames(Rml.block.BlockKind)) |blockKindName| {
            const blockKind = @field(Rml.block.BlockKind, blockKindName);
            const closeStr = comptime blockKind.toCloseStr();

            if (comptime std.mem.eql(u8, closeStr, "")) {
                parsing.debug("checking for eof", .{});
                const is = self.isEof();
                parsing.debug("eof: {}", .{is});
                return is;
            } else {
                parsing.debug("checking for {s}", .{closeStr});
                const is = try self.expectSlice(closeStr);
                parsing.debug("{s}: {}", .{closeStr, is});
                return is;
            }
        }
    }

    pub fn parseInt(self: *Parser) Error! ?Obj(Rml.Int) {
        parsing.debug("parseInt {?u}", .{self.peekChar() catch null});
        errdefer parsing.debug("parseInt failed", .{});

        const rml = getRml(self);
        const start = self.buffer_pos;

        var int: Rml.Int = 0;

        const sign = try self.expectOptionalSign(Rml.Int) orelse {
            parsing.debug("parseInt stop: no input", .{});
            return null;
        };

        var digits: usize = 0;

        while (try self.expectDecimalDigit()) |value| {
            int = int * 10 + value;
            digits += 1;
        }

        if (digits == 0) {
            parsing.debug("parseInt reset: no digits", .{});
            self.reset(start);
            return null;
        }

        const result: Obj(Rml.Int) = try .wrap(rml, self.getOrigin(start, self.buffer_pos), int * sign);

        parsing.debug("parseInt result: {}", .{result});

        return result;
    }

    pub fn parseFloat(self: *Parser) Error! ?Obj(Rml.Float) {
        parsing.debug("parseFloat {?u}", .{self.peekChar() catch null});
        errdefer parsing.debug("parseFloat failed", .{});

        const rml = getRml(self);
        const start = self.buffer_pos;

        var int: Rml.Float = 0;
        var frac: Rml.Float = 0;
        var exp: Rml.Float = 0;

        const sign = try self.expectOptionalSign(Rml.Float) orelse {
            parsing.debug("parseFloat stop: no input", .{});
            return null;
        };

        var digits: usize = 0;

        while (try self.expectDecimalDigit()) |value| {
            int = int * 10 + @as(Rml.Float, @floatFromInt(value));
            digits += 1;
        }

        if (try self.expectChar('.')) {
            var fracDiv: Rml.Float = 1;

            while (try self.expectDecimalDigit()) |value| {
                frac = frac * 10 + @as(Rml.Float, @floatFromInt(value));
                fracDiv *= 10;
                digits += 1;
            }

            frac /= fracDiv;

            if (digits > 0) {
                if (try self.expectAnyChar(&.{ 'e', 'E' }) != null) {
                    const expSign = try self.require(Rml.Float, expectOptionalSign, .{Rml.Float});

                    while (try self.expectDecimalDigit()) |value| {
                        exp = exp * 10 + @as(Rml.Float, @floatFromInt(value));
                        digits += 1;
                    }

                    exp *= expSign;
                }
            }
        } else {
            parsing.debug("parseFloat reset: no frac", .{});
            self.reset(start);
            return null;
        }

        if (digits == 0) {
            parsing.debug("parseFloat reset: no digits", .{});
            self.reset(start);
            return null;
        }

        const result = try Rml.Obj(Float).wrap(rml, self.getOrigin(start, self.buffer_pos), (int + frac) * sign * std.math.pow(Rml.Float, 10.0, exp));

        parsing.debug("parseFloat result: {}", .{result});

        return result;
    }

    pub fn parseChar(self: *Parser) Error! ?Obj(Char) {
        parsing.debug("parseChar {?u}", .{self.peekChar() catch null});
        errdefer parsing.debug("parseChar failed", .{});

        const rml = getRml(self);
        const start = self.buffer_pos;

        if (!try self.expectChar('\'')) {
            parsing.debug("parseChar stop: expected '\''", .{});
            return null;
        }

        const ch = ch: {
            if (try self.peekChar()) |ch| {
                if (ch == '\\') {
                    break :ch try self.require(Char, expectEscape, .{});
                } else if (ch != '\'' and !TextUtils.isControl(ch)) {
                    try self.advChar();
                    break :ch ch;
                } else {
                    return error.UnexpectedInput;
                }
            } else {
                return error.UnexpectedEOF;
            }
        };

        if (!try self.expectChar('\'')) {
            parsing.debug("parseChar reset: expected '\''", .{});
            self.reset(start);
            return null;
        }

        const result: Obj(Char) = try .wrap(rml, self.getOrigin(start, self.buffer_pos), ch);

        parsing.debug("parseChar result: {}", .{result});

        return result;
    }

    pub fn parseString(self: *Parser) Error! ?Obj(String) {
        parsing.debug("parseString {?u}", .{self.peekChar() catch null});
        errdefer parsing.debug("parseString failed", .{});

        const rml = getRml(self);
        const start = self.buffer_pos;

        if (!try self.expectChar('"')) {
            parsing.debug("parseString stop: expected '\"'", .{});
            return null;
        }

        var textBuffer: Rml.string.StringUnmanaged = .{};

        while (try self.peekChar()) |ch| {
            if (ch == '"') {
                try self.advChar();

                parsing.debug("parseString result: {s}", .{textBuffer.text()});

                return try Obj(String).wrap(rml, self.getOrigin(start, self.buffer_pos), .{ .unmanaged = textBuffer });
            }

            const i =
                if (ch == '\\') try self.require(Char, expectEscape, .{})
                else if (!TextUtils.isControl(ch)) try self.nextChar() orelse return error.UnexpectedEOF
                else return error.UnexpectedInput;

            try textBuffer.append(rml, i);
        }

        return error.UnexpectedEOF;
    }

    pub fn parseSymbolic(self: *Parser) Error! ?Object {
        const sym = try self.parseSymbol() orelse return null;

        const BUILTIN_SYMS = .{
            .@"nil" = Rml.Nil{},
            .@"nan" = std.math.nan(Rml.Float),
            .@"inf" = std.math.inf(Rml.Float),
            .@"+inf" = std.math.inf(Rml.Float),
            .@"-inf" = -std.math.inf(Rml.Float),
            .@"true" = true,
            .@"false" = false,
        };

        inline for (comptime std.meta.fieldNames(@TypeOf(BUILTIN_SYMS))) |builtinSym| {
            if (std.mem.eql(u8, builtinSym, sym.data.str)) {
                const obj = try Rml.bindgen.toObjectConst(getRml(self), sym.getOrigin(), @field(BUILTIN_SYMS, builtinSym));

                return obj.typeErase();
            }
        }

        return sym.typeErase();
    }

    pub fn parseSymbol(self: *Parser) Error! ?Obj(Symbol) {
        const rml = getRml(self);

        const start = self.buffer_pos;

        while (try self.peekChar()) |ch| {
            switch (ch) {
                inline '(', ')', '[', ']', '{', '}', ';', ',', '#', '\'', '`', '"', '\\', => break,

                else => if (TextUtils.isSpace(ch) or TextUtils.isControl(ch)) break,
            }

            try self.advChar();
        }

        if (start.offset == self.buffer_pos.offset) {
            parsing.debug("parseSymbol reset: nothing recognized", .{});
            return null;
        }

        const result: Obj(Symbol) = try .wrap(rml, self.getOrigin(start, self.buffer_pos), try .create(rml, self.input.data.text()[start.offset..self.buffer_pos.offset]));

        parsing.debug("parseSymbol result: {s}", .{result});

        return result;
    }

    pub fn expectChar(self: *Parser, ch: Char) Error! bool {
        if (try self.peekChar() == ch) {
            try self.advChar();
            return true;
        }

        return false;
    }

    pub fn expectAnyChar(self: *Parser, chars: []const Char) Error! ?Char {
        if (try self.peekChar()) |ch| {
            for (chars) |c| {
                if (ch == c) {
                    try self.advChar();
                    return c;
                }
            }
        }

        return null;
    }

    pub fn expectAnySlice(self: *Parser, slices: []const []const u8) Error! ?[]const u8 {
        const start = self.buffer_pos;

        slices: for (slices) |slice| {
            for (slice) |ch| {
                if (try self.peekChar() != ch) {
                    self.reset(start);
                    continue :slices;
                }

                try self.advChar();
            }

            return slice;
        }

        return null;
    }

    pub fn expectSlice(self: *Parser, slice: []const u8) Error! bool {
        const start = self.buffer_pos;

        for (slice) |ch| {
            if (try self.peekChar() != ch) {
                self.reset(start);
                return false;
            }

            try self.advChar();
        }

        return true;
    }

    pub fn expectEscape(self: *Parser) Error! ?Char {
        const start = self.buffer_pos;

        if (!try self.expectChar('\\')) {
            return null;
        }

        if (try self.nextChar()) |ch| ch: {
            const x: Char = switch (ch) {
                '0' => '\x00',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                '"' => '"',
                '\'' => '\'',
                'e' => if (try self.expectSlice("sc")) '\x1b' else break :ch,
                else => break :ch,
            };

            return x;
        }

        self.reset(start);
        return null;
    }

    pub fn expectDecimalDigit(self: *Parser) Error! ?u8 {
        if (try self.peekChar()) |ch| {
            if (TextUtils.decimalValue(ch)) |value| {
                try self.advChar();
                return value;
            }
        }

        return null;
    }


    pub fn expectOptionalSign(self: *Parser, comptime T: type) Error! ?T {
        if (try self.peekChar()) |ch| {
            if (ch == '-') {
                try self.advChar();
                return -1;
            } else if (ch == '+') {
                try self.advChar();
            }

            return 1;
        }

        return null;
    }

    pub fn scan(self: *Parser) Error! ?PropertySet {
        const rml = getRml(self);
        var propertyState: union(enum) { none, start, inside: struct { []const u8, u32 } } = .none;

        var propertySet: PropertySet = .{};

        var start: Pos = undefined;

        while (try self.peekChar()) |ch| {
            switch (propertyState) {
                .none => if (ch == ';') {
                    propertyState = .start;
                    start = self.buffer_pos;
                    try self.advChar();
                } else if (TextUtils.isSpace(ch)) {
                    if (self.buffer_pos.indentation == 0 and self.buffer_pos.column == 0) {
                        try self.consumeIndent();
                    } else try self.advChar();
                } else {
                    break;
                },
                .start => if (ch == '!') {
                    propertyState = .{ .inside = .{ "documentation", self.buffer_pos.offset + 1 } };
                    try self.advChar();
                } else if (ch == '\n') {
                    propertyState = .none;
                    try self.advChar();
                } else {
                    propertyState = .{ .inside = .{ "comment", self.buffer_pos.offset } };
                    try self.advChar();
                },
                .inside => |state| {
                    if (ch == '\n') {
                        propertyState = .none;

                        const origin = self.getOrigin(start, self.buffer_pos);

                        const sym: Obj(Symbol) = try .wrap(rml, origin, try .create(rml, state[0]));
                        const string: Obj(String) = try .wrap(rml, origin, try .create(rml, self.input.data.text()[state[1]..self.buffer_pos.offset]));

                        // FIXME: this is overwriting, should concat
                        try propertySet.set(rml, sym.typeErase(), string.typeErase());
                    }

                    try self.advChar();
                },
            }
        }

        if (start.offset == self.buffer_pos.offset) return null;

        return propertySet;
    }

    pub fn reset(self: *Parser, pos: Pos) void {
        self.buffer_pos = pos;
        self.char_peek_cache = null;
    }

    pub fn failed(self: *Parser, origin: Origin, comptime fmt: []const u8, args: anytype) Error! noreturn {
        const err = if (self.isEof()) error.UnexpectedEOF else error.UnexpectedInput;

        const diagnostic = getRml(self).diagnostic orelse return err;

        var diag = Rml.Diagnostic {
            .error_origin = origin,
        };

        // the error produced is only NoSpaceLeft, if the buffer is too small, so give the length of the buffer
        diag.message_len = len: {
            break :len (std.fmt.bufPrintZ(&diag.message_mem, fmt, args) catch {
                parsing.warn("Diagnostic message too long, truncating", .{});
                break :len Rml.Diagnostic.MAX_LENGTH;
            }).len;
        };

        diagnostic.* = diag;

        return err;
    }

    pub fn require(self: *Parser, comptime T: type, callback: anytype, args: anytype) !T {
        return try @call(.auto, callback, .{self} ++ args) orelse {
            try self.failed(self.getOrigin(self.buffer_pos, self.buffer_pos), "failed to parse {s}", .{@typeName(T)});
        };
    }

    pub fn isBof(self: *Parser) bool {
        return self.buffer_pos.offset == 0;
    }

    pub fn isEof(self: *Parser) bool {
        return self.buffer_pos.offset >= self.input.data.text().len;
    }

    pub fn peekChar(self: *Parser) Error! ?Char {
        if (self.isEof()) {
            return null;
        }

        if (self.char_peek_cache) |ch| {
            return ch;
        } else {
            const len = try TextUtils.sequenceLengthByte(self.input.data.text()[self.buffer_pos.offset]);
            const slice = self.input.data.text()[self.buffer_pos.offset .. self.buffer_pos.offset + len];

            const ch = try TextUtils.decode(slice);
            self.char_peek_cache = ch;

            return ch;
        }
    }

    pub fn nextChar(self: *Parser) Error! ?Char {
        if (self.peek_cache != null) {
            parsing.err("Parser.nextChar: peek_cache is not null", .{});
            return error.Unexpected;
        }

        if (try self.peekChar()) |ch| {
            switch (ch) {
                '\n' => {
                    self.buffer_pos.line += 1;
                    self.buffer_pos.column = 0;
                    self.buffer_pos.offset += 1;
                    self.buffer_pos.indentation = 0;
                },

                else => {
                    self.buffer_pos.column += 1;
                    self.buffer_pos.offset += try TextUtils.sequenceLength(ch);
                },
            }

            self.char_peek_cache = null;

            return ch;
        } else {
            return null;
        }
    }

    pub fn advChar(self: *Parser) Error! void {
        _ = try self.nextChar();
    }

    pub fn consumeIndent(self: *Parser) Error! void {
        while (try self.peekChar()) |ch| {
            if (TextUtils.isSpace(ch)) {
                self.buffer_pos.indentation += 1;
                try self.advChar();
            } else {
                break;
            }
        }
    }
};


pub fn isIndentationDomain(start: Pos, pos: Pos) bool {
    log.debug("isIndentationDomain? {} {}", .{ start, pos });
    const value = ( pos.line == start.line
        and pos.column >= start.column
    ) or ( pos.line > start.line
        and pos.indentation > start.indentation
    );
    log.debug("isIndentationDomain: {}", .{ value });
    return value;
}

pub fn isSameLine(start: Pos, pos: Pos) bool {
    log.debug("isSameLine? {} {}", .{ start, pos });
    const value = pos.line == start.line;
    log.debug("isSameLine: {}", .{ value });
    return value;
}
