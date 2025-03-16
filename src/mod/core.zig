//! # Core
//! The core module is a namespace containing the runtime bytecode representation,
//! as well as the Ribbon virtual machine's `Fiber` implementation,
//! and their supporting data structures.
const Core = @This();

const std = @import("std");
const log = std.log.scoped(.Core);

const pl = @import("platform");
const Id = @import("Id");
const Buffer = @import("Buffer");
const Stack = @import("Stack");

test {
    std.testing.refAllDeclsRecursive(@This());
}


/// Set of `platform.MAX_REGISTERS` virtual registers for a function call.
pub const RegisterArray: type = [pl.MAX_REGISTERS]usize;

/// A stack allocator for virtual register arrays.
pub const RegisterStack: type = Stack.new(RegisterArray, pl.CALL_STACK_SIZE);
/// A stack allocator, allocated in 64-bit word increments; for arbitrary data within a fiber.
pub const DataStack: type = Stack.new(usize, pl.DATA_STACK_SIZE);
/// A stack allocator; for Rvm's function call frames within a fiber.
pub const CallStack: type = Stack.new(CallFrame, pl.CALL_STACK_SIZE);
/// A stack allocator; for Rvm's effect handler set frames within a fiber.
pub const SetStack: type = Stack.new(SetFrame, pl.SET_STACK_SIZE);

/// The type of a relative jump offset within a Ribbon bytecode program.
pub const InstructionOffset = i32;
/// The address of an instruction in a Ribbon bytecode program.
pub const InstructionAddr: type = [*]const InstructionBits;
/// The address of an instruction in a Ribbon bytecode program, while it is being constructed.
pub const MutInstructionAddr: type = [*]InstructionBits;
/// The bits of an encoded instruction, represented by an unsigned integer of the same size.
pub const InstructionBits: type = std.meta.Int(.unsigned, pl.BYTECODE_ALIGNMENT);



/// A bytecode binary unit. Not necessarily self contained; may reference other units.
/// Light wrapper for `Header`.
pub const Bytecode = packed struct(usize) {
    /// The bytecode unit header.
    header: *const Header,

    /// De-initialize the bytecode unit, freeing the memory that it owns.
    pub fn deinit(b: Bytecode, allocator: std.mem.Allocator) void {
        allocator.free(@as(InstructionAddr, @ptrCast(b.header))[0..b.header.size]);
    }
};

/// A Ribbon constant value definition.
pub const Constant = Buffer.new(u8, .constant);

/// A Ribbon global variable definition.
pub const Global = Buffer.new(u8, .mutable);

/// Designates a specific Ribbon effect, runtime-wide.
/// EffectId is used to bind to one of these within individual bytecode units.
pub const Effect = enum(u16) {_};

/// A Ribbon function definition.
pub const Function = extern struct {
    /// The `Header` that owns this function,
    /// which we rely on to resolve the ids encoded in the function's instructions.
    header: *const Header,
    /// A pair of offsets:
    /// * `base`: the function's first instruction in the bytecode unit; the entry point
    /// * `upper`: one past the end of its instructions; for bounds checking
    extents: Extents,
    /// The stack window size of the function.
    stack_size: usize,
};

/// A Ribbon builtin value definition.
pub const BuiltinAddress = extern struct {
    /// The builtin's function, if it has one.
    /// * Signature is actually `fn (Rvm.Fiber) callconv(.c) Rvm.NativeSignal` (aka `Rvm.AllocatedBuiltinFunction`);
    ///
    ///   type erased version used here to reduce dependencies
    function: ?*const fn (*anyopaque) callconv(.c) i64,
    /// The builtin's data pointer. If the builtin has no function, this is just POD; otherwise,
    /// it is the builtin's closure data.
    data: Buffer.MutBytes,
};

/// Intent-communication alias for `*anyopaque`.
pub const ForeignAddress = *anyopaque;

