const std = @import("std");

const utils = @import("utils");

const Rbc = @import("Rbc");

const Rvm = @import("../Rvm.zig");
const Fiber = Rvm.Fiber;


const Eval = @This();



const ZeroCheck = enum {
    zero,
    non_zero
};

const ReturnStyle = enum {
    v,
    no_v
};

pub fn run(fiber: *Fiber) Fiber.Trap!void {
    return stepBytecode(true, fiber);
}

pub fn step(fiber: *Fiber) Fiber.Trap!bool {
    return stepBytecode(false, fiber);
}

fn decodeWideImmediate(fiber: *Fiber) u64 {
    const currentBlockFrame = fiber.blocks.top();
    const instr = currentBlockFrame.ip[0];
    currentBlockFrame.ip += 1;
    return @bitCast(instr);
}

fn decodeInstr(fiber: *Fiber, out_data: *Rbc.Op.Data) Rbc.Op.Code {
    const currentBlockFrame = fiber.blocks.top();
    const instr = currentBlockFrame.ip[0];
    out_data.* = instr.data;
    // std.debug.print("{}\t|\t{s} {any}\n", .{@intFromPtr(currentBlockFrame.ip), @tagName(instr.code), @call(.never_ Rbc.Info.extractInstructionInfo, .{instr})});
    currentBlockFrame.ip += 1;
    return instr.code;
}

fn byteSizeToWordSize(byteSize: usize) usize {
    const byteOffset = @divTrunc(byteSize, 8);
    const padding = @intFromBool(utils.alignmentDelta(byteSize, 8) > 0);
    return byteOffset + padding;
}

fn decodeArguments(fiber: *Fiber, count: usize) [*]const Rbc.RegisterIndex {
    const currentBlockFrame = fiber.blocks.top();

    const out: [*]const Rbc.RegisterIndex = @ptrCast(currentBlockFrame.ip);

    currentBlockFrame.ip += byteSizeToWordSize(count * @sizeOf(Rbc.RegisterIndex));

    return out;
}


