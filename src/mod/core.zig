//! # core
//! The core module is a namespace containing the runtime bytecode representation,
//! as well as the Ribbon virtual machine's `Fiber` implementation,
//! and their supporting data structures.
//!
//! Key Components:
//! - Fiber: The central execution context, containing all stacks (data, calls, registers).
//! - Bytecode: A container for compiled code, including symbol and address tables.
//! - Function, Builtin: Representations for guest-code functions and host-provided functions.
//! - Layout: A primitive used throughout to define the memory size and alignment of types.
//! - Effect, Handler, HandlerSet: Primitives for implementing the algebraic effects system.
//!
//! Also contained here are all the primary constant values used by the vm, such as the maximum number of registers;
//! and various low-level data structures used by the vm, such as layout representation primitives.
const core = @This();

const std = @import("std");
const log = std.log.scoped(.core);

const common = @import("common");

const build_info = @import("build_info");

test {
    std.testing.refAllDeclsRecursive(@This());
}

// Basic constants and types for ids and simple component data //

/// The exact semantic version of the Ribbon language this module was built for.
pub const VERSION = build_info.version;

/// The size of a virtual opcode, in bytes.
pub const OPCODE_SIZE = 2;

/// The size of a virtual opcode, in bits.
pub const OPCODE_SIZE_BITS = common.bitsFromBytes(OPCODE_SIZE);

/// The alignment of bytecode instructions.
pub const BYTECODE_ALIGNMENT = 8;

/// The size of the data stack in words.
pub const DATA_STACK_SIZE = common.bytesFromMegabytes(1) / 8;
/// The size of the call stack in frames.
pub const CALL_STACK_SIZE = 1024;
/// The size of the set stack in frames.
pub const SET_STACK_SIZE = 4096;

/// The size of a register in bits.
pub const REGISTER_SIZE_BITS = 64;
/// The size of a register in bytes.
pub const REGISTER_SIZE_BYTES = 8;
/// The maximum number of registers.
pub const MAX_REGISTERS = 255;
/// The maximum number of unique effect types within a ribbon runtime instance.
pub const MAX_EFFECT_TYPES = std.math.maxInt(u16);

// The number of bits used for symbolic identity of module level values.
pub const STATIC_ID_BITS = common.bitsFromBytes(STATIC_ID_BYTES);
/// The number of bytes used for symbolic identity of module level values.
pub const STATIC_ID_BYTES = 4;
/// The number of bits used for symbolic identity of local values.
pub const LOCAL_ID_BITS = common.bitsFromBytes(LOCAL_ID_BYTES);
/// The number of bytes used for symbolic identity of local values.
pub const LOCAL_ID_BYTES = 2;

/// The maximum alignment value.
pub const MAX_ALIGNMENT = 4096;

/// The maximum size of a bytecode section.
pub const MAX_VIRTUAL_CODE_SIZE = common.bytesFromMegabytes(64);

/// The maximum size of a jit-compiled machine code section.
pub const MAX_MACHINE_CODE_SIZE = common.bytesFromMegabytes(64);

/// The C ABI we're using.
pub const ABI: Abi = if (@import("builtin").os.tag == .windows) .win else .sys_v;

/// Description of the C ABI used by the current hardware.
pub const Abi = enum {
    sys_v,
    win,

    /// The number of registers used for passing arguments under this Abi.
    pub fn argumentRegisterCount(self: Abi) usize {
        return switch (self) {
            .sys_v => 6,
            .win => 4,
        };
    }
};

/// The maximum number of arguments we allow to be passed in `callForeign`.
pub const MAX_FOREIGN_ARGUMENTS = 4;

/// Call a foreign function with a dynamic number of arguments.
/// * It is undefined behavior (checked in safe modes) to call this function with slices of a length more than `MAX_FOREIGN_ARGUMENTS`.
/// * This function cannot handle stack operands, and you must perform aggregate splitting yourself on platforms where this is necessary.
pub fn callForeign(fnPtr: *const anyopaque, args: []const usize) usize {
    return switch (args.len) {
        0 => @as(*const fn () callconv(.c) usize, @ptrCast(@alignCast(fnPtr)))(),
        1 => @as(*const fn (usize) callconv(.c) usize, @ptrCast(@alignCast(fnPtr)))(args[0]),
        2 => @as(*const fn (usize, usize) callconv(.c) usize, @ptrCast(@alignCast(fnPtr)))(args[0], args[1]),
        3 => @as(*const fn (usize, usize, usize) callconv(.c) usize, @ptrCast(@alignCast(fnPtr)))(args[0], args[1], args[2]),
        4 => @as(*const fn (usize, usize, usize, usize) callconv(.c) usize, @ptrCast(@alignCast(fnPtr)))(args[0], args[1], args[2], args[3]),
        else => unreachable,
    };
}

