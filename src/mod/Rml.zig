const Rml = @This();

const std = @import("std");
const utils = @import("utils");

pub const log = struct {
    pub usingnamespace std.log.scoped(.rml);
    pub const interpreter = std.log.scoped(.@"rml/interpreter");
    pub const parser = std.log.scoped(.@"rml/parser");
    pub const match = std.log.scoped(.@"rml/match");
};

test {
    std.testing.refAllDeclsRecursive(@This());
}

// Rml type

data: Storage,
cwd: ?std.fs.Dir,
out: ?std.io.AnyWriter,
namespace_env: Obj(Env) = undefined,
global_env: Obj(Env) = undefined,
main_interpreter: Obj(Interpreter) = undefined,
diagnostic: ?*?Diagnostic = null,

/// caller must close cwd and out
pub fn init(allocator: std.mem.Allocator, cwd: ?std.fs.Dir, out: ?std.io.AnyWriter, diagnostic: ?*?Diagnostic, args: []const []const u8) OOM!*Rml {
    const self = try allocator.create(Rml);
    errdefer allocator.destroy(self);

    self.* = Rml{
        .data = try Storage.init(allocator),
        .cwd = cwd,
        .out = out,
        .diagnostic = diagnostic,
    };
    errdefer self.data.deinit();

    self.data.origin = try Origin.fromStr(self, "system");

    log.debug("initializing interpreter ...", .{});

    self.global_env = try Obj(Env).wrap(self, self.data.origin, .{ .allocator = self.data.permanent.allocator() });
    self.namespace_env = try Obj(Env).wrap(self, self.data.origin, .{ .allocator = self.data.permanent.allocator() });

    bindgen.bindObjectNamespaces(self, self.namespace_env, builtin.types) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => @panic(@errorName(err)),
    };

    bindgen.bindObjectNamespaces(self, self.namespace_env, builtin.namespaces) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => @panic(@errorName(err)),
    };

    bindgen.bindGlobals(self, self.global_env, builtin.global) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => @panic(@errorName(err)),
    };

    // TODO args
    _ = args;

    if (Obj(Interpreter).wrap(self, self.data.origin, try .create(self))) |x| {
        log.debug("... interpreter ready", .{});
        self.main_interpreter = x;
        return self;
    } else |err| {
        log.err("... failed to initialize interpreter", .{});
        return err;
    }
}

pub fn deinit(self: *Rml) MemoryLeak!void {
    log.debug("deinitializing Rml", .{});

    self.data.deinit();

    self.data.long_term.destroy(self);
}

pub fn expectedOutput(self: *Rml, comptime fmt: []const u8, args: anytype) void {
    if (self.out) |out| {
        log.info(fmt, args);
        out.print(fmt ++ "\n", args) catch @panic("failed to write to host-provided out");
    }
}

pub fn beginBlob(self: *Rml) void {
    log.debug("beginBlob", .{});
    self.data.beginBlob();
}

pub fn endBlob(self: *Rml) Blob {
    log.debug("endBlob", .{});
    return self.data.endBlob();
}

pub fn blobId(self: *Rml) BlobId {
    return self.data.blobId();
}

pub fn blobAllocator(self: *Rml) std.mem.Allocator {
    return self.data.blobAllocator();
}

// TODO run
pub fn runString(self: *Rml, fileName: []const u8, text: []const u8) Error!Object {
    log.info("running [{s}] ...", .{fileName});
    const result = try utils.todo(noreturn, .{ self, text });
    log.info("... finished [{s}], result: {}", .{ fileName, result });

    return result;
}

pub fn runFile(self: *Rml, fileName: []const u8) Error!Object {
    const src = try self.readFile(fileName);

    return self.runString(fileName, src);
}

pub fn readFile(self: *Rml, fileName: []const u8) Error![]const u8 {
    log.info("reading [{s}] ...", .{fileName});
    return if (self.data.read_file_callback) |cb| try cb(self, fileName) else error.AccessDenied;
}

pub fn errorCast(err: anyerror) Error {
    if (utils.types.narrowErrorSet(Error, err)) |e| {
        return e;
    } else {
        log.err("unexpected error in errorCast: {s}", .{@errorName(err)});
        return error.Unexpected;
    }
}

pub fn lookupNamespace(sym: Obj(Symbol)) ?Object {
    return sym.getRml().namespace_env.data.get(sym);
}

// Rml module

pub const Result = Signal || Error;
pub const Error = IOError || OOM || EvalError || SyntaxError || Unexpected;
pub const Signal = error{Cancel};

pub const EvalError = error{
    Panic,
    TypeError,
    PatternFailed,
    UnboundSymbol,
    SymbolAlreadyBound,
    InvalidArgumentCount,
};

pub const SyntaxError = error{
    Sentinel,
    UnexpectedInput,
    UnexpectedEOF,
    BadEncoding,
};

pub fn isSyntaxError(err: anyerror) bool {
    return utils.types.isInErrorSet(SyntaxError, err);
}

pub const OOM = error{OutOfMemory};
pub const MemoryLeak = error{MemoryLeak};
pub const Unexpected = error{Unexpected};

pub const SymbolError = UnboundSymbol || SymbolAlreadyBound;
pub const UnboundSymbol = error{UnboundSymbol};
pub const SymbolAlreadyBound = error{SymbolAlreadyBound};

pub const IOError = utils.IOError;

pub const Nil = extern struct {
    pub fn onFormat(_: *Nil, _: Format, w: std.io.AnyWriter) anyerror!void {
        return w.print("nil", .{});
    }

    pub fn onCompare(_: *Nil, other: Object) std.math.Order {
        return utils.compare(TypeId.of(Nil), other.getTypeId());
    }
};
pub const Bool = bool;
pub const Int = i64;
pub const Float = f64;
pub const Char = utils.text.Char;

pub const str = []const u8;

pub const NativeFunction = bindgen.NativeFunction;

pub fn blobOrigin(blob: []const Object) Origin {
    if (blob.len == 0) return Origin{ .filename = "system" };

    var origin = blob[0].getOrigin();

    for (blob[1..]) |obj| {
        origin = origin.merge(obj.getOrigin()) orelse return Origin{ .filename = "multiple" };
    }

    return origin;
}

pub const Origin = struct {
    filename: []const u8,
    range: ?Range = null,

    pub fn merge(self: Origin, other: Origin) ?Origin {
        return if (std.mem.eql(u8, self.filename, other.filename)) Origin{
            .filename = self.filename,
            .range = rangeMerge(self.range, other.range),
        } else null;
    }

    pub fn fromStr(rml: *Rml, s: []const u8) OOM!Origin {
        return Origin{ .filename = try rml.data.intern(s) };
    }

    pub fn fromComptimeStr(comptime s: []const u8) Origin {
        return Origin{ .filename = s };
    }

    pub fn fromComptimeFmt(comptime fmt: []const u8, comptime args: anytype) Origin {
        return Origin{ .filename = comptime std.fmt.comptimePrint(fmt, args) };
    }

    pub fn compare(self: Origin, other: Origin) std.math.Order {
        var res = utils.compare(self.filename, other.filename);

        if (res == .eq) {
            res = utils.compare(self.range, other.range);
        }

        return res;
    }

    pub fn format(self: *const Origin, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
        try writer.print("[{s}", .{self.filename});

        if (self.range) |range| {
            try writer.print(":{" ++ fmt ++ "}", .{range});
        }

        try writer.print("]", .{});
    }

    pub fn hashWith(self: Origin, hasher: anytype) void {
        utils.hashWith(hasher, self.filename);
        utils.hashWith(hasher, self.range);
    }
};

pub fn rangeMerge(a: ?Range, b: ?Range) ?Range {
    if (a == null or b == null) return null;
    const x = a.?;
    const y = b.?;
    return Range{
        .start = posMin(x.start, y.start),
        .end = posMax(x.end, y.end),
    };
}

pub fn posMin(a: ?Pos, b: ?Pos) ?Pos {
    if (a == null) return b;
    if (b == null) return a;
    return if (a.?.offset < b.?.offset) a else b;
}

pub fn posMax(a: ?Pos, b: ?Pos) ?Pos {
    if (a == null) return b;
    if (b == null) return a;
    return if (a.?.offset > b.?.offset) a else b;
}

pub const Range = struct {
    start: ?Pos = null,
    end: ?Pos = null,

    pub fn compare(self: Range, other: Range) std.math.Order {
        var res = utils.compare(self.start, other.start);

        if (res == .eq) {
            res = utils.compare(self.end, other.end);
        }

        return res;
    }

    pub fn format(self: *const Range, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
        const g = "{" ++ fmt ++ "}";

        if (self.start) |start| {
            try writer.print(g, .{start});
            if (self.end) |end| {
                if (start.line == end.line and !std.mem.eql(u8, fmt, "offset")) {
                    try writer.print("-{}", .{end.column});
                } else {
                    try writer.print(" to " ++ g, .{end});
                }
            }
        } else if (self.end) |end| {
            try writer.print("?-" ++ g, .{end});
        } else {
            try writer.print("?-?", .{});
        }
    }

    pub fn hashWith(self: Range, hasher: anytype) void {
        utils.hashWith(hasher, self.start);
        utils.hashWith(hasher, self.end);
    }
};

pub const Pos = struct {
    line: u32 = 0,
    column: u32 = 0,
    offset: u32 = 0,
    indentation: u32 = 0,

    pub fn compare(self: Pos, other: Pos) std.math.Order {
        return utils.compare(self.offset, other.offset);
    }

    pub fn format(self: *const Pos, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
        try writer.print("{d}:{d}", .{ self.line, self.column });
    }

    pub fn hashWith(self: Pos, hasher: anytype) void {
        utils.hashWith(hasher, self.offset);
    }

    pub fn isIndentationDomain(start: Pos, last: Pos, pos: Pos) bool {
        log.parser.debug("isIndentationDomain? {} {}", .{ start, pos });
        const value = (pos.line == start.line and pos.column >= start.column) or (pos.line > start.line and pos.indentation > start.indentation) or (pos.line > start.line and pos.indentation >= start.indentation and last.line == pos.line);
        log.parser.debug("isIndentationDomain: {}", .{value});
        return value;
    }

    pub fn isSameLine(start: Pos, pos: Pos) bool {
        log.parser.debug("isSameLine? {} {}", .{ start, pos });
        const value = pos.line == start.line;
        log.parser.debug("isSameLine: {}", .{value});
        return value;
    }
};

pub const ARENA_RETAIN_AMOUNT = 1024 * 1024 * 16;
const InternerMap = std.ArrayHashMapUnmanaged([]const u8, void, utils.SimpleHashContext, true);

pub const Blob = struct {
    arena: std.heap.ArenaAllocator,
    id: BlobId,

    pub fn deinit(self: Blob) void {
        self.arena.deinit();
    }
};

pub const BlobId = enum(usize) {
    pre_blob = 0,
    _,
};

const GenSym = enum(usize) {
    _,

    pub fn format(self: GenSym, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
        try writer.print("#{}", .{@intFromEnum(self)});
    }
};

pub const Storage = struct {
    long_term: std.mem.Allocator,
    map: InternerMap,
    permanent: std.heap.ArenaAllocator,
    blob: ?Blob = null,
    _fresh: usize = 0,
    /// callback may use rml.storage.blob for return allocator, or user must handle memory management
    read_file_callback: ?*const fn (rml: *Rml, []const u8) (IOError || OOM)![]const u8 = null,
    userstate: *anyopaque = undefined,
    origin: Origin = undefined,

    pub fn init(long_term: std.mem.Allocator) OOM!Storage {
        return .{
            .long_term = long_term,
            .map = .{},
            .permanent = std.heap.ArenaAllocator.init(long_term),
        };
    }

    pub fn blobId(self: *Storage) BlobId {
        return if (self.blob) |*b| b.id else .pre_blob;
    }

    pub fn blobAllocator(self: *Storage) std.mem.Allocator {
        return if (self.blob) |*b| b.arena.allocator() else self.permanent.allocator();
    }

    pub fn beginBlob(self: *Storage) void {
        std.debug.assert(self.blob == null);

        self.blob = .{
            .arena = std.heap.ArenaAllocator.init(self.long_term),
            .id = self.fresh(BlobId),
        };
    }

    pub fn endBlob(self: *Storage) Blob {
        if (self.blob) |b| {
            self.blob = null;
            return b;
        } else unreachable;
    }

    pub fn deinit(self: *Storage) void {
        self.map.deinit(self.long_term);
        if (self.blob) |*b| b.deinit();
        self.permanent.deinit();
    }

    pub fn fresh(self: *Storage, comptime T: type) T {
        const i = self._fresh;
        self._fresh += 1;
        return @enumFromInt(i);
    }

    pub fn internerLength(self: *const Storage) usize {
        return self.map.count();
    }

    pub fn contents(self: *const Storage) []str {
        return self.map.keys();
    }

    pub fn contains(self: *const Storage, key: []const u8) bool {
        return self.map.contains(key);
    }

    pub fn internNoAlloc(self: *const Storage, key: []const u8) ?str {
        if (self.map.getEntry(key)) |existing| {
            return existing.key_ptr.*;
        }
        return null;
    }

    pub fn intern(self: *Storage, key: []const u8) OOM!str {
        return self.internNoAlloc(key) orelse {
            const ownedKey = try self.permanent.allocator().dupe(u8, key);
            try self.map.put(self.long_term, ownedKey, {});

            return ownedKey;
        };
    }

    pub fn gensym(self: *Storage, origin: Origin) OOM!str {
        const key = try std.fmt.allocPrint(self.permanent.allocator(), "{s}/{}", .{ origin.filename, self.fresh(GenSym) });
        std.debug.assert(!self.map.contains(key));
        try self.map.put(self.long_term, key, {});
        return key;
    }
};

pub const TypeId = struct {
    typename: [*:0]const u8,

    pub fn of(comptime T: type) TypeId {
        return TypeId{ .typename = bindgen.fmtNativeType(T) };
    }

    pub fn name(self: TypeId) []const u8 {
        return std.mem.span(self.typename);
    }

    pub fn format(self: TypeId, comptime _: []const u8, _: std.fmt.FormatOptions, w: anytype) anyerror!void {
        try w.print("{s}", .{self.name()});
    }
};

pub const Diagnostic = struct {
    pub const MAX_LENGTH = 256;

    error_origin: Origin,

    message_len: usize = 0,
    message_mem: [MAX_LENGTH]u8 = std.mem.zeroes([MAX_LENGTH]u8),

    pub fn formatter(self: Diagnostic, err: ?anyerror) Formatter {
        return .{
            .err = err,
            .diag = self,
        };
    }

    pub const Formatter = struct {
        err: ?anyerror,
        diag: Diagnostic,

        pub fn log(self: Formatter, logger: anytype) void {
            if (self.err) |err| {
                logger.err("{s} {}: {s}", .{ @errorName(err), self.diag.error_origin, self.diag.message_mem[0..self.diag.message_len] });
            } else {
                logger.err("{}: {s}", .{ self.diag.error_origin, self.diag.message_mem[0..self.diag.message_len] });
            }
        }

        pub fn format(self: Formatter, comptime _: []const u8, _: std.fmt.FormatOptions, w: anytype) anyerror!void {
            if (self.err) |err| {
                return w.print("{s} {}: {s}", .{ @errorName(err), self.diag.error_origin, self.diag.message_mem[0..self.diag.message_len] });
            } else {
                return w.print("{}: {s}", .{ self.diag.error_origin, self.diag.message_mem[0..self.diag.message_len] });
            }
        }
    };
};

pub const Format = enum {
    debug,
    message,
    source,

    pub fn fromSymbol(s: Obj(Symbol)) ?Format {
        return Format.fromStr(s.data.text());
    }

    pub fn fromStr(s: []const u8) ?Format {
        if (std.mem.eql(u8, s, "debug")) {
            return .debug;
        } else if (std.mem.eql(u8, s, "message")) {
            return .message;
        } else if (std.mem.eql(u8, s, "source")) {
            return .source;
        } else {
            return null;
        }
    }

    pub fn slice(buf: anytype) Slice(@typeInfo(@TypeOf(buf)).pointer.child) {
        return .{ .buf = buf };
    }

    pub fn Slice(comptime T: type) type {
        return struct {
            const Self = @This();

            buf: []const T,

            pub fn onFormat(self: *const Self, fmt: Format, writer: std.io.AnyWriter) anyerror!void {
                for (self.buf) |item| {
                    try item.onFormat(fmt, writer);
                }
            }

            pub fn format(self: *const Self, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
                for (self.buf) |item| {
                    try item.format(fmt, .{}, writer);
                }
            }
        };
    }
};

