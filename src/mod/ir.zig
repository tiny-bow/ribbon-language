//! # ir
//! This namespace provides a mid-level SSA-form Intermediate Representation (IR) for Ribbon.
//!
//! It is used to represent the program in a way that is easy to optimize and transform.
//!
//! This IR targets:
//! * rvm's `core` bytecode (via the `bytecode` module)
//! * native machine code, in two ways:
//!    + in house x64 jit (the `machine` module)
//!    + freestanding (eventually; via llvm, likely)
const ir = @This();

const std = @import("std");
const log = std.log.scoped(.Rir);

const pl = @import("platform");
const Interner = @import("Interner");
const Id = @import("Id");

test {
    std.testing.refAllDeclsRecursive(@This());
}


/// The builtin types and constants that are used in the IR.
/// This is a static data structure that is created at `init` and used throughout the IR.
pub const Builtin = struct {
    /// Builtin names.
    names: struct {
        /// The name of the entry point of functions.
        entry: *const Name,

        /// The name of the nil type.
        nil: *const Name,
        /// The name of the opaque type.
        @"opaque": *const Name,
        /// The name of the noreturn type.
        noreturn: *const Name,

        /// The name of the type of types.
        type: *const Name,
        /// The name of the type of blocks.
        block: *const Name,
        /// The name of the type of modules.
        module: *const Name,

        /// The name of the type of boolean values.
        bool: *const Name,

        /// The name of the type of 8-bit signed integers.
        i8: *const Name,
        /// The name of the type of 16-bit signed integers.
        i16: *const Name,
        /// The name of the type of 32-bit signed integers.
        i32: *const Name,
        /// The name of the type of 64-bit signed integers.
        i64: *const Name,

        /// The name of the type of 8-bit unsigned integers.
        u8: *const Name,
        /// The name of the type of 16-bit unsigned integers.
        u16: *const Name,
        /// The name of the type of 32-bit unsigned integers.
        u32: *const Name,
        /// The name of the type of 64-bit unsigned integers.
        u64: *const Name,

        /// The name of the type of 32-bit floating point values.
        f32: *const Name,
        /// The name of the type of 64-bit floating point values.
        f64: *const Name,
    },
    /// Builtin types.
    types: struct {
        /// The type of `nil` values, ie void, unit etc.
        nil: *const Type,
        /// The type of opaque values, data without a known structure.
        @"opaque": *const Type,
        /// The type of the result of functions that don't actually return.
        noreturn: *const Type,

        /// The type of a type.
        type: *const Type,
        /// The type of an IR basic block.
        block: *const Type,
        /// The type of an IR module.
        module: *const Type,

        /// The type of boolean values, true or false.
        bool: *const Type,

        /// 8-bit signed integer type.
        i8: *const Type,
        /// 16-bit signed integer type.
        i16: *const Type,
        /// 32-bit signed integer type.
        i32: *const Type,
        /// 64-bit signed integer type.
        i64: *const Type,

        /// 8-bit unsigned integer type.
        u8: *const Type,
        /// 16-bit unsigned integer type.
        u16: *const Type,
        /// 32-bit unsigned integer type.
        u32: *const Type,
        /// 64-bit unsigned integer type.
        u64: *const Type,

        /// 32-bit floating point type.
        f32: *const Type,
        /// 64-bit floating point type.
        f64: *const Type,
    },
};

/// The root of a Ribbon IR unit.
///
/// The IR unit is a collection of types, constants, foreign addresses, effects, and modules;
/// each of which can reference each other.
///
/// This is the main entry point for creating and managing IR structures.
pub const Builder = struct {
    /// The allocator that all memory used by ir structures is sourced from.
    /// * The builder is allocator-agnostic and any allocator can be used here,
    /// though resulting usage patterns may differ slightly. See `deinit`.
    allocator: std.mem.Allocator,
    /// Arena allocator used for names.
    name_arena: std.heap.ArenaAllocator,
    /// Arena allocator used for types.
    type_arena: std.heap.ArenaAllocator,
    /// Arena allocator used for constants.
    constant_arena: std.heap.ArenaAllocator,
    /// Names in the IR are interned in this hash set.
    names: NameSet = .empty,
    /// Types used in the IR are interned in this hash set.
    types: TypeSet = .empty,
    /// Compile time constants that are larger than an immediate value.
    constants: ConstantSet = .empty,
    /// Foreign addresses that can be referenced by functions.
    foreign_addresses: ForeignAddressSet = .empty,
    /// Side effects that can be performed by functions.
    effects: EffectSet = .empty,
    /// All of the IR modules that can reference each other within this IR unit.
    modules: ModuleSet = .empty,
    /// Static data created at `init`.
    builtin: Builtin,

    /// Initialize a new IR unit.
    ///
    /// * `allocator`-agnostic
    /// * result `Builder` root ir node will own all ir memory allocated with the provided allocator;
    /// it can all be freed at once with `deinit`
    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!*const Builder {
        const self = try allocator.create(Builder);

        self.* = .{
            .allocator = allocator,
            .name_arena = std.heap.ArenaAllocator.init(allocator),
            .type_arena = std.heap.ArenaAllocator.init(allocator),
            .constant_arena = std.heap.ArenaAllocator.init(allocator),
            .builtin = undefined,
        };

        self.builtin.names.entry = try self.internName("entry");

        inline for (comptime std.meta.fieldNames(@TypeOf(self.builtin.types))) |builtinTypeName| {
            const typeIr = try self.internType(builtinTypeName, @field(BUILTIN_TYPE_INFO, builtinTypeName));

            @field(self.builtin.names, builtinTypeName) = typeIr.name.?;
            @field(self.builtin.types, builtinTypeName) = typeIr;
        }

        return self;
    }

    /// De-initialize the IR unit, freeing all allocated memory.
    pub fn deinit(ptr: *const Builder) void {
        const self: *Builder = @constCast(ptr);

        const allocator = self.allocator;
        defer allocator.destroy(self);

        var effectIt = self.effects.keyIterator();
        while (effectIt.next()) |effectPtr| {
            Effect.deinit(effectPtr.*);
        }

        var moduleIt = self.modules.keyIterator();
        while (moduleIt.next()) |modulePtr| {
            Module.deinit(modulePtr.*);
        }

        var foreignAddressIt = self.foreign_addresses.keyIterator();
        while (foreignAddressIt.next()) |foreignAddressPtr| {
            ForeignAddress.deinit(foreignAddressPtr.*);
        }

        self.name_arena.deinit();
        self.type_arena.deinit();
        self.constant_arena.deinit();

        self.names.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.types.deinit(self.allocator);

        self.foreign_addresses.deinit(self.allocator);
        self.effects.deinit(self.allocator);
        self.modules.deinit(self.allocator);
    }

    /// Get a `Name` from a string value.
    ///
    /// If the string has already been interned, the existing `Name` will be returned;
    /// otherwise a new `Name` will be allocated.
    ///
    /// The `Name` that is returned will be owned by this IR unit.
    pub fn internName(ptr: *const Builder, value: []const u8) error{OutOfMemory}!*const Name {
        const self: *Builder = @constCast(ptr);

        return (try self.names.intern(self.allocator, self.name_arena.allocator(), &Name{
            .root = self,
            .id = @enumFromInt(self.names.count()),
            .value = value,
            .hash = pl.hash64(value),
        })).ptr.*;
    }

    /// Get a `Type` from a `TypeInfo` value.
    ///
    /// If the type has already been interned, the existing `Type` will be returned;
    /// Otherwise a new `Type` will be allocated.
    ///
    /// The `Type` that is returned will be owned by this IR unit.
    pub fn internType(ptr: *const Builder, nameString: ?[]const u8, info: TypeInfo) error{OutOfMemory}!*const Type {
        const self: *Builder = @constCast(ptr);

        const name = if (nameString) |ns| try self.internName(ns) else null;

        return (try self.types.intern(self.allocator, self.type_arena.allocator(), &Type{
            .root = self,
            .id = @enumFromInt(self.types.count()),
            .name = name,
            .info = info,
            .hash = info.hash(),
        })).ptr.*;
    }

    /// Get a `Constant` from a `ConstantData` value.
    ///
    /// If the constant has already been interned, the existing `Constant` will be returned;
    /// Otherwise a new `Constant` will be allocated.
    ///
    /// The `Constant` that is returned will be owned by this IR unit.
    pub fn internConstant(ptr: *const Builder, nameString: ?[]const u8, data: ConstantData) error{OutOfMemory}!*const Constant {
        const self: *Builder = @constCast(ptr);

        const name = if (nameString) |ns| try self.internName(ns) else null;

        return (try self.constants.intern(self.allocator, self.constant_arena.allocator(), &Constant{
            .root = self,
            .id = @enumFromInt(self.constants.count()),
            .name = name,
            .data = data,
            .hash = data.hash(),
        })).ptr.*;
    }

    /// Create a `ForeignAddress` for a symbol, given a type.
    ///
    /// If a foreign address with the same name has already been created,
    /// the type passed at this call must match, otherwise `error.DuplicateForeignAddress` is returned.
    ///
    /// If a foreign address has already been created with the same name and type,
    /// the existing `ForeignAddress` will be returned;
    /// Otherwise a new `ForeignAddress` will be allocated.
    ///
    /// The `ForeignAddress` that is returned will be owned by this IR unit.
    pub fn createForeignAddress(ptr: *const Builder, nameString: []const u8, typeIr: *const Type) error{DuplicateForeignAddress, OutOfMemory}!*const ForeignAddress {
        const self: *Builder = @constCast(ptr);

        const name = try self.internName(nameString);

        var it = self.foreign_addresses.keyIterator();
        while (it.next()) |foreignAddressPtr| {
            const foreignAddressIr = foreignAddressPtr.*;
            if (name == foreignAddressIr.name) {
                if (foreignAddressIr.type == typeIr) {
                    return foreignAddressIr;
                } else {
                    return error.DuplicateForeignAddress;
                }
            }
        }

        const out = try ForeignAddress.init(self, @enumFromInt(self.foreign_addresses.count()), name, typeIr);

        try self.foreign_addresses.put(self.allocator, out, {});

        return out;
    }

    /// Create an `Effect` for a symbol, given a handler signature type.
    ///
    /// If an effect with the same name has already been created,
    /// the handler signature type passed at this call must match,
    /// otherwise `error.DuplicateEffect` is returned.
    ///
    /// If an effect has already been created with the same name and handler signature type,
    /// the existing `Effect` will be returned;
    /// Otherwise a new `Effect` will be allocated.
    ///
    /// The `Effect` that is returned will be owned by this IR unit.
    pub fn createEffect(ptr: *const Builder, nameString: []const u8, handlerSignatures: []*const Type) error{DuplicateEffect, OutOfMemory}!*const Effect {
        const self: *Builder = @constCast(ptr);

        const name = try self.internName(nameString);

        var it = self.effects.keyIterator();
        while (it.next()) |effectPtr| {
            const effectIr = effectPtr.*;
            if (name == effectIr.name) {
                if (std.mem.eql(*const Type, handlerSignatures, effectIr.handler_signatures)) {
                    return effectIr;
                } else {
                    return error.DuplicateEffect;
                }
            }
        }

        const out = try Effect.init(self, @enumFromInt(self.effects.count()), name, try self.allocator.dupe(*const Type, handlerSignatures));

        try self.effects.put(self.allocator, out, {});

        return out;
    }

    /// Create a new `Module` with a given name.
    ///
    /// If a module with the same name has already been created, `error.DuplicateModuleName` is returned.
    ///
    /// The `Module` that is returned will be owned by this IR unit.
    pub fn createModule(ptr: *const Builder, name: *const Name) error{DuplicateModuleName, OutOfMemory}!*Module {
        const self: *Builder = @constCast(ptr);

        var it = self.modules.keyIterator();
        while (it.next()) |modulePtr| {
            if (name == modulePtr.*.name) {
                return error.DuplicateModuleName;
            }
        }

        const out = try Module.init(self, @enumFromInt(self.modules.count()), name);

        try self.modules.put(self.allocator, out, {});

        return out;
    }
};