/// Whether runtime safety checks are enabled.
pub const RUNTIME_SAFETY: bool = switch (@import("builtin").mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

/// The size of a page.
pub const PAGE_SIZE = common.PAGE_SIZE;

comptime {
    if (PAGE_SIZE < MAX_ALIGNMENT) {
        @compileError("Unsupported target; the page size must be comptime known, and at least as large as MAX_ALIGNMENT");
    }
}

/// Represents the bit size of an integer type; we allow arbitrary bit-width integers, from 0 up to the max `Alignment`.
pub const IntegerBitSize: type = std.math.IntFittingRange(0, MAX_ALIGNMENT);

/// Set of `core.MAX_REGISTERS` virtual registers for a function call.
pub const RegisterArray: type = [core.MAX_REGISTERS]RegisterBits;

/// A stack allocator for virtual register arrays.
pub const RegisterStack: type = common.Stack.new(RegisterArray, CALL_STACK_SIZE);
/// A stack allocator, allocated in 64-bit word increments; for arbitrary data within a fiber.
pub const DataStack: type = common.Stack.new(RegisterBits, DATA_STACK_SIZE);
/// A stack allocator; for Rvm's function call frames within a fiber.
pub const CallStack: type = common.Stack.new(CallFrame, CALL_STACK_SIZE);
/// A stack allocator; for Rvm's effect handler set frames within a fiber.
pub const SetStack: type = common.Stack.new(SetFrame, SET_STACK_SIZE);

/// The type of a relative jump offset within a Ribbon bytecode program.
pub const InstructionOffset = i32;
/// The type of a frame-relative stack offset within a Ribbon bytecode program.
pub const StackOffset = i32;

/// The address of an instruction in a Ribbon bytecode program.
pub const InstructionAddr: type = [*]const InstructionBits;
/// The address of an instruction in a Ribbon bytecode program, while it is being constructed.
pub const MutInstructionAddr: type = [*]InstructionBits;

/// The bits of an encoded instruction, represented by an unsigned integer of the same size.
pub const InstructionBits: type = std.meta.Int(.unsigned, common.bitsFromBytes(BYTECODE_ALIGNMENT));
/// The bits of a register, represented by a 64-bit unsigned integer.
pub const RegisterBits: type = std.meta.Int(.unsigned, REGISTER_SIZE_BITS);

pub const Mutability = common.Mutability;
pub const Signedness = common.Signedness;

pub const StaticId = common.Id.of(anyopaque, STATIC_ID_BITS);
pub const ConstantId = common.Id.of(Constant, STATIC_ID_BITS);
pub const GlobalId = common.Id.of(Global, STATIC_ID_BITS);
pub const FunctionId = common.Id.of(Function, STATIC_ID_BITS);
pub const BuiltinId = common.Id.of(Builtin, STATIC_ID_BITS);
pub const ForeignAddressId = common.Id.of(ForeignAddress, STATIC_ID_BITS);
pub const HandlerId = common.Id.of(Handler, STATIC_ID_BITS);
pub const EffectId = common.Id.of(Effect, STATIC_ID_BITS);
pub const HandlerSetId = common.Id.of(HandlerSet, STATIC_ID_BITS);

pub const UpvalueId = common.Id.of(Upvalue, LOCAL_ID_BITS);
pub const BlockId = common.Id.of(Block, core.LOCAL_ID_BITS);
pub const LocalId = common.Id.of(Local, core.LOCAL_ID_BITS);

/// Represents the alignment of a value type; the max alignment is the minimum page size supported.
///
/// `0` is not an applicable *machine* alignment, but may appear in some cases, such as on zero-sized types.
/// It generally indicates a lack of a need for an address,
/// while an alignment of `1` indicates an address is required, but it may be totally arbitrary.
/// Successive integers (generally powers of two) indicate that proper use of a data structure
/// relies on being placed at an address that is a multiple of that value.
pub const Alignment: type = std.math.IntFittingRange(0, MAX_ALIGNMENT);

/// Represents the size of a value type; the max size is determined by the maximum alignment's bit representation.
pub const Size: type = std.meta.Int(.unsigned, 64 - @bitSizeOf(Alignment));

/// Simple value layout for Ribbon's constant and global values.
pub const Layout = packed struct {
    size: Size,
    alignment: Alignment,

    /// The default `Layout`, no size, align 1.
    pub const none: Layout = .{ .size = 0, .alignment = 1 };

    /// `@sizeOf(T)` + `@alignOf(T)`, converted to our runtime representation types.
    pub fn of(comptime T: type) Layout {
        return Layout{
            .size = @sizeOf(T),
            .alignment = @alignOf(T),
        };
    }

    /// Computes an optimal layout for a set of items, sorting them by alignment.
    ///
    /// This is a pure computational function that requires the caller to provide all buffers.
    ///
    /// - `data`: Input slice of `Layout`s for each item.
    /// - `indices`: Output slice. Will be populated with the item indices (0..n-1)
    ///   sorted according to the final, optimal layout order.
    /// - `offsets`: Output slice. Will be populated with the final stack offset for
    ///   each corresponding item in the `data` slice.
    ///
    /// Returns the final `Layout` of the entire container.
    ///
    /// * Panics if the input slices are not of equal length.
    pub fn computeOptimalCommonLayout(
        data: []const Layout,
        indices: []u64,
        offsets: []u64,
    ) Layout {
        if (data.len != indices.len or data.len != offsets.len) {
            std.debug.panic("core.Layout.computeOptimalCommonLayout: Input slices must be of equal length, got {d}, {d}, {d}", .{
                data.len,
                indices.len,
                offsets.len,
            });
        }

        if (data.len == 0) {
            return Layout{ .size = 0, .alignment = 1 };
        }

        // Find max alignment and populate indices
        var max_alignment: Alignment = 1;
        for (data, 0..) |lyt, i| {
            indices[i] = i; // Populate with original indices 0, 1, 2...
            if (lyt.alignment > max_alignment) {
                max_alignment = lyt.alignment;
            }
        }

        // Sort indices by layout
        // The `indices` slice is sorted in-place. Its final state is the layout order.
        std.mem.sort(u64, indices, data, struct {
            pub fn sorter(context: []const Layout, a_idx: u64, b_idx: u64) bool {
                const layout_a = context[a_idx];
                const layout_b = context[b_idx];
                if (layout_a.alignment > layout_b.alignment) return true;
                if (layout_a.alignment < layout_b.alignment) return false;
                if (layout_a.size > layout_b.size) return true;
                if (layout_a.size < layout_b.size) return false;
                return a_idx < b_idx;
            }
        }.sorter);

        // Calculate layout offsets
        // We iterate using the sorted `indices` to determine the layout order,
        // but we write the results to the `offsets` slice at the correct original index.
        var current_size: Size = 0;
        for (indices) |original_index| {
            const lyt = data[original_index];
            const aligned_offset = common.alignTo(current_size, lyt.alignment);

            offsets[original_index] = aligned_offset;

            current_size = aligned_offset + lyt.size;
        }

        // Finalization
        const final_size = common.alignTo(current_size, max_alignment);

        return Layout{
            .size = final_size,
            .alignment = max_alignment,
        };
    }
};

/// The base and upper address of a code section.
pub const Extents = packed struct(u128) {
    /// The base address of the code section.
    base: InstructionAddr,
    /// The upper address of the code section. (1 past the last instruction)
    upper: InstructionAddr,

    /// Returns whether an instruction address is within the bounds of this code section.
    pub fn boundsCheck(self: Extents, addr: InstructionAddr) bool {
        log.debug("bounds check {x}:({x} to {x}) {} {}", .{
            @intFromPtr(addr),
            @intFromPtr(self.base),
            @intFromPtr(self.upper),
            @intFromPtr(addr) >= @intFromPtr(self.base),
            @intFromPtr(addr) < @intFromPtr(self.upper),
        });
        return (@intFromPtr(addr) >= @intFromPtr(self.base)) and (@intFromPtr(addr) < @intFromPtr(self.upper));
    }
};

// The primary static symbol definition types used within the vm //

/// A reference to a virtual register.
pub const Register = enum(std.math.IntFittingRange(0, MAX_REGISTERS)) {
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
    r241, r242, r243, r244, r245, r246, r247, r248, r249, r250, r251, r252, r253, r254,

    scratch,
    // zig fmt: on

    pub const native_ret: Register = .r0;
    pub const native_cancelled_frame: Register = .r1;

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
        return @intFromEnum(self) * REGISTER_SIZE_BYTES;
    }

    pub fn format(self: Register, writer: *std.io.Writer) !void {
        try writer.print("r{d}", .{@intFromEnum(self)});
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
            .builtin => Builtin,
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
            Builtin => .builtin,
            ForeignAddress => .foreign_address,
            HandlerSet => .handler_set,
            Effect => .effect,
            else => @compileError("SymbolKind.fromType: unsupported type `" ++ @typeName(T) ++ "`"),
        };
    }

    /// Get the byte size of the value type corresponding to this `SymbolKind`.
    pub fn byteSize(kind: SymbolKind) usize {
        inline for (comptime std.meta.fieldNames(SymbolKind)) |name| {
            const sym = comptime @field(SymbolKind, name);
            const T = SymbolKind.toType(sym);

            if (sym == kind) return @sizeOf(T);
        } else unreachable;
    }

    /// Get the bit size of the value type corresponding to this `SymbolKind`.
    pub fn bitSize(kind: SymbolKind) usize {
        inline for (comptime std.meta.fieldNames(SymbolKind)) |name| {
            const sym = comptime @field(SymbolKind, name);
            const T = SymbolKind.toType(sym);

            if (sym == kind) return @bitSizeOf(T);
        } else unreachable;
    }

    /// Get the alignment of the value type corresponding to this `SymbolKind`.
    pub fn alignment(kind: SymbolKind) Alignment {
        inline for (comptime std.meta.fieldNames(SymbolKind)) |name| {
            const sym = comptime @field(SymbolKind, name);
            const T = SymbolKind.toType(sym);

            if (sym == kind) return @alignOf(T);
        } else unreachable;
    }

    /// Convert an `Id` type to a `SymbolKind`.
    pub fn fromIdType(comptime T: type) SymbolKind {
        return switch (T) {
            ConstantId => .constant,
            GlobalId => .global,
            FunctionId => .function,
            BuiltinId => .builtin,
            ForeignAddressId => .foreign_address,
            HandlerId => .handler_set,
            EffectId => .effect,
            HandlerSetId => .handler_set,
            else => @compileError("SymbolKind.fromIdType: unsupported type `" ++ @typeName(T) ++ "`"),
        };
    }

    /// Convert a `SymbolKind` to an `Id` type.
    pub fn asIdType(comptime kind: SymbolKind) type {
        return switch (kind) {
            .constant => ConstantId,
            .global => GlobalId,
            .function => FunctionId,
            .builtin => BuiltinId,
            .foreign_address => ForeignAddressId,
            .effect => EffectId,
            .handler_set => HandlerSetId,
        };
    }
};

