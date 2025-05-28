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

/// 64-bit specialiation of `common.Id`, for ir structures.
pub fn Id(comptime T: type) type {
    return common.Id.ofSize(T, 64);
}

/// Main data storage for the ir graph.
/// Given a struct type `T`, this provides a table with rows of type `T`, and columns matching `T`'s fields.
/// This is a simple interface wrapper over a multiarray-based slotmap.
pub fn Table(comptime T: type) type {
    return struct {
        const Self = @This();
        const Id = ir.Id(T);

        const Data = common.SlotMap.MultiArray(T, 32, 32);

        /// The type of the rows in this table.
        pub const RowType = T;

        /// Multi-array based data storage for the table.
        data: Data = .empty,

        /// Create a new table with a given capacity in the provided allocator.
        pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !Self {
            return Self {
                .data = try Data.initCapacity(allocator, capacity),
            };
        }

        /// Ensure the table has at least the given capacity in *unused* space.
        pub fn ensureCapacity(self: *Self, allocator: std.mem.Allocator, capacity: usize) !void {
            try self.data.ensureCapacity(allocator, capacity);
        }

        /// Deinitialize the table's rows.
        /// * Not necessary to call if the table's row type does not have a `deinit` method.
        pub fn deinitData(self: *Self, allocator: std.mem.Allocator) void {
            if (comptime pl.hasDecl(T, .deinit)) {
                for (0..self.data.count()) |i| {
                    if (self.data.getIndex(@intCast(i))) |a| {
                        var x = a;
                        x.deinit(allocator);
                    }
                }
            }
        }

        /// Clear the table's rows.
        /// * This does not deinitialize them; use `deinitData` first if needed.
        pub fn clear(self: *Self) void {
            self.data.clear();
        }

        /// Deinitialize the table, freeing all the memory used for its rows.
        /// * This will deinitialize the rows themselves, if necessary.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.deinitData(allocator);
            self.data.deinit(allocator);
        }

        /// Get the number of rows in the table.
        pub fn rowCount(self: *Self) usize {
            return self.data.len;
        }

        /// Get all entries in the table within a specific column.
        /// * Given a `Table(T)`, returns a linear buffer containing the field of each `T` under the provided name.
        /// * If a string name needs to be converted: `@field(std.meta.FieldEnum(T), comptime str)`
        pub fn getColumn(self: *Self, comptime name: std.meta.FieldEnum(T)) []std.meta.FieldType(T, name) {
            return self.data.fields(name);
        }

        /// Get the id of a table row at a specific index.
        /// * Only bounds checked in safe modes.
        pub fn getIdFromIndex(self: *Self, index: u32) Self.Id {
            const slot_index = self.data.__valueToSlot(index).*;

            return refToId(Data.Ref {
                .index = slot_index,
                .generation = self.data.__generation(index).*,
            }).cast(T);
        }

        /// Get the index of a table row from its id.
        pub fn getIndex(self: *Self, id: Self.Id) ?usize {
            return if (self.data.resolveIndex(idToRef(id.cast(anyopaque)))) |i| i else null; // needed because i is u32 not usize
        }

        /// Gets a pointer to a specific (row, column) cell in the table, given its id and name.
        /// * If a string name needs to be converted: `@field(std.meta.FieldEnum(T), comptime str)`
        pub fn getCell(self: *Self, id: Self.Id, comptime name: std.meta.FieldEnum(T)) ?*std.meta.FieldType(T, name) {
            return self.getCellAt(self.getIndex(id) orelse return null, name);
        }

        /// Gets a pointer to a specific (row, column) cell in the table, given its index and name.
        /// * If a string name needs to be converted: `@field(std.meta.FieldEnum(T), comptime str)`
        pub fn getCellAt(self: *Self, index: usize, comptime name: std.meta.FieldEnum(T)) *std.meta.FieldType(T, name) {
            return self.data.field(index, name);
        }

        /// Get a copy of a row of the table, given its id.
        pub fn getRow(self: *Self, id: Self.Id) ?T {
            const index = self.getIndex(@bitCast(id)) orelse return null;

            return self.data.get(index);
        }

        /// Set a whole row of the table, given its id.
        pub fn setRow(self: *Self, id: Self.Id, value: T) !void {
            const index = self.getIndex(@bitCast(id)) orelse return error.InvalidId;

            return self.data.set(index, value);
        }

        /// Create a new row in the table, returning its id.
        /// * The value will be initialized with fields from the `init` argument, or from the default value of the field if not provided.
        pub fn addRow(self: *Self, allocator: std.mem.Allocator, init: anytype) !Self.Id {
            log.debug(@typeName(Self) ++ " @ {} addRow: {}", .{@intFromPtr(self), init});
            const I = @TypeOf(init);
            const ref, const index = try self.data.create(allocator);
            const id = refToId(ref);

            inline for (comptime std.meta.fields(T)) |field| {
                const field_enum = @field(std.meta.FieldEnum(T), field.name);
                if (comptime std.mem.eql(u8, field.name, "id")) {
                    self.data.field(index, field_enum).* = id.cast(T);
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

            return id.cast(T);
        }

        /// Delete a row from the table, given its id.
        pub fn delRow(self: *Self, id: Self.Id) void {
            self.data.destroy(idToRef(id.cast(anyopaque)));
        }

        /// Get an iterator over all the ids in the table.
        pub fn iterateIds(self: *Self) RefToIdIterator(Self.RowType) {
            return .{
                .inner = self.data.iterator(),
            };
        }

        /// Get an iterator over all the keys in the table.
        pub fn iterateKeys(self: *Self) TableKeyIterator {
            return TableKeyIterator.from(Self.RowType, self.iterateIds().cast(anyopaque));
        }
    };
}



pub fn idToRef(id: Id(anyopaque)) common.SlotMap.Ref(32, 32) {
    const bits: u64 = @intFromEnum(id);

    return @bitCast(bits);
}

pub fn refToId(ref: common.SlotMap.Ref(32, 32)) Id(anyopaque) {
    return @enumFromInt(@as(u64, @bitCast(ref)));
}

pub fn RefToIdIterator(comptime T: type) type {
    return struct {
        /// The type of the values covered by this iterator.
        pub const RowType = T;

        inner: common.SlotMap.Iterator(32, 32),

        pub fn next(self: *@This()) ?Id(T) {
            return refToId(self.inner.next() orelse return null).cast(T);
        }

        pub fn cast(self: @This(), comptime U: type) RefToIdIterator(U) {
            return .{ .inner = self.inner };
        }
    };
}

pub const TableKeyIterator = IdToKeyIterator(RefToIdIterator(anyopaque));

pub fn IdToKeyIterator(comptime I: type) type {
    return struct {
        tag: Key.Tag,
        inner: I,

        pub fn from(comptime R: type, id_iterator: I) @This() {
            return .{
                .tag = comptime Key.Tag.fromRowType(R),
                .inner = id_iterator,
            };
        }

        pub fn next(self: *@This()) ?Key {
            return Key {
                .tag = self.tag,
                .id = self.inner.next() orelse return null,
            };
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
        /// types that handlers bound for this effect must conform to
        handler_type_list: Id(rows.TypeList),
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

        /// Defines which kind of intrinsic is carried in `Instrinsic.Data`.
        pub const Tag = enum(u8) {
            /// This intrinsic represents a specific bytecode instruction.
            bytecode,
            /// Placeholder for future expansions to the intrinsic api.
            _,
        };

        /// The actual value carried by an `Intrinsic`.
        pub const Data = packed union {
            /// Embedding the bytecode opcode directly is super convenient because we can
            /// use this to represent instructions that are not semantically significant to
            /// analysis, such as simple addition etc; and then also to represent selected
            /// instructions during the lowering process.
            bytecode: bytecode.Instruction.OpCode,
            /// Placeholder for future expansions to the intrinsic api.
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
        /// the index of this edge relative to the destination;
        /// designates which control edge this is; ie the first or second predecessor in a phi.
        destination_index: usize = 0,
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

        /// Deinitialize the buffer, freeing its memory.
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

        /// Deinitialize the key list, freeing its memory.
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

    /// Indicates where the data for a key is stored.
    pub const Storage: type = enum(u8) {
        map,
        table,
    };

    /// Discriminator for the type of id carried by a `Key`. Generally, corresponds to a type in `ir.rows`.
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

        /// Increment a tag to the next value category.
        pub fn next(self: Tag) ?Tag {
            const max = comptime @intFromEnum(Tag.key_list);
            const a = @intFromEnum(self);
            if (a == max) return null; // no next tag

            return @enumFromInt(a + 1);
        }

        /// Convert a comptime-known Tag to the row type it represents.
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

        /// Get the field of a data structure that shares the name of a comptime-known tag.
        pub fn getField(self: Tag, data: anytype) @FieldType(@typeInfo(@TypeOf(data)).pointer.child, @tagName(self)) {
            return &@field(data, @tagName(self));
        }

        /// Set the field of a data structure that shares the name of a comptime-known tag.
        pub fn setField(self: Tag, data: anytype, value: @FieldType(@typeInfo(@TypeOf(data)).pointer.child, @tagName(self))) void {
            @field(data, @tagName(self)) = value;
        }

        /// Determine whether the tag's data row lives in a map or a table.
        pub fn getStorage(self: Tag) Storage {
            return switch (self) {
                .name, .source => .map,
                else => .table,
            };
        }

        /// Get a pointer to the field of a data structure that shares the name of a comptime-known tag.
        pub fn fieldPtr(comptime self: Tag, data: anytype) *@FieldType(@typeInfo(@TypeOf(data)).pointer.child, @tagName(self)) {
            return &@field(data, @tagName(self));
        }

        /// Convert a comptime-known Tag to the type of id it represents.
        pub fn toIdType(comptime self: Tag) type {
            comptime return Id(self.toType());
        }

        /// Convert an `Id(row._)` type to a comptime-known Tag.
        pub fn fromIdType(comptime T: type) Tag {
            return fromRowType(T.Value);
        }

        /// Convert a type from `ir.rows` to a comptime-known Tag.
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

    /// Create a Key from an id of any known type.
    pub fn fromId(id: anytype) Key {
        return Key {
            .tag = comptime Tag.fromIdType(@TypeOf(id)),
            .id = id.cast(anyopaque),
        };
    }

    /// Convert a key to an `Id` of the provided row type, without checking the tag.
    pub fn toIdUnchecked(self: Key, comptime T: type) Id(T) {
        return self.id.cast(T);
    }

    /// Convert a key to an `Id` of the provided row type, if the tag matches.
    pub fn toId(self: Key, comptime T: type) ?Id(T) {
        if (self.tag != comptime Tag.fromRowType(T)) {
            return null;
        }

        return self.id.cast(T);
    }

    /// A wrapper type for std.fmt-related rich printing of `Key`.
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

    /// Create a rich formatter for this key, which can be used with `std.fmt`.
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

/// Convert a comptime-known `Builtin` to a handler wrapper of the corresponding row type.
pub fn BuiltinType(comptime builtin: Builtin) type {
    return WrappedId(BuiltinId(builtin));
}

/// Convert a comptime-known `Builtin` to an `Id` of the corresponding row type.
pub fn BuiltinId(comptime builtin: Builtin) type {
    return Id(BuiltinRowType(builtin));
}

/// Convert a comptime-known `Builtin` to the row type it represents.
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

/// Initializer functions for built-in values.
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

/// The signature of functions that can provide custom formatting to an ir `Context`.
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

    /// Clear the context, resetting all data structures to their initial state, but retaining memory for tables.
    pub fn clear(self: *Context) void {
        inline for (comptime std.meta.fieldNames(@FieldType(Context, "map"))) |map_name| {
            @field(self.map, map_name).clearRetainingCapacity();
        }

        inline for (comptime std.meta.fieldNames(@FieldType(Context, "table"))) |table_name| {
            @field(self.table, table_name).deinitData(self.gpa);
            @field(self.table, table_name).clear();
        }

        _ = self.arena.reset(.retain_capacity);
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

    /// Check whether a given id is constant.
    pub fn isConstant(self: *Context, id: anytype) bool {
        return (self.map.mutability.get(Key.fromId(id.cast(RowType(@TypeOf(id))))) orelse return false) == .constant;
    }

    /// Check whether a given id is mutable.
    pub fn isMutable(self: *Context, id: anytype) bool {
        return (self.map.mutability.get(Key.fromId(id.cast(RowType(@TypeOf(id))))) orelse return false) == .mutable;
    }

    /// Define the mutability of a given id.
    pub fn setMutability(self: *Context, id: anytype, mutability: pl.Mutability) !void {
        const key = Key.fromId(id.cast(RowType(@TypeOf(id))));
        if (self.map.mutability.get(key)) |existing| {
            if (existing == mutability) return;
            log.debug("mutability of {} already set to {}", .{key, existing});
            return error.InvalidGraphState;
        }

        try self.map.mutability.put(self.arena.child_allocator, key, mutability);
    }

    /// Convert a mutable id to a constant id.
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

    /// Get the source set bound to a key.
    pub fn getOrigin(self: *Context, id: anytype) ?Origin {
        return wrapId(self, self.map.origin.get_b(Key.fromId(id.cast(RowType(@TypeOf(id))))) orelse return null);
    }

    /// Get the formatter bound to a key.
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

    /// Get a built-in value by its identifier.
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

    /// Get an iterator that visits all keys in this context.
    /// * keys will be visited categorically in the order they appear in the graph;
    ///   so all names, then all sources, then all kinds, etc.
    /// * within categories:
    ///     + the names of *table* entries will be visited in the order they were added to the table.
    ///     + the names of *map* entries will be visited in their arbitrary hash order.
    pub fn keyIterator(self: *Context) KeyIterator {
        return KeyIterator{
            .context = self,
            .category = comptime Key.Tag.fromRowType(rows.Name),
            .inner = .none,
        };
    }
};

pub const KeyIterator = struct {
    context: *Context,
    category: ?Key.Tag,
    inner: union(enum) {
        none: void,
        name: @FieldType(@FieldType(Context, "map"), "name_storage").Iterator,
        source: @FieldType(@FieldType(Context, "map"), "source_storage").Iterator,
        table: TableKeyIterator,
    },

    pub fn next(self: *KeyIterator) ?Key {
        switch (self.inner) {
            inline .name, .source => |*entry_iter| {
                const entry = entry_iter.next() orelse {
                    // if we reach the end of the iterator, we need to switch to the next category
                    self.inner = .none;
                    if (self.category) |category| self.category = category.next();
                    return self.next();
                };

                return Key.fromId(entry.b);
            },

            .table => |*key_iter| {
                const key = key_iter.next() orelse {
                    // if we reach the end of the key iterator, we need to switch to the next category
                    self.inner = .none;
                    if (self.category) |category| self.category = category.next();
                    return self.next();
                };

                return key;
            },

            .none => if (self.category) |category| {
                switch (category) {
                    .name => {
                        self.inner = .{ .name = self.context.map.name_storage.iterator() };
                        return self.next();
                    },
                    .source => {
                        self.inner = .{ .source = self.context.map.source_storage.iterator() };
                        return self.next();
                    },
                    .kind => {
                        self.inner = .{ .table = self.context.table.kind.iterateKeys() };
                        return self.next();
                    },
                    .constructor => {
                        self.inner = .{ .table = self.context.table.constructor.iterateKeys() };
                        return self.next();
                    },
                    .type => {
                        self.inner = .{ .table = self.context.table.type.iterateKeys() };
                        return self.next();
                    },
                    .effect => {
                        self.inner = .{ .table = self.context.table.effect.iterateKeys() };
                        return self.next();
                    },
                    .constant => {
                        self.inner = .{ .table = self.context.table.constant.iterateKeys() };
                        return self.next();
                    },
                    .global => {
                        self.inner = .{ .table = self.context.table.global.iterateKeys() };
                        return self.next();
                    },
                    .foreign_address => {
                        self.inner = .{ .table = self.context.table.foreign_address.iterateKeys() };
                        return self.next();
                    },
                    .builtin_address => {
                        self.inner = .{ .table = self.context.table.builtin_address.iterateKeys() };
                        return self.next();
                    },
                    .intrinsic => {
                        self.inner = .{ .table = self.context.table.intrinsic.iterateKeys() };
                        return self.next();
                    },
                    .handler => {
                        self.inner = .{ .table = self.context.table.handler.iterateKeys() };
                        return self.next();
                    },
                    .function => {
                        self.inner = .{ .table = self.context.table.function.iterateKeys() };
                        return self.next();
                    },
                    .dynamic_scope => {
                        self.inner = .{ .table = self.context.table.dynamic_scope.iterateKeys() };
                        return self.next();
                    },
                    .block => {
                        self.inner = .{ .table = self.context.table.block.iterateKeys() };
                        return self.next();
                    },
                    .variable => {
                        self.inner = .{ .table = self.context.table.variable.iterateKeys() };
                        return self.next();
                    },
                    .data_edge => {
                        self.inner = .{ .table = self.context.table.data_edge.iterateKeys() };
                        return self.next();
                    },
                    .control_edge => {
                        self.inner = .{ .table = self.context.table.control_edge.iterateKeys() };
                        return self.next();
                    },
                    .instruction => {
                        self.inner = .{ .table = self.context.table.instruction.iterateKeys() };
                        return self.next();
                    },
                    .buffer => {
                        self.inner = .{ .table = self.context.table.buffer.iterateKeys() };
                        return self.next();
                    },
                    .key_list => {
                        self.inner = .{ .table = self.context.table.key_list.iterateKeys() };
                        return self.next();
                    },
                    else => unreachable,
                }
            } else {
                return null;
            },
        }
    }
};

/// Type mapping from row types to wrapper handle types.
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

/// Wrap an id in a `WrappedId` handle, which provides additional functionality.
pub fn wrapId(context: *Context, id: anytype) WrappedId(@TypeOf(id)) {
    return .{ .context = context, .id = id };
}

/// Base mixin for handle types that provides common functionality.
pub fn HandleBase(comptime Self: type) type {
    return struct {
        const Mixin = @This();

        const Id = @FieldType(Self, "id");
        const Row = Mixin.Id.Value;

        /// Get a low-level Key from this handle.
        pub fn getKey(self: Self) Key {
            return Key.fromId(self.id);
        }

        /// Determine if the value bound by this handle is mutable.
        pub fn isMutable(self: Self) bool {
            return self.context.isMutable(self.id);
        }

        /// Determine if the value bound by this handle is constant.
        pub fn isConstant(self: Self) bool {
            return self.context.isConstant(self.id);
        }

        /// Get the symbol name binding the value associated with this handle, if present.
        pub fn getName(self: Self) ?Name {
            return self.context.getName(self.id);
        }
    };
}

/// Mixin for key list types that provides common functionality for key lists.
pub fn KeyListBase(comptime Self: type, comptime T: type) type {
    return struct {
        const Mixin = @This();

        const Id = @FieldType(Self, "id");
        const Row = Mixin.Id.Value;
        const ValueId = ir.Id(T);
        const Value = WrappedId(ValueId);

        /// Create a new key list from a slice of wrapper values.
        pub fn create(context: *Context, values: []const Value) !Self {
            const temp = try context.arena.allocator().alloc(Key, values.len);
            defer context.arena.allocator().free(temp);

            for (values, 0..) |value, index| {
                temp[index] = Key.fromId(value.id);
            }

            const id = try context.createKeyList(temp);

            return wrapId(context, id.cast(Row));
        }

        /// Create a new empty key list.
        pub fn init(context: *Context) !Self {
            const id = try context.createKeyList(&.{});
            return wrapId(context, id.cast(Row));
        }

        /// Deinitialize the key list, freeing its resources from the graph.
        pub fn deinit(self: Self) void {
            self.context.delRow(self.id);
        }

        /// Get the number of keys in the key list.
        pub fn getCount(self: Self) usize {
            return (self.getSlice() orelse return 0).len;
        }

        /// Get a mutable slice of keys in the key list.
        pub fn getMutSlice(self: Self) ?[]Key {
            return (self.getMutArrayList() orelse return null).items;
        }

        /// Get a mutable pointer to the array list of keys in the key list.
        pub fn getMutArrayList(self: Self) ?*pl.ArrayList(Key) {
            std.debug.assert(!self.context.isConstant(self.id));
            return self.context.getCellPtr(self.id.cast(rows.KeyList), .keys);
        }

        /// Get a slice of keys in the key list.
        pub fn getSlice(self: Self) ?[]const Key {
            return (self.getArrayList() orelse return null).items;
        }

        /// Get a pointer to the array list of keys in the key list.
        pub fn getArrayList(self: Self) ?*const pl.ArrayList(Key) {
            return self.context.getCellPtr(self.id.cast(rows.KeyList), .keys);
        }

        /// Append a value to the key list.
        pub fn append(self: Self, value: Value) !void {
            const array = self.getMutArrayList() orelse return error.InvalidGraphState;
            try array.append(self.context.arena.child_allocator, Key.fromId(value.id));
        }

        /// `std.fmt` impl
        pub fn format(self: Self, comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
            try wrapId(self.context, self.id.cast(rows.KeyList)).format(fmt, opts, writer);
        }
    };
}

/// Generic collection of graph keys.
pub const KeyList = struct {
    id: Id(rows.KeyList),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Create a new key list from a slice of keys.
    pub fn create(context: *Context, keys: []const Key) !KeyList {
        const id = try context.createKeyList(keys);
        return KeyList{ .id = id, .context = context };
    }

    /// Create a new empty key list.
    pub fn init(context: *Context) !KeyList {
        const id = try context.createKeyList(&.{});
        return KeyList{ .id = id, .context = context };
    }

    /// Deinitialize the key list, freeing its resources from the graph.
    pub fn deinit(self: KeyList) void {
        self.context.delRow(self.id);
    }

    /// Cast the key list to a narrower type.
    pub fn cast(self: KeyList, comptime Narrow: type) Narrow {
        return wrapId(self.context, self.id.cast(@FieldType(Narrow, "id").Value));
    }

    /// Get the number of keys in the key list.
    pub fn getCount(self: KeyList) usize {
        return (self.getSlice() orelse return 0).len;
    }

    /// Get a mutable slice of keys in the key list.
    pub fn getSlice(self: KeyList) ?[]Key {
        return (self.getArrayList() orelse return null).items;
    }

    /// Get a mutable pointer to the array list of keys in the key list.
    pub fn getArrayList(self: KeyList) ?*pl.ArrayList(Key) {
        return self.context.getCellPtr(self.id.cast(rows.KeyList), .keys);
    }

    /// Add a key to the key list.
    pub fn append(self: KeyList, key: Key) !void {
        const array = self.getArrayList() orelse return error.InvalidGraphState;
        try array.append(self.context.arena.child_allocator, key);
    }

    /// `std.fmt` impl
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

/// A handle to a name in the graph, which can be used to bind symbols and debug information.
pub const Name = struct {
    id: Id(rows.Name),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Intern a name in the context, getting a shared handle to it.
    pub fn intern(context: *Context, name: []const u8) !Name {
        const id = try context.internName(name);
        return Name{ .id = id, .context = context };
    }

    /// Get the text of the name.
    pub fn getText(self: Name) ![]const u8 {
        return self.context.map.name_storage.get_a(self.id) orelse return error.InvalidGraphState;
    }

    /// Get the key associated with this name, if any is bound.
    pub fn getSymbolBinding(self: Name) ?Key {
        return self.context.map.name_to_key.get(self.id);
    }

    /// Bind a key to this name, creating a symbol table entry.
    pub fn bindSymbol(self: Name, value: anytype) !void {
        try self.context.bindSymbolName(self.id, Key.fromId(value.id));
    }

    /// Bind a key to this name, allowing the generation of debug information.
    pub fn bindDebug(self: Name, value: anytype) !void {
        try self.context.bindDebugName(self.id, Key.fromId(value.id));
    }

    /// `std.fmt` impl
    pub fn format(self: Name, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll(try self.getText());
    }
};

/// A handle to a source in the graph, which can be used to represent the origin of a value.
pub const Source = struct {
    id: Id(source.Source),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Intern a source in the context, getting a shared handle to it.
    pub fn intern(context: *Context, src: source.Source) !Source {
        const id = try context.internSource(src);
        return Source{ .id = id, .context = context };
    }

    /// Get a copy of the source data.
    pub fn getData(self: Source) !source.Source {
        return self.context.map.source_storage.get_a(self.id) orelse return error.InvalidGraphState;
    }

    /// `std.fmt` impl
    pub fn format(self: Source, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}", .{try self.getData()});
    }
};

/// A handle to a source set in the graph, which can be used to represent a multi-origin value.
pub const Origin = struct {
    id: Id(rows.Origin),
    context: *Context,

    pub usingnamespace HandleBase(@This());
    pub usingnamespace KeyListBase(@This(), source.Source);

    pub fn bindValue(self: Origin, value: anytype) !void {
        try self.context.bindOrigin(self.id, Key.fromId(value.id));
    }
};

/// Type-narrowing of KeyList for lists of `Handler`s.
pub const HandlerList = struct {
    id: Id(rows.HandlerList),
    context: *Context,

    pub usingnamespace HandleBase(@This());
    pub usingnamespace KeyListBase(@This(), rows.Handler);
};

/// Type-narrowing of KeyList for lists of `Kind`s.
pub const KindList = struct {
    id: Id(rows.KindList),
    context: *Context,

    pub usingnamespace HandleBase(@This());
    pub usingnamespace KeyListBase(@This(), rows.Kind);

    /// Get or create a shared KindList from a slice of `Kind`s.
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

/// Type-narrowing of KeyList for lists of `Type`s.
pub const TypeList = struct {
    id: Id(rows.TypeList),
    context: *Context,

    pub usingnamespace HandleBase(@This());
    pub usingnamespace KeyListBase(@This(), rows.Type);

    /// Get or create a shared TypeList from a slice of `Type`s.
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

/// Type-narrowing of KeyList for lists of `Variable`s.
pub const VariableList = struct {
    id: Id(rows.VariableList),
    context: *Context,

    pub usingnamespace HandleBase(@This());
    pub usingnamespace KeyListBase(@This(), rows.Variable);

    /// Get or create a shared VariableList from a slice of `Variable`s.
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

/// A handle to a type constructor in the ir graph.
/// Essentially, this a discriminator for the open-union of types in the system.
pub const Constructor = struct {
    id: Id(rows.Constructor),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Create a new constructor with the given kind.
    pub fn init(context: *Context, kind: Kind) !Constructor {
        const id = try context.addRow(rows.Constructor, .mutable, .{ .kind = kind.id });
        return Constructor{ .id = id, .context = context };
    }

    /// Remove a constructor from the graph, freeing its resources.
    pub fn deinit(self: Constructor) void {
        self.context.delRow(self.id);
    }

    /// Set the kind of this constructor.
    pub fn setKind(self: Constructor, kind: Kind) !void {
        try self.context.setCell(self.id, .kind, kind.id);
    }

    /// Get the kind of this constructor.
    pub fn getKind(self: Constructor) ?Kind {
        return Kind {
            .id = self.context.getCell(self.id, .kind) orelse return null,
            .context = self.context,
        };
    }

    /// Get the output tag of this constructor's kind.
    pub fn getOutputKindTag(self: Constructor) ?rows.Kind.Tag {
        return (self.getKind() orelse return null).getOutputTag();
    }

    /// Get the number of input kinds for this constructor's kind.
    pub fn getInputKindCount(self: Constructor) usize {
        return (self.getInputKinds() orelse return 0).getCount();
    }

    /// Get a slice of input kinds for this constructor's kind.
    pub fn getInputKindSlice(self: Constructor) ?[]const Key {
        return (self.getInputKinds() orelse return null).getSlice();
    }

    /// Get the input KindList for this constructor's kind.
    pub fn getInputKinds(self: Constructor) ?KindList {
        return (self.getKind() orelse return null).getInputs();
    }

    /// `std.fmt` impl
    pub fn format(self: Constructor, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const kind = self.getKind();
        const name = self.context.getName(self.id);

        try writer.print("(𝓬𝓸𝓷 {} {?s} :: {?})", .{self.id, name, kind});
    }
};

/// Defines the signature of a type constructor in the ir graph.
pub const Kind = struct {
    id: Id(rows.Kind),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Get or create a shared Kind from a tag and a slice of input kinds.
    pub fn intern(context: *Context, tag: rows.Kind.Tag, inputs: []const Kind) !Kind {
        const kind_list = try KindList.intern(context, inputs);

        for (context.table.kind.getColumn(.tag), context.table.kind.getColumn(.inputs), 0..) |existing_tag, existing_inputs, index| {
            if (existing_tag == tag
            and existing_inputs == kind_list.id.cast(rows.KeyList)) {
                return Kind{ .id = context.table.kind.getIdFromIndex(@intCast(index)), .context = context };
            }
        }

        return Kind.init(context, .constant, tag, kind_list);
    }

    /// Create a new Kind with the given tag and a slice of input kinds.
    pub fn create(context: *Context, tag: rows.Kind.Tag, ids: []const Kind) !Kind {
        const kind_list = try KindList.create(context, ids);

        return Kind.init(context, .mutable, tag, kind_list);
    }

    /// Initialize a new Kind with the given mutability, tag, and input kinds.
    pub fn init(context: *Context, mutability: pl.Mutability, tag: rows.Kind.Tag, inputs: ?KindList) !Kind {
        const id = try context.addRow(rows.Kind, mutability, .{ .tag = tag, .inputs = if (inputs) |x| x.id.cast(rows.KeyList) else .null });
        return Kind{ .id = id, .context = context };
    }

    /// Deinitialize the Kind, freeing its resources from the graph.
    pub fn deinit(self: Kind) void {
        self.context.delRow(self.id);
    }

    /// Get the number of input kinds for this Kind.
    pub fn getInputCount(self: Kind) usize {
        return (self.getInputs() orelse return 0).getCount();
    }

    /// Get a slice of input kinds for this Kind.
    pub fn getInputSlice(self: Kind) ?[]const Key {
        return (self.getInputs() orelse return null).getSlice();
    }

    /// Set the output tag for this Kind.
    pub fn setOutputTag(self: Kind, tag: rows.Kind.Tag) !void {
        try self.context.setCell(self.id, .tag, tag);
    }

    /// Get the output tag for this Kind.
    pub fn getOutputTag(self: Kind) ?rows.Kind.Tag {
        return (self.context.table.kind.getCell(self.id, .tag) orelse return null).*;
    }

    /// Override the input KindList for this Kind.
    pub fn setInputs(self: Kind, inputs: KindList) !void {
        try self.context.setCell(self.id, .inputs, inputs.id.cast(rows.KeyList));
    }

    /// Get the input KindList for this Kind.
    pub fn getInputs(self: Kind) ?KindList {
        const id = (self.context.getCellPtr(self.id, .inputs) orelse return null).*;
        return KindList{ .id = id.cast(rows.KindList), .context = self.context };
    }

    /// `std.fmt` impl
    pub fn format(self: Kind, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const tag = self.context.getCell(self.id, .tag);
        const inputs = self.context.getCell(self.id, .inputs);

        try writer.print("(𝓴𝓲𝓷𝓭 {?} => {?s})", .{ if (inputs) |id| wrapId(self.context, id) else null, if (tag) |t| @tagName(t) else null });
    }
};

/// A handle to a type in the ir graph.
pub const Type = struct {
    id: Id(rows.Type),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Get or create a shared Type from a constructor and a slice of input types.
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

    /// Create a new int-kinded type with the given value.
    pub fn createInt(context: *Context, value: i256) !Type {
        const constructor = try context.getBuiltin(.int_constructor);
        const ty = try Type.init(context, .mutable, constructor, null);

        const constant = try Constant.fromUnownedBytes(context, ty, std.mem.asBytes(&value));
        const inputs = try KeyList.create(context, &.{ constant.getKey() });

        try ty.setTypeInputs(inputs.cast(TypeList));

        return ty;
    }

    /// Create a new data-kinded integer type with the given signedness and bit size.
    pub fn createBitInteger(context: *Context, signedness: pl.Signedness, bit_size: u16) !Type {
        const int = try Type.createInt(context, bit_size);

        const cint = switch (signedness) {
            .signed => try context.getBuiltin(.signed_integer_constructor),
            .unsigned => try context.getBuiltin(.unsigned_integer_constructor),
        };

        return Type.create(context, cint, &.{ int });
    }

    /// Create a new function type with the given input, result, and effect types.
    pub fn createFunction(context: *Context, inputs: []const Type, result: Type, effect: Type) !Type {
        const type_list = try TypeList.create(context, inputs);
        errdefer type_list.deinit();

        const input_product = try Type.create(context, try context.getBuiltin(.product_constructor), inputs);
        errdefer input_product.deinit();

        return Type.create(context, try context.getBuiltin(.function_constructor), &.{ input_product, effect, result });
    }

    /// Create a new function type with the given input, result, and effect types.
    pub fn createFunctionAB(context: *Context, input: Type, result: Type, effect: Type) !Type {
        return Type.create(context, try context.getBuiltin(.function_constructor), &.{ input, effect, result });
    }

    /// Create a new type with the given constructor and input types.
    pub fn create(context: *Context, constructor: Constructor, inputs: []const Type) !Type {
        const type_list = try TypeList.create(context, inputs);
        errdefer type_list.deinit();

        return Type.init(context, .mutable, constructor, type_list);
    }

    /// Initialize a new Type with the given mutability, constructor, and input types.
    pub fn init(context: *Context, mutability: pl.Mutability, constructor: ?Constructor, inputs: ?TypeList) !Type {
        const id = try context.addRow(rows.Type, mutability, .{ .constructor = if (constructor) |x| x.id else .null, .inputs = if (inputs) |x| x.id.cast(rows.KeyList) else .null });
        return Type{ .id = id, .context = context };
    }

    /// Remove a Type from the graph, freeing its resources.
    pub fn deinit(self: Type) void {
        self.context.delRow(self.id);
    }

    /// `std.fmt` impl
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

    /// Override the constructor of this type.
    pub fn setConstructor(self: Type, constructor: Constructor) !void {
        try self.context.setCell(self.id, .constructor, constructor.id);
    }

    /// Get the constructor of this type.
    pub fn getConstructor(self: Type) ?Constructor {
        const id = self.context.getCell(self.id, .constructor) orelse return null;

        return wrapId(self.context, id);
    }

    /// Get the number of input types for this type.
    pub fn getInputTypeCount(self: Type) usize {
        return (self.getTypeInputs() orelse return 0).getCount();
    }

    /// Get a slice of input types for this type.
    pub fn getInputTypeSlice(self: Type) ?[]const Key {
        return (self.getTypeInputs() orelse return null).getSlice();
    }

    /// Get an input type for this type by its index.
    pub fn getInputTypeIndex(self: Type, index: usize) ?Type {
        const slice = self.getInputTypeSlice() orelse return null;

        if (index >= slice.len) return null;

        return wrapId(self.context, slice[index].toIdUnchecked(rows.Type));
    }

    /// Override the input types for this type.
    pub fn setTypeInputs(self: Type, inputs: TypeList) !void {
        try self.context.setCell(self.id, .inputs, inputs.id.cast(rows.KeyList));
    }

    /// Get the input TypeList for this type.
    pub fn getTypeInputs(self: Type) ?TypeList {
        const inputs = self.context.getCell(self.id, .inputs) orelse return null;
        return wrapId(self.context, inputs.cast(rows.TypeList));
    }

    /// Get the kind of the constructor for this type.
    pub fn getConstructorKind(self: Type) ?Kind {
        const constructor = self.getConstructor() orelse return null;

        return constructor.getKind();
    }

    /// Get the output tag of the constructor for this type.
    pub fn getConstructorOutputKindTag(self: Type) ?rows.Kind.Tag {
        return (self.getConstructorKind() orelse return null).getOutputTag();
    }

    /// Get the number of input kinds for the constructor of this type.
    pub fn getConstructorInputKindCount(self: Type) usize {
        return (self.getConstructorInputKinds() orelse return 0).getCount();
    }

    /// Get a slice of input kinds for the constructor of this type.
    pub fn getConstructorInputKindSlice(self: Type) ?[]const Key {
        return (self.getConstructorInputKinds() orelse return null).getSlice();
    }

    /// Get the input KindList for the constructor of this type.
    pub fn getConstructorInputKinds(self: Type) ?KindList {
        return (self.getConstructorKind() orelse return null).getInputs();
    }
};

/// A handle to an effect in the ir graph.
pub const Effect = struct {
    id: Id(rows.Effect),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Create a new effect with the given handler type list.
    pub fn init(context: *Context, handler_type_list: ?TypeList) !Effect {
        const id = try context.addRow(rows.Effect, .mutable, .{ .handler_type_list = if (handler_type_list) |x| x.id else .null });
        return Effect{ .id = id, .context = context };
    }

    /// Remove an Effect from the graph, freeing its resources.
    pub fn deinit(self: Effect) void {
        self.context.delRow(self.id);
    }

    /// Get the TypeList for the handlers of this effect.
    pub fn getHandlerTypeList(self: Effect) ?TypeList {
        const id = (self.context.table.effect.getCell(self.id, .handler_type_list) orelse return null).*;
        return wrapId(self.context, id);
    }

    /// Override the TypeList for the handlers of this effect.
    pub fn setHandlerTypeList(self: Effect, handler_type_list: TypeList) !void {
        try self.context.setCell(self.id, .handler_type_list, handler_type_list.id);
    }

    /// `std.fmt` impl
    pub fn format(self: Effect, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const handler_type_list = (self.context.table.effect.getCell(self.id, .handler_type_list) orelse return error.InvalidGraphState).*;

        if (self.context.getName(self.id)) |name| {
            try writer.print("({} {} : {})", .{name, self.id, handler_type_list});
        } else {
            try writer.print("({} : {})", .{self.id, handler_type_list});
        }
    }
};

/// A handle to an effect handler in the ir graph.
pub const Handler = struct {
    id: Id(rows.Handler),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Create a new handler for the provided effect, using the given function under the provided cancellation type and upvalues.
    pub fn init(context: *Context, effect: ?Effect, function: ?Function, cancellation_type: ?Type, upvalues: ?KeyList) !Handler {
        const id = try context.addRow(rows.Handler, .mutable, .{
            .effect = if (effect) |x| x.id else .null,
            .function = if (function) |x| x.id else .null,
            .cancellation_type = if (cancellation_type) |x| x.id else .null,
            .upvalues = if (upvalues) |x| x.id else .null,
        });

        return Handler{ .id = id, .context = context };
    }

    /// Remove a Handler from the graph, freeing its resources.
    pub fn deinit(self: Handler) void {
        self.context.delRow(self.id);
    }

    /// Get the effect this handler is associated with.
    pub fn getEffect(self: Handler) ?Effect {
        const id = (self.context.table.handler.getCell(self.id, .effect) orelse return null).*;
        return wrapId(self.context, id);
    }

    /// Override the effect this handler is associated with.
    pub fn setEffect(self: Handler, effect: Effect) !void {
        try self.context.setCell(self.id, .effect, effect.id);
    }

    /// Get the function implementing this handler's body.
    pub fn getFunction(self: Handler) ?Function {
        const id = (self.context.table.handler.getCell(self.id, .function) orelse return null).*;
        return wrapId(self.context, id);
    }

    /// Override the function implementing this handler's body.
    pub fn setFunction(self: Handler, func: Function) !void {
        try self.context.setCell(self.id, .function, func.id);
    }

    /// Get the type of cancellation used within this handler.
    pub fn getCancellationType(self: Handler) ?Type {
        const id = (self.context.table.handler.getCell(self.id, .cancellation_type) orelse return null).*;
        return wrapId(self.context, id);
    }

    /// Override the type of cancellation used within this handler.
    pub fn setCancellationType(self: Handler, ty: Type) !void {
        try self.context.setCell(self.id, .cancellation_type, ty.id);
    }

    /// Get the upvalues used by this handler.
    pub fn getUpvalues(self: Handler) ?KeyList {
        const id = (self.context.table.handler.getCell(self.id, .upvalues) orelse return null).*;
        return wrapId(self.context, id);
    }

    /// Override the upvalues used by this handler.
    pub fn setUpvalues(self: Handler, upvalues: KeyList) !void {
        try self.context.setCell(self.id, .upvalues, upvalues.id);
    }

    /// `std.fmt` impl
    pub fn format(self: Handler, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const name = self.context.getName(self.id);
        const effect = self.getEffect();
        try writer.print("({} {?} : {?})", .{self.id, name, effect});
    }
};

/// A handle to a constant in the ir graph; may be either a block or a buffer.
pub const Constant = struct {
    id: Id(rows.Constant),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Create a new constant from a block.
    pub fn fromBlock(context: *Context, ty: Type, block: Block) !Constant {
        const id = try context.addRow(rows.Constant, .mutable, .{ .type = ty.id, .data = Key.fromId(block.id) });
        return Constant{ .id = id, .context = context };
    }

    /// Create a new constant from a buffer.
    pub fn fromBuffer(context: *Context, ty: Type, buffer: Buffer) !Constant {
        const id = try context.addRow(rows.Constant, .mutable, .{ .type = ty.id, .data = Key.fromId(buffer.id) });
        return Constant{ .id = id, .context = context };
    }

    /// Create a new constant from a byte slice already owned by the ir context.
    pub fn fromOwnedBytes(context: *Context, ty: Type, owned_bytes: []const u8) !Constant {
        const buffer = try Buffer.fromOwnedBytes(context, owned_bytes);
        errdefer context.delRow(buffer.id);

        return Constant.fromBuffer(context, ty, buffer);
    }

    /// Create a new constant from an unowned byte slice.
    pub fn fromUnownedBytes(context: *Context, ty: Type, bytes: []const u8) !Constant {
        const buffer = try Buffer.create(context, bytes);
        errdefer context.delRow(buffer.id);

        return Constant.fromBuffer(context, ty, buffer);
    }

    /// Create a new constant with no data binding.
    pub fn init(context: *Context) !Constant {
        const id = try context.addRow(rows.Constant, .mutable, .{ });
        return Constant{ .id = id, .context = context };
    }

    /// Remove a Constant from the graph, freeing its resources.
    pub fn deinit(self: Constant) void {
        self.context.delRow(self.id);
    }

    /// Get the key binding this constant's data, if it has any.
    pub fn getDataKey(self: Constant) !Key {
        const key = self.context.getCell(self.id, .data) orelse return error.InvalidGraphState;
        return key;
    }

    /// Override the key binding this constant's data.
    pub fn setDataKey(self: Constant, key: Key) !void {
        try self.context.setCell(self.id, .data, key);
    }

    /// `std.fmt` impl
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

/// A handle to a global variable in the ir graph.
pub const Global = struct {
    id: Id(rows.Global),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Create a new global variable with the given type and initializer.
    pub fn init(context: *Context, ty: ?Type, initializer: ?Constant) !Global {
        const id = try context.addRow(rows.Global, .mutable, .{ .type = if (ty) |x| x.id else .null, .initializer = if (initializer) |x| x.id else .null });
        return Global{ .id = id, .context = context };
    }

    /// Remove a Global from the graph, freeing its resources.
    pub fn deinit(self: Global) void {
        self.context.delRow(self.id);
    }

    /// Get the type of this global variable.
    pub fn getType(self: Global) ?Type {
        const id = self.context.getCell(self.id, .type) orelse return null;
        return wrapId(self.context, id);
    }

    /// Override the type of this global variable.
    pub fn setType(self: Global, ty: Type) !void {
        try self.context.setCell(self.id, .type, ty.id);
    }

    /// Get the constant initializer of this global variable, if it has one.
    pub fn getInitializer(self: Global) ?Constant {
        const id = self.context.getCell(self.id, .initializer) orelse return null;
        return wrapId(self.context, id);
    }

    /// Override the constant initializer of this global variable.
    pub fn setInitializer(self: Global, initializer: Constant) !void {
        try self.context.setCell(self.id, .initializer, initializer.id);
    }

    /// `std.fmt` impl
    pub fn format(self: Global, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const name = self.getName();
        const ty = self.getType();
        const initializer = self.getInitializer();

        try writer.print("(𝓰𝓵𝓸𝓫𝓪𝓵 {} {?} : {?} = {?})", .{self.id, name, ty, initializer});
    }
};

/// A handle to a foreign address in the ir graph, which can be used to represent an external memory location linked by the runtime.
pub const ForeignAddress = struct {
    id: Id(rows.ForeignAddress),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Create a new foreign address for the given machine address and type.
    pub fn init(context: *Context, address: ?u64, ty: ?Type) !ForeignAddress {
        const id = try context.addRow(rows.ForeignAddress, .mutable, .{ .address = if (address) |x| x else 0, .type = if (ty) |x| x.id else .null });
        return ForeignAddress{ .id = id, .context = context };
    }

    /// Remove a ForeignAddress from the graph, freeing its resources.
    pub fn deinit(self: ForeignAddress) void {
        self.context.delRow(self.id);
    }

    /// `sdt.fmt` impl
    pub fn format(self: ForeignAddress, comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
        try self.id.format(fmt, opts, writer);
    }
};

/// A handle to a builtin address in the ir graph, which can be used to represent a built-in memory location provided by the runtime.
pub const BuiltinAddress = struct {
    id: Id(rows.BuiltinAddress),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Create a new builtin address for the given machine address and type.
    pub fn init(context: *Context, address: ?u64, ty: ?Type) !BuiltinAddress {
        const id = try context.addRow(rows.BuiltinAddress, .mutable, .{ .address = if (address) |x| x else 0, .type = if (ty) |x| x.id else .null });
        return BuiltinAddress{ .id = id, .context = context };
    }

    /// Remove a BuiltinAddress from the graph, freeing its resources.
    pub fn deinit(self: BuiltinAddress) void {
        self.context.delRow(self.id);
    }

    /// `std.fmt` impl
    pub fn format(self: BuiltinAddress, comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
        try self.id.format(fmt, opts, writer);
    }
};

/// A handle to an intrinsic in the ir graph, which represents things like specific bytecode instructions.
pub const Intrinsic = struct {
    id: Id(rows.Intrinsic),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Given a bytecode opcode, get a shared Intrinsic handle.
    pub fn intern(context: *Context, opcode: bytecode.Instruction.OpCode) !Intrinsic {
        const id = try context.internOpCode(opcode);
        return Intrinsic{ .id = id, .context = context };
    }

    /// `std.fmt` impl
    pub fn format(self: Intrinsic, comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
        try self.id.format(fmt, opts, writer);
    }

    /// Get the bytecode opcode for this intrinsic, if it is one.
    pub fn getOpCode(self: Intrinsic) ?bytecode.Instruction.OpCode {
        const tag = self.context.getCell(self.id, .tag) orelse return null;
        if (tag != .bytecode) return null;

        return self.context.getCell(self.id, .data).?.bytecode;
    }
};

/// A handle to a buffer in the ir graph, which can be used to store arbitrary byte arrays.
pub const Buffer = struct {
    id: Id(rows.Buffer),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Create a new buffer from a slice of bytes that is already owned by the ir context.
    pub fn fromOwnedBytes(context: *Context, owned_data: []const u8) !Buffer {
        const id = try context.addRow(rows.Buffer, .mutable, .{ .data = owned_data });
        return wrapId(context, id);
    }

    /// Create a new buffer from an unowned slice of bytes, which will be copied into the ir context's arena.
    pub fn create(context: *Context, unowned_data: []const u8) !Buffer {
        const owned_data = try context.arena.allocator().dupe(u8, unowned_data);
        errdefer context.arena.allocator().free(owned_data);

        const id = try context.addRow(rows.Buffer, .mutable, .{ .data = owned_data });
        return wrapId(context, id);
    }

    /// Create a new buffer with no data binding.
    pub fn init(context: *Context) !Buffer {
        const id = try context.addRow(rows.Buffer, .mutable, .{ });
        return wrapId(context, id);
    }

    /// Remove a Buffer from the graph, freeing its resources.
    pub fn deinit(self: Buffer) void {
        self.context.delRow(self.id);
    }

    /// Override the data slice of this buffer.
    /// * Provided slice should be owned by the ir context.
    pub fn setData(self: Buffer, data: []const u8) !void {
        return self.context.setCell(self.id, .data, data);
    }

    /// Get the data slice of this buffer.
    pub fn getData(self: Buffer) ?[]const u8 {
        return self.context.getCell(self.id, .data);
    }

    /// `std.fmt` impl
    pub fn format(self: Buffer, comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
        try self.id.format(fmt, opts, writer);
    }
};

/// A handle to a function in the ir graph; either a standard procedure or an effect-handler.
pub const Function = struct {
    id: Id(rows.Function),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Create a new function with the given type and a fresh, empty body.
    /// * Variable bindings will be created in the body block, for each input type of the function.
    pub fn create(context: *Context, ty: Type) !Function { // TODO: move variable binding/initial block creation to its own function
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

    /// Create a new function with the given type and body.
    /// * Does not create variable bindings for the input types of the function.
    pub fn init(context: *Context, ty: ?Type, body: ?Block) !Function {
        const id = try context.addRow(rows.Function, .mutable, .{ .type = if (ty) |x| x.id else .null, .body = if (body) |x| x.id else (try Block.init(context, null, null, null)).id });
        return wrapId(context, id);
    }

    /// Remove a Function from the graph, freeing its resources.
    pub fn deinit(self: Function) void {
        self.context.delRow(self.id);
    }

    /// `std.fmt` impl
    pub fn format(self: Function, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const name = self.context.getName(self.id);
        const ty = self.getType();
        const body = self.getBody();

        try writer.print("({} {?s} : {?} = {?})", .{self.id, name, ty, body});
    }

    /// Override the type of this function.
    pub fn setType(self: Function, ty: Type) !void {
        try self.context.setCell(self.id, .type, ty.id);
    }

    /// Get the type of this function.
    pub fn getType(self: Function) ?Type {
        return Type {
            .id = self.context.getCell(self.id, .type) orelse return null,
            .context = self.context,
        };
    }

    /// Override the body block of this function.
    pub fn setBody(self: Function, body: Block) !void {
        try self.context.setCell(self.id, .body, body.id);
    }

    /// Get the body block of this function.
    pub fn getBody(self: Function) ?Block {
        return Block {
            .id = self.context.getCell(self.id, .body) orelse return null,
            .context = self.context,
        };
    }

    /// Override the variables of this function's body block.
    pub fn setVariables(self: Function, variables: []const Variable) !void {
        const block = self.getBody() orelse return error.InvalidGraphState;
        try block.setVariables(try VariableList.create(self.context, variables));
    }

    /// Get the variables of this function's body block.
    pub fn getVariables(self: Function) ?VariableList {
        const block = self.getBody() orelse return null;
        return block.getVariables();
    }

    /// Get the contents of this function's body block.
    pub fn getContents(self: Function) ?KeyList {
        const block = self.getBody() orelse return null;
        return block.getContents();
    }

    /// Get the number of elements within the content of this function's body block.
    pub fn getContentCount(self: Function) ?usize {
        const block = self.getBody() orelse return null;
        return block.getContentCount();
    }

    /// Get a slice of the element keys within the content of this function's body block.
    pub fn getContentSlice(self: Function) ?[]const Key {
        const block = self.getBody() orelse return null;
        return block.getContentSlice();
    }
};

/// A handle to a dynamic scope in the ir graph, which can be used to manage inputs and handlers for effectful operations.
pub const DynamicScope = struct {
    id: Id(rows.DynamicScope),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Create a new dynamic scope with an empty input key list and handler list.
    pub fn new(context: *Context) !DynamicScope {
        const inputs = try KeyList.init(context);
        errdefer inputs.deinit();

        const handler_list = try HandlerList.init(context);
        errdefer handler_list.deinit();

        return DynamicScope.init(context, inputs, handler_list);
    }

    /// Create a new dynamic scope with the given inputs and handler list.
    pub fn init(context: *Context, inputs: KeyList, handler_list: HandlerList) !DynamicScope {
        const id = try context.addRow(rows.DynamicScope, .mutable, .{ .inputs = inputs.id, .handler_list = handler_list.id });
        return DynamicScope{ .id = id, .context = context };
    }

    /// Remove a DynamicScope from the graph, freeing its resources.
    pub fn deinit(self: DynamicScope) void {
        self.context.delRow(self.id);
    }

    /// `std.fmt` impl
    pub fn format(self: DynamicScope, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("({})", .{ self.id });
    }

    /// Override the inputs of this dynamic scope.
    pub fn setInputs(self: DynamicScope, inputs: KeyList) !void {
        try self.context.setCell(self.id, .inputs, inputs.id);
    }

    /// Get the inputs of this dynamic scope.
    pub fn getInputs(self: DynamicScope) ?KeyList {
        const inputs = self.context.getCell(self.id, .inputs) orelse return null;
        return wrapId(self.context, inputs);
    }

    /// Override the handler list of this dynamic scope.
    pub fn setHandlerList(self: DynamicScope, handler_list: HandlerList) !void {
        try self.context.setCell(self.id, .handler_list, handler_list.id);
    }

    /// Get the handler list of this dynamic scope.
    pub fn getHandlerList(self: DynamicScope) ?HandlerList {
        const handler_list = self.context.getCell(self.id, .handler_list) orelse return null;
        return wrapId(self.context, handler_list);
    }

    /// Get the number of inputs in this dynamic scope.
    pub fn getInputCount(self: DynamicScope) usize {
        return (self.getInputs() orelse return 0).getCount();
    }

    /// Get the number of handlers in this dynamic scope.
    pub fn getHandlerCount(self: DynamicScope) usize {
        return (self.getHandlerList() orelse return 0).getCount();
    }
};

/// A handle to a variable in the ir graph, which can be used to represent mutable state within a block.
pub const Variable = struct {
    id: Id(rows.Variable),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Create a new variable with the given type.
    pub fn create(context: *Context, ty: Type) !Variable {
        return Variable.init(context, ty);
    }

    /// Create a new variable with the given type.
    pub fn init(context: *Context, ty: ?Type) !Variable {
        const id = try context.addRow(rows.Variable, .mutable, .{ .type = if (ty) |t| t.id else .null });
        return wrapId(context, id);
    }

    /// Remove a Variable from the graph, freeing its resources.
    pub fn deinit(self: Variable) void {
        self.context.delRow(self.id);
    }

    /// `std.fmt` impl
    pub fn format(self: Variable, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const name = self.context.getName(self.id);
        const ty = self.getType();

        try writer.print("(𝓿𝓪𝓻 {} {?s} : {?})", .{self.id, name, ty});
    }

    /// Override the type of this variable.
    pub fn setType(self: Variable, ty: Type) !void {
        try self.context.setCell(self.id, .type, ty.id);
    }

    /// Get the type of this variable.
    pub fn getType(self: Variable) ?Type {
        const id = self.context.getCell(self.id, .type) orelse return null;
        return wrapId(self.context, id);
    }
};

/// A handle to a block in the ir graph, which can contain
/// variables, a dynamic scope binding effect handlers to those variables, instructions,
/// and other blocks.
/// Instructions and blocks are stored in execution order.
pub const Block = struct {
    id: Id(rows.Block),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Create a new block with the given variables, dynamic scope, and empty contents.
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

    /// Create a new block with the given variables, dynamic scope, and contents.
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

    /// Remove a Block from the graph, freeing its resources.
    pub fn deinit(self: Block) void {
        self.context.delRow(self.id);
    }

    /// `std.fmt` impl
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

    /// Override the variables of this block.
    pub fn setVariables(self: Block, variables: VariableList) !void {
        try self.context.setCell(self.id, .variables, variables.id);
    }

    /// Get the VariableList of this block.
    pub fn getVariables(self: Block) ?VariableList {
        const variables = (self.context.table.block.getCell(self.id, .variables) orelse return null).*;
        return wrapId(self.context, variables.cast(rows.VariableList));
    }

    /// Override the dynamic scope of this block.
    pub fn setDynamicScope(self: Block, dynamic_scope: DynamicScope) !void {
        try self.context.setCell(self.id, .dynamic_scope, dynamic_scope.id);
    }

    /// Get the DynamicScope of this block.
    pub fn getDynamicScope(self: Block) ?DynamicScope {
        const dynamic_scope = (self.context.table.block.getCell(self.id, .dynamic_scope) orelse return null).*;
        return DynamicScope{ .id = dynamic_scope.cast(rows.DynamicScope), .context = self.context };
    }

    /// Override the contents of this block.
    pub fn setContents(self: Block, contents: KeyList) !void {
        try self.context.setCell(self.id, .contents, contents.id);
    }

    /// Get the ordered content KeyList of this block.
    pub fn getContents(self: Block) ?KeyList {
        const instructions = (self.context.table.block.getCell(self.id, .contents) orelse return null).*;
        return KeyList{ .id = instructions.cast(rows.KeyList), .context = self.context };
    }

    /// Get the number of variables in this block.
    pub fn getVariableCount(self: Block) usize {
        return (self.getVariables() orelse return 0).getCount();
    }

    /// Get a slice of the variable keys in this block.
    pub fn getVariableSlice(self: Block) ?[]const Key {
        return (self.getVariables() orelse return null).getSlice();
    }

    /// Get the number of elements in the contents of this block.
    pub fn getContentCount(self: Block) ?usize {
        return (self.getContents() orelse return null).getCount();
    }

    /// Get a slice of the element keys in the contents of this block.
    pub fn getContentSlice(self: Block) ?[]const Key {
        return (self.getContents() orelse return null).getSlice();
    }

    /// Append a new element to the contents of this block.
    /// * Expects either another `Block`, or an `Instruction`.
    /// * Self-containment is an error.
    pub fn append(self: Block, value: anytype) !void {
        const contents = self.getContents() orelse return error.InvalidGraphState;
        try contents.append(Key.fromId(value.id));
    }

    /// Create a new variable with the given type in this block.
    pub fn bindVariable(self: Block, ty: Type) !Variable {
        const variables = self.getVariables() orelse return error.InvalidGraphState;
        const variable = try Variable.create(self.context, ty);

        try variables.append(variable);

        return variable;
    }
};

/// A handle to an instruction in the ir graph.
pub const Instruction = struct {
    id: Id(rows.Instruction),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Create a new instruction with the given operation.
    pub fn create(context: *Context, operation: Operation) !Instruction {
        return Instruction.init(context, null, operation);
    }

    /// Create a new instruction with the given operation, optionally specifying its type.
    /// * Type can be computed later if needed.
    pub fn init(context: *Context, ty: ?Type, operation: ?Operation) !Instruction {
        const id = try context.addRow(rows.Instruction, .mutable, .{ .type = if (ty) |t| t.id else .null, .operation = operation orelse .@"unreachable" });
        return wrapId(context, id);
    }

    /// Remove an Instruction from the graph, freeing its resources.
    pub fn deinit(self: Instruction) void {
        self.context.delRow(self.id);
    }

    /// `std.fmt` impl
    pub fn format(self: Instruction, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}", .{ @tagName(self.getOperation()) });
    }

    /// Override the type of this instruction.
    pub fn setType(self: Instruction, ty: Type) !void {
        try self.context.setCell(self.id, .type, ty.id);
    }

    /// Get the type of this instruction.
    pub fn getType(self: Instruction) ?Type { // TODO: compute here?
        const id = self.context.getCell(self.id, .type) orelse return null;
        return wrapId(self.context, id);
    }

    /// Override the operation of this instruction.
    pub fn setOperation(self: Instruction, operation: Operation) !void {
        try self.context.setCell(self.id, .operation, operation);
    }

    /// Get the operation of this instruction.
    pub fn getOperation(self: Instruction) Operation {
        return self.context.getCell(self.id, .operation) orelse return .@"unreachable";
    }
};

/// A handle to a control edge in the ir graph, which represents a control flow dependency between two nodes.
/// While operational nodes are arranged in execution order within Blocks,
/// these edges represent flow between branches and phi instructions.
pub const ControlEdge = struct {
    id: Id(rows.ControlEdge),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Create a new control edge with no source or destination.
    pub fn init(context: *Context) !ControlEdge {
        const id = try context.addRow(rows.ControlEdge, .mutable, .{ });
        return ControlEdge{ .id = id, .context = context };
    }

    /// Create a new control edge with the given source and destination keys and indices.
    pub fn create(context: *Context, src: Key, dest: Key, source_index: usize, destination_index: usize) !ControlEdge {
        const id = try context.addRow(rows.ControlEdge, .mutable, .{ .source = src, .destination = dest, .source_index = source_index, .destination_index = destination_index});
        return ControlEdge{ .id = id, .context = context };
    }

    /// Remove a ControlEdge from the graph, freeing its resources.
    pub fn deinit(self: ControlEdge) void {
        self.context.delRow(self.id);
    }

    /// `std.fmt` impl
    pub fn format(self: ControlEdge, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("({})", .{ self.id });
    }

    /// Override the source of this control edge.
    pub fn setSource(self: ControlEdge, src: Key) !void {
        try self.context.setCell(self.id, .source, src);
    }

    /// Get the source of this control edge.
    pub fn getSource(self: ControlEdge) ?Key {
        return self.context.getCell(self.id, .source);
    }

    /// Override the destination of this control edge.
    pub fn setDestination(self: ControlEdge, destination: Key) !void {
        try self.context.setCell(self.id, .destination, destination);
    }

    /// Get the destination of this control edge.
    pub fn getDestination(self: ControlEdge) ?Key {
        return self.context.getCell(self.id, .destination);
    }

    /// Override the source index of this control edge.
    pub fn setSourceIndex(self: ControlEdge, index: usize) !void {
        try self.context.setCell(self.id, .source_index, index);
    }

    /// Get the source index of this control edge.
    pub fn getSourceIndex(self: ControlEdge) usize {
        return self.context.getCell(self.id, .source_index) orelse 0;
    }

    /// Get the destination index of this control edge.
    pub fn getDestinationIndex(self: ControlEdge) usize {
        return self.context.getCell(self.id, .destination_index) orelse 0;
    }

    /// Override the destination index of this control edge.
    pub fn setDestinationIndex(self: ControlEdge, index: usize) !void {
        try self.context.setCell(self.id, .destination_index, index);
    }
};

/// A handle to a data edge in the ir graph, which represents a data dependency between two nodes.
pub const DataEdge = struct {
    id: Id(rows.DataEdge),
    context: *Context,

    pub usingnamespace HandleBase(@This());

    /// Create a new data edge with no source or destination.
    pub fn init(context: *Context) !DataEdge {
        const id = try context.addRow(rows.DataEdge, .mutable, .{ });
        return wrapId(context, id);
    }

    /// Create a new data edge with the given source and destination keys and indices.
    pub fn create(context: *Context, src: Key, destination: Key, source_index: usize, destination_index: usize) !DataEdge {
        const id = try context.addRow(rows.DataEdge, .mutable, .{ .source = src, .destination = destination, .source_index = source_index, .destination_index = destination_index });
        return wrapId(context, id);
    }

    /// Remove a DataEdge from the graph, freeing its resources.
    pub fn deinit(self: DataEdge) void {
        self.context.delRow(self.id);
    }

    /// `std.fmt` impl
    pub fn format(self: DataEdge, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("({})", .{ self.id });
    }

    /// Override the source of this data edge.
    pub fn setSource(self: DataEdge, src: Key) !void {
        try self.context.setCell(self.id, .source, src);
    }

    /// Get the source of this data edge.
    pub fn getSource(self: DataEdge) ?Key {
        return self.context.getCell(self.id, .source);
    }

    /// Override the destination of this data edge.
    pub fn setDestination(self: DataEdge, destination: Key) !void {
        try self.context.setCell(self.id, .destination, destination);
    }

    /// Get the destination of this data edge.
    pub fn getDestination(self: DataEdge) ?Key {
        return self.context.getCell(self.id, .destination);
    }

    /// Override the source index of this data edge.
    pub fn setSourceIndex(self: DataEdge, index: usize) !void {
        try self.context.setCell(self.id, .source_index, index);
    }

    /// Get the source index of this data edge.
    pub fn getSourceIndex(self: DataEdge) usize {
        return self.context.getCell(self.id, .source_index) orelse 0;
    }

    /// Override the destination index of this data edge.
    pub fn setDestinationIndex(self: DataEdge, index: usize) !void {
        try self.context.setCell(self.id, .destination_index, index);
    }

    /// Get the destination index of this data edge.
    pub fn getDestinationIndex(self: DataEdge) usize {
        return self.context.getCell(self.id, .destination_index) orelse 0;
    }
};

/// Simple visitor structure for the ir graph; collects nodes.
pub const Visitor = struct {
    context: *Context,
    visited: pl.UniqueReprSet(Key, 80),

    /// Initialize a new Visitor with the given context.
    pub fn init(context: *Context) Visitor {
        return .{
            .context = context,
            .visited = .empty,
        };
    }

    /// Deinitialize the Visitor, freeing its resources.
    pub fn deinit(self: *Visitor) void {
        self.visited.deinit(self.context.arena.child_allocator);
    }

    /// Clear the visited set, retaining its capacity.
    pub fn clear(self: *Visitor) void {
        self.visited.clearRetainingCapacity();
    }

    /// Check if the given key has already been visited.
    pub fn alreadyVisited(self: *Visitor, key: Key) !bool {
        return (try self.visited.getOrPut(self.context.arena.child_allocator, key)).found_existing;
    }

    /// Visit all nodes reachable (via control flow) from the given key, recursively.
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


test "ir_basic_integration" {
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

    // std.debug.print("{}", .{function});

    var keys = context.keyIterator();

    while (keys.next()) |key| {
        log.debug("{}", .{key});
        // std.debug.print("{}\n", .{key});
    }
}
