//! # ir
//! This namespace provides a mid-level hybrid SSA Intermediate Representation (ir) for Ribbon.
//!
//! It is used to represent the program in a way that is easy to optimize and transform.
//!
//! This ir targets:
//! * rvm's core bytecode (via the `bytecode` module)
//! * native machine code, in two ways:
//!    + in house x64 jit (the `machine` module)
//!    + freestanding (eventually)
//!
//! ### TODO
//!
//! #### 1. Core IR Infrastructure & Correctness
//! *   ** Implement an IR Verifier:**
//!     *   Verify that every block ends with a `Termination` instruction.
//!     *   Check that `phi` nodes only appear at the beginning of a block.
//!     *   Validate that the number of `phi` operands matches the number of predecessor blocks.
//!     *   Ensure that an instruction's result is used only by instructions that it dominates (the core SSA property).
//!     *   Type check every instruction, ensuring operand types match what the operation expects.
//!     *   Verify that `prev` and `next` pointers in blocks are consistent.
//!     *   Check that `predecessors` and `successors` lists are correctly maintained.
//!
//! *   ** Create a Builder API:**
//!     *   Design a `Builder` struct to simplify IR construction.
//!     *   Methods like `builder.setInsertPoint(*Block)`, `builder.createAdd(lhs, rhs, ?name)`, `builder.createBr(dest_block)`.
//!     *   The builder should handle memory allocation for instructions and operands, and automatically link instructions into the block.
//!
//! *   ** SSA Construction Utilities:**
//!     *   Implement a standard "Mem2Reg" pass that converts stack allocations (`stack_alloc`, `load`, `store`) of local variables into SSA registers (`phi` nodes). This is a cornerstone of building SSA form from an AST.
//!     *   Develop an algorithm for computing dominance frontiers, which is required for placing `phi` nodes.
//!
//! *   ** Serialization/Deserialization:**
//!     *   Create a textual representation of the IR for debugging. This is invaluable for inspecting the output of compiler passes.
//!     *   Implement a binary serialization format (e.g., using Zig's `std.bincode` or a custom format) for caching IR or saving it for later stages.
//!
//! #### 2. Memory Management
//!
//! *   ** Address the Memory Pool `TODO`s:**
//!     *   In the `Module` struct, replace `std.heap.MemoryPool` for `function_pool` and `block_pool` with a custom pool allocator that supports iteration.
//!         This is critical for properly de-initializing a module and all the functions/blocks it owns. A simple approach is an `ArrayList` of allocated pointers.
//!
//! #### 3. Type System (`Term`s)
//!
//! *   ** Resolve `cbr` `TODO`s:**
//!     *   In `terms.HandlerSet`, the `cancellation_point` is `void`. This needs to be defined as a proper block reference.
//!     *   Develop a stable `cbr` strategy for block references. Since memory addresses change, we cannot hash the pointer directly.
//!         A common solution is to use a unique ID (`u64`) assigned to each block upon creation.
//! *   ** Implement Type System `TODO`s:**
//!     *   Add support for bit-offset pointers as mentioned in the `PointerType` `TODO`.
//! *   ** Refine Term Representation:**
//!     *   Consider if all `Term`s truly need to be arena-allocated.
//!         Simple terms like `IntegerType` with a small, fixed number of fields could potentially be passed by value if it proves more efficient, though the current pointer-based approach is more uniform.
//!
//! #### 4. Instruction Set & Semantics
//!
//! *   ** Define User-Defined Operation (`_`) Semantics:**
//!     *   The `Operation._` is only the start for extensibility.
//!         A mechanism is needed for extensions to register these operations,
//!         including their type-checking rules, semantics, and how they are eventually lowered or code-generated.
//! *   ** Specify Intrinsic Functions:**
//!     *   Many operations are better represented as "intrinsics" (special functions known to the compiler) rather than low-level instructions.
//!         This could include things like `memcpy`, `memset`, or complex math operations. Decide which should be instructions vs. intrinsics.
//! *   ** Define `reify` and `lift` Semantics:**
//!     *   The purpose of `reify` (term to SSA) and `lift` (SSA to term) is clear, but their exact semantics and constraints need to be rigorously defined.
//!         For example, what happens if we try to `reify` a type that has no runtime representation?
//!
//! #### 5. Analysis & Transformation Framework
//!
//! *   ** Create a Pass Manager:**
//!     *   Design a system to schedule and run analysis and transformation passes over the IR.
//!     *   It should handle dependencies between passes (e.g., a dominance analysis must run before Mem2Reg).
//!     *   It should support passes at different granularities (Module, Function, etc.).
//! *   ** Implement Standard Analyses:**
//!     *   **Dominator Tree:** Essential for SSA construction and many optimizations.
//!     *   **Control Flow Graph (CFG) Analysis:** Already partially present with `predecessors`/`successors`, but could be formalized.
//!     *   **Alias Analysis:** To determine if two pointers can refer to the same memory location. Crucial for reordering `load`/`store` operations.
//!     *   **Loop Analysis:** To find loops in the CFG, which are prime candidates for optimization.
//! *   ** Implement Foundational Optimizations:**
//!     *   Constant Folding and Propagation
//!     *   Dead Code Elimination
//!     *   Common Subexpression Elimination
//!     *   Instruction Combining
//!     *   Global Value Numbering (GVN)
//!
//! #### 6. Tooling & Debugging
//!
//! *   ** Source-Level Debug Information:**
//!     *   Extend the IR to carry debug information. `Instruction`s should be able to store a source location (file, line, column).
//!     *   This is non-negotiable for producing debuggable executables.
//! *   ** Graph Visualization:**
//!     *   Write a utility to export the CFG of a `Function` to a format like Graphviz `.dot`. This is one of the most effective ways to debug a compiler's IR.
//!
//! #### 7. Documentation
//!
//! *   ** Write Comprehensive Documentation:**
//!     *   Document the semantics of every single `Operation` and `Termination`.
//!     *   Explain the purpose and structure of every `Term`.
//!     *   Provide a high-level overview of the IR architecture and its design philosophy.
//!     *   Document the invariants that the IR Verifier checks.
const ir = @This();

const std = @import("std");
const log = std.log.scoped(.Rir);

const core = @import("core");
const common = @import("common");
const analysis = @import("analysis");
const bytecode = @import("bytecode");

test {
    // std.debug.print("semantic analysis for ir\n", .{});
    std.testing.refAllDecls(@This());
}

