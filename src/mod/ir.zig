//! # ir
//! This namespace provides a mid-level SSA/Sea of Nodes hybrid Intermediate Representation (ir) for Ribbon.
//!
//! It is used to represent the program in a way that is easy to optimize and transform.
//!
//! This ir targets:
//! * rvm's `core` bytecode (via the `bytecode` module)
//! * native machine code, in two ways:
//!    + in house x64 jit (the `machine` module)
//!    + freestanding (eventually)
const ir = @This();

const std = @import("std");
const log = std.log.scoped(.Rir);

const pl = @import("platform");
const common = @import("common");
const utils = @import("utils");
const Interner = @import("Interner");
const analysis = @import("analysis");
const bytecode = @import("bytecode");
const Source = analysis.Source;

test {
    std.testing.refAllDeclsRecursive(@This());
}

pub fn Id(comptime T: type) type {
    return common.Id.ofSize(T, 64);
}

pub fn Table(comptime T: type) type {
    return struct {
        const Self = @This();
        const Id = ir.Id(T);
        const Data = common.SlotMap.MultiArray(T, 32, 32);

        data: Data = .empty,

        pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !Self {
            return Self {
                .data = try Data.initCapacity(allocator, capacity),
            };
        }

        pub fn ensureCapacity(self: *Self, allocator: std.mem.Allocator, capacity: usize) !void {
            try self.data.ensureCapacity(allocator, capacity);
        }

        pub fn deinitData(self: *Self, allocator: std.mem.Allocator) void {
            if (comptime pl.hasDecl(T, .deinit)) {
                for (0..self.data.count()) |i| {
                    if (self.data.getIndex(@intCast(i))) |a| {
                        var x = a;
                        x.deinit(allocator);
                    }
                }
            }

            self.data.clear();
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.deinitData(allocator);
            self.data.deinit(allocator);
        }

        pub fn clear(self: *Self) void {
            self.data.clear();
        }

        pub fn rowCount(self: *Self) usize {
            return self.data.len;
        }

        pub fn getColumn(self: *Self, comptime name: std.meta.FieldEnum(T)) []std.meta.FieldType(T, name) {
            return self.data.fields(name);
        }

        fn idToRef(id: Self.Id) Data.Ref {
            const bits: u64 = @intFromEnum(id);

            return @bitCast(bits);
        }

        fn refToId(ref: Data.Ref) Self.Id {
            return @enumFromInt(@as(u64, @bitCast(ref)));
        }

        pub fn getIndex(self: *Self, id: Self.Id) ?usize {
            return if (self.data.resolveIndex(idToRef(id))) |i| i else null; // needed because i is u32 not usize
        }

        pub fn getCell(self: *Self, id: Self.Id, comptime name: std.meta.FieldEnum(T)) ?*std.meta.FieldType(T, name) {
            return self.getCellAt(self.getIndex(id) orelse return null, name);
        }

        pub fn getCellAt(self: *Self, index: usize, comptime name: std.meta.FieldEnum(T)) *std.meta.FieldType(T, name) {
            return self.data.field(index, name);
        }

        pub fn getRow(self: *Self, id: Self.Id) ?T {
            const index = self.getIndex(@bitCast(id)) orelse return null;

            return self.data.get(index);
        }

        pub fn setRow(self: *Self, id: Self.Id, value: T) !void {
            const index = self.getIndex(@bitCast(id)) orelse return error.InvalidId;

            return self.data.set(index, value);
        }

        pub fn addRow(self: *Self, allocator: std.mem.Allocator, init: anytype) !Self.Id {
            log.debug(@typeName(Self) ++ " @ {} addRow: {}", .{@intFromPtr(self), init});
            const I = @TypeOf(init);
            const ref, const index = try self.data.create(allocator);
            const id = refToId(ref);

            inline for (comptime std.meta.fields(T)) |field| {
                const field_enum = @field(std.meta.FieldEnum(T), field.name);
                if (comptime std.mem.eql(u8, field.name, "id")) {
                    self.data.field(index, field_enum).* = id;
                    continue;
                }

                self.data.field(index, field_enum).* =
                    if (comptime @hasField(I, field.name)) @field(init, field.name)
                    else if (comptime @hasField(@TypeOf(field), "default_value_ptr") and field.default_value_ptr != null) @as(*const field.type, @alignCast(@ptrCast(field.default_value_ptr.?))).*
                    else @compileError("Missing field " ++ field.name ++ " in initialization value for table entry of type " ++ @typeName(T));
            }

            return id;
        }

        pub fn delRow(self: *Self, id: Self.Id) !void {
            if (self.head.destroy(idToRef(id))) |index| {
                std.debug.assert(index < self.data.len);

                self.data.swapRemove(index);
            } else {
                return error.InvalidId;
            }
        }
    };
}

