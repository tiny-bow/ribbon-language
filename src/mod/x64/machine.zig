//! This module provides a Just-In-Time (JIT) compiler and other utilities for the host architecture, (x64 in this case),
//! enabling dynamic generation and execution of machine code. Parts of this module are specialized
//! for use with `core`, while others are more general-purpose architecture-related items.
//!
//! This module serves as both the primary data structure and interface for the Builder,
//! as well as the namespace for supporting functions, types, etc.
//! A simple machine code disassembler is also provided here.
//!
//! ## Usage
//! 1. Initialize a `Builder` instance using `Builder.init`.
//! 2. Use the `Builder` instance to encode and write architecture-specific machine instructions.
//! 3. Finalize the builder to obtain a `NativeFunction`.
//! 4. Invoke the compiled function using `NativeFunction.invoke`.
//! 5. De-initialize any generated functions using `NativeFunction.deinit`.
//! 6. De-initialize the builder to free any allocated memory it still owns.
const machine = @This();

const std = @import("std");
const log = std.log.scoped(.X64Builder);

const common = @import("common");
const core = @import("core");
const assembler = @import("assembler");
const VirtualWriter = @import("common").VirtualWriter;

test {
    // std.debug.print("semantic analysis for x64/machine\n", .{});
    std.testing.refAllDeclsRecursive(@This());
}

const abi = @import("abi");

/// Disassemble an allocated machine function, printing to the provided writer.
pub fn disas(mem: common.VirtualMemory, options: assembler.DisassemblerOptions, writer: *std.io.Writer) !void {
    return assembler.disas(mem, options, writer);
}

/// A `BuiltinFunction`, but compiled at runtime.
///
/// Can be called within a `Fiber` using the `interpreter.invokeBuiltin` family of functions.
///
/// This is primarily a memory management structure,
/// as the jit is expected to disown the memory upon finalization.
pub const AllocatedBuiltinFunction = extern struct {
    /// The function's bytes.
    ptr: [*]align(common.PAGE_SIZE) const u8,
    /// The function's length in bytes.
    ///
    /// Note that this is not necessarily the length of the mapped memory, as it is page aligned.
    len: u64,

    /// `munmap` all pages of a native function, freeing the memory.
    pub fn deinit(self: AllocatedBuiltinFunction) void {
        std.posix.munmap(@alignCast(self.ptr[0..common.alignTo(self.len, common.PAGE_SIZE)]));
    }

    /// Get the function's machine code as a slice.
    pub fn toSlice(self: AllocatedBuiltinFunction) []align(common.PAGE_SIZE) const u8 {
        return self.ptr[0..self.len];
    }
};