/// Intent-communication alias for `*anyopaque`.
pub const ForeignAddress = *anyopaque;

/// Marker type for UpvalueId.
pub const Upvalue = struct {};

/// Marker type for BlockId.
pub const Block = struct {};

/// Marker type for LocalId.
pub const Local = struct {};

/// A Ribbon constant value definition.
/// * This is essentially a header type; the actual bytes of the value are expected to be encoded just past the address
///
///     The expected layout is:
///     ```txt
///     [ core.Constant .. padding bytes .. constant data bytes described by core.Constant.layout ]
///     ```
pub const Constant = packed struct {
    /// Designates the size and alignment of the constant data following this struct in memory.
    layout: Layout,

    /// Creates a `Constant` header from a `Layout`.
    pub fn fromType(comptime T: type) Constant {
        return .{ .layout = .of(T) };
    }

    /// Creates a `Constant` header from a `Layout`.
    pub fn fromLayout(layout: Layout) Constant {
        return .{ .layout = layout };
    }

    /// Converts a `Constant` pointer to a pointer to the constant data.
    pub fn asPtr(self: *const Constant) [*]const u8 {
        const base = @as([*]const u8, @ptrCast(self)) + @sizeOf(Constant);
        const padding = common.alignDelta(base, self.layout.alignment);

        return base + padding;
    }

    /// Converts a `Constant` pointer to a slice of the constant data.
    pub fn asSlice(self: *const Constant) []const u8 {
        return self.asPtr()[0..self.layout.size];
    }
};