/// A frame-local stack value offset into the frame of the parent function of a handler set.
pub const Upvalue = enum(i32) {_};


/// `cancel` configuration for a `HandlerSet`.
pub const Cancellation = extern struct {
    /// The (`push_set`-instruction relative) offset to apply to the IP if a handler in this set cancels
    cancellation_offset: InstructionOffset,
    /// The register to store any cancellation values in.
    cancellation_register: Register,
};

/// A Ribbon effect handler set definition. Data is relative to the function.
pub const HandlerSet = extern struct {
    /// The handler set's effects.
    handlers: Id.Buffer(Handler, .constant),
    /// The handler set's upvalue offsets.
    upvalues: Id.Buffer(Upvalue, .constant),
    /// Cancellation configuration for this handler set.
    cancellation: Cancellation,

    /// Get a pointer to a `Handler` from its `id`.
    pub fn getHandler(self: *const HandlerSet, id: Id.of(Handler)) *const Handler {
        return &self.handlers.asSlice()[id.toInt()];
    }

    /// Get an `Upvalue` offset from its `id`.
    pub fn getUpvalue(self: *const HandlerSet, id: Id.of(Upvalue)) Upvalue {
        return self.upvalues.asSlice()[id.toInt()];
    }
};

/// We use pointer tagging here to store the effect type in the unused bits of the pointer.
pub const Handler = packed struct(usize) {
    /// The effect type this handler is for.
    effect: Id.of(Effect),
    /// The function implementing the handler.
    function: u48,

    /// Unpack the `Function` pointer embedded in this handler.
    pub fn toPointer(self: Handler) *const anyopaque {
        return @ptrFromInt(self.function);
    }
};

/// Indicates the kind of value bound to a symbol in a `SymbolTable`.
pub const SymbolKind = enum(u16) {
    constant,
    global,
    function,
    builtin,
    foreign_address,
    effect,
    handler_set,

    /// Comptime function to convert symbol kinds to zig types.
    pub fn toType(comptime K: SymbolKind) type {
        return switch (K) {
            .constant => Constant,
            .global => Global,
            .function => Function,
            .builtin => BuiltinAddress,
            .foreign_address => ForeignAddress,
            .effect => Effect,
            .handler_set => HandlerSet,
        };
    }

    /// Comptime function to convert zig types to symbol kinds.
    pub fn fromType(comptime T: type) SymbolKind {
        return switch (T) {
            Constant => .constant,
            Global => .global,
            Function => .function,
            BuiltinAddress => .builtin,
            ForeignAddress => .foreign_address,
            HandlerSet => .handler_set,
            Effect => .effect,
            else => @compileError("SymbolKind.fromType: unsupported type `" ++ @typeName(T) ++ "`"),
        };
    }
};

/// The base and upper address of a code section.
pub const Extents = packed struct(u128) {
    /// The base address of the code section.
    base: InstructionAddr,
    /// The upper address of the code section. (1 past the last instruction)
    upper: InstructionAddr,
};

