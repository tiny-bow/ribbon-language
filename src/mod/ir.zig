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
const analysis = @import("analysis");

test {
    std.testing.refAllDeclsRecursive(@This());
}

pub fn Id(comptime T: type) type {
    return common.Id.ofSize(T, 32);
}

pub fn Table(comptime T: type) type {
    return struct {
        const Self = @This();

        data: pl.MultiArrayList(T) = .empty,

        fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !Self {
            var self = Self.empty;

            try self.data.ensureTotalCapacity(allocator, capacity);
            errdefer self.data.deinit(allocator);

            return self;
        }

        fn ensureCapacity(self: *Self, allocator: std.mem.Allocator, capacity: usize) !void {
            try self.data.ensureUnusedCapacity(allocator, capacity);
        }

        fn deinitData(self: *Self, allocator: std.mem.Allocator) void {
            if (comptime pl.hasDecl(T, .deinit)) {
                for (0..self.data.len) |i| {
                    var a = self.data.get(i);
                    a.deinit(allocator);
                }
            }

            self.data.len = 0;
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.deinitData(allocator);
            self.data.deinit(allocator);
        }

        fn clear(self: *Self) void {
            self.data.clearRetainingCapacity();
        }

        pub fn column(self: *Self, comptime name: std.meta.FieldEnum(T)) []const std.meta.FieldType(T, name) {
            return self.data.items(name);
        }

        pub fn cell(self: *Self, id: Id(T), comptime name: std.meta.FieldEnum(T)) *const std.meta.FieldType(T, name) {
            return &self.data.items(name)[id.toInt()];
        }

        pub fn getRow(self: *Self, id: Id(T)) ?T {
            if (id == .null) return null;

            return self.data.get(id.toInt());
        }

        pub fn addRow(self: *Self, allocator: std.mem.Allocator, data: T) !Id(T) {
            const id = Id(T).fromInt(self.data.len);

            try self.data.append(allocator, data);

            return id;
        }
    };
}

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
    /// in the event a local variable is referenced as a value,
    /// it will have the type `Local`, which is of this kind.
    /// Size is known, can be used for comparisons.
    local: void,
    /// in the event a type is referenced as a value, it will have the type `Type`,
    /// which is in turn, of this kind.
    /// Size is known, can be used for comparisons.
    type: Id(Constructor),
};

pub const Constructor = struct {
    id: Id(Constructor),
    /// the type kind this type constructor produces as a result
    output: Kind,
    /// the type kinds this type constructor expects as operands
    inputs: pl.ArrayList(Kind) = .empty,

    fn deinit(self: *Constructor, allocator: std.mem.Allocator) void {
        self.inputs.deinit(allocator);
    }
};

pub const Type = struct {
    id: Id(Type),
    /// the type constructor for this type
    constructor: Id(Constructor),
    /// computed at construction
    kind: Kind,
    /// type parameters for the type constructor
    operands: pl.ArrayList(TypeParameter) = .empty,

    fn deinit(self: *Type, allocator: std.mem.Allocator) void {
        self.operands.deinit(allocator);
    }
};

pub const TypeParameter = union(enum) {
    type: Id(Type),
    constant: Id(Constant),
};

pub const Constant = struct {
    id: Id(Constant),
    /// the type of this constant
    type: Id(Type),
    /// the value of this constant
    value: []const u8,

    fn deinit(self: *Constant, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }
};

pub const Global = struct {
    id: Id(Global),
    /// the type of this global
    type: Id(Type),
    /// optional constant-value initializer for this global
    initializer: Id(Constant) = .null,
};

pub const Function = struct {
    id: Id(Function),
    /// the type of this function
    type: Id(Type),
    /// the function's entry block
    entry: Id(Block) = .null,
    /// all the blocks in this function
    blocks: pl.ArrayList(Block) = .empty,
    /// all block->block edges in this function
    edges: pl.ArrayList(BlockEdge) = .empty,
    /// all the instructions in this function's blocks
    instructions: pl.ArrayList(Instruction) = .empty,

    fn deinit(self: *Function, allocator: std.mem.Allocator) void {
        for (self.blocks.items) |block| block.deinit(allocator);
        for (self.edges.items) |edge| edge.deinit(allocator);
        for (self.instructions.items) |instruction| instruction.deinit(allocator);

        self.blocks.deinit(allocator);
        self.edges.deinit(allocator);
        self.instructions.deinit(allocator);
    }
};

