const Rml = @import("../Rml.zig");

const parser = @This();

const std = @import("std");
const utils = @import("utils");



pub const Parser = struct {
    input: Rml.Obj(Rml.String),
    filename: Rml.str,
    buffer_pos: Rml.Pos,
    rel_offset: Rml.Pos,
    obj_peek_cache: ?Rml.Object,
    char_peek_cache: ?Rml.Char,

    pub fn create(filename: Rml.str, input: Rml.Obj(Rml.String)) Parser {
        return .{
            .input = input,
            .filename = filename,
            .buffer_pos = Rml.Pos { .line = 0, .column = 0, .offset = 0, .indentation = 0 },
            .rel_offset = Rml.Pos { .line = 1, .column = 1, .offset = 0, .indentation = 0 },
            .obj_peek_cache = null,
            .char_peek_cache = null,
        };
    }

    pub fn onCompare(a: *const Parser, other: Rml.Object) utils.Ordering {
        var ord = utils.compare(Rml.getTypeId(a), other.getTypeId());

        if (ord == .Equal) {
            const b = Rml.forceObj(Parser, other);
            ord = utils.compare(@intFromPtr(a), @intFromPtr(b.data));
        }

        return ord;
    }

    pub fn onFormat(self: *const Parser, _: Rml.Format, writer: std.io.AnyWriter) anyerror! void {
        return writer.print("Parser{x}", .{@intFromPtr(self)});
    }

    pub fn peek(self: *Parser) Rml.Error! ?Rml.Object {
        return self.peekWith(&self.obj_peek_cache);
    }

    pub fn offsetPos(self: *Parser, pos: Rml.Pos) Rml.Pos {
        return .{
            .line = pos.line + self.rel_offset.line,
            .column = pos.column + self.rel_offset.column,
            .offset = pos.offset + self.rel_offset.offset,
            .indentation = pos.indentation + self.rel_offset.indentation,
        };
    }

    pub fn getOffsetPos(self: *Parser) Rml.Pos {
        return self.offsetPos(self.buffer_pos);
    }

    pub fn peekWith(self: *Parser, peek_cache: *?Rml.Object) Rml.Error! ?Rml.Object {
        if (peek_cache.*) |cachedObject| {
            Rml.log.parser.debug("peek: using cached object", .{});
            return cachedObject;
        }

        Rml.log.parser.debug("peek: parsing object", .{});

        const rml = Rml.getRml(self);

        var properties = try self.scan() orelse Rml.object.PropertySet{};

        if (try self.parseAnyBlockClosing()) {
            return null;
        }

        const obj = try self.parseObject() orelse return null;
        var it = properties.iterator();
        while (it.next()) |entry| {
            try obj.getHeader().properties.put(rml.blobAllocator(), entry.key_ptr.*, entry.value_ptr.*);
        }

        peek_cache.* = obj;

        return obj;
    }

    pub fn next(self: *Parser) Rml.Error! ?Rml.Object {
        return self.nextWith(&self.obj_peek_cache);
    }

    pub fn nextWith(self: *Parser, peek_cache: *?Rml.Object) Rml.Error! ?Rml.Object {
        const result = try self.peekWith(peek_cache) orelse return null;

        peek_cache.* = null;

        return result;
    }


    pub fn setOffset(self: *Parser, offset: Rml.Pos) void {
        self.rel_offset = offset;
    }

    pub fn clearOffset(self: *Parser) void {
        self.rel_offset = Rml.Pos { .line = 1, .column = 1, .offset = 0 };
    }

    pub fn getOrigin(self: *Parser, start: ?Rml.Pos, end: ?Rml.Pos) Rml.Origin {
        return self.getOffsetOrigin(
            if (start) |x| self.offsetPos(x) else null,
            if (end) |x| self.offsetPos(x) else null,
        );
    }

    pub fn getOffsetOrigin(self: *Parser, start: ?Rml.Pos, end: ?Rml.Pos) Rml.Origin {
        return Rml.Origin {
            .filename = self.filename,
            .range = Rml.Range { .start = start, .end = end },
        };
    }

    pub fn parseObject(self: *Parser) Rml.Error! ?Rml.Object {
        Rml.log.parser.debug("parseObject {?u}", .{self.peekChar() catch null});
        errdefer Rml.log.parser.debug("parseObject failed", .{});

        const result
             = try self.parseAtom()
        orelse if (try self.parseAnyBlock()) |x| x.typeErase() else null
        orelse if (try self.parseAnyQuote()) |x| x.typeErase() else null;

        Rml.log.parser.debug("parseObject result: {?}", .{result});

        return result;
    }

    pub fn parseAtom(self: *Parser) Rml.Error! ?Rml.Object {
        Rml.log.parser.debug("parseAtom", .{});
        errdefer Rml.log.parser.debug("parseAtom failed", .{});

        const result
             = (if (try self.parseInt()) |x| x.typeErase() else null)
        orelse (if (try self.parseFloat()) |x| x.typeErase() else null)
        orelse (if (try self.parseChar()) |x| x.typeErase() else null)
        orelse (if (try self.parseString()) |x| x.typeErase() else null)
        orelse try self.parseSymbolic();

        Rml.log.parser.debug("parseAtom result: {?}", .{result});

        return result;
    }

    pub fn parseQuote(self: *Parser, quoteKind: Rml.object.quote.QuoteKind) Rml.Error! ?Rml.Obj(Rml.Quote) {
        Rml.log.parser.debug("parseQuote", .{});
        errdefer Rml.log.parser.debug("parseQuote failed", .{});

        const rml = Rml.getRml(self);
        const start = self.buffer_pos;

        if (!try self.parseQuoteOpening(quoteKind)) {
            Rml.log.parser.debug("parseQuote stop: no quote kind", .{});
            return null;
        }

        const body = try self.parseObject() orelse
            try self.failed(self.getOrigin(self.buffer_pos, null),
                "expected an object to follow quote operator `{s}`", .{quoteKind.toStr()});

        const result: Rml.Obj(Rml.Quote) = try .wrap(rml, self.getOrigin(start, self.buffer_pos), .{ .kind = quoteKind, .body = body });

        Rml.log.parser.debug("parseQuote result: {?}", .{result});

        return result;
    }

    pub fn parseAnyQuote(self: *Parser) Rml.Error! ?Rml.Obj(Rml.Quote) {
        Rml.log.parser.debug("parseQuote", .{});
        errdefer Rml.log.parser.debug("parseQuote failed", .{});

        const rml = Rml.getRml(self);
        const start = self.buffer_pos;

        const quoteKind = try self.parseAnyQuoteOpening() orelse return null;

        Rml.log.parser.debug("got quote opening {s}", .{quoteKind.toStr()});

        const body = try self.parseObject() orelse
            try self.failed(self.getOrigin(self.buffer_pos, null),
                "expected an object to follow quote operator `{s}`", .{quoteKind.toStr()});

        const result: Rml.Obj(Rml.Quote) = try .wrap(rml, self.getOrigin(start, self.buffer_pos), .{ .kind = quoteKind, .body = body });

        Rml.log.parser.debug("parseQuote result: {?}", .{result});

        return result;
    }

    pub fn parseBlock(self: *Parser, blockKind: Rml.object.block.BlockKind) Rml.Error! ?Rml.Obj(Rml.Block) {
        Rml.log.parser.debug("parseBlock", .{});
        errdefer Rml.log.parser.debug("parseBlock failed", .{});

        const start = self.buffer_pos;

        if (!try self.parseBlockOpening(blockKind)) {
            return null;
        }

        const result = try self.parseBlockTail(start, blockKind);

        Rml.log.parser.debug("parseBlock result: {?}", .{result});

        return result;
    }

    pub fn parseAnyBlock(self: *Parser) Rml.Error! ?Rml.Obj(Rml.Block) {
        Rml.log.parser.debug("parseBlock", .{});
        errdefer Rml.log.parser.debug("parseBlock failed", .{});

        const start = self.buffer_pos;

        const blockKind = try self.parseAnyBlockOpening() orelse return null;

        Rml.log.parser.debug("got block opening {s}", .{blockKind.toOpenStr()});

        const result = try self.parseBlockTail(start, blockKind);

        Rml.log.parser.debug("parseBlock result: {?}", .{result});

        return result;
    }

    pub fn nextBlob(self: *Parser) Rml.Error! ?[]Rml.Object {
        return self.nextBlobWith(&self.obj_peek_cache);
    }

    pub fn nextBlobWith(self: *Parser, peekCache: *?Rml.Object) Rml.Error! ?[]Rml.Object {
        var blob: std.ArrayListUnmanaged(Rml.Object) = .{};

        const start = self.buffer_pos;

        const first = try self.peekWith(peekCache) orelse {
            return null;
        };

        var last = first.getOrigin().range.?.end.?;

        blob: while (next: {
            const nxt = try self.nextWith(peekCache);
            break :next nxt;
        }) |sourceExpr| {
            {
                try blob.append(Rml.getRml(self).blobAllocator(), sourceExpr);
            }

            const nxt: Rml.Object = try self.peekWith(peekCache) orelse break :blob;
            const range = nxt.getOrigin().range.?;

            if (!isIndentationDomain(start, last, range.start.?)) {
                break :blob;
            }

            last = range.end.?;
        }

        return try self.blobify(.same_indent, first.getOrigin().range.?.end.?, blob.items);
    }

    pub fn blobify(self: *Parser, heuristic: enum {same_indent, domain}, start: Rml.Pos, blob: []Rml.Object) Rml.Error! []Rml.Object {
        const end = blob[blob.len - 1].getOrigin().range.?.end.?;
        const blobOrigin = self.getOffsetOrigin(start, end);

        Rml.log.parser.debug("blobify: {any}", .{blob});

        var array: std.ArrayListUnmanaged(Rml.Object) = .{};

        var last = start;

        var i: usize = 0;
        for (blob) |item| {
            const range = item.getOrigin().range.?;

            switch (heuristic) {
                .same_indent => if (start.indentation != range.start.?.indentation) break,
                .domain => if (!isIndentationDomain(start, last, range.start.?)) break,
            }

            try array.append(Rml.getRml(self).blobAllocator(), item);
            last = range.end.?;
            i += 1;
        }

        Rml.log.parser.debug("scanned: {}", .{array});

        if (i == blob.len) {
            Rml.log.parser.debug("return blob", .{});
            return array.items;
        } else {
            const first = blob[i].getOrigin().range.?.start.?;

            const newBlob = try self.blobify(.domain, first, blob[i..]);

            Rml.log.parser.debug("new blob: {any}", .{newBlob});

            switch (heuristic) {
                .domain => {
                    const firstLine = try Rml.Obj(Rml.Block).wrap(Rml.getRml(self), blobOrigin, try .create(Rml.getRml(self), .doc, array.items));

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
                        Rml.log.parser.debug("concat", .{});
                        return std.mem.concat(Rml.getRml(self).blobAllocator(), Rml.Object, &.{&.{firstLine.typeErase()}, newBlob});
                    } else {
                        Rml.log.parser.debug("append first line, wrap", .{});
                        var newArr: std.ArrayListUnmanaged(Rml.Object) = .{};
                        try newArr.append(Rml.getRml(self).blobAllocator(), firstLine.typeErase());
                        try newArr.append(Rml.getRml(self).blobAllocator(), (try Rml.Obj(Rml.Block).wrap(Rml.getRml(self), blobOrigin, try .create(Rml.getRml(self), .doc, newBlob))).typeErase());

                        return newArr.items;
                    }
                },
                .same_indent => {
                    Rml.log.parser.debug("append", .{});
                    try array.append(Rml.getRml(self).blobAllocator(), (try Rml.Obj(Rml.Block).wrap(Rml.getRml(self), blobOrigin, try .create(Rml.getRml(self), .doc, newBlob))).typeErase());
                    return array.items;
                }
            }
        }
    }

    fn parseBlockTail(self: *Parser, start: Rml.Pos, blockKind: Rml.object.block.BlockKind) Rml.Error! Rml.Obj(Rml.Block) {
        const rml = Rml.getRml(self);

        var array: std.ArrayListUnmanaged(Rml.Object) = .{};

        var properties = try self.scan() orelse Rml.object.PropertySet{};

        var tailDeinit = true;
        var tailProperties: Rml.object.PropertySet = .{};

        var peekCache: ?Rml.Object = null;

        while (true) {
            if (self.isEof() and blockKind != .doc) {
                return error.UnexpectedEOF;
            }

            if (try self.parseBlockClosing(blockKind)) {
                tailProperties = try properties.clone(rml.blobAllocator());
                break;
            }

            {
                const blob = try self.nextBlobWith(&peekCache) orelse {
                    try self.failed(self.getOrigin(self.buffer_pos, null), "expected object", .{});
                };

                const blobOrigin = self.getOffsetOrigin(blob[0].getOrigin().range.?.start.?, blob[blob.len - 1].getOrigin().range.?.end.?);

                try array.append(rml.blobAllocator(), (try Rml.Obj(Rml.Block).wrap(Rml.getRml(self), blobOrigin, try .create(Rml.getRml(self), .doc, blob))).typeErase());
            }

            if (try self.scan()) |props| {
                properties = props;
            } else { // require whitespace between objects
                if (try self.parseBlockClosing(blockKind)) {
                    tailProperties = try properties.clone(rml.blobAllocator());
                    break;
                } else {
                    try self.failed(self.getOrigin(self.buffer_pos, null), "expected space or `{s}`", .{blockKind.toCloseStr()});
                }
            }
        }

        const origin = self.getOrigin(start, self.buffer_pos);

        const block: Rml.Obj(Rml.Block) = block: {
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

            break :block try .wrap(rml, origin, try .create(
                rml,
                blockKind,
                array.items,
            ));
        };

        if (tailProperties.count() > 0) {
            const sym: Rml.Obj(Rml.Symbol) = try .wrap(rml, origin, try .create(rml, "tail"));

            const map: Rml.Obj(Rml.Map) = try .wrap(rml, origin, .{ .allocator = rml.blobAllocator(), .native_map = @as(*Rml.Map.NativeMap, @ptrCast(&tailProperties)).* });
            tailDeinit = false;

            try block.getHeader().properties.put(rml.blobAllocator(), sym, map.typeErase());
        }

        return block;
    }

    pub fn parseQuoteOpening(self: *Parser, kind : Rml.object.quote.QuoteKind) Rml.Error! bool {
        const openStr = kind.toStr();

        std.debug.assert(!std.mem.eql(u8, openStr, ""));

        return try self.expectSlice(openStr);
    }

    pub fn parseAnyQuoteOpening(self: *Parser) Rml.Error! ?Rml.object.quote.QuoteKind {
        inline for (comptime std.meta.fieldNames(Rml.object.quote.QuoteKind)) |quoteKindName| {
            const quoteKind = @field(Rml.object.quote.QuoteKind, quoteKindName);
            const openStr = comptime quoteKind.toStr();

            if (comptime std.mem.eql(u8, openStr, "")) @compileError("QuoteKind." ++ quoteKindName ++ ".toStr() must not return an empty string");

            if (try self.expectSlice(openStr)) {
                Rml.log.parser.debug("got quote opening {s}", .{openStr});
                return quoteKind;
            }
        }

        return null;
    }

    pub fn parseBlockOpening(self: *Parser, kind: Rml.object.block.BlockKind) Rml.Error! bool {
        const openStr = kind.toOpenStr();

        if (std.mem.eql(u8, openStr, "")) {
            Rml.log.parser.debug("checking for bof", .{});
            const is = self.isBof();
            Rml.log.parser.debug("bof: {}", .{is});
            return is;
        } else {
            Rml.log.parser.debug("checking for {s}", .{openStr});
            const is = try self.expectSlice(openStr);
            Rml.log.parser.debug("{s}: {}", .{openStr, is});
            return is;
        }
    }

    pub fn parseAnyBlockOpening(self: *Parser) Rml.Error! ?Rml.object.block.BlockKind {
        inline for (comptime std.meta.fieldNames(Rml.object.block.BlockKind)) |blockKindName| {
            const blockKind = @field(Rml.object.block.BlockKind, blockKindName);
            const openStr = comptime blockKind.toOpenStr();

            if (comptime std.mem.eql(u8, openStr, "")) continue;

            if (try self.expectSlice(openStr)) {
                Rml.log.parser.debug("got block opening {s}", .{openStr});
                return blockKind;
            }
        }

        return null;
    }

    pub fn parseBlockClosing(self: *Parser, kind: Rml.object.block.BlockKind) Rml.Error! bool {
        const closeStr = kind.toCloseStr();

        if (std.mem.eql(u8, closeStr, "")) {
            Rml.log.parser.debug("checking for eof", .{});
            const is = self.isEof();
            Rml.log.parser.debug("eof: {}", .{is});
            return is;
        } else {
            Rml.log.parser.debug("checking for {s}", .{closeStr});
            const is = try self.expectSlice(closeStr);
            Rml.log.parser.debug("{s}: {}", .{closeStr, is});
            return is;
        }
    }

    pub fn parseAnyBlockClosing(self: *Parser) Rml.Error! bool {
        inline for (comptime std.meta.fieldNames(Rml.object.block.BlockKind)) |blockKindName| {
            const blockKind = @field(Rml.object.block.BlockKind, blockKindName);
            const closeStr = comptime blockKind.toCloseStr();

            if (comptime std.mem.eql(u8, closeStr, "")) {
                Rml.log.parser.debug("checking for eof", .{});
                const is = self.isEof();
                Rml.log.parser.debug("eof: {}", .{is});
                return is;
            } else {
                Rml.log.parser.debug("checking for {s}", .{closeStr});
                const is = try self.expectSlice(closeStr);
                Rml.log.parser.debug("{s}: {}", .{closeStr, is});
                return is;
            }
        }
    }

    pub fn parseInt(self: *Parser) Rml.Error! ?Rml.Obj(Rml.Int) {
        Rml.log.parser.debug("parseInt {?u}", .{self.peekChar() catch null});
        errdefer Rml.log.parser.debug("parseInt failed", .{});

        const rml = Rml.getRml(self);
        const start = self.buffer_pos;

        var int: Rml.Int = 0;

        const sign = try self.expectOptionalSign(Rml.Int) orelse {
            Rml.log.parser.debug("parseInt stop: no input", .{});
            return null;
        };

        var digits: usize = 0;

        while (try self.expectDecimalDigit()) |value| {
            int = int * 10 + value;
            digits += 1;
        }

        if (digits == 0) {
            Rml.log.parser.debug("parseInt reset: no digits", .{});
            self.reset(start);
            return null;
        }

        const result: Rml.Obj(Rml.Int) = try .wrap(rml, self.getOrigin(start, self.buffer_pos), int * sign);

        Rml.log.parser.debug("parseInt result: {}", .{result});

        return result;
    }

    pub fn parseFloat(self: *Parser) Rml.Error! ?Rml.Obj(Rml.Float) {
        Rml.log.parser.debug("parseFloat {?u}", .{self.peekChar() catch null});
        errdefer Rml.log.parser.debug("parseFloat failed", .{});

        const rml = Rml.getRml(self);
        const start = self.buffer_pos;

        var int: Rml.Float = 0;
        var frac: Rml.Float = 0;
        var exp: Rml.Float = 0;

        const sign = try self.expectOptionalSign(Rml.Float) orelse {
            Rml.log.parser.debug("parseFloat stop: no input", .{});
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
            Rml.log.parser.debug("parseFloat reset: no frac", .{});
            self.reset(start);
            return null;
        }

        if (digits == 0) {
            Rml.log.parser.debug("parseFloat reset: no digits", .{});
            self.reset(start);
            return null;
        }

        const result = try Rml.Obj(Rml.Float).wrap(rml, self.getOrigin(start, self.buffer_pos), (int + frac) * sign * std.math.pow(Rml.Float, 10.0, exp));

        Rml.log.parser.debug("parseFloat result: {}", .{result});

        return result;
    }

    pub fn parseChar(self: *Parser) Rml.Error! ?Rml.Obj(Rml.Char) {
        Rml.log.parser.debug("parseChar {?u}", .{self.peekChar() catch null});
        errdefer Rml.log.parser.debug("parseChar failed", .{});

        const rml = Rml.getRml(self);
        const start = self.buffer_pos;

        if (!try self.expectChar('\'')) {
            Rml.log.parser.debug("parseChar stop: expected '\''", .{});
            return null;
        }

        const ch = ch: {
            if (try self.peekChar()) |ch| {
                if (ch == '\\') {
                    break :ch try self.require(Rml.Char, expectEscape, .{});
                } else if (ch != '\'' and !utils.text.isControl(ch)) {
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
            Rml.log.parser.debug("parseChar reset: expected '\''", .{});
            self.reset(start);
            return null;
        }

        const result: Rml.Obj(Rml.Char) = try .wrap(rml, self.getOrigin(start, self.buffer_pos), ch);

        Rml.log.parser.debug("parseChar result: {}", .{result});

        return result;
    }

    pub fn parseString(self: *Parser) Rml.Error! ?Rml.Obj(Rml.String) {
        Rml.log.parser.debug("parseString {?u}", .{self.peekChar() catch null});
        errdefer Rml.log.parser.debug("parseString failed", .{});

        const rml = Rml.getRml(self);
        const start = self.buffer_pos;

        if (!try self.expectChar('"')) {
            Rml.log.parser.debug("parseString stop: expected '\"'", .{});
            return null;
        }

        var textBuffer: Rml.String = try .create(rml, "");

        while (try self.peekChar()) |ch| {
            if (ch == '"') {
                try self.advChar();

                Rml.log.parser.debug("parseString result: {s}", .{textBuffer.text()});

                return try Rml.Obj(Rml.String).wrap(rml, self.getOrigin(start, self.buffer_pos), textBuffer);
            }

            const i =
                if (ch == '\\') try self.require(Rml.Char, expectEscape, .{})
                else if (!utils.text.isControl(ch)) try self.nextChar() orelse return error.UnexpectedEOF
                else return error.UnexpectedInput;

            try textBuffer.append(i);
        }

        return error.UnexpectedEOF;
    }

    pub fn parseSymbolic(self: *Parser) Rml.Error! ?Rml.Object {
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
                const obj = try Rml.bindgen.toObjectConst(Rml.getRml(self), sym.getOrigin(), @field(BUILTIN_SYMS, builtinSym));

                return obj.typeErase();
            }
        }

        return sym.typeErase();
    }

    pub fn parseSymbol(self: *Parser) Rml.Error! ?Rml.Obj(Rml.Symbol) {
        const rml = Rml.getRml(self);

        const start = self.buffer_pos;

        while (try self.peekChar()) |ch| {
            switch (ch) {
                inline '(', ')', '[', ']', '{', '}', ';', ',', '#', '\'', '`', '"', '\\', => break,

                else => if (utils.text.isSpace(ch) or utils.text.isControl(ch)) break,
            }

            try self.advChar();
        }

        if (start.offset == self.buffer_pos.offset) {
            Rml.log.parser.debug("parseSymbol reset: nothing recognized", .{});
            return null;
        }

        const result: Rml.Obj(Rml.Symbol) = try .wrap(rml, self.getOrigin(start, self.buffer_pos), try .create(rml, self.input.data.text()[start.offset..self.buffer_pos.offset]));

        Rml.log.parser.debug("parseSymbol result: {s}", .{result});

        return result;
    }

    pub fn expectChar(self: *Parser, ch: Rml.Char) Rml.Error! bool {
        if (try self.peekChar() == ch) {
            try self.advChar();
            return true;
        }

        return false;
    }

    pub fn expectAnyChar(self: *Parser, chars: []const Rml.Char) Rml.Error! ?Rml.Char {
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

    pub fn expectAnySlice(self: *Parser, slices: []const []const u8) Rml.Error! ?[]const u8 {
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

    pub fn expectSlice(self: *Parser, slice: []const u8) Rml.Error! bool {
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

    pub fn expectEscape(self: *Parser) Rml.Error! ?Rml.Char {
        const start = self.buffer_pos;

        if (!try self.expectChar('\\')) {
            return null;
        }

        if (try self.nextChar()) |ch| ch: {
            const x: Rml.Char = switch (ch) {
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

    pub fn expectDecimalDigit(self: *Parser) Rml.Error! ?u8 {
        if (try self.peekChar()) |ch| {
            if (utils.text.decimalValue(ch)) |value| {
                try self.advChar();
                return value;
            }
        }

        return null;
    }


    pub fn expectOptionalSign(self: *Parser, comptime T: type) Rml.Error! ?T {
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

    pub fn scan(self: *Parser) Rml.Error! ?Rml.object.PropertySet {
        const rml = Rml.getRml(self);
        var propertyState: union(enum) { none, start, inside: struct { []const u8, u32 } } = .none;

        var propertySet: Rml.object.PropertySet = .{};

        var start: Rml.Pos = undefined;

        while (try self.peekChar()) |ch| {
            switch (propertyState) {
                .none => if (ch == ';') {
                    propertyState = .start;
                    start = self.buffer_pos;
                    try self.advChar();
                } else if (utils.text.isSpace(ch)) {
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

                        const sym: Rml.Obj(Rml.Symbol) = try .wrap(rml, origin, try .create(rml, state[0]));
                        const string: Rml.Obj(Rml.String) = try .wrap(rml, origin, try .create(rml, self.input.data.text()[state[1]..self.buffer_pos.offset]));

                        // FIXME: this is overwriting, should concat
                        try propertySet.put(rml.blobAllocator(), sym, string.typeErase());
                    }

                    try self.advChar();
                },
            }
        }

        if (start.offset == self.buffer_pos.offset) return null;

        return propertySet;
    }

    pub fn reset(self: *Parser, pos: Rml.Pos) void {
        self.buffer_pos = pos;
        self.char_peek_cache = null;
    }

    pub fn failed(self: *Parser, origin: Rml.Origin, comptime fmt: []const u8, args: anytype) Rml.Error! noreturn {
        const err = if (self.isEof()) error.UnexpectedEOF else error.UnexpectedInput;

        const diagnostic = Rml.getRml(self).diagnostic orelse return err;

        var diag = Rml.Diagnostic {
            .error_origin = origin,
        };

        // the error produced is only NoSpaceLeft, if the buffer is too small, so give the length of the buffer
        diag.message_len = len: {
            break :len (std.fmt.bufPrintZ(&diag.message_mem, fmt, args) catch {
                Rml.log.parser.warn("Diagnostic message too long, truncating", .{});
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

    pub fn peekChar(self: *Parser) Rml.Error! ?Rml.Char {
        if (self.isEof()) {
            return null;
        }

        if (self.char_peek_cache) |ch| {
            return ch;
        } else {
            const len = try utils.text.sequenceLengthByte(self.input.data.text()[self.buffer_pos.offset]);
            const slice = self.input.data.text()[self.buffer_pos.offset .. self.buffer_pos.offset + len];

            const ch = try utils.text.decode(slice);
            self.char_peek_cache = ch;

            return ch;
        }
    }

    pub fn nextChar(self: *Parser) Rml.Error! ?Rml.Char {
        if (self.obj_peek_cache != null) {
            Rml.log.parser.err("Parser.nextChar: peek_cache is not null", .{});
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
                    self.buffer_pos.offset += try utils.text.sequenceLength(ch);
                },
            }

            self.char_peek_cache = null;

            return ch;
        } else {
            return null;
        }
    }

    pub fn advChar(self: *Parser) Rml.Error! void {
        _ = try self.nextChar();
    }

    pub fn consumeIndent(self: *Parser) Rml.Error! void {
        while (try self.peekChar()) |ch| {
            if (utils.text.isSpace(ch)) {
                self.buffer_pos.indentation += 1;
                try self.advChar();
            } else {
                break;
            }
        }
    }
};


pub fn isIndentationDomain(start: Rml.Pos, last: Rml.Pos, pos: Rml.Pos) bool {
    Rml.log.parser.debug("isIndentationDomain? {} {}", .{ start, pos });
    const value = ( pos.line == start.line
        and pos.column >= start.column
    ) or ( pos.line > start.line
        and pos.indentation > start.indentation
    ) or ( pos.line > start.line
        and pos.indentation >= start.indentation
        and last.line == pos.line
    );
    Rml.log.parser.debug("isIndentationDomain: {}", .{ value });
    return value;
}

pub fn isSameLine(start: Rml.Pos, pos: Rml.Pos) bool {
    Rml.log.parser.debug("isSameLine? {} {}", .{ start, pos });
    const value = pos.line == start.line;
    Rml.log.parser.debug("isSameLine: {}", .{ value });
    return value;
}
