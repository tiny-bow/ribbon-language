const driver = @This();

const std = @import("std");

const ribbon = @import("ribbon");

const log = std.log.scoped(.main);

pub const std_options = std.Options{
    .log_level = .info,
};


pub fn main() !void {
    // @breakpoint();

    log.info("Running tests ...", .{});

    try test_bytecode_builder();

    // try test_rir();
    // try test_x64();

    log.info("... All tests passed!", .{});
}

fn test_bytecode_builder() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const b = try ribbon.bytecode.Builder.init(allocator, ribbon.common.Id.of(ribbon.core.Function).fromInt(0));
    defer b.deinit();

    const entry = try b.createBlock();

    try entry.instr(.i_add64, .{ .Rx = .r7, .Ry = .r32, .Rz = .r255 });

    var encoder = ribbon.bytecode.Encoder { .writer = try ribbon.bytecode.Writer.init() };
    defer encoder.writer.deinit();

    try b.encode(&encoder);

    const mem = try encoder.finalize();
    defer std.posix.munmap(mem);

    const stdout = std.io.getStdOut();

    try ribbon.bytecode.disas(mem, stdout.writer());
}

fn test_rir() !void {

    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();


    const ir = try ribbon.ir.Builder.init(allocator);
    defer ir.deinit();

    const foo = try ir.internName("foo");
    const bar = try ir.internName("bar");
    const foo2 = try ir.internName("foo");

    try std.testing.expectEqual(foo, foo2);
    try std.testing.expect(foo != bar);

    log.debug("foo: {} bar: {}", .{ foo, bar });

    const i64Name = try ir.internName("i64");

    log.debug("i64Name: {}", .{ i64Name });

    const i64Type = try ir.internType(i64Name, ribbon.ir.TypeInfo {
        .integer = .{ .bit_size = 64, .signedness = .signed },
    });

    log.debug("I64: {}", .{ i64Type });


    const aData = ribbon.ir.ConstantData {
        .type = i64Type,
        .bytes = std.mem.asBytes(&@as(i64, -23)),
    };

    const bData = ribbon.ir.ConstantData {
        .type = i64Type,
        .bytes = std.mem.asBytes(&@as(i64, 42)),
    };

    const a = try ir.internConstant(try ir.internName("a"), aData);
    const b = try ir.internConstant(try ir.internName("b"), bData);
    const a2 = try ir.internConstant(try ir.internName("a2"), aData);

    try std.testing.expectEqual(a, a2);
    try std.testing.expect(a != b);
}


fn test_x64() !void {
    try test_interpreter();
    try test_jit();
}