/// Machine code function builder. `x64`
pub const Builder = struct {
    /// The x64 encoder used to generate machine code.
    encoder: Encoder,

    /// Represents an error that can occur during machine function building.
    pub const Error = error{
        /// The encoder ran out of memory.
        OutOfMemory,
        /// The encoding failed.
        BadEncoding,
    };

    /// Creates a new `Writer`, `Encoder`, and a `Builder`,
    /// then calls `Builder.prelude`,
    /// and returns the jit.
    pub fn init() error{OutOfMemory}!Builder {
        var self = Builder{
            .encoder = try Encoder.init(),
        };

        try self.prelude();

        return self;
    }

    /// De-initializes the jit, freeing any memory it still owns.
    pub fn deinit(self: *Builder) void {
        self.encoder.writer.deinit();
    }

    /// Finalizes the jit and returns a wrapper over the generated native function.
    ///
    /// After calling this function, the jit will be in its default initialization state.
    /// In other words, it is safe but not necessary to call `deinit` on it, and it is safe to reuse it immediately.
    ///
    /// ### Panics
    /// + If the OS does not allow `mprotect` with `READ | WRITE`
    pub fn finalize(self: *Builder) Error!AllocatedBuiltinFunction {
        const mem = try self.encoder.writer.finalize(.read_execute);

        return AllocatedBuiltinFunction{
            .ptr = mem.ptr,
            .len = mem.len,
        };
    }

    const REGISTERS_TOP_PTR_OFFSET = @offsetOf(core.Fiber, "registers") + @offsetOf(core.RegisterStack, "top_ptr");

    const FRAMES_TOP_PTR_OFFSET = @offsetOf(core.Fiber, "calls") + @offsetOf(core.CallStack, "top_ptr");

    // comptime {
    //     @compileError(std.fmt.comptimePrint("{x} {x}", .{ REGISTERS_TOP_PTR_OFFSET, FRAMES_TOP_PTR_OFFSET }));
    // }

    /// Inject the abi prelude code into the function being constructed.
    pub fn prelude(self: *Builder) error{OutOfMemory}!void { // FIXME: prelude here is not in sync with that of the interpreter asm
        // We use C ABI for jit compiled builtins, so first we need to capture the arguments into
        // callee-saved registers, so that they get persisted if we end up calling any functions.
        // In C ABI, the first 6 word-sized arguments are passed in registers, so we simply need
        // to move the Fiber argument into the first callee-saved register.
        self.encoder.mov(.register(abi.FIBER), .register(abi.AUX1)) catch {
            return error.OutOfMemory;
        };

        // In addition to the fiber pointer,
        // we will access the top of the virtual registers array stack and the current call frame frequently,
        // so we move them into callee-saved registers as well.
        self.encoder.mov(.register(abi.VREG), .ptr_offset(abi.FIBER, REGISTERS_TOP_PTR_OFFSET)) catch {
            return error.OutOfMemory;
        };
        self.encoder.mov(.register(abi.FRAME), .ptr_offset(abi.FIBER, FRAMES_TOP_PTR_OFFSET)) catch {
            return error.OutOfMemory;
        };
    }

    /// Builds a return instruction for a function.
    pub fn @"return"(self: *Builder, operand: ?Operand) Error!void {
        if (operand) |op| {
            switch (op) {
                .immediate => |im| try self.encoder.imm(im),
                .register_index => |r| try self.encoder.load(r),
            }

            try self.encoder.store(.native_ret);
        }

        try self.encoder.imm(@bitCast(@intFromEnum(core.Builtin.Signal.@"return")));
        try self.encoder.ret();
    }

    /// Builds a 64-bit integer add instruction.
    pub fn i_add64(self: *Builder, out: core.Register, a: Operand, b: Operand) Error!void {
        switch (a) {
            .register_index => |ra| switch (b) {
                .register_index => |rb| {
                    try self.encoder.mov(.register(abi.ACC), .ptr_offset(abi.VREG, @intCast(rb.getOffset())));
                    try self.encoder.i_add(.register(abi.ACC), .ptr_offset(abi.VREG, @intCast(ra.getOffset())));
                    try self.encoder.mov(.ptr_offset(abi.VREG, @intCast(out.getOffset())), .register(abi.ACC));
                },

                .immediate => |ib| {
                    try self.encoder.mov(.register(abi.ACC), .ptr_offset(abi.VREG, @intCast(ra.getOffset())));
                    try self.encoder.i_add(.register(abi.ACC), .im(ib));
                    try self.encoder.mov(.ptr_offset(abi.VREG, @intCast(out.getOffset())), .register(abi.ACC));
                },
            },

            .immediate => |ia| switch (b) {
                .register_index => |rb| {
                    try self.encoder.mov(.register(abi.ACC), .im(ia));
                    try self.encoder.i_add(.register(abi.ACC), .ptr_offset(abi.VREG, @intCast(rb.getOffset())));
                    try self.encoder.mov(.ptr_offset(abi.VREG, @intCast(out.getOffset())), .register(abi.ACC));
                },

                .immediate => |ib| {
                    try self.encoder.mov(.ptr_offset(abi.VREG, @intCast(out.getOffset())), .im(ia + ib));
                },
            },
        }
    }
};

/// Represents an operand for an x64 instruction.
pub const Operand = union(enum) {
    /// A register index.
    register_index: core.Register,
    /// An immediate value.
    immediate: u64,

    /// Creates an operand from a virtual register index.
    pub fn r(index: std.meta.Tag(core.Register)) Operand {
        return .{ .register_index = @enumFromInt(index) };
    }

    /// Creates an operand from an immediate value.
    pub fn im(value: anytype) Operand {
        const T = @TypeOf(value);
        return .{
            .immediate = switch (@typeInfo(T)) {
                .comptime_int => if (comptime std.math.sign(value) == -1) @as(u64, @bitCast(@as(i64, value))) else value,
                .comptime_float => @as(u64, @bitCast(@as(f64, value))),
                else => @as(std.meta.Int(.unsigned, @bitSizeOf(T)), @bitCast(value)),
            },
        };
    }
};

