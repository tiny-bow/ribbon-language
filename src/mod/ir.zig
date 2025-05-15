//! # ir
//! This namespace provides a mid-level SSA-form Intermediate Representation (ir) for Ribbon.
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
const Id = common.Id;
const Interner = @import("Interner");
const analysis = @import("analysis");
const Source = analysis.Source;

test {
    std.testing.refAllDeclsRecursive(@This());
}


/// the maximum number of operands anything in the ir can have
pub const max_operands = 255;

pub const Name = []const u8;

pub const NameTable = struct {
    name_to_id: pl.StringArrayMap(Id.of(Name)) = .empty,
    data: pl.ArrayList(Name) = .empty,
};

/// Designates the kind of operation, be it data manipulation or control flow, that is performed by an ir `Instruction`.
pub const Operation = enum {
    /// No operation.
    nop,
    /// Indicates a breakpoint should be emitted in the output; skipped by optimizers.
    breakpoint,
    /// Indicates an undefined state; all uses may be discarded by optimizers.
    @"unreachable",
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
    /// Square context operation.
    sqrt,
    /// Convert a value to (approximately) the same value in another representation.
    convert,
    /// Convert bits to a different type, changing the meaning without changing the bits.
    bitcast,
};

pub const Termination = enum {
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
};

/// Type kinds refer to the general category of a type, be it data, function, etc.
/// This provides a high-level discriminator for locations where values of a type can be used or stored.
pub const Kind = union(enum) {
    /// Data types can be stored anywhere, passed as arguments, etc.
    /// Size is known, some can be used in arithmetic or comparisons.
    data: void,
    /// Opaque types cannot be values, only the destination of a pointer.
    /// Size is unknown, and they cannot be used in arithmetic or comparisons.
    @"opaque": void,
    /// Function types can be called, have side effects, have a return value,
    /// and can be passed as arguments (via coercion to pointer).
    /// They cannot be stored in memory, and have no size.
    function: void,
    /// Foreign addresses are pointers to external functions or data, and can be called or
    /// dereferenced, depending on type.
    foreign_address: void,
    /// Builtin addresses are pointers to host functions or data, and can be called or
    /// dereferenced, depending on type.
    builtin_address: void,
    /// Effect types represent a side effect that can be performed by a function.
    effect: void,
    /// Handler types represent a function that can handle a side effect.
    /// In addition to the other properties of functions, they have a cancel type.
    handler: void,
    /// No return types represent functions that do not return,
    /// and cannot be used in arithmetic or comparisons.
    /// Any use of a value of this type is undefined, as it is inherently dead code.
    noreturn: void,
    /// in the event an effect handler block is referenced as a value,
    /// it will have the type `Block`, which is of this kind.
    /// Size is known, can be used for comparisons.
    block: void,
    /// in the event a module is referenced as a value, it will have the type `Module`,
    /// which is of this kind.
    /// Size is known, can be used for comparisons.
    module: void,
    /// in the event a local variable is referenced as a value,
    /// it will have the type `Local`, which is of this kind.
    /// Size is known, can be used for comparisons.
    local: void,
    /// in the event a type is referenced as a value, it will have the type `Type`,
    /// which is in turn, of this kind.
    /// Size is known, can be used for comparisons.
    type: Id.of(Constructor),
};

pub const Constructor = struct {
    id: Id.of(Constructor),
    /// the type kind this type constructor produces as a result
    output: Kind,
    /// the type kinds this type constructor expects as operands
    inputs: [max_operands] ?Kind = [1]?Kind{null} ** max_operands,
};

pub const Type = struct {
    id: Id.of(Type),
    /// the type constructor for this type
    constructor: Id.of(Constructor),
    /// computed at construction
    kind: Kind,
    /// type parameters for the type constructor
    operands: [max_operands] ?TypeParameter = [1]?TypeParameter{null} ** max_operands,
};

pub const TypeParameter = union(enum) {
    type: Id.of(Type),
    constant: Id.of(Constant),
};

pub const Constant = struct {
    id: Id.of(Constant),
    type: Id.of(Type),
    value: []const u8,
};

pub const Global = struct {
    id: Id.of(Global),
    type: Id.of(Type),
    /// optional constant-value initializer for this global
    init: Id.of(Constant) = .null,
};

pub const Function = struct {
    id: Id.of(Function),
    type: Id.of(Type),
    entry: Id.of(Block) = .null,
    blocks: pl.ArrayList(Block) = .empty,
    edges: pl.ArrayList(BlockEdge) = .empty,
};

pub const Input = struct {
    type: Id.of(Type),
};

pub const Block = struct {
    id: Id.of(Block),
    /// the block operand's types
    inputs: [max_operands] ?Input = [1]?Input{null} ** max_operands,
    /// the instructions of this block
    instructions: pl.ArrayList(Instruction) = .empty,
    /// the destinations for this block's termination
    edges: [max_edges] ?BlockEdge = [1]?BlockEdge{null} ** max_edges,
    /// the way this block terminates
    termination: ?Termination = null,
    /// handler set for this block, if any
    handler_set: Id.of(HandlerSet) = .null,

    /// maximum number of instructions a block can have
    pub const max_instructions = std.math.maxInt(std.meta.Tag(Id.of(Instruction)));

    /// maximum number of (outbound) edges a block can have
    /// * currently we only support simple 2-way cond and 1-way uncond branches,
    /// in addition to an optional cancellation; totalling a max of 3 possible edges
    pub const max_edges = 3;
};

