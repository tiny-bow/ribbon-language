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
const source = @import("source");
const bytecode = @import("bytecode");

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

        pub fn getIdFromIndex(self: *Self, index: u32) Self.Id {
            const slot_index = self.data.__valueToSlot(index).*;

            return refToId(Data.Ref {
                .index = slot_index,
                .generation = self.data.__generation(index).*,
            });
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

            inline for (comptime std.meta.fieldNames(I)) |input_field| {
                if (comptime !@hasField(T, input_field)) {
                    @compileError(std.fmt.comptimePrint("Invalid initialization argument {s} for row of type {s}, valid fields are: {s}",
                        .{input_field, @typeName(T), std.meta.fieldNames(T)}));
                }
            }

            return id;
        }

        pub fn delRow(self: *Self, id: Self.Id) void {
            self.data.destroy(idToRef(id));
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

/// Data table row types for the ir.
pub const rows = struct {
    /// marker type for `Id`; not actually instantiated anywhere, string map is used instead
    pub const Name = struct {
        id: Id(@This()),
    };

    /// marker type for `Id`; not actually instantiated anywhere, keylist is used instead
    pub const Origin = struct {
        id: Id(@This()),
    };

    /// marker type for `Id`; not actually instantiated anywhere, keylist is used instead
    pub const KindList = struct {
        id: Id(@This()),
    };

    /// marker type for `Id`; not actually instantiated anywhere, keylist is used instead
    pub const TypeList = struct {
        id: Id(@This()),
    };

    /// marker type for `Id`; not actually instantiated anywhere, keylist is used instead
    pub const VariableList = struct {
        id: Id(@This()),
    };

    /// marker type for `Id`; not actually instantiated anywhere, keylist is used instead
    pub const HandlerList = struct {
        id: Id(@This()),
    };

    /// Simple wrapper binding an identity to a type, for variables and other inputs.
    pub const Variable = struct {
        id: Id(@This()),
        type: Id(rows.Type) = .null,
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
        inputs: Id(rows.KeyList) = .null,

        pub const Tag = enum(u8) {
            /// Data types can be stored anywhere, passed as arguments, etc.
            /// Size is known, some can be used in arithmetic or comparisons.
            data,
            /// Integer types can be stored anywhere, passed as arguments, etc.
            /// Size is known, some can be used in arithmetic or comparisons.
            /// Unlike other data, integers may be used in type expressions.
            int,
            /// Symbol types can be stored anywhere, passed as arguments, etc.
            /// Size is known, can be used for comparisons.
            /// Unlike other data, symbols may be used in type expressions.
            sym,
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
            /// in the event a set of types is required, this is how it is encoded.
            type_set,
        };
    };

    /// Defines a unique type constructor.
    /// Types are defined by construction alone, so this is akin to the discriminator of a union.
    /// For example, `u8` and `u16` can be represented with the constructor `int`, applied to the
    /// type-level arguments `unsigned` and either `8` or `16`.
    pub const Constructor = struct {
        id: Id(@This()),
        /// the kind signature of this constructor.
        kind: Id(rows.Kind) = .null,
    };

    /// Combines a set of type-level arguments with a type constructor to form a concrete type that can be used in the graph.
    pub const Type = struct {
        id: Id(@This()),
        /// the type constructor for this type.
        constructor: Id(rows.Constructor) = .null,
        /// type parameters for the type constructor.
        inputs: Id(rows.KeyList) = .null,
    };

    /// Binds a set of effect handler signatures, forming an effect,
    /// which can be referenced by functions and types anywhere in the graph.
    pub const Effect = struct {
        id: Id(@This()),
        /// types handlers bound for this effect must conform to
        handler_list: Id(rows.HandlerList),
    };

    /// Binds buffers and constant expressions to a type to form a constant value that can be used anywhere in the graph.
    pub const Constant = struct {
        id: Id(@This()),
        /// the type of this constant
        type: Id(rows.Type) = .null,
        /// the value of this constant
        data: Key = .none,
    };

    /// Binds a type to an optional constant to form a global variable that can be used anywhere in the graph.
    pub const Global = struct {
        id: Id(@This()),
        /// the type of this global
        type: Id(rows.Type) = .null,
        /// optional constant-value initializer for this global
        initializer: Id(rows.Constant) = .null,
    };

    /// Binds a type to a compile-time defined address.
    /// These are used for foreign-abi calls and variable bindings, and can be referenced anywhere in the graph.
    pub const ForeignAddress = struct {
        id: Id(@This()),
        /// the address of the foreign value
        address: u64,
        /// the type of the foreign value
        type: Id(rows.Type),
    };

    /// Binds a type to a compile-time defined address.
    /// These are used for interpreter calls and variable bindings, and can be referenced anywhere in the graph.
    pub const BuiltinAddress = struct {
        id: Id(@This()),
        /// the address of the builtin value
        address: u64,
        /// the type of the builtin value
        type: Id(rows.Type),
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
        effect: Id(rows.Effect) = .null,
        /// the function that implements this handler
        function: Id(rows.Function) = .null,
        /// the cancellation type for this handler, if allowed. must match the type bound by DynamicScope
        cancellation_type: Id(rows.Type) = .null,
        /// the parameters for the handler; upvalue bindings. must match the inputs bound by DynamicScope
        upvalues: Id(rows.KeyList) = .null,
    };

    /// Binds a type to a block to form a function that can be called anywhere in the graph.
    pub const Function = struct {
        id: Id(@This()),
        /// the type of this function
        type: Id(rows.Type) = .null,
        /// the function's entry block
        body: Id(rows.Block) = .null,
    };

    /// Binds a set of effect handlers to a set of operands, forming a dynamic scope in which the bound handlers
    /// are used to handle the effects they bind.
    pub const DynamicScope = struct {
        id: Id(@This()),
        /// the parameters for the handler set; upvalue bindings
        inputs: Id(rows.KeyList) = .null,
        /// the handlers bound by this dynamic scope to handle effects within it
        handler_list: Id(rows.HandlerList) = .null,
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
        variables: Id(rows.VariableList) = .null,
        /// dynamic scope for this block, if any
        dynamic_scope: Id(rows.DynamicScope) = .null,
        /// the instructions and blocks belonging to this block, in order of execution
        contents: Id(rows.KeyList) = .null,
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
        type: Id(rows.Type) = .null,
        /// the instruction's operation
        operation: Operation = .@"unreachable",
    };

    /// Binds binary data to a type; used for backing precomputed constants etc.
    pub const Buffer = struct {
        id: Id(@This()),
        /// optional type information for this buffer
        type: Id(rows.Type) = .null,
        /// the actual data of this buffer (stored in the context arena)
        data: []const u8 = &.{},

        pub fn deinit(self: *rows.Buffer, allocator: std.mem.Allocator) void {
            if (self.data.ptr != @as([]const u8, &.{}).ptr) return;

            allocator.free(self.data);
        }
    };

    /// The general collection type for the ir graph.
    pub const KeyList = struct {
        id: Id(@This()),
        /// the keys in this key set
        keys: pl.ArrayList(Key) = .empty,

        pub fn deinit(self: *rows.KeyList, allocator: std.mem.Allocator) void {
            self.keys.deinit(allocator);
        }
    };
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
        untyped = std.math.minInt(i64),
        none = 0,
        name,
        source,
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
        variable,
        data_edge,
        control_edge,
        instruction,
        buffer,
        key_list,
        _,

        pub fn toRowType(comptime self: Tag) type {
            comptime return switch (self) {
                .name => rows.Name,
                .source => source.Source,
                .kind => rows.Kind,
                .constructor => rows.Constructor,
                .type => rows.Type,
                .effect => rows.Effect,
                .constant => rows.Constant,
                .global => rows.Global,
                .foreign_address => rows.ForeignAddress,
                .builtin_address => rows.BuiltinAddress,
                .intrinsic => rows.Intrinsic,
                .handler => rows.Handler,
                .function => rows.Function,
                .dynamic_scope => rows.DynamicScope,
                .block => rows.Block,
                .data_edge => rows.DataEdge,
                .control_edge => rows.ControlEdge,
                .instruction => rows.Instruction,
                .buffer => rows.Buffer,
                .variable => rows.Variable,
                .key_list => rows.KeyList,

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

        pub fn fromIdType(comptime T: type) Tag {
            return fromRowType(T.Value);
        }

        pub fn fromRowType(comptime T: type) Tag {
            comptime return switch (T) {
                rows.Name => .name,
                source.Source => .source,
                rows.Kind => .kind,
                rows.Constructor => .constructor,
                rows.Type => .type,
                rows.Effect => .effect,
                rows.Constant => .constant,
                rows.Global => .global,
                rows.ForeignAddress => .foreign_address,
                rows.BuiltinAddress => .builtin_address,
                rows.Intrinsic => .intrinsic,
                rows.Handler => .handler,
                rows.Function => .function,
                rows.DynamicScope => .dynamic_scope,
                rows.Block => .block,
                rows.Variable => .variable,
                rows.DataEdge => .data_edge,
                rows.ControlEdge => .control_edge,
                rows.Instruction => .instruction,
                rows.Buffer => .buffer,
                rows.KeyList => .key_list,
                rows.Origin,
                rows.KindList,
                rows.TypeList,
                rows.VariableList,
                rows.HandlerList,
                => .key_list,

                else => @compileError("Invalid type for Key: " ++ @typeName(T)),
            };
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
        if (self.tag != comptime Tag.fromRowType(T)) {
            return null;
        }

        return self.id.cast(T);
    }

    pub const KeyFormatter = struct {
        key: Key,
        context: *Context,

        pub fn format(self: KeyFormatter, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            switch (self.key.tag) {
                .name => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(rows.Name)) }),
                .source => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(source.Source)) }),
                .kind => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(rows.Kind)) }),
                .constructor => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(rows.Constructor)) }),
                .type => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(rows.Type)) }),
                .function => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(rows.Function)) }),
                .effect => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(rows.Effect)) }),
                .constant => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(rows.Constant)) }),
                .global => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(rows.Global)) }),
                .foreign_address => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(rows.ForeignAddress)) }),
                .builtin_address => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(rows.BuiltinAddress)) }),
                .intrinsic => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(rows.Intrinsic)) }),
                .handler => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(rows.Handler)) }),
                .dynamic_scope => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(rows.DynamicScope)) }),
                .block => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(rows.Block)) }),
                .data_edge => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(rows.DataEdge)) }),
                .control_edge => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(rows.ControlEdge)) }),
                .instruction => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(rows.Instruction)) }),
                .buffer => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(rows.Buffer)) }),
                .key_list => try writer.print("{}", .{ wrapId(self.context, self.key.toIdUnchecked(rows.KeyList)) }),
                else => try writer.print("{}", .{ self.key }),
            }
        }
    };

    pub fn formatter(self: Key, context: *Context) KeyFormatter {
        return KeyFormatter {
            .key = self,
            .context = context,
        };
    }
};


