//! A collection of builtin term representations for the IR.
const terms = @This();

const std = @import("std");
const common = @import("common");

const ir = @import("../ir.zig");

/// Binds a set of member definitions for a typeclass
pub const Implementation = struct {
    class: ir.Term,
    members: []const Field,

    pub const Field = struct {
        name: ir.Name,
        value: ir.Term,
    };

    pub fn eql(self: *const Implementation, other: *const Implementation) bool {
        if (self.class != other.class and self.members.len == other.members.len) return false;

        for (0..self.members.len) |i| {
            const field1 = self.members[i];
            const field2 = other.members[i];
            if (field1.name.value.ptr != field2.name.value.ptr or field1.value != field2.value) return false;
        }

        return true;
    }

    pub fn hash(self: *const Implementation, hasher: *ir.QuickHasher) void {
        hasher.update(self.class);
        hasher.update(self.members.len);
        for (self.members) |field| {
            hasher.update(field.name.value.ptr);
            hasher.update(field.value);
        }
    }

    pub fn cbr(self: *const Implementation) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("Implementation");

        hasher.update("class:");
        hasher.update(self.class.getCbr());

        hasher.update("members.count:");
        hasher.update(self.members.len);

        hasher.update("members:");
        for (self.members) |field| {
            hasher.update("field.name:");
            hasher.update(field.name.value);

            hasher.update("field.value:");
            hasher.update(field.value.getCbr());
        }

        return hasher.final();
    }

    pub fn dehydrate(self: *const Implementation, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.class) },
        });

        for (self.members) |field| {
            const field_name_id = try dehydrator.dehydrateName(field.name);
            const field_value_id = try dehydrator.dehydrateTerm(field.value);
            try out.appendSlice(dehydrator.sma.allocator, &.{
                ir.Sma.Operand{ .kind = .name, .value = field_name_id },
                ir.Sma.Operand{ .kind = .term, .value = field_value_id },
            });
        }
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *Implementation) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// A symbol is a term that can appear in both values and types, and is simply a nominative identity in the form of a name.
pub const Symbol = struct {
    name: ir.Name,

    pub fn eql(self: *const Symbol, other: *const Symbol) bool {
        return self.name.value.ptr == other.name.value.ptr;
    }

    pub fn hash(self: *const Symbol, hasher: *ir.QuickHasher) void {
        hasher.update(self.name.value.ptr);
    }

    pub fn cbr(self: *const Symbol) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("Symbol");

        hasher.update(self.name.value);

        return hasher.final();
    }

    pub fn dehydrate(self: *const Symbol, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.append(dehydrator.sma.allocator, .{ .kind = .name, .value = try dehydrator.dehydrateName(self.name) });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *Symbol) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Data for a typeclass repr.
pub const Class = struct {
    /// Nominative identity for this typeclass.
    name: ir.Name,
    /// Descriptions of each element required for the implementation of this typeclass.
    elements: []const Field = &.{},

    pub const Field = struct {
        name: ir.Name,
        type: ir.Term,
    };

    pub fn eql(self: *const Class, other: *const Class) bool {
        if (self.name.value.ptr != other.name.value.ptr and self.elements.len == other.elements.len) return false;

        for (0..self.elements.len) |i| {
            const field1 = self.elements[i];
            const field2 = other.elements[i];
            if (field1.name.value.ptr != field2.name.value.ptr or field1.type != field2.type) return false;
        }

        return true;
    }

    pub fn hash(self: *const Class, hasher: *ir.QuickHasher) void {
        hasher.update(self.name);
        hasher.update(self.elements.len);
        for (self.elements) |field| {
            hasher.update(field.name.value.ptr);
            hasher.update(field.type);
        }
    }

    pub fn cbr(self: *const Class) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("Class");

        hasher.update("name:");
        hasher.update(self.name.value);

        hasher.update("elements.count:");
        hasher.update(self.elements.len);

        hasher.update("elements:");
        for (self.elements) |elem| {
            hasher.update("elem.name:");
            hasher.update(elem.name.value);

            hasher.update("elem.type:");
            hasher.update(elem.type.getCbr());
        }

        return hasher.final();
    }

    pub fn dehydrate(self: *const Class, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .name, .value = try dehydrator.dehydrateName(self.name) },
        });

        for (self.elements) |elem| {
            const elem_name_id = try dehydrator.dehydrateName(elem.name);
            const elem_type_id = try dehydrator.dehydrateTerm(elem.type);
            try out.appendSlice(dehydrator.sma.allocator, &.{
                ir.Sma.Operand{ .kind = .name, .value = elem_name_id },
                ir.Sma.Operand{ .kind = .term, .value = elem_type_id },
            });
        }
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *Class) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Data for an effect repr.
pub const Effect = struct {
    /// Nominative identity for this effect.
    name: ir.Name,
    /// Descriptions of each element required for the handling of this effect.
    elements: []const Field = &.{},

    pub const Field = struct {
        name: ir.Name,
        type: ir.Term,
    };

    pub fn eql(self: *const Effect, other: *const Effect) bool {
        if (self.name.value.ptr != other.name.value.ptr or self.elements.len != other.elements.len) return false;

        for (0..self.elements.len) |i| {
            const field1 = self.elements[i];
            const field2 = other.elements[i];
            if (field1.name.value.ptr != field2.name.value.ptr or field1.type != field2.type) return false;
        }

        return true;
    }

    pub fn hash(self: *const Effect, hasher: *ir.QuickHasher) void {
        hasher.update(self.name);
        hasher.update(self.elements.len);
        for (self.elements) |field| {
            hasher.update(field.name.value.ptr);
            hasher.update(field.type);
        }
    }

    pub fn cbr(self: *const Effect) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("Effect");

        hasher.update("name:");
        hasher.update(self.name.value);

        hasher.update("elements.count:");
        hasher.update(self.elements.len);

        hasher.update("elements:");
        for (self.elements) |elem| {
            hasher.update("elem.name:");
            hasher.update(elem.name.value);

            hasher.update("elem.type:");
            hasher.update(elem.type.getCbr());
        }

        return hasher.final();
    }

    pub fn dehydrate(self: *const Effect, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .name, .value = try dehydrator.dehydrateName(self.name) },
        });

        for (self.elements) |elem| {
            const elem_name_id = try dehydrator.dehydrateName(elem.name);
            const elem_type_id = try dehydrator.dehydrateTerm(elem.type);
            try out.appendSlice(dehydrator.sma.allocator, &.{
                ir.Sma.Operand{ .kind = .name, .value = elem_name_id },
                ir.Sma.Operand{ .kind = .term, .value = elem_type_id },
            });
        }
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *Effect) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Defines a variable in a Polymorphic repr.
pub const Quantifier = struct {
    /// Unique ID binding variables within a PolymorphicType.
    id: u32,
    /// Type kind required for instantiations of this quantifier.
    kind: ir.Term,

    pub fn eql(self: *const Quantifier, other: *const Quantifier) bool {
        return self.id == other.id and self.kind == other.kind;
    }

    pub fn hash(self: *const Quantifier, hasher: *ir.QuickHasher) void {
        hasher.update(self.id);
        hasher.update(self.kind);
    }

    pub fn cbr(self: *const Quantifier) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("Quantifier");

        hasher.update("id:");
        hasher.update(self.id);

        hasher.update("kind:");
        hasher.update(self.kind.getCbr());

        return hasher.final();
    }

    pub fn dehydrate(self: *const Quantifier, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .uint, .value = self.id },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.kind) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *Quantifier) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// The kind of a type that is a symbolic identity.
