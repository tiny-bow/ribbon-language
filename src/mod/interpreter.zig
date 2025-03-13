//! Provides interfaces for running code on a `core.Fiber`.
const interpreter = @This();

const core = @import("core");
const pl = @import("platform");
const std = @import("std");

extern fn rvm_interpreter_eval(*const core.mem.FiberHeader) callconv(.c) core.BuiltinSignal;
extern fn rvm_interpreter_step(*const core.mem.FiberHeader) callconv(.c) core.BuiltinSignal;


pub fn invokeBuiltin(self: *core.Fiber, fun: anytype, arguments: []const usize) core.Error!usize {
    const T = @TypeOf(fun);
    // Because the allocated builtin is a packed structure with the pointer at the start, we can just truncate it.
    // To handle both cases, we cast to the bitsize of the input first and then truncate to the output.
    return self.invokeStaticBuiltin(@ptrFromInt(@as(usize, @truncate(@as(std.meta(.unsigned, @bitSizeOf(T)), @bitCast(fun))))), arguments);
}

/// Invokes a `core.AllocatedBuiltinFunction` on the provided fiber, returning the result.
pub fn invokeAllocatedBuiltin(self: core.Fiber, fun: core.AllocatedBuiltinFunction, arguments: []const usize) core.Error!usize {
    return self.invokeStaticBuiltin(@ptrCast(fun.ptr), arguments);
}

/// Invokes a `core.BuiltinFunction` on the provided fiber, returning the result.
pub fn invokeStaticBuiltin(self: core.Fiber, fun: *const core.BuiltinFunction, arguments: []const usize) core.Error!usize {
    if (!self.header.calls.hasSpace(1)) {
        return error.Overflow;
    }

    self.header.calls.push(core.CallFrame{
        .function = @ptrCast(fun),
        .set = self.header.sets.top_ptr,
        .evidence = null,
        .data = self.header.data.top_ptr,
        .ip = undefined,
    });

    const newRegisters = self.header.registers.allocPtr();
    @memcpy(newRegisters[0..arguments.len], arguments);

    return switch (fun(self.header)) {
        .halt => @panic("unexpected halt signal from builtin function"),

        .request_trap => error.FunctionTrapped,
        .@"return" => {
            self.header.calls.pop();

            return self.header.registers.popPtr()[comptime core.Register.native_ret.getIndex()];
        },
        .bad_encoding => error.BadEncoding,
        .panic => @panic("An unexpected error occurred in native code; exiting"),
        .overflow => error.Overflow,
        .underflow => error.Underflow,
    };
}

/// Invokes a `core.Function` on the provided fiber, returning the result.
pub fn invokeBytecode(self: core.Fiber, fun: *const core.Function, arguments: []const usize) core.Error!usize {
    const HALT: usize = undefined; // FIXME

    if (!self.header.calls.hasSpace(2)) {
        return error.Overflow;
    }

    self.header.calls.pushSlice(&.{
        core.CallFrame {
            .function = undefined,
            .set = self.header.sets.top_ptr,
            .evidence = null,
            .data = self.header.data.top_ptr,
            .ip = @ptrCast(&HALT),
        },
        core.CallFrame {
            .function = @ptrCast(fun),
            .set = self.header.sets.top_ptr,
            .evidence = null,
            .data = self.header.data.top_ptr,
            .ip = fun.extents.base,
        },
    });

    const newRegisters = self.header.registers.allocSlice(2);
    @memcpy(newRegisters[1][0..arguments.len], arguments);

    try self.eval();

    // second frame will have already been popped by the interpreter,
    // so we only pop 1 each here.
    self.header.calls.pop();
    const registers = self.header.registers.popMultiPtr(1);

    // we need to reach into the second register frame
    return registers[1][comptime core.Register.native_ret.getIndex()];
}

/// Run the interpreter loop until `halt`.
pub fn eval(self: core.Fiber) core.Error!void {
    const result = rvm_interpreter_eval(self.header);
    _ = try result.toNative();
}

/// Run the interpreter loop for a single instruction.
pub fn step(self: core.Fiber) core.Error!core.InterpreterSignal {
    const result = rvm_interpreter_step(self.header);
    return result.toNative();
}