/// Get the type of a specific cell (data structure field) in a table within this context.
/// Equivalent to `@FieldType(id.Value, @tagName(column))`.
pub fn RowType(comptime id: type) type {
    return Key.Tag.fromIdType(id).toRowType();
}

/// Get the type of a specific cell (data structure field) in a table within this context.
/// Equivalent to `@FieldType(id.Value, @tagName(column))`.
pub fn CellType(comptime id: type, comptime column: pl.EnumLiteral) type {
    return pl.FieldType(RowType(id), column);
}

/// Identifier for built-in values.
pub const Builtin = enum {
    data_kind,
    effect_kind,
    int_kind,
    sym_kind,
    function_kind,
    function_constructor,
    product_constructor,
    int_constructor,
    sym_constructor,
    signed_integer_constructor,
    unsigned_integer_constructor,
    no_effect_type,
};

pub fn BuiltinType(comptime builtin: Builtin) type {
    return WrappedId(BuiltinId(builtin));
}

pub fn BuiltinId(comptime builtin: Builtin) type {
    return Id(BuiltinRowType(builtin));
}

pub fn BuiltinRowType(comptime builtin: Builtin) type {
    return switch (builtin) {
        .data_kind => rows.Kind,
        .effect_kind => rows.Kind,
        .int_kind => rows.Kind,
        .sym_kind => rows.Kind,
        .function_kind => rows.Kind,
        .function_constructor => rows.Constructor,
        .product_constructor => rows.Constructor,
        .int_constructor => rows.Constructor,
        .sym_constructor => rows.Constructor,
        .signed_integer_constructor => rows.Constructor,
        .unsigned_integer_constructor => rows.Constructor,
        .no_effect_type => rows.Type,
    };
}

pub const builtin_initializers = struct {
    pub fn data_kind(context: *Context) !Key {
        const kind = try Kind.intern(context, .data, &.{});

        return kind.getKey();
    }

    pub fn effect_kind(context: *Context) !Key {
        const kind = try Kind.intern(context, .effect, &.{});

        return kind.getKey();
    }

    pub fn int_kind(context: *Context) !Key {
        const kind = try Kind.intern(context, .int, &.{});

        return kind.getKey();
    }

    pub fn sym_kind(context: *Context) !Key {
        const kind = try Kind.intern(context, .sym, &.{});

        return kind.getKey();
    }

    pub fn function_kind(context: *Context) !Key {
        const data = try Kind.intern(context, .data, &.{});
        const effect = try Kind.intern(context, .effect, &.{});
        const kind = try Kind.intern(context, .function, &.{data, data, effect});

        return kind.getKey();
    }

    pub fn function_constructor(context: *Context) !Key {
        const data = try Kind.intern(context, .data, &.{});
        const effect = try Kind.intern(context, .effect, &.{});
        const kind = try Kind.intern(context, .function, &.{data, data, effect});
        const constructor = try Constructor.init(context, kind);

        const key = constructor.getKey();

        try context.bindFormatter(key, &struct {
            pub fn format_function_type(ctx: *Context, value: Key, writer: std.io.AnyWriter) anyerror!void {
                const function_type: Type = wrapId(ctx, value.toIdUnchecked(rows.Type));
                if (function_type.getInputTypeSlice()) |types| {
                    try writer.print("({?} -> {?} in {?})", .{
                        if (types[0].toId(rows.Type)) |id| wrapId(ctx, id) else null,
                        if (types[1].toId(rows.Type)) |id| wrapId(ctx, id) else null,
                        if (types[2].toId(rows.Type)) |id| wrapId(ctx, id) else null,
                    });
                } else {
                    try writer.print("(INVALID FUNCTION TYPE {})", .{function_type});
                }
            }
        }.format_function_type);

        return key;
    }

    pub fn product_constructor(context: *Context) !Key {
        const data = try Kind.intern(context, .data, &.{});
        const type_set = try Kind.intern(context, .type_set, &.{data});
        const kind = try Kind.intern(context, .data, &.{type_set});
        const constructor = try Constructor.init(context, kind);

        return constructor.getKey();
    }

    pub fn int_constructor(context: *Context) !Key {
        const kint = try context.getBuiltin(.int_kind);
        const constructor = try Constructor.init(context, kint);
        const key = constructor.getKey();

        try context.bindFormatter(key, &struct {
            pub fn format_signed_integer_type(ctx: *Context, value: Key, writer: std.io.AnyWriter) anyerror!void {
                const ty: Type = wrapId(ctx, value.toIdUnchecked(rows.Type));

                if (ty.getInputTypeSlice()) |ts| {
                    const operand = ts[0];

                    try writer.print("{}", .{operand});
                } else {
                    try writer.print("(INVALID INT TYPE {})", .{ty});
                }
            }
        }.format_signed_integer_type);

        return key;
    }

    pub fn signed_integer_constructor(context: *Context) !Key {
        const int = try Kind.intern(context, .int, &.{});
        const kind = try Kind.intern(context, .data, &.{int});
        const constructor = try Constructor.init(context, kind);
        const key = constructor.getKey();

        try context.bindFormatter(key, &struct {
            pub fn format_signed_integer_type(ctx: *Context, value: Key, writer: std.io.AnyWriter) anyerror!void {
                const ty: Type = wrapId(ctx, value.toIdUnchecked(rows.Type));

                if (ty.getInputTypeSlice()) |ts| {
                    const operand = ts[0];

                    try writer.print("(Int {})", .{operand});
                } else {
                    try writer.print("(INVALID SIGNED INTEGER TYPE {})", .{ty});
                }
            }
        }.format_signed_integer_type);

        return key;
    }

    pub fn unsigned_integer_constructor(context: *Context) !Key {
        const int = try Kind.intern(context, .int, &.{});
        const kind = try Kind.create(context, .data, &.{int});
        const constructor = try Constructor.init(context, kind);
        const key = constructor.getKey();

        try context.bindFormatter(key, &struct {
            pub fn format_unsigned_integer_type(ctx: *Context, value: Key, writer: std.io.AnyWriter) anyerror!void {
                const ty: Type = wrapId(ctx, value.toIdUnchecked(rows.Type));

                if (ty.getInputTypeSlice()) |ts| {
                    const operand = ts[0];

                    try writer.print("(Word {})", .{operand});
                } else {
                    try writer.print("(INVALID UNSIGNED INTEGER TYPE {})", .{ty});
                }
            }
        }.format_unsigned_integer_type);

        return key;
    }

    pub fn no_effect_type(context: *Context) !Key {
        const kind = try Kind.intern(context, .effect, &.{});
        const con = try Constructor.init(context, kind);
        const ty = try Type.intern(context, con, &.{});

        return ty.getKey();
    }
};