/// This is an indirection table for the `Id`s used by instruction encodings.
///
/// The addresses are resolved at *link time*, so where they actually point is environment-dependent;
/// ownership varies.
pub const AddressTable = extern struct {
    /// Constant value bindings section.
    constants: Id.Buffer(*const Constant, .constant),
    /// Global value bindings section.
    globals: Id.Buffer(*const Global, .constant),
    /// Function value bindings section.
    functions: Id.Buffer(*const Function, .constant),
    /// Builtin function value bindings section.
    builtin_addresses: Id.Buffer(*const BuiltinAddress, .constant),
    /// C ABI value bindings section.
    foreign_addresses: Id.Buffer(*const ForeignAddress, .constant),
    /// Effect handler set bindings section.
    handler_sets: Id.Buffer(*const HandlerSet, .constant),
    /// Effect identity bindings section.
    effects: Id.Buffer(*const Effect, .constant),

    /// Get a pointer to a `Constant` from its `id`.
    pub fn getConstant(self: *const AddressTable, id: Id.of(Constant)) *const Constant {
        return self.constants.asSlice()[id.toInt()];
    }

    /// Get a pointer to a `Global` from its `id`.
    pub fn getGlobal(self: *const AddressTable, id: Id.of(Global)) *const Global {
        return self.globals.asSlice()[id.toInt()];
    }

    /// Get a pointer to a `Function` from its `id`.
    pub fn getFunction(self: *const AddressTable, id: Id.of(Function)) *const Function {
        return self.functions.asSlice()[id.toInt()];
    }

    /// Get a pointer to a `BuiltinAddress` from its `id`.
    pub fn getBuiltinAddress(self: *const AddressTable, id: Id.of(BuiltinAddress)) *const BuiltinAddress {
        return self.builtin_addresses.asSlice()[id.toInt()];
    }

    /// Get a pointer to a `ForeignAddress` from its `id`.
    pub fn getForeignAddress(self: *const AddressTable, id: Id.of(ForeignAddress)) *const ForeignAddress {
        return self.foreign_addresses.asSlice()[id.toInt()];
    }

    /// Get a pointer to a `HandlerSet` from its `id`.
    pub fn getHandlerSet(self: *const AddressTable, id: Id.of(HandlerSet)) *const HandlerSet {
        return self.handler_sets.asSlice()[id.toInt()];
    }

    /// Get a pointer to a `Handler` from its `id`.
    pub fn getHandler(self: *const AddressTable, s: Id.of(HandlerSet), h: Id.of(Handler)) *const Handler {
        return self.getHandlerSet(s).getHandler(h);
    }

    /// Get a pointer to an `Effect` from its `id`.
    pub fn getEffect(self: *const AddressTable, id: Id.of(Effect)) *const Effect {
        return self.effects.asSlice()[id.toInt()];
    }
};

/// An association list binding names to ids.
///
/// This is a simple encoding; for runtime purposes it is usually better to construct a hash table.
///
/// It is a compilation`*` error for a name to appear in the list more than once,
/// but ids may appear multiple times under different names.
///
///
/// `*` Within Ribbon's compiler, not Zig's
pub const SymbolTable = packed struct(u128) {
    /// This symbol table's keys.
    keys: Id.Buffer(SymbolTable.Key, .constant),
    /// This symbol table's values.
    values: Id.Buffer(SymbolTable.Value, .constant),

    /// One half of a key/value pair used for address resolution in a `SymbolTable`.
    ///
    /// See `Value`.
    pub const Key = packed struct(u128) {
        /// The symbol text's hash value.
        hash: u64,
        /// The symbol's text value.
        name: Id.Buffer(u8, .constant),
    };

    /// One half of a key/value pair used for address resolution in the `SymbolTable`.
    ///
    /// See `Key`.
    pub const Value = packed struct(u32) {
        /// The kind of value bound to the symbol.
        kind: SymbolKind,
        /// The id (within a reference `AddressTable`) of the value bound to the symbol.
        id: Id.of(anyopaque),
    };

    /// Get the id of a symbol by name.
    pub fn lookupId(self: SymbolTable, name: []const u8) ?SymbolTable.Value {
        const hash = pl.hash64(name);

        for (self.keys.asSlice(), 0..) |key, i| {
            if (key.hash != hash) {
                @branchHint(.likely);
                continue;
            }

            if (std.mem.eql(u8, key.name.asSlice(), name)) {
                @branchHint(.likely);
                return self.values.asSlice()[i];
            }
        }

        return null;
    }
};