/// Designates the kind of operation, be it data manipulation or control flow, that is performed by an ir `Instruction`.
pub const Operation = enum(u8) {
    /// No operation.
    nop,

    /// Standard ssa phi node, merge values from predecessor flows. As a user of the ir api,
    /// it is typically not necessary to use this directly. It is primarily used by the optimizer to
    /// eliminate unnecessary stack allocations and allocate registers.
    /// * In-bound control edges designate the predecessors to merge from.
    /// * In-bound data edges designate the value to use in case of arrival from the associated predecessor.
    /// * The out-bound data edges are the merged values.
    phi,

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
    /// Jump to the control edge.
    unconditional_branch,
    /// Jump to the first control edge, if the data edge is non-zero. Othewrise, jump to the second control edge.
    conditional_branch,
    /// A standard function call.
    /// * The first in-bound data edge is the function to call,
    /// the rest are the arguments to the function.
    /// * The out-bound data edge is the return value of the function.
    call,
    /// An effect handler prompt.
    /// * The first in-bound data edge is the effect to prompt,
    /// the rest are the arguments to the prompt.
    /// * The out-bound data edge is the return value of the prompt.
    prompt,

    /// Get the value of a local variable.
    /// * The first in-bound data edge is the l-value of the local variable to get,
    /// the second is the value to set it to.
    /// * The out-bound data edge is the r-value of the local variable.
    get_local,
    /// Set the value of a local variable.
    /// * The first in-bound data edge is the l-value of the local variable to set,
    /// the second is the value to set it to.
    /// * No out-bound data edge.
    set_local,

    /// Extract an elemental r-value from a composite r-value.
    get_element,
    /// Set an elemental value in a composite l-value or r-value.
    set_element,

    /// Extract an elemental r-value address from a composite l-value or r-value.
    /// * Type of the instruction is the type of the element.
    /// * The first in-bound data edge is the composite value to extract from,
    /// the second is the index of the element to extract. Second edge must be constant.
    /// * The out-bound data edge is the r-value address of the element.
    /// * If the composite edge is a local variable, this will force de-optimization of the local variable in mem2reg.
    get_element_addr,

    /// Load an r-value from an r-value address.
    /// * Type of the instruction is the type of the value to load.
    /// * The in-bound data edge is the r-value address to store to.
    /// * The out-bound data edge is the loaded value.
    load,
    /// Store an r-value to an r-value address.
    /// * The first in-bound data edge is the r-value address to store to,
    /// the second is the value to store.
    /// * No out-bound data edge.
    store,

    /// Convert a value to (approximately) the same value in another representation.
    /// * Type of the instruction is the type to convert to.
    /// * The in-bound data edge is the value to convert.
    /// * The out-bound data edge is the converted value.
    convert,
    /// Convert bits to a different type, changing the meaning without changing the bits.
    /// * Type of the instruction is the type to convert to.
    /// * The in-bound data edge is the value to convert.
    /// * The out-bound data edge is the converted value.
    bitcast,
};



/// marker type for `Id`; not actually instantiated anywhere
pub const Name = struct {
    id: Id(@This()),
};

/// marker type for `Id`; not actually instantiated anywhere
pub const Alias = struct {
    id: Id(@This()),
};

pub const Origin = struct {
    id: Id(@This()),
};

/// Type kinds refer to the general category of a type, be it data, function, etc.
/// This provides a high-level discriminator for locations where values of a type can be used or stored.
pub const Kind = struct {
    id: Id(@This()),
    /// note that tag alone is not a full discriminator of a kind; see `inputs` for more information.
    tag: Tag = .data,
    /// if this kind is an arrow, such as `data -> effect`,
    /// the tag will be `effect`, representing the head of the arrow,
    /// and the inputs here are the tail of the arrow, in the example holding one value, `data`.
    inputs: Id(KeyList) = .null,

    pub const Tag = enum(u8) {
        /// Data types can be stored anywhere, passed as arguments, etc.
        /// Size is known, some can be used in arithmetic or comparisons.
        data,
        /// Opaque types cannot be values, only the destination of a pointer.
        /// Size is unknown, and they cannot be used in arithmetic or comparisons.
        @"opaque",
        /// Function types can be called, have side effects, have a return value,
        /// and can be passed as arguments (via coercion to pointer).
        /// They cannot be stored in memory, and have no size.
        function,
        /// Effect types represent a side effect that can be performed by a function.
        effect,
        /// Handler types represent a function that can handle a side effect.
        /// In addition to the other properties of functions, they have a cancel type.
        handler,
        /// No return types represent functions that do not return,
        /// and cannot be used in arithmetic or comparisons.
        /// Any use of a value of this type is undefined, as it is inherently dead code.
        noreturn,
        /// in the event an effect handler block is referenced as a value,
        /// it will have the type `Block`, which is of this kind.
        /// Size is known, can be used for comparisons.
        block,
        /// in the event a local variable is referenced as a value,
        /// it will have the type `Local`, which is of this kind.
        /// Size is known, can be used for comparisons.
        local,
        /// in the event a type is referenced as a value, it will have the type `Type`,
        /// which is in turn, of this kind.
        /// Size is known, can be used for comparisons.
        type,
    };
};