const ForeignAddressSet: type = Id.Set(*const ForeignAddress, 80);
const EffectSet: type = Id.Set(*const Effect, 80);
const ModuleSet: type = Id.Set(*const Module, 80);

pub const NameSet: type = Interner.new(*const Name, struct {
    pub const DATA_FIELD = .value;

    pub fn eql(a: *const []const u8, b: *const []const u8) bool {
        return std.mem.eql(u8, a.*, b.*);
    }

    pub fn onFirstIntern(slot: **const Name, allocator: std.mem.Allocator) error{OutOfMemory}!void {
        const self = try allocator.create(Name);

        self.* = slot.*.*;

        self.value = try allocator.dupe(u8, self.value);

        slot.* = self;
    }
});

pub const TypeSet: type = Interner.new(*const Type, struct {
    pub const DATA_FIELD = .info;

    pub fn eql(a: *const TypeInfo, b: *const TypeInfo) bool {
        return a.eql(b);
    }

    pub fn onFirstIntern(slot: **const Type, allocator: std.mem.Allocator) error{OutOfMemory}!void {
        const self = try allocator.create(Type);

        self.* = slot.*.*;

        self.info = try self.info.clone(allocator);

        slot.* = self;
    }
});

pub const ConstantSet: type = Interner.new(*const Constant, struct {
    pub const DATA_FIELD = .data;

    pub fn eql(a: *const ConstantData, b: *const ConstantData) bool {
        return a.eql(b);
    }

    pub fn onFirstIntern(slot: **const Constant, allocator: std.mem.Allocator) error{OutOfMemory}!void {
        const self = try allocator.create(Constant);

        self.* = slot.*.*;

        self.data = try self.data.clone(allocator);

        slot.* = self;
    }
});

/// Various data structures in the IR can be given a name, for debugging and symbol resolution purposes;
/// when such a name is provided to the IR builder, it is interned in the Rir's name set using a `Name`.
pub const Name = struct {
    /// The IR unit that owns this name.
    root: *const Builder,
    /// The unique identifier for this name.
    id: Id.of(Name),
    /// The actual text value of this name.
    value: []const u8,
    /// A 64-bit hash of the text value of this name.
    hash: u64,

    pub fn onFormat(self: *const Name, formatter: anytype) !void {
        try formatter.writeAll(self.value);
    }
};

/// All compile-time known constant values that are used in the IR are interned in the Rir's constant set using a `Constant`;
/// this is a simple binding of `ConstantData` to an `ID` and an optional debug `Name` in the IR unit.
pub const Constant = struct {
    /// The IR unit that owns this constant.
    root: *const Builder,
    /// The unique identifier for this constant.
    id: Id.of(Constant),
    /// A debug name for this constant, if it has one.
    name: ?*const Name,
    /// The actual data for this constant.
    data: ConstantData,
    /// A 64-bit hash of the data of this constant.
    hash: u64,

    pub fn onFormat(self: *const Constant, formatter: anytype) !void {
        try formatter.writeAll("constant(");

        if (self.name) |name| {
            try formatter.fmt(name);
        } else {
            try formatter.fmt(self.id.toInt());
        }

        try formatter.writeAll(" :: ");

        try self.data.onFormat(formatter);

        try formatter.writeAll(")");
    }
};

/// The actual data for a compile-time known constant value.
pub const ConstantData = struct {
    /// The type of this constant.
    type: *const Type,
    /// The actual data for this constant.
    bytes: []const u8,

    /// `allocator.dupe` the bytes of this constant data.
    pub fn clone(self: *const ConstantData, allocator: std.mem.Allocator) error{OutOfMemory}!ConstantData {
        return .{
            .type = self.type,
            .bytes = try allocator.dupe(u8, self.bytes),
        };
    }

    /// Free the bytes of this constant data.
    pub fn deinit(self: *ConstantData, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }

    fn hash(self: *const ConstantData) u64 {
        var hasher = std.hash.Fnv1a_64.init();

        hasher.update(std.mem.asBytes(&self.type));
        hasher.update(self.bytes);

        return hasher.final();
    }

    fn eql(self: *const ConstantData, other: *const ConstantData) bool {
        if (self.type != other.type) return false;

        return std.mem.eql(u8, self.bytes, other.bytes);
    }

    pub fn onFormat(self: *const ConstantData, formatter: anytype) !void {
        try formatter.print("({} : ", .{self.type});

        // TODO: TypeInfo.fmtMemory
        for (self.bytes) |byte| {
            try formatter.print("{x:0<2}", .{byte});
        }

        try formatter.writeAll(")");
    }
};

/// Addresses of foreign functions or data that can be referenced by functions in the IR,
/// together with their type and symbolic name.
pub const ForeignAddress = struct {
    /// The IR unit that owns this foreign address.
    root: *const Builder,
    /// The unique identifier for this foreign address.
    id: Id.of(ForeignAddress),
    /// An identifying symbol for this foreign address;
    /// This is required because foreign address resolution at runtime is done via symbol name.
    name: *const Name,
    /// The type of the data or function at this foreign address.
    type: *const Type,

    fn init(root: *const Builder, id: Id.of(ForeignAddress), name: *const Name, typeIr: *const Type) error{OutOfMemory}!*const ForeignAddress {
        const self = try root.allocator.create(ForeignAddress);

        self.* = .{
            .root = root,
            .id = id,
            .name = name,
            .type = typeIr,
        };

        return self;
    }

    fn deinit(ptr: *const ForeignAddress) void {
        const self: *ForeignAddress = @constCast(ptr);

        const allocator = self.root.allocator;
        defer allocator.destroy(self);
    }

    fn onFormat(self: *const ForeignAddress, formatter: anytype) !void {
        try formatter.print("foreign_address({} :: {})", .{self.name, self.type});
    }
};

/// Side effects that can be performed by functions in the IR. their handler signature
pub const Effect = struct {
    /// The IR unit that owns this effect.
    root: *const Builder,
    /// The unique identifier for this effect.
    id: Id.of(Effect),
    /// An identifying name for this effect.
    /// This is required because effect unification is done via symbol name.
    name: *const Name,
    /// A generic type giving the shape of effect handler function that is compatible this effect.
    handler_signatures: []*const Type,

    fn init(root: *const Builder, id: Id.of(Effect), name: *const Name, handlerSignatures: []*const Type) error{OutOfMemory}!*Effect {
        const self = try root.allocator.create(Effect);

        self.* = .{
            .root = root,
            .id = id,
            .name = name,
            .handler_signatures = handlerSignatures,
        };

        return self;
    }

    fn deinit(ptr: *const Effect) void {
        const self: *Effect = @constCast(ptr);

        const allocator = self.root.allocator;
        defer allocator.destroy(self);
    }

    pub fn onFormat(self: *const Effect, formatter: anytype) !void {
        try formatter.print("effect({} :: {})", .{self.name, self.handler_signature});
    }
};

/// All types that are used in the IR are interned in the Rir's type set using a `Type`;
/// this is a simple binding of `TypeInfo` to an `ID` and an optional debug `Name` in the IR unit.
pub const Type = struct {
    /// The IR unit that owns this type.
    root: *const Builder,
    /// The unique identifier for this type.
    id: Id.of(Type),
    /// A debug name for this type, if it has one.
    name: ?*const Name,
    /// The actual type information for this type.
    info: TypeInfo,
    /// A 64-bit hash of the type information of this type.
    hash: u64,

    /// Get the `Kind` of the type described by this type information.
    pub fn getKind(self: *const Type) TypeInfo.Kind {
        return self.info.getKind();
    }
};

pub const BUILTIN_TYPE_INFO = .{
    .@"opaque" = TypeInfo.@"opaque",
    .noreturn  = TypeInfo.noreturn,
    .type      = TypeInfo.type,
    .block     = TypeInfo.block,
    .module    = TypeInfo.module,
    .nil  = TypeInfo.nil,
    .bool = TypeInfo.bool,
    .i8   = TypeInfo.integerOf(8,  .signed),
    .i16  = TypeInfo.integerOf(16, .signed),
    .i32  = TypeInfo.integerOf(32, .signed),
    .i64  = TypeInfo.integerOf(64, .signed),
    .u8   = TypeInfo.integerOf(8,  .unsigned),
    .u16  = TypeInfo.integerOf(16, .unsigned),
    .u32  = TypeInfo.integerOf(32, .unsigned),
    .u64  = TypeInfo.integerOf(64, .unsigned),
    .f32  = TypeInfo.floatOf(.single),
    .f64  = TypeInfo.floatOf(.double),
};

