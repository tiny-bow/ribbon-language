const std = @import("std");

const RirCore = @import("Rir:Core");

pub const std_options = std.Options {
    .log_level = .debug,
};

const log = std.log.scoped(.main);


pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    var ir = try RirCore.IR.init(allocator);
    defer ir.deinit();


    const module = try ir.module(try ir.intern("test-module"));

    const one = try module.globalFromNative(try ir.intern("one"), @as(i32, 1), null);

    const Incr = try module.typeIdFromNative(fn (i32) i32, &.{"n"});
    const incr = try module.function(try ir.intern("incr"), Incr);

    const arg = try incr.getArgument(0);

    const entry = incr.entry();
    try entry.ref_local(arg.id);
    try entry.ref_global(one.id);
    try entry.add();
    try entry.ret();

    const stdout = std.io.getStdOut().writer();

    var formatter = try RirCore.Formatter.init(&ir, stdout.any());
    defer formatter.deinit();

    try formatter.fmt(module);
}