/// Defines a unique type constructor.
/// Types are defined by construction alone, so this is akin to the discriminator of a union.
/// For example, `u8` and `u16` can be represented with the constructor `int`, applied to the
/// type-level arguments `unsigned` and either `8` or `16`.
pub const Constructor = struct {
    id: Id(@This()),
    /// the kind signature of this constructor.
    kind: Id(Kind) = .null,
};

/// Combines a set of type-level arguments with a type constructor to form a concrete type that can be used in the graph.
pub const Type = struct {
    id: Id(@This()),
    /// the type constructor for this type.
    constructor: Id(Constructor) = .null,
    /// type parameters for the type constructor.
    inputs: Id(KeyList) = .null,
};

/// Binds a set of effect handler signatures, forming an effect,
/// which can be referenced by functions and types anywhere in the graph.
pub const Effect = struct {
    id: Id(@This()),
    /// types handlers bound for this effect must conform to
    handler_signatures: Id(KeyList),
};

/// Binds buffers and constant expressions to a type to form a constant value that can be used anywhere in the graph.
pub const Constant = struct {
    id: Id(@This()),
    /// the type of this constant
    type: Id(Type) = .null,
    /// the value of this constant
    data: Key = .none,
};

/// Binds a type to an optional constant to form a global variable that can be used anywhere in the graph.
pub const Global = struct {
    id: Id(@This()),
    /// the type of this global
    type: Id(Type) = .null,
    /// optional constant-value initializer for this global
    initializer: Id(Constant) = .null,
};

/// Binds a type to a compile-time defined address.
/// These are used for foreign-abi calls and variable bindings, and can be referenced anywhere in the graph.
pub const ForeignAddress = struct {
    id: Id(@This()),
    /// the address of the foreign value
    address: u64,
    /// the type of the foreign value
    type: Id(Type),
};

/// Binds a type to a compile-time defined address.
/// These are used for interpreter calls and variable bindings, and can be referenced anywhere in the graph.
pub const BuiltinAddress = struct {
    id: Id(@This()),
    /// the address of the builtin value
    address: u64,
    /// the type of the builtin value
    type: Id(Type),
};

/// Builtins that are, or can be thought of as, compiled to primitive instructions,
/// and can be used throughout the graph as functions.
pub const Intrinsic = struct {
    id: Id(@This()),
    /// The kind of intrinsic this is.
    tag: Tag,
    /// The actual value of the intrinsic.
    data: Data,

    pub const Tag = enum(u8) {
        bytecode,
        _,
    };

    pub const Data = packed union {
        /// Embedding the bytecode opcode directly is super convenient because we can
        /// use this to represent instructions that are not semantically significant to
        /// analysis, such as simple addition etc; and then also to represent selected
        /// instructions during the lowering process.
        bytecode: bytecode.Instruction.OpCode,
        userdata: *anyopaque,
    };
};

/// Binds an effect to a special effect-handling function,
/// along with a *cancellation type* that may be used in the function,
/// and the types of any *upvalues* that may be used in the function;
/// creating an effect handler definition that may be bound in an appropriate dynamic scope,
/// anywhere in the graph.
pub const Handler = struct {
    id: Id(@This()),
    /// the type of effect that is handled by this handler
    effect: Id(Effect) = .null,
    /// the function that implements this handler
    function: Id(Function) = .null,
    /// the cancellation type for this handler, if allowed. must match the type bound by DynamicScope
    cancellation_type: Id(Type) = .null,
    /// the parameters for the handler; upvalue bindings. must match the values bound by DynamicScope
    inputs: Id(KeyList) = .null,
};

/// Binds a function type to an entry point instruction to form a function that can be called anywhere in the graph.
pub const Function = struct {
    id: Id(@This()),
    /// the type of this function
    type: Id(Type) = .null,
    /// the function's entry
    entry: Key = .none,
};