/// A sum type that represents all possible types usable in an IR,
/// as well as a namespace for data structures that are specific to each variant
///
/// This must be deduplicated before use in the IR, via the `Type` structure. See `internType`
pub const TypeInfo = union(enum) {
    // the following variants have no data //

    /// The type of `nil` values, ie void, unit etc.
    nil: void,
    /// The type of opaque values, data without a known structure.
    @"opaque": void,
    /// The type of the result of functions that don't actually return.
    noreturn: void,
    /// The type of a type.
    type: void,
    /// The type of an IR effect handler block token.
    block: void,
    /// The type of an IR module.
    module: void,
    /// The type of boolean values, true or false.
    bool: void,

    // the following variants have no allocations //

    /// A placeholder for an actual type, of a specific kind.
    @"var": TypeInfo.Var,
    /// A wrapper for a local variable's type.
    local: TypeInfo.Local,
    /// The type of integer values, signed or unsigned, arbitrary bit size.
    integer: TypeInfo.Integer,
    /// The type of floating point values, with choice of precision.
    float: TypeInfo.Float,
    /// The type of a pointer to a value of another type.
    pointer: TypeInfo.Pointer,
    /// The type of a pointer to, and a count of, values of another type.
    slice: TypeInfo.Slice,
    /// The type of a pointer to c-style sentinel terminated buffers of values another type.
    sentinel: TypeInfo.Sentinel,
    /// The type of an array of values of another type.
    array: TypeInfo.Array,
    /// The type of a function, with a signature and a return type.
    function: TypeInfo.Function,
    /// The type of a foreign address, a pointer to an external function or data.
    foreign_address: TypeInfo.ForeignAddress,
    /// The type of a side effect that can be performed by a function.
    effect: TypeInfo.Effect,
    /// The type of a function that can handle a side effect.
    handler: TypeInfo.Handler,

    // the following variants have allocations that must be managed //

    /// The type of a user-defined product data structure, with fields of various types.
    @"struct": TypeInfo.Struct,
    /// The type of a user-defined sum data structure, with fields of various types.
    @"union": TypeInfo.Union,
    /// The type of a user-defined product data structure, with fields of various types.
    product: TypeInfo.Product,
    /// The type of a user-defined sum data structure, with fields of various types.
    sum: TypeInfo.Sum,

    /// Shallow copy of the type information, creating at most one new allocation.
    /// This is simply a bit copy for many variants, but allocated types can fail.
    pub fn clone(self: *const TypeInfo, allocator: std.mem.Allocator) error{OutOfMemory}!TypeInfo {
        switch (self.*) {
            .@"struct" => |info| return .{ .@"struct" = try info.clone(allocator) },
            .@"union" => |info| return .{ .@"union" = try info.clone(allocator) },
            .product => |info| return .{ .product = try info.clone(allocator) },
            .sum => |info| return .{ .sum = try info.clone(allocator) },
            else => return self.*,
        }
    }

    /// De-initialize the type information
    ///
    /// This is not necessary to call from user-facing code unless the instance was created by a call to `clone`
    pub fn deinit(self: *TypeInfo, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .@"struct" => |info| info.deinit(allocator),
            .@"union" => |info| info.deinit(allocator),
            .product => |info| info.deinit(allocator),
            .sum => |info| info.deinit(allocator),
            else => {},
        }
    }

    pub fn hash(self: *const TypeInfo) u64 {
        var hasher = std.hash.Fnv1a_64.init();

        hasher.update(@tagName(self.*));

        switch (self.*) {
            .nil,
            .@"opaque",
            .noreturn,
            .bool,
            .type,
            .block,
            .module,
            => {},

            inline else => |*x| x.hash(&hasher),
        }

        return hasher.final();
    }

    pub fn eql(self: *const TypeInfo, other: *const TypeInfo) bool {
        if (@as(Tag, self.*) != @as(Tag, other.*)) return false;

        return switch (self.*) {
            .nil, .@"opaque", .noreturn, .bool, .type, .block, .module => true,

            .@"var" => |*x| x.eql(&other.@"var"),
            .local => |*x| x.eql(&other.local),
            .integer => |*x| x.eql(&other.integer),
            .float => |*x| x.eql(&other.float),
            .pointer => |*x| x.eql(&other.pointer),
            .slice => |*x| x.eql(&other.slice),
            .sentinel => |*x| x.eql(&other.sentinel),
            .array => |*x| x.eql(&other.array),
            .function => |*x| x.eql(&other.function),
            .foreign_address => |*x| x.eql(&other.foreign_address),
            .effect => |*x| x.eql(&other.effect),
            .handler => |*x| x.eql(&other.handler),

            .@"struct" => |*x| x.eql(&other.@"struct"),
            .@"union" => |*x| x.eql(&other.@"union"),
            .product => |*x| x.eql(&other.product),
            .sum => |*x| x.eql(&other.sum),
        };
    }

    pub fn onFormat(self: *const TypeInfo, formatter: anytype) !void {
        switch (self.*) {
            .nil => try formatter.writeAll("nil"),
            .@"opaque" => try formatter.writeAll("opaque"),
            .noreturn => try formatter.writeAll("no_return"),
            .bool => try formatter.writeAll("bool"),
            .type => try formatter.writeAll("type"),
            .block => try formatter.writeAll("block"),
            .module => try formatter.writeAll("module"),

            inline else => |*x| try x.onFormat(formatter)
        }
    }

    /// Get the `Kind` of the type described by this type information.
    pub fn getKind(self: *const TypeInfo) TypeInfo.Kind {
        return switch (self.*) {
            inline .@"var", .product, .sum,
            => |x| x.kind,

            .nil, .bool, .integer, .float, .pointer, .slice, .sentinel, .array, .@"struct", .@"union",
            => .data,

            .@"opaque" => .@"opaque",
            .function => .function,
            .foreign_address => .foreign_address,
            .effect => .effect,
            .handler => .handler,
            .noreturn => .noreturn,
            .type => .type,
            .block => .block,
            .module => .module,
            .local => .local,
        };
    }

    /// Create integer type info.
    pub fn integerOf(bitSize: pl.IntegerBitSize, signedness: pl.Signedness) TypeInfo {
        return .{
            .integer = .{
                .bit_size = bitSize,
                .signedness = signedness,
            },
        };
    }

    /// Create floating point type info.
    pub fn floatOf(precision: FloatPrecision) TypeInfo {
        return .{
            .float = .{
                .precision = precision,
            },
        };
    }

    /// Create pointer type info.
    pub fn pointerOf(element: *const ir.Type, allocator: ?*const ir.Type, alignmentOverride: ?pl.IntegerBitSize) TypeInfo {
        return .{
            .pointer = .{
                .element = element,
                .allocator = allocator,
                .alignment_override = alignmentOverride,
            },
        };
    }

    /// Create slice type info.
    pub fn sliceOf(element: *const ir.Type, allocator: ?*const ir.Type, alignmentOverride: ?pl.IntegerBitSize) TypeInfo {
        return .{
            .slice = .{
                .element = element,
                .allocator = allocator,
                .alignment_override = alignmentOverride,
            },
        };
    }

    /// Create sentinel-terminated pointer type info.
    pub fn sentinelOf(element: *const ir.Type, sentinel: *const ir.Constant, allocator: ?*const ir.Type, alignmentOverride: ?pl.IntegerBitSize) TypeInfo {
        return .{
            .sentinel = .{
                .element = element,
                .sentinel = sentinel,
                .allocator = allocator,
                .alignment_override = alignmentOverride,
            },
        };
    }

    /// Create array type info.
    pub fn arrayOf(element: *const ir.Type, length: TypeInfo.ArrayLength) TypeInfo {
        return .{
            .array = .{
                .element = element,
                .length = length,
            },
        };
    }

    /// Create local type info.
    pub fn localOf(element: *const ir.Type) TypeInfo {
        return .{
            .local = .{
                .element = element,
            },
        };
    }

    /// Extract function type information from a variety of types, such as foreign addresses and effect handlers.
    /// * Returns `error.TypeMismatch` if the type does not lead to a function type with a single pointer of indirection.
    pub fn coerceFunction(self: *const TypeInfo) error{TypeMismatch}!*const TypeInfo.Function {
        return switch (self.*) {
            .function => |*x| x,
            .foreign_address => |*x|
                switch (x.element.info) {
                    .function => |*f| f,
                    .handler => |*h|
                        if (h.signature.info == .function) &h.signature.info.function
                        else return error.TypeMismatch,
                    else => return error.TypeMismatch,
                },
            .handler => |*x|
                switch (x.signature.info) {
                    .function => |*f| f,
                    .foreign_address => |*f|
                        if (f.element.info == .function) &f.element.info.function
                        else return error.TypeMismatch,
                    else => return error.TypeMismatch,
                },
            .pointer => |*x|
                if (x.element.info == .function) &x.element.info.function
                else return error.TypeMismatch,
            else => |x| {
                log.err("TypeInfo.coerceFunction: got {}", .{x});
                return error.TypeMismatch;
            },
        };
    }

    /// The discriminant type for type info variants.
    pub const Tag: type = std.meta.Tag(TypeInfo);

    /// Designates the member layout algorithm to use for a struct or union.
    pub const LayoutMethod = enum {
        /// Best-effort C-ABI matching layout.
        c_style,
        /// No padding or alignment concerns, fit fields into as few bits as possible.
        bit_pack,
    };

    /// A field in struct type information
    pub const StructField = struct {
        /// The type of the field.
        type: *const ir.Type,
        /// The debug name of the field, if it has one.
        name: ?*const Name,

        fn hash(self: *const TypeInfo.StructField, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.type));
        }

        fn eql(self: *const TypeInfo.StructField, other: *const TypeInfo.StructField) bool {
            return self.type == other.type;
        }
    };

    /// A field in union type information.
    pub const UnionField = struct {
        /// The constant value that serves as a tag identifying this field as the active one in the union.
        discriminator: *Constant,
        /// The type of the field.
        type: *const ir.Type,
        /// The debug name of the field, if it has one.
        name: ?*const Name,

        fn hash(self: *const TypeInfo.UnionField, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.discriminator));
            hasher.update(std.mem.asBytes(&self.type));
        }

        fn eql(self: *const TypeInfo.UnionField, other: *const TypeInfo.UnionField) bool {
            return self.discriminator == other.discriminator
               and self.type == other.type;
        }
    };

    /// Describes the manner in which an effect handler may end its computation.
    pub const Cancel = enum {
        /// The effect handler never returns or cancels.
        divergent,
        /// The effect handler never cancels its caller; it always returns a value.
        always_returns,
        /// The effect handler always cancels its caller; it never returns a value.
        always_cancels,
        /// The effect handler may cancel its caller, or it may return a value.
        conditional,
    };

    /// Represents the precision of a floating point type.
    pub const FloatPrecision = enum(std.math.IntFittingRange(0, 128)) {
        /// Half-precision, 16-bit float; not widely supported.
        half = 16,
        /// Single-precision, 32-bit float. (c `float`)
        single = 32,
        /// Double-precision, 64-bit float. (c `double`)
        double = 64,
        /// Extended-precision, 80-bit float; not widely supported.
        eighty = 80,
        /// Quad-precision, 128-bit float; not widely supported.
        quad = 128,

        /// Get an `IntegerBitSize` from this `FloatPrecision`.
        pub fn toInt(self: TypeInfo.FloatPrecision) pl.IntegerBitSize {
            return @intFromEnum(self);
        }

        /// Get an `IntegerBitSize` from this `FloatPrecision`, representing the size of the mantissa portion.
        pub fn mantissaBits(self: TypeInfo.FloatPrecision) pl.IntegerBitSize {
            return switch (self) {
                .half => 11,
                .single => 24,
                .double => 53,
                .eighty => 64,
                .quad => 113,
            };
        }

        /// Get an `IntegerBitSize` from this `FloatPrecision`, representing the size of the exponent portion.
        pub fn exponentBits(self: TypeInfo.FloatPrecision) pl.IntegerBitSize {
            return switch (self) {
                .half => 5,
                .single => 8,
                .double => 11,
                .eighty => 15,
                .quad => 15,
            };
        }
    };

    /// Type kinds refer to the general category of a type, be it data, function, etc.
    /// This provides a high-level discriminator for where values of a type can be used or stored.
    pub const Kind = enum {
        /// Data types can be stored anywhere, passed as arguments, etc.
        /// Size is known, some can be used in arithmetic or comparisons.
        data,
        /// Opaque types cannot be values, only the destination of a pointer.
        /// Size is unknown, and they cannot be used in arithmetic or comparisons.
        @"opaque",
        /// Function types can be called, have side effects, have a return value, and can be passed as arguments (via coercion to pointer).
        /// They cannot be stored in memory, and have no size.
        function,
        /// Foreign addresses are pointers to external functions or data, and can be called or dereferenced, depending on type.
        foreign_address,
        /// Effect types represent a side effect that can be performed by a function.
        effect,
        /// Handler types represent a function that can handle a side effect.
        /// In addition to the other properties of functions they have a cancel type.
        handler,
        /// No return types represent functions that do not return, and cannot be used in arithmetic or comparisons.
        /// Any use of a value of this type is undefined, as it is inherently dead code.
        noreturn,
        /// in the event a type is referenced as a value, it will have the type `Type`, which is of this kind.
        /// Size is known, can be used for comparisons.
        type,
        /// in the event an effect handler block is referenced as a value, it will have the type `Block`, which is of this kind.
        /// Size is known, can be used for comparisons.
        block,
        /// in the event a module is referenced as a value, it will have the type `Module`, which is of this kind.
        /// Size is known, can be used for comparisons.
        module,
        /// in the event a local variable is referenced as a value, it will have the type `Local`, which is of this kind.
        /// Size is known, can be used for comparisons.
        local,
    };

    /// A placeholder for an actual type, of a specific kind.
    /// As a top-level variant, this allows easy substitution throughout a complete IR unit,
    /// though it should be noted that Rir does not have a concept of type constraints at this time,
    /// and the fallibility of arbitrary substitutions must be accounted for.
    pub const Var = struct {
        /// The kind of type that this placeholder variable represents.
        kind: TypeInfo.Kind,

        fn hash(self: *const TypeInfo.Var, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.kind));
        }

        fn eql(self: *const TypeInfo.Var, other: *const TypeInfo.Var) bool {
            return self.kind == other.kind;
        }

        fn onFormat(self: *const TypeInfo.Var, formatter: anytype) !void {
            try formatter.print("any({})", .{self.kind});
        }
    };

    /// A wrapper for a local variable's type.
    pub const Local = struct {
        /// The type of value that local variables of this type contain.
        element: *const ir.Type,

        fn hash(self: *const TypeInfo.Local, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.element));
        }

        fn eql(self: *const TypeInfo.Local, other: *const TypeInfo.Local) bool {
            return self.element == other.element;
        }

        fn onFormat(self: *const TypeInfo.Local, formatter: anytype) !void {
            try formatter.print("local({})", .{self.element});
        }
    };

    /// Represents the type of integer values, signed or unsigned, arbitrary bit size.
    pub const Integer = struct {
        /// The bit size of the integer type, up to the max alignment.
        bit_size: pl.IntegerBitSize,
        /// Determines whether or not the integer type can represent numbers less than zero.
        signedness: pl.Signedness,

        fn hash(self: *const TypeInfo.Integer, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.bit_size));
            hasher.update(std.mem.asBytes(&self.signedness));
        }

        fn eql(self: *const TypeInfo.Integer, other: *const TypeInfo.Integer) bool {
            return self.bit_size == other.bit_size and self.signedness == other.signedness;
        }

        fn onFormat(self: *const TypeInfo.Integer, formatter: anytype) !void {
            try formatter.print("{u}{d}", .{
                switch (self.signedness) {
                    .signed => @as(u8, 'i'),
                    .unsigned => 'u',
                },
                self.bit_size,
            });
        }
    };

    /// Represents the type of floating point values, with choice of precision.
    pub const Float = struct {
        /// The precision of the floating point type, usually single or double.
        precision: TypeInfo.FloatPrecision,

        fn hash(self: *const TypeInfo.Float, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.precision));
        }

        fn eql(self: *const TypeInfo.Float, other: *const TypeInfo.Float) bool {
            return self.precision == other.precision;
        }

        fn onFormat(self: *const TypeInfo.Float, formatter: anytype) !void {
            try formatter.print("f{d}", .{@intFromEnum(self.precision)});
        }
    };

    /// Represents the type of a pointer to a value of another type.
    pub const Pointer = struct {
        /// The type of the value that this pointer type points to.
        element: *const ir.Type,
        /// The type of the allocator that will be used to allocate the pointed-to value, if it is known.
        /// Pointers to foreign values will usually have a null allocator, representing the fact
        /// that the program compiled by the IR unit does not manage the memory.
        allocator: ?*const ir.Type,
        /// The alignment override, if it has one, for the value at the pointer's address.
        /// When null, the natural alignment of the value is used.
        alignment_override: ?pl.IntegerBitSize,

        fn hash(self: *const TypeInfo.Pointer, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.element));

            if (self.allocator) |al| {
                hasher.update(std.mem.asBytes(&al));
            } else {
                hasher.update("null");
            }

            if (self.alignment_override) |al| {
                hasher.update(std.mem.asBytes(&al));
            } else {
                hasher.update("null");
            }
        }

        fn eql(self: *const TypeInfo.Pointer, other: *const TypeInfo.Pointer) bool {
            if (self.element != other.element) return false;

            if (self.allocator) |a1| {
                if (other.allocator) |a2| {
                    if (a1 != a2) return false;
                } else {
                    return false;
                }
            } else if (other.allocator != null) {
                return false;
            }

            if (self.alignment_override) |a1| {
                if (other.alignment_override) |a2| {
                    if (a1 != a2) return false;
                } else {
                    return false;
                }
            } else if (other.alignment_override != null) {
                return false;
            }

            return true;
        }

        fn onFormat(self: *const TypeInfo.Pointer, formatter: anytype) !void {
            if (self.allocator) |allocatorType| {
                try formatter.print("{} ", .{allocatorType});
            }

            try formatter.writeAll("^");

            if (self.alignment_override) |alignment| {
                try formatter.print("align({d}) ", .{alignment});
            }

            try formatter.fmt(self.element);
        }
    };

    /// Represents the type of a slice of values of another type,
    /// ie a wide pointer containing an address and a length.
    pub const Slice = struct {
        /// The type of the values that this slice type points to.
        element: *const ir.Type,
        /// The type of the allocator that will be used to allocate the pointed-to buffer, if it is known.
        /// Slices of foreign values will usually have a null allocator, representing the fact
        /// that the program compiled by the IR unit does not manage the memory.
        allocator: ?*const ir.Type,
        /// The alignment override, if it has one, for the values at the slice's address.
        /// When null, the natural alignment of the value is used.
        alignment_override: ?pl.Alignment,

        fn hash(self: *const TypeInfo.Slice, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.element));

            if (self.allocator) |al| {
                hasher.update(std.mem.asBytes(&al));
            } else {
                hasher.update("null");
            }

            if (self.alignment_override) |al| {
                hasher.update(std.mem.asBytes(&al));
            } else {
                hasher.update("null");
            }
        }

        fn eql(self: *const TypeInfo.Slice, other: *const TypeInfo.Slice) bool {
            if (self.element != other.element) return false;

            if (self.allocator) |a1| {
                if (other.allocator) |a2| {
                    if (a1 != a2) return false;
                } else {
                    return false;
                }
            } else if (other.allocator != null) {
                return false;
            }

            if (self.alignment_override) |a1| {
                if (other.alignment_override) |a2| {
                    if (a1 != a2) return false;
                } else {
                    return false;
                }
            } else if (other.alignment_override != null) {
                return false;
            }

            return true;
        }

        fn onFormat(self: *const TypeInfo.Slice, formatter: anytype) !void {
            if (self.allocator) |allocatorType| {
                try formatter.print("{} ", .{allocatorType});
            }

            try formatter.writeAll("^");

            if (self.alignment_override) |alignment| {
                try formatter.print("align({d}) ", .{alignment});
            }
        }
    };

    /// Represents the type of a c-style sentinel-terminated buffers of another type,
    /// ie a single pointer to a sequence of values,
    /// the end of which is signified by a compile-time specified value
    /// (such as null, in the case of c-style strings).
    pub const Sentinel = struct {
        /// The type of the values that this sentinel type points to.
        element: *const ir.Type,
        /// The constant representing the sentinel value that terminates all buffers of this type.
        /// e.g., for c strings, this is a single null byte.
        sentinel: *const ir.Constant,
        /// The type of the allocator that will be used to allocate the pointed-to buffer, if it is known.
        /// Buffers of foreign values will usually have a null allocator, representing the fact
        /// that the program compiled by the IR unit does not manage the memory.
        allocator: ?*const ir.Type,
        /// The alignment override, if it has one, for the values at the buffers's address.
        /// When null, the natural alignment of the value is used.
        alignment_override: ?pl.Alignment,

        fn hash(self: *const TypeInfo.Sentinel, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.element));

            hasher.update(std.mem.asBytes(&self.sentinel));

            if (self.allocator) |al| {
                hasher.update(std.mem.asBytes(&al));
            } else {
                hasher.update("null");
            }

            if (self.alignment_override) |al| {
                hasher.update(std.mem.asBytes(&al));
            } else {
                hasher.update("null");
            }
        }

        fn eql(self: *const TypeInfo.Sentinel, other: *const TypeInfo.Sentinel) bool {
            if (self.element != other.element) return false;

            if (self.allocator) |a1| {
                if (other.allocator) |a2| {
                    if (a1 != a2) return false;
                } else {
                    return false;
                }
            } else if (other.allocator != null) {
                return false;
            }

            if (self.alignment_override) |a1| {
                if (other.alignment_override) |a2| {
                    if (a1 != a2) return false;
                } else {
                    return false;
                }
            } else if (other.alignment_override != null) {
                return false;
            }

            return true;
        }

        fn onFormat(self: *const TypeInfo.Sentinel, formatter: anytype) !void {
            if (self.allocator) |allocatorType| {
                try formatter.print("{} ", .{allocatorType});
            }

            try formatter.writeAll("^");

            if (self.alignment_override) |alignment| {
                try formatter.print("align({d}) ", .{alignment});
            }
        }
    };

    /// Represents the length of an array type.
    pub const ArrayLength = u64;

    /// Represents the type of an array of values of another type
    pub const Array = struct {
        /// The type of the values that this array type contains
        element: *const ir.Type,
        /// The number of elements in the array
        length: TypeInfo.ArrayLength,

        fn hash(self: *const TypeInfo.Array, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.element));
            hasher.update(std.mem.asBytes(&self.length));
        }

        fn eql(self: *const TypeInfo.Array, other: *const TypeInfo.Array) bool {
            return self.element == other.element and self.length == other.length;
        }

        fn onFormat(self: *const TypeInfo.Array, formatter: anytype) !void {
            try formatter.print("[{} x {}]", .{ self.element, self.length });
        }
    };

    /// Represents the type of a function.
    /// In Rir, functions always have a single parameter type, a single return value type,
    /// and may optionally have a single side effect type.
    ///
    /// To represent a function which:
    /// + Has no parameters: use `Nil` for the input type.
    /// + With multiple parameters: use `Product` for the input type.
    /// + With multiple return values: use `Product` for the output type.
    /// + That does not return: use `NoReturn` for the output type.
    /// + Returns no value: use `Nil` for the output type.
    /// + Has multiple possible side effects: use `Product` for the effect type.
    /// + Has no possible side effect: use `null` for the effect type.
    pub const Function = struct {
        /// The type of the input parameter.
        input: *const ir.Type,
        /// The type of the return value.
        output: *const ir.Type,
        /// The type of the side effect that can be performed by this function, if any.
        effect: ?*const ir.Type,

        fn hash(self: *const TypeInfo.Function, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.input));

            hasher.update(std.mem.asBytes(&self.output));

            if (self.effect) |e| {
                hasher.update(std.mem.asBytes(&e));
            } else {
                hasher.update("null");
            }
        }

        fn eql(self: *const TypeInfo.Function, other: *const TypeInfo.Function) bool {
            if (self.input != other.input) return false;
            if (self.output != other.output) return false;

            if (self.effect) |e1| {
                if (other.effect) |e2| {
                    if (e1 != e2) return false;
                } else {
                    return false;
                }
            } else if (other.effect != null) {
                return false;
            }

            return true;
        }

        fn onFormat(self: *const TypeInfo.Function, formatter: anytype) !void {
            try formatter.print("function({} -> {}", .{ self.input, self.output });

            if (self.effect) |e| {
                try formatter.print(" in {}", .{e});
            }

            try formatter.writeAll(")");
        }
    };

    /// Represents the type of a foreign address, a pointer to an external function or data.
    pub const ForeignAddress = struct {
        element: *const ir.Type,

        fn hash(self: *const TypeInfo.ForeignAddress, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.element));
        }

        fn eql(self: *const TypeInfo.ForeignAddress, other: *const TypeInfo.ForeignAddress) bool {
            return self.element == other.element;
        }

        fn onFormat(self: *const TypeInfo.ForeignAddress, formatter: anytype) !void {
            try formatter.print("foreign({})", .{self.element});
        }
    };

    /// Represents the type of a side effect that can be performed by a function.
    pub const Effect = struct {
        /// The effect's specific information.
        effect: *const ir.Effect,

        fn hash(self: *const TypeInfo.Effect, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.effect));
        }

        fn eql(self: *const TypeInfo.Effect, other: *const TypeInfo.Effect) bool {
            return self.effect == other.effect;
        }

        fn onFormat(self: *const TypeInfo.Effect, formatter: anytype) !void {
            try formatter.fmt(self.effect);
        }
    };

    /// Represents the type of a function that can handle a side effect.
    pub const Handler = struct {
        /// The type of the side effect that this handler can process.
        target: *const ir.Type,
        /// The cancellation style of this handler.
        cancel: Cancel,
        /// The function signature of this handler.
        signature: *const ir.Type,

        fn hash(self: *const TypeInfo.Handler, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.target));
            hasher.update(std.mem.asBytes(&self.cancel));
            hasher.update(std.mem.asBytes(&self.signature));
        }

        fn eql(self: *const TypeInfo.Handler, other: *const TypeInfo.Handler) bool {
            return self.target == other.target
               and self.cancel == other.cancel
               and self.signature == other.signature;
        }

        fn onFormat(self: *const TypeInfo.Handler, formatter: anytype) !void {
            try formatter.print("handler({} -> ", .{self.input});

            switch (self.cancel) {
                .divergent => try formatter.writeAll("noreturn"),
                .always_returns => |returnType| try formatter.print("{}", .{returnType}),
                .always_cancels => |cancelType| try formatter.print("!{}", .{cancelType}),
                .conditional => |types| try formatter.print("{} ?{}", .{types.on_return, types.on_cancel}),
            }

            if (self.effect) |effectType| {
                try formatter.print(" in {}", .{effectType});
            }

            try formatter.writeAll(")");
        }
    };




    /// Represents the type of a user-defined product data structure, with fields of various types.
    /// Structures may appear in memory in a variety of ways, depending on the layout method and alignment.
    /// Additionally, fields may optionally have a name associated with them for debugging purposes.
    pub const Struct = struct {
        /// The layout method to use for this struct.
        layout_method: TypeInfo.LayoutMethod,
        /// The alignment override of the struct, if it has one.
        /// When null, the natural alignment of the struct is used;
        /// that is, the alignment of the field with the largest alignment,
        /// or the alignment of the backing integer if `layout_method` is `.bit_pack`
        alignment_override: ?pl.Alignment,
        /// The fields of the struct, in machine order.
        fields: []const TypeInfo.StructField,

        fn clone(self: *const TypeInfo.Struct, allocator: std.mem.Allocator) error{OutOfMemory}!TypeInfo.Struct {
            return TypeInfo.Struct{
                .layout_method = self.layout_method,
                .alignment_override = self.alignment_override,
                .fields = try allocator.dupe(TypeInfo.StructField, self.fields),
            };
        }

        fn deinit(self: TypeInfo.Struct, allocator: std.mem.Allocator) void {
            allocator.free(self.fields);
        }

        fn hash(self: *const TypeInfo.Struct, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.layout_method));

            if (self.alignment_override) |al| {
                hasher.update(std.mem.asBytes(&al));
            } else {
                hasher.update("null");
            }

            for (self.fields) |*field| field.hash(hasher);
        }

        fn eql(self: *const TypeInfo.Struct, other: *const TypeInfo.Struct) bool {
            if (self.layout_method != other.layout_method) return false;

            if (self.alignment_override) |al1| {
                if (other.alignment_override) |al2| {
                    if (al1 != al2) return false;
                } else {
                    return false;
                }
            } else if (other.alignment_override != null) {
                return false;
            }

            if (self.fields.len != other.fields.len) return false;

            for (self.fields, other.fields) |*field1, *field2| {
                if (!field1.eql(field2)) return false;
            }

            return true;
        }

        fn onFormat(self: *const TypeInfo.Struct, formatter: anytype) !void {
            switch (self.layout_method) {
                .c_style => try formatter.writeAll("struct "),
                .bit_pack => try formatter.writeAll("packed struct "),
            }

            if (self.alignment_override) |al| {
                try formatter.print("align({}) ", .{al});
            }

            try formatter.beginBlock(.Structure);

            for (self.fields, 0..) |*field, i| {
                if (i > 0) {
                    try formatter.endLine(true);
                }

                if (field.name) |name| {
                    try formatter.fmt(name);
                } else {
                    try formatter.fmt(i);
                }

                try formatter.print(": {}", .{field.type});
            }

            try formatter.endBlock();
        }
    };

    /// Represents the type of a user-defined sum data structure, with fields of various types.
    /// Unions may appear in memory in a variety of ways, depending on the layout method and alignment.
    /// Each field in a union has a discriminator, which is a compile-time constant that is used to identify the field,
    /// all discriminator constants must be of the union's discriminator type.
    /// Additionally, fields may optionally have a name associated with them for debugging purposes.
    pub const Union = struct {
        /// The type of the compile-time constants that are used to identify the active field in the union.
        /// All fields in the union must have a discriminator that is of this type.
        /// Must be an integer type.
        discriminator: *const ir.Type,
        /// The layout method to use for this union.
        layout_method: TypeInfo.LayoutMethod,
        /// The alignment override of the union, if it has one.
        /// When null, the natural alignment of the union is used;
        /// that is, the alignment of the field with the largest alignment,
        /// or the alignment of the backing integer if `layout_method` is `.bit_pack`
        alignment_override: ?pl.Alignment,
        /// The fields of the union, in order.
        fields: []const TypeInfo.UnionField,

        fn clone(self: *const TypeInfo.Union, allocator: std.mem.Allocator) error{OutOfMemory}!TypeInfo.Union {
            return TypeInfo.Union{
                .discriminator = self.discriminator,
                .layout_method = self.layout_method,
                .alignment_override = self.alignment_override,
                .fields = try allocator.dupe(TypeInfo.UnionField, self.fields),
            };
        }

        fn deinit(self: TypeInfo.Union, allocator: std.mem.Allocator) void {
            allocator.free(self.fields);
        }

        fn hash(self: *const TypeInfo.Union, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.discriminator));

            hasher.update(std.mem.asBytes(&self.layout_method));

            if (self.alignment_override) |al| {
                hasher.update(std.mem.asBytes(&al));
            } else {
                hasher.update("null");
            }

            for (self.fields) |*field| field.hash(hasher);
        }

        fn eql(self: *const TypeInfo.Union, other: *const TypeInfo.Union) bool {
            if (self.discriminator != other.discriminator) return false;

            if (self.layout_method != other.layout_method) return false;

            if (self.alignment_override) |a1| {
                if (other.alignment_override) |a2| {
                    if (a1 != a2) return false;
                } else {
                    return false;
                }
            } else if (other.alignment_override != null) {
                return false;
            }

            if (self.fields.len != other.fields.len) return false;

            for (self.fields, other.fields) |*field1, *field2| {
                if (!field1.eql(field2)) return false;
            }

            return true;
        }

        fn onFormat(self: *const TypeInfo.Union, formatter: anytype) !void {
            switch (self.layout_method) {
                .c_style => try formatter.writeAll("union "),
                .bit_pack => try formatter.writeAll("packed union "),
            }

            if (self.alignment_override) |al| {
                try formatter.print("align({}) ", .{al});
            }

            try formatter.beginBlock(.Structure);

            for (self.fields, 0..) |*field, i| {
                if (i > 0) {
                    try formatter.endLine(true);
                }

                try formatter.print("({})", .{field.discriminator});

                if (field.name) |name| {
                    try formatter.print(" {}", .{name});
                }

                try formatter.print(": {}", .{field.type});
            }

            try formatter.endBlock();
        }
    };

    /// Represents the type of a user-defined product data structure, with fields of various types.
    /// Unlike `Struct`, fields here do not have names, and are simply carried together;
    /// Additionally, `Product` does not offer layout control.
    /// This is meant to represent simple product types like multiple return, but not complex structures.
    pub const Product = struct {
        /// The kind of the types inside this product type.
        kind: TypeInfo.Kind,
        /// The types that are carried together to form this product type.
        types: []*const ir.Type,

        fn clone(self: *const TypeInfo.Product, allocator: std.mem.Allocator) error{OutOfMemory}!TypeInfo.Product {
            return TypeInfo.Product{
                .kind = self.kind,
                .types = try allocator.dupe(*const ir.Type, self.types),
            };
        }

        fn deinit(self: TypeInfo.Product, allocator: std.mem.Allocator) void {
            allocator.free(self.types);
        }

        fn hash(self: *const TypeInfo.Product, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.kind));

            for (self.types) |t| {
                hasher.update(std.mem.asBytes(&t));
            }
        }

        fn eql(self: *const TypeInfo.Product, other: *const TypeInfo.Product) bool {
            if (self.kind != other.kind) return false;

            if (self.types.len != other.types.len) return false;

            for (self.types, other.types) |t1, t2| {
                if (t1 != t2) return false;
            }

            return true;
        }

        fn onFormat(self: *const TypeInfo.Product, formatter: anytype) !void {
            try formatter.writeAll("(");
            for (self.types, 0..) |typeIr, i| {
                if (i > 0) {
                    try formatter.writeAll(" * ");
                }

                try formatter.fmt(typeIr);
            }
            try formatter.writeAll(")");
        }
    };

    /// Represents the type of a user-defined sum data structure, with fields of various types.
    /// Unlike `Union`, fields here do not have names or discriminators, and are simply added together;
    /// Additionally, `Sum` does not offer layout control.
    /// This is meant to represent c-style untagged unions.
    pub const Sum = struct {
        /// The kind of the types inside this sum type.
        kind: TypeInfo.Kind,
        /// The types that are added together to form this sum type.
        types: []*const ir.Type,

        fn clone(self: *const TypeInfo.Sum, allocator: std.mem.Allocator) error{OutOfMemory}!TypeInfo.Sum {
            return TypeInfo.Sum{
                .kind = self.kind,
                .types = try allocator.dupe(*const ir.Type, self.types),
            };
        }

        fn deinit(self: TypeInfo.Sum, allocator: std.mem.Allocator) void {
            allocator.free(self.types);
        }

        fn hash(self: *const TypeInfo.Sum, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.kind));

            for (self.types) |t| {
                hasher.update(std.mem.asBytes(&t));
            }
        }

        fn eql(self: *const TypeInfo.Sum, other: *const TypeInfo.Sum) bool {
            if (self.kind != other.kind) return false;

            if (self.types.len != other.types.len) return false;

            for (self.types, other.types) |t1, t2| {
                if (t1 != t2) return false;
            }

            return true;
        }

        fn onFormat(self: *const TypeInfo.Sum, formatter: anytype) !void {
            try formatter.writeAll("(");
            for (self.types, 0..) |typeIr, i| {
                if (i > 0) {
                    try formatter.writeAll(" + ");
                }

                try formatter.fmt(typeIr);
            }
            try formatter.writeAll(")");
        }
    };
};