/// The "universe" for an ir compilation session.
pub const Context = struct {
    // memory management //
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    // module data //

    /// Map from ModuleGUID to an index in the `modules` array
    modules: common.UniqueReprMap(ModuleGUID, *Module) = .empty,
    /// Map from module name string to ModuleGUID
    name_to_module_guid: common.StringMap(ModuleGUID) = .empty,

    // shared content //

    /// A set of all names in the context, de-duplicated and owned by the context itself
    interned_name_set: common.StringSet = .empty,
    /// A set of all constant data blobs in the context, de-duplicated and owned by the context itself
    interned_data_set: common.HashSet(*const BlobHeader, BlobHeader.HashContext) = .empty,

    /// Contains terms that are not subject to interface association, such as ints and arrays
    shared_terms: common.HashSet(Term, Term.IdentityContext) = .empty,
    /// Contains terms that are commonly used, such as "i32"
    named_shared_terms: common.StringMap(Term) = .empty,

    /// Map from @typeName to Tag
    tags: common.StringMap(Tag) = .empty,
    /// Map from Tag to TermVTable for the associated type
    vtables: common.UniqueReprMap(Tag, TermVTable) = .empty,

    pub fn init(allocator: std.mem.Allocator) *Context {
        const self = try allocator.create(Context);

        self.* = Context{
            .allocator = allocator,
            .arena = .init(allocator),
        };

        inline for (comptime std.meta.declarations(terms)) |decl| {
            try self.registerTermType(@field(terms, decl.name));
        }

        return self;
    }

    pub fn deinit(self: *Context) void {
        var module_it = self.modules.valueIterator();
        while (module_it.next()) |module_p2p| module_p2p.*.deinit();
        self.modules.deinit(self.allocator);

        self.name_to_module_guid.deinit(self.allocator);
        self.interned_name_set.deinit(self.allocator);
        self.interned_data_set.deinit(self.allocator);
        self.shared_terms.deinit(self.allocator);
        self.named_shared_terms.deinit(self.allocator);

        self.arena.deinit();

        self.allocator.destroy(self);
    }

    pub fn tagFromType(self: *Context, comptime T: type) ?Tag {
        return self.tags.get(@typeName(T));
    }

    pub fn registerTermType(self: *Context, comptime T: type) error{ DuplicateTermType, TooManyTermTypes, OutOfMemory }!void {
        if (self.tags.get(@typeName(T))) {
            return error.DuplicateTermType;
        }

        const tag_number = self.tags.count();
        if (tag_number > std.math.maxInt(std.meta.Tag(Tag))) {
            return error.TooManyTermTypes;
        }

        const tag: Tag = @enumFromInt(tag_number);

        try self.tags.put(self.allocator, @typeName(T), tag);
        errdefer _ = self.tags.remove(@typeName(T));

        try self.vtables.put(self.allocator, tag, TermVTable{
            .eql = &T.eql,
            .hash = &T.hash,
            .cbr = &T.cbr,
        });
        errdefer _ = self.vtables.remove(tag);
    }

    pub fn createModule(self: *Context, name: Name, guid: ModuleGUID) !*Module {
        if (self.modules.contains(guid)) {
            return error.DuplicateModuleGUID;
        }

        if (self.name_to_module_guid.contains(name)) {
            return error.DuplicateModuleName;
        }

        const new_module = try self.arena.allocator().create(Module);
        const interned_name = try self.internName(name);

        new_module.* = Module{
            .root = self,
            .guid = guid,
            .name = interned_name,
        };

        try self.name_to_module_guid.put(self.allocator, interned_name, guid);
        errdefer _ = self.name_to_module_guid.remove(interned_name);

        try self.modules.put(self.allocator, guid, new_module);
        errdefer _ = self.modules.remove(guid);
    }

    pub fn internName(self: *Context, name: []const u8) !Name {
        const gop = try self.interned_name_set.getOrPut(self.allocator, name);

        if (!gop.found_existing) {
            const owned_buf = try self.arena.allocator().dupe(u8, name);
            gop.key_ptr.* = owned_buf;
        }

        return Name{ .value = gop.key_ptr.* };
    }

    pub fn internData(self: *Context, alignment: core.Alignment, bytes: []const u8) !*const BlobHeader {
        if (self.interned_data_set.getKeyAdapted(.{ alignment, bytes }, BlobHeader.AdaptedHashContext{})) |existing_blob| {
            return existing_blob;
        }

        const new_buf = try self.arena.allocator().alignedAlloc(u8, .fromByteUnits(@alignOf(BlobHeader)), @sizeOf(BlobHeader) + bytes.len);
        const blob: *const BlobHeader = @ptrCast(new_buf.ptr);
        @memcpy(new_buf.ptr + @sizeOf(BlobHeader), bytes);
        try self.interned_data_set.put(self.allocator, blob, {});

        return blob;
    }

    pub fn createTerm(self: *Context, comptime T: type, module: ?*Module) error{ ZigTypeNotRegistered, OutOfMemory }!struct { *T, Term } {
        const ptr = try TermData(T).allocate(self, module);
        return .{ ptr, Term.fromPtr(self, ptr) };
    }

    pub fn addTerm(self: *Context, module: ?*Module, value: anytype) error{OutOfMemory}!Term {
        const T = @TypeOf(value);
        const ptr, const term = try self.createTerm(T, module);
        ptr.* = value;
        return term;
    }

    pub fn getOrCreateSharedTerm(self: *Context, name: ?Name, value: anytype) error{ MismatchedNamedTermDefinitions, OutOfMemory }!Term {
        const T = @TypeOf(value);
        if (self.shared_terms.getKeyAdapted(&value, Term.AdaptedIdentityContext(T){ .ctx = self })) |existing_term| {
            if (name) |new_name| {
                if (self.named_shared_terms.get(new_name)) |named_term| {
                    if (named_term != existing_term) return error.MismatchedNamedTermDefinitions;
                } else {
                    try self.named_shared_terms.put(self.allocator, new_name, existing_term);
                }
            }

            return existing_term;
        } else {
            const new_term = try self.addTerm(null, value);
            if (name) |new_name| {
                if (self.named_shared_terms.contains(new_name)) return error.MismatchedNamedTermDefinitions;
                try self.named_shared_terms.put(self.allocator, new_name, new_term);
            }
            try self.shared_terms.put(self.allocator, new_term, {});

            return new_term;
        }
    }

    pub fn getNamedSharedTerm(self: *Context, name: Name) ?Term {
        return self.named_shared_terms.get(name.value);
    }
};

/// Identifier for a type within the IR term type registry
pub const Tag = enum(u8) { _ };

pub const TermHeader = struct {
    root: *Context,
    module: ?*Module,
    tag: Tag,
    value_offset: u8,
    cached_cbr: ?[]const u8 = null,

    fn toTermData(self: *TermHeader, comptime T: type) error{ZigTypeMismatch}!*TermData(T) {
        if (self.tag != self.root.tagFromType(T)) return error.ZigTypeMismatch;
        return @fieldParentPtr("header", self);
    }

    fn toTerm(self: *TermHeader) Term {
        return .{
            .tag = self.tag,
            .header_offset = self.value_offset,
            .ptr = @intFromPtr(self) + self.value_offset,
        };
    }

    fn toTermPtr(self: *TermHeader, comptime T: type) error{ZigTypeMismatch}!*T {
        return &(try self.toTermData(T)).value;
    }

    fn toOpaqueTermAddress(self: *TermHeader) *anyopaque {
        return @ptrFromInt(@intFromPtr(self) + self.value_offset);
    }

    fn fromTerm(term: Term) *TermHeader {
        return term.toHeader();
    }

    fn fromTermPtr(ptr: anytype) *TermHeader {
        const data: *TermData(@typeInfo(@TypeOf(ptr)).pointer.child) = @fieldParentPtr("value", ptr);
        return &data.header;
    }

    fn getCbr(self: *TermHeader) error{OutOfMemory}![]const u8 {
        if (self.cached_cbr) |cached| {
            return cached;
        }

        const allocator = self.root.arena.allocator();
        const new_hash = try self.root.vtables[@intFromEnum(self.tag)].cbr(self.toOpaqueTermAddress(), allocator);
        self.cached_cbr = new_hash;
        return new_hash;
    }
};

pub const TermVTable = struct {
    eql: *const fn (*const anyopaque, *const anyopaque) bool,
    hash: *const fn (*const anyopaque, *std.hash.Fnv1a_64) void,
    cbr: *const fn (*const anyopaque, std.mem.Allocator) error{OutOfMemory}![]const u8,
};

pub fn TermData(comptime T: type) type {
    return struct {
        const Self = @This();

        header: TermHeader,
        value: T,

        fn allocate(context: *Context, module: ?*Module) error{ ZigTypeNotRegistered, OutOfMemory }!*T {
            const self = try context.arena.allocator().create(Self);
            self.header = .{
                .root = context,
                .module = module,
                .tag = context.tagFromType(T) orelse return error.ZigTypeNotRegistered,
                .value_offset = @offsetOf(Self, "value"),
            };
            return &self.value;
        }
    };
}