/// A `VirtualWriter` with a `platform.MAX_MACHINE_CODE_SIZE` memory limit.
pub const Writer: type = VirtualWriter.new(core.MAX_MACHINE_CODE_SIZE);

/// Wrapper over `VirtualWriter` that provides a machine instruction specific API.
pub const Encoder = struct {
    /// The `VirtualWriter` used by the encoder to write machine code.
    writer: Writer,

    pub const Error = Writer.Error || error{BadEncoding};

    /// Creates a new `Encoder` and a `Writer`.
    pub fn init() error{OutOfMemory}!Encoder {
        return Encoder{
            .writer = try Writer.init(),
        };
    }

    /// Writes as much of a slice of bytes to the encoder as will fit without an allocation.
    /// Returns the number of bytes written.
    pub fn write(self: *Encoder, noalias bytes: []const u8) Encoder.Error!usize {
        return self.writer.write(bytes);
    }

    /// Writes all bytes from a slice to the encoder.
    pub fn writeAll(self: *Encoder, bytes: []const u8) Encoder.Error!void {
        return self.writer.writeAll(bytes);
    }

    /// Writes a single byte to the encoder.
    pub fn writeByte(self: *Encoder, byte: u8) Encoder.Error!void {
        return self.writer.writeByte(byte);
    }

    /// Writes a byte to the encoder `n` times.
    pub fn writeByteNTimes(self: *Encoder, byte: u8, n: usize) Encoder.Error!void {
        return self.writer.writeByteNTimes(byte, n);
    }

    /// Writes a slice of bytes to the encoder `n` times.
    pub fn writeBytesNTimes(self: *Encoder, bytes: []const u8, n: usize) Encoder.Error!void {
        return self.writer.writeBytesNTimes(bytes, n);
    }

    /// Writes an integer to the encoder.
    pub fn writeInt(
        self: *Encoder,
        comptime T: type,
        value: T,
        comptime _: enum { little }, // allows backward compat with writer code in r64; but only in provably compatible use-cases
    ) Encoder.Error!void {
        const bytes = std.mem.asBytes(&value);
        try self.writeAll(bytes);
    }

    /// Encodes an x64 instruction.
    pub fn instr(self: *Encoder, mnemonic: assembler.Mnemonic, ops: []const assembler.Operand) Encoder.Error!void {
        return self.instrPfx(.none, mnemonic, ops);
    }

    /// Encodes an x64 instruction with a prefix.
    pub fn instrPfx(self: *Encoder, prefix: assembler.Prefix, mnemonic: assembler.Mnemonic, ops: []const assembler.Operand) Encoder.Error!void {
        const i = try assembler.Instruction.new(prefix, mnemonic, ops);

        i.encode(self, .{ .allow_frame_loc = true }) catch {
            return error.OutOfMemory;
        };
    }

    /// Loads an immediate value into `ACC`.
    pub fn imm(self: *Encoder, im: u64) error{OutOfMemory}!void {
        self.mov(.register(abi.ACC), .im(im)) catch {
            return error.OutOfMemory;
        };
    }

    /// Loads an immediate value into `AUX1`.
    pub fn imm1(self: *Encoder, im: u64) error{OutOfMemory}!void {
        self.mov(.register(abi.AUX1), .im(im)) catch {
            return error.OutOfMemory;
        };
    }

    /// Loads an immediate value into `AUX2`.
    pub fn imm2(self: *Encoder, im: u64) error{OutOfMemory}!void {
        self.mov(.register(abi.AUX2), .im(im)) catch {
            return error.OutOfMemory;
        };
    }

    /// Loads an immediate value into `AUX3`.
    pub fn imm3(self: *Encoder, im: u64) error{OutOfMemory}!void {
        self.mov(.register(abi.AUX3), .im(im)) catch {
            return error.OutOfMemory;
        };
    }

    /// Loads an immediate value into `AUX4`.
    pub fn imm4(self: *Encoder, im: u64) error{OutOfMemory}!void {
        self.mov(.register(abi.AUX4), .im(im)) catch {
            return error.OutOfMemory;
        };
    }

    /// Loads an immediate value into `AUX5`.
    pub fn imm5(self: *Encoder, im: u64) error{OutOfMemory}!void {
        self.mov(.register(abi.AUX5), .im(im)) catch {
            return error.OutOfMemory;
        };
    }

    /// Loads an immediate value into `AUX6`.
    pub fn imm6(self: *Encoder, im: u64) error{OutOfMemory}!void {
        self.mov(.register(abi.AUX6), .im(im)) catch {
            return error.OutOfMemory;
        };
    }

    /// Loads an immediate value into `TER_A`.
    pub fn immA(self: *Encoder, im: u64) error{OutOfMemory}!void {
        self.mov(.register(abi.TER_A), .im(im)) catch {
            return error.OutOfMemory;
        };
    }

    /// Loads an immediate value into `TER_B`.
    pub fn immB(self: *Encoder, im: u64) error{OutOfMemory}!void {
        self.mov(.register(abi.TER_B), .im(im)) catch {
            return error.OutOfMemory;
        };
    }

    /// Loads a value from a virtual register into `ACC`.
    pub fn load(self: *Encoder, r: core.Register) error{OutOfMemory}!void {
        self.mov(.register(abi.ACC), .ptr_offset(abi.VREG, @intCast(r.getOffset()))) catch {
            return error.OutOfMemory;
        };
    }

    /// Loads a value from a virtual register into `AUX1`.
    pub fn load1(self: *Encoder, r: core.Register) error{OutOfMemory}!void {
        self.mov(.register(abi.AUX1), .ptr_offset(abi.VREG, @intCast(r.getOffset()))) catch {
            return error.OutOfMemory;
        };
    }

    /// Loads a value from a virtual register into `AUX2`.
    pub fn load2(self: *Encoder, r: core.Register) error{OutOfMemory}!void {
        self.mov(.register(abi.AUX2), .ptr_offset(abi.VREG, @intCast(r.getOffset()))) catch {
            return error.OutOfMemory;
        };
    }

    /// Loads a value from a virtual register into `AUX3`.
    pub fn load3(self: *Encoder, r: core.Register) error{OutOfMemory}!void {
        self.mov(.register(abi.AUX3), .ptr_offset(abi.VREG, @intCast(r.getOffset()))) catch {
            return error.OutOfMemory;
        };
    }

    /// Loads a value from a virtual register into `AUX4`.
    pub fn load4(self: *Encoder, r: core.Register) error{OutOfMemory}!void {
        self.mov(.register(abi.AUX4), .ptr_offset(abi.VREG, @intCast(r.getOffset()))) catch {
            return error.OutOfMemory;
        };
    }

    /// Loads a value from a virtual register into `AUX5`.
    pub fn load5(self: *Encoder, r: core.Register) error{OutOfMemory}!void {
        self.mov(.register(abi.AUX5), .ptr_offset(abi.VREG, @intCast(r.getOffset()))) catch {
            return error.OutOfMemory;
        };
    }

    /// Loads a value from a virtual register into `AUX6`.
    pub fn load6(self: *Encoder, r: core.Register) error{OutOfMemory}!void {
        self.mov(.register(abi.AUX6), .ptr_offset(abi.VREG, @intCast(r.getOffset()))) catch {
            return error.OutOfMemory;
        };
    }

    /// Loads a value from a virtual register into `TER_A`.
    pub fn loadA(self: *Encoder, r: core.Register) error{OutOfMemory}!void {
        self.mov(.register(abi.TER_A), .ptr_offset(abi.VREG, @intCast(r.getOffset()))) catch {
            return error.OutOfMemory;
        };
    }

    /// Loads a value from a virtual register into `TER_B`.
    pub fn loadB(self: *Encoder, r: core.Register) error{OutOfMemory}!void {
        self.mov(.register(abi.TER_B), .ptr_offset(abi.VREG, @intCast(r.getOffset()))) catch {
            return error.OutOfMemory;
        };
    }

    /// Stores the value in `ACC` into a virtual register.
    pub fn store(self: *Encoder, r: core.Register) error{OutOfMemory}!void {
        self.mov(.ptr_offset(abi.VREG, @intCast(r.getOffset())), .register(abi.ACC)) catch {
            return error.OutOfMemory;
        };
    }

    /// Stores the value in `AUX1` into a virtual register.
    pub fn store1(self: *Encoder, r: core.Register) error{OutOfMemory}!void {
        self.mov(.ptr_offset(abi.VREG, @intCast(r.getOffset())), .register(abi.AUX1)) catch {
            return error.OutOfMemory;
        };
    }

    /// Stores the value in `AUX2` into a virtual register.
    pub fn store2(self: *Encoder, r: core.Register) error{OutOfMemory}!void {
        self.mov(.ptr_offset(abi.VREG, @intCast(r.getOffset())), .register(abi.AUX2)) catch {
            return error.OutOfMemory;
        };
    }

    /// Stores the value in `AUX3` into a virtual register.
    pub fn store3(self: *Encoder, r: core.Register) error{OutOfMemory}!void {
        self.mov(.ptr_offset(abi.VREG, @intCast(r.getOffset())), .register(abi.AUX3)) catch {
            return error.OutOfMemory;
        };
    }

    /// Stores the value in `AUX4` into a virtual register.
    pub fn store4(self: *Encoder, r: core.Register) error{OutOfMemory}!void {
        self.mov(.ptr_offset(abi.VREG, @intCast(r.getOffset())), .register(abi.AUX4)) catch {
            return error.OutOfMemory;
        };
    }

    /// Stores the value in `AUX5` into a virtual register.
    pub fn store5(self: *Encoder, r: core.Register) error{OutOfMemory}!void {
        self.mov(.ptr_offset(abi.VREG, @intCast(r.getOffset())), .register(abi.AUX5)) catch {
            return error.OutOfMemory;
        };
    }

    /// Stores the value in `AUX6` into a virtual register.
    pub fn store6(self: *Encoder, r: core.Register) error{OutOfMemory}!void {
        self.mov(.ptr_offset(abi.VREG, @intCast(r.getOffset())), .register(abi.AUX6)) catch {
            return error.OutOfMemory;
        };
    }

    /// Stores the value in `TER_A` into a virtual register.
    pub fn storeA(self: *Encoder, r: core.Register) error{OutOfMemory}!void {
        self.mov(.ptr_offset(abi.VREG, @intCast(r.getOffset())), .register(abi.TER_A)) catch {
            return error.OutOfMemory;
        };
    }

    /// Stores the value in `TER_B` into a virtual register.
    pub fn storeB(self: *Encoder, r: core.Register) error{OutOfMemory}!void {
        self.mov(.ptr_offset(abi.VREG, @intCast(r.getOffset())), .register(abi.TER_B)) catch {
            return error.OutOfMemory;
        };
    }

    /// Saves the value in `ACC` into `AUX1`.
    pub fn save1(self: *Encoder) error{OutOfMemory}!void {
        self.mov(.register(abi.AUX1), .register(abi.ACC)) catch {
            return error.OutOfMemory;
        };
    }

    /// Restores the value in `AUX1` into `ACC`.
    pub fn restore1(self: *Encoder) error{OutOfMemory}!void {
        self.mov(.register(abi.ACC), .register(abi.AUX1)) catch {
            return error.OutOfMemory;
        };
    }

    /// Saves the value in `ACC` into `AUX2`.
    pub fn save2(self: *Encoder) error{OutOfMemory}!void {
        self.mov(.register(abi.AUX2), .register(abi.ACC)) catch {
            return error.OutOfMemory;
        };
    }

    /// Restores the value in `AUX2` into `ACC`.
    pub fn restore2(self: *Encoder) error{OutOfMemory}!void {
        self.mov(.register(abi.ACC), .register(abi.AUX2)) catch {
            return error.OutOfMemory;
        };
    }

    /// Saves the value in `ACC` into `AUX3`.
    pub fn save3(self: *Encoder) error{OutOfMemory}!void {
        self.mov(.register(abi.AUX3), .register(abi.ACC)) catch {
            return error.OutOfMemory;
        };
    }

    /// Restores the value in `AUX3` into `ACC`.
    pub fn restore3(self: *Encoder) error{OutOfMemory}!void {
        self.mov(.register(abi.ACC), .register(abi.AUX3)) catch {
            return error.OutOfMemory;
        };
    }

    /// Saves the value in `ACC` into `AUX4`.
    pub fn save4(self: *Encoder) error{OutOfMemory}!void {
        self.mov(.register(abi.AUX4), .register(abi.ACC)) catch {
            return error.OutOfMemory;
        };
    }

    /// Restores the value in `AUX4` into `ACC`.
    pub fn restore4(self: *Encoder) error{OutOfMemory}!void {
        self.mov(.register(abi.ACC), .register(abi.AUX4)) catch {
            return error.OutOfMemory;
        };
    }

    /// Saves the value in `ACC` into `AUX5`.
    pub fn save5(self: *Encoder) error{OutOfMemory}!void {
        self.mov(.register(abi.AUX5), .register(abi.ACC)) catch {
            return error.OutOfMemory;
        };
    }

    /// Restores the value in `AUX5` into `ACC`.
    pub fn restore5(self: *Encoder) error{OutOfMemory}!void {
        self.mov(.register(abi.ACC), .register(abi.AUX5)) catch {
            return error.OutOfMemory;
        };
    }

    /// Saves the value in `ACC` into `AUX6`.
    pub fn save6(self: *Encoder) error{OutOfMemory}!void {
        self.mov(.register(abi.AUX6), .register(abi.ACC)) catch {
            return error.OutOfMemory;
        };
    }

    /// Restores the value in `AUX6` into `ACC`.
    pub fn restore6(self: *Encoder) error{OutOfMemory}!void {
        self.mov(.register(abi.ACC), .register(abi.AUX6)) catch {
            return error.OutOfMemory;
        };
    }

    /// Saves the value in `ACC` into `TER_A`.
    pub fn saveA(self: *Encoder) error{OutOfMemory}!void {
        self.mov(.register(abi.TER_A), .register(abi.ACC)) catch {
            return error.OutOfMemory;
        };
    }

    /// Restores the value in `TER_A` into `ACC`.
    pub fn restoreA(self: *Encoder) error{OutOfMemory}!void {
        self.mov(.register(abi.ACC), .register(abi.TER_A)) catch {
            return error.OutOfMemory;
        };
    }

    /// Saves the value in `ACC` into `TER_B`.
    pub fn saveB(self: *Encoder) error{OutOfMemory}!void {
        self.mov(.register(abi.TER_B), .register(abi.ACC)) catch {
            return error.OutOfMemory;
        };
    }

    /// Restores the value in `TER_B` into `ACC`.
    pub fn restoreB(self: *Encoder) error{OutOfMemory}!void {
        self.mov(.register(abi.ACC), .register(abi.TER_B)) catch {
            return error.OutOfMemory;
        };
    }

    /// Encodes a `ret` instruction.
    pub fn ret(self: *Encoder) error{OutOfMemory}!void {
        self.instr(.ret, &.{}) catch {
            return error.OutOfMemory;
        };
    }

    /// Encodes a `mov` instruction.
    pub fn mov(self: *Encoder, destination: assembler.Operand, source: assembler.Operand) Encoder.Error!void {
        try self.instr(.mov, &.{ destination, source });
    }

    /// Encodes an `add` instruction.
    pub fn i_add(self: *Encoder, a: assembler.Operand, b: assembler.Operand) Encoder.Error!void {
        try self.instr(.add, &.{ a, b });
    }

    /// Encodes a `sub` instruction.
    pub fn i_sub(self: *Encoder, a: assembler.Operand, b: assembler.Operand) Encoder.Error!void {
        try self.instr(.sub, &.{ a, b });
    }
};