pub const SymbolKind = ir.Term.IdentityType("SymbolKind");

/// The kind of a standard type.
pub const TypeKind = ir.Term.IdentityType("TypeKind");

/// The kind of a type class type.
pub const ClassKind = ir.Term.IdentityType("ClassKind");

/// The kind of an effect type.
pub const EffectKind = ir.Term.IdentityType("EffectKind");

/// The kind of a handler type.
pub const HandlerKind = ir.Term.IdentityType("HandlerKind");

/// The kind of a raw function type.
pub const FunctionKind = ir.Term.IdentityType("FunctionKind");

/// The kind of a type constraint.
pub const ConstraintKind = ir.Term.IdentityType("ConstraintKind");

/// The kind of a data value lifted to type level.
pub const LiftedDataKind = struct {
    unlifted_type: ir.Term,

    pub fn eql(self: *const LiftedDataKind, other: *const LiftedDataKind) bool {
        return self.unlifted_type == other.unlifted_type;
    }

    pub fn hash(self: *const LiftedDataKind, hasher: *ir.QuickHasher) void {
        hasher.update(self.unlifted_type);
    }

    pub fn cbr(self: *const LiftedDataKind) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("LiftedDataKind");
        hasher.update(self.unlifted_type.getCbr());
        return hasher.final();
    }

    pub fn dehydrate(self: *const LiftedDataKind, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.append(dehydrator.sma.allocator, .{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.unlifted_type) });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *LiftedDataKind) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// The kind of type constructors, functions on types.
pub const ArrowKind = struct {
    /// The kind of the input type provided to a constructor of this arrow kind.
    input: ir.Term,
    /// The kind of the output type produced by a constructor of this arrow kind.
    output: ir.Term,

    pub fn eql(self: *const ArrowKind, other: *const ArrowKind) bool {
        return self.input == other.input and self.output == other.output;
    }

    pub fn hash(self: *const ArrowKind, hasher: *ir.QuickHasher) void {
        hasher.update(self.input);
        hasher.update(self.output);
    }

    pub fn cbr(self: *const ArrowKind) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("ArrowKind");

        hasher.update("input:");
        hasher.update(self.input.getCbr());

        hasher.update("output:");
        hasher.update(self.output.getCbr());

        return hasher.final();
    }

    pub fn dehydrate(self: *const ArrowKind, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.input) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.output) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *ArrowKind) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Type data for a void type repr.
pub const VoidType = ir.Term.IdentityType("VoidType");

/// Type data for a boolean type repr.
pub const BoolType = ir.Term.IdentityType("BoolType"); // TODO: it may be better to represent this as a sum or enum; currently this was chosen because bool is a bit special in that it is representable as a single bit. Ideally, this property should be representable on the aformentioned options as well.

/// Type data for a unit type repr.
pub const UnitType = ir.Term.IdentityType("UnitType");

/// Type data for the top type repr representing the absence of control flow resulting from an expression.
pub const NoReturnType = ir.Term.IdentityType("NoReturnType");