pub const Term = packed struct(u64) {
    tag: Tag,
    header_offset: u8,
    ptr: u48,

    fn fromPtr(context: *Context, ptr: anytype) error{ZigTypeMismatch}!Term {
        const T = @typeInfo(@TypeOf(ptr)).pointer.child;
        return .{
            .tag = context.tagFromType(T) orelse return error.ZigTypeMismatch,
            // we need the offset of value so that we can subtract it to get header
            .header_offset = @offsetOf(TermData(T), "value"),
            .ptr = @intCast(@intFromPtr(ptr)),
        };
    }

    pub fn toMutPtr(self: Term, context: *const Context, comptime T: type) error{ZigTypeMismatch}!*T {
        if (self.tag != context.tagFromType(T)) return error.ZigTypeMismatch;
        return @ptrFromInt(self.ptr);
    }

    pub fn toPtr(self: Term, context: *const Context, comptime T: type) error{ZigTypeMismatch}!*const T {
        if (self.tag != context.tagFromType(T)) return error.ZigTypeMismatch;
        return @ptrFromInt(self.ptr);
    }

    fn toOpaquePtr(self: Term) *anyopaque {
        return @ptrFromInt(self.ptr);
    }

    fn toHeader(self: Term) *TermHeader {
        return @ptrFromInt(self.ptr - self.header_offset);
    }

    pub fn toRoot(self: Term) *Context {
        return self.toHeader().root;
    }

    pub fn toModule(self: Term) ?*Module {
        return self.toHeader().module;
    }

    fn toTermData(self: Term, comptime T: type) error{ZigTypeMismatch}!*TermData(T) {
        return self.toHeader().toTermData();
    }

    pub fn getCbr(self: Term) error{OutOfMemory}![]const u8 {
        return self.toHeader().getCbr();
    }

    pub fn AdaptedIdentityContext(comptime T: type) type {
        return struct {
            ctx: *Context,

            pub fn hash(self: @This(), t: *const T) u64 {
                const tag = self.ctx.tagFromType(T);
                var hasher = std.hash.Fnv1a_64.init();
                hasher.hash(std.mem.asBytes(&tag));
                self.ctx.vtables[@intFromEnum(tag)].cbr(t, &hasher);
                return hasher.final();
            }

            pub fn eql(self: @This(), a: Term, b: *const T) bool {
                const tag = self.ctx.tagFromType(T);
                if (a.tag != tag) return false;
                return self.ctx.vtables[@intFromEnum(tag)].eql(a.toOpaquePtr(), b);
            }
        };
    }

    pub const IdentityContext = struct {
        pub fn hash(_: @This(), t: Term) u64 {
            var hasher = std.hash.Fnv1a_64.init();
            hasher.hash(std.mem.asBytes(&t.tag));
            t.toHeader().root.vtables[@intFromEnum(t.tag)].hash(t.toOpaquePtr(), &hasher);
            return hasher.final();
        }

        pub fn eql(_: @This(), a: Term, b: Term) bool {
            if (a.tag != b.tag) return false;
            return a.toHeader().root.vtables[@intFromEnum(a.tag)].eql(a.toOpaquePtr(), b.toOpaquePtr());
        }
    };
};

/// A unique identifier for a ribbon module.
pub const ModuleGUID = enum(u128) { _ };

pub const Name = struct {
    value: []const u8,
};

pub const BlobHeader = struct {
    layout: core.Layout,

    pub inline fn getBytes(self: *const BlobHeader) []const u8 {
        return (@as([*]const u8, @ptrCast(self)) + @sizeOf(BlobHeader))[0..self.layout.size];
    }

    pub const AdaptedHashContext = struct {
        pub fn hash(_: @This(), descriptor: struct { core.Alignment, []const u8 }) u64 {
            const layout = core.Layout{ .alignment = descriptor[0], .size = descriptor[1].len };
            var hasher = std.hash.Fnv1a_64.init();
            hasher.update(std.mem.asBytes(&layout));
            hasher.update(descriptor[1]);
            return hasher.final();
        }

        pub fn eql(_: @This(), a: *const BlobHeader, b: struct { core.Alignment, []const u8 }) bool {
            const layout = core.Layout{ .alignment = b[0], .size = b[1].len };
            if (a.layout != layout) return false;
            return std.mem.eql(u8, a.getBytes(), b[1]);
        }
    };

    pub const HashContext = struct {
        pub fn hash(_: @This(), blob: *const BlobHeader) u64 {
            var hasher = std.hash.Fnv1a_64.init();
            hasher.update(std.mem.asBytes(&blob.layout));
            hasher.update(blob.getBytes());
            return hasher.final();
        }

        pub fn eql(_: @This(), a: *const BlobHeader, b: *const BlobHeader) bool {
            if (a.layout != b.layout) return false;
            return std.mem.eql(u8, a.getBytes(), b.getBytes());
        }
    };
};

/// An ir module, representing a single compilation unit within a context/compilation session.
pub const Module = struct {
    root: *Context,
    guid: ModuleGUID,
    name: Name,

    exported_symbols: common.StringMap(Binding) = .empty,
    function_pool: std.heap.MemoryPool(Function), // TODO: we need a pool-like allocator that allows us to actually iterate the allocations for memory management
    block_pool: std.heap.MemoryPool(Block), // TODO: we need a pool-like allocator that allows us to actually iterate the allocations for memory management

    pub fn deinit(self: *Module) void {
        self.exported_symbols.deinit(self.root.allocator);
    }

    pub fn exportTerm(self: *Module, name: Name, term: Term) error{ DuplicateModuleExports, OutOfMemory }!void {
        const gop = try self.exported_symbols.getOrPut(self.root.allocator, name.value);
        if (gop.found_existing) {
            return error.DuplicateModuleExports;
        }
        gop.value_ptr.* = .{ .term = term };
    }

    pub fn exportFunction(self: *Module, name: Name, function: *Function) error{ DuplicateModuleExports, OutOfMemory }!void {
        const gop = try self.exported_symbols.getOrPut(self.root.allocator, name.value);
        if (gop.found_existing) {
            return error.DuplicateModuleExports;
        }
        gop.value_ptr.* = .{ .function = function };
    }
};

pub const Binding = union(enum) {
    term: Term,
    function: *Function,
};

pub const Instruction = struct {
    /// Optional debug name for the SSA variable binding the result of this operation.
    name: ?Name,
    /// The type of value produced by this operation, if any.
    type: Term,
    /// The command code for this operation, ie an Operation or Termination.
    command: u8,

    /// The block that contains this operation.
    parent: *Block,
    /// The first operation in the block, or null if this is the first operation.
    prev: ?*Instruction = null,
    /// The next operation in the block, or null if this is the last operation.
    next: ?*Instruction = null,

    /// A pointer to the head of the singly-linked list of all Uses that refer to this Instruction.
    first_user: ?*Use = null,

    /// The number of operands encoded after this Instruction in memory.
    num_operands: usize = 0,

    /// Get a slice of the operands encoded after this Instruction in memory.
    pub fn operands(self: *Instruction) []Use {
        // invariant: the Instruction struct must be aligned such that the operands can be placed directly after it
        comptime std.debug.assert(common.alignDelta(@sizeOf(Instruction), @alignOf(Use)) == 0);
        return @as([*]Use, @ptrCast(@alignCast(@as([*]u8, @ptrCast(self)) + @sizeOf(Instruction))))[0..self.num_operands];
    }

    /// Determine if this Instruction is a Termination.
    pub fn isTermination(self: *Instruction) bool {
        return self.command < @intFromEnum(Operation.offset);
    }

    /// Determine if this Instruction is an Operation.
    pub fn isOperation(self: *Instruction) bool {
        return self.command >= @intFromEnum(Operation.offset);
    }

    /// Cast this Instruction's command to a Termination. Returns null if this Instruction is an Operation.
    pub fn asTermination(self: *Instruction) ?Termination {
        return if (self.isTermination()) @enumFromInt(self.command) else null;
    }

    /// Cast this Instruction's command to an Operation. Returns null if this Instruction is a Termination.
    pub fn asOperation(self: *Instruction) ?Operation {
        return if (self.isOperation()) @enumFromInt(self.command) else null;
    }

    /// Cast this Instruction's command to a specific value. Returns false if this Instruction does not match the expected command.
    pub fn isCommand(self: *Instruction, command: anytype) bool {
        const expected_command = @intFromEnum(command);
        return self.command == expected_command;
    }
};