test "x64_machine_basic_integration" {
    const expected_disas =
        "\n  ╿ \n" ++ // trailing whitespace gets trimmed causing test failure
        \\  │  x64-intel-syntax
        \\╾─┼──────────────────────────────────╼
        \\  │
        \\  │  mov rbx, rdi
        \\  │  mov r12, qword ptr [rbx]
        \\  │  mov r13, qword ptr [rbx + 0x30]
        \\  │  mov rax, qword ptr [r12 + 0x8]
        \\  │  add rax, qword ptr [r12]
        \\  │  mov qword ptr [r12 + 0x10], rax
        \\  │  mov rax, qword ptr [r12 + 0x10]
        \\  │  mov qword ptr [r12], rax
        \\  │  mov rax, 0x0
        \\  │  ret
        \\  ╽
        \\
        ;

    const allocator = std.testing.allocator;

    const fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    var jit = try machine.Builder.init();
    defer jit.deinit();

    try jit.i_add64(.r(2), .r(0), .r(1));
    try jit.@"return"(.r(2));

    const exe = try jit.finalize();
    defer exe.deinit();

    var buf = std.io.Writer.Allocating.init(allocator);
    defer buf.deinit();

    try machine.disas(exe.toSlice(), .{ .display = .{ .function_address = false } }, &buf.writer);

    try std.testing.expectEqualStrings(expected_disas, buf.written()); // FIXME: this is not the expected output
}