pub const Input = struct {
    id: Id(Input),
    /// the type expected for this block operand
    type: Id(Type),
};

pub const Block = struct {
    id: Id(Block),
    /// the block operand's types
    inputs: pl.ArrayList(Input) = .empty,
    /// the instructions belonging to this block
    instructions: pl.ArrayList(Id(Instruction)) = .empty,
    /// the way this block terminates
    termination: ?Termination = null,
    /// handler set for this block, if any
    handler_set: Id(HandlerSet) = .null,

    fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        self.inputs.deinit(allocator);
        self.instructions.deinit(allocator);
    }
};

pub const BlockEdge = struct {
    /// the block to which this edge points, if any
    destination: Id(Block),
    /// parameters for the termination such as the condition for a conditional branch
    inputs: pl.ArrayList(Operand) = .empty,
    /// parameters for the destination block
    outputs: pl.ArrayList(Operand) = .empty,

    fn deinit(self: *BlockEdge, allocator: std.mem.Allocator) void {
        self.inputs.deinit(allocator);
        self.outputs.deinit(allocator);
    }
};

pub const HandlerSet = struct {
    id: Id(HandlerSet),
    /// cancellation type for this handler set, if allowed
    cancellation_type: Id(Type),
    /// the parameters for the handler set; upvalue bindings
    inputs: pl.ArrayList(Operand) = .empty,
    /// the handlers implementing this handler set
    handlers: pl.ArrayList(Id(Handler)) = .empty,

    /// maximum number of handlers a handler set can have
    pub const max_handlers = 1024;

    fn deinit(self: *HandlerSet, allocator: std.mem.Allocator) void {
        self.inputs.deinit(allocator);
        self.handlers.deinit(allocator);
    }
};

pub const Handler = struct {
    id: Id(Handler),
    /// the block implementing this handler
    block: Id(Block),
    /// the effect handled by this handler
    handled_effect_type: Id(Type),
    /// the function that implements this handler
    function: Id(Function),
    /// the cancellation type for this handler, if allowed. must match the type bound by handler set
    cancellation_type: Id(Type) = .null,
    /// the parameters for the handler; upvalue bindings. must match the values bound by handler set
    inputs: pl.ArrayList(Input) = .empty,

    fn deinit(self: *Handler, allocator: std.mem.Allocator) void {
        self.inputs.deinit(allocator);
    }
};

pub const Instruction = struct {
    id: Id(Instruction),
    /// type of this instruction
    /// * computed value
    type: Id(Type) = .null,
    /// the instruction's operation
    operation: Operation = .nop,
    /// the instruction's operands
    operands: pl.ArrayList(Operand) = .empty,

    fn deinit(self: *Instruction, allocator: std.mem.Allocator) void {
        self.operands.deinit(allocator);
    }
};

pub const Operand = union(enum) {
    constant: Id(Constant),
    instruction: Id(Instruction),
    input: Id(Input),
    block: Id(Block),
};

pub const ForeignAddress = struct {
    id: Id(ForeignAddress),
    /// the address of the foreign value
    address: u64,
    /// the type of the foreign value
    type: Id(Type),
};

pub const BuiltinAddress = struct {
    id: Id(BuiltinAddress),
    /// the address of the builtin value
    address: u64,
    /// the type of the builtin value
    type: Id(Type),
};

pub const Effect = struct {
    id: Id(Effect),
    /// types handlers bound for this effect must conform to
    handler_signatures: pl.ArrayList(Id(Type)),

    fn deinit(self: *Effect, allocator: std.mem.Allocator) void {
        self.handler_signatures.deinit(allocator);
    }
};

