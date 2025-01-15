const std = @import("std");
const zig_builtin = @import("builtin");

const MiscUtils = @import("Utils").Misc;
const TypeUtils = @import("Utils").Type;
const TextUtils = @import("Utils").Text;

pub const log = struct {
    pub usingnamespace std.log.scoped(.rml);
    pub const interpreter = std.log.scoped(.@"rml/interpreter");
    pub const parser = std.log.scoped(.@"rml/parser");
    pub const match = std.log.scoped(.@"rml/match");
};

const Rml = @This();

pub const TypeId = bindgen.TypeId;

pub const IOError = MiscUtils.IOError;
pub const SimpleHashContext = MiscUtils.SimpleHashContext;
pub const Ordering = MiscUtils.Ordering;
pub const compare = MiscUtils.compare;
pub const equal = MiscUtils.equal;
pub const hashWith = MiscUtils.hashWith;

pub const bindgen = @import("Rml/bindgen.zig");
pub const builtin = @import("Rml/builtin.zig");
pub const format = @import("Rml/format.zig");
pub const interpreter = @import("Rml/interpreter.zig");
pub const object = @import("Rml/object.zig");
pub const parser = @import("Rml/parser.zig");
pub const source = @import("Rml/source.zig");
pub const storage = @import("Rml/storage.zig");

pub const Nil = extern struct {
    pub fn onFormat(_: *Nil, _: Format, w: std.io.AnyWriter) anyerror! void {
        return w.print("nil", .{});
    }

    pub fn onCompare(_: *Nil, other: Object) Ordering {
        return Rml.compare(TypeId.of(Nil), other.getTypeId());
    }
};
pub const Bool = bool;
pub const Int = i64;
pub const Float = f64;
pub const Char = TextUtils.Char;

pub const str = []const u8;

pub const Result = Signal || Error;
pub const Error = IOError || OOM || EvalError || SyntaxError || Unexpected;
pub const Signal = error { Cancel };

pub const EvalError = error {
    Panic,
    TypeError,
    PatternFailed,
    UnboundSymbol,
    SymbolAlreadyBound,
    InvalidArgumentCount,
};

pub const SyntaxError = error {
    Sentinel,
    UnexpectedInput,
    UnexpectedEOF,
    BadEncoding,
};

pub fn isSyntaxError(err: anyerror) bool {
    return TypeUtils.isInErrorSet(SyntaxError, err);
}

pub const OOM = error { OutOfMemory };
pub const MemoryLeak = error { MemoryLeak };
pub const Unexpected = error { Unexpected };

pub const SymbolError  = UnboundSymbol || SymbolAlreadyBound;
pub const UnboundSymbol = error { UnboundSymbol };
pub const SymbolAlreadyBound = error { SymbolAlreadyBound };

pub const NativeFunction = bindgen.NativeFunction;

pub const Format = format.Format;

pub const Interpreter = interpreter.Interpreter;
pub const WithId = interpreter.WithId;
pub const Parser = parser.Parser;

pub const Origin = source.Origin;
pub const Range = source.Range;
pub const Pos = source.Pos;

pub const Storage = storage.Storage;

pub const Obj = object.Obj;
pub const ObjData = object.ObjData;
pub const Object = object.Object;
pub const Header = object.Header;
pub const Writer = object.Writer;
pub const Array = object.Array;
pub const Block = object.Block;
pub const Cell = object.Cell;
pub const Env = object.Env;
pub const Pattern = object.Pattern;
pub const Procedure = object.Procedure;
pub const Quote = object.Quote;
pub const Set = object.Set;
pub const String = object.String;
pub const Symbol = object.Symbol;
pub const Map = object.Map;
pub const getObj = object.getObj;
pub const getHeader = object.getHeader;
pub const getOrigin = object.getOrigin;
pub const getTypeId = object.getTypeId;
pub const getRml = object.getRml;
pub const forceObj = object.forceObj;
pub const isAtom = object.isAtom;
pub const isType = object.isType;
pub const isBuiltin = object.isBuiltin;
pub const isBuiltinType = object.isBuiltinType;
pub const castObj = object.castObj;
pub const coerceBool = object.coerceBool;
pub const coerceArray = object.coerceArray;
pub const isArrayLike = object.isArrayLike;