/// A Ribbon global variable definition.
/// * This is essentially a header type; the actual bytes of the value are expected to be encoded just past the address
///
///     The expected layout is:
///     ```txt
///     [ core.Global .. padding bytes .. global data bytes described by core.Global.layout ]
///     ```
pub const Global = packed struct {
    /// Designates the size and alignment of the global data following this struct in memory.
    layout: Layout,

    pub fn fromLayout(layout: Layout) Global {
        return .{ .layout = layout };
    }

    pub fn asPtr(self: *const Global) [*]u8 {
        const base = @as([*]u8, @ptrCast(@constCast(self))) + @sizeOf(Global);
        const padding = common.alignDelta(base, self.layout.alignment);

        return base + padding;
    }

    pub fn asSlice(self: *const Global) []u8 {
        return self.asPtr()[0..self.layout.size];
    }
};

/// Designates a specific Ribbon effect, runtime-wide.
/// EffectId is used to bind to one of these within individual bytecode units.
pub const Effect = enum(std.math.IntFittingRange(0, MAX_EFFECT_TYPES)) {
    _,

    pub fn toIndex(self: Effect) std.meta.Tag(Effect) {
        return @intFromEnum(self);
    }
};

/// Abstraction for the disambiguation of bytecode and builtin functions.
/// When you take the address of a function, the type is lost; but we can recover it by inspecting the first byte at the address for this marker type.
pub const InternalFunctionKind = enum(u8) {
    /// A bytecode function.
    bytecode = 0xBC,
    /// A builtin function.
    builtin = 0xBF,

    /// Get the internal function kind from an internal function address.
    pub fn fromAddress(addr: *const anyopaque) InternalFunctionKind {
        return @enumFromInt(@as(*const u8, @ptrCast(addr)).*);
    }
};

/// A Ribbon function definition.
pub const Function = extern struct {
    /// Static marker differentiating bytecode and builtin functions.
    /// * This must remain as the first field and must not be mutated, because we allow taking the address of static values in the VM.
    ///   In order to disambiguate these addresses' types later (ie, builtin vs bytecode), we inspect the first byte of the address. See also `core.Builtin.kind`.
    kind: InternalFunctionKind = .bytecode,
    /// The `Bytecode` that owns this function,
    /// which we rely on to resolve the ids encoded in the function's instructions.
    unit: *const Bytecode = .empty,
    /// A pair of offsets:
    /// * `base`: the function's first instruction in the bytecode unit; the entry point
    /// * `upper`: one past the end of its instructions; for bounds checking
    extents: Extents,
    /// The size and alignment of the function's stack frame.
    layout: Layout,
};