/// The representation of source code modules in the IR.
/// Modules can contain global variables and functions.
/// They must be given a name for symbol resolution purposes.
pub const Module = struct {
    /// The IR unit that owns this module.
    root: *const Builder,
    /// The unique identifier of this module.
    id: Id.of(Module),
    /// The name of this module, for symbol resolution purposes.
    name: *const Name,
    /// The global variables defined in this module.
    globals: Id.Set(*const Global, 80) = .{},
    /// The functions defined in this module.
    functions: Id.Set(*const Function, 80) = .{},
    /// Fresh id generator
    fresh_global_id: Id.of(Global) = .fromInt(1),
    /// Fresh id generator
    fresh_function_id: Id.of(Function) = .fromInt(1),

    fn init(root: *const Builder, id: Id.of(Module), name: *const Name) error{OutOfMemory}!*Module {
        const self = try root.allocator.create(Module);

        self.* = Module {
            .root = root,
            .id = id,
            .name = name,
        };

        return self;
    }

    fn deinit(ptr: *const Module) void {
        const self: *Module = @constCast(ptr);

        const allocator = self.root.allocator;
        defer allocator.destroy(self);

        var globalIt = self.globals.keyIterator();
        while (globalIt.next()) |globalPtr| {
            Global.deinit(globalPtr.*);
        }

        var functionIt = self.functions.keyIterator();
        while (functionIt.next()) |functionPtr| {
            Function.deinit(functionPtr.*);
        }

        self.globals.deinit(self.root.allocator);
        self.functions.deinit(self.root.allocator);
    }

    pub fn createGlobal(
        ptr: *const Module,
        nameString: []const u8,
        typeIr: *const Type,
        initialValue: ?*const Constant,
    ) !*const Global {
        const self: *Module = @constCast(ptr);
        // TODO: collision check
        const id = self.fresh_global_id.next();
        const name = try self.root.internName(nameString);

        const global = try Global.init(self.root, self, id, name, typeIr);

        if (initialValue) |value| {
            global.initial_value = value;
        }

        try self.globals.put(self.root.allocator, global, {});

        return global;
    }

    pub fn createFunction(
        ptr: *const Module,
        parentSet: ?*const HandlerSet,
        nameString: []const u8,
        typeIr: *const Type,
    ) !*const Function {
        const self: *Module = @constCast(ptr);
        // TODO: collision check
        const id = self.fresh_function_id.next();
        const name = try self.root.internName(nameString);
        // TODO: would be good to insert some debug sanity checks here like that the parentSet is in the same module
        const function = try Function.init(self.root, self, parentSet, id, name, typeIr);

        try self.functions.put(self.root.allocator, function, {});

        return function;
    }

    pub fn onFormat(self: *const Module, formatter: anytype) !void {
        try formatter.fmt(self.name);

        if (self.globals.count() | self.functions.count() == 0) {
            return formatter.writeAll("{}");
        }

        try formatter.beginBlock(.Structure);
        var globalIt = self.globals.keyIterator();

        if (globalIt.next()) |firstPtr| {
            try formatter.writeAll("globals:");
            try formatter.beginBlock(.Structure);

            try formatter.fmt(firstPtr.*);

            while (globalIt.next()) |globalPtr| {
                try formatter.endLine(true);

                try formatter.fmt(globalPtr.*);
            }

            try formatter.endBlock();
        }

        var functionIt = self.functions.keyIterator();
        if (functionIt.next()) |firstPtr| {
            try formatter.writeAll("functions:");
            try formatter.beginBlock(.Structure);

            try formatter.fmt(firstPtr.*);

            while (functionIt.next()) |functionPtr| {
                try formatter.endLine(true);

                try formatter.fmt(functionPtr.*);
            }

            try formatter.endBlock();
        }
        try formatter.endBlock();
    }
};