/// Type data for an integer type repr.
pub const IntegerType = struct {
    /// Indicates whether or not the integer type is signed.
    signedness: ir.Term,
    /// Precise width of the integer type in bits, allowing arbitrary value ranges.
    bit_width: ir.Term,

    pub fn eql(self: *const IntegerType, other: *const IntegerType) bool {
        return self.signedness == other.signedness and self.bit_width == other.bit_width;
    }

    pub fn hash(self: *const IntegerType, hasher: *ir.QuickHasher) void {
        hasher.update(self.signedness);
        hasher.update(self.bit_width);
    }

    pub fn cbr(self: *const IntegerType) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("IntegerType");

        hasher.update("signedness:");
        hasher.update(self.signedness.getCbr());

        hasher.update("bit_width:");
        hasher.update(self.bit_width.getCbr());

        return hasher.final();
    }

    pub fn dehydrate(self: *const IntegerType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.signedness) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.bit_width) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *IntegerType) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Type data for a floating point type repr.
pub const FloatType = struct {
    /// Precise width of the floating point type in bits;
    /// unlike Integer, this should not allow arbitrary value ranges.
    bit_width: ir.Term,

    pub fn eql(self: *const FloatType, other: *const FloatType) bool {
        return self.bit_width == other.bit_width;
    }

    pub fn hash(self: *const FloatType, hasher: *ir.QuickHasher) void {
        hasher.update(self.bit_width);
    }

    pub fn cbr(self: *const FloatType) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("FloatType");

        hasher.update(self.bit_width.getCbr());

        return hasher.final();
    }

    pub fn dehydrate(self: *const FloatType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.append(dehydrator.sma.allocator, .{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.bit_width) });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *FloatType) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Type data for an array type repr.
pub const ArrayType = struct {
    /// Number of elements in the array type.
    len: ir.Term,
    /// Optional constant value transparently attached to the end of the array,
    /// allowing easy creation of sentinel buffers.
    /// (ie, in zig syntax: [*:0]u8 for null-terminated string)
    sentinel_value: ir.Term,
    /// Value type at each element slot in the array type.
    payload: ir.Term,

    pub fn eql(self: *const ArrayType, other: *const ArrayType) bool {
        return self.len == other.len and self.sentinel_value == other.sentinel_value and self.payload == other.payload;
    }

    pub fn hash(self: *const ArrayType, hasher: *ir.QuickHasher) void {
        hasher.update(self.len);
        hasher.update(self.sentinel_value);
        hasher.update(self.payload);
    }

    pub fn cbr(self: *const ArrayType) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("ArrayType");

        hasher.update("len:");
        hasher.update(self.len.getCbr());

        hasher.update("sentinel_value:");
        hasher.update(self.sentinel_value.getCbr());

        hasher.update("payload:");
        hasher.update(self.payload.getCbr());

        return hasher.final();
    }

    pub fn dehydrate(self: *const ArrayType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.len) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.sentinel_value) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.payload) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *ArrayType) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Type data for a pointer type repr.
pub const PointerType = struct {
    /// Alignment override for addresses of this type.
    /// `nil` indicates natural alignment of `payload`.
    alignment: ir.Term,
    /// Symbolic tag indicating the allocator this pointer belongs to.
    address_space: ir.Term,
    /// Value type at the destination address of pointers with this type.
    payload: ir.Term,
    // TODO: support bit offset ala zig extended alignment? e.g. `align(10:4:10)`

    pub fn eql(self: *const PointerType, other: *const PointerType) bool {
        return self.alignment == other.alignment and self.address_space == other.address_space and self.payload == other.payload;
    }

    pub fn hash(self: *const PointerType, hasher: *ir.QuickHasher) void {
        hasher.update(self.alignment);
        hasher.update(self.address_space);
        hasher.update(self.payload);
    }

    pub fn cbr(self: *const PointerType) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("PointerType");

        hasher.update("alignment:");
        hasher.update(self.alignment.getCbr());

        hasher.update("address_space:");
        hasher.update(self.address_space.getCbr());

        hasher.update("payload:");
        hasher.update(self.payload.getCbr());

        return hasher.final();
    }

    pub fn dehydrate(self: *const PointerType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.alignment) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.address_space) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.payload) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *PointerType) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Type data for a pointer-to-many type repr.
pub const BufferType = struct {
    /// Alignment override for addresses of this type.
    /// `nil` indicates natural alignment of `payload`.
    alignment: ir.Term,
    /// Symbolic tag indicating the allocator this pointer belongs to.
    address_space: ir.Term,
    /// Optional constant value transparently attached to the end of the buffer,
    /// (ie, in zig syntax: [*:0]u8 for null-terminated string)
    sentinel_value: ir.Term,
    /// Value type at the destination address of pointers with this type.
    payload: ir.Term,

    pub fn eql(self: *const BufferType, other: *const BufferType) bool {
        return self.alignment == other.alignment and self.address_space == other.address_space and self.sentinel_value == other.sentinel_value and self.payload == other.payload;
    }

    pub fn hash(self: *const BufferType, hasher: *ir.QuickHasher) void {
        hasher.update(self.alignment);
        hasher.update(self.address_space);
        hasher.update(self.sentinel_value);
        hasher.update(self.payload);
    }

    pub fn cbr(self: *const BufferType) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("BufferType");

        hasher.update("alignment:");
        hasher.update(self.alignment.getCbr());

        hasher.update("address_space:");
        hasher.update(self.address_space.getCbr());

        hasher.update("sentinel_value:");
        hasher.update(self.sentinel_value.getCbr());

        hasher.update("payload:");
        hasher.update(self.payload.getCbr());

        return hasher.final();
    }

    pub fn dehydrate(self: *const BufferType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.alignment) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.address_space) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.sentinel_value) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.payload) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *BufferType) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Type data for a wide-pointer-to-many type repr.