pub const Parser = struct {
    input: Obj(String),
    filename: str,
    buffer_pos: Pos,
    rel_offset: Pos,
    obj_peek_cache: ?Object,
    char_peek_cache: ?Char,

    pub fn create(filename: str, input: Obj(String)) Parser {
        return .{
            .input = input,
            .filename = filename,
            .buffer_pos = Pos{ .line = 0, .column = 0, .offset = 0, .indentation = 0 },
            .rel_offset = Pos{ .line = 1, .column = 1, .offset = 0, .indentation = 0 },
            .obj_peek_cache = null,
            .char_peek_cache = null,
        };
    }

    pub fn onCompare(a: *const Parser, other: Object) std.math.Order {
        var ord = utils.compare(getTypeId(a), other.getTypeId());

        if (ord == .eq) {
            const b = forceObj(Parser, other);
            ord = utils.compare(@intFromPtr(a), @intFromPtr(b.data));
        }

        return ord;
    }

    pub fn onFormat(self: *const Parser, _: Format, writer: std.io.AnyWriter) anyerror!void {
        return writer.print("Parser{x}", .{@intFromPtr(self)});
    }

    pub fn peek(self: *Parser) Error!?Object {
        return self.peekWith(&self.obj_peek_cache);
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

    pub fn peekWith(self: *Parser, peek_cache: *?Object) Error!?Object {
        if (peek_cache.*) |cachedObject| {
            log.parser.debug("peek: using cached object", .{});
            return cachedObject;
        }

        log.parser.debug("peek: parsing object", .{});

        const rml = getRml(self);

        var properties = try self.scan() orelse PropertySet{};

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

    pub fn next(self: *Parser) Error!?Object {
        return self.nextWith(&self.obj_peek_cache);
    }

    pub fn nextWith(self: *Parser, peek_cache: *?Object) Error!?Object {
        const result = try self.peekWith(peek_cache) orelse return null;

        peek_cache.* = null;

        return result;
    }

    pub fn setOffset(self: *Parser, offset: Pos) void {
        self.rel_offset = offset;
    }

    pub fn clearOffset(self: *Parser) void {
        self.rel_offset = Pos{ .line = 1, .column = 1, .offset = 0 };
    }

    pub fn getOrigin(self: *Parser, start: ?Pos, end: ?Pos) Origin {
        return self.getOffsetOrigin(
            if (start) |x| self.offsetPos(x) else null,
            if (end) |x| self.offsetPos(x) else null,
        );
    }

    pub fn getOffsetOrigin(self: *Parser, start: ?Pos, end: ?Pos) Origin {
        return Origin{
            .filename = self.filename,
            .range = Range{ .start = start, .end = end },
        };
    }

    pub fn parseObject(self: *Parser) Error!?Object {
        log.parser.debug("parseObject {?u}", .{self.peekChar() catch null});
        errdefer log.parser.debug("parseObject failed", .{});

        const result = try self.parseAtom() orelse if (try self.parseAnyBlock()) |x| x.typeErase() else null orelse if (try self.parseAnyQuote()) |x| x.typeErase() else null;

        log.parser.debug("parseObject result: {?}", .{result});

        return result;
    }

    pub fn parseAtom(self: *Parser) Error!?Object {
        log.parser.debug("parseAtom", .{});
        errdefer log.parser.debug("parseAtom failed", .{});

        const result = (if (try self.parseInt()) |x| x.typeErase() else null) orelse (if (try self.parseFloat()) |x| x.typeErase() else null) orelse (if (try self.parseChar()) |x| x.typeErase() else null) orelse (if (try self.parseString()) |x| x.typeErase() else null) orelse try self.parseSymbolic();

        log.parser.debug("parseAtom result: {?}", .{result});

        return result;
    }

    pub fn parseQuote(self: *Parser, quoteKind: QuoteKind) Error!?Obj(Quote) {
        log.parser.debug("parseQuote", .{});
        errdefer log.parser.debug("parseQuote failed", .{});

        const rml = getRml(self);
        const start = self.buffer_pos;

        if (!try self.parseQuoteOpening(quoteKind)) {
            log.parser.debug("parseQuote stop: no quote kind", .{});
            return null;
        }

        const body = try self.parseObject() orelse
            try self.failed(self.getOrigin(self.buffer_pos, null), "expected an object to follow quote operator `{s}`", .{quoteKind.toStr()});

        const result: Obj(Quote) = try .wrap(rml, self.getOrigin(start, self.buffer_pos), .{ .kind = quoteKind, .body = body });

        log.parser.debug("parseQuote result: {?}", .{result});

        return result;
    }

    pub fn parseAnyQuote(self: *Parser) Error!?Obj(Quote) {
        log.parser.debug("parseQuote", .{});
        errdefer log.parser.debug("parseQuote failed", .{});

        const rml = getRml(self);
        const start = self.buffer_pos;

        const quoteKind = try self.parseAnyQuoteOpening() orelse return null;

        log.parser.debug("got quote opening {s}", .{quoteKind.toStr()});

        const body = try self.parseObject() orelse
            try self.failed(self.getOrigin(self.buffer_pos, null), "expected an object to follow quote operator `{s}`", .{quoteKind.toStr()});

        const result: Obj(Quote) = try .wrap(rml, self.getOrigin(start, self.buffer_pos), .{ .kind = quoteKind, .body = body });

        log.parser.debug("parseQuote result: {?}", .{result});

        return result;
    }

    pub fn parseBlock(self: *Parser, blockKind: BlockKind) Error!?Obj(Block) {
        log.parser.debug("parseBlock", .{});
        errdefer log.parser.debug("parseBlock failed", .{});

        const start = self.buffer_pos;

        if (!try self.parseBlockOpening(blockKind)) {
            return null;
        }

        const result = try self.parseBlockTail(start, blockKind);

        log.parser.debug("parseBlock result: {?}", .{result});

        return result;
    }

    pub fn parseAnyBlock(self: *Parser) Error!?Obj(Block) {
        log.parser.debug("parseBlock", .{});
        errdefer log.parser.debug("parseBlock failed", .{});

        const start = self.buffer_pos;

        const blockKind = try self.parseAnyBlockOpening() orelse return null;

        log.parser.debug("got block opening {s}", .{blockKind.toOpenStr()});

        const result = try self.parseBlockTail(start, blockKind);

        log.parser.debug("parseBlock result: {?}", .{result});

        return result;
    }

    pub fn nextBlob(self: *Parser) Error!?[]Object {
        return self.nextBlobWith(&self.obj_peek_cache);
    }

    pub fn nextBlobWith(self: *Parser, peekCache: *?Object) Error!?[]Object {
        var blob: std.ArrayListUnmanaged(Object) = .{};

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
                try blob.append(getRml(self).blobAllocator(), sourceExpr);
            }

            const nxt: Object = try self.peekWith(peekCache) orelse break :blob;
            const range = nxt.getOrigin().range.?;

            if (!isIndentationDomain(start, last, range.start.?)) {
                break :blob;
            }

            last = range.end.?;
        }

        return try self.blobify(.same_indent, first.getOrigin().range.?.end.?, blob.items);
    }

    pub fn blobify(self: *Parser, heuristic: enum { same_indent, domain }, start: Pos, blob: []Object) Error![]Object {
        const end = blob[blob.len - 1].getOrigin().range.?.end.?;
        const origin = self.getOffsetOrigin(start, end);

        log.parser.debug("blobify: {any}", .{blob});

        var array: std.ArrayListUnmanaged(Object) = .{};

        var last = start;

        var i: usize = 0;
        for (blob) |item| {
            const range = item.getOrigin().range.?;

            switch (heuristic) {
                .same_indent => if (start.indentation != range.start.?.indentation) break,
                .domain => if (!isIndentationDomain(start, last, range.start.?)) break,
            }

            try array.append(getRml(self).blobAllocator(), item);
            last = range.end.?;
            i += 1;
        }

        log.parser.debug("scanned: {}", .{array});

        if (i == blob.len) {
            log.parser.debug("return blob", .{});
            return array.items;
        } else {
            const first = blob[i].getOrigin().range.?.start.?;

            const newBlob = try self.blobify(.domain, first, blob[i..]);

            log.parser.debug("new blob: {any}", .{newBlob});

            switch (heuristic) {
                .domain => {
                    const firstLine = try Obj(Block).wrap(getRml(self), origin, try .create(getRml(self), .doc, array.items));

                    var allDocBlock = true;
                    for (newBlob) |item| {
                        if (castObj(Block, item)) |x| {
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
                        log.parser.debug("concat", .{});
                        return std.mem.concat(getRml(self).blobAllocator(), Object, &.{ &.{firstLine.typeErase()}, newBlob });
                    } else {
                        log.parser.debug("append first line, wrap", .{});
                        var newArr: std.ArrayListUnmanaged(Object) = .{};
                        try newArr.append(getRml(self).blobAllocator(), firstLine.typeErase());
                        try newArr.append(getRml(self).blobAllocator(), (try Obj(Block).wrap(getRml(self), origin, try .create(getRml(self), .doc, newBlob))).typeErase());

                        return newArr.items;
                    }
                },
                .same_indent => {
                    log.parser.debug("append", .{});
                    try array.append(getRml(self).blobAllocator(), (try Obj(Block).wrap(getRml(self), origin, try .create(getRml(self), .doc, newBlob))).typeErase());
                    return array.items;
                },
            }
        }
    }

    fn parseBlockTail(self: *Parser, start: Pos, blockKind: BlockKind) Error!Obj(Block) {
        const rml = getRml(self);

        var array: std.ArrayListUnmanaged(Object) = .{};

        var properties = try self.scan() orelse PropertySet{};

        var tailDeinit = true;
        var tailProperties: PropertySet = .{};

        var peekCache: ?Object = null;

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

                const origin = self.getOffsetOrigin(blob[0].getOrigin().range.?.start.?, blob[blob.len - 1].getOrigin().range.?.end.?);

                try array.append(rml.blobAllocator(), (try Obj(Block).wrap(getRml(self), origin, try .create(getRml(self), .doc, blob))).typeErase());
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

        const block: Obj(Block) = block: {
            if (array.items.len == 1) {
                const item = array.items[0];
                if (castObj(Block, item)) |x| {
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
            const sym: Obj(Symbol) = try .wrap(rml, origin, try .create(rml, "tail"));

            const map: Obj(Map) = try .wrap(rml, origin, .{ .allocator = rml.blobAllocator(), .native_map = @as(*Map.NativeMap, @ptrCast(&tailProperties)).* });
            tailDeinit = false;

            try block.getHeader().properties.put(rml.blobAllocator(), sym, map.typeErase());
        }

        return block;
    }

    pub fn parseQuoteOpening(self: *Parser, kind: QuoteKind) Error!bool {
        const openStr = kind.toStr();

        std.debug.assert(!std.mem.eql(u8, openStr, ""));

        return try self.expectSlice(openStr);
    }

    pub fn parseAnyQuoteOpening(self: *Parser) Error!?QuoteKind {
        inline for (comptime std.meta.fieldNames(QuoteKind)) |quoteKindName| {
            const quoteKind = @field(QuoteKind, quoteKindName);
            const openStr = comptime quoteKind.toStr();

            if (comptime std.mem.eql(u8, openStr, "")) @compileError("QuoteKind." ++ quoteKindName ++ ".toStr() must not return an empty string");

            if (try self.expectSlice(openStr)) {
                log.parser.debug("got quote opening {s}", .{openStr});
                return quoteKind;
            }
        }

        return null;
    }

    pub fn parseBlockOpening(self: *Parser, kind: BlockKind) Error!bool {
        const openStr = kind.toOpenStr();

        if (std.mem.eql(u8, openStr, "")) {
            log.parser.debug("checking for bof", .{});
            const is = self.isBof();
            log.parser.debug("bof: {}", .{is});
            return is;
        } else {
            log.parser.debug("checking for {s}", .{openStr});
            const is = try self.expectSlice(openStr);
            log.parser.debug("{s}: {}", .{ openStr, is });
            return is;
        }
    }

    pub fn parseAnyBlockOpening(self: *Parser) Error!?BlockKind {
        inline for (comptime std.meta.fieldNames(BlockKind)) |blockKindName| {
            const blockKind = @field(BlockKind, blockKindName);
            const openStr = comptime blockKind.toOpenStr();

            if (comptime std.mem.eql(u8, openStr, "")) continue;

            if (try self.expectSlice(openStr)) {
                log.parser.debug("got block opening {s}", .{openStr});
                return blockKind;
            }
        }

        return null;
    }

    pub fn parseBlockClosing(self: *Parser, kind: BlockKind) Error!bool {
        const closeStr = kind.toCloseStr();

        if (std.mem.eql(u8, closeStr, "")) {
            log.parser.debug("checking for eof", .{});
            const is = self.isEof();
            log.parser.debug("eof: {}", .{is});
            return is;
        } else {
            log.parser.debug("checking for {s}", .{closeStr});
            const is = try self.expectSlice(closeStr);
            log.parser.debug("{s}: {}", .{ closeStr, is });
            return is;
        }
    }

    pub fn parseAnyBlockClosing(self: *Parser) Error!bool {
        inline for (comptime std.meta.fieldNames(BlockKind)) |blockKindName| {
            const blockKind = @field(BlockKind, blockKindName);
            const closeStr = comptime blockKind.toCloseStr();

            if (comptime std.mem.eql(u8, closeStr, "")) {
                log.parser.debug("checking for eof", .{});
                const is = self.isEof();
                log.parser.debug("eof: {}", .{is});
                return is;
            } else {
                log.parser.debug("checking for {s}", .{closeStr});
                const is = try self.expectSlice(closeStr);
                log.parser.debug("{s}: {}", .{ closeStr, is });
                return is;
            }
        }
    }

    pub fn parseInt(self: *Parser) Error!?Obj(Int) {
        log.parser.debug("parseInt {?u}", .{self.peekChar() catch null});
        errdefer log.parser.debug("parseInt failed", .{});

        const rml = getRml(self);
        const start = self.buffer_pos;

        var int: Int = 0;

        const sign = try self.expectOptionalSign(Int) orelse {
            log.parser.debug("parseInt stop: no input", .{});
            return null;
        };

        var digits: usize = 0;

        while (try self.expectDecimalDigit()) |value| {
            int = int * 10 + value;
            digits += 1;
        }

        if (digits == 0) {
            log.parser.debug("parseInt reset: no digits", .{});
            self.reset(start);
            return null;
        }

        const result: Obj(Int) = try .wrap(rml, self.getOrigin(start, self.buffer_pos), int * sign);

        log.parser.debug("parseInt result: {}", .{result});

        return result;
    }

    pub fn parseFloat(self: *Parser) Error!?Obj(Float) {
        log.parser.debug("parseFloat {?u}", .{self.peekChar() catch null});
        errdefer log.parser.debug("parseFloat failed", .{});

        const rml = getRml(self);
        const start = self.buffer_pos;

        var int: Float = 0;
        var frac: Float = 0;
        var exp: Float = 0;

        const sign = try self.expectOptionalSign(Float) orelse {
            log.parser.debug("parseFloat stop: no input", .{});
            return null;
        };

        var digits: usize = 0;

        while (try self.expectDecimalDigit()) |value| {
            int = int * 10 + @as(Float, @floatFromInt(value));
            digits += 1;
        }

        if (try self.expectChar('.')) {
            var fracDiv: Float = 1;

            while (try self.expectDecimalDigit()) |value| {
                frac = frac * 10 + @as(Float, @floatFromInt(value));
                fracDiv *= 10;
                digits += 1;
            }

            frac /= fracDiv;

            if (digits > 0) {
                if (try self.expectAnyChar(&.{ 'e', 'E' }) != null) {
                    const expSign = try self.require(Float, expectOptionalSign, .{Float});

                    while (try self.expectDecimalDigit()) |value| {
                        exp = exp * 10 + @as(Float, @floatFromInt(value));
                        digits += 1;
                    }

                    exp *= expSign;
                }
            }
        } else {
            log.parser.debug("parseFloat reset: no frac", .{});
            self.reset(start);
            return null;
        }

        if (digits == 0) {
            log.parser.debug("parseFloat reset: no digits", .{});
            self.reset(start);
            return null;
        }

        const result = try Obj(Float).wrap(rml, self.getOrigin(start, self.buffer_pos), (int + frac) * sign * std.math.pow(Float, 10.0, exp));

        log.parser.debug("parseFloat result: {}", .{result});

        return result;
    }

    pub fn parseChar(self: *Parser) Error!?Obj(Char) {
        log.parser.debug("parseChar {?u}", .{self.peekChar() catch null});
        errdefer log.parser.debug("parseChar failed", .{});

        const rml = getRml(self);
        const start = self.buffer_pos;

        if (!try self.expectChar('\'')) {
            log.parser.debug("parseChar stop: expected '\''", .{});
            return null;
        }

        const ch = ch: {
            if (try self.peekChar()) |ch| {
                if (ch == '\\') {
                    break :ch try self.require(Char, expectEscape, .{});
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
            log.parser.debug("parseChar reset: expected '\''", .{});
            self.reset(start);
            return null;
        }

        const result: Obj(Char) = try .wrap(rml, self.getOrigin(start, self.buffer_pos), ch);

        log.parser.debug("parseChar result: {}", .{result});

        return result;
    }

    pub fn parseString(self: *Parser) Error!?Obj(String) {
        log.parser.debug("parseString {?u}", .{self.peekChar() catch null});
        errdefer log.parser.debug("parseString failed", .{});

        const rml = getRml(self);
        const start = self.buffer_pos;

        if (!try self.expectChar('"')) {
            log.parser.debug("parseString stop: expected '\"'", .{});
            return null;
        }

        var textBuffer: String = try .create(rml, "");

        while (try self.peekChar()) |ch| {
            if (ch == '"') {
                try self.advChar();

                log.parser.debug("parseString result: {s}", .{textBuffer.text()});

                return try Obj(String).wrap(rml, self.getOrigin(start, self.buffer_pos), textBuffer);
            }

            const i =
                if (ch == '\\') try self.require(Char, expectEscape, .{}) else if (!utils.text.isControl(ch)) try self.nextChar() orelse return error.UnexpectedEOF else return error.UnexpectedInput;

            try textBuffer.append(i);
        }

        return error.UnexpectedEOF;
    }

    pub fn parseSymbolic(self: *Parser) Error!?Object {
        const sym = try self.parseSymbol() orelse return null;

        const BUILTIN_SYMS = .{
            .nil = Nil{},
            .nan = std.math.nan(Float),
            .inf = std.math.inf(Float),
            .@"+inf" = std.math.inf(Float),
            .@"-inf" = -std.math.inf(Float),
            .true = true,
            .false = false,
        };

        inline for (comptime std.meta.fieldNames(@TypeOf(BUILTIN_SYMS))) |builtinSym| {
            if (std.mem.eql(u8, builtinSym, sym.data.str)) {
                const obj = try bindgen.toObjectConst(getRml(self), sym.getOrigin(), @field(BUILTIN_SYMS, builtinSym));

                return obj.typeErase();
            }
        }

        return sym.typeErase();
    }

    pub fn parseSymbol(self: *Parser) Error!?Obj(Symbol) {
        const rml = getRml(self);

        const start = self.buffer_pos;

        while (try self.peekChar()) |ch| {
            switch (ch) {
                '(',
                ')',
                '[',
                ']',
                '{',
                '}',
                ';',
                ',',
                '#',
                '\'',
                '`',
                '"',
                '\\',
                => break,

                else => if (utils.text.isSpace(ch) or utils.text.isControl(ch)) break,
            }

            try self.advChar();
        }

        if (start.offset == self.buffer_pos.offset) {
            log.parser.debug("parseSymbol reset: nothing recognized", .{});
            return null;
        }

        const result: Obj(Symbol) = try .wrap(rml, self.getOrigin(start, self.buffer_pos), try .create(rml, self.input.data.text()[start.offset..self.buffer_pos.offset]));

        log.parser.debug("parseSymbol result: {s}", .{result});

        return result;
    }

    pub fn expectChar(self: *Parser, ch: Char) Error!bool {
        if (try self.peekChar() == ch) {
            try self.advChar();
            return true;
        }

        return false;
    }

    pub fn expectAnyChar(self: *Parser, chars: []const Char) Error!?Char {
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

    pub fn expectAnySlice(self: *Parser, slices: []const []const u8) Error!?[]const u8 {
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

    pub fn expectSlice(self: *Parser, slice: []const u8) Error!bool {
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

    pub fn expectEscape(self: *Parser) Error!?Char {
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

    pub fn expectDecimalDigit(self: *Parser) Error!?u8 {
        if (try self.peekChar()) |ch| {
            if (utils.text.decimalValue(ch)) |value| {
                try self.advChar();
                return value;
            }
        }

        return null;
    }

    pub fn expectOptionalSign(self: *Parser, comptime T: type) Error!?T {
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

    pub fn scan(self: *Parser) Error!?PropertySet {
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

                        const sym: Obj(Symbol) = try .wrap(rml, origin, try .create(rml, state[0]));
                        const string: Obj(String) = try .wrap(rml, origin, try .create(rml, self.input.data.text()[state[1]..self.buffer_pos.offset]));

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

    pub fn reset(self: *Parser, pos: Pos) void {
        self.buffer_pos = pos;
        self.char_peek_cache = null;
    }

    pub fn failed(self: *Parser, origin: Origin, comptime fmt: []const u8, args: anytype) Error!noreturn {
        const err = if (self.isEof()) error.UnexpectedEOF else error.UnexpectedInput;

        const diagnostic = getRml(self).diagnostic orelse return err;

        var diag = Diagnostic{
            .error_origin = origin,
        };

        // the error produced is only NoSpaceLeft, if the buffer is too small, so give the length of the buffer
        diag.message_len = len: {
            break :len (std.fmt.bufPrintZ(&diag.message_mem, fmt, args) catch {
                log.parser.warn("Diagnostic message too long, truncating", .{});
                break :len Diagnostic.MAX_LENGTH;
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

    pub fn peekChar(self: *Parser) Error!?Char {
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

    pub fn nextChar(self: *Parser) Error!?Char {
        if (self.obj_peek_cache != null) {
            log.parser.err("Parser.nextChar: peek_cache is not null", .{});
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

    pub fn advChar(self: *Parser) Error!void {
        _ = try self.nextChar();
    }

    pub fn consumeIndent(self: *Parser) Error!void {
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

pub fn isIndentationDomain(start: Pos, last: Pos, pos: Pos) bool {
    log.parser.debug("isIndentationDomain? {} {}", .{ start, pos });
    const value = (pos.line == start.line and pos.column >= start.column) or (pos.line > start.line and pos.indentation > start.indentation) or (pos.line > start.line and pos.indentation >= start.indentation and last.line == pos.line);
    log.parser.debug("isIndentationDomain: {}", .{value});
    return value;
}

pub fn isSameLine(start: Pos, pos: Pos) bool {
    log.parser.debug("isSameLine? {} {}", .{ start, pos });
    const value = pos.line == start.line;
    log.parser.debug("isSameLine: {}", .{value});
    return value;
}

pub const WithId = enum(usize) { _ };

pub const Cancellation = struct {
    with_id: WithId,
    output: Object,
};

pub const Interpreter = struct {
    evaluation_env: Obj(Env),
    evidence_env: Obj(Env),
    cancellation: ?Cancellation = null,

    pub fn create(rml: *Rml) OOM!Interpreter {
        return Interpreter{
            .evaluation_env = try Obj(Env).wrap(rml, try .fromStr(rml, "system"), .{ .allocator = rml.blobAllocator() }),
            .evidence_env = try Obj(Env).wrap(rml, try .fromStr(rml, "system"), .{ .allocator = rml.blobAllocator() }),
        };
    }

    pub fn onCompare(a: *Interpreter, other: Object) std.math.Order {
        return utils.compare(@intFromPtr(a), @intFromPtr(other.data));
    }

    pub fn onFormat(self: *Interpreter, _: Format, writer: std.io.AnyWriter) anyerror!void {
        return writer.print("Obj(Interpreter){x}", .{@intFromPtr(self)});
    }

    pub fn reset(self: *Interpreter) OOM!void {
        const rml = getRml(self);
        self.evaluation_env = try Obj(Env).wrap(rml, getHeader(self).origin, .{ .allocator = rml.blobAllocator() });
    }

    pub fn castObj(self: *Interpreter, comptime T: type, obj: Object) Error!Obj(T) {
        if (Rml.castObj(T, obj)) |x| return x else {
            try self.abort(obj.getOrigin(), error.TypeError, "expected `{s}`, got `{s}`", .{ @typeName(T), TypeId.name(obj.getTypeId()) });
        }
    }

    pub fn freshCancellation(self: *Interpreter, origin: Origin) OOM!Obj(Procedure) {
        const withId = getRml(self).data.fresh(WithId);
        return Obj(Procedure).wrap(getRml(self), origin, Procedure{ .cancellation = withId });
    }

    pub fn abort(self: *Interpreter, origin: Origin, err: Error, comptime fmt: []const u8, args: anytype) Error!noreturn {
        const diagnostic = getRml(self).diagnostic orelse return err;

        var diag = Diagnostic{
            .error_origin = origin,
        };

        // the error produced is only NoSpaceLeft, if the buffer is too small, so give the length of the buffer
        diag.message_len = len: {
            break :len (std.fmt.bufPrintZ(&diag.message_mem, fmt, args) catch {
                log.interpreter.warn("Diagnostic message too long, truncating", .{});
                break :len Diagnostic.MAX_LENGTH;
            }).len;
        };

        diagnostic.* = diag;

        return err;
    }

    pub fn eval(self: *Interpreter, expr: Object) Result!Object {
        var offset: usize = 0;
        return self.evalCheck(false, &.{expr}, &offset, null);
    }

    pub fn evalAll(self: *Interpreter, exprs: []const Object) Result!std.ArrayListUnmanaged(Object) {
        var results: std.ArrayListUnmanaged(Object) = .{};

        for (exprs) |expr| {
            const value = try self.eval(expr);

            try results.append(getRml(self).blobAllocator(), value);
        }

        return results;
    }

    pub fn evalCheck(self: *Interpreter, shouldInvoke: bool, program: []const Object, offset: *usize, workDone: ?*bool) Result!Object {
        log.interpreter.debug("evalCheck {any} @ {}", .{ program, offset.* });

        const blob = program[offset.*..];

        const expr = if (offset.* < program.len) expr: {
            const out = program[offset.*];
            offset.* += 1;
            break :expr out;
        } else (try Obj(Nil).wrap(getRml(self), blobOrigin(blob), .{})).typeErase();

        const value = value: {
            if (Rml.castObj(Symbol, expr)) |symbol| {
                if (workDone) |x| x.* = true;

                log.interpreter.debug("looking up symbol {}", .{symbol});

                break :value self.lookup(symbol) orelse {
                    log.interpreter.err("failed to lookup symbol {}", .{symbol});
                    log.interpreter.err("evaluation_env: {debug}", .{self.evaluation_env.data.keys()});
                    log.interpreter.err("evidence_env: {debug}", .{self.evidence_env.data.keys()});
                    log.interpreter.err("global_env: {debug}", .{getRml(self).global_env.data.keys()});
                    log.interpreter.err("namespace_env: {debug}", .{getRml(self).namespace_env.data.keys()});
                    for (getRml(self).namespace_env.data.keys()) |key| {
                        log.interpreter.err("namespace {message}: {debug}", .{ key, getRml(self).namespace_env.data.get(key).? });
                    }
                    try self.abort(expr.getOrigin(), error.UnboundSymbol, "no symbol `{s}` in evaluation environment", .{symbol});
                };
            } else if (Rml.castObj(Block, expr)) |block| {
                if (block.data.length() == 0) {
                    log.interpreter.debug("empty block", .{});
                    break :value expr;
                }

                if (workDone) |x| x.* = true;

                log.interpreter.debug("running block", .{});
                break :value try self.runProgram(block.data.kind == .paren, block.data.items());
            } else if (Rml.castObj(Quote, expr)) |quote| {
                if (workDone) |x| x.* = true;

                log.interpreter.debug("running quote", .{});
                break :value try quote.data.run(self);
            }

            log.interpreter.debug("cannot evaluate further: {}", .{expr});

            break :value expr;
        };

        if (isType(Procedure, value) and (shouldInvoke or program.len > offset.*)) {
            const args = program[offset.*..];
            offset.* = program.len;

            return self.invoke(blobOrigin(blob), expr, value, args);
        } else {
            return value;
        }
    }

    pub fn lookup(self: *Interpreter, symbol: Obj(Symbol)) ?Object {
        return self.evaluation_env.data.get(symbol) orelse self.evidence_env.data.get(symbol) orelse getRml(self).global_env.data.get(symbol);
    }

    pub fn runProgram(self: *Interpreter, shouldInvoke: bool, program: []const Object) Result!Object {
        log.interpreter.debug("runProgram {any}", .{program});

        var last: Object = (try Obj(Nil).wrap(getRml(self), blobOrigin(program), .{})).typeErase();

        log.interpreter.debug("runProgram - begin loop", .{});

        var offset: usize = 0;
        while (offset < program.len) {
            const value = try self.evalCheck(shouldInvoke, program, &offset, null);

            last = value;
        }

        log.interpreter.debug("runProgram - end loop: {}", .{last});

        return last;
    }

    pub fn invoke(self: *Interpreter, callOrigin: Origin, blame: Object, callable: Object, args: []const Object) Result!Object {
        if (Rml.castObj(Procedure, callable)) |procedure| {
            return procedure.data.call(self, callOrigin, blame, args);
        } else {
            try self.abort(callOrigin, error.TypeError, "expected a procedure, got {s}: {s}", .{ TypeId.name(callable.getTypeId()), callable });
        }
    }
};

pub const bindgen = struct {
    pub fn isObj(comptime T: type) bool { // TODO: this check really needs to be more robust
        return std.mem.startsWith(u8, @typeName(T), "Rml.Obj");
    }

    pub fn bindGlobals(rml: *Rml, env: Obj(Env), comptime globals: type) (OOM || SymbolAlreadyBound)!void {
        inline for (comptime std.meta.declarations(globals)) |field| {
            const symbol: Obj(Symbol) = try .wrap(rml, rml.data.origin, try .create(rml, field.name));
            const obj = try toObjectConst(rml, rml.data.origin, &@field(globals, field.name));

            try env.data.bind(symbol, obj.typeErase());
        }
    }

    pub fn bindObjectNamespaces(rml: *Rml, env: Obj(Env), comptime namespaces: anytype) (OOM || SymbolAlreadyBound)!void {
        inline for (comptime std.meta.fields(@TypeOf(namespaces))) |field| {
            const builtinEnv: Obj(Env) = try .wrap(rml, rml.data.origin, .{ .allocator = rml.blobAllocator() });
            const Ns = Namespace(@field(namespaces, field.name));

            const methods = try Ns.methods(rml, rml.data.origin);

            try builtinEnv.data.bindNamespace(methods);
            const sym: Obj(Symbol) = try .wrap(rml, rml.data.origin, try .create(rml, field.name));

            try env.data.bind(sym, builtinEnv.typeErase());
        }
    }

    pub fn Support(comptime T: type) type {
        return struct {
            pub const onCompare = switch (@typeInfo(T)) {
                else => struct {
                    pub fn onCompare(a: *const T, obj: Object) std.math.Order {
                        var ord = utils.compare(getTypeId(a), obj.getTypeId());

                        if (ord == .eq) {
                            ord = utils.compare(a.*, forceObj(T, obj).data.*);
                        }

                        return ord;
                    }
                },
            }.onCompare;

            pub const onFormat = switch (T) {
                Char => struct {
                    pub fn onFormat(self: *const T, fmt: Format, writer: std.io.AnyWriter) anyerror!void {
                        switch (fmt) {
                            .message => try writer.print("{u}", .{self.*}),
                            inline else => {
                                var buf = [1]u8{0} ** 4;
                                const out = utils.text.escape(self.*, .Single, &buf) catch "[@INVALID BYTE@]";
                                try writer.print("'{s}'", .{out});
                            },
                        }
                    }
                },
                else => switch (@typeInfo(T)) {
                    .pointer => |info| if (@typeInfo(info.child) == .@"fn") struct {
                        pub fn onFormat(self: *const T, _: Format, writer: std.io.AnyWriter) anyerror!void {
                            try writer.print("[native-function {s} {x}]", .{ fmtNativeType(T), @intFromPtr(self) });
                        }
                    } else struct {
                        pub fn onFormat(self: *const T, _: Format, writer: std.io.AnyWriter) anyerror!void {
                            try writer.print("[native-{s} {x}]", .{ @typeName(T), @intFromPtr(self) });
                        }
                    },
                    .array => |info| struct {
                        pub fn onFormat(self: *const T, fmt: Format, writer: std.io.AnyWriter) anyerror!void {
                            try writer.writeAll("{");
                            for (self, 0..) |elem, i| {
                                try elem.onFormat(fmt, writer);
                                if (i < info.len - 1) try writer.writeAll("  ");
                            }
                            try writer.writeAll("}");
                        }
                    },
                    else => if (std.meta.hasFn(T, "format")) struct {
                        pub fn onFormat(self: *const T, fmt: Format, writer: std.io.AnyWriter) anyerror!void {
                            inline for (comptime std.meta.fieldNames(Format)) |fmtName| {
                                const field = comptime @field(Format, fmtName);
                                if (field == fmt) {
                                    return T.format(self, @tagName(field), .{}, writer);
                                }
                            }
                            unreachable;
                        }
                    } else struct {
                        pub fn onFormat(self: *const T, _: Format, writer: std.io.AnyWriter) anyerror!void {
                            return writer.print("{any}", .{self.*});
                        }
                    },
                },
            }.onFormat;
        };
    }

    pub const VTABLE_METHOD_NAMES = std.meta.fieldNames(VTable.ObjDataFunctions) ++ std.meta.fieldNames(VTable.ObjMemoryFunctions) ++ .{"onInit"};

    pub fn isVTableMethodName(name: []const u8) bool {
        for (VTABLE_METHOD_NAMES) |vtableName| {
            if (std.mem.eql(u8, name, vtableName)) return true;
        }
        return false;
    }

    pub const NativeFunction = *const fn (*Interpreter, Origin, []const Object) Result!Object;

    fn onAList(comptime T: type, comptime fieldName: []const u8) bool {
        comptime {
            const alist: []const []const u8 =
                if (@hasDecl(T, "BINDGEN_ALLOW")) T.BINDGEN_ALLOW else return true;

            for (alist) |name| {
                if (std.mem.eql(u8, name, fieldName)) return true;
            }

            return false;
        }
    }

    fn onDList(comptime T: type, comptime fieldName: []const u8) bool {
        comptime {
            const dlist: []const []const u8 =
                if (@hasDecl(T, "BINDGEN_DENY")) T.BINDGEN_DENY else return false;

            for (dlist) |name| {
                if (std.mem.eql(u8, name, fieldName)) return true;
            }

            return false;
        }
    }

    pub fn Namespace(comptime T: type) type {
        @setEvalBranchQuota(10_000);

        const BaseMethods = BaseMethods: {
            if (!utils.types.supportsDecls(T)) break :BaseMethods @Type(.{ .@"struct" = std.builtin.Type.Struct{
                .layout = .auto,
                .fields = &.{},
                .decls = &.{},
                .is_tuple = false,
            } });

            const Api = Api: {
                const ApiEntry = struct { type: type, name: [:0]const u8 };
                const decls = std.meta.declarations(T);

                var entries = [1]ApiEntry{undefined} ** decls.len;
                var i = 0;

                for (decls) |decl| {
                    if (std.meta.hasFn(T, decl.name) and !isVTableMethodName(decl.name) and onAList(T, decl.name) and !onDList(T, decl.name)) {
                        const F = @TypeOf(@field(T, decl.name));
                        if (@typeInfo(F) != .@"fn") continue;
                        const fInfo = @typeInfo(F).@"fn";
                        if (fInfo.is_generic or fInfo.is_var_args) continue;
                        entries[i] = ApiEntry{
                            .type = F,
                            .name = decl.name,
                        };
                        i += 1;
                    }
                }

                break :Api entries[0..i];
            };

            var fields = [1]std.builtin.Type.StructField{undefined} ** Api.len;
            for (Api, 0..) |apiEntry, i| {
                const fInfo = @typeInfo(apiEntry.type).@"fn";

                const GenericType = generic: {
                    break :generic @Type(.{ .@"fn" = std.builtin.Type.Fn{
                        .calling_convention = .auto,
                        .is_generic = false,
                        .is_var_args = false,
                        .return_type = ret_type: {
                            const R = fInfo.return_type.?;
                            const rInfo = @typeInfo(R);
                            if (rInfo != .error_union) break :ret_type R;
                            break :ret_type @Type(.{ .error_union = std.builtin.Type.ErrorUnion{
                                .error_set = Result,
                                .payload = rInfo.error_union.payload,
                            } });
                        },
                        .params = fInfo.params,
                    } });
                };

                fields[i] = std.builtin.Type.StructField{
                    .name = apiEntry.name,
                    .type = *const GenericType,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(*const fn () void),
                };
            }

            break :BaseMethods @Type(.{ .@"struct" = std.builtin.Type.Struct{
                .layout = .auto,
                .fields = &fields,
                .decls = &.{},
                .is_tuple = false,
            } });
        };

        const baseMethods = baseMethods: {
            var ms: BaseMethods = undefined;
            for (std.meta.fields(BaseMethods)) |field| {
                @field(ms, field.name) = @as(field.type, @ptrCast(&@field(T, field.name)));
            }
            break :baseMethods ms;
        };

        const Methods = Methods: {
            var fields = [1]std.builtin.Type.StructField{undefined} ** std.meta.fields(BaseMethods).len;

            for (std.meta.fields(BaseMethods), 0..) |field, fieldIndex| {
                fields[fieldIndex] = std.builtin.Type.StructField{
                    .name = field.name,
                    .type = Obj(Procedure),
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = @alignOf(*const fn () void),
                };
            }

            break :Methods @Type(.{ .@"struct" = std.builtin.Type.Struct{
                .layout = .auto,
                .fields = &fields,
                .decls = &.{},
                .is_tuple = false,
            } });
        };

        return struct {
            pub fn methods(rml: *Rml, origin: Origin) OOM!Methods {
                var ms: Methods = undefined;

                inline for (comptime std.meta.fieldNames(Methods)) |fieldName| {
                    @field(ms, fieldName) = try wrapNativeFunction(rml, origin, @field(baseMethods, fieldName));
                }

                return ms;
            }
        };
    }

    pub fn fromObject(comptime T: type, _: *Rml, value: Object) Error!T {
        const tInfo = @typeInfo(T);

        switch (tInfo) {
            .pointer => |info| {
                if (comptime info.size == .One and isBuiltinType(info.child)) {
                    if (!utils.equal(TypeId.of(info.child), value.getTypeId())) {
                        log.warn("expected {s} got {s}", .{ @typeName(info.child), TypeId.name(value.getTypeId()) });
                        return error.TypeError;
                    }

                    const obj = forceObj(info.child, value);
                    return obj.data;
                } else {
                    const obj = castObj(T, value) orelse return error.TypeError;
                    return obj.data.*;
                }
            },
            else => {
                if (comptime T == Object) {
                    return value;
                } else if (comptime isObj(T)) {
                    const O = @typeInfo(tInfo.@"struct".fields[0].type).pointer.child;

                    if (!utils.equal(TypeId.of(O), value.getTypeId())) {
                        return error.TypeError;
                    }

                    const obj = forceObj(O, value);
                    return obj;
                } else {
                    const obj = forceObj(T, value);
                    return obj.data.*;
                }
            },
        }
    }

    pub fn ObjectRepr(comptime T: type) type {
        const tInfo = @typeInfo(T);
        return switch (T) {
            Object => Object,
            Int => Obj(Int),
            Float => Obj(Float),
            Char => Obj(Char),
            bindgen.NativeFunction => Obj(Procedure),
            else => switch (tInfo) {
                .bool => Obj(Bool),

                .void, .null, .undefined, .noreturn => Obj(Nil),

                .int,
                .float,
                .error_set,
                .error_union,
                .@"enum",
                .@"opaque",
                .enum_literal,
                .array,
                .vector,
                => Obj(T),

                .pointer => |info| if (@typeInfo(info.child) == .@"fn") Obj(Procedure) else if (info.size == .One and isBuiltinType(info.child)) Obj(info.child) else Obj(T),

                .@"struct" => if (comptime isObj(T)) T else Obj(T),

                .@"union" => Obj(T),

                .@"fn" => Obj(Procedure),

                .optional => Object,

                else => @compileError("unsupported return type: " ++ @typeName(T)),
            },
        };
    }

    pub fn toObject(rml: *Rml, origin: Origin, value: anytype) OOM!ObjectRepr(@TypeOf(value)) {
        const T = @TypeOf(value);
        const tInfo = @typeInfo(T);
        return switch (T) {
            Nil => Obj(Nil).wrap(rml, origin, value),
            Int => Obj(Int).wrap(rml, origin, value),
            Float => Obj(Float).wrap(rml, origin, value),
            Char => Obj(Char).wrap(rml, origin, value),
            str => Obj(str).wrap(rml, origin, value),
            Object => return value,
            bindgen.NativeFunction => Obj(Procedure).wrap(rml, origin, .{ .native = value }),
            else => switch (tInfo) {
                .bool => Obj(Bool).wrap(rml, origin, value),

                .void,
                .null,
                .undefined,
                .noreturn,
                => Obj(Nil).wrap(rml, origin, Nil{}),

                .int,
                .float,
                .error_set,
                .error_union,
                .@"enum",
                .@"opaque",
                .enum_literal,
                .array,
                .vector,
                => Obj(T).wrap(rml, origin, value),

                .pointer => |info| if (@typeInfo(info.child) == .@"fn") @compileError("wrap functions with wrapNativeFunction") else if (comptime info.size == .One and isBuiltinType(info.child)) Obj(T).wrap(rml, origin, value.*) else Obj(T).wrap(rml, origin, value),

                .@"struct" => if (comptime isObj(T)) value else Obj(T).wrap(rml, origin, value),

                .@"union" => Obj(T).wrap(rml, origin, value),

                .optional => if (value) |v| v: {
                    const x = try toObject(rml, origin, v);
                    break :v x.typeErase();
                } else nil: {
                    const x = try Obj(Nil).wrap(rml, origin, Nil{});
                    break :nil x.typeErase();
                },

                else => @compileError("unsupported type: " ++ @typeName(T)),
            },
        };
    }

    pub fn toObjectConst(rml: *Rml, origin: Origin, comptime value: anytype) OOM!ObjectRepr(@TypeOf(value)) {
        const T = @TypeOf(value);
        const tInfo = @typeInfo(T);
        return switch (T) {
            Nil => Obj(Nil).wrap(rml, origin, value),
            Int => Obj(Int).wrap(rml, origin, value),
            Float => Obj(Float).wrap(rml, origin, value),
            Char => Obj(Char).wrap(rml, origin, value),
            str => Obj([]const u8).wrap(rml, origin, value),
            Object => value.clone(),
            bindgen.NativeFunction => Obj(Procedure).wrap(rml, origin, .{ .native_function = value }),
            else => switch (tInfo) {
                .bool => Obj(Bool).wrap(rml, origin, value),

                .void,
                .null,
                .undefined,
                .noreturn,
                => Obj(Nil).wrap(rml, origin, Nil{}),

                .int,
                .float,
                .error_set,
                .error_union,
                .@"enum",
                .@"opaque",
                .enum_literal,
                .array,
                .vector,
                => Obj(T).wrap(rml, origin, value),

                .pointer => |info| if (@typeInfo(info.child) == .@"fn") wrapNativeFunction(rml, origin, value) else if (comptime info.size == .One and isBuiltinType(info.child)) Obj(info.child).wrap(rml, origin, value.*) else { // TODO: remove compileError when not frequently adding builtins
                    @compileError(std.fmt.comptimePrint("not builtin type {} {}", .{ info, isBuiltinType(info.child) }));
                    // break :x Obj(T).wrap(rml, origin, value);
                },

                .@"struct",
                .@"union",
                => if (comptime isObj(T)) value else Obj(T).wrap(rml, origin, value),

                .optional => if (value) |v| v: {
                    const x = try toObject(rml, origin, v);
                    break :v x.typeErase();
                } else nil: {
                    const x = try Obj(Nil).wrap(rml, origin, Nil{});
                    break :nil x.typeErase();
                },

                else => @compileError("unsupported type: " ++ @typeName(T)),
            },
        };
    }

    pub fn wrapNativeFunction(rml: *Rml, origin: Origin, comptime nativeFunc: anytype) OOM!Obj(Procedure) {
        if (@TypeOf(nativeFunc) == bindgen.NativeFunction) {
            return Obj(Procedure).wrap(rml, origin, .{ .native_function = nativeFunc });
        }

        const T = @typeInfo(@TypeOf(nativeFunc)).pointer.child;
        const info = @typeInfo(T).@"fn";

        return Obj(Procedure).wrap(rml, origin, .{
            .native_function = &struct {
                pub fn method(interp: *Interpreter, callOrigin: Origin, args: []const Object) Result!Object {
                    // log.debug("native wrapper", .{});

                    if (args.len != info.params.len) {
                        try interp.abort(callOrigin, error.InvalidArgumentCount, "expected {} arguments, got {}", .{ info.params.len, args.len });
                    }

                    var nativeArgs: std.meta.ArgsTuple(T) = undefined;

                    inline for (info.params, 0..) |param, i| {
                        nativeArgs[i] = fromObject(param.type.?, getRml(interp), args[i]) catch |err| {
                            try interp.abort(callOrigin, err, "failed to convert argument {} from rml {} to native {s}", .{ i, args[i], @typeName(@TypeOf(nativeArgs[i])) });
                        };
                    }

                    const nativeResult = nativeResult: {
                        // log.debug("calling native function", .{});
                        const r = @call(.auto, nativeFunc, nativeArgs);
                        break :nativeResult if (comptime utils.types.causesErrors(T)) try r else r;
                    };

                    // log.debug("native function returned {any}", .{nativeResult});

                    const objWrapper = toObject(getRml(interp), callOrigin, nativeResult) catch |err| {
                        try interp.abort(callOrigin, err, "failed to convert result from native to rml", .{});
                    };

                    return objWrapper.typeErase();
                }
            }.method,
        });
    }

    pub fn fmtNativeType(comptime T: type) [:0]const u8 {
        return comptime switch (T) {
            else => if (isBuiltinType(T)) &fmtBuiltinTypeName(T) else switch (@typeInfo(T)) {
                .void, .null, .undefined, .noreturn => "Nil",
                .@"opaque" => "Opaque",
                .bool => "Bool",
                .int => |info| std.fmt.comptimePrint("{u}{}", .{ switch (info.signedness) {
                    .signed => 'S',
                    .unsigned => 'U',
                }, info.bits }),
                .float => |info| std.fmt.comptimePrint("F{}", .{info.bits}),
                .error_set => "Error",
                .error_union => |info| fmtNativeType(info.error_set) ++ "! " ++ fmtNativeType(info.payload),
                .pointer => |info| if (@typeInfo(info.child) == .@"fn") fmtNativeType(info.child) else switch (info.size) {
                    .C, .One, .Many => if (info.alignment == OBJ_ALIGN) fmtNativeType(info.child) else "*" ++ fmtNativeType(info.child),
                    .Slice => "[]" ++ fmtNativeType(info.child),
                },
                .array => |info| std.fmt.comptimePrint("[{}]", .{info.len} ++ fmtNativeType(info.child)),
                .vector => |info| std.fmt.comptimePrint("<{}>", .{info.len} ++ fmtNativeType(info.child)),
                .optional => |info| "?" ++ fmtNativeType(info.child),
                .@"struct" => &fmtTypeName(T),
                .@"enum" => &fmtTypeName(T),
                .@"union" => &fmtTypeName(T),
                .@"fn" => |info| fun: {
                    var x: []const u8 = "(";

                    for (info.params) |param| {
                        x = x ++ fmtNativeType(param.type.?) ++ " ";
                    }

                    x = x ++ "-> " ++ fmtNativeType(info.return_type.?);

                    break :fun x ++ ")";
                },
                .enum_literal => "Symbol",
                else => fmtTypeName(T),
            },
        };
    }

    pub fn builtinTypeNameLen(comptime T: type) usize {
        comptime {
            for (std.meta.fieldNames(@TypeOf(builtin.types))) |builtinName| {
                const x = @field(builtin.types, builtinName);
                if (x == T) return builtinName.len;
            }

            @compileError("fmtBuiltinTypeName: " ++ @typeName(T) ++ " is not a builtin type");
        }
    }

    pub fn fmtBuiltinTypeName(comptime T: type) [builtinTypeNameLen(T):0]u8 {
        comptime {
            for (std.meta.fieldNames(@TypeOf(builtin.types))) |builtinName| {
                const x = @field(builtin.types, builtinName);
                if (x == T) return @as(*const [builtinTypeNameLen(T):0]u8, @ptrCast(builtinName.ptr)).*;
            }

            @compileError("fmtBuiltinTypeName: " ++ @typeName(T) ++ " is not a builtin type");
        }
    }

    pub fn typeNameLen(comptime T: type) usize {
        comptime return if (isBuiltinType(T)) builtinTypeNameLen(T) else externTypeNameLen(T);
    }

    pub const NATIVE_PREFIX = "native:";

    pub fn externTypeNameLen(comptime T: type) usize {
        comptime return if (isBuiltinType(T)) @compileError("externTypeNameLen used with builtin type") else @typeName(T).len + NATIVE_PREFIX.len;
    }

    pub fn fmtExternTypeName(comptime T: type) [externTypeNameLen(T):0]u8 {
        @setEvalBranchQuota(10_000);

        comptime if (isBuiltinType(T)) @compileLog("fmtExternTypeName used with builtin type") else {
            const baseName = @typeName(T).*;
            var outName = std.mem.zeroes([externTypeNameLen(T):0]u8);
            for (NATIVE_PREFIX, 0..) |c, i| {
                outName[i] = c;
            }

            for (baseName, 0..) |c, i| {
                if (c == '.') {
                    outName[i + NATIVE_PREFIX.len] = '/';
                } else if (std.mem.indexOfScalar(u8, "()[]{}", c) != null) {
                    outName[i + NATIVE_PREFIX.len] = '_';
                } else {
                    outName[i + NATIVE_PREFIX.len] = c;
                }
            }

            return outName;
        };
    }

    pub fn fmtTypeName(comptime T: type) [typeNameLen(T):0]u8 {
        comptime return if (isBuiltinType(T)) fmtBuiltinTypeName(T) else fmtExternTypeName(T);
    }
};

pub const builtin = struct {
    pub const types = utils.types.structConcat(.{ value_types, object_types });

    pub const value_types = utils.types.structConcat(.{ atom_types, data_types });
    pub const object_types = utils.types.structConcat(.{ source_types, collection_types });

    pub const atom_types = .{
        .Nil = Nil,
        .Bool = Bool,
        .Int = Int,
        .Float = Float,
        .Char = Char,
        .String = String,
        .Symbol = Symbol,
    };

    pub const data_types = .{
        .Procedure = Procedure,
        .Interpreter = Interpreter,
        .Parser = Parser,
        .Pattern = Pattern,
        .Writer = Writer,
        .Cell = Cell,
    };

    pub const source_types = .{
        .Block = Block,
        .Quote = Quote,
    };

    pub const collection_types = .{
        .Env = Env,
        .Map = Map,
        .Set = Set,
        .Array = Array,
    };

    pub const namespaces = .{
        .text = struct {
            /// given a char, gives a symbol representing the unicode general category
            pub fn category(char: Char) utils.text.GeneralCategory {
                return utils.text.generalCategory(char);
            }

            /// given a string or char, checks if all characters are control characters
            pub fn @"control?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isControl, utils.text.isControlStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are letter characters
            pub fn @"letter?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isLetter, utils.text.isLetterStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are mark characters
            pub fn @"mark?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isMark, utils.text.isMarkStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are number characters
            pub fn @"number?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isNumber, utils.text.isNumberStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are punctuation characters
            pub fn @"punctuation?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isPunctuation, utils.text.isPunctuationStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are separator characters
            pub fn @"separator?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isSeparator, utils.text.isSeparatorStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are symbol characters
            pub fn @"symbol?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isSymbol, utils.text.isSymbolStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are math characters
            pub fn @"math?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isMath, utils.text.isMathStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are alphabetic characters
            pub fn @"alphabetic?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isAlphabetic, utils.text.isAlphabeticStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are id-start characters char
            pub fn @"id-start?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isIdStart, utils.text.isIdStartStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are id-continue characters char
            pub fn @"id-continue?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isIdContinue, utils.text.isIdContinueStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are xid-start characters char
            pub fn @"xid-start?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isXidStart, utils.text.isXidStartStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are xid-continue characters char
            pub fn @"xid-continue?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isXidContinue, utils.text.isXidContinueStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are space characters
            pub fn @"space?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isSpace, utils.text.isSpaceStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are hexadecimal digit characters char
            pub fn @"hex-digit?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isHexDigit, utils.text.isHexDigitStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are diacritic characters
            pub fn @"diacritic?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isDiacritic, utils.text.isDiacriticStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are numeric characters
            pub fn @"numeric?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isNumeric, utils.text.isNumericStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are digit characters
            pub fn @"digit?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isDigit, utils.text.isDigitStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are decimal digit characters char
            pub fn @"decimal?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isDecimal, utils.text.isDecimalStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are hexadecimal digit characters char
            pub fn @"hex?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isHexDigit, utils.text.isHexDigitStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are lowercase
            pub fn @"lowercase?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isLower, utils.text.isLowerStr, interp, origin, args);
            }

            /// given a string or char, checks if all characters are uppercase
            pub fn @"uppercase?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textPred(utils.text.isUpper, utils.text.isUpperStr, interp, origin, args);
            }

            /// given a string or char, returns a new copy with all of the characters converted to lowercase
            pub fn lowercase(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textConv(utils.text.toLower, interp, origin, args);
            }

            /// given a string or char, returns a new copy with all of the characters converted to uppercase
            pub fn uppercase(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return textConv(utils.text.toUpper, interp, origin, args);
            }

            /// given a string or a char, returns a new copy with all characters converted with unicode case folding; note that is may require converting chars to strings
            pub fn casefold(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                return try textConv(utils.text.caseFold, interp, origin, args);
            }

            /// given a string or a char, returns the number of bytes required to represent it as text/8
            pub fn @"byte-count"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                var a: Int = 0;

                for (args) |arg| {
                    if (castObj(String, arg)) |s| {
                        a += @intCast(s.data.text().len);
                    } else if (castObj(Char, arg)) |char| {
                        a += @intCast(utils.text.sequenceLength(char.data.*) catch {
                            return try interp.abort(origin, error.TypeError, "bad utf32 char", .{});
                        });
                    } else {
                        return try interp.abort(origin, error.TypeError, "expected a String or a Char, got {}: `{}`", .{ arg.getTypeId(), arg });
                    }
                }

                return (try Obj(Int).wrap(getRml(interp), origin, a)).typeErase();
            }

            /// given a string or a char, returns the width of the value in visual columns (approximate
            pub fn @"display-width"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                var a: Int = 0;

                for (args) |arg| {
                    if (castObj(String, arg)) |s| {
                        a += @intCast(utils.text.displayWidthStr(s.data.text()) catch 0);
                    } else if (castObj(Char, arg)) |char| {
                        a += @intCast(utils.text.displayWidth(char.data.*));
                    } else {
                        return try interp.abort(origin, error.TypeError, "expected a String or a Char, got {}: `{}`", .{ arg.getTypeId(), arg });
                    }
                }

                return (try Obj(Int).wrap(getRml(interp), origin, a)).typeErase();
            }

            /// compare two strings or chars using unicode case folding to ignore case
            pub fn @"case-insensitive-eq?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                var is = true;

                for (args) |arg| {
                    if (castObj(String, arg)) |str1| {
                        if (castObj(String, arg)) |str2| {
                            is = utils.text.caseInsensitiveCompareStr(str1.data.text(), str2.data.text()) catch true;
                        } else {
                            return try interp.abort(origin, error.TypeError, "expected two Strings or Two chars, got {}: `{}`, and {}: `{}`", .{ arg.getTypeId(), arg, arg.getTypeId(), arg });
                        }
                    } else if (castObj(Char, arg)) |char1| {
                        if (castObj(Char, arg)) |char2| {
                            is = utils.text.caseInsensitiveCompare(char1.data.*, char2.data.*);
                        } else {
                            return try interp.abort(origin, error.TypeError, "expected two Strings or Two chars, got {}: `{}`, and {}: `{}`", .{ arg.getTypeId(), arg, arg.getTypeId(), arg });
                        }
                    } else {
                        return try interp.abort(origin, error.TypeError, "expected two Strings or Two chars, got {}: `{}`, and {}: `{}`", .{ arg.getTypeId(), arg, arg.getTypeId(), arg });
                    }

                    if (!is) {
                        break;
                    }
                }

                return (try Obj(Bool).wrap(getRml(interp), origin, is)).typeErase();
            }

            fn appendConv(newStr: *String, conv: anytype) Result!void {
                const T = @TypeOf(conv);
                if (T == Char) {
                    try newStr.append(conv);
                } else if (@typeInfo(T) == .pointer) {
                    if (@typeInfo(T).pointer.child == Char) {
                        for (conv) |ch| try newStr.append(ch);
                    } else if (comptime @typeInfo(T).pointer.child == u8) {
                        try newStr.appendSlice(conv);
                    } else {
                        @compileError("unexpected type");
                    }
                } else {
                    @compileError("unexpected type");
                }
            }

            fn textConv(comptime charConv: anytype, interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                var compound = args.len != 1;
                var newStr = try String.create(getRml(interp), "");

                for (args) |arg| {
                    if (castObj(String, arg)) |s| {
                        compound = true;
                        const t = s.data.text();
                        var i: usize = 0;
                        while (i < t.len) {
                            const res = try utils.text.decode1(t[i..]);
                            i += res.len;
                            const conv = charConv(res.ch);
                            try appendConv(&newStr, conv);
                        }
                    } else if (castObj(Char, arg)) |char| {
                        const conv = charConv(char.data.*);
                        try appendConv(&newStr, conv);
                    } else {
                        return try interp.abort(origin, Error.TypeError, "expected a String or a Char, got {}: `{}`", .{ arg.getTypeId(), arg });
                    }
                }

                if (!compound) {
                    if (utils.text.codepointCount(newStr.text()) catch 0 == 1) {
                        return (try Obj(Char).wrap(getRml(interp), origin, utils.text.nthCodepoint(0, newStr.text()) catch unreachable orelse unreachable)).typeErase();
                    }
                }

                return (try Obj(String).wrap(getRml(interp), origin, newStr)).typeErase();
            }

            fn textPred(comptime chPred: fn (Char) bool, comptime strPred: fn ([]const u8) bool, interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                var is = true;

                for (args) |arg| {
                    const argIs = if (castObj(String, arg)) |s|
                        strPred(s.data.text())
                    else if (castObj(Char, arg)) |char|
                        chPred(char.data.*)
                    else {
                        try interp.abort(origin, error.TypeError, "expected a String or a Char, got {}: `{}`", .{ arg.getTypeId(), arg });
                    };

                    if (!argIs) {
                        is = false;
                        break;
                    }
                }

                return (try Obj(Bool).wrap(getRml(interp), origin, is)).typeErase();
            }
        },

        .type = struct {
            /// Get the type of an object
            pub fn of(obj: Object) OOM!Obj(Symbol) {
                const id = obj.getTypeId();

                return .wrap(obj.getRml(), obj.getOrigin(), try .create(obj.getRml(), id.name()));
            }

            /// Determine if an object is of type `nil`
            pub fn @"nil?"(obj: Object) Bool {
                log.warn("Nil? {}", .{obj});
                return utils.equal(obj.getTypeId(), TypeId.of(Nil));
            }

            /// Determine if an object is of type `bool`
            pub fn @"bool?"(obj: Object) Bool {
                return utils.equal(obj.getTypeId(), TypeId.of(Bool));
            }

            /// Determine if an object is of type `int`
            pub fn @"int?"(obj: Object) Bool {
                return utils.equal(obj.getTypeId(), TypeId.of(Int));
            }

            /// Determine if an object is of type `float`
            pub fn @"float?"(obj: Object) Bool {
                return utils.equal(obj.getTypeId(), TypeId.of(Float));
            }

            /// Determine if an object is of type `char`
            pub fn @"char?"(obj: Object) Bool {
                return utils.equal(obj.getTypeId(), TypeId.of(Char));
            }

            /// Determine if an object is of type `string`
            pub fn @"string?"(obj: Object) Bool {
                return utils.equal(obj.getTypeId(), TypeId.of(String));
            }

            /// Determine if an object is of type `symbol`
            pub fn @"symbol?"(obj: Object) Bool {
                return utils.equal(obj.getTypeId(), TypeId.of(Symbol));
            }

            /// Determine if an object is a procedure
            pub fn @"procedure?"(obj: Object) Bool {
                return utils.equal(obj.getTypeId(), TypeId.of(Procedure));
            }

            /// Determine if an object is an interpreter
            pub fn @"interpreter?"(obj: Object) Bool {
                return utils.equal(obj.getTypeId(), TypeId.of(Interpreter));
            }

            /// Determine if an object is a parser
            pub fn @"parser?"(obj: Object) Bool {
                return utils.equal(obj.getTypeId(), TypeId.of(Parser));
            }

            /// Determine if an object is a pattern
            pub fn @"pattern?"(obj: Object) Bool {
                return utils.equal(obj.getTypeId(), TypeId.of(Pattern));
            }

            /// Determine if an object is a writer
            pub fn @"writer?"(obj: Object) Bool {
                return utils.equal(obj.getTypeId(), TypeId.of(Writer));
            }

            /// Determine if an object is a cell
            pub fn @"cell?"(obj: Object) Bool {
                return utils.equal(obj.getTypeId(), TypeId.of(Cell));
            }

            /// Determine if an object is a block
            pub fn @"block?"(obj: Object) Bool {
                return utils.equal(obj.getTypeId(), TypeId.of(Block));
            }

            /// Determine if an object is a quote
            pub fn @"quote?"(obj: Object) Bool {
                return utils.equal(obj.getTypeId(), TypeId.of(Quote));
            }

            /// Determine if an object is an environment
            pub fn @"env?"(obj: Object) Bool {
                return utils.equal(obj.getTypeId(), TypeId.of(Env));
            }

            /// Determine if an object is a map
            pub fn @"map?"(obj: Object) Bool {
                return utils.equal(obj.getTypeId(), TypeId.of(Map));
            }

            /// Determine if an object is a set
            pub fn @"set?"(obj: Object) Bool {
                return utils.equal(obj.getTypeId(), TypeId.of(Set));
            }

            /// Determine if an object is an array
            pub fn @"array?"(obj: Object) Bool {
                return utils.equal(obj.getTypeId(), TypeId.of(Array));
            }
        },
    };

    pub const global = struct {
        /// Creates a string from any sequence of objects. If there are no objects, the string will be empty.
        ///
        /// Each object will be evaluated, and stringified with message formatting.
        /// The resulting strings will be concatenated to form the final string.
        pub fn format(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            const allocator = getRml(interp).blobAllocator();

            var out = NativeString{};

            try out.writer(allocator).print("{message}", .{Format.slice(args)});

            return (try Obj(String).wrap(getRml(interp), origin, .{ .allocator = allocator, .native_string = out })).typeErase();
        }

        /// Forces the Rml runtime to abort evaluation with `EvalError.Panic`, and a message.
        ///
        /// The message can be derived from any sequence of objects. If there are no objects, the panic message will be empty.
        ///
        /// Each object will be evaluated, and stringified with message formatting.
        /// The resulting strings will be concatenated to form the final abort message.
        ///
        /// Note that the resulting message will only be seen if the interpreter has an `Diagnostic` output bound to it.
        pub fn panic(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            try interp.abort(origin, error.Panic, "{message}", .{Format.slice(args)});
        }

        /// Evaluates the first argument, and coerces it to a bool.
        ///
        /// + **If the coerced bool is true**:
        /// Returns the un-coerced, evaluated value. Any remaining arguments are left un-evaluated.
        /// + **Otherwise**: Triggers a panic.
        /// Any remaining arguments are passed as the arguments to panic; or if there were no remaining arguments,
        /// the panic message will be the string representation of the value in un-evaluated and evaluated (but un-coerced) forms.
        /// Note that the resulting message will only be seen if the interpreter has an `Diagnostic` output bound to it.
        pub const assert = Procedure{
            .native_macro = &struct {
                pub fn fun(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                    if (args.len == 0) try interp.abort(origin, error.InvalidArgumentCount, "expected at least 1 argument, found {}", .{args.len});

                    const cond = try interp.eval(args[0]);

                    if (coerceBool(cond)) {
                        return cond;
                    } else if (args.len > 1) {
                        const eArgs = try interp.evalAll(args[1..]);
                        try interp.abort(origin, error.Panic, "Assertion failed: {message}", .{Format.slice(eArgs.items)});
                    } else {
                        try interp.abort(origin, error.Panic, "Assertion failed: {source} ({message})", .{ args[0], cond });
                    }
                }
            }.fun,
        };

        /// Evaluates the first two arguments, and compares them.
        ///
        /// + **If the two values are equal**:
        /// Returns the first value. Any remaining arguments are left un-evaluated.
        /// + **Otherwise**: Triggers a panic.
        /// Any remaining arguments are passed as the arguments to panic; or if there were no remaining arguments,
        /// the panic message will be a string representation of the comparison in un-evaluated and evaluated forms.
        /// Note that the resulting message will only be seen if the interpreter has an `Diagnostic` output bound to it.
        pub const @"assert-eq" = Procedure{
            .native_macro = &struct {
                pub fn fun(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                    if (args.len != 2) try interp.abort(origin, error.InvalidArgumentCount, "expected 2 arguments, found {}", .{args.len});

                    const a = try interp.eval(args[0]);
                    const b = try interp.eval(args[1]);

                    if (utils.equal(a, b)) {
                        return a;
                    } else if (args.len > 2) {
                        try interp.abort(origin, error.Panic, "Assertion failed: {message}", .{Format.slice(args[2..])});
                    } else {
                        try interp.abort(origin, error.Panic, "Assertion failed: {source} ({message}) (of type {}) is not equal to {source} ({message}) (of type {})", .{ args[0], a, a.getTypeId(), args[1], b, b.getTypeId() });
                    }
                }
            }.fun,
        };

        /// # `import` Syntax
        ///
        /// Imports a namespace into the current environment
        ///
        /// ## Example
        /// ```rml
        /// import text
        /// assert (text/lowercase? 't')
        /// ```
        pub const import = Procedure{
            .native_macro = &struct {
                pub fn fun(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                    if (args.len != 1) try interp.abort(origin, error.InvalidArgumentCount, "expected 1 argument, found {}", .{args.len});

                    const namespaceSym = try interp.castObj(Symbol, args[0]);

                    const namespace: Object = getRml(interp).namespace_env.data.get(namespaceSym) orelse {
                        try interp.abort(origin, error.UnboundSymbol, "namespace `{}` not found; available namespaces are: {any}", .{ namespaceSym, getRml(interp).namespace_env.data.keys() });
                    };

                    const env = try interp.castObj(Env, namespace);

                    const localEnv: *Env = interp.evaluation_env.data;

                    var it = env.data.table.iterator();
                    while (it.next()) |entry| {
                        const slashSym = slashSym: {
                            const slashStr = try std.fmt.allocPrint(getRml(interp).blobAllocator(), "{}/{}", .{ namespaceSym, entry.key_ptr.* });

                            break :slashSym try Obj(Symbol).wrap(getRml(interp), origin, try .create(getRml(interp), slashStr));
                        };

                        try localEnv.rebindCell(slashSym, entry.value_ptr.*);
                    }

                    return (try Obj(Nil).wrap(getRml(interp), origin, .{})).typeErase();
                }
            }.fun,
        };

        /// # `global` Syntax
        ///
        /// Binds a new variable in the global environment
        ///
        /// ## Example
        /// ```rml
        /// global x = 1
        /// global (y z) = '(2 3)
        /// assert-eq x 1
        /// assert-eq y 2
        /// assert-eq z 3
        /// ```
        pub const global = Procedure{
            .native_macro = &struct {
                pub fn fun(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                    log.interpreter.debug("global {}: {any}", .{ origin, args });

                    if (args.len < 1)
                        try interp.abort(origin, error.InvalidArgumentCount, "expected at least a name for global variable", .{});

                    const nilObj = try Obj(Nil).wrap(getRml(interp), origin, .{});
                    const equalSym = try Obj(Symbol).wrap(getRml(interp), origin, try .create(getRml(interp), ASSIGNMENT_OPERATOR));

                    const patt, const offset = parse: {
                        var diag: ?Diagnostic = null;
                        const parseResult = Pattern.parse(&diag, args) catch |err| {
                            if (err == error.SyntaxError) {
                                if (diag) |d| {
                                    try interp.abort(origin, error.PatternFailed, "cannot parse global variable pattern: {}", .{d.formatter(error.SyntaxError)});
                                } else {
                                    log.err("requested pattern parse diagnostic is null", .{});
                                    try interp.abort(origin, error.PatternFailed, "cannot parse global variable pattern `{}`", .{args[0]});
                                }
                            }

                            return err;
                        } orelse {
                            try interp.abort(origin, error.UnexpectedInput, "cannot parse global variable pattern `{}`", .{args[0]});
                        };

                        break :parse .{ parseResult.value, parseResult.offset };
                    };

                    log.parser.debug("global variable pattern: {}", .{patt});

                    const dom = patternBinders(patt.typeErase()) catch |err| switch (err) {
                        error.BadDomain => {
                            try interp.abort(origin, error.PatternFailed, "bad domain in pattern `{}`", .{patt});
                        },
                        error.OutOfMemory => return error.OutOfMemory,
                    };

                    for (dom.keys()) |sym| {
                        log.interpreter.debug("rebinding global variable {} = nil", .{sym});
                        try getRml(interp).global_env.data.rebind(sym, nilObj.typeErase());
                    }

                    const obj =
                        if (args.len - offset == 0) nilObj.typeErase() else obj: {
                        if (!utils.equal(args[offset], equalSym.typeErase())) {
                            try interp.abort(origin, error.UnexpectedInput, "expected `=` after global variable pattern", .{});
                        }

                        const body = args[offset + 1 ..];

                        if (body.len == 1) {
                            if (castObj(Block, body[0])) |bod| {
                                break :obj try interp.runProgram(
                                    bod.data.kind == .paren,
                                    bod.data.items(),
                                );
                            }
                        }

                        break :obj try interp.runProgram(false, body);
                    };

                    log.interpreter.debug("evaluating global variable {} = {}", .{ patt, obj });

                    const table = table: {
                        var diag: ?Diagnostic = null;
                        if (try patt.data.run(interp, &diag, origin, &.{obj})) |m| break :table m;

                        if (diag) |d| {
                            try interp.abort(origin, error.PatternFailed, "failed to match; {} vs {}:\n\t{}", .{ patt, obj, d.formatter(error.PatternFailed) });
                        } else {
                            log.interpreter.err("requested pattern diagnostic is null", .{});
                            try interp.abort(origin, error.PatternFailed, "failed to match; {} vs {}", .{ patt, obj });
                        }
                    };

                    var it = table.data.native_map.iterator();
                    while (it.next()) |entry| {
                        const sym = entry.key_ptr.*;
                        const val = entry.value_ptr.*;

                        log.interpreter.debug("setting global variable {} = {}", .{ sym, val });

                        // TODO: deep copy into long term memory

                        try getRml(interp).global_env.data.rebind(sym, val);
                    }

                    return nilObj.typeErase();
                }
            }.fun,
        };

        /// # `local` Syntax
        ///
        /// Binds a new variable in the local environment
        ///
        /// ## Example
        /// ```rml
        /// local x = 1
        /// local (y z) = '(2 3)
        /// assert-eq x 1
        /// assert-eq y 2
        /// assert-eq z 3
        /// ```
        pub const local = Procedure{
            .native_macro = &struct {
                pub fn fun(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                    log.interpreter.debug("local {}: {any}", .{ origin, args });

                    if (args.len < 1)
                        try interp.abort(origin, error.InvalidArgumentCount, "expected at least a name for local variable", .{});

                    const nilObj = try Obj(Nil).wrap(getRml(interp), origin, .{});
                    const equalSym = try Obj(Symbol).wrap(getRml(interp), origin, try .create(getRml(interp), ASSIGNMENT_OPERATOR));

                    const patt, const offset = parse: {
                        var diag: ?Diagnostic = null;
                        const parseResult = Pattern.parse(&diag, args) catch |err| {
                            if (err == error.SyntaxError) {
                                if (diag) |d| {
                                    try interp.abort(origin, error.PatternFailed, "cannot parse local variable pattern: {}", .{d.formatter(error.SyntaxError)});
                                } else {
                                    log.err("requested pattern parse diagnostic is null", .{});
                                    try interp.abort(origin, error.PatternFailed, "cannot parse local variable pattern `{}`", .{args[0]});
                                }
                            }

                            return err;
                        } orelse {
                            try interp.abort(origin, error.UnexpectedInput, "cannot parse local variable pattern `{}`", .{args[0]});
                        };

                        break :parse .{ parseResult.value, parseResult.offset };
                    };

                    log.parser.debug("local variable pattern: {}", .{patt});

                    const dom = patt.data.binders() catch |err| switch (err) {
                        error.BadDomain => {
                            try interp.abort(origin, error.PatternFailed, "bad domain in pattern `{}`", .{patt});
                        },
                        error.OutOfMemory => return error.OutOfMemory,
                    };

                    for (dom.keys()) |sym| {
                        log.interpreter.debug("rebinding local variable {} = nil", .{sym});
                        try interp.evaluation_env.data.rebind(sym, nilObj.typeErase());
                    }

                    const obj =
                        if (args.len - offset == 0) nilObj.typeErase() else obj: {
                        if (!utils.equal(args[offset], equalSym.typeErase())) {
                            try interp.abort(origin, error.UnexpectedInput, "expected `=` after local variable pattern", .{});
                        }

                        const body = args[offset + 1 ..];

                        if (body.len == 1) {
                            if (castObj(Block, body[0])) |bod| {
                                break :obj try interp.runProgram(
                                    bod.data.kind == .paren,
                                    bod.data.items(),
                                );
                            }
                        }

                        break :obj try interp.runProgram(false, body);
                    };

                    log.interpreter.debug("evaluating local variable {} = {}", .{ patt, obj });

                    const table = table: {
                        var diag: ?Diagnostic = null;
                        if (try patt.data.run(interp, &diag, origin, &.{obj})) |m| break :table m;

                        if (diag) |d| {
                            try interp.abort(origin, error.PatternFailed, "failed to match; {} vs {}:\n\t{}", .{ patt, obj, d.formatter(error.PatternFailed) });
                        } else {
                            log.interpreter.err("requested pattern diagnostic is null", .{});
                            try interp.abort(origin, error.PatternFailed, "failed to match; {} vs {}", .{ patt, obj });
                        }
                    };

                    var it = table.data.native_map.iterator();
                    while (it.next()) |entry| {
                        const sym = entry.key_ptr.*;
                        const val = entry.value_ptr.*;

                        log.interpreter.debug("setting local variable {} = {}", .{ sym, val });

                        try interp.evaluation_env.data.set(sym, val);
                    }

                    return nilObj.typeErase();
                }
            }.fun,
        };

        /// Sets the value of a variable associated with an existing binding in the current environment
        ///
        /// E.g. `(set! x 42)` will set the value of the variable `x` to `42`.
        pub const @"set!" = Procedure{
            .native_macro = &struct {
                pub fn fun(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                    if (args.len != 2) try interp.abort(origin, error.InvalidArgumentCount, "expected 2 arguments, found {}", .{args.len});

                    const sym = castObj(Symbol, args[0]) orelse try interp.abort(origin, error.TypeError, "expected symbol, found {s}", .{TypeId.name(args[0].getTypeId())});

                    const value = try interp.eval(args[1]);

                    try interp.evaluation_env.data.set(sym, value);

                    const nil = try Obj(Nil).wrap(getRml(interp), origin, .{});
                    return nil.typeErase();
                }
            }.fun,
        };

        /// # `with` Syntax
        ///
        /// Binds provided effect handlers to the evidence environment, then evaluates its body.
        ///
        /// Effect handlers bound this way have access to the `cancel` Syntax, which can be used to escape the with block.
        ///
        /// ## Example
        /// ```rml
        /// local x = 0
        /// with {
        ///     fresh = fun =>
        ///         local out = x
        ///         set! x (+ x 1)
        ///         out
        /// }
        ///     local a = (fresh)
        ///     local b = (fresh)
        ///     assert-eq a 0
        ///     assert-eq b 1
        /// ```
        ///
        /// ## Example
        /// ```rml
        /// assert-eq 'failed (with (fail = fun => cancel 'failed) (fail))
        /// ```
        pub const with = Procedure{
            .native_macro = &struct {
                pub fn fun(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                    if (args.len < 2) try interp.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

                    const context = (castObj(Block, args[0]) orelse {
                        try interp.abort(args[0].getOrigin(), error.TypeError, "expected a context block for with-syntax, found {s}", .{TypeId.name(args[0].getTypeId())});
                    });

                    const body = args[1..];

                    const newEvidence = try interp.evidence_env.data.clone(origin);

                    const cancellation = try interp.freshCancellation(origin);

                    var isCases = true;
                    for (context.data.items()) |obj| {
                        if (!isType(Block, obj)) {
                            isCases = false;
                            break;
                        }
                    }

                    const cases: []const Obj(Block) =
                        if (isCases) @as([*]const Obj(Block), @ptrCast(context.data.items().ptr))[0..@intCast(context.data.length())] else &.{context};

                    for (cases) |caseBlock| {
                        const case = caseBlock.data.items();
                        const effectSym = castObj(Symbol, case[0]) orelse {
                            try interp.abort(case[0].getOrigin(), error.TypeError, "expected a symbol for the effect handler in with-syntax case block, found {s}", .{TypeId.name(case[0].getTypeId())});
                        };

                        const sepSym = castObj(Symbol, case[1]) orelse {
                            try interp.abort(case[1].getOrigin(), error.TypeError, "expected {s} in with-syntax context block, found {}", .{ ASSIGNMENT_OPERATOR, case[1] });
                        };

                        if (!std.mem.eql(u8, ASSIGNMENT_OPERATOR, sepSym.data.text())) {
                            try interp.abort(sepSym.getOrigin(), error.TypeError, "expected {s} in with-syntax context block, found {s}", .{ ASSIGNMENT_OPERATOR, sepSym.data.text() });
                        }

                        const handlerBody = case[2..];

                        const handler = handler: {
                            const cancelerSym = try Obj(Symbol).wrap(getRml(interp), origin, try .create(getRml(interp), "cancel"));

                            const oldEnv = interp.evaluation_env;
                            defer interp.evaluation_env = oldEnv;
                            interp.evaluation_env = try oldEnv.data.clone(origin);
                            try interp.evaluation_env.data.rebind(cancelerSym, cancellation.typeErase());

                            break :handler try interp.runProgram(false, handlerBody);
                        };

                        try newEvidence.data.rebind(effectSym, handler);
                    }

                    const oldEvidence = interp.evidence_env;
                    defer interp.evidence_env = oldEvidence;
                    interp.evidence_env = newEvidence;

                    return interp.runProgram(false, body) catch |sig| {
                        if (sig == Signal.Cancel) {
                            const currentCancellation = interp.cancellation orelse @panic("cancellation signal received without a cancellation context");

                            if (currentCancellation.with_id == cancellation.data.cancellation) {
                                defer interp.cancellation = null;

                                return currentCancellation.output;
                            }
                        }

                        return sig;
                    };
                }
            }.fun,
        };

        /// # `fun` Syntax
        ///
        /// Creates a function closure
        ///
        /// ## Example
        /// ```rml
        /// local add = fun (a b) => (+ a b)
        /// assert-eq (add 1 2) 3
        /// ```
        pub const fun = Procedure{
            .native_macro = &struct {
                pub fn fun(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                    log.parser.debug("fun {}: {any}", .{ origin, args });

                    if (args.len == 0) try interp.abort(origin, error.InvalidArgumentCount, "expected at least 1 argument, found 0", .{});

                    const rml = getRml(interp);

                    var cases: std.ArrayListUnmanaged(Case) = .{};

                    if (args.len == 1) {
                        log.parser.debug("case fun", .{});
                        const caseSet: Obj(Block) = try interp.castObj(Block, args[0]);
                        log.parser.debug("case set {}", .{caseSet});

                        var isCases = true;
                        for (caseSet.data.items()) |obj| {
                            if (!isType(Block, obj)) {
                                isCases = false;
                                break;
                            }
                        }

                        if (isCases) {
                            log.parser.debug("isCases {any}", .{caseSet.data.array.items});
                            for (caseSet.data.array.items) |case| {
                                log.parser.debug("case {}", .{case});
                                const caseBlock = try interp.castObj(Block, case);

                                const c = try Case.parse(interp, caseBlock.getOrigin(), caseBlock.data.array.items);

                                try cases.append(rml.blobAllocator(), c);
                            }
                        } else {
                            log.parser.debug("fun single case: {any}", .{caseSet.data.array.items});
                            const c = try Case.parse(interp, caseSet.getOrigin(), caseSet.data.array.items);

                            try cases.append(rml.blobAllocator(), c);
                        }
                    } else {
                        log.parser.debug("fun single case: {any}", .{args});
                        const c = try Case.parse(interp, origin, args);

                        try cases.append(rml.blobAllocator(), c);
                    }

                    const env = try interp.evaluation_env.data.clone(origin);

                    const out: Obj(Procedure) = try .wrap(rml, origin, Procedure{
                        .function = .{
                            .env = env,
                            .cases = cases,
                        },
                    });

                    log.parser.debug("fun done: {}", .{out});

                    return out.typeErase();
                }
            }.fun,
        };

        /// # `macro` Syntax
        ///
        /// Creates a macro closure
        ///
        /// ## Example
        /// ```rml
        /// local add = macro (a b) => `(+ a b)
        /// assert-eq (add 1 2) 3
        /// ```
        pub const macro = Procedure{
            .native_macro = &struct {
                pub fn fun(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                    log.interpreter.debug("macro {}: {any}", .{ origin, args });

                    if (args.len == 0) try interp.abort(origin, error.InvalidArgumentCount, "expected at least 1 argument, found 0", .{});

                    const rml = getRml(interp);

                    var cases: std.ArrayListUnmanaged(Case) = .{};

                    if (args.len == 1) {
                        log.interpreter.debug("case macro", .{});
                        const caseSet: Obj(Block) = try interp.castObj(Block, args[0]);
                        log.interpreter.debug("case set {}", .{caseSet});

                        var isCases = true;
                        for (caseSet.data.items()) |obj| {
                            if (!isType(Block, obj)) {
                                isCases = false;
                                break;
                            }
                        }

                        if (isCases) {
                            log.interpreter.debug("isCases {}", .{isCases});
                            for (caseSet.data.array.items) |case| {
                                log.interpreter.debug("case {}", .{case});
                                const caseBlock = try interp.castObj(Block, case);

                                const c = try Case.parse(interp, origin, caseBlock.data.array.items);

                                try cases.append(rml.blobAllocator(), c);
                            }
                        } else {
                            log.interpreter.debug("isCases {}", .{isCases});
                            log.interpreter.debug("macro single case: {any}", .{caseSet.data.array.items});
                            const c = try Case.parse(interp, origin, caseSet.data.array.items);

                            try cases.append(rml.blobAllocator(), c);
                        }
                    } else {
                        log.interpreter.debug("macro single case: {any}", .{args});
                        const c = try Case.parse(interp, origin, args);
                        try cases.append(rml.blobAllocator(), c);
                    }

                    const env = try interp.evaluation_env.data.clone(origin);

                    const out: Obj(Procedure) = try .wrap(rml, origin, Procedure{
                        .macro = .{
                            .env = env,
                            .cases = cases,
                        },
                    });

                    return out.typeErase();
                }
            }.fun,
        };

        /// Prints a message followed by a new line. (To skip the new line, use `print`)
        ///
        /// The message can be derived from any sequence of objects. If there are no objects, the message will be empty.
        ///
        /// Each object will be evaluated, stringified with message formatting,
        /// and the resulting strings will be concatenated to form the final message.
        pub fn @"print-ln"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            const rml = getRml(interp);

            const stdout = std.io.getStdOut();

            stdout.writer().print("{}: {message}\n", .{ origin, Format.slice(args) }) catch |err| return errorCast(err);

            return (try Obj(Nil).wrap(rml, origin, .{})).typeErase();
        }

        /// Prints a message. (To append a new line to the message, use `print-ln`)
        ///
        /// The message can be derived from any sequence of objects. If there are no objects, the message will be empty.
        ///
        /// Each object will be evaluated, stringified with message formatting,
        /// and the resulting strings will be concatenated to form the final message.
        pub fn print(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            const rml = getRml(interp);

            const stdout = std.io.getStdOut();

            stdout.writer().print("{}: {message}", .{ origin, Format.slice(args) }) catch |err| return errorCast(err);

            return (try Obj(Nil).wrap(rml, origin, .{})).typeErase();
        }

        /// alias for `+`
        pub const add = @"+";
        /// sum any number of arguments of type `int | float | char`;
        /// if only one argument is provided, return the argument's absolute value
        pub fn @"+"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            if (args.len == 0) try interp.abort(origin, error.InvalidArgumentCount, "expected at least 1 argument, found 0", .{});

            var sum: Object = args[0];

            if (args.len == 1) {
                if (castObj(Int, sum)) |int| {
                    return (try Obj(Int).wrap(int.getRml(), origin, @intCast(@abs(int.data.*)))).typeErase();
                } else if (castObj(Float, sum)) |float| {
                    return (try Obj(Float).wrap(float.getRml(), origin, @abs(float.data.*))).typeErase();
                }
                if (castObj(Char, sum)) |char| {
                    return (try Obj(Char).wrap(char.getRml(), origin, char.data.*)).typeErase();
                } else {
                    try interp.abort(origin, error.TypeError, "expected int | float | char, found {s}", .{TypeId.name(sum.getTypeId())});
                }
            }

            return arithCastReduce(interp, origin, &sum, args[1..], struct {
                pub fn int(a: Int, b: Int) Int {
                    return a + b;
                }
                pub fn float(a: Float, b: Float) Float {
                    return a + b;
                }
                pub fn char(a: Char, b: Char) Char {
                    return a + b;
                }
            });
        }

        /// alias for `-`
        pub const sub = @"-";
        /// subtract any number of arguments of type `int | float | char`;
        /// if only one argument is provided, return the argument's negative value
        pub fn @"-"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            if (args.len == 0) try interp.abort(origin, error.InvalidArgumentCount, "expected at least 1 argument, found 0", .{});

            var sum: Object = args[0];

            if (args.len == 1) {
                if (castObj(Int, sum)) |int| {
                    return (try Obj(Int).wrap(int.getRml(), origin, -int.data.*)).typeErase();
                } else if (castObj(Float, sum)) |float| {
                    return (try Obj(Float).wrap(float.getRml(), origin, -float.data.*)).typeErase();
                }
                if (castObj(Char, sum)) |char| { // TODO: ???
                    return (try Obj(Char).wrap(char.getRml(), origin, char.data.*)).typeErase();
                } else {
                    try interp.abort(origin, error.TypeError, "expected int | float | char, found {s}", .{TypeId.name(sum.getTypeId())});
                }
            }

            return arithCastReduce(interp, origin, &sum, args[1..], struct {
                pub fn int(a: Int, b: Int) Int {
                    return a - b;
                }
                pub fn float(a: Float, b: Float) Float {
                    return a - b;
                }
                pub fn char(a: Char, b: Char) Char {
                    return a - b;
                }
            });
        }

        /// alias for `/`
        pub const div = @"/";
        /// divide any number of arguments of type `int | float | char`;
        /// it is an error to provide less than two arguments
        pub fn @"/"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            if (args.len < 2) try interp.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

            var sum: Object = args[0];

            return arithCastReduce(interp, origin, &sum, args[1..], struct {
                pub fn int(a: Int, b: Int) Int {
                    return @divFloor(a, b);
                }
                pub fn float(a: Float, b: Float) Float {
                    return a / b;
                }
                pub fn char(a: Char, b: Char) Char {
                    return @divFloor(a, b);
                }
            });
        }

        /// alias for `*`
        pub const mul = @"*";
        /// multiply any number of arguments of type `int | float | char`;
        /// it is an error to provide less than two arguments
        pub fn @"*"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            if (args.len < 2) try interp.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

            var sum: Object = args[0];

            return arithCastReduce(interp, origin, &sum, args[1..], struct {
                pub fn int(a: Int, b: Int) Int {
                    return a * b;
                }
                pub fn float(a: Float, b: Float) Float {
                    return a * b;
                }
                pub fn char(a: Char, b: Char) Char {
                    return a * b;
                }
            });
        }

        /// remainder division on any number of arguments of type `int | float | char`;
        /// it is an error to provide less than two arguments
        pub fn rem(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            if (args.len < 2) try interp.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

            var sum: Object = args[0];

            return arithCastReduce(interp, origin, &sum, args[1..], struct {
                pub fn int(a: Int, b: Int) Int {
                    return @rem(a, b);
                }
                pub fn float(a: Float, b: Float) Float {
                    return @rem(a, b);
                }
                pub fn char(a: Char, b: Char) Char {
                    return @rem(a, b);
                }
            });
        }

        /// exponentiation on any number of arguments of type `int | float | char`;
        /// it is an error to provide less than two arguments
        pub fn pow(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            if (args.len < 2) try interp.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

            var sum: Object = args[0];

            return arithCastReduce(interp, origin, &sum, args[1..], struct {
                pub fn int(a: Int, b: Int) Int {
                    return std.math.pow(Int, a, b);
                }
                pub fn float(a: Float, b: Float) Float {
                    return std.math.pow(Float, a, b);
                }
                pub fn char(a: Char, b: Char) Char {
                    return std.math.pow(Char, a, b);
                }
            });
        }

        /// bitwise NOT on an argument of type `int | char`
        pub fn @"bit-not"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            if (args.len != 1) try interp.abort(origin, error.InvalidArgumentCount, "expected 1 argument, found {}", .{args.len});

            if (castObj(Int, args[0])) |i| {
                return (try Obj(Int).wrap(i.getRml(), origin, ~i.data.*)).typeErase();
            } else if (castObj(Char, args[0])) |c| {
                return (try Obj(Char).wrap(c.getRml(), origin, ~c.data.*)).typeErase();
            } else {
                try interp.abort(origin, error.TypeError, "expected int | char, found {s}", .{TypeId.name(args[0].getTypeId())});
            }
        }

        /// bitwise AND on any number of arguments of type `int | char`;
        /// it is an error to provide less than two arguments
        pub fn @"bit-and"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            if (args.len < 2) try interp.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

            var sum: Object = args[0];

            return arithCastReduce(interp, origin, &sum, args[1..], struct {
                pub fn int(a: Int, b: Int) Int {
                    return a & b;
                }
                pub fn char(a: Char, b: Char) Char {
                    return a & b;
                }
            });
        }

        /// bitwise OR on any number of arguments of type `int | char`;
        /// it is an error to provide less than two arguments
        pub fn @"bit-or"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            if (args.len < 2) try interp.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

            var sum: Object = args[0];

            return arithCastReduce(interp, origin, &sum, args[1..], struct {
                pub fn int(a: Int, b: Int) Int {
                    return a | b;
                }
                pub fn char(a: Char, b: Char) Char {
                    return a | b;
                }
            });
        }

        /// bitwise XOR on any number of arguments of type `int | char`;
        /// it is an error to provide less than two arguments
        pub fn @"bit-xor"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            if (args.len < 2) try interp.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

            var sum: Object = args[0];

            return arithCastReduce(interp, origin, &sum, args[1..], struct {
                pub fn int(a: Int, b: Int) Int {
                    return a ^ b;
                }
                pub fn char(a: Char, b: Char) Char {
                    return a ^ b;
                }
            });
        }

        /// bitwise right shift on two arguments of type `int | char`
        pub fn @"bit-rshift"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            if (args.len != 2) try interp.abort(origin, error.InvalidArgumentCount, "expected 2 arguments, found {}", .{args.len});

            var sum: Object = args[0];

            return arithCastReduce(interp, origin, &sum, args[1..], struct {
                pub fn int(a: Int, b: Int) Int {
                    return a >> @intCast(b);
                }
                pub fn char(a: Char, b: Char) Char {
                    return a >> @intCast(b);
                }
            });
        }

        /// bitwise left shift on two arguments of type `int | char`
        pub fn @"bit-lshift"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            if (args.len != 2) try interp.abort(origin, error.InvalidArgumentCount, "expected 2 arguments, found {}", .{args.len});

            var sum: Object = args[0];

            return arithCastReduce(interp, origin, &sum, args[1..], struct {
                pub fn int(a: Int, b: Int) Int {
                    return a << @intCast(b);
                }
                pub fn char(a: Char, b: Char) Char {
                    return a << @intCast(b);
                }
            });
        }

        /// coerce an argument to type `bool`
        pub fn @"truthy?"(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            if (args.len != 1) {
                try interp.abort(origin, error.InvalidArgumentCount, "expected 1 argument, found {}", .{args.len});
            }

            return (try Obj(Bool).wrap(getRml(interp), origin, coerceBool(args[0]))).typeErase();
        }

        /// logical NOT on an argument coerced to type `bool`
        pub fn not(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            if (args.len != 1) {
                try interp.abort(origin, error.InvalidArgumentCount, "expected 1 argument, found {}", .{args.len});
            }

            return (try Obj(Bool).wrap(getRml(interp), origin, !coerceBool(args[0]))).typeErase();
        }

        /// short-circuiting logical AND on any number of arguments of any type;
        /// returns the last succeeding argument or nil
        pub const @"and" = Procedure{
            .native_macro = &struct {
                pub fn fun(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                    if (args.len == 0) return (try Obj(Nil).wrap(getRml(interp), origin, .{})).typeErase();

                    var a = try interp.eval(args[0]);

                    if (!coerceBool(a)) {
                        return (try Obj(Nil).wrap(getRml(interp), origin, .{})).typeErase();
                    }

                    for (args[1..]) |aN| {
                        const b = try interp.eval(aN);

                        if (!coerceBool(b)) return a;

                        a = b;
                    }

                    return a;
                }
            }.fun,
        };

        /// short-circuiting logical OR on any number of arguments of any type;
        /// returns the first succeeding argument or nil
        pub const @"or" = Procedure{
            .native_macro = &struct {
                pub fn fun(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                    for (args[0..]) |aN| {
                        const a = try interp.eval(aN);

                        if (coerceBool(a)) return a;
                    }

                    return (try Obj(Nil).wrap(getRml(interp), origin, .{})).typeErase();
                }
            }.fun,
        };

        /// alias for `==`
        pub const @"eq?" = @"==";
        /// determine if any number of values are equal; uses structural comparison
        /// it is an error to provide less than two arguments
        pub fn @"=="(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            if (args.len < 2)
                try interp.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

            const a = args[0];

            for (args[1..]) |aN| {
                const b = aN;

                if (!utils.equal(a, b)) return (try Obj(Bool).wrap(getRml(interp), origin, false)).typeErase();
            }

            return (try Obj(Bool).wrap(getRml(interp), origin, true)).typeErase();
        }

        /// alias for `!=`
        pub const @"ne?" = @"!=";
        /// determine if any number of values are not equal; uses structural comparison
        /// it is an error to provide less than two arguments
        pub fn @"!="(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            if (args.len < 2)
                try interp.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

            const a = args[0];

            for (args[1..]) |aN| {
                const b = aN;

                if (utils.equal(a, b)) return (try Obj(Bool).wrap(getRml(interp), origin, false)).typeErase();
            }

            return (try Obj(Bool).wrap(getRml(interp), origin, true)).typeErase();
        }

        /// alias for `<`
        pub const @"lt?" = @"<";
        /// determine if any number of values are in strictly increasing order
        /// it is an error to provide less than two arguments
        pub fn @"<"(
            interp: *Interpreter,
            origin: Origin,
            args: []const Object,
        ) Result!Object {
            if (args.len < 2)
                try interp.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

            var a = args[0];

            for (args[1..]) |aN| {
                const b = aN;

                if (utils.compare(a, b) != .lt) return (try Obj(Bool).wrap(getRml(interp), origin, false)).typeErase();

                a = b;
            }

            return (try Obj(Bool).wrap(getRml(interp), origin, true)).typeErase();
        }

        /// alias for `<=`
        pub const @"le?" = @"<=";
        /// determine if any number of values are in increasing order, allowing for equality on adjacent values
        /// it is an error to provide less than two arguments
        pub fn @"<="(
            interp: *Interpreter,
            origin: Origin,
            args: []const Object,
        ) Result!Object {
            if (args.len < 2)
                try interp.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

            var a = args[0];

            for (args[1..]) |aN| {
                const b = aN;

                if (utils.compare(a, b) == .gt) return (try Obj(Bool).wrap(getRml(interp), origin, false)).typeErase();

                a = b;
            }

            return (try Obj(Bool).wrap(getRml(interp), origin, true)).typeErase();
        }

        /// alias for `>`
        pub const @"gt?" = @">";
        /// determine if any number of values are in strictly decreasing order
        /// it is an error to provide less than two arguments
        pub fn @">"(
            interp: *Interpreter,
            origin: Origin,
            args: []const Object,
        ) Result!Object {
            if (args.len < 2)
                try interp.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

            var a = args[0];

            for (args[1..]) |aN| {
                const b = aN;

                if (utils.compare(a, b) != .gt) return (try Obj(Bool).wrap(getRml(interp), origin, false)).typeErase();

                a = b;
            }

            return (try Obj(Bool).wrap(getRml(interp), origin, true)).typeErase();
        }

        /// alias for `>=`
        pub const @"ge?" = @">=";
        /// determine if any number of values are in decreasing order, allowing for equality on adjacent values
        /// it is an error to provide less than two arguments
        pub fn @">="(
            interp: *Interpreter,
            origin: Origin,
            args: []const Object,
        ) Result!Object {
            if (args.len < 2)
                try interp.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});

            var a = args[0];

            for (args[1..]) |aN| {
                const b = aN;

                if (utils.compare(a, b) == .lt) return (try Obj(Bool).wrap(getRml(interp), origin, false)).typeErase();

                a = b;
            }

            return (try Obj(Bool).wrap(getRml(interp), origin, true)).typeErase();
        }

        /// calls a function with a list of arguments
        pub const apply = Procedure{ .native_macro = &struct {
            pub fn fun(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
                if (args.len != 2)
                    try interp.abort(origin, error.InvalidArgumentCount, "expected 2 arguments, found {}", .{args.len});

                const proc = try interp.castObj(Procedure, try interp.eval(args[0]));
                const argsArr = try coerceArray(try interp.eval(args[1])) orelse try interp.abort(origin, error.TypeError, "expected array, found {s}", .{TypeId.name(args[1].getTypeId())});

                return proc.data.call(interp, origin, args[0], argsArr.data.items());
            }
        }.fun };

        /// generates a unique Symbol
        pub fn gensym(interp: *Interpreter, origin: Origin, args: []const Object) Result!Object {
            if (args.len != 0) {
                try interp.abort(origin, error.InvalidArgumentCount, "expected 0 arguments, found {}", .{args.len});
            }

            const rml = getRml(interp);

            const sym = try rml.data.gensym(origin);

            return (try Obj(Symbol).wrap(rml, origin, .{ .str = sym })).typeErase();
        }

        const ASSIGNMENT_OPERATOR = "=";

        fn arithCastReduce(
            interp: *Interpreter,
            origin: Origin,
            acc: *Object,
            args: []const Object,
            comptime Ops: type,
        ) Result!Object {
            const offset = 1;
            comptime var expect: []const u8 = "";
            const decls = comptime std.meta.declarations(Ops);
            inline for (decls, 0..) |decl, i| comptime {
                expect = expect ++ decl.name;
                if (i < decls.len - 1) expect = expect ++ " | ";
            };
            for (args, 0..) |arg, i| {
                if (@hasDecl(Ops, "int") and isType(Int, acc.*)) {
                    const int = forceObj(Int, acc.*);
                    if (castObj(Int, arg)) |int2| {
                        const int3: Obj(Int) = try .wrap(int2.getRml(), origin, @field(Ops, "int")(int.data.*, int2.data.*));
                        acc.* = int3.typeErase();
                    } else if (@hasDecl(Ops, "float") and isType(Float, arg)) {
                        const float = forceObj(Float, arg);
                        const float2: Obj(Float) = try .wrap(float.getRml(), origin, @field(Ops, "float")(@as(Float, @floatFromInt(int.data.*)), float.data.*));
                        acc.* = float2.typeErase();
                    } else if (castObj(Char, arg)) |char| {
                        const int2: Obj(Int) = try .wrap(char.getRml(), origin, @field(Ops, "int")(int.data.*, @as(Int, @intCast(char.data.*))));
                        acc.* = int2.typeErase();
                    } else {
                        try interp.abort(origin, error.TypeError, "expected " ++ expect ++ " for argument {}, found {s}", .{ i + offset, TypeId.name(arg.getTypeId()) });
                    }
                } else if (@hasDecl(Ops, "float") and isType(Float, acc.*)) {
                    const float = forceObj(Float, acc.*);

                    if (castObj(Int, arg)) |int| {
                        const float2: Obj(Float) = try .wrap(int.getRml(), origin, @field(Ops, "float")(float.data.*, @as(Float, @floatFromInt(int.data.*))));
                        acc.* = float2.typeErase();
                    } else if (castObj(Float, arg)) |float2| {
                        const float3: Obj(Float) = try .wrap(float2.getRml(), origin, @field(Ops, "float")(float.data.*, float2.data.*));
                        acc.* = float3.typeErase();
                    } else if (castObj(Char, arg)) |char| {
                        const float2: Obj(Float) = try .wrap(char.getRml(), origin, @field(Ops, "float")(float.data.*, @as(Float, @floatFromInt(char.data.*))));
                        acc.* = float2.typeErase();
                    } else {
                        try interp.abort(origin, error.TypeError, "expected " ++ expect ++ " for argument {}, found {s}", .{ i + offset, TypeId.name(arg.getTypeId()) });
                    }
                } else if (@hasDecl(Ops, "char") and isType(Char, acc.*)) {
                    const char = forceObj(Char, acc.*);

                    if (@hasDecl(Ops, "int") and isType(Int, arg)) {
                        const int = forceObj(Int, arg);
                        const int2: Obj(Int) = try .wrap(char.getRml(), origin, @field(Ops, "int")(@as(Int, @intCast(char.data.*)), int.data.*));
                        acc.* = int2.typeErase();
                    } else if (@hasDecl(Ops, "float") and isType(Float, arg)) {
                        const float = forceObj(Float, arg);
                        const float2: Obj(Float) = try .wrap(float.getRml(), origin, @field(Ops, "float")(@as(Float, @floatFromInt(char.data.*)), float.data.*));
                        acc.* = float2.typeErase();
                    } else if (castObj(Char, arg)) |char2| {
                        const char3: Obj(Char) = try .wrap(char2.getRml(), origin, @field(Ops, "char")(char.data.*, char2.data.*));
                        acc.* = char3.typeErase();
                    } else {
                        try interp.abort(origin, error.TypeError, "expected " ++ expect ++ " for argument {}, found {s}", .{ i + offset, TypeId.name(arg.getTypeId()) });
                    }
                } else {
                    try interp.abort(origin, error.TypeError, "expected " ++ expect ++ " for argument {}, found {s}", .{ i, TypeId.name(acc.getTypeId()) });
                }
            }

            return acc.*;
        }
    };
};

pub const OBJ_ALIGN = 16;

pub const ObjData = extern struct { data: u8 align(OBJ_ALIGN) };

pub const PropertySet = std.ArrayHashMapUnmanaged(Obj(Symbol), Obj(ObjData), utils.SimpleHashContext, true);

pub const Header = struct {
    rml: *Rml,
    blob_id: BlobId,
    type_id: TypeId,
    vtable: *const VTable,
    origin: Origin,
    properties: PropertySet,

    pub fn onInit(self: *Header, comptime T: type, rml: *Rml, origin: Origin) void {
        self.* = Header{
            .rml = rml,
            .blob_id = rml.blobId(),
            .type_id = comptime TypeId.of(T),
            .vtable = VTable.of(T),
            .origin = origin,
            .properties = .{},
        };
    }

    pub fn onCompare(self: *Header, other: *Header) std.math.Order {
        const obj = other.getObject();
        return self.vtable.onCompare(self, obj);
    }

    pub fn onFormat(self: *Header, fmt: Format, w: std.io.AnyWriter) anyerror!void {
        return self.vtable.onFormat(self, fmt, w);
    }

    pub fn getObject(self: *Header) Object {
        return getObj(self.getData());
    }

    pub fn getObjMemory(self: *Header) *ObjMemory(ObjData) {
        return @alignCast(@fieldParentPtr("header", @as(*utils.types.ToBytes(Header), @ptrCast(self))));
    }

    pub fn getData(self: *Header) *ObjData {
        return self.getObjMemory().getData();
    }
};

pub const VTable = struct {
    obj_memory: ObjMemoryFunctions,
    obj_data: ObjDataFunctions,

    pub const ObjMemoryFunctions = struct {};

    pub const ObjDataFunctions = struct {
        onCompare: ?*const fn (*const ObjData, Object) std.math.Order = null,
        onFormat: ?*const fn (*const ObjData, Format, std.io.AnyWriter) anyerror!void = null,
    };

    pub fn of(comptime T: type) *const VTable {
        if (comptime T == ObjData) return undefined;

        const x = struct {
            const vtable = VTable{
                .obj_memory = obj_memory: {
                    var functionSet: ObjMemoryFunctions = .{};

                    for (std.meta.fields(ObjMemoryFunctions)) |field| {
                        const funcName = field.name;

                        const G = @typeInfo(@typeInfo(field.type).optional.child).pointer.child;
                        const gInfo = @typeInfo(G).@"fn";

                        const F = @TypeOf(@field(ObjMemory(T), funcName));
                        const fInfo = @typeInfo(F).@"fn";

                        std.debug.assert(!fInfo.is_generic);
                        std.debug.assert(!fInfo.is_var_args);
                        std.debug.assert(fInfo.return_type.? == gInfo.return_type.?);
                        std.debug.assert(fInfo.params.len == gInfo.params.len);

                        @field(functionSet, funcName) = @ptrCast(&@field(ObjMemory(T), funcName));
                    }

                    break :obj_memory functionSet;
                },
                .obj_data = obj_data: {
                    var functionSet: ObjDataFunctions = .{};

                    const support = bindgen.Support(T);
                    for (std.meta.fields(ObjDataFunctions)) |field| {
                        const funcName = field.name;

                        const def =
                            if (utils.types.supportsDecls(T) and @hasDecl(T, funcName)) &@field(T, funcName) else if (@hasDecl(support, funcName)) &@field(support, funcName) else @compileError("no " ++ @typeName(T) ++ "." ++ funcName ++ " found");

                        const G = @typeInfo(@typeInfo(field.type).optional.child).pointer.child;
                        const gInfo = @typeInfo(G).@"fn";

                        const F = @typeInfo(@TypeOf(def)).pointer.child;
                        if (@typeInfo(F) != .@"fn") {
                            @compileError("expected fn: " ++ @typeName(T) ++ "." ++ @typeName(@TypeOf(def)));
                        }
                        const fInfo = @typeInfo(F).@"fn";

                        if (fInfo.is_generic) {
                            @compileError("expected non-generic function: " ++ @typeName(T) ++ "." ++ funcName);
                        }
                        if (fInfo.is_var_args) {
                            @compileError("expected non-variadic function: " ++ @typeName(T) ++ "." ++ funcName);
                        }
                        if (fInfo.return_type.? != gInfo.return_type.?) {
                            @compileError("expected return type: " ++ @typeName(T) ++ "." ++ funcName ++ ": " ++ @typeName(gInfo.return_type.?) ++ ", got " ++ @typeName(fInfo.return_type.?));
                        }
                        if (fInfo.params.len != gInfo.params.len) {
                            @compileError("invalid param count: " ++ @typeName(T) ++ "." ++ funcName);
                        }

                        @field(functionSet, funcName) = @ptrCast(def);
                    }

                    break :obj_data functionSet;
                },
            };
        };

        return &x.vtable;
    }

    pub fn onCompare(self: *const VTable, header: *Header, other: Object) std.math.Order {
        const data = header.getData();
        return self.obj_data.onCompare.?(data, other);
    }

    pub fn onFormat(self: *const VTable, header: *Header, fmt: Format, w: std.io.AnyWriter) Error!void {
        const data = header.getData();
        return self.obj_data.onFormat.?(data, fmt, w) catch |err| errorCast(err);
    }
};

pub const ObjectMemory = ObjMemory(ObjData);
pub fn ObjMemory(comptime T: type) type {
    return extern struct {
        const Self = @This();

        // this sucks but we need extern to guarantee layout here & don't want it on Header / T
        header: utils.types.ToBytes(Header) align(OBJ_ALIGN),
        data: utils.types.ToBytes(T) align(OBJ_ALIGN),

        pub fn onInit(self: *Self, rml: *Rml, origin: Origin, data: T) void {
            Header.onInit(@ptrCast(&self.header), T, rml, origin);
            self.data = std.mem.toBytes(data);
        }

        pub fn getHeader(self: *Self) *Header {
            return @ptrCast(&self.header);
        }

        pub fn getTypeId(self: *Self) TypeId {
            return self.getHeader().type_id;
        }

        pub fn getData(self: *Self) *T {
            return @ptrCast(&self.data);
        }
    };
}

pub const Object = Obj(ObjData);
pub fn Obj(comptime T: type) type {
    std.debug.assert(@alignOf(T) <= OBJ_ALIGN);

    return struct {
        const Self = @This();

        data: *T,

        pub fn typeErase(self: Self) Object {
            return .{ .data = @alignCast(@ptrCast(self.data)) };
        }

        pub fn wrap(rml: *Rml, origin: Origin, val: T) OOM!Self {
            const memory = try rml.blobAllocator().create(ObjMemory(T));

            memory.onInit(rml, origin, val);

            return Self{ .data = memory.getData() };
        }

        pub fn compare(self: Self, other: Obj(T)) std.math.Order {
            return self.getHeader().onCompare(other.getHeader());
        }

        pub fn format(self: Self, comptime fmt: []const u8, _: std.fmt.FormatOptions, w: anytype) anyerror!void {
            return self.getHeader().onFormat(comptime Format.fromStr(fmt) orelse Format.debug, if (@TypeOf(w) == std.io.AnyWriter) w else w.any());
        }

        pub fn getMemory(self: Self) *ObjMemory(T) {
            return @alignCast(@fieldParentPtr("data", @as(*utils.types.ToBytes(T), @ptrCast(self.data))));
        }

        pub fn getHeader(self: Self) *Header {
            return @ptrCast(&getMemory(self).header);
        }

        pub fn getTypeId(self: Self) TypeId {
            return self.getHeader().type_id;
        }

        pub fn getOrigin(self: Self) Origin {
            return self.getHeader().origin;
        }

        pub fn getRml(self: Self) *Rml {
            return self.getHeader().rml;
        }

        pub fn onCompare(self: Self, other: Object) std.math.Order {
            return self.getHeader().onCompare(other.getHeader());
        }

        pub fn onFormat(self: Self, fmt: Format, w: std.io.AnyWriter) anyerror!void {
            return self.getHeader().onFormat(fmt, w);
        }
    };
}

pub fn getObj(p: anytype) Obj(@typeInfo(@TypeOf(p)).pointer.child) {
    return Obj(@typeInfo(@TypeOf(p)).pointer.child){ .data = @constCast(p) };
}

pub fn getHeader(p: anytype) *Header {
    return getObj(p).getHeader();
}

pub fn getOrigin(p: anytype) Origin {
    return getHeader(p).origin;
}

pub fn getTypeId(p: anytype) TypeId {
    return getHeader(p).type_id;
}

pub fn getRml(p: anytype) *Rml {
    return getHeader(p).rml;
}

pub fn castObj(comptime T: type, obj: Object) ?Obj(T) {
    return if (isType(T, obj)) forceObj(T, obj) else null;
}

pub fn isType(comptime T: type, obj: Object) bool {
    return utils.equal(obj.getTypeId(), TypeId.of(T));
}

pub fn isUserdata(obj: Object) bool {
    return !isBuiltin(obj);
}

pub fn isBuiltinType(comptime T: type) bool {
    comptime {
        for (std.meta.fieldNames(@TypeOf(builtin.types))) |builtinName| {
            const x = @field(builtin.types, builtinName);
            if (x == T) {
                return true;
            } // else @compileLog("builtin type: " ++ @typeName(builtin) ++ " vs " ++ " " ++ @typeName(T));
        }

        return false;
    }
}

pub fn isBuiltin(obj: Object) bool {
    const typeId = obj.getTypeId();

    inline for (comptime std.meta.fields(@TypeOf(builtin.types))) |x| {
        if (utils.equal(typeId, TypeId.of(@field(builtin.types, x.name)))) return true;
    }

    return false;
}

pub fn isValue(obj: Object) bool {
    const typeId = obj.getTypeId();

    inline for (comptime std.meta.fields(@TypeOf(builtin.value_types))) |value| {
        if (utils.equal(typeId, TypeId.of(@field(builtin.value_types, value.name)))) return true;
    }

    return false;
}

pub fn isAtom(obj: Object) bool {
    const typeId = obj.getTypeId();

    inline for (comptime std.meta.fields(@TypeOf(builtin.atom_types))) |atom| {
        if (utils.equal(typeId, TypeId.of(@field(builtin.atom_types, atom.name)))) return true;
    }

    return false;
}

pub fn isData(obj: Object) bool {
    const typeId = obj.getTypeId();

    inline for (comptime std.meta.fields(@TypeOf(builtin.data_types))) |data| {
        if (utils.equal(typeId, TypeId.of(@field(builtin.data_types, data.name)))) return true;
    }

    return false;
}

pub fn isObject(obj: Object) bool {
    const typeId = obj.getTypeId();

    inline for (comptime std.meta.fields(@TypeOf(builtin.object_types))) |o| {
        if (utils.equal(typeId, TypeId.of(@field(builtin.object_types, o.name)))) return true;
    }

    return false;
}

pub fn isSource(obj: Object) bool {
    const typeId = obj.getTypeId();

    inline for (comptime std.meta.fields(@TypeOf(builtin.source_types))) |source| {
        if (utils.equal(typeId, TypeId.of(@field(builtin.source_types, source.name)))) return true;
    }

    return false;
}

pub fn isCollection(obj: Object) bool {
    const typeId = obj.getTypeId();

    inline for (comptime std.meta.fields(@TypeOf(builtin.collection_types))) |collection| {
        if (utils.equal(typeId, TypeId.of(@field(builtin.collection_types, collection.name)))) return true;
    }

    return false;
}

pub fn isObjectType(comptime T: type) bool {
    const typeId = TypeId.of(T);

    inline for (comptime std.meta.fields(builtin.object_types)) |obj| {
        if (utils.equal(typeId, TypeId.of(@field(builtin.object_types, obj.name)))) return true;
    }

    return false;
}

pub fn forceObj(comptime T: type, obj: Object) Obj(T) {
    return .{ .data = @ptrCast(obj.data) };
}

pub fn coerceBool(obj: Object) Bool {
    if (castObj(Bool, obj)) |b| {
        return b.data.*;
    } else if (isType(Nil, obj)) {
        return false;
    } else {
        return true;
    }
}

pub fn coerceArray(obj: Object) OOM!?Obj(Array) {
    if (castObj(Array, obj)) |x| return x else if (castObj(Map, obj)) |x| {
        return try x.data.toArray();
    } else if (castObj(Set, obj)) |x| {
        return try x.data.toArray();
    } else if (castObj(Block, obj)) |x| {
        return try x.data.toArray();
    } else return null;
}

pub fn isArrayLike(obj: Object) bool {
    return isType(Array, obj) or isType(Map, obj) or isType(Set, obj) or isType(Block, obj);
}

pub fn isExactString(name: []const u8, obj: Object) bool {
    if (castObj(String, obj)) |sym| {
        return std.mem.eql(u8, sym.data.text(), name);
    } else {
        return false;
    }
}

pub fn isExactSymbol(name: []const u8, obj: Object) bool {
    if (castObj(Symbol, obj)) |sym| {
        return std.mem.eql(u8, sym.data.text(), name);
    } else {
        return false;
    }
}

pub const Array = TypedArray(ObjData);

pub fn TypedArray(comptime T: type) type {
    const NativeArray = std.ArrayListUnmanaged(Obj(T));

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        native_array: NativeArray = .{},

        pub fn create(allocator: std.mem.Allocator, values: []const Obj(T)) OOM!Self {
            var self = Self{ .allocator = allocator };
            try self.native_array.appendSlice(allocator, values);
            return self;
        }

        pub fn compare(self: Self, other: Self) std.math.Order {
            return utils.compare(self.native_array.items, other.native_array.items);
        }

        pub fn format(self: *const Self, comptime fmtStr: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
            const fmt = Format.fromStr(fmtStr) orelse .debug;
            const w = if (@TypeOf(writer) == std.io.AnyWriter) writer else writer.any();
            try w.print("array[{}]{{ ", .{self.native_array.items.len});
            for (self.native_array.items) |obj| {
                try obj.onFormat(fmt, w);
                try w.writeAll(" ");
            }
            try w.writeAll("}");
        }

        /// Shallow copy the array.
        pub fn clone(self: *const Self, origin: ?Origin) OOM!Obj(Self) {
            const arr = try self.native_array.clone(self.allocator);
            return Obj(Self).wrap(getRml(self), origin orelse getOrigin(self), Self{ .allocator = self.allocator, .native_array = arr });
        }

        /// Clear the array.
        pub fn clear(self: *Self) void {
            self.native_array.clearRetainingCapacity();
        }

        /// Length of the array.
        pub fn length(self: *const Self) Int {
            return @intCast(self.native_array.items.len);
        }

        /// Contents of the array.
        /// Pointers to elements in this slice are invalidated by various functions of this ArrayList in accordance with the respective documentation.
        /// In all cases, "invalidated" means that the memory has been passed to an allocator's resize or free function.
        pub fn items(self: *const Self) []Obj(T) {
            return self.native_array.items;
        }

        /// Get the last element of the array.
        pub fn last(self: *const Self) ?Obj(T) {
            return if (self.native_array.items.len > 0) self.native_array.items[self.native_array.items.len - 1] else null;
        }

        /// Get an element of the array.
        pub fn get(self: *const Self, index: usize) ?Obj(T) {
            return if (index < self.native_array.items.len) self.native_array.items[index] else null;
        }

        /// Insert item at index 0.
        /// Moves list[0 .. list.len] to higher indices to make room.
        /// This operation is O(N).
        /// Invalidates element pointers.
        pub fn prepend(self: *Self, val: Obj(T)) OOM!void {
            try self.native_array.insert(self.allocator, 0, val);
        }

        /// Insert item at index i.
        /// Moves list[i .. list.len] to higher indices to make room.
        /// This operation is O(N).
        /// Invalidates element pointers.
        pub fn insert(self: *Self, index: usize, val: Obj(T)) OOM!void {
            try self.native_array.insert(self.allocator, index, val);
        }

        /// Extend the array by 1 element.
        /// Allocates more memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        pub fn append(self: *Self, val: Obj(T)) OOM!void {
            try self.native_array.append(self.allocator, val);
        }

        /// Append the slice of items to the array. Allocates more memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        pub fn appendSlice(self: *Self, slice: []const Obj(T)) OOM!void {
            try self.native_array.appendSlice(self.allocator, slice);
        }
    };
}