/// Metadata for a Ribbon program.
pub const Header = extern struct {
    /// Instructions section base and upper address.
    extents: Extents,
    /// The total size of the program.
    size: usize,
    /// Address table used by instructions this header owns.
    addresses: *const AddressTable,
    /// Symbol bindings for the address table; what this program calls different addresses.
    ///
    /// Not necessarily a complete listing for all bindings;
    /// only what it wants to be known externally.
    symbols: *const SymbolTable,

    /// Get the address of a symbol by name, in a type-generic manner.
    /// * **Note**: This uses the raw table to lookup a symbol. While we do store symbol hashes to
    /// speed this up a bit, for large symbol tables it is likely better to use a hashmap.
    pub fn lookupAddress(self: *const Header, name: []const u8) ?struct {SymbolKind, *const anyopaque} {
        const value = self.symbols.lookupId(name) orelse return null;
        return switch (value.kind) {
            .constant => .{ value.kind, @ptrCast(self.addresses.getConstant(value.id.cast(Constant))) },
            .global => .{ value.kind, @ptrCast(self.addresses.getGlobal(value.id.cast(Global))) },
            .function => .{ value.kind, @ptrCast(self.addresses.getFunction(value.id.cast(Function))) },
            .builtin => .{ value.kind, @ptrCast(self.addresses.getBuiltinAddress(value.id.cast(BuiltinAddress))) },
            .foreign_address => .{ value.kind, @ptrCast(self.addresses.getForeignAddress(value.id.cast(ForeignAddress))) },
            .handler_set => .{ value.kind, @ptrCast(self.addresses.getHandlerSet(value.id.cast(HandlerSet))) },
            .effect => .{ value.kind, @ptrCast(self.addresses.getEffect(value.id.cast(Effect))) },
        };
    }

    /// Get the address of a symbol within a given type by name.
    /// * **Note**: This uses the raw table to lookup a symbol. While we do store symbol hashes to
    /// speed this up a bit, for large symbol tables it is likely better to use a hashmap.
    pub fn lookupAddressOf(self: *const Header, comptime T: type, name: []const u8) error{TypeError}!?*const T {
        const K = SymbolKind.fromType(T);

        const erased = self.lookupAddress(name) orelse return null;

        return if (erased.kind == K) @ptrCast(@alignCast(erased.ptr))
        else {
            @branchHint(.unlikely);
            return error.TypeError;
        };
    }
};

/// A reference to a virtual register.
pub const Register = enum(std.math.IntFittingRange(0, pl.MAX_REGISTERS)) {
    // zig fmt: off
    r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15, r16, r17, r18, r19, r20,
    r21, r22, r23, r24, r25, r26, r27, r28, r29, r30, r31, r32, r33, r34, r35, r36, r37, r38, r39,
    r40, r41, r42, r43, r44, r45, r46, r47, r48, r49, r50, r51, r52, r53, r54, r55, r56, r57, r58,
    r59, r60, r61, r62, r63, r64, r65, r66, r67, r68, r69, r70, r71, r72, r73, r74, r75, r76, r77,
    r78, r79, r80, r81, r82, r83, r84, r85, r86, r87, r88, r89, r90, r91, r92, r93, r94, r95, r96,
    r97, r98, r99, r100, r101, r102, r103, r104, r105, r106, r107, r108, r109, r110, r111, r112,
    r113, r114, r115, r116, r117, r118, r119, r120, r121, r122, r123, r124, r125, r126, r127, r128,
    r129, r130, r131, r132, r133, r134, r135, r136, r137, r138, r139, r140, r141, r142, r143, r144,
    r145, r146, r147, r148, r149, r150, r151, r152, r153, r154, r155, r156, r157, r158, r159, r160,
    r161, r162, r163, r164, r165, r166, r167, r168, r169, r170, r171, r172, r173, r174, r175, r176,
    r177, r178, r179, r180, r181, r182, r183, r184, r185, r186, r187, r188, r189, r190, r191, r192,
    r193, r194, r195, r196, r197, r198, r199, r200, r201, r202, r203, r204, r205, r206, r207, r208,
    r209, r210, r211, r212, r213, r214, r215, r216, r217, r218, r219, r220, r221, r222, r223, r224,
    r225, r226, r227, r228, r229, r230, r231, r232, r233, r234, r235, r236, r237, r238, r239, r240,
    r241, r242, r243, r244, r245, r246, r247, r248, r249, r250, r251, r252, r253, r254, r255,
    // zig fmt: on

    pub const native_ret: Register = .r0;


    /// Creates a `Register` from an integer value.
    pub fn r(value: anytype) Register {
        return @enumFromInt(value);
    }

    /// Integer representation of a `Register`.
    pub const BackingInteger = std.meta.Tag(Register);

    /// Converts a `Register` to its integer representation.
    pub fn getIndex(self: Register) BackingInteger {
        return @intFromEnum(self);
    }

    pub fn getOffset(self: Register) BackingInteger {
        return @intFromEnum(self) * @sizeOf(usize);
    }
};


