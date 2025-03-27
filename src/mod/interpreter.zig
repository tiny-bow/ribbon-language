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
pub const BuiltinSignal = enum {
    /// Nominal return value.
    @"return",
    /// Effect handler cancellation.
    cancel,
};

/// The result of invoking a builtin function.
pub const BuiltinResult = struct {
    /// The return value of the function;
    /// may or not be initialized, depending on signature of callee.
    u64,
    /// The kind of control flow to perform, either return or cancel;
    /// errors are lifted to zig errors by the time this struct is relevant.
    BuiltinSignal,
};

/// Invokes a `core.BuiltinFunction` on the provided fiber, returning the result.
pub fn invokeStaticBuiltin(self: core.Fiber, evidence: ?*core.Evidence, fun: *const core.BuiltinFunction, arguments: []const u64) core.Error!BuiltinResult {
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

            return .{ self.header.registers.popPtr()[comptime core.Register.native_ret.getIndex()], .cancel };
        },
        .@"return" => {
            self.header.calls.pop();

            return .{ self.header.registers.popPtr()[comptime core.Register.native_ret.getIndex()], .@"return" };
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

/// Run the interpreter loop until `halt`; and optionally stop at breakpoints.
pub fn eval(self: core.Fiber, comptime mode: enum {breakpoints_halt, skip_breakpoints}) core.Error!void {
    while (true) {
        run(true, self.header) catch |signalOrError| {
            if (comptime mode == .breakpoints_halt) {
                switch (signalOrError) {
                    RunSignal.breakpoint => break,
                    inline RunSignal.step, RunSignal.@"return", RunSignal.cancel => continue,
                    inline else => |e| return e,
                }
            } else {
                switch (signalOrError) {
                    inline RunSignal.step, RunSignal.breakpoint, RunSignal.@"return", RunSignal.cancel => continue,
                    inline else => |e| return e,
                }
            }
        };

        break;
    }
}


/// Run the interpreter loop for a single instruction.
pub fn step(self: core.Fiber) core.Error!?InterpreterSignal {
    run(false, self.header) catch |signalOrError| {
        switch (signalOrError) {
            RunSignal.@"return" => return .@"return",
            RunSignal.cancel => return .cancel,
            RunSignal.breakpoint => return .breakpoint,
            RunSignal.step => return null,
            inline else => |e| return e,
        }
    };

    return .halt;
}


/// Signals that can be returned by the interpreter
pub const InterpreterSignal = enum(i64) {
    @"return" = 0,
    cancel = 1,

    halt = -1,
    breakpoint = -2,
};

const RunSignal = error {
    step,
    breakpoint,
    @"return",
    cancel,
};

fn run(comptime isLoop: bool, self: *core.mem.FiberHeader) (core.Error || RunSignal)!void {
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

        fn advance(st: *@This(), header: *core.mem.FiberHeader, signal: RunSignal) RunSignal!Instruction.OpCode {
            if (comptime isLoop) {
                return st.decode(header);
            } else {
                return signal;
            }
        }

        fn step(st: *@This(), header: *core.mem.FiberHeader) RunSignal!Instruction.OpCode {
            return st.advance(header, RunSignal.step);
        }
    };

    var state: State = undefined;
    const current = &state;

    dispatch: switch (current.decode(self)) {
        .nop => continue :dispatch try state.step(self),
        .@"breakpoint" => return RunSignal.breakpoint,
        .halt => return,
        .trap => return error.Unreachable,
        .@"unreachable" => return error.Unreachable,

        .@"push_set" => {
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
        .@"pop_set" => {
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

        .@"br" => {
            const offset: core.InstructionOffset = @bitCast(current.instruction.data.br.I);
            std.debug.assert(offset != 0);

            const newIp: core.InstructionAddr = pl.offsetPointer(current.callFrame.ip, offset);
            std.debug.assert(pl.alignDelta(newIp, @alignOf(core.InstructionBits)) == 0);
            std.debug.assert(current.function.extents.boundsCheck(newIp));

            current.callFrame.ip = newIp;

            continue :dispatch try state.step(self);
        },
        .@"br_if" => {
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

        .@"call" => {
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

                    const retVal, const signal = try invokeStaticBuiltin(.{ .header = self }, null, functionPtr, arguments);
                    _ = signal; // FIXME: signal handling

                    current.callFrame.vregs[registerIdX.getIndex()] = retVal;
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
        .@"call_c" => {
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

                    const retVal, const signal = try invokeStaticBuiltin(.{ .header = self }, null, functionPtr, arguments);
                    _ = signal; // FIXME: signal handling

                    current.callFrame.vregs[registerId.getIndex()] = retVal;
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

        .@"prompt" => {
            const registerId = current.instruction.data.prompt.R;
            const abi = current.instruction.data.prompt.A;
            const effectId = current.instruction.data.prompt.E;
            const argumentCount = current.instruction.data.prompt.I;

            const effectIndex = current.function.header.get(effectId).toIndex();

            const evidencePtr = self.evidence[effectIndex] orelse {
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

                    const retVal, const signal = try invokeStaticBuiltin(.{ .header = self }, evidencePtr, functionPtr, arguments);
                    _ = signal; // FIXME: signal handling

                    current.callFrame.vregs[registerId.getIndex()] = retVal;
                },
                .foreign => {
                    // TODO: document the fact that we are not assuming the foreign function
                    // knows about prompting, and not passing it the evidence.
                    // TODO: re-evaluate if this is the best strategy for foreign prompt.
                    // it might be nicer to pass the evidence here; but this method allows
                    // code to use arbitrary foreign functions as side effect handlers;
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


        .@"return" => {
            const registerId = current.instruction.data.@"return".R;
            const retVal: u64 = current.callFrame.vregs[registerId.getIndex()];

            self.calls.pop();
            self.registers.pop();
            self.data.top_ptr = current.callFrame.data;

            const newCallFrame = self.calls.top();
            const newRegisters = self.registers.top();
            std.debug.assert(@intFromPtr(newCallFrame) >= @intFromPtr(self.calls.base));

            newRegisters[current.callFrame.output.getIndex()] = retVal;

            continue :dispatch try state.advance(self, RunSignal.@"return");
        },
        .@"cancel" => {
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
        },

        .@"mem_set" => pl.todo(noreturn, "mem_set"),
        .@"mem_set_a" => pl.todo(noreturn, "mem_set_a"),
        .@"mem_set_b" => pl.todo(noreturn, "mem_set_b"),
        .@"mem_copy" => pl.todo(noreturn, "mem_copy"),
        .@"mem_copy_a" => pl.todo(noreturn, "mem_copy_a"),
        .@"mem_copy_b" => pl.todo(noreturn, "mem_copy_b"),
        .@"mem_swap" => pl.todo(noreturn, "mem_swap"),
        .@"mem_swap_c" => pl.todo(noreturn, "mem_swap_c"),
        .@"addr_l" => pl.todo(noreturn, "addr_l"),
        .@"addr_u" => pl.todo(noreturn, "addr_u"),
        .@"addr_g" => pl.todo(noreturn, "addr_g"),
        .@"addr_f" => pl.todo(noreturn, "addr_f"),
        .@"addr_b" => pl.todo(noreturn, "addr_b"),
        .@"addr_x" => pl.todo(noreturn, "addr_x"),
        .@"addr_c" => pl.todo(noreturn, "addr_c"),
        .@"load8" => pl.todo(noreturn, "load8"),
        .@"load16" => pl.todo(noreturn, "load16"),
        .@"load32" => pl.todo(noreturn, "load32"),
        .@"load64" => pl.todo(noreturn, "load64"),
        .@"store8" => pl.todo(noreturn, "store8"),
        .@"store16" => pl.todo(noreturn, "store16"),
        .@"store32" => pl.todo(noreturn, "store32"),
        .@"store64" => pl.todo(noreturn, "store64"),
        .@"store8c" => pl.todo(noreturn, "store8c"),
        .@"store16c" => pl.todo(noreturn, "store16c"),
        .@"store32c" => pl.todo(noreturn, "store32c"),
        .@"store64c" => pl.todo(noreturn, "store64c"),

        .@"bit_swap8" => pl.todo(noreturn, "bit_swap8"),
        .@"bit_swap16" => pl.todo(noreturn, "bit_swap16"),
        .@"bit_swap32" => pl.todo(noreturn, "bit_swap32"),
        .@"bit_swap64" => pl.todo(noreturn, "bit_swap64"),
        .@"bit_copy8" => pl.todo(noreturn, "bit_copy8"),
        .@"bit_copy16" => pl.todo(noreturn, "bit_copy16"),
        .@"bit_copy32" => pl.todo(noreturn, "bit_copy32"),
        .@"bit_copy64" => pl.todo(noreturn, "bit_copy64"),
        .@"bit_copy8c" => pl.todo(noreturn, "bit_copy8c"),
        .@"bit_copy16c" => pl.todo(noreturn, "bit_copy16c"),
        .@"bit_copy32c" => pl.todo(noreturn, "bit_copy32c"),
        .@"bit_copy64c" => pl.todo(noreturn, "bit_copy64c"),
        .@"bit_clz8" => pl.todo(noreturn, "bit_clz8"),
        .@"bit_clz16" => pl.todo(noreturn, "bit_clz16"),
        .@"bit_clz32" => pl.todo(noreturn, "bit_clz32"),
        .@"bit_clz64" => pl.todo(noreturn, "bit_clz64"),
        .@"bit_pop8" => pl.todo(noreturn, "bit_pop8"),
        .@"bit_pop16" => pl.todo(noreturn, "bit_pop16"),
        .@"bit_pop32" => pl.todo(noreturn, "bit_pop32"),
        .@"bit_pop64" => pl.todo(noreturn, "bit_pop64"),
        .@"bit_not8" => pl.todo(noreturn, "bit_not8"),
        .@"bit_not16" => pl.todo(noreturn, "bit_not16"),
        .@"bit_not32" => pl.todo(noreturn, "bit_not32"),
        .@"bit_not64" => pl.todo(noreturn, "bit_not64"),
        .@"bit_and8" => pl.todo(noreturn, "bit_and8"),
        .@"bit_and16" => pl.todo(noreturn, "bit_and16"),
        .@"bit_and32" => pl.todo(noreturn, "bit_and32"),
        .@"bit_and64" => pl.todo(noreturn, "bit_and64"),
        .@"bit_and8c" => pl.todo(noreturn, "bit_and8c"),
        .@"bit_and16c" => pl.todo(noreturn, "bit_and16c"),
        .@"bit_and32c" => pl.todo(noreturn, "bit_and32c"),
        .@"bit_and64c" => pl.todo(noreturn, "bit_and64c"),
        .@"bit_or8" => pl.todo(noreturn, "bit_or8"),
        .@"bit_or16" => pl.todo(noreturn, "bit_or16"),
        .@"bit_or32" => pl.todo(noreturn, "bit_or32"),
        .@"bit_or64" => pl.todo(noreturn, "bit_or64"),
        .@"bit_or8c" => pl.todo(noreturn, "bit_or8c"),
        .@"bit_or16c" => pl.todo(noreturn, "bit_or16c"),
        .@"bit_or32c" => pl.todo(noreturn, "bit_or32c"),
        .@"bit_or64c" => pl.todo(noreturn, "bit_or64c"),
        .@"bit_xor8" => pl.todo(noreturn, "bit_xor8"),
        .@"bit_xor16" => pl.todo(noreturn, "bit_xor16"),
        .@"bit_xor32" => pl.todo(noreturn, "bit_xor32"),
        .@"bit_xor64" => pl.todo(noreturn, "bit_xor64"),
        .@"bit_xor8c" => pl.todo(noreturn, "bit_xor8c"),
        .@"bit_xor16c" => pl.todo(noreturn, "bit_xor16c"),
        .@"bit_xor32c" => pl.todo(noreturn, "bit_xor32c"),
        .@"bit_xor64c" => pl.todo(noreturn, "bit_xor64c"),
        .@"bit_lshift8" => pl.todo(noreturn, "bit_lshift8"),
        .@"bit_lshift16" => pl.todo(noreturn, "bit_lshift16"),
        .@"bit_lshift32" => pl.todo(noreturn, "bit_lshift32"),
        .@"bit_lshift64" => pl.todo(noreturn, "bit_lshift64"),
        .@"bit_lshift8a" => pl.todo(noreturn, "bit_lshift8a"),
        .@"bit_lshift16a" => pl.todo(noreturn, "bit_lshift16a"),
        .@"bit_lshift32a" => pl.todo(noreturn, "bit_lshift32a"),
        .@"bit_lshift64a" => pl.todo(noreturn, "bit_lshift64a"),
        .@"bit_lshift8b" => pl.todo(noreturn, "bit_lshift8b"),
        .@"bit_lshift16b" => pl.todo(noreturn, "bit_lshift16b"),
        .@"bit_lshift32b" => pl.todo(noreturn, "bit_lshift32b"),
        .@"bit_lshift64b" => pl.todo(noreturn, "bit_lshift64b"),
        .@"u_rshift8" => pl.todo(noreturn, "u_rshift8"),
        .@"u_rshift16" => pl.todo(noreturn, "u_rshift16"),
        .@"u_rshift32" => pl.todo(noreturn, "u_rshift32"),
        .@"u_rshift64" => pl.todo(noreturn, "u_rshift64"),
        .@"u_rshift8a" => pl.todo(noreturn, "u_rshift8a"),
        .@"u_rshift16a" => pl.todo(noreturn, "u_rshift16a"),
        .@"u_rshift32a" => pl.todo(noreturn, "u_rshift32a"),
        .@"u_rshift64a" => pl.todo(noreturn, "u_rshift64a"),
        .@"u_rshift8b" => pl.todo(noreturn, "u_rshift8b"),
        .@"u_rshift16b" => pl.todo(noreturn, "u_rshift16b"),
        .@"u_rshift32b" => pl.todo(noreturn, "u_rshift32b"),
        .@"u_rshift64b" => pl.todo(noreturn, "u_rshift64b"),
        .@"s_rshift8" => pl.todo(noreturn, "s_rshift8"),
        .@"s_rshift16" => pl.todo(noreturn, "s_rshift16"),
        .@"s_rshift32" => pl.todo(noreturn, "s_rshift32"),
        .@"s_rshift64" => pl.todo(noreturn, "s_rshift64"),
        .@"s_rshift8a" => pl.todo(noreturn, "s_rshift8a"),
        .@"s_rshift16a" => pl.todo(noreturn, "s_rshift16a"),
        .@"s_rshift32a" => pl.todo(noreturn, "s_rshift32a"),
        .@"s_rshift64a" => pl.todo(noreturn, "s_rshift64a"),
        .@"s_rshift8b" => pl.todo(noreturn, "s_rshift8b"),
        .@"s_rshift16b" => pl.todo(noreturn, "s_rshift16b"),
        .@"s_rshift32b" => pl.todo(noreturn, "s_rshift32b"),
        .@"s_rshift64b" => pl.todo(noreturn, "s_rshift64b"),

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