/// A Ribbon host-builtin function definition; two words, bit packed.
///
/// The first word is composed of:
/// - **`kind` (8 bits):** A marker, always `InternalFunctionKind.builtin`.
///     This is used by the interpreter to disambiguate this from a `core.Function` when only an address is available.
/// - **`addr` (56 bits):** A C-ABI function address matching either of the `Builtin.Procedure` or `Builtin.Closure` signatures.
///
/// The second word (`extra`) is a `u64` used to hold an optional pointer to closure state.
///
/// ### C ABI, JIT compilation and stateful built-ins
///
/// We use the host platform's C ABI calling convention for built-in functions.
/// This choice enables two simplifying features:
/// * runtime *arity polymorphism*
/// * unified handling for both JIT-compiled and host-provided functions.
///
/// The benefit for JIT compilation is straightforward, as the compiler can simply target this C ABI signature for all internal calls.
/// The runtime arity polymorphism however, is a more subtle and powerful consequence of this design.
///
/// Certain stipulations of the C ABI's specification, when understood together,
/// allow the VM to invoke both `Procedure` (no state) and `Closure` (with state) functions using the exact same call sequence,
/// always passing the `extra` field as the second argument. This simplifies the VM's interpreter loop,
/// as it doesn't need to branch based on the type of built-in it's calling.
///
/// To be precise, this works safely and efficiently due to these properties of the C ABI:
///
/// #### Standardized Argument Passing
/// The first few word-sized arguments to a function are passed in specific registers.
/// * Our first argument is always the `*core.Fiber`.
/// * Our second argument is the `?*const anyopaque` state pointer from the `extra` field.
///
/// #### No Aggregate Types
/// The interface strictly uses word-sized types (addresses), avoiding complex platform-specific ABI rules
/// for passing structs or other aggregates on the stack (like Sys-V aggregate splitting).
///
/// #### Caller-Saved Registers
/// The registers used for passing arguments are designated as "caller-saved." This is the critical point.
///
/// When we call a `Procedure` (which only expects one argument), the second argument register is populated with the `extra` data,
/// but the `Procedure` simply ignores it. Because the register is caller-saved, it is the *caller's* responsibility to clean it up, not the callee's.
///
/// The `Procedure` does not need to perform any extra work or even be aware that it received a superfluous argument.
pub const Builtin = packed struct(u128) {
    /// The kind of builtin this is.
    /// * This must come first and must not be mutated, as we allow taking the address of static values in the VM.
    ///   In order to disambiguate these addresses' types later (ie, builtin vs bytecode),
    ///   we inspect the first byte of the address. See also `core.Function.kind`.
    kind: InternalFunctionKind = .builtin,
    /// The actual address of the builtin function.
    addr: u56,
    /// The address of the closure state, if present.
    extra: u64,

    /// Zig versions of `BuiltinSignal`s that can be returned by a built-in function or assembly code.
    pub const SignalError = error{
        // The built-in function is cancelling a computation it was prompted by.
        cancel,

        /// An unexpected error has occurred in a built-in function; runtime should panic.
        panic,

        /// Indicates that a guest function call requested the runtime to trap.
        request_trap,
    };

    /// Signals that can be returned by a built-in function / assembly code.
    pub const Signal = enum(i64) {
        // Nominal signals

        /// The built-in function is finished and returning a value.
        @"return" = 0,
        // The built-in function is cancelling a computation it was prompted by.
        cancel = 1,

        // Misc signals

        /// Indicates that a guest function call requested the runtime to trap.
        request_trap = std.math.minInt(i64),

        /// An unexpected error has occurred in a built-in function; runtime should panic.
        panic = std.math.maxInt(i64),

        // Standard errors

        /// Indicates that a guest function call reached an invalid state.
        @"unreachable" = -1,
        /// Indicates that a built-in function call requested the fiber to trap.
        function_trapped = -2,
        /// Indicates that the interpreter encountered an invalid encoding.
        bad_encoding = -3,
        /// Indicates an overflow of one of the stacks in a fiber.
        overflow = -4,
        /// Indicates an underflow of one of the stacks in a fiber.
        underflow = -5,
        /// Indicates that a guest function attempted to call a missing effect handler.
        missing_evidence = -6,
    };

    /// The type of procedures which do not have a local state and can operate as "built-in" functions
    /// (those provided by the host environment) within Ribbon's `core.Fiber`.
    ///
    /// Can be called within a `Fiber` using `interpreter.invokeBuiltin`.
    ///
    /// See `Builtin` for detailed documentation on builtin usage, construction, and lifecycle.
    pub const Procedure = fn (fiber: *core.Fiber) callconv(.c) Signal;

    /// The type of procedures which have a local state and can operate as "built-in" functions
    /// (those provided by the host environment) within Ribbon's `core.Fiber`.
    ///
    /// Can be called within a `Fiber` using `interpreter.invokeBuiltin`.
    ///
    /// See `Builtin` for detailed documentation on builtin usage, construction, and lifecycle.
    pub const Closure = fn (fiber: *core.Fiber, local_state: ?*const anyopaque) callconv(.c) Signal;

    /// Create a `Builtin` from a procedure pointer.
    pub fn fromProcedure(ptr: *const Procedure) Builtin {
        return Builtin{
            .kind = .builtin,
            .addr = @intCast(@intFromPtr(ptr)),
            .extra = 0, // No local state for procedures
        };
    }

    /// Create a `Builtin` from a closure.
    pub fn fromClosure(ptr: anytype, local_state: anytype) Builtin {
        comptime { // typecheck the function signature
            const F = @typeInfo(@TypeOf(ptr)).pointer.child;
            const S = @TypeOf(local_state);

            const F_info = @typeInfo(F).@"fn";
            const result = F_info.return_type.?;
            const params = F_info.params;

            const c_conv = std.builtin.CallingConvention.c;
            const ConvTag = std.meta.Tag(std.builtin.CallingConvention);

            if (@as(ConvTag, F_info.calling_convention) != @as(ConvTag, c_conv) or F_info.is_generic or F_info.is_var_args) {
                @compileError("core.Builtin.fromClosure: Expected a zig function with standard C calling convention, got " ++ @typeName(F));
            }

            if (params.len != 2) {
                @compileError("core.Builtin.fromClosure: Expected a zig function with exactly two parameters, got " ++ @typeName(F));
            }

            if (params[0].type != *core.Fiber) {
                @compileError("core.Builtin.fromClosure: Expected a zig function with a first parameter of type `*core.Fiber`, got " ++ @typeName(F));
            }

            if (params[1].type != S) {
                @compileError("core.Builtin.fromClosure: Expected a zig function with the second parameter being a pointer to the local state (of type " ++ @typeName(S) ++ "), got " ++ @typeName(F));
            }

            if (result != Signal) {
                @compileError("core.Builtin.fromClosure: Expected a zig function with a return type of `core.Builtin.Signal`, got " ++ @typeName(F));
            }
        }

        return Builtin{
            .addr = @intCast(@intFromPtr(ptr)),
            .extra = @intCast(@intFromPtr(local_state)),
        };
    }

    /// Invoke this `Builtin` on the provided fiber.
    pub fn invoke(self: *const Builtin, fiber: *core.Fiber) Signal {
        const func: *const Closure = @ptrFromInt(self.addr);

        return func(fiber, @ptrFromInt(self.extra));
    }
};

/// A Ribbon effect handler set definition. Data is relative to the function.
pub const HandlerSet = extern struct {
    /// The actual effect handlers used by this set.
    handlers: Buffer,
    /// Cancellation configuration for this handler set.
    cancellation: Cancellation,

    /// A `Buffer` of effect Handlers for a `HandlerSet`.
    pub const Buffer = common.Buffer.short(Handler, .constant);

    /// Get a pointer to a `Handler` from its `id`.
    pub fn getHandler(self: *const HandlerSet, id: HandlerId) *const Handler {
        return &self.handlers.asSlice()[id.toInt()];
    }

    /// Validate a `Handler` id.
    pub fn validateHandler(self: *const HandlerSet, id: HandlerId) bool {
        return self.handlers.asSlice().len > id.toInt();
    }
};

/// An effect handler definition.
pub const Handler = extern struct {
    /// The id of the effect this handler is for.
    effect: EffectId,
    /// The handler's address
    function: *const anyopaque,
};

/// `cancel` configuration for a `HandlerSet`.
pub const Cancellation = extern struct {
    /// The address to jump to if a handler in this set cancels.
    /// This should be the address *just past* the `pop_set` instruction that corresponds to the
    /// `push_set` that adds the handler set being canceled.
    address: InstructionAddr,
    /// The register to store any cancellation values in.
    register: Register,
};

// vm types for the fiber and bytecode data representation //

/// Represents an evidence structure.
pub const Evidence = extern struct {
    /// A pointer to the set frame this evidence belongs to.
    frame: *SetFrame,
    /// A pointer to the effect handler this evidence carries.
    handler: *const Handler,
    /// A pointer to the previous evidence, if there was already a set frame when this one was created.
    previous: ?*Evidence,
};

/// Represents a set frame.
pub const SetFrame = extern struct {
    /// A pointer to the call frame that created this set frame.
    call: *CallFrame,
    /// The effect handler set that defines this frame.
    handler_set: *const HandlerSet,
    /// The top_ptr of the data stack before this set frame was created.
    base: [*]RegisterBits,
};