pub const BlockKind = enum {
    doc,
    curly,
    square,
    paren,

    pub fn compare(a: BlockKind, b: BlockKind) std.math.Order {
        if (a == .doc or b == .doc) return .eq;
        return utils.compare(@intFromEnum(a), @intFromEnum(b));
    }

    pub fn toOpenStr(self: BlockKind) []const u8 {
        return switch (self) {
            .doc => "",
            .curly => "{",
            .square => "[",
            .paren => "(",
        };
    }

    pub fn toCloseStr(self: BlockKind) []const u8 {
        return switch (self) {
            .doc => "",
            .curly => "}",
            .square => "]",
            .paren => ")",
        };
    }

    pub fn toOpenStrFmt(self: BlockKind, format: Format) []const u8 {
        return switch (self) {
            .doc => if (format != .source) "⧼" else "",
            .curly => "{",
            .square => "[",
            .paren => "(",
        };
    }

    pub fn toCloseStrFmt(self: BlockKind, format: Format) []const u8 {
        return switch (self) {
            .doc => if (format != .source) "⧽" else "",
            .curly => "}",
            .square => "]",
            .paren => ")",
        };
    }
};

pub const Block = struct {
    allocator: std.mem.Allocator,
    kind: BlockKind = .doc,
    array: std.ArrayListUnmanaged(Object) = .{},

    pub fn create(rml: *Rml, kind: BlockKind, initialItems: []const Object) OOM!Block {
        const allocator = rml.blobAllocator();

        var array: std.ArrayListUnmanaged(Object) = .{};
        try array.appendSlice(allocator, initialItems);

        return .{
            .allocator = allocator,
            .kind = kind,
            .array = array,
        };
    }

    pub fn compare(self: Block, other: Block) std.math.Order {
        var ord = BlockKind.compare(self.kind, other.kind);

        if (ord == .eq) {
            ord = utils.compare(self.array.items, other.array.items);
        }

        return ord;
    }

    pub fn format(self: *const Block, comptime fmtStr: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
        const fmt = Format.fromStr(fmtStr) orelse .debug;
        const w = if (@TypeOf(writer) == std.io.AnyWriter) writer else writer.any();
        try w.writeAll(self.kind.toOpenStrFmt(fmt));
        for (self.items(), 0..) |item, i| {
            try item.onFormat(fmt, w);

            if (i < self.length() - 1) {
                try w.writeAll(" ");
            }
        }
        try w.writeAll(self.kind.toCloseStrFmt(fmt));
    }

    /// Length of the block.
    pub fn length(self: *const Block) Int {
        return @intCast(self.array.items.len);
    }

    /// Contents of the block.
    /// Pointers to elements in this slice are invalidated by various functions of this ArrayList in accordance with the respective documentation.
    /// In all cases, "invalidated" means that the memory has been passed to an allocator's resize or free function.
    pub fn items(self: *const Block) []Object {
        return self.array.items;
    }

    /// Convert a block to an array.
    pub fn toArray(self: *const Block) OOM!Obj(Array) {
        const allocator = getRml(self).blobAllocator();
        return try Obj(Array).wrap(getRml(self), getOrigin(self), try .create(allocator, self.items()));
    }

    /// Extend the block by 1 element.
    /// Allocates more memory as necessary.
    /// Invalidates element pointers if additional memory is needed.
    pub fn append(self: *Block, obj: Object) OOM!void {
        return self.array.append(self.allocator, obj);
    }

    /// Append the slice of items to the block. Allocates more memory as necessary.
    /// Invalidates element pointers if additional memory is needed.
    pub fn appendSlice(self: *Block, slice: []const Object) OOM!void {
        return self.array.appendSlice(self.allocator, slice);
    }
};