pub const SliceType = struct {
    /// Alignment override for addresses of this type.
    /// `nil` indicates natural alignment of `payload`.
    alignment: ir.Term,
    /// Symbolic tag indicating the allocator this pointer belongs to.
    address_space: ir.Term,
    /// Optional constant value transparently attached to the end of the slice,
    /// (ie, in zig syntax: [:0]u8 for slice of null-terminated string buffer)
    sentinel_value: ir.Term,
    /// Value type at the destination address of pointers with this type.
    payload: ir.Term,

    pub fn eql(self: *const SliceType, other: *const SliceType) bool {
        return self.alignment == other.alignment and self.address_space == other.address_space and self.sentinel_value == other.sentinel_value and self.payload == other.payload;
    }

    pub fn hash(self: *const SliceType, hasher: *ir.QuickHasher) void {
        hasher.update(self.alignment);
        hasher.update(self.address_space);
        hasher.update(self.sentinel_value);
        hasher.update(self.payload);
    }

    pub fn cbr(self: *const SliceType) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("SliceType");

        hasher.update("alignment:");
        hasher.update(self.alignment.getCbr());

        hasher.update("address_space:");
        hasher.update(self.address_space.getCbr());

        hasher.update("sentinel_value:");
        hasher.update(self.sentinel_value.getCbr());

        hasher.update("payload:");
        hasher.update(self.payload.getCbr());

        return hasher.final();
    }

    pub fn dehydrate(self: *const SliceType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.alignment) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.address_space) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.sentinel_value) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.payload) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *SliceType) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Used for abstract data description.
pub const RowElementType = struct {
    label: ir.Term,
    payload: ir.Term,

    pub fn eql(self: *const RowElementType, other: *const RowElementType) bool {
        return self.label == other.label and self.payload == other.payload;
    }

    pub fn hash(self: *const RowElementType, hasher: *ir.QuickHasher) void {
        hasher.update(self.label);
        hasher.update(self.payload);
    }

    pub fn cbr(self: *const RowElementType) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("RowElementType");

        hasher.update("label:");
        hasher.update(self.label.getCbr());

        hasher.update("payload:");
        hasher.update(self.payload.getCbr());

        return hasher.final();
    }

    pub fn dehydrate(self: *const RowElementType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.label) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.payload) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *RowElementType) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Used for abstract data description.
pub const LabelType = union(enum) {
    name: ir.Term,
    index: ir.Term,
    exact: struct {
        name: ir.Term,
        index: ir.Term,
    },

    pub fn eql(self: *const LabelType, other: *const LabelType) bool {
        if (@as(std.meta.Tag(LabelType), self.*) != other.*) return false;
        return switch (self.*) {
            .name => |n| n == other.name,
            .index => |i| i == other.index,
            .exact => |e| e.name == other.exact.name and e.index == other.exact.index,
        };
    }

    pub fn hash(self: *const LabelType, hasher: *ir.QuickHasher) void {
        hasher.update(@as(std.meta.Tag(LabelType), self.*));
        switch (self.*) {
            .name => |n| {
                hasher.update(n);
            },
            .index => |i| {
                hasher.update(i);
            },
            .exact => |e| {
                hasher.update(e.name);
                hasher.update(e.index);
            },
        }
    }

    pub fn cbr(self: *const LabelType) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("LabelType");

        switch (self.*) {
            .name => |n| {
                hasher.update("name:");
                hasher.update(n.getCbr());
            },
            .index => |i| {
                hasher.update("index:");
                hasher.update(i.getCbr());
            },
            .exact => |e| {
                hasher.update("exact.name:");
                hasher.update(e.name.getCbr());

                hasher.update("exact.index:");
                hasher.update(e.index.getCbr());
            },
        }

        return hasher.final();
    }

    pub fn dehydrate(self: *const LabelType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        switch (self.*) {
            .name => |n| {
                try out.appendSlice(dehydrator.sma.allocator, &.{
                    ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(n) },
                });
            },
            .index => |i| {
                try out.appendSlice(dehydrator.sma.allocator, &.{
                    ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(i) },
                });
            },
            .exact => |e| {
                try out.appendSlice(dehydrator.sma.allocator, &.{
                    ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(e.name) },
                    ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(e.index) },
                });
            },
        }
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *LabelType) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Used for compile time constants as types, such as integer values.
pub const LiftedDataType = struct {
    /// The type of the data before it was lifted to a type value.
    unlifted_type: ir.Term,
    /// The actual value of the data.
    value: *ir.Block,

    pub fn eql(self: *const LiftedDataType, other: *const LiftedDataType) bool {
        return self.unlifted_type == other.unlifted_type and self.value == other.value;
    }

    pub fn hash(self: *const LiftedDataType, hasher: *ir.QuickHasher) void {
        hasher.update(self.unlifted_type);
        hasher.update(&self.value);
    }

    pub fn cbr(self: *const LiftedDataType) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("LiftedDataType");

        hasher.update("unlifted_type:");
        hasher.update(self.unlifted_type.getCbr());

        hasher.update("value:");
        hasher.update(self.value.getCbr());

        return hasher.final();
    }

    pub fn dehydrate(self: *const LiftedDataType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        const unlifted_type_id = try dehydrator.dehydrateTerm(self.unlifted_type);
        const value_id = try dehydrator.dehydrateExpression(self.value);

        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = unlifted_type_id },
            ir.Sma.Operand{ .kind = .expression, .value = value_id },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *LiftedDataType) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Type data for a structure type repr.