test {
    std.testing.refAllDeclsRecursive(@This());
}


data: Storage,
cwd: ?std.fs.Dir,
out: ?std.io.AnyWriter,
namespace_env: Obj(Env) = undefined,
global_env: Obj(Env) = undefined,
main_interpreter: Obj(Interpreter) = undefined,
diagnostic: ?*?Diagnostic = null,


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
                logger.err("{s} {}: {s}", .{@errorName(err), self.diag.error_origin, self.diag.message_mem[0..self.diag.message_len]});
            } else {
                logger.err("{}: {s}", .{self.diag.error_origin, self.diag.message_mem[0..self.diag.message_len]});
            }
        }

        pub fn format(self: Formatter, comptime _: []const u8, _: std.fmt.FormatOptions, w: anytype) anyerror! void {
            if (self.err) |err| {
                return w.print("{s} {}: {s}", .{@errorName(err), self.diag.error_origin,self. diag.message_mem[0..self.diag.message_len]});
            } else {
                return w.print("{}: {s}", .{self.diag.error_origin, self.diag.message_mem[0..self.diag.message_len]});
            }
        }
    };
};



/// caller must close cwd and out
pub fn init(allocator: std.mem.Allocator, cwd: ?std.fs.Dir, out: ?std.io.AnyWriter, diagnostic: ?*?Diagnostic, args: []const []const u8) OOM! *Rml {
    const self = try allocator.create(Rml);
    errdefer allocator.destroy(self);

    self.* = Rml {
        .data = try Storage.init(allocator),
        .cwd = cwd,
        .out = out,
        .diagnostic = diagnostic,
    };
    errdefer self.data.deinit();

    self.data.origin = try Origin.fromStr(self, "system");

    log.debug("initializing interpreter ...", .{});

    self.global_env = try Obj(Env).wrap(self, self.data.origin, .{.allocator = self.data.permanent.allocator()});
    self.namespace_env = try Obj(Env).wrap(self, self.data.origin, .{.allocator = self.data.permanent.allocator()});

    bindgen.bindObjectNamespaces(self, self.namespace_env, builtin.types)
        catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => @panic(@errorName(err)),
        };

    bindgen.bindObjectNamespaces(self, self.namespace_env, builtin.namespaces)
        catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => @panic(@errorName(err)),
        };

    bindgen.bindGlobals(self, self.global_env, builtin.global)
        catch |err| switch (err) {
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

pub fn deinit(self: *Rml) MemoryLeak! void {
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

pub fn endBlob(self: *Rml) storage.Blob {
    log.debug("endBlob", .{});
    return self.data.endBlob();
}

pub fn blobId(self: *Rml) storage.BlobId {
    return self.data.blobId();
}

pub fn blobAllocator(self: *Rml) std.mem.Allocator {
    return self.data.blobAllocator();
}

// TODO run
pub fn runString(self: *Rml, fileName: []const u8, text: []const u8) Error! Object {
    log.info("running [{s}] ...", .{fileName});
    const result = try MiscUtils.todo(noreturn, .{self, text});
    log.info("... finished [{s}], result: {}", .{ fileName, result });

    return result;
}

pub fn runFile(self: *Rml, fileName: []const u8) Error! Object {
    const src = try self.readFile(fileName);

    return self.runString(fileName, src);
}

pub fn readFile(self: *Rml, fileName: []const u8) Error! []const u8 {
    log.info("reading [{s}] ...", .{fileName});
    return if (self.data.read_file_callback) |cb| try cb(self, fileName)
        else error.AccessDenied;
}

pub fn errorCast(err: anyerror) Error {
    if (TypeUtils.narrowErrorSet(Error, err)) |e| {
        return e;
    } else {
        log.err("unexpected error in errorCast: {s}", .{@errorName(err)});
        return error.Unexpected;
    }
}

pub fn lookupNamespace(sym: Obj(Symbol)) ?Object {
    return sym.getRml().namespace_env.data.get(sym);
}