// TODO: reimplement foreign calls as an instruction
fn stepBytecode(comptime reswitch: bool, fiber: *Fiber) Fiber.Trap!if (reswitch) void else bool {
    @setEvalBranchQuota(10_000);

    var lastData: Rbc.Op.Data = undefined;

    var registerScratchSpace = [1]u64 { undefined } ** Rbc.MAX_REGISTERS;

    reswitch: switch (decodeInstr(fiber, &lastData)) {
        .nop => if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData),


        .halt => if (comptime !reswitch) return false,

        .trap => return Fiber.Trap.Unreachable,

        .block => {
            block(fiber, lastData.block.B0, undefined);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .block_v => {
            block(fiber, lastData.block_v.B0, lastData.block_v.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .with => {
            try with(fiber, lastData.with.B0, lastData.with.H0, undefined);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .with_v => {
            try with(fiber, lastData.with_v.B0, lastData.with_v.H0, lastData.with_v.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .if_nz => {
            @"if"(fiber, lastData.if_nz.B0, lastData.if_nz.B1, lastData.if_nz.R0, .non_zero, undefined);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .if_nz_v => {
            @"if"(fiber, lastData.if_nz_v.B0, lastData.if_nz_v.B1, lastData.if_nz_v.R0, .non_zero, lastData.if_nz_v.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .if_z => {
            @"if"(fiber, lastData.if_z.B0, lastData.if_z.B1, lastData.if_z.R0, .zero, undefined);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .if_z_v => {
            @"if"(fiber, lastData.if_z_v.B0, lastData.if_z_v.B1, lastData.if_z_v.R0, .zero, lastData.if_z_v.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .when_nz => {
            when(fiber, lastData.when_nz.B0, lastData.when_nz.R0, .non_zero);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .when_z => {
            when(fiber, lastData.when_z.B0, lastData.when_z.R0, .zero);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .re => {
            re(fiber, lastData.re.B0, undefined, null);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .re_nz => {
            re(fiber, lastData.re_nz.B0, lastData.re_nz.R0, .non_zero);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .re_z => {
            re(fiber, lastData.re_z.B0, lastData.re_z.R0, .zero);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .br => {
            br(fiber, lastData.br.B0, undefined, null, undefined, .no_v);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .br_nz => {
            br(fiber, lastData.br_nz.B0, lastData.br_nz.R0, .non_zero, undefined, .no_v);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .br_z => {
            br(fiber, lastData.br_z.B0, lastData.br_z.R0, .zero, undefined, .no_v);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .br_v => {
            br(fiber, lastData.br_v.B0, undefined, null, fiber.readLocal(u64, lastData.br_v.R0), .v);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .br_nz_v => {
            br(fiber, lastData.br_nz_v.B0, lastData.br_nz_v.R0, .non_zero, fiber.readLocal(u64, lastData.br_nz_v.R1), .v);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .br_z_v => {
            br(fiber, lastData.br_z_v.B0, lastData.br_z_v.R0, .zero, fiber.readLocal(u64, lastData.br_z_v.R1), .v);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .br_im_v => {
            br(fiber, lastData.br_im_v.B0, undefined, null, lastData.br_im_v.i0, .v);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .br_im_w_v => {
            br(fiber, lastData.br_im_w_v.B0, undefined, null, decodeWideImmediate(fiber), .v);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .br_nz_im_v => {
            br(fiber, lastData.br_nz_im_v.B0, lastData.br_nz_im_v.R0, .non_zero, decodeWideImmediate(fiber), .v);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .br_z_im_v => {
            br(fiber, lastData.br_z_im_v.B0, lastData.br_z_im_v.R0, .zero, decodeWideImmediate(fiber), .v);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .call => {
            const f = fiber.readLocal(Rbc.FunctionIndex, lastData.call.R0);
            try call(fiber, &fiber.program.functions[f], undefined);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .call_v => {
            const f = fiber.readLocal(Rbc.FunctionIndex, lastData.call_v.R0);
            try call(fiber, &fiber.program.functions[f], lastData.call_v.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .call_im => {
            try call(fiber, &fiber.program.functions[lastData.call_im.F0], undefined);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .call_im_v => {
            try call(fiber,  &fiber.program.functions[lastData.call_im_v.F0], lastData.call_im_v.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .tail_call => {
            const f = fiber.readLocal(Rbc.FunctionIndex, lastData.tail_call.R0);
            try tail_call(fiber, &registerScratchSpace, &fiber.program.functions[f]);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .tail_call_im => {
            try tail_call(fiber, &registerScratchSpace, &fiber.program.functions[lastData.tail_call_im.F0]);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .prompt => {
            try prompt(fiber, lastData.prompt.E0, undefined);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .prompt_v => {
            try prompt(fiber, lastData.prompt_v.E0, lastData.prompt_v.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .ret => {
            ret(fiber, undefined, .no_v);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .ret_v => {
            ret(fiber, fiber.readLocal(u64, lastData.ret_v.R0), .v);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .ret_im_v => {
            ret(fiber, lastData.ret_im_v.i0, .v);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .ret_im_w_v => {
            ret(fiber, decodeWideImmediate(fiber), .v);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .term => {
            term(fiber, undefined, .no_v);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .term_v => {
            term(fiber, fiber.readLocal(u64, lastData.term_v.R0), .v);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .term_im_v => {
            term(fiber, lastData.term_im_v.i0, .v);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .term_im_w_v => {
            term(fiber, decodeWideImmediate(fiber), .v);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .alloca => {
            try alloca(fiber, lastData.alloca.s0, lastData.alloca.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .addr_global => {
            addr_global(fiber, lastData.addr_global.G0, lastData.addr_global.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .addr_upvalue => {
            addr_upvalue(fiber, lastData.addr_upvalue.U0, lastData.addr_upvalue.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .addr_local => {
            addr_local(fiber, lastData.addr_local.R0, lastData.addr_local.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .read_global_8 => {
            read_global(u8, fiber, lastData.read_global_8.G0, lastData.read_global_8.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .read_global_16 => {
            read_global(u16, fiber, lastData.read_global_16.G0, lastData.read_global_16.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .read_global_32 => {
            read_global(u32, fiber, lastData.read_global_32.G0, lastData.read_global_32.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .read_global_64 => {
            read_global(u64, fiber, lastData.read_global_64.G0, lastData.read_global_64.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .read_upvalue_8 => {
            read_upvalue(u8, fiber, lastData.read_upvalue_8.U0, lastData.read_upvalue_8.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .read_upvalue_16 => {
            read_upvalue(u16, fiber, lastData.read_upvalue_16.U0, lastData.read_upvalue_16.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .read_upvalue_32 => {
            read_upvalue(u32, fiber, lastData.read_upvalue_32.U0, lastData.read_upvalue_32.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .read_upvalue_64 => {
            read_upvalue(u64, fiber, lastData.read_upvalue_64.U0, lastData.read_upvalue_64.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .write_global_8 => {
            fiber.writeGlobal(lastData.write_global_8.G0, fiber.readLocal(u8, lastData.write_global_8.R0));
            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .write_global_16 => {
            fiber.writeGlobal(lastData.write_global_16.G0, fiber.readLocal(u16, lastData.write_global_16.R0));

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .write_global_32 => {
            fiber.writeGlobal(lastData.write_global_32.G0, fiber.readLocal(u32, lastData.write_global_32.R0));

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .write_global_64 => {
            fiber.writeGlobal(lastData.write_global_64.G0, fiber.readLocal(u64, lastData.write_global_64.R0));

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .write_global_8_im => {
            fiber.writeGlobal(lastData.write_global_8_im.G0, lastData.write_global_8_im.b0);
            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .write_global_16_im => {
            fiber.writeGlobal(lastData.write_global_16_im.G0, lastData.write_global_16_im.s0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .write_global_32_im => {
            fiber.writeGlobal(lastData.write_global_32_im.G0, lastData.write_global_32_im.i0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .write_global_64_im => {
            fiber.writeGlobal(lastData.write_global_64_im.G0, decodeWideImmediate(fiber));

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .write_upvalue_8 => {
            fiber.writeUpvalue(lastData.write_upvalue_8.U0, fiber.readLocal(u8, lastData.write_upvalue_8.R0));

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .write_upvalue_16 => {
            fiber.writeUpvalue(lastData.write_upvalue_16.U0, fiber.readLocal(u16, lastData.write_upvalue_16.R0));

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .write_upvalue_32 => {
            fiber.writeUpvalue(lastData.write_upvalue_32.U0, fiber.readLocal(u32, lastData.write_upvalue_32.R0));

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .write_upvalue_64 => {
            fiber.writeUpvalue(lastData.write_upvalue_64.U0, fiber.readLocal(u64, lastData.write_upvalue_64.R0));

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .write_upvalue_8_im => {
            fiber.writeUpvalue(lastData.write_upvalue_8_im.U0, lastData.write_upvalue_8_im.b0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .write_upvalue_16_im => {
            fiber.writeUpvalue(lastData.write_upvalue_16_im.U0, lastData.write_upvalue_16_im.s0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .write_upvalue_32_im => {
            fiber.writeUpvalue(lastData.write_upvalue_32_im.U0, lastData.write_upvalue_32_im.i0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .write_upvalue_64_im => {
            fiber.writeUpvalue(lastData.write_upvalue_64_im.U0, decodeWideImmediate(fiber));

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .load_8 => {
            try load(u8, fiber, lastData.load_8.R0, lastData.load_8.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .load_16 => {
            try load(u16, fiber, lastData.load_16.R0, lastData.load_16.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .load_32 => {
            try load(u32, fiber, lastData.load_32.R0, lastData.load_32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .load_64 => {
            try load(u64, fiber, lastData.load_64.R0, lastData.load_64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .store_8 => {
            try store(fiber, fiber.readLocal(u8, lastData.store_8.R0), lastData.store_8.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .store_16 => {
            try store(fiber, fiber.readLocal(u16, lastData.store_16.R0), lastData.store_16.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .store_32 => {
            try store(fiber, fiber.readLocal(u32, lastData.store_32.R0), lastData.store_32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .store_64 => {
            try store(fiber, fiber.readLocal(u64, lastData.store_64.R0), lastData.store_64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .store_8_im => {
            try store(fiber, lastData.store_8_im.b0, lastData.store_8_im.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .store_16_im => {
            try store(fiber, lastData.store_16_im.s0, lastData.store_16_im.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .store_32_im => {
            try store(fiber, lastData.store_32_im.i0, lastData.store_32_im.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .store_64_im => {
            try store(fiber, decodeWideImmediate(fiber), lastData.store_64_im.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .clear_8 => {
            clear(u8, fiber, lastData.clear_8.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .clear_16 => {
            clear(u16, fiber, lastData.clear_16.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .clear_32 => {
            clear(u32, fiber, lastData.clear_32.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .clear_64 => {
            clear(u64, fiber, lastData.clear_64.R0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .swap_8 => {
            swap(u8, fiber, lastData.swap_8.R0, lastData.swap_8.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .swap_16 => {
            swap(u16, fiber, lastData.swap_16.R0, lastData.swap_16.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .swap_32 => {
            swap(u32, fiber, lastData.swap_32.R0, lastData.swap_32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .swap_64 => {
            swap(u64, fiber, lastData.swap_64.R0, lastData.swap_64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .copy_8 => {
            fiber.writeLocal(lastData.copy_8.R1, fiber.readLocal(u8, lastData.copy_8.R0));

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .copy_16 => {
            fiber.writeLocal(lastData.copy_16.R1, fiber.readLocal(u16, lastData.copy_16.R0));

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .copy_32 => {
            fiber.writeLocal(lastData.copy_32.R1, fiber.readLocal(u32, lastData.copy_32.R0));

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .copy_64 => {
            fiber.writeLocal(lastData.copy_64.R1, fiber.readLocal(u64, lastData.copy_64.R0));

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .copy_8_im => {
            fiber.writeLocal(lastData.copy_8_im.R0, lastData.copy_8_im.b0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .copy_16_im => {
            fiber.writeLocal(lastData.copy_16_im.R0, lastData.copy_16_im.s0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .copy_32_im => {
            fiber.writeLocal(lastData.copy_32_im.R0, lastData.copy_32_im.i0);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .copy_64_im => {
            fiber.writeLocal(lastData.copy_64_im.R0, decodeWideImmediate(fiber));

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },


        .i_add_8 => {
            binary(fiber, "add", fiber.readLocal(u8, lastData.i_add_8.R0), fiber.readLocal(u8, lastData.i_add_8.R1), lastData.i_add_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_add_16 => {
            binary(fiber, "add", fiber.readLocal(u16, lastData.i_add_16.R0), fiber.readLocal(u16, lastData.i_add_16.R1), lastData.i_add_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_add_32 => {
            binary(fiber, "add", fiber.readLocal(u32, lastData.i_add_32.R0), fiber.readLocal(u32, lastData.i_add_32.R1), lastData.i_add_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_add_64 => {
            binary(fiber, "add", fiber.readLocal(u64, lastData.i_add_64.R0), fiber.readLocal(u64, lastData.i_add_64.R1), lastData.i_add_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_add_8_im => {
            binary(fiber, "add", lastData.i_add_8_im.b0, fiber.readLocal(u8, lastData.i_add_8_im.R0), lastData.i_add_8_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_add_16_im => {
            binary(fiber, "add", lastData.i_add_16_im.s0, fiber.readLocal(u16, lastData.i_add_16_im.R0), lastData.i_add_16_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_add_32_im => {
            binary(fiber, "add", lastData.i_add_32_im.i0, fiber.readLocal(u32, lastData.i_add_32_im.R0), lastData.i_add_32_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_add_64_im => {
            binary(fiber, "add", decodeWideImmediate(fiber), fiber.readLocal(u64, lastData.i_add_64_im.R0), lastData.i_add_64_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_add_32 => {
            binary(fiber, "add", fiber.readLocal(f32, lastData.f_add_32.R0), fiber.readLocal(f32, lastData.f_add_32.R1), lastData.f_add_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_add_64 => {
            binary(fiber, "add", fiber.readLocal(f64, lastData.f_add_64.R0), fiber.readLocal(f64, lastData.f_add_64.R1), lastData.f_add_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_add_32_im => {
            binary(fiber, "add", @as(f32, @bitCast(lastData.f_add_32_im.i0)), fiber.readLocal(f32, lastData.f_add_32_im.R0), lastData.f_add_32_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_add_64_im => {
            binary(fiber, "add", @as(f64, @bitCast(decodeWideImmediate(fiber))), fiber.readLocal(f64, lastData.f_add_64_im.R0), lastData.f_add_64_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_sub_8 => {
            binary(fiber, "sub", fiber.readLocal(u8, lastData.i_sub_8.R0), fiber.readLocal(u8, lastData.i_sub_8.R1), lastData.i_sub_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_sub_16 => {
            binary(fiber, "sub", fiber.readLocal(u16, lastData.i_sub_16.R0), fiber.readLocal(u16, lastData.i_sub_16.R1), lastData.i_sub_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_sub_32 => {
            binary(fiber, "sub", fiber.readLocal(u32, lastData.i_sub_32.R0), fiber.readLocal(u32, lastData.i_sub_32.R1), lastData.i_sub_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_sub_64 => {
            binary(fiber, "sub", fiber.readLocal(u64, lastData.i_sub_64.R0), fiber.readLocal(u64, lastData.i_sub_64.R1), lastData.i_sub_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_sub_8_im_a => {
            binary(fiber, "sub", lastData.i_sub_8_im_a.b0, fiber.readLocal(u8, lastData.i_sub_8_im_a.R0), lastData.i_sub_8_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_sub_16_im_a => {
            binary(fiber, "sub", lastData.i_sub_16_im_a.s0, fiber.readLocal(u16, lastData.i_sub_16_im_a.R0), lastData.i_sub_16_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_sub_32_im_a => {
            binary(fiber, "sub", lastData.i_sub_32_im_a.i0, fiber.readLocal(u32, lastData.i_sub_32_im_a.R0), lastData.i_sub_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_sub_64_im_a => {
            binary(fiber, "sub", decodeWideImmediate(fiber), fiber.readLocal(u64, lastData.i_sub_64_im_a.R0), lastData.i_sub_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_sub_8_im_b => {
            binary(fiber, "sub", fiber.readLocal(u8, lastData.i_sub_8_im_b.R0), lastData.i_sub_8_im_b.b0, lastData.i_sub_8_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_sub_16_im_b => {
            binary(fiber, "sub", fiber.readLocal(u16, lastData.i_sub_16_im_b.R0), lastData.i_sub_16_im_b.s0, lastData.i_sub_16_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_sub_32_im_b => {
            binary(fiber, "sub", fiber.readLocal(u32, lastData.i_sub_32_im_b.R0), lastData.i_sub_32_im_b.i0, lastData.i_sub_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_sub_64_im_b => {
            binary(fiber, "sub", fiber.readLocal(u64, lastData.i_sub_64_im_b.R0), decodeWideImmediate(fiber), lastData.i_sub_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_sub_32 => {
            binary(fiber, "sub", fiber.readLocal(f32, lastData.f_sub_32.R0), fiber.readLocal(f32, lastData.f_sub_32.R1), lastData.f_sub_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_sub_64 => {
            binary(fiber, "sub", fiber.readLocal(f64, lastData.f_sub_64.R0), fiber.readLocal(f64, lastData.f_sub_64.R1), lastData.f_sub_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_sub_32_im_a => {
            binary(fiber, "sub", @as(f32, @bitCast(lastData.f_sub_32_im_a.i0)), fiber.readLocal(f32, lastData.f_sub_32_im_a.R0), lastData.f_sub_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_sub_64_im_a => {
            binary(fiber, "sub", @as(f64, @bitCast(decodeWideImmediate(fiber))), fiber.readLocal(f64, lastData.f_sub_64_im_a.R0), lastData.f_sub_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_sub_32_im_b => {
            binary(fiber, "sub", fiber.readLocal(f32, lastData.f_sub_32_im_b.R0), @as(f32, @bitCast(lastData.f_sub_32_im_b.i0)), lastData.f_sub_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_sub_64_im_b => {
            binary(fiber, "sub", fiber.readLocal(f64, lastData.f_sub_64_im_b.R0), @as(f64, @bitCast(decodeWideImmediate(fiber))), lastData.f_sub_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_mul_8 => {
            binary(fiber, "mul", fiber.readLocal(u8, lastData.i_mul_8.R0), fiber.readLocal(u8, lastData.i_mul_8.R1), lastData.i_mul_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_mul_16 => {
            binary(fiber, "mul", fiber.readLocal(u16, lastData.i_mul_16.R0), fiber.readLocal(u16, lastData.i_mul_16.R1), lastData.i_mul_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_mul_32 => {
            binary(fiber, "mul", fiber.readLocal(u32, lastData.i_mul_32.R0), fiber.readLocal(u32, lastData.i_mul_32.R1), lastData.i_mul_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_mul_64 => {
            binary(fiber, "mul", fiber.readLocal(u64, lastData.i_mul_64.R0), fiber.readLocal(u64, lastData.i_mul_64.R1), lastData.i_mul_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_mul_8_im => {
            binary(fiber, "mul", lastData.i_mul_8_im.b0, fiber.readLocal(u8, lastData.i_mul_8_im.R0), lastData.i_mul_8_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_mul_16_im => {
            binary(fiber, "mul", lastData.i_mul_16_im.s0, fiber.readLocal(u16, lastData.i_mul_16_im.R0), lastData.i_mul_16_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_mul_32_im => {
            binary(fiber, "mul", lastData.i_mul_32_im.i0, fiber.readLocal(u32, lastData.i_mul_32_im.R0), lastData.i_mul_32_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_mul_64_im => {
            binary(fiber, "mul", decodeWideImmediate(fiber), fiber.readLocal(u64, lastData.i_mul_64_im.R0), lastData.i_mul_64_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_mul_32 => {
            binary(fiber, "mul", fiber.readLocal(f32, lastData.f_mul_32.R0), fiber.readLocal(f32, lastData.f_mul_32.R1), lastData.f_mul_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_mul_64 => {
            binary(fiber, "mul", fiber.readLocal(f64, lastData.f_mul_64.R0), fiber.readLocal(f64, lastData.f_mul_64.R1), lastData.f_mul_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_mul_32_im => {
            binary(fiber, "mul", @as(f32, @bitCast(lastData.f_mul_32_im.i0)), fiber.readLocal(f32, lastData.f_mul_32_im.R0), lastData.f_mul_32_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_mul_64_im => {
            binary(fiber, "mul", @as(f64, @bitCast(decodeWideImmediate(fiber))), fiber.readLocal(f64, lastData.f_mul_64_im.R0), lastData.f_mul_64_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_div_8 => {
            binary(fiber, "div", fiber.readLocal(u8, lastData.u_div_8.R0), fiber.readLocal(u8, lastData.u_div_8.R1), lastData.u_div_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_div_16 => {
            binary(fiber, "div", fiber.readLocal(u16, lastData.u_div_16.R0), fiber.readLocal(u16, lastData.u_div_16.R1), lastData.u_div_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_div_32 => {
            binary(fiber, "div", fiber.readLocal(u32, lastData.u_div_32.R0), fiber.readLocal(u32, lastData.u_div_32.R1), lastData.u_div_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_div_64 => {
            binary(fiber, "div", fiber.readLocal(u64, lastData.u_div_64.R0), fiber.readLocal(u64, lastData.u_div_64.R1), lastData.u_div_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_div_8_im_a => {
            binary(fiber, "div", lastData.u_div_8_im_a.b0, fiber.readLocal(u8, lastData.u_div_8_im_a.R0), lastData.u_div_8_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_div_16_im_a => {
            binary(fiber, "div", lastData.u_div_16_im_a.s0, fiber.readLocal(u16, lastData.u_div_16_im_a.R0), lastData.u_div_16_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_div_32_im_a => {
            binary(fiber, "div", lastData.u_div_32_im_a.i0, fiber.readLocal(u32, lastData.u_div_32_im_a.R0), lastData.u_div_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_div_64_im_a => {
            binary(fiber, "div", decodeWideImmediate(fiber), fiber.readLocal(u64, lastData.u_div_64_im_a.R0), lastData.u_div_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_div_8_im_b => {
            binary(fiber, "div", fiber.readLocal(u8, lastData.u_div_8_im_b.R0), lastData.u_div_8_im_b.b0, lastData.u_div_8_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_div_16_im_b => {
            binary(fiber, "div", fiber.readLocal(u16, lastData.u_div_16_im_b.R0), lastData.u_div_16_im_b.s0, lastData.u_div_16_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_div_32_im_b => {
            binary(fiber, "div", fiber.readLocal(u32, lastData.u_div_32_im_b.R0), lastData.u_div_32_im_b.i0, lastData.u_div_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_div_64_im_b => {
            binary(fiber, "div", fiber.readLocal(u64, lastData.u_div_64_im_b.R0), decodeWideImmediate(fiber), lastData.u_div_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_div_8 => {
            binary(fiber, "div", fiber.readLocal(i8, lastData.s_div_8.R0), fiber.readLocal(i8, lastData.s_div_8.R1), lastData.s_div_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_div_16 => {
            binary(fiber, "div", fiber.readLocal(i16, lastData.s_div_16.R0), fiber.readLocal(i16, lastData.s_div_16.R1), lastData.s_div_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_div_32 => {
            binary(fiber, "div", fiber.readLocal(i32, lastData.s_div_32.R0), fiber.readLocal(i32, lastData.s_div_32.R1), lastData.s_div_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_div_64 => {
            binary(fiber, "div", fiber.readLocal(i64, lastData.s_div_64.R0), fiber.readLocal(i64, lastData.s_div_64.R1), lastData.s_div_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_div_8_im_a => {
            binary(fiber, "div", @as(i8, @bitCast(lastData.s_div_8_im_a.b0)), fiber.readLocal(i8, lastData.s_div_8_im_a.R0), lastData.s_div_8_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_div_16_im_a => {
            binary(fiber, "div", @as(i16, @bitCast(lastData.s_div_16_im_a.s0)), fiber.readLocal(i16, lastData.s_div_16_im_a.R0), lastData.s_div_16_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_div_32_im_a => {
            binary(fiber, "div", @as(i32, @bitCast(lastData.s_div_32_im_a.i0)), fiber.readLocal(i32, lastData.s_div_32_im_a.R0), lastData.s_div_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_div_64_im_a => {
            binary(fiber, "div", @as(i64, @bitCast(decodeWideImmediate(fiber))), fiber.readLocal(i64, lastData.s_div_64_im_a.R0), lastData.s_div_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_div_8_im_b => {
            binary(fiber, "div", fiber.readLocal(i8, lastData.s_div_8_im_b.R0), @as(i8, @bitCast(lastData.s_div_8_im_b.b0)), lastData.s_div_8_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_div_16_im_b => {
            binary(fiber, "div", fiber.readLocal(i16, lastData.s_div_16_im_b.R0), @as(i16, @bitCast(lastData.s_div_16_im_b.s0)), lastData.s_div_16_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_div_32_im_b => {
            binary(fiber, "div", fiber.readLocal(i32, lastData.s_div_32_im_b.R0), @as(i32, @bitCast(lastData.s_div_32_im_b.i0)), lastData.s_div_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_div_64_im_b => {
            binary(fiber, "div", fiber.readLocal(i64, lastData.s_div_64_im_b.R0), @as(i64, @bitCast(decodeWideImmediate(fiber))), lastData.s_div_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_div_32 => {
            binary(fiber, "div", fiber.readLocal(f32, lastData.f_div_32.R0), fiber.readLocal(f32, lastData.f_div_32.R1), lastData.f_div_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_div_64 => {
            binary(fiber, "div", fiber.readLocal(f64, lastData.f_div_64.R0), fiber.readLocal(f64, lastData.f_div_64.R1), lastData.f_div_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_div_32_im_a => {
            binary(fiber, "div", @as(f32, @bitCast(lastData.f_div_32_im_a.i0)), fiber.readLocal(f32, lastData.f_div_32_im_a.R0), lastData.f_div_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_div_64_im_a => {
            binary(fiber, "div", @as(f64, @bitCast(decodeWideImmediate(fiber))), fiber.readLocal(f64, lastData.f_div_64_im_a.R0), lastData.f_div_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_div_32_im_b => {
            binary(fiber, "div", fiber.readLocal(f32, lastData.f_div_32_im_b.R0), @as(f32, @bitCast(lastData.f_div_32_im_b.i0)), lastData.f_div_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_div_64_im_b => {
            binary(fiber, "div", fiber.readLocal(f64, lastData.f_div_64_im_b.R0), @as(f64, @bitCast(decodeWideImmediate(fiber))), lastData.f_div_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_rem_8 => {
            binary(fiber, "rem", fiber.readLocal(u8, lastData.u_rem_8.R0), fiber.readLocal(u8, lastData.u_rem_8.R1), lastData.u_rem_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_rem_16 => {
            binary(fiber, "rem", fiber.readLocal(u16, lastData.u_rem_16.R0), fiber.readLocal(u16, lastData.u_rem_16.R1), lastData.u_rem_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_rem_32 => {
            binary(fiber, "rem", fiber.readLocal(u32, lastData.u_rem_32.R0), fiber.readLocal(u32, lastData.u_rem_32.R1), lastData.u_rem_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_rem_64 => {
            binary(fiber, "rem", fiber.readLocal(u64, lastData.u_rem_64.R0), fiber.readLocal(u64, lastData.u_rem_64.R1), lastData.u_rem_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_rem_8_im_a => {
            binary(fiber, "rem", lastData.u_rem_8_im_a.b0, fiber.readLocal(u8, lastData.u_rem_8_im_a.R0), lastData.u_rem_8_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_rem_16_im_a => {
            binary(fiber, "rem", lastData.u_rem_16_im_a.s0, fiber.readLocal(u16, lastData.u_rem_16_im_a.R0), lastData.u_rem_16_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_rem_32_im_a => {
            binary(fiber, "rem", lastData.u_rem_32_im_a.i0, fiber.readLocal(u32, lastData.u_rem_32_im_a.R0), lastData.u_rem_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_rem_64_im_a => {
            binary(fiber, "rem", decodeWideImmediate(fiber), fiber.readLocal(u64, lastData.u_rem_64_im_a.R0), lastData.u_rem_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_rem_8_im_b => {
            binary(fiber, "rem", fiber.readLocal(u8, lastData.u_rem_8_im_b.R0), lastData.u_rem_8_im_b.b0, lastData.u_rem_8_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_rem_16_im_b => {
            binary(fiber, "rem", fiber.readLocal(u16, lastData.u_rem_16_im_b.R0), lastData.u_rem_16_im_b.s0, lastData.u_rem_16_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_rem_32_im_b => {
            binary(fiber, "rem", fiber.readLocal(u32, lastData.u_rem_32_im_b.R0), lastData.u_rem_32_im_b.i0, lastData.u_rem_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_rem_64_im_b => {
            binary(fiber, "rem", fiber.readLocal(u64, lastData.u_rem_64_im_b.R0), decodeWideImmediate(fiber), lastData.u_rem_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_rem_8 => {
            binary(fiber, "rem", fiber.readLocal(i8, lastData.s_rem_8.R0), fiber.readLocal(i8, lastData.s_rem_8.R1), lastData.s_rem_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_rem_16 => {
            binary(fiber, "rem", fiber.readLocal(i16, lastData.s_rem_16.R0), fiber.readLocal(i16, lastData.s_rem_16.R1), lastData.s_rem_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_rem_32 => {
            binary(fiber, "rem", fiber.readLocal(i32, lastData.s_rem_32.R0), fiber.readLocal(i32, lastData.s_rem_32.R1), lastData.s_rem_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_rem_64 => {
            binary(fiber, "rem", fiber.readLocal(i64, lastData.s_rem_64.R0), fiber.readLocal(i64, lastData.s_rem_64.R1), lastData.s_rem_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_rem_8_im_a => {
            binary(fiber, "rem", @as(i8, @bitCast(lastData.s_rem_8_im_a.b0)), fiber.readLocal(i8, lastData.s_rem_8_im_a.R0), lastData.s_rem_8_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_rem_16_im_a => {
            binary(fiber, "rem", @as(i16, @bitCast(lastData.s_rem_16_im_a.s0)), fiber.readLocal(i16, lastData.s_rem_16_im_a.R0), lastData.s_rem_16_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_rem_32_im_a => {
            binary(fiber, "rem", @as(i32, @bitCast(lastData.s_rem_32_im_a.i0)), fiber.readLocal(i32, lastData.s_rem_32_im_a.R0), lastData.s_rem_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_rem_64_im_a => {
            binary(fiber, "rem", @as(i64, @bitCast(decodeWideImmediate(fiber))), fiber.readLocal(i64, lastData.s_rem_64_im_a.R0), lastData.s_rem_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_rem_8_im_b => {
            binary(fiber, "rem", fiber.readLocal(i8, lastData.s_rem_8_im_b.R0), @as(i8, @bitCast(lastData.s_rem_8_im_b.b0)), lastData.s_rem_8_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_rem_16_im_b => {
            binary(fiber, "rem", fiber.readLocal(i16, lastData.s_rem_16_im_b.R0), @as(i16, @bitCast(lastData.s_rem_16_im_b.s0)), lastData.s_rem_16_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_rem_32_im_b => {
            binary(fiber, "rem", fiber.readLocal(i32, lastData.s_rem_32_im_b.R0), @as(i32, @bitCast(lastData.s_rem_32_im_b.i0)), lastData.s_rem_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_rem_64_im_b => {
            binary(fiber, "rem", fiber.readLocal(i64, lastData.s_rem_64_im_b.R0), @as(i64, @bitCast(decodeWideImmediate(fiber))), lastData.s_rem_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_rem_32 => {
            binary(fiber, "rem", fiber.readLocal(f32, lastData.f_rem_32.R0), fiber.readLocal(f32, lastData.f_rem_32.R1), lastData.f_rem_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_rem_64 => {
            binary(fiber, "rem", fiber.readLocal(f64, lastData.f_rem_64.R0), fiber.readLocal(f64, lastData.f_rem_64.R1), lastData.f_rem_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_rem_32_im_a => {
            binary(fiber, "rem", @as(f32, @bitCast(lastData.f_rem_32_im_a.i0)), fiber.readLocal(f32, lastData.f_rem_32_im_a.R0), lastData.f_rem_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_rem_64_im_a => {
            binary(fiber, "rem", @as(f64, @bitCast(decodeWideImmediate(fiber))), fiber.readLocal(f64, lastData.f_rem_64_im_a.R0), lastData.f_rem_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_rem_32_im_b => {
            binary(fiber, "rem", fiber.readLocal(f32, lastData.f_rem_32_im_b.R0), @as(f32, @bitCast(lastData.f_rem_32_im_b.i0)), lastData.f_rem_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_rem_64_im_b => {
            binary(fiber, "rem", fiber.readLocal(f64, lastData.f_rem_64_im_b.R0), @as(f64, @bitCast(decodeWideImmediate(fiber))), lastData.f_rem_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_neg_8 => {
            unary(fiber, "neg", fiber.readLocal(i8, lastData.s_neg_8.R0), lastData.s_neg_8.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_neg_16 => {
            unary(fiber, "neg", fiber.readLocal(i16, lastData.s_neg_16.R0), lastData.s_neg_16.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_neg_32 => {
            unary(fiber, "neg", fiber.readLocal(i32, lastData.s_neg_32.R0), lastData.s_neg_32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_neg_64 => {
            unary(fiber, "neg", fiber.readLocal(i64, lastData.s_neg_64.R0), lastData.s_neg_64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_neg_32 => {
            unary(fiber, "neg", fiber.readLocal(f32, lastData.f_neg_32.R0), lastData.f_neg_32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_neg_64 => {
            unary(fiber, "neg", fiber.readLocal(f64, lastData.f_neg_64.R0), lastData.f_neg_64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },


        .band_8 => {
            binary(fiber, "band", fiber.readLocal(u8, lastData.band_8.R0), fiber.readLocal(u8, lastData.band_8.R1), lastData.band_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .band_16 => {
            binary(fiber, "band", fiber.readLocal(u16, lastData.band_16.R0), fiber.readLocal(u16, lastData.band_16.R1), lastData.band_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .band_32 => {
            binary(fiber, "band", fiber.readLocal(u32, lastData.band_32.R0), fiber.readLocal(u32, lastData.band_32.R1), lastData.band_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .band_64 => {
            binary(fiber, "band", fiber.readLocal(u64, lastData.band_64.R0), fiber.readLocal(u64, lastData.band_64.R1), lastData.band_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .band_8_im => {
            binary(fiber, "band", lastData.band_8_im.b0, fiber.readLocal(u8, lastData.band_8_im.R0), lastData.band_8_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .band_16_im => {
            binary(fiber, "band", lastData.band_16_im.s0, fiber.readLocal(u16, lastData.band_16_im.R0), lastData.band_16_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .band_32_im => {
            binary(fiber, "band", lastData.band_32_im.i0, fiber.readLocal(u32, lastData.band_32_im.R0), lastData.band_32_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .band_64_im => {
            binary(fiber, "band", decodeWideImmediate(fiber), fiber.readLocal(u64, lastData.band_64_im.R0), lastData.band_64_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bor_8 => {
            binary(fiber, "bor", fiber.readLocal(u8, lastData.bor_8.R0), fiber.readLocal(u8, lastData.bor_8.R1), lastData.bor_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bor_16 => {
            binary(fiber, "bor", fiber.readLocal(u16, lastData.bor_16.R0), fiber.readLocal(u16, lastData.bor_16.R1), lastData.bor_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bor_32 => {
            binary(fiber, "bor", fiber.readLocal(u32, lastData.bor_32.R0), fiber.readLocal(u32, lastData.bor_32.R1), lastData.bor_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bor_64 => {
            binary(fiber, "bor", fiber.readLocal(u64, lastData.bor_64.R0), fiber.readLocal(u64, lastData.bor_64.R1), lastData.bor_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bor_8_im => {
            binary(fiber, "bor", lastData.bor_8_im.b0, fiber.readLocal(u8, lastData.bor_8_im.R0), lastData.bor_8_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bor_16_im => {
            binary(fiber, "bor", lastData.bor_16_im.s0, fiber.readLocal(u16, lastData.bor_16_im.R0), lastData.bor_16_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bor_32_im => {
            binary(fiber, "bor", lastData.bor_32_im.i0, fiber.readLocal(u32, lastData.bor_32_im.R0), lastData.bor_32_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bor_64_im => {
            binary(fiber, "bor", decodeWideImmediate(fiber), fiber.readLocal(u64, lastData.bor_64_im.R0), lastData.bor_64_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bxor_8 => {
            binary(fiber, "bxor", fiber.readLocal(u8, lastData.bxor_8.R0), fiber.readLocal(u8, lastData.bxor_8.R1), lastData.bxor_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bxor_16 => {
            binary(fiber, "bxor", fiber.readLocal(u16, lastData.bxor_16.R0), fiber.readLocal(u16, lastData.bxor_16.R1), lastData.bxor_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bxor_32 => {
            binary(fiber, "bxor", fiber.readLocal(u32, lastData.bxor_32.R0), fiber.readLocal(u32, lastData.bxor_32.R1), lastData.bxor_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bxor_64 => {
            binary(fiber, "bxor", fiber.readLocal(u64, lastData.bxor_64.R0), fiber.readLocal(u64, lastData.bxor_64.R1), lastData.bxor_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bxor_8_im => {
            binary(fiber, "bxor", lastData.bxor_8_im.b0, fiber.readLocal(u8, lastData.bxor_8_im.R0), lastData.bxor_8_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bxor_16_im => {
            binary(fiber, "bxor", lastData.bxor_16_im.s0, fiber.readLocal(u16, lastData.bxor_16_im.R0), lastData.bxor_16_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bxor_32_im => {
            binary(fiber, "bxor", lastData.bxor_32_im.i0, fiber.readLocal(u32, lastData.bxor_32_im.R0), lastData.bxor_32_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bxor_64_im => {
            binary(fiber, "bxor", decodeWideImmediate(fiber), fiber.readLocal(u64, lastData.bxor_64_im.R0), lastData.bxor_64_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bnot_8 => {
            unary(fiber, "bnot", fiber.readLocal(u8, lastData.bnot_8.R0), lastData.bnot_8.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bnot_16 => {
            unary(fiber, "bnot", fiber.readLocal(u16, lastData.bnot_16.R0), lastData.bnot_16.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bnot_32 => {
            unary(fiber, "bnot", fiber.readLocal(u32, lastData.bnot_32.R0), lastData.bnot_32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bnot_64 => {
            unary(fiber, "bnot", fiber.readLocal(u64, lastData.bnot_64.R0), lastData.bnot_64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bshiftl_8 => {
            binary(fiber, "bshiftl", fiber.readLocal(u8, lastData.bshiftl_8.R0), fiber.readLocal(u8, lastData.bshiftl_8.R1), lastData.bshiftl_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bshiftl_16 => {
            binary(fiber, "bshiftl", fiber.readLocal(u16, lastData.bshiftl_16.R0), fiber.readLocal(u16, lastData.bshiftl_16.R1), lastData.bshiftl_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bshiftl_32 => {
            binary(fiber, "bshiftl", fiber.readLocal(u32, lastData.bshiftl_32.R0), fiber.readLocal(u32, lastData.bshiftl_32.R1), lastData.bshiftl_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bshiftl_64 => {
            binary(fiber, "bshiftl", fiber.readLocal(u64, lastData.bshiftl_64.R0), fiber.readLocal(u64, lastData.bshiftl_64.R1), lastData.bshiftl_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bshiftl_8_im_a => {
            binary(fiber, "bshiftl", lastData.bshiftl_8_im_a.b0, fiber.readLocal(u8, lastData.bshiftl_8_im_a.R0), lastData.bshiftl_8_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bshiftl_16_im_a => {
            binary(fiber, "bshiftl", lastData.bshiftl_16_im_a.s0, fiber.readLocal(u16, lastData.bshiftl_16_im_a.R0), lastData.bshiftl_16_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bshiftl_32_im_a => {
            binary(fiber, "bshiftl", lastData.bshiftl_32_im_a.i0, fiber.readLocal(u32, lastData.bshiftl_32_im_a.R0), lastData.bshiftl_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bshiftl_64_im_a => {
            binary(fiber, "bshiftl", decodeWideImmediate(fiber), fiber.readLocal(u64, lastData.bshiftl_64_im_a.R0), lastData.bshiftl_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bshiftl_8_im_b => {
            binary(fiber, "bshiftl", fiber.readLocal(u8, lastData.bshiftl_8_im_b.R0), lastData.bshiftl_8_im_b.b0, lastData.bshiftl_8_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bshiftl_16_im_b => {
            binary(fiber, "bshiftl", fiber.readLocal(u16, lastData.bshiftl_16_im_b.R0), lastData.bshiftl_16_im_b.s0, lastData.bshiftl_16_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bshiftl_32_im_b => {
            binary(fiber, "bshiftl", fiber.readLocal(u32, lastData.bshiftl_32_im_b.R0), lastData.bshiftl_32_im_b.i0, lastData.bshiftl_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .bshiftl_64_im_b => {
            binary(fiber, "bshiftl", fiber.readLocal(u64, lastData.bshiftl_64_im_b.R0), decodeWideImmediate(fiber), lastData.bshiftl_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_bshiftr_8 => {
            binary(fiber, "bshiftr", fiber.readLocal(u8, lastData.u_bshiftr_8.R0), fiber.readLocal(u8, lastData.u_bshiftr_8.R1), lastData.u_bshiftr_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_bshiftr_16 => {
            binary(fiber, "bshiftr", fiber.readLocal(u16, lastData.u_bshiftr_16.R0), fiber.readLocal(u16, lastData.u_bshiftr_16.R1), lastData.u_bshiftr_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_bshiftr_32 => {
            binary(fiber, "bshiftr", fiber.readLocal(u32, lastData.u_bshiftr_32.R0), fiber.readLocal(u32, lastData.u_bshiftr_32.R1), lastData.u_bshiftr_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_bshiftr_64 => {
            binary(fiber, "bshiftr", fiber.readLocal(u64, lastData.u_bshiftr_64.R0), fiber.readLocal(u64, lastData.u_bshiftr_64.R1), lastData.u_bshiftr_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_bshiftr_8_im_a => {
            binary(fiber, "bshiftr", lastData.u_bshiftr_8_im_a.b0, fiber.readLocal(u8, lastData.u_bshiftr_8_im_a.R0), lastData.u_bshiftr_8_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_bshiftr_16_im_a => {
            binary(fiber, "bshiftr", lastData.u_bshiftr_16_im_a.s0, fiber.readLocal(u16, lastData.u_bshiftr_16_im_a.R0), lastData.u_bshiftr_16_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_bshiftr_32_im_a => {
            binary(fiber, "bshiftr", lastData.u_bshiftr_32_im_a.i0, fiber.readLocal(u32, lastData.u_bshiftr_32_im_a.R0), lastData.u_bshiftr_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_bshiftr_64_im_a => {
            binary(fiber, "bshiftr", decodeWideImmediate(fiber), fiber.readLocal(u64, lastData.u_bshiftr_64_im_a.R0), lastData.u_bshiftr_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_bshiftr_8_im_b => {
            binary(fiber, "bshiftr", fiber.readLocal(u8, lastData.u_bshiftr_8_im_b.R0), lastData.u_bshiftr_8_im_b.b0, lastData.u_bshiftr_8_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_bshiftr_16_im_b => {
            binary(fiber, "bshiftr", fiber.readLocal(u16, lastData.u_bshiftr_16_im_b.R0), lastData.u_bshiftr_16_im_b.s0, lastData.u_bshiftr_16_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_bshiftr_32_im_b => {
            binary(fiber, "bshiftr", fiber.readLocal(u32, lastData.u_bshiftr_32_im_b.R0), lastData.u_bshiftr_32_im_b.i0, lastData.u_bshiftr_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_bshiftr_64_im_b => {
            binary(fiber, "bshiftr", fiber.readLocal(u64, lastData.u_bshiftr_64_im_b.R0), decodeWideImmediate(fiber), lastData.u_bshiftr_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_bshiftr_8 => {
            binary(fiber, "bshiftr", fiber.readLocal(i8, lastData.s_bshiftr_8.R0), fiber.readLocal(i8, lastData.s_bshiftr_8.R1), lastData.s_bshiftr_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_bshiftr_16 => {
            binary(fiber, "bshiftr", fiber.readLocal(i16, lastData.s_bshiftr_16.R0), fiber.readLocal(i16, lastData.s_bshiftr_16.R1), lastData.s_bshiftr_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_bshiftr_32 => {
            binary(fiber, "bshiftr", fiber.readLocal(i32, lastData.s_bshiftr_32.R0), fiber.readLocal(i32, lastData.s_bshiftr_32.R1), lastData.s_bshiftr_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_bshiftr_64 => {
            binary(fiber, "bshiftr", fiber.readLocal(i64, lastData.s_bshiftr_64.R0), fiber.readLocal(i64, lastData.s_bshiftr_64.R1), lastData.s_bshiftr_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_bshiftr_8_im_a => {
            binary(fiber, "bshiftr", @as(i8, @bitCast(lastData.s_bshiftr_8_im_a.b0)), fiber.readLocal(i8, lastData.s_bshiftr_8_im_a.R0), lastData.s_bshiftr_8_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_bshiftr_16_im_a => {
            binary(fiber, "bshiftr", @as(i16, @bitCast(lastData.s_bshiftr_16_im_a.s0)), fiber.readLocal(i16, lastData.s_bshiftr_16_im_a.R0), lastData.s_bshiftr_16_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_bshiftr_32_im_a => {
            binary(fiber, "bshiftr", @as(i32, @bitCast(lastData.s_bshiftr_32_im_a.i0)), fiber.readLocal(i32, lastData.s_bshiftr_32_im_a.R0), lastData.s_bshiftr_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_bshiftr_64_im_a => {
            binary(fiber, "bshiftr", @as(i64, @bitCast(decodeWideImmediate(fiber))), fiber.readLocal(i64, lastData.s_bshiftr_64_im_a.R0), lastData.s_bshiftr_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_bshiftr_8_im_b => {
            binary(fiber, "bshiftr", fiber.readLocal(i8, lastData.s_bshiftr_8_im_b.R0), @as(i8, @bitCast(lastData.s_bshiftr_8_im_b.b0)), lastData.s_bshiftr_8_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_bshiftr_16_im_b => {
            binary(fiber, "bshiftr", fiber.readLocal(i16, lastData.s_bshiftr_16_im_b.R0), @as(i16, @bitCast(lastData.s_bshiftr_16_im_b.s0)), lastData.s_bshiftr_16_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_bshiftr_32_im_b => {
            binary(fiber, "bshiftr", fiber.readLocal(i32, lastData.s_bshiftr_32_im_b.R0), @as(i32, @bitCast(lastData.s_bshiftr_32_im_b.i0)), lastData.s_bshiftr_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_bshiftr_64_im_b => {
            binary(fiber, "bshiftr", fiber.readLocal(i64, lastData.s_bshiftr_64_im_b.R0), @as(i64, @bitCast(decodeWideImmediate(fiber))), lastData.s_bshiftr_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },


        .i_eq_8 => {
            binary(fiber, "eq", fiber.readLocal(u8, lastData.i_eq_8.R0), fiber.readLocal(u8, lastData.i_eq_8.R1), lastData.i_eq_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_eq_16 => {
            binary(fiber, "eq", fiber.readLocal(u16, lastData.i_eq_16.R0), fiber.readLocal(u16, lastData.i_eq_16.R1), lastData.i_eq_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_eq_32 => {
            binary(fiber, "eq", fiber.readLocal(u32, lastData.i_eq_32.R0), fiber.readLocal(u32, lastData.i_eq_32.R1), lastData.i_eq_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_eq_64 => {
            binary(fiber, "eq", fiber.readLocal(u64, lastData.i_eq_64.R0), fiber.readLocal(u64, lastData.i_eq_64.R1), lastData.i_eq_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_eq_8_im => {
            binary(fiber, "eq", lastData.i_eq_8_im.b0, fiber.readLocal(u8, lastData.i_eq_8_im.R0), lastData.i_eq_8_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_eq_16_im => {
            binary(fiber, "eq", lastData.i_eq_16_im.s0, fiber.readLocal(u16, lastData.i_eq_16_im.R0), lastData.i_eq_16_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_eq_32_im => {
            binary(fiber, "eq", lastData.i_eq_32_im.i0, fiber.readLocal(u32, lastData.i_eq_32_im.R0), lastData.i_eq_32_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_eq_64_im => {
            binary(fiber, "eq", decodeWideImmediate(fiber), fiber.readLocal(u64, lastData.i_eq_64_im.R0), lastData.i_eq_64_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_eq_32 => {
            binary(fiber, "eq", fiber.readLocal(f32, lastData.f_eq_32.R0), fiber.readLocal(f32, lastData.f_eq_32.R1), lastData.f_eq_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_eq_64 => {
            binary(fiber, "eq", fiber.readLocal(f64, lastData.f_eq_64.R0), fiber.readLocal(f64, lastData.f_eq_64.R1), lastData.f_eq_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_eq_32_im => {
            binary(fiber, "eq", @as(f32, @bitCast(lastData.f_eq_32_im.i0)), fiber.readLocal(f32, lastData.f_eq_32_im.R0), lastData.f_eq_32_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_eq_64_im => {
            binary(fiber, "eq", @as(f64, @bitCast(decodeWideImmediate(fiber))), fiber.readLocal(f64, lastData.f_eq_64_im.R0), lastData.f_eq_64_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_ne_8 => {
            binary(fiber, "ne", fiber.readLocal(u8, lastData.i_ne_8.R0), fiber.readLocal(u8, lastData.i_ne_8.R1), lastData.i_ne_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_ne_16 => {
            binary(fiber, "ne", fiber.readLocal(u16, lastData.i_ne_16.R0), fiber.readLocal(u16, lastData.i_ne_16.R1), lastData.i_ne_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_ne_32 => {
            binary(fiber, "ne", fiber.readLocal(u32, lastData.i_ne_32.R0), fiber.readLocal(u32, lastData.i_ne_32.R1), lastData.i_ne_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_ne_64 => {
            binary(fiber, "ne", fiber.readLocal(u64, lastData.i_ne_64.R0), fiber.readLocal(u64, lastData.i_ne_64.R1), lastData.i_ne_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_ne_8_im => {
            binary(fiber, "ne", lastData.i_ne_8_im.b0, fiber.readLocal(u8, lastData.i_ne_8_im.R0), lastData.i_ne_8_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_ne_16_im => {
            binary(fiber, "ne", lastData.i_ne_16_im.s0, fiber.readLocal(u16, lastData.i_ne_16_im.R0), lastData.i_ne_16_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_ne_32_im => {
            binary(fiber, "ne", lastData.i_ne_32_im.i0, fiber.readLocal(u32, lastData.i_ne_32_im.R0), lastData.i_ne_32_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_ne_64_im => {
            binary(fiber, "ne", decodeWideImmediate(fiber), fiber.readLocal(u64, lastData.i_ne_64_im.R0), lastData.i_ne_64_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_ne_32 => {
            binary(fiber, "ne", fiber.readLocal(f32, lastData.f_ne_32.R0), fiber.readLocal(f32, lastData.f_ne_32.R1), lastData.f_ne_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_ne_64 => {
            binary(fiber, "ne", fiber.readLocal(f64, lastData.f_ne_64.R0), fiber.readLocal(f64, lastData.f_ne_64.R1), lastData.f_ne_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_ne_32_im => {
            binary(fiber, "ne", @as(f32, @bitCast(lastData.f_ne_32_im.i0)), fiber.readLocal(f32, lastData.f_ne_32_im.R0), lastData.f_ne_32_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_ne_64_im => {
            binary(fiber, "ne", @as(f64, @bitCast(decodeWideImmediate(fiber))), fiber.readLocal(f64, lastData.f_ne_64_im.R0), lastData.f_ne_64_im.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_lt_8 => {
            binary(fiber, "lt", fiber.readLocal(u8, lastData.u_lt_8.R0), fiber.readLocal(u8, lastData.u_lt_8.R1), lastData.u_lt_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_lt_16 => {
            binary(fiber, "lt", fiber.readLocal(u16, lastData.u_lt_16.R0), fiber.readLocal(u16, lastData.u_lt_16.R1), lastData.u_lt_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_lt_32 => {
            binary(fiber, "lt", fiber.readLocal(u32, lastData.u_lt_32.R0), fiber.readLocal(u32, lastData.u_lt_32.R1), lastData.u_lt_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_lt_64 => {
            binary(fiber, "lt", fiber.readLocal(u64, lastData.u_lt_64.R0), fiber.readLocal(u64, lastData.u_lt_64.R1), lastData.u_lt_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_lt_8_im_a => {
            binary(fiber, "lt", lastData.u_lt_8_im_a.b0, fiber.readLocal(u8, lastData.u_lt_8_im_a.R0), lastData.u_lt_8_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_lt_16_im_a => {
            binary(fiber, "lt", lastData.u_lt_16_im_a.s0, fiber.readLocal(u16, lastData.u_lt_16_im_a.R0), lastData.u_lt_16_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_lt_32_im_a => {
            binary(fiber, "lt", lastData.u_lt_32_im_a.i0, fiber.readLocal(u32, lastData.u_lt_32_im_a.R0), lastData.u_lt_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_lt_64_im_a => {
            binary(fiber, "lt", decodeWideImmediate(fiber), fiber.readLocal(u64, lastData.u_lt_64_im_a.R0), lastData.u_lt_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_lt_8_im_b => {
            binary(fiber, "lt", fiber.readLocal(u8, lastData.u_lt_8_im_b.R0), lastData.u_lt_8_im_b.b0, lastData.u_lt_8_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_lt_16_im_b => {
            binary(fiber, "lt", fiber.readLocal(u16, lastData.u_lt_16_im_b.R0), lastData.u_lt_16_im_b.s0, lastData.u_lt_16_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_lt_32_im_b => {
            binary(fiber, "lt", fiber.readLocal(u32, lastData.u_lt_32_im_b.R0), lastData.u_lt_32_im_b.i0, lastData.u_lt_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_lt_64_im_b => {
            binary(fiber, "lt", fiber.readLocal(u64, lastData.u_lt_64_im_b.R0), decodeWideImmediate(fiber), lastData.u_lt_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_lt_8 => {
            binary(fiber, "lt", fiber.readLocal(i8, lastData.s_lt_8.R0), fiber.readLocal(i8, lastData.s_lt_8.R1), lastData.s_lt_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_lt_16 => {
            binary(fiber, "lt", fiber.readLocal(i16, lastData.s_lt_16.R0), fiber.readLocal(i16, lastData.s_lt_16.R1), lastData.s_lt_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_lt_32 => {
            binary(fiber, "lt", fiber.readLocal(i32, lastData.s_lt_32.R0), fiber.readLocal(i32, lastData.s_lt_32.R1), lastData.s_lt_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_lt_64 => {
            binary(fiber, "lt", fiber.readLocal(i64, lastData.s_lt_64.R0), fiber.readLocal(i64, lastData.s_lt_64.R1), lastData.s_lt_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_lt_8_im_a => {
            binary(fiber, "lt", @as(i8, @bitCast(lastData.s_lt_8_im_a.b0)), fiber.readLocal(i8, lastData.s_lt_8_im_a.R0), lastData.s_lt_8_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_lt_16_im_a => {
            binary(fiber, "lt", @as(i16, @bitCast(lastData.s_lt_16_im_a.s0)), fiber.readLocal(i16, lastData.s_lt_16_im_a.R0), lastData.s_lt_16_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_lt_32_im_a => {
            binary(fiber, "lt", @as(i32, @bitCast(lastData.s_lt_32_im_a.i0)), fiber.readLocal(i32, lastData.s_lt_32_im_a.R0), lastData.s_lt_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_lt_64_im_a => {
            binary(fiber, "lt", @as(i64, @bitCast(decodeWideImmediate(fiber))), fiber.readLocal(i64, lastData.s_lt_64_im_a.R0), lastData.s_lt_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_lt_8_im_b => {
            binary(fiber, "lt", fiber.readLocal(i8, lastData.s_lt_8_im_b.R0), @as(i8, @bitCast(lastData.s_lt_8_im_b.b0)), lastData.s_lt_8_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_lt_16_im_b => {
            binary(fiber, "lt", fiber.readLocal(i16, lastData.s_lt_16_im_b.R0), @as(i16, @bitCast(lastData.s_lt_16_im_b.s0)), lastData.s_lt_16_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_lt_32_im_b => {
            binary(fiber, "lt", fiber.readLocal(i32, lastData.s_lt_32_im_b.R0), @as(i32, @bitCast(lastData.s_lt_32_im_b.i0)), lastData.s_lt_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_lt_64_im_b => {
            binary(fiber, "lt", fiber.readLocal(i64, lastData.s_lt_64_im_b.R0), @as(i64, @bitCast(decodeWideImmediate(fiber))), lastData.s_lt_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_lt_32 => {
            binary(fiber, "lt", fiber.readLocal(f32, lastData.f_lt_32.R0), fiber.readLocal(f32, lastData.f_lt_32.R1), lastData.f_lt_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_lt_64 => {
            binary(fiber, "lt", fiber.readLocal(f64, lastData.f_lt_64.R0), fiber.readLocal(f64, lastData.f_lt_64.R1), lastData.f_lt_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_lt_32_im_a => {
            binary(fiber, "lt", @as(f32, @bitCast(lastData.f_lt_32_im_a.i0)), fiber.readLocal(f32, lastData.f_lt_32_im_a.R0), lastData.f_lt_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_lt_64_im_a => {
            binary(fiber, "lt", @as(f64, @bitCast(decodeWideImmediate(fiber))), fiber.readLocal(f64, lastData.f_lt_64_im_a.R0), lastData.f_lt_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_lt_32_im_b => {
            binary(fiber, "lt", fiber.readLocal(f32, lastData.f_lt_32_im_b.R0), @as(f32, @bitCast(lastData.f_lt_32_im_b.i0)), lastData.f_lt_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_lt_64_im_b => {
            binary(fiber, "lt", fiber.readLocal(f64, lastData.f_lt_64_im_b.R0), @as(f64, @bitCast(decodeWideImmediate(fiber))), lastData.f_lt_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_gt_8 => {
            binary(fiber, "gt", fiber.readLocal(u8, lastData.u_gt_8.R0), fiber.readLocal(u8, lastData.u_gt_8.R1), lastData.u_gt_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_gt_16 => {
            binary(fiber, "gt", fiber.readLocal(u16, lastData.u_gt_16.R0), fiber.readLocal(u16, lastData.u_gt_16.R1), lastData.u_gt_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_gt_32 => {
            binary(fiber, "gt", fiber.readLocal(u32, lastData.u_gt_32.R0), fiber.readLocal(u32, lastData.u_gt_32.R1), lastData.u_gt_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_gt_64 => {
            binary(fiber, "gt", fiber.readLocal(u64, lastData.u_gt_64.R0), fiber.readLocal(u64, lastData.u_gt_64.R1), lastData.u_gt_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_gt_8_im_a => {
            binary(fiber, "gt", lastData.u_gt_8_im_a.b0, fiber.readLocal(u8, lastData.u_gt_8_im_a.R0), lastData.u_gt_8_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_gt_16_im_a => {
            binary(fiber, "gt", lastData.u_gt_16_im_a.s0, fiber.readLocal(u16, lastData.u_gt_16_im_a.R0), lastData.u_gt_16_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_gt_32_im_a => {
            binary(fiber, "gt", lastData.u_gt_32_im_a.i0, fiber.readLocal(u32, lastData.u_gt_32_im_a.R0), lastData.u_gt_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_gt_64_im_a => {
            binary(fiber, "gt", decodeWideImmediate(fiber), fiber.readLocal(u64, lastData.u_gt_64_im_a.R0), lastData.u_gt_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_gt_8_im_b => {
            binary(fiber, "gt", fiber.readLocal(u8, lastData.u_gt_8_im_b.R0), lastData.u_gt_8_im_b.b0, lastData.u_gt_8_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_gt_16_im_b => {
            binary(fiber, "gt", fiber.readLocal(u16, lastData.u_gt_16_im_b.R0), lastData.u_gt_16_im_b.s0, lastData.u_gt_16_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_gt_32_im_b => {
            binary(fiber, "gt", fiber.readLocal(u32, lastData.u_gt_32_im_b.R0), lastData.u_gt_32_im_b.i0, lastData.u_gt_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_gt_64_im_b => {
            binary(fiber, "gt", fiber.readLocal(u64, lastData.u_gt_64_im_b.R0), decodeWideImmediate(fiber), lastData.u_gt_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_gt_8 => {
            binary(fiber, "gt", fiber.readLocal(i8, lastData.s_gt_8.R0), fiber.readLocal(i8, lastData.s_gt_8.R1), lastData.s_gt_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_gt_16 => {
            binary(fiber, "gt", fiber.readLocal(i16, lastData.s_gt_16.R0), fiber.readLocal(i16, lastData.s_gt_16.R1), lastData.s_gt_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_gt_32 => {
            binary(fiber, "gt", fiber.readLocal(i32, lastData.s_gt_32.R0), fiber.readLocal(i32, lastData.s_gt_32.R1), lastData.s_gt_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_gt_64 => {
            binary(fiber, "gt", fiber.readLocal(i64, lastData.s_gt_64.R0), fiber.readLocal(i64, lastData.s_gt_64.R1), lastData.s_gt_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_gt_8_im_a => {
            binary(fiber, "gt", @as(i8, @bitCast(lastData.s_gt_8_im_a.b0)), fiber.readLocal(i8, lastData.s_gt_8_im_a.R0), lastData.s_gt_8_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_gt_16_im_a => {
            binary(fiber, "gt", @as(i16, @bitCast(lastData.s_gt_16_im_a.s0)), fiber.readLocal(i16, lastData.s_gt_16_im_a.R0), lastData.s_gt_16_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_gt_32_im_a => {
            binary(fiber, "gt", @as(i32, @bitCast(lastData.s_gt_32_im_a.i0)), fiber.readLocal(i32, lastData.s_gt_32_im_a.R0), lastData.s_gt_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_gt_64_im_a => {
            binary(fiber, "gt", @as(i64, @bitCast(decodeWideImmediate(fiber))), fiber.readLocal(i64, lastData.s_gt_64_im_a.R0), lastData.s_gt_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_gt_8_im_b => {
            binary(fiber, "gt", fiber.readLocal(i8, lastData.s_gt_8_im_b.R0), @as(i8, @bitCast(lastData.s_gt_8_im_b.b0)), lastData.s_gt_8_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_gt_16_im_b => {
            binary(fiber, "gt", fiber.readLocal(i16, lastData.s_gt_16_im_b.R0), @as(i16, @bitCast(lastData.s_gt_16_im_b.s0)), lastData.s_gt_16_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_gt_32_im_b => {
            binary(fiber, "gt", fiber.readLocal(i32, lastData.s_gt_32_im_b.R0), @as(i32, @bitCast(lastData.s_gt_32_im_b.i0)), lastData.s_gt_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_gt_64_im_b => {
            binary(fiber, "gt", fiber.readLocal(i64, lastData.s_gt_64_im_b.R0), @as(i64, @bitCast(decodeWideImmediate(fiber))), lastData.s_gt_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_gt_32 => {
            binary(fiber, "gt", fiber.readLocal(f32, lastData.f_gt_32.R0), fiber.readLocal(f32, lastData.f_gt_32.R1), lastData.f_gt_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_gt_64 => {
            binary(fiber, "gt", fiber.readLocal(f64, lastData.f_gt_64.R0), fiber.readLocal(f64, lastData.f_gt_64.R1), lastData.f_gt_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_gt_32_im_a => {
            binary(fiber, "gt", @as(f32, @bitCast(lastData.f_gt_32_im_a.i0)), fiber.readLocal(f32, lastData.f_gt_32_im_a.R0), lastData.f_gt_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_gt_64_im_a => {
            binary(fiber, "gt", @as(f64, @bitCast(decodeWideImmediate(fiber))), fiber.readLocal(f64, lastData.f_gt_64_im_a.R0), lastData.f_gt_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_gt_32_im_b => {
            binary(fiber, "gt", fiber.readLocal(f32, lastData.f_gt_32_im_b.R0), @as(f32, @bitCast(lastData.f_gt_32_im_b.i0)), lastData.f_gt_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_gt_64_im_b => {
            binary(fiber, "gt", fiber.readLocal(f64, lastData.f_gt_64_im_b.R0), @as(f64, @bitCast(decodeWideImmediate(fiber))), lastData.f_gt_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_le_8 => {
            binary(fiber, "le", fiber.readLocal(u8, lastData.u_le_8.R0), fiber.readLocal(u8, lastData.u_le_8.R1), lastData.u_le_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_le_16 => {
            binary(fiber, "le", fiber.readLocal(u16, lastData.u_le_16.R0), fiber.readLocal(u16, lastData.u_le_16.R1), lastData.u_le_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_le_32 => {
            binary(fiber, "le", fiber.readLocal(u32, lastData.u_le_32.R0), fiber.readLocal(u32, lastData.u_le_32.R1), lastData.u_le_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_le_64 => {
            binary(fiber, "le", fiber.readLocal(u64, lastData.u_le_64.R0), fiber.readLocal(u64, lastData.u_le_64.R1), lastData.u_le_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_le_8_im_a => {
            binary(fiber, "le", lastData.u_le_8_im_a.b0, fiber.readLocal(u8, lastData.u_le_8_im_a.R0), lastData.u_le_8_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_le_16_im_a => {
            binary(fiber, "le", lastData.u_le_16_im_a.s0, fiber.readLocal(u16, lastData.u_le_16_im_a.R0), lastData.u_le_16_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_le_32_im_a => {
            binary(fiber, "le", lastData.u_le_32_im_a.i0, fiber.readLocal(u32, lastData.u_le_32_im_a.R0), lastData.u_le_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_le_64_im_a => {
            binary(fiber, "le", decodeWideImmediate(fiber), fiber.readLocal(u64, lastData.u_le_64_im_a.R0), lastData.u_le_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_le_8_im_b => {
            binary(fiber, "le", fiber.readLocal(u8, lastData.u_le_8_im_b.R0), lastData.u_le_8_im_b.b0, lastData.u_le_8_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_le_16_im_b => {
            binary(fiber, "le", fiber.readLocal(u16, lastData.u_le_16_im_b.R0), lastData.u_le_16_im_b.s0, lastData.u_le_16_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_le_32_im_b => {
            binary(fiber, "le", fiber.readLocal(u32, lastData.u_le_32_im_b.R0), lastData.u_le_32_im_b.i0, lastData.u_le_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_le_64_im_b => {
            binary(fiber, "le", fiber.readLocal(u64, lastData.u_le_64_im_b.R0), decodeWideImmediate(fiber), lastData.u_le_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_le_8 => {
            binary(fiber, "le", fiber.readLocal(i8, lastData.s_le_8.R0), fiber.readLocal(i8, lastData.s_le_8.R1), lastData.s_le_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_le_16 => {
            binary(fiber, "le", fiber.readLocal(i16, lastData.s_le_16.R0), fiber.readLocal(i16, lastData.s_le_16.R1), lastData.s_le_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_le_32 => {
            binary(fiber, "le", fiber.readLocal(i32, lastData.s_le_32.R0), fiber.readLocal(i32, lastData.s_le_32.R1), lastData.s_le_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_le_64 => {
            binary(fiber, "le", fiber.readLocal(i64, lastData.s_le_64.R0), fiber.readLocal(i64, lastData.s_le_64.R1), lastData.s_le_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_le_8_im_a => {
            binary(fiber, "le", @as(i8, @bitCast(lastData.s_le_8_im_a.b0)), fiber.readLocal(i8, lastData.s_le_8_im_a.R0), lastData.s_le_8_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_le_16_im_a => {
            binary(fiber, "le", @as(i16, @bitCast(lastData.s_le_16_im_a.s0)), fiber.readLocal(i16, lastData.s_le_16_im_a.R0), lastData.s_le_16_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_le_32_im_a => {
            binary(fiber, "le", @as(i32, @bitCast(lastData.s_le_32_im_a.i0)), fiber.readLocal(i32, lastData.s_le_32_im_a.R0), lastData.s_le_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_le_64_im_a => {
            binary(fiber, "le", @as(i64, @bitCast(decodeWideImmediate(fiber))), fiber.readLocal(i64, lastData.s_le_64_im_a.R0), lastData.s_le_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_le_8_im_b => {
            binary(fiber, "le", fiber.readLocal(i8, lastData.s_le_8_im_b.R0), @as(i8, @bitCast(lastData.s_le_8_im_b.b0)), lastData.s_le_8_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_le_16_im_b => {
            binary(fiber, "le", fiber.readLocal(i16, lastData.s_le_16_im_b.R0), @as(i16, @bitCast(lastData.s_le_16_im_b.s0)), lastData.s_le_16_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_le_32_im_b => {
            binary(fiber, "le", fiber.readLocal(i32, lastData.s_le_32_im_b.R0), @as(i32, @bitCast(lastData.s_le_32_im_b.i0)), lastData.s_le_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_le_64_im_b => {
            binary(fiber, "le", fiber.readLocal(i64, lastData.s_le_64_im_b.R0), @as(i64, @bitCast(decodeWideImmediate(fiber))), lastData.s_le_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_le_32 => {
            binary(fiber, "le", fiber.readLocal(f32, lastData.f_le_32.R0), fiber.readLocal(f32, lastData.f_le_32.R1), lastData.f_le_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_le_64 => {
            binary(fiber, "le", fiber.readLocal(f64, lastData.f_le_64.R0), fiber.readLocal(f64, lastData.f_le_64.R1), lastData.f_le_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_le_32_im_a => {
            binary(fiber, "le", @as(f32, @bitCast(lastData.f_le_32_im_a.i0)), fiber.readLocal(f32, lastData.f_le_32_im_a.R0), lastData.f_le_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_le_64_im_a => {
            binary(fiber, "le", @as(f64, @bitCast(decodeWideImmediate(fiber))), fiber.readLocal(f64, lastData.f_le_64_im_a.R0), lastData.f_le_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_le_32_im_b => {
            binary(fiber, "le", fiber.readLocal(f32, lastData.f_le_32_im_b.R0), @as(f32, @bitCast(lastData.f_le_32_im_b.i0)), lastData.f_le_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_le_64_im_b => {
            binary(fiber, "le", fiber.readLocal(f64, lastData.f_le_64_im_b.R0), @as(f64, @bitCast(decodeWideImmediate(fiber))), lastData.f_le_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_ge_8 => {
            binary(fiber, "ge", fiber.readLocal(u8, lastData.u_ge_8.R0), fiber.readLocal(u8, lastData.u_ge_8.R1), lastData.u_ge_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_ge_16 => {
            binary(fiber, "ge", fiber.readLocal(u16, lastData.u_ge_16.R0), fiber.readLocal(u16, lastData.u_ge_16.R1), lastData.u_ge_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_ge_32 => {
            binary(fiber, "ge", fiber.readLocal(u32, lastData.u_ge_32.R0), fiber.readLocal(u32, lastData.u_ge_32.R1), lastData.u_ge_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_ge_64 => {
            binary(fiber, "ge", fiber.readLocal(u64, lastData.u_ge_64.R0), fiber.readLocal(u64, lastData.u_ge_64.R1), lastData.u_ge_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_ge_8_im_a => {
            binary(fiber, "ge", lastData.u_ge_8_im_a.b0, fiber.readLocal(u8, lastData.u_ge_8_im_a.R0), lastData.u_ge_8_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_ge_16_im_a => {
            binary(fiber, "ge", lastData.u_ge_16_im_a.s0, fiber.readLocal(u16, lastData.u_ge_16_im_a.R0), lastData.u_ge_16_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_ge_32_im_a => {
            binary(fiber, "ge", lastData.u_ge_32_im_a.i0, fiber.readLocal(u32, lastData.u_ge_32_im_a.R0), lastData.u_ge_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_ge_64_im_a => {
            binary(fiber, "ge", decodeWideImmediate(fiber), fiber.readLocal(u64, lastData.u_ge_64_im_a.R0), lastData.u_ge_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_ge_8_im_b => {
            binary(fiber, "ge", fiber.readLocal(u8, lastData.u_ge_8_im_b.R0), lastData.u_ge_8_im_b.b0, lastData.u_ge_8_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_ge_16_im_b => {
            binary(fiber, "ge", fiber.readLocal(u16, lastData.u_ge_16_im_b.R0), lastData.u_ge_16_im_b.s0, lastData.u_ge_16_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_ge_32_im_b => {
            binary(fiber, "ge", fiber.readLocal(u32, lastData.u_ge_32_im_b.R0), lastData.u_ge_32_im_b.i0, lastData.u_ge_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_ge_64_im_b => {
            binary(fiber, "ge", fiber.readLocal(u64, lastData.u_ge_64_im_b.R0), decodeWideImmediate(fiber), lastData.u_ge_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_ge_8 => {
            binary(fiber, "ge", fiber.readLocal(i8, lastData.s_ge_8.R0), fiber.readLocal(i8, lastData.s_ge_8.R1), lastData.s_ge_8.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_ge_16 => {
            binary(fiber, "ge", fiber.readLocal(i16, lastData.s_ge_16.R0), fiber.readLocal(i16, lastData.s_ge_16.R1), lastData.s_ge_16.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_ge_32 => {
            binary(fiber, "ge", fiber.readLocal(i32, lastData.s_ge_32.R0), fiber.readLocal(i32, lastData.s_ge_32.R1), lastData.s_ge_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_ge_64 => {
            binary(fiber, "ge", fiber.readLocal(i64, lastData.s_ge_64.R0), fiber.readLocal(i64, lastData.s_ge_64.R1), lastData.s_ge_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_ge_8_im_a => {
            binary(fiber, "ge", @as(i8, @bitCast(lastData.s_ge_8_im_a.b0)), fiber.readLocal(i8, lastData.s_ge_8_im_a.R0), lastData.s_ge_8_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_ge_16_im_a => {
            binary(fiber, "ge", @as(i16, @bitCast(lastData.s_ge_16_im_a.s0)), fiber.readLocal(i16, lastData.s_ge_16_im_a.R0), lastData.s_ge_16_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_ge_32_im_a => {
            binary(fiber, "ge", @as(i32, @bitCast(lastData.s_ge_32_im_a.i0)), fiber.readLocal(i32, lastData.s_ge_32_im_a.R0), lastData.s_ge_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_ge_64_im_a => {
            binary(fiber, "ge", @as(i64, @bitCast(decodeWideImmediate(fiber))), fiber.readLocal(i64, lastData.s_ge_64_im_a.R0), lastData.s_ge_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_ge_8_im_b => {
            binary(fiber, "ge", fiber.readLocal(i8, lastData.s_ge_8_im_b.R0), @as(i8, @bitCast(lastData.s_ge_8_im_b.b0)), lastData.s_ge_8_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_ge_16_im_b => {
            binary(fiber, "ge", fiber.readLocal(i16, lastData.s_ge_16_im_b.R0), @as(i16, @bitCast(lastData.s_ge_16_im_b.s0)), lastData.s_ge_16_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_ge_32_im_b => {
            binary(fiber, "ge", fiber.readLocal(i32, lastData.s_ge_32_im_b.R0), @as(i32, @bitCast(lastData.s_ge_32_im_b.i0)), lastData.s_ge_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_ge_64_im_b => {
            binary(fiber, "ge", fiber.readLocal(i64, lastData.s_ge_64_im_b.R0), @as(i64, @bitCast(decodeWideImmediate(fiber))), lastData.s_ge_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_ge_32 => {
            binary(fiber, "ge", fiber.readLocal(f32, lastData.f_ge_32.R0), fiber.readLocal(f32, lastData.f_ge_32.R1), lastData.f_ge_32.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_ge_64 => {
            binary(fiber, "ge", fiber.readLocal(f64, lastData.f_ge_64.R0), fiber.readLocal(f64, lastData.f_ge_64.R1), lastData.f_ge_64.R2);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_ge_32_im_a => {
            binary(fiber, "ge", @as(f32, @bitCast(lastData.f_ge_32_im_a.i0)), fiber.readLocal(f32, lastData.f_ge_32_im_a.R0), lastData.f_ge_32_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_ge_64_im_a => {
            binary(fiber, "ge", @as(f64, @bitCast(decodeWideImmediate(fiber))), fiber.readLocal(f64, lastData.f_ge_64_im_a.R0), lastData.f_ge_64_im_a.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_ge_32_im_b => {
            binary(fiber, "ge", fiber.readLocal(f32, lastData.f_ge_32_im_b.R0), @as(f32, @bitCast(lastData.f_ge_32_im_b.i0)), lastData.f_ge_32_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_ge_64_im_b => {
            binary(fiber, "ge", fiber.readLocal(f64, lastData.f_ge_64_im_b.R0), @as(f64, @bitCast(decodeWideImmediate(fiber))), lastData.f_ge_64_im_b.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },


        .u_ext_8_16 => {
            cast(u8, u16, fiber, lastData.u_ext_8_16.R0, lastData.u_ext_8_16.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_ext_8_32 => {
            cast(u8, u32, fiber, lastData.u_ext_8_32.R0, lastData.u_ext_8_32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_ext_8_64 => {
            cast(u8, u64, fiber, lastData.u_ext_8_64.R0, lastData.u_ext_8_64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_ext_16_32 => {
            cast(u16, u32, fiber, lastData.u_ext_16_32.R0, lastData.u_ext_16_32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_ext_16_64 => {
            cast(u16, u64, fiber, lastData.u_ext_16_64.R0, lastData.u_ext_16_64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u_ext_32_64 => {
            cast(u32, u64, fiber, lastData.u_ext_32_64.R0, lastData.u_ext_32_64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_ext_8_16 => {
            cast(i8, i16, fiber, lastData.s_ext_8_16.R0, lastData.s_ext_8_16.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_ext_8_32 => {
            cast(i8, i32, fiber, lastData.s_ext_8_32.R0, lastData.s_ext_8_32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_ext_8_64 => {
            cast(i8, i64, fiber, lastData.s_ext_8_64.R0, lastData.s_ext_8_64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_ext_16_32 => {
            cast(i16, i32, fiber, lastData.s_ext_16_32.R0, lastData.s_ext_16_32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_ext_16_64 => {
            cast(i16, i64, fiber, lastData.s_ext_16_64.R0, lastData.s_ext_16_64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s_ext_32_64 => {
            cast(i32, i64, fiber, lastData.s_ext_32_64.R0, lastData.s_ext_32_64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_ext_32_64 => {
            cast(f32, i64, fiber, lastData.f_ext_32_64.R0, lastData.f_ext_32_64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_trunc_64_32 => {
            cast(u64, u32, fiber, lastData.i_trunc_64_32.R0, lastData.i_trunc_64_32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_trunc_64_16 => {
            cast(u64, u16, fiber, lastData.i_trunc_64_16.R0, lastData.i_trunc_64_16.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_trunc_64_8 => {
            cast(u64, u8, fiber, lastData.i_trunc_64_8.R0, lastData.i_trunc_64_8.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_trunc_32_16 => {
            cast(u32, u16, fiber, lastData.i_trunc_32_16.R0, lastData.i_trunc_32_16.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_trunc_32_8 => {
            cast(u32, u8, fiber, lastData.i_trunc_32_8.R0, lastData.i_trunc_32_8.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .i_trunc_16_8 => {
            cast(u16, u8, fiber, lastData.i_trunc_16_8.R0, lastData.i_trunc_16_8.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f_trunc_64_32 => {
            cast(f64, f32, fiber, lastData.f_trunc_64_32.R0, lastData.f_trunc_64_32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u8_to_f32 => {
            cast(u8, f32, fiber, lastData.u8_to_f32.R0, lastData.u8_to_f32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u16_to_f32 => {
            cast(u16, f32, fiber, lastData.u16_to_f32.R0, lastData.u16_to_f32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u32_to_f32 => {
            cast(u32, f32, fiber, lastData.u32_to_f32.R0, lastData.u32_to_f32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u64_to_f32 => {
            cast(u64, f32, fiber, lastData.u64_to_f32.R0, lastData.u64_to_f32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s8_to_f32 => {
            cast(i8, f32, fiber, lastData.s8_to_f32.R0, lastData.s8_to_f32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s16_to_f32 => {
            cast(i16, f32, fiber, lastData.s16_to_f32.R0, lastData.s16_to_f32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s32_to_f32 => {
            cast(i32, f32, fiber, lastData.s32_to_f32.R0, lastData.s32_to_f32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s64_to_f32 => {
            cast(i64, f32, fiber, lastData.s64_to_f32.R0, lastData.s64_to_f32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f32_to_u8 => {
            cast(f32, u8, fiber, lastData.f32_to_u8.R0, lastData.f32_to_u8.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f32_to_u16 => {
            cast(f32, u16, fiber, lastData.f32_to_u16.R0, lastData.f32_to_u16.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f32_to_u32 => {
            cast(f32, u32, fiber, lastData.f32_to_u32.R0, lastData.f32_to_u32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f32_to_u64 => {
            cast(f32, u64, fiber, lastData.f32_to_u64.R0, lastData.f32_to_u64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u8_to_f64 => {
            cast(u8, f64, fiber, lastData.u8_to_f64.R0, lastData.u8_to_f64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u16_to_f64 => {
            cast(u16, f64, fiber, lastData.u16_to_f64.R0, lastData.u16_to_f64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u32_to_f64 => {
            cast(u32, f64, fiber, lastData.u32_to_f64.R0, lastData.u32_to_f64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .u64_to_f64 => {
            cast(u64, f64, fiber, lastData.u64_to_f64.R0, lastData.u64_to_f64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s8_to_f64 => {
            cast(i8, f64, fiber, lastData.s8_to_f64.R0, lastData.s8_to_f64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s16_to_f64 => {
            cast(i16, f64, fiber, lastData.s16_to_f64.R0, lastData.s16_to_f64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s32_to_f64 => {
            cast(i32, f64, fiber, lastData.s32_to_f64.R0, lastData.s32_to_f64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .s64_to_f64 => {
            cast(i64, f64, fiber, lastData.s64_to_f64.R0, lastData.s64_to_f64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f64_to_u8 => {
            cast(f64, u8, fiber, lastData.f64_to_u8.R0, lastData.f64_to_u8.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f64_to_u16 => {
            cast(f64, u16, fiber, lastData.f64_to_u16.R0, lastData.f64_to_u16.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f64_to_u32 => {
            cast(f64, u32, fiber, lastData.f64_to_u32.R0, lastData.f64_to_u32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f64_to_u64 => {
            cast(f64, u64, fiber, lastData.f64_to_u64.R0, lastData.f64_to_u64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f32_to_s8 => {
            cast(f32, i8, fiber, lastData.f32_to_s8.R0, lastData.f32_to_s8.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f32_to_s16 => {
            cast(f32, i16, fiber, lastData.f32_to_s16.R0, lastData.f32_to_s16.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f32_to_s32 => {
            cast(f32, i32, fiber, lastData.f32_to_s32.R0, lastData.f32_to_s32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f32_to_s64 => {
            cast(f32, i64, fiber, lastData.f32_to_s64.R0, lastData.f32_to_s64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f64_to_s8 => {
            cast(f64, i8, fiber, lastData.f64_to_s8.R0, lastData.f64_to_s8.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f64_to_s16 => {
            cast(f64, i16, fiber, lastData.f64_to_s16.R0, lastData.f64_to_s16.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f64_to_s32 => {
            cast(f64, i32, fiber, lastData.f64_to_s32.R0, lastData.f64_to_s32.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },

        .f64_to_s64 => {
            cast(f64, i64, fiber, lastData.f64_to_s64.R0, lastData.f64_to_s64.R1);

            if (comptime reswitch) continue :reswitch decodeInstr(fiber, &lastData);
        },
    }

    if (comptime !reswitch) return true;
}

fn stepForeign(fiber: *Fiber) Fiber.Trap!void {
    const currentCallFrame = fiber.stack.call.topPtrUnchecked();
    const foreign = fiber.getForeign(currentCallFrame.function.value.foreign);

    const currentBlockFrame = fiber.blocks.getPtrUnchecked(currentCallFrame.root_block);

    var foreignOut: Fiber.ForeignOut = undefined;
    const control = foreign(fiber, currentBlockFrame.index, &foreignOut);

    switch (control) {
        .trap => return Fiber.convertForeignError(foreignOut.trap),
        .step => currentBlockFrame.index = foreignOut.step,
        .done => {
            fiber.stack.data.ptr = currentCallFrame.stack.base;
            fiber.stack.call.ptr -= 1;
            fiber.blocks.ptr = currentCallFrame.root_block;
        },
        .done_v => {
            const rootBlockFrame = fiber.blocks.getPtrUnchecked(currentCallFrame.root_block);

            const out = fiber.readLocal(u64, foreignOut.done_v);

            fiber.writeReg(fiber.stack.call.ptr -| 2, rootBlockFrame.out, out);

            fiber.stack.data.ptr = currentCallFrame.stack.base;
            fiber.stack.call.ptr -= 1;
            fiber.blocks.ptr = currentCallFrame.root_block;
        },
    }
}

pub fn alloca(fiber: *Fiber, size: u16, y: Rbc.RegisterIndex) Fiber.Trap!void {
    const wordSize = byteSizeToWordSize(size);

    if (!fiber.data.hasSpace(wordSize)) {
        @branchHint(.cold);
        return Fiber.Trap.Overflow;
    }

    const ptr = fiber.data.incrGet(wordSize);

    fiber.writeLocal(y, ptr);
}

pub fn addr_global(fiber: *Fiber, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) void {
    const global = fiber.addrGlobal(g);
    fiber.writeLocal(x, global);
}

pub fn addr_upvalue(fiber: *Fiber, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) void {
    const upvalue = fiber.addrUpvalue(u);
    fiber.writeLocal(x, upvalue);
}

fn addr_local(fiber: *Fiber, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) void {
    const local = fiber.addrLocal(x);
    fiber.writeLocal(y, local);
}

pub fn read_global(comptime T: type, fiber: *Fiber, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) void {
    const global = fiber.readGlobal(T, g);
    fiber.writeLocal(x, global);
}

pub fn read_upvalue(comptime T: type, fiber: *Fiber, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) void {
    const upvalue = fiber.readUpvalue(T, u);
    fiber.writeLocal(x, upvalue);
}


pub fn load(comptime T: type, fiber: *Fiber, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Fiber.Trap!void {
    const in = fiber.readLocal(*T, x);
    try fiber.boundsCheck(in, @sizeOf(T));
    fiber.writeLocal(y, in.*);
}

pub fn store(fiber: *Fiber, x: anytype, y: Rbc.RegisterIndex) Fiber.Trap!void {
    const T = @TypeOf(x);
    const out = fiber.readLocal(*T, y);
    try fiber.boundsCheck(out, @sizeOf(T));
    out.* = x;
}


pub fn clear(comptime T: type, fiber: *Fiber, x: Rbc.RegisterIndex) void {
    fiber.writeLocal(x, @as(T, 0));
}

pub fn swap(comptime T: type, fiber: *Fiber, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) void {
    const temp = fiber.readLocal(T, x);
    const yVal = fiber.readLocal(T, y);
    fiber.writeLocal(x, yVal);
    fiber.writeLocal(y, temp);
}



fn when(fiber: *Fiber, newBlockIndex: Rbc.BlockIndex, x: Rbc.RegisterIndex, comptime zeroCheck: ZeroCheck) void {
    const cond = fiber.readLocal(u8, x);

    const newBlock = fiber.calls.top().function.bytecode.blocks[newBlockIndex];

    const newBlockFrame = Fiber.BlockFrame {
        .base = newBlock,
        .ip = newBlock,
        .out = undefined,
        .handler_set = null,
    };

    switch (zeroCheck) {
        .zero => if (cond == 0) fiber.blocks.push(newBlockFrame),
        .non_zero => if (cond != 0) fiber.blocks.push(newBlockFrame),
    }
}

fn br(fiber: *Fiber, terminatedBlockOffset: Rbc.BlockIndex, x: Rbc.RegisterIndex, comptime zeroCheck: ?ZeroCheck, y: u64, comptime style: ReturnStyle) void {
    const terminatedBlockPtr: [*]Fiber.BlockFrame = fiber.blocks.top_ptr - terminatedBlockOffset;

    if (comptime zeroCheck) |zc| {
        const cond = fiber.readLocal(u8, x);

        switch (zc) {
            .zero => if (cond != 0) return,
            .non_zero => if (cond == 0) return,
        }
    }

    if (comptime style == .v) {
        fiber.writeLocal(terminatedBlockPtr[0].out, y);
    }

    fiber.removeAnyHandlerSet(@ptrCast(terminatedBlockPtr));

    fiber.blocks.top_ptr = terminatedBlockPtr;
}

fn re(fiber: *Fiber, restartedBlockOffset: Rbc.BlockIndex, x: Rbc.RegisterIndex, comptime zeroCheck: ?ZeroCheck) void {
    const restartedBlockPtr: [*]Fiber.BlockFrame = fiber.blocks.top_ptr - restartedBlockOffset;

    if (zeroCheck) |zc| {
        const cond = fiber.readLocal(u8, x);

        switch (zc) {
            .zero => if (cond != 0) return,
            .non_zero => if (cond == 0) return,
        }
    }

    restartedBlockPtr[0].ip = restartedBlockPtr[0].base;
    fiber.blocks.top_ptr = restartedBlockPtr;
}

fn block(fiber: *Fiber, newBlockIndex: Rbc.BlockIndex, y: Rbc.RegisterIndex) void {
    const newBlock = fiber.calls.top().function.bytecode.blocks[newBlockIndex];

    const newBlockFrame = Fiber.BlockFrame {
        .base = newBlock,
        .ip = newBlock,
        .out = y,
        .handler_set = null,
    };

    fiber.blocks.push(newBlockFrame);
}

fn with(fiber: *Fiber, newBlockIndex: Rbc.BlockIndex, handlerSetIndex: Rbc.HandlerSetIndex, y: Rbc.RegisterIndex) Fiber.Trap!void {
    const handlerSet = &fiber.program.handler_sets[handlerSetIndex];

    const newBlock = fiber.calls.top().function.bytecode.blocks[newBlockIndex];

    const newBlockFrame = Fiber.BlockFrame {
        .base = newBlock,
        .ip = newBlock,
        .out = y,
        .handler_set = handlerSet,
    };

    fiber.blocks.push(newBlockFrame);

    if (!fiber.data.hasSpace(handlerSet.len)) {
        @branchHint(.cold);
        return Fiber.Trap.Overflow;
    }

    const oldHandlerStorage: [*]Fiber.Evidence = @ptrCast(fiber.data.incrGet(handlerSet.len * (@sizeOf(Fiber.Evidence) / @sizeOf(Rbc.Register))));

    for (handlerSet.*, 0..) |binding, i| {
        oldHandlerStorage[i] = fiber.evidence[binding.id];
        fiber.evidence[binding.id] = Fiber.Evidence {
            .handler = &fiber.program.functions[binding.handler],
            .call = fiber.calls.top(),
            .block = fiber.blocks.top(),
            .data = fiber.data.top_ptr,
        };
    }
}

fn @"if"(fiber: *Fiber, thenBlockIndex: Rbc.BlockIndex, elseBlockIndex: Rbc.BlockIndex, x: Rbc.RegisterIndex, comptime zeroCheck: ZeroCheck, y: Rbc.RegisterIndex) void {
    const cond = fiber.readLocal(u8, x);

    const newBlockIndex = switch (zeroCheck) {
        .zero => if (cond == 0) thenBlockIndex else elseBlockIndex,
        .non_zero => if (cond != 0) thenBlockIndex else elseBlockIndex,
    };

    const newBlock = fiber.calls.top().function.bytecode.blocks[newBlockIndex];

    const newBlockFrame = Fiber.BlockFrame {
        .base = newBlock,
        .ip = newBlock,
        .out = y,
        .handler_set = null,
    };

    fiber.blocks.push(newBlockFrame);
}



fn call(fiber: *Fiber, newFunction: *const Rbc.Function, y: Rbc.RegisterIndex) Fiber.Trap!void {
    if (( fiber.data.hasSpaceU1(newFunction.num_registers)
        & fiber.calls.hasSpaceU1(1)
        ) != 1)
    {
        @branchHint(.cold);
        if (!fiber.data.hasSpace(newFunction.num_registers)) {
            std.debug.print("stack overflow @{}\n", .{Fiber.DATA_STACK_SIZE});
        }
        if (!fiber.calls.hasSpace(1)) {
            std.debug.print("call overflow @{}\n", .{Fiber.CALL_STACK_SIZE});
        }
        return Fiber.Trap.Overflow;
    }

    const arguments = decodeArguments(fiber, newFunction.num_arguments);

    const data = fiber.data.incrGetMulti(newFunction.num_registers);

    const newBlock = newFunction.bytecode.blocks[0];

    const newBlockFrame = fiber.blocks.pushGet(Fiber.BlockFrame {
        .base = newBlock,
        .ip = newBlock,
        .out = y,
        .handler_set = null,
    });

    const oldCallFrame = fiber.calls.top();

    fiber.calls.push(Fiber.CallFrame {
        .function = newFunction,
        .evidence = undefined,
        .block = newBlockFrame,
        .data = data,
    });

    for (0..newFunction.num_arguments) |i| {
        const value = Fiber.readReg(u64, oldCallFrame, arguments[i]);
        Fiber.writeReg(fiber.calls.top(), @truncate(i), value);
    }
}

fn tail_call(fiber: *Fiber, registerScratchSpace: [*]u64, newFunction: *const Rbc.Function) Fiber.Trap!void {
    const callFrame = fiber.calls.top();
    const blockFrame = fiber.blocks.top();

    const oldFunction = callFrame.function;

    if (!fiber.data.hasSpace(newFunction.num_registers -| oldFunction.num_registers)) {
        @branchHint(.cold);
        std.debug.print("stack overflow @{}\n", .{Fiber.DATA_STACK_SIZE});
        return Fiber.Trap.Overflow;
    }

    const arguments = decodeArguments(fiber, newFunction.num_arguments);

    for (0..newFunction.num_arguments) |i| {
        const value = fiber.readLocal(u64, arguments[i]);
        registerScratchSpace[i] = value;
    }

    for (0..newFunction.num_arguments) |i| {
        fiber.writeLocal(@truncate(i), registerScratchSpace[i]);
    }

    const newBlock = newFunction.bytecode.blocks[0];
    blockFrame.base = newBlock;
    blockFrame.ip = newBlock;
    blockFrame.handler_set = null;

    callFrame.evidence = undefined;
    callFrame.function = newFunction;

    fiber.blocks.top_ptr = @ptrCast(blockFrame);

    fiber.data.top_ptr =
        if (oldFunction.num_registers > newFunction.num_registers)
            fiber.data.top_ptr - (oldFunction.num_registers - newFunction.num_registers)
        else
            fiber.data.top_ptr + (newFunction.num_registers - oldFunction.num_registers);
}

fn prompt(fiber: *Fiber, evIndex: Rbc.EvidenceIndex, y: Rbc.RegisterIndex) Fiber.Trap!void {
    const ev = &fiber.evidence[evIndex];

    try call(fiber, ev.handler, y);

    fiber.calls.top().evidence = ev;
}

fn ret(fiber: *Fiber, y: u64, comptime style: ReturnStyle) void {
    const currentCallFrame = fiber.calls.top();

    const rootBlockFrame = currentCallFrame.block;

    if (comptime style == .v) {
        Fiber.writeReg(@ptrCast(fiber.calls.top_ptr - 1), rootBlockFrame.out, y);
    }

    fiber.data.top_ptr = currentCallFrame.data;
    fiber.calls.pop();
    fiber.blocks.top_ptr = @as([*]Fiber.BlockFrame, @ptrCast(rootBlockFrame)) - 1;
}

fn term(fiber: *Fiber, y: u64, comptime style: ReturnStyle) void {
    const currentCallFrame = fiber.calls.top();

    const ev = currentCallFrame.evidence;

    if (comptime style == .v) {
        Fiber.writeReg(ev.call, ev.block.out, y);
    }

    fiber.calls.top_ptr = @ptrCast(ev.call);
    fiber.blocks.top_ptr = @as([*]Fiber.BlockFrame, @ptrCast(ev.block)) - 1;
    fiber.data.top_ptr = ev.data;
}


pub fn cast(comptime X: type, comptime Y: type, fiber: *Fiber, xOp: Rbc.RegisterIndex, yOp: Rbc.RegisterIndex) void {
    const x = fiber.readLocal(X, xOp);

    const xKind = @as(std.builtin.TypeId, @typeInfo(X));
    const yKind = @as(std.builtin.TypeId, @typeInfo(Y));

    const y =
        if (comptime xKind == yKind) (
            if (comptime xKind == .int) ops.intCast(Y, x)
            else ops.floatCast(Y, x)
        ) else ops.typeCast(Y, x);

    fiber.writeLocal(yOp, y);
}

pub fn unary(fiber: *Fiber, comptime op: []const u8, x: anytype, y: Rbc.RegisterIndex) void {
    fiber.writeLocal(y, @field(ops, op)(x));
}

pub fn binary(fiber: *Fiber, comptime op: []const u8, x: anytype, y: @TypeOf(x), z: Rbc.RegisterIndex) void {
    fiber.writeLocal(z, @field(ops, op)(x, y));
}

const ops = struct {
    fn intCast(comptime T: type, x: anytype) T {
        const U = @TypeOf(x);

        if (comptime @typeInfo(U).int.bits > @typeInfo(T).int.bits) {
            return @truncate(x);
        } else {
            return x;
        }
    }

    fn floatCast(comptime T: type, x: anytype) T {
        return @floatCast(x);
    }

    fn typeCast(comptime T: type, x: anytype) T {
        const U = @TypeOf(x);

        const tagT = @as(std.builtin.TypeId, @typeInfo(T));
        const tagU = @as(std.builtin.TypeId, @typeInfo(U));

        if (comptime tagT == .int and tagU == .float) {
            return @intFromFloat(x);
        } else if (comptime tagT == .float and tagU == .int) {
            return @floatFromInt(x);
        } else unreachable;
    }

    fn neg(a: anytype) @TypeOf(a) {
        switch (@typeInfo(@TypeOf(a))) {
            .int => return -% a,
            else => return -a,
        }
    }

    fn add(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
        switch (@typeInfo(@TypeOf(a))) {
            .int => return a +% b,
            else => return a + b,
        }
    }

    fn sub(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
        switch (@typeInfo(@TypeOf(a))) {
            .int => return a -% b,
            else => return a - b,
        }
    }

    fn mul(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
        switch (@typeInfo(@TypeOf(a))) {
            .int => return a *% b,
            else => return a * b,
        }
    }

    fn div(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
        switch (@typeInfo(@TypeOf(a))) {
            .int => return @divTrunc(a, b),
            else => return a / b,
        }
    }

    fn rem(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
        return @rem(a, b);
    }

    fn bnot(a: anytype) @TypeOf(a) {
        return ~a;
    }

    fn band(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
        return a & b;
    }

    fn bor(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
        return a | b;
    }

    fn bxor(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
        return a ^ b;
    }

    fn bshiftl(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
        const T = @TypeOf(a);
        const bits = @bitSizeOf(T);
        const S = std.meta.Int(.unsigned, std.math.log2(bits));
        const U = std.meta.Int(.unsigned, bits);
        const bu: U = @bitCast(b);
        const bs: U = @rem(std.math.maxInt(S), bu);
        return a << @truncate(bs);
    }

    fn bshiftr(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
        const T = @TypeOf(a);
        const bits = @bitSizeOf(T);
        const S = std.meta.Int(.unsigned, std.math.log2(bits));
        const U = std.meta.Int(.unsigned, bits);
        const bu: U = @bitCast(b);
        const bs: U = @rem(std.math.maxInt(S), bu);
        return a >> @truncate(bs);
    }

    fn eq(a: anytype, b: @TypeOf(a)) bool {
        return a == b;
    }

    fn ne(a: anytype, b: @TypeOf(a)) bool {
        return a != b;
    }

    fn lt(a: anytype, b: @TypeOf(a)) bool {
        return a < b;
    }

    fn gt(a: anytype, b: @TypeOf(a)) bool {
        return a > b;
    }

    fn le(a: anytype, b: @TypeOf(a)) bool {
        return a <= b;
    }

    fn ge(a: anytype, b: @TypeOf(a)) bool {
        return a >= b;
    }
};
