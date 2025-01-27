//! The Fiber contains everything needed to execute a single thread

const std = @import("std");

const utils = @import("utils");
const Rbc = @import("Rbc");

const Rvm = @import("../Rvm.zig");
const Context = Rvm.Context;


const Fiber = @This();


context: *const Context,
program: *const Rbc.Program,
data: DataStack,
calls: CallStack,
blocks: BlockStack,
evidence: [*]Evidence,
foreign: []const ForeignFunction,


pub const CALL_STACK_SIZE: usize = 1024;
pub const BLOCK_STACK_SIZE: usize = CALL_STACK_SIZE * Rbc.MAX_BLOCKS;
pub const EVIDENCE_VECTOR_SIZE: usize = std.math.maxInt(Rbc.EvidenceIndex);
pub const DATA_STACK_SIZE: usize = CALL_STACK_SIZE * Rbc.MAX_REGISTERS;


pub const DataStack = Stack(Rbc.Register, false);
pub const CallStack = Stack(CallFrame, true);
pub const BlockStack = Stack(BlockFrame, true);

pub const Trap = error {
    ForeignUnknown,
    Unreachable,
    Underflow,
    Overflow,
    OutOfBounds,
    MissingEvidence,
    OutValueMismatch,
    BadEncoding,
    ArgCountMismatch,
    BadAlignment,
    InvalidBlockRestart,
};


pub const ForeignFunction = *const fn (*anyopaque, Rbc.BlockIndex, *ForeignOut) callconv(.C) ForeignControl;

pub const ForeignControl = enum(u32) {
    step,
    done,
    done_v,
    trap,
};

pub const ForeignOut = extern union {
    step: Rbc.BlockIndex,
    done: void,
    done_v: Rbc.RegisterIndex,
    trap: utils.external.Error,
};

pub fn convertForeignError(e: utils.external.Error) Trap {
    const i = @intFromError(e.toNative());

    for (comptime std.meta.fieldNames(Trap)) |trapName| {
        if (i == @intFromError(@field(Trap, trapName))) {
            return @field(Trap, trapName);
        }
    }

    return Trap.ForeignUnknown;
}



pub fn Stack(comptime T: type, comptime PRE_INCR: bool) type {
    return struct {
        top_ptr: [*]T,

        base_ptr: [*]T,
        max_ptr: [*]T,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
            const buf = try allocator.alloc(T, size);
            return .{
                .top_ptr =
                    if (comptime PRE_INCR) buf.ptr - 1
                    else buf.ptr,
                .base_ptr = buf.ptr,
                .max_ptr = buf.ptr + size,
            };
        }

        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            allocator.free(self.base_ptr[0..(@intFromPtr(self.max_ptr) - @intFromPtr(self.base_ptr)) / @sizeOf(T)]);
        }

        pub fn push(self: *Self, value: T) void {
            if (comptime PRE_INCR) {
                self.top_ptr += 1;
                self.top_ptr[0] = value;
            } else {
                self.top_ptr[0] = value;
                self.top_ptr += 1;
            }
        }

        pub fn pushGet(self: *Self, value: T) *T {
            if (comptime PRE_INCR) {
                self.top_ptr += 1;
                self.top_ptr[0] = value;
                return @ptrCast(self.top_ptr);
            } else {
                self.top_ptr[0] = value;
                self.top_ptr += 1;
                return @ptrCast(self.top_ptr - 1);
            }
        }

        pub fn top(self: *Self) *T {
            return @ptrCast(self.top_ptr);
        }

        pub fn decr(self: *Self, count: usize) void {
            comptime std.debug.assert(!PRE_INCR);

            self.top_ptr -= count;
        }

        pub fn decrGet(self: *Self, count: usize) *T {
            return @ptrCast(self.decrGetMulti(count));
        }

        pub fn decrGetMulti(self: *Self, count: usize) [*]T {
            self.decr(count);

            return self.top_ptr;
        }

        pub fn incr(self: *Self, count: usize) void {
            self.top_ptr += count;
        }

        pub fn incrGet(self: *Self, count: usize) *T {
            return @ptrCast(self.incrGetMulti(count));
        }

        pub fn incrGetMulti(self: *Self, count: usize) [*]T {
            if (comptime PRE_INCR) {
                self.top_ptr += count;
                return self.top_ptr;
            } else {
                const out = self.top_ptr;
                self.top_ptr += count;
                return out;
            }
        }

        pub fn pop(self: *Self) void {
            self.top_ptr -= 1;
        }

        pub fn popGet(self: *Self) *T {
            if (comptime PRE_INCR) {
                const out = self.top_ptr;
                self.top_ptr -= 1;
                return @ptrCast(out);
            } else {
                self.top_ptr -= 1;
                return @ptrCast(self.top_ptr);
            }
        }

        pub fn hasSpace(self: *Self, count: usize) bool {
            return @intFromPtr(self.top_ptr + count) < @intFromPtr(self.max_ptr);
        }

        pub fn hasSpaceU1(self: *Self, count: usize) u1 {
            return @intFromBool(self.hasSpace(count));
        }
    };
}