fn test_interpreter() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const fiber = try ribbon.core.Fiber.init(allocator);
    defer fiber.deinit(allocator);
    const byteCount = @sizeOf(ribbon.platform.uword) * 64;
    const extraMem = byteCount + @sizeOf(ribbon.core.Function) + @sizeOf([*]ribbon.core.Function) + @sizeOf(ribbon.core.Constant);
    const totalMem = @sizeOf(ribbon.core.Header) + extraMem;
    const buffer = try allocator.allocWithOptions(u8, totalMem, @alignOf(ribbon.core.Header), null);
    defer allocator.free(buffer);
    const header: *ribbon.core.Header = @ptrCast(buffer);
    header.size = totalMem;
    header.instructions = @ptrCast(buffer.ptr + @sizeOf(ribbon.core.Header) + @sizeOf([*]ribbon.core.Function) + @sizeOf(ribbon.core.Constant));
    header.functions = @ptrCast(buffer.ptr + @sizeOf(ribbon.core.Header));
    header.constants = @ptrCast(buffer.ptr + @sizeOf(ribbon.core.Header) + @sizeOf([*]ribbon.core.Function));

    const function: *ribbon.core.Function = @ptrCast(buffer.ptr + @sizeOf(ribbon.core.Header) + @sizeOf([*]ribbon.core.Function) + @sizeOf(ribbon.core.Constant));
    @constCast(header.functions)[0] = function;
    function.* = ribbon.core.Function {
        .header = header,
        .id = @enumFromInt(0),
        .base_address = header.instructions,
        .stack_size = 0,
    };

    var instruction_ptr: [*]u8 = @ptrCast(@constCast(header.instructions));

    // Encode i_add64 instruction
    @as([*]u16, @alignCast(@ptrCast(instruction_ptr)))[0] = @intFromEnum(ribbon.core.OpCode.@"i_add64"); // Opcode
    instruction_ptr = @ptrCast(instruction_ptr + 2); // Advance past opcode (2 bytes)
    @as([*]ribbon.core.operand_sets.@"i_add64", @alignCast(@ptrCast(instruction_ptr)))[0] = ribbon.core.operand_sets.@"i_add64"{
        .Rx = .r2,
        .Ry = .r0,
        .Rz = .r1,
    };
    instruction_ptr = @ptrCast(instruction_ptr + 4); // Advance past operands & padding

    // Encode return_v instruction
    @as([*]u16, @alignCast(@ptrCast(instruction_ptr)))[0] = @intFromEnum(ribbon.core.OpCode.@"return_v"); // Opcode
    instruction_ptr = @ptrCast(instruction_ptr + 2); // Advance past opcode (2 bytes)
    @as([*]ribbon.core.operand_sets.@"return_v", @alignCast(@ptrCast(instruction_ptr)))[0] = ribbon.core.operand_sets.@"return_v"{ .R = .r2 }; // Operands
    instruction_ptr = @ptrCast(instruction_ptr + 4); // Advance past operands & padding

    try std.fmt.formatInt(@intFromEnum(ribbon.core.OpCode.@"i_add64"), 16, .lower, .{ .alignment = .right, .width = 2, .fill = '0' }, std.io.getStdErr().writer());
    std.debug.print("\n", .{});
    std.debug.print("function instructions: {?x:0>16}\n", .{ @intFromPtr(function.base_address) });
    const x: i64 = -8;
    const y: i64 = 2;
    const z: i64 = @bitCast(fiber.invokeBytecode(function, &.{ @as(ribbon.platform.uword, @bitCast(x)), @as(ribbon.platform.uword, @bitCast(y)) }) catch |err| {
        if (fiber.header.trap) |causePtr| {
            log.err("Native Error: {}, cause_ptr: {?x:0>16}", .{ err, @intFromPtr(causePtr) });
            switch (err) {
                error.BadEncoding => log.err("Badly encoded opcode: {x}", .{ @as(*const u16, @alignCast(@ptrCast(causePtr))).* }),
                else => log.err("?? Cause ptr is not expected for this error type ??", .{}),
            }
        }
        return err;
    });
    try std.testing.expectEqual(x + y, z);
}


fn test_jit() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();


    const fiber = try ribbon.core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    var jit = try ribbon.machine.Builder.init();
    defer jit.deinit();

    try jit.i_add_64(.r(2), .r(0), .r(1));
    try jit.ret(.r(2));

    const exe = try jit.finalize();
    defer exe.deinit();

    try exe.disas(.{}, std.io.getStdOut().writer());

    const x: i64 = -8;
    const y: i64 = 2;

    const z: i64 = @bitCast(try exe.invoke(fiber, &.{ @as(ribbon.platform.uword, @bitCast(x)), @as(ribbon.platform.uword, @bitCast(y)) }));

    try std.testing.expectEqual(x + y, z);

    log.info("{} + {} = {}", .{ x, y, z });

    try std.testing.expectEqual(
        @as(i64, @intCast(@intFromPtr(fiber.header.calls.memory))) - @sizeOf(ribbon.core.CallFrame),
        @as(i64, @intCast(@intFromPtr(fiber.header.calls.top_ptr))),
    );
}
