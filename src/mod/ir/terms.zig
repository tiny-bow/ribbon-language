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
            hasher.update(field.name.value);
            hasher.update(field.value);
        }
    }

    pub fn dehydrate(self: *const Implementation, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.append(dehydrator.sma.allocator, .{
            .kind = .term,
            .value = try dehydrator.dehydrateTerm(self.class),
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
        out.class = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 0));
        const members = try rehydrator.ctx.arena.allocator().alloc(Implementation.Field, @divExact(dehydrated.operands.items.len - 1, 2));
        out.members = members;
        for (0..out.members.len) |i| {
            const name_op = try dehydrated.getOperandOf(.name, 1 + i * 2);
            const value_op = try dehydrated.getOperandOf(.term, 2 + i * 2);
            members[i] = .{
                .name = try rehydrator.rehydrateName(name_op),
                .value = try rehydrator.rehydrateTerm(value_op),
            };
        }
    }
};

/// A symbol is a term that can appear in both values and types, and is simply a nominative identity in the form of a name.
pub const Symbol = struct {
    name: ir.Name,

    pub fn eql(self: *const Symbol, other: *const Symbol) bool {
        return self.name.value.ptr == other.name.value.ptr;
    }

    pub fn hash(self: *const Symbol, hasher: *ir.QuickHasher) void {
        hasher.update(self.name.value);
    }

    pub fn dehydrate(self: *const Symbol, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.append(dehydrator.sma.allocator, .{ .kind = .name, .value = try dehydrator.dehydrateName(self.name) });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *Symbol) error{ BadEncoding, OutOfMemory }!void {
        out.name = try rehydrator.rehydrateName(try dehydrated.getOperandOf(.name, 0));
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
            hasher.update(field.name.value);
            hasher.update(field.type);
        }
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
        out.name = try rehydrator.rehydrateName(try dehydrated.getOperandOf(.name, 0));

        const elements = try rehydrator.ctx.arena.allocator().alloc(Class.Field, @divExact(dehydrated.operands.items.len - 1, 2));
        out.elements = elements;

        for (0..out.elements.len) |i| {
            const name_op = try dehydrated.getOperandOf(.name, 1 + i * 2);
            const type_op = try dehydrated.getOperandOf(.term, 2 + i * 2);
            elements[i] = .{
                .name = try rehydrator.rehydrateName(name_op),
                .type = try rehydrator.rehydrateTerm(type_op),
            };
        }
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
            hasher.update(field.name.value);
            hasher.update(field.type);
        }
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
        out.name = try rehydrator.rehydrateName(try dehydrated.getOperandOf(.name, 0));

        const elements = try rehydrator.ctx.arena.allocator().alloc(Effect.Field, @divExact(dehydrated.operands.items.len - 1, 2));
        out.elements = elements;

        for (0..out.elements.len) |i| {
            const name_op = try dehydrated.getOperandOf(.name, 1 + i * 2);
            const type_op = try dehydrated.getOperandOf(.term, 2 + i * 2);
            elements[i] = .{
                .name = try rehydrator.rehydrateName(name_op),
                .type = try rehydrator.rehydrateTerm(type_op),
            };
        }
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

    pub fn dehydrate(self: *const Quantifier, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .uint, .value = self.id },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.kind) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *Quantifier) error{ BadEncoding, OutOfMemory }!void {
        out.id = try dehydrated.getOperandOf(.uint, 0);
        out.kind = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1));
    }
};

/// The kind of a type that is a symbolic identity.
pub const SymbolKind = ir.Term.Identity("SymbolKind");

/// The kind of a standard type.
pub const TypeKind = ir.Term.Identity("TypeKind");

/// The kind of a type class type.
pub const ClassKind = ir.Term.Identity("ClassKind");

/// The kind of an effect type.
pub const EffectKind = ir.Term.Identity("EffectKind");

/// The kind of a handler type.
pub const HandlerKind = ir.Term.Identity("HandlerKind");

/// The kind of a raw function type.
pub const FunctionKind = ir.Term.Identity("FunctionKind");

/// The kind of a type constraint.
pub const ConstraintKind = ir.Term.Identity("ConstraintKind");

/// The kind of a data value lifted to type level.
pub const LiftedDataKind = struct {
    unlifted_type: ir.Term,

    pub fn eql(self: *const LiftedDataKind, other: *const LiftedDataKind) bool {
        return self.unlifted_type == other.unlifted_type;
    }

    pub fn hash(self: *const LiftedDataKind, hasher: *ir.QuickHasher) void {
        hasher.update(self.unlifted_type);
    }

    pub fn dehydrate(self: *const LiftedDataKind, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.append(dehydrator.sma.allocator, .{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.unlifted_type) });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *LiftedDataKind) error{ BadEncoding, OutOfMemory }!void {
        out.unlifted_type = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 0));
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

    pub fn dehydrate(self: *const ArrowKind, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.input) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.output) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *ArrowKind) error{ BadEncoding, OutOfMemory }!void {
        out.input = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 0));
        out.output = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1));
    }
};