/// Represents an evidence structure.
pub const Evidence = extern struct {
    /// A pointer to the set frame this evidence belongs to.
    frame: *SetFrame,
    /// A copy of the effect handler this evidence carries.
    handler: Handler,
    /// A pointer to the previous evidence, if there was already a set frame when this one was created.
    previous: ?*Evidence,
};

/// Represents a set frame.
pub const SetFrame = extern struct {
    /// A pointer to the call frame that created this set frame.
    call: *CallFrame,
    /// The effect handler set that defines this frame.
    handler_set: *const HandlerSet,
    /// A pointer to the top of the data stack frame at the time this set frame was created.
    data: [*]usize,
};

/// Represents a call frame.
pub const CallFrame = extern struct {
    /// A pointer to the next instruction to execute.
    ip: InstructionAddr,
    /// A pointer to either a `Function`, `BuiltinAddress`, or `ForeignAddress`.
    function: *const anyopaque,
    /// A pointer to the set frame.
    set: [*]SetFrame,
    /// A pointer to the evidence.
    evidence: ?*Evidence,
    /// A pointer to the data.
    data: [*]usize,
};

/// Signals that can be returned by a built-in function / assembly code.
pub const BuiltinSignal = enum(i64) {
    /// The built-in function is finished and returning a value.
    @"return" = 0,


    // Standard errors

    /// The built-in function has encountered an error would like to trap the fiber at this point.
    request_trap = 1,

    /// The built-in function has encountered a stack overflow.
    overflow = 2,

    /// The built-in function has encountered a stack overflow.
    underflow = 3,


    // Signals

    /// The built-in function (only the interpreter, in this case), has finished executing.
    halt = -1,

    /// The built-in function (only the interpreter, in this case), has encountered an error due to bad encoding.
    bad_encoding = -2,

    /// An unexpected error has occurred; runtime should panic.
    panic = std.math.minInt(i64),


    /// Convert a `BuiltinSignal` into `Error!InterpreterSignal`.
    pub fn toNative(self: BuiltinSignal) Error!InterpreterSignal {
        switch (self) {
            .@"return" => return .@"return",

            .overflow => return error.Overflow,
            .underflow => return error.Underflow,

            .request_trap => return error.FunctionTrapped,

            .halt => return .halt,
            .bad_encoding => return error.BadEncoding,
            .panic => @panic("An unexpected error occurred in native code; exiting"),
        }
    }
};

/// Subset of `BuiltinSignal`.
pub const InterpreterSignal = enum(i64) {
    /// See `BuiltinSignal.@"return"`.
    @"return" = 0,
    /// See `BuiltinSignal.halt`.
    halt = -1,
};

/// The type of procedures that can operate as "built-in" functions
/// (those provided by the host environment) within Ribbon's `core.Fiber`.
///
/// Can be called within a `Fiber` using the `interpreter.invokeBuiltin` family of functions.
///
/// It should be fine to pass a `Fiber` to a function that expects `*mem.FiberHeader`, because
/// it is simply a wrapper over a pointer; the signature is written this way for clarity.
///
/// We use the host's C ABI calling convention for these functions
/// because we need a specified calling convention for the interface between the vm and the jit.
pub const BuiltinFunction = fn (*mem.FiberHeader) callconv(.c) BuiltinSignal;