pub const Operand = union(enum) {
    term: Term,
    block: *Block,
    function: *Function,
    variable: *Instruction,
};

pub const Use = struct {
    /// The operand being used.
    operand: Operand,
    /// Back pointer to the Instruction that uses this operand.
    user: *Instruction,
    /// Next use of the same operand if it is an ssa variable.
    next: ?*Use = null,
};

// Functions and handlers cannot be terms because they must manage memory while terms are arena-allocated

pub const Function = struct {
    /// Optional debug name for this function.
    name: ?Name,
    /// The type of this function, which must be a function type or a polymorphic type that instantiates to a function.
    type: Term,
    /// The entry block of this function.
    entry: *Block,
    /// The kind of function, either a procedure or an effect handler.
    kind: Kind,
    /// Storage for the function's instructions.
    /// While slightly less memory efficient than a Pool, this allows us to include operands in the same allocation as the instruction.
    arena: std.heap.ArenaAllocator,

    /// The kind of a function, either a procedure or an effect handler.
    pub const Kind = enum(u1) {
        /// The function is a normal procedure.
        procedure,
        /// The function is an effect handler.
        handler,
    };
};

pub const Block = struct {
    name: ?Name = null,
    first_op: ?*Instruction = null,
    last_op: ?*Instruction = null,

    predecessors: common.ArrayList(*Block) = .empty,
    successors: common.ArrayList(*Block) = .empty,

    pub const Iterator = struct {
        op: ?*Instruction,
        pub fn next(self: *Iterator) ?*Instruction {
            if (self.op == null) return null;
            const current = self.op.?;
            self.op = current.next;
            return current;
        }
    };

    pub fn iterate(self: *Block) Iterator {
        return Iterator{ .op = self.first_op };
    }
};

/// Defines the action performed by a Termination
pub const Termination = enum(u8) {
    /// represents an unreachable point in the program
    @"unreachable",
    /// returns a value from a function
    @"return",
    /// calls an effect handler;
    /// must provide one successor block for the nominal return; a second successor block is taken from the handlerset for the cancellation
    // TODO: should this just take two successor blocks directly? not sure which would be better
    prompt,
    /// returns a substitute value from an effect handler's binding block
    cancel,
    /// unconditionally branches to a block
    br,
    /// conditionally branches to a block
    br_if,
    /// runtime panic
    panic,
    /// returns an ssa variable as the value of a term
    lift,
};

/// Defines the action performed by an Operation
pub const Operation = enum(u8) {
    pub const offset = calc_offset: {
        // we start the Operation enum at the end of the Termination enum so they can both be compared generically to u8
        const tags = std.meta.tags(Termination);
        break :calc_offset @intFromEnum(tags[tags.len - 1]) + 1;
    };

    /// allocate a value on the stack and return a pointer to it
    stack_alloc = offset,
    /// load a value from an address
    load,
    /// store a value to an address
    store,
    /// get an element pointer from a pointer
    get_element_ptr,
    /// get the address of a global
    get_address,
    /// create an ssa variable merging values from predecessor blocks
    phi,
    /// addition
    add,
    /// subtraction
    sub,
    /// multiplication
    mul,
    /// division
    div,
    /// remainder division
    rem,
    /// equality comparison
    eq,
    /// inequality comparison
    ne,
    /// less than comparison
    lt,
    /// less than or equal comparison
    le,
    /// greater than comparison
    gt,
    /// greater than or equal comparison
    ge,
    /// logical and
    l_and,
    /// logical or
    l_or,
    /// logical not
    l_not,
    /// bitwise and
    b_and,
    /// bitwise or
    b_or,
    /// bitwise xor
    b_xor,
    /// bitwise left shift
    b_shl,
    /// bitwise right shift
    b_shr,
    /// bitwise not
    b_not,
    /// direct bitcast between types, changing meaning without changing value
    bitcast,
    /// indirect cast between types, changing value without changing meaning
    convert,
    /// calls a standard function
    call,
    /// lowers a term to an ssa variable
    reify,
    /// pushes a new effect handler set onto the stack
    push_set,
    /// pops the current effect handler set from the stack
    pop_set,
    /// represents a debugger breakpoint
    breakpoint,
    /// user-defined operations, which must be handled by extensions
    _,
};