/// Represents a call frame.
pub const CallFrame = extern struct {
    /// A pointer to the next instruction to execute.
    ip: InstructionAddr,
    /// A pointer to the function being executed in this frame;
    /// * may be either `*const Function`, `*const Builtin` or `ForeignAddress`;
    /// discriminated by `kind` field of our internal types and by the context of the call.
    function: *const anyopaque,
    /// A pointer to the evidence that this call frame was spawned by.
    evidence: ?*Evidence,
    /// The virtual register frame for this call.
    vregs: *RegisterArray,
    /// A pointer to the base of the data stack at this call frame.
    /// This pointer is guaranteed to be aligned according to the function's `layout` requirements.
    data: [*]RegisterBits,
    /// A pointer to the top-most SetFrame at this call frame.
    set_frame: *SetFrame,
    /// Output register designated where to place a return value from this frame, in the frame above it.
    output: Register,
};

/// All errors that can occur during execution of an Rvm fiber.
pub const Error = error{
    /// Indicates that a guest function call reached an invalid state.
    Unreachable,
    /// Indicates that a built-in function call requested the fiber to trap.
    FunctionTrapped,
    /// Indicates that the interpreter encountered an invalid encoding.
    BadEncoding,
    /// Indicates an overflow of one of the stacks in a fiber.
    Overflow,
    /// Indicates an underflow of one of the stacks in a fiber.
    Underflow,
    /// Indicates that a guest function attempted to call a missing effect handler.
    MissingEvidence,
};

/// Encapsulates all the state needed to execute a sub-routine within Rvm.
///
/// A *fiber* is a lightweight, independent code execution environment;
/// *in this case* emulating a CPU thread. Unlike true threads,
/// `Fiber`s are managed and stored in *[user space](https://en.wikipedia.org/wiki/User_space)*;
/// or in other words: we have full control over them, in terms of scheduling and memory management.
///
/// All data for a `Fiber` is stored contiguously in a single allocation;
/// they can be allocated and freed very efficiently.
///
/// Note that the size of `Fiber` is not the size of the allocation at addresses of type `*Fiber`, this is a header type.
pub const Fiber = extern struct {
    /// Stack of virtual register arrays - stores intermediate values up to a word in size, `pl.MAX_REGISTERS` per function.
    registers: RegisterStack,
    /// Arbitrary data stack allocator - stores intermediate values that need to be addressed or are larger than a word in size.
    data: DataStack,
    /// The call frame stack - tracks in-progress function calls.
    calls: CallStack,
    /// The effect handler set stack - manages lexically scoped effect handler sets.
    sets: SetStack,
    /// The evidence buffer - stores bindings to currently accessible effect handlers by effect id + linked lists via Evidence
    evidence: [MAX_EFFECT_TYPES]?*Evidence,
    /// The cause of a trap, if any was known. Pointee-type depends on the trap.
    /// * TODO: error handling function that covers this variance
    trap: ?*const anyopaque,
    /// Arbitrary user-data pointer, used by runtime environment to store fiber-local contextual data.
    userdata: ?*const anyopaque,

    /// Allocates and initializes a new fiber.
    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!*Fiber {
        const buf = try allocator.allocAdvancedWithRetAddr(u8, std.mem.Alignment.fromByteUnits(mem.ALIGNMENT), mem.SIZE, @returnAddress());

        log.debug("allocated address range {x} to {x} for {s}", .{ @intFromPtr(buf.ptr), @intFromPtr(buf.ptr) + buf.len, @typeName(Fiber) });

        const header: *Fiber = @ptrCast(buf.ptr);

        fiber_fields: inline for (comptime std.meta.fieldNames(Fiber)) |fieldName| {
            inline for (&.{ "loop", "trap", "breakpoint", "evidence", "userdata" }) |ignoredField| {
                if (comptime std.mem.eql(u8, fieldName, ignoredField)) {
                    continue :fiber_fields;
                }
            }

            const memoryOffset = comptime mem.getOffset(fieldName);
            @field(header, fieldName) = .init(@alignCast(buf.ptr + memoryOffset));
        }

        return header;
    }

    /// De-initializes the fiber, freeing its memory.
    pub fn deinit(self: *Fiber, allocator: std.mem.Allocator) void {
        const buf: []align(mem.ALIGNMENT) u8 = @alignCast(@as([*]u8, @ptrCast(self))[0..mem.SIZE]);
        allocator.free(buf);
    }

    /// Get a pointer to one of the stacks' memory block.
    /// * This function can be called at both runtime and comptime.
    /// * The name of the stack can be either a string or an enum literal.
    pub fn getStack(self: *Fiber, stackName: anytype) [*]u8 {
        return @as([*]u8, @ptrCast(self.header)) + mem.getOffset(stackName);
    }

    /// Set the userdata pointer for this fiber.
    pub fn setUserdata(self: *Fiber, data: ?*const anyopaque) void {
        self.userdata = data;
    }

    /// Get the userdata pointer for this fiber.
    pub fn getUserdata(self: *const Fiber) ?*const anyopaque {
        return self.userdata;
    }

    /// Low level fiber memory constants and types.
    ///
    /// This comptime struct calculates the total memory size and field offsets for a Fiber
    /// and all its associated stacks. This allows the entire Fiber to exist in a single,
    /// contiguous memory allocation, which can be allocated and freed with a single call.
    /// It ensures correct alignment for all members, preventing padding issues and enabling
    /// efficient memory access.
    pub const mem = comptime_memorySize: {
        const REQUIRED_ALIGNMENT = 8; // we enforce 8-byte alignment on the entire fiber memory

        const FIELDS = std.meta.fieldNames(Fiber);

        std.debug.assert(@alignOf(Fiber) == REQUIRED_ALIGNMENT);

        var offsets: [FIELDS.len]comptime_int = undefined;
        var total = @sizeOf(Fiber);

        var k = 0;
        var fieldNames: [FIELDS.len][:0]const u8 = undefined;

        for (FIELDS) |fieldName| {
            const S = @FieldType(Fiber, fieldName);

            const alignment, const size = if (common.canHaveDecls(S)) .{ S.mem.ALIGNMENT, S.mem.SIZE } else continue;

            if (alignment != REQUIRED_ALIGNMENT) {
                @compileError(std.fmt.comptimePrint(
                    \\[Fiber.mem] - field "{s}" (of type `{s}`) in `Fiber` has incorrect alignment for its memory block;
                    \\              it is {d} but it should be == {}"
                    \\
                , .{ fieldName, @typeName(S), alignment, REQUIRED_ALIGNMENT }));
            }

            // ensure that we haven't screwed this up somehow
            std.debug.assert(total % alignment == 0);

            // not necessary: we've already ensured that the alignment is correct
            // total += pl.alignDelta(total, REQUIRED_ALIGNMENT);

            fieldNames[k] = fieldName;
            offsets[k] = total;
            k += 1;

            total += size;
        }

        std.debug.assert(common.alignDelta(total, REQUIRED_ALIGNMENT) == 0);

        const finalOffsets = final_offsets: {
            var out: [k]comptime_int = undefined;
            @memcpy(&out, offsets[0..k]);
            break :final_offsets out;
        };

        const finalFieldNames = final_field_names: {
            var out: [k][:0]const u8 = undefined;
            @memcpy(&out, fieldNames[0..k]);
            break :final_field_names out;
        };

        const DATA_FIELDS = data_fields: {
            var finalFields: [k]std.builtin.Type.EnumField = undefined;

            for (finalFieldNames, 0..) |fieldName, i| {
                finalFields[i] = std.builtin.Type.EnumField{
                    .name = fieldName,
                    .value = i,
                };
            }

            break :data_fields @Type(std.builtin.Type{ .@"enum" = .{
                .tag_type = u8,
                .fields = &finalFields,
                .decls = &.{},
                .is_exhaustive = true,
            } });
        };

        break :comptime_memorySize struct {
            /// The alignment required for the full fiber's `memory`.
            ///
            /// We enforce 8-byte alignment; this eliminates the need for padding.
            pub const ALIGNMENT = REQUIRED_ALIGNMENT;

            /// The total number of bytes required to store the full fiber's `memory`.
            /// * includes the `Fiber` and all stacks' memory blocks.
            pub const SIZE = total;

            /// The offsets of each section within the fiber's `memory`.
            pub const OFFSETS = finalOffsets;

            /// Byte block type representing a full `Fiber`, with all of its memory blocks.
            pub const FiberBuffer: type = extern struct {
                bytes: [SIZE]u8 align(REQUIRED_ALIGNMENT),
            };

            pub const DataFields = DATA_FIELDS;

            /// Get the offset of a field within the fiber's `memory`.
            /// * this function is comptime
            pub fn getOffset(comptime fieldName: []const u8) comptime_int {
                comptime return OFFSETS[@intFromEnum(@field(DataFields, fieldName))];
            }
        };
    };

    comptime {
        const mb = common.megabytesFromBytes(mem.SIZE);

        if (mb > 5.0) {
            @compileError(std.fmt.comptimePrint("Fiber total size is {d:.2}mb", .{mb}));
        }

        for (mem.OFFSETS, 0..) |o1, i| {
            for (mem.OFFSETS, 0..) |o2, j| {
                if (i == j) continue;

                if (o1 == o2) {
                    @compileError(std.fmt.comptimePrint("Fiber memory offset {d} collides with {d}", .{ i, j }));
                }
            }
        }
    }
};