/// Binds a set of effect handlers to a set of operands, forming a dynamic scope in which the bound handlers
/// are used to handle the effects they bind.
pub const DynamicScope = struct {
    id: Id(@This()),
    /// the parameters for the handler set; upvalue bindings
    inputs: Id(KeyList) = .null,
    /// the handlers bound by this dynamic scope to handle effects within it
    handler_set: Id(KeyList) = .null,
};

/// Because Ribbon is a highly expression oriented, but also systems level and side
/// effectful language, a major semantic component of the language is blocks of
/// "statements"; statements in this context simply being expressions that have
/// their results dropped, executed only for their side effects. In the source
/// language, these blocks often end with an expression that is *not* dropped, but
/// rather used as the value of the block, with the block itself "becoming" an
/// expression.
///
/// The design of the ir is motivated by a desire for a well-matched data driven
/// representation of those source level semantics, and the sea-of-nodes style
/// affords a great deal of flexibility in this regard. It happens to be the case
/// that we do not need a *basic block* at all; and instead we are free to represent
/// other relationships more significant to our domain. As a result, the `Block`
/// defined here differs quite a bit from the *basic blocks* of other irs. In fact,
/// it bears more of a resemblance to the *lexical blocks* of high-level languages
/// in that, at its core, it is an encoding of this precise slice of semantics:
///
/// > A nested sequence of instructions (notably may include control flow/loops/etc)
/// > that are run for their side effects, *except for the last*, which may also
/// > yield a single value to the greater context.
///
/// In addition, because this boundary exactly coincides with the source level
/// binding of effect handlers, we utilize the block structure to encode the
/// bindings of effect handlers. Finally, because this boundary *also* exactly
/// coincides with the source level lifetime of variables*, we also utilize the block
/// structure to encode the local variable bindings accessible within that block. In
/// combination, these last two points allow us to easily track relations between
/// local variables and effect handler "upvalues", that being our choice of term for
/// free variables within effect handlers that must be bound by local variables in
/// their enclosing scope.
///
/// * Note that in Ribbon "lifetimes" are concerned with the liveness of *memory*, not of
///   *value*; the fact the variable may only become *initialized* or have a deinit
///   function run somewhere in the middle of the block is not relevant to the
///   lifetime of the stack memory, which is what we care about in our safety analysis.
pub const Block = struct {
    id: Id(@This()),
    /// local variables bound by this block
    variables: Id(KeyList) = .null,
    /// dynamic scope for this block, if any
    dynamic_scope: Id(DynamicScope) = .null,
    /// the instructions belonging to this block
    instructions: Id(KeyList) = .null,
};

/// Edges encode the control and data flow of the graph. Data edges specifically are used to
/// represent the output of one instruction being used as the input to another instruction.
pub const DataEdge = struct {
    id: Id(@This()),
    /// the object that this edge is connected from
    source: Key = .none,
    /// the object that this edge is connected to
    destination: Key = .none,
    /// the index of this edge relative to the source;
    /// used to select an output from multi-output instructions like phi.
    source_index: usize = 0,
    /// the index of this edge relative to the destination;
    /// used to determine the order of operands in the destination.
    destination_index: usize = 0,
};

/// Edges encode the control and data flow of the graph. Control edges specifically are used to
/// represent the critical execution orderings of the graph, linking the destinations of jump instructions etc.
pub const ControlEdge = struct {
    id: Id(@This()),
    /// the object that this edge is connected from
    source: Key = .none,
    /// the object that this edge is connected to
    destination: Key = .none,
    /// the index of this edge relative to the source;
    /// designates which control edge this is; ie the true or false branch of a conditional.
    source_index: usize = 0,
};

/// Binds a type and an operation to form a single instruction in the graph.
/// Instruction relations are defined separately from the instruction itself, see `InstructionEdge`.
/// Unlike other types in the graph, instructions may not be reused anywhere in the graph;
/// relations must remain confined to constant expressions and function bodies.
pub const Instruction = struct {
    id: Id(@This()),
    /// type of this instruction
    type: Id(Type) = .null,
    /// the instruction's operation
    operation: Operation = .@"unreachable",
};

