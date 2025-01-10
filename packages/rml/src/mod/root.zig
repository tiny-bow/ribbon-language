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

pub const TypeId = TypeUtils.TypeId;

pub const IOError = MiscUtils.IOError;
pub const SimpleHashContext = MiscUtils.SimpleHashContext;
pub const Ordering = MiscUtils.Ordering;
pub const compare = MiscUtils.compare;
pub const equal = MiscUtils.equal;
pub const hashWith = MiscUtils.hashWith;

pub const array = @import("array.zig");
pub const bindgen = @import("bindgen.zig");
pub const block = @import("block.zig");
pub const cell = @import("cell.zig");
pub const env = @import("env.zig");
pub const interpreter = @import("interpreter.zig");
pub const map = @import("map.zig");
pub const object = @import("object.zig");
pub const parser = @import("parser.zig");
pub const pattern = @import("pattern.zig");
pub const procedure = @import("procedure.zig");
pub const quote = @import("quote.zig");
pub const set = @import("set.zig");
pub const source = @import("source.zig");
pub const Storage = @import("Storage.zig");
pub const string = @import("string.zig");
pub const symbol = @import("symbol.zig");
pub const writer = @import("writer.zig");

pub const Nil = extern struct {
    pub fn onFormat(_: *Nil, w: std.io.AnyWriter) anyerror! void {
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

pub const Result = interpreter.Result;
pub const EvalError = interpreter.EvalError;
pub const SyntaxError = parser.SyntaxError;
pub const OOM = error{OutOfMemory};
pub const MemoryLeak = error{MemoryLeak};
pub const Unexpected = error{Unexpected};
pub const SymbolAlreadyBound = env.SymbolAlreadyBound;
pub const Error = IOError || OOM || EvalError || SyntaxError || Unexpected;

pub const Writer = writer.Writer;
pub const Array = array.Array;
pub const Block = block.Block;
pub const Cell = cell.Cell;
pub const Env = env.Env;
pub const Interpreter = interpreter.Interpreter;
pub const Parser = parser.Parser;
pub const Pattern = pattern.Pattern;
pub const Procedure = procedure.Procedure;
pub const Quote = quote.Quote;
pub const Set = set.Set;
pub const String = string.String;
pub const Symbol = symbol.Symbol;
pub const Map = map.Map;

pub const NativeFunction = bindgen.NativeFunction;
pub const Origin = source.Origin;
pub const Range = source.Range;
pub const Pos = source.Pos;
pub const Obj = object.Obj;
pub const ObjData = object.ObjData;
pub const Object = object.Object;
pub const Header = object.Header;
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


storage: Storage,
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

    pub fn formatter(self: Diagnostic, err: anyerror) Formatter {
        return .{
            .err = err,
            .diag = self,
        };
    }

    pub const Formatter = struct {
        err: anyerror,
        diag: Diagnostic,

        pub fn log(self: Formatter, logger: anytype) void {
            logger.err("{s} {}: {s}", .{@errorName(self.err), self.diag.error_origin, self.diag.message_mem[0..self.diag.message_len]});
        }

        pub fn format(self: Formatter, comptime _: []const u8, _: std.fmt.FormatOptions, w: anytype) anyerror! void {
            return w.print("{s} {}: {s}", .{@errorName(self.err), self.diag.error_origin,self. diag.message_mem[0..self.diag.message_len]});
        }
    };
};


pub const BUILTIN = @import("BUILTIN.zig");

pub const BUILTIN_NAMESPACES = .{
    .type = struct {
        pub fn @"nil?"(obj: Object) Bool { return equal(obj.getTypeId(), TypeId.of(Nil)); }
        pub fn @"bool?"(obj: Object) Bool { return equal(obj.getTypeId(), TypeId.of(Bool)); }
        pub fn @"int?"(obj: Object) Bool { return equal(obj.getTypeId(), TypeId.of(Int)); }
        pub fn @"float?"(obj: Object) Bool { return equal(obj.getTypeId(), TypeId.of(Float)); }
        pub fn @"char?"(obj: Object) Bool { return equal(obj.getTypeId(), TypeId.of(Char)); }
        pub fn @"string?"(obj: Object) Bool { return equal(obj.getTypeId(), TypeId.of(String)); }
        pub fn @"symbol?"(obj: Object) Bool { return equal(obj.getTypeId(), TypeId.of(Symbol)); }
        pub fn @"procedure?"(obj: Object) Bool { return equal(obj.getTypeId(), TypeId.of(Procedure)); }
        pub fn @"interpreter?"(obj: Object) Bool { return equal(obj.getTypeId(), TypeId.of(Interpreter)); }
        pub fn @"parser?"(obj: Object) Bool { return equal(obj.getTypeId(), TypeId.of(Parser)); }
        pub fn @"pattern?"(obj: Object) Bool { return equal(obj.getTypeId(), TypeId.of(Pattern)); }
        pub fn @"writer?"(obj: Object) Bool { return equal(obj.getTypeId(), TypeId.of(Writer)); }
        pub fn @"cell?"(obj: Object) Bool { return equal(obj.getTypeId(), TypeId.of(Cell)); }
        pub fn @"block?"(obj: Object) Bool { return equal(obj.getTypeId(), TypeId.of(Block)); }
        pub fn @"quote?"(obj: Object) Bool { return equal(obj.getTypeId(), TypeId.of(Quote)); }
        pub fn @"env?"(obj: Object) Bool { return equal(obj.getTypeId(), TypeId.of(Env)); }
        pub fn @"map?"(obj: Object) Bool { return equal(obj.getTypeId(), TypeId.of(Map)); }
        pub fn @"set?"(obj: Object) Bool { return equal(obj.getTypeId(), TypeId.of(Set)); }
        pub fn @"array?"(obj: Object) Bool { return equal(obj.getTypeId(), TypeId.of(Array)); }
    },
};

pub const BUILTIN_TYPES = TypeUtils.structConcat(.{VALUE_TYPES, OBJECT_TYPES});

pub const VALUE_TYPES = TypeUtils.structConcat(.{ATOM_TYPES, DATA_TYPES});

pub const ATOM_TYPES = .{
    .Nil = Nil,
    .Bool = Bool,
    .Int = Int,
    .Float = Float,
    .Char = Char,
    .String = String,
    .Symbol = Symbol,
};

pub const DATA_TYPES = .{
    .Procedure = Procedure,
    .Interpreter = Interpreter,
    .Parser = Parser,
    .Pattern = Pattern,
    .Writer = Writer,
    .Cell = Cell,
};

pub const OBJECT_TYPES = TypeUtils.structConcat(.{SOURCE_TYPES, COLLECTION_TYPES});

pub const SOURCE_TYPES = .{
    .Block = Block,
    .Quote = Quote,
};

pub const COLLECTION_TYPES = .{
    .Env = Env,
    .Map = Map,
    .Set = Set,
    .Array = Array,
};


/// caller must close cwd and out
pub fn init(allocator: std.mem.Allocator, cwd: ?std.fs.Dir, out: ?std.io.AnyWriter, diagnostic: ?*?Diagnostic, args: []const []const u8) OOM! *Rml {
    const self = try allocator.create(Rml);
    errdefer allocator.destroy(self);

    self.* = Rml {
        .storage = try Storage.init(allocator),
        .cwd = cwd,
        .out = out,
        .diagnostic = diagnostic,
    };
    errdefer self.storage.deinit();

    self.storage.origin = try Origin.fromStr(self, "system");

    log.debug("initializing interpreter ...", .{});

    self.global_env = try Obj(Env).wrap(self, self.storage.origin, .{.allocator = self.storage.permanent.allocator()});
    self.namespace_env = try Obj(Env).wrap(self, self.storage.origin, .{.allocator = self.storage.permanent.allocator()});

    bindgen.bindObjectNamespaces(self, self.namespace_env, BUILTIN_TYPES)
        catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => @panic(@errorName(err)),
        };

    bindgen.bindObjectNamespaces(self, self.namespace_env, BUILTIN_NAMESPACES)
        catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => @panic(@errorName(err)),
        };

    bindgen.bindGlobals(self, self.global_env, BUILTIN)
        catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => @panic(@errorName(err)),
        };

    // TODO args
    _ = args;

    if (Obj(Interpreter).wrap(self, self.storage.origin, try .create(self))) |x| {
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

    self.storage.deinit();

    self.storage.long_term.destroy(self);
}

pub fn expectedOutput(self: *Rml, comptime fmt: []const u8, args: anytype) void {
    if (self.out) |out| {
        log.info(fmt, args);
        out.print(fmt ++ "\n", args) catch @panic("failed to write to host-provided out");
    }
}


pub fn beginBlob(self: *Rml) void {
    log.debug("beginBlob", .{});
    self.storage.beginBlob();
}

pub fn endBlob(self: *Rml) Storage.Blob {
    log.debug("endBlob", .{});
    return self.storage.endBlob();
}

pub fn blobId(self: *Rml) Storage.BlobId {
    return self.storage.blobId();
}

pub fn blobAllocator(self: *Rml) std.mem.Allocator {
    return self.storage.blobAllocator();
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
    return if (self.storage.read_file_callback) |cb| try cb(self, fileName)
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