/// The representation of global variables in the IR.
/// Global variables are defined in modules and must be given a name for symbol resolution purposes.
/// They may have an initial value, which must be of the same type as the global variable.
pub const Global = struct {
    /// The IR unit that owns this global.
    root: *const Builder,
    /// The module that this global variable belongs to.
    module: *const Module,
    /// The unique identifier of this global variable.
    id: Id.of(Global),
    /// The name of this global variable, for symbol resolution purposes.
    name: *const Name,
    /// The type of this global variable.
    type: *const ir.Type,
    /// The initial value of this global variable, if any.
    /// Must be of the same type, if present.
    initial_value: ?*const Constant = null,

    fn init(root: *const Builder, module: *Module, id: Id.of(Global), name: *const Name, typeIr: *const ir.Type) error{OutOfMemory}!*Global {
        const self = try root.allocator.create(Global);

        self.* = .{
            .root = root,
            .module = module,
            .id = id,
            .name = name,
            .type = typeIr,
        };

        return self;
    }

    fn deinit(self: *const Global) void {
        const allocator = self.root.allocator;
        defer allocator.destroy(self);
    }

    pub fn onFormat(self: *const Global, formatter: anytype) !void {
        try formatter.print("global({} :: {})", .{self.name, self.type});

        if (self.initial_value) |initialValue| {
            try formatter.print(" = {}", .{initialValue});
        }
    }
};