/// Binds binary data to a type; used for backing precomputed constants etc.
pub const Buffer = struct {
    id: Id(@This()),
    /// optional type information for this buffer
    type: Id(Type) = .null,
    /// the actual data of this buffer (stored in the context arena)
    data: []const u8 = &.{},

    pub fn deinit(self: *Buffer, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// The general collection type for the ir graph.
pub const KeyList = struct {
    id: Id(@This()),
    /// the keys in this key set
    keys: pl.ArrayList(Key) = .empty,

    pub fn deinit(self: *KeyList, allocator: std.mem.Allocator) void {
        self.keys.deinit(allocator);
    }
};

/// The general reference type for the ir graph.
pub const Key = packed struct(u128) {
    /// discriminator for the `id`.
    tag: Tag,
    id: Id(anyopaque),

    /// The invalid key; null.
    pub const none = Key {
        .tag = .none,
        .id = .null,
    };

    /// Discriminator for the type of id carried by a `Key`.
    pub const Tag: type = enum(i64) { // must be 32 for abi-aligned packing with 32-bit id
        null = std.math.minInt(i64),
        none = 0,
        name,
        kind,
        constructor,
        type,
        effect,
        constant,
        global,
        foreign_address,
        builtin_address,
        intrinsic,
        handler,
        function,
        dynamic_scope,
        block,
        data_edge,
        control_edge,
        instruction,
        buffer,
        key_list,
        _,

        pub fn toType(comptime self: Tag) type {
            comptime return switch (self) {
                .name => Name,
                .kind => Kind,
                .constructor => Constructor,
                .type => Type,
                .effect => Effect,
                .constant => Constant,
                .global => Global,
                .foreign_address => ForeignAddress,
                .builtin_address => BuiltinAddress,
                .intrinsic => Intrinsic,
                .handler => Handler,
                .function => Function,
                .dynamic_scope => DynamicScope,
                .block => Block,
                .data_edge => DataEdge,
                .control_edge => ControlEdge,
                .instruction => Instruction,
                .buffer => Buffer,
                .key_list => KeyList,

                else => @compileError("Invalid tag for Key: " ++ @typeName(self)),
            };
        }

        pub fn getField(self: Tag, data: anytype) @FieldType(@typeInfo(@TypeOf(data)).pointer.child, @tagName(self)) {
            return &@field(data, @tagName(self));
        }

        pub fn setField(self: Tag, data: anytype, value: @FieldType(@typeInfo(@TypeOf(data)).pointer.child, @tagName(self))) void {
            @field(data, @tagName(self)) = value;
        }

        pub fn fieldPtr(comptime self: Tag, data: anytype) *@FieldType(@typeInfo(@TypeOf(data)).pointer.child, @tagName(self)) {
            return &@field(data, @tagName(self));
        }

        pub fn toIdType(comptime self: Tag) type {
            comptime return Id(self.toType());
        }

        pub fn fromType(comptime T: type) Tag {
            comptime return switch (T) {
                ir.Name => .name,
                ir.Kind => .kind,
                ir.Constructor => .constructor,
                ir.Type => .type,
                ir.Effect => .effect,
                ir.Constant => .constant,
                ir.Global => .global,
                ir.ForeignAddress => .foreign_address,
                ir.BuiltinAddress => .builtin_address,
                ir.Intrinsic => .intrinsic,
                ir.Handler => .handler,
                ir.Function => .function,
                ir.DynamicScope => .dynamic_scope,
                ir.Block => .block,
                ir.DataEdge => .data_edge,
                ir.ControlEdge => .control_edge,
                ir.Instruction => .instruction,
                ir.Buffer => .buffer,
                ir.KeyList => .key_list,

                else => @compileError("Invalid type for Key: " ++ @typeName(T)),
            };
        }

        pub fn fromIdType(comptime T: type) Tag {
            return fromType(T.Value);
        }
    };

    pub fn fromId(id: anytype) Key {
        return Key {
            .tag = comptime Tag.fromIdType(@TypeOf(id)),
            .id = id.cast(anyopaque),
        };
    }

    pub fn toIdUnchecked(self: Key, comptime T: type) Id(T) {
        return self.id.cast(T);
    }

    pub fn toId(self: Key, comptime T: type) ?Id(T) {
        if (self.tag != comptime Tag.fromType(T)) {
            return null;
        }

        return self.id.cast(T);
    }
};

/// The core of Ribbon's intermediate representation. This is the main data
/// structure used to represent Ribbon programs in the intermediate phase of
/// compilation; ie, after the frontend has performed semantic analysis, and before
/// the backend has performed code generation. The layout of this structure is
/// designed to make it easy and efficient to traverse the graph in various ways in
/// order to perform further analysis and optimizations.
pub const Context = struct {
    /// General purpose allocator for the context; where most data is stored.
    /// Arenas are an acceptable backing, but:
    /// * Allocations will (attempt to) be grown and freed as needed
    /// * The next field is an arena allocator backed by this allocator,
    /// and freely available to api users
    gpa: std.mem.Allocator,
    /// Arena allocator (backed by `gpa`) for storing long-term data,
    /// that will not grow or free as long as the context is alive.
    ///
    /// * Users of the context may also use this allocator for their own data with context lifetimes.
    arena: std.heap.ArenaAllocator,
    /// Storage of simple relations, and the name interner.
    map: struct {
        /// Maps interned string names to their unique id.
        string_to_name: pl.StringMap(Id(Name)) = .empty,
        /// Maps interned sources to their unique id.
        source: analysis.SourceMap(Id(Source)) = .empty,
        /// Binds keys to names, allowing the generation of symbol tables.
        name: pl.UniqueReprBiMap(Key, Id(Name), .bucket) = .empty,
        /// Maps keys to sets of names that have been used to refer to them in the source code,
        /// but that are not used for symbol resolution. Intended for various debugging purposes.
        /// For example, certain instructions may be given a name to make the ir output more readable.
        alias: pl.UniqueReprBiMap(Key, Id(Alias), .bucket) = .empty,
        /// Maps keys to sets of sources that have contributed to their definition;
        /// for debugging purposes.
        origin: pl.UniqueReprBiMap(Key, Id(Origin), .bucket) = .empty,
    } = .{},
    /// Storage of standard ir graph types data.
    table: struct {
        /// Type kinds refer to the general category of a type, be it data, function, etc.
        kind: Table(Kind) = .{},
        /// Defines a unique type constructor. Types are defined by construction alone, so this is akin to the discriminator of a union.
        constructor: Table(Constructor) = .{},
        /// Combines a set of type-level arguments with a type constructor to form a concrete type that can be used in the graph.
        type: Table(Type) = .{},
        /// Binds a set of effect handler signatures, forming an effect.
        effect: Table(Effect) = .{},
        /// Binds buffers and constant expressions to a type to form a constant value.
        constant: Table(Constant) = .{},
        /// Binds a type to an optional constant initializer to form a global variable.
        global: Table(Global) = .{},
        /// Binds a type to a compile-time defined foreign-abi address.
        foreign_address: Table(ForeignAddress) = .{},
        /// Binds a type to a compile-time defined interpreter address.
        builtin_address: Table(BuiltinAddress) = .{},
        /// Builtins that are, or can be thought of as, compiled to primitive instructions,
        intrinsic: Table(Intrinsic) = .{},
        /// Binds a function to an effect type and upvalue environment to form a handler for effects.
        handler: Table(Handler) = .{},
        /// Binds a type to an entry point to form a function.
        function: Table(Function) = .{},
        /// Binds a set of effect handlers into a block, creating an effect handling context.
        dynamic_scope: Table(DynamicScope) = .{},
        /// Binds a set of instructions linearly, creating a sequential block.
        block: Table(Block) = .{},
        /// Binds an output of one instruction to the input of another, creating a data flow edge.
        data_edge: Table(DataEdge) = .{},
        /// Binds an edge between two instructions, creating explicit control flow.
        control_edge: Table(ControlEdge) = .{},
        /// All IR instruction nodes present in the graph.
        instruction: Table(Instruction) = .{},
        /// Optional type bound to raw memory buffer, for comptime known data.
        buffer: Table(Buffer) = .{},
        /// A list of keys, used for various purposes, such as operands to a node.
        key_list: Table(KeyList) = .{},

        comptime {
            const a = std.meta.fieldNames(Key.Tag);
            const b = std.meta.fieldNames(@This());
            std.debug.assert(a.len == b.len + 3);

            for (a[3..], b) |a_name, b_name| {
                std.debug.assert(std.mem.eql(u8, a_name, b_name));
            }
        }
    } = .{},

    /// Creates a new context using the given allocator.
    /// The allocator is used for all* allocations in the context, and the context will own all allocations created with this copy
    /// * includes the arena allocator within the context
    pub fn init(allocator: std.mem.Allocator) !*Context {
        const capacity = 1024;

        const self = try allocator.create(Context);
        errdefer allocator.destroy(self);

        self.* = Context {
            .gpa = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer self.deinit();

        inline for (comptime std.meta.fieldNames(@FieldType(Context, "map"))) |map_name| {
            try @field(self.map, map_name).ensureTotalCapacity(allocator, capacity);
        }

        inline for (comptime std.meta.fieldNames(@FieldType(Context, "table"))) |table_name| {
            std.debug.assert(@field(self.table, table_name).data.freelist_head == null);
            try @field(self.table, table_name).ensureCapacity(allocator, capacity);
            std.debug.assert(@field(self.table, table_name).data.freelist_head == null);
        }

        return self;
    }

    /// Deinitializes the context, freeing all memory that has since been allocated with the provided allocator.
    pub fn deinit(self: *Context) void {
        inline for (comptime std.meta.fieldNames(@FieldType(Context, "map"))) |map_name| {
            @field(self.map, map_name).deinit(self.gpa);
        }

        inline for (comptime std.meta.fieldNames(@FieldType(Context, "table"))) |table_name| {
            @field(self.table, table_name).deinit(self.gpa);
        }

        self.arena.deinit();
        self.gpa.destroy(self);
    }

    /// Get an id from a source.
    /// This will intern the source if it is not already interned.
    pub fn internSource(self: *Context, source: Source) !Id(Source) {
        const gop = try self.map.source.getOrPut(self.arena.child_allocator, source);

        if (!gop.found_existing) {
            const id: Id(Source) = @enumFromInt(self.map.source.count());

            gop.key_ptr.* = Source {
                .name = try self.arena.allocator().dupe(u8, source.name),
                .location = source.location,
            };
            gop.value_ptr.* = id;
        }

        return gop.value_ptr.*;
    }

    /// Get an id from a string name.
    /// This will intern the name if it is not already interned.
    pub fn internName(self: *Context, name: []const u8) !Id(Name) {
        const gop = try self.map.string_to_name.getOrPut(self.arena.child_allocator, name);

        if (!gop.found_existing) {
            const id: Id(Name) = @enumFromInt(self.map.string_to_name.count());

            gop.key_ptr.* = try self.arena.allocator().dupe(u8, name);
            gop.value_ptr.* = id;
        }

        return gop.value_ptr.*;
    }

    /// Get an id from a keylist.
    /// This will intern the keylist if it is not already interned.
    pub fn internKeyList(self: *Context, keys: []const Key) !Id(KeyList) {
        lists: for (self.table.key_list.getColumn(.keys), 0..) |*existing_list, list_index| {
            for (existing_list.items, 0..) |existing_key, key_index| {
                if (existing_key != keys[key_index]) {
                    continue :lists;
                }

                // found a match
                if (list_index == keys.len) {
                    return self.table.key_list.getCellAt(list_index, .id).*;
                }
            }
        }

        const id = try self.addRow(KeyList, .{});

        const array: *pl.ArrayList(Key) = self.table.key_list.getCell(id, .keys) orelse unreachable;
        try array.appendSlice(self.arena.child_allocator, keys);

        return id;
    }

    /// Get/create the alias set for a given key.
    /// This will intern the alias if it is not already interned.
    pub fn getAliasSet(self: *Context, key: Key) !Id(Alias) {
        if (self.map.alias.get_b(key)) |id| {
            return id;
        }

        const id: Id(Alias) = @enumFromInt(self.map.alias.count());

        try self.map.alias.put(self.arena.child_allocator, key, id);

        return id;
    }

    /// Get/create the origin set for a given key.
    /// This will intern the origin if it is not already interned.
    pub fn getOriginSet(self: *Context, key: Key) !Id(Origin) {
        if (self.map.origin.get_b(key)) |id| {
            return id;
        }

        const id: Id(Origin) = @enumFromInt(self.map.origin.count());

        try self.map.origin.put(self.arena.child_allocator, key, id);

        return id;
    }

    /// Bind a name to a key, creating a symbol table entry.
    /// * This will fail if the name is already bound to a different key,
    /// or if the key is already bound to a different name.
    pub fn bindName(self: *Context, name: Id(Name), key: Key) !void {
        if (self.map.name.get_a(name)) |existing| {
            log.debug("binding {} already bound to name {}", .{name, existing});
            return error.DuplicateNameBinding;
        }

        if (self.map.name.get_b(key)) |existing| {
            log.debug("binding {} already bound to name {}", .{key, existing});
            return error.DuplicateNameBinding;
        }

        try self.map.name.put(self.arena.child_allocator, key, name);
    }

    /// Get the type of a specific cell (data structure field) in a table within this context.
    /// Equivalent to `@FieldType(id.Value, @tagName(column))`.
    pub fn CellType(comptime id: type, comptime column: pl.EnumLiteral) type {
        return pl.FieldType(id.Value, column);
    }

    /// Set the value of a specific cell (data structure field) in a table within this context.
    /// For example, to set the type of a function, you would call: `ctx.setCellPtr(function_id, .type)`.
    /// * This will fail if the id is not bound.
    pub fn setCell(self: *Context, id: anytype, comptime column: pl.EnumLiteral, value: CellType(@TypeOf(id), column)) !void {
        const ptr = self.getCellPtr(id, column) orelse return error.InvalidId;
        ptr.* = value;
    }

    /// Get a copy of a specific cell (data structure field) in a table within this context.
    /// For example, to get the type of a function, you would call: `ctx.getCellPtr(function_id, .type)`.
    pub fn getCell(self: *Context, id: anytype, comptime column: pl.EnumLiteral) ?CellType(@TypeOf(id), column) {
        return (self.getCellPtr(id, column) orelse return null).*;
    }

    /// Get a pointer to a specific cell (data structure field) in a table within this context.
    /// For example, to get the type of a function, you would call: `ctx.getCellPtr(function_id, .type)`.
    pub fn getCellPtr(self: *Context, id: anytype, comptime column: pl.EnumLiteral) ?*CellType(@TypeOf(id), column) {
        const tag = comptime Key.Tag.fromIdType(@TypeOf(id));
        const key = Key.fromId(id);
        const table: *Table(@TypeOf(Id).Value) = tag.fieldPtr(&self.table);

        return table.getCell(key, column);
    }

    /// Get a copy of a specific row in the tables within this context.
    pub fn getRow(self: *Context, id: anytype) ?@TypeOf(id).Value {
        const tag = comptime Key.Tag.fromIdType(@TypeOf(id));
        const key = Key.fromId(id);
        const table: *Table(@TypeOf(Id).Value) = tag.fieldPtr(&self.table);

        return table.getRow(key);
    }

    /// Set a specific row in the tables within this context.
    /// * This will fail if the id is not bound.
    pub fn setRow(self: *Context, id: anytype, row: @TypeOf(id).Value) !void {
        const tag = comptime Key.Tag.fromIdType(@TypeOf(id));
        const key = Key.fromId(id);
        const table: *Table(@TypeOf(Id).Value) = tag.fieldPtr(&self.table);

        return table.setRow(key, row);
    }

    /// Delete a specific row in the tables within this context.
    /// * This will fail if the id is not bound.
    pub fn delRow(self: *Context, id: anytype) !void {
        const tag = comptime Key.Tag.fromIdType(@TypeOf(id));
        const key = Key.fromId(id);
        const table: *Table(@TypeOf(Id).Value) = tag.fieldPtr(&self.table);

        return table.delRow(key);
    }

    /// Add a new row to the tables within this context.
    pub fn addRow(self: *Context, comptime T: type, args: anytype) !Id(T) {
        const tag = comptime Key.Tag.fromType(T);
        const table: *Table(T) = tag.fieldPtr(&self.table);

        log.debug("adding row to table {} @{x}: {}", .{tag, @intFromPtr(table), table.*});

        const id = try table.addRow(self.arena.child_allocator, args);
        return id;
    }
};

pub fn Handle(comptime T: type) type {
    return struct {
        const Self = @This();

        id: Id(T),
        context: *Context,

        pub fn asKey(self: Self) Key {
            return Key.fromId(self.id);
        }

        pub usingnamespace switch(T) {
            Name => struct {
                pub fn init(context: *Context, name: []const u8) !Self {
                    return .{ .id = try context.internName(name), .context = context };
                }
            },

            Source => struct {
                pub fn init(context: *Context, source: Source) !Self {
                    return .{ .id = try context.internSource(source), .context = context };
                }
            },

            Alias => struct {
                pub fn init(context: *Context, bound_to: Key) !Self {
                    return .{ .id = try context.getAliasSet(bound_to), .context = context };
                }
            },

            Origin => struct {
                pub fn init(context: *Context, bound_to: Key) !Self {
                    return .{ .id = try context.getOriginSet(bound_to), .context = context };
                }
            },

            else => struct {
                pub fn init(context: *Context, args: anytype) !Self {
                    return .{ .id = try context.addRow(T, args), .context = context };
                }
            },
        };

        pub usingnamespace switch(T) {
            Name,
            Source,
            Alias,
            Origin,
            => struct {}, // these are interned types, so no need to deinit

            else => struct {
                pub fn deinit(self: Self) void {
                    self.context.delRow(self.id);
                }
            },
        };
    };
}


test {
    std.testing.log_level = .debug;

    const context = try Context.init(std.testing.allocator);
    defer context.deinit();

    const name = try Handle(Name).init(context, "test");

    const con = try Handle(Constructor).init(context, .{});

    const ty = try Handle(Type).init(context, .{
        .constructor = con.id,
    });

    try context.bindName(name.id, ty.asKey());

    std.debug.print("{}\n", .{ty});
}