pub const Cell = struct {
    value: Object,

    pub fn onCompare(a: *Cell, other: Object) std.math.Order {
        var ord = utils.compare(getTypeId(a), other.getTypeId());
        if (ord == .eq) {
            const b = forceObj(Cell, other);
            ord = a.value.compare(b.data.value);
        } else if (utils.compare(a.value.getTypeId(), other.getTypeId()) == .eq) {
            ord = utils.compare(a.value, other);
        }
        return ord;
    }

    pub fn compare(self: Cell, other: Cell) std.math.Order {
        return self.value.compare(other.value);
    }

    pub fn onFormat(self: *Cell, fmt: Format, w: std.io.AnyWriter) anyerror!void {
        if (fmt == .debug) {
            try w.print("Cell({s})", .{self.value});
        } else {
            try self.value.onFormat(fmt, w);
        }
    }

    pub fn format(self: *Cell, comptime fmtStr: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
        const fmt = Format.fromStr(fmtStr) orelse .debug;
        const w = if (@TypeOf(writer) == std.io.AnyWriter) writer else writer.any();
        try self.onFormat(fmt, w);
    }

    pub fn set(self: *Cell, value: Object) void {
        self.value = value;
    }

    pub fn get(self: *Cell) Object {
        return self.value;
    }
};