/// An intermediate representation of functions.
/// Functions are defined in modules and must be given a name for symbol resolution purposes.
pub const Function = struct {
    /// The IR unit that owns this function.
    root: *const Builder,
    /// The module that this function belongs to.
    module: *const Module,
    /// The handler set that this function belongs to, if any.
    parent_set: ?*const HandlerSet,
    /// The unique identifier of this function.
    id: Id.of(Function),
    /// The name of this function, for symbol resolution purposes.
    name: *const Name,
    /// The type of this function.
    type: *const Type,
    /// Arena allocator owning all `Instruction`s referenced by this function.
    arena: std.heap.ArenaAllocator,
    /// Fresh id generator for blocks.
    fresh_block_id: Id.of(Block) = .fromInt(1),
    /// Basic blocks in this function.
    blocks: Id.Set(*const Block, 80) = .empty,
    /// All instruction relations for the function are stored here in the form of use->def edges.
    edges: EdgeMap = .empty,
    /// The beginning block of this function.
    entry: *const Block,

    const EdgeMap = pl.UniqueReprMap(*const Instruction, EdgeList, 80);
    // Not a set because we can do for example `add x x`
    const EdgeList = pl.ArrayList(UseDef);

    fn init(
        root: *const Builder,
        module: *const Module,
        parentSet: ?*const HandlerSet,
        id: Id.of(Function),
        name: *const Name,
        typeIr: *const Type,
    ) error{OutOfMemory}!*Function {
        const self = try root.allocator.create(Function);

        self.* = .{
            .root = root,
            .module = module,
            .parent_set = parentSet,
            .id = id,
            .name = name,
            .type = typeIr,
            .arena = std.heap.ArenaAllocator.init(root.allocator),
            .entry = try Block.init(self, root.builtin.names.entry, .fromInt(1)),
        };

        try self.edges.ensureTotalCapacity(root.allocator, 1024);
        try self.blocks.ensureTotalCapacity(root.allocator, 64);

        self.blocks.putAssumeCapacity(self.entry, {});

        return self;
    }

    fn getOrCreateEdgeList(
        ptr: *const Function,
        use: *const Instruction,
    ) error{OutOfMemory}!*EdgeList {
        const self: *Function = @constCast(ptr);

        const getOrPut = try self.edges.getOrPut(self.root.allocator, use);
        if (!getOrPut.found_existing) {
            getOrPut.value_ptr.* = try EdgeList.initCapacity(self.root.allocator, 128);
        }

        return getOrPut.value_ptr;
    }


    /// Get a list of edges from `use` to any defs it references.
    pub fn getUseDefs(
        ptr: *const Function,
        use: *const Instruction,
    ) []const UseDef {
        return (ptr.getOrCreateEdgeList(use) catch return &.{}).items;
    }

    /// Adds an edge from `use` to `def`, at the start of the list.
    /// * This is a directed edge, meaning that `def` becomes a predecessor of `use`.
    /// * This is an ordered insertion, other edges may be moved.
    pub fn prependUseDef(
        ptr: *const Function,
        use: *const Instruction,
        def: UseDef,
    ) error{OutOfMemory, InvalidIndex, InvalidCycle}!void {
        return ptr.insertUseDef(use, 0, def);
    }

    /// Adds an edge from `use` to `def`, at the end of the list.
    /// * This is a directed edge, meaning that `def` becomes a predecessor of `use`.
    pub fn appendUseDef(
        ptr: *const Function,
        use: *const Instruction,
        def: UseDef,
    ) error{OutOfMemory, InvalidCycle}!void {
        const self: *Function = @constCast(ptr);

        if (UseDef.fromPtr(use) == def) return error.InvalidCycle;

        const edgeList = try self.getOrCreateEdgeList(use);

        try edgeList.append(self.root.allocator, def);
    }

    /// Adds an edge from `use` to `def`.
    /// * This is a directed edge, meaning that `def` becomes a predecessor of `use`.
    pub fn insertUseDef(
        ptr: *const Function,
        use: *const Instruction,
        index: usize,
        def: UseDef,
    ) error{OutOfMemory, InvalidIndex, InvalidCycle}!void {
        const self: *Function = @constCast(ptr);

        if (UseDef.fromPtr(use) == def) return error.InvalidCycle;

        const edgeList = try self.getOrCreateEdgeList(use);

        if (index <= edgeList.items.len) {
            try edgeList.insert(self.root.allocator, index, def);
        } else {
            return error.InvalidIndex;
        }
    }

    /// Replace an edge from `use` at the given index, referencing a new `def`.
    /// * This is a directed edge, meaning that the old def is no longer a predecessor of `use`, if this is the only edge to it.
    /// * Returns the replaced edge, if any.
    pub fn replaceUseDef(
        ptr: *const Function,
        use: *const Instruction,
        index: usize,
        def: UseDef,
    ) ?UseDef {
        const self: *Function = @constCast(ptr);

        if (self.edges.getPtr(use)) |defs| {
            if (index < defs.items.len) {
                const old = defs.items[index];
                defs.items[index] = def;
                return old;
            }
        }

        return null;
    }

    /// Remove an edge from `use` to a def, by index.
    /// * This is a directed edge, meaning that the old def is no longer a predecessor of `use`, if this is the only edge to it.
    /// * This is a no-op if the edge does not exist.
    /// * This is an ordered removal, other edges may be moved to fill a gap.
    /// * Returns the removed edge, if any.
    pub fn removeUseDef(
        ptr: *const Function,
        use: *const Instruction,
        index: usize,
    ) ?UseDef {
        const self: *Function = @constCast(ptr);

        if (self.edges.getPtr(use)) |defs| {
            if (index < defs.items.len) return defs.orderedRemove(index);
        }

        return null;
    }

    fn deinit(ptr: *const Function) void {
        const self: *Function = @constCast(ptr);

        const allocator = self.root.allocator;
        defer allocator.destroy(self);

        var edges_it = self.edges.valueIterator();
        while (edges_it.next()) |list| list.deinit(allocator);

        var blocks_it = self.blocks.keyIterator();
        while (blocks_it.next()) |blockPtr| Block.deinit(blockPtr.*);

        self.arena.deinit();
        self.edges.deinit(allocator);
    }

    pub fn onFormat(self: *const Function, formatter: anytype) !void {
        pl.todo(noreturn, .{self, formatter});
    }
};

