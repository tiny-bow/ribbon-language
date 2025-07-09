//! Provides interfaces for running code on a `core.Fiber`.
const interpreter = @This();

const std = @import("std");
const log = std.log.scoped(.interpreter);

const core = @import("core");
const Instruction = @import("Instruction");
const pl = @import("platform");
const common = @import("common");

test {
    std.testing.refAllDecls(@This());
}

/// Invokes either a `core.BuiltinFunction` or `core.BuiltinAddress` on the provided fiber, returning the result.
pub fn invokeBuiltin(self: core.Fiber, evidence: ?*core.Evidence, fun: anytype, arguments: []const core.RegisterBits) core.Error!BuiltinResult {
    const T = @TypeOf(fun);
    // Because the allocated builtin is a packed structure with the pointer at the start, we can just truncate it.
    // To handle both cases, we cast to the bitsize of the input first and then truncate to the output.
    return invokeStaticBuiltin(self, evidence, @ptrFromInt(@as(u64, @truncate(@as(std.meta.Int(.unsigned, @bitSizeOf(T)), @bitCast(fun))))), arguments);
}

/// Invokes a `core.AllocatedBuiltinFunction` on the provided fiber, returning the result.
pub fn invokeAllocatedBuiltin(self: core.Fiber, evidence: ?*core.Evidence, fun: core.AllocatedBuiltinFunction, arguments: []const core.RegisterBits) core.Error!BuiltinResult {
    return invokeStaticBuiltin(self, evidence, @ptrCast(fun.ptr), arguments);
}

/// Result of `invokeBuiltin` depends on the kind of control flow yield being performed by a builtin function;
/// this tagged union discriminates between the two.
pub const BuiltinResult = union(enum) {
    /// Nominal return value.
    /// May or may not be initialized depending on function signature.
    @"return": core.RegisterBits,
    /// Effect handler cancellation.
    cancel: struct {
        /// Cancellation value.
        /// May or may not be initialized depending on function signature.
        value: core.RegisterBits,
        /// The effect handler set frame that was cancelled.
        set_frame: *const core.SetFrame,
    },
};

/// Invokes a `core.BuiltinFunction` on the provided fiber, returning the result.
pub fn invokeStaticBuiltin(self: core.Fiber, evidence: ?*core.Evidence, fun: *const core.BuiltinFunction, arguments: []const core.RegisterBits) core.Error!BuiltinResult {
    if (!self.header.calls.hasSpace(1)) {
        return error.Overflow;
    }

    self.header.calls.push(core.CallFrame{
        .function = @ptrCast(fun),
        .evidence = evidence,
        .data = self.header.data.top_ptr,
        .set_frame = self.header.sets.top(),
        .vregs = self.header.registers.allocPtr(),
        .ip = undefined,
        .output = .scratch,
    });

    const newRegisters = self.header.registers.allocPtr();
    @memcpy(newRegisters[0..arguments.len], arguments);

    return switch (fun(self.header)) {
        .cancel => {
            self.header.calls.pop();

            const oldRegisters = self.header.registers.popPtr();

            return .{ .cancel = .{
                .value = oldRegisters[comptime core.Register.native_ret.getIndex()],
                .set_frame = @ptrFromInt(oldRegisters[comptime core.Register.native_cancelled_frame.getIndex()]),
            } };
        },
        .@"return" => {
            self.header.calls.pop();

            return .{
                .@"return" = self.header.registers.popPtr()[comptime core.Register.native_ret.getIndex()],
            };
        },

        .panic => @panic("An unexpected error occurred in native code; exiting"),

        .request_trap => error.FunctionTrapped,
        .overflow => error.Overflow,
        .underflow => error.Underflow,
    };
}
// In src/mod/interpreter.zig

fn getOrInitWrapper() *const core.Function {
    const static = struct {
        // The function struct and initialization state.
        threadlocal var buffer = [1]core.InstructionBits{0x0002}; // halt instruction
        threadlocal var function: core.Function = undefined;
        threadlocal var init = false;
    };

    if (static.init) return &static.function;

    const buffer: [*]core.InstructionBits = @ptrCast(&static.buffer);

    static.function = core.Function{
        .header = core.EMPTY_HEADER,
        .extents = .{
            .base = buffer,
            .upper = buffer + 1,
        },
        .stack_size = 0,
    };

    static.init = true;

    return &static.function;
}

/// Invokes a `core.Function` on the provided fiber, returning the result.
pub fn invokeBytecode(self: core.Fiber, fun: *const core.Function, arguments: []const u64) core.Error!u64 {
    if (!self.header.calls.hasSpace(2)) {
        return error.Overflow;
    }

    const newRegisters = self.header.registers.allocSlice(2);
    @memcpy(newRegisters[1][0..arguments.len], arguments);

    log.debug("invoking bytecode function {x} with extents {x} to {x}", .{
        @intFromPtr(fun),
        @intFromPtr(fun.extents.base),
        @intFromPtr(fun.extents.upper),
    });

    const wrapper = getOrInitWrapper();

    self.header.calls.push(core.CallFrame{
        .function = wrapper,
        .evidence = null,
        .data = self.header.data.top_ptr,
        .set_frame = self.header.sets.top(),
        .vregs = &newRegisters[0],
        .ip = wrapper.extents.base,
        .output = .scratch,
    });

    self.header.calls.push(core.CallFrame{
        .function = @ptrCast(fun),
        .evidence = null,
        .data = self.header.data.top_ptr,
        .set_frame = self.header.sets.top(),
        .vregs = &newRegisters[1],
        .ip = fun.extents.base,
        .output = .native_ret,
    });

    try eval(self, .skip_breakpoints);

    // second frame will have already been popped by the interpreter
    self.header.calls.pop();

    const registers = self.header.registers.popPtr();

    return registers[comptime core.Register.native_ret.getIndex()];
}

/// Passed to `eval`, indicates how to handle breakpoints in the interpreter loop.
pub const BreakpointMode = enum(u1) {
    /// Skip breakpoints and continue until halt.
    skip_breakpoints,
    /// Stop at breakpoints, and return to the caller.
    breakpoints_halt,
};

/// Signals that can be returned by the `eval` function in `breakpoints_halt` mode
pub const EvalSignal = enum(i64) {
    /// Halt instruction reached.
    halt = -1,
    /// Breakpoint hit, execution paused.
    breakpoint = -2,
};

/// Run the interpreter loop until `halt`; and optionally stop at breakpoints.
pub fn eval(self: core.Fiber, comptime mode: BreakpointMode) core.Error!if (mode == .breakpoints_halt) EvalSignal else void {
    while (true) {
        run(true, self.header) catch |signalOrError| {
            if (comptime mode == .breakpoints_halt) {
                switch (signalOrError) {
                    LoopSignalErr.breakpoint => return .breakpoint,
                    else => |e| return e,
                }
            } else {
                switch (signalOrError) {
                    LoopSignalErr.breakpoint => continue,
                    else => |e| return e,
                }
            }
        };

        return if (comptime mode == .breakpoints_halt) .halt else {};
    }
}

/// Signals that can be returned by the `step` function
pub const StepSignal = enum(i64) {
    /// Nominal function return.
    @"return" = 0,
    /// Effect handler set context cancellation.
    cancel = 1,
    /// Halt instruction reached.
    halt = -1,
    /// Breakpoint hit, execution paused.
    breakpoint = -2,
};

/// Run the interpreter loop for a single instruction.
pub fn step(self: core.Fiber) core.Error!?StepSignal {
    run(false, self.header) catch |signalOrError| {
        switch (signalOrError) {
            StepSignalErr.@"return" => return .@"return",
            StepSignalErr.cancel => return .cancel,
            StepSignalErr.breakpoint => return .breakpoint,
            StepSignalErr.step => return null,
            inline else => |e| return e,
        }
    };

    return .halt;
}

const StepSignalErr = error{
    step,
    breakpoint,
    @"return",
    cancel,
};

const LoopSignalErr = error{
    breakpoint,
};

fn SignalSubset(comptime isLoop: bool) type {
    return if (isLoop) LoopSignalErr else StepSignalErr;
}

fn invokeForeign(self: *core.mem.FiberHeader, current: anytype, registerId: core.Register, functionOpaquePtr: *const anyopaque, argumentRegisterIds: []const core.Register) !void {
    _ = self;

    if (argumentRegisterIds.len > pl.MAX_FOREIGN_ARGUMENTS) {
        @branchHint(.cold);
        return error.Overflow;
    }

    const arguments = current.tempRegisters[0..argumentRegisterIds.len];
    for (argumentRegisterIds, 0..) |reg, i| {
        arguments[i] = current.callFrame.vregs[reg.getIndex()];
    }

    const retVal = pl.callForeign(functionOpaquePtr, arguments);

    current.callFrame.vregs[registerId.getIndex()] = retVal;
}

fn invokeInternal(self: *core.mem.FiberHeader, current: anytype, registerId: core.Register, functionOpaquePtr: *const anyopaque, argumentRegisterIds: []const core.Register) !void {
    switch (core.InternalFunctionKind.fromAddress(functionOpaquePtr)) {
        .bytecode => {
            const functionPtr: *const core.Function = @ptrCast(@alignCast(functionOpaquePtr));

            if (@intFromBool(self.calls.hasSpace(1)) & @intFromBool(self.data.hasSpace(functionPtr.stack_size)) == 0) {
                @branchHint(.cold);
                return error.Overflow;
            }

            const data = self.data.allocSlice(functionPtr.stack_size);

            const newRegisters = self.registers.allocPtr();

            self.calls.push(core.CallFrame{
                .function = functionOpaquePtr,
                .evidence = null,
                .set_frame = self.sets.top(),
                .data = data.ptr,
                .vregs = newRegisters,
                .ip = current.function.extents.base,
                .output = registerId,
            });

            for (argumentRegisterIds, 0..) |reg, i| {
                newRegisters[i] = current.callFrame.vregs[reg.getIndex()];
            }
        },
        .builtin => {
            const functionPtr: *const core.BuiltinFunction = @as(*const core.BuiltinAddress, @ptrCast(@alignCast(functionOpaquePtr))).asFunction();

            const arguments = current.tempRegisters[0..argumentRegisterIds.len];
            for (argumentRegisterIds, 0..) |reg, i| {
                arguments[i] = current.callFrame.vregs[reg.getIndex()];
            }

            const result = try invokeStaticBuiltin(.{ .header = self }, null, functionPtr, arguments);
            switch (result) {
                .cancel => |cancelInfo| {
                    const cancelledSet = cancelInfo.set_frame;

                    cancelledSet.call.ip = cancelledSet.handler_set.cancellation.address;
                    cancelledSet.call.vregs[cancelledSet.handler_set.cancellation.register.getIndex()] = cancelInfo.value;

                    self.calls.top_ptr = @ptrCast(cancelledSet.call);
                    self.registers.top_ptr = @ptrCast(cancelledSet.call.vregs);

                    while (@intFromPtr(self.sets.top()) >= @intFromPtr(cancelledSet.handler_set)) {
                        const setFrame = self.sets.popPtr();
                        for (setFrame.handler_set.effects.asSlice()) |effectId| {
                            const effectIndex = current.function.header.get(effectId).toIndex();
                            const evidencePointerSlot = &self.evidence[effectIndex];

                            self.data.top_ptr = pl.offsetPointer(setFrame.call.data, setFrame.handler_set.evidence);

                            evidencePointerSlot.* = evidencePointerSlot.*.?.previous;
                        }
                    }
                },
                .@"return" => |retVal| current.callFrame.vregs[registerId.getIndex()] = retVal,
            }
        },
    }
}