pub const StructureType = struct {
    /// Nominative identity of this structure type.
    name: ir.Name,
    /// Layout heuristic determining how fields are to be arranged in memory.
    layout: ir.Term,
    /// Optional integer representation of the structure type.
    /// For example, when specifying bit_packed, it helps to prevent errors if one specifies the precise integer size.
    backing_integer: ir.Term,
    /// Descriptions of each field of this structure type.
    elements: []const Field = &.{},

    /// Descriptor for structural fields.
    pub const Field = struct {
        /// Nominative identity of this field.
        name: ir.Name,
        /// The type of data stored in this field.
        payload: ir.Term,
        /// An optional custom alignment for this field, overriding the natural alignment of `payload`;
        /// used by `Heuristic.optimal`; not allowed by others.
        alignment_override: ir.Term,
    };

    pub fn eql(self: *const StructureType, other: *const StructureType) bool {
        if (self.name.value.ptr != other.name.value.ptr or self.layout != other.layout or self.backing_integer != other.backing_integer or self.elements.len != other.elements.len) return false;

        for (0..self.elements.len) |i| {
            const a = self.elements[i];
            const b = other.elements[i];
            if (a.name.value.ptr != b.name.value.ptr or a.payload != b.payload or a.alignment_override != b.alignment_override) return false;
        }

        return true;
    }

    pub fn hash(self: *const StructureType, hasher: *ir.QuickHasher) void {
        hasher.update(self.name);
        hasher.update(self.layout);
        hasher.update(self.backing_integer);
        hasher.update(self.elements.len);
        for (self.elements) |elem| {
            hasher.update(elem.name.value);
            hasher.update(elem.payload);
            hasher.update(elem.alignment_override);
        }
    }

    pub fn cbr(self: *const StructureType) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("StructureType");

        hasher.update("name:");
        hasher.update(self.name.value);

        hasher.update("layout:");
        hasher.update(self.layout.getCbr());

        hasher.update("backing_integer:");
        hasher.update(self.backing_integer.getCbr());

        hasher.update("elements.len:");
        hasher.update(self.elements.len);

        hasher.update("elements:");
        for (self.elements) |elem| {
            hasher.update("elem.name:");
            hasher.update(elem.name.value);

            hasher.update("elem.payload:");
            hasher.update(elem.payload.getCbr());

            hasher.update("elem.alignment_override:");
            hasher.update(elem.alignment_override.getCbr());
        }

        return hasher.final();
    }

    pub fn dehydrate(self: *const StructureType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        const name_id = try dehydrator.dehydrateName(self.name);
        const layout_id = try dehydrator.dehydrateTerm(self.layout);
        const backing_integer_id = try dehydrator.dehydrateTerm(self.backing_integer);

        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .name, .value = name_id },
            ir.Sma.Operand{ .kind = .term, .value = layout_id },
            ir.Sma.Operand{ .kind = .term, .value = backing_integer_id },
        });

        for (self.elements) |field| {
            const field_name_id = try dehydrator.dehydrateName(field.name);
            const field_payload_id = try dehydrator.dehydrateTerm(field.payload);
            const field_alignment_id = try dehydrator.dehydrateTerm(field.alignment_override);
            try out.appendSlice(dehydrator.sma.allocator, &.{
                ir.Sma.Operand{ .kind = .name, .value = field_name_id },
                ir.Sma.Operand{ .kind = .term, .value = field_payload_id },
                ir.Sma.Operand{ .kind = .term, .value = field_alignment_id },
            });
        }
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *StructureType) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Type data for a tagged sum type repr.
pub const UnionType = struct {
    /// Nominative identity for this undiscriminated union type.
    name: ir.Name,
    /// Heuristic determining the variant tagging and data layout strategy.
    layout: ir.Term,
    /// Descriptions of each descriminant and variant of this union type.
    elements: []const Field = &.{},

    /// Descriptor for union fields.
    pub const Field = struct {
        /// Nominative identity for this variant.
        name: ir.Name,
        /// Optional type of data stored in this variant;
        /// nil indicates discriminant-only variation.
        payload: ir.Term,
    };

    pub fn eql(self: *const UnionType, other: *const UnionType) bool {
        if (self.name.value.ptr != other.name.value.ptr or self.layout != other.layout or self.elements.len != other.elements.len) return false;

        for (0..self.elements.len) |i| {
            const a = self.elements[i];
            const b = other.elements[i];
            if (a.name.value.ptr != b.name.value.ptr or a.payload != b.payload) return false;
        }

        return true;
    }

    pub fn hash(self: *const UnionType, hasher: *ir.QuickHasher) void {
        hasher.update(self.name);
        hasher.update(self.layout);
        hasher.update(self.elements.len);
        for (self.elements) |elem| {
            hasher.update(elem.name.value.ptr);
            hasher.update(elem.payload);
        }
    }

    pub fn cbr(self: *const UnionType) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("UnionType");

        hasher.update("name:");
        hasher.update(self.name.value);

        hasher.update("layout:");
        hasher.update(self.layout.getCbr());

        hasher.update("elements.len:");
        hasher.update(self.elements.len);

        hasher.update("elements:");
        for (self.elements) |elem| {
            hasher.update("elem.name:");
            hasher.update(elem.name.value);

            hasher.update("elem.payload:");
            hasher.update(elem.payload.getCbr());
        }

        return hasher.final();
    }

    pub fn dehydrate(self: *const UnionType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        const name_id = try dehydrator.dehydrateName(self.name);
        const layout_id = try dehydrator.dehydrateTerm(self.layout);

        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .name, .value = name_id },
            ir.Sma.Operand{ .kind = .term, .value = layout_id },
        });

        for (self.elements) |field| {
            const field_name_id = try dehydrator.dehydrateName(field.name);
            const field_payload_id = try dehydrator.dehydrateTerm(field.payload);
            try out.appendSlice(dehydrator.sma.allocator, &.{
                ir.Sma.Operand{ .kind = .name, .value = field_name_id },
                ir.Sma.Operand{ .kind = .term, .value = field_payload_id },
            });
        }
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *UnionType) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Type data for a tagged sum type repr.
pub const SumType = struct {
    /// Nominative identity for this discriminated union type.
    name: ir.Name,
    /// Type for the discriminant tag in this union.
    tag_type: ir.Term,
    /// Heuristic determining the variant tagging and data layout strategy.
    layout: ir.Term,
    /// Descriptions of each descriminant and variant of this union type.
    elements: []const Field = &.{},

    /// Descriptor for union fields.
    pub const Field = struct {
        /// Nominative identity for this variant.
        name: ir.Name,
        /// Optional type of data stored in this variant;
        /// nil indicates discriminant-only variation.
        payload: ir.Term,
        /// Constant value of this variant's discriminant.
        tag: ir.Term,
    };

    pub fn eql(self: *const SumType, other: *const SumType) bool {
        if (self.name.value.ptr != other.name.value.ptr or self.tag_type != other.tag_type or self.layout != other.layout or self.elements.len != other.elements.len) return false;

        for (0..self.elements.len) |i| {
            const a = self.elements[i];
            const b = other.elements[i];
            if (a.name.value.ptr != b.name.value.ptr or a.payload != b.payload or a.tag != b.tag) return false;
        }

        return true;
    }

    pub fn hash(self: *const SumType, hasher: *ir.QuickHasher) void {
        hasher.update(self.name);
        hasher.update(self.tag_type);
        hasher.update(self.layout);
        hasher.update(self.elements.len);
        for (self.elements) |elem| {
            hasher.update(elem.name);
            hasher.update(elem.payload);
            hasher.update(elem.tag);
        }
    }

    pub fn cbr(self: *const SumType) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("SumType");

        hasher.update("name:");
        hasher.update(self.name.value);

        hasher.update("tag_type:");
        hasher.update(self.tag_type.getCbr());

        hasher.update("layout:");
        hasher.update(self.layout.getCbr());

        hasher.update("elements.len:");
        hasher.update(self.elements.len);

        hasher.update("elements:");
        for (self.elements) |elem| {
            hasher.update("elem.name:");
            hasher.update(elem.name.value);

            hasher.update("elem.payload:");
            hasher.update(elem.payload.getCbr());

            hasher.update("elem.tag:");
            hasher.update(elem.tag.getCbr());
        }

        return hasher.final();
    }

    pub fn dehydrate(self: *const SumType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        const name_id = try dehydrator.dehydrateName(self.name);
        const tag_type_id = try dehydrator.dehydrateTerm(self.tag_type);
        const layout_id = try dehydrator.dehydrateTerm(self.layout);

        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .name, .value = name_id },
            ir.Sma.Operand{ .kind = .term, .value = tag_type_id },
            ir.Sma.Operand{ .kind = .term, .value = layout_id },
        });

        for (self.elements) |field| {
            const field_name_id = try dehydrator.dehydrateName(field.name);
            const field_payload_id = try dehydrator.dehydrateTerm(field.payload);
            const field_tag_id = try dehydrator.dehydrateTerm(field.tag);
            try out.appendSlice(dehydrator.sma.allocator, &.{
                ir.Sma.Operand{ .kind = .name, .value = field_name_id },
                ir.Sma.Operand{ .kind = .term, .value = field_payload_id },
                ir.Sma.Operand{ .kind = .term, .value = field_tag_id },
            });
        }
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *SumType) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Type data for a function type repr.
pub const FunctionType = struct {
    /// Parameter type for this function signature. Multiple input values are represented by Product.
    input: ir.Term,
    /// Result type for this function.
    output: ir.Term,
    /// Side effect type incurred when calling this function. Multiple effects are represented by Product.
    effects: ir.Term,

    pub fn eql(self: *const FunctionType, other: *const FunctionType) bool {
        return self.input == other.input and self.output == other.output and self.effects == other.effects;
    }

    pub fn hash(self: *const FunctionType, hasher: *ir.QuickHasher) void {
        hasher.update(self.input);
        hasher.update(self.output);
        hasher.update(self.effects);
    }

    pub fn cbr(self: *const FunctionType) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("FunctionType");

        hasher.update("input:");
        hasher.update(self.input.getCbr());

        hasher.update("output:");
        hasher.update(self.output.getCbr());

        hasher.update("effects:");
        hasher.update(self.effects.getCbr());

        return hasher.final();
    }

    pub fn dehydrate(self: *const FunctionType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.input) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.output) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.effects) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *FunctionType) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Type data for an effect handler repr.