/// Type data for a void type repr.
pub const VoidType = ir.Term.Identity("VoidType");

/// Type data for a boolean type repr.
pub const BoolType = ir.Term.Identity("BoolType"); // TODO: it may be better to represent this as a sum or enum; currently this was chosen because bool is a bit special in that it is representable as a single bit. Ideally, this property should be representable on the aformentioned options as well.

/// Type data for a unit type repr.
pub const UnitType = ir.Term.Identity("UnitType");

/// Type data for the top type repr representing the absence of control flow resulting from an expression.
pub const NoReturnType = ir.Term.Identity("NoReturnType");

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

    pub fn dehydrate(self: *const IntegerType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.signedness) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.bit_width) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *IntegerType) error{ BadEncoding, OutOfMemory }!void {
        out.signedness = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 0));
        out.bit_width = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1));
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

    pub fn dehydrate(self: *const FloatType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.append(dehydrator.sma.allocator, .{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.bit_width) });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *FloatType) error{ BadEncoding, OutOfMemory }!void {
        out.bit_width = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 0));
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

    pub fn dehydrate(self: *const ArrayType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.len) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.sentinel_value) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.payload) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *ArrayType) error{ BadEncoding, OutOfMemory }!void {
        out.len = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 0));
        out.sentinel_value = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1));
        out.payload = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 2));
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

    pub fn dehydrate(self: *const PointerType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.alignment) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.address_space) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.payload) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *PointerType) error{ BadEncoding, OutOfMemory }!void {
        out.alignment = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 0));
        out.address_space = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1));
        out.payload = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 2));
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

    pub fn dehydrate(self: *const BufferType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.alignment) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.address_space) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.sentinel_value) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.payload) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *BufferType) error{ BadEncoding, OutOfMemory }!void {
        out.alignment = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 0));
        out.address_space = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1));
        out.sentinel_value = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 2));
        out.payload = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 3));
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

    pub fn dehydrate(self: *const SliceType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.alignment) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.address_space) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.sentinel_value) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.payload) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *SliceType) error{ BadEncoding, OutOfMemory }!void {
        out.alignment = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 0));
        out.address_space = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1));
        out.sentinel_value = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 2));
        out.payload = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 3));
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

    pub fn dehydrate(self: *const RowElementType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.label) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.payload) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *RowElementType) error{ BadEncoding, OutOfMemory }!void {
        out.label = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 0));
        out.payload = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1));
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

    pub fn dehydrate(self: *const LabelType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.append(dehydrator.sma.allocator, .{ .kind = .uint, .value = @intFromEnum(@as(std.meta.Tag(LabelType), self.*)) });

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
        const discriminant_u32 = try dehydrated.getOperandOf(.uint, 0);
        const discriminant: std.meta.Tag(LabelType) = @enumFromInt(discriminant_u32);

        switch (discriminant) {
            .name => {
                out.* = .{ .name = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1)) };
            },
            .index => {
                out.* = .{ .index = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1)) };
            },
            .exact => {
                out.* = .{ .exact = .{
                    .name = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1)),
                    .index = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 2)),
                } };
            },
        }
    }
};

