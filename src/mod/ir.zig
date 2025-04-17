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

    /// Initialize a new IR unit.
    ///
    /// * `allocator`-agnostic, but see `deinit`
    /// * result `Builder` root ir node will own all ir memory allocated with the provided allocator;
    /// it can all be freed at once with `deinit`
    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!*const Builder {
        const self = try allocator.create(Builder);

        self.* = .{
            .allocator = allocator,
        };

        return self;
    }

    /// De-initialize the IR unit, freeing all allocated memory.
    ///
    /// This is not necessary to call if the allocator provided to the `Builder` is a `std.heap.Arena` or similar.
    pub fn deinit(ptr: *const Builder) void {
        const self: *Builder = @constCast(ptr);

        const allocator = self.allocator;
        defer allocator.destroy(self);

        var nameIt = self.names.keyIterator();
        while (nameIt.next()) |namePtr| {
            Name.deinit(namePtr.*);
        }

        var constantIt = self.constants.keyIterator();
        while (constantIt.next()) |constantPtr| {
            Constant.deinit(constantPtr.*);
        }

        var foreignAddressIt = self.foreign_addresses.keyIterator();
        while (foreignAddressIt.next()) |foreignPtr| {
            ForeignAddress.deinit(foreignPtr.*);
        }

        var effectIt = self.effects.keyIterator();
        while (effectIt.next()) |effectPtr| {
            Effect.deinit(effectPtr.*);
        }

        var typeIt = self.types.keyIterator();
        while (typeIt.next()) |typePtr| {
            Type.deinit(typePtr.*);
        }

        var moduleIt = self.modules.keyIterator();
        while (moduleIt.next()) |modulePtr| {
            Module.deinit(modulePtr.*);
        }

        self.names.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.foreign_addresses.deinit(self.allocator);
        self.effects.deinit(self.allocator);
        self.types.deinit(self.allocator);
        self.modules.deinit(self.allocator);
    }

    /// Get a `Name` from a string value.
    ///
    /// If the string has already been interned, the existing `Name` will be returned;
    /// Otherwise a new `Name` will be allocated.
    ///
    /// The `Name` that is returned will be owned by this IR unit.
    pub fn internName(ptr: *const Builder, value: []const u8) error{OutOfMemory}!*const Name {
        const self: *Builder = @constCast(ptr);

        return (try self.names.intern(self.allocator, null, &Name{
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
    pub fn internType(ptr: *const Builder, name: ?*const Name, info: TypeInfo) error{OutOfMemory}!*const Type {
        const self: *Builder = @constCast(ptr);

        return (try self.types.intern(self.allocator, null, &Type{
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
    pub fn internConstant(ptr: *const Builder, name: ?*const Name, data: ConstantData) error{OutOfMemory}!*const Constant {
        const self: *Builder = @constCast(ptr);

        return (try self.constants.intern(self.allocator, null, &Constant{
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
    pub fn createForeignAddress(ptr: *const Builder, name: *const Name, typeIr: *const Type) error{DuplicateForeignAddress, OutOfMemory}!*const ForeignAddress {
        const self: *Builder = @constCast(ptr);

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
    pub fn createEffect(ptr: *const Builder, name: *const Name, handlerSignatures: []*const Type) error{DuplicateEffect, OutOfMemory}!*const Effect {
        const self: *Builder = @constCast(ptr);

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

    fn deinit(ptr: *const Name) void {
        const self: *Name = @constCast(ptr);

        const allocator = self.root.allocator;
        defer allocator.destroy(self);

        allocator.free(self.value);
    }

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

    fn deinit(ptr: *const Constant) void {
        const self: *Constant = @constCast(ptr);

        const allocator = self.root.allocator;
        defer allocator.destroy(self);

        self.data.deinit(allocator);
    }

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

    fn deinit(ptr: *const Type) void {
        const self: *Type = @constCast(ptr);

        const allocator = self.root.allocator;
        defer allocator.destroy(self);

        self.info.deinit(allocator);
    }

    /// Get the `Kind` of the type described by this type information.
    pub fn getKind(self: *const Type) TypeInfo.Kind {
        return self.info.getKind();
    }
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
    /// The type of boolean values, true or false.
    bool: void,
    /// The type of a type.
    type: void,
    /// The type of an IR basic block.
    block: void,
    /// The type of an IR module.
    module: void,

    // the following variants have no allocations //

    /// A placeholder for an actual type, of a specific kind.
    @"var": TypeInfo.Var,
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
    pub const Cancel = union(enum) {
        /// The effect handler never returns or cancels.
        divergent: void,
        /// The effect handler never cancels its caller; it always returns a value.
        always_returns: *const ir.Type,
        /// The effect handler always cancels its caller; it never returns a value.
        always_cancels: *const ir.Type,
        /// The effect handler may cancel its caller, or it may return a value.
        conditional: struct {
            on_cancel: *const ir.Type,
            on_return: *const ir.Type,
        },

        fn hash(self: *const TypeInfo.Cancel, hasher: anytype) void {
            hasher.update(@tagName(self.*));

            switch (self.*) {
                .divergent => hasher.update("div"),
                .always_returns, .always_cancels => |ty| hasher.update(std.mem.asBytes(ty)),
                .conditional => |*cond| {
                    hasher.update(std.mem.asBytes(&cond.on_cancel));
                    hasher.update(std.mem.asBytes(&cond.on_return));
                },
            }
        }

        fn eql(self: *const TypeInfo.Cancel, other: *const TypeInfo.Cancel) bool {
            if (@as(std.meta.Tag(Cancel), self.*) != @as(std.meta.Tag(Cancel), other.*)) return false;

            return switch (self.*) {
                .divergent => true,
                .always_returns => |ty| ty == other.always_returns,
                .always_cancels => |ty| ty == other.always_cancels,
                .conditional => |*cond| cond.on_cancel == other.conditional.on_cancel and cond.on_return == other.conditional.on_return,
            };
        }
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
        /// in the event a block is referenced as a value, it will have the type `Block`, which is of this kind.
        /// Size is known, can be used for comparisons.
        block,
        /// in the event a module is referenced as a value, it will have the type `Module`, which is of this kind.
        /// Size is known, can be used for comparisons.
        module,
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
        sentinel: *ir.Constant,
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

    /// Represents the type of an array of values of another type
    pub const Array = struct {
        /// The type of the values that this array type contains
        element: *const ir.Type,
        /// The number of elements in the array
        length: u64,

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
    /// To represent a function:
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
        signature: *const ir.Type,

        fn hash(self: *const TypeInfo.ForeignAddress, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.signature));
        }

        fn eql(self: *const TypeInfo.ForeignAddress, other: *const TypeInfo.ForeignAddress) bool {
            return self.signature == other.signature;
        }

        fn onFormat(self: *const TypeInfo.ForeignAddress, formatter: anytype) !void {
            try formatter.print("foreign({})", .{self.signature});
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
        /// The type of the input parameter.
        input: *const ir.Type,
        /// The manner in which the handler may end its computation,
        /// including return and cancellation types if applicable.
        cancel: Cancel,
        /// The type of an additional side effect, if any, that would be incurred by invoking this handler.
        ///
        /// For example, an effect handler could:
        /// * Translate one effect into another.
        /// * Re-contextualize the same effect, into a new version of itself.
        /// * Split an effect into multiple effects, or
        /// (using a full handler set, ie a product of handlers) combine multiple effects into one.
        effect: ?*const ir.Type,

        fn hash(self: *const TypeInfo.Handler, hasher: anytype) void {
            hasher.update(std.mem.asBytes(&self.target));

            hasher.update(std.mem.asBytes(&self.input));

            self.cancel.hash(hasher);

            if (self.effect) |e| {
                hasher.update(std.mem.asBytes(&e));
            } else {
                hasher.update("null");
            }
        }

        fn eql(self: *const TypeInfo.Handler, other: *const TypeInfo.Handler) bool {
            if (self.target != other.target) return false;

            if (self.input != other.input) return false;

            if (!self.cancel.eql(&other.cancel)) return false;

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
    initial_value: ?*Constant,

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

/// The representation of functions in the IR.
/// Functions are defined in modules and must be given a name for symbol resolution purposes.
pub const Function = struct {
    /// The IR unit that owns this function.
    root: *const Builder,
    /// The module that this function belongs to.
    module: *const Module,
    /// The handler set that this function belongs to, if any.
    handler_set: ?*const HandlerSet,
    /// The unique identifier of this function.
    id: Id.of(Function),
    /// The name of this function, for symbol resolution purposes.
    name: *const Name,
    /// The type of this function.
    type: *const Type,
    /// The basic blocks that make up this function.
    blocks: Id.Set(*const Block, 80) = .{},
    /// The effect handler sets used in this function.
    handler_sets: Id.Set(*const HandlerSet, 80) = .{},

    fn init(root: *const Builder, module: *const Module, handlerSet: ?*const HandlerSet, id: Id.of(Function), name: *const Name, typeIr: *const Type) error{OutOfMemory}!*Function {
        const self = try root.allocator.create(Function);

        self.* = .{
            .root = root,
            .module = module,
            .handler_set = handlerSet,
            .id = id,
            .name = name,
            .type = typeIr,
        };

        return self;
    }

    fn deinit(ptr: *const Function) void {
        const self: *Function = @constCast(ptr);

        const allocator = self.root.allocator;
        defer allocator.destroy(self);
    }

    pub fn onFormat(self: *const Function, formatter: anytype) !void {
        try formatter.print("function({} :: {})", .{self.name, self.type});

        if (self.blocks.count() == 0) {
            return formatter.writeAll("{}");
        }

        var blockIt = self.blocks.keyIterator();

        const firstPtr = blockIt.next().?;

        try formatter.fmt(firstPtr.*);

        try formatter.beginBlock(.Structure);

        while (blockIt.next()) |blockPtr| {
            try formatter.endLine(false);

            try formatter.fmt(blockPtr.*);
        }

        try formatter.endBlock();
    }
};

pub const HandlerSet = struct {
    root: *const Builder,
    function: *const Function,
    id: Id.of(HandlerSet),
    handlers: Id.Set(*const Handler, 80),
};

pub const Handler = struct {
    id: Id.of(Handler),
    function: *const Function,
};

// TODO
pub const Block = struct {
    /// The IR unit that owns this block.
    root: *const Builder,
    /// The function that this block belongs to.
    function: *const Function,
    /// The (function-level-)unique identifier of this block.
    id: Id.of(Block),
    /// The name of this block, if desired for debugging purposes.
    name: ?*const Name,

    /// The blocks that proceed this block in control flow.
    // predecessors: Id.Set(*const Block, 80) = .{},
    // /// The blocks that follow this block in control flow.
    // successors: Id.Set(*const Block, 80) = .{},
    /// The type of this block.
    instructions: pl.ArrayList(*const Instruction),
};


const Value = enum (u64) {_};


pub const Instruction = union(enum) {
    /// No operation.
    nop: void,
    /// Indicates a breakpoint should be emitted in the output;
    /// ignored by optimizers.
    breakpoint: void,
    /// Indicates an undesirable state. Terminates its block.
    /// Cannot be assumed truly unreachable, by optimizations.
    trap: void,
    /// Indicates an impossible state. Terminates its block.
    /// Can be assumed truly unreachable, by optimizations.
    @"unreachable": void,
    /// Pushes an effect handler set.
    push_set: Instruction.PushSet,
    /// Pops an effect handler set.
    pop_set: void,
    /// A standard function call.
    call: Instruction.Invoke,
    /// An effect handler prompt.
    prompt: Instruction.Invoke,
    /// Return flow control from a function or handler. Terminates its block.
    @"return": Instruction.Yield,
    /// Cancel the effect block of the current handler. Terminates its block.
    cancel: Instruction.Yield,
    /// Create a local variable.
    create_local: Instruction.CreateLocal,
    /// Set the value of a local variable.
    set_local: Instruction.SetLocal,
    /// Get the value of a local variable.
    get_local: Instruction.GetLocal,
    /// Perform a comparison operation.
    comparison: Instruction.Comparison,
    /// Perform a bitwise operation.
    bitwise: Instruction.Bitwise,
    /// Perform an arithmetic operation.
    arithmetic: Instruction.Arithmetic,
    /// Convert between values of different types.
    cast: Instruction.Cast,

    pub const PushSet = struct {
        /// The function-local id of the effect handler set to push.
        id: Id.of(HandlerSet),
    };

    pub const Invoke = struct {
        /// The id of the item to invoke.
        id: Id.of(anyopaque),
        /// Arguments to provide to the item invoked.
        args: []const Value,
    };

    pub const Yield = struct {
        /// The item to yield, if any.
        value: ?Value,
    };

    pub const CreateLocal = struct {
        /// The type of the local variable to create.
        type: *const ir.Type,
        /// The id of the local variable. Must be (function-locally) unique.
        id: Id.of(Value),
    };

    pub const SetLocal = struct {
        /// The id of the local variable to set.
        id: Id.of(Value),
        /// The value to set the local variable to.
        value: Value,
    };

    pub const GetLocal = struct {
        /// The id of the local variable to get.
        id: Id.of(Value),
    };

    pub const Comparison = struct {
        /// The type of the comparison operation.
        op: Kind,
        /// The left-hand side of the comparison.
        lhs: Value,
        /// The right-hand side of the comparison.
        rhs: Value,

        pub const Kind = enum {
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
        };
    };

    pub const Bitwise = struct {
        /// The type of the bitwise operation.
        op: Kind,
        /// The left-hand side of the bitwise operation.
        lhs: Value,
        /// The right-hand side of the bitwise operation.
        /// * `undefined` for `.not`
        rhs: Value,

        pub const Kind = enum {
            /// Bitwise AND operation.
            @"and",
            /// Bitwise OR operation.
            @"or",
            /// Bitwise XOR operation.
            xor,
            /// Bitwise NOT operation.
            not,
        };
    };

    pub const Arithmetic = struct {
        /// The type of the arithmetic operation.
        op: Kind,
        /// The left-hand side of the arithmetic operation.
        lhs: Value,
        /// The right-hand side of the arithmetic operation.
        ///
        /// * `undefined` for some `op`s.
        rhs: Value,

        pub const Kind = enum {
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
        };
    };

    pub const Cast = struct {
        /// The type of the cast operation.
        kind: Kind,
        /// The type to cast to.
        to: *const ir.Type,
        /// The value to cast.
        value: Value,

        pub const Kind = enum {
            /// Convert a value to (approximately) the same value in another representation.
            convert,
            /// Convert bits to a different type, changing the meaning without changing the bits.
            bitcast,
        };
    };
};