/// A bytecode binary unit. Not necessarily self contained; may reference other units.
/// Light wrapper for `core.Bytecode`.
///
/// See `bytecode` module for construction methods.
///
/// Note that the size of `Bytecode` is not the size of the allocation at addresses of type `*Bytecode`, this is a header type.
pub const Bytecode = extern struct {
    /// The total size of the program.
    size: u64 = @sizeOf(Bytecode),
    /// Address table used by instructions this Bytecode owns.
    address_table: AddressTable = .{},
    /// Symbol bindings for the address table; what this program calls different addresses.
    ///
    /// Not necessarily a complete listing for all bindings;
    /// only what it wants to be known externally.
    symbol_table: SymbolTable = .{},

    /// A static minimal valid header.
    pub const empty: *const Bytecode = &Bytecode{ .size = 0 };

    /// Get an address from an ID.
    /// * Does not perform any validation outside of debug mode
    pub fn get(self: *const Bytecode, id: anytype) *const @TypeOf(id).Value {
        return self.address_table.get(id);
    }

    /// Get the address of a symbol by name, in a type-generic manner.
    /// * **Note**: This uses the raw table to lookup a symbol. While we do store symbol hashes to
    /// speed this up a bit, for large symbol tables it is likely better to use a hashmap.
    pub fn lookupAddress(self: *const Bytecode, name: []const u8) ?struct { SymbolKind, *const anyopaque } {
        const id = self.symbol_table.lookupId(name) orelse return null;
        return .{ self.address_table.getKind(id), self.address_table.getAddress(id) };
    }

    /// Get the address of a symbol within a given type by name.
    /// * **Note**: This uses the raw table to lookup a symbol. While we do store symbol hashes to
    /// speed this up a bit, for large symbol tables it is likely better to use a hashmap.
    pub fn lookupAddressOf(self: *const Bytecode, comptime T: type, name: []const u8) error{TypeError}!?*const T {
        const K = SymbolKind.fromType(T);

        const erased = self.lookupAddress(name) orelse return null;

        return if (erased[0] == K) @ptrCast(@alignCast(erased[1])) else {
            @branchHint(.unlikely);
            return error.TypeError;
        };
    }

    /// De-initialize the bytecode unit, freeing the memory that it owns.
    pub fn deinit(self: *Bytecode, allocator: std.mem.Allocator) void {
        const base: [*]const u8 = @ptrCast(self);
        const buf: []align(PAGE_SIZE) const u8 = @alignCast(base[0 .. @sizeOf(Bytecode) + self.size]);
        allocator.free(buf);
    }
};