pub const FormatFunction = fn (ctx: *Context, value: Key, writer: std.io.AnyWriter) anyerror!void;

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
        name_storage: pl.UniqueReprStringBiMap(Id(rows.Name), .bucket) = .empty,
        /// Maps interned sources to their unique id.
        source_storage: source.UniqueReprSourceBiMap(Id(source.Source), .bucket) = .empty,
        /// Binds keys to names, allowing the generation of debug information.
        key_to_name: pl.UniqueReprMap(Key, Id(rows.Name), 80) = .empty,
        /// binds names to keys, allowing the generation of symbol tables.
        name_to_key: pl.UniqueReprMap(Id(rows.Name), Key, 80) = .empty,
        /// Maps keys to sets of sources that have contributed to their definition;
        /// for debugging purposes.
        origin: pl.UniqueReprBiMap(Key, Id(rows.Origin), .bucket) = .empty,
        /// Maps keys to pl.Mutability values, indicating whether or not they can be mutated.
        /// This is used for various purposes, such as determining whether or not a value can be destroyed.
        mutability: pl.UniqueReprMap(Key, pl.Mutability, 80) = .empty,
        /// Builtin values.
        builtin: pl.UniqueReprBiMap(Builtin, Key, .bucket) = .empty,
        /// Intrinsic value bindings.
        intrinsic: pl.UniqueReprBiMap(bytecode.Instruction.OpCode, Id(rows.Intrinsic), .bucket) = .empty,
        /// Formatting functions for values by key.
        /// The key passed to the function is the key of the value to format; depending on the kind of formatter,
        /// the binding key may be different. For example, in the case of types, the binding key is the type constructor,
        /// and the key passed to the function is a type using that constructor.
        formatter: pl.UniqueReprMap(Key, *const anyopaque, 80) = .empty,
    } = .{},
    /// Storage of standard ir graph types data.
    table: struct {
        /// Type kinds refer to the general category of a type, be it data, function, etc.
        kind: Table(rows.Kind) = .{},
        /// Defines a unique type constructor. Types are defined by construction alone, so this is akin to the discriminator of a union.
        constructor: Table(rows.Constructor) = .{},
        /// Combines a set of type-level arguments with a type constructor to form a concrete type that can be used in the graph.
        type: Table(rows.Type) = .{},
        /// Binds a set of effect handler signatures, forming an effect.
        effect: Table(rows.Effect) = .{},
        /// Binds buffers and constant expressions to a type to form a constant value.
        constant: Table(rows.Constant) = .{},
        /// Binds a type to an optional constant initializer to form a global variable.
        global: Table(rows.Global) = .{},
        /// Binds a type to a compile-time defined foreign-abi address.
        foreign_address: Table(rows.ForeignAddress) = .{},
        /// Binds a type to a compile-time defined interpreter address.
        builtin_address: Table(rows.BuiltinAddress) = .{},
        /// Builtins that are, or can be thought of as, compiled to primitive instructions,
        intrinsic: Table(rows.Intrinsic) = .{},
        /// Binds a function to an effect type and upvalue environment to form a handler for effects.
        handler: Table(rows.Handler) = .{},
        /// Binds a type to an entry point to form a function.
        function: Table(rows.Function) = .{},
        /// Binds a set of effect handlers into a block, creating an effect handling context.
        dynamic_scope: Table(rows.DynamicScope) = .{},
        /// Binds a set of instructions linearly, creating a sequential block.
        block: Table(rows.Block) = .{},
        /// Value -> type bindings for various structures in the ir.
        variable: Table(rows.Variable) = .{},
        /// Binds an output of one instruction to the input of another, creating a data flow edge.
        data_edge: Table(rows.DataEdge) = .{},
        /// Binds an edge between two instructions, creating explicit control flow.
        control_edge: Table(rows.ControlEdge) = .{},
        /// All IR instruction nodes present in the graph.
        instruction: Table(rows.Instruction) = .{},
        /// Optional type bound to raw memory buffer, for comptime known data.
        buffer: Table(rows.Buffer) = .{},
        /// A list of keys, used for various purposes, such as operands to a node.
        key_list: Table(rows.KeyList) = .{},

        comptime {
            const a = std.meta.fieldNames(Key.Tag);
            const b = std.meta.fieldNames(@This());
            if(a.len != b.len + 4) {
                @compileError(std.fmt.comptimePrint("Key and table field names do not match: {} {s} vs {} {s}", .{a.len, a, b.len, b}));
            }

            for (a[4..], b) |a_name, b_name| {
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

    pub fn isConstant(self: *Context, id: anytype) bool {
        return (self.map.mutability.get(Key.fromId(id.cast(RowType(@TypeOf(id))))) orelse return false) == .constant;
    }

    pub fn isMutable(self: *Context, id: anytype) bool {
        return (self.map.mutability.get(Key.fromId(id.cast(RowType(@TypeOf(id))))) orelse return false) == .mutable;
    }

    pub fn setMutability(self: *Context, id: anytype, mutability: pl.Mutability) !void {
        const key = Key.fromId(id.cast(RowType(@TypeOf(id))));
        if (self.map.mutability.get(key)) |existing| {
            if (existing == mutability) return;
            log.debug("mutability of {} already set to {}", .{key, existing});
            return error.InvalidGraphState;
        }

        try self.map.mutability.put(self.arena.child_allocator, key, mutability);
    }

    pub fn makeConstant(self: *Context, id: anytype) !void {
        const key = Key.fromId(id.cast(RowType(@TypeOf(id))));
        if (self.map.mutability.get(key)) |existing| {
            if (existing == .constant) return;
        } else {
            return error.InvalidGraphState;
        }

        try self.map.mutability.put(self.arena.child_allocator, key, .constant);
    }

    /// Get an id from a source.
    /// This will intern the source if it is not already interned.
    pub fn internSource(self: *Context, src: source.Source) !Id(source.Source) {
        if (self.map.source_storage.get_b(src)) |id| return id;

        const id: Id(source.Source) = @enumFromInt(self.map.source_storage.count());
        const source_copy = try src.dupe(self.arena.allocator());
        try self.map.source_storage.put(self.arena.child_allocator, source_copy, id);

        return id;
    }

    /// Get an id from a string name.
    /// This will intern the name if it is not already interned.
    pub fn internName(self: *Context, name: []const u8) !Id(rows.Name) {
        if (self.map.name_storage.get_b(name)) |id| return id;

        const id: Id(rows.Name) = @enumFromInt(self.map.name_storage.count());
        const name_copy = try self.arena.allocator().dupe(u8, name);
        try self.map.name_storage.put(self.arena.child_allocator, name_copy, id);

        return id;
    }

    pub fn internOpCode(self: *Context, opcode: bytecode.Instruction.OpCode) !Id(rows.Intrinsic) {
        if (self.map.intrinsic.get_b(opcode)) |existing| {
            return existing;
        }

        const id = try self.addRow(rows.Intrinsic, .constant, .{ .tag = .bytecode, .data = rows.Intrinsic.Data { .bytecode = opcode } });

        try self.map.intrinsic.put(self.arena.child_allocator, opcode, id);

        return id;
    }

    /// Get an id from a keylist.
    /// This will intern the keylist if it is not already interned.
    pub fn internKeyList(self: *Context, keys: []const Key) !Id(rows.KeyList) {
        lists: for (self.table.key_list.getColumn(.keys), 0..) |*existing_list, list_index| {
            if (self.isMutable(self.table.key_list.getIdFromIndex(@intCast(list_index)))
            or existing_list.items.len != keys.len) {
                continue :lists;
            }

            for (existing_list.items, keys) |existing_key, new_key| {
                if (existing_key != new_key) continue :lists;
            }

            // found a match

            if (list_index == keys.len) {
                return self.table.key_list.getCellAt(list_index, .id).*;
            }
        }

        const id = try self.addRow(rows.KeyList, .constant , .{});

        const array: *pl.ArrayList(Key) = self.table.key_list.getCell(id, .keys) orelse unreachable;
        try array.appendSlice(self.arena.child_allocator, keys);

        return id;
    }

    /// Get an id from a keylist.
    /// This will create a new keylist even if a matching one already exists.
    pub fn createKeyList(self: *Context, keys: []const Key) !Id(rows.KeyList) {
        const id = try self.addRow(rows.KeyList, .mutable, .{});

        const array: *pl.ArrayList(Key) = self.table.key_list.getCell(id, .keys) orelse unreachable;
        try array.appendSlice(self.arena.child_allocator, keys);

        return id;
    }

    /// Bind a name to a key, creating a symbol table entry.
    /// * This will fail if the name is already bound to a different key,
    /// or if the key is already bound to a different name.
    pub fn bindSymbolName(self: *Context, name: Id(rows.Name), key: Key) !void {
        try self.map.name_to_key.put(self.arena.child_allocator, name, key);
        try self.map.key_to_name.put(self.arena.child_allocator, key, name);
    }

    /// Bind a key to a name, allowing the generation of debug information.
    /// * overrides any existing binding for the key; does not clobber symbol-table entry.
    pub fn bindDebugName(self: *Context, name: Id(rows.Name), id: anytype) !void {
        try self.map.key_to_name.put(self.arena.child_allocator, Key.fromId(id), name);
    }

    /// Bind an origin to a key.
    /// * This will fail if the origin is already bound to a different key,
    /// or if the key is already bound to a different origin.
    pub fn bindOrigin(self: *Context, origin: Id(rows.Origin), key: Key) !void {
        if (self.map.origin.get_a(origin)) |existing| {
            log.debug("binding {} already bound to origin {}", .{origin, existing});
            return error.DuplicateNameBinding;
        }

        if (self.map.origin.get_b(key)) |existing| {
            log.debug("binding {} already bound to origin {}", .{key, existing});
            return error.DuplicateNameBinding;
        }

        try self.map.origin.put(self.arena.child_allocator, key, origin);
    }

    /// Bind a formatting function to a key.
    pub fn bindFormatter(self: *Context, key: Key, function: *const FormatFunction) !void {
        try self.map.formatter.put(self.arena.child_allocator, key, function);
    }

    /// Get the last name bound to a key, if any.
    pub fn getName(self: *Context, id: anytype) ?Name {
        return wrapId(self, self.map.key_to_name.get(Key.fromId(id.cast(RowType(@TypeOf(id))))) orelse return null);
    }

    /// Get the source set bound to a key, if it exists.
    pub fn getOrigin(self: *Context, id: anytype) ?Origin {
        return wrapId(self, self.map.origin.get_b(Key.fromId(id.cast(RowType(@TypeOf(id))))) orelse return null);
    }

    /// Get the formatter bound to a key, if it exists.
    pub fn getFormatter(self: *Context, id: anytype) ?*const FormatFunction {
        return @ptrCast(self.map.formatter.get(Key.fromId(id.cast(RowType(@TypeOf(id))))) orelse return null);
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
        const table = tag.fieldPtr(&self.table);

        return @ptrCast(table.getCell(id.cast(RowType(@TypeOf(id))), column));
    }

    /// Get a copy of a specific row in the tables within this context.
    pub fn getRow(self: *Context, id: anytype) ?RowType(@TypeOf(id)) {
        const tag = comptime Key.Tag.fromIdType(@TypeOf(id));
        const key = Key.fromId(id);
        const table = tag.fieldPtr(&self.table);

        return table.getRow(key);
    }

    /// Set a specific row in the tables within this context.
    /// * This will fail if the id is not bound.
    pub fn setRow(self: *Context, id: anytype, row: @TypeOf(id).Value) !void {
        const tag = comptime Key.Tag.fromIdType(@TypeOf(id));
        const table = tag.fieldPtr(&self.table);

        return table.setRow(id.cast(RowType(@TypeOf(id))), row);
    }

    /// Delete a specific row in the tables within this context.
    pub fn delRow(self: *Context, id: anytype) void {
        std.debug.assert(!self.isConstant(id));

        const tag = comptime Key.Tag.fromIdType(@TypeOf(id));
        const table = tag.fieldPtr(&self.table);

        table.delRow(id.cast(RowType(@TypeOf(id))));
    }

    /// Add a new row to the tables within this context.
    pub fn addRow(self: *Context, comptime Row: type, mutability: pl.Mutability, args: anytype) !Id(Row) {
        const tag = comptime Key.Tag.fromRowType(Row);
        const table = tag.fieldPtr(&self.table);

        log.debug("adding {s} row to table {} @{x}: {}", .{@tagName(mutability), tag, @intFromPtr(table), table.*});

        const id = try table.addRow(self.arena.child_allocator, args);
        errdefer table.delRow(id);

        try self.setMutability(id, mutability);

        return id.cast(Row);
    }

    pub fn getBuiltin(self: *Context, comptime id: Builtin) !BuiltinType(id) {
        const IdT = @FieldType(BuiltinType(id), "id");
        const Row = IdT.Value;

        if (self.map.builtin.get_b(id)) |existing| {
            return wrapId(self, existing.toIdUnchecked(Row));
        }

        const key = try @field(builtin_initializers, @tagName(id))(self);

        try self.map.builtin.put(self.arena.child_allocator, id, key);

        return wrapId(self, key.toIdUnchecked(Row));
    }

    pub fn isBuiltin(self: *Context, id: anytype) bool {
        return self.getBuiltinIdentity(id.getRef()) != null;
    }

    pub fn getBuiltinIdentity(self: *Context, id: Key) ?Builtin {
        return self.map.builtin.get_a(id);
    }
};

pub inline fn WrappedId(comptime T: type) type {
    return switch (T.Value) {
        rows.Name => Name,
        source.Source => Source,
        rows.Kind => Kind,
        rows.Constructor => Constructor,
        rows.Type => Type,
        rows.KeyList => KeyList,
        rows.Origin => Origin,
        rows.KindList => KindList,
        rows.TypeList  => TypeList,
        rows.HandlerList  => HandlerList,
        rows.VariableList  => VariableList,
        rows.Effect => Effect,
        rows.Constant => Constant,
        rows.Global => Global,
        rows.ForeignAddress => ForeignAddress,
        rows.BuiltinAddress => BuiltinAddress,
        rows.Intrinsic => Intrinsic,
        rows.Handler => Handler,
        rows.Function => Function,
        rows.DynamicScope => DynamicScope,
        rows.Block => Block,
        rows.Variable => Variable,
        rows.Buffer => Buffer,
        rows.DataEdge => DataEdge,
        rows.ControlEdge => ControlEdge,
        rows.Instruction => Instruction,
        else => @compileError("Invalid type for WrappedId: " ++ @typeName(T)),
    };
}

pub fn wrapId(context: *Context, id: anytype) WrappedId(@TypeOf(id)) {
    return .{ .context = context, .id = id };
}

pub fn HandleBase(comptime Self: type) type {
    return struct {
        const Mixin = @This();

        const Id = @FieldType(Self, "id");
        const Row = Mixin.Id.Value;

        pub fn getKey(self: Self) Key {
            return Key.fromId(self.id);
        }

        pub fn isMutable(self: Self) bool {
            return self.context.isMutable(self.id);
        }

        pub fn isConstant(self: Self) bool {
            return self.context.isConstant(self.id);
        }

        pub fn getName(self: Self) ?Name {
            return self.context.getName(self.id);
        }
    };
}

pub fn KeyListBase(comptime Self: type, comptime T: type) type {
    return struct {
        const Mixin = @This();

        const Id = @FieldType(Self, "id");
        const Row = Mixin.Id.Value;
        const ValueId = ir.Id(T);
        const Value = WrappedId(ValueId);

        pub fn create(context: *Context, values: []const Value) !Self {
            const temp = try context.arena.allocator().alloc(Key, values.len);
            defer context.arena.allocator().free(temp);

            for (values, 0..) |value, index| {
                temp[index] = Key.fromId(value.id);
            }

            const id = try context.createKeyList(temp);

            return wrapId(context, id.cast(Row));
        }

        pub fn init(context: *Context) !Self {
            const id = try context.createKeyList(&.{});
            return wrapId(context, id.cast(Row));
        }

        pub fn deinit(self: Self) void {
            self.context.delRow(self.id);
        }

        pub fn getCount(self: Self) usize {
            return (self.getSlice() orelse return 0).len;
        }

        pub fn getMutSlice(self: Self) ?[]Key {
            return (self.getMutArrayList() orelse return null).items;
        }

        pub fn getMutArrayList(self: Self) ?*pl.ArrayList(Key) {
            std.debug.assert(!self.context.isConstant(self.id));
            return self.context.getCellPtr(self.id.cast(rows.KeyList), .keys);
        }

        pub fn getSlice(self: Self) ?[]const Key {
            return (self.getArrayList() orelse return null).items;
        }

        pub fn getArrayList(self: Self) ?*const pl.ArrayList(Key) {
            return self.context.getCellPtr(self.id.cast(rows.KeyList), .keys);
        }

        pub fn append(self: Self, value: Value) !void {
            const array = self.getMutArrayList() orelse return error.InvalidGraphState;
            try array.append(self.context.arena.child_allocator, Key.fromId(value.id));
        }

        pub fn format(self: Self, comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
            try wrapId(self.context, self.id.cast(rows.KeyList)).format(fmt, opts, writer);
        }
    };
}

pub const KeyList = struct {
    id: Id(rows.KeyList),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn create(context: *Context, keys: []const Key) !KeyList {
        const id = try context.createKeyList(keys);
        return KeyList{ .id = id, .context = context };
    }

    pub fn init(context: *Context) !KeyList {
        const id = try context.createKeyList(&.{});
        return KeyList{ .id = id, .context = context };
    }

    pub fn deinit(self: KeyList) void {
        self.context.delRow(self.id);
    }

    pub fn cast(self: KeyList, comptime Narrow: type) Narrow {
        return wrapId(self.context, self.id.cast(@FieldType(Narrow, "id").Value));
    }

    pub fn getCount(self: KeyList) usize {
        return (self.getSlice() orelse return 0).len;
    }

    pub fn getSlice(self: KeyList) ?[]Key {
        return (self.getArrayList() orelse return null).items;
    }

    pub fn getArrayList(self: KeyList) ?*pl.ArrayList(Key) {
        return self.context.getCellPtr(self.id.cast(rows.KeyList), .keys);
    }

    pub fn append(self: KeyList, key: Key) !void {
        const array = self.getArrayList() orelse return error.InvalidGraphState;
        try array.append(self.context.arena.child_allocator, key);
    }

    pub fn format(self: KeyList, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.getSlice()) |keys| {
            try writer.writeAll("[");

            for (keys, 0..) |key, index| {
                if (index != 0) try writer.writeAll(", ");

                try writer.print("{}", .{key.formatter(self.context)});
            }

            try writer.writeAll("]");
        } else {
            try writer.writeAll("[]");
        }
    }
};

pub const Name = struct {
    id: Id(rows.Name),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn intern(context: *Context, name: []const u8) !Name {
        const id = try context.internName(name);
        return Name{ .id = id, .context = context };
    }

    pub fn getText(self: Name) ![]const u8 {
        return self.context.map.name_storage.get_a(self.id) orelse return error.InvalidGraphState;
    }

    pub fn getSymbolBinding(self: Name) !Key {
        return self.context.map.name_to_key.get(self.id) orelse return error.InvalidGraphState;
    }

    pub fn bindSymbol(self: Name, value: anytype) !void {
        try self.context.bindSymbolName(self.id, Key.fromId(value.id));
    }

    pub fn bindDebug(self: Name, value: anytype) !void {
        try self.context.bindDebugName(self.id, Key.fromId(value.id));
    }

    pub fn format(self: Name, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll(try self.getText());
    }
};

pub const Source = struct {
    id: Id(source.Source),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn intern(context: *Context, src: source.Source) !Source {
        const id = try context.internSource(src);
        return Source{ .id = id, .context = context };
    }

    pub fn getData(self: Source) !source.Source {
        return self.context.map.source_storage.get_a(self.id) orelse return error.InvalidGraphState;
    }

    pub fn format(self: Source, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}", .{try self.getData()});
    }
};