pub const HandlerType = struct {
    /// Parameter type for this handler signature. Multiple input values are represented by Product.
    input: ir.Term,
    /// Result type for this handler.
    output: ir.Term,
    /// Effect that is (at least temporarily) eliminated by this handler.
    handled_effect: ir.Term,
    /// Side effects that are incurred in the process of handling this handler's effect. May include `handled_effect` for modulating handlers.
    added_effects: ir.Term,

    pub fn eql(self: *const HandlerType, other: *const HandlerType) bool {
        return self.input == other.input and self.output == other.output and self.handled_effect == other.handled_effect and self.added_effects == other.added_effects;
    }

    pub fn hash(self: *const HandlerType, hasher: *ir.QuickHasher) void {
        hasher.update(self.input);
        hasher.update(self.output);
        hasher.update(self.handled_effect);
        hasher.update(self.added_effects);
    }

    pub fn cbr(self: *const HandlerType) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("HandlerType");

        hasher.update("input:");
        hasher.update(self.input.getCbr());

        hasher.update("output:");
        hasher.update(self.output.getCbr());

        hasher.update("handled_effect:");
        hasher.update(self.handled_effect.getCbr());

        hasher.update("added_effects:");
        hasher.update(self.added_effects.getCbr());

        return hasher.final();
    }

    pub fn dehydrate(self: *const HandlerType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.input) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.output) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.handled_effect) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.added_effects) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *HandlerType) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Type data for a polymorphic type repr, with quantifiers and/or qualifiers.
