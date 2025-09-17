const std = @import("std");
const common = @import("common");
const core = @import("core");

const ml = @import("../meta_language.zig");
const Expr = ml.Expr;

const analysis = @import("analysis");
const SyntaxTree = analysis.SyntaxTree;

/// Immutable string type used in the meta-language.
pub const IString = struct {};

/// An efficient, bit-packed union of all value types in the meta-language semantics.
///
/// ```txt
///               ┍╾on target architectures, this bit is 1 for quiet nans, 0 for signalling.
/// ┍╾f64 sign    │   ┍╾discriminant for non-f64                        ┍╾discriminant for objects
/// ╽             ╽ ┌─┤                                               ┌─┤
/// 0_00000000000_0_000_000000000000000000000000000000000000000000000_000 (64 bits)
///   ├─────────┘       ├───────────────────────────────────────────┘
///   │                 ┕╾45 bit object pointer (8 byte aligned means 3 lsb are always 0)
///   ┕╾f64 exponent; if not f64, these are all 1s (encoding f64 nan), forming the first discriminant of the value
/// ```
pub const Value = packed struct(u64) {
    /// Value bits store the actual value when it is not an f64.
    val_bits: Data,
    /// Tag bits are used when the value is not an f64, and serve as a second discriminant, between immediates.
    tag_bits: Tag,
    /// Nan bits are used by f64 as the sign and exponent, but when we encode other values,
    /// these are all 1s, forming the first discriminant of the value.
    nan_bits: NanBits,

    /// Payload of a `Value` that is not an f64.
    pub const Data = packed struct(u48) {
        /// The lower 3 bits are used to store the third discriminant, between the pointer types.
        obj_bits: Obj,
        /// All pointers must be aligned to 8 bytes, freeing up the lower 3 bits for the discriminant.
        ptr_bits: PtrBits,

        /// Same as @bitcast but the type is known.
        pub fn asBits(self: @This()) u48 {
            return @bitCast(self);
        }

        /// Same as @bitcast but the type is known.
        pub fn fromBits(bits: u48) @This() {
            return @bitCast(bits);
        }

        /// Decodes the ptr_bits from object Data to an opaque pointer type.
        pub fn forceObject(self: @This()) *anyopaque {
            return @ptrFromInt(@as(u48, self.ptr_bits) << 3);
        }
    };

    const NAN_FILL: NanBits = 0b1_11111111111_1; // signalling NaN bits; sign is irrelevant but prefer keeping it on as this makes nil all ones
    const NAN_MASK: NanBits = 0b0_11111111111_0; // we dont care about sign or signal when checking for nans
    const PTR_FILL: PtrBits = 0b111111111111111111111111111111111111111111111;

    /// Nan bits are used by f64 as the sign and exponent, but when we encode other values,
    /// these are all 1s, forming the first discriminant of the value.
    pub const NanBits = u13;
    /// All pointers must be aligned to 8 bytes, freeing up the lower 3 bits for the discriminant.
    pub const PtrBits = u45;

    /// The tag bits distinguish between different types of immediate values, separating them from f64 and object.
    pub const Tag = enum(u3) {
        /// Value payload is an f64. `0b000`
        f64 = 0b000,
        /// Value payload is a 48-bit signed integer. `0b001`
        i48 = 0b001,
        /// Value payload is a 48-bit unsigned integer. `0b010`
        u48 = 0b010,
        /// Value payload is a character. `0b011`
        char = 0b011,
        /// Value payload is a boolean. `0b100`
        bool = 0b100,
        /// Value payload is a symbol, which is an interned, null-terminated immutable byte string pointer. `0b101`
        symbol = 0b101,
        /// Usage TBD `0b110`
        _reserved0 = 0b110,
        /// Value payload is a pointer to an object, which is a user-defined data structure. `0b111`
        object = 0b111,

        pub fn fromType(comptime T: type) Tag {
            return switch (T) {
                f32, f64 => .f64,
                i8, i16, i32, i48 => .i48,
                u8, u16, u32, u48 => .u48,
                u21 => .char,
                bool => .bool,
                [*:0]align(8) const u8, [*:0]align(8) u8 => .symbol,
                else => {
                    _ = Obj.fromType(T); // invoke compilation error if T is not a valid object pointer type

                    return .object;
                },
            };
        }
    };

    /// The obj bits distinguish between different types of heap-allocated payloads.
    pub const Obj = enum(u3) {
        /// Value payload is a bytecode function. `0b000`
        bytecode = 0b000,
        /// Value payload is a builtin address provided by the runtime. `0b001`
        builtin = 0b001,
        /// Value payload is an address with a foreign abi, provided by the runtime. `0b010`
        foreign = 0b010,
        /// Value payload is a string, which is a custom data structure allowing immutable concatenation etc. `0b011`
        string = 0b011,
        /// Value payload is a concrete syntax tree; non-ml source code. `0b100`
        cst = 0b100,
        /// Value payload is an ml syntax tree; ml source code. `0b101`
        expr = 0b101,
        /// Usage TBD `0b110`
        _reserved1 = 0b110,
        /// No payload, this is a nil value. `0b111`
        nil = 0b111,

        /// Convert a zig pointer type to an `Obj` discriminant.
        pub fn fromType(comptime T: type) Obj {
            return switch (T) {
                void => .nil,
                *align(8) anyopaque, *align(8) const anyopaque => .foreign,
                *align(8) core.Bytecode, *align(8) const core.Bytecode => .bytecode,
                *align(8) core.Builtin, *align(8) const core.Builtin => .builtin,
                *align(8) IString, *align(8) const IString => .string,
                *align(8) SyntaxTree, *align(8) const SyntaxTree => .cst,
                *align(8) Expr, *align(8) const Expr => .expr,
                else => @compileError("Value.Obj.fromPtrType: " ++ @typeName(T) ++ " is not a valid object pointer type"),
            };
        }
    };

    /// Same as @bitcast but the type is known.
    pub fn asBits(self: Value) u64 {
        return @bitCast(self);
    }

    /// Same as @bitcast but the type is known.
    pub fn fromBits(bits: u64) Value {
        return @bitCast(bits);
    }

    /// A value representing the absence of data.
    pub const nil = Value{
        .nan_bits = NAN_FILL,
        .tag_bits = .object,
        .val_bits = .{
            .ptr_bits = PTR_FILL,
            .obj_bits = .nil,
        },
    };

    /// F64 signalling nan value.
    pub const snan = Value.fromF64(std.math.snan(f64));

    /// F64 quiet nan value.
    pub const qnan = Value.fromF64(std.math.nan(f64));

    /// F64-inf value.
    pub const inf = Value.fromF64(std.math.inf(f64));

    /// F64-neg-inf value.
    pub const neg_inf = Value.fromF64(-std.math.inf(f64));

    /// Construct a value from any valid payload.
    pub fn from(value: anytype) Value {
        return switch (comptime Tag.fromType(@TypeOf(value))) {
            .f64 => Value.fromF64(value),
            .i48 => Value.fromI48(value),
            .u48 => Value.fromU48(value),
            .char => Value.fromChar(value),
            .bool => Value.fromBool(value),
            .symbol => Value.fromSymbol(value),
            .object => Value.fromObjectPointer(Obj.fromType(@TypeOf(value)), @ptrCast(value)),
            ._reserved0 => unreachable,
        };
    }

    /// Determine if the given type is the type of the payload of a value.
    /// * Foreign values can only be checked with `*anyopaque`, not whatever native type they had.
    pub fn is(self: Value, comptime T: type) bool {
        return switch (comptime Tag.fromType(T)) {
            .f64 => self.isF64(),
            .i48 => self.isI48(),
            .u48 => self.isU48(),
            .char => self.isChar(),
            .bool => self.isBool(),
            .symbol => self.isSymbol(),
            .object => self.isObj(comptime Obj.fromType(T)),
            ._reserved0 => unreachable,
        };
    }

    /// Extract a payload of a given type from a value.
    pub fn as(self: Value, comptime T: type) ?T {
        return switch (comptime Tag.fromType(T)) {
            .f64 => self.asF64(),
            .i48 => self.asI48(),
            .u48 => self.asU48(),
            .char => self.asChar(),
            .bool => self.asBool(),
            .symbol => self.asSymbol(),
            .object => @ptrCast(self.asObj(comptime Obj.fromType(T))),
            ._reserved0 => unreachable,
        };
    }

    /// Extract a payload of a given type from a value.
    /// * only checked in safe modes
    pub fn force(self: Value, comptime T: type) T {
        return switch (comptime Tag.fromType(T)) {
            .f64 => self.forceF64(),
            .i48 => self.forceI48(),
            .u48 => self.forceU48(),
            .char => self.forceChar(),
            .bool => self.forceBool(),
            .symbol => self.forceSymbol(),
            .object => @ptrCast(self.forceObj(comptime Obj.fromType(T))),
            ._reserved0 => unreachable,
        };
    }

    /// Construct a value from an f64 payload.
    pub fn fromF64(x: f64) Value {
        return @bitCast(x);
    }

    /// Construct a value from an i48 payload.
    pub fn fromI48(x: i48) Value {
        return Value{
            .nan_bits = NAN_FILL,
            .tag_bits = .i48,
            .val_bits = .fromBits(@bitCast(x)),
        };
    }

    /// Construct a value from a u48 payload.
    pub fn fromU48(x: u48) Value {
        return Value{
            .nan_bits = NAN_FILL,
            .tag_bits = .u48,
            .val_bits = .fromBits(x),
        };
    }

    /// Construct a value from a character payload.
    pub fn fromChar(x: common.Char) Value {
        return Value{
            .nan_bits = NAN_FILL,
            .tag_bits = .char,
            .val_bits = .fromBits(x),
        };
    }

    /// Construct a value from a boolean payload.
    pub fn fromBool(x: bool) Value {
        return Value{
            .nan_bits = NAN_FILL,
            .tag_bits = .bool,
            .val_bits = .fromBits(@intFromBool(x)),
        };
    }

    /// Construct a value from a string payload.
    pub fn fromSymbol(symbol: [*:0]const u8) Value {
        std.debug.assert(common.alignDelta(symbol, 8) == 0);

        return Value{
            .nan_bits = NAN_FILL,
            .tag_bits = .symbol,
            .val_bits = .fromBits(@intCast(@intFromPtr(symbol))),
        };
    }

    /// Construct a value from an object payload.
    pub fn fromObjectPointer(obj: Obj, ptr: *anyopaque) Value {
        std.debug.assert(obj != ._reserved1);

        const ptr_bits: u48 = @intCast(@intFromPtr(ptr));
        // ensure the pointer is aligned to 8 bytes and we can store our object discriminant
        std.debug.assert(ptr_bits & 0b000000000000000000000000000000000000000000000_111 == 0);

        return Value{
            .nan_bits = NAN_FILL,
            .tag_bits = .object,
            .val_bits = .fromBits(ptr_bits | @intFromEnum(obj)),
        };
    }

    /// Construct a value from a bytecode function payload.
    pub fn fromBytecode(ptr: *core.Bytecode) Value {
        return Value.fromObjectPointer(.bytecode, @ptrCast(ptr));
    }

    /// Construct a value from a builtin address payload.
    pub fn fromBuiltin(ptr: *core.Builtin) Value {
        return Value.fromObjectPointer(.builtin, @ptrCast(ptr));
    }

    /// Construct a value from a foreign address payload.
    pub fn fromForeign(ptr: core.ForeignAddress) Value {
        return Value.fromObjectPointer(.foreign, @ptrCast(ptr));
    }

    /// Construct a value from a string payload.
    pub fn fromString(ptr: *IString) Value {
        return Value.fromObjectPointer(.string, @ptrCast(ptr));
    }

    /// Construct a value from a concrete syntax tree payload.
    pub fn fromCst(ptr: *SyntaxTree) Value {
        return Value.fromObjectPointer(.cst, @ptrCast(ptr));
    }

    /// Construct a value from a meta-language expression payload.
    pub fn fromExpr(ptr: *Expr) Value {
        return Value.fromObjectPointer(.expr, @ptrCast(ptr));
    }

    /// Determine if the value is nil.
    pub fn isNil(self: Value) bool {
        const mask = comptime (Value{
            .nan_bits = NAN_MASK,
            .tag_bits = .object,
            .val_bits = .{
                .ptr_bits = 0,
                .obj_bits = .nil,
            },
        }).asBits();

        return self.asBits() & mask == mask;
    }

    /// Determine if the value is numeric.
    /// * returns `true` for: f64 (except NaN), i48, u48.
    pub fn isNumber(self: Value) bool {
        const notNan = @intFromBool(self.nan_bits & NAN_MASK != NAN_MASK);
        const bits = @intFromEnum(self.tag_bits);

        const bit1: u1 = @truncate(bits >> 2);
        const bit2: u1 = @truncate(bits >> 1);
        const bit3: u1 = @truncate(bits >> 0);

        return notNan | (~bit1 & (bit2 ^ bit3)) == 1;
    }

    /// Determine if the value is non-numeric.
    /// * returns `true` for: nil, char, bool, symbol, objects.
    pub fn isData(self: Value) bool {
        const isNan = @intFromBool(self.nan_bits & NAN_MASK == NAN_MASK);
        const bits = @intFromEnum(self.tag_bits);

        const bit1: u1 = @truncate(bits >> 2);
        const bit2: u1 = @truncate(bits >> 1);
        const bit3: u1 = @truncate(bits >> 0);

        return isNan & (bit1 | (bit2 & bit3)) == 1;
    }

    /// Determine if the payload of the value is an f64.
    pub fn isF64(self: Value) bool {
        const notNan = @intFromBool(self.nan_bits & NAN_MASK != NAN_MASK);
        const noTag = @intFromBool(self.tag_bits == .f64);

        return notNan | noTag == 1;
    }

    /// Determine if the payload of the value is a NaN by IEEE 754 standards.
    /// * note this will return `true` for i48/u48 etc.
    pub fn isNaN(self: Value) bool {
        return std.math.isNan(@as(f64, @bitCast(self)));
    }

    /// Determine if the payload of the value is an infinity by IEEE 754 standards.
    pub fn isInfF64(self: Value) bool {
        return std.math.isInf(@as(f64, @bitCast(self)));
    }

    /// Determine if the payload of the value is a positive infinity by IEEE 754 standards.
    pub fn isPosInfF64(self: Value) bool {
        return std.math.isPositiveInf(@as(f64, @bitCast(self)));
    }

    /// Determine if the payload of the value is a negative infinity by IEEE 754 standards.
    pub fn isNegInfF64(self: Value) bool {
        return std.math.isNegativeInf(@as(f64, @bitCast(self)));
    }

    /// Determine if the payload of the value is a finite F64.
    pub fn isFiniteF64(self: Value) bool {
        return std.math.isFinite(@as(f64, @bitCast(self)));
    }

    /// Determine if the payload of the value is a normal F64.
    /// * ie. not either of zeroes, subnormal, infinity, or NaN.
    pub fn isNormalF64(self: Value) bool {
        return std.math.isNormal(@as(f64, @bitCast(self)));
    }

    /// Determine if the payload of the value is an i48.
    pub fn isI48(self: Value) bool {
        const mask = comptime (Value{
            .nan_bits = NAN_MASK,
            .tag_bits = .i48,
            .val_bits = .fromBits(0),
        }).asBits();

        return self.asBits() & mask == mask;
    }

    /// Determine if the payload of the value is a u48.
    pub fn isU48(self: Value) bool {
        const mask = comptime (Value{
            .nan_bits = NAN_MASK,
            .tag_bits = .u48,
            .val_bits = .fromBits(0),
        }).asBits();

        return self.asBits() & mask == mask;
    }

    /// Determine if the payload of the value is a character.
    pub fn isChar(self: Value) bool {
        const mask = comptime (Value{
            .nan_bits = NAN_MASK,
            .tag_bits = .char,
            .val_bits = .fromBits(0),
        }).asBits();

        return self.asBits() & mask == mask;
    }

    /// Determine if the payload of the value is a boolean.
    pub fn isBool(self: Value) bool {
        const mask = comptime (Value{
            .nan_bits = NAN_MASK,
            .tag_bits = .bool,
            .val_bits = .fromBits(0),
        }).asBits();

        return self.asBits() & mask == mask;
    }

    /// Determine if the payload of the value is a symbol.
    pub fn isSymbol(self: Value) bool {
        const mask = comptime (Value{
            .nan_bits = NAN_MASK,
            .tag_bits = .symbol,
            .val_bits = .fromBits(0),
        }).asBits();

        return self.asBits() & mask == mask;
    }

    /// Determine if the payload of the value is an object.
    pub fn isObject(self: Value) bool {
        const mask = comptime (Value{
            .nan_bits = NAN_MASK,
            .tag_bits = .object,
            .val_bits = .fromBits(0),
        }).asBits();

        return self.asBits() & mask == mask and self.val_bits.obj_bits != .nil;
    }

    /// Determine if the payload of the value is an object.
    pub fn isObj(self: Value, obj: Obj) bool {
        const mask = (Value{
            .nan_bits = NAN_MASK,
            .tag_bits = .object,
            .val_bits = .{
                .ptr_bits = 0,
                .obj_bits = obj,
            },
        }).asBits();

        return self.asBits() & mask == mask;
    }

    /// Determine if the payload of the value is a bytecode function.
    pub fn isBytecode(self: Value) bool {
        return self.isObj(.bytecode);
    }

    /// Determine if the payload of the value is a builtin address.
    pub fn isBuiltin(self: Value) bool {
        return self.isObj(.builtin);
    }

    /// Determine if the payload of the value is a foreign address.
    pub fn isForeign(self: Value) bool {
        return self.isObj(.foreign);
    }

    /// Determine if the payload of the value is a string.
    pub fn isString(self: Value) bool {
        return self.isObj(.string);
    }

    /// Determine if the payload of the value is a concrete syntax tree.
    pub fn isCst(self: Value) bool {
        return self.isObj(.cst);
    }

    /// Determine if the payload of the value is a meta-language expression.
    pub fn isExpr(self: Value) bool {
        return self.isObj(.expr);
    }

    /// Extract the f64 payload of a value. See also `forceF64`.
    pub fn asF64(self: Value) ?f64 {
        if (!self.isF64()) return null;

        return @bitCast(self);
    }

    /// Extract the i48 payload of a value. See also `forceI48`.
    pub fn asI48(self: Value) ?i48 {
        if (!self.isI48()) return null;

        return @bitCast(self.val_bits);
    }

    /// Extract the u48 payload of a value. See also `forceU48`.
    pub fn asU48(self: Value) ?u48 {
        if (!self.isU48()) return null;

        return @bitCast(self.val_bits);
    }

    /// Extract the character payload of a value. See also `forceChar`.
    pub fn asChar(self: Value) ?common.Char {
        if (!self.isChar()) return null;

        return @truncate(self.val_bits.asBits());
    }

    /// Extract the boolean payload of a value. See also `forceBool`.
    pub fn asBool(self: Value) ?bool {
        if (!self.isBool()) return null;

        return self.val_bits.asBits() != 0;
    }

    /// Extract the symbol payload of a value. See also `forceSymbol`.
    pub fn asSymbol(self: Value) ?[*:0]const u8 {
        if (!self.isSymbol()) return null;

        return @ptrFromInt(self.val_bits.asBits());
    }

    /// Extract the object payload of a value.
    pub fn asObject(self: Value) ?*anyopaque {
        if (!self.isObject()) return null;

        return self.val_bits.forceObject();
    }

    /// Extract the object payload of a value if it is the right object type.
    pub fn asObj(self: Value, obj: Obj) ?*anyopaque {
        if (!self.isObj(obj)) return null;

        return self.val_bits.forceObject();
    }

    /// Extract the function payload of a value.
    pub fn asBytecode(self: Value) ?*core.Function {
        if (!self.isBytecode()) return null;

        return @ptrCast(@alignCast(self.val_bits.forceObject()));
    }

    /// Extract the builtin address payload of a value.
    pub fn asBuiltin(self: Value) ?*core.Builtin {
        if (!self.isBuiltin()) return null;

        return @ptrCast(@alignCast(self.val_bits.forceObject()));
    }

    /// Extract the foreign address payload of a value.
    pub fn asForeign(self: Value) ?core.ForeignAddress {
        if (!self.isForeign()) return null;

        return @ptrCast(@alignCast(self.val_bits.forceObject()));
    }

    /// Extract the string payload of a value.
    pub fn asString(self: Value) ?*IString {
        if (!self.isString()) return null;

        return @ptrCast(@alignCast(self.val_bits.forceObject()));
    }

    /// Extract the cst payload of a value.
    pub fn asCst(self: Value) ?*SyntaxTree {
        if (!self.isCst()) return null;

        return @ptrCast(@alignCast(self.val_bits.forceObject()));
    }

    /// Extract the expr payload of a value.
    pub fn asExpr(self: Value) ?*Expr {
        if (!self.isExpr()) return null;

        return @ptrCast(@alignCast(self.val_bits.forceObject()));
    }

    /// Extract the f64 payload of a value. See also `asF64`.
    /// * only checked in safe modes
    pub fn forceF64(self: Value) f64 {
        std.debug.assert(self.isF64());

        return @bitCast(self);
    }

    /// Extract the i48 payload of a value. See also `asI48`.
    /// * only checked in safe modes
    pub fn forceI48(self: Value) i48 {
        std.debug.assert(self.isI48());

        return @bitCast(self.val_bits);
    }

    /// Extract the u48 payload of a value. See also `asU48`.
    /// * only checked in safe modes
    pub fn forceU48(self: Value) u48 {
        std.debug.assert(self.isU48());

        return @bitCast(self.val_bits);
    }

    /// Extract the character payload of a value. See also `asChar`.
    /// * only checked in safe modes
    pub fn forceChar(self: Value) common.Char {
        std.debug.assert(self.isChar());

        return @truncate(self.val_bits.asBits());
    }

    /// Extract the boolean payload of a value. See also `asBool`.
    pub fn forceBool(self: Value) bool {
        std.debug.assert(self.isBool());

        return self.val_bits.asBits() != 0;
    }

    /// Extract the symbol payload of a value. See also `asSymbol`.
    /// * only checked in safe modes
    pub fn forceSymbol(self: Value) [*:0]const u8 {
        std.debug.assert(self.isSymbol());

        return @ptrFromInt(self.val_bits.asBits());
    }

    /// Extract the object payload of a value. See also `asObject`.
    /// * only checked in safe modes
    pub fn forceObject(self: Value) *anyopaque {
        std.debug.assert(self.isObject());

        return self.val_bits.forceObject();
    }

    /// Extract the object payload of a value if it is the right object type.
    /// * only checked in safe modes
    pub fn forceObj(self: Value, obj: Obj) *anyopaque {
        std.debug.assert(self.isObj(obj));

        return self.val_bits.forceObject();
    }

    /// Extract the bytecode function payload of a value. See also `asBytecode`.
    /// * only checked in safe modes
    pub fn forceBytecode(self: Value) *core.Bytecode {
        std.debug.assert(self.isBytecode());

        return @ptrCast(@alignCast(self.val_bits.forceObject()));
    }

    /// Extract the builtin address payload of a value. See also `asBuiltin`.
    /// * only checked in safe modes
    pub fn forceBuiltin(self: Value) *core.Builtin {
        std.debug.assert(self.isBuiltin());

        return @ptrCast(@alignCast(self.val_bits.forceObject()));
    }

    /// Extract the foreign address payload of a value. See also `asForeign`.
    /// * only checked in safe modes
    pub fn forceForeign(self: Value) core.ForeignAddress {
        std.debug.assert(self.isForeign());

        return @ptrCast(@alignCast(self.val_bits.forceObject()));
    }

    /// Extract the string payload of a value. See also `asString`.
    /// * only checked in safe modes
    pub fn forceString(self: Value) *IString {
        std.debug.assert(self.isString());

        return @ptrCast(@alignCast(self.val_bits.forceObject()));
    }

    /// Extract the cst payload of a value. See also `asCst`.
    /// * only checked in safe modes
    pub fn forceCst(self: Value) *SyntaxTree {
        std.debug.assert(self.isCst());

        return @ptrCast(@alignCast(self.val_bits.forceObject()));
    }

    /// Extract the expression payload of a value. See also `asExpr`.
    /// * only checked in safe modes
    pub fn forceExpr(self: Value) *Expr {
        std.debug.assert(self.isExpr());

        return @ptrCast(@alignCast(self.val_bits.forceObject()));
    }
};