/// This is an indirection table for the `Id`s used by instruction encodings.
///
/// The addresses are resolved at *link time*, so where they actually point is environment-dependent;
/// ownership varies.
pub const AddressTable = extern struct {
    /// The actual addresses of the symbols in this table.
    addresses: [*]const *const anyopaque = undefined,
    /// The kind of symbol stored in the adjacent address buffer slot.
    kinds: [*]const SymbolKind = undefined,
    /// The number of symbol/address pairs in this table.
    len: u32 = 0,

    /// Get a slice of all symbol kinds in this address table.
    pub fn kindSlice(self: *const AddressTable) []const SymbolKind {
        return self.kinds[0..self.len];
    }

    /// Get a slice of all addresses in this address table.
    pub fn addressSlice(self: *const AddressTable) []const *const anyopaque {
        return self.addresses[0..self.len];
    }

    /// Get the SymbolKind of an address by its id.
    /// * Does not perform any validation outside of safe modes
    pub fn getKind(self: *const AddressTable, id: StaticId) SymbolKind {
        return self.kindSlice()[id.toInt()];
    }

    /// Get the address of a static value by its id.
    /// * Does not perform any validation outside of safe modes
    pub fn getAddress(self: *const AddressTable, id: StaticId) *const anyopaque {
        return self.addressSlice()[id.toInt()];
    }

    /// Get the address of a typed static by its id.
    /// * Does not perform bounds checking or type checking outside of safe modes
    pub fn get(self: *const AddressTable, id: anytype) *const @TypeOf(id).Value {
        const T = @TypeOf(id);

        const addr = self.getAddress(id.cast(anyopaque));

        if (comptime T == StaticId) {
            return addr;
        } else {
            const kind = self.getKind(id.cast(anyopaque));
            const id_kind = comptime SymbolKind.fromIdType(T);

            std.debug.assert(kind == id_kind);

            return @ptrCast(@alignCast(addr));
        }
    }

    /// Determine if the provided id exists and has the given kind.
    pub fn validateSymbol(self: *const AddressTable, id: StaticId) bool {
        return self.len > id.toInt();
    }

    /// Determine if the provided id exists and has the given kind.
    pub fn validateSymbolKind(self: *const AddressTable, kind: SymbolKind, id: StaticId) bool {
        const kinds = self.kindSlice();
        const index = id.toInt();

        return kinds.len > index and kinds[index] == kind;
    }

    /// Determine if the provided id exists and has the given kind.
    pub fn validate(self: *const AddressTable, id: anytype) bool {
        const T = @TypeOf(id);

        if (comptime T == StaticId) {
            return id.toInt() < self.len;
        } else {
            const id_kind = comptime SymbolKind.fromIdType(T);

            if (self.tryGetKind(id)) |kind| {
                @branchHint(.likely);

                return kind == id_kind;
            }

            return false;
        }
    }

    /// Get the SymbolKind of an address by its id, if it is bound.
    pub fn tryGetKind(self: *const AddressTable, id: StaticId) ?SymbolKind {
        const kinds = self.kindSlice();
        const index = id.toInt();

        if (kinds.len > index) {
            return kinds[index];
        } else {
            @branchHint(.unlikely);

            return null;
        }
    }

    /// Get the address of a static value by its id, if it is bound.
    pub fn tryGetAddress(self: *const AddressTable, id: StaticId) ?*const anyopaque {
        const addresses = self.addressSlice();
        const index = id.toInt();

        if (addresses.len > index) {
            return addresses[index];
        } else {
            @branchHint(.unlikely);

            return null;
        }
    }

    /// Get the address of a typed static by its id, if it is bound.
    pub fn tryGet(self: *const AddressTable, id: anytype) ?*const @TypeOf(id).Value {
        if (self.tryGetAddress(id.cast(anyopaque))) |address| {
            @branchHint(.likely);

            const kind = self.getKind(id.cast(anyopaque));
            const id_kind = comptime SymbolKind.fromIdType(@TypeOf(id));

            if (kind == id_kind) {
                @branchHint(.likely);

                return @ptrCast(@alignCast(address));
            }
        }

        return null;
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
pub const SymbolTable = extern struct {
    /// The actual symbolic string values in this table.
    keys: [*]const Key = undefined,
    /// The symbolic id of the adjacent key buffer slot.
    values: [*]const StaticId = undefined,
    /// The number of key/value pairs in this table.
    len: u32 = 0,

    /// One half of a key/value pair used for address resolution in a `SymbolTable`.
    pub const Key = packed struct {
        /// The symbol text's hash value.
        hash: u64,
        /// The symbol's text value.
        name: Buffer,

        /// A short byte buffer for a symbol's name in a `SymbolTable.Key`.
        pub const Buffer = common.Buffer.short(u8, .constant);
    };

    /// Get a slice of all the keys in this symbol table.
    pub fn keySlice(self: *const SymbolTable) []const Key {
        return self.keys[0..self.len];
    }

    /// Get a slice of all the values in this symbol table.
    pub fn valueSlice(self: *const SymbolTable) []const StaticId {
        return self.values[0..self.len];
    }

    /// Get the id of a symbol by name.
    pub fn lookupId(self: SymbolTable, name: []const u8) ?StaticId {
        const hash = common.hash64(name);

        for (self.keySlice(), 0..) |key, i| {
            if (key.hash != hash) {
                @branchHint(.likely);
                continue;
            }

            if (std.mem.eql(u8, key.name.asSlice(), name)) {
                @branchHint(.likely);
                return self.valueSlice()[i];
            }
        }

        return null;
    }
};