pub const PolymorphicType = struct {
    /// Type variable declarations for this polymorphic type.
    quantifiers: []const ir.Term = &.{},
    /// Type constraints declarations for this polymorphic type.
    qualifiers: ir.Term,
    /// The type to be instantiated by this polymorphic repr.
    payload: ir.Term,

    pub fn eql(self: *const PolymorphicType, other: *const PolymorphicType) bool {
        if (self.quantifiers.len != other.quantifiers.len or self.qualifiers != other.qualifiers or self.payload != other.payload) return false;

        for (0..self.quantifiers.len) |i| {
            if (self.quantifiers[i] != other.quantifiers[i]) return false;
        }

        return true;
    }

    pub fn hash(self: *const PolymorphicType, hasher: *ir.QuickHasher) void {
        hasher.update(self.quantifiers.len);
        for (self.quantifiers) |quant| {
            hasher.update(quant);
        }
        hasher.update(self.qualifiers);
        hasher.update(self.payload);
    }

    pub fn cbr(self: *const PolymorphicType) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("PolymorphicType");

        hasher.update("quantifiers_count:");
        hasher.update(self.quantifiers.len);

        hasher.update("quantifiers:");
        for (self.quantifiers) |quant| {
            hasher.update("quantifier:");
            hasher.update(quant.getCbr());
        }

        hasher.update("qualifiers:");
        hasher.update(self.qualifiers.getCbr());

        hasher.update("payload:");
        hasher.update(self.payload.getCbr());

        return hasher.final();
    }

    pub fn dehydrate(self: *const PolymorphicType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        for (self.quantifiers) |quant| {
            try out.appendSlice(dehydrator.sma.allocator, &.{
                ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(quant) },
            });
        }

        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.qualifiers) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.payload) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *PolymorphicType) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Constraint checking that `subtype_row` is a subset of `primary_row`.
pub const IsSubRowConstraint = struct {
    /// The larger product type.
    primary_row: ir.Term,
    /// The smaller product type that must be a subset of `primary_row`.
    subtype_row: ir.Term,

    pub fn eql(self: *const IsSubRowConstraint, other: *const IsSubRowConstraint) bool {
        return self.primary_row == other.primary_row and self.subtype_row == other.subtype_row;
    }

    pub fn hash(self: *const IsSubRowConstraint, hasher: *ir.QuickHasher) void {
        hasher.update(self.primary_row);
        hasher.update(self.subtype_row);
    }

    pub fn cbr(self: *const IsSubRowConstraint) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("IsSubRowConstraint");

        hasher.update("primary_row:");
        hasher.update(self.primary_row.getCbr());

        hasher.update("subtype_row:");
        hasher.update(self.subtype_row.getCbr());

        return hasher.final();
    }

    pub fn dehydrate(self: *const IsSubRowConstraint, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.primary_row) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.subtype_row) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *IsSubRowConstraint) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Constraint checking that `row_result` is the disjoint union of `row_a` and `row_b`.
