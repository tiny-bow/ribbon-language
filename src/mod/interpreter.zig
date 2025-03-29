//! Provides interfaces for running code on a `core.Fiber`.
const interpreter = @This();

const core = @import("core");
const Instruction = @import("Instruction");
const pl = @import("platform");
const std = @import("std");

test {
    std.testing.refAllDeclsRecursive(@This());
}

pub fn invokeBuiltin(self: core.Fiber, evidence: ?*core.Evidence, fun: anytype, arguments: []const core.RegisterBits) core.Error!BuiltinResult {
    const T = @TypeOf(fun);
    // Because the allocated builtin is a packed structure with the pointer at the start, we can just truncate it.
    // To handle both cases, we cast to the bitsize of the input first and then truncate to the output.
    return invokeStaticBuiltin(self, evidence, @ptrFromInt(@as(u64, @truncate(@as(std.meta(.unsigned, @bitSizeOf(T)), @bitCast(fun))))), arguments);
}

/// Invokes a `core.AllocatedBuiltinFunction` on the provided fiber, returning the result.
pub fn invokeAllocatedBuiltin(self: core.Fiber, evidence: ?*core.Evidence, fun: core.AllocatedBuiltinFunction, arguments: []const core.RegisterBits) core.Error!BuiltinResult {
    return invokeStaticBuiltin(self, evidence, @ptrCast(fun.ptr), arguments);
}

/// The indicates the kind of control flow yield being performed by a builtin function.
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

            return .{ .@"return" = self.header.registers.popPtr()[comptime core.Register.native_ret.getIndex()],  };
        },

        .panic => @panic("An unexpected error occurred in native code; exiting"),

        .request_trap => error.FunctionTrapped,
        .overflow => error.Overflow,
        .underflow => error.Underflow,
    };
}

/// Invokes a `core.Function` on the provided fiber, returning the result.
pub fn invokeBytecode(self: core.Fiber, fun: *const core.Function, arguments: []const u64) core.Error!u64 {
    const HALT: core.InstructionAddr = &.{ 0x02 }; // TODO: switch on endian?

    if (!self.header.calls.hasSpace(2)) {
        return error.Overflow;
    }

    const newRegisters = self.header.registers.allocSlice(2);
    @memcpy(newRegisters[1][0..arguments.len], arguments);

    self.header.calls.pushSlice(&.{
        core.CallFrame {
            .function = undefined,
            .evidence = null,
            .data = self.header.data.top_ptr,
            .set_frame = self.header.sets.top(),
            .vregs = &newRegisters[0],
            .ip = HALT,
            .output = .scratch,
        },
        core.CallFrame {
            .function = @ptrCast(fun),
            .evidence = null,
            .data = self.header.data.top_ptr,
            .set_frame = self.header.sets.top(),
            .vregs = &newRegisters[1],
            .ip = fun.extents.base,
            .output = .native_ret,
        },
    });

    try eval(self, .skip_breakpoints);

    // second frame will have already been popped by the interpreter,
    // so we only pop 1 each here.
    self.header.calls.pop();
    const registers = self.header.registers.popMultiPtr(1);

    // we need to reach into the second register frame
    return registers[1][comptime core.Register.native_ret.getIndex()];
}

/// Passed to `eval`, indicates how to handle breakpoints in the interpreter loop.
pub const BreakpointMode = enum {
    /// Stop at breakpoints, and return to the caller.
    breakpoints_halt,
    /// Skip breakpoints and continue until halt.
    skip_breakpoints,
};

/// Run the interpreter loop until `halt`; and optionally stop at breakpoints.
pub fn eval(self: core.Fiber, comptime mode: BreakpointMode) core.Error!void {
    while (true) {
        run(true, self.header) catch |signalOrError| {
            if (comptime mode == .breakpoints_halt) {
                switch (signalOrError) {
                    LoopSignal.breakpoint => break,
                    else => |e| return e,
                }
            } else {
                switch (signalOrError) {
                    LoopSignal.breakpoint => continue,
                    else => |e| return e,
                }
            }
        };

        break;
    }
}



/// Signals that can be returned by the `step` function
pub const Signal = enum(i64) {
    @"return" = 0,
    cancel = 1,

    halt = -1,
    breakpoint = -2,
};

/// Run the interpreter loop for a single instruction.
pub fn step(self: core.Fiber) core.Error!?Signal {
    run(false, self.header) catch |signalOrError| {
        switch (signalOrError) {
            StepSignal.@"return" => return .@"return",
            StepSignal.cancel => return .cancel,
            StepSignal.breakpoint => return .breakpoint,
            StepSignal.step => return null,
            inline else => |e| return e,
        }
    };

    return .halt;
}

const StepSignal = error {
    step,
    breakpoint,
    @"return",
    cancel,
};

const LoopSignal = error {
    breakpoint,
};

fn SignalSubset(comptime isLoop: bool) type {
    return if (isLoop) LoopSignal else StepSignal;
}