/// Intermediate representation of effect handler sets.
/// Handler sets are collections of simple bindings from effect ids to functions that can be used to process those effects.
pub const HandlerSet = struct {
    /// The IR unit that owns this handler set.
    root: *const Builder,
    /// The block that this handler set belongs to.
    block: *const Block,
    /// The unique identifier of this handler set.
    id: Id.of(HandlerSet),
    /// The handlers that this handler set contains.
    handlers: Id.Set(*const Handler, 80),
};

/// A binding from an effect to a function handling that effect, within a `HandlerSet`.
pub const Handler = struct {
    /// The IR unit that owns this handler.
    root: *const Builder,
    /// The set that this handler belongs to.
    handler_set: *const HandlerSet,
    /// The unique identifier of this handler.
    id: Id.of(Handler),
    /// The effect that this handler can process.
    effect: *const Effect,
    /// The function implementing the effect handling.
    function: *const Function,
};

/// Intermediate representation of basic blocks.
/// Blocks are used to group `Instruction`s together, inside `Function`s.
pub const Block = struct {
    /// The root IR unit that owns this block.
    root: *const Builder,
    /// The function that this block belongs to.
    function: *const Function,
    /// The name of this block, if any, for debugging purposes.
    name: ?*const Name,
    /// The unique identifier of this block.
    id: Id.of(Block),
    /// The instructions in this block.
    instructions: pl.ArrayList(*const Instruction) = .empty,
    /// The effect handler sets used in this block.
    handler_sets: Id.Set(*const HandlerSet, 80) = .empty,

    fn init(
        function: *Function,
        name: ?*const Name,
        id: Id.of(Block),
    ) error{OutOfMemory}!*const Block {
        const self = try function.arena.allocator().create(Block);

        self.* = Block {
            .root = function.root,
            .function = function,
            .name = name,
            .id = id,
        };

        return self;
    }

    fn deinit(ptr: *const Block) void {
        const self: *Block = @constCast(ptr);

        const allocator = self.root.allocator;
        defer allocator.destroy(self);

        self.instructions.deinit(allocator);
    }

    /// Get the index of a given instruction in this block.
    /// Returns `null` if the instruction is not in this block.
    pub fn getInstructionIndex(
        ptr: *const Block,
        i: *const Instruction,
    ) ?usize {
        return std.mem.indexOfScalar(*const Instruction, ptr.instructions.items, i);
    }

    /// Creates a new default-initialized `Instruction` at the end of this block.
    /// The instruction is allocated in an arena owned by the function,
    /// no memory management is necessary on behalf of the caller.
    pub fn instr(ptr: *const Block, operation: Operation) error{OutOfMemory}!*const Instruction {
        const self: *Block = @constCast(ptr);

        return Instruction.init(self, operation);
    }
};