pub const terms = struct {
    /// Binds information about a global variable.
    pub const Global = struct {
        name: Name,
        type: Term,
        initializer: Term,

        pub fn eql(self: *const Global, other: *const Global) bool {
            return self.name.value.ptr == other.name.value.ptr and self.type == other.type and self.initializer == other.initializer;
        }

        pub fn hash(self: *const Global, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.name.value.ptr));
            hasher.update(std.mem.asBytes(&self.type));
            hasher.update(std.mem.asBytes(&self.initializer));
        }

        pub fn cbr(self: *const Global, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("Global");
            hasher.update("name:");
            hasher.update(self.name.value);
            hasher.update("type:");
            hasher.update(try self.type.getCbr(allocator));
            hasher.update("initializer:");
            hasher.update(try self.initializer.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Binds a set of handlers and cancellation information for a push_set instruction
    pub const HandlerSet = struct {
        handlers: []const *Function,
        /// a HandlerType that describes the unified type of the handlers in this set
        handler_type: Term,
        /// the type of value the handler set resolves to, either directly or by cancellation
        result_type: Term,
        /// the instruction where this handler set yields its value
        cancellation_point: void, // TODO: block references

        pub fn eql(self: *const HandlerSet, other: *const HandlerSet) bool {
            if (self.handlers.len != other.handlers.len or self.handler_type != other.handler_type or self.result_type != other.result_type or self.cancellation_point != other.cancellation_point) return false;
            for (0..self.handlers.len) |i| {
                if (self.handlers[i] != other.handlers[i]) return false;
            }
            return true;
        }

        pub fn hash(self: *const HandlerSet, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.handlers.len));
            for (self.handlers) |handler| {
                hasher.update(std.mem.asBytes(&handler));
            }
            hasher.update(std.mem.asBytes(&self.handler_type));
            hasher.update(std.mem.asBytes(&self.result_type));
            hasher.update(std.mem.asBytes(&self.cancellation_point));
        }

        pub fn cbr(self: *const HandlerSet, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("HandlerSet");
            hasher.update("handlers.count:");
            hasher.update(std.mem.asBytes(&self.handlers.len));
            for (self.handlers) |handler| {
                hasher.update("handler:");
                hasher.update(try handler.getCbr(allocator));
            }
            hasher.update("handler_type:");
            hasher.update(try self.handler_type.getCbr(allocator));
            hasher.update("result_type:");
            hasher.update(try self.result_type.getCbr(allocator));
            hasher.update("cancellation_point:");
            hasher.update(std.mem.asBytes(&self.cancellation_point)); // TODO: basic block reference cbr strategy
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Binds a set of member definitions for a typeclass
    pub const Implementation = struct {
        class: Class,
        members: []const Field,

        pub const Field = struct {
            name: Name,
            value: Term,
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

        pub fn hash(self: *const Implementation, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.class));
            hasher.update(std.mem.asBytes(&self.members.len));
            for (self.members) |field| {
                hasher.update(std.mem.asBytes(&field.name.value.ptr));
                hasher.update(std.mem.asBytes(&field.value));
            }
        }

        pub fn cbr(self: *const Implementation, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("Implementation");
            hasher.update("class:");
            hasher.update(try self.class.getCbr(allocator));
            hasher.update("members.count:");
            hasher.update(std.mem.asBytes(&self.members.len));
            for (self.members) |field| {
                hasher.update("field.name:");
                hasher.update(field.name.value);
                hasher.update("field.value:");
                hasher.update(try field.value.getCbr(allocator));
            }
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// A blob is a contiguous region of memory containing arbitrary data, owned by the context and de-duplicated.
    pub const Blob = struct {
        header: *const BlobHeader,

        pub fn getBytes(self: *const Blob) []const u8 {
            return self.header.getBytes();
        }

        pub fn eql(self: *const Blob, other: *const Blob) bool {
            return self.header == other.header;
        }

        pub fn hash(self: *const Blob, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.header));
        }

        pub fn cbr(self: *const Blob, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("Blob");
            hasher.update(self.header.getBytes());
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// A symbol is a term that can appear in both values and types, and is simply a nominative identity in the form of a name.
    pub const Symbol = struct {
        name: Name,

        pub fn eql(self: *const Symbol, other: *const Symbol) bool {
            return self.name.value.ptr == other.name.value.ptr;
        }

        pub fn hash(self: *const Symbol, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.name.value.ptr));
        }

        pub fn cbr(self: *const Symbol, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("Symbol");
            hasher.update(self.name.value);
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Data for a typeclass repr.
    pub const Class = struct {
        /// Nominative identity for this typeclass.
        name: Name,
        /// Descriptions of each element required for the implementation of this typeclass.
        elements: []const Field = &.{},

        pub const Field = struct {
            name: Name,
            type: Term,
        };

        pub fn eql(self: *const Class, other: *const Class) bool {
            if (!self.name.value.ptr == other.name.value.ptr and self.elements.len == other.elements.len) return false;

            for (0..self.elements.len) |i| {
                const field1 = self.elements[i];
                const field2 = other.elements[i];
                if (field1.name.value.ptr != field2.name.value.ptr or field1.type != field2.type) return false;
            }

            return true;
        }

        pub fn hash(self: *const Class, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.name));
            hasher.update(std.mem.asBytes(&self.elements.len));
            for (self.elements) |field| {
                hasher.update(std.mem.asBytes(&field.name.value.ptr));
                hasher.update(std.mem.asBytes(&field.type));
            }
        }

        pub fn cbr(self: *const Class, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("Class");
            hasher.update("name:");
            hasher.update(self.name.value);
            hasher.update("elements.count:");
            hasher.update(std.mem.asBytes(&self.elements.len));
            hasher.update("elements:");
            for (self.elements) |elem| {
                hasher.update("elem.name:");
                hasher.update(elem.name.value);
                hasher.update("elem.type:");
                hasher.update(try elem.type.getCbr(allocator));
            }
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Data for an effect repr.
    pub const Effect = struct {
        /// Nominative identity for this effect.
        name: Name,
        /// Descriptions of each element required for the handling of this effect.
        elements: []const Field = &.{},

        pub const Field = struct {
            name: Name,
            type: Term,
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

        pub fn hash(self: *const Effect, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.name));
            hasher.update(std.mem.asBytes(&self.elements.len));
            for (self.elements) |field| {
                hasher.update(std.mem.asBytes(&field.name.value.ptr));
                hasher.update(std.mem.asBytes(&field.type));
            }
        }

        pub fn cbr(self: *const Effect, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("Effect");
            hasher.update("name:");
            hasher.update(self.name.value);
            hasher.update("elements.count:");
            hasher.update(std.mem.asBytes(&self.elements.len));
            hasher.update("elements:");
            for (self.elements) |elem| {
                hasher.update("elem.name:");
                hasher.update(elem.name.value);
                hasher.update("elem.type:");
                hasher.update(try elem.type.getCbr(allocator));
            }
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Defines a variable in a Polymorphic repr.
    pub const Quantifier = struct {
        /// Unique ID binding variables within a PolymorphicType.
        id: u32,
        /// Type kind required for instantiations of this quantifier.
        kind: Term,

        pub fn eql(self: *const Quantifier, other: *const Quantifier) bool {
            return self.id == other.id and self.kind == other.kind;
        }

        pub fn hash(self: *const Quantifier, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.id));
            hasher.update(std.mem.asBytes(&self.kind));
        }

        pub fn cbr(self: *const Quantifier, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("Quantifier");
            hasher.update("id:");
            hasher.update(std.mem.asBytes(&self.id));
            hasher.update("kind:");
            hasher.update(try self.kind.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    pub const SymbolKind = IdentityTerm("SymbolKind");
    pub const DataKind = IdentityTerm("DataKind");
    pub const TypeKind = IdentityTerm("TypeKind");
    pub const ClassKind = IdentityTerm("ClassKind");
    pub const EffectKind = IdentityTerm("EffectKind");
    pub const HandlerKind = IdentityTerm("HandlerKind");
    pub const FunctionKind = IdentityTerm("FunctionKind");
    pub const ConstraintKind = IdentityTerm("ConstraintKind");
    pub const LiftedDataKind = struct {
        unlifted_type: Term,

        pub fn eql(self: *const LiftedDataKind, other: *const LiftedDataKind) bool {
            return self.unlifted_type == other.unlifted_type;
        }

        pub fn hash(self: *const LiftedDataKind, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.unlifted_type));
        }

        pub fn cbr(self: *const LiftedDataKind, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("LiftedDataKind");
            hasher.update(try self.unlifted_type.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };
    pub const ArrowKind = struct {
        input: Term,
        output: Term,

        pub fn eql(self: *const ArrowKind, other: *const ArrowKind) bool {
            return self.input == other.input and self.output == other.output;
        }

        pub fn hash(self: *const ArrowKind, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.input));
            hasher.update(std.mem.asBytes(&self.output));
        }

        pub fn cbr(self: *const ArrowKind, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("ArrowKind");
            hasher.update("input:");
            hasher.update(try self.input.getCbr(allocator));
            hasher.update("output:");
            hasher.update(try self.output.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Type data for an integer type repr.
    pub const IntegerType = struct {
        /// Indicates whether or not the integer type is signed.
        signedness: Term,
        /// Precise width of the integer type in bits, allowing arbitrary value ranges.
        bit_width: Term,

        pub fn eql(self: *const IntegerType, other: *const IntegerType) bool {
            return self.signedness == other.signedness and self.bit_width == other.bit_width;
        }

        pub fn hash(self: *const IntegerType, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.signedness));
            hasher.update(std.mem.asBytes(&self.bit_width));
        }

        pub fn cbr(self: *const IntegerType, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("IntegerType");
            hasher.update("signedness:");
            hasher.update(try self.signedness.getCbr(allocator));
            hasher.update("bit_width:");
            hasher.update(try self.bit_width.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Type data for a floating point type repr.
    pub const FloatType = struct {
        /// Precise width of the floating point type in bits;
        /// unlike Integer, this should not allow arbitrary value ranges.
        bit_width: Term,

        pub fn eql(self: *const FloatType, other: *const FloatType) bool {
            return self.bit_width == other.bit_width;
        }

        pub fn hash(self: *const FloatType, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.bit_width));
        }

        pub fn cbr(self: *const FloatType, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("FloatType");
            hasher.update("bit_width:");
            hasher.update(try self.bit_width.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Type data for an array type repr.
    pub const ArrayType = struct {
        /// Number of elements in the array type.
        len: Term,
        /// Optional constant value transparently attached to the end of the array,
        /// allowing easy creation of sentinel buffers.
        /// (ie, in zig syntax: [*:0]u8 for null-terminated string)
        sentinel_value: Term,
        /// Value type at each element slot in the array type.
        payload: Term,

        pub fn eql(self: *const ArrayType, other: *const ArrayType) bool {
            return self.len == other.len and self.sentinel_value == other.sentinel_value and self.payload == other.payload;
        }

        pub fn hash(self: *const ArrayType, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.len));
            hasher.update(std.mem.asBytes(&self.sentinel_value));
            hasher.update(std.mem.asBytes(&self.payload));
        }

        pub fn cbr(self: *const ArrayType, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("ArrayType");
            hasher.update("len:");
            hasher.update(try self.len.getCbr(allocator));
            hasher.update("sentinel_value:");
            hasher.update(try self.sentinel_value.getCbr(allocator));
            hasher.update("payload:");
            hasher.update(try self.payload.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Type data for a pointer type repr.
    pub const PointerType = struct {
        /// Alignment override for addresses of this type.
        /// `nil` indicates natural alignment of `payload`.
        alignment: Term,
        /// Symbolic tag indicating the allocator this pointer belongs to.
        address_space: Term,
        /// Value type at the destination address of pointers with this type.
        payload: Term,
        // TODO: support bit offset ala zig extended alignment? e.g. `align(10:4:10)`

        pub fn eql(self: *const PointerType, other: *const PointerType) bool {
            return self.alignment == other.alignment and self.address_space == other.address_space and self.payload == other.payload;
        }

        pub fn hash(self: *const PointerType, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.alignment));
            hasher.update(std.mem.asBytes(&self.address_space));
            hasher.update(std.mem.asBytes(&self.payload));
        }

        pub fn cbr(self: *const PointerType, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("PointerType");
            hasher.update("alignment:");
            hasher.update(try self.alignment.getCbr(allocator));
            hasher.update("address_space:");
            hasher.update(try self.address_space.getCbr(allocator));
            hasher.update("payload:");
            hasher.update(try self.payload.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Type data for a pointer-to-many type repr.
    pub const BufferType = struct {
        /// Alignment override for addresses of this type.
        /// `nil` indicates natural alignment of `payload`.
        alignment: Term,
        /// Symbolic tag indicating the allocator this pointer belongs to.
        address_space: Term,
        /// Optional constant value transparently attached to the end of the buffer,
        /// (ie, in zig syntax: [*:0]u8 for null-terminated string)
        sentinel_value: Term,
        /// Value type at the destination address of pointers with this type.
        payload: Term,

        pub fn eql(self: *const BufferType, other: *const BufferType) bool {
            return self.alignment == other.alignment and self.address_space == other.address_space and self.sentinel_value == other.sentinel_value and self.payload == other.payload;
        }

        pub fn hash(self: *const BufferType, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.alignment));
            hasher.update(std.mem.asBytes(&self.address_space));
            hasher.update(std.mem.asBytes(&self.sentinel_value));
            hasher.update(std.mem.asBytes(&self.payload));
        }

        pub fn cbr(self: *const BufferType, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("BufferType");
            hasher.update("alignment:");
            hasher.update(try self.alignment.getCbr(allocator));
            hasher.update("address_space:");
            hasher.update(try self.address_space.getCbr(allocator));
            hasher.update("sentinel_value:");
            hasher.update(try self.sentinel_value.getCbr(allocator));
            hasher.update("payload:");
            hasher.update(try self.payload.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Type data for a wide-pointer-to-many type repr.
    pub const SliceType = struct {
        /// Alignment override for addresses of this type.
        /// `nil` indicates natural alignment of `payload`.
        alignment: Term,
        /// Symbolic tag indicating the allocator this pointer belongs to.
        address_space: Term,
        /// Optional constant value transparently attached to the end of the slice,
        /// (ie, in zig syntax: [:0]u8 for slice of null-terminated string buffer)
        sentinel_value: Term,
        /// Value type at the destination address of pointers with this type.
        payload: Term,

        pub fn eql(self: *const SliceType, other: *const SliceType) bool {
            return self.alignment == other.alignment and self.address_space == other.address_space and self.sentinel_value == other.sentinel_value and self.payload == other.payload;
        }

        pub fn hash(self: *const SliceType, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.alignment));
            hasher.update(std.mem.asBytes(&self.address_space));
            hasher.update(std.mem.asBytes(&self.sentinel_value));
            hasher.update(std.mem.asBytes(&self.payload));
        }

        pub fn cbr(self: *const SliceType, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("SliceType");
            hasher.update("alignment:");
            hasher.update(try self.alignment.getCbr(allocator));
            hasher.update("address_space:");
            hasher.update(try self.address_space.getCbr(allocator));
            hasher.update("sentinel_value:");
            hasher.update(try self.sentinel_value.getCbr(allocator));
            hasher.update("payload:");
            hasher.update(try self.payload.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Used for abstract data description.
    pub const RowElementType = struct {
        label: Term,
        payload: Term,

        pub fn eql(self: *const RowElementType, other: *const RowElementType) bool {
            return self.label == other.label and self.payload == other.payload;
        }

        pub fn hash(self: *const RowElementType, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.label));
            hasher.update(std.mem.asBytes(&self.payload));
        }

        pub fn cbr(self: *const RowElementType, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("RowElementType");
            hasher.update("label:");
            hasher.update(try self.label.getCbr(allocator));
            hasher.update("payload:");
            hasher.update(try self.payload.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Used for abstract data description.
    pub const LabelType = union(enum) {
        name: Term,
        index: Term,
        exact: struct {
            name: Term,
            index: Term,
        },

        pub fn eql(self: *const LabelType, other: *const LabelType) bool {
            if (@as(std.meta.Tag(LabelType), self.*) != other.*) return false;
            return switch (self.*) {
                .name => |n| n == other.name,
                .index => |i| i == other.index,
                .exact => |e| e.name == other.exact.name and e.index == other.exact.index,
            };
        }

        pub fn hash(self: *const LabelType, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&@as(std.meta.Tag(LabelType), self)));
            switch (self.*) {
                .name => |n| {
                    hasher.update(std.mem.asBytes(&n));
                },
                .index => |i| {
                    hasher.update(std.mem.asBytes(&i));
                },
                .exact => |e| {
                    hasher.update(std.mem.asBytes(&e.name));
                    hasher.update(std.mem.asBytes(&e.index));
                },
            }
        }

        pub fn cbr(self: *const LabelType, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("LabelType");
            switch (self.*) {
                .name => |n| {
                    hasher.update("name:");
                    hasher.update(try n.getCbr(allocator));
                },
                .index => |i| {
                    hasher.update("index:");
                    hasher.update(try i.getCbr(allocator));
                },
                .exact => |e| {
                    hasher.update("exact.name:");
                    hasher.update(try e.name.getCbr(allocator));
                    hasher.update("exact.index:");
                    hasher.update(try e.index.getCbr(allocator));
                },
            }
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Used for compile time constants as types, such as integer values.
    pub const LiftedDataType = struct {
        /// The type of the data before it was lifted to a type value.
        unlifted_type: Term,
        /// The actual value of the data. Either a blob or a constant expression.
        term: Term,

        pub fn eql(self: *const LiftedDataType, other: *const LiftedDataType) bool {
            return self.unlifted_type == other.unlifted_type and self.term == other.term;
        }

        pub fn hash(self: *const LiftedDataType, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.unlifted_type));
            hasher.update(std.mem.asBytes(&self.term));
        }

        pub fn cbr(self: *const LiftedDataType, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("LiftedDataType");
            hasher.update("unlifted_type:");
            hasher.update(try self.unlifted_type.getCbr(allocator));
            hasher.update("term:");
            hasher.update(try self.term.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Type data for a row type
    /// Type data for a structure type repr.
    pub const StructureType = struct {
        /// Nominative identity of this structure type.
        name: Name,
        /// Layout heuristic determining how fields are to be arranged in memory.
        layout: Term,
        /// Optional integer representation of the structure type.
        /// For example, when specifying bit_packed, it helps to prevent errors if one specifies the precise integer size.
        backing_integer: Term,
        /// Descriptions of each field of this structure type.
        elements: []const Field = &.{},

        /// Descriptor for structural fields.
        pub const Field = struct {
            /// Nominative identity of this field.
            name: Term,
            /// The type of data stored in this field.
            payload: Term,
            /// An optional custom alignment for this field, overriding the natural alignment of `payload`;
            /// used by `Heuristic.optimal`; not allowed by others.
            alignment_override: Term,
        };

        pub fn eql(self: *const StructureType, other: *const StructureType) bool {
            if (self.name.value.ptr != other.name.value.ptr or self.layout != other.layout or self.backing_integer != other.backing_integer or self.elements.len != other.elements.len) return false;

            for (0..self.elements.len) |i| {
                const a = self.elements[i];
                const b = other.elements[i];
                if (!(a.name == b.name and a.payload == b.payload and a.alignment_override == b.alignment_override)) return false;
            }

            return true;
        }

        pub fn hash(self: *const StructureType, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.name));
            hasher.update(std.mem.asBytes(&self.layout));
            hasher.update(std.mem.asBytes(&self.backing_integer));
            hasher.update(std.mem.asBytes(&self.elements.len));
            for (self.elements) |elem| {
                hasher.update(std.mem.asBytes(&elem.name));
                hasher.update(std.mem.asBytes(&elem.payload));
                hasher.update(std.mem.asBytes(&elem.alignment_override));
            }
        }

        pub fn cbr(self: *const StructureType, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("StructureType");
            hasher.update("name:");
            hasher.update(self.name.value);
            hasher.update("layout:");
            hasher.update(try self.layout.getCbr(allocator));
            hasher.update("backing_integer:");
            hasher.update(try self.backing_integer.getCbr(allocator));
            hasher.update("elements_count:");
            hasher.update(std.mem.asBytes(&self.elements.len));
            for (self.elements) |elem| {
                hasher.update("elem.name:");
                hasher.update(try elem.name.getCbr(allocator));
                hasher.update("elem.payload:");
                hasher.update(try elem.payload.getCbr(allocator));
                hasher.update("elem.alignment_override:");
                hasher.update(try elem.alignment_override.getCbr(allocator));
            }
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Type data for a tagged sum type repr.
    pub const UnionType = struct {
        /// Nominative identity for this undiscriminated union type.
        name: Name,
        /// Heuristic determining the variant tagging and data layout strategy.
        layout: Term,
        /// Descriptions of each descriminant and variant of this union type.
        elements: []const Field = &.{},

        /// Descriptor for union fields.
        pub const Field = struct {
            /// Nominative identity for this variant.
            name: Name,
            /// Optional type of data stored in this variant;
            /// nil indicates discriminant-only variation.
            payload: Term,
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

        pub fn hash(self: *const UnionType, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.name));
            hasher.update(std.mem.asBytes(&self.layout));
            hasher.update(std.mem.asBytes(&self.elements.len));
            for (self.elements) |elem| {
                hasher.update(std.mem.asBytes(&elem.name.value.ptr));
                hasher.update(std.mem.asBytes(&elem.payload));
            }
        }

        pub fn cbr(self: *const UnionType, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("UnionType");
            hasher.update("name:");
            hasher.update(self.name.value);
            hasher.update("layout:");
            hasher.update(try self.layout.getCbr(allocator));
            hasher.update("elements_count:");
            hasher.update(std.mem.asBytes(&self.elements.len));
            for (self.elements) |elem| {
                hasher.update("elem.name:");
                hasher.update(elem.name.value);
                hasher.update("elem.payload:");
                hasher.update(try elem.payload.getCbr(allocator));
            }
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Type data for a tagged sum type repr.
    pub const SumType = struct {
        /// Nominative identity for this discriminated union type.
        name: Name,
        /// Type for the discriminant tag in this union.
        tag_type: Term,
        /// Heuristic determining the variant tagging and data layout strategy.
        layout: Term,
        /// Descriptions of each descriminant and variant of this union type.
        elements: []const Field = &.{},

        /// Descriptor for union fields.
        pub const Field = struct {
            /// Nominative identity for this variant.
            name: Name,
            /// Optional type of data stored in this variant;
            /// nil indicates discriminant-only variation.
            payload: Term,
            /// Constant value of this variant's discriminant.
            tag: Term,
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

        pub fn hash(self: *const SumType, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.name));
            hasher.update(std.mem.asBytes(&self.tag_type));
            hasher.update(std.mem.asBytes(&self.layout));
            hasher.update(std.mem.asBytes(&self.elements.len));
            for (self.elements) |elem| {
                hasher.update(std.mem.asBytes(&elem.name));
                hasher.update(std.mem.asBytes(&elem.payload));
                hasher.update(std.mem.asBytes(&elem.tag));
            }
        }

        pub fn cbr(self: *const SumType, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("SumType");
            hasher.update("name:");
            hasher.update(self.name.value);
            hasher.update("tag_type:");
            hasher.update(try self.tag_type.getCbr(allocator));
            hasher.update("layout:");
            hasher.update(try self.layout.getCbr(allocator));
            hasher.update("elements_count:");
            hasher.update(std.mem.asBytes(&self.elements.len));
            for (self.elements) |elem| {
                hasher.update("elem.name:");
                hasher.update(elem.name.value);
                hasher.update("elem.payload:");
                hasher.update(try elem.payload.getCbr(allocator));
                hasher.update("elem.tag:");
                hasher.update(try elem.tag.getCbr(allocator));
            }
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Type data for a function type repr.
    pub const FunctionType = struct {
        /// Parameter type for this function signature. Multiple input values are represented by Product.
        input: Term,
        /// Result type for this function.
        output: Term,
        /// Side effect type incurred when calling this function. Multiple effects are represented by Product.
        effects: Term,

        pub fn eql(self: *const FunctionType, other: *const FunctionType) bool {
            return self.input == other.input and self.output == other.output and self.effects == other.effects;
        }

        pub fn hash(self: *const FunctionType, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.input));
            hasher.update(std.mem.asBytes(&self.output));
            hasher.update(std.mem.asBytes(&self.effects));
        }

        pub fn cbr(self: *const FunctionType, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("FunctionType");
            hasher.update("input:");
            hasher.update(try self.input.getCbr(allocator));
            hasher.update("output:");
            hasher.update(try self.output.getCbr(allocator));
            hasher.update("effects:");
            hasher.update(try self.effects.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Type data for an effect handler repr.
    pub const HandlerType = struct {
        /// Parameter type for this handler signature. Multiple input values are represented by Product.
        input: Term,
        /// Result type for this handler.
        output: Term,
        /// Effect that is (at least temporarily) eliminated by this handler.
        handled_effect: Term,
        /// Side effects that are incurred in the process of handling this handler's effect. May include `handled_effect` for modulating handlers.
        added_effects: Term,

        pub fn eql(self: *const HandlerType, other: *const HandlerType) bool {
            return self.input == other.input and self.output == other.output and self.handled_effect == other.handled_effect and self.added_effects == other.added_effects;
        }

        pub fn hash(self: *const HandlerType, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.input));
            hasher.update(std.mem.asBytes(&self.output));
            hasher.update(std.mem.asBytes(&self.handled_effect));
            hasher.update(std.mem.asBytes(&self.added_effects));
        }

        pub fn cbr(self: *const HandlerType, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("HandlerType");
            hasher.update("input:");
            hasher.update(try self.input.getCbr(allocator));
            hasher.update("output:");
            hasher.update(try self.output.getCbr(allocator));
            hasher.update("handled_effect:");
            hasher.update(try self.handled_effect.getCbr(allocator));
            hasher.update("added_effects:");
            hasher.update(try self.added_effects.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Type data for a polymorphic type repr, with quantifiers and/or qualifiers.
    pub const PolymorphicType = struct {
        /// Type variable declarations for this polymorphic type.
        quantifiers: []const Term = &.{},
        /// Type constraints declarations for this polymorphic type.
        qualifiers: Term,
        /// The type to be instantiated by this polymorphic repr.
        payload: Term,

        pub fn eql(self: *const PolymorphicType, other: *const PolymorphicType) bool {
            if (self.quantifiers.len != other.quantifiers.len or self.qualifiers != other.qualifiers or self.payload != other.payload) return false;

            for (0..self.quantifiers.len) |i| {
                if (self.quantifiers[i] != other.quantifiers[i]) return false;
            }

            return true;
        }

        pub fn hash(self: *const PolymorphicType, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.quantifiers.len));
            for (self.quantifiers) |*quant| {
                hasher.update(std.mem.asBytes(quant));
            }
            hasher.update(std.mem.asBytes(&self.qualifiers));
            hasher.update(std.mem.asBytes(&self.payload));
        }

        pub fn cbr(self: *const PolymorphicType, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("PolymorphicType");
            hasher.update("quantifiers_count:");
            hasher.update(std.mem.asBytes(&self.quantifiers.len));
            for (self.quantifiers) |quant| {
                hasher.update("quantifier:");
                hasher.update(try quant.getCbr(allocator));
            }
            hasher.update("qualifiers:");
            hasher.update(try self.qualifiers.getCbr(allocator));
            hasher.update("payload:");
            hasher.update(try self.payload.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Constraint checking that `subtype_row` is a subset of `primary_row`.
    pub const IsSubRowConstraint = struct {
        /// The larger product type.
        primary_row: Term,
        /// The smaller product type that must be a subset of `primary_row`.
        subtype_row: Term,

        pub fn eql(self: *const IsSubRowConstraint, other: *const IsSubRowConstraint) bool {
            return self.primary_row == other.primary_row and self.subtype_row == other.subtype_row;
        }

        pub fn hash(self: *const IsSubRowConstraint, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.primary_row));
            hasher.update(std.mem.asBytes(&self.subtype_row));
        }

        pub fn cbr(self: *const IsSubRowConstraint, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("IsSubRowConstraint");
            hasher.update("primary_row:");
            hasher.update(try self.primary_row.getCbr(allocator));
            hasher.update("subtype_row:");
            hasher.update(try self.subtype_row.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Constraint checking that `row_result` is the disjoint union of `row_a` and `row_b`.
    pub const RowsConcatenateConstraint = struct {
        /// The LHS input to the concatenation.
        row_a: Term,
        /// The RHS input to the concatenation.
        row_b: Term,
        /// The product type that must match the disjoint union of `row_a` and `row_b`.
        row_result: Term,

        pub fn eql(self: *const RowsConcatenateConstraint, other: *const RowsConcatenateConstraint) bool {
            return self.row_a == other.row_a and self.row_b == other.row_b and self.row_result == other.row_result;
        }

        pub fn hash(self: *const RowsConcatenateConstraint, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.row_a));
            hasher.update(std.mem.asBytes(&self.row_b));
            hasher.update(std.mem.asBytes(&self.row_result));
        }

        pub fn cbr(self: *const RowsConcatenateConstraint, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("RowsConcatenateConstraint");
            hasher.update("row_a:");
            hasher.update(try self.row_a.getCbr(allocator));
            hasher.update("row_b:");
            hasher.update(try self.row_b.getCbr(allocator));
            hasher.update("row_result:");
            hasher.update(try self.row_result.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Constraint checking that the `data` type implements the `class` typeclass.
    pub const ImplementsClassConstraint = struct {
        /// The type that must implement the `class` typeclass.
        data: Term,
        /// The typeclass that must be implemented by `data`.
        class: Term,

        pub fn eql(self: *const ImplementsClassConstraint, other: *const ImplementsClassConstraint) bool {
            return self.data == other.data and self.class == other.class;
        }

        pub fn hash(self: *const ImplementsClassConstraint, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.data));
            hasher.update(std.mem.asBytes(&self.class));
        }

        pub fn cbr(self: *const ImplementsClassConstraint, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("ImplementsClassConstraint");
            hasher.update("data:");
            hasher.update(try self.data.getCbr(allocator));
            hasher.update("class:");
            hasher.update(try self.class.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Constraint checking that the `data` type is a nominative identity for a structure over the `row` type.
    pub const IsStructureConstraint = struct {
        /// The nominative structural type that must contain `row`.
        data: Term,
        /// The structural description type that must match the layout of `data`.
        row: Term,

        pub fn eql(self: *const IsStructureConstraint, other: *const IsStructureConstraint) bool {
            return self.data == other.data and self.row == other.row;
        }

        pub fn hash(self: *const IsStructureConstraint, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.data));
            hasher.update(std.mem.asBytes(&self.row));
        }

        pub fn cbr(self: *const IsStructureConstraint, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("IsStructureConstraint");
            hasher.update("data:");
            hasher.update(try self.data.getCbr(allocator));
            hasher.update("row:");
            hasher.update(try self.row.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Constraint checking that the `data` type is a nominative identity for a union over the `row` type.
    pub const IsUnionConstraint = struct {
        /// The nominative structural type that must contain `row`.
        data: Term,
        /// The structural description type that must match the layout of `data`.
        row: Term,

        pub fn eql(self: *const IsUnionConstraint, other: *const IsUnionConstraint) bool {
            return self.data == other.data and self.row == other.row;
        }

        pub fn hash(self: *const IsUnionConstraint, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.data));
            hasher.update(std.mem.asBytes(&self.row));
        }

        pub fn cbr(self: *const IsUnionConstraint, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("IsUnionConstraint");
            hasher.update("data:");
            hasher.update(try self.data.getCbr(allocator));
            hasher.update("row:");
            hasher.update(try self.row.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };

    /// Constraint checking that the `data` type is a nominative identity for a sum over the `row` type.
    pub const IsSumConstraint = struct {
        /// The nominative structural type that must contain `row`.
        data: Term,
        /// The structural description type that must match the layout of `data`.
        row: Term,

        pub fn eql(self: *const IsSumConstraint, other: *const IsSumConstraint) bool {
            return self.data == other.data and self.row == other.row;
        }

        pub fn hash(self: *const IsSumConstraint, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(std.mem.asBytes(&self.data));
            hasher.update(std.mem.asBytes(&self.row));
        }

        pub fn cbr(self: *const IsSumConstraint, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            var hasher = std.crypto.hash.Blake3.init(.{});
            hasher.update("IsSumConstraint");
            hasher.update("data:");
            hasher.update(try self.data.getCbr(allocator));
            hasher.update("row:");
            hasher.update(try self.row.getCbr(allocator));
            const buf = try allocator.alloc(u8, 32);
            hasher.final(buf);
            return buf;
        }
    };
};

pub fn IdentityTerm(comptime name: []const u8) type {
    return struct {
        const Self = @This();

        pub fn eql(_: *const Self, _: *const Self) bool {
            return true;
        }

        pub fn hash(_: *const Self, hasher: *std.hash.Fnv1a_64) void {
            hasher.update(name);
        }

        pub fn cbr(_: *const Self, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
            const buf = try allocator.alloc(u8, 32);
            std.crypto.hash.Blake3.hash(name, buf, .{});
            return buf;
        }
    };
}
