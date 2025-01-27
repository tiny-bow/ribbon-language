const std = @import("std");

const zig_builtin = @import("builtin");

const utils = @import("utils");
const Rvm = @import("Rvm");
const Builder = @import("RbcBuilder");
const log = std.log.scoped(.rvm);

pub const std_options = std.Options {
    .log_level = .info,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const context = try Rvm.Context.init(arena.allocator());
    // defer context.deinit();

    var builder = try Builder.init(arena.allocator());

    // const out_global = try builder.globalNative(@as(i64, 0));

    const one = try builder.globalNative(@as(i64, 1));
    const two = try builder.globalNative(@as(i64, 2));

    const func = try builder.main();


    const arg = try func.arg();
    const cond = try func.local();
    const two_loaded = try func.local();
    const one_loaded = try func.local();
    try func.entry.read_global_64(two.index, two_loaded);
    try func.entry.read_global_64(one.index, one_loaded);
    try func.entry.s_lt_64(arg, two_loaded, cond);
    const thenBlock, const elseBlock = try func.entry.if_nz(cond);

    try func.entry.trap();

    try thenBlock.ret_v(arg);

    const a = try func.local();
    try elseBlock.i_sub_64(arg, one_loaded, a);
    try elseBlock.call_im_v(func, a, .{a});

    const b = try func.local();
    try elseBlock.i_sub_64(arg, two_loaded, b);
    try elseBlock.call_im_v(func, b, .{b});

    try elseBlock.i_add_64(a, b, a);
    try elseBlock.ret_v(a);

    const program = try builder.assemble(arena.allocator());
    // defer program.deinit(arena.allocator());


    const fiber = try Rvm.Fiber.init(context, &program, &[0] Rvm.Fiber.ForeignFunction {});
    defer fiber.deinit();

    const n: i64 = 32;

    const start = std.time.nanoTimestamp();

    const result = try fiber.invoke(i64, program.main, .{ n });

    const end = std.time.nanoTimestamp();

    const time = @as(f64, @floatFromInt(end - start)) / std.time.ns_per_s;


    try std.io.getStdOut().writer().print("result: {} (in {d:.3}s)\n", .{result, time});
    try std.testing.expectEqual(2178309, result);
}

// fn fib(n: i64) i64 {
//     return if (n < 2) n else fib(n - 1) + fib(n - 2);
// }


test {
    std.testing.refAllDeclsRecursive(@This());
}