/// Intermediate representation of instructions;
/// created and organized by `Block`s, memory-managed by `Function`s.
pub const Instruction = struct {
    /// The block that this instruction belongs to.
    block: *const Block,
    /// The kind of operation being performed by this instruction.
    operation: Operation,
    /// The cache for the type of this instruction; use `getType` to access.
    type_cache: ?*const Type,

    fn init(block: *Block, operation: Operation) error{OutOfMemory}!*const Instruction {
        const self = try @constCast(block.function).arena.allocator().create(Instruction);
        errdefer @constCast(block.function).arena.allocator().destroy(self);

        self.* = Instruction {
            .block = block,
            .operation = operation,
            .type_cache = null,
        };

        return self;
    }

    /// Shortcut for `Function.insertUseDef`.
    pub fn insertUseDef(ptr: *const Instruction, index: usize, useDef: UseDef) error{OutOfMemory, InvalidCycle, InvalidIndex}!void {
        return ptr.block.function.insertUseDef(ptr, index, useDef);
    }

    /// Shortcut for `Function.appendUseDef`.
    pub fn appendUseDef(ptr: *const Instruction, input: UseDef) error{OutOfMemory, InvalidCycle}!void {
        return ptr.block.function.appendUseDef(ptr, input);
    }

    /// Shortcut for `Function.replaceUseDef`.
    pub fn replaceUseDef(ptr: *const Instruction, index: usize, input: UseDef) ?UseDef {
        return ptr.block.function.replaceUseDef(ptr, index, input);
    }

    /// Shortcut for `Function.removeUseDef`.
    pub fn removeUseDef(ptr: *const Instruction, index: usize) ?UseDef {
        return ptr.block.function.removeUseDef(ptr, index);
    }

    /// Marks this instruction as dirty, so that it will recompute its type the next time `getType` is called.
    pub fn makeDirty(ptr: *const Instruction) void {
        const self: *Instruction = @constCast(ptr);
        self.type_cache = null;
    }

    /// Checks if the type cache is empty, or any input `isDirty`.
    pub fn isDirty(self: *const Instruction) bool {
        return self.type_cache == null or self.hasDirtyUseDefs();
    }

    /// Simply loops over inputs and checks if any of them `isDirty`.
    pub fn hasDirtyUseDefs(self: *const Instruction) bool {
        const useDefs = self.block.function.getUseDefs(self);

        for (useDefs) |input| {
            if (input.isDirty()) return true;
        }

        return false;
    }

    /// Returns the cached type if it is valid; does not recompute. See also `getType`.
    pub fn getCachedType(ptr: *const Instruction) ?*const Type {
        const self: *Instruction = @constCast(ptr);

        if (self.type_cache) |typeCache| {
            if (!self.hasDirtyUseDefs()) {
                return typeCache;
            } else {
                self.type_cache = null;
            }
        }

        return null;
    }

    /// Un-memoized version of `getType`.
    pub fn computeType(self: *const Instruction) error{InvalidInstruction, TypeMismatch, OutOfMemory}!*const ir.Type {
        const useDefs = self.block.function.getUseDefs(self);

        return switch(self.operation) {
            .nop => self.block.root.builtin.types.nil,
            .breakpoint => self.block.root.builtin.types.nil,
            .@"unreachable" => self.block.root.builtin.types.noreturn,
            .trap => self.block.root.builtin.types.noreturn,
            .@"return" => self.block.root.builtin.types.noreturn,
            .cancel => self.block.root.builtin.types.noreturn,
            .unconditional_branch => self.block.root.builtin.types.nil,
            .conditional_branch => self.block.root.builtin.types.nil,
            .phi =>
                if (useDefs.len == 0) error.InvalidInstruction
                else try useDefs[0].getType(),
            .call =>
                if (useDefs.len == 0) error.InvalidInstruction
                else (try (try useDefs[0].getType()).info.coerceFunction()).output,
            .prompt =>
                if (useDefs.len == 0) error.InvalidInstruction
                else (try (try useDefs[0].getType()).info.coerceFunction()).output,
            .set_local => self.block.root.builtin.types.nil,
            .get_local =>
                if (useDefs.len == 0) error.InvalidInstruction
                else checkLocal: {
                    const info = (try useDefs[0].getType()).info;
                    if (info != .local) return error.InvalidInstruction;
                    break :checkLocal info.local.element;
                },
            inline .eq, .ne, .le, .lt, .ge, .gt =>
                self.block.root.builtin.types.bool,
            inline .bit_and, .bit_or, .bit_xor, .bit_not, .bit_lshift, .bit_rshift_a, .bit_rshift_l =>
                if (useDefs.len == 0) error.InvalidInstruction
                else try useDefs[0].getType(),
            inline .add, .sub, .mul, .div, .mod, .pow, .floor, .ceil, .trunc, .abs, .neg, .sqrt =>
                if (useDefs.len == 0) error.InvalidInstruction
                else try useDefs[0].getType(),
            inline .convert, .bitcast =>
                if (useDefs.len == 0 or useDefs[0].tag != .type) error.InvalidInstruction
                else useDefs[0].forcePtr(Type),
        };
    }

    /// Provides memoized computation of the type of an instruction. See also `cachedType`, `computeType`.
    pub fn getType(ptr: *const Instruction) error{InvalidInstruction, TypeMismatch, OutOfMemory}!*const ir.Type {
        const self: *Instruction = @constCast(ptr);

        if (self.getCachedType()) |cachedType| {
            return cachedType;
        }

        const out = try self.computeType();

        self.type_cache = out;

        return out;
    }
};

/// The inputs to an ir `Instruction`.
/// Can be either a constant, a type, or another instruction.
pub const UseDef = packed struct {
    /// The kind of value carried by this input.
    tag: Tag,
    /// The address of the value carried by this input.
    ptr: u48,

    /// Determine if the owner of this UseDef needs to recalculate its type.
    pub fn isDirty(self: UseDef) bool {
        return switch (self.tag) {
            inline .type, .constant => false,
            .instruction => @as(*const Instruction, @ptrFromInt(self.ptr)).isDirty(),
        };
    }

    /// Get the type of an input.
    pub fn getType(self: UseDef) error{InvalidInstruction, TypeMismatch, OutOfMemory}!*const Type {
        return switch (self.tag) {
            .type => @as(*const Type, @ptrFromInt(self.ptr)).root.builtin.types.type,
            .constant => @as(*const Constant, @ptrFromInt(self.ptr)).data.type,
            .instruction => try @as(*const Instruction, @ptrFromInt(self.ptr)).getType(),
        };
    }

    fn addOutput(self: UseDef, owner: *const Instruction) error{TooManyEdges}!void {
        if (self.toPtr(Instruction)) |instr| {
            try instr.addOutput(owner);
        }
    }

    fn removeOutput(self: UseDef, owner: *const Instruction) void {
        if (self.toPtr(Instruction)) |instr| {
            instr.removeOutput(owner);
        }
    }

    /// Marker for which kind of value is carried by an `UseDef`.
    pub const Tag = enum(u16) {
        /// Receives a type.
        type,
        /// Receives a constant value.
        constant,
        /// Receives the output of another instruction.
        instruction,

        /// Creates a new `Tag` from any type that is a valid input.
        pub fn fromType(comptime T: type) Tag {
            comptime return switch (T) {
                *const Type, *Type => .type,
                *const Constant, *Constant => .constant,
                *const Instruction, *Instruction => .instruction,
                else => @compileError(@typeName(T) ++ " is not a valid UseDef type"),
            };
        }
    };

    /// Creates a new `UseDef` from a pointer to any type that is a valid input.
    /// The type of the pointer is used to determine the `Tag` of the input.
    /// The pointer must be a valid pointer to the type.
    pub fn fromPtr(ptr: anytype) UseDef {
        const tag = comptime Tag.fromType(@TypeOf(ptr));

        return UseDef {
            .tag = tag,
            .ptr = @intCast(@intFromPtr(ptr)),
        };
    }

    /// Create a typed pointer from an UseDef.
    /// The type of the parameter must match the tag of the UseDef, or else null is returned; see also `forcePtr`.
    pub fn toPtr(self: UseDef, comptime T: type) ?*const T {
        const tag = comptime Tag.fromType(*const T);

        if (self.tag != tag) return null;

        return @ptrFromInt(self.ptr);
    }

    /// Create a typed pointer from an UseDef.
    /// Only checks that the tag matches the type in debug mode; see also `toPtr`.
    pub fn forcePtr(self: UseDef, comptime T: type) *const T {
        const tag = comptime Tag.fromType(*const T);

        std.debug.assert(self.tag == tag);

        return @ptrFromInt(self.ptr);
    }
};


/// Designates which kind of operation, be it data manipulation or control flow, is performed by an ir `Instruction`.
pub const Operation = enum {
    /// No operation.
    nop,
    /// Indicates a breakpoint should be emitted in the output; skipped by optimizers.
    breakpoint,
    /// Indicates an undefined state; all uses may be discarded by optimizers.
    @"unreachable",
    /// Indicates a defined but undesirable state that should halt execution.
    trap,
    /// Return flow control from a function or handler.
    @"return",
    /// Cancel the effect block of the current handler.
    cancel,
    /// Jump to the output instruction.
    unconditional_branch,
    /// Jump to the output instruction, if the input is non-zero.
    conditional_branch,
    /// A unification point for virtual registers from predecessor blocks.
    phi,
    /// A standard function call.
    call,
    /// An effect handler prompt.
    prompt,
    /// Set the value of a local variable.
    set_local,
    /// Get the value of a local variable.
    get_local,
    /// Equality comparison.
    eq,
    /// Inequality comparison.
    ne,
    /// Less than comparison.
    lt,
    /// Less than or equal to comparison.
    le,
    /// Greater than comparison.
    gt,
    /// Greater than or equal to comparison.
    ge,
    /// Bitwise AND operation.
    bit_and,
    /// Bitwise OR operation.
    bit_or,
    /// Bitwise XOR operation.
    bit_xor,
    /// Bitwise left shift operation.
    bit_lshift,
    /// Logical right shift operation.
    bit_rshift_l,
    /// Arithmetic right shift operation.
    bit_rshift_a,
    /// Bitwise NOT operation.
    bit_not,
    /// Addition operation.
    add,
    /// Subtraction operation.
    sub,
    /// Multiplication operation.
    mul,
    /// Division operation.
    div,
    /// Modulus operation.
    mod,
    /// Exponentiation operation.
    pow,
    /// Floor operation.
    floor,
    /// Ceiling operation.
    ceil,
    /// Truncation operation.
    trunc,
    /// Negation operation.
    neg,
    /// Absolute value operation.
    abs,
    /// Square root operation.
    sqrt,
    /// Convert a value to (approximately) the same value in another representation.
    convert,
    /// Convert bits to a different type, changing the meaning without changing the bits.
    bitcast,
};