pub const Evidence = struct {
    handler: *const Rbc.Function,
    call: *CallFrame,
    block: *BlockFrame,
    data: [*]Rbc.Register,
};

pub const BlockFrame = struct {
    base: [*]const Rbc.Instruction,
    ip: [*]const Rbc.Instruction,
    out: Rbc.RegisterIndex,
    handler_set: ?*const Rbc.Handler.Set,
};

pub const CallFrame = struct {
    function: *const Rbc.Function,
    evidence: *Evidence,
    block: *BlockFrame,
    data: [*]Rbc.Register,
};


pub fn init(context: *const Context, program: *const Rbc.Program, foreign: []const ForeignFunction) !*Fiber {
    const ptr = try context.allocator.create(Fiber);
    errdefer context.allocator.destroy(ptr);

    const data = try DataStack.init(context.allocator, DATA_STACK_SIZE);
    errdefer data.deinit(context.allocator);

    const calls = try CallStack.init(context.allocator, CALL_STACK_SIZE);
    errdefer calls.deinit(context.allocator);

    const blocks = try BlockStack.init(context.allocator, BLOCK_STACK_SIZE);
    errdefer blocks.deinit(context.allocator);

    const evidence = try context.allocator.alloc(Evidence, EVIDENCE_VECTOR_SIZE);
    errdefer context.allocator.free(evidence);

    ptr.* = Fiber {
        .program = program,
        .context = context,
        .data = data,
        .calls = calls,
        .blocks = blocks,
        .evidence = evidence.ptr,
        .foreign = foreign,
    };

    return ptr;
}

pub fn deinit(self: *Fiber) void {
    self.data.deinit(self.context.allocator);
    self.calls.deinit(self.context.allocator);
    self.blocks.deinit(self.context.allocator);

    self.context.allocator.free(self.evidence[0..EVIDENCE_VECTOR_SIZE]);

    self.context.allocator.destroy(self);
}

pub fn getLocation(self: *const Fiber) Rbc.Info.Location {
    const call = &self.calls.top_ptr[0];
    const block = &self.blocks.top_ptr[0];

    return .{
        .function = call.function,
        .block = block.base,
        .ip = block.ip,
    };
}


pub fn getForeign(self: *const Fiber, index: Rbc.ForeignId) ForeignFunction {
    return self.foreign[index];
}

pub fn boundsCheck(self: *Fiber, address: anytype, size: Rbc.RegisterLocalOffset) Fiber.Trap!void {
    utils.todo(noreturn, .{self, address, size});
}

pub fn removeAnyHandlerSet(self: *Fiber, blockFrame: *const Fiber.BlockFrame) void {
    if (blockFrame.handler_set) |handlerSet| {
        self.removeHandlerSet(handlerSet);
    }
}

pub fn removeHandlerSet(self: *Fiber, handlerSet: *const Rbc.Handler.Set) void {
    const oldHandlerStorage: [*]Evidence = @ptrCast(self.data.decrGet(handlerSet.len * (@sizeOf(Evidence) / @sizeOf(Rbc.Register))));
    for (handlerSet.*, 0..) |binding, i| {
        self.evidence[binding.id] = oldHandlerStorage[i];
    }
}




