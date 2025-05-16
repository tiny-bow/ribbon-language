//! # ir
//! This namespace provides a mid-level SSA/Sea of Nodes hybrid Intermediate Representation (ir) for Ribbon.
//!
//! It is used to represent the program in a way that is easy to optimize and transform.
//!
//! This ir targets:
//! * rvm's `core` bytecode (via the `bytecode` module)
//! * native machine code, in two ways:
//!    + in house x64 jit (the `machine` module)
//!    + freestanding (eventually; via llvm, likely)
const ir = @This();

const std = @import("std");
const log = std.log.scoped(.Rir);

const pl = @import("platform");
const common = @import("common");
const Interner = @import("Interner");
const analysis = @import("analysis");
const Source = analysis.source;

test {
    std.testing.refAllDeclsRecursive(@This());
}

pub fn Id(comptime T: type) type {
    return common.Id.ofSize(T, 32);
}

pub fn Table(comptime T: type) type {
    return common.Id.Table(T, 32);
}

/// Builtins that are, or can be thought of as, compiled to primitive instructions.
pub const Intrinsic = enum(u8) { // TODO: expand mnemonics to instructions; maybe just generate this def?
// Memory
    mem_set,
    mem_copy,
    mem_swap,
// Bitwise
    bit_swap,
    bit_copy,
    bit_clz,
    bit_pop,
    bit_not,
    bit_and,
    bit_or,
    bit_xor,
    bit_lshift,
    bit_rshift,
// Comparison
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
// Integer arithmetic
    i_neg,
    i_abs,
    i_add,
    i_sub,
    i_mul,
    i_div,
    i_rem,
    i_pow,
// Floating point arithmetic
    f_neg,
    f_abs,
    f_sqrt,
    f_floor,
    f_ceil,
    f_round,
    f_trunc,
    f_whole,
    f_frac,
    f_add,
    f_sub,
    f_mul,
    f_div,
    f_rem,
    f_pow,
// Value conversion
    s_ext,
    f_to_i,
    i_to_f,
    f_to_f,
};

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

/// Type kinds refer to the general category of a type, be it data, function, etc.
/// This provides a high-level discriminator for locations where values of a type can be used or stored.
pub const Kind = struct {
    id: Id(@This()),
    /// note that tag alone is not a full discriminator of a kind; see `inputs` for more information.
    tag: Tag = .data,
    /// if this kind is an arrow, such as `data -> effect`,
    /// the tag will be `effect`, representing the head of the arrow,
    /// and the inputs here are the tail of the arrow, in the example holding one value, `data`.
    inputs: Id(KeySet) = .null,

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
    inputs: Id(KeySet) = .null,
};

/// Binds a set of effect handler signatures, forming an effect,
/// which can be referenced by functions and types anywhere in the graph.
pub const Effect = struct {
    id: Id(@This()),
    /// types handlers bound for this effect must conform to
    handler_signatures: Id(KeySet),
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
    inputs: Id(KeySet) = .null,
};

/// Binds a function type to an entry point instruction to form a function that can be called anywhere in the graph.
pub const Function = struct {
    id: Id(@This()),
    /// the type of this function
    type: Id(Type) = .null,
    /// the function's entry block
    entry: Id(Block) = .null,
};

/// Binds a set of effect handlers to a set of operands, forming a dynamic scope in which the bound handlers
/// are used to handle the effects they bind.
pub const DynamicScope = struct {
    id: Id(@This()),
    /// the parameters for the handler set; upvalue bindings
    inputs: Id(KeySet) = .null,
    /// the handlers bound by this dynamic scope to handle effects within it
    handler_set: Id(KeySet) = .null,
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
    variables: Id(KeySet) = .null,
    /// dynamic scope for this block, if any
    dynamic_scope: Id(DynamicScope) = .null,
    /// the instructions belonging to this block
    instructions: Id(KeySet) = .null,
};

/// Edges encode the control and data flow of the graph.
pub const Edge = struct {
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
    /// the type of this edge; either control or data.
    transfer: Transfer = .control,

    pub const Transfer = enum(u8) {
        /// The edge is a control flow edge.
        control,
        /// The edge is a data flow edge.
        data,
    };
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
pub const KeySet = struct {
    id: Id(@This()),
    /// the keys in this key set
    keys: pl.ArrayList(Key) = .empty,

    pub fn deinit(self: *KeySet, allocator: std.mem.Allocator) void {
        self.keys.deinit(allocator);
    }
};

/// The general reference type for the ir graph.
pub const Key = packed struct(u64) {
    /// discriminator for the `id`.
    tag: Tag,
    id: Id(anyopaque),

    /// The invalid key; null.
    pub const none = Key {
        .tag = .none,
        .id = .null,
    };

    /// Discriminator for the type of id carried by a `Key`.
    pub const Tag: type = enum(i32) { // must be 32 for abi-aligned packing with 32-bit id
        null = std.math.minInt(i32),
        none = 0,
        name = 1,
        kind = 2,
        constructor = 3,
        type = 4,
        effect = 5,
        constant = 6,
        global = 7,
        foreign_address = 8,
        builtin_address = 9,
        handler = 10,
        function = 11,
        block = 12,
        dynamic_scope = 13,
        instruction = 14,
        buffer = 15,
        keyset = 16,
        _,
    };
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
        string_to_name: pl.StringArrayMap(Id(Name)) = .empty,
        /// Binds keys to names, allowing the generation of symbol tables.
        name: pl.UniqueReprBiMap(Key, Id(Name), .bucket) = .empty,
        /// Maps keys to sets of names that have been used to refer to them in the source code,
        /// but that are not used for symbol resolution. Intended for various debugging purposes.
        /// For example, certain instructions may be given a name to make the ir output more readable.
        alias: pl.UniqueReprBiMap(Key, Id(KeySet), .bucket) = .empty,
        /// Maps keys to sets of sources that have contributed to their definition;
        /// for debugging purposes.
        origin: pl.UniqueReprBiMap(Key, Id(KeySet), .bucket) = .empty,
    } = .{},

    table: struct {
        constructor: Table(Constructor) = .{},
        type: Table(Type) = .{},
        constant: Table(Constant) = .{},
        global: Table(Global) = .{},
        function: Table(Function) = .{},
        handler: Table(Handler) = .{},
        instruction: Table(Instruction) = .{},
        foreign_address: Table(ForeignAddress) = .{},
        builtin_address: Table(BuiltinAddress) = .{},
        effect: Table(Effect) = .{},
        handler_set: Table(DynamicScope) = .{},
        buffer: Table(DynamicScope) = .{},
        key_set: Table(KeySet) = .{},
    } = .{},

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
            try @field(self.table, table_name).ensureCapacity(allocator, capacity);
        }

        return self;
    }

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
};