/// Optional metadata for ir objects.
pub const Meta = struct {
    id: Id(Meta),
    /// debug and/or symbol resolution name depending on context
    name: Id(Name) = .null,
    /// the location in the original source code that initiated the creation of this object
    source: Id(Source) = .null,

    pub const Key = packed struct(u128) {
        tag: Tag,
        data: Data,

        pub const Tag: type = pl.FieldEnumOfSize(Data, 32);

        pub const Data = packed union {
            builtin_address: Id(BuiltinAddress),
            constant: Id(Constant),
            constructor: Id(Constructor),
            foreign_address: Id(ForeignAddress),
            function: Id(Function),
            global: Id(Global),
            handler_set: Id(HandlerSet),
            handler: Id(Handler),
            type: Id(Type),
            effect: Id(Effect),
            block: packed struct {f: Id(Function), b: Id(Block)},
            input: packed struct {f: Id(Function), b: Id(Block), i: Id(Input)},
            instruction: packed struct {f: Id(Function), i: Id(Instruction)},
            termination: packed struct {f: Id(Function)},
        };
    };

};

pub const Name = struct {
    id: Id(Name),
    // all the names of this object, globally
    aliases: pl.ArrayList([]const u8) = .empty,

    fn deinit(self: *Name, allocator: std.mem.Allocator) void {
        self.aliases.deinit(allocator);
    }
};

pub const Source = struct {
    id: Id(Source),
    aliases: pl.ArrayList(analysis.Source) = .empty,

    fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        self.aliases.deinit(allocator);
    }
};

pub const Graph = struct {
    allocator: std.mem.Allocator,

    map: struct {
        meta: pl.UniqueReprMap(Meta.Key, Id(Meta), 80) = .{},
        name: pl.StringArrayMap(Id(Name)) = .{},
        source: analysis.SourceMap(Id(Source)) = .{},

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.name.deinit(allocator);
            self.meta.deinit(allocator);
            self.source.deinit(allocator);
        }
    } = .{},

    table: struct {
        meta: Table(Meta) = .{},
        name: Table(Name) = .{},
        source: Table(Source) = .{},
        builtin_address: Table(BuiltinAddress) = .{},
        constant: Table(Constant) = .{},
        constructor: Table(Constructor) = .{},
        foreign_address: Table(ForeignAddress) = .{},
        function: Table(Function) = .{},
        global: Table(Global) = .{},
        handler_set: Table(HandlerSet) = .{},
        handler: Table(Handler) = .{},
        type: Table(Type) = .{},
        effect: Table(Effect) = .{},

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.name.deinit(allocator);
            self.meta.deinit(allocator);
            self.builtin_address.deinit(allocator);
            self.constant.deinit(allocator);
            self.constructor.deinit(allocator);
            self.foreign_address.deinit(allocator);
            self.function.deinit(allocator);
            self.global.deinit(allocator);
            self.handler_set.deinit(allocator);
            self.handler.deinit(allocator);
            self.type.deinit(allocator);
            self.effect.deinit(allocator);
        }
    } = .{},

    pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !*Graph {
        const self = try allocator.create(Graph);
        errdefer allocator.destroy(self);

        self.* = Graph { .allocator = allocator };

        try self.map.name.ensureUnusedCapacity(allocator, capacity);
        errdefer self.map.name.deinit(allocator);

        try self.map.meta.ensureUnusedCapacity(allocator, @intCast(capacity));
        errdefer self.map.meta.deinit(allocator);

        try self.table.name.ensureCapacity(allocator, capacity);
        errdefer self.table.name.deinit(allocator);

        try self.table.meta.ensureCapacity(allocator, capacity);
        errdefer self.table.meta.deinit(allocator);

        try self.table.builtin_address.ensureCapacity(allocator, capacity);
        errdefer self.table.builtin_address.deinit(allocator);

        try self.table.constant.ensureCapacity(allocator, capacity);
        errdefer self.table.constant.deinit(allocator);

        try self.table.constructor.ensureCapacity(allocator, capacity);
        errdefer self.table.constructor.deinit(allocator);

        try self.table.foreign_address.ensureCapacity(allocator, capacity);
        errdefer self.table.foreign_address.deinit(allocator);

        try self.table.function.ensureCapacity(allocator, capacity);
        errdefer self.table.function.deinit(allocator);

        try self.table.global.ensureCapacity(allocator, capacity);
        errdefer self.table.global.deinit(allocator);

        try self.table.handler_set.ensureCapacity(allocator, capacity);
        errdefer self.table.handler_set.deinit(allocator);

        try self.table.handler.ensureCapacity(allocator, capacity);
        errdefer self.table.handler.deinit(allocator);

        try self.table.type.ensureCapacity(allocator, capacity);
        errdefer self.table.type.deinit(allocator);

        try self.table.effect.ensureCapacity(allocator, capacity);
        errdefer self.table.effect.deinit(allocator);

        return self;
    }

    pub fn deinit(self: *Graph) void {
        self.map.deinit(self.allocator);
        self.table.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};