pub const Origin = struct {
    id: Id(rows.Origin),
    context: *Context,

    pub usingnamespace HandleBase(@This());
    pub usingnamespace KeyListBase(@This(), source.Source);

    pub fn bindValue(self: Origin, value: anytype) !void {
        try self.context.bindOrigin(self.id, Key.fromId(value.id));
    }
};

pub const HandlerList = struct {
    id: Id(rows.HandlerList),
    context: *Context,

    pub usingnamespace HandleBase(@This());
    pub usingnamespace KeyListBase(@This(), rows.Handler);
};

pub const KindList = struct {
    id: Id(rows.KindList),
    context: *Context,

    pub usingnamespace HandleBase(@This());
    pub usingnamespace KeyListBase(@This(), rows.Kind);

    pub fn intern(context: *Context, kinds: []const Kind) !KindList {
        const temp = try context.arena.allocator().alloc(Key, kinds.len);
        defer context.arena.allocator().free(temp);

        for (kinds, 0..) |kind, index| {
            temp[index] = Key.fromId(kind.id);
        }

        const id = try context.internKeyList(temp);
        return KindList { .id = id.cast(rows.KindList), .context = context };
    }
};

pub const TypeList = struct {
    id: Id(rows.TypeList),
    context: *Context,

    pub usingnamespace HandleBase(@This());
    pub usingnamespace KeyListBase(@This(), rows.Type);

    pub fn intern(context: *Context, types: []const Type) !TypeList {
        const temp = try context.arena.allocator().alloc(Key, types.len);
        defer context.arena.allocator().free(temp);

        for (types, 0..) |ty, index| {
            temp[index] = Key.fromId(ty.id);
        }

        const id = try context.internKeyList(temp);
        return TypeList { .id = id.cast(rows.TypeList), .context = context };
    }
};