pub const RowsConcatenateConstraint = struct {
    /// The LHS input to the concatenation.
    row_a: ir.Term,
    /// The RHS input to the concatenation.
    row_b: ir.Term,
    /// The product type that must match the disjoint union of `row_a` and `row_b`.
    row_result: ir.Term,

    pub fn eql(self: *const RowsConcatenateConstraint, other: *const RowsConcatenateConstraint) bool {
        return self.row_a == other.row_a and self.row_b == other.row_b and self.row_result == other.row_result;
    }

    pub fn hash(self: *const RowsConcatenateConstraint, hasher: *ir.QuickHasher) void {
        hasher.update(self.row_a);
        hasher.update(self.row_b);
        hasher.update(self.row_result);
    }

    pub fn cbr(self: *const RowsConcatenateConstraint) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("RowsConcatenateConstraint");

        hasher.update("row_a:");
        hasher.update(self.row_a.getCbr());

        hasher.update("row_b:");
        hasher.update(self.row_b.getCbr());

        hasher.update("row_result:");
        hasher.update(self.row_result.getCbr());

        return hasher.final();
    }

    pub fn dehydrate(self: *const RowsConcatenateConstraint, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.row_a) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.row_b) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.row_result) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *RowsConcatenateConstraint) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Constraint checking that the `data` type implements the `class` typeclass.
pub const ImplementsClassConstraint = struct {
    /// The type that must implement the `class` typeclass.
    data: ir.Term,
    /// The typeclass that must be implemented by `data`.
    class: ir.Term,

    pub fn eql(self: *const ImplementsClassConstraint, other: *const ImplementsClassConstraint) bool {
        return self.data == other.data and self.class == other.class;
    }

    pub fn hash(self: *const ImplementsClassConstraint, hasher: *ir.QuickHasher) void {
        hasher.update(self.data);
        hasher.update(self.class);
    }

    pub fn cbr(self: *const ImplementsClassConstraint) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("ImplementsClassConstraint");

        hasher.update("data:");
        hasher.update(self.data.getCbr());

        hasher.update("class:");
        hasher.update(self.class.getCbr());

        return hasher.final();
    }

    pub fn dehydrate(self: *const ImplementsClassConstraint, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.data) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.class) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *ImplementsClassConstraint) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Constraint checking that the `data` type is a nominative identity for a structure over the `row` type.
pub const IsStructureConstraint = struct {
    /// The nominative structural type that must contain `row`.
    data: ir.Term,
    /// The structural description type that must match the layout of `data`.
    row: ir.Term,

    pub fn eql(self: *const IsStructureConstraint, other: *const IsStructureConstraint) bool {
        return self.data == other.data and self.row == other.row;
    }

    pub fn hash(self: *const IsStructureConstraint, hasher: *ir.QuickHasher) void {
        hasher.update(self.data);
        hasher.update(self.row);
    }

    pub fn cbr(self: *const IsStructureConstraint) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("IsStructureConstraint");

        hasher.update("data:");
        hasher.update(self.data.getCbr());

        hasher.update("row:");
        hasher.update(self.row.getCbr());

        return hasher.final();
    }

    pub fn dehydrate(self: *const IsStructureConstraint, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.data) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.row) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *IsStructureConstraint) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Constraint checking that the `data` type is a nominative identity for a union over the `row` type.
pub const IsUnionConstraint = struct {
    /// The nominative structural type that must contain `row`.
    data: ir.Term,
    /// The structural description type that must match the layout of `data`.
    row: ir.Term,

    pub fn eql(self: *const IsUnionConstraint, other: *const IsUnionConstraint) bool {
        return self.data == other.data and self.row == other.row;
    }

    pub fn hash(self: *const IsUnionConstraint, hasher: *ir.QuickHasher) void {
        hasher.update(self.data);
        hasher.update(self.row);
    }

    pub fn cbr(self: *const IsUnionConstraint) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("IsUnionConstraint");

        hasher.update("data:");
        hasher.update(self.data.getCbr());

        hasher.update("row:");
        hasher.update(self.row.getCbr());

        return hasher.final();
    }

    pub fn dehydrate(self: *const IsUnionConstraint, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.data) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.row) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *IsUnionConstraint) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};

/// Constraint checking that the `data` type is a nominative identity for a sum over the `row` type.
pub const IsSumConstraint = struct {
    /// The nominative structural type that must contain `row`.
    data: ir.Term,
    /// The structural description type that must match the layout of `data`.
    row: ir.Term,

    pub fn eql(self: *const IsSumConstraint, other: *const IsSumConstraint) bool {
        return self.data == other.data and self.row == other.row;
    }

    pub fn hash(self: *const IsSumConstraint, hasher: *ir.QuickHasher) void {
        hasher.update(self.data);
        hasher.update(self.row);
    }

    pub fn cbr(self: *const IsSumConstraint) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("IsSumConstraint");

        hasher.update("data:");
        hasher.update(self.data.getCbr());

        hasher.update("row:");
        hasher.update(self.row.getCbr());

        return hasher.final();
    }

    pub fn dehydrate(self: *const IsSumConstraint, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.data) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.row) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *IsSumConstraint) error{ BadEncoding, OutOfMemory }!void {
        common.todo(noreturn, .{ dehydrated, rehydrator, out });
    }
};