pub const Context = struct {
    id: Id(Context),
    /// Context can either be a root or a child; this holds state specific to each.
    mode: Mode,

    /// Contains state specific to a context type.
    pub const Mode = union(enum) {
        /// The root context, which is the top-level context for a graph.
        /// * child contexts may access the shared graph via the rw_lock. See `Context.acquireRead`, etc.
        root: struct {
            child_contexts: pl.ArrayList(*Context) = .{},
            shared_graph: *Graph,
            rw_lock: std.Thread.RwLock = .{},
        },
        /// A child context, which is a sub-context of a root context, or another child context.
        /// * care should be taken with child->child context relationships as they are not thread safe
        child: struct {
            parent_context: *Context,
            local_graph: *Graph,
        },
    };

    pub fn init(graph: *Graph) !*Context {
        const self = try graph.allocator.create(Context);
        errdefer graph.allocator.destroy(self);

        self.* = Context{
            .id = Id(Context).fromInt(0),
            .mode = .{ .root = .{ .shared_graph = graph } },
        };

        return self;
    }

    pub fn fetchRoot(self: *Context) *Context {
        return switch (self.mode) {
            .root => self,
            .child => |*state| state.parent_context.fetchRoot(),
        };
    }

    pub fn acquireRead(self: *Context) void {
        switch (self.mode) {
            .root => |*state| state.rw_lock.lockShared(),
            .child => |*state| state.parent_context.acquireRead(),
        }
    }

    pub fn acquireWrite(self: *Context) void {
        switch (self.mode) {
            .root => |*state| state.rw_lock.lock(),
            .child => |*state| state.parent_context.acquireWrite(),
        }
    }

    pub fn releaseRead(self: *Context) void {
        switch (self.mode) {
            .root => |*state| state.rw_lock.unlockShared(),
            .child => |*state| state.parent_context.releaseRead(),
        }
    }

    pub fn releaseWrite(self: *Context) void {
        switch (self.mode) {
            .root => |*state| state.rw_lock.unlock(),
            .child => |*state| state.parent_context.releaseWrite(),
        }
    }

    pub fn createChildContext(self: *Context, graph: *Graph) !*Context {
        switch (self.mode) {
            .root => |*state| {
                self.acquireWrite();
                defer self.releaseWrite();

                const id = Id(Context).fromInt(state.child_contexts.items.len);

                const child = try state.shared_graph.allocator.create(Context);
                errdefer state.shared_graph.allocator.destroy(child);

                try state.child_contexts.append(state.shared_graph.allocator, child);

                child.* = Context{
                    .id = id,
                    .mode = .{ .child = .{ .parent_context = self, .local_graph = graph } },
                };

                return child;
            },
            .child => |*state| {
                const root = self.fetchRoot();

                root.acquireWrite();
                defer root.releaseWrite();

                const root_state = &root.mode.root;

                const id = Id(Context).fromInt(root.mode.root.child_contexts.items.len);

                const child = try root_state.shared_graph.allocator.create(Context);
                errdefer root_state.shared_graph.allocator.destroy(child);

                try root.mode.root.child_contexts.append(root.mode.root.shared_graph.allocator, child);

                child.* = Context{
                    .id = id,
                    .mode = .{ .child = .{ .parent_context = self, .local_graph = state.local_graph } },
                };

                return child;
            },
        }
    }
};