fn run(comptime isLoop: bool, self: *core.mem.FiberHeader) (core.Error || SignalSubset(isLoop))!void {
    const State = struct {
        callFrame: *core.CallFrame,
        function: *const core.Function,
        stackFrame: []const core.RegisterBits,
        instruction: Instruction,
        tempRegisters: core.RegisterArray,

        fn decode(st: *@This(), header: *core.mem.FiberHeader) Instruction.OpCode {
            st.callFrame = header.calls.top();
            std.debug.assert(@intFromPtr(st.callFrame) >= @intFromPtr(header.calls.base));

            st.function = @ptrCast(@alignCast(st.callFrame.function));

            std.debug.assert(st.function.extents.boundsCheck(st.callFrame.ip));

            st.instruction = Instruction.fromBits(st.callFrame.ip[0]);

            st.callFrame.ip += 1;

            st.stackFrame = st.callFrame.data[0..st.function.stack_size];
            std.debug.assert(@intFromPtr(st.stackFrame.ptr) >= @intFromPtr(header.data.base));
            std.debug.assert(@intFromPtr(st.stackFrame.ptr + st.stackFrame.len) <= @intFromPtr(header.data.limit));

            return st.instruction.code;
        }

        fn advance(st: *@This(), header: *core.mem.FiberHeader, comptime signal: anyerror) SignalSubset(isLoop)!Instruction.OpCode {
            if (comptime isLoop) {
                return st.decode(header);
            } else {
                return @errorCast(signal);
            }
        }

        fn step(st: *@This(), header: *core.mem.FiberHeader) SignalSubset(isLoop)!Instruction.OpCode {
            return if (comptime isLoop) st.decode(header)
            else @errorFromInt(@intFromError(error.step));
        }
    };

    var state: State = undefined;
    const current = &state;

    dispatch: switch (current.decode(self)) {
        // No operation; does nothing
        .nop => continue :dispatch try state.step(self),
        // Triggers a breakpoint in debuggers; does nothing otherwise
        .@"breakpoint" => return StepSignal.breakpoint,
        // Halts execution at this instruction offset
        .halt => return,
        // Traps execution of the Rvm.Fiber at this instruction offset Unlike unreachable, this indicates expected behavior; optimizing compilers should not assume it is never reached
        .trap => return error.Unreachable,
        // Marks a point in the code as unreachable; if executed in Rvm, it is the same as trap Unlike trap, however, this indicates undefined behavior; optimizing compilers should assume it is never reached
        .@"unreachable" => return error.Unreachable,

        .@"push_set" => { // Pushes H onto the stack. The handlers in this set will be first in line for their effects' prompts until a corresponding pop operation
            if (!self.sets.hasSpace(1)) {
                @branchHint(.cold);
                return error.Overflow;
            }

            const handlerSetId = current.instruction.data.push_set.H;

            const handlerSet: *const core.HandlerSet = current.function.header.get(handlerSetId);

            const setFrame = self.sets.create(core.SetFrame {
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
        .@"pop_set" => { // Pops the top most Id.of(HandlerSet) from the stack, restoring the previous if present
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

        .@"br" => { // Applies a signed integer offset I to the instruction pointer
            const offset: core.InstructionOffset = @bitCast(current.instruction.data.br.I);
            std.debug.assert(offset != 0);

            const newIp: core.InstructionAddr = pl.offsetPointer(current.callFrame.ip, offset);
            std.debug.assert(pl.alignDelta(newIp, @alignOf(core.InstructionBits)) == 0);
            std.debug.assert(current.function.extents.boundsCheck(newIp));

            current.callFrame.ip = newIp;

            continue :dispatch try state.step(self);
        },
        .@"br_if" => { // Applies a signed integer offset I to the instruction pointer, if the value stored in R is non-zero
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

        .@"call" => { // Calls the function in Ry using A, placing the result in Rx
            const registerIdX = current.instruction.data.call.Rx;
            const registerIdY = current.instruction.data.call.Ry;
            const abi = current.instruction.data.call.A;
            const argumentCount = current.instruction.data.call.I;

            const functionOpaquePtr: *const anyopaque = @ptrFromInt(current.callFrame.vregs[registerIdY.getIndex()]);

            const newIp: core.InstructionAddr = pl.alignTo(pl.offsetPointer(current.callFrame.ip, argumentCount * @sizeOf(core.Register)), @alignOf(core.InstructionBits));
            std.debug.assert(current.function.extents.boundsCheck(newIp));
            current.callFrame.ip = newIp;

            const argumentRegisterIds = @as([*]const core.Register, @ptrCast(@alignCast(current.callFrame.ip)))[0..argumentCount];

            switch (abi) {
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
                        .output = registerIdX,
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
                        .@"return" => |retVal| current.callFrame.vregs[registerIdX.getIndex()] = retVal,
                    }
                },
                .foreign => {
                    if (argumentRegisterIds.len > pl.MAX_FOREIGN_ARGUMENTS) {
                        @branchHint(.cold);
                        return error.Overflow;
                    }

                    const arguments = current.tempRegisters[0..argumentRegisterIds.len];
                    for (argumentRegisterIds, 0..) |reg, i| {
                        arguments[i] = current.callFrame.vregs[reg.getIndex()];
                    }

                    const retVal = pl.callForeign(functionOpaquePtr, arguments);

                    current.callFrame.vregs[registerIdX.getIndex()] = retVal;
                },
            }

            continue :dispatch try state.step(self);
        },
        .@"call_c" => { // Calls the function at F using A, placing the result in R
            const registerId = current.instruction.data.call_c.R;
            const functionId = current.instruction.data.call_c.F.cast(anyopaque);
            const abi = current.instruction.data.call_c.A;
            const argumentCount = current.instruction.data.call_c.I;

            std.debug.assert(current.function.extents.boundsCheck(current.callFrame.ip + argumentCount * @sizeOf(core.Register)));
            const argumentRegisterIds = @as([*]const core.Register, @ptrCast(@alignCast(current.callFrame.ip)))[0..argumentCount];

            switch (abi) {
                .bytecode => {
                    const functionPtr = current.function.header.get(functionId.cast(core.Function));

                    if (@intFromBool(self.calls.hasSpace(1)) & @intFromBool(self.data.hasSpace(functionPtr.stack_size)) == 0) {
                        @branchHint(.cold);
                        return error.Overflow;
                    }

                    const data = self.data.allocSlice(functionPtr.stack_size);

                    const newRegisters = self.registers.allocPtr();

                    self.calls.push(core.CallFrame{
                        .function = functionPtr,
                        .evidence = null,
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
                    const functionPtr: *const core.BuiltinFunction = current.function.header.get(functionId.cast(core.BuiltinAddress)).asFunction();

                    const arguments = current.tempRegisters[0..argumentRegisterIds.len];
                    for (argumentRegisterIds, 0..) |reg, i| {
                        arguments[i] = current.callFrame.vregs[reg.getIndex()];
                    }

                    const result = try invokeStaticBuiltin(.{ .header = self }, null, functionPtr, arguments);
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
                .foreign => {
                    if (argumentRegisterIds.len > pl.MAX_FOREIGN_ARGUMENTS) {
                        @branchHint(.cold);
                        return error.Overflow;
                    }

                    const functionPtr = current.function.header.get(functionId.cast(core.ForeignAddress)).*;

                    const arguments = current.tempRegisters[0..argumentRegisterIds.len];
                    for (argumentRegisterIds, 0..) |reg, i| {
                        arguments[i] = current.callFrame.vregs[reg.getIndex()];
                    }

                    const retVal = pl.callForeign(functionPtr, arguments);

                    current.callFrame.vregs[registerId.getIndex()] = retVal;
                },
            }

            continue :dispatch try state.step(self);
        },

        .@"prompt" => { // Calls the effect handler designated by E using A, placing the result in R
            const registerId = current.instruction.data.prompt.R;
            const abi = current.instruction.data.prompt.A;
            const promptId = current.instruction.data.prompt.E;
            const argumentCount = current.instruction.data.prompt.I;

            const promptIndex = current.function.header.get(promptId).toIndex();

            const evidencePtr = self.evidence[promptIndex] orelse {
                @branchHint(.cold);
                return error.MissingEvidence;
            };

            const handler = evidencePtr.handler;

            std.debug.assert(current.function.extents.boundsCheck(current.callFrame.ip + argumentCount * @sizeOf(core.Register)));
            const argumentRegisterIds = @as([*]const core.Register, @ptrCast(@alignCast(current.callFrame.ip)))[0..argumentCount];

            switch (abi) {
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
                .foreign => {
                    // TODO: document the fact that we are not assuming the foreign function
                    // knows about prompting, and not passing it the evidence.
                    // TODO: re-evaluate if this is the best strategy for foreign prompt.
                    // it might be nicer to pass the evidence here; but this method allows
                    // code to classify arbitrary foreign functions as side effects;
                    // they just can never cancel or do anything contextual within the Ribbon fiber.
                    // Could potentially introduce another abi for "ribbon-aware foreign".
                    if (argumentRegisterIds.len > pl.MAX_FOREIGN_ARGUMENTS) {
                        @branchHint(.cold);
                        return error.Overflow;
                    }

                    const arguments = current.tempRegisters[0..argumentRegisterIds.len];
                    for (argumentRegisterIds, 0..) |reg, i| {
                        arguments[i] = current.callFrame.vregs[reg.getIndex()];
                    }

                    const functionPtr = handler.toPointer(core.ForeignAddress);

                    const retVal = pl.callForeign(functionPtr, arguments);

                    current.callFrame.vregs[registerId.getIndex()] = retVal;
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

            continue :dispatch try state.advance(self, StepSignal.@"return");
        },
        .@"cancel" => { // Returns flow control to the offset associated with the current effect handler's Id.of(HandlerSet), yielding R as the cancellation value
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

            continue :dispatch try state.advance(self, StepSignal.cancel);
        },


        // TODO: bounds check memory access
        .@"mem_set" => { // Each byte, starting from the address in Rx, up to an offset of Rz, is set to the least significant byte of Ry
            const registerIdX = current.instruction.data.mem_set.Rx;
            const registerIdY = current.instruction.data.mem_set.Ry;
            const registerIdZ = current.instruction.data.mem_set.Rz;

            const dest: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerIdX.getIndex()]);
            const src: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const size: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            @memset(dest[0..size], src);

            continue :dispatch try state.step(self);
        },
        .@"mem_set_a" => { // Each byte, starting from the address in Rx, up to an offset of I, is set to Ry
            const registerIdX = current.instruction.data.mem_set_a.Rx;
            const registerIdY = current.instruction.data.mem_set_a.Ry;
            const size: u32 = current.instruction.data.mem_set_a.I;

            const dest: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerIdX.getIndex()]);
            const src: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            @memset(dest[0..size], src);

            continue :dispatch try state.step(self);
        },
        .@"mem_set_b" => { // Each byte, starting from the address in Rx, up to an offset of Ry, is set to I
            const registerIdX = current.instruction.data.mem_set_b.Rx;
            const registerIdY = current.instruction.data.mem_set_b.Ry;
            const src: u8 = current.instruction.data.mem_set_b.I;

            const dest: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerIdX.getIndex()]);
            const size: u64 = current.callFrame.vregs[registerIdY.getIndex()];

            @memset(dest[0..size], src);

            continue :dispatch try state.step(self);
        },

        .@"mem_copy" => { // Each byte, starting from the address in Ry, up to an offset of Rz, is copied to the same offset of the address in Rx
            const registerIdX = current.instruction.data.mem_copy.Rx;
            const registerIdY = current.instruction.data.mem_copy.Ry;
            const registerIdZ = current.instruction.data.mem_copy.Rz;

            const dest: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerIdX.getIndex()]);
            const src: [*]const u8 = @ptrFromInt(current.callFrame.vregs[registerIdY.getIndex()]);
            const size: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            @memcpy(dest[0..size], src[0..size]);

            continue :dispatch try state.step(self);
        },
        .@"mem_copy_a" => { // Each byte, starting from the address in Ry, up to an offset of I, is copied to the same offset from the address in Rx
            const registerIdX = current.instruction.data.mem_copy_a.Rx;
            const registerIdY = current.instruction.data.mem_copy_a.Ry;
            const size: u32 = current.instruction.data.mem_copy_a.I;

            const dest: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerIdX.getIndex()]);
            const src: [*]const u8 = @ptrFromInt(current.callFrame.vregs[registerIdY.getIndex()]);

            @memcpy(dest[0..size], src[0..size]);

            continue :dispatch try state.step(self);
        },
        .@"mem_copy_b" => { // Each byte, starting from the address of C, up to an offset of Ry, is copied to the same offset from the address in Rx
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

        .@"mem_swap" => { // Each byte, starting from the addresses in Rx and Ry, up to an offset of Rz, are swapped with each-other
            const registerIdX = current.instruction.data.mem_swap.Rx;
            const registerIdY = current.instruction.data.mem_swap.Ry;
            const registerIdZ = current.instruction.data.mem_swap.Rz;

            const dest: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerIdX.getIndex()]);
            const src: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerIdY.getIndex()]);
            const size: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            // TODO: more efficient swap implementation
            for (src[0..size], dest[0..size]) |*srcByte, *destByte| {
                const tmp = srcByte.*;
                srcByte.* = destByte.*;
                destByte.* = tmp;
            }

            continue :dispatch try state.step(self);
        },
        .@"mem_swap_c" => { // Each byte, starting from the addresses in Rx and Ry, up to an offset of I, are swapped with each-other
            const registerIdX = current.instruction.data.mem_swap_c.Rx;
            const registerIdY = current.instruction.data.mem_swap_c.Ry;
            const size: u32 = current.instruction.data.mem_swap_c.I;

            const dest: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerIdX.getIndex()]);
            const src: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerIdY.getIndex()]);

            // TODO: more efficient swap implementation
            for (src[0..size], dest[0..size]) |*srcByte, *destByte| {
                const tmp = srcByte.*;
                srcByte.* = destByte.*;
                destByte.* = tmp;
            }

            continue :dispatch try state.step(self);
        },

        .@"addr_l" => { // Get the address of a signed integer frame-relative operand stack offset I, placing it in R.
            const registerId = current.instruction.data.addr_l.R;
            const offset: i32 = @bitCast(current.instruction.data.addr_l.I);

            const addr = pl.offsetPointer(current.stackFrame.ptr, offset);

            std.debug.assert(@intFromPtr(addr) >= @intFromPtr(self.data.base) and @intFromPtr(addr) <= @intFromPtr(self.data.limit));

            current.callFrame.vregs[registerId.getIndex()] = @intFromPtr(addr);

            continue :dispatch try state.step(self);
        },
        .@"addr_u" => { // Get the address of U, placing it in R
            const upvalueId = current.instruction.data.addr_u.U;
            const registerId = current.instruction.data.addr_u.R;

            pl.todo(noreturn, .{ "upvalue binding", upvalueId, registerId });
        },
        .@"addr_g" => { // Get the address of G, placing it in R
            const globalId = current.instruction.data.addr_g.G;
            const registerId = current.instruction.data.addr_g.R;

            const global: *const core.Global = current.function.header.get(globalId);

            current.callFrame.vregs[registerId.getIndex()] = global.ptr;

            continue :dispatch try state.step(self);
        },
        .@"addr_f" => { // Get the address of F, placing it in R
            const functionId = current.instruction.data.addr_f.F;
            const registerId = current.instruction.data.addr_f.R;

            const function: *const core.Function = current.function.header.get(functionId);

            current.callFrame.vregs[registerId.getIndex()] = @intFromPtr(function);

            continue :dispatch try state.step(self);
        },
        .@"addr_b" => { // Get the address of B, placing it in R
            const builtinId = current.instruction.data.addr_b.B;
            const registerId = current.instruction.data.addr_b.R;

            const builtin: *const core.BuiltinAddress = current.function.header.get(builtinId);

            current.callFrame.vregs[registerId.getIndex()] = @intFromPtr(builtin.asPointer());

            continue :dispatch try state.step(self);
        },
        .@"addr_x" => { // Get the address of X, placing it in R
            const foreignId = current.instruction.data.addr_x.X;
            const registerId = current.instruction.data.addr_x.R;

            const foreign: core.ForeignAddress = current.function.header.get(foreignId).*;

            current.callFrame.vregs[registerId.getIndex()] = @intFromPtr(foreign);

            continue :dispatch try state.step(self);
        },
        .@"addr_c" => { // Get the address of C, placing it in R
            const constantId = current.instruction.data.addr_c.C;
            const registerId = current.instruction.data.addr_c.R;

            const constant: *const core.Constant = current.function.header.get(constantId);

            current.callFrame.vregs[registerId.getIndex()] = constant.ptr;

            continue :dispatch try state.step(self);
        },

        .@"load8" => { // Loads an 8-bit value from memory at the address in Ry offset by I, placing the result in Rx
            const Rx = current.instruction.data.load8.Rx;
            const Ry = current.instruction.data.load8.Ry;
            const offset: i32 = @bitCast(current.instruction.data.load8.I);

            const srcBase: [*]const u8 = @ptrFromInt(current.callFrame.vregs[Ry.getIndex()]);
            const src = pl.offsetPointer(srcBase, offset);

            current.callFrame.vregs[Rx.getIndex()] = src[0];

            continue :dispatch try state.step(self);
        },
        .@"load16" => { // Loads a 16-bit value from memory at the address in Ry offset by I, placing the result in Rx
            const Rx = current.instruction.data.load16.Rx;
            const Ry = current.instruction.data.load16.Ry;
            const offset: i32 = @bitCast(current.instruction.data.load16.I);

            const srcBase: [*]const u16 = @ptrFromInt(current.callFrame.vregs[Ry.getIndex()]);
            const src = pl.offsetPointer(srcBase, offset);

            current.callFrame.vregs[Rx.getIndex()] = src[0];

            continue :dispatch try state.step(self);
        },
        .@"load32" => { // Loads a 32-bit value from memory at the address in Ry offset by I, placing the result in Rx
            const Rx = current.instruction.data.load32.Rx;
            const Ry = current.instruction.data.load32.Ry;
            const offset: i32 = @bitCast(current.instruction.data.load32.I);

            const srcBase: [*]const u32 = @ptrFromInt(current.callFrame.vregs[Ry.getIndex()]);
            const src = pl.offsetPointer(srcBase, offset);

            current.callFrame.vregs[Rx.getIndex()] = src[0];

            continue :dispatch try state.step(self);

        },
        .@"load64" => { // Loads a 64-bit value from memory at the address in Ry offset by I, placing the result in Rx
            const Rx = current.instruction.data.load64.Rx;
            const Ry = current.instruction.data.load64.Ry;
            const offset: i32 = @bitCast(current.instruction.data.load64.I);

            const srcBase: [*]const u64 = @ptrFromInt(current.callFrame.vregs[Ry.getIndex()]);
            const src = pl.offsetPointer(srcBase, offset);

            current.callFrame.vregs[Rx.getIndex()] = src[0];

            continue :dispatch try state.step(self);
        },

        .@"store8" => { // Stores an 8-bit value from Ry to memory at the address in Rx offset by I
            const Rx = current.instruction.data.store8.Rx;
            const Ry = current.instruction.data.store8.Ry;
            const offset: i32 = @bitCast(current.instruction.data.store8.I);

            const destBase: [*]u8 = @ptrFromInt(current.callFrame.vregs[Rx.getIndex()]);
            const dest = pl.offsetPointer(destBase, offset);

            dest[0] = @truncate(current.callFrame.vregs[Ry.getIndex()]);

            continue :dispatch try state.step(self);
        },
        .@"store16" => { // Stores a 16-bit value from Ry to memory at the address in Rx offset by I
            const Rx = current.instruction.data.store16.Rx;
            const Ry = current.instruction.data.store16.Ry;
            const offset: i32 = @bitCast(current.instruction.data.store16.I);

            const destBase: [*]u16 = @ptrFromInt(current.callFrame.vregs[Rx.getIndex()]);
            const dest = pl.offsetPointer(destBase, offset);

            dest[0] = @truncate(current.callFrame.vregs[Ry.getIndex()]);

            continue :dispatch try state.step(self);
        },
        .@"store32" => { // Stores a 32-bit value from Ry to memory at the address in Rx offset by I
            const Rx = current.instruction.data.store32.Rx;
            const Ry = current.instruction.data.store32.Ry;
            const offset: i32 = @bitCast(current.instruction.data.store32.I);

            const destBase: [*]u32 = @ptrFromInt(current.callFrame.vregs[Rx.getIndex()]);
            const dest = pl.offsetPointer(destBase, offset);

            dest[0] = @truncate(current.callFrame.vregs[Ry.getIndex()]);

            continue :dispatch try state.step(self);
        },
        .@"store64" => { // Stores a 64-bit value from Ry to memory at the address in Rx offset by I
            const Rx = current.instruction.data.store64.Rx;
            const Ry = current.instruction.data.store64.Ry;
            const offset: i32 = @bitCast(current.instruction.data.store64.I);

            const destBase: [*]u64 = @ptrFromInt(current.callFrame.vregs[Rx.getIndex()]);
            const dest = pl.offsetPointer(destBase, offset);

            dest[0] = @truncate(current.callFrame.vregs[Ry.getIndex()]);

            continue :dispatch try state.step(self);
        },
        .@"store8c" => { // Stores an 8-bit value (Ix) to memory at the address in R offset by Iy
            const registerId = current.instruction.data.store8c.R;
            const constant: u8 = current.instruction.data.store8c.Ix;
            const offset: i32 = @bitCast(current.instruction.data.store8c.Iy);

            const destBase: [*]u8 = @ptrFromInt(current.callFrame.vregs[registerId.getIndex()]);
            const dest = pl.offsetPointer(destBase, offset);

            dest[0] = constant;

            continue :dispatch try state.step(self);
        },
        .@"store16c" => { // Stores a 16-bit value (Ix) to memory at the address in R offset by Iy
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
        .@"store32c" => { // Stores a 32-bit value (Ix) to memory at the address in R offset by Iy
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
        .@"store64c" => { // Stores a 64-bit value (Iy) to memory at the address in R offset by Ix
            const registerId = current.instruction.data.store64c.R;
            const offset: i32 = @bitCast(current.instruction.data.store64c.Ix);

            const bits: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            const destBase: [*]u64 = @ptrFromInt(current.callFrame.vregs[registerId.getIndex()]);
            const dest = pl.offsetPointer(destBase, offset);

            dest[0] = bits;

            continue :dispatch try state.step(self);
        },


        .@"bit_swap8" => { // 8-bit Rx ⇔ Ry
            const registerIdX = current.instruction.data.bit_swap8.Rx;
            const registerIdY = current.instruction.data.bit_swap8.Ry;

            const a: *u8 = @ptrCast(&current.callFrame.vregs[registerIdX.getIndex()]);
            const b: *u8 = @ptrCast(&current.callFrame.vregs[registerIdY.getIndex()]);

            const tmp = a.*;
            a.* = b.*;
            b.* = tmp;

            continue :dispatch try state.step(self);
        },
        .@"bit_swap16" => { // 16-bit Rx ⇔ Ry
            const registerIdX = current.instruction.data.bit_swap16.Rx;
            const registerIdY = current.instruction.data.bit_swap16.Ry;

            const a: *u16 = @ptrCast(&current.callFrame.vregs[registerIdX.getIndex()]);
            const b: *u16 = @ptrCast(&current.callFrame.vregs[registerIdY.getIndex()]);

            const tmp = a.*;
            a.* = b.*;
            b.* = tmp;

            continue :dispatch try state.step(self);

        },
        .@"bit_swap32" => { // 32-bit Rx ⇔ Ry
            const registerIdX = current.instruction.data.bit_swap32.Rx;
            const registerIdY = current.instruction.data.bit_swap32.Ry;

            const a: *u32 = @ptrCast(&current.callFrame.vregs[registerIdX.getIndex()]);
            const b: *u32 = @ptrCast(&current.callFrame.vregs[registerIdY.getIndex()]);

            const tmp = a.*;
            a.* = b.*;
            b.* = tmp;

            continue :dispatch try state.step(self);
        },
        .@"bit_swap64" => {
            const registerIdX = current.instruction.data.bit_swap64.Rx;
            const registerIdY = current.instruction.data.bit_swap64.Ry;

            const a: *u64 = @ptrCast(&current.callFrame.vregs[registerIdX.getIndex()]);
            const b: *u64 = @ptrCast(&current.callFrame.vregs[registerIdY.getIndex()]);

            const tmp = a.*;
            a.* = b.*;
            b.* = tmp;

            continue :dispatch try state.step(self);
        },

        .@"bit_copy8" => { // 8-bit Rx = Ry
            const registerIdX = current.instruction.data.bit_copy8.Rx;
            const registerIdY = current.instruction.data.bit_copy8.Ry;

            const dst: *u8 = @ptrCast(&current.callFrame.vregs[registerIdX.getIndex()]);
            const src: *const u8 = @ptrCast(&current.callFrame.vregs[registerIdY.getIndex()]);

            dst.* = src.*;

            continue :dispatch try state.step(self);
        },
        .@"bit_copy16" => { // 16-bit Rx = Ry
            const registerIdX = current.instruction.data.bit_copy16.Rx;
            const registerIdY = current.instruction.data.bit_copy16.Ry;

            const dst: *u16 = @ptrCast(&current.callFrame.vregs[registerIdX.getIndex()]);
            const src: *const u16 = @ptrCast(&current.callFrame.vregs[registerIdY.getIndex()]);

            dst.* = src.*;

            continue :dispatch try state.step(self);
        },
        .@"bit_copy32" => { // 32-bit Rx = Ry
            const registerIdX = current.instruction.data.bit_copy32.Rx;
            const registerIdY = current.instruction.data.bit_copy32.Ry;

            const dst: *u32 = @ptrCast(&current.callFrame.vregs[registerIdX.getIndex()]);
            const src: *const u32 = @ptrCast(&current.callFrame.vregs[registerIdY.getIndex()]);

            dst.* = src.*;

            continue :dispatch try state.step(self);
        },
        .@"bit_copy64" => { // 64-bit Rx = Ry
            const registerIdX = current.instruction.data.bit_copy64.Rx;
            const registerIdY = current.instruction.data.bit_copy64.Ry;

            const dst: *u64 = &current.callFrame.vregs[registerIdX.getIndex()];
            const src: *const u64 = &current.callFrame.vregs[registerIdY.getIndex()];

            dst.* = src.*;
        },
        .@"bit_copy8c" => { // 8-bit R = I
            const registerId = current.instruction.data.bit_copy8c.R;
            const bits: u8 = current.instruction.data.bit_copy8c.I;

            current.callFrame.vregs[registerId.getIndex()] = bits;

            continue :dispatch try state.step(self);
        },
        .@"bit_copy16c" => { // 16-bit R = I
            const registerId = current.instruction.data.bit_copy16c.R;
            const bits: u16 = current.instruction.data.bit_copy16c.I;

            current.callFrame.vregs[registerId.getIndex()] = bits;

            continue :dispatch try state.step(self);
        },
        .@"bit_copy32c" => { // 32-bit R = I
            const registerId = current.instruction.data.bit_copy32c.R;
            const bits: u32 = current.instruction.data.bit_copy32c.I;

            current.callFrame.vregs[registerId.getIndex()] = bits;

            continue :dispatch try state.step(self);
        },
        .@"bit_copy64c" => { // 64-bit R = I
            const registerId = current.instruction.data.bit_copy64c.R;

            const bits: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerId.getIndex()] = bits;

            continue :dispatch try state.step(self);
        },

        .@"bit_clz8" => { // Counts the leading zeroes in 8-bits of Ry, placing the result in Rx
            const registerIdX = current.instruction.data.bit_clz8.Rx;
            const registerIdY = current.instruction.data.bit_clz8.Ry;

            const bits: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @clz(bits);

            continue :dispatch try state.step(self);
        },
        .@"bit_clz16" => { // Counts the leading zeroes in 16-bits of Ry, placing the result in Rx
            const registerIdX = current.instruction.data.bit_clz16.Rx;
            const registerIdY = current.instruction.data.bit_clz16.Ry;

            const bits: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @clz(bits);

            continue :dispatch try state.step(self);

        },
        .@"bit_clz32" => { // Counts the leading zeroes in 32-bits of Ry, placing the result in Rx
            const registerIdX = current.instruction.data.bit_clz32.Rx;
            const registerIdY = current.instruction.data.bit_clz32.Ry;

            const bits: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @clz(bits);

            continue :dispatch try state.step(self);
        },
        .@"bit_clz64" => { // Counts the leading zeroes in 64-bits of Ry, placing the result in Rx
            const registerIdX = current.instruction.data.bit_clz64.Rx;
            const registerIdY = current.instruction.data.bit_clz64.Ry;

            const bits: u64 = current.callFrame.vregs[registerIdY.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = @clz(bits);

            continue :dispatch try state.step(self);

        },

        .@"bit_pop8" => { // Counts the set bits in 8-bits of Ry, placing the result in Rx
            const registerIdX = current.instruction.data.bit_pop8.Rx;
            const registerIdY = current.instruction.data.bit_pop8.Ry;

            const bits: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @popCount(bits);

            continue :dispatch try state.step(self);
        },
        .@"bit_pop16" => { // Counts the set bits in 16-bits of Ry, placing the result in Rx
            const registerIdX = current.instruction.data.bit_pop16.Rx;
            const registerIdY = current.instruction.data.bit_pop16.Ry;

            const bits: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @popCount(bits);

            continue :dispatch try state.step(self);

        },
        .@"bit_pop32" => { // Counts the set bits in 32-bits of Ry, placing the result in Rx
            const registerIdX = current.instruction.data.bit_pop32.Rx;
            const registerIdY = current.instruction.data.bit_pop32.Ry;

            const bits: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @popCount(bits);

            continue :dispatch try state.step(self);
        },
        .@"bit_pop64" => { // Counts the set bits in 64-bits of Ry, placing the result in Rx
            const registerIdX = current.instruction.data.bit_pop64.Rx;
            const registerIdY = current.instruction.data.bit_pop64.Ry;

            const bits: u64 = current.callFrame.vregs[registerIdY.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = @popCount(bits);

            continue :dispatch try state.step(self);
        },

        .@"bit_not8" => { // 8-bit Rx = ~Ry
            const registerIdX = current.instruction.data.bit_not8.Rx;
            const registerIdY = current.instruction.data.bit_not8.Ry;

            const bits: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = ~bits;

            continue :dispatch try state.step(self);
        },
        .@"bit_not16" => { // 16-bit Rx = ~Ry
            const registerIdX = current.instruction.data.bit_not16.Rx;
            const registerIdY = current.instruction.data.bit_not16.Ry;

            const bits: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = ~bits;

            continue :dispatch try state.step(self);

        },
        .@"bit_not32" => { // 32-bit Rx = ~Ry
            const registerIdX = current.instruction.data.bit_not32.Rx;
            const registerIdY = current.instruction.data.bit_not32.Ry;

            const bits: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = ~bits;

            continue :dispatch try state.step(self);
        },
        .@"bit_not64" => { // 64-bit Rx = ~Ry
            const registerIdX = current.instruction.data.bit_not64.Rx;
            const registerIdY = current.instruction.data.bit_not64.Ry;

            const bits: u64 = current.callFrame.vregs[registerIdY.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = ~bits;

            continue :dispatch try state.step(self);
        },

        .@"bit_and8" => { // 8-bit Rx = Ry & Rz
            const registerIdX = current.instruction.data.bit_and8.Rx;
            const registerIdY = current.instruction.data.bit_and8.Ry;
            const registerIdZ = current.instruction.data.bit_and8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY & bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_and16" => { // 16-bit Rx = Ry & Rz
            const registerIdX = current.instruction.data.bit_and16.Rx;
            const registerIdY = current.instruction.data.bit_and16.Ry;
            const registerIdZ = current.instruction.data.bit_and16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY & bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_and32" => { // 32-bit Rx = Ry & Rz
            const registerIdX = current.instruction.data.bit_and32.Rx;
            const registerIdY = current.instruction.data.bit_and32.Ry;
            const registerIdZ = current.instruction.data.bit_and32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY & bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_and64" => { // 64-bit Rx = Ry & Rz
            const registerIdX = current.instruction.data.bit_and64.Rx;
            const registerIdY = current.instruction.data.bit_and64.Ry;
            const registerIdZ = current.instruction.data.bit_and64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY & bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_and8c" => { // 8-bit Rx = Ry & I
            const registerIdX = current.instruction.data.bit_and8c.Rx;
            const registerIdY = current.instruction.data.bit_and8c.Ry;
            const bitsZ: u8 = current.instruction.data.bit_and8c.I;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY & bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_and16c" => { // 16-bit Rx = Ry & I
            const registerIdX = current.instruction.data.bit_and16c.Rx;
            const registerIdY = current.instruction.data.bit_and16c.Ry;
            const bitsZ: u16 = current.instruction.data.bit_and16c.I;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY & bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_and32c" => { // 32-bit Rx = Ry & I
            const registerIdX = current.instruction.data.bit_and32c.Rx;
            const registerIdY = current.instruction.data.bit_and32c.Ry;
            const bitsZ: u32 = current.instruction.data.bit_and32c.I;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY & bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_and64c" => { // 64-bit Rx = Ry & I
            const registerIdX = current.instruction.data.bit_and64c.Rx;
            const registerIdY = current.instruction.data.bit_and64c.Ry;

            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY & bitsZ;

            continue :dispatch try state.step(self);
        },

        .@"bit_or8" => { // 8-bit Rx = Ry | Rz
            const registerIdX = current.instruction.data.bit_or8.Rx;
            const registerIdY = current.instruction.data.bit_or8.Ry;
            const registerIdZ = current.instruction.data.bit_or8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY | bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_or16" => { // 16-bit Rx = Ry | Rz
            const registerIdX = current.instruction.data.bit_or16.Rx;
            const registerIdY = current.instruction.data.bit_or16.Ry;
            const registerIdZ = current.instruction.data.bit_or16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY | bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_or32" => { // 32-bit Rx = Ry | Rz
            const registerIdX = current.instruction.data.bit_or32.Rx;
            const registerIdY = current.instruction.data.bit_or32.Ry;
            const registerIdZ = current.instruction.data.bit_or32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY | bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_or64" => { // 64-bit Rx = Ry | Rz
            const registerIdX = current.instruction.data.bit_or64.Rx;
            const registerIdY = current.instruction.data.bit_or64.Ry;
            const registerIdZ = current.instruction.data.bit_or64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY | bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_or8c" => { // 8-bit Rx = Ry | I
            const registerIdX = current.instruction.data.bit_or8c.Rx;
            const registerIdY = current.instruction.data.bit_or8c.Ry;
            const bitsZ: u8 = current.instruction.data.bit_or8c.I;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY | bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_or16c" => { // 16-bit Rx = Ry | I
            const registerIdX = current.instruction.data.bit_or16c.Rx;
            const registerIdY = current.instruction.data.bit_or16c.Ry;
            const bitsZ: u16 = current.instruction.data.bit_or16c.I;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY | bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_or32c" => { // 32-bit Rx = Ry | I
            const registerIdX = current.instruction.data.bit_or32c.Rx;
            const registerIdY = current.instruction.data.bit_or32c.Ry;
            const bitsZ: u32 = current.instruction.data.bit_or32c.I;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY | bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_or64c" => { // 64-bit Rx = Ry | I
            const registerIdX = current.instruction.data.bit_or64c.Rx;
            const registerIdY = current.instruction.data.bit_or64c.Ry;

            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY | bitsZ;

            continue :dispatch try state.step(self);
        },

        .@"bit_xor8" => { // 8-bit Rx = Ry ^ Rz
            const registerIdX = current.instruction.data.bit_xor8.Rx;
            const registerIdY = current.instruction.data.bit_xor8.Ry;
            const registerIdZ = current.instruction.data.bit_xor8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY ^ bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_xor16" => { // 16-bit Rx = Ry ^ Rz
            const registerIdX = current.instruction.data.bit_xor16.Rx;
            const registerIdY = current.instruction.data.bit_xor16.Ry;
            const registerIdZ = current.instruction.data.bit_xor16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY ^ bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_xor32" => { // 32-bit Rx = Ry ^ Rz
            const registerIdX = current.instruction.data.bit_xor32.Rx;
            const registerIdY = current.instruction.data.bit_xor32.Ry;
            const registerIdZ = current.instruction.data.bit_xor32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY ^ bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_xor64" => { // 64-bit Rx = Ry ^ Rz
            const registerIdX = current.instruction.data.bit_xor64.Rx;
            const registerIdY = current.instruction.data.bit_xor64.Ry;
            const registerIdZ = current.instruction.data.bit_xor64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u64 = current.callFrame.vregs[registerIdZ.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY ^ bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_xor8c" => { // 8-bit Rx = Ry ^ I
            const registerIdX = current.instruction.data.bit_xor8c.Rx;
            const registerIdY = current.instruction.data.bit_xor8c.Ry;
            const bitsZ: u8 = current.instruction.data.bit_xor8c.I;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY ^ bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_xor16c" => { // 16-bit Rx = Ry ^ I
            const registerIdX = current.instruction.data.bit_xor16c.Rx;
            const registerIdY = current.instruction.data.bit_xor16c.Ry;
            const bitsZ: u16 = current.instruction.data.bit_xor16c.I;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY ^ bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_xor32c" => { // 32-bit Rx = Ry ^ I
            const registerIdX = current.instruction.data.bit_xor32c.Rx;
            const registerIdY = current.instruction.data.bit_xor32c.Ry;
            const bitsZ: u32 = current.instruction.data.bit_xor32c.I;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY ^ bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_xor64c" => { // 64-bit Rx = Ry ^ I
            const registerIdX = current.instruction.data.bit_xor64c.Rx;
            const registerIdY = current.instruction.data.bit_xor64c.Ry;

            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY ^ bitsZ;

            continue :dispatch try state.step(self);
        },

        .@"bit_lshift8" => { // 8-bit Rx = Ry << Rz
            const registerIdX = current.instruction.data.bit_lshift8.Rx;
            const registerIdY = current.instruction.data.bit_lshift8.Ry;
            const registerIdZ = current.instruction.data.bit_lshift8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u3 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY << bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_lshift16" => { // 16-bit Rx = Ry << Rz
            const registerIdX = current.instruction.data.bit_lshift16.Rx;
            const registerIdY = current.instruction.data.bit_lshift16.Ry;
            const registerIdZ = current.instruction.data.bit_lshift16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u4 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY << bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_lshift32" => { // 32-bit Rx = Ry << Rz
            const registerIdX = current.instruction.data.bit_lshift32.Rx;
            const registerIdY = current.instruction.data.bit_lshift32.Ry;
            const registerIdZ = current.instruction.data.bit_lshift32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u5 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY << bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_lshift64" => { // 64-bit Rx = Ry << Rz
            const registerIdX = current.instruction.data.bit_lshift64.Rx;
            const registerIdY = current.instruction.data.bit_lshift64.Ry;
            const registerIdZ = current.instruction.data.bit_lshift64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u6 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY << bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_lshift8a" => { // 8-bit Rx = I << Ry
            const registerIdX = current.instruction.data.bit_lshift8a.Rx;
            const registerIdY = current.instruction.data.bit_lshift8a.Ry;

            const bitsY: u3 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = current.instruction.data.bit_lshift8a.I;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ << bitsY;

            continue :dispatch try state.step(self);
        },
        .@"bit_lshift16a" => { // 16-bit Rx = I << Ry
            const registerIdX = current.instruction.data.bit_lshift16a.Rx;
            const registerIdY = current.instruction.data.bit_lshift16a.Ry;

            const bitsY: u4 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = current.instruction.data.bit_lshift16a.I;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ << bitsY;

            continue :dispatch try state.step(self);
        },
        .@"bit_lshift32a" => { // 32-bit Rx = I << Ry
            const registerIdX = current.instruction.data.bit_lshift32a.Rx;
            const registerIdY = current.instruction.data.bit_lshift32a.Ry;

            const bitsY: u5 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = current.instruction.data.bit_lshift32a.I;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ << bitsY;

            continue :dispatch try state.step(self);
        },
        .@"bit_lshift64a" => { // 64-bit Rx = I << Ry
            const registerIdX = current.instruction.data.bit_lshift64a.Rx;
            const registerIdY = current.instruction.data.bit_lshift64a.Ry;

            const bitsY: u6 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ << bitsY;

            continue :dispatch try state.step(self);
        },
        .@"bit_lshift8b" => { // 8-bit Rx = Ry << I
            const registerIdX = current.instruction.data.bit_lshift8b.Rx;
            const registerIdY = current.instruction.data.bit_lshift8b.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u3 = @truncate(current.instruction.data.bit_lshift8b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY << bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_lshift16b" => { // 16-bit Rx = Ry << I
            const registerIdX = current.instruction.data.bit_lshift16b.Rx;
            const registerIdY = current.instruction.data.bit_lshift16b.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u4 = @truncate(current.instruction.data.bit_lshift16b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY << bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_lshift32b" => { // 32-bit Rx = Ry << I
            const registerIdX = current.instruction.data.bit_lshift32b.Rx;
            const registerIdY = current.instruction.data.bit_lshift32b.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u5 = @truncate(current.instruction.data.bit_lshift32b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY << bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"bit_lshift64b" => { // 64-bit Rx = Ry << I
            const registerIdX = current.instruction.data.bit_lshift64b.Rx;
            const registerIdY = current.instruction.data.bit_lshift64b.Ry;

            const bitsY: u64 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u6 = @truncate(current.instruction.data.bit_lshift64b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY << bitsZ;

            continue :dispatch try state.step(self);
        },

        .@"u_rshift8" => { // 8-bit unsigned/logical Rx = Ry >> Rz
            const registerIdX = current.instruction.data.u_rshift8.Rx;
            const registerIdY = current.instruction.data.u_rshift8.Ry;
            const registerIdZ = current.instruction.data.u_rshift8.Rz;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u3 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY >> bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"u_rshift16" => { // 16-bit unsigned/logical Rx = Ry >> Rz
            const registerIdX = current.instruction.data.u_rshift16.Rx;
            const registerIdY = current.instruction.data.u_rshift16.Ry;
            const registerIdZ = current.instruction.data.u_rshift16.Rz;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u4 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY >> bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"u_rshift32" => { // 32-bit unsigned/logical Rx = Ry >> Rz
            const registerIdX = current.instruction.data.u_rshift32.Rx;
            const registerIdY = current.instruction.data.u_rshift32.Ry;
            const registerIdZ = current.instruction.data.u_rshift32.Rz;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u5 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY >> bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"u_rshift64" => { // 64-bit unsigned/logical Rx = Ry >> Rz
            const registerIdX = current.instruction.data.u_rshift64.Rx;
            const registerIdY = current.instruction.data.u_rshift64.Ry;
            const registerIdZ = current.instruction.data.u_rshift64.Rz;

            const bitsY: u64 = current.callFrame.vregs[registerIdY.getIndex()];
            const bitsZ: u6 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY >> bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"u_rshift8a" => { // 8-bit unsigned/logical Rx = I >> Ry
            const registerIdX = current.instruction.data.u_rshift8a.Rx;
            const registerIdY = current.instruction.data.u_rshift8a.Ry;

            const bitsY: u3 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u8 = current.instruction.data.u_rshift8a.I;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ >> bitsY;

            continue :dispatch try state.step(self);
        },
        .@"u_rshift16a" => { // 16-bit unsigned/logical Rx = I >> Ry
            const registerIdX = current.instruction.data.u_rshift16a.Rx;
            const registerIdY = current.instruction.data.u_rshift16a.Ry;

            const bitsY: u4 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u16 = current.instruction.data.u_rshift16a.I;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ >> bitsY;

            continue :dispatch try state.step(self);
        },
        .@"u_rshift32a" => { // 32-bit unsigned/logical Rx = I >> Ry
            const registerIdX = current.instruction.data.u_rshift32a.Rx;
            const registerIdY = current.instruction.data.u_rshift32a.Ry;

            const bitsY: u5 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u32 = current.instruction.data.u_rshift32a.I;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ >> bitsY;

            continue :dispatch try state.step(self);
        },
        .@"u_rshift64a" => { // 64-bit unsigned/logical Rx = I >> Ry
            const registerIdX = current.instruction.data.u_rshift64a.Rx;
            const registerIdY = current.instruction.data.u_rshift64a.Ry;

            const bitsY: u6 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u64 = current.callFrame.ip[0];
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = bitsZ >> bitsY;

            continue :dispatch try state.step(self);
        },
        .@"u_rshift8b" => { // 8-bit unsigned/logical Rx = Ry >> I
            const registerIdX = current.instruction.data.u_rshift8b.Rx;
            const registerIdY = current.instruction.data.u_rshift8b.Ry;

            const bitsY: u8 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u3 = @truncate(current.instruction.data.u_rshift8b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY >> bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"u_rshift16b" => { // 16-bit unsigned/logical Rx = Ry >> I
            const registerIdX = current.instruction.data.u_rshift16b.Rx;
            const registerIdY = current.instruction.data.u_rshift16b.Ry;

            const bitsY: u16 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u4 = @truncate(current.instruction.data.u_rshift16b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY >> bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"u_rshift32b" => { // 32-bit unsigned/logical Rx = Ry >> I
            const registerIdX = current.instruction.data.u_rshift32b.Rx;
            const registerIdY = current.instruction.data.u_rshift32b.Ry;

            const bitsY: u32 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u5 = @truncate(current.instruction.data.u_rshift32b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY >> bitsZ;

            continue :dispatch try state.step(self);
        },
        .@"u_rshift64b" => { // 64-bit unsigned/logical Rx = Ry >> I
            const registerIdX = current.instruction.data.u_rshift64b.Rx;
            const registerIdY = current.instruction.data.u_rshift64b.Ry;

            const bitsY: u64 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: u6 = @truncate(current.instruction.data.u_rshift64b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = bitsY >> bitsZ;

            continue :dispatch try state.step(self);
        },

        .@"s_rshift8" => { // 8-bit signed/arithmetic Rx = Ry >> Rz
            const registerIdX = current.instruction.data.s_rshift8.Rx;
            const registerIdY = current.instruction.data.s_rshift8.Ry;
            const registerIdZ = current.instruction.data.s_rshift8.Rz;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: u3 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u8, @bitCast(bitsY >> bitsZ));

            continue :dispatch try state.step(self);
        },
        .@"s_rshift16" => { // 16-bit signed/arithmetic Rx = Ry >> Rz
            const registerIdX = current.instruction.data.s_rshift16.Rx;
            const registerIdY = current.instruction.data.s_rshift16.Ry;
            const registerIdZ = current.instruction.data.s_rshift16.Rz;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: u4 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @bitCast(bitsY >> bitsZ));

            continue :dispatch try state.step(self);
        },
        .@"s_rshift32" => { // 32-bit signed/arithmetic Rx = Ry >> Rz
            const registerIdX = current.instruction.data.s_rshift32.Rx;
            const registerIdY = current.instruction.data.s_rshift32.Ry;
            const registerIdZ = current.instruction.data.s_rshift32.Rz;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: u5 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(bitsY >> bitsZ));

            continue :dispatch try state.step(self);
        },
        .@"s_rshift64" => { // 64-bit signed/arithmetic Rx = Ry >> Rz
            const registerIdX = current.instruction.data.s_rshift64.Rx;
            const registerIdY = current.instruction.data.s_rshift64.Ry;
            const registerIdZ = current.instruction.data.s_rshift64.Rz;

            const bitsY: i64 = @bitCast(@as(u64, current.callFrame.vregs[registerIdY.getIndex()]));
            const bitsZ: u6 = @truncate(current.callFrame.vregs[registerIdZ.getIndex()]);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(bitsY >> bitsZ));

            continue :dispatch try state.step(self);
        },
        .@"s_rshift8a" => { // 8-bit signed/arithmetic Rx = I >> Ry
            const registerIdX = current.instruction.data.s_rshift8a.Rx;
            const registerIdY = current.instruction.data.s_rshift8a.Ry;

            const bitsY: u3 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i8 = @bitCast(@as(u8, current.instruction.data.s_rshift8a.I));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u8, @bitCast(bitsZ >> bitsY));

            continue :dispatch try state.step(self);
        },
        .@"s_rshift16a" => { // 16-bit signed/arithmetic Rx = I >> Ry
            const registerIdX = current.instruction.data.s_rshift16a.Rx;
            const registerIdY = current.instruction.data.s_rshift16a.Ry;

            const bitsY: u4 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i16 = @bitCast(@as(u16, current.instruction.data.s_rshift16a.I));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @bitCast(bitsZ >> bitsY));

            continue :dispatch try state.step(self);
        },
        .@"s_rshift32a" => { // 32-bit signed/arithmetic Rx = I >> Ry
            const registerIdX = current.instruction.data.s_rshift32a.Rx;
            const registerIdY = current.instruction.data.s_rshift32a.Ry;

            const bitsY: u5 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i32 = @bitCast(@as(u32, current.instruction.data.s_rshift32a.I));

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(bitsZ >> bitsY));

            continue :dispatch try state.step(self);
        },
        .@"s_rshift64a" => { // 64-bit signed/arithmetic Rx = I >> Ry
            const registerIdX = current.instruction.data.s_rshift64a.Rx;
            const registerIdY = current.instruction.data.s_rshift64a.Ry;

            const bitsY: u6 = @truncate(current.callFrame.vregs[registerIdY.getIndex()]);
            const bitsZ: i64 = @bitCast(@as(u64, current.callFrame.ip[0]));
            current.callFrame.ip += 1;

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(bitsZ >> bitsY));

            continue :dispatch try state.step(self);
        },
        .@"s_rshift8b" => { // 8-bit signed/arithmetic Rx = Ry >> I
            const registerIdX = current.instruction.data.s_rshift8b.Rx;
            const registerIdY = current.instruction.data.s_rshift8b.Ry;

            const bitsY: i8 = @bitCast(@as(u8, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: u3 = @truncate(current.instruction.data.s_rshift8b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u8, @bitCast(bitsY >> bitsZ));

            continue :dispatch try state.step(self);
        },
        .@"s_rshift16b" => { // 16-bit signed/arithmetic Rx = Ry >> I
            const registerIdX = current.instruction.data.s_rshift16b.Rx;
            const registerIdY = current.instruction.data.s_rshift16b.Ry;

            const bitsY: i16 = @bitCast(@as(u16, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: u4 = @truncate(current.instruction.data.s_rshift16b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u16, @bitCast(bitsY >> bitsZ));

            continue :dispatch try state.step(self);
        },
        .@"s_rshift32b" => { // 32-bit signed/arithmetic Rx = Ry >> I
            const registerIdX = current.instruction.data.s_rshift32b.Rx;
            const registerIdY = current.instruction.data.s_rshift32b.Ry;

            const bitsY: i32 = @bitCast(@as(u32, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: u5 = @truncate(current.instruction.data.s_rshift32b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u32, @bitCast(bitsY >> bitsZ));

            continue :dispatch try state.step(self);
        },
        .@"s_rshift64b" => { // 64-bit signed/arithmetic Rx = Ry >> I
            const registerIdX = current.instruction.data.s_rshift64b.Rx;
            const registerIdY = current.instruction.data.s_rshift64b.Ry;

            const bitsY: i64 = @bitCast(@as(u64, @truncate(current.callFrame.vregs[registerIdY.getIndex()])));
            const bitsZ: u6 = @truncate(current.instruction.data.s_rshift64b.I);

            current.callFrame.vregs[registerIdX.getIndex()] = @as(u64, @bitCast(bitsY >> bitsZ));

            continue :dispatch try state.step(self);
        },

        .@"i_eq8" => pl.todo(noreturn, "i_eq8"),
        .@"i_eq16" => pl.todo(noreturn, "i_eq16"),
        .@"i_eq32" => pl.todo(noreturn, "i_eq32"),
        .@"i_eq64" => pl.todo(noreturn, "i_eq64"),
        .@"i_eq8c" => pl.todo(noreturn, "i_eq8c"),
        .@"i_eq16c" => pl.todo(noreturn, "i_eq16c"),
        .@"i_eq32c" => pl.todo(noreturn, "i_eq32c"),
        .@"i_eq64c" => pl.todo(noreturn, "i_eq64c"),
        .@"f_eq32" => pl.todo(noreturn, "f_eq32"),
        .@"f_eq32c" => pl.todo(noreturn, "f_eq32c"),
        .@"f_eq64" => pl.todo(noreturn, "f_eq64"),
        .@"f_eq64c" => pl.todo(noreturn, "f_eq64c"),
        .@"i_ne8" => pl.todo(noreturn, "i_ne8"),
        .@"i_ne16" => pl.todo(noreturn, "i_ne16"),
        .@"i_ne32" => pl.todo(noreturn, "i_ne32"),
        .@"i_ne64" => pl.todo(noreturn, "i_ne64"),
        .@"i_ne8c" => pl.todo(noreturn, "i_ne8c"),
        .@"i_ne16c" => pl.todo(noreturn, "i_ne16c"),
        .@"i_ne32c" => pl.todo(noreturn, "i_ne32c"),
        .@"i_ne64c" => pl.todo(noreturn, "i_ne64c"),
        .@"f_ne32" => pl.todo(noreturn, "f_ne32"),
        .@"f_ne32c" => pl.todo(noreturn, "f_ne32c"),
        .@"f_ne64" => pl.todo(noreturn, "f_ne64"),
        .@"f_ne64c" => pl.todo(noreturn, "f_ne64c"),
        .@"u_lt8" => pl.todo(noreturn, "u_lt8"),
        .@"u_lt16" => pl.todo(noreturn, "u_lt16"),
        .@"u_lt32" => pl.todo(noreturn, "u_lt32"),
        .@"u_lt64" => pl.todo(noreturn, "u_lt64"),
        .@"u_lt8a" => pl.todo(noreturn, "u_lt8a"),
        .@"u_lt16a" => pl.todo(noreturn, "u_lt16a"),
        .@"u_lt32a" => pl.todo(noreturn, "u_lt32a"),
        .@"u_lt64a" => pl.todo(noreturn, "u_lt64a"),
        .@"u_lt8b" => pl.todo(noreturn, "u_lt8b"),
        .@"u_lt16b" => pl.todo(noreturn, "u_lt16b"),
        .@"u_lt32b" => pl.todo(noreturn, "u_lt32b"),
        .@"u_lt64b" => pl.todo(noreturn, "u_lt64b"),
        .@"s_lt8" => pl.todo(noreturn, "s_lt8"),
        .@"s_lt16" => pl.todo(noreturn, "s_lt16"),
        .@"s_lt32" => pl.todo(noreturn, "s_lt32"),
        .@"s_lt64" => pl.todo(noreturn, "s_lt64"),
        .@"s_lt8a" => pl.todo(noreturn, "s_lt8a"),
        .@"s_lt16a" => pl.todo(noreturn, "s_lt16a"),
        .@"s_lt32a" => pl.todo(noreturn, "s_lt32a"),
        .@"s_lt64a" => pl.todo(noreturn, "s_lt64a"),
        .@"s_lt8b" => pl.todo(noreturn, "s_lt8b"),
        .@"s_lt16b" => pl.todo(noreturn, "s_lt16b"),
        .@"s_lt32b" => pl.todo(noreturn, "s_lt32b"),
        .@"s_lt64b" => pl.todo(noreturn, "s_lt64b"),
        .@"f_lt32" => pl.todo(noreturn, "f_lt32"),
        .@"f_lt32a" => pl.todo(noreturn, "f_lt32a"),
        .@"f_lt32b" => pl.todo(noreturn, "f_lt32b"),
        .@"f_lt64" => pl.todo(noreturn, "f_lt64"),
        .@"f_lt64a" => pl.todo(noreturn, "f_lt64a"),
        .@"f_lt64b" => pl.todo(noreturn, "f_lt64b"),
        .@"u_gt8" => pl.todo(noreturn, "u_gt8"),
        .@"u_gt16" => pl.todo(noreturn, "u_gt16"),
        .@"u_gt32" => pl.todo(noreturn, "u_gt32"),
        .@"u_gt64" => pl.todo(noreturn, "u_gt64"),
        .@"u_gt8a" => pl.todo(noreturn, "u_gt8a"),
        .@"u_gt16a" => pl.todo(noreturn, "u_gt16a"),
        .@"u_gt32a" => pl.todo(noreturn, "u_gt32a"),
        .@"u_gt64a" => pl.todo(noreturn, "u_gt64a"),
        .@"u_gt8b" => pl.todo(noreturn, "u_gt8b"),
        .@"u_gt16b" => pl.todo(noreturn, "u_gt16b"),
        .@"u_gt32b" => pl.todo(noreturn, "u_gt32b"),
        .@"u_gt64b" => pl.todo(noreturn, "u_gt64b"),
        .@"s_gt8" => pl.todo(noreturn, "s_gt8"),
        .@"s_gt16" => pl.todo(noreturn, "s_gt16"),
        .@"s_gt32" => pl.todo(noreturn, "s_gt32"),
        .@"s_gt64" => pl.todo(noreturn, "s_gt64"),
        .@"s_gt8a" => pl.todo(noreturn, "s_gt8a"),
        .@"s_gt16a" => pl.todo(noreturn, "s_gt16a"),
        .@"s_gt32a" => pl.todo(noreturn, "s_gt32a"),
        .@"s_gt64a" => pl.todo(noreturn, "s_gt64a"),
        .@"s_gt8b" => pl.todo(noreturn, "s_gt8b"),
        .@"s_gt16b" => pl.todo(noreturn, "s_gt16b"),
        .@"s_gt32b" => pl.todo(noreturn, "s_gt32b"),
        .@"s_gt64b" => pl.todo(noreturn, "s_gt64b"),
        .@"f_gt32" => pl.todo(noreturn, "f_gt32"),
        .@"f_gt32a" => pl.todo(noreturn, "f_gt32a"),
        .@"f_gt32b" => pl.todo(noreturn, "f_gt32b"),
        .@"f_gt64" => pl.todo(noreturn, "f_gt64"),
        .@"f_gt64a" => pl.todo(noreturn, "f_gt64a"),
        .@"f_gt64b" => pl.todo(noreturn, "f_gt64b"),
        .@"u_le8" => pl.todo(noreturn, "u_le8"),
        .@"u_le16" => pl.todo(noreturn, "u_le16"),
        .@"u_le32" => pl.todo(noreturn, "u_le32"),
        .@"u_le64" => pl.todo(noreturn, "u_le64"),
        .@"u_le8a" => pl.todo(noreturn, "u_le8a"),
        .@"u_le16a" => pl.todo(noreturn, "u_le16a"),
        .@"u_le32a" => pl.todo(noreturn, "u_le32a"),
        .@"u_le64a" => pl.todo(noreturn, "u_le64a"),
        .@"u_le8b" => pl.todo(noreturn, "u_le8b"),
        .@"u_le16b" => pl.todo(noreturn, "u_le16b"),
        .@"u_le32b" => pl.todo(noreturn, "u_le32b"),
        .@"u_le64b" => pl.todo(noreturn, "u_le64b"),
        .@"s_le8" => pl.todo(noreturn, "s_le8"),
        .@"s_le16" => pl.todo(noreturn, "s_le16"),
        .@"s_le32" => pl.todo(noreturn, "s_le32"),
        .@"s_le64" => pl.todo(noreturn, "s_le64"),
        .@"s_le8a" => pl.todo(noreturn, "s_le8a"),
        .@"s_le16a" => pl.todo(noreturn, "s_le16a"),
        .@"s_le32a" => pl.todo(noreturn, "s_le32a"),
        .@"s_le64a" => pl.todo(noreturn, "s_le64a"),
        .@"s_le8b" => pl.todo(noreturn, "s_le8b"),
        .@"s_le16b" => pl.todo(noreturn, "s_le16b"),
        .@"s_le32b" => pl.todo(noreturn, "s_le32b"),
        .@"s_le64b" => pl.todo(noreturn, "s_le64b"),
        .@"f_le32" => pl.todo(noreturn, "f_le32"),
        .@"f_le32a" => pl.todo(noreturn, "f_le32a"),
        .@"f_le32b" => pl.todo(noreturn, "f_le32b"),
        .@"f_le64" => pl.todo(noreturn, "f_le64"),
        .@"f_le64a" => pl.todo(noreturn, "f_le64a"),
        .@"f_le64b" => pl.todo(noreturn, "f_le64b"),
        .@"u_ge8" => pl.todo(noreturn, "u_ge8"),
        .@"u_ge16" => pl.todo(noreturn, "u_ge16"),
        .@"u_ge32" => pl.todo(noreturn, "u_ge32"),
        .@"u_ge64" => pl.todo(noreturn, "u_ge64"),
        .@"u_ge8a" => pl.todo(noreturn, "u_ge8a"),
        .@"u_ge16a" => pl.todo(noreturn, "u_ge16a"),
        .@"u_ge32a" => pl.todo(noreturn, "u_ge32a"),
        .@"u_ge64a" => pl.todo(noreturn, "u_ge64a"),
        .@"u_ge8b" => pl.todo(noreturn, "u_ge8b"),
        .@"u_ge16b" => pl.todo(noreturn, "u_ge16b"),
        .@"u_ge32b" => pl.todo(noreturn, "u_ge32b"),
        .@"u_ge64b" => pl.todo(noreturn, "u_ge64b"),
        .@"s_ge8" => pl.todo(noreturn, "s_ge8"),
        .@"s_ge16" => pl.todo(noreturn, "s_ge16"),
        .@"s_ge32" => pl.todo(noreturn, "s_ge32"),
        .@"s_ge64" => pl.todo(noreturn, "s_ge64"),
        .@"s_ge8a" => pl.todo(noreturn, "s_ge8a"),
        .@"s_ge16a" => pl.todo(noreturn, "s_ge16a"),
        .@"s_ge32a" => pl.todo(noreturn, "s_ge32a"),
        .@"s_ge64a" => pl.todo(noreturn, "s_ge64a"),
        .@"s_ge8b" => pl.todo(noreturn, "s_ge8b"),
        .@"s_ge16b" => pl.todo(noreturn, "s_ge16b"),
        .@"s_ge32b" => pl.todo(noreturn, "s_ge32b"),
        .@"s_ge64b" => pl.todo(noreturn, "s_ge64b"),
        .@"f_ge32" => pl.todo(noreturn, "f_ge32"),
        .@"f_ge32a" => pl.todo(noreturn, "f_ge32a"),
        .@"f_ge32b" => pl.todo(noreturn, "f_ge32b"),
        .@"f_ge64" => pl.todo(noreturn, "f_ge64"),
        .@"f_ge64a" => pl.todo(noreturn, "f_ge64a"),
        .@"f_ge64b" => pl.todo(noreturn, "f_ge64b"),

        .@"s_neg8" => pl.todo(noreturn, "s_neg8"),
        .@"s_neg16" => pl.todo(noreturn, "s_neg16"),
        .@"s_neg32" => pl.todo(noreturn, "s_neg32"),
        .@"s_neg64" => pl.todo(noreturn, "s_neg64"),
        .@"s_abs8" => pl.todo(noreturn, "s_abs8"),
        .@"s_abs16" => pl.todo(noreturn, "s_abs16"),
        .@"s_abs32" => pl.todo(noreturn, "s_abs32"),
        .@"s_abs64" => pl.todo(noreturn, "s_abs64"),
        .@"i_add8" => pl.todo(noreturn, "i_add8"),
        .@"i_add16" => pl.todo(noreturn, "i_add16"),
        .@"i_add32" => pl.todo(noreturn, "i_add32"),
        .@"i_add64" => pl.todo(noreturn, "i_add64"),
        .@"i_add8c" => pl.todo(noreturn, "i_add8c"),
        .@"i_add16c" => pl.todo(noreturn, "i_add16c"),
        .@"i_add32c" => pl.todo(noreturn, "i_add32c"),
        .@"i_add64c" => pl.todo(noreturn, "i_add64c"),
        .@"i_sub8" => pl.todo(noreturn, "i_sub8"),
        .@"i_sub16" => pl.todo(noreturn, "i_sub16"),
        .@"i_sub32" => pl.todo(noreturn, "i_sub32"),
        .@"i_sub64" => pl.todo(noreturn, "i_sub64"),
        .@"i_sub8a" => pl.todo(noreturn, "i_sub8a"),
        .@"i_sub16a" => pl.todo(noreturn, "i_sub16a"),
        .@"i_sub32a" => pl.todo(noreturn, "i_sub32a"),
        .@"i_sub64a" => pl.todo(noreturn, "i_sub64a"),
        .@"i_sub8b" => pl.todo(noreturn, "i_sub8b"),
        .@"i_sub16b" => pl.todo(noreturn, "i_sub16b"),
        .@"i_sub32b" => pl.todo(noreturn, "i_sub32b"),
        .@"i_sub64b" => pl.todo(noreturn, "i_sub64b"),
        .@"i_mul8" => pl.todo(noreturn, "i_mul8"),
        .@"i_mul16" => pl.todo(noreturn, "i_mul16"),
        .@"i_mul32" => pl.todo(noreturn, "i_mul32"),
        .@"i_mul64" => pl.todo(noreturn, "i_mul64"),
        .@"i_mul8c" => pl.todo(noreturn, "i_mul8c"),
        .@"i_mul16c" => pl.todo(noreturn, "i_mul16c"),
        .@"i_mul32c" => pl.todo(noreturn, "i_mul32c"),
        .@"i_mul64c" => pl.todo(noreturn, "i_mul64c"),
        .@"u_i_div8" => pl.todo(noreturn, "u_i_div8"),
        .@"u_i_div16" => pl.todo(noreturn, "u_i_div16"),
        .@"u_i_div32" => pl.todo(noreturn, "u_i_div32"),
        .@"u_i_div64" => pl.todo(noreturn, "u_i_div64"),
        .@"u_i_div8a" => pl.todo(noreturn, "u_i_div8a"),
        .@"u_i_div16a" => pl.todo(noreturn, "u_i_div16a"),
        .@"u_i_div32a" => pl.todo(noreturn, "u_i_div32a"),
        .@"u_i_div64a" => pl.todo(noreturn, "u_i_div64a"),
        .@"u_i_div8b" => pl.todo(noreturn, "u_i_div8b"),
        .@"u_i_div16b" => pl.todo(noreturn, "u_i_div16b"),
        .@"u_i_div32b" => pl.todo(noreturn, "u_i_div32b"),
        .@"u_i_div64b" => pl.todo(noreturn, "u_i_div64b"),
        .@"s_i_div8" => pl.todo(noreturn, "s_i_div8"),
        .@"s_i_div16" => pl.todo(noreturn, "s_i_div16"),
        .@"s_i_div32" => pl.todo(noreturn, "s_i_div32"),
        .@"s_i_div64" => pl.todo(noreturn, "s_i_div64"),
        .@"s_i_div8a" => pl.todo(noreturn, "s_i_div8a"),
        .@"s_i_div16a" => pl.todo(noreturn, "s_i_div16a"),
        .@"s_i_div32a" => pl.todo(noreturn, "s_i_div32a"),
        .@"s_i_div64a" => pl.todo(noreturn, "s_i_div64a"),
        .@"s_i_div8b" => pl.todo(noreturn, "s_i_div8b"),
        .@"s_i_div16b" => pl.todo(noreturn, "s_i_div16b"),
        .@"s_i_div32b" => pl.todo(noreturn, "s_i_div32b"),
        .@"s_i_div64b" => pl.todo(noreturn, "s_i_div64b"),
        .@"u_i_rem8" => pl.todo(noreturn, "u_i_rem8"),
        .@"u_i_rem16" => pl.todo(noreturn, "u_i_rem16"),
        .@"u_i_rem32" => pl.todo(noreturn, "u_i_rem32"),
        .@"u_i_rem64" => pl.todo(noreturn, "u_i_rem64"),
        .@"u_i_rem8a" => pl.todo(noreturn, "u_i_rem8a"),
        .@"u_i_rem16a" => pl.todo(noreturn, "u_i_rem16a"),
        .@"u_i_rem32a" => pl.todo(noreturn, "u_i_rem32a"),
        .@"u_i_rem64a" => pl.todo(noreturn, "u_i_rem64a"),
        .@"u_i_rem8b" => pl.todo(noreturn, "u_i_rem8b"),
        .@"u_i_rem16b" => pl.todo(noreturn, "u_i_rem16b"),
        .@"u_i_rem32b" => pl.todo(noreturn, "u_i_rem32b"),
        .@"u_i_rem64b" => pl.todo(noreturn, "u_i_rem64b"),
        .@"s_i_rem8" => pl.todo(noreturn, "s_i_rem8"),
        .@"s_i_rem16" => pl.todo(noreturn, "s_i_rem16"),
        .@"s_i_rem32" => pl.todo(noreturn, "s_i_rem32"),
        .@"s_i_rem64" => pl.todo(noreturn, "s_i_rem64"),
        .@"s_i_rem8a" => pl.todo(noreturn, "s_i_rem8a"),
        .@"s_i_rem16a" => pl.todo(noreturn, "s_i_rem16a"),
        .@"s_i_rem32a" => pl.todo(noreturn, "s_i_rem32a"),
        .@"s_i_rem64a" => pl.todo(noreturn, "s_i_rem64a"),
        .@"s_i_rem8b" => pl.todo(noreturn, "s_i_rem8b"),
        .@"s_i_rem16b" => pl.todo(noreturn, "s_i_rem16b"),
        .@"s_i_rem32b" => pl.todo(noreturn, "s_i_rem32b"),
        .@"s_i_rem64b" => pl.todo(noreturn, "s_i_rem64b"),
        .@"i_pow8" => pl.todo(noreturn, "i_pow8"),
        .@"i_pow16" => pl.todo(noreturn, "i_pow16"),
        .@"i_pow32" => pl.todo(noreturn, "i_pow32"),
        .@"i_pow64" => pl.todo(noreturn, "i_pow64"),
        .@"i_pow8a" => pl.todo(noreturn, "i_pow8a"),
        .@"i_pow16a" => pl.todo(noreturn, "i_pow16a"),
        .@"i_pow32a" => pl.todo(noreturn, "i_pow32a"),
        .@"i_pow64a" => pl.todo(noreturn, "i_pow64a"),
        .@"i_pow8b" => pl.todo(noreturn, "i_pow8b"),
        .@"i_pow16b" => pl.todo(noreturn, "i_pow16b"),
        .@"i_pow32b" => pl.todo(noreturn, "i_pow32b"),
        .@"i_pow64b" => pl.todo(noreturn, "i_pow64b"),

        .@"f_neg32" => pl.todo(noreturn, "f_neg32"),
        .@"f_neg64" => pl.todo(noreturn, "f_neg64"),
        .@"f_abs32" => pl.todo(noreturn, "f_abs32"),
        .@"f_abs64" => pl.todo(noreturn, "f_abs64"),
        .@"f_sqrt32" => pl.todo(noreturn, "f_sqrt32"),
        .@"f_sqrt64" => pl.todo(noreturn, "f_sqrt64"),
        .@"f_floor32" => pl.todo(noreturn, "f_floor32"),
        .@"f_floor64" => pl.todo(noreturn, "f_floor64"),
        .@"f_ceil32" => pl.todo(noreturn, "f_ceil32"),
        .@"f_ceil64" => pl.todo(noreturn, "f_ceil64"),
        .@"f_round32" => pl.todo(noreturn, "f_round32"),
        .@"f_round64" => pl.todo(noreturn, "f_round64"),
        .@"f_trunc32" => pl.todo(noreturn, "f_trunc32"),
        .@"f_trunc64" => pl.todo(noreturn, "f_trunc64"),
        .@"f_man32" => pl.todo(noreturn, "f_man32"),
        .@"f_man64" => pl.todo(noreturn, "f_man64"),
        .@"f_frac32" => pl.todo(noreturn, "f_frac32"),
        .@"f_frac64" => pl.todo(noreturn, "f_frac64"),
        .@"f_add32" => pl.todo(noreturn, "f_add32"),
        .@"f_add32c" => pl.todo(noreturn, "f_add32c"),
        .@"f_add64" => pl.todo(noreturn, "f_add64"),
        .@"f_add64c" => pl.todo(noreturn, "f_add64c"),
        .@"f_sub32" => pl.todo(noreturn, "f_sub32"),
        .@"f_sub32a" => pl.todo(noreturn, "f_sub32a"),
        .@"f_sub32b" => pl.todo(noreturn, "f_sub32b"),
        .@"f_sub64" => pl.todo(noreturn, "f_sub64"),
        .@"f_sub64a" => pl.todo(noreturn, "f_sub64a"),
        .@"f_sub64b" => pl.todo(noreturn, "f_sub64b"),
        .@"f_mul32" => pl.todo(noreturn, "f_mul32"),
        .@"f_mul32c" => pl.todo(noreturn, "f_mul32c"),
        .@"f_mul64" => pl.todo(noreturn, "f_mul64"),
        .@"f_mul64c" => pl.todo(noreturn, "f_mul64c"),
        .@"f_div32" => pl.todo(noreturn, "f_div32"),
        .@"f_div32a" => pl.todo(noreturn, "f_div32a"),
        .@"f_div32b" => pl.todo(noreturn, "f_div32b"),
        .@"f_div64" => pl.todo(noreturn, "f_div64"),
        .@"f_div64a" => pl.todo(noreturn, "f_div64a"),
        .@"f_div64b" => pl.todo(noreturn, "f_div64b"),
        .@"f_rem32" => pl.todo(noreturn, "f_rem32"),
        .@"f_rem32a" => pl.todo(noreturn, "f_rem32a"),
        .@"f_rem32b" => pl.todo(noreturn, "f_rem32b"),
        .@"f_rem64" => pl.todo(noreturn, "f_rem64"),
        .@"f_rem64a" => pl.todo(noreturn, "f_rem64a"),
        .@"f_rem64b" => pl.todo(noreturn, "f_rem64b"),
        .@"f_pow32" => pl.todo(noreturn, "f_pow32"),
        .@"f_pow32a" => pl.todo(noreturn, "f_pow32a"),
        .@"f_pow32b" => pl.todo(noreturn, "f_pow32b"),
        .@"f_pow64" => pl.todo(noreturn, "f_pow64"),
        .@"f_pow64a" => pl.todo(noreturn, "f_pow64a"),
        .@"f_pow64b" => pl.todo(noreturn, "f_pow64b"),

        .@"s_ext8_16" => pl.todo(noreturn, "s_ext8_16"),
        .@"s_ext8_32" => pl.todo(noreturn, "s_ext8_32"),
        .@"s_ext8_64" => pl.todo(noreturn, "s_ext8_64"),
        .@"s_ext16_32" => pl.todo(noreturn, "s_ext16_32"),
        .@"s_ext16_64" => pl.todo(noreturn, "s_ext16_64"),
        .@"s_ext32_64" => pl.todo(noreturn, "s_ext32_64"),

        .@"f32_to_u8" => pl.todo(noreturn, "f32_to_u8"),
        .@"f32_to_u16" => pl.todo(noreturn, "f32_to_u16"),
        .@"f32_to_u32" => pl.todo(noreturn, "f32_to_u32"),
        .@"f32_to_u64" => pl.todo(noreturn, "f32_to_u64"),
        .@"f32_to_s8" => pl.todo(noreturn, "f32_to_s8"),
        .@"f32_to_s16" => pl.todo(noreturn, "f32_to_s16"),
        .@"f32_to_s32" => pl.todo(noreturn, "f32_to_s32"),
        .@"f32_to_s64" => pl.todo(noreturn, "f32_to_s64"),
        .@"u8_to_f32" => pl.todo(noreturn, "u8_to_f32"),
        .@"u16_to_f32" => pl.todo(noreturn, "u16_to_f32"),
        .@"u32_to_f32" => pl.todo(noreturn, "u32_to_f32"),
        .@"u64_to_f32" => pl.todo(noreturn, "u64_to_f32"),
        .@"s8_to_f32" => pl.todo(noreturn, "s8_to_f32"),
        .@"s16_to_f32" => pl.todo(noreturn, "s16_to_f32"),
        .@"s32_to_f32" => pl.todo(noreturn, "s32_to_f32"),
        .@"s64_to_f32" => pl.todo(noreturn, "s64_to_f32"),
        .@"u8_to_f64" => pl.todo(noreturn, "u8_to_f64"),
        .@"u16_to_f64" => pl.todo(noreturn, "u16_to_f64"),
        .@"u32_to_f64" => pl.todo(noreturn, "u32_to_f64"),
        .@"u64_to_f64" => pl.todo(noreturn, "u64_to_f64"),
        .@"s8_to_f64" => pl.todo(noreturn, "s8_to_f64"),
        .@"s16_to_f64" => pl.todo(noreturn, "s16_to_f64"),
        .@"s32_to_f64" => pl.todo(noreturn, "s32_to_f64"),
        .@"s64_to_f64" => pl.todo(noreturn, "s64_to_f64"),
        .@"f32_to_f64" => pl.todo(noreturn, "f32_to_f64"),
        .@"f64_to_f32" => pl.todo(noreturn, "f64_to_f32"),
    }
}
