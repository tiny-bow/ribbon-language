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
const Interner = @import("Interner");
const Id = @import("Id");

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
    /// optional debug name for this type constructor
    name: Id.of(Name)= .null,
};

pub const Type = struct {
    id: Id.of(Type),
    /// the type constructor for this type
    constructor: Id.of(Constructor),
    /// computed at construction
    kind: Kind,
    /// optional debug name for this type
    name: Id.of(Name)= .null,
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
    /// optional debug name for this constant
    name: Id.of(Name) = .null,
};

pub const Global = struct {
    id: Id.of(Global),
    type: Id.of(Type),
    /// debug + resolution; unnamed globals cannot be resolved through symbol tables
    name: Id.of(Name) = .null,
    /// optional constant-value initializer for this global
    init: Id.of(Constant) = .null,
};

pub const Function = struct {
    id: Id.of(Function),
    type: Id.of(Type),
    /// debug + resolution; unnamed functions cannot be resolved through symbol tables
    name: Id.of(Name) = .null,
    entry: Id.of(Block) = .null,
    blocks: pl.ArrayList(Block) = .empty,
    edges: pl.ArrayList(BlockEdge) = .empty,
};

/// marker type for id system
pub const Input = struct{};

pub const Block = struct {
    id: Id.of(Block),
    /// optional debug name for this block
    name: Id.of(Name) = .null,
    /// the block operand's types
    inputs: [max_operands] Id.of(Type) = [1]Id.of(Type){.null} ** max_operands,
    /// the instructions of this block
    instructions: pl.ArrayList(Instruction) = .empty,
    /// the destinations for this block's termination
    edges: [max_edges] ?BlockEdge = [1]?BlockEdge{null} ** max_edges,
    /// the way this block terminates
    termination: ?Termination = null,

    /// maximum number of instructions a block can have
    pub const max_instructions = std.math.maxInt(std.meta.Tag(Id.of(Instruction)));

    /// maximum number of (outbound) edges a block can have
    pub const max_edges = 2; // currently we only support cond and uncond branches
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

pub const BlockEdge = struct {
    /// the block to which this edge points, if any
    destination: Id.of(Block),
    /// parameters for the termination such as the condition for a conditional branch
    inputs: [max_operands] ?Operand = [1]?Operand{null} ** max_operands,
    /// parameters for the destination block
    outputs: [max_operands] ?Operand = [1]?Operand{null} ** max_operands,
};

pub const Instruction = struct {
    id: Id.of(Instruction),
    /// optional debug name for this instruction
    name: Id.of(Name),
    /// type of this instruction
    /// * computed at construction
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

pub const Module = struct {
    id: Id.of(Module),
    /// debug + resolution; unnamed modules and their elements cannot be resolved through symbol tables
    name: Id.of(Name) = .null,
    /// global variables belonging to this module
    globals: pl.ArrayList(Id.of(Global)) = .empty,
    /// functions belonging to this module
    functions: pl.ArrayList(Id.of(Function)) = .empty,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    names: NameTable = .{},
    constructors: Id.Table(Constructor) = .empty,
    types: Id.Table(Type) = .empty,
    constants: Id.Table(Constant) = .empty,
    globals: Id.Table(Global) = .empty,
    functions: Id.Table(Function) = .empty,
    modules: Id.Table(Module) = .empty,
};

pub const Context = struct {
    id: Id.of(Context),
    data: Data = .uninit,

    pub const Data = union(enum) {
        uninit: void,
        root: struct {
            mutex: std.Thread.Mutex = .{},
            child_contexts: Id.Table(Context) = .empty,
            shared_graph: *Graph,
        },
        child: struct {
            parent_context: *Context,
            local_graph: *Graph,
        },
    };
};