/// A `BuiltinFunction`, but compiled at runtime.
///
/// Can be called within a `Fiber` using the `interpreter.invokeBuiltin` family of functions.
///
/// This is primarily a memory management structure,
/// as the jit is expected to disown the memory upon finalization.
pub const AllocatedBuiltinFunction = extern struct {
    /// The function's bytes.
    ptr: [*]align(pl.PAGE_SIZE) const u8,
    /// The function's length in bytes.
    ///
    /// Note that this is not necessarily the length of the mapped memory, as it is page aligned.
    len: usize,

    /// `munmap` all pages of a native function, freeing the memory.
    pub fn deinit(self: AllocatedBuiltinFunction) void {
        std.posix.munmap(@alignCast(self.ptr[0..pl.alignTo(self.len, pl.PAGE_SIZE)]));
    }
};

/// All errors that can occur during execution of an Rvm fiber.
pub const Error = error {
    /// Indicates that a built-in function call requested the fiber to trap.
    FunctionTrapped,
    /// Indicates that the interpreter encountered an invalid encoding.
    BadEncoding,
    /// Indicates an overflow of one of the stacks in a fiber.
    Overflow,
    /// Indicates an underflow of one of the stacks in a fiber.
    Underflow,
};


/// Low level fiber memory constants and types.
pub const mem = comptime_memorySize: {
    const REQUIRED_ALIGNMENT = 8; // we enforce 8-byte alignment on the entire fiber memory

    const FIBER_HEADER = extern struct {
        /// Stack of virtual register arrays - stores intermediate values up to a word in size, `pl.MAX_REGISTERS` per function.
        registers: RegisterStack,
        /// Arbitrary data stack allocator - stores intermediate values that need to be addressed or are larger than a word in size.
        data: DataStack,
        /// The call frame stack - tracks in-progress function calls.
        calls: CallStack,
        /// The effect handler set stack - manages lexically scoped effect handler sets.
        sets: SetStack,
        /// Used by the interpreter to store follow-up dispatch labels.
        loop: *const anyopaque,
        /// The cause of a trap, if any was known. Pointee-type depends on the trap.
        trap: ?*const anyopaque, // TODO: error handling function that covers this variance
    };

    const FIELDS = std.meta.fieldNames(FIBER_HEADER);

    std.debug.assert(@alignOf(FIBER_HEADER) == REQUIRED_ALIGNMENT);

    var offsets: [FIELDS.len]comptime_int = undefined;
    var total = @sizeOf(FIBER_HEADER);

    for (FIELDS, 0..) |fieldName, i| {
        const T = @FieldType(FIBER_HEADER, fieldName);

        const alignment, const size = if (pl.canHaveDecls(T)) .{ T.mem.ALIGNMENT, T.mem.SIZE } else .{ @alignOf(T), @sizeOf(T) };

        if (alignment != REQUIRED_ALIGNMENT) {
            @compileError(std.fmt.comptimePrint(
                \\[Fiber.mem] - field "{s}" (of type `{s}`) in `FiberHeader` has incorrect alignment for its memory block;
                \\              it is {d} but it should be == {}"
                \\
                , .{fieldName, @typeName(T), alignment, REQUIRED_ALIGNMENT}));
        }

        // ensure that we haven't screwed this up somehow
        std.debug.assert(total % alignment == 0);

        // not necessary: we've already ensured that the alignment is correct
        // total += pl.alignDelta(total, REQUIRED_ALIGNMENT);

        offsets[i] = total;

        total += size;
    }

    std.debug.assert(pl.alignDelta(total, REQUIRED_ALIGNMENT) == 0);

    break :comptime_memorySize struct {
        /// After initializing a `Fiber`, its memory has the following layout:
        ///
        /// 0. `FiberHeader`
        /// 1. Memory block for the registers `Stack`
        /// 2. Memory block for the next `Stack`
        ///
        /// ... etc
        ///
        /// This is possible because care has been taken to ensure all the stacks and the header are 8-byte aligned,
        /// so there actually shouldn't be any padding necessary on most platforms.
        pub const FiberHeader = FIBER_HEADER;

        /// The alignment required for the full fiber's `memory`.
        ///
        /// We enforce 8-byte alignment; this eliminates the need for padding.
        pub const ALIGNMENT = REQUIRED_ALIGNMENT;

        /// The total number of bytes required to store the full fiber's `memory`.
        /// * includes the `mem.FiberHeader` and all stacks' memory blocks.
        pub const SIZE = total;

        /// The offsets of each section within the fiber's `memory`.
        pub const OFFSETS = offsets;

        /// Byte block type representing a full `Fiber`, with its `mem.FiberHeader` and stacks' memory blocks.
        pub const FiberBuffer: type = extern struct {
            bytes: [SIZE] u8 align(REQUIRED_ALIGNMENT),
        };

        /// Get the offset of a field within the fiber's `memory`.
        /// * this function is comptime
        pub fn getOffset(fieldName: []const u8) comptime_int {
            comptime return OFFSETS[std.meta.fieldIndex(FiberHeader, fieldName) orelse @compileError("No field " ++ fieldName ++ " in Rvm.FiberHeader")];
        }
    };
};