pub const Domain = std.ArrayHashMapUnmanaged(Obj(Symbol), void, utils.SimpleHashContext, true);
pub const CellTable = std.ArrayHashMapUnmanaged(Obj(Symbol), Obj(Cell), utils.SimpleHashContext, true);

pub const Env = struct {
    allocator: std.mem.Allocator,
    table: CellTable = .{},

    pub fn compare(self: Env, other: Env) std.math.Order {
        var ord = utils.compare(self.keys(), other.keys());

        if (ord == .eq) {
            ord = utils.compare(self.cells(), other.cells());
        }

        return ord;
    }

    pub fn format(self: *const Env, comptime fmtStr: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
        const fmt = Format.fromStr(fmtStr) orelse .debug;
        const w = if (@TypeOf(writer) == std.io.AnyWriter) writer else writer.any();
        try w.writeAll("env{ ");
        var it = self.table.iterator();
        while (it.next()) |entry| {
            try w.writeAll("(");
            try entry.key_ptr.onFormat(fmt, w);
            try w.writeAll(" = ");
            try entry.value_ptr.onFormat(fmt, w);
            try w.writeAll(") ");
        }
        try w.writeAll("}");
    }

    /// Shallow copy an Env.
    pub fn clone(self: *const Env, origin: ?Origin) OOM!Obj(Env) {
        const table = try self.table.clone(self.allocator);

        return try .wrap(getRml(self), origin orelse getOrigin(self), .{ .allocator = self.allocator, .table = table });
    }

    /// Set a value associated with a key in this Env.
    ///
    /// If the key is already bound, a new cell is created, overwriting the old one
    ///
    /// Returns an error if:
    /// * Rml is out of memory
    pub fn rebind(self: *Env, key: Obj(Symbol), val: Object) OOM!void {
        const cell = try Obj(Cell).wrap(getRml(self), key.getOrigin(), .{ .value = val });

        try self.table.put(self.allocator, key, cell);
    }

    /// Bind a value to a new key
    ///
    /// Returns an error if:
    /// * a value with the same name was already declared in this scope
    /// * Rml is out of memory
    pub fn bind(self: *Env, key: Obj(Symbol), val: Object) (OOM || SymbolAlreadyBound)!void {
        if (self.contains(key)) return error.SymbolAlreadyBound;

        return self.rebind(key, val);
    }

    /// Bind a value to an existing key
    ///
    /// Returns an error if:
    /// * binding does not exist in this env
    pub fn set(self: *Env, key: Obj(Symbol), val: Object) UnboundSymbol!void {
        return if (self.table.getEntry(key)) |entry| {
            entry.value_ptr.data.set(val);
        } else error.UnboundSymbol;
    }

    /// Find the value bound to a symbol in the env
    pub fn get(self: *const Env, key: Obj(Symbol)) ?Object {
        if (self.table.getEntry(key)) |entry| {
            return entry.value_ptr.data.get();
        }

        return null;
    }

    /// Returns the number of bindings in the env
    pub fn length(self: *const Env) Int {
        return @intCast(self.table.count());
    }

    /// Check whether a key is bound in the env
    pub fn contains(self: *const Env, key: Obj(Symbol)) bool {
        return self.table.contains(key);
    }

    /// Get a slice of the keys of this Env
    pub fn keys(self: *const Env) []Obj(Symbol) {
        return self.table.keys();
    }

    /// Get a slice of the cells of this Env
    pub fn cells(self: *const Env) []Obj(Cell) {
        return self.table.values();
    }

    /// Copy all bindings from another env
    pub fn copyFromEnv(self: *Env, other: *Env) (OOM || SymbolAlreadyBound)!void {
        var it = other.table.iterator();
        while (it.next()) |entry| {
            try self.rebindCell(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    /// Copy all bindings from a table
    pub fn copyFromTable(self: *Env, table: *const Table) (OOM || SymbolAlreadyBound)!void {
        var it = table.native_map.iterator();
        while (it.next()) |entry| {
            try self.rebind(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    /// Set a cell associated with a key
    ///
    /// If the key is already bound, overwrites the old one
    ///
    /// Returns an error if:
    /// * Rml is out of memory
    pub fn rebindCell(self: *Env, key: Obj(Symbol), cell: Obj(Cell)) OOM!void {
        try self.table.put(self.allocator, key, cell);
    }

    /// Bind a cell to a new key
    ///
    /// Returns an error if:
    /// * a value with the same name was already declared in this scope
    /// * Rml is out of memory
    pub fn bindCell(self: *Env, key: Obj(Symbol), cell: Obj(Cell)) (OOM || SymbolAlreadyBound)!void {
        if (self.contains(key)) return error.SymbolAlreadyBound;

        try self.table.put(self.allocator, key, cell);
    }

    /// Copy all bindings from a Zig namespace
    pub fn bindNamespace(self: *Env, namespace: anytype) OOM!void {
        const T = @TypeOf(namespace);
        const rml = getRml(self);
        const origin = Origin.fromComptimeStr("builtin-" ++ @typeName(T));
        inline for (comptime std.meta.fields(T)) |field| {
            const sym: Obj(Symbol) = try .wrap(rml, origin, try .create(rml, field.name));

            if (comptime bindgen.isObj(field.type)) {
                self.bind(sym, @field(namespace, field.name).typeErase()) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory else @panic(@errorName(err));
                };
            } else {
                const val: Obj(field.type) = try .wrap(rml, origin, @field(namespace, field.name));

                self.bind(sym, val.typeErase()) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory else @panic(@errorName(err));
                };
            }
        }
    }
};

pub const Map = TypedMap(ObjData, ObjData);

pub fn TypedMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        native_map: NativeMap = .{},

        pub const NativeIter = NativeMap.Iterator;
        pub const NativeMap = std.ArrayHashMapUnmanaged(Obj(K), Obj(V), utils.SimpleHashContext, true);

        pub fn compare(self: Self, other: Self) std.math.Order {
            var ord = utils.compare(self.keys().len, other.keys().len);

            if (ord == .eq) {
                ord = utils.compare(self.keys(), other.keys());
            }

            if (ord == .eq) {
                ord = utils.compare(self.values(), other.values());
            }

            return ord;
        }

        pub fn format(self: *const Self, comptime fmtStr: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
            const fmt = Format.fromStr(fmtStr) orelse .debug;
            const w = if (@TypeOf(writer) == std.io.AnyWriter) writer else writer.any();

            try w.writeAll("map{ ");

            var it = self.native_map.iterator();
            while (it.next()) |entry| {
                try w.writeAll("(");
                try entry.key_ptr.onFormat(fmt, w);
                try w.writeAll(" = ");
                try entry.value_ptr.onFormat(fmt, w);
                try w.writeAll(") ");
            }

            try w.writeAll("}");
        }

        /// Set the value associated with a key
        pub fn set(self: *Self, key: Obj(K), val: Obj(V)) OOM!void {
            if (self.native_map.getEntry(key)) |entry| {
                entry.key_ptr.* = key;
                entry.value_ptr.* = val;
            } else {
                try self.native_map.put(self.allocator, key, val);
            }
        }

        /// Find the value associated with a key
        pub fn get(self: *const Self, key: Obj(K)) ?Obj(V) {
            return self.native_map.get(key);
        }

        /// Returns the number of key-value pairs in the map
        pub fn length(self: *const Self) Int {
            return @intCast(self.native_map.count());
        }

        /// Check whether a key is stored in the map
        pub fn contains(self: *const Self, key: Obj(K)) bool {
            return self.native_map.contains(key);
        }

        // / Returns an iterator over the pairs in this map. Modifying the map may invalidate this iterator.
        // pub fn iter(self: *const Self) NativeIter {
        //     return self.native_map.iterator();
        // }

        /// Returns the backing array of keys in this map. Modifying the map may invalidate this array.
        /// Modifying this array in a way that changes key hashes or key equality puts the map into an unusable state until reIndex is called.
        pub fn keys(self: *const Self) []Obj(K) {
            return self.native_map.keys();
        }

        /// Returns the backing array of values in this map.
        /// Modifying the map may invalidate this array.
        /// It is permitted to modify the values in this array.
        pub fn values(self: *const Self) []Obj(V) {
            return self.native_map.values();
        }

        /// Recomputes stored hashes and rebuilds the key indexes.
        /// If the underlying keys have been modified directly,
        /// call this method to recompute the denormalized metadata
        /// necessary for the operation of the methods of this map that lookup entries by key.
        pub fn reIndex(self: *Self, rml: *Rml) OOM!void {
            return self.native_map.reIndex(rml.blobAllocator());
        }

        /// Convert a map to an array of key-value pairs.
        pub fn toArray(self: *Self) OOM!Obj(Array) {
            const rml = getRml(self);
            var it = self.native_map.iterator();

            var out: Obj(Array) = try .wrap(rml, getOrigin(self), .{ .allocator = rml.blobAllocator() });

            while (it.next()) |entry| {
                var pair: Obj(Array) = try .wrap(rml, getOrigin(self), try .create(rml.blobAllocator(), &.{
                    entry.key_ptr.typeErase(),
                    entry.value_ptr.typeErase(),
                }));

                try out.data.append(pair.typeErase());
            }

            return out;
        }

        pub fn clone(self: *Self) OOM!Self {
            const newMap = Self{ .allocator = self.allocator, .native_map = try self.native_map.clone(self.allocator) };
            return newMap;
        }

        pub fn copyFrom(self: *Self, other: *Self) OOM!void {
            var it = other.native_map.iterator();
            while (it.next()) |entry| {
                try self.set(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    };
}

pub const Alias = struct {
    sym: Obj(Symbol),
    sub: Object,

    pub fn compare(self: Alias, other: Alias) std.math.Order {
        var ord = self.sym.compare(other.sym);

        if (ord == .eq) {
            ord = self.sub.onCompare(other.sub);
        }

        return ord;
    }
};

pub const Pattern = union(enum) {
    // _                    ;wildcard
    wildcard: void,

    // x                    ;variable
    symbol: Obj(Symbol),

    // () [] {}             ;interchangeable block syntax
    // ~() ~[] ~{}          ;literal block syntax
    block: Obj(Block),

    // nil true 1 'c' "foo" ;literal
    value_literal: Object,

    // *(foo?) *(@foo x y)  ;procedural literal syntax
    procedure: Object,

    // 'foo '(foo)          ;value-wise quotation
    // `foo `(foo)          ;pattern-wise quotation
    // ,foo ,@foo           ;unquote, unquote-splicing
    quote: Obj(Quote),

    // (as symbol patt)     ;aliasing ;outer block is not-a-block
    alias: Alias,

    // x y z                ;bare sequence
    sequence: Obj(Array),

    // (? patt)             ;optional ;outer block is not-a-block
    optional: Object,

    // (* patt)             ;zero or more ;outer block is not-a-block
    zero_or_more: Object,

    // (+ patt)             ;one or more ;outer block is not-a-block
    one_or_more: Object,

    // (| patt patt)        ;alternation ;outer block is not-a-block
    alternation: Obj(Array),

    pub fn compare(self: Pattern, other: Pattern) std.math.Order {
        var ord = utils.compare(std.meta.activeTag(self), std.meta.activeTag(other));

        if (ord == .eq) {
            ord = switch (self) {
                .wildcard => ord,
                .symbol => |x| x.compare(other.symbol),
                .block => |x| x.compare(other.block),
                .value_literal => |x| x.compare(other.value_literal),
                .procedure => |x| x.compare(other.procedure),
                .quote => |x| x.compare(other.quote),
                .alias => |x| x.compare(other.alias),
                .sequence => |x| x.compare(other.sequence),
                .optional => |x| x.compare(other.optional),
                .zero_or_more => |x| x.compare(other.zero_or_more),
                .one_or_more => |x| x.compare(other.one_or_more),
                .alternation => |x| x.compare(other.alternation),
            };
        }

        return ord;
    }

    pub fn format(self: *const Pattern, comptime fmtStr: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
        const fmt = Format.fromStr(fmtStr) orelse .debug;
        const w = if (@TypeOf(writer) == std.io.AnyWriter) writer else writer.any();
        switch (self.*) {
            .wildcard => try w.writeAll("_"),
            .symbol => |x| try x.onFormat(fmt, w),
            .block => |x| try x.onFormat(fmt, w),
            .value_literal => |x| try x.onFormat(fmt, w),
            .procedure => |x| try x.onFormat(fmt, w),
            .quote => |x| try x.onFormat(fmt, w),
            .sequence => |x| {
                try w.writeAll("${");
                try Format.slice(x.data.items()).onFormat(fmt, w);
                try w.writeAll("}");
            },
            .alias => |alias| {
                try w.writeAll("{as ");
                try alias.sym.onFormat(fmt, w);
                try w.writeAll(" ");
                try alias.sub.onFormat(fmt, w);
                try w.writeAll("}");
            },
            .optional => |optional| {
                try w.writeAll("{? ");
                try optional.onFormat(fmt, w);
                try w.writeAll("}");
            },
            .zero_or_more => |zero_or_more| {
                try w.writeAll("{* ");
                try zero_or_more.onFormat(fmt, w);
                try w.writeAll("}");
            },
            .one_or_more => |one_or_more| {
                try w.writeAll("{+ ");
                try one_or_more.onFormat(fmt, w);
                try w.writeAll("}");
            },
            .alternation => |alternation| {
                try w.writeAll("{| ");
                try Format.slice(alternation.data.items()).onFormat(fmt, w);
                try w.writeAll("}");
            },
        }
    }

    pub fn binders(self: *Pattern) (OOM || error{BadDomain})!Domain {
        return patternBinders(getObj(self).typeErase());
    }

    pub fn run(self: *Pattern, interpreter: *Interpreter, diag: ?*?Diagnostic, origin: Origin, input: []const Object) Result!?Obj(Table) {
        const obj = getObj(self);

        log.match.debug("Pattern.run `{} :: {any}` @ {}", .{ obj, input, origin });

        var offset: usize = 0;

        const out = try out: {
            if (self.* == .block) {
                if (input.len == 1 and isArrayLike(input[0])) {
                    log.match.debug("block pattern with array-like input", .{});
                    const inner = try coerceArray(input[0]) orelse @panic("array-like object is not an array");

                    break :out runSequence(interpreter, diag, origin, self.block.data.items(), inner.data.items(), &offset);
                } else {
                    log.match.debug("block pattern with input stream", .{});
                    break :out runSequence(interpreter, diag, origin, self.block.data.items(), input, &offset);
                }
            } else {
                log.match.debug("non-block pattern with input stream", .{});
                break :out runPattern(interpreter, diag, origin, obj, input, &offset);
            }
        } orelse {
            log.match.debug("Pattern.run failed", .{});
            return null;
        };

        if (offset < input.len) {
            return patternAbort(diag, origin, "expected end of input, got `{}`", .{input[offset]});
        }

        return out;
    }

    pub fn parse(diag: ?*?Diagnostic, input: []const Object) (OOM || SyntaxError)!?ParseResult(Pattern) {
        var offset: usize = 0;
        const pattern = try parsePattern(diag, input, &offset) orelse return null;
        return .{
            .value = pattern,
            .offset = offset,
        };
    }
};

pub fn ParseResult(comptime T: type) type {
    return struct {
        value: Obj(T),
        offset: usize,
    };
}

pub const Table = TypedMap(Symbol, ObjData);

pub fn patternBinders(patternObj: Object) (OOM || error{BadDomain})!Domain {
    const rml = patternObj.getRml();

    const pattern = castObj(Pattern, patternObj) orelse return .{};

    var domain: Domain = .{};

    switch (pattern.data.*) {
        .wildcard,
        .value_literal,
        .procedure,
        .quote,
        => {},

        .symbol => |symbol| try domain.put(rml.blobAllocator(), symbol, {}),

        .block => |block| for (block.data.items()) |item| {
            const subDomain = try patternBinders(item);
            for (subDomain.keys()) |key| {
                try domain.put(rml.blobAllocator(), key, {});
            }
        },

        .alias => |alias| try domain.put(rml.blobAllocator(), alias.sym, {}),

        .sequence => |sequence| for (sequence.data.items()) |item| {
            const subDomain = try patternBinders(item);
            for (subDomain.keys()) |key| {
                try domain.put(rml.blobAllocator(), key, {});
            }
        },

        .optional => |optional| {
            const subDomain = try patternBinders(optional);
            for (subDomain.keys()) |key| {
                try domain.put(rml.blobAllocator(), key, {});
            }
        },

        .zero_or_more => |zero_or_more| {
            const subDomain = try patternBinders(zero_or_more);
            for (subDomain.keys()) |key| {
                try domain.put(rml.blobAllocator(), key, {});
            }
        },

        .one_or_more => |one_or_more| {
            const subDomain = try patternBinders(one_or_more);
            for (subDomain.keys()) |key| {
                try domain.put(rml.blobAllocator(), key, {});
            }
        },

        .alternation => |alternation| {
            var referenceSubDomain: ?Domain = null;
            for (alternation.data.items()) |item| {
                var subDomain = try patternBinders(item);

                if (referenceSubDomain) |refDomain| {
                    if (utils.equal(refDomain, subDomain)) {
                        for (subDomain.keys()) |key| {
                            try domain.put(rml.blobAllocator(), key, {});
                        }
                    } else {
                        return error.BadDomain;
                    }
                } else {
                    referenceSubDomain = subDomain;
                }
            }
        },
    }

    return domain;
}

pub fn nilBinders(interpreter: *Interpreter, table: Obj(Table), origin: Origin, patt: Obj(Pattern)) Result!void {
    var binders = patternBinders(patt.typeErase()) catch |err| switch (err) {
        error.BadDomain => try interpreter.abort(patt.getOrigin(), error.PatternFailed, "bad domain in pattern `{}`", .{patt}),
        error.OutOfMemory => return error.OutOfMemory,
    };

    const nil = (try Obj(Nil).wrap(getRml(interpreter), origin, .{})).typeErase();

    for (binders.keys()) |key| {
        try table.data.set(key, nil);
    }
}

pub fn runPattern(
    interpreter: *Interpreter,
    diag: ?*?Diagnostic,
    origin: Origin,
    pattern: Obj(Pattern),
    objects: []const Object,
    offset: *usize,
) Result!?Obj(Table) {
    const table: Obj(Table) = try .wrap(getRml(interpreter), origin, .{
        .allocator = getRml(interpreter).blobAllocator(),
    });

    log.match.debug("runPattern `{} :: {?}` {any} {}", .{ pattern, if (offset.* < objects.len) objects[offset.*] else null, objects, offset.* });

    switch (pattern.data.*) {
        .wildcard => {},

        .symbol => |symbol| {
            log.match.debug("match symbol {}", .{symbol});
            if (offset.* >= objects.len) return patternAbort(diag, origin, "unexpected end of input", .{});
            const input = objects[offset.*];
            offset.* += 1;
            log.match.debug("input {}", .{input});
            try table.data.set(symbol, input);
            log.match.debug("bound", .{});
        },

        .block => |block| {
            log.match.debug("match block {}", .{block});
            const patts = block.data.items();
            if (offset.* >= objects.len) return patternAbort(diag, origin, "expected {}, got end of input", .{block});

            if (castObj(Block, objects[offset.*])) |inputBlock| {
                offset.* += 1;

                const seqOrigin = pattern.getOrigin();
                switch (block.data.kind) {
                    .doc => {
                        var newOffset: usize = 0;
                        const result = try runSequence(interpreter, diag, inputBlock.getOrigin(), patts, inputBlock.data.items(), &newOffset) orelse return null;
                        try table.data.copyFrom(result.data);
                    },
                    else => if (inputBlock.data.kind == block.data.kind) {
                        var newOffset: usize = 0;
                        const result = try runSequence(interpreter, diag, inputBlock.getOrigin(), patts, inputBlock.data.items(), &newOffset) orelse return null;
                        try table.data.copyFrom(result.data);
                    } else return patternAbort(diag, seqOrigin, "expected a `{s}{s}` block, found `{s}{s}`", .{
                        block.data.kind.toOpenStr(),
                        block.data.kind.toCloseStr(),
                        inputBlock.data.kind.toOpenStr(),
                        inputBlock.data.kind.toCloseStr(),
                    }),
                }
            } else {
                const input = objects[offset.*];
                offset.* += 1;
                return patternAbort(diag, pattern.getOrigin(), "expected a block, found `{}`", .{input});
            }
        },

        .value_literal => |value_literal| {
            log.match.debug("match value {}", .{value_literal});

            if (offset.* >= objects.len) return patternAbort(diag, origin, "expected {}, got end of input", .{value_literal});

            const input = objects[offset.*];
            offset.* += 1;

            if (value_literal.onCompare(input) != .eq)
                return patternAbort(diag, input.getOrigin(), "expected `{}`, got `{}`", .{ value_literal, input });
        },

        .procedure => |procedure| {
            log.match.debug("match procedure call {}", .{procedure});

            if (offset.* >= objects.len) return patternAbort(diag, origin, "expected a procedure, got end of input", .{});

            const input = objects[offset.*];
            offset.* += 1;

            const result = try interpreter.invoke(input.getOrigin(), pattern.typeErase(), procedure, &.{input});
            if (!coerceBool(result))
                return patternAbort(diag, input.getOrigin(), "expected a truthy value, got `{}`", .{input});
        },

        .quote => |quote| {
            if (offset.* >= objects.len) return patternAbort(diag, origin, "expected {}, got end of input", .{quote});

            const input = objects[offset.*];
            offset.* += 1;

            switch (quote.data.kind) {
                .basic => {
                    const patt = quote.data.body;
                    if (patt.onCompare(input) != .eq) return patternAbort(diag, input.getOrigin(), "expected `{}`, got `{}`", .{ patt, input });
                },
                .quasi => {
                    const w = try runQuasi(interpreter, quote.data.body, null);
                    if (w.onCompare(input) != .eq) return patternAbort(diag, input.getOrigin(), "expected `{}`, got `{}`", .{ w, input });
                },
                .to_quote => {
                    const v = try interpreter.eval(quote.data.body);
                    const q = try Obj(Quote).wrap(getRml(interpreter), quote.getOrigin(), .{ .kind = .basic, .body = v });
                    if (q.onCompare(input) != .eq) return patternAbort(diag, input.getOrigin(), "expected `{}`, got `{}`", .{ q, input });
                },
                .to_quasi => {
                    const v = try interpreter.eval(quote.data.body);
                    const q = try Obj(Quote).wrap(getRml(interpreter), quote.getOrigin(), .{ .kind = .quasi, .body = v });
                    if (q.onCompare(input) != .eq) return patternAbort(diag, input.getOrigin(), "expected `{}`, got `{}`", .{ q, input });
                },
                .unquote, .unquote_splice => try interpreter.abort(quote.getOrigin(), error.UnexpectedInput, "unquote syntax is not allowed in this context, found `{}`", .{quote}),
            }
        },

        .alias => |alias| {
            const sub: Obj(Pattern) = castObj(Pattern, alias.sub) orelse {
                try interpreter.abort(alias.sub.getOrigin(), error.UnexpectedInput, "alias syntax expects a pattern in this context, found `{}`", .{alias.sub});
            };
            const result = try runPattern(interpreter, diag, origin, sub, objects, offset) orelse return null;
            if (result.data.length() > 0) {
                try table.data.set(alias.sym, result.typeErase());
            } else {
                if (offset.* < objects.len) {
                    try table.data.set(alias.sym, objects[offset.*]);
                } else {
                    try table.data.set(alias.sym, (try Obj(Nil).wrap(getRml(interpreter), origin, .{})).typeErase());
                }
            }
        },

        .sequence => |sequence| {
            const subEnv = try runSequence(interpreter, diag, sequence.getOrigin(), sequence.data.items(), objects, offset) orelse return null;

            try table.data.copyFrom(subEnv.data);
        },

        .optional => |optional| {
            const patt = castObj(Pattern, optional) orelse {
                try interpreter.abort(optional.getOrigin(), error.TypeError, "optional syntax expects a pattern in this context, found `{}`", .{optional});
            };

            var subOffset = offset.*;
            const result = try runPattern(interpreter, null, origin, patt, objects, &subOffset);

            if (result) |res| {
                offset.* = subOffset;

                try table.data.copyFrom(res.data);
            } else {
                try nilBinders(interpreter, table, origin, patt);
            }
        },

        .zero_or_more => |zero_or_more| {
            const patt = castObj(Pattern, zero_or_more) orelse {
                try interpreter.abort(zero_or_more.getOrigin(), error.TypeError, "zero-or-more syntax expects a pattern in this context, found `{}`", .{zero_or_more});
            };

            var i: usize = 0;

            var binders = patternBinders(patt.typeErase()) catch |err| switch (err) {
                error.BadDomain => try interpreter.abort(patt.getOrigin(), error.PatternFailed, "bad domain in pattern `{}`", .{patt}),
                error.OutOfMemory => return error.OutOfMemory,
            };

            for (binders.keys()) |key| {
                const k = key;

                const obj = try Obj(Array).wrap(getRml(interpreter), origin, .{ .allocator = getRml(interpreter).blobAllocator() });

                try table.data.set(k, obj.typeErase());
            }

            while (offset.* < objects.len) {
                var subOffset = offset.*;
                log.match.debug("*{} `{} :: {}`", .{ i, patt, objects[subOffset] });
                const result = try runPattern(interpreter, null, origin, patt, objects, &subOffset);
                if (result) |res| {
                    i += 1;

                    for (res.data.keys()) |key| {
                        const arrayObj = table.data.get(key) orelse @panic("binder not in patternBinders result");

                        const array = castObj(Array, arrayObj) orelse {
                            try interpreter.abort(arrayObj.getOrigin(), error.TypeError, "expected an array, found `{}`", .{arrayObj});
                        };

                        const erase = res.typeErase();

                        try array.data.append(erase);
                    }

                    offset.* = subOffset;
                } else {
                    break;
                }
            }
        },

        .one_or_more => |one_or_more| {
            const patt = castObj(Pattern, one_or_more) orelse {
                try interpreter.abort(one_or_more.getOrigin(), error.TypeError, "one-or-more syntax expects a pattern in this context, found `{}`", .{one_or_more});
            };

            var binders = patternBinders(patt.typeErase()) catch |err| switch (err) {
                error.BadDomain => try interpreter.abort(patt.getOrigin(), error.PatternFailed, "bad domain in pattern {}", .{patt}),
                error.OutOfMemory => return error.OutOfMemory,
            };

            for (binders.keys()) |key| {
                const k = key;

                const obj = try Obj(Array).wrap(getRml(interpreter), origin, .{ .allocator = getRml(interpreter).blobAllocator() });

                try table.data.set(k, obj.typeErase());
            }

            var i: usize = 0;

            while (offset.* < objects.len) {
                var subOffset = offset.*;
                log.match.debug("+{} `{} :: {}`", .{ i, patt, objects[subOffset] });
                const result = try runPattern(interpreter, null, origin, patt, objects, &subOffset);
                log.match.debug("✓", .{});
                if (result) |res| {
                    log.match.debug("matched `{} :: {}`", .{ patt, objects[offset.*] });

                    i += 1;

                    for (res.data.keys()) |key| {
                        const arrayObj = table.data.get(key) orelse @panic("binder not in patternBinders result");

                        const array = castObj(Array, arrayObj) orelse {
                            try interpreter.abort(arrayObj.getOrigin(), error.TypeError, "expected an array, found {}", .{arrayObj});
                        };

                        const erase = res.typeErase();

                        try array.data.append(erase);
                    }

                    offset.* = subOffset;
                } else {
                    break;
                }
            }

            if (i == 0) {
                return patternAbort(diag, origin, "expected at least one match for pattern {}", .{patt});
            }
        },

        .alternation => |alternation| {
            const pattObjs = alternation.data.items();
            var errs: String = try .create(getRml(interpreter), "");

            const errWriter = errs.writer();

            loop: for (pattObjs) |pattObj| {
                const patt = castObj(Pattern, pattObj) orelse {
                    try interpreter.abort(pattObj.getOrigin(), error.UnexpectedInput, "alternation syntax expects a pattern in this context, found `{}`", .{pattObj});
                };

                var diagStorage: ?Diagnostic = null;
                const newDiag = if (diag != null) &diagStorage else null;

                var subOffset = offset.*;
                const result = try runPattern(interpreter, newDiag, origin, patt, objects, &subOffset);

                if (result) |res| {
                    offset.* = subOffset;

                    try table.data.copyFrom(res.data);

                    break :loop;
                } else if (newDiag) |dx| {
                    if (dx.*) |d| {
                        const formatter = d.formatter(error.PatternMatch);
                        log.debug("failed alternative {}", .{formatter});
                        errWriter.print("\t{}\n", .{formatter}) catch |e| @panic(@errorName(e));
                    } else {
                        log.warn("requested pattern diagnostic is null", .{});
                        errWriter.print("\tfailed\n", .{}) catch |e| @panic(@errorName(e));
                    }
                }
            }

            return patternAbort(diag, objects[offset.*].getOrigin(), "all alternatives failed:\n{s}", .{errs.text()});
        },
    }

    log.match.debug("completed runPattern, got {}", .{table});

    var it = table.data.native_map.iterator();
    while (it.next()) |entry| {
        log.match.debug("{} :: {}", .{
            entry.key_ptr.*,
            entry.value_ptr.*,
        });
    }

    return table;
}

fn runSequence(
    interpreter: *Interpreter,
    diag: ?*?Diagnostic,
    origin: Origin,
    patterns: []const Object,
    objects: []const Object,
    offset: *usize,
) Result!?Obj(Table) {
    const table: Obj(Table) = try .wrap(getRml(interpreter), origin, .{ .allocator = getRml(interpreter).blobAllocator() });

    for (patterns, 0..) |patternObj, p| {
        _ = p;

        const pattern = castObj(Pattern, patternObj) orelse {
            try interpreter.abort(patternObj.getOrigin(), error.UnexpectedInput, "sequence syntax expects a pattern in this context, found `{}`", .{patternObj});
        };

        const result = try runPattern(interpreter, diag, origin, pattern, objects, offset) orelse return null;

        try table.data.copyFrom(result.data);
    }

    if (offset.* < objects.len) return patternAbort(diag, origin, "unexpected input `{}`", .{objects[offset.*]});

    return table;
}

fn patternAbort(diagnostic: ?*?Diagnostic, origin: Origin, comptime fmt: []const u8, args: anytype) ?Obj(Table) {
    const diagPtr = diagnostic orelse return null;

    var diag = Diagnostic{
        .error_origin = origin,
    };

    // the error produced is only NoSpaceLeft, if the buffer is too small, so give the length of the buffer
    diag.message_len = len: {
        break :len (std.fmt.bufPrintZ(&diag.message_mem, fmt, args) catch {
            log.warn("Pattern Diagnostic message too long, truncating", .{});
            break :len Diagnostic.MAX_LENGTH;
        }).len;
    };

    diagPtr.* = diag;

    return null;
}

fn abortParse(diagnostic: ?*?Diagnostic, origin: Origin, err: (OOM || SyntaxError), comptime fmt: []const u8, args: anytype) (OOM || SyntaxError)!noreturn {
    const diagPtr = diagnostic orelse return err;

    var diag = Diagnostic{
        .error_origin = origin,
    };

    // the error produced is only NoSpaceLeft, if the buffer is too small, so give the length of the buffer
    diag.message_len = len: {
        break :len (std.fmt.bufPrintZ(&diag.message_mem, fmt, args) catch {
            log.warn("Diagnostic message too long, truncating", .{});
            break :len Diagnostic.MAX_LENGTH;
        }).len;
    };

    diagPtr.* = diag;

    return err;
}

fn parseSequence(rml: *Rml, diag: ?*?Diagnostic, objects: []const Object, offset: *usize) (OOM || SyntaxError)!?[]Obj(Pattern) {
    log.match.debug("parseSequence {any} {}", .{ objects, offset.* });
    var output: std.ArrayListUnmanaged(Obj(Pattern)) = .{};

    while (offset.* < objects.len) {
        const patt = try parsePattern(diag, objects, offset) orelse return null;

        try output.append(rml.blobAllocator(), patt);
    }

    return output.items;
}

fn parsePattern(diag: ?*?Diagnostic, objects: []const Object, offset: *usize) (OOM || SyntaxError)!?Obj(Pattern) {
    const input = objects[offset.*];

    for (SENTINEL_SYMBOLS) |sentinel| {
        if (castObj(Symbol, input)) |sym| {
            if (std.mem.eql(u8, sym.data.text(), sentinel)) {
                return null;
            }
        }
    }
    offset.* += 1;

    const rml = input.getRml();

    if (castObj(Pattern, input)) |patt| {
        log.match.debug("parsePattern got existing pattern `{}`", .{patt});
        return patt;
    } else {
        log.match.debug("parsePattern {}:`{}` {any} {}", .{ input.getOrigin(), input, objects, offset.* });
        const body: Pattern =
            if (castObj(Symbol, input)) |sym|
        sym: {
            log.match.debug("parsePattern symbol", .{});

            break :sym if (BUILTIN_SYMBOLS.matchText(sym.data.text())) |fun| {
                return try fun(diag, input, objects, offset);
            } else .{ .symbol = sym };
        } else if (isAtom(input)) .{ .value_literal = input } else if (castObj(Quote, input)) |quote| .{ .quote = quote } else if (castObj(Block, input)) |block| block: {
            log.match.debug("parsePattern block", .{});

            if (block.data.length() > 0) not_a_block: {
                const items = block.data.items();

                const symbol = castObj(Symbol, items[0]) orelse break :not_a_block;

                inline for (comptime std.meta.declarations(NOT_A_BLOCK)) |decl| {
                    if (std.mem.eql(u8, decl.name, symbol.data.text())) {
                        log.match.debug("using {} as a not-a-block pattern", .{symbol});
                        var subOffset: usize = 1;
                        return try @field(NOT_A_BLOCK, decl.name)(diag, input, block.data.items(), &subOffset);
                    }
                }
            }

            var subOffset: usize = 0;
            const seq: []Obj(Pattern) = try parseSequence(rml, diag, block.data.items(), &subOffset) orelse return null;

            break :block Pattern{ .block = try Obj(Block).wrap(rml, input.getOrigin(), try .create(rml, .doc, @ptrCast(seq))) };
        } else {
            try abortParse(diag, input.getOrigin(), error.UnexpectedInput, "`{}` is not a valid pattern", .{input});
        };

        return try Obj(Pattern).wrap(rml, input.getOrigin(), body);
    }
}

const SENTINEL_SYMBOLS: []const []const u8 = &.{"=>"};

const BUILTIN_SYMBOLS = struct {
    fn matchText(text: []const u8) ?*const fn (?*?Diagnostic, Object, []const Object, *usize) (OOM || SyntaxError)!Obj(Pattern) {
        inline for (comptime std.meta.declarations(BUILTIN_SYMBOLS)) |decl| {
            if (std.mem.eql(u8, decl.name, text)) return @field(BUILTIN_SYMBOLS, decl.name);
        }
        return null;
    }

    pub fn @"_"(_: ?*?Diagnostic, input: Object, _: []const Object, _: *usize) (OOM || SyntaxError)!Obj(Pattern) {
        return Obj(Pattern).wrap(input.getRml(), input.getOrigin(), .wildcard);
    }

    /// literal block syntax; expect a block, return that exact block kind (do not change to doc like default)
    pub fn @"~"(diag: ?*?Diagnostic, input: Object, objects: []const Object, offset: *usize) (OOM || SyntaxError)!Obj(Pattern) {
        const rml = input.getRml();
        const origin = input.getOrigin();

        if (offset.* >= objects.len) return error.UnexpectedEOF;

        const block = castObj(Block, objects[offset.*]) orelse {
            return error.UnexpectedInput;
        };
        offset.* += 1;

        var subOffset: usize = 0;
        const body = try parseSequence(rml, diag, block.data.items(), &subOffset);

        const patternBlock = try Obj(Block).wrap(rml, origin, try .create(rml, block.data.kind, @ptrCast(body)));

        return Obj(Pattern).wrap(rml, origin, .{ .block = patternBlock });
    }

    pub fn @"$"(diag: ?*?Diagnostic, input: Object, objects: []const Object, offset: *usize) (OOM || SyntaxError)!Obj(Pattern) {
        const rml = input.getRml();
        const origin = input.getOrigin();

        if (offset.* >= objects.len) return error.UnexpectedEOF;

        const block = castObj(Block, objects[offset.*]) orelse try abortParse(diag, origin, error.UnexpectedInput, "expected a block to escape following `$`, got `{}`", .{objects[offset.*]});
        offset.* += 1;

        const seq = seq: {
            const items = try block.data.array.clone(input.getRml().blobAllocator());

            break :seq try Obj(Array).wrap(rml, origin, .{ .allocator = input.getRml().blobAllocator(), .native_array = items });
        };

        return Obj(Pattern).wrap(rml, origin, .{ .sequence = seq });
    }
};

const NOT_A_BLOCK = struct {
    fn recursive(comptime name: []const u8) *const fn (?*?Diagnostic, Object, []const Object, *usize) (OOM || SyntaxError)!Obj(Pattern) {
        return &struct {
            pub fn fun(diag: ?*?Diagnostic, obj: Object, objects: []const Object, offset: *usize) (OOM || SyntaxError)!Obj(Pattern) {
                log.match.debug("recursive-{s} `{}` {any} {}", .{ name, obj, objects, offset.* });
                const rml = obj.getRml();

                if (offset.* != 1)
                    try abortParse(diag, obj.getOrigin(), error.UnexpectedInput, "{s}-syntax should be at start of expression", .{name});

                if (offset.* >= objects.len)
                    try abortParse(diag, obj.getOrigin(), error.UnexpectedInput, "expected a pattern for {s}-syntax", .{name});

                const array = array: {
                    const seq = try parseSequence(rml, diag, objects, offset);

                    break :array try Obj(Array).wrap(rml, obj.getOrigin(), try .create(rml.blobAllocator(), @ptrCast(seq)));
                };

                const sub = switch (array.data.length()) {
                    0 => unreachable,
                    1 => one: {
                        const singleObj = array.data.get(0).?;
                        break :one castObj(Pattern, singleObj).?;
                    },
                    else => try Obj(Pattern).wrap(obj.getRml(), obj.getOrigin(), .{ .sequence = array }),
                };

                return Obj(Pattern).wrap(obj.getRml(), obj.getOrigin(), @unionInit(Pattern, name, sub.typeErase()));
            }
        }.fun;
    }

    pub const @"?" = recursive("optional");
    pub const @"*" = recursive("zero_or_more");
    pub const @"+" = recursive("one_or_more");

    pub fn @"|"(diag: ?*?Diagnostic, input: Object, objects: []const Object, offset: *usize) (OOM || SyntaxError)!Obj(Pattern) {
        if (offset.* != 1)
            try abortParse(diag, input.getOrigin(), error.UnexpectedInput, "alternation-syntax should be at start of expression", .{});

        if (offset.* >= objects.len)
            try abortParse(diag, input.getOrigin(), error.UnexpectedInput, "expected a block to follow `|`", .{});

        const rml = input.getRml();
        const origin = input.getOrigin();

        const array = array: {
            const seq = try parseSequence(rml, diag, objects, offset);

            break :array try Obj(Array).wrap(rml, origin, try .create(rml.blobAllocator(), @ptrCast(seq)));
        };

        return Obj(Pattern).wrap(rml, origin, .{ .alternation = array });
    }
};

pub const CASE_SEP_SYM = "=>";

pub const ProcedureKind = enum {
    macro,
    function,
    native_macro,
    native_function,
    cancellation,
};

pub const Case = union(enum) {
    @"else": Obj(Block),

    pattern: struct {
        scrutinizer: Obj(Pattern),
        body: Obj(Block),
    },

    pub fn body(self: Case) Obj(Block) {
        return switch (self) {
            .@"else" => |block| block,
            .pattern => |pat| pat.body,
        };
    }

    pub fn parse(interpreter: *Interpreter, origin: Origin, args: []const Object) Result!Case {
        log.parser.debug("parseCase {}:{any}", .{ origin, args });

        if (args.len < 2) {
            try interpreter.abort(origin, error.InvalidArgumentCount, "expected at least 2 arguments, found {}", .{args.len});
        }

        var offset: usize = 1;

        const case = if (isExactSymbol("else", args[0]) or isExactSymbol(CASE_SEP_SYM, args[0])) elseCase: {
            break :elseCase Case{ .@"else" = try Obj(Block).wrap(getRml(interpreter), origin, try .create(getRml(interpreter), .doc, &.{})) };
        } else patternCase: {
            var diag: ?Diagnostic = null;
            const parseResult = Pattern.parse(&diag, args) catch |err| {
                if (isSyntaxError(err)) {
                    if (diag) |d| {
                        try interpreter.abort(args[0].getOrigin(), err, "cannot parse pattern starting with syntax object `{}`:\n\t{}", .{ args[0], d.formatter(null) });
                    } else {
                        log.parser.err("requested pattern parse diagnostic is null", .{});
                        try interpreter.abort(args[0].getOrigin(), error.UnexpectedInput, "cannot parse pattern `{}`", .{args[0]});
                    }
                }

                return err;
            } orelse try interpreter.abort(args[0].getOrigin(), error.UnexpectedInput, "expected a pattern, got `{}`", .{args[0]});

            log.parser.debug("pattern parse result: {}", .{parseResult});
            offset = parseResult.offset;

            if (offset + 2 > args.len) try interpreter.abort(parseResult.value.getOrigin(), error.UnexpectedEOF, "expected {s} and a body to follow case scrutinizer pattern", .{CASE_SEP_SYM});

            const sepSym = castObj(Symbol, args[offset]) orelse {
                try interpreter.abort(args[offset].getOrigin(), error.UnexpectedInput, "expected {s} to follow case scrutinizer pattern, found {}", .{ CASE_SEP_SYM, args[offset] });
            };

            offset += 1;

            if (!std.mem.eql(u8, sepSym.data.text(), CASE_SEP_SYM)) {
                try interpreter.abort(sepSym.getOrigin(), error.UnexpectedInput, "expected {s} to follow case scrutinizer pattern, found {}", .{ CASE_SEP_SYM, sepSym });
            }

            break :patternCase Case{
                .pattern = .{
                    .scrutinizer = parseResult.value,
                    .body = try Obj(Block).wrap(getRml(interpreter), origin, try .create(getRml(interpreter), .doc, &.{})),
                },
            };
        };

        const content = case.body();

        for (args[offset..]) |arg| {
            try content.data.append(arg);
        }

        log.interpreter.debug("case body: {any}", .{content});

        return case;
    }
};

pub const ProcedureBody = struct {
    env: Obj(Env),
    cases: std.ArrayListUnmanaged(Case),
};

pub const Procedure = union(ProcedureKind) {
    macro: ProcedureBody,
    function: ProcedureBody,
    native_macro: bindgen.NativeFunction,
    native_function: bindgen.NativeFunction,
    cancellation: WithId,

    pub fn compare(self: Procedure, other: Procedure) std.math.Order {
        var ord = utils.compare(std.meta.activeTag(self), std.meta.activeTag(other));

        if (ord == .eq) {
            switch (self) {
                .macro => |macro| {
                    ord = utils.compare(macro.env, other.macro.env);
                    if (ord == .eq) ord = utils.compare(macro.cases, other.macro.cases);
                },
                .function => |function| {
                    ord = utils.compare(function.env, other.function.env);
                    if (ord == .eq) ord = utils.compare(function.cases, other.function.cases);
                },
                .native_macro => |native| {
                    ord = utils.compare(native, other.native_macro);
                },
                .native_function => |native| {
                    ord = utils.compare(native, other.native_function);
                },
                .cancellation => |cancellation| {
                    ord = utils.compare(cancellation, other.cancellation);
                },
            }
        }

        return ord;
    }

    pub fn format(self: *const Procedure, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
        // TODO: source formatting
        return writer.print("[{s}-{x}]", .{ @tagName(self.*), @intFromPtr(self) });
    }

    pub fn call(self: *Procedure, interpreter: *Interpreter, callOrigin: Origin, blame: Object, args: []const Object) Result!Object {
        switch (self.*) {
            .cancellation => |cancellation| {
                log.interpreter.debug("calling cancellation {}", .{cancellation});

                std.debug.assert(interpreter.cancellation == null);

                const eArgs = try interpreter.evalAll(args);

                interpreter.cancellation = .{ .with_id = cancellation, .output = if (eArgs.items.len == 0) (try Obj(Nil).wrap(getRml(interpreter), callOrigin, .{})).typeErase() else if (eArgs.items.len == 1) eArgs.items[0] else (try Obj(Array).wrap(getRml(interpreter), callOrigin, .{ .allocator = getRml(interpreter).blobAllocator(), .native_array = eArgs })).typeErase() };

                return Signal.Cancel;
            },
            .macro => |macro| {
                log.interpreter.debug("calling macro {}", .{macro});

                var errors: String = try .create(getRml(self), "");

                const writer = errors.writer();

                var result: ?Object = null;

                for (macro.cases.items) |case| switch (case) {
                    .@"else" => |caseData| {
                        result = try interpreter.runProgram(false, caseData.data.items());
                        break;
                    },
                    .pattern => |caseData| {
                        var diag: ?Diagnostic = null;
                        const table: ?Obj(Table) = try caseData.scrutinizer.data.run(interpreter, &diag, callOrigin, args);
                        if (table) |tbl| {
                            const oldEnv = interpreter.evaluation_env;
                            defer interpreter.evaluation_env = oldEnv;

                            interpreter.evaluation_env = env: {
                                const env: Obj(Env) = try macro.env.data.clone(callOrigin);
                                try env.data.copyFromTable(tbl.data);

                                break :env env;
                            };

                            result = try interpreter.runProgram(false, caseData.body.data.items());
                            break;
                        } else if (diag) |d| {
                            writer.print("failed to match; {} vs {any}:\n\t{}", .{ caseData.scrutinizer, args, d.formatter(error.PatternFailed) }) catch |err| return errorCast(err);
                        } else {
                            log.interpreter.err("requested pattern diagnostic is null", .{});
                            writer.print("failed to match; {} vs {any}", .{ caseData.scrutinizer, args }) catch |err| return errorCast(err);
                        }
                    },
                };

                if (result) |res| {
                    return try interpreter.eval(res);
                } else {
                    try interpreter.abort(callOrigin, error.PatternFailed, "{} failed; no matching case found for input {any}", .{ blame, args });
                }
            },
            .function => |func| {
                log.interpreter.debug("calling func {}", .{func});

                const eArgs = (try interpreter.evalAll(args)).items;
                var errors: String = try .create(getRml(self), "");

                const writer = errors.writer();

                log.interpreter.debug("calling func {any}", .{func.cases});
                for (func.cases.items) |case| switch (case) {
                    .@"else" => |caseData| {
                        log.interpreter.debug("calling else case {}", .{caseData});
                        return interpreter.runProgram(false, caseData.data.items());
                    },
                    .pattern => |caseData| {
                        log.interpreter.debug("calling pattern case {}", .{caseData});
                        var diag: ?Diagnostic = null;
                        const result: ?Obj(Table) = try caseData.scrutinizer.data.run(interpreter, &diag, callOrigin, eArgs);
                        if (result) |res| {
                            const oldEnv = interpreter.evaluation_env;
                            defer interpreter.evaluation_env = oldEnv;

                            interpreter.evaluation_env = env: {
                                const env: Obj(Env) = try func.env.data.clone(callOrigin);

                                try env.data.copyFromTable(res.data);

                                break :env env;
                            };

                            return interpreter.runProgram(false, caseData.body.data.items());
                        } else if (diag) |d| {
                            writer.print("failed to match; {} vs {any}:\n\t{}", .{ caseData.scrutinizer, eArgs, d.formatter(error.PatternFailed) }) catch |err| return errorCast(err);
                        } else {
                            log.interpreter.err("requested pattern diagnostic is null", .{});
                            writer.print("failed to match; {} vs {any}", .{ caseData.scrutinizer, eArgs }) catch |err| return errorCast(err);
                        }
                    },
                };

                try interpreter.abort(callOrigin, error.PatternFailed, "{} failed; no matching case found for input {any}", .{ blame, eArgs });
            },
            .native_macro => |func| {
                log.interpreter.debug("calling native macro {x}", .{@intFromPtr(func)});

                return func(interpreter, callOrigin, args);
            },
            .native_function => |func| {
                log.interpreter.debug("calling native func {x}", .{@intFromPtr(func)});

                const eArgs = try interpreter.evalAll(args);

                return func(interpreter, callOrigin, eArgs.items);
            },
        }
    }
};

pub const QuoteKind = enum {
    // these need to be ordered length-wise if they use the same prefix
    // (e.g. unquote_splice must come before unquote)
    basic,
    quasi,
    to_quote,
    to_quasi,
    unquote_splice,
    unquote,

    pub fn toStr(self: QuoteKind) []const u8 {
        return switch (self) {
            .basic => "'",
            .quasi => "`",
            .to_quote => "~'",
            .to_quasi => "~`",
            .unquote_splice => ",@",
            .unquote => ",",
        };
    }

    pub fn fromStr(s: []const u8) ?QuoteKind {
        return if (std.mem.eql(u8, s, "'")) .basic else if (std.mem.eql(u8, s, "`")) .quasi else if (std.mem.eql(u8, s, "~'")) .to_quote else if (std.mem.eql(u8, s, "~`")) .to_quasi else if (std.mem.eql(u8, s, ",@")) .unquote_splice else if (std.mem.eql(u8, s, ",")) .unquote else null;
    }
};

pub const Quote = struct {
    kind: QuoteKind,
    body: Object,

    pub fn compare(self: Quote, other: Quote) std.math.Order {
        var ord = utils.compare(self.kind, other.kind);

        if (ord == .eq) {
            ord = self.body.compare(other.body);
        }

        return ord;
    }

    pub fn format(self: *const Quote, comptime fmtStr: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
        const fmt = Format.fromStr(fmtStr) orelse .debug;
        const w = if (@TypeOf(writer) == std.io.AnyWriter) writer else writer.any();
        try w.writeAll(self.kind.toStr());
        try self.body.onFormat(fmt, w);
    }

    pub fn run(self: *Quote, interpreter: *Interpreter) Result!Object {
        switch (self.kind) {
            .basic => {
                log.interpreter.debug("evaluating basic quote {}", .{self});
                return self.body;
            },
            .quasi => {
                log.interpreter.debug("evaluating quasi quote {}", .{self});
                return runQuasi(interpreter, self.body, null);
            },
            .to_quote => {
                log.interpreter.debug("evaluating to_quote quote {}", .{self});
                const val = try interpreter.eval(self.body);
                return (try Obj(Quote).wrap(getRml(self), self.body.getOrigin(), .{ .kind = .basic, .body = val })).typeErase();
            },
            .to_quasi => {
                log.interpreter.debug("evaluating to_quasi quote {}", .{self});
                const val = try interpreter.eval(self.body);
                return (try Obj(Quote).wrap(getRml(self), self.body.getOrigin(), .{ .kind = .quasi, .body = val })).typeErase();
            },
            else => {
                try interpreter.abort(getOrigin(self), error.TypeError, "unexpected {s}", .{@tagName(self.kind)});
            },
        }
    }
};

pub fn runQuasi(interpreter: *Interpreter, body: Object, out: ?*std.ArrayListUnmanaged(Object)) Result!Object {
    const rml = getRml(interpreter);

    if (castObj(Quote, body)) |quote| quote: {
        const origin = quote.getOrigin();

        switch (quote.data.kind) {
            .basic => break :quote,
            .quasi => break :quote,
            .to_quote => {
                const ranBody = try runQuasi(interpreter, quote.data.body, null);
                return (try Obj(Quote).wrap(rml, origin, .{ .kind = .basic, .body = ranBody })).typeErase();
            },
            .to_quasi => {
                const ranBody = try runQuasi(interpreter, quote.data.body, null);
                return (try Obj(Quote).wrap(rml, origin, .{ .kind = .quasi, .body = ranBody })).typeErase();
            },
            .unquote => {
                return interpreter.eval(quote.data.body);
            },
            .unquote_splice => {
                const outArr = out orelse try interpreter.abort(body.getOrigin(), error.UnexpectedInput, "unquote-splice is not allowed here", .{});

                const ranBody = try interpreter.eval(quote.data.body);

                const arrBody = try coerceArray(ranBody) orelse try interpreter.abort(quote.data.body.getOrigin(), error.TypeError, "unquote-splice expects an array-like, got {s}: {}", .{ TypeId.name(ranBody.getTypeId()), ranBody });

                for (arrBody.data.items()) |item| {
                    try outArr.append(rml.blobAllocator(), item);
                }

                return (try Obj(Nil).wrap(rml, origin, .{})).typeErase();
            },
        }
    } else if (castObj(Block, body)) |block| {
        var subOut: std.ArrayListUnmanaged(Object) = .{};

        for (block.data.array.items) |item| {
            const len = subOut.items.len;

            const ranItem = try runQuasi(interpreter, item, &subOut);

            // don't append if its the nil from unquote-splice
            if (len == subOut.items.len) try subOut.append(rml.blobAllocator(), ranItem) else {
                std.debug.assert(isType(Nil, ranItem));
            }
        }

        return (try Obj(Block).wrap(rml, block.getOrigin(), try .create(getRml(interpreter), block.data.kind, subOut.items))).typeErase();
    }

    return body;
}

pub const Set = TypedSet(ObjData);

pub fn TypedSet(comptime K: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        native_set: NativeSet = .{},

        pub const NativeIter = NativeSet.Iterator;
        pub const NativeSet = std.ArrayHashMapUnmanaged(Obj(K), void, utils.SimpleHashContext, true);

        pub fn create(rml: *Rml, initialKeys: []const Obj(K)) OOM!Self {
            var self = Self{ .allocator = rml.blobAllocator() };
            for (initialKeys) |k| try self.native_set.put(rml.blobAllocator(), k, {});
            return self;
        }

        pub fn compare(self: Self, other: Self) std.math.Order {
            var ord = utils.compare(self.keys().len, other.keys().len);

            if (ord == .eq) {
                ord = utils.compare(self.keys(), other.keys());
            }

            return ord;
        }

        pub fn format(self: *const Self, comptime fmtStr: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
            const fmt = Format.fromStr(fmtStr) orelse .debug;
            const w = if (@TypeOf(writer) == std.io.AnyWriter) writer else writer.any();

            const ks = self.keys();
            try w.writeAll("set{ ");
            for (ks) |key| {
                try key.onFormat(fmt, w);
                try w.writeAll(" ");
            }
            try w.writeAll("}");
        }

        /// Clones and returns the backing array of values in this map.
        pub fn toArray(self: *const Self) OOM!Obj(Array) {
            var array = try Obj(Array).wrap(getRml(self), getOrigin(self), .{ .allocator = self.allocator });

            for (self.keys()) |key| {
                try array.data.append(key.typeErase());
            }

            return array;
        }

        pub fn clone(self: *const Self) OOM!Self {
            return Self{ .allocator = self.allocator, .native_set = try self.native_set.clone(self.allocator) };
        }

        pub fn copyFrom(self: *Self, other: *const Self) OOM!void {
            for (other.keys()) |key| {
                try self.set(key);
            }
        }

        /// Set a key
        pub fn set(self: *Self, key: Obj(K)) OOM!void {
            if (self.native_set.getEntry(key)) |entry| {
                entry.key_ptr.* = key;
            } else {
                try self.native_set.put(self.allocator, key, {});
            }
        }

        /// Find a local copy matching a given key
        pub fn get(self: *const Self, key: Obj(K)) ?Obj(K) {
            return if (self.native_set.getEntry(key)) |entry| entry.key_ptr.* else null;
        }

        /// Returns the number of key-value pairs in the map
        pub fn length(self: *const Self) Int {
            return @intCast(self.native_set.count());
        }

        /// Check whether a key is stored in the map
        pub fn contains(self: *const Self, key: Obj(K)) bool {
            return self.native_set.contains(key);
        }

        /// Returns the backing array of keys in this map. Modifying the map may invalidate this array.
        /// Modifying this array in a way that changes key hashes or key equality puts the map into an unusable state until reIndex is called.
        pub fn keys(self: *const Self) []Obj(K) {
            return self.native_set.keys();
        }

        /// Recomputes stored hashes and rebuilds the key indexes.
        /// If the underlying keys have been modified directly,
        /// call this method to recompute the denormalized metadata
        /// necessary for the operation of the methods of this map that lookup entries by key.
        pub fn reIndex(self: *Self) OOM!void {
            return self.native_set.reIndex(self.allocator);
        }
    };
}

pub const NativeString = std.ArrayListUnmanaged(u8);

pub const String = struct {
    pub const NativeWriter = NativeString.Writer;

    allocator: std.mem.Allocator,
    native_string: NativeString = .{},

    pub fn create(rml: *Rml, s: []const u8) OOM!String {
        var self = String{ .allocator = rml.blobAllocator() };
        try self.appendSlice(s);
        return self;
    }

    pub fn onCompare(self: *const String, other: Object) std.math.Order {
        var ord = utils.compare(TypeId.of(String), other.getTypeId());

        if (ord == .eq) {
            const otherStr = forceObj(String, other);
            ord = utils.compare(self.text(), otherStr.data.text());
        }

        return ord;
    }

    pub fn compare(self: String, other: String) std.math.Order {
        return utils.compare(self.text(), other.text());
    }

    pub fn onFormat(self: *const String, fmt: Format, w: std.io.AnyWriter) anyerror!void {
        switch (fmt) {
            .message => try w.print("{s}", .{self.text()}),
            else => {
                try w.writeAll("\"");
                try utils.text.escapeStrWrite(w, self.text(), .Double);
                try w.writeAll("\"");
            },
        }
    }

    pub fn format(self: *const String, comptime fmt: []const u8, _: std.fmt.FormatOptions, w: anytype) anyerror!void {
        return self.onFormat(comptime Format.fromStr(fmt) orelse Format.debug, if (@TypeOf(w) == std.io.AnyWriter) w else w.any());
    }

    pub fn text(self: *const String) []const u8 {
        return self.native_string.items;
    }

    pub fn length(self: *const String) Int {
        return @intCast(self.text().len);
    }

    pub fn append(self: *String, ch: Char) OOM!void {
        var buf = [1]u8{0} ** 4;
        const len = utils.text.encode(ch, &buf) catch @panic("invalid ch");
        return self.native_string.appendSlice(self.allocator, buf[0..len]);
    }

    pub fn appendSlice(self: *String, s: []const u8) OOM!void {
        return self.native_string.appendSlice(self.allocator, s);
    }

    pub fn makeInternedSlice(self: *const String) OOM![]const u8 {
        return try getRml(self).data.intern(self.text());
    }

    pub fn writer(self: *String) String.NativeWriter {
        return self.native_string.writer(self.allocator);
    }
};

pub const Symbol = struct {
    str: str,

    pub fn create(rml: *Rml, s: []const u8) OOM!Symbol {
        return .{ .str = try rml.data.intern(s) };
    }

    pub fn format(self: *const Symbol, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
        return writer.writeAll(self.text());
    }

    pub fn text(self: *const Symbol) str {
        return self.str;
    }

    pub fn length(self: *const Symbol) Int {
        return @intCast(self.str.len);
    }
};

pub const NativeWriter = std.io.AnyWriter;

pub const Writer = struct {
    native: NativeWriter,

    pub fn create(native_writer: NativeWriter) Writer {
        return Writer{ .native = native_writer };
    }

    pub fn compare(self: Writer, other: Writer) std.math.Order {
        return utils.compare(self.native, other.native);
    }

    pub fn format(self: *const Writer, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
        try writer.print("[native-writer-{x}-{x}]", .{ @intFromPtr(self.native.context), @intFromPtr(self.native.writeFn) });
    }

    pub fn print(self: *const Writer, comptime fmt: []const u8, args: anytype) Error!void {
        return self.native.print(fmt, args) catch |err| return errorCast(err);
    }

    pub fn write(self: *const Writer, val: []const u8) Error!usize {
        return self.native.write(val) catch |err| return errorCast(err);
    }

    pub fn writeAll(self: *const Writer, val: []const u8) Error!void {
        return self.native.writeAll(val) catch |err| return errorCast(err);
    }
};