/// Used for compile time constants as types, such as integer values.
pub const LiftedDataType = struct {
    /// The type of the data before it was lifted to a type value.
    unlifted_type: ir.Term,
    /// The actual value of the data.
    value: *ir.Expression,

    pub fn eql(self: *const LiftedDataType, other: *const LiftedDataType) bool {
        return self.unlifted_type == other.unlifted_type and self.value == other.value;
    }

    pub fn hash(self: *const LiftedDataType, hasher: *ir.QuickHasher) void {
        hasher.update(self.unlifted_type);
        hasher.update(&self.value);
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
        out.unlifted_type = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 0));
        out.value = try rehydrator.rehydrateExpression(try dehydrated.getOperandOf(.expression, 1));
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
        out.name = try rehydrator.rehydrateName(try dehydrated.getOperandOf(.name, 0));
        out.layout = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1));
        out.backing_integer = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 2));

        const elements = try rehydrator.ctx.arena.allocator().alloc(StructureType.Field, @divExact(dehydrated.operands.items.len - 3, 3));
        out.elements = elements;

        for (0..out.elements.len) |i| {
            const name_op = try dehydrated.getOperandOf(.name, 3 + i * 3);
            const payload_op = try dehydrated.getOperandOf(.term, 4 + i * 3);
            const alignment_op = try dehydrated.getOperandOf(.term, 5 + i * 3);
            elements[i] = .{
                .name = try rehydrator.rehydrateName(name_op),
                .payload = try rehydrator.rehydrateTerm(payload_op),
                .alignment_override = try rehydrator.rehydrateTerm(alignment_op),
            };
        }
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
            hasher.update(elem.name.value);
            hasher.update(elem.payload);
        }
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
        out.name = try rehydrator.rehydrateName(try dehydrated.getOperandOf(.name, 0));
        out.layout = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1));

        const elements = try rehydrator.ctx.arena.allocator().alloc(UnionType.Field, @divExact(dehydrated.operands.items.len - 2, 2));
        out.elements = elements;

        for (0..out.elements.len) |i| {
            const name_op = try dehydrated.getOperandOf(.name, 2 + i * 2);
            const payload_op = try dehydrated.getOperandOf(.term, 3 + i * 2);
            elements[i] = .{
                .name = try rehydrator.rehydrateName(name_op),
                .payload = try rehydrator.rehydrateTerm(payload_op),
            };
        }
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
        out.name = try rehydrator.rehydrateName(try dehydrated.getOperandOf(.name, 0));
        out.tag_type = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1));
        out.layout = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 2));

        const elements = try rehydrator.ctx.arena.allocator().alloc(SumType.Field, @divExact(dehydrated.operands.items.len - 3, 3));
        out.elements = elements;

        for (0..out.elements.len) |i| {
            const name_op = try dehydrated.getOperandOf(.name, 3 + i * 3);
            const payload_op = try dehydrated.getOperandOf(.term, 4 + i * 3);
            const tag_op = try dehydrated.getOperandOf(.term, 5 + i * 3);
            elements[i] = .{
                .name = try rehydrator.rehydrateName(name_op),
                .payload = try rehydrator.rehydrateTerm(payload_op),
                .tag = try rehydrator.rehydrateTerm(tag_op),
            };
        }
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

    pub fn dehydrate(self: *const FunctionType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.input) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.output) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.effects) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *FunctionType) error{ BadEncoding, OutOfMemory }!void {
        out.input = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 0));
        out.output = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1));
        out.effects = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 2));
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

    pub fn dehydrate(self: *const HandlerType, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.input) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.output) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.handled_effect) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.added_effects) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *HandlerType) error{ BadEncoding, OutOfMemory }!void {
        out.input = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 0));
        out.output = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1));
        out.handled_effect = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 2));
        out.added_effects = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 3));
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
        const quantifiers = try rehydrator.ctx.arena.allocator().alloc(ir.Term, dehydrated.operands.items.len - 2);
        out.quantifiers = quantifiers;
        for (0..quantifiers.len) |i| {
            quantifiers[i] = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, i));
        }

        out.qualifiers = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, quantifiers.len));
        out.payload = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, quantifiers.len + 1));
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

    pub fn dehydrate(self: *const IsSubRowConstraint, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.primary_row) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.subtype_row) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *IsSubRowConstraint) error{ BadEncoding, OutOfMemory }!void {
        out.primary_row = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 0));
        out.subtype_row = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1));
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

    pub fn dehydrate(self: *const RowsConcatenateConstraint, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.row_a) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.row_b) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.row_result) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *RowsConcatenateConstraint) error{ BadEncoding, OutOfMemory }!void {
        out.row_a = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 0));
        out.row_b = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1));
        out.row_result = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 2));
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

    pub fn dehydrate(self: *const ImplementsClassConstraint, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.data) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.class) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *ImplementsClassConstraint) error{ BadEncoding, OutOfMemory }!void {
        out.data = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 0));
        out.class = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1));
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

    pub fn dehydrate(self: *const IsStructureConstraint, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.data) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.row) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *IsStructureConstraint) error{ BadEncoding, OutOfMemory }!void {
        out.data = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 0));
        out.row = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1));
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

    pub fn dehydrate(self: *const IsUnionConstraint, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.data) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.row) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *IsUnionConstraint) error{ BadEncoding, OutOfMemory }!void {
        out.data = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 0));
        out.row = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1));
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

    pub fn dehydrate(self: *const IsSumConstraint, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Operand)) error{ BadEncoding, OutOfMemory }!void {
        try out.appendSlice(dehydrator.sma.allocator, &.{
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.data) },
            ir.Sma.Operand{ .kind = .term, .value = try dehydrator.dehydrateTerm(self.row) },
        });
    }

    pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *IsSumConstraint) error{ BadEncoding, OutOfMemory }!void {
        out.data = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 0));
        out.row = try rehydrator.rehydrateTerm(try dehydrated.getOperandOf(.term, 1));
    }
};