pub const VariableList = struct {
    id: Id(rows.VariableList),
    context: *Context,

    pub usingnamespace HandleBase(@This());
    pub usingnamespace KeyListBase(@This(), rows.Variable);

    pub fn intern(context: *Context, variables: []const Variable) !VariableList {
        const temp = try context.arena.allocator().alloc(Key, variables.len);
        defer context.arena.allocator().free(temp);

        for (variables, 0..) |v, index| {
            temp[index] = Key.fromId(v.id);
        }

        const id = try context.internKeyList(temp);
        return VariableList { .id = id.cast(rows.VariableList), .context = context };
    }
};

pub const Constructor = struct {
    id: Id(rows.Constructor),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn init(context: *Context, kind: Kind) !Constructor {
        const id = try context.addRow(rows.Constructor, .mutable, .{ .kind = kind.id });
        return Constructor{ .id = id, .context = context };
    }

    pub fn deinit(self: Constructor) void {
        self.context.delRow(self.id);
    }

    pub fn setKind(self: Constructor, kind: Kind) !void {
        try self.context.setCell(self.id, .kind, kind.id);
    }

    pub fn getKind(self: Constructor) ?Kind {
        return Kind {
            .id = self.context.getCell(self.id, .kind) orelse return null,
            .context = self.context,
        };
    }

    pub fn getOutputKindTag(self: Constructor) ?rows.Kind.Tag {
        return (self.getKind() orelse return null).getOutputTag();
    }

    pub fn getInputKindCount(self: Constructor) usize {
        return (self.getInputKinds() orelse return 0).getCount();
    }

    pub fn getInputKindSlice(self: Constructor) ?[]const Key {
        return (self.getInputKinds() orelse return null).getSlice();
    }

    pub fn getInputKinds(self: Constructor) ?KindList {
        return (self.getKind() orelse return null).getInputs();
    }

    pub fn format(self: Constructor, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const kind = self.getKind();
        const name = self.context.getName(self.id);

        try writer.print("(𝓬𝓸𝓷 {} {?s} :: {?})", .{self.id, name, kind});
    }
};


pub const Kind = struct {
    id: Id(rows.Kind),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn intern(context: *Context, tag: rows.Kind.Tag, inputs: []const Kind) !Kind {
        const kind_list = try KindList.intern(context, inputs);

        for (context.table.kind.getColumn(.tag), context.table.kind.getColumn(.inputs), 0..) |existing_tag, existing_inputs, index| {
            if (existing_tag == tag
            and existing_inputs == kind_list.id.cast(rows.KeyList)) {
                return Kind{ .id = context.table.kind.getIdFromIndex(@intCast(index)), .context = context };
            }
        }

        return Kind.init(context, .constant, tag, kind_list.id);
    }

    pub fn create(context: *Context, tag: rows.Kind.Tag, ids: []const Kind) !Kind {
        const kind_list = try KindList.create(context, ids);

        return Kind.init(context, .mutable, tag, kind_list.id);
    }

    pub fn init(context: *Context, mutability: pl.Mutability, tag: rows.Kind.Tag, inputs: Id(rows.KindList)) !Kind {
        const id = try context.addRow(rows.Kind, mutability, .{ .tag = tag, .inputs = inputs.cast(rows.KeyList) });
        return Kind{ .id = id, .context = context };
    }

    pub fn deinit(self: Kind) void {
        self.context.delRow(self.id);
    }

    pub fn getInputCount(self: Kind) usize {
        return (self.getInputs() orelse return 0).getCount();
    }

    pub fn getInputSlice(self: Kind) ?[]const Key {
        return (self.getInputs() orelse return null).getSlice();
    }

    pub fn setOutputTag(self: Kind, tag: rows.Kind.Tag) !void {
        try self.context.setCell(self.id, .tag, tag);
    }

    pub fn getOutputTag(self: Kind) ?rows.Kind.Tag {
        return (self.context.table.kind.getCell(self.id, .tag) orelse return null).*;
    }

    pub fn setInputs(self: Kind, inputs: Id(rows.KindList)) !void {
        try self.context.setCell(self.id, .inputs, inputs.cast(rows.KeyList));
    }

    pub fn getInputs(self: Kind) ?KindList {
        const inputs = (self.context.getCellPtr(self.id, .inputs) orelse return null).*;
        return KindList{ .id = inputs.cast(rows.KindList), .context = self.context };
    }

    pub fn format(self: Kind, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const tag = self.context.getCell(self.id, .tag);
        const inputs = self.context.getCell(self.id, .inputs);

        try writer.print("(𝓴𝓲𝓷𝓭 {?} => {?s})", .{ if (inputs) |id| wrapId(self.context, id) else null, if (tag) |t| @tagName(t) else null });
    }
};


pub const Type = struct {
    id: Id(rows.Type),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn intern(context: *Context, constructor: Constructor, inputs: []const Type) !Type {
        const type_list = try TypeList.intern(context, inputs);
        errdefer type_list.deinit();

        for (context.table.type.getColumn(.constructor), context.table.type.getColumn(.inputs), 0..) |existing_constructor, existing_inputs, index| {
            if (existing_constructor == constructor.id
            and existing_inputs == type_list.id.cast(rows.KeyList)) {
                return Type{ .id = context.table.type.getIdFromIndex(@intCast(index)), .context = context };
            }
        }

        return Type.init(context, .constant, constructor, type_list);
    }

    pub fn createInt(context: *Context, value: i256) !Type {
        const constructor = try context.getBuiltin(.int_constructor);
        const ty = try Type.init(context, .mutable, constructor, null);

        const constant = try Constant.fromUnownedBytes(context, ty, std.mem.asBytes(&value));
        const inputs = try KeyList.create(context, &.{ constant.getKey() });

        try ty.setTypeInputs(inputs.cast(TypeList));

        return ty;
    }

    pub fn createBitInteger(context: *Context, signedness: pl.Signedness, bit_size: u16) !Type {
        const int = try Type.createInt(context, bit_size);

        const cint = switch (signedness) {
            .signed => try context.getBuiltin(.signed_integer_constructor),
            .unsigned => try context.getBuiltin(.unsigned_integer_constructor),
        };

        return Type.create(context, cint, &.{ int });
    }

    pub fn createFunction(context: *Context, inputs: []const Type, result: Type, effect: Type) !Type {
        const type_list = try TypeList.create(context, inputs);
        errdefer type_list.deinit();

        const input_product = try Type.create(context, try context.getBuiltin(.product_constructor), inputs);
        errdefer input_product.deinit();

        return Type.create(context, try context.getBuiltin(.function_constructor), &.{ input_product, effect, result });
    }

    pub fn create(context: *Context, constructor: Constructor, inputs: []const Type) !Type {
        const type_list = try TypeList.create(context, inputs);
        errdefer type_list.deinit();

        return Type.init(context, .mutable, constructor, type_list);
    }

    pub fn init(context: *Context, mutability: pl.Mutability, constructor: ?Constructor, inputs: ?TypeList) !Type {
        const id = try context.addRow(rows.Type, mutability, .{ .constructor = if (constructor) |x| x.id else .null, .inputs = if (inputs) |x| x.id.cast(rows.KeyList) else .null });
        return Type{ .id = id, .context = context };
    }

    pub fn deinit(self: Type) void {
        self.context.delRow(self.id);
    }

    pub fn format(self: Type, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const constructor = self.getConstructor();

        if (constructor) |c| {
            if (self.context.getFormatter(c.id)) |formatter| {
                formatter(self.context, Key.fromId(self.id), writer) catch |err| {
                    log.err("error formatting type {}: {}", .{self.id, err});
                    return error.InvalidArgument;
                };
            } else {
                try writer.print("(𝓽𝔂𝓹𝓮 {} {?} :: {} {?})", .{ self.id, self.getName(), c, self.getTypeInputs() });
            }
        } else {
            try writer.print("(𝓽𝔂𝓹𝓮 {} {?} :: null {?})", .{ self.id, self.getName(), self.getTypeInputs() });
        }
    }

    pub fn setConstructor(self: Type, constructor: Constructor) !void {
        try self.context.setCell(self.id, .constructor, constructor.id);
    }

    pub fn getConstructor(self: Type) ?Constructor {
        const id = self.context.getCell(self.id, .constructor) orelse return null;

        return wrapId(self.context, id);
    }

    pub fn getInputTypeCount(self: Type) usize {
        return (self.getTypeInputs() orelse return 0).getCount();
    }

    pub fn getInputTypeSlice(self: Type) ?[]const Key {
        return (self.getTypeInputs() orelse return null).getSlice();
    }

    pub fn getInputTypeIndex(self: Type, index: usize) ?Type {
        const slice = self.getInputTypeSlice() orelse return null;

        if (index >= slice.len) return null;

        return wrapId(self.context, slice[index].toIdUnchecked(rows.Type));
    }

    pub fn setTypeInputs(self: Type, inputs: TypeList) !void {
        try self.context.setCell(self.id, .inputs, inputs.id.cast(rows.KeyList));
    }

    pub fn getTypeInputs(self: Type) ?TypeList {
        const inputs = self.context.getCell(self.id, .inputs) orelse return null;
        return wrapId(self.context, inputs.cast(rows.TypeList));
    }

    pub fn getConstructorKind(self: Type) ?Kind {
        const constructor = self.getConstructor() orelse return null;

        return constructor.getKind();
    }

    pub fn getConstructorOutputKindTag(self: Type) ?rows.Kind.Tag {
        return (self.getConstructorKind() orelse return null).getOutputTag();
    }

    pub fn getConstructorInputKindCount(self: Type) ?usize {
        return (self.getConstructorInputKinds() orelse return null).getCount();
    }

    pub fn getConstructorInputKindSlice(self: Type) ?[]const Key {
        return (self.getConstructorInputKinds() orelse return null).getSlice();
    }

    pub fn getConstructorInputKinds(self: Type) ?KindList {
        return (self.getConstructorKind() orelse return null).getInputs();
    }
};