pub const BlockEdge = struct {
    /// the block to which this edge points, if any
    destination: Id.of(Block),
    /// parameters for the termination such as the condition for a conditional branch
    inputs: [max_operands] ?Operand = [1]?Operand{null} ** max_operands,
    /// parameters for the destination block
    outputs: [max_operands] ?Operand = [1]?Operand{null} ** max_operands,
};

pub const HandlerSet = struct {
    id: Id.of(HandlerSet),
    /// cancellation type for this handler set, if allowed
    cancellation_type: Id.of(Type),
    /// the parameters for the handler set; upvalue bindings
    inputs: [max_operands] ?Operand = [1]?Operand{null} ** max_operands,
    /// the handlers implementing this handler set
    handlers: [max_handlers] Id.of(Handler) = [1]Id.of(Handler){.null} ** max_handlers,

    /// maximum number of handlers a handler set can have
    pub const max_handlers = 1024;
};

pub const Handler = struct {
    id: Id.of(Handler),
    /// the block implementing this handler
    block: Id.of(Block),
    /// the effect handled by this handler
    handled_effect_type: Id.of(Type),
    /// the function that implements this handler
    function: Id.of(Function),
    /// the cancellation type for this handler, if allowed. must match the type bound by handler set
    cancellation_type: Id.of(Type) = .null,
    /// the parameters for the handler; upvalue bindings. must match the values bound by handler set
    inputs: [max_operands] ?Input = [1]?Input{null} ** max_operands,
};

pub const Instruction = struct {
    id: Id.of(Instruction),
    /// type of this instruction
    /// * computed value
    type: Id.of(Type) = .null,
    /// the instruction's operation
    operation: Operation = .nop,
    /// the instruction's operands
    operands: [max_operands] ?Operand = [1]?Operand{null} ** max_operands,
};

pub const Operand = union(enum) {
    constant: Id.of(Constant),
    instruction: Id.of(Instruction),
    input: Id.of(Input),
    block: Id.of(Block),
};

pub const ForeignAddress = struct {
    id: Id.of(ForeignAddress),
    /// the address of the foreign value
    address: u64,
    /// the type of the foreign value
    type: Id.of(Type),
};

pub const BuiltinAddress = struct {
    id: Id.of(BuiltinAddress),
    /// the address of the builtin value
    address: u64,
    /// the type of the builtin value
    type: Id.of(Type),
};

pub const MetaData = struct {
    /// debug and/or symbol resolution name depending on context
    name: Id.of(Name) = .null,
    /// the location in the original source code that initiated the creation of this object
    source: ?Source = null,
};

pub const MetaDataTable = struct {
    map: pl.UniqueReprMap(Key, MetaData, 80) = .empty,

    pub const Key = packed struct {
        tag: enum(u7) {
            builtin_address,
            constant,
            constructor,
            foreign_address,
            function,
            global,
            handler_set,
            handler,
            name,
            type,
            block,
            input,
            instruction,
            termination,
        },
        data: packed union {
            builtin_address: Id.of(BuiltinAddress),
            constant: Id.of(Constant),
            constructor: Id.of(Constructor),
            foreign_address: Id.of(ForeignAddress),
            function: Id.of(Function),
            global: Id.of(Global),
            handler_set: Id.of(HandlerSet),
            handler: Id.of(Handler),
            name: Id.of(Name),
            type: Id.of(Type),
            block: packed struct {f: Id.of(Function), b: Id.of(Block)},
            input: packed struct {f: Id.of(Function), b: Id.of(Block), i: Id.of(Input)},
            instruction: packed struct {f: Id.of(Function), b: Id.of(Block), i: Id.of(Instruction)},
            termination: packed struct {f: Id.of(Function), b: Id.of(Block)},
        },
    };
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    names: NameTable = .{},
    meta_data: MetaDataTable = .{},

    builtin_addresses: Id.Table(BuiltinAddress) = .empty,
    constants: Id.Table(Constant) = .empty,
    constructors: Id.Table(Constructor) = .empty,
    foreign_addresses: Id.Table(ForeignAddress) = .empty,
    functions: Id.Table(Function) = .empty,
    globals: Id.Table(Global) = .empty,
    handler_sets: Id.Table(HandlerSet) = .empty,
    handlers: Id.Table(Handler) = .empty,
    types: Id.Table(Type) = .empty,
};

pub const Context = struct {
    id: Id.of(Context),
    data: Data = .uninit,

    pub const Data = union(enum) {
        uninit: void,
        root: struct {
            child_contexts: Id.Table(Context) = .empty,
            shared_graph: *Graph,
        },
        child: struct {
            parent_context: *Context,
            local_graph: *Graph,
        },
    };
};