fn run(comptime isLoop: bool, self: *core.mem.FiberHeader) (core.Error || SignalSubset(isLoop))!void {
    log.debug("begin {s}", .{if (isLoop) "loop" else "step"});

    const State = struct {
        callFrame: *core.CallFrame,
        function: *const core.Function,
        stackFrame: []const core.RegisterBits,
        instruction: Instruction,
        tempRegisters: core.RegisterArray,

        fn decode(st: *@This(), header: *core.mem.FiberHeader) Instruction.OpCode {
            st.callFrame = header.calls.top();
            std.debug.assert(@intFromPtr(st.callFrame) >= @intFromPtr(header.calls.base));

            log.debug("active function for decode is at {x}", .{@intFromPtr(st.callFrame.function)});
            st.function = @ptrCast(@alignCast(st.callFrame.function));

            std.debug.assert(st.function.extents.boundsCheck(st.callFrame.ip));

            st.instruction = Instruction.fromBits(st.callFrame.ip[0]);

            st.callFrame.ip += 1;

            st.stackFrame = st.callFrame.data[0..st.function.stack_size];

            return st.instruction.code;
        }

        fn advance(st: *@This(), header: *core.mem.FiberHeader, comptime signal: StepSignalErr) SignalSubset(isLoop)!Instruction.OpCode {
            if (comptime isLoop) {
                return st.decode(header);
            } else {
                return @errorCast(signal);
            }
        }

        fn step(st: *@This(), header: *core.mem.FiberHeader) SignalSubset(isLoop)!Instruction.OpCode {
            return if (comptime isLoop) st.decode(header) else @errorFromInt(@intFromError(error.step));
        }
    };

    var state: State = undefined;
    const current = &state;

    dispatch: switch (current.decode(self)) {
        // No operation; does nothing
        .nop => continue :dispatch try state.step(self),
        // Triggers a breakpoint in debuggers; does nothing otherwise
        .breakpoint => return StepSignalErr.breakpoint,
        // Halts execution at this instruction offset
        .halt => return,
        // Traps execution of the Rvm.Fiber at this instruction offset Unlike unreachable, this indicates expected behavior; optimizing compilers should not assume it is never reached
        .trap => return error.Unreachable,
        // Marks a point in the code as unreachable; if executed in Rvm, it is the same as trap Unlike trap, however, this indicates undefined behavior; optimizing compilers should assume it is never reached
        .@"unreachable" => return error.Unreachable,

        .push_set => { // Pushes H onto the stack. The handlers in this set will be first in line for their effects' prompts until a corresponding pop operation
            if (!self.sets.hasSpace(1)) {
                @branchHint(.cold);
                return error.Overflow;
            }

            const handlerSetId = current.instruction.data.push_set.H;

            const handlerSet: *const core.HandlerSet = current.function.header.get(handlerSetId);

            const setFrame = self.sets.create(core.SetFrame{
                .call = current.callFrame,
                .handler_set = handlerSet,
            });

            current.callFrame.set_frame = setFrame;

            for (handlerSet.effects.asSlice()) |effectId| {
                const effectIndex = current.function.header.get(effectId).toIndex();

                const evidencePointerSlot = &self.evidence[effectIndex];

                const oldEvidence = evidencePointerSlot.*;
                evidencePointerSlot.* = oldEvidence.?.previous;
            }

            continue :dispatch try state.step(self);
        },
        .pop_set => { // Pops the top most Id.of(HandlerSet) from the stack, restoring the previous if present
            if (@intFromBool(self.sets.count() == 0) | @intFromBool(self.sets.top().call != current.callFrame) != 0) {
                @branchHint(.cold);
                return error.Underflow;
            }

            const setFrame = self.sets.popPtr();
            current.callFrame.set_frame = self.sets.top();

            for (setFrame.handler_set.effects.asSlice()) |effectId| {
                const effectIndex = current.function.header.get(effectId).toIndex();
                const evidencePointerSlot = &self.evidence[effectIndex];

                evidencePointerSlot.* = evidencePointerSlot.*.?.previous;
            }

            continue :dispatch try state.step(self);
        },

        .br => { // Applies a signed integer offset I to the instruction pointer
            const offset: core.InstructionOffset = @bitCast(current.instruction.data.br.I);
            std.debug.assert(offset != 0);

            const newIp: core.InstructionAddr = pl.offsetPointer(current.callFrame.ip, offset);
            std.debug.assert(pl.alignDelta(newIp, @alignOf(core.InstructionBits)) == 0);
            std.debug.assert(current.function.extents.boundsCheck(newIp));

            current.callFrame.ip = newIp;

            continue :dispatch try state.step(self);
        },
        .br_if => { // Applies a signed integer offset I to the instruction pointer, if the value stored in R is non-zero
            const offset: core.InstructionOffset = @bitCast(current.instruction.data.br.I);
            std.debug.assert(offset != 0);

            const registerId = current.instruction.data.br_if.R;

            const newIp: core.InstructionAddr = pl.offsetPointer(current.callFrame.ip, offset);
            std.debug.assert(pl.alignDelta(newIp, @alignOf(core.InstructionBits)) == 0);
            std.debug.assert(current.function.extents.boundsCheck(newIp));

            const register = &current.callFrame.vregs[registerId.getIndex()];

            if (register.* != 0) current.callFrame.ip = newIp;

            continue :dispatch try state.step(self);
        },

        .call => { // Calls the internal function in Ry using A, placing the result in Rx
            const registerIdX = current.instruction.data.call.Rx;
            const registerIdY = current.instruction.data.call.Ry;
            const argumentCount = current.instruction.data.call.I;

            const argsBase: [*]const core.Register = @ptrCast(@alignCast(current.callFrame.ip));
            const argumentRegisterIds = argsBase[0..argumentCount];

            const functionOpaquePtr: *const anyopaque = @ptrFromInt(current.callFrame.vregs[registerIdY.getIndex()]);

            const newIp: core.InstructionAddr = pl.alignTo(
                pl.offsetPointer(current.callFrame.ip, argumentCount * @sizeOf(core.Register)),
                @alignOf(core.InstructionBits),
            );
            std.debug.assert(current.function.extents.boundsCheck(newIp));
            current.callFrame.ip = newIp;

            try invokeInternal(self, current, registerIdX, functionOpaquePtr, argumentRegisterIds);

            continue :dispatch try state.step(self);
        },
        .call_c => { // Calls  internal function at F using A, placing the result in R
            const registerId = current.instruction.data.call_c.R;
            const functionId = current.instruction.data.call_c.F;
            const argumentCount = current.instruction.data.call_c.I;

            const argsBase: [*]const core.Register = @ptrCast(@alignCast(current.callFrame.ip));
            const argumentRegisterIds = argsBase[0..argumentCount];

            const functionOpaquePtr = current.function.header.get(functionId.cast(anyopaque));

            const newIp: core.InstructionAddr = pl.alignTo(
                pl.offsetPointer(current.callFrame.ip, argumentCount * @sizeOf(core.Register)),
                @alignOf(core.InstructionBits),
            );
            std.debug.assert(current.function.extents.boundsCheck(newIp));
            current.callFrame.ip = newIp;

            try invokeInternal(self, current, registerId, functionOpaquePtr, argumentRegisterIds);

            continue :dispatch try state.step(self);
        },

        .f_call => { // Calls the c abi function in Ry using A, placing the result in Rx
            const registerIdX = current.instruction.data.call.Rx;
            const registerIdY = current.instruction.data.call.Ry;
            const argumentCount = current.instruction.data.call.I;

            const argsBase: [*]const core.Register = @ptrCast(@alignCast(current.callFrame.ip));
            const argumentRegisterIds = argsBase[0..argumentCount];

            const functionOpaquePtr: *const anyopaque = @ptrFromInt(current.callFrame.vregs[registerIdY.getIndex()]);

            const newIp: core.InstructionAddr = pl.alignTo(
                pl.offsetPointer(current.callFrame.ip, argumentCount * @sizeOf(core.Register)),
                @alignOf(core.InstructionBits),
            );
            std.debug.assert(current.function.extents.boundsCheck(newIp));
            current.callFrame.ip = newIp;

            try invokeForeign(self, current, registerIdX, functionOpaquePtr, argumentRegisterIds);

            continue :dispatch try state.step(self);
        },
        .f_call_c => { // Calls the c abi function at F using A, placing the result in R
            const registerId = current.instruction.data.call_c.R;
            const functionId = current.instruction.data.call_c.F;
            const argumentCount = current.instruction.data.call_c.I;

            const argsBase: [*]const core.Register = @ptrCast(@alignCast(current.callFrame.ip));
            const argumentRegisterIds = argsBase[0..argumentCount];

            const functionOpaquePtr = current.function.header.get(functionId.cast(anyopaque));

            const newIp: core.InstructionAddr = pl.alignTo(
                pl.offsetPointer(current.callFrame.ip, argumentCount * @sizeOf(core.Register)),
                @alignOf(core.InstructionBits),
            );
            std.debug.assert(current.function.extents.boundsCheck(newIp));
            current.callFrame.ip = newIp;

            try invokeForeign(self, current, registerId, functionOpaquePtr, argumentRegisterIds);

            continue :dispatch try state.step(self);
        },

        .prompt => { // Calls the effect handler designated by E using A, placing the result in R
            const registerId = current.instruction.data.prompt.R;
            const promptId = current.instruction.data.prompt.E;
            const argumentCount = current.instruction.data.prompt.I;

            const argsBase: [*]const core.Register = @ptrCast(@alignCast(current.callFrame.ip));
            const argumentRegisterIds = argsBase[0..argumentCount];

            const newIp: core.InstructionAddr = pl.alignTo(
                pl.offsetPointer(current.callFrame.ip, argumentCount * @sizeOf(core.Register)),
                @alignOf(core.InstructionBits),
            );
            std.debug.assert(current.function.extents.boundsCheck(newIp));
            current.callFrame.ip = newIp;

            const promptIndex = current.function.header.get(promptId).toIndex();

            const evidencePtr = self.evidence[promptIndex] orelse {
                @branchHint(.cold);
                return error.MissingEvidence;
            };

            const handler = evidencePtr.handler;

            const functionOpaquePtr = handler.function;

            switch (core.InternalFunctionKind.fromAddress(functionOpaquePtr)) {
                .bytecode => {
                    const functionPtr = handler.toPointer(*const core.Function);

                    if (@intFromBool(self.calls.hasSpace(1)) & @intFromBool(self.data.hasSpace(functionPtr.stack_size)) == 0) {
                        @branchHint(.cold);
                        return error.Overflow;
                    }

                    const data = self.data.allocSlice(functionPtr.stack_size);

                    const newRegisters = self.registers.allocPtr();

                    self.calls.push(core.CallFrame{
                        .function = functionPtr,
                        .evidence = evidencePtr,
                        .data = data.ptr,
                        .vregs = newRegisters,
                        .set_frame = self.sets.top(),
                        .ip = functionPtr.extents.base,
                        .output = registerId,
                    });

                    for (argumentRegisterIds, 0..) |reg, i| {
                        newRegisters[i] = current.callFrame.vregs[reg.getIndex()];
                    }
                },
                .builtin => {
                    const functionPtr: *const core.BuiltinFunction = handler.toPointer(*const core.BuiltinAddress).asFunction();

                    const arguments = current.tempRegisters[0..argumentRegisterIds.len];
                    for (argumentRegisterIds, 0..) |reg, i| {
                        arguments[i] = current.callFrame.vregs[reg.getIndex()];
                    }

                    const result = try invokeStaticBuiltin(.{ .header = self }, evidencePtr, functionPtr, arguments);
                    switch (result) {
                        .cancel => |cancelVal| {
                            const cancelledSet = cancelVal.set_frame;

                            cancelledSet.call.ip = cancelledSet.handler_set.cancellation.address;
                            cancelledSet.call.vregs[cancelledSet.handler_set.cancellation.register.getIndex()] = cancelVal.value;

                            self.calls.top_ptr = @ptrCast(cancelledSet.call);
                            self.registers.top_ptr = @ptrCast(cancelledSet.call.vregs);

                            while (@intFromPtr(self.sets.top()) >= @intFromPtr(cancelledSet.handler_set)) {
                                const setFrame = self.sets.popPtr();
                                for (setFrame.handler_set.effects.asSlice()) |effectId| {
                                    const effectIndex = current.function.header.get(effectId).toIndex();
                                    const evidencePointerSlot = &self.evidence[effectIndex];

                                    self.data.top_ptr = pl.offsetPointer(setFrame.call.data, setFrame.handler_set.evidence);

                                    evidencePointerSlot.* = evidencePointerSlot.*.?.previous;
                                }
                            }
                        },
                        .@"return" => |retVal| current.callFrame.vregs[registerId.getIndex()] = retVal,
                    }
                },
            }

            continue :dispatch try state.step(self);
        },

        .@"return" => { // Returns flow control to the caller of current function, yielding R to the caller
            const registerId = current.instruction.data.@"return".R;
            const retVal: u64 = current.callFrame.vregs[registerId.getIndex()];

            self.calls.pop();
            self.registers.pop();
            self.data.top_ptr = current.callFrame.data;

            const newCallFrame = self.calls.top();
            const newRegisters = self.registers.top();
            std.debug.assert(@intFromPtr(newCallFrame) >= @intFromPtr(self.calls.base));

            newRegisters[current.callFrame.output.getIndex()] = retVal;

            continue :dispatch try state.advance(self, StepSignalErr.@"return");
        },
        .cancel => { // Returns flow control to the offset associated with the current effect handler's Id.of(HandlerSet), yielding R as the cancellation value
            const cancelledSetFrame = if (current.callFrame.evidence) |ev| ev.frame else {
                @branchHint(.cold);
                return error.MissingEvidence;
            };

            const registerId = current.instruction.data.cancel.R;
            const cancelVal: u64 = current.callFrame.vregs[registerId.getIndex()];
            const canceledCallFrame: *core.CallFrame = cancelledSetFrame.call;
            const cancellation: core.Cancellation = cancelledSetFrame.handler_set.cancellation;

            self.calls.top_ptr = @ptrCast(canceledCallFrame);
            self.registers.top_ptr = @ptrCast(self.calls.top().vregs);

            const newIp: core.InstructionAddr = cancellation.address;
            std.debug.assert(current.function.extents.boundsCheck(newIp));

            canceledCallFrame.ip = newIp;
            canceledCallFrame.vregs[cancellation.register.getIndex()] = cancelVal;

            while (@intFromPtr(self.sets.top()) >= @intFromPtr(canceledCallFrame.set_frame)) {
                const setFrame = self.sets.popPtr();
                for (setFrame.handler_set.effects.asSlice()) |effectId| {
                    const effectIndex = current.function.header.get(effectId).toIndex();
                    const evidencePointerSlot = &self.evidence[effectIndex];

                    evidencePointerSlot.* = evidencePointerSlot.*.?.previous;
                }
            }

            continue :dispatch try state.advance(self, StepSignalErr.cancel);
        },

        // TODO: bounds check memory access
        .mem_set => { // Each byte, starting from the address in Rx, up to an offset of Rz, is set to the least significant byte of Ry
            const registerIdX = current.instruction.data.mem_set.Rx;
            const registerIdY = current.instruction.data.mem_set.Ry;
            const registerIdZ = current.instruction.data.mem_set.Rz;

            const dest: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerIdX.getIndex()]);
            const src: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const size: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            @memset(dest[0..size], src);

            continue :dispatch try state.step(self);
        },
        .mem_set_a => { // Each byte, starting from the address in Rx, up to an offset of I, is set to Ry
            const registerIdX = current.instruction.data.mem_set_a.Rx;
            const registerIdY = current.instruction.data.mem_set_a.Ry;
            const size: u32 = current.instruction.data.mem_set_a.I;

            const dest: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerIdX.getIndex()]);
            const src: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            @memset(dest[0..size], src);

            continue :dispatch try state.step(self);
        },
        .mem_set_b => { // Each byte, starting from the address in Rx, up to an offset of Ry, is set to I
            const registerIdX = current.instruction.data.mem_set_b.Rx;
            const registerIdY = current.instruction.data.mem_set_b.Ry;
            const src: u8 = current.instruction.data.mem_set_b.I;

            const dest: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerIdX.getIndex()]);
            const size: u64 = current.callFrame.vregs[registerIdY.getIndex()];

            @memset(dest[0..size], src);

            continue :dispatch try state.step(self);
        },

        .mem_copy => { // Each byte, starting from the address in Ry, up to an offset of Rz, is copied to the same offset of the address in Rx
            const registerIdX = current.instruction.data.mem_copy.Rx;
            const registerIdY = current.instruction.data.mem_copy.Ry;
            const registerIdZ = current.instruction.data.mem_copy.Rz;

            const dest: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerIdX.getIndex()]);
            const src: [*]const u8 = @ptrFromInt(current.callFrame.vregs[registerIdY.getIndex()]);
            const size: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            @memcpy(dest[0..size], src[0..size]);

            continue :dispatch try state.step(self);
        },
        .mem_copy_a => { // Each byte, starting from the address in Ry, up to an offset of I, is copied to the same offset from the address in Rx
            const registerIdX = current.instruction.data.mem_copy_a.Rx;
            const registerIdY = current.instruction.data.mem_copy_a.Ry;
            const size: u32 = current.instruction.data.mem_copy_a.I;

            const dest: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerIdX.getIndex()]);
            const src: [*]const u8 = @ptrFromInt(current.callFrame.vregs[registerIdY.getIndex()]);

            @memcpy(dest[0..size], src[0..size]);

            continue :dispatch try state.step(self);
        },
        .mem_copy_b => { // Each byte, starting from the address of C, up to an offset of Ry, is copied to the same offset from the address in Rx
            const registerIdX = current.instruction.data.mem_copy_b.Rx;
            const registerIdY = current.instruction.data.mem_copy_b.Ry;
            const constantId = current.instruction.data.mem_copy_b.C;

            const constant: []const u8 = current.function.header.get(constantId).asSlice();

            const dest: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerIdX.getIndex()]);
            const size: u64 = current.callFrame.vregs[registerIdY.getIndex()];

            std.debug.assert(size <= constant.len);

            @memcpy(dest[0..size], constant[0..size]);

            continue :dispatch try state.step(self);
        },

        .mem_swap => { // Each byte, starting from the addresses in Rx and Ry, up to an offset of Rz, are swapped with each-other
            const registerIdX = current.instruction.data.mem_swap.Rx;
            const registerIdY = current.instruction.data.mem_swap.Ry;
            const registerIdZ = current.instruction.data.mem_swap.Rz;

            const dest: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerIdX.getIndex()]);
            const src: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerIdY.getIndex()]);
            const size: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            pl.swap(dest, src, size);

            continue :dispatch try state.step(self);
        },
        .mem_swap_c => { // Each byte, starting from the addresses in Rx and Ry, up to an offset of I, are swapped with each-other
            const registerIdX = current.instruction.data.mem_swap_c.Rx;
            const registerIdY = current.instruction.data.mem_swap_c.Ry;
            const size: u32 = current.instruction.data.mem_swap_c.I;

            const dest: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerIdX.getIndex()]);
            const src: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerIdY.getIndex()]);

            pl.swap(dest, src, size);

            continue :dispatch try state.step(self);
        },

        .addr_l => { // Get the address of a signed integer frame-relative operand stack offset I, placing it in R.
            const registerId = current.instruction.data.addr_l.R;
            const offset: i32 = @bitCast(current.instruction.data.addr_l.I);

            const addr = pl.offsetPointer(current.stackFrame.ptr, offset);

            std.debug.assert(@intFromPtr(addr) >= @intFromPtr(self.data.base) and @intFromPtr(addr) <= @intFromPtr(self.data.limit));

            current.callFrame.vregs[registerId.getIndex()] = @intFromPtr(addr);

            continue :dispatch try state.step(self);
        },
        .addr_u => { // Get the address of U, placing it in R
            const upvalueId = current.instruction.data.addr_u.U;
            const registerId = current.instruction.data.addr_u.R;

            pl.todo(noreturn, .{ "upvalue binding", upvalueId, registerId });
        },
        .addr_g => { // Get the address of G, placing it in R
            const globalId = current.instruction.data.addr_g.G;
            const registerId = current.instruction.data.addr_g.R;

            const global: *const core.Global = current.function.header.get(globalId);

            current.callFrame.vregs[registerId.getIndex()] = global.ptr;

            continue :dispatch try state.step(self);
        },
        .addr_f => { // Get the address of F, placing it in R
            const functionId = current.instruction.data.addr_f.F;
            const registerId = current.instruction.data.addr_f.R;

            const function: *const core.Function = current.function.header.get(functionId);

            current.callFrame.vregs[registerId.getIndex()] = @intFromPtr(function);

            continue :dispatch try state.step(self);
        },
        .addr_b => { // Get the address of B, placing it in R
            const builtinId = current.instruction.data.addr_b.B;
            const registerId = current.instruction.data.addr_b.R;

            const builtin: *const core.BuiltinAddress = current.function.header.get(builtinId);

            current.callFrame.vregs[registerId.getIndex()] = @intFromPtr(builtin.asPointer());

            continue :dispatch try state.step(self);
        },
        .addr_x => { // Get the address of X, placing it in R
            const foreignId = current.instruction.data.addr_x.X;
            const registerId = current.instruction.data.addr_x.R;

            const foreign: core.ForeignAddress = current.function.header.get(foreignId).*;

            current.callFrame.vregs[registerId.getIndex()] = @intFromPtr(foreign);

            continue :dispatch try state.step(self);
        },
        .addr_c => { // Get the address of C, placing it in R
            const constantId = current.instruction.data.addr_c.C;
            const registerId = current.instruction.data.addr_c.R;

            const constant: *const core.Constant = current.function.header.get(constantId);

            current.callFrame.vregs[registerId.getIndex()] = constant.ptr;

            continue :dispatch try state.step(self);
        },

        .load8 => { // Loads an 8-bit value from memory at the address in Ry offset by I, placing the result in Rx
            const Rx = current.instruction.data.load8.Rx;
            const Ry = current.instruction.data.load8.Ry;
            const offset: i32 = @bitCast(current.instruction.data.load8.I);

            const srcBase: [*]const u8 = @ptrFromInt(current.callFrame.vregs[Ry.getIndex()]);
            const src = pl.offsetPointer(srcBase, offset);

            current.callFrame.vregs[Rx.getIndex()] = src[0];

            continue :dispatch try state.step(self);
        },
        .load16 => { // Loads a 16-bit value from memory at the address in Ry offset by I, placing the result in Rx
            const Rx = current.instruction.data.load16.Rx;
            const Ry = current.instruction.data.load16.Ry;
            const offset: i32 = @bitCast(current.instruction.data.load16.I);

            const srcBase: [*]const u16 = @ptrFromInt(current.callFrame.vregs[Ry.getIndex()]);
            const src = pl.offsetPointer(srcBase, offset);

            current.callFrame.vregs[Rx.getIndex()] = src[0];

            continue :dispatch try state.step(self);
        },
        .load32 => { // Loads a 32-bit value from memory at the address in Ry offset by I, placing the result in Rx
            const Rx = current.instruction.data.load32.Rx;
            const Ry = current.instruction.data.load32.Ry;
            const offset: i32 = @bitCast(current.instruction.data.load32.I);

            const srcBase: [*]const u32 = @ptrFromInt(current.callFrame.vregs[Ry.getIndex()]);
            const src = pl.offsetPointer(srcBase, offset);

            current.callFrame.vregs[Rx.getIndex()] = src[0];

            continue :dispatch try state.step(self);
        },
        .load64 => { // Loads a 64-bit value from memory at the address in Ry offset by I, placing the result in Rx
            const Rx = current.instruction.data.load64.Rx;
            const Ry = current.instruction.data.load64.Ry;
            const offset: i32 = @bitCast(current.instruction.data.load64.I);

            const srcBase: [*]const u64 = @ptrFromInt(current.callFrame.vregs[Ry.getIndex()]);
            const src = pl.offsetPointer(srcBase, offset);

            current.callFrame.vregs[Rx.getIndex()] = src[0];

            continue :dispatch try state.step(self);
        },

        .store8 => { // Stores an 8-bit value from Ry to memory at the address in Rx offset by I
            const Rx = current.instruction.data.store8.Rx;
            const Ry = current.instruction.data.store8.Ry;
            const offset: i32 = @bitCast(current.instruction.data.store8.I);

            const destBase: [*]u8 = @ptrFromInt(current.callFrame.vregs[Rx.getIndex()]);
            const dest = pl.offsetPointer(destBase, offset);

            dest[0] = @truncate(current.callFrame.vregs[Ry.getIndex()]);

            continue :dispatch try state.step(self);
        },
        .store16 => { // Stores a 16-bit value from Ry to memory at the address in Rx offset by I
            const Rx = current.instruction.data.store16.Rx;
            const Ry = current.instruction.data.store16.Ry;
            const offset: i32 = @bitCast(current.instruction.data.store16.I);

            const destBase: [*]u16 = @ptrFromInt(current.callFrame.vregs[Rx.getIndex()]);
            const dest = pl.offsetPointer(destBase, offset);

            dest[0] = @truncate(current.callFrame.vregs[Ry.getIndex()]);

            continue :dispatch try state.step(self);
        },
        .store32 => { // Stores a 32-bit value from Ry to memory at the address in Rx offset by I
            const Rx = current.instruction.data.store32.Rx;
            const Ry = current.instruction.data.store32.Ry;
            const offset: i32 = @bitCast(current.instruction.data.store32.I);

            const destBase: [*]u32 = @ptrFromInt(current.callFrame.vregs[Rx.getIndex()]);
            const dest = pl.offsetPointer(destBase, offset);

            dest[0] = @truncate(current.callFrame.vregs[Ry.getIndex()]);

            continue :dispatch try state.step(self);
        },
        .store64 => { // Stores a 64-bit value from Ry to memory at the address in Rx offset by I
            const Rx = current.instruction.data.store64.Rx;
            const Ry = current.instruction.data.store64.Ry;
            const offset: i32 = @bitCast(current.instruction.data.store64.I);

            const destBase: [*]u64 = @ptrFromInt(current.callFrame.vregs[Rx.getIndex()]);
            const dest = pl.offsetPointer(destBase, offset);

            dest[0] = @truncate(current.callFrame.vregs[Ry.getIndex()]);

            continue :dispatch try state.step(self);
        },
        .store8c => { // Stores an 8-bit value (Ix) to memory at the address in R offset by Iy
            const registerId = current.instruction.data.store8c.R;
            const constant: u8 = current.instruction.data.store8c.Ix;
            const offset: i32 = @bitCast(current.instruction.data.store8c.Iy);

            const destBase: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerId.getIndex()]);
            const dest = pl.offsetPointer(destBase, offset);

            dest[0] = constant;

            continue :dispatch try state.step(self);
        },
        .store16c => { // Stores a 16-bit value (Ix) to memory at the address in R offset by Iy
            const registerId = current.instruction.data.store16c.R;

            const immBits: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            const bits: u16 = @truncate(immBits);
            const offset: i32 = @bitCast(@as(u32, @truncate(immBits >> 16)));

            const destBase: [*]u16 = @ptrFromInt(current.callFrame.vregs[registerId.getIndex()]);
            const dest = pl.offsetPointer(destBase, offset);

            dest[0] = bits;

            continue :dispatch try state.step(self);
        },
        .store32c => { // Stores a 32-bit value (Ix) to memory at the address in R offset by Iy
            const registerId = current.instruction.data.store32c.R;

            const immBits: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            const bits: u32 = @truncate(immBits);
            const offset: i32 = @bitCast(@as(u32, @truncate(immBits >> 32)));

            const destBase: [*]u32 = @ptrFromInt(current.callFrame.vregs[registerId.getIndex()]);
            const dest = pl.offsetPointer(destBase, offset);

            dest[0] = bits;

            continue :dispatch try state.step(self);
        },
        .store64c => { // Stores a 64-bit value (Iy) to memory at the address in R offset by Ix
            const registerId = current.instruction.data.store64c.R;
            const offset: i32 = @bitCast(current.instruction.data.store64c.Ix);

            const bits: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            const destBase: [*]u64 = @ptrFromInt(current.callFrame.vregs[registerId.getIndex()]);
            const dest = pl.offsetPointer(destBase, offset);

            dest[0] = bits;

            continue :dispatch try state.step(self);
        },

        .bit_swap8 => { // 8-bit Rx ⇔ Ry
            const registerIdX = current.instruction.data.bit_swap8.Rx;
            const registerIdY = current.instruction.data.bit_swap8.Ry;

            const a: *u8 = @ptrCast(&current.callFrame.vregs[registerIdX.getIndex()]);
            const b: *u8 = @ptrCast(&current.callFrame.vregs[registerIdY.getIndex()]);

            const tmp = a.*;
            a.* = b.*;
            b.* = tmp;

            continue :dispatch try state.step(self);
        },
        .bit_swap16 => { // 16-bit Rx ⇔ Ry
            const registerIdX = current.instruction.data.bit_swap16.Rx;
            const registerIdY = current.instruction.data.bit_swap16.Ry;

            const a: *u16 = @ptrCast(&current.callFrame.vregs[registerIdX.getIndex()]);
            const b: *u16 = @ptrCast(&current.callFrame.vregs[registerIdY.getIndex()]);

            const tmp = a.*;
            a.* = b.*;
            b.* = tmp;

            continue :dispatch try state.step(self);
        },
        .bit_swap32 => { // 32-bit Rx ⇔ Ry
            const registerIdX = current.instruction.data.bit_swap32.Rx;
            const registerIdY = current.instruction.data.bit_swap32.Ry;

            const a: *u32 = @ptrCast(&current.callFrame.vregs[registerIdX.getIndex()]);
            const b: *u32 = @ptrCast(&current.callFrame.vregs[registerIdY.getIndex()]);

            const tmp = a.*;
            a.* = b.*;
            b.* = tmp;

            continue :dispatch try state.step(self);
        },
        .bit_swap64 => {
            const registerIdX = current.instruction.data.bit_swap64.Rx;
            const registerIdY = current.instruction.data.bit_swap64.Ry;

            const a: *u64 = @ptrCast(&current.callFrame.vregs[registerIdX.getIndex()]);
            const b: *u64 = @ptrCast(&current.callFrame.vregs[registerIdY.getIndex()]);

            const tmp = a.*;
            a.* = b.*;
            b.* = tmp;

            continue :dispatch try state.step(self);
        },

        .bit_copy8 => { // 8-bit Rx = Ry
            const registerIdX = current.instruction.data.bit_copy8.Rx;
            const registerIdY = current.instruction.data.bit_copy8.Ry;

            const dst: *u8 = @ptrCast(&current.callFrame.vregs[registerIdX.getIndex()]);
            const src: *const u8 = @ptrCast(&current.callFrame.vregs[registerIdY.getIndex()]);

            dst.* = src.*;

            continue :dispatch try state.step(self);
        },
        .bit_copy16 => { // 16-bit Rx = Ry
            const registerIdX = current.instruction.data.bit_copy16.Rx;
            const registerIdY = current.instruction.data.bit_copy16.Ry;

            const dst: *u16 = @ptrCast(&current.callFrame.vregs[registerIdX.getIndex()]);
            const src: *const u16 = @ptrCast(&current.callFrame.vregs[registerIdY.getIndex()]);

            dst.* = src.*;

            continue :dispatch try state.step(self);
        },
        .bit_copy32 => { // 32-bit Rx = Ry
            const registerIdX = current.instruction.data.bit_copy32.Rx;
            const registerIdY = current.instruction.data.bit_copy32.Ry;

            const dst: *u32 = @ptrCast(&current.callFrame.vregs[registerIdX.getIndex()]);
            const src: *const u32 = @ptrCast(&current.callFrame.vregs[registerIdY.getIndex()]);

            dst.* = src.*;

            continue :dispatch try state.step(self);
        },
        .bit_copy64 => { // 64-bit Rx = Ry
            const registerIdX = current.instruction.data.bit_copy64.Rx;
            const registerIdY = current.instruction.data.bit_copy64.Ry;

            const dst: *u64 = &current.callFrame.vregs[registerIdX.getIndex()];
            const src: *const u64 = &current.callFrame.vregs[registerIdY.getIndex()];

            dst.* = src.*;
        },
        .bit_copy8c => { // 8-bit R = I
            const registerId = current.instruction.data.bit_copy8c.R;
            const bits: u8 = current.instruction.data.bit_copy8c.I;

            current.callFrame.vregs[registerId.getIndex()] = bits;

            continue :dispatch try state.step(self);
        },
        .bit_copy16c => { // 16-bit R = I
            const registerId = current.instruction.data.bit_copy16c.R;
            const bits: u16 = current.instruction.data.bit_copy16c.I;

            current.callFrame.vregs[registerId.getIndex()] = bits;

            continue :dispatch try state.step(self);
        },
        .bit_copy32c => { // 32-bit R = I
            const registerId = current.instruction.data.bit_copy32c.R;
            const bits: u32 = current.instruction.data.bit_copy32c.I;

            current.callFrame.vregs[registerId.getIndex()] = bits;

            continue :dispatch try state.step(self);
        },
        .bit_copy64c => { // 64-bit R = I
            const registerId = current.instruction.data.bit_copy64c.R;

            const bits: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerId.getIndex()] = bits;

            continue :dispatch try state.step(self);
        },

        .bit_clz8 => { // Counts the leading zeroes in 8-bits of Ry, placing the result in Rx
            const registerIdX = current.instruction.data.bit_clz8.Rx;
            const registerIdY = current.instruction.data.bit_clz8.Ry;

            const bits: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @clz(bits);

            continue :dispatch try state.step(self);
        },
        .bit_clz16 => { // Counts the leading zeroes in 16-bits of Ry, placing the result in Rx
            const registerIdX = current.instruction.data.bit_clz16.Rx;
            const registerIdY = current.instruction.data.bit_clz16.Ry;

            const bits: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @clz(bits);

            continue :dispatch try state.step(self);
        },
        .bit_clz32 => { // Counts the leading zeroes in 32-bits of Ry, placing the result in Rx
            const registerIdX = current.instruction.data.bit_clz32.Rx;
            const registerIdY = current.instruction.data.bit_clz32.Ry;

            const bits: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @clz(bits);

            continue :dispatch try state.step(self);
        },
        .bit_clz64 => { // Counts the leading zeroes in 64-bits of Ry, placing the result in Rx
            const registerIdX = current.instruction.data.bit_clz64.Rx;
            const registerIdY = current.instruction.data.bit_clz64.Ry;

            const bits: u64 = current.callFrame.vregs[registerIdY.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = @clz(bits);

            continue :dispatch try state.step(self);
        },

        .bit_pop8 => { // Counts the set bits in 8-bits of Ry, placing the result in Rx
            const registerIdX = current.instruction.data.bit_pop8.Rx;
            const registerIdY = current.instruction.data.bit_pop8.Ry;

            const bits: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @popCount(bits);

            continue :dispatch try state.step(self);
        },
        .bit_pop16 => { // Counts the set bits in 16-bits of Ry, placing the result in Rx
            const registerIdX = current.instruction.data.bit_pop16.Rx;
            const registerIdY = current.instruction.data.bit_pop16.Ry;

            const bits: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @popCount(bits);

            continue :dispatch try state.step(self);
        },
        .bit_pop32 => { // Counts the set bits in 32-bits of Ry, placing the result in Rx
            const registerIdX = current.instruction.data.bit_pop32.Rx;
            const registerIdY = current.instruction.data.bit_pop32.Ry;

            const bits: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @popCount(bits);

            continue :dispatch try state.step(self);
        },
        .bit_pop64 => { // Counts the set bits in 64-bits of Ry, placing the result in Rx
            const registerIdX = current.instruction.data.bit_pop64.Rx;
            const registerIdY = current.instruction.data.bit_pop64.Ry;

            const bits: u64 = current.callFrame.vregs[registerIdY.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = @popCount(bits);

            continue :dispatch try state.step(self);
        },

        .bit_not8 => { // 8-bit Rx = ~Ry
            const registerIdX = current.instruction.data.bit_not8.Rx;
            const registerIdY = current.instruction.data.bit_not8.Ry;

            const bits: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = ~bits;

            continue :dispatch try state.step(self);
        },
        .bit_not16 => { // 16-bit Rx = ~Ry
            const registerIdX = current.instruction.data.bit_not16.Rx;
            const registerIdY = current.instruction.data.bit_not16.Ry;

            const bits: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = ~bits;

            continue :dispatch try state.step(self);
        },
        .bit_not32 => { // 32-bit Rx = ~Ry
            const registerIdX = current.instruction.data.bit_not32.Rx;
            const registerIdY = current.instruction.data.bit_not32.Ry;

            const bits: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = ~bits;

            continue :dispatch try state.step(self);
        },
        .bit_not64 => { // 64-bit Rx = ~Ry
            const registerIdX = current.instruction.data.bit_not64.Rx;
            const registerIdY = current.instruction.data.bit_not64.Ry;

            const bits: u64 = current.callFrame.vregs[registerIdY.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = ~bits;

            continue :dispatch try state.step(self);
        },

        .bit_and8 => { // 8-bit Rx = Ry & Rz
            const registerIdX = current.instruction.data.bit_and8.Rx;
            const registerIdY = current.instruction.data.bit_and8.Ry;
            const registerIdZ = current.instruction.data.bit_and8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY & bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_and16 => { // 16-bit Rx = Ry & Rz
            const registerIdX = current.instruction.data.bit_and16.Rx;
            const registerIdY = current.instruction.data.bit_and16.Ry;
            const registerIdZ = current.instruction.data.bit_and16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY & bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_and32 => { // 32-bit Rx = Ry & Rz
            const registerIdX = current.instruction.data.bit_and32.Rx;
            const registerIdY = current.instruction.data.bit_and32.Ry;
            const registerIdZ = current.instruction.data.bit_and32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY & bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_and64 => { // 64-bit Rx = Ry & Rz
            const registerIdX = current.instruction.data.bit_and64.Rx;
            const registerIdY = current.instruction.data.bit_and64.Ry;
            const registerIdZ = current.instruction.data.bit_and64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY & bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_and8c => { // 8-bit Rx = Ry & I
            const registerIdX = current.instruction.data.bit_and8c.Rx;
            const registerIdY = current.instruction.data.bit_and8c.Ry;
            const bitsZ: u8 = current.instruction.data.bit_and8c.I;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY & bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_and16c => { // 16-bit Rx = Ry & I
            const registerIdX = current.instruction.data.bit_and16c.Rx;
            const registerIdY = current.instruction.data.bit_and16c.Ry;
            const bitsZ: u16 = current.instruction.data.bit_and16c.I;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY & bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_and32c => { // 32-bit Rx = Ry & I
            const registerIdX = current.instruction.data.bit_and32c.Rx;
            const registerIdY = current.instruction.data.bit_and32c.Ry;
            const bitsZ: u32 = current.instruction.data.bit_and32c.I;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY & bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_and64c => { // 64-bit Rx = Ry & I
            const registerIdX = current.instruction.data.bit_and64c.Rx;
            const registerIdY = current.instruction.data.bit_and64c.Ry;

            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY & bitsZ;

            continue :dispatch try state.step(self);
        },

        .bit_or8 => { // 8-bit Rx = Ry | Rz
            const registerIdX = current.instruction.data.bit_or8.Rx;
            const registerIdY = current.instruction.data.bit_or8.Ry;
            const registerIdZ = current.instruction.data.bit_or8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY | bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_or16 => { // 16-bit Rx = Ry | Rz
            const registerIdX = current.instruction.data.bit_or16.Rx;
            const registerIdY = current.instruction.data.bit_or16.Ry;
            const registerIdZ = current.instruction.data.bit_or16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY | bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_or32 => { // 32-bit Rx = Ry | Rz
            const registerIdX = current.instruction.data.bit_or32.Rx;
            const registerIdY = current.instruction.data.bit_or32.Ry;
            const registerIdZ = current.instruction.data.bit_or32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY | bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_or64 => { // 64-bit Rx = Ry | Rz
            const registerIdX = current.instruction.data.bit_or64.Rx;
            const registerIdY = current.instruction.data.bit_or64.Ry;
            const registerIdZ = current.instruction.data.bit_or64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY | bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_or8c => { // 8-bit Rx = Ry | I
            const registerIdX = current.instruction.data.bit_or8c.Rx;
            const registerIdY = current.instruction.data.bit_or8c.Ry;
            const bitsZ: u8 = current.instruction.data.bit_or8c.I;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY | bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_or16c => { // 16-bit Rx = Ry | I
            const registerIdX = current.instruction.data.bit_or16c.Rx;
            const registerIdY = current.instruction.data.bit_or16c.Ry;
            const bitsZ: u16 = current.instruction.data.bit_or16c.I;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY | bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_or32c => { // 32-bit Rx = Ry | I
            const registerIdX = current.instruction.data.bit_or32c.Rx;
            const registerIdY = current.instruction.data.bit_or32c.Ry;
            const bitsZ: u32 = current.instruction.data.bit_or32c.I;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY | bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_or64c => { // 64-bit Rx = Ry | I
            const registerIdX = current.instruction.data.bit_or64c.Rx;
            const registerIdY = current.instruction.data.bit_or64c.Ry;

            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY | bitsZ;

            continue :dispatch try state.step(self);
        },

        .bit_xor8 => { // 8-bit Rx = Ry ^ Rz
            const registerIdX = current.instruction.data.bit_xor8.Rx;
            const registerIdY = current.instruction.data.bit_xor8.Ry;
            const registerIdZ = current.instruction.data.bit_xor8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY ^ bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_xor16 => { // 16-bit Rx = Ry ^ Rz
            const registerIdX = current.instruction.data.bit_xor16.Rx;
            const registerIdY = current.instruction.data.bit_xor16.Ry;
            const registerIdZ = current.instruction.data.bit_xor16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY ^ bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_xor32 => { // 32-bit Rx = Ry ^ Rz
            const registerIdX = current.instruction.data.bit_xor32.Rx;
            const registerIdY = current.instruction.data.bit_xor32.Ry;
            const registerIdZ = current.instruction.data.bit_xor32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY ^ bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_xor64 => { // 64-bit Rx = Ry ^ Rz
            const registerIdX = current.instruction.data.bit_xor64.Rx;
            const registerIdY = current.instruction.data.bit_xor64.Ry;
            const registerIdZ = current.instruction.data.bit_xor64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY ^ bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_xor8c => { // 8-bit Rx = Ry ^ I
            const registerIdX = current.instruction.data.bit_xor8c.Rx;
            const registerIdY = current.instruction.data.bit_xor8c.Ry;
            const bitsZ: u8 = current.instruction.data.bit_xor8c.I;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY ^ bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_xor16c => { // 16-bit Rx = Ry ^ I
            const registerIdX = current.instruction.data.bit_xor16c.Rx;
            const registerIdY = current.instruction.data.bit_xor16c.Ry;
            const bitsZ: u16 = current.instruction.data.bit_xor16c.I;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY ^ bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_xor32c => { // 32-bit Rx = Ry ^ I
            const registerIdX = current.instruction.data.bit_xor32c.Rx;
            const registerIdY = current.instruction.data.bit_xor32c.Ry;
            const bitsZ: u32 = current.instruction.data.bit_xor32c.I;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY ^ bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_xor64c => { // 64-bit Rx = Ry ^ I
            const registerIdX = current.instruction.data.bit_xor64c.Rx;
            const registerIdY = current.instruction.data.bit_xor64c.Ry;

            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY ^ bitsZ;

            continue :dispatch try state.step(self);
        },

        .bit_lshift8 => { // 8-bit Rx = Ry << Rz
            const registerIdX = current.instruction.data.bit_lshift8.Rx;
            const registerIdY = current.instruction.data.bit_lshift8.Ry;
            const registerIdZ = current.instruction.data.bit_lshift8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u3 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY << bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_lshift16 => { // 16-bit Rx = Ry << Rz
            const registerIdX = current.instruction.data.bit_lshift16.Rx;
            const registerIdY = current.instruction.data.bit_lshift16.Ry;
            const registerIdZ = current.instruction.data.bit_lshift16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u4 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY << bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_lshift32 => { // 32-bit Rx = Ry << Rz
            const registerIdX = current.instruction.data.bit_lshift32.Rx;
            const registerIdY = current.instruction.data.bit_lshift32.Ry;
            const registerIdZ = current.instruction.data.bit_lshift32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u5 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY << bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_lshift64 => { // 64-bit Rx = Ry << Rz
            const registerIdX = current.instruction.data.bit_lshift64.Rx;
            const registerIdY = current.instruction.data.bit_lshift64.Ry;
            const registerIdZ = current.instruction.data.bit_lshift64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u6 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY << bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_lshift8a => { // 8-bit Rx = I << Ry
            const registerIdX = current.instruction.data.bit_lshift8a.Rx;
            const registerIdY = current.instruction.data.bit_lshift8a.Ry;

            const bitsY: u3 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = current.instruction.data.bit_lshift8a.I;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ << bitsY;

            continue :dispatch try state.step(self);
        },
        .bit_lshift16a => { // 16-bit Rx = I << Ry
            const registerIdX = current.instruction.data.bit_lshift16a.Rx;
            const registerIdY = current.instruction.data.bit_lshift16a.Ry;

            const bitsY: u4 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = current.instruction.data.bit_lshift16a.I;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ << bitsY;

            continue :dispatch try state.step(self);
        },
        .bit_lshift32a => { // 32-bit Rx = I << Ry
            const registerIdX = current.instruction.data.bit_lshift32a.Rx;
            const registerIdY = current.instruction.data.bit_lshift32a.Ry;

            const bitsY: u5 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = current.instruction.data.bit_lshift32a.I;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ << bitsY;

            continue :dispatch try state.step(self);
        },
        .bit_lshift64a => { // 64-bit Rx = I << Ry
            const registerIdX = current.instruction.data.bit_lshift64a.Rx;
            const registerIdY = current.instruction.data.bit_lshift64a.Ry;

            const bitsY: u6 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ << bitsY;

            continue :dispatch try state.step(self);
        },
        .bit_lshift8b => { // 8-bit Rx = Ry << I
            const registerIdX = current.instruction.data.bit_lshift8b.Rx;
            const registerIdY = current.instruction.data.bit_lshift8b.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u3 = @truncate(current.instruction.data.bit_lshift8b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY << bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_lshift16b => { // 16-bit Rx = Ry << I
            const registerIdX = current.instruction.data.bit_lshift16b.Rx;
            const registerIdY = current.instruction.data.bit_lshift16b.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u4 = @truncate(current.instruction.data.bit_lshift16b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY << bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_lshift32b => { // 32-bit Rx = Ry << I
            const registerIdX = current.instruction.data.bit_lshift32b.Rx;
            const registerIdY = current.instruction.data.bit_lshift32b.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u5 = @truncate(current.instruction.data.bit_lshift32b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY << bitsZ;

            continue :dispatch try state.step(self);
        },
        .bit_lshift64b => { // 64-bit Rx = Ry << I
            const registerIdX = current.instruction.data.bit_lshift64b.Rx;
            const registerIdY = current.instruction.data.bit_lshift64b.Ry;

            const bitsY: u64 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u6 = @truncate(current.instruction.data.bit_lshift64b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY << bitsZ;

            continue :dispatch try state.step(self);
        },

        .u_rshift8 => { // 8-bit unsigned/logical Rx = Ry >> Rz
            const registerIdX = current.instruction.data.u_rshift8.Rx;
            const registerIdY = current.instruction.data.u_rshift8.Ry;
            const registerIdZ = current.instruction.data.u_rshift8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u3 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY >> bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_rshift16 => { // 16-bit unsigned/logical Rx = Ry >> Rz
            const registerIdX = current.instruction.data.u_rshift16.Rx;
            const registerIdY = current.instruction.data.u_rshift16.Ry;
            const registerIdZ = current.instruction.data.u_rshift16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u4 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY >> bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_rshift32 => { // 32-bit unsigned/logical Rx = Ry >> Rz
            const registerIdX = current.instruction.data.u_rshift32.Rx;
            const registerIdY = current.instruction.data.u_rshift32.Ry;
            const registerIdZ = current.instruction.data.u_rshift32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u5 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY >> bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_rshift64 => { // 64-bit unsigned/logical Rx = Ry >> Rz
            const registerIdX = current.instruction.data.u_rshift64.Rx;
            const registerIdY = current.instruction.data.u_rshift64.Ry;
            const registerIdZ = current.instruction.data.u_rshift64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u6 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY >> bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_rshift8a => { // 8-bit unsigned/logical Rx = I >> Ry
            const registerIdX = current.instruction.data.u_rshift8a.Rx;
            const registerIdY = current.instruction.data.u_rshift8a.Ry;

            const bitsY: u3 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = current.instruction.data.u_rshift8a.I;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ >> bitsY;

            continue :dispatch try state.step(self);
        },
        .u_rshift16a => { // 16-bit unsigned/logical Rx = I >> Ry
            const registerIdX = current.instruction.data.u_rshift16a.Rx;
            const registerIdY = current.instruction.data.u_rshift16a.Ry;

            const bitsY: u4 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = current.instruction.data.u_rshift16a.I;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ >> bitsY;

            continue :dispatch try state.step(self);
        },
        .u_rshift32a => { // 32-bit unsigned/logical Rx = I >> Ry
            const registerIdX = current.instruction.data.u_rshift32a.Rx;
            const registerIdY = current.instruction.data.u_rshift32a.Ry;

            const bitsY: u5 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = current.instruction.data.u_rshift32a.I;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ >> bitsY;

            continue :dispatch try state.step(self);
        },
        .u_rshift64a => { // 64-bit unsigned/logical Rx = I >> Ry
            const registerIdX = current.instruction.data.u_rshift64a.Rx;
            const registerIdY = current.instruction.data.u_rshift64a.Ry;

            const bitsY: u6 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ >> bitsY;

            continue :dispatch try state.step(self);
        },
        .u_rshift8b => { // 8-bit unsigned/logical Rx = Ry >> I
            const registerIdX = current.instruction.data.u_rshift8b.Rx;
            const registerIdY = current.instruction.data.u_rshift8b.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u3 = @truncate(current.instruction.data.u_rshift8b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY >> bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_rshift16b => { // 16-bit unsigned/logical Rx = Ry >> I
            const registerIdX = current.instruction.data.u_rshift16b.Rx;
            const registerIdY = current.instruction.data.u_rshift16b.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u4 = @truncate(current.instruction.data.u_rshift16b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY >> bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_rshift32b => { // 32-bit unsigned/logical Rx = Ry >> I
            const registerIdX = current.instruction.data.u_rshift32b.Rx;
            const registerIdY = current.instruction.data.u_rshift32b.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u5 = @truncate(current.instruction.data.u_rshift32b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY >> bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_rshift64b => { // 64-bit unsigned/logical Rx = Ry >> I
            const registerIdX = current.instruction.data.u_rshift64b.Rx;
            const registerIdY = current.instruction.data.u_rshift64b.Ry;

            const bitsY: u64 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u6 = @truncate(current.instruction.data.u_rshift64b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY >> bitsZ;

            continue :dispatch try state.step(self);
        },

        .s_rshift8 => { // 8-bit signed/arithmetic Rx = Ry >> Rz
            const registerIdX = current.instruction.data.s_rshift8.Rx;
            const registerIdY = current.instruction.data.s_rshift8.Ry;
            const registerIdZ = current.instruction.data.s_rshift8.Rz;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: u3 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u8, @bitCast(bitsY >> bitsZ));

            continue :dispatch try state.step(self);
        },
        .s_rshift16 => { // 16-bit signed/arithmetic Rx = Ry >> Rz
            const registerIdX = current.instruction.data.s_rshift16.Rx;
            const registerIdY = current.instruction.data.s_rshift16.Ry;
            const registerIdZ = current.instruction.data.s_rshift16.Rz;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: u4 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @bitCast(bitsY >> bitsZ));

            continue :dispatch try state.step(self);
        },
        .s_rshift32 => { // 32-bit signed/arithmetic Rx = Ry >> Rz
            const registerIdX = current.instruction.data.s_rshift32.Rx;
            const registerIdY = current.instruction.data.s_rshift32.Ry;
            const registerIdZ = current.instruction.data.s_rshift32.Rz;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: u5 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(bitsY >> bitsZ));

            continue :dispatch try state.step(self);
        },
        .s_rshift64 => { // 64-bit signed/arithmetic Rx = Ry >> Rz
            const registerIdX = current.instruction.data.s_rshift64.Rx;
            const registerIdY = current.instruction.data.s_rshift64.Ry;
            const registerIdZ = current.instruction.data.s_rshift64.Rz;

            const bitsY: i64 = @bitCast(@as(u64, current.callFrame.vregs[registerIdY.getIndex()]));
            const bitsZ: u6 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(bitsY >> bitsZ));

            continue :dispatch try state.step(self);
        },
        .s_rshift8a => { // 8-bit signed/arithmetic Rx = I >> Ry
            const registerIdX = current.instruction.data.s_rshift8a.Rx;
            const registerIdY = current.instruction.data.s_rshift8a.Ry;

            const bitsY: u3 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i8 = @bitCast(@as(u8, current.instruction.data.s_rshift8a.I));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u8, @bitCast(bitsZ >> bitsY));

            continue :dispatch try state.step(self);
        },
        .s_rshift16a => { // 16-bit signed/arithmetic Rx = I >> Ry
            const registerIdX = current.instruction.data.s_rshift16a.Rx;
            const registerIdY = current.instruction.data.s_rshift16a.Ry;

            const bitsY: u4 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i16 = @bitCast(@as(u16, current.instruction.data.s_rshift16a.I));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @bitCast(bitsZ >> bitsY));

            continue :dispatch try state.step(self);
        },
        .s_rshift32a => { // 32-bit signed/arithmetic Rx = I >> Ry
            const registerIdX = current.instruction.data.s_rshift32a.Rx;
            const registerIdY = current.instruction.data.s_rshift32a.Ry;

            const bitsY: u5 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i32 = @bitCast(@as(u32, current.instruction.data.s_rshift32a.I));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(bitsZ >> bitsY));

            continue :dispatch try state.step(self);
        },
        .s_rshift64a => { // 64-bit signed/arithmetic Rx = I >> Ry
            const registerIdX = current.instruction.data.s_rshift64a.Rx;
            const registerIdY = current.instruction.data.s_rshift64a.Ry;

            const bitsY: u6 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(@as(u64, current.callFrame.ip[0]));
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(bitsZ >> bitsY));

            continue :dispatch try state.step(self);
        },
        .s_rshift8b => { // 8-bit signed/arithmetic Rx = Ry >> I
            const registerIdX = current.instruction.data.s_rshift8b.Rx;
            const registerIdY = current.instruction.data.s_rshift8b.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: u3 = @truncate(current.instruction.data.s_rshift8b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u8, @bitCast(bitsY >> bitsZ));

            continue :dispatch try state.step(self);
        },
        .s_rshift16b => { // 16-bit signed/arithmetic Rx = Ry >> I
            const registerIdX = current.instruction.data.s_rshift16b.Rx;
            const registerIdY = current.instruction.data.s_rshift16b.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: u4 = @truncate(current.instruction.data.s_rshift16b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @bitCast(bitsY >> bitsZ));

            continue :dispatch try state.step(self);
        },
        .s_rshift32b => { // 32-bit signed/arithmetic Rx = Ry >> I
            const registerIdX = current.instruction.data.s_rshift32b.Rx;
            const registerIdY = current.instruction.data.s_rshift32b.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: u5 = @truncate(current.instruction.data.s_rshift32b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(bitsY >> bitsZ));

            continue :dispatch try state.step(self);
        },
        .s_rshift64b => { // 64-bit signed/arithmetic Rx = Ry >> I
            const registerIdX = current.instruction.data.s_rshift64b.Rx;
            const registerIdY = current.instruction.data.s_rshift64b.Ry;

            const bitsY: i64 = @bitCast(@as(u64, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: u6 = @truncate(current.instruction.data.s_rshift64b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(bitsY >> bitsZ));

            continue :dispatch try state.step(self);
        },

        .i_eq8 => { // 8-bit sign-agnostic integer Rx = Ry == Rz
            const registerIdX = current.instruction.data.i_eq8.Rx;
            const registerIdY = current.instruction.data.i_eq8.Ry;
            const registerIdZ = current.instruction.data.i_eq8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY == bitsZ);

            continue :dispatch try state.step(self);
        },
        .i_eq16 => { // 16-bit sign-agnostic integer Rx = Ry == Rz
            const registerIdX = current.instruction.data.i_eq16.Rx;
            const registerIdY = current.instruction.data.i_eq16.Ry;
            const registerIdZ = current.instruction.data.i_eq16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY == bitsZ);

            continue :dispatch try state.step(self);
        },
        .i_eq32 => { // 32-bit sign-agnostic integer Rx = Ry == Rz
            const registerIdX = current.instruction.data.i_eq32.Rx;
            const registerIdY = current.instruction.data.i_eq32.Ry;
            const registerIdZ = current.instruction.data.i_eq32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY == bitsZ);

            continue :dispatch try state.step(self);
        },
        .i_eq64 => { // 64-bit sign-agnostic integer Rx = Ry == Rz
            const registerIdX = current.instruction.data.i_eq64.Rx;
            const registerIdY = current.instruction.data.i_eq64.Ry;
            const registerIdZ = current.instruction.data.i_eq64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY == bitsZ);

            continue :dispatch try state.step(self);
        },
        .i_eq8c => { // 8-bit sign-agnostic integer Rx = Ry == I
            const registerIdX = current.instruction.data.i_eq8c.Rx;
            const registerIdY = current.instruction.data.i_eq8c.Ry;
            const bitsZ: u8 = current.instruction.data.i_eq8c.I;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY == bitsZ);

            continue :dispatch try state.step(self);
        },
        .i_eq16c => { // 16-bit sign-agnostic integer Rx = Ry == I
            const registerIdX = current.instruction.data.i_eq16c.Rx;
            const registerIdY = current.instruction.data.i_eq16c.Ry;
            const bitsZ: u16 = current.instruction.data.i_eq16c.I;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY == bitsZ);

            continue :dispatch try state.step(self);
        },
        .i_eq32c => { // 32-bit sign-agnostic integer Rx = Ry == I
            const registerIdX = current.instruction.data.i_eq32c.Rx;
            const registerIdY = current.instruction.data.i_eq32c.Ry;
            const bitsZ: u32 = current.instruction.data.i_eq32c.I;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY == bitsZ);

            continue :dispatch try state.step(self);
        },
        .i_eq64c => { // 64-bit sign-agnostic integer Rx = Ry == I
            const registerIdX = current.instruction.data.i_eq64c.Rx;
            const registerIdY = current.instruction.data.i_eq64c.Ry;
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY == bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_eq32 => { // 32-bit floating point Rx = Ry == Rz
            const registerIdX = current.instruction.data.f_eq32.Rx;
            const registerIdY = current.instruction.data.f_eq32.Ry;
            const registerIdZ = current.instruction.data.f_eq32.Rz;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY == bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_eq32c => { // 32-bit floating point Rx = Ry == I
            const registerIdX = current.instruction.data.f_eq32c.Rx;
            const registerIdY = current.instruction.data.f_eq32c.Ry;
            const bitsZ: f32 = @bitCast(@as(u32, current.instruction.data.f_eq32c.I));

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY == bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_eq64 => { // 64-bit floating point Rx = Ry == Rz
            const registerIdX = current.instruction.data.f_eq64.Rx;
            const registerIdY = current.instruction.data.f_eq64.Ry;
            const registerIdZ = current.instruction.data.f_eq64.Rz;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY == bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_eq64c => { // 64-bit floating point Rx = Ry == I
            const registerIdX = current.instruction.data.f_eq64c.Rx;
            const registerIdY = current.instruction.data.f_eq64c.Ry;
            const bitsZ: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY == bitsZ);

            continue :dispatch try state.step(self);
        },

        .i_ne8 => { // 8-bit sign-agnostic integer Rx = Ry != Rz
            const registerIdX = current.instruction.data.i_ne8.Rx;
            const registerIdY = current.instruction.data.i_ne8.Ry;
            const registerIdZ = current.instruction.data.i_ne8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY != bitsZ);

            continue :dispatch try state.step(self);
        },
        .i_ne16 => { // 16-bit sign-agnostic integer Rx = Ry != Rz
            const registerIdX = current.instruction.data.i_ne16.Rx;
            const registerIdY = current.instruction.data.i_ne16.Ry;
            const registerIdZ = current.instruction.data.i_ne16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY != bitsZ);

            continue :dispatch try state.step(self);
        },
        .i_ne32 => { // 32-bit sign-agnostic integer Rx = Ry != Rz
            const registerIdX = current.instruction.data.i_ne32.Rx;
            const registerIdY = current.instruction.data.i_ne32.Ry;
            const registerIdZ = current.instruction.data.i_ne32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY != bitsZ);

            continue :dispatch try state.step(self);
        },
        .i_ne64 => { // 64-bit sign-agnostic integer Rx = Ry != Rz
            const registerIdX = current.instruction.data.i_ne64.Rx;
            const registerIdY = current.instruction.data.i_ne64.Ry;
            const registerIdZ = current.instruction.data.i_ne64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY != bitsZ);

            continue :dispatch try state.step(self);
        },
        .i_ne8c => { // 8-bit sign-agnostic integer Rx = Ry != I
            const registerIdX = current.instruction.data.i_ne8c.Rx;
            const registerIdY = current.instruction.data.i_ne8c.Ry;
            const bitsZ: u8 = current.instruction.data.i_ne8c.I;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY != bitsZ);

            continue :dispatch try state.step(self);
        },
        .i_ne16c => { // 16-bit sign-agnostic integer Rx = Ry != I
            const registerIdX = current.instruction.data.i_ne16c.Rx;
            const registerIdY = current.instruction.data.i_ne16c.Ry;
            const bitsZ: u16 = current.instruction.data.i_ne16c.I;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY != bitsZ);

            continue :dispatch try state.step(self);
        },
        .i_ne32c => { // 32-bit sign-agnostic integer Rx = Ry != I
            const registerIdX = current.instruction.data.i_ne32c.Rx;
            const registerIdY = current.instruction.data.i_ne32c.Ry;
            const bitsZ: u32 = current.instruction.data.i_ne32c.I;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY != bitsZ);

            continue :dispatch try state.step(self);
        },
        .i_ne64c => { // 64-bit sign-agnostic integer Rx = Ry != I
            const registerIdX = current.instruction.data.i_ne64c.Rx;
            const registerIdY = current.instruction.data.i_ne64c.Ry;
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY != bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_ne32 => { // 32-bit floating point Rx = Ry != Rz
            const registerIdX = current.instruction.data.f_ne32.Rx;
            const registerIdY = current.instruction.data.f_ne32.Ry;
            const registerIdZ = current.instruction.data.f_ne32.Rz;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY != bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_ne32c => { // 32-bit floating point Rx = Ry != I
            const registerIdX = current.instruction.data.f_ne32c.Rx;
            const registerIdY = current.instruction.data.f_ne32c.Ry;
            const bitsZ: f32 = @bitCast(@as(u32, current.instruction.data.f_ne32c.I));

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY != bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_ne64 => { // 64-bit floating point Rx = Ry != Rz
            const registerIdX = current.instruction.data.f_ne64.Rx;
            const registerIdY = current.instruction.data.f_ne64.Ry;
            const registerIdZ = current.instruction.data.f_ne64.Rz;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY != bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_ne64c => { // 64-bit floating point Rx = Ry != I
            const registerIdX = current.instruction.data.f_ne64c.Rx;
            const registerIdY = current.instruction.data.f_ne64c.Ry;
            const bitsZ: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY != bitsZ);

            continue :dispatch try state.step(self);
        },

        .u_lt8 => { // 8-bit unsigned integer Rx = Ry < Rz
            const registerIdX = current.instruction.data.u_lt8.Rx;
            const registerIdY = current.instruction.data.u_lt8.Ry;
            const registerIdZ = current.instruction.data.u_lt8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_lt16 => { // 16-bit unsigned integer Rx = Ry < Rz
            const registerIdX = current.instruction.data.u_lt16.Rx;
            const registerIdY = current.instruction.data.u_lt16.Ry;
            const registerIdZ = current.instruction.data.u_lt16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_lt32 => { // 32-bit unsigned integer Rx = Ry < Rz
            const registerIdX = current.instruction.data.u_lt32.Rx;
            const registerIdY = current.instruction.data.u_lt32.Ry;
            const registerIdZ = current.instruction.data.u_lt32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_lt64 => { // 64-bit unsigned integer Rx = Ry < Rz
            const registerIdX = current.instruction.data.u_lt64.Rx;
            const registerIdY = current.instruction.data.u_lt64.Ry;
            const registerIdZ = current.instruction.data.u_lt64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_lt8a => { // 8-bit unsigned integer Rx = I < Ry
            const registerIdX = current.instruction.data.u_lt8a.Rx;
            const registerIdY = current.instruction.data.u_lt8a.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.instruction.data.u_lt8a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ < bitsY);

            continue :dispatch try state.step(self);
        },
        .u_lt16a => { // 16-bit unsigned integer Rx = I < Ry
            const registerIdX = current.instruction.data.u_lt16a.Rx;
            const registerIdY = current.instruction.data.u_lt16a.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.instruction.data.u_lt16a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ < bitsY);

            continue :dispatch try state.step(self);
        },
        .u_lt32a => { // 32-bit unsigned integer Rx = I < Ry
            const registerIdX = current.instruction.data.u_lt32a.Rx;
            const registerIdY = current.instruction.data.u_lt32a.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.instruction.data.u_lt32a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ < bitsY);

            continue :dispatch try state.step(self);
        },
        .u_lt64a => { // 64-bit unsigned integer Rx = I < Ry
            const registerIdX = current.instruction.data.u_lt64a.Rx;
            const registerIdY = current.instruction.data.u_lt64a.Ry;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ < bitsY);

            continue :dispatch try state.step(self);
        },
        .u_lt8b => { // 8-bit unsigned integer Rx = Ry < I
            const registerIdX = current.instruction.data.u_lt8b.Rx;
            const registerIdY = current.instruction.data.u_lt8b.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.instruction.data.u_lt8b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_lt16b => { // 16-bit unsigned integer Rx = Ry < I
            const registerIdX = current.instruction.data.u_lt16b.Rx;
            const registerIdY = current.instruction.data.u_lt16b.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.instruction.data.u_lt16b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_lt32b => { // 32-bit unsigned integer Rx = Ry < I
            const registerIdX = current.instruction.data.u_lt32b.Rx;
            const registerIdY = current.instruction.data.u_lt32b.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.instruction.data.u_lt32b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_lt64b => { // 64-bit unsigned integer Rx = Ry < I
            const registerIdX = current.instruction.data.u_lt64b.Rx;
            const registerIdY = current.instruction.data.u_lt64b.Ry;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_lt8 => { // 8-bit signed integer Rx = Ry < Rz
            const registerIdX = current.instruction.data.s_lt8.Rx;
            const registerIdY = current.instruction.data.s_lt8.Ry;
            const registerIdZ = current.instruction.data.s_lt8.Rz;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_lt16 => { // 16-bit signed integer Rx = Ry < Rz
            const registerIdX = current.instruction.data.s_lt16.Rx;
            const registerIdY = current.instruction.data.s_lt16.Ry;
            const registerIdZ = current.instruction.data.s_lt16.Rz;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_lt32 => { // 32-bit signed integer Rx = Ry < Rz
            const registerIdX = current.instruction.data.s_lt32.Rx;
            const registerIdY = current.instruction.data.s_lt32.Ry;
            const registerIdZ = current.instruction.data.s_lt32.Rz;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_lt64 => { // 64-bit signed integer Rx = Ry < Rz
            const registerIdX = current.instruction.data.s_lt64.Rx;
            const registerIdY = current.instruction.data.s_lt64.Ry;
            const registerIdZ = current.instruction.data.s_lt64.Rz;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_lt8a => { // 8-bit signed integer Rx = I < Ry
            const registerIdX = current.instruction.data.s_lt8a.Rx;
            const registerIdY = current.instruction.data.s_lt8a.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.instruction.data.s_lt8a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ < bitsY);

            continue :dispatch try state.step(self);
        },
        .s_lt16a => { // 16-bit signed integer Rx = I < Ry
            const registerIdX = current.instruction.data.s_lt16a.Rx;
            const registerIdY = current.instruction.data.s_lt16a.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.instruction.data.s_lt16a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ < bitsY);

            continue :dispatch try state.step(self);
        },
        .s_lt32a => { // 32-bit signed integer Rx = I < Ry
            const registerIdX = current.instruction.data.s_lt32a.Rx;
            const registerIdY = current.instruction.data.s_lt32a.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.instruction.data.s_lt32a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ < bitsY);

            continue :dispatch try state.step(self);
        },
        .s_lt64a => { // 64-bit signed integer Rx = I < Ry
            const registerIdX = current.instruction.data.s_lt64a.Rx;
            const registerIdY = current.instruction.data.s_lt64a.Ry;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ < bitsY);

            continue :dispatch try state.step(self);
        },
        .s_lt8b => { // 8-bit signed integer Rx = Ry < I
            const registerIdX = current.instruction.data.s_lt8b.Rx;
            const registerIdY = current.instruction.data.s_lt8b.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.instruction.data.s_lt8b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_lt16b => { // 16-bit signed integer Rx = Ry < I
            const registerIdX = current.instruction.data.s_lt16b.Rx;
            const registerIdY = current.instruction.data.s_lt16b.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.instruction.data.s_lt16b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_lt32b => { // 32-bit signed integer Rx = Ry < I
            const registerIdX = current.instruction.data.s_lt32b.Rx;
            const registerIdY = current.instruction.data.s_lt32b.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.instruction.data.s_lt32b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_lt64b => { // 64-bit signed integer Rx = Ry < I
            const registerIdX = current.instruction.data.s_lt64b.Rx;
            const registerIdY = current.instruction.data.s_lt64b.Ry;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_lt32 => { // 32-bit floating point Rx = Ry < Rz
            const registerIdX = current.instruction.data.f_lt32.Rx;
            const registerIdY = current.instruction.data.f_lt32.Ry;
            const registerIdZ = current.instruction.data.f_lt32.Rz;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_lt32a => { // 32-bit floating point Rx = I < Ry
            const registerIdX = current.instruction.data.f_lt32a.Rx;
            const registerIdY = current.instruction.data.f_lt32a.Ry;
            const bitsZ: f32 = @bitCast(@as(u32, current.instruction.data.f_lt32a.I));

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ < bitsY);

            continue :dispatch try state.step(self);
        },
        .f_lt32b => { // 32-bit floating point Rx = Ry < I
            const registerIdX = current.instruction.data.f_lt32b.Rx;
            const registerIdY = current.instruction.data.f_lt32b.Ry;
            const bitsZ: f32 = @bitCast(@as(u32, current.instruction.data.f_lt32b.I));

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_lt64 => { // 64-bit floating point Rx = Ry < Rz
            const registerIdX = current.instruction.data.f_lt64.Rx;
            const registerIdY = current.instruction.data.f_lt64.Ry;
            const registerIdZ = current.instruction.data.f_lt64.Rz;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_lt64a => { // 64-bit floating point Rx = I < Ry
            const registerIdX = current.instruction.data.f_lt64a.Rx;
            const registerIdY = current.instruction.data.f_lt64a.Ry;
            const bitsZ: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ < bitsY);

            continue :dispatch try state.step(self);
        },
        .f_lt64b => { // 64-bit floating point Rx = Ry < I
            const registerIdX = current.instruction.data.f_lt64b.Rx;
            const registerIdY = current.instruction.data.f_lt64b.Ry;
            const bitsZ: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY < bitsZ);

            continue :dispatch try state.step(self);
        },

        .u_gt8 => { // 8-bit unsigned integer Rx = Ry > Rz
            const registerIdX = current.instruction.data.u_gt8.Rx;
            const registerIdY = current.instruction.data.u_gt8.Ry;
            const registerIdZ = current.instruction.data.u_gt8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_gt16 => { // 16-bit unsigned integer Rx = Ry > Rz
            const registerIdX = current.instruction.data.u_gt16.Rx;
            const registerIdY = current.instruction.data.u_gt16.Ry;
            const registerIdZ = current.instruction.data.u_gt16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_gt32 => { // 32-bit unsigned integer Rx = Ry > Rz
            const registerIdX = current.instruction.data.u_gt32.Rx;
            const registerIdY = current.instruction.data.u_gt32.Ry;
            const registerIdZ = current.instruction.data.u_gt32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_gt64 => { // 64-bit unsigned integer Rx = Ry > Rz
            const registerIdX = current.instruction.data.u_gt64.Rx;
            const registerIdY = current.instruction.data.u_gt64.Ry;
            const registerIdZ = current.instruction.data.u_gt64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_gt8a => { // 8-bit unsigned integer Rx = I > Ry
            const registerIdX = current.instruction.data.u_gt8a.Rx;
            const registerIdY = current.instruction.data.u_gt8a.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.instruction.data.u_gt8a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ > bitsY);

            continue :dispatch try state.step(self);
        },
        .u_gt16a => { // 16-bit unsigned integer Rx = I > Ry
            const registerIdX = current.instruction.data.u_gt16a.Rx;
            const registerIdY = current.instruction.data.u_gt16a.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.instruction.data.u_gt16a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ > bitsY);

            continue :dispatch try state.step(self);
        },
        .u_gt32a => { // 32-bit unsigned integer Rx = I > Ry
            const registerIdX = current.instruction.data.u_gt32a.Rx;
            const registerIdY = current.instruction.data.u_gt32a.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.instruction.data.u_gt32a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ > bitsY);

            continue :dispatch try state.step(self);
        },
        .u_gt64a => { // 64-bit unsigned integer Rx = I > Ry
            const registerIdX = current.instruction.data.u_gt64a.Rx;
            const registerIdY = current.instruction.data.u_gt64a.Ry;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ > bitsY);

            continue :dispatch try state.step(self);
        },
        .u_gt8b => { // 8-bit unsigned integer Rx = Ry > I
            const registerIdX = current.instruction.data.u_gt8b.Rx;
            const registerIdY = current.instruction.data.u_gt8b.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.instruction.data.u_gt8b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_gt16b => { // 16-bit unsigned integer Rx = Ry > I
            const registerIdX = current.instruction.data.u_gt16b.Rx;
            const registerIdY = current.instruction.data.u_gt16b.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.instruction.data.u_gt16b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_gt32b => { // 32-bit unsigned integer Rx = Ry > I
            const registerIdX = current.instruction.data.u_gt32b.Rx;
            const registerIdY = current.instruction.data.u_gt32b.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.instruction.data.u_gt32b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_gt64b => { // 64-bit unsigned integer Rx = Ry > I
            const registerIdX = current.instruction.data.u_gt64b.Rx;
            const registerIdY = current.instruction.data.u_gt64b.Ry;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_gt8 => { // 8-bit signed integer Rx = Ry > Rz
            const registerIdX = current.instruction.data.s_gt8.Rx;
            const registerIdY = current.instruction.data.s_gt8.Ry;
            const registerIdZ = current.instruction.data.s_gt8.Rz;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_gt16 => { // 16-bit signed integer Rx = Ry > Rz
            const registerIdX = current.instruction.data.s_gt16.Rx;
            const registerIdY = current.instruction.data.s_gt16.Ry;
            const registerIdZ = current.instruction.data.s_gt16.Rz;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_gt32 => { // 32-bit signed integer Rx = Ry > Rz
            const registerIdX = current.instruction.data.s_gt32.Rx;
            const registerIdY = current.instruction.data.s_gt32.Ry;
            const registerIdZ = current.instruction.data.s_gt32.Rz;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_gt64 => { // 64-bit signed integer Rx = Ry > Rz
            const registerIdX = current.instruction.data.s_gt64.Rx;
            const registerIdY = current.instruction.data.s_gt64.Ry;
            const registerIdZ = current.instruction.data.s_gt64.Rz;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_gt8a => { // 8-bit signed integer Rx = I > Ry
            const registerIdX = current.instruction.data.s_gt8a.Rx;
            const registerIdY = current.instruction.data.s_gt8a.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.instruction.data.s_gt8a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ > bitsY);

            continue :dispatch try state.step(self);
        },
        .s_gt16a => { // 16-bit signed integer Rx = I > Ry
            const registerIdX = current.instruction.data.s_gt16a.Rx;
            const registerIdY = current.instruction.data.s_gt16a.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.instruction.data.s_gt16a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ > bitsY);

            continue :dispatch try state.step(self);
        },
        .s_gt32a => { // 32-bit signed integer Rx = I > Ry
            const registerIdX = current.instruction.data.s_gt32a.Rx;
            const registerIdY = current.instruction.data.s_gt32a.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.instruction.data.s_gt32a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ > bitsY);

            continue :dispatch try state.step(self);
        },
        .s_gt64a => { // 64-bit signed integer Rx = I > Ry
            const registerIdX = current.instruction.data.s_gt64a.Rx;
            const registerIdY = current.instruction.data.s_gt64a.Ry;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ > bitsY);

            continue :dispatch try state.step(self);
        },
        .s_gt8b => { // 8-bit signed integer Rx = Ry > I
            const registerIdX = current.instruction.data.s_gt8b.Rx;
            const registerIdY = current.instruction.data.s_gt8b.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.instruction.data.s_gt8b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_gt16b => { // 16-bit signed integer Rx = Ry > I
            const registerIdX = current.instruction.data.s_gt16b.Rx;
            const registerIdY = current.instruction.data.s_gt16b.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.instruction.data.s_gt16b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_gt32b => { // 32-bit signed integer Rx = Ry > I
            const registerIdX = current.instruction.data.s_gt32b.Rx;
            const registerIdY = current.instruction.data.s_gt32b.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.instruction.data.s_gt32b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_gt64b => { // 64-bit signed integer Rx = Ry > I
            const registerIdX = current.instruction.data.s_gt64b.Rx;
            const registerIdY = current.instruction.data.s_gt64b.Ry;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_gt32 => { // 32-bit floating point Rx = Ry > Rz
            const registerIdX = current.instruction.data.f_gt32.Rx;
            const registerIdY = current.instruction.data.f_gt32.Ry;
            const registerIdZ = current.instruction.data.f_gt32.Rz;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_gt32a => { // 32-bit floating point Rx = I > Ry
            const registerIdX = current.instruction.data.f_gt32a.Rx;
            const registerIdY = current.instruction.data.f_gt32a.Ry;
            const bitsZ: f32 = @bitCast(@as(u32, current.instruction.data.f_gt32a.I));

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ > bitsY);

            continue :dispatch try state.step(self);
        },
        .f_gt32b => { // 32-bit floating point Rx = Ry > I
            const registerIdX = current.instruction.data.f_gt32b.Rx;
            const registerIdY = current.instruction.data.f_gt32b.Ry;
            const bitsZ: f32 = @bitCast(@as(u32, current.instruction.data.f_gt32b.I));

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_gt64 => { // 64-bit floating point Rx = Ry > Rz
            const registerIdX = current.instruction.data.f_gt64.Rx;
            const registerIdY = current.instruction.data.f_gt64.Ry;
            const registerIdZ = current.instruction.data.f_gt64.Rz;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_gt64a => { // 64-bit floating point Rx = I > Ry
            const registerIdX = current.instruction.data.f_gt64a.Rx;
            const registerIdY = current.instruction.data.f_gt64a.Ry;
            const bitsZ: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ > bitsY);

            continue :dispatch try state.step(self);
        },
        .f_gt64b => { // 64-bit floating point Rx = Ry > I
            const registerIdX = current.instruction.data.f_gt64b.Rx;
            const registerIdY = current.instruction.data.f_gt64b.Ry;
            const bitsZ: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY > bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_le8 => { // 8-bit unsigned integer Rx = Ry <= Rz
            const registerIdX = current.instruction.data.u_le8.Rx;
            const registerIdY = current.instruction.data.u_le8.Ry;
            const registerIdZ = current.instruction.data.u_le8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_le16 => { // 16-bit unsigned integer Rx = Ry <= Rz
            const registerIdX = current.instruction.data.u_le16.Rx;
            const registerIdY = current.instruction.data.u_le16.Ry;
            const registerIdZ = current.instruction.data.u_le16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_le32 => { // 32-bit unsigned integer Rx = Ry <= Rz
            const registerIdX = current.instruction.data.u_le32.Rx;
            const registerIdY = current.instruction.data.u_le32.Ry;
            const registerIdZ = current.instruction.data.u_le32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_le64 => { // 64-bit unsigned integer Rx = Ry <= Rz
            const registerIdX = current.instruction.data.u_le64.Rx;
            const registerIdY = current.instruction.data.u_le64.Ry;
            const registerIdZ = current.instruction.data.u_le64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_le8a => { // 8-bit unsigned integer Rx = I <= Ry
            const registerIdX = current.instruction.data.u_le8a.Rx;
            const registerIdY = current.instruction.data.u_le8a.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.instruction.data.u_le8a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ <= bitsY);

            continue :dispatch try state.step(self);
        },
        .u_le16a => { // 16-bit unsigned integer Rx = I <= Ry
            const registerIdX = current.instruction.data.u_le16a.Rx;
            const registerIdY = current.instruction.data.u_le16a.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.instruction.data.u_le16a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ <= bitsY);

            continue :dispatch try state.step(self);
        },
        .u_le32a => { // 32-bit unsigned integer Rx = I <= Ry
            const registerIdX = current.instruction.data.u_le32a.Rx;
            const registerIdY = current.instruction.data.u_le32a.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.instruction.data.u_le32a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ <= bitsY);

            continue :dispatch try state.step(self);
        },
        .u_le64a => { // 64-bit unsigned integer Rx = I <= Ry
            const registerIdX = current.instruction.data.u_le64a.Rx;
            const registerIdY = current.instruction.data.u_le64a.Ry;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ <= bitsY);

            continue :dispatch try state.step(self);
        },
        .u_le8b => { // 8-bit unsigned integer Rx = Ry <= I
            const registerIdX = current.instruction.data.u_le8b.Rx;
            const registerIdY = current.instruction.data.u_le8b.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.instruction.data.u_le8b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_le16b => { // 16-bit unsigned integer Rx = Ry <= I
            const registerIdX = current.instruction.data.u_le16b.Rx;
            const registerIdY = current.instruction.data.u_le16b.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.instruction.data.u_le16b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_le32b => { // 32-bit unsigned integer Rx = Ry <= I
            const registerIdX = current.instruction.data.u_le32b.Rx;
            const registerIdY = current.instruction.data.u_le32b.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.instruction.data.u_le32b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_le64b => { // 64-bit unsigned integer Rx = Ry <= I
            const registerIdX = current.instruction.data.u_le64b.Rx;
            const registerIdY = current.instruction.data.u_le64b.Ry;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_le8 => { // 8-bit signed integer Rx = Ry <= Rz
            const registerIdX = current.instruction.data.s_le8.Rx;
            const registerIdY = current.instruction.data.s_le8.Ry;
            const registerIdZ = current.instruction.data.s_le8.Rz;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_le16 => { // 16-bit signed integer Rx = Ry <= Rz
            const registerIdX = current.instruction.data.s_le16.Rx;
            const registerIdY = current.instruction.data.s_le16.Ry;
            const registerIdZ = current.instruction.data.s_le16.Rz;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_le32 => { // 32-bit signed integer Rx = Ry <= Rz
            const registerIdX = current.instruction.data.s_le32.Rx;
            const registerIdY = current.instruction.data.s_le32.Ry;
            const registerIdZ = current.instruction.data.s_le32.Rz;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_le64 => { // 64-bit signed integer Rx = Ry <= Rz
            const registerIdX = current.instruction.data.s_le64.Rx;
            const registerIdY = current.instruction.data.s_le64.Ry;
            const registerIdZ = current.instruction.data.s_le64.Rz;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_le8a => { // 8-bit signed integer Rx = I <= Ry
            const registerIdX = current.instruction.data.s_le8a.Rx;
            const registerIdY = current.instruction.data.s_le8a.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.instruction.data.s_le8a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ <= bitsY);

            continue :dispatch try state.step(self);
        },
        .s_le16a => { // 16-bit signed integer Rx = I <= Ry
            const registerIdX = current.instruction.data.s_le16a.Rx;
            const registerIdY = current.instruction.data.s_le16a.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.instruction.data.s_le16a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ <= bitsY);

            continue :dispatch try state.step(self);
        },
        .s_le32a => { // 32-bit signed integer Rx = I <= Ry
            const registerIdX = current.instruction.data.s_le32a.Rx;
            const registerIdY = current.instruction.data.s_le32a.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.instruction.data.s_le32a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ <= bitsY);

            continue :dispatch try state.step(self);
        },
        .s_le64a => { // 64-bit signed integer Rx = I <= Ry
            const registerIdX = current.instruction.data.s_le64a.Rx;
            const registerIdY = current.instruction.data.s_le64a.Ry;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ <= bitsY);

            continue :dispatch try state.step(self);
        },
        .s_le8b => { // 8-bit signed integer Rx = Ry <= I
            const registerIdX = current.instruction.data.s_le8b.Rx;
            const registerIdY = current.instruction.data.s_le8b.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.instruction.data.s_le8b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_le16b => { // 16-bit signed integer Rx = Ry <= I
            const registerIdX = current.instruction.data.s_le16b.Rx;
            const registerIdY = current.instruction.data.s_le16b.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.instruction.data.s_le16b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_le32b => { // 32-bit signed integer Rx = Ry <= I
            const registerIdX = current.instruction.data.s_le32b.Rx;
            const registerIdY = current.instruction.data.s_le32b.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.instruction.data.s_le32b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_le64b => { // 64-bit signed integer Rx = Ry <= I
            const registerIdX = current.instruction.data.s_le64b.Rx;
            const registerIdY = current.instruction.data.s_le64b.Ry;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_le32 => { // 32-bit floating point Rx = Ry <= Rz
            const registerIdX = current.instruction.data.f_le32.Rx;
            const registerIdY = current.instruction.data.f_le32.Ry;
            const registerIdZ = current.instruction.data.f_le32.Rz;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_le32a => { // 32-bit floating point Rx = I <= Ry
            const registerIdX = current.instruction.data.f_le32a.Rx;
            const registerIdY = current.instruction.data.f_le32a.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.instruction.data.f_le32a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ <= bitsY);

            continue :dispatch try state.step(self);
        },
        .f_le32b => { // 32-bit floating point Rx = Ry <= I
            const registerIdX = current.instruction.data.f_le32b.Rx;
            const registerIdY = current.instruction.data.f_le32b.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.instruction.data.f_le32b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_le64 => { // 64-bit floating point Rx = Ry <= Rz
            const registerIdX = current.instruction.data.f_le64.Rx;
            const registerIdY = current.instruction.data.f_le64.Ry;
            const registerIdZ = current.instruction.data.f_le64.Rz;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_le64a => { // 64-bit floating point Rx = I <= Ry
            const registerIdX = current.instruction.data.f_le64a.Rx;
            const registerIdY = current.instruction.data.f_le64a.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ <= bitsY);

            continue :dispatch try state.step(self);
        },
        .f_le64b => { // 64-bit floating point Rx = Ry <= I
            const registerIdX = current.instruction.data.f_le64b.Rx;
            const registerIdY = current.instruction.data.f_le64b.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY <= bitsZ);

            continue :dispatch try state.step(self);
        },

        .u_ge8 => { // 8-bit unsigned integer Rx = Ry >= Rz
            const registerIdX = current.instruction.data.u_ge8.Rx;
            const registerIdY = current.instruction.data.u_ge8.Ry;
            const registerIdZ = current.instruction.data.u_ge8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_ge16 => { // 16-bit unsigned integer Rx = Ry >= Rz
            const registerIdX = current.instruction.data.u_ge16.Rx;
            const registerIdY = current.instruction.data.u_ge16.Ry;
            const registerIdZ = current.instruction.data.u_ge16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_ge32 => { // 32-bit unsigned integer Rx = Ry >= Rz
            const registerIdX = current.instruction.data.u_ge32.Rx;
            const registerIdY = current.instruction.data.u_ge32.Ry;
            const registerIdZ = current.instruction.data.u_ge32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_ge64 => { // 64-bit unsigned integer Rx = Ry >= Rz
            const registerIdX = current.instruction.data.u_ge64.Rx;
            const registerIdY = current.instruction.data.u_ge64.Ry;
            const registerIdZ = current.instruction.data.u_ge64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_ge8a => { // 8-bit unsigned integer Rx = I >= Ry
            const registerIdX = current.instruction.data.u_ge8a.Rx;
            const registerIdY = current.instruction.data.u_ge8a.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.instruction.data.u_ge8a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ >= bitsY);

            continue :dispatch try state.step(self);
        },
        .u_ge16a => { // 16-bit unsigned integer Rx = I >= Ry
            const registerIdX = current.instruction.data.u_ge16a.Rx;
            const registerIdY = current.instruction.data.u_ge16a.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.instruction.data.u_ge16a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ >= bitsY);

            continue :dispatch try state.step(self);
        },
        .u_ge32a => { // 32-bit unsigned integer Rx = I >= Ry
            const registerIdX = current.instruction.data.u_ge32a.Rx;
            const registerIdY = current.instruction.data.u_ge32a.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.instruction.data.u_ge32a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ >= bitsY);

            continue :dispatch try state.step(self);
        },
        .u_ge64a => { // 64-bit unsigned integer Rx = I >= Ry
            const registerIdX = current.instruction.data.u_ge64a.Rx;
            const registerIdY = current.instruction.data.u_ge64a.Ry;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ >= bitsY);

            continue :dispatch try state.step(self);
        },
        .u_ge8b => { // 8-bit unsigned integer Rx = Ry >= I
            const registerIdX = current.instruction.data.u_ge8b.Rx;
            const registerIdY = current.instruction.data.u_ge8b.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.instruction.data.u_ge8b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_ge16b => { // 16-bit unsigned integer Rx = Ry >= I
            const registerIdX = current.instruction.data.u_ge16b.Rx;
            const registerIdY = current.instruction.data.u_ge16b.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.instruction.data.u_ge16b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_ge32b => { // 32-bit unsigned integer Rx = Ry >= I
            const registerIdX = current.instruction.data.u_ge32b.Rx;
            const registerIdY = current.instruction.data.u_ge32b.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.instruction.data.u_ge32b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },
        .u_ge64b => { // 64-bit unsigned integer Rx = Ry >= I
            const registerIdX = current.instruction.data.u_ge64b.Rx;
            const registerIdY = current.instruction.data.u_ge64b.Ry;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_ge8 => { // 8-bit signed integer Rx = Ry >= Rz
            const registerIdX = current.instruction.data.s_ge8.Rx;
            const registerIdY = current.instruction.data.s_ge8.Ry;
            const registerIdZ = current.instruction.data.s_ge8.Rz;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_ge16 => { // 16-bit signed integer Rx = Ry >= Rz
            const registerIdX = current.instruction.data.s_ge16.Rx;
            const registerIdY = current.instruction.data.s_ge16.Ry;
            const registerIdZ = current.instruction.data.s_ge16.Rz;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_ge32 => { // 32-bit signed integer Rx = Ry >= Rz
            const registerIdX = current.instruction.data.s_ge32.Rx;
            const registerIdY = current.instruction.data.s_ge32.Ry;
            const registerIdZ = current.instruction.data.s_ge32.Rz;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_ge64 => { // 64-bit signed integer Rx = Ry >= Rz
            const registerIdX = current.instruction.data.s_ge64.Rx;
            const registerIdY = current.instruction.data.s_ge64.Ry;
            const registerIdZ = current.instruction.data.s_ge64.Rz;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_ge8a => { // 8-bit signed integer Rx = I >= Ry
            const registerIdX = current.instruction.data.s_ge8a.Rx;
            const registerIdY = current.instruction.data.s_ge8a.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.instruction.data.s_ge8a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ >= bitsY);

            continue :dispatch try state.step(self);
        },
        .s_ge16a => { // 16-bit signed integer Rx = I >= Ry
            const registerIdX = current.instruction.data.s_ge16a.Rx;
            const registerIdY = current.instruction.data.s_ge16a.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.instruction.data.s_ge16a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ >= bitsY);

            continue :dispatch try state.step(self);
        },
        .s_ge32a => { // 32-bit signed integer Rx = I >= Ry
            const registerIdX = current.instruction.data.s_ge32a.Rx;
            const registerIdY = current.instruction.data.s_ge32a.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.instruction.data.s_ge32a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ >= bitsY);

            continue :dispatch try state.step(self);
        },
        .s_ge64a => { // 64-bit signed integer Rx = I >= Ry
            const registerIdX = current.instruction.data.s_ge64a.Rx;
            const registerIdY = current.instruction.data.s_ge64a.Ry;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ >= bitsY);

            continue :dispatch try state.step(self);
        },
        .s_ge8b => { // 8-bit signed integer Rx = Ry >= I
            const registerIdX = current.instruction.data.s_ge8b.Rx;
            const registerIdY = current.instruction.data.s_ge8b.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.instruction.data.s_ge8b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_ge16b => { // 16-bit signed integer Rx = Ry >= I
            const registerIdX = current.instruction.data.s_ge16b.Rx;
            const registerIdY = current.instruction.data.s_ge16b.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.instruction.data.s_ge16b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_ge32b => { // 32-bit signed integer Rx = Ry >= I
            const registerIdX = current.instruction.data.s_ge32b.Rx;
            const registerIdY = current.instruction.data.s_ge32b.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.instruction.data.s_ge32b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },
        .s_ge64b => { // 64-bit signed integer Rx = Ry >= I
            const registerIdX = current.instruction.data.s_ge64b.Rx;
            const registerIdY = current.instruction.data.s_ge64b.Ry;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_ge32 => { // 32-bit floating point Rx = Ry >= Rz
            const registerIdX = current.instruction.data.f_ge32.Rx;
            const registerIdY = current.instruction.data.f_ge32.Ry;
            const registerIdZ = current.instruction.data.f_ge32.Rz;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_ge32a => { // 32-bit floating point Rx = I >= Ry
            const registerIdX = current.instruction.data.f_ge32a.Rx;
            const registerIdY = current.instruction.data.f_ge32a.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.instruction.data.f_ge32a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ >= bitsY);

            continue :dispatch try state.step(self);
        },
        .f_ge32b => { // 32-bit floating point Rx = Ry >= I
            const registerIdX = current.instruction.data.f_ge32b.Rx;
            const registerIdY = current.instruction.data.f_ge32b.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.instruction.data.f_ge32b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_ge64 => { // 64-bit floating point Rx = Ry >= Rz
            const registerIdX = current.instruction.data.f_ge64.Rx;
            const registerIdY = current.instruction.data.f_ge64.Ry;
            const registerIdZ = current.instruction.data.f_ge64.Rz;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },
        .f_ge64a => { // 64-bit floating point Rx = I >= Ry
            const registerIdX = current.instruction.data.f_ge64a.Rx;
            const registerIdY = current.instruction.data.f_ge64a.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsZ >= bitsY);

            continue :dispatch try state.step(self);
        },
        .f_ge64b => { // 64-bit floating point Rx = Ry >= I
            const registerIdX = current.instruction.data.f_ge64b.Rx;
            const registerIdY = current.instruction.data.f_ge64b.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @intFromBool(bitsY >= bitsZ);

            continue :dispatch try state.step(self);
        },

        .s_neg8 => { // 8-bit signed integer Rx = -Ry
            const registerIdX = current.instruction.data.s_neg8.Rx;
            const registerIdY = current.instruction.data.s_neg8.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u8, @bitCast(-bitsY));

            continue :dispatch try state.step(self);
        },
        .s_neg16 => { // 16-bit signed integer Rx = -Ry
            const registerIdX = current.instruction.data.s_neg16.Rx;
            const registerIdY = current.instruction.data.s_neg16.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @bitCast(-bitsY));

            continue :dispatch try state.step(self);
        },
        .s_neg32 => { // 32-bit signed integer Rx = -Ry
            const registerIdX = current.instruction.data.s_neg32.Rx;
            const registerIdY = current.instruction.data.s_neg32.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(-bitsY));

            continue :dispatch try state.step(self);
        },
        .s_neg64 => { // 64-bit signed integer Rx = -Ry
            const registerIdX = current.instruction.data.s_neg64.Rx;
            const registerIdY = current.instruction.data.s_neg64.Ry;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(-bitsY));

            continue :dispatch try state.step(self);
        },

        .s_abs8 => { // 8-bit signed integer Rx = |Ry|
            const registerIdX = current.instruction.data.s_abs8.Rx;
            const registerIdY = current.instruction.data.s_abs8.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u8, @bitCast(@abs(bitsY)));

            continue :dispatch try state.step(self);
        },
        .s_abs16 => { // 16-bit signed integer Rx = |Ry|
            const registerIdX = current.instruction.data.s_abs16.Rx;
            const registerIdY = current.instruction.data.s_abs16.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @bitCast(@abs(bitsY)));

            continue :dispatch try state.step(self);
        },
        .s_abs32 => { // 32-bit signed integer Rx = |Ry|
            const registerIdX = current.instruction.data.s_abs32.Rx;
            const registerIdY = current.instruction.data.s_abs32.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@abs(bitsY)));

            continue :dispatch try state.step(self);
        },
        .s_abs64 => { // 64-bit signed integer Rx = |Ry|
            const registerIdX = current.instruction.data.s_abs64.Rx;
            const registerIdY = current.instruction.data.s_abs64.Ry;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@abs(bitsY)));

            continue :dispatch try state.step(self);
        },

        .i_add8 => { // 8-bit sign-agnostic integer Rx = Ry + Rz
            const registerIdX = current.instruction.data.i_add8.Rx;
            const registerIdY = current.instruction.data.i_add8.Ry;
            const registerIdZ = current.instruction.data.i_add8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY + bitsZ;

            continue :dispatch try state.step(self);
        },
        .i_add16 => { // 16-bit sign-agnostic integer Rx = Ry + Rz
            const registerIdX = current.instruction.data.i_add16.Rx;
            const registerIdY = current.instruction.data.i_add16.Ry;
            const registerIdZ = current.instruction.data.i_add16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY + bitsZ;

            continue :dispatch try state.step(self);
        },
        .i_add32 => { // 32-bit sign-agnostic integer Rx = Ry + Rz
            const registerIdX = current.instruction.data.i_add32.Rx;
            const registerIdY = current.instruction.data.i_add32.Ry;
            const registerIdZ = current.instruction.data.i_add32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY + bitsZ;

            continue :dispatch try state.step(self);
        },
        .i_add64 => { // 64-bit sign-agnostic integer Rx = Ry + Rz
            const registerIdX = current.instruction.data.i_add64.Rx;
            const registerIdY = current.instruction.data.i_add64.Ry;
            const registerIdZ = current.instruction.data.i_add64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY + bitsZ;

            continue :dispatch try state.step(self);
        },
        .i_add8c => { // 8-bit sign-agnostic integer Rx = I + Ry
            const registerIdX = current.instruction.data.i_add8c.Rx;
            const registerIdY = current.instruction.data.i_add8c.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.instruction.data.i_add8c.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ + bitsY;

            continue :dispatch try state.step(self);
        },
        .i_add16c => { // 16-bit sign-agnostic integer Rx = I + Ry
            const registerIdX = current.instruction.data.i_add16c.Rx;
            const registerIdY = current.instruction.data.i_add16c.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.instruction.data.i_add16c.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ + bitsY;

            continue :dispatch try state.step(self);
        },
        .i_add32c => { // 32-bit sign-agnostic integer Rx = I + Ry
            const registerIdX = current.instruction.data.i_add32c.Rx;
            const registerIdY = current.instruction.data.i_add32c.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.instruction.data.i_add32c.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ + bitsY;

            continue :dispatch try state.step(self);
        },
        .i_add64c => { // 64-bit sign-agnostic integer Rx = I + Ry
            const registerIdX = current.instruction.data.i_add64c.Rx;
            const registerIdY = current.instruction.data.i_add64c.Ry;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ + bitsY;

            continue :dispatch try state.step(self);
        },

        .i_sub8 => { // 8-bit sign-agnostic integer Rx = Ry - Rz
            const registerIdX = current.instruction.data.i_sub8.Rx;
            const registerIdY = current.instruction.data.i_sub8.Ry;
            const registerIdZ = current.instruction.data.i_sub8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY - bitsZ;

            continue :dispatch try state.step(self);
        },
        .i_sub16 => { // 16-bit sign-agnostic integer Rx = Ry - Rz
            const registerIdX = current.instruction.data.i_sub16.Rx;
            const registerIdY = current.instruction.data.i_sub16.Ry;
            const registerIdZ = current.instruction.data.i_sub16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY - bitsZ;

            continue :dispatch try state.step(self);
        },
        .i_sub32 => { // 32-bit sign-agnostic integer Rx = Ry - Rz
            const registerIdX = current.instruction.data.i_sub32.Rx;
            const registerIdY = current.instruction.data.i_sub32.Ry;
            const registerIdZ = current.instruction.data.i_sub32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY - bitsZ;

            continue :dispatch try state.step(self);
        },
        .i_sub64 => { // 64-bit sign-agnostic integer Rx = Ry - Rz
            const registerIdX = current.instruction.data.i_sub64.Rx;
            const registerIdY = current.instruction.data.i_sub64.Ry;
            const registerIdZ = current.instruction.data.i_sub64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY - bitsZ;

            continue :dispatch try state.step(self);
        },
        .i_sub8a => { // 8-bit sign-agnostic integer Rx = I - Ry
            const registerIdX = current.instruction.data.i_sub8a.Rx;
            const registerIdY = current.instruction.data.i_sub8a.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.instruction.data.i_sub8a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ - bitsY;

            continue :dispatch try state.step(self);
        },
        .i_sub16a => { // 16-bit sign-agnostic integer Rx = I - Ry
            const registerIdX = current.instruction.data.i_sub16a.Rx;
            const registerIdY = current.instruction.data.i_sub16a.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.instruction.data.i_sub16a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ - bitsY;

            continue :dispatch try state.step(self);
        },
        .i_sub32a => { // 32-bit sign-agnostic integer Rx = I - Ry
            const registerIdX = current.instruction.data.i_sub32a.Rx;
            const registerIdY = current.instruction.data.i_sub32a.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.instruction.data.i_sub32a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ - bitsY;

            continue :dispatch try state.step(self);
        },
        .i_sub64a => { // 64-bit sign-agnostic integer Rx = I - Ry
            const registerIdX = current.instruction.data.i_sub64a.Rx;
            const registerIdY = current.instruction.data.i_sub64a.Ry;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ - bitsY;

            continue :dispatch try state.step(self);
        },
        .i_sub8b => { // 8-bit sign-agnostic integer Rx = Ry - I
            const registerIdX = current.instruction.data.i_sub8b.Rx;
            const registerIdY = current.instruction.data.i_sub8b.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.instruction.data.i_sub8b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY - bitsZ;

            continue :dispatch try state.step(self);
        },
        .i_sub16b => { // 16-bit sign-agnostic integer Rx = Ry - I
            const registerIdX = current.instruction.data.i_sub16b.Rx;
            const registerIdY = current.instruction.data.i_sub16b.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.instruction.data.i_sub16b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY - bitsZ;

            continue :dispatch try state.step(self);
        },
        .i_sub32b => { // 32-bit sign-agnostic integer Rx = Ry - I
            const registerIdX = current.instruction.data.i_sub32b.Rx;
            const registerIdY = current.instruction.data.i_sub32b.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.instruction.data.i_sub32b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY - bitsZ;

            continue :dispatch try state.step(self);
        },
        .i_sub64b => { // 64-bit sign-agnostic integer Rx = Ry - I
            const registerIdX = current.instruction.data.i_sub64b.Rx;
            const registerIdY = current.instruction.data.i_sub64b.Ry;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY - bitsZ;

            continue :dispatch try state.step(self);
        },

        .i_mul8 => { // 8-bit sign-agnostic integer Rx = Ry * Rz
            const registerIdX = current.instruction.data.i_mul8.Rx;
            const registerIdY = current.instruction.data.i_mul8.Ry;
            const registerIdZ = current.instruction.data.i_mul8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY * bitsZ;

            continue :dispatch try state.step(self);
        },
        .i_mul16 => { // 16-bit sign-agnostic integer Rx = Ry * Rz
            const registerIdX = current.instruction.data.i_mul16.Rx;
            const registerIdY = current.instruction.data.i_mul16.Ry;
            const registerIdZ = current.instruction.data.i_mul16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY * bitsZ;

            continue :dispatch try state.step(self);
        },
        .i_mul32 => { // 32-bit sign-agnostic integer Rx = Ry * Rz
            const registerIdX = current.instruction.data.i_mul32.Rx;
            const registerIdY = current.instruction.data.i_mul32.Ry;
            const registerIdZ = current.instruction.data.i_mul32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY * bitsZ;

            continue :dispatch try state.step(self);
        },
        .i_mul64 => { // 64-bit sign-agnostic integer Rx = Ry * Rz
            const registerIdX = current.instruction.data.i_mul64.Rx;
            const registerIdY = current.instruction.data.i_mul64.Ry;
            const registerIdZ = current.instruction.data.i_mul64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY * bitsZ;

            continue :dispatch try state.step(self);
        },
        .i_mul8c => { // 8-bit sign-agnostic integer Rx = I * Ry
            const registerIdX = current.instruction.data.i_mul8c.Rx;
            const registerIdY = current.instruction.data.i_mul8c.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.instruction.data.i_mul8c.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ * bitsY;

            continue :dispatch try state.step(self);
        },
        .i_mul16c => { // 16-bit sign-agnostic integer Rx = I * Ry
            const registerIdX = current.instruction.data.i_mul16c.Rx;
            const registerIdY = current.instruction.data.i_mul16c.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.instruction.data.i_mul16c.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ * bitsY;

            continue :dispatch try state.step(self);
        },
        .i_mul32c => { // 32-bit sign-agnostic integer Rx = I * Ry
            const registerIdX = current.instruction.data.i_mul32c.Rx;
            const registerIdY = current.instruction.data.i_mul32c.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.instruction.data.i_mul32c.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ * bitsY;

            continue :dispatch try state.step(self);
        },
        .i_mul64c => { // 64-bit sign-agnostic integer Rx = I * Ry
            const registerIdX = current.instruction.data.i_mul64c.Rx;
            const registerIdY = current.instruction.data.i_mul64c.Ry;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ * bitsY;

            continue :dispatch try state.step(self);
        },

        .u_div8 => { // 8-bit unsigned integer Rx = Ry / Rz
            const registerIdX = current.instruction.data.u_div8.Rx;
            const registerIdY = current.instruction.data.u_div8.Ry;
            const registerIdZ = current.instruction.data.u_div8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY / bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_div16 => { // 16-bit unsigned integer Rx = Ry / Rz
            const registerIdX = current.instruction.data.u_div16.Rx;
            const registerIdY = current.instruction.data.u_div16.Ry;
            const registerIdZ = current.instruction.data.u_div16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY / bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_div32 => { // 32-bit unsigned integer Rx = Ry / Rz
            const registerIdX = current.instruction.data.u_div32.Rx;
            const registerIdY = current.instruction.data.u_div32.Ry;
            const registerIdZ = current.instruction.data.u_div32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY / bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_div64 => { // 64-bit unsigned integer Rx = Ry / Rz
            const registerIdX = current.instruction.data.u_div64.Rx;
            const registerIdY = current.instruction.data.u_div64.Ry;
            const registerIdZ = current.instruction.data.u_div64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY / bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_div8a => { // 8-bit unsigned integer Rx = I / Ry
            const registerIdX = current.instruction.data.u_div8a.Rx;
            const registerIdY = current.instruction.data.u_div8a.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.instruction.data.u_div8a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ / bitsY;

            continue :dispatch try state.step(self);
        },
        .u_div16a => { // 16-bit unsigned integer Rx = I / Ry
            const registerIdX = current.instruction.data.u_div16a.Rx;
            const registerIdY = current.instruction.data.u_div16a.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.instruction.data.u_div16a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ / bitsY;

            continue :dispatch try state.step(self);
        },
        .u_div32a => { // 32-bit unsigned integer Rx = I / Ry
            const registerIdX = current.instruction.data.u_div32a.Rx;
            const registerIdY = current.instruction.data.u_div32a.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.instruction.data.u_div32a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ / bitsY;

            continue :dispatch try state.step(self);
        },
        .u_div64a => { // 64-bit unsigned integer Rx = I / Ry
            const registerIdX = current.instruction.data.u_div64a.Rx;
            const registerIdY = current.instruction.data.u_div64a.Ry;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ / bitsY;

            continue :dispatch try state.step(self);
        },
        .u_div8b => { // 8-bit unsigned integer Rx = Ry / I
            const registerIdX = current.instruction.data.u_div8b.Rx;
            const registerIdY = current.instruction.data.u_div8b.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.instruction.data.u_div8b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY / bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_div16b => { // 16-bit unsigned integer Rx = Ry / I
            const registerIdX = current.instruction.data.u_div16b.Rx;
            const registerIdY = current.instruction.data.u_div16b.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.instruction.data.u_div16b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY / bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_div32b => { // 32-bit unsigned integer Rx = Ry / I
            const registerIdX = current.instruction.data.u_div32b.Rx;
            const registerIdY = current.instruction.data.u_div32b.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.instruction.data.u_div32b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY / bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_div64b => { // 64-bit unsigned integer Rx = Ry / I
            const registerIdX = current.instruction.data.u_div64b.Rx;
            const registerIdY = current.instruction.data.u_div64b.Ry;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY / bitsZ;

            continue :dispatch try state.step(self);
        },
        .s_div8 => { // 8-bit signed integer Rx = Ry / Rz
            const registerIdX = current.instruction.data.s_div8.Rx;
            const registerIdY = current.instruction.data.s_div8.Ry;
            const registerIdZ = current.instruction.data.s_div8.Rz;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u8, @bitCast(@divTrunc(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .s_div16 => { // 16-bit signed integer Rx = Ry / Rz
            const registerIdX = current.instruction.data.s_div16.Rx;
            const registerIdY = current.instruction.data.s_div16.Ry;
            const registerIdZ = current.instruction.data.s_div16.Rz;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @bitCast(@divTrunc(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .s_div32 => { // 32-bit signed integer Rx = Ry / Rz
            const registerIdX = current.instruction.data.s_div32.Rx;
            const registerIdY = current.instruction.data.s_div32.Ry;
            const registerIdZ = current.instruction.data.s_div32.Rz;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@divTrunc(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .s_div64 => { // 64-bit signed integer Rx = Ry / Rz
            const registerIdX = current.instruction.data.s_div64.Rx;
            const registerIdY = current.instruction.data.s_div64.Ry;
            const registerIdZ = current.instruction.data.s_div64.Rz;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@divTrunc(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .s_div8a => { // 8-bit signed integer Rx = I / Ry
            const registerIdX = current.instruction.data.s_div8a.Rx;
            const registerIdY = current.instruction.data.s_div8a.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.instruction.data.s_div8a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u8, @bitCast(@divTrunc(bitsZ, bitsY)));

            continue :dispatch try state.step(self);
        },
        .s_div16a => { // 16-bit signed integer Rx = I / Ry
            const registerIdX = current.instruction.data.s_div16a.Rx;
            const registerIdY = current.instruction.data.s_div16a.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.instruction.data.s_div16a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @bitCast(@divTrunc(bitsZ, bitsY)));

            continue :dispatch try state.step(self);
        },
        .s_div32a => { // 32-bit signed integer Rx = I / Ry
            const registerIdX = current.instruction.data.s_div32a.Rx;
            const registerIdY = current.instruction.data.s_div32a.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.instruction.data.s_div32a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@divTrunc(bitsZ, bitsY)));

            continue :dispatch try state.step(self);
        },
        .s_div64a => { // 64-bit signed integer Rx = I / Ry
            const registerIdX = current.instruction.data.s_div64a.Rx;
            const registerIdY = current.instruction.data.s_div64a.Ry;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@divTrunc(bitsZ, bitsY)));

            continue :dispatch try state.step(self);
        },
        .s_div8b => { // 8-bit signed integer Rx = Ry / I
            const registerIdX = current.instruction.data.s_div8b.Rx;
            const registerIdY = current.instruction.data.s_div8b.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.instruction.data.s_div8b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u8, @bitCast(@divTrunc(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .s_div16b => { // 16-bit signed integer Rx = Ry / I
            const registerIdX = current.instruction.data.s_div16b.Rx;
            const registerIdY = current.instruction.data.s_div16b.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.instruction.data.s_div16b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @bitCast(@divTrunc(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .s_div32b => { // 32-bit signed integer Rx = Ry / I
            const registerIdX = current.instruction.data.s_div32b.Rx;
            const registerIdY = current.instruction.data.s_div32b.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.instruction.data.s_div32b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@divTrunc(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .s_div64b => { // 64-bit signed integer Rx = Ry / I
            const registerIdX = current.instruction.data.s_div64b.Rx;
            const registerIdY = current.instruction.data.s_div64b.Ry;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@divTrunc(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },

        .u_rem8 => { // 8-bit unsigned integer Rx = Ry % Rz
            const registerIdX = current.instruction.data.u_rem8.Rx;
            const registerIdY = current.instruction.data.u_rem8.Ry;
            const registerIdZ = current.instruction.data.u_rem8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY % bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_rem16 => { // 16-bit unsigned integer Rx = Ry % Rz
            const registerIdX = current.instruction.data.u_rem16.Rx;
            const registerIdY = current.instruction.data.u_rem16.Ry;
            const registerIdZ = current.instruction.data.u_rem16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY % bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_rem32 => { // 32-bit unsigned integer Rx = Ry % Rz
            const registerIdX = current.instruction.data.u_rem32.Rx;
            const registerIdY = current.instruction.data.u_rem32.Ry;
            const registerIdZ = current.instruction.data.u_rem32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY % bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_rem64 => { // 64-bit unsigned integer Rx = Ry % Rz
            const registerIdX = current.instruction.data.u_rem64.Rx;
            const registerIdY = current.instruction.data.u_rem64.Ry;
            const registerIdZ = current.instruction.data.u_rem64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY % bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_rem8a => { // 8-bit unsigned integer Rx = I % Ry
            const registerIdX = current.instruction.data.u_rem8a.Rx;
            const registerIdY = current.instruction.data.u_rem8a.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.instruction.data.u_rem8a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ % bitsY;

            continue :dispatch try state.step(self);
        },
        .u_rem16a => { // 16-bit unsigned integer Rx = I % Ry
            const registerIdX = current.instruction.data.u_rem16a.Rx;
            const registerIdY = current.instruction.data.u_rem16a.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.instruction.data.u_rem16a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ % bitsY;

            continue :dispatch try state.step(self);
        },
        .u_rem32a => { // 32-bit unsigned integer Rx = I % Ry
            const registerIdX = current.instruction.data.u_rem32a.Rx;
            const registerIdY = current.instruction.data.u_rem32a.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.instruction.data.u_rem32a.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ % bitsY;

            continue :dispatch try state.step(self);
        },
        .u_rem64a => { // 64-bit unsigned integer Rx = I % Ry
            const registerIdX = current.instruction.data.u_rem64a.Rx;
            const registerIdY = current.instruction.data.u_rem64a.Ry;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ % bitsY;

            continue :dispatch try state.step(self);
        },
        .u_rem8b => { // 8-bit unsigned integer Rx = Ry % I
            const registerIdX = current.instruction.data.u_rem8b.Rx;
            const registerIdY = current.instruction.data.u_rem8b.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.instruction.data.u_rem8b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY % bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_rem16b => { // 16-bit unsigned integer Rx = Ry % I
            const registerIdX = current.instruction.data.u_rem16b.Rx;
            const registerIdY = current.instruction.data.u_rem16b.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.instruction.data.u_rem16b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY % bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_rem32b => { // 32-bit unsigned integer Rx = Ry % I
            const registerIdX = current.instruction.data.u_rem32b.Rx;
            const registerIdY = current.instruction.data.u_rem32b.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.instruction.data.u_rem32b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY % bitsZ;

            continue :dispatch try state.step(self);
        },
        .u_rem64b => { // 64-bit unsigned integer Rx = Ry % I
            const registerIdX = current.instruction.data.u_rem64b.Rx;
            const registerIdY = current.instruction.data.u_rem64b.Ry;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY % bitsZ;

            continue :dispatch try state.step(self);
        },
        .s_rem8 => { // 8-bit signed integer Rx = Ry % Rz
            const registerIdX = current.instruction.data.s_rem8.Rx;
            const registerIdY = current.instruction.data.s_rem8.Ry;
            const registerIdZ = current.instruction.data.s_rem8.Rz;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u8, @bitCast(@rem(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .s_rem16 => { // 16-bit signed integer Rx = Ry % Rz
            const registerIdX = current.instruction.data.s_rem16.Rx;
            const registerIdY = current.instruction.data.s_rem16.Ry;
            const registerIdZ = current.instruction.data.s_rem16.Rz;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @bitCast(@rem(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .s_rem32 => { // 32-bit signed integer Rx = Ry % Rz
            const registerIdX = current.instruction.data.s_rem32.Rx;
            const registerIdY = current.instruction.data.s_rem32.Ry;
            const registerIdZ = current.instruction.data.s_rem32.Rz;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@rem(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .s_rem64 => { // 64-bit signed integer Rx = Ry % Rz
            const registerIdX = current.instruction.data.s_rem64.Rx;
            const registerIdY = current.instruction.data.s_rem64.Ry;
            const registerIdZ = current.instruction.data.s_rem64.Rz;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@rem(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .s_rem8a => { // 8-bit signed integer Rx = I % Ry
            const registerIdX = current.instruction.data.s_rem8a.Rx;
            const registerIdY = current.instruction.data.s_rem8a.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.instruction.data.s_rem8a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u8, @bitCast(@rem(bitsZ, bitsY)));

            continue :dispatch try state.step(self);
        },
        .s_rem16a => { // 16-bit signed integer Rx = I % Ry
            const registerIdX = current.instruction.data.s_rem16a.Rx;
            const registerIdY = current.instruction.data.s_rem16a.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.instruction.data.s_rem16a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @bitCast(@rem(bitsZ, bitsY)));

            continue :dispatch try state.step(self);
        },
        .s_rem32a => { // 32-bit signed integer Rx = I % Ry
            const registerIdX = current.instruction.data.s_rem32a.Rx;
            const registerIdY = current.instruction.data.s_rem32a.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.instruction.data.s_rem32a.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@rem(bitsZ, bitsY)));

            continue :dispatch try state.step(self);
        },
        .s_rem64a => { // 64-bit signed integer Rx = I % Ry
            const registerIdX = current.instruction.data.s_rem64a.Rx;
            const registerIdY = current.instruction.data.s_rem64a.Ry;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@rem(bitsZ, bitsY)));

            continue :dispatch try state.step(self);
        },
        .s_rem8b => { // 8-bit signed integer Rx = Ry % I
            const registerIdX = current.instruction.data.s_rem8b.Rx;
            const registerIdY = current.instruction.data.s_rem8b.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.instruction.data.s_rem8b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u8, @bitCast(@rem(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .s_rem16b => { // 16-bit signed integer Rx = Ry % I
            const registerIdX = current.instruction.data.s_rem16b.Rx;
            const registerIdY = current.instruction.data.s_rem16b.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.instruction.data.s_rem16b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @bitCast(@rem(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .s_rem32b => { // 32-bit signed integer Rx = Ry % I
            const registerIdX = current.instruction.data.s_rem32b.Rx;
            const registerIdY = current.instruction.data.s_rem32b.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.instruction.data.s_rem32b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@rem(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .s_rem64b => { // 64-bit signed integer Rx = Ry % I
            const registerIdX = current.instruction.data.s_rem64b.Rx;
            const registerIdY = current.instruction.data.s_rem64b.Ry;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@rem(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },

        .i_pow8 => { // 8-bit integer Rx = Ry ** Rz
            const registerIdX = current.instruction.data.i_pow8.Rx;
            const registerIdY = current.instruction.data.i_pow8.Ry;
            const registerIdZ = current.instruction.data.i_pow8.Rz;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u8, @bitCast(std.math.powi(i8, bitsY, bitsZ) catch unreachable));

            continue :dispatch try state.step(self);
        },
        .i_pow16 => { // 16-bit integer Rx = Ry ** Rz
            const registerIdX = current.instruction.data.i_pow16.Rx;
            const registerIdY = current.instruction.data.i_pow16.Ry;
            const registerIdZ = current.instruction.data.i_pow16.Rz;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @bitCast(std.math.powi(i16, bitsY, bitsZ) catch unreachable));

            continue :dispatch try state.step(self);
        },
        .i_pow32 => { // 32-bit integer Rx = Ry ** Rz
            const registerIdX = current.instruction.data.i_pow32.Rx;
            const registerIdY = current.instruction.data.i_pow32.Ry;
            const registerIdZ = current.instruction.data.i_pow32.Rz;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(std.math.powi(i32, bitsY, bitsZ) catch unreachable));

            continue :dispatch try state.step(self);
        },
        .i_pow64 => { // 64-bit integer Rx = Ry ** Rz
            const registerIdX = current.instruction.data.i_pow64.Rx;
            const registerIdY = current.instruction.data.i_pow64.Ry;
            const registerIdZ = current.instruction.data.i_pow64.Rz;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(std.math.powi(i64, bitsY, bitsZ) catch unreachable));

            continue :dispatch try state.step(self);
        },
        .i_pow8a => { // 8-bit integer Rx = I ** Ry
            const registerIdX = current.instruction.data.i_pow8a.Rx;
            const registerIdY = current.instruction.data.i_pow8a.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.instruction.data.i_pow8a.I)));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u8, @bitCast(std.math.powi(i8, bitsY, bitsZ) catch unreachable));

            continue :dispatch try state.step(self);
        },
        .i_pow16a => { // 16-bit integer Rx = I ** Ry
            const registerIdX = current.instruction.data.i_pow16a.Rx;
            const registerIdY = current.instruction.data.i_pow16a.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.instruction.data.i_pow16a.I)));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @bitCast(std.math.powi(i16, bitsY, bitsZ) catch unreachable));

            continue :dispatch try state.step(self);
        },
        .i_pow32a => { // 32-bit integer Rx = I ** Ry
            const registerIdX = current.instruction.data.i_pow32a.Rx;
            const registerIdY = current.instruction.data.i_pow32a.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.instruction.data.i_pow32a.I)));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(std.math.powi(i32, bitsY, bitsZ) catch unreachable));

            continue :dispatch try state.step(self);
        },
        .i_pow64a => { // 64-bit integer Rx = I ** Ry
            const registerIdX = current.instruction.data.i_pow64a.Rx;
            const registerIdY = current.instruction.data.i_pow64a.Ry;

            const bitsY: i64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;
            const bitsZ: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(std.math.powi(i64, bitsY, bitsZ) catch unreachable));

            continue :dispatch try state.step(self);
        },
        .i_pow8b => { // 8-bit integer Rx = Ry ** I
            const registerIdX = current.instruction.data.i_pow8b.Rx;
            const registerIdY = current.instruction.data.i_pow8b.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i8 = @bitCast(@as(u8, @truncate(current.instruction.data.i_pow8b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u8, @bitCast(std.math.powi(i8, bitsY, bitsZ) catch unreachable));

            continue :dispatch try state.step(self);
        },
        .i_pow16b => { // 16-bit integer Rx = Ry ** I
            const registerIdX = current.instruction.data.i_pow16b.Rx;
            const registerIdY = current.instruction.data.i_pow16b.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i16 = @bitCast(@as(u16, @truncate(current.instruction.data.i_pow16b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @bitCast(std.math.powi(i16, bitsY, bitsZ) catch unreachable));

            continue :dispatch try state.step(self);
        },
        .i_pow32b => { // 32-bit integer Rx = Ry ** I
            const registerIdX = current.instruction.data.i_pow32b.Rx;
            const registerIdY = current.instruction.data.i_pow32b.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: i32 = @bitCast(@as(u32, @truncate(current.instruction.data.i_pow32b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(std.math.powi(i32, bitsY, bitsZ) catch unreachable));

            continue :dispatch try state.step(self);
        },
        .i_pow64b => { // 64-bit integer Rx = Ry ** I
            const registerIdX = current.instruction.data.i_pow64b.Rx;
            const registerIdY = current.instruction.data.i_pow64b.Ry;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(std.math.powi(i64, bitsY, bitsZ) catch unreachable));

            continue :dispatch try state.step(self);
        },

        .f_neg32 => { // 32-bit floating point Rx = -Ry
            const registerIdX = current.instruction.data.f_neg32.Rx;
            const registerIdY = current.instruction.data.f_neg32.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(-bitsY));

            continue :dispatch try state.step(self);
        },
        .f_neg64 => { // 64-bit floating point Rx = -Ry
            const registerIdX = current.instruction.data.f_neg64.Rx;
            const registerIdY = current.instruction.data.f_neg64.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(-bitsY));

            continue :dispatch try state.step(self);
        },

        .f_abs32 => { // 32-bit floating point Rx = |Ry|
            const registerIdX = current.instruction.data.f_abs32.Rx;
            const registerIdY = current.instruction.data.f_abs32.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@abs(bitsY)));

            continue :dispatch try state.step(self);
        },
        .f_abs64 => { // 64-bit floating point Rx = |Ry|
            const registerIdX = current.instruction.data.f_abs64.Rx;
            const registerIdY = current.instruction.data.f_abs64.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@abs(bitsY)));

            continue :dispatch try state.step(self);
        },

        .f_sqrt32 => { // 32-bit floating point Rx = sqrt(Ry)
            const registerIdX = current.instruction.data.f_sqrt32.Rx;
            const registerIdY = current.instruction.data.f_sqrt32.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(std.math.sqrt(bitsY)));

            continue :dispatch try state.step(self);
        },
        .f_sqrt64 => { // 64-bit floating point Rx = sqrt(Ry)
            const registerIdX = current.instruction.data.f_sqrt64.Rx;
            const registerIdY = current.instruction.data.f_sqrt64.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(std.math.sqrt(bitsY)));

            continue :dispatch try state.step(self);
        },

        .f_floor32 => { // 32-bit floating point Rx = floor(Ry)
            const registerIdX = current.instruction.data.f_floor32.Rx;
            const registerIdY = current.instruction.data.f_floor32.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@floor(bitsY)));

            continue :dispatch try state.step(self);
        },
        .f_floor64 => { // 64-bit floating point Rx = floor(Ry)
            const registerIdX = current.instruction.data.f_floor64.Rx;
            const registerIdY = current.instruction.data.f_floor64.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@floor(bitsY)));

            continue :dispatch try state.step(self);
        },

        .f_ceil32 => { // 32-bit floating point Rx = ceil(Ry)
            const registerIdX = current.instruction.data.f_ceil32.Rx;
            const registerIdY = current.instruction.data.f_ceil32.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@ceil(bitsY)));

            continue :dispatch try state.step(self);
        },
        .f_ceil64 => { // 64-bit floating point Rx = ceil(Ry)
            const registerIdX = current.instruction.data.f_ceil64.Rx;
            const registerIdY = current.instruction.data.f_ceil64.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@ceil(bitsY)));

            continue :dispatch try state.step(self);
        },

        .f_round32 => { // 32-bit floating point Rx = round(Ry)
            const registerIdX = current.instruction.data.f_round32.Rx;
            const registerIdY = current.instruction.data.f_round32.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@round(bitsY)));

            continue :dispatch try state.step(self);
        },
        .f_round64 => { // 64-bit floating point Rx = round(Ry)
            const registerIdX = current.instruction.data.f_round64.Rx;
            const registerIdY = current.instruction.data.f_round64.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@round(bitsY)));

            continue :dispatch try state.step(self);
        },

        .f_trunc32 => { // 32-bit floating point Rx = trunc(Ry)
            const registerIdX = current.instruction.data.f_trunc32.Rx;
            const registerIdY = current.instruction.data.f_trunc32.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@trunc(bitsY)));

            continue :dispatch try state.step(self);
        },
        .f_trunc64 => { // 64-bit floating point Rx = trunc(Ry)
            const registerIdX = current.instruction.data.f_trunc64.Rx;
            const registerIdY = current.instruction.data.f_trunc64.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@trunc(bitsY)));

            continue :dispatch try state.step(self);
        },

        .f_whole32 => { // extract the whole number part of a 32-bit float Rx = whole(Ry)
            const registerIdX = current.instruction.data.f_whole32.Rx;
            const registerIdY = current.instruction.data.f_whole32.Ry;

            const num: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(pl.whole(num)));

            continue :dispatch try state.step(self);
        },
        .f_whole64 => { // extract the whole number part of a 64-bit float Rx = whole(Ry)
            const registerIdX = current.instruction.data.f_whole64.Rx;
            const registerIdY = current.instruction.data.f_whole64.Ry;

            const num: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(pl.whole(num)));

            continue :dispatch try state.step(self);
        },

        .f_frac32 => { // extract the fractional part of a 32-bit float Rx = frac(Ry)
            const registerIdX = current.instruction.data.f_frac32.Rx;
            const registerIdY = current.instruction.data.f_frac32.Ry;

            const num: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(pl.frac(num)));

            continue :dispatch try state.step(self);
        },
        .f_frac64 => { // extract the fractional part of a 64-bit float Rx = frac(Ry)
            const registerIdX = current.instruction.data.f_frac64.Rx;
            const registerIdY = current.instruction.data.f_frac64.Ry;

            const num: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(pl.frac(num)));

            continue :dispatch try state.step(self);
        },

        .f_add32 => { // 32-bit floating point Rx = Ry + Rz
            const registerIdX = current.instruction.data.f_add32.Rx;
            const registerIdY = current.instruction.data.f_add32.Ry;
            const registerIdZ = current.instruction.data.f_add32.Rz;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(bitsY + bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_add32c => { // 32-bit floating point Rx = Ry + I
            const registerIdX = current.instruction.data.f_add32c.Rx;
            const registerIdY = current.instruction.data.f_add32c.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.instruction.data.f_add32c.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(bitsY + bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_add64 => { // 64-bit floating point Rx = Ry + Rz
            const registerIdX = current.instruction.data.f_add64.Rx;
            const registerIdY = current.instruction.data.f_add64.Ry;
            const registerIdZ = current.instruction.data.f_add64.Rz;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(bitsY + bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_add64c => { // 64-bit floating point Rx = Ry + I
            const registerIdX = current.instruction.data.f_add64c.Rx;
            const registerIdY = current.instruction.data.f_add64c.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(bitsY + bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_sub32 => { // 32-bit floating point Rx = Ry - Rz
            const registerIdX = current.instruction.data.f_sub32.Rx;
            const registerIdY = current.instruction.data.f_sub32.Ry;
            const registerIdZ = current.instruction.data.f_sub32.Rz;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(bitsY - bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_sub32a => { // 32-bit floating point Rx = I - Ry
            const registerIdX = current.instruction.data.f_sub32a.Rx;
            const registerIdY = current.instruction.data.f_sub32a.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.instruction.data.f_sub32a.I)));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(bitsY - bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_sub32b => { // 32-bit floating point Rx = Ry - I
            const registerIdX = current.instruction.data.f_sub32b.Rx;
            const registerIdY = current.instruction.data.f_sub32b.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.instruction.data.f_sub32b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(bitsY - bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_sub64 => { // 64-bit floating point Rx = Ry - Rz
            const registerIdX = current.instruction.data.f_sub64.Rx;
            const registerIdY = current.instruction.data.f_sub64.Ry;
            const registerIdZ = current.instruction.data.f_sub64.Rz;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(bitsY - bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_sub64a => { // 64-bit floating point Rx = I - Ry
            const registerIdX = current.instruction.data.f_sub64a.Rx;
            const registerIdY = current.instruction.data.f_sub64a.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;
            const bitsZ: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(bitsY - bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_sub64b => { // 64-bit floating point Rx = Ry - I
            const registerIdX = current.instruction.data.f_sub64b.Rx;
            const registerIdY = current.instruction.data.f_sub64b.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(bitsY - bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_mul32 => { // 32-bit floating point Rx = Ry * Rz
            const registerIdX = current.instruction.data.f_mul32.Rx;
            const registerIdY = current.instruction.data.f_mul32.Ry;
            const registerIdZ = current.instruction.data.f_mul32.Rz;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(bitsY * bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_mul32c => { // 32-bit floating point Rx = Ry * I
            const registerIdX = current.instruction.data.f_mul32c.Rx;
            const registerIdY = current.instruction.data.f_mul32c.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.instruction.data.f_mul32c.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(bitsY * bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_mul64 => { // 64-bit floating point Rx = Ry * Rz
            const registerIdX = current.instruction.data.f_mul64.Rx;
            const registerIdY = current.instruction.data.f_mul64.Ry;
            const registerIdZ = current.instruction.data.f_mul64.Rz;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(bitsY * bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_mul64c => { // 64-bit floating point Rx = Ry * I
            const registerIdX = current.instruction.data.f_mul64c.Rx;
            const registerIdY = current.instruction.data.f_mul64c.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(bitsY * bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_div32 => { // 32-bit floating point Rx = Ry / Rz
            const registerIdX = current.instruction.data.f_div32.Rx;
            const registerIdY = current.instruction.data.f_div32.Ry;
            const registerIdZ = current.instruction.data.f_div32.Rz;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(bitsY / bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_div32a => { // 32-bit floating point Rx = I / Ry
            const registerIdX = current.instruction.data.f_div32a.Rx;
            const registerIdY = current.instruction.data.f_div32a.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.instruction.data.f_div32a.I)));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(bitsY / bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_div32b => { // 32-bit floating point Rx = Ry / I
            const registerIdX = current.instruction.data.f_div32b.Rx;
            const registerIdY = current.instruction.data.f_div32b.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.instruction.data.f_div32b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(bitsY / bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_div64 => { // 64-bit floating point Rx = Ry / Rz
            const registerIdX = current.instruction.data.f_div64.Rx;
            const registerIdY = current.instruction.data.f_div64.Ry;
            const registerIdZ = current.instruction.data.f_div64.Rz;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(bitsY / bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_div64a => { // 64-bit floating point Rx = I / Ry
            const registerIdX = current.instruction.data.f_div64a.Rx;
            const registerIdY = current.instruction.data.f_div64a.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;
            const bitsZ: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(bitsY / bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_div64b => { // 64-bit floating point Rx = Ry / I
            const registerIdX = current.instruction.data.f_div64b.Rx;
            const registerIdY = current.instruction.data.f_div64b.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(bitsY / bitsZ));

            continue :dispatch try state.step(self);
        },
        .f_rem32 => { // 32-bit floating point Rx = Ry % Rz
            const registerIdX = current.instruction.data.f_rem32.Rx;
            const registerIdY = current.instruction.data.f_rem32.Ry;
            const registerIdZ = current.instruction.data.f_rem32.Rz;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@rem(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .f_rem32a => { // 32-bit floating point Rx = I % Ry
            const registerIdX = current.instruction.data.f_rem32a.Rx;
            const registerIdY = current.instruction.data.f_rem32a.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.instruction.data.f_rem32a.I)));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@rem(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .f_rem32b => { // 32-bit floating point Rx = Ry % I
            const registerIdX = current.instruction.data.f_rem32b.Rx;
            const registerIdY = current.instruction.data.f_rem32b.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.instruction.data.f_rem32b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@rem(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .f_rem64 => { // 64-bit floating point Rx = Ry % Rz
            const registerIdX = current.instruction.data.f_rem64.Rx;
            const registerIdY = current.instruction.data.f_rem64.Ry;
            const registerIdZ = current.instruction.data.f_rem64.Rz;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@rem(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .f_rem64a => { // 64-bit floating point Rx = I % Ry
            const registerIdX = current.instruction.data.f_rem64a.Rx;
            const registerIdY = current.instruction.data.f_rem64a.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;
            const bitsZ: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@rem(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .f_rem64b => { // 64-bit floating point Rx = Ry % I
            const registerIdX = current.instruction.data.f_rem64b.Rx;
            const registerIdY = current.instruction.data.f_rem64b.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@rem(bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .f_pow32 => { // 32-bit floating point Rx = Ry ** Rz
            const registerIdX = current.instruction.data.f_pow32.Rx;
            const registerIdY = current.instruction.data.f_pow32.Ry;
            const registerIdZ = current.instruction.data.f_pow32.Rz;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdZ.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(std.math.pow(f32, bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .f_pow32a => { // 32-bit floating point Rx = I ** Ry
            const registerIdX = current.instruction.data.f_pow32a.Rx;
            const registerIdY = current.instruction.data.f_pow32a.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.instruction.data.f_pow32a.I)));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(std.math.pow(f32, bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .f_pow32b => { // 32-bit floating point Rx = Ry ** I
            const registerIdX = current.instruction.data.f_pow32b.Rx;
            const registerIdY = current.instruction.data.f_pow32b.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: f32 = @bitCast(@as(u32, @truncate(current.instruction.data.f_pow32b.I)));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(std.math.pow(f32, bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .f_pow64 => { // 64-bit floating point Rx = Ry ** Rz
            const registerIdX = current.instruction.data.f_pow64.Rx;
            const registerIdY = current.instruction.data.f_pow64.Ry;
            const registerIdZ = current.instruction.data.f_pow64.Rz;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(std.math.pow(f64, bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .f_pow64a => { // 64-bit floating point Rx = I ** Ry
            const registerIdX = current.instruction.data.f_pow64a.Rx;
            const registerIdY = current.instruction.data.f_pow64a.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;
            const bitsZ: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(std.math.pow(f64, bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },
        .f_pow64b => { // 64-bit floating point Rx = Ry ** I
            const registerIdX = current.instruction.data.f_pow64b.Rx;
            const registerIdY = current.instruction.data.f_pow64b.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: f64 = @bitCast(current.callFrame.ip[0]);
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(std.math.pow(f64, bitsY, bitsZ)));

            continue :dispatch try state.step(self);
        },

        .s_ext8_16 => { // sign extension from 8-bit to 16-bit
            const registerIdX = current.instruction.data.s_ext8_16.Rx;
            const registerIdY = current.instruction.data.s_ext8_16.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @bitCast(@as(i16, @intCast(bitsY))));

            continue :dispatch try state.step(self);
        },
        .s_ext8_32 => { // sign extension from 8-bit to 32-bit
            const registerIdX = current.instruction.data.s_ext8_32.Rx;
            const registerIdY = current.instruction.data.s_ext8_32.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@as(i32, @intCast(bitsY))));

            continue :dispatch try state.step(self);
        },
        .s_ext8_64 => { // sign extension from 8-bit to 64-bit
            const registerIdX = current.instruction.data.s_ext8_64.Rx;
            const registerIdY = current.instruction.data.s_ext8_64.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@as(i64, @intCast(bitsY))));

            continue :dispatch try state.step(self);
        },
        .s_ext16_32 => { // sign extension from 16-bit to 32-bit
            const registerIdX = current.instruction.data.s_ext16_32.Rx;
            const registerIdY = current.instruction.data.s_ext16_32.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@as(i32, @intCast(bitsY))));

            continue :dispatch try state.step(self);
        },
        .s_ext16_64 => { // sign extension from 16-bit to 64-bit
            const registerIdX = current.instruction.data.s_ext16_64.Rx;
            const registerIdY = current.instruction.data.s_ext16_64.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@as(i64, @intCast(bitsY))));

            continue :dispatch try state.step(self);
        },
        .s_ext32_64 => { // sign extension from 32-bit to 64-bit
            const registerIdX = current.instruction.data.s_ext32_64.Rx;
            const registerIdY = current.instruction.data.s_ext32_64.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@as(i64, @intCast(bitsY))));

            continue :dispatch try state.step(self);
        },

        .f32_to_u8 => { // convert 32-bit float to 8-bit unsigned int
            const registerIdX = current.instruction.data.f32_to_u8.Rx;
            const registerIdY = current.instruction.data.f32_to_u8.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u8, @intFromFloat(bitsY));

            continue :dispatch try state.step(self);
        },
        .f32_to_u16 => { // convert 32-bit float to 16-bit unsigned int
            const registerIdX = current.instruction.data.f32_to_u16.Rx;
            const registerIdY = current.instruction.data.f32_to_u16.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @intFromFloat(bitsY));

            continue :dispatch try state.step(self);
        },
        .f32_to_u32 => { // convert 32-bit float to 32-bit unsigned int
            const registerIdX = current.instruction.data.f32_to_u32.Rx;
            const registerIdY = current.instruction.data.f32_to_u32.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @intFromFloat(bitsY));

            continue :dispatch try state.step(self);
        },
        .f32_to_u64 => { // convert 32-bit float to 64-bit unsigned int
            const registerIdX = current.instruction.data.f32_to_u64.Rx;
            const registerIdY = current.instruction.data.f32_to_u64.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @intFromFloat(bitsY));

            continue :dispatch try state.step(self);
        },
        .f32_to_s8 => { // convert 32-bit float to 8-bit signed int
            const registerIdX = current.instruction.data.f32_to_s8.Rx;
            const registerIdY = current.instruction.data.f32_to_s8.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u8, @bitCast(@as(i8, @intFromFloat(bitsY))));

            continue :dispatch try state.step(self);
        },
        .f32_to_s16 => { // convert 32-bit float to 16-bit signed int
            const registerIdX = current.instruction.data.f32_to_s16.Rx;
            const registerIdY = current.instruction.data.f32_to_s16.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @bitCast(@as(i16, @intFromFloat(bitsY))));

            continue :dispatch try state.step(self);
        },
        .f32_to_s32 => { // convert 32-bit float to 32-bit signed int
            const registerIdX = current.instruction.data.f32_to_s32.Rx;
            const registerIdY = current.instruction.data.f32_to_s32.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@as(i32, @intFromFloat(bitsY))));

            continue :dispatch try state.step(self);
        },
        .f32_to_s64 => { // convert 32-bit float to 64-bit signed int
            const registerIdX = current.instruction.data.f32_to_s64.Rx;
            const registerIdY = current.instruction.data.f32_to_s64.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@as(i64, @intFromFloat(bitsY))));

            continue :dispatch try state.step(self);
        },
        .u8_to_f32 => { // convert 8-bit unsigned int to 32-bit float
            const registerIdX = current.instruction.data.u8_to_f32.Rx;
            const registerIdY = current.instruction.data.u8_to_f32.Ry;

            const bitsY: u8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@as(f32, @floatFromInt(bitsY))));

            continue :dispatch try state.step(self);
        },
        .u16_to_f32 => { // convert 16-bit unsigned int to 32-bit float
            const registerIdX = current.instruction.data.u16_to_f32.Rx;
            const registerIdY = current.instruction.data.u16_to_f32.Ry;

            const bitsY: u16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@as(f32, @floatFromInt(bitsY))));

            continue :dispatch try state.step(self);
        },
        .u32_to_f32 => { // convert 32-bit unsigned int to 32-bit float
            const registerIdX = current.instruction.data.u32_to_f32.Rx;
            const registerIdY = current.instruction.data.u32_to_f32.Ry;

            const bitsY: u32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@as(f32, @floatFromInt(bitsY))));

            continue :dispatch try state.step(self);
        },
        .u64_to_f32 => { // convert 64-bit unsigned int to 32-bit float
            const registerIdX = current.instruction.data.u64_to_f32.Rx;
            const registerIdY = current.instruction.data.u64_to_f32.Ry;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@as(f32, @floatFromInt(bitsY))));

            continue :dispatch try state.step(self);
        },
        .s8_to_f32 => { // convert 8-bit signed int to 32-bit float
            const registerIdX = current.instruction.data.s8_to_f32.Rx;
            const registerIdY = current.instruction.data.s8_to_f32.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@as(f32, @floatFromInt(bitsY))));

            continue :dispatch try state.step(self);
        },
        .s16_to_f32 => { // convert 16-bit signed int to 32-bit float
            const registerIdX = current.instruction.data.s16_to_f32.Rx;
            const registerIdY = current.instruction.data.s16_to_f32.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@as(f32, @floatFromInt(bitsY))));

            continue :dispatch try state.step(self);
        },
        .s32_to_f32 => { // convert 32-bit signed int to 32-bit float
            const registerIdX = current.instruction.data.s32_to_f32.Rx;
            const registerIdY = current.instruction.data.s32_to_f32.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@as(f32, @floatFromInt(bitsY))));

            continue :dispatch try state.step(self);
        },
        .s64_to_f32 => { // convert 64-bit signed int to 32-bit float
            const registerIdX = current.instruction.data.s64_to_f32.Rx;
            const registerIdY = current.instruction.data.s64_to_f32.Ry;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@as(f32, @floatFromInt(bitsY))));

            continue :dispatch try state.step(self);
        },
        .u8_to_f64 => { // convert 8-bit unsigned int to 64-bit float
            const registerIdX = current.instruction.data.u8_to_f64.Rx;
            const registerIdY = current.instruction.data.u8_to_f64.Ry;

            const bitsY: u8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@as(f64, @floatFromInt(bitsY))));

            continue :dispatch try state.step(self);
        },
        .u16_to_f64 => { // convert 16-bit unsigned int to 64-bit float
            const registerIdX = current.instruction.data.u16_to_f64.Rx;
            const registerIdY = current.instruction.data.u16_to_f64.Ry;

            const bitsY: u16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@as(f64, @floatFromInt(bitsY))));

            continue :dispatch try state.step(self);
        },
        .u32_to_f64 => { // convert 32-bit unsigned int to 64-bit float
            const registerIdX = current.instruction.data.u32_to_f64.Rx;
            const registerIdY = current.instruction.data.u32_to_f64.Ry;

            const bitsY: u32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@as(f64, @floatFromInt(bitsY))));

            continue :dispatch try state.step(self);
        },
        .u64_to_f64 => { // convert 64-bit unsigned int to 64-bit float
            const registerIdX = current.instruction.data.u64_to_f64.Rx;
            const registerIdY = current.instruction.data.u64_to_f64.Ry;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@as(f64, @floatFromInt(bitsY))));

            continue :dispatch try state.step(self);
        },
        .s8_to_f64 => { // convert 8-bit signed int to 64-bit float
            const registerIdX = current.instruction.data.s8_to_f64.Rx;
            const registerIdY = current.instruction.data.s8_to_f64.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@as(f64, @floatFromInt(bitsY))));

            continue :dispatch try state.step(self);
        },
        .s16_to_f64 => { // convert 16-bit signed int to 64-bit float
            const registerIdX = current.instruction.data.s16_to_f64.Rx;
            const registerIdY = current.instruction.data.s16_to_f64.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@as(f64, @floatFromInt(bitsY))));

            continue :dispatch try state.step(self);
        },
        .s32_to_f64 => { // convert 32-bit signed int to 64-bit float
            const registerIdX = current.instruction.data.s32_to_f64.Rx;
            const registerIdY = current.instruction.data.s32_to_f64.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@as(f64, @floatFromInt(bitsY))));

            continue :dispatch try state.step(self);
        },
        .s64_to_f64 => { // convert 64-bit signed int to 64-bit float
            const registerIdX = current.instruction.data.s64_to_f64.Rx;
            const registerIdY = current.instruction.data.s64_to_f64.Ry;

            const bitsY: i64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@as(f64, @floatFromInt(bitsY))));

            continue :dispatch try state.step(self);
        },
        .f32_to_f64 => { // convert 32-bit float to 64-bit float
            const registerIdX = current.instruction.data.f32_to_f64.Rx;
            const registerIdY = current.instruction.data.f32_to_f64.Ry;

            const bitsY: f32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(@as(f64, @floatCast(bitsY))));

            continue :dispatch try state.step(self);
        },
        .f64_to_f32 => { // convert 64-bit float to 32-bit float
            const registerIdX = current.instruction.data.f64_to_f32.Rx;
            const registerIdY = current.instruction.data.f64_to_f32.Ry;

            const bitsY: f64 = @bitCast(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(@as(f32, @floatCast(bitsY))));

            continue :dispatch try state.step(self);
        },
    }
}