pub const Effect = struct {
    id: Id(rows.Effect),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn init(context: *Context, handler_list: ?HandlerList) !Effect {
        const id = try context.addRow(rows.Effect, .mutable, .{ .handler_list = if (handler_list) |x| x.id else .null });
        return Effect{ .id = id, .context = context };
    }

    pub fn deinit(self: Effect) void {
        self.context.delRow(self.id);
    }

    pub fn getHandlerList(self: Effect) ?HandlerList {
        const id = (self.context.table.effect.getCell(self.id, .handler_list) orelse return null).*;
        return wrapId(self.context, id);
    }

    pub fn setHandlerList(self: Effect, handler_list: HandlerList) !void {
        try self.context.setCell(self.id, .handler_list, handler_list.id);
    }

    pub fn format(self: Effect, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const handler_list = (self.context.table.effect.getCell(self.id, .handler_list) orelse return error.InvalidGraphState).*;

        if (self.context.getName(self.id)) |name| {
            try writer.print("({} {} : {})", .{name, self.id, handler_list});
        } else {
            try writer.print("({} : {})", .{self.id, handler_list});
        }
    }
};

pub const Handler = struct {
    id: Id(rows.Handler),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn init(context: *Context, effect: ?Effect, function: ?Function, cancellation_type: ?Type, upvalues: ?KeyList) !Handler {
        const id = try context.addRow(rows.Handler, .mutable, .{
            .effect = if (effect) |x| x.id else .null,
            .function = if (function) |x| x.id else .null,
            .cancellation_type = if (cancellation_type) |x| x.id else .null,
            .upvalues = if (upvalues) |x| x.id else .null,
        });

        return Handler{ .id = id, .context = context };
    }

    pub fn deinit(self: Handler) void {
        self.context.delRow(self.id);
    }

    pub fn getEffect(self: Handler) ?Effect {
        const id = (self.context.table.handler.getCell(self.id, .effect) orelse return null).*;
        return wrapId(self.context, id);
    }

    pub fn setEffect(self: Handler, effect: Effect) !void {
        try self.context.setCell(self.id, .effect, effect.id);
    }

    pub fn getFunction(self: Handler) ?Function {
        const id = (self.context.table.handler.getCell(self.id, .function) orelse return null).*;
        return wrapId(self.context, id);
    }

    pub fn setFunction(self: Handler, func: Function) !void {
        try self.context.setCell(self.id, .function, func.id);
    }

    pub fn getCancellationType(self: Handler) ?Type {
        const id = (self.context.table.handler.getCell(self.id, .cancellation_type) orelse return null).*;
        return wrapId(self.context, id);
    }

    pub fn setCancellationType(self: Handler, ty: Type) !void {
        try self.context.setCell(self.id, .cancellation_type, ty.id);
    }

    pub fn getUpvalues(self: Handler) ?KeyList {
        const id = (self.context.table.handler.getCell(self.id, .upvalues) orelse return null).*;
        return wrapId(self.context, id);
    }

    pub fn setUpvalues(self: Handler, upvalues: KeyList) !void {
        try self.context.setCell(self.id, .upvalues, upvalues.id);
    }

    pub fn format(self: Handler, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const name = self.context.getName(self.id);
        const effect = self.getEffect();
        try writer.print("({} {?} : {?})", .{self.id, name, effect});
    }
};

pub const Constant = struct {
    id: Id(rows.Constant),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn fromBlock(context: *Context, ty: Type, block: Block) !Constant {
        const id = try context.addRow(rows.Constant, .mutable, .{ .type = ty.id, .data = Key.fromId(block.id) });
        return Constant{ .id = id, .context = context };
    }

    pub fn fromBuffer(context: *Context, ty: Type, buffer: Buffer) !Constant {
        const id = try context.addRow(rows.Constant, .mutable, .{ .type = ty.id, .data = Key.fromId(buffer.id) });
        return Constant{ .id = id, .context = context };
    }

    pub fn fromOwnedBytes(context: *Context, ty: Type, owned_bytes: []const u8) !Constant {
        const buffer = try Buffer.fromOwnedBytes(context, owned_bytes);
        errdefer context.delRow(buffer.id);

        return Constant.fromBuffer(context, ty, buffer);
    }

    pub fn fromUnownedBytes(context: *Context, ty: Type, bytes: []const u8) !Constant {
        const buffer = try Buffer.create(context, bytes);
        errdefer context.delRow(buffer.id);

        return Constant.fromBuffer(context, ty, buffer);
    }

    pub fn init(context: *Context) !Constant {
        const id = try context.addRow(rows.Constant, .mutable, .{ });
        return Constant{ .id = id, .context = context };
    }

    pub fn deinit(self: Constant) void {
        self.context.delRow(self.id);
    }

    pub fn getData(self: Constant) !Key {
        const key = self.context.getCell(self.id, .data) orelse return error.InvalidGraphState;
        return key;
    }

    pub fn setData(self: Constant, key: Key) !void {
        try self.context.setCell(self.id, .data, key);
    }

    pub fn format(self: Constant, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const ty = self.context.getCell(self.id, .type) orelse return error.InvalidGraphState;
        const key = self.context.getCell(self.id, .data) orelse return error.InvalidGraphState;

        switch (key.tag) {
            .none => try writer.print("(𝓬𝓸𝓷𝓼𝓽 {} = none)", .{ wrapId(self.context, ty) }),
            .block => try writer.print("(𝓬𝓸𝓷𝓼𝓽 {} = {})", .{ wrapId(self.context, ty), wrapId(self.context, key.toIdUnchecked(rows.Block)) }),
            .buffer => try writer.print("(𝓬𝓸𝓷𝓼𝓽 {} = {})", .{ wrapId(self.context, ty), wrapId(self.context, key.toIdUnchecked(rows.Buffer)) }),
            else => try writer.print("(𝓬𝓸𝓷𝓼𝓽 {} = invalid {})", .{ wrapId(self.context, ty), key }),
        }
    }
};

pub const Global = struct {
    id: Id(rows.Global),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn init(context: *Context, ty: ?Type, initializer: ?Constant) !Global {
        const id = try context.addRow(rows.Global, .mutable, .{ .type = if (ty) |x| x.id else .null, .initializer = if (initializer) |x| x.id else .null });
        return Global{ .id = id, .context = context };
    }

    pub fn deinit(self: Global) void {
        self.context.delRow(self.id);
    }

    pub fn getType(self: Global) ?Type {
        const id = self.context.getCell(self.id, .type) orelse return null;
        return wrapId(self.context, id);
    }

    pub fn setType(self: Global, ty: Type) !void {
        try self.context.setCell(self.id, .type, ty.id);
    }

    pub fn getInitializer(self: Global) ?Constant {
        const id = self.context.getCell(self.id, .initializer) orelse return null;
        return wrapId(self.context, id);
    }

    pub fn setInitializer(self: Global, initializer: Constant) !void {
        try self.context.setCell(self.id, .initializer, initializer.id);
    }

    pub fn format(self: Global, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const name = self.getName();
        const ty = self.getType();
        const initializer = self.getInitializer();

        try writer.print("(𝓰𝓵𝓸𝓫𝓪𝓵 {} {?} : {?} = {?})", .{self.id, name, ty, initializer});
    }
};

pub const ForeignAddress = struct {
    id: Id(rows.ForeignAddress),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn init(context: *Context, address: ?u64, ty: ?Type) !ForeignAddress {
        const id = try context.addRow(rows.ForeignAddress, .mutable, .{ .address = if (address) |x| x else 0, .type = if (ty) |x| x.id else .null });
        return ForeignAddress{ .id = id, .context = context };
    }

    pub fn deinit(self: ForeignAddress) void {
        self.context.delRow(self.id);
    }

    pub fn format(self: ForeignAddress, comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
        try self.id.format(fmt, opts, writer);
    }
};

pub const BuiltinAddress = struct {
    id: Id(rows.BuiltinAddress),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn init(context: *Context, address: ?u64, ty: ?Type) !BuiltinAddress {
        const id = try context.addRow(rows.BuiltinAddress, .mutable, .{ .address = if (address) |x| x else 0, .type = if (ty) |x| x.id else .null });
        return BuiltinAddress{ .id = id, .context = context };
    }

    pub fn deinit(self: BuiltinAddress) void {
        self.context.delRow(self.id);
    }

    pub fn format(self: BuiltinAddress, comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
        try self.id.format(fmt, opts, writer);
    }
};