pub fn invoke(self: *Rvm.Fiber, comptime T: type, functionIndex: Rbc.FunctionIndex, arguments: anytype) Trap!T {
    const function = &self.program.functions[functionIndex];

    if (( self.calls.hasSpaceU1(2)
        & self.data.hasSpaceU1(function.num_registers + 1)
        ) != 1) {
        @branchHint(.cold);
        return Trap.Overflow;
    }

    const wrapperInstructions = [_]Rbc.Instruction {
        .{ .code = .halt, .data = .{ .halt = {} } },
    };

    const wrapper = Rbc.Function {
        .num_arguments = 0,
        .num_registers = 1,
        .bytecode = .{
            .blocks = &[_][*]const Rbc.Instruction {
                &wrapperInstructions
            },
            .instructions = &wrapperInstructions
        },
    };

    var dataBase = self.data.incrGet(1);
    const wrapperBlock = self.blocks.pushGet(BlockFrame {
        .base = &wrapperInstructions,
        .ip = &wrapperInstructions,
        .out = undefined,
        .handler_set = null,
    });

    self.calls.push(CallFrame {
        .function = &wrapper,
        .evidence = undefined,
        .block = wrapperBlock,
        .data = @ptrCast(dataBase),
    });

    dataBase = self.data.incrGet(function.num_registers);

    const block = self.blocks.pushGet(BlockFrame {
        .base = function.bytecode.blocks[0],
        .ip = function.bytecode.blocks[0],
        .out = 0,
        .handler_set = null,
    });

    self.calls.push(CallFrame {
        .function = function,
        .evidence = undefined,
        .block = block,
        .data = @ptrCast(dataBase),
    });

    inline for (0..arguments.len) |i| {
        self.writeLocal(@truncate(i), arguments[i]);
    }

    try Rvm.Eval.run(self);

    const result = self.readLocal(T, 0);

    const frame = self.calls.popGet();
    self.data.top_ptr = frame.data;

    self.blocks.pop();

    return result;
}


pub fn readLocal(self: *Fiber, comptime T: type, r: Rbc.RegisterIndex) T {
    return readReg(T, self.calls.top(), r);
}

pub fn writeLocal(self: *Fiber, r: Rbc.RegisterIndex, value: anytype) void {
    return writeReg(self.calls.top(), r, value);
}

pub fn addrLocal(self: *Fiber, r: Rbc.RegisterIndex) *u64 {
    return addrReg(self.calls.top(), r);
}

pub fn readUpvalue(self: *Fiber, comptime T: type, u: Rbc.UpvalueIndex) T {
    return readReg(T, self.calls.top().evidence.call, u);
}

pub fn writeUpvalue(self: *Fiber, u: Rbc.UpvalueIndex, value: anytype) void {
    return writeReg(self.calls.top().evidence.call, u, value);
}

pub fn addrUpvalue(self: *Fiber, u: Rbc.UpvalueIndex) *u64 {
    return addrReg(self.calls.top().evidence.call, u);
}

pub fn addrGlobal(self: *Fiber, g: Rbc.GlobalIndex) [*]u8 {
    return self.program.globals[g];
}

pub fn readGlobal(self: *Fiber, comptime T: type, g: Rbc.GlobalIndex) T {
    return @as(*T, @ptrCast(@alignCast(self.addrGlobal(g)))).*;
}

pub fn writeGlobal(self: *Fiber, g: Rbc.GlobalIndex, value: anytype) void {
    @as(*@TypeOf(value), @ptrCast(@alignCast(self.addrGlobal(g)))).* = value;
}

pub fn addrReg(frame: *const CallFrame, r: Rbc.RegisterIndex) *u64 {
    return @ptrCast(frame.data + r);
}

pub fn readReg(comptime T: type, frame: *const CallFrame, r: Rbc.RegisterIndex) T {
    return @as(*T, @ptrCast(addrReg(frame, r))).*;
}

pub fn writeReg(frame: *const CallFrame, r: Rbc.RegisterIndex, value: anytype) void {
    @as(*@TypeOf(value), @ptrCast(addrReg(frame, r))).* = value;
}


test {
    std.testing.refAllDeclsRecursive(@This());
}
