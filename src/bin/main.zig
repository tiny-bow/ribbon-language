const driver = @This();

const std = @import("std");

const ribbon = @import("ribbon_language");
const pl = @import("platform");

const log = std.log.scoped(.main);

const repl = @import("repl");

pub const std_options = std.Options{
    .log_level = .debug,
};

const Repl = repl.Builder(ReplContext);

const ReplContext = struct {
    pub const Error = anyerror;
};

pub fn main() !void {
    std.debug.print("interpreter_basic_integration\n", .{});
    const allocator = std.heap.page_allocator;

    const b = try ribbon.bytecode.Builder.init(allocator, .fromInt(0));
    defer b.deinit();

    const entry = try b.createBlock();

    try entry.instr(.i_add64, .{ .Rx = .r7, .Ry = .r0, .Rz = .r1 });
    try entry.instr(.@"return", .{ .R = .r7 });

    var encoder = try ribbon.bytecode.Encoder.init();
    defer encoder.writer.deinit();

    try b.encode(&encoder);

    const mem = try encoder.finalize();
    defer std.posix.munmap(mem);

    const instr: []const ribbon.core.InstructionBits = @ptrCast(mem);

    const stdout = std.io.getStdOut();

    try ribbon.bytecode.disas(mem, stdout.writer());

    const fiber = try ribbon.core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    const function = ribbon.core.Function{
        .header = ribbon.core.EMPTY_HEADER,
        .extents = .{ .base = instr.ptr, .upper = instr.ptr + instr.len },
        .stack_size = 0,
    };

    const result = try ribbon.interpreter.invokeBytecode(fiber, &function, &.{ 3, 2 });
    log.info("{} + {} = {}", .{ 3, 2, result });
    try std.testing.expectEqual(5, result);
}

// pub fn main() !void {
//     log.warn("todo: full CLI; repl-only mode enabled", .{});

//     const allocator = std.heap.page_allocator;

//     const args = try std.process.argsAlloc(allocator);
//     defer std.process.argsFree(allocator, args);

//     var ctx = ReplContext{};

//     var R = Repl.init(&ctx, allocator);
//     defer R.deinit();

//     var line_count: u32 = 0;

//     var line_accumulator = std.ArrayList(u8).init(allocator);
//     defer line_accumulator.deinit();

//     while (R.getInput(">") catch |err| {
//         switch (err) {
//             error.EndOfStream => {
//                 std.debug.print("[STREAM CLOSED] goodbye 💝\n", .{});
//                 return;
//             },
//             error.CtrlC => {
//                 std.debug.print("[CTRL + C] goodbye 💝\n", .{});
//                 return;
//             },
//             else => {
//                 log.err("cannot get input: {}", .{err});
//                 return err;
//             },
//         }
//     }) |input| {
//         if (std.mem.eql(u8, input, "exit")) {
//             std.debug.print("[EXIT] goodbye 💝\n", .{});
//             return;
//         }

//         line_count += 1;

//         line_accumulator.appendSlice(input) catch @panic("OOM in line accumulator");

//         var expr = ribbon.meta_language.getExpr(
//             allocator,
//             .{ .attrOffset = .{ .column = 0, .line = line_count } },
//             "stdin",
//             line_accumulator.items,
//         ) catch |err| {
//             if (err == error.UnexpectedEof) {
//                 std.debug.print("Incomplete input, waiting for more...\n", .{});
//             } else {
//                 log.err("Error parsing input: {}", .{err});
//                 R.history.add(line_accumulator.items) catch @panic("OOM in history");

//                 line_accumulator.clearRetainingCapacity();
//             }

//             continue;
//         } orelse continue;
//         defer expr.deinit(allocator);

//         R.history.add(line_accumulator.items) catch @panic("OOM in history");

//         line_accumulator.clearRetainingCapacity();

//         std.debug.print("{}\n", .{expr});
//     }
// }