pub const Intrinsic = struct {
    id: Id(rows.Intrinsic),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn intern(context: *Context, opcode: bytecode.Instruction.OpCode) !Intrinsic {
        const id = try context.internOpCode(opcode);
        return Intrinsic{ .id = id, .context = context };
    }

    pub fn format(self: Intrinsic, comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
        try self.id.format(fmt, opts, writer);
    }

    pub fn getOpCode(self: Intrinsic) ?bytecode.Instruction.OpCode {
        const tag = self.context.getCell(self.id, .tag) orelse return null;
        if (tag != .bytecode) return null;

        return self.context.getCell(self.id, .data).?.bytecode;
    }
};

pub const Buffer = struct {
    id: Id(rows.Buffer),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn fromOwnedBytes(context: *Context, owned_data: []const u8) !Buffer {
        const id = try context.addRow(rows.Buffer, .mutable, .{ .data = owned_data });
        return wrapId(context, id);
    }

    pub fn create(context: *Context, unowned_data: []const u8) !Buffer {
        const owned_data = try context.arena.allocator().dupe(u8, unowned_data);
        errdefer context.arena.allocator().free(owned_data);

        const id = try context.addRow(rows.Buffer, .mutable, .{ .data = owned_data });
        return wrapId(context, id);
    }

    pub fn init(context: *Context) !Buffer {
        const id = try context.addRow(rows.Buffer, .mutable, .{ });
        return wrapId(context, id);
    }

    pub fn deinit(self: Buffer) void {
        self.context.delRow(self.id);
    }

    pub fn setData(self: Buffer, data: []const u8) !void {
        return self.context.setCell(self.id, .data, data);
    }

    pub fn getData(self: Buffer) ![]const u8 {
        return self.context.getCell(self.id, .data) orelse error.InvalidGraphState;
    }

    pub fn format(self: Buffer, comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
        try self.id.format(fmt, opts, writer);
    }
};

pub const Function = struct {
    id: Id(rows.Function),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn create(context: *Context, ty: Type) !Function {
        const builtin_func_con = try context.getBuiltin(.function_constructor);
        const builtin_product_con = try context.getBuiltin(.product_constructor);

        const constructor = ty.getConstructor() orelse return error.InvalidGraphState;

        if (constructor.id != builtin_func_con.id) return error.InvalidGraphState;

        const input_type = ty.getInputTypeIndex(0) orelse return error.InvalidGraphState;
        const input_constructor = input_type.getConstructor() orelse return error.InvalidGraphState;

        if (input_constructor.id != builtin_product_con.id) return error.InvalidGraphState;

        const input_types = input_type.getTypeInputs() orelse return error.InvalidGraphState;
        const variables = try VariableList.init(context);
        errdefer variables.deinit();

        for (input_types.getSlice() orelse &.{}) |input_type_key| {
            const variable = try Variable.create(context, wrapId(context, input_type_key.toIdUnchecked(rows.Type)));
            errdefer variable.deinit();

            try variables.append(variable);
        }

        const contents = try KeyList.init(context);
        errdefer contents.deinit();

        const body = try Block.init(context, variables, null, contents);
        errdefer body.deinit();

        return Function.init(context, ty, body);
    }

    pub fn init(context: *Context, ty: ?Type, body: ?Block) !Function {
        const id = try context.addRow(rows.Function, .mutable, .{ .type = if (ty) |x| x.id else .null, .body = if (body) |x| x.id else (try Block.init(context, null, null, null)).id });
        return wrapId(context, id);
    }

    pub fn deinit(self: Function) void {
        self.context.delRow(self.id);
    }

    pub fn format(self: Function, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const name = self.context.getName(self.id);
        const ty = self.getType();
        const body = self.getBody();

        try writer.print("({} {?s} : {?} = {?})", .{self.id, name, ty, body});
    }

    pub fn setType(self: Function, ty: Type) !void {
        try self.context.setCell(self.id, .type, ty.id);
    }

    pub fn getType(self: Function) ?Type {
        return Type {
            .id = self.context.getCell(self.id, .type) orelse return null,
            .context = self.context,
        };
    }

    pub fn setBody(self: Function, body: Block) !void {
        try self.context.setCell(self.id, .body, body.id);
    }

    pub fn getBody(self: Function) ?Block {
        return Block {
            .id = self.context.getCell(self.id, .body) orelse return null,
            .context = self.context,
        };
    }

    pub fn setVariables(self: Function, variables: []const Variable) !void {
        const block = self.getBody() orelse return error.InvalidGraphState;
        try block.setVariables(try VariableList.create(self.context, variables));
    }

    pub fn getVariables(self: Function) ?VariableList {
        const block = self.getBody() orelse return null;
        return block.getVariables();
    }

    pub fn getContents(self: Function) ?KeyList {
        const block = self.getBody() orelse return null;
        return block.getContents();
    }

    pub fn getContentCount(self: Function) ?usize {
        const block = self.getBody() orelse return null;
        return block.getContentCount();
    }

    pub fn getContentSlice(self: Function) ?[]const Key {
        const block = self.getBody() orelse return null;
        return block.getContentSlice();
    }
};

pub const DynamicScope = struct {
    id: Id(rows.DynamicScope),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn new(context: *Context) !DynamicScope {
        const inputs = try KeyList.init(context);
        errdefer inputs.deinit();

        const handler_list = try HandlerList.init(context);
        errdefer handler_list.deinit();

        return DynamicScope.init(context, inputs, handler_list);
    }

    pub fn init(context: *Context, inputs: KeyList, handler_list: HandlerList) !DynamicScope {
        const id = try context.addRow(rows.DynamicScope, .mutable, .{ .inputs = inputs.id, .handler_list = handler_list.id });
        return DynamicScope{ .id = id, .context = context };
    }

    pub fn deinit(self: DynamicScope) void {
        self.context.delRow(self.id);
    }

    pub fn format(self: DynamicScope, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("({})", .{ self.id });
    }

    pub fn setInputs(self: DynamicScope, inputs: KeyList) !void {
        try self.context.setCell(self.id, .inputs, inputs.id);
    }

    pub fn getInputs(self: DynamicScope) ?KeyList {
        const inputs = self.context.getCell(self.id, .inputs) orelse return null;
        return wrapId(self.context, inputs);
    }

    pub fn setHandlerList(self: DynamicScope, handler_list: HandlerList) !void {
        try self.context.setCell(self.id, .handler_list, handler_list.id);
    }

    pub fn getHandlerList(self: DynamicScope) ?HandlerList {
        const handler_list = self.context.getCell(self.id, .handler_list) orelse return null;
        return wrapId(self.context, handler_list);
    }

    pub fn getInputCount(self: DynamicScope) usize {
        return (self.getInputs() orelse return 0).getCount();
    }

    pub fn getHandlerCount(self: DynamicScope) usize {
        return (self.getHandlerList() orelse return 0).getCount();
    }
};

pub const Variable = struct {
    id: Id(rows.Variable),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn create(context: *Context, ty: Type) !Variable {
        return Variable.init(context, ty);
    }

    pub fn init(context: *Context, ty: ?Type) !Variable {
        const id = try context.addRow(rows.Variable, .mutable, .{ .type = if (ty) |t| t.id else .null });
        return wrapId(context, id);
    }

    pub fn deinit(self: Variable) void {
        self.context.delRow(self.id);
    }

    pub fn format(self: Variable, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const name = self.context.getName(self.id);
        const ty = self.getType();

        try writer.print("(𝓿𝓪𝓻 {} {?s} : {?})", .{self.id, name, ty});
    }

    pub fn setType(self: Variable, ty: Type) !void {
        try self.context.setCell(self.id, .type, ty.id);
    }

    pub fn getType(self: Variable) ?Type {
        const id = self.context.getCell(self.id, .type) orelse return null;
        return wrapId(self.context, id);
    }
};