comptime {
    const mb = pl.megabytesFromBytes(mem.SIZE);

    if (mb > 4.0) {
        @compileError(std.fmt.comptimePrint("Fiber total size is {d}mb", .{}));
    }
}

/// Encapsulates all the state needed to execute a sub-routine within Rvm.
///
/// A *fiber* is a lightweight, independent code execution environment;
/// *in this case* emulating a CPU thread. Unlike true threads,
/// `Fiber`s are managed and stored in *[user space](https://en.wikipedia.org/wiki/User_space)*;
/// or in other words: we have full control over them, in terms of scheduling and memory management.
///
/// All data for a `Fiber` is stored contiguously in a single allocation;
/// they can be allocated and freed very efficiently.
pub const Fiber = extern struct {
    /// Pointer to the beginning of the fiber's memory block.
    header: *mem.FiberHeader,

    /// Allocates and initializes a new fiber.
    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Fiber {
        const buf = try allocator.allocAdvancedWithRetAddr(u8, mem.ALIGNMENT, mem.SIZE, @returnAddress());

        log.debug("allocated address range {x} to {x} for {s}\n", .{@intFromPtr(buf.ptr), @intFromPtr(buf.ptr) + buf.len, @typeName(Fiber)});

        const header: *mem.FiberHeader = @ptrCast(buf.ptr);

        fiber_fields: inline for (comptime std.meta.fieldNames(mem.FiberHeader)) |fieldName| {
            inline for (&.{ "loop", "trap" }) |ignoredField| {
                if (comptime std.mem.eql(u8, fieldName, ignoredField)) {
                    continue :fiber_fields;
                }
            }

            const memoryOffset = comptime mem.getOffset(fieldName);
            @field(header, fieldName) = .init(@alignCast(buf.ptr + memoryOffset));
        }

        return Fiber {
            .header = header,
        };
    }

    /// De-initializes the fiber, freeing its memory.
    pub fn deinit(self: Fiber, allocator: std.mem.Allocator) void {
        allocator.destroy(@as(*mem.FiberBuffer, @ptrCast(self.header)));
    }

    /// Get a pointer to one of the stacks' memory block.
    /// * This function can be called at both runtime and comptime.
    /// * The name of the stack can be either a string or an enum literal.
    pub fn getStack(self: Fiber, stackName: anytype) [*]u8 {
        return @as([*]u8, @ptrCast(self.header)) + mem.getOffset(stackName);
    }
};