pub const Block = struct {
    id: Id(rows.Block),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn create(context: *Context, variables: []const Variable, dynamic_scope: ?DynamicScope) !Block {
        const block = try Block.init(context, null, dynamic_scope, null);
        errdefer block.deinit();

        const variable_list = try VariableList.create(context, variables);
        errdefer variable_list.deinit();

        if (dynamic_scope) |scope| {
            try block.setDynamicScope(scope);
        }

        try block.setVariables(variable_list);

        return block;
    }

    pub fn init(context: *Context,
        variables: ?VariableList,
        dynamic_scope: ?DynamicScope,
        contents: ?KeyList,
    ) !Block {
        const id = try context.addRow(rows.Block, .mutable, .{
            .variables = if (variables) |x| x.id else (try VariableList.init(context)).id,
            .dynamic_scope = if (dynamic_scope) |x| x.id else .null,
            .contents = if (contents) |x| x.id else (try KeyList.init(context)).id,
        });
        return wrapId(context, id);
    }

    pub fn deinit(self: Block) void {
        self.context.delRow(self.id);
    }

    pub fn format(self: Block, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.context.getName(self.id)) |alias| {
            try writer.print(":: {} {}\n", .{alias, self.id});
        } else {
            try writer.print(":: {}\n", .{self.id});
        }

        if (self.getVariableSlice()) |variables| {
            for (variables) |variable_key| {
                const variable: Variable = wrapId(self.context, variable_key.toIdUnchecked(rows.Variable));
                const variable_type = variable.getType();
                const variable_name = self.context.getName(variable.id);
                try writer.print("  𝓿𝓪𝓻 {} {?}: {?};\n", .{variable.id, variable_name, variable_type});
            }
        }

        if (self.getDynamicScope()) |scope| {
            try writer.print("  𝔀𝓲𝓽𝓱 {}\n", .{scope});
        }

        if (self.getContentSlice()) |contents| {
            for (contents) |content_key| {
                switch (content_key.tag) {
                    .instruction => {
                        const content = wrapId(self.context, content_key.toIdUnchecked(rows.Instruction));
                        try writer.print("{};\n", .{content});
                    },
                    .block => {
                        const content = wrapId(self.context, content_key.toIdUnchecked(rows.Block));
                        try writer.print("{}", .{content});
                    },
                    else => return error.InvalidGraphState,
                }
            }
        }
    }

    pub fn setVariables(self: Block, variables: VariableList) !void {
        try self.context.setCell(self.id, .variables, variables.id);
    }

    pub fn getVariables(self: Block) ?VariableList {
        const variables = (self.context.table.block.getCell(self.id, .variables) orelse return null).*;
        return wrapId(self.context, variables.cast(rows.VariableList));
    }

    pub fn setDynamicScope(self: Block, dynamic_scope: DynamicScope) !void {
        try self.context.setCell(self.id, .dynamic_scope, dynamic_scope.id);
    }

    pub fn getDynamicScope(self: Block) ?DynamicScope {
        const dynamic_scope = (self.context.table.block.getCell(self.id, .dynamic_scope) orelse return null).*;
        return DynamicScope{ .id = dynamic_scope.cast(rows.DynamicScope), .context = self.context };
    }

    pub fn setContents(self: Block, contents: KeyList) !void {
        try self.context.setCell(self.id, .contents, contents.id);
    }

    pub fn getContents(self: Block) ?KeyList {
        const instructions = (self.context.table.block.getCell(self.id, .contents) orelse return null).*;
        return KeyList{ .id = instructions.cast(rows.KeyList), .context = self.context };
    }

    pub fn getVariableCount(self: Block) usize {
        return (self.getVariables() orelse return 0).getCount();
    }

    pub fn getVariableSlice(self: Block) ?[]const Key {
        return (self.getVariables() orelse return null).getSlice();
    }

    pub fn getContentCount(self: Block) ?usize {
        return (self.getContents() orelse return null).getCount();
    }

    pub fn getContentSlice(self: Block) ?[]const Key {
        return (self.getContents() orelse return null).getSlice();
    }

    pub fn append(self: Block, value: anytype) !void {
        const contents = self.getContents() orelse return error.InvalidGraphState;
        try contents.append(Key.fromId(value.id));
    }

    pub fn bindVariable(self: Block, ty: Type) !Variable {
        const variables = self.getVariables() orelse return error.InvalidGraphState;
        const variable = try Variable.create(self.context, ty);

        try variables.append(variable);

        return variable;
    }
};

pub const Instruction = struct {
    id: Id(rows.Instruction),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn create(context: *Context, operation: Operation) !Instruction {
        return Instruction.init(context, null, operation);
    }

    pub fn init(context: *Context, ty: ?Type, operation: ?Operation) !Instruction {
        const id = try context.addRow(rows.Instruction, .mutable, .{ .type = if (ty) |t| t.id else .null, .operation = operation orelse .@"unreachable" });
        return wrapId(context, id);
    }

    pub fn deinit(self: Instruction) void {
        self.context.delRow(self.id);
    }

    pub fn format(self: Instruction, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}", .{ @tagName(self.getOperation()) });
    }

    pub fn setType(self: Instruction, ty: Type) !void {
        try self.context.setCell(self.id, .type, ty.id);
    }

    pub fn getType(self: Instruction) ?Type {
        const id = self.context.getCell(self.id, .type) orelse return null;
        return wrapId(self.context, id);
    }

    pub fn setOperation(self: Instruction, operation: Operation) !void {
        try self.context.setCell(self.id, .operation, operation);
    }

    pub fn getOperation(self: Instruction) Operation {
        return self.context.getCell(self.id, .operation) orelse return .@"unreachable";
    }
};

pub const ControlEdge = struct {
    id: Id(rows.ControlEdge),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn init(context: *Context) !ControlEdge {
        const id = try context.addRow(rows.ControlEdge, .mutable, .{ });
        return ControlEdge{ .id = id, .context = context };
    }

    pub fn create(context: *Context, src: Key, dest: Key, source_index: usize) !ControlEdge {
        const id = try context.addRow(rows.ControlEdge, .mutable, .{ .source = src, .destination = dest, .source_index = source_index });
        return ControlEdge{ .id = id, .context = context };
    }

    pub fn deinit(self: ControlEdge) void {
        self.context.delRow(self.id);
    }

    pub fn format(self: ControlEdge, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("({})", .{ self.id });
    }

    pub fn setSource(self: ControlEdge, src: Key) !void {
        try self.context.setCell(self.id, .source, src);
    }

    pub fn getSource(self: ControlEdge) ?Key {
        return self.context.getCell(self.id, .source);
    }

    pub fn setDestination(self: ControlEdge, destination: Key) !void {
        try self.context.setCell(self.id, .destination, destination);
    }

    pub fn getDestination(self: ControlEdge) ?Key {
        return self.context.getCell(self.id, .destination);
    }

    pub fn setSourceIndex(self: ControlEdge, index: usize) !void {
        try self.context.setCell(self.id, .source_index, index);
    }

    pub fn getSourceIndex(self: ControlEdge) usize {
        return self.context.getCell(self.id, .source_index) orelse 0;
    }
};

pub const DataEdge = struct {
    id: Id(rows.DataEdge),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    pub fn init(context: *Context) !DataEdge {
        const id = try context.addRow(rows.DataEdge, .mutable, .{ });
        return wrapId(context, id);
    }

    pub fn create(context: *Context, src: Key, destination: Key) !DataEdge {
        const id = try context.addRow(rows.DataEdge, .mutable, .{ .source = src, .destination = destination });
        return wrapId(context, id);
    }

    pub fn deinit(self: DataEdge) void {
        self.context.delRow(self.id);
    }

    pub fn format(self: DataEdge, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("({})", .{ self.id });
    }

    pub fn setSource(self: DataEdge, src: Key) !void {
        try self.context.setCell(self.id, .source, src);
    }

    pub fn getSource(self: DataEdge) ?Key {
        return self.context.getCell(self.id, .source);
    }

    pub fn setDestination(self: DataEdge, destination: Key) !void {
        try self.context.setCell(self.id, .destination, destination);
    }

    pub fn getDestination(self: DataEdge) ?Key {
        return self.context.getCell(self.id, .destination);
    }

    pub fn setSourceIndex(self: DataEdge, index: usize) !void {
        try self.context.setCell(self.id, .source_index, index);
    }

    pub fn getSourceIndex(self: DataEdge) usize {
        return self.context.getCell(self.id, .source_index) orelse 0;
    }

    pub fn setDestinationIndex(self: DataEdge, index: usize) !void {
        try self.context.setCell(self.id, .destination_index, index);
    }

    pub fn getDestinationIndex(self: DataEdge) usize {
        return self.context.getCell(self.id, .destination_index) orelse 0;
    }
};

pub const Visitor = struct {
    context: *Context,
    visited: pl.UniqueReprSet(Key, 80),

    pub fn init(context: *Context) Visitor {
        return .{
            .context = context,
            .visited = .empty,
        };
    }

    pub fn deinit(self: *Visitor) void {
        self.visited.deinit(self.context.arena.child_allocator);
    }

    pub fn clear(self: *Visitor) void {
        self.visited.clearRetainingCapacity();
    }

    pub fn alreadyVisited(self: *Visitor, key: Key) !bool {
        return (try self.visited.getOrPut(self.context.arena.child_allocator, key)).found_existing;
    }

    pub fn reachable(self: *Visitor, key: Key) !void {
        if (try self.alreadyVisited(key)) return;

        const control_sources: []Key = self.context.table.control_edge.getColumn(.source);
        for (control_sources, 0..) |source_key, edge_index| {
            if (source_key != key) continue;

            const destination_key = self.context.table.control_edge.getCellAt(edge_index, .destination).*;

            try self.reachable(destination_key);
        }

        const data_key: []Key = self.context.table.data_edge.getColumn(.source);
        for (data_key, 0..) |source_key, edge_index| {
            if (source_key != key) continue;

            const destination_key = self.context.table.data_edge.getCellAt(edge_index, .destination).*;

            try self.reachable(destination_key);
        }

        if (key.tag == .block) {
            const block = wrapId(self.context, key.toIdUnchecked(rows.Block));
            const contents = block.getContents() orelse return error.InvalidGraphState;

            for (contents.getSlice() orelse &.{}) |content_key| {
                try self.reachable(content_key);
            }
        }
    }
};




test {
    const context = try Context.init(std.testing.allocator);
    defer context.deinit();


    const empty_origin = try Origin.create(context, &.{});

    const test_name = try Name.intern(context, "test");

    // std.debug.print("{}\n", .{test_name});

    const kdata = try context.getBuiltin(.data_kind);
    const ccustom_data = try Constructor.init(context, kdata);

    try test_name.bindSymbol(ccustom_data);
    try empty_origin.bindValue(ccustom_data);

    const tcustom_data = try Type.intern(context, ccustom_data, &.{});
    const tno_effect = try context.getBuiltin(.no_effect_type);

    const constant = try Constant.fromUnownedBytes(context, tcustom_data, "test");
    defer constant.deinit();

    const test_func_name = try Name.intern(context, "test_func_ty");
    const function_ty = try Type.createFunction(context, &.{tcustom_data, tcustom_data}, tcustom_data, tno_effect);

    try test_func_name.bindSymbol(function_ty);

    // std.debug.print("{}",.{function_ty});

    const function = try Function.create(context, function_ty);

    const body = function.getBody().?;

    try body.append(try Instruction.create(context, .nop));

    std.debug.print("{}", .{function});
}
